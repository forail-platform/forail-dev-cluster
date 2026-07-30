#!/bin/bash
# Initialize first k3s server (k8s-m1) with embedded etcd.
# Publishes admin kubeconfig to /vagrant/shared/admin.conf so the host
# (and the other VMs) can reach the cluster.
set -euo pipefail

NODE_IP="${1:?missing NODE_IP}"
K3S_TOKEN="${2:?missing K3S_TOKEN}"
K3S_VERSION="${3:?missing K3S_VERSION}"

SHARED_DIR="/vagrant/shared"

echo "============================================"
echo " [server-init] $NODE_IP (k3s $K3S_VERSION)"
echo "============================================"

mkdir -p "$SHARED_DIR"

# --flannel-iface=eth1 — without this, flannel picks eth0 (NAT, same
# 10.0.2.15 on every VM) and VXLAN tunnels never reach across nodes.
# --tls-san — accept connections on every server IP for HA failover.
# --node-ip — advertise the host-only address, not the NAT one.
# --disable servicelb is intentionally NOT set: we keep klipper-lb so
# LoadBalancer Services work out of the box for dev workloads.
# Traefik + local-path-provisioner are bundled by default — no opt-in.

if [ -f /etc/systemd/system/k3s.service ]; then
    echo "[server-init] k3s already installed, skipping."
else
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="$K3S_VERSION" \
        K3S_TOKEN="$K3S_TOKEN" \
        sh -s - server \
            --cluster-init \
            --node-ip="$NODE_IP" \
            --advertise-address="$NODE_IP" \
            --flannel-iface=eth1 \
            --tls-san=192.168.56.30 \
            --tls-san=192.168.56.31 \
            --tls-san=192.168.56.32 \
            --tls-san=k8s-m1 \
            --tls-san=k8s-m2 \
            --tls-san=k8s-m3 \
            --write-kubeconfig-mode=0644
fi

# Wait for the API server to be reachable before publishing kubeconfig.
for i in $(seq 1 30); do
    if kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# Publish kubeconfig with the right server URL (default is 127.0.0.1)
# so the host can use it directly via $KUBECONFIG=shared/admin.conf.
# needtofix L19 (accepted, dev-only): 0644 is required so the host user can
# read the Vagrant-synced admin.conf. This grants cluster-admin to anyone with
# the file — fine for a local throwaway cluster only.
sed "s|server: https://127.0.0.1:6443|server: https://${NODE_IP}:6443|" \
    /etc/rancher/k3s/k3s.yaml > "$SHARED_DIR/admin.conf"
chmod 644 "$SHARED_DIR/admin.conf"

# Convenience: vagrant + root get kubectl access via ~/.kube/config.
mkdir -p /home/vagrant/.kube /root/.kube
cp -f /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
cp -f /etc/rancher/k3s/k3s.yaml /root/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# Symlink k3s' kubectl to /usr/local/bin in case anything looks for it there.
ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl 2>/dev/null || true

# Helm. scripts/install-forail.sh -- the documented way to put Forail into this
# cluster -- runs on a control-plane node and calls helm directly, but nothing
# here ever installed it. On a cluster that had been up for a while this went
# unnoticed because helm had been installed by hand; a freshly created one fails
# with "sudo: helm: command not found" at the first install step.
if ! command -v helm >/dev/null 2>&1; then
    echo "[server-init] Installing helm..."
    curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
        || echo "[server-init] WARNING: helm install failed -- install-forail.sh will not run"
fi

echo "[server-init] Done."
kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes -o wide || true
