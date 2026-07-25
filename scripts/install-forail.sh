#!/bin/bash
# Install (or upgrade) Forail into this dev cluster, with the settings the dev
# cluster actually needs. Run it on a control-plane node:
#
#   vagrant ssh k8s-m1 -c "sudo bash /vagrant/scripts/install-forail.sh"
#
# Options via env:
#   ADMIN_PASSWORD   admin password        (default changeme-admin, matches cypress.env.json)
#   IMAGE_TAG        override both Forail image tags (default: whatever values.yaml pins)
#   CHART            chart path            (default /vagrant/shared/forail-helm)
#
# WHY THIS SCRIPT EXISTS -- the privileged flags.
#
# The chart ships task.privileged=false and task.hostCgroup=false. That is the
# right default to publish: a privileged pod with a host cgroup mount is a
# trivial container escape to node-root, so users must opt in knowingly.
#
# But Forail runs project updates and jobs through *podman inside the task
# pod*, and podman cannot mount its overlay storage without those privileges.
# With the published defaults every job fails at 0s with
#
#   [graphdriver] prior storage driver overlay failed:
#     mount /var/lib/containers/storage/overlay: permission denied
#
# and the only symptom a user sees is a project stuck in "Pending" forever --
# nothing in the UI says why. This dev cluster is a throwaway VM lab on a
# host-only network, so it opts in. NEVER copy these two flags to a real
# deployment without dedicated, tainted execution nodes.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
CHART="${CHART:-/vagrant/shared/forail-helm}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-changeme-admin}"
IMAGE_TAG="${IMAGE_TAG:-}"

if [ ! -d "$CHART" ]; then
  echo "[install] chart not found at $CHART"
  echo "[install] sync it from the host first:  rsync -a --delete --exclude .git ../forail-helm/ shared/forail-helm/"
  exit 1
fi

TAG_ARGS=()
if [ -n "$IMAGE_TAG" ]; then
  TAG_ARGS=(--set "images.backend.tag=${IMAGE_TAG}" --set "images.frontend.tag=${IMAGE_TAG}")
  echo "[install] pinning Forail images to ${IMAGE_TAG}"
fi

echo "[install] helm upgrade --install forail"
helm upgrade --install forail "$CHART" \
  -n forail --create-namespace \
  -f "$CHART/values.yaml" \
  --set "secrets.forailAdminPassword=${ADMIN_PASSWORD}" \
  --set task.privileged=true \
  --set task.hostCgroup=true \
  "${TAG_ARGS[@]}"

echo "[install] waiting for rollouts..."
for d in forail-web forail-task forail-frontend; do
  kubectl -n forail rollout status "deploy/$d" --timeout=600s || true
done

echo "[install] pods:"
kubectl -n forail get pods

cat <<EOF

==================================================
 Forail installed.
==================================================

 URL:    https://forail.lan   (map it to any node IP in /etc/hosts)
 Admin:  admin / ${ADMIN_PASSWORD}

 Job execution is enabled (task.privileged=true, task.hostCgroup=true).
 Dev-only -- see the comment at the top of this script.

EOF
