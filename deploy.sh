#!/usr/bin/env bash
# deploy.sh — Spins up (or tears down) a complete, disposable Kasten K10
# training lab on a local k3d (k3s-in-Docker) cluster. Works the same way on
# macOS and Linux — the only real dependency is Docker; everything else
# (k3d, kubectl, helm) is checked for and, if missing, you get the exact
# command to install it for your OS rather than the script trying to
# sudo-install things for you.
#
# This is a single, self-contained file: no `git clone` of this repo (just
# download this one script and run it) and no `git clone` of anything else
# either — every manifest is inlined below, and the two things that used to
# need a real git checkout (the CSI driver's install script, and two
# `kubectl apply -k github.com/...` kustomizations, which secretly shell out
# to git too) are instead fetched as plain files over HTTPS. `git` isn't a
# dependency of this lab at all.
#
# Usage:
#   ./deploy.sh            # stand up the lab (safe to re-run)
#   ./deploy.sh destroy    # tear down the k3d cluster (only cleanup needed)
#
# What deploy creates, in order:
#   1. A k3d cluster (Traefik disabled — Kasten doesn't need it here)
#   2. The VolumeSnapshot CRDs + snapshot-controller (k3s ships neither)
#   3. The CSI hostpath driver (kubernetes-csi/csi-driver-host-path) — a
#      real, snapshot-capable CSI driver, unlike k3s's built-in
#      "local-path" storage class which cannot do CSI snapshots at all.
#      Exposed as two StorageClasses backed by the same driver: sc1 (the
#      cluster default — Kasten/MinIO/demo-app all land here) and sc2
#      (unused at deploy time, reserved for training exercises).
#   4. A tiny single-instance MinIO (1Gi) — Kasten's export/location target
#   5. A sample app (namespace + ConfigMap + a 10Mi PVC + a Deployment that
#      continuously appends timestamps to a file on that PVC)
#   6. Kasten K10 itself, with the EULA pre-accepted and a location profile
#      already pointed at the in-cluster MinIO
#
# Re-running this script is safe: every step either no-ops or upgrades in
# place if it already ran before.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kasten-training}"
EXTERNAL_SNAPSHOTTER_VERSION="v8.6.0"
CSI_HOSTPATH_VERSION="v1.18.0"
# The directory kubernetes-csi/csi-driver-host-path's `deploy/kubernetes-latest`
# symlink currently resolves to, for CSI_HOSTPATH_VERSION above. Only needed
# because we fetch files directly over HTTPS instead of git-cloning (raw
# GitHub URLs don't follow symlinks) — if CSI_HOSTPATH_VERSION is ever
# bumped, check what `deploy/kubernetes-latest` points to at that tag
# (https://github.com/kubernetes-csi/csi-driver-host-path/tree/<tag>/deploy)
# and update this to match.
CSI_HOSTPATH_DIR="kubernetes-1.34"
ADMIN_EMAIL="${ADMIN_EMAIL:-trainee@example.com}"
K10_AUTH_USER="${K10_AUTH_USER:-admin}"
K10_AUTH_PASS="${K10_AUTH_PASS:-kasten123}"

log() { printf '\n==> %s\n' "$*"; }

# --- destroy -----------------------------------------------------------------
if [ "${1:-}" = "destroy" ]; then
  if ! command -v k3d >/dev/null 2>&1; then
    echo "k3d is not installed — nothing to do." >&2
    exit 0
  fi
  if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
    log "Deleting k3d cluster '${CLUSTER_NAME}'..."
    k3d cluster delete "$CLUSTER_NAME"
    echo "Done."
  else
    echo "No cluster named '${CLUSTER_NAME}' found — nothing to do."
  fi
  exit 0
fi

# --- 0. Prerequisites -------------------------------------------------------
need() {
  local bin="$1" hint="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Missing dependency: $bin" >&2
    echo "  Install it with: $hint" >&2
    exit 1
  fi
}

