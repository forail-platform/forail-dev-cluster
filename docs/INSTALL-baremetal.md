# Installing on real servers (bare metal / cloud VMs)

The provisioning scripts in `scripts/` are reusable on real servers, not just
the Vagrant lab. This guide shows how to stand up a cluster on physical or
cloud machines — e.g. **1 master + 2 worker nodes** — using the same
`common.sh`, `server-init.sh` and `agent-join.sh`.

> The defaults in the `Vagrantfile` and these scripts are tuned for a
> **throwaway local lab** (hardcoded join token, host-only `eth1`,
> world-readable kubeconfig). Before running on anything real you MUST change
> the four things in [Step 0](#step-0--adapt-the-four-lab-only-assumptions).

## Topology (example)

Substitute your own IPs, hostnames and network interface throughout.

| Role | Hostname | IP | k3s role | Scripts run |
|---|---|---|---|---|
| master | `k8s-m1` | `10.0.0.10` | server | `common.sh` → `server-init.sh` |
| node 1 | `k8s-w1` | `10.0.0.11` | agent | `common.sh` → `agent-join.sh` |
| node 2 | `k8s-w2` | `10.0.0.12` | agent | `common.sh` → `agent-join.sh` |

For **1 master + N workers** you only use `common.sh`, `server-init.sh` and
`agent-join.sh`. `server-join.sh` is only for *additional control-plane*
servers (HA etcd) — see [HA control plane](#adding-more-control-plane-nodes-ha).

## Prerequisites

* Ubuntu 24.04 or 26.04 LTS on every node (other systemd distros work; the
  `apt-get` line in `common.sh` is Debian/Ubuntu-specific).
* `root`/`sudo` on every node.
* Every node can reach the master's IP, and the master can reach each node.
* Outbound HTTPS so `https://get.k3s.io` and the k3s binary can be fetched
  (or pre-stage the k3s binary for an air-gapped install).
* Firewall open **between nodes**:

  | Port | Proto | Purpose | Where |
  |---|---|---|---|
  | 6443 | tcp | Kubernetes API | nodes → master(s) |
  | 8472 | udp | Flannel VXLAN | all ↔ all |
  | 10250 | tcp | kubelet (metrics, exec/logs) | all ↔ all |
  | 2379–2380 | tcp | embedded etcd | server ↔ server (HA only) |

## Step 0 — Adapt the four lab-only assumptions

These are the only edits that separate "lab" from "real server". Make them
once in your working copy of `scripts/` before you run anything.

**1. `--flannel-iface=eth1` → your real NIC.**
In the lab, `eth1` is VirtualBox's host-only adapter. On a real server you
have one primary interface (`ens3`, `eth0`, `enp1s0`, …). Find it with
`ip -4 addr`, then in **`server-init.sh`** *and* **`agent-join.sh`** either
change the flag to your interface, or delete the `--flannel-iface=...` line so
k3s auto-detects the default-route interface.

**2. The `/etc/hosts` block in `common.sh`.**
It hardcodes the lab's `192.168.56.30 k8s-m1 …` map. Replace those lines with
your real hosts so every node resolves every other:

```
10.0.0.10 k8s-m1
10.0.0.11 k8s-w1
10.0.0.12 k8s-w2
```

**3. The join token.**
`K3S_TOKEN` in the `Vagrantfile` is a published throwaway. Generate a real
secret and use the *same* value on the master and every node:

```bash
openssl rand -hex 32   # use this output as <TOKEN> below
```

**4. `--write-kubeconfig-mode=0644` in `server-init.sh`.**
A world-readable kubeconfig grants cluster-admin to any local user. **Delete
that flag** on real servers; the k3s default (`0600`) is correct.

*(Cosmetic, safe to leave:* the serial-console grub edit, the `vmwgfx`
blacklist and the `/swap.img` removal in `common.sh` are VirtualBox niceties —
on real hardware they simply no-op or print a harmless warning.)*

## Step 1 — Host prep on EVERY node

Copy `scripts/` to each machine, then run `common.sh` with
`NODE_IP NODE_HOSTNAME`:

```bash
# master
sudo bash common.sh 10.0.0.10 k8s-m1
# node 1
sudo bash common.sh 10.0.0.11 k8s-w1
# node 2
sudo bash common.sh 10.0.0.12 k8s-w2
```

This disables swap, loads `overlay` + `br_netfilter`, sets the Kubernetes
sysctls, and installs prerequisites (`curl`, `open-iscsi`, `nfs-common`,
`conntrack`, `ipset`).

## Step 2 — Master: install the k3s server

`server-init.sh` takes `NODE_IP K3S_TOKEN K3S_VERSION`:

```bash
sudo bash server-init.sh 10.0.0.10 "<TOKEN>" "v1.30.4+k3s1"
```

It runs `k3s server --cluster-init` (embedded etcd), waits for the API, writes
`admin.conf`, and installs Helm. `--cluster-init` is fine on a single server
and lets you add control-plane nodes later. If you are certain you will never
go HA, you may drop `--cluster-init` to use the simpler SQLite datastore.

## Step 3 — Each worker: join as an agent

`agent-join.sh` takes `NODE_IP MASTER_IP K3S_TOKEN K3S_VERSION`:

```bash
# node 1
sudo bash agent-join.sh 10.0.0.11 10.0.0.10 "<TOKEN>" "v1.30.4+k3s1"
# node 2
sudo bash agent-join.sh 10.0.0.12 10.0.0.10 "<TOKEN>" "v1.30.4+k3s1"
```

Each agent waits for `https://MASTER:6443/livez`, then joins the cluster.

## Step 4 — Verify (on the master)

```bash
sudo k3s kubectl get nodes -o wide
```

Expect `k8s-m1` (control-plane) plus `k8s-w1`, `k8s-w2` (workers), all `Ready`.

To use `kubectl`/`helm` from your workstation, copy
`/etc/rancher/k3s/k3s.yaml` off the master and replace the `server:` URL's
`127.0.0.1` with the master's real IP.

## Step 5 — Deploy Forail on top

The same two helper scripts work here; adapt the registry secret and chart
path. The Forail images on `ghcr.io/forail-platform/*` are **public**, so the
`harbor-pull` secret defaults are harmless — override `HARBOR_*` only if you
mirror images into a private registry.

```bash
# namespace + self-signed TLS + (unused-by-default) pull secret
sudo bash post-cluster-setup.sh

# Forail core — point CHART at your copy of the forail-helm chart
sudo CHART=/path/to/forail-helm ADMIN_PASSWORD='<strong-password>' \
     bash install-forail.sh
```

> ⚠️ `install-forail.sh` sets `task.privileged=true` and `task.hostCgroup=true`
> so Forail's in-pod podman can mount its overlay storage. This is a container
> escape to node-root. On a real cluster, enable it **only** on dedicated,
> tainted execution nodes — never cluster-wide. See the header of
> `scripts/install-forail.sh`.

Operator:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
TOKEN=$(kubectl -n forail exec deploy/forail-web -- \
    forail-manage create_oauth2_token --user admin | tail -1)
helm install forail-operator /path/to/forail-operator/helm \
  -n forail-operator --create-namespace \
  --set forail.token=$TOKEN \
  --set forail.url=http://forail-web.forail.svc.cluster.local:8013
```

Then map `forail.lan` (or your real hostname) to a node IP in DNS or
`/etc/hosts` and browse to `https://forail.lan`.

## Adding more control-plane nodes (HA)

For a highly-available control plane (3 servers sharing etcd quorum), run
`server-join.sh` on each extra server after the first is up. It takes
`NODE_IP INIT_SERVER_IP K3S_TOKEN K3S_VERSION`:

```bash
# on k8s-m2
sudo bash common.sh      10.0.0.20 k8s-m2
sudo bash server-join.sh 10.0.0.20 10.0.0.10 "<TOKEN>" "v1.30.4+k3s1"
```

etcd needs an odd number of servers and a quorum of at least 2 of 3 online.
Put a TCP load balancer (or a shared VIP) in front of the three `:6443`
endpoints and point agents/kubeconfig at it, so the API survives losing one
server.

## What differs from the Vagrant lab, at a glance

| | Vagrant lab | Real server |
|---|---|---|
| Flannel interface | `eth1` (host-only) | your real NIC, or auto |
| `/etc/hosts` | fixed `192.168.56.x` map | your real IPs |
| Join token | published throwaway | `openssl rand -hex 32` |
| kubeconfig mode | `0644` (world-readable) | `0600` (default) |
| `task.privileged` | cluster-wide (throwaway) | tainted exec nodes only |
