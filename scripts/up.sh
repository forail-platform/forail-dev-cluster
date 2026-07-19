#!/bin/bash
# Bring the cluster up node by node, retrying any node whose boot wedges.
#
# Why this exists: a node can lose its boot for reasons outside the guest --
# most often KVM taking AMD-V away from VirtualBox mid-run, which either kills
# the VM outright (Guru Meditation VERR_SVM_IN_USE) or wedges a vCPU so
# systemd-networkd never finishes and Vagrant times out waiting for SSH.
# See docs/TROUBLESHOOTING-vagrant.md -- fix the host first; this script only
# makes the remaining flakiness survivable.
#
# A wedged or gurued guest never recovers on its own, and a half-provisioned
# node would fail to join, so the retry destroys and recreates rather than
# rebooting.
#
# Usage:
#   scripts/up.sh                 # whole cluster, in dependency order
#   scripts/up.sh k8s-w1 k8s-w2   # only these nodes
#   RETRIES=5 scripts/up.sh       # override the retry budget (default 3)
set -uo pipefail

cd "$(dirname "$0")/.."

RETRIES="${RETRIES:-3}"

# m1 initialises etcd; the other servers join it, and agents join the cluster.
# Order matters, so keep m1 first.
ALL_NODES=(k8s-m1 k8s-m2 k8s-m3 k8s-w1 k8s-w2 k8s-w3 k8s-w4)
if [ "$#" -gt 0 ]; then
  NODES=("$@")
else
  NODES=("${ALL_NODES[@]}")
fi

failed=()

for node in "${NODES[@]}"; do
  echo "============================================"
  echo " [up] $node"
  echo "============================================"

  ok=0
  for attempt in $(seq 1 "$RETRIES"); do
    if [ "$attempt" -gt 1 ]; then
      echo "[up] $node: attempt $attempt/$RETRIES -- destroying the wedged VM first"
      # A guest stuck in the RCU stall never comes back, and a half-provisioned
      # node would fail to join, so start from a clean clone rather than reboot.
      vagrant destroy -f "$node" >/dev/null 2>&1 || true
    fi

    if vagrant up "$node"; then
      ok=1
      break
    fi

    echo "[up] $node: boot/provision failed on attempt $attempt/$RETRIES"
    if [ -f "logs/${node}-serial.log" ]; then
      echo "[up] $node: last serial console lines --"
      tail -20 "logs/${node}-serial.log" || true
    fi
  done

  if [ "$ok" -ne 1 ]; then
    echo "[up] $node: GIVING UP after $RETRIES attempts"
    failed+=("$node")
  fi
done

echo "============================================"
if [ "${#failed[@]}" -gt 0 ]; then
  echo " [up] FAILED nodes: ${failed[*]}"
  echo "============================================"
  exit 1
fi

echo " [up] all nodes up"
echo "============================================"
vagrant ssh k8s-m1 -c "sudo k3s kubectl get nodes -o wide" 2>/dev/null || true
