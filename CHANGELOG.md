# Changelog

All notable changes to the Forail dev-cluster will be documented in
this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to CalVer (`YYYY.MM.PATCH`).

## [Unreleased]

### Fixed
- **Boot hang on VirtualBox 7.2 + recent host kernels**: the guests are started
  with the KVM paravirtual clock disabled (`no-kvmclock`,
  `--paravirtprovider none`). The bad kvmclock caused `rcu_preempt` stalls that
  hung `systemd-networkd`/`-resolved`, so `sshd` never came up and `vagrant up`
  timed out mid-provision.

### Security
- **Dev-only tradeoffs are now flagged in-tree** rather than left implicit: the
  hardcoded k3s join token, the world-readable synced `admin.conf`, and the
  unpinned k3s installer are deliberate conveniences for this throwaway local
  cluster. They are documented as *not* to be copied into, or exposed by, any
  shared or internet-reachable environment.

## [2026.06.0] - 2026-06-14

### Changed
- **Renamed `forge` → `forail`** across the entire project (organization `forgeplatform` → `forail-platform`): the cluster tooling, image references (`ghcr.io/forail-platform/forail-*`), CLI, and all documentation/URLs. The GitHub organization and repositories were renamed to match.
- Versioning unified across all platform components to CalVer `2026.06.0`.


## [2026.05.0] - 2026-05-22

### Changed
- **Cluster topology expanded to 7 nodes**: 3 control-plane (`k8s-m1`,
  `k8s-m2`, `k8s-m3`) + 4 worker (`k8s-w1`..`k8s-w4`), all on
  `192.168.56.30-36`. Per-VM resources bumped to 2 vCPU / 4 GB
  (was 2 vCPU / 2 GB) → 14 vCPU, 28 GB total. Reasoning: 3-node etcd
  quorum tolerates a single master failure (was 2-node quorum, which
  loses the cluster on any master loss), and 4 GB per VM avoids OOM
  once `forail-helm` + `forail-operator` + the AI assistant are deployed.
- **Switched distribution from kubeadm to k3s** (v1.30.4+k3s1). k3s
  bundles Traefik (default ingress), local-path-provisioner (default
  StorageClass), klipper-lb (servicelb), CoreDNS, and metrics-server,
  so `post-cluster-setup.sh` collapsed from 4 stages to creating just
  the `forail` namespace + Harbor pull-secret + self-signed TLS cert.
  No separate Helm/Traefik install step needed.
- **HA control plane via embedded etcd**: first server runs
  `k3s server --cluster-init`, the other two join with `--server`.
  TLS SANs cover all 3 server IPs and hostnames so `kubectl` works
  against any master.
- `--flannel-iface=eth1` passed explicitly on every node (was a
  post-init patch on the kubeadm setup) — fixes the long-standing
  cross-node VXLAN problem on VirtualBox without a second pass.
- Provisioning scripts renamed: `master-init.sh` → `server-init.sh`,
  `master-join.sh` → `server-join.sh`, `worker-join.sh` →
  `agent-join.sh`. Old kubeadm-specific code (containerd repo,
  Kubernetes apt repo, image pre-pull, Flannel manifest patch) removed.

### Removed
- nginx-ingress was never wired in here, but the `post-cluster-setup.sh`
  helm-install dance for Traefik is gone — Traefik is now the bundled
  k3s default ingress. The Traefik `IngressClass` is named `traefik`
  (was `traefik` before too, but installed by Helm into the `traefik`
  namespace; it now lives in `kube-system`).

## [2026.04.0] - 2026-04-28

### Changed
- `post-cluster-setup.sh` and `README.md` now reference the
  `forail-helm` chart at `../forail-helm` (was `../forail-deploy/helm`
  before the chart was extracted into its own repo)

## [2026.03.0] - 2026-03-15

### Added
- 4-VM Vagrant + VirtualBox cluster: 2 control-plane (`k8s-m1`,
  `k8s-m2`) + 2 worker (`k8s-w1`, `k8s-w2`), all on host-only
  network `192.168.56.30-33`
- Provisioning scripts: `common.sh` (containerd + kubeadm prereqs),
  `master-init.sh` (kubeadm init + Flannel), `master-join.sh`,
  `worker-join.sh`
- Flannel `--iface=eth1` patch baked into `master-init.sh` so
  pod-to-pod traffic uses the VirtualBox host-only adapter instead
  of the NAT adapter (without this, cross-node Service VIPs are
  unreachable)
- `post-cluster-setup.sh` installs local-path-provisioner (default
  StorageClass), Traefik IngressController on NodePort 30080/30443,
  the `forail` namespace, plus pre-created `harbor-pull` and
  `forail-tls` secrets
- `shared/` directory mounted into every VM for kubeadm join tokens
  and `admin.conf` export
