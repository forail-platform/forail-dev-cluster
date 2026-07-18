#!/bin/bash
# Common prep for every k3s node (Ubuntu 24.04).
# k3s ships its own containerd + kubelet bundle, so this only handles
# host-level prerequisites: swap, /etc/hosts, sysctl, prereq tooling.
set -euo pipefail

NODE_IP="${1:?missing NODE_IP}"
NODE_HOSTNAME="${2:?missing NODE_HOSTNAME}"

export DEBIAN_FRONTEND=noninteractive

echo "============================================"
echo " [common] $NODE_HOSTNAME ($NODE_IP)"
echo "============================================"

cat > /etc/hosts <<EOF
127.0.0.1 localhost
$NODE_IP $NODE_HOSTNAME

192.168.56.30 k8s-m1
192.168.56.31 k8s-m2
192.168.56.32 k8s-m3
192.168.56.33 k8s-w1
192.168.56.34 k8s-w2
192.168.56.35 k8s-w3
192.168.56.36 k8s-w4
EOF

hostnamectl set-hostname "$NODE_HOSTNAME"

echo "[1/3] Disabling swap..."
swapoff -a
sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
systemctl mask swap.target 2>/dev/null || true
rm -f /swap.img 2>/dev/null || true

echo "[2/3] Kernel modules + sysctl..."
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo "[3/4] Kernel console + vmwgfx blacklist..."
# vmwgfx bound to VirtualBox's SVGA device logs "running on an unsupported
# hypervisor / this configuration is likely broken". The Vagrantfile already
# picks vboxvga so it never loads; this covers a VM whose graphics controller
# got switched back by hand. Cosmetic -- it is not what used to hang boots.
cat > /etc/modprobe.d/blacklist-vmwgfx.conf <<EOF
blacklist vmwgfx
EOF

# Mirror the kernel console onto ttyS0, which the Vagrantfile captures to
# logs/<node>-serial.log on the host. Without this the serial file stays empty
# and a hung boot leaves no evidence beyond a screenshot.
if ! grep -q "console=ttyS0" /etc/default/grub; then
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/GRUB_CMDLINE_LINUX_DEFAULT="\1 console=tty0 console=ttyS0,115200n8"/' /etc/default/grub
  update-grub >/dev/null 2>&1 || true
fi

echo "[4/4] Installing prereq tooling..."
apt-get update -qq
apt-get install -y -qq curl ca-certificates open-iscsi nfs-common conntrack ipset

echo "[common] Done for $NODE_HOSTNAME"