os="$(uname -s)"
case "$os" in
  Darwin)
    need docker "Docker Desktop — https://www.docker.com/products/docker-desktop/"
    need k3d    "brew install k3d"
    need kubectl "brew install kubectl"
    need helm   "brew install helm"
    need curl   "brew install curl"
    need openssl "brew install openssl"
    ;;
  Linux)
    need docker "curl -fsSL https://get.docker.com | sh"
    need k3d    "curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
    need kubectl "curl -LO https://dl.k8s.io/release/\$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl && sudo install -m 0755 kubectl /usr/local/bin/kubectl"
    need helm   "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    need curl   "your distro's package manager, e.g. sudo apt install -y curl"
    need openssl "your distro's package manager, e.g. sudo apt install -y openssl"
    ;;
  *)
    echo "Unsupported OS: $os — this lab targets macOS and Linux. On Windows, run it from inside WSL2 (which reports itself as Linux) — see prereqs.ps1 to get WSL2 set up." >&2
    exit 1
    ;;
esac

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but not reachable — start Docker Desktop (or the docker daemon) and try again." >&2
  exit 1
fi

# --- 1. k3d cluster ----------------------------------------------------------
if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
  log "k3d cluster '${CLUSTER_NAME}' already exists — reusing it."
else
  log "Creating k3d cluster '${CLUSTER_NAME}' (1 server + 1 agent)..."
  k3d cluster create "$CLUSTER_NAME" \
    --agents 1 \
    --k3s-arg "--disable=traefik@server:0" \
    --wait
fi

k3d kubeconfig merge "$CLUSTER_NAME" --kubeconfig-switch-context >/dev/null
kubectl wait --for=condition=ready node --all --timeout=120s
kubectl cluster-info

# --- 2. VolumeSnapshot CRDs + snapshot-controller ---------------------------
# Cluster-wide prerequisite for ANY CSI driver's snapshot feature — k3s
# doesn't ship these, regardless of which CSI driver you pick. Applied as
# plain files (not `kubectl apply -k github.com/...`) since that kustomize
# remote-fetch path shells out to a local `git` binary — this doesn't.
SNAPSHOTTER_RAW="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${EXTERNAL_SNAPSHOTTER_VERSION}"

log "Installing VolumeSnapshot CRDs (external-snapshotter ${EXTERNAL_SNAPSHOTTER_VERSION})..."
kubectl apply \
  -f "${SNAPSHOTTER_RAW}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml" \
  -f "${SNAPSHOTTER_RAW}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml" \
  -f "${SNAPSHOTTER_RAW}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml" \
  -f "${SNAPSHOTTER_RAW}/client/config/crd/groupsnapshot.storage.k8s.io_volumegroupsnapshotclasses.yaml" \
  -f "${SNAPSHOTTER_RAW}/client/config/crd/groupsnapshot.storage.k8s.io_volumegroupsnapshotcontents.yaml" \
  -f "${SNAPSHOTTER_RAW}/client/config/crd/groupsnapshot.storage.k8s.io_volumegroupsnapshots.yaml"

log "Installing the snapshot-controller..."
kubectl apply \
  -f "${SNAPSHOTTER_RAW}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml" \
  -f "${SNAPSHOTTER_RAW}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"
kubectl -n kube-system rollout status deployment/snapshot-controller --timeout=120s

# --- 3. CSI hostpath driver (snapshot-capable; local-path is not) ----------
log "Installing the CSI hostpath driver (csi-driver-host-path ${CSI_HOSTPATH_VERSION})..."
# The upstream install script lives at deploy/util/deploy-hostpath.sh and
# expects to run next to a hostpath/ directory containing these manifests
# (that's normally what deploy/kubernetes-latest/ symlinks resolve to) — we
# recreate that exact layout in a temp dir with plain curl fetches instead
# of a git clone.
CSI_RAW="https://raw.githubusercontent.com/kubernetes-csi/csi-driver-host-path/${CSI_HOSTPATH_VERSION}"
TMP_CSI_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_CSI_DIR"' EXIT
mkdir -p "$TMP_CSI_DIR/hostpath"
curl -fsSL "${CSI_RAW}/deploy/util/deploy-hostpath.sh" -o "$TMP_CSI_DIR/deploy.sh"
chmod +x "$TMP_CSI_DIR/deploy.sh"
for f in csi-hostpath-driverinfo.yaml csi-hostpath-plugin.yaml csi-hostpath-snapshotclass.yaml csi-hostpath-testing.yaml csi-snapshot-metadata-sidecar.patch; do
  curl -fsSL "${CSI_RAW}/deploy/${CSI_HOSTPATH_DIR}/hostpath/${f}" -o "$TMP_CSI_DIR/hostpath/${f}"
