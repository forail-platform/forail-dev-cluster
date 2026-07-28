# Contributing to forail-dev-cluster

Thanks for your interest in contributing!

The full contributing guide — git workflow, commit conventions, coding standards, PR process — lives in the [forail-deploy repository](https://github.com/forail-platform/forail-devops/blob/main/docs/10-contributing-guide.md). Please read it before submitting a pull request.

## What lives here

Vagrant-based local Kubernetes (k3s) cluster used for testing the operator, helm chart, and full deployment end-to-end. Topology: 3 server (`k8s-m1..m3`) + 4 agent (`k8s-w1..w4`) nodes, embedded etcd quorum, Flannel CNI bound to `eth1`.

## Quick start

```bash
git clone https://github.com/forail-platform/forail-dev-cluster.git
cd forail-dev-cluster
vagrant up
vagrant ssh k8s-m1 -c "sudo kubectl get nodes"
```

See [README.md](./README.md) for full details (resource requirements: ~28 GB RAM).

## Guidelines

- **Reproducibility** — provisioning must work from a clean `vagrant destroy -f && vagrant up` on the supported host (Manjaro/Arch + VirtualBox; libvirt/KVM is not supported and must not be running).
- **Idempotency** — provision scripts must be re-runnable without breaking state.
- **No secrets in repo** — default credentials only; document any required out-of-band secrets in README.
- **Shellcheck-clean** — bash scripts must pass `shellcheck`.

## Reporting bugs

Open an issue with reproduction steps, your host OS, Vagrant version, and VirtualBox version.

For security vulnerabilities, see [SECURITY.md](./SECURITY.md) — please do **not** open a public issue.
