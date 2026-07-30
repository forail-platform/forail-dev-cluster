# forail-dev-cluster

[![CI](https://github.com/forail-platform/forail-dev-cluster/actions/workflows/ci.yml/badge.svg)](https://github.com/forail-platform/forail-dev-cluster/actions/workflows/ci.yml)

A 7-node Kubernetes test cluster (3 control-plane + 4 worker) on Vagrant +
VirtualBox. Used as the development / test environment for the Forail
Platform components (`forail-deploy` k8s manifests, `forail-operator`,
`forail-helm`).

Powered by **k3s** (lightweight upstream-conformant Kubernetes), which bundles
Traefik (default ingress) and local-path-provisioner (default StorageClass)
out of the box — no separate installer step needed.

## Topology

| Node | IP | Role | Resources |
|---|---|---|---|
| `k8s-m1` | 192.168.56.30 | server (cluster-init, etcd) | 2 vCPU / 4 GB |
| `k8s-m2` | 192.168.56.31 | server (etcd quorum) | 2 vCPU / 4 GB |
| `k8s-m3` | 192.168.56.32 | server (etcd quorum) | 2 vCPU / 4 GB |
| `k8s-w1` | 192.168.56.33 | agent (worker) | 2 vCPU / 4 GB |
| `k8s-w2` | 192.168.56.34 | agent (worker) | 2 vCPU / 4 GB |
| `k8s-w3` | 192.168.56.35 | agent (worker) | 2 vCPU / 4 GB |
| `k8s-w4` | 192.168.56.36 | agent (worker) | 2 vCPU / 4 GB |

Total footprint: **14 vCPU, 28 GB RAM**.

* **Distribution:** k3s v1.30.4+k3s1
* **Control plane HA:** embedded etcd (3-node quorum)
* **CNI:** Flannel (VXLAN bound to `eth1` host-only adapter)
* **Ingress:** Traefik (bundled, default IngressClass)
* **Storage:** local-path-provisioner (bundled, default StorageClass)
* **LoadBalancer:** klipper-lb / servicelb (bundled)
* **Runtime:** containerd (bundled inside k3s)
* **Box:** `bento/ubuntu-24.04`

## Prerequisites

* VirtualBox 7.0+ — the only supported provider. Do not run libvirt/KVM on the
  same host: one hypervisor owns AMD-V per boot, so a live KVM guest kills every
  VM here (see [docs/TROUBLESHOOTING-vagrant.md](docs/TROUBLESHOOTING-vagrant.md))
* Vagrant 2.4+
* ~32 GB RAM free on the host
* Ports 22, 6443, 80, 443 free on the 192.168.56.0/24 host-only network

## Quickstart

```bash
vagrant up                  # ~5–10 min on a cached box

# Create forail namespace + secrets (Traefik and local-path are already up)
vagrant ssh k8s-m1 -c "bash /vagrant/scripts/post-cluster-setup.sh"

# Verify
vagrant ssh k8s-m1 -c "kubectl get nodes,pods -A"
```

`shared/admin.conf` is exported on the first `server-init` run with the
correct server URL — point your host `KUBECONFIG` at it for direct cluster
access:

```bash
export KUBECONFIG=$PWD/shared/admin.conf
kubectl get nodes
```

## After cluster is up

This repo only stands up an empty cluster. Forail core and operator
deploy from their own repos:

```bash
# Forail core
helm install forail ../forail-helm -n forail

# forail-operator
TOKEN=$(kubectl -n forail exec deploy/forail-web -- \
    forail-manage create_oauth2_token --user admin | tail -1)
helm install forail-operator ../forail-operator/helm \
    -n forail-operator --create-namespace \
    --set forail.token=$TOKEN
```

## Tear down

```bash
vagrant destroy -f
```

Removes the seven VMs and their disks. Re-run `vagrant up` to recreate
from scratch — provisioning is idempotent.

## Layout

```
forail-dev-cluster/
├── Vagrantfile               # 7-VM multi-machine config
├── scripts/
│   ├── common.sh             # host prep (swap, hosts, sysctl)
│   ├── server-init.sh        # k3s server --cluster-init on k8s-m1
│   ├── server-join.sh        # k3s server --server (k8s-m2, k8s-m3)
│   ├── agent-join.sh         # k3s agent join (k8s-w1..w4)
│   └── post-cluster-setup.sh # forail namespace + harbor-pull + forail-tls
└── shared/                   # synced /vagrant/shared (admin.conf export)
```

## Known issues

* **Flannel must bind to `eth1`** — every VM has eth0 (NAT, 10.0.2.15) and
  eth1 (host-only, 192.168.56.x). Without `--flannel-iface=eth1` the VXLAN
  tunnels collapse onto the duplicate NAT addresses and cross-node Service
  VIPs become unreachable. The provisioning scripts pass this flag
  explicitly on every node — verify with
  `journalctl -u k3s | grep flannel` if pod-to-pod traffic breaks.
* **Rolling restarts of cluster-critical components can leave VirtualBox
  host-only networking in a bad state** due to apiserver↔kubelet TLS
  handshake timeouts. Symptom: workers flap `NotReady`, NodePorts return
  Connection refused. Fix: `vagrant destroy -f && vagrant up`.
  Does not happen on baremetal.
* **etcd quorum requires at least 2 of 3 servers** to stay online — if you
  `vagrant halt k8s-m1 k8s-m2` simultaneously, the API server on m3 will
  go read-only until quorum returns.