done
(cd "$TMP_CSI_DIR" && ./deploy.sh)

# The driver ships no StorageClass of its own for us to reuse — the upstream
# example one would just be a third, unused class — so we apply our own two
# instead: sc1 (default, used by Kasten/MinIO/demo-app) and sc2 (reserved
# for training exercises). Its VolumeSnapshotClass (csi-hostpath-snapclass)
# was already applied above as part of hostpath/*.yaml.
log "Adding the sc1/sc2 StorageClasses (same CSI driver, different names)..."
kubectl apply -f - <<'EOF'
# The two StorageClasses for this lab, both backed by the same CSI hostpath
# driver — only their names differ. There's nothing driver-specific about
# that: any CSI driver can back any number of StorageClasses.
#   sc1 — the cluster default. Kasten K10, MinIO, and the sample app's PVC
#         all land here.
#   sc2 — deliberately unused by anything at deploy time. It's there for
#         training exercises: e.g. restoring demo-app's PVC into sc2 instead
#         of sc1, to see Kasten retarget storage on restore.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sc1
provisioner: hostpath.csi.k8s.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sc2
provisioner: hostpath.csi.k8s.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF

log "Making sc1 the default StorageClass..."
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
kubectl patch storageclass sc1 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

log "Waiting for the CSI hostpath driver pod to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=hostpath.csi.k8s.io -n default --timeout=180s

# --- 4. MinIO (Kasten's export/location target) -----------------------------
log "Deploying MinIO..."
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: minio
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-creds
  namespace: minio
type: Opaque
stringData:
  MINIO_ROOT_USER: minioadmin
  MINIO_ROOT_PASSWORD: minioadmin
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
  namespace: minio
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: sc1
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: minio/minio:latest
          args: ["server", "/data", "--console-address", ":9001"]
          envFrom:
            - secretRef:
                name: minio-creds
          ports:
            - containerPort: 9000
              name: api
            - containerPort: 9001
              name: console
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 300m
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: 9000
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /minio/health/live
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 15
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-data
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  selector:
    app: minio
  ports:
    - name: api
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
---
# One-shot job: creates the bucket Kasten will export to. MinIO itself has
# no "create this bucket on first boot" option, so this is the standard way
# — wait for the API, then `mc mb` (idempotent: --ignore-existing is not
# needed, `mc mb` on an already-existing bucket is itself already a no-op
# error we simply ignore with `|| true`).
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-make-bucket
  namespace: minio
spec:
  backoffLimit: 6
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: minio/mc:latest
          envFrom:
            - secretRef:
                name: minio-creds
          command:
            - /bin/sh
            - -c
            - |
              until mc alias set local http://minio.minio.svc.cluster.local:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"; do
                echo "waiting for minio..."; sleep 3
              done
              mc mb local/kasten-exports || true
              echo "bucket ready"
EOF
kubectl -n minio rollout status deployment/minio --timeout=120s
kubectl -n minio wait --for=condition=complete job/minio-make-bucket --timeout=120s

# --- 5. Sample application ---------------------------------------------------
log "Deploying the sample application (namespace demo-app)..."
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: demo-app
  labels:
    # Lets you target this one namespace with a Kasten policy by label
    # instead of picking it by name.
    k10.kasten.io/appNamespace: "true"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-data
  namespace: demo-app
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: sc1
  resources:
    requests:
      storage: 10Mi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-config
  namespace: demo-app
data:
  # Just here so the app has more than one kind of manifest to protect,
  # like a real one would (config alongside data).
  GREETING: "Hello from the Kasten k3d training lab"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: demo-app
