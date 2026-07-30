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

# One hypervisor owns AMD-V per boot. If KVM holds it, VirtualBox loses the
# virtualisation extensions and every VM dies mid-run with "Guru Meditation
# VERR_SVM_IN_USE" -- so refuse now, with a message, rather than after twenty
# minutes of provisioning.
#
# This is why VirtualBox is the only supported provider here and libvirt is kept
# off the host entirely (daemon masked, vagrant-libvirt not installed). The two
# checks below are tripwires for a host where that has been undone.
#
# libvirtd is checked as a daemon, not only via the module refcount: on
# 2026-07-26 the cluster was killed twice with no guest running at all -- the
# daemon being active was enough, and it starts itself, being socket-activated.
# Do NOT call `vagrant global-status` here; that call is one of the things that
# used to wake libvirtd up.
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet libvirtd 2>/dev/null; then
  echo "[up] REFUSING: libvirtd is running. It holds /dev/kvm and VirtualBox"
  echo "[up] cannot share the CPU's virtualisation extensions with it -- the VMs"
  echo "[up] will die with Guru Meditation VERR_SVM_IN_USE, with or without a"
  echo "[up] live guest. libvirt is not used by this project; keep it masked:"
  echo "[up]   sudo systemctl disable --now libvirtd.service libvirtd{,-ro,-admin}.socket"
  echo "[up]   sudo systemctl mask    libvirtd.service libvirtd{,-ro,-admin}.socket"
  echo "[up] See docs/TROUBLESHOOTING-vagrant.md."
  exit 1
fi

kvm_refs="$(awk '$1 == "kvm_amd" || $1 == "kvm_intel" { print $3 }' /proc/modules | head -1)"
if [ -n "${kvm_refs:-}" ] && [ "$kvm_refs" -gt 0 ]; then
  echo "[up] REFUSING: a KVM guest is running and holds the CPU's virtualisation"
  echo "[up] extensions. VirtualBox cannot share them -- see"
  echo "[up] docs/TROUBLESHOOTING-vagrant.md. Live KVM guests:"
  # A qemu command line runs to thousands of characters; print the guest name.
  pgrep -af 'qemu-system.*-accel kvm' \
    | sed -E 's/^([0-9]+).*-name guest=([^,[:space:]]+).*/[up]   pid \1  \2/' || true
  echo "[up] Stop them and re-run."
  exit 1
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
