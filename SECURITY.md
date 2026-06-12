# Security Policy

## Supported Versions

Only the latest release receives security fixes. See [CHANGELOG.md](./CHANGELOG.md) for releases.

## Reporting a Vulnerability

Please report security issues privately to **office@krletron.xyz**.

Do **not** open a public GitHub issue for suspected vulnerabilities.

Include:

- Script or playbook affected
- Steps to reproduce
- Impact assessment (host compromise, privilege escalation, etc.)

## Disclosure Timeline

- **48 hours** — acknowledgement of report
- **7 days** — initial assessment
- **30 days** — fix released for critical/high severity
- **90 days** — public disclosure

## Scope

In scope:

- forail-dev-cluster scripts (`server-init.sh`, `server-join.sh`, `agent-join.sh`, `post-cluster-setup.sh`)
- Vagrant provisioning and default credentials
- k3s configuration that exposes the cluster insecurely by default

Out of scope:

- Vulnerabilities in k3s, kubeadm, Vagrant, or VirtualBox upstream
- Self-inflicted misconfiguration (running this dev cluster on the public internet)

## Important note

This repository is a **development environment**. It is intentionally easy to bring up and assumes a trusted local network. Do not use it as a template for production deployments.
