#!/usr/bin/env bash
# destroy.sh — Tears down the whole lab by deleting the k3d cluster. Since
# everything (Kasten, MinIO, the sample app, the CSI driver) lives inside
# that one cluster's containers/volumes, this is the only cleanup step
# needed — there's nothing left behind on the host afterwards.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kasten-training}"

if ! command -v k3d >/dev/null 2>&1; then
  echo "k3d is not installed — nothing to do." >&2
  exit 0
fi

if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
  echo "==> Deleting k3d cluster '${CLUSTER_NAME}'..."
  k3d cluster delete "$CLUSTER_NAME"
  echo "Done."
else
  echo "No cluster named '${CLUSTER_NAME}' found — nothing to do."
fi
