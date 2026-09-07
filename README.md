# Veeam Kasten — k3d training lab

A complete, disposable Veeam Kasten lab you can stand up on your own laptop in
a few minutes — macOS, Linux, or Windows (via WSL2), no cloud account, no
shared cluster. It's a single, self-contained script: no `git clone`, no
extra files to fetch — download `deploy.sh` and run it. The same file also
tears the lab down (`./deploy.sh destroy`).

---

## What you get

- A local **k3d** cluster (k3s running in Docker) — 1 server + 1 agent node
- The **CSI hostpath driver** ([kubernetes-csi/csi-driver-host-path](https://github.com/kubernetes-csi/csi-driver-host-path)),
  exposed as **two StorageClasses** backed by the same driver: `sc1` (the
  cluster default — Kasten, MinIO, and the sample app's PVC all land here)
  and `sc2` (unused at deploy time, reserved for training exercises like
  restoring a PVC into a different StorageClass). This matters: k3s's
  built-in `local-path` StorageClass **cannot do CSI snapshots at all** —
  Kasten's backups on it would fall back to a slow, less realistic
  file-copy method instead of the real CSI snapshot workflow you'd see on
  any production cluster. This lab gives you an actual snapshot-capable
  CSI driver instead, with its VolumeSnapshotClass annotated
  `k10.kasten.io/is-snapshot-class: "true"` so Kasten reliably picks it up
  for both sc1 and sc2 (same driver, so one VolumeSnapshotClass covers
  both).
- A tiny single-instance **MinIO** (1Gi) as the S3-compatible target Kasten
  exports to
- A **sample application** (`demo-app` namespace): a ConfigMap, a 10Mi PVC,
  and a Deployment that continuously appends a timestamp to a file on that
  PVC every 5 seconds — enough to actually *see* a restore rewind the data
- **Veeam Kasten** itself, EULA pre-accepted, with a location profile already
  pointed at the in-cluster MinIO

Everything lives inside the k3d cluster's Docker containers/volumes.
Deleting the cluster (`./deploy.sh destroy`) leaves nothing behind on your
machine.

---

## Prerequisites

Only Docker is a hard requirement — `deploy.sh` checks for everything else
(`k3d`, `kubectl`, `helm`, `curl`, `openssl`) and tells you the exact
command to install whatever's missing for your OS, rather than trying to
install things for you. **`git` is not needed at all** — every file the
script needs, including the CSI driver's own install files, is fetched
directly over HTTPS.

| Tool | macOS | Linux |
|---|---|---|
| Docker | [Docker Desktop](https://www.docker.com/products/docker-desktop/) | `curl -fsSL https://get.docker.com \| sh` |
| k3d | `brew install k3d` | `curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \| bash` |
| kubectl | `brew install kubectl` | see [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| helm | `brew install helm` | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| curl, openssl | already on macOS | already on virtually every distro |

**Windows**: run this from inside **WSL2** — it identifies itself as Linux
to the script and everything works the same way. Running it directly from
PowerShell/cmd isn't supported. `prereqs.ps1` (in this repo) automates
getting there: run it from an elevated PowerShell and it sets up WSL2 +
Ubuntu and installs Docker Desktop if needed, then tells you the one
command to run inside WSL2 to fetch and launch `deploy.sh` — see
[Windows setup](#windows-setup) below.

**Resources** — measured on a real run (27 pods: k3d system pods, the CSI
driver, MinIO, the sample app, and all of Veeam Kasten's microservices):

| Resource | Measured usage | Recommended to allocate |
|---|---|---|
| RAM | ~1.3 GB total across all pods at idle | At least 4 GB free for Docker Desktop/the Docker daemon (6–8 GB for comfortable headroom during backups/restores) |
| CPU | ~0.3 vCPU at idle, bursts during install/backup | 2 vCPUs minimum |
| Disk | ~9 GB of container images (see breakdown below) + ~1 GB for the MinIO/demo-app PVCs | 10–15 GB free disk |

That ~9 GB covers every image the script pulls, across both of k3d's nodes
(1 server + 1 agent — each maintains its own independent image store, so
most images get downloaded twice, once per node). Roughly, by component:

| Component | Approx. share of the ~9 GB |
|---|---|
| Veeam Kasten microservices (23 images) | ~7.5 GB |
| CSI hostpath driver + sidecars (provisioner, attacher, resizer, snapshotter, health-monitor — 9 images) | ~0.8 GB |
| MinIO + `mc` | ~0.2 GB |
| k3s's own bundled system images (CoreDNS, metrics-server, local-path-provisioner, pause) | ~0.15 GB |
| Sample app (`busybox`) | negligible |

Veeam Kasten's own images are by far the largest pull — the CSI driver,
MinIO, and k3s's own system images together add up to well under 1.5 GB.

On macOS/Windows this comes out of whatever Docker Desktop's VM is
configured with (Settings → Resources) — bump that if it's set below these
numbers. On Linux, Docker uses the host directly, so it's the host's own
free RAM/disk that matters. Any laptop from the last several years that can
run Docker Desktop comfortably can run this.

---

## Quick start

macOS or Linux (or Windows, from inside WSL2 — see [Windows setup](#windows-setup)):

```bash
curl -fsSL https://raw.githubusercontent.com/cpouthier/kasten-k3d-training/main/deploy.sh -o deploy.sh
chmod +x deploy.sh
./deploy.sh
```

Takes 3–6 minutes depending on your internet connection (mostly spent
pulling the Veeam Kasten images). When it's done, both URLs below already
work — `deploy.sh` starts a background `kubectl port-forward` for each one
itself (auto-stopping after 12h, or immediately on `./deploy.sh destroy`),
so there's no `kubectl port-forward` command to run or terminal to keep
open:

```
Kasten dashboard: http://127.0.0.1:8080/k10/#/
  username: admin
  password: kasten123
```

Kasten is installed with a fixed username/password (Basic Auth) instead of
the default Kubernetes-token login, so there's nothing to generate or paste
each time — see [Login](#login) below to change the credentials.

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
namespace (clone), restoring into the **`sc2`** StorageClass instead of the
default `sc1` (Kasten lets you pick the target StorageClass per-PVC during a
restore — a good way to see storage retargeting in action), disaster-recovery
by deleting the whole `demo-app` namespace and restoring from the MinIO
export alone, or exporting/importing across a *second* lab cluster if you
spin one up with a different `CLUSTER_NAME`.

---

## Login

Kasten has no true "no authentication" mode — some login method is always
required (Basic Auth, token auth, OIDC, LDAP, or the default Kubernetes
RBAC-token login). This lab uses HTTP Basic Auth with a fixed, non-expiring
username/password so you can log in the same way every time without
generating a fresh token per session:

```
username: admin
password: kasten123
```

The htpasswd hash Kasten needs is generated by `deploy.sh` itself with
`openssl passwd -apr1`, which ships by default on both macOS (LibreSSL) and
Linux (OpenSSL) — no extra tools to install.

Change the credentials with the `K10_AUTH_USER` / `K10_AUTH_PASS`
environment variables (see [Configuration](#configuration)).

---

## Windows setup

From an elevated PowerShell (right-click → Run as Administrator):

```powershell
curl.exe -fsSL https://raw.githubusercontent.com/cpouthier/kasten-k3d-training/main/prereqs.ps1 -o prereqs.ps1
powershell -ExecutionPolicy Bypass -File prereqs.ps1
```

It checks your Windows build supports `wsl --install`, sets up WSL2 +
Ubuntu if that's not already done (this may require a reboot — the script
tells you when and what to do next), and installs Docker Desktop via
`winget` if it's missing. It finishes by printing the one-time manual step
(enabling Docker Desktop's WSL integration for Ubuntu — there's no stable
way to script that toggle across Docker Desktop versions) and the exact
command to run inside Ubuntu/WSL2 to fetch and launch `deploy.sh`.

`deploy.sh` itself never runs on native Windows — it's a bash script, and
WSL2 gives you the same tested Linux environment as macOS/Linux, just
reached through a Windows machine.

---

## Repository layout

```
kasten-k3d-training/
├── deploy.sh      # the whole lab: run it to deploy, `./deploy.sh destroy` to tear down.
│                  # Fully self-contained — every manifest is inlined, nothing else to fetch.
├── prereqs.ps1    # Windows-only: gets WSL2 + Docker Desktop set up so deploy.sh can run
└── README.md
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
| `K10_AUTH_USER` | `admin` | Dashboard Basic Auth username |
| `K10_AUTH_PASS` | `kasten123` | Dashboard Basic Auth password |

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

**Dashboard login rejects `admin` / `kasten123`**
You likely set `K10_AUTH_USER`/`K10_AUTH_PASS` on a previous run — Kasten
keeps whatever credentials were in place the last time `deploy.sh` ran with
Helm. Re-run `./deploy.sh` with the same environment variables you used
originally, or `./deploy.sh destroy` and start fresh with new ones.

**A dashboard/MinIO URL isn't reachable**
`deploy.sh` starts each port-forward in the background and skips it if that
local port is already taken (printing a message saying so) — check the log
files it points you to (`kasten.log`/`minio.log` under a temp directory
named for your `CLUSTER_NAME`) for what actually happened. Re-running
`./deploy.sh` retries any port-forward that isn't already running.

**Starting over cleanly**
`./deploy.sh destroy` deletes the k3d cluster entirely (containers +
volumes) and stops the background port-forwards. There's no other state to
clean up — `deploy.sh` afterwards starts fresh.