spec:
  replicas: 1
  strategy:
    # ReadWriteOnce PVC: never run two pods at once, or the second gets
    # stuck Pending waiting to attach a volume the first pod still holds.
    type: Recreate
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      containers:
        - name: demo-app
          image: busybox:1.36
          envFrom:
            - configMapRef:
                name: demo-config
          # Appends a timestamped line every 5s. This is the whole point of
          # the lab: back up, then keep writing, then restore, and watch
          # the log file jump back to its state at backup time.
          command:
            - /bin/sh
            - -c
            - |
              echo "$GREETING" >> /data/log.txt
              while true; do
                date +"%Y-%m-%d %H:%M:%S - still running" >> /data/log.txt
                sleep 5
              done
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: 20m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: demo-data
EOF
kubectl -n demo-app rollout status deployment/demo-app --timeout=120s

# --- 6. Kasten K10 ------------------------------------------------------------
log "Installing Kasten K10 (this can take a few minutes on first run)..."
helm repo add kasten https://charts.kasten.io/ --force-update >/dev/null
helm repo update kasten >/dev/null

log "Generating the dashboard login (Basic Auth, user: ${K10_AUTH_USER})..."
K10_HTPASSWD="${K10_AUTH_USER}:$(openssl passwd -apr1 "${K10_AUTH_PASS}")"

helm upgrade --install k10 kasten/k10 --namespace kasten-io --create-namespace --wait --timeout 10m \
  --set auth.basicAuth.enabled=true \
  --set-string auth.basicAuth.htpasswd="${K10_HTPASSWD}"

log "Accepting the EULA so the dashboard doesn't block on it..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: k10-eula-info
  namespace: kasten-io
data:
  accepted: "true"
  company: "Kasten k3d Training Lab"
  email: "${ADMIN_EMAIL}"
EOF

log "Creating the MinIO location profile..."
kubectl create secret generic k10-minio-secret \
  --namespace kasten-io \
  --type secrets.kanister.io/aws \
  --from-literal=aws_access_key_id=minioadmin \
  --from-literal=aws_secret_access_key=minioadmin \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'EOF'
apiVersion: config.kio.kasten.io/v1alpha1
kind: Profile
metadata:
  name: minio-training
  namespace: kasten-io
spec:
  type: Location
  locationSpec:
    type: ObjectStore
    objectStore:
      objectStoreType: S3
      name: kasten-exports
      region: us-east-1
      endpoint: http://minio.minio.svc.cluster.local:9000
      skipSSLVerify: true
    credential:
      secretType: AwsAccessKey
      secret:
        apiVersion: v1
        kind: Secret
        name: k10-minio-secret
        namespace: kasten-io
EOF

# --- 7. Final readiness check ------------------------------------------------
# Belt-and-braces: the steps above already wait on their own rollouts, but
# this gives one last, explicit confirmation that nothing crash-looped after
# the fact (e.g. a slow image pull settling into a restart) before declaring
# the lab ready. --field-selector excludes Completed Job pods (like MinIO's
# bucket-creation job), which are done, not "ready", and would otherwise
# block this forever.
log "Waiting for all Kasten K10 pods to be up and running..."
kubectl -n kasten-io wait --for=condition=ready pod --all --timeout=300s \
  --field-selector=status.phase!=Succeeded

log "Waiting for every pod in the cluster to be up and running..."
kubectl wait --for=condition=ready pod --all -A --timeout=300s \
  --field-selector=status.phase!=Succeeded

log "Lab ready!"
cat <<EOF

Kasten dashboard
    kubectl --namespace kasten-io port-forward service/gateway 8080:80
    URL:      http://127.0.0.1:8080/k10/#/
    username: ${K10_AUTH_USER}
    password: ${K10_AUTH_PASS}

MinIO console (for a peek at what Kasten exports)
    kubectl -n minio port-forward service/minio 9001:9001
    URL:      http://127.0.0.1:9001/
    username: minioadmin
    password: minioadmin

Sample application (demo-app)
    No web UI — it's a background job appending timestamps to its PVC.
    kubectl -n demo-app get pods
    kubectl -n demo-app exec deploy/demo-app -- cat /data/log.txt

Each port-forward above runs in the foreground — keep its terminal open
(or run it with & to background it) while you use that URL.

Tear everything down:
    ./deploy.sh destroy
EOF
