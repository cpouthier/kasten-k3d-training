#!/usr/bin/env bash
# deploy.sh — Spins up a complete, disposable Kasten K10 training lab on a
# local k3d (k3s-in-Docker) cluster. Works the same way on macOS and Linux —
# the only real dependency is Docker; everything else (k3d, kubectl, helm)
# is checked for and, if missing, you get the exact command to install it
# for your OS rather than the script trying to sudo-install things for you.
#
# What this creates, in order:
#   1. A k3d cluster (Traefik disabled — Kasten doesn't need it here)
#   2. The VolumeSnapshot CRDs + snapshot-controller (k3s ships neither)
#   3. The CSI hostpath driver (kubernetes-csi/csi-driver-host-path) — a
#      real, snapshot-capable CSI driver, unlike k3s's built-in
#      "local-path" storage class which cannot do CSI snapshots at all.
#      Set as the cluster's default StorageClass.
#   4. A tiny single-instance MinIO (1Gi) — Kasten's export/location target
#   5. A sample app (namespace + ConfigMap + a 10Mi PVC + a Deployment that
#      continuously appends timestamps to a file on that PVC)
#   6. Kasten K10 itself, with the EULA pre-accepted and a location profile
#      already pointed at the in-cluster MinIO
#
# Re-running this script is safe: every step either no-ops or upgrades in
# place if it already ran before.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-kasten-training}"
EXTERNAL_SNAPSHOTTER_VERSION="v8.6.0"
CSI_HOSTPATH_VERSION="v1.18.0"
ADMIN_EMAIL="${ADMIN_EMAIL:-trainee@example.com}"

log() { printf '\n==> %s\n' "$*"; }

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
    need git    "brew install git"
    ;;
  Linux)
    need docker "curl -fsSL https://get.docker.com | sh"
    need k3d    "curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
    need kubectl "curl -LO https://dl.k8s.io/release/\$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl && sudo install -m 0755 kubectl /usr/local/bin/kubectl"
    need helm   "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    need git    "your distro's package manager, e.g. sudo apt install -y git"
    ;;
  *)
    echo "Unsupported OS: $os — this lab targets macOS and Linux. On Windows, run it from inside WSL2 (which reports itself as Linux)." >&2
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
# doesn't ship these, regardless of which CSI driver you pick.
log "Installing VolumeSnapshot CRDs (external-snapshotter ${EXTERNAL_SNAPSHOTTER_VERSION})..."
kubectl apply -k "github.com/kubernetes-csi/external-snapshotter/client/config/crd?ref=${EXTERNAL_SNAPSHOTTER_VERSION}"

log "Installing the snapshot-controller..."
kubectl apply -k "github.com/kubernetes-csi/external-snapshotter/deploy/kubernetes/snapshot-controller?ref=${EXTERNAL_SNAPSHOTTER_VERSION}"
kubectl -n kube-system rollout status deployment/snapshot-controller --timeout=120s

# --- 3. CSI hostpath driver (snapshot-capable; local-path is not) ----------
log "Installing the CSI hostpath driver (csi-driver-host-path ${CSI_HOSTPATH_VERSION})..."
# deploy.sh in this project is a symlink chain (kubernetes-latest ->
# kubernetes-1.35 -> kubernetes-1.34) that only resolves correctly on a real
# checkout — a raw.githubusercontent.com fetch just returns the symlink
# target as text, so this has to be a real git clone, not a curl.
TMP_CSI_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_CSI_DIR"' EXIT
git clone --quiet --depth 1 --branch "$CSI_HOSTPATH_VERSION" \
  https://github.com/kubernetes-csi/csi-driver-host-path.git "$TMP_CSI_DIR"
(cd "$TMP_CSI_DIR" && ./deploy/kubernetes-latest/deploy.sh)

# The driver ships no StorageClass/VolumeSnapshotClass of its own — these
# are meant to be applied separately (see the project's own examples/).
kubectl apply -f "$TMP_CSI_DIR/examples/csi-storageclass.yaml"
kubectl apply -f "$TMP_CSI_DIR/deploy/kubernetes-latest/hostpath/csi-hostpath-snapshotclass.yaml"

log "Making csi-hostpath-sc the default StorageClass..."
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
kubectl patch storageclass csi-hostpath-sc -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

log "Waiting for the CSI hostpath driver pod to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=hostpath.csi.k8s.io -n default --timeout=180s

# --- 4. MinIO (Kasten's export/location target) -----------------------------
log "Deploying MinIO..."
kubectl apply -f "${SCRIPT_DIR}/manifests/minio.yaml"
kubectl -n minio rollout status deployment/minio --timeout=120s
kubectl -n minio wait --for=condition=complete job/minio-make-bucket --timeout=120s

# --- 5. Sample application ---------------------------------------------------
log "Deploying the sample application (namespace demo-app)..."
kubectl apply -f "${SCRIPT_DIR}/manifests/sample-app.yaml"
kubectl -n demo-app rollout status deployment/demo-app --timeout=120s

# --- 6. Kasten K10 ------------------------------------------------------------
log "Installing Kasten K10 (this can take a few minutes on first run)..."
helm repo add kasten https://charts.kasten.io/ --force-update >/dev/null
helm repo update kasten >/dev/null
helm upgrade --install k10 kasten/k10 --namespace kasten-io --create-namespace --wait --timeout 10m

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

log "Creating a login identity for the dashboard (k10-trainee, bound to the k10-admin ClusterRole)..."
kubectl -n kasten-io create serviceaccount k10-trainee --dry-run=client -o yaml | kubectl apply -f -
kubectl create clusterrolebinding k10-trainee-binding \
  --clusterrole=k10-admin \
  --serviceaccount=kasten-io:k10-trainee \
  --dry-run=client -o yaml | kubectl apply -f -

log "Creating the MinIO location profile..."
kubectl create secret generic k10-minio-secret \
  --namespace kasten-io \
  --type secrets.kanister.io/aws \
  --from-literal=aws_access_key_id=minioadmin \
  --from-literal=aws_secret_access_key=minioadmin \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
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

log "Lab ready!"
cat <<'EOF'

Access the Kasten dashboard:
    kubectl --namespace kasten-io port-forward service/gateway 8080:80
    then open http://127.0.0.1:8080/k10/#/

Log in with a Kubernetes bearer token (Kasten has no basic-auth user in
this lab). Generate one for the pre-created admin binding with:
    kubectl -n kasten-io create token k10-trainee --duration=24h

Sample app:
    kubectl -n demo-app get pods
    kubectl -n demo-app exec deploy/demo-app -- cat /data/log.txt

MinIO console (for a peek at what Kasten exports):
    kubectl -n minio port-forward service/minio 9001:9001
    then open http://127.0.0.1:9001/ (minioadmin / minioadmin)

Tear everything down:
    ./destroy.sh
EOF
