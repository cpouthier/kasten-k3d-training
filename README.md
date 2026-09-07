# Kasten K10 — k3d training lab

A complete, disposable Kasten K10 lab you can stand up on your own laptop in
a few minutes — macOS or Linux, no cloud account, no shared cluster. One
script deploys everything; one script tears it all down.

---

## What you get

- A local **k3d** cluster (k3s running in Docker) — 1 server + 1 agent node
- The **CSI hostpath driver** ([kubernetes-csi/csi-driver-host-path](https://github.com/kubernetes-csi/csi-driver-host-path)),
  set as the default StorageClass. This matters: k3s's built-in `local-path`
  StorageClass **cannot do CSI snapshots at all** — Kasten's backups on it
  would fall back to a slow, less realistic file-copy method instead of the
  real CSI snapshot workflow you'd see on any production cluster. This lab
  gives you an actual snapshot-capable CSI driver instead.
- A tiny single-instance **MinIO** (1Gi) as the S3-compatible target Kasten
  exports to
- A **sample application** (`demo-app` namespace): a ConfigMap, a 10Mi PVC,
  and a Deployment that continuously appends a timestamp to a file on that
  PVC every 5 seconds — enough to actually *see* a restore rewind the data
- **Kasten K10** itself, EULA pre-accepted, with a location profile already
  pointed at the in-cluster MinIO

Everything lives inside the k3d cluster's Docker containers/volumes.
Deleting the cluster (`./destroy.sh`) leaves nothing behind on your machine.

---

## Prerequisites

Only Docker is a hard requirement — `deploy.sh` checks for everything else
(`k3d`, `kubectl`, `helm`, `git`) and tells you the exact command to install
whatever's missing for your OS, rather than trying to install things for you.

| Tool | macOS | Linux |
|---|---|---|
| Docker | [Docker Desktop](https://www.docker.com/products/docker-desktop/) | `curl -fsSL https://get.docker.com \| sh` |
| k3d | `brew install k3d` | `curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \| bash` |
| kubectl | `brew install kubectl` | see [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| helm | `brew install helm` | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| git | `brew install git` | your package manager |

**Windows**: run this from inside **WSL2** — it identifies itself as Linux
to the script and everything works the same way. Running it directly from
PowerShell/cmd isn't supported.

**Resources**: the whole lab is intentionally tiny (a few hundred MB of RAM
across all pods). Any laptop that can run Docker Desktop comfortably can run
this.

---

## Quick start

```bash
git clone https://github.com/cpouthier/kasten-k3d-training.git
cd kasten-k3d-training
./deploy.sh
```

Takes 3–6 minutes depending on your internet connection (mostly spent
pulling the Kasten K10 images). The script prints exactly what to run next
when it's done — the short version:

```bash
# Kasten dashboard
kubectl -n kasten-io port-forward service/gateway 8080:80
# then open http://127.0.0.1:8080/k10/#/ and log in with:
kubectl -n kasten-io create token k10-trainee --duration=24h
```

Paste that token into the dashboard's login screen (Kasten has no
username/password in this lab — see [Why no basic auth?](#why-no-basic-auth)
below).

---

## Try it: back up, break it, restore it

1. Open the dashboard, find the **demo-app** application card, click it.
2. **Create a policy**: hourly snapshot (doesn't matter for this exercise,
   you'll trigger it manually), export to **minio-training**, no
   retention limits needed for a quick test.
3. **Run the policy now** (the ⋮ menu on the policy, or "Run once").
4. While it's exporting, watch the app keep writing:
   ```bash
   kubectl -n demo-app exec deploy/demo-app -- tail -f /data/log.txt
   ```
5. Once the export completes, **delete the data** to simulate an incident:
   ```bash
   kubectl -n demo-app exec deploy/demo-app -- sh -c 'echo OOPS > /data/log.txt'
   ```
6. In the dashboard, pick the RestorePoint you just created and **restore**.
7. Check the file again — it's back to what it was at backup time, and the
   app keeps appending from there:
   ```bash
   kubectl -n demo-app exec deploy/demo-app -- cat /data/log.txt
   ```

From here, the natural next steps to explore: restoring into a **new**
namespace (clone), disaster-recovery by deleting the whole `demo-app`
namespace and restoring from the MinIO export alone, or exporting/importing
across a *second* lab cluster if you spin one up with a different
`CLUSTER_NAME`.

---

## Why no basic auth?

Kasten K10 supports HTTP Basic Auth (`--set auth.basicAuth.enabled=true`
plus an htpasswd string), which is what you'll see in a lot of quick demo
scripts. This lab deliberately skips it: generating an htpasswd hash
portably across macOS and Linux means depending on either the `htpasswd`
binary (not installed by default on either OS) or Python's `crypt` module
(removed in Python 3.13). Kasten's built-in Kubernetes-token login needs
neither — `kubectl create token` is enough, on any platform, with tools
you already have installed for this lab anyway.

---

## Repository layout

```
kasten-k3d-training/
├── deploy.sh              # one-shot: cluster + CSI + MinIO + sample app + Kasten
├── destroy.sh             # tears down the k3d cluster (that's the only cleanup needed)
└── manifests/
    ├── minio.yaml          # namespace, Secret, 1Gi PVC, Deployment, Service, bucket-creation Job
    └── sample-app.yaml     # namespace, ConfigMap, 10Mi PVC, Deployment
```

`deploy.sh` is safe to re-run — every step either no-ops or upgrades in
place if it already ran (the k3d cluster check, the CSI driver's own
idempotent manifests, `helm upgrade --install`, `kubectl apply`).

---

## Configuration

Environment variables, all optional:

| Variable | Default | Purpose |
|---|---|---|
| `CLUSTER_NAME` | `kasten-training` | k3d cluster name — set this to run a second, independent lab alongside the first |
| `ADMIN_EMAIL` | `trainee@example.com` | Used only for the Kasten EULA acceptance ConfigMap |

Example: two independent labs side by side (e.g. for practicing
cross-cluster DR/migration) —

```bash
CLUSTER_NAME=lab-a ./deploy.sh
CLUSTER_NAME=lab-b ./deploy.sh
```

---

## Troubleshooting

**`docker info` fails / "Docker is installed but not reachable"**
Docker Desktop (or the daemon, on Linux) isn't running. Start it and re-run.

**The CSI hostpath driver pod never becomes ready**
Check `kubectl -n default get pods -l app.kubernetes.io/instance=hostpath.csi.k8s.io`
and `kubectl -n default logs <pod> -c hostpath` — this is almost always a
transient image pull issue on a slow connection; re-running `deploy.sh`
picks up where it left off.

**Kasten install times out**
`helm upgrade --install ... --wait --timeout 10m` gives it a generous
window, but a first-time image pull on a slow link can still exceed it.
Just re-run `./deploy.sh` — `helm upgrade --install` resumes cleanly.

**`kubectl create token k10-trainee` fails with "not found"**
`deploy.sh` creates this ServiceAccount itself (bound to Kasten's own
`k10-admin` ClusterRole) right after the Helm install — if it's missing,
either `deploy.sh` didn't complete, or something deleted it. Re-run
`./deploy.sh`; it recreates it idempotently.

**Starting over cleanly**
`./destroy.sh` deletes the k3d cluster entirely (containers + volumes).
There's no other state to clean up — `deploy.sh` afterwards starts fresh.
