# -*- mode: ruby -*-
# vi: set ft=ruby :
#
require "fileutils"
#
# Forail Platform — k8s test environment (multi-VM, HA control plane)
#
# Layout:
#   k8s-m1  192.168.56.30  server (cluster-init, embedded etcd)
#   k8s-m2  192.168.56.31  server (joins etcd quorum)
#   k8s-m3  192.168.56.32  server (joins etcd quorum)
#   k8s-w1  192.168.56.33  agent (worker)
#   k8s-w2  192.168.56.34  agent (worker)
#   k8s-w3  192.168.56.35  agent (worker)
#   k8s-w4  192.168.56.36  agent (worker)
#
# Total: 14 vCPU, 28 GB RAM (2 vCPU / 4 GB per VM)
# Kubernetes: k3s v1.30.4+k3s1 with embedded etcd, Traefik ingress (default),
# local-path-provisioner (default StorageClass), Flannel CNI bound to eth1.
#
# Usage:
#   vagrant up                          # bring up whole cluster
#   vagrant ssh k8s-m1
#   kubectl get nodes -o wide
#
# Tear down:
#   vagrant destroy -f
#
# VirtualBox is the only supported provider. libvirt/KVM is deliberately not
# used: one hypervisor owns AMD-V per boot, so a live KVM guest kills every VM
# here with "Guru Meditation VERR_SVM_IN_USE" (see
# docs/TROUBLESHOOTING-vagrant.md).
ENV["VAGRANT_DEFAULT_PROVIDER"] ||= "virtualbox"

# Pre-shared token for all k3s nodes. Dev-only — do not reuse for prod.
# needtofix L19/L20 (accepted, dev-only): this is a local throwaway Vagrant
# cluster on a private host-only network. The hardcoded join token, the
# world-readable kubeconfig (0644, so the host can read the synced admin.conf),
# and the unpinned curl|sh k3s install are deliberate dev conveniences. NEVER
# expose this cluster or reuse these values outside local development.
K3S_TOKEN = "forail-dev-cluster-shared-token-do-not-reuse"
K3S_VERSION = "v1.30.4+k3s1"
INIT_SERVER_IP = "192.168.56.30"

# Per-VM serial console logs land here so a boot that never reaches sshd still
# leaves a full kernel log on the host. Without this the only evidence is a
# screenshot of the last 40 lines of the VT.
SERIAL_LOG_DIR = File.join(File.dirname(__FILE__), "logs")
FileUtils.mkdir_p(SERIAL_LOG_DIR)

NODES = [
  { name: "k8s-m1", ip: "192.168.56.30", role: "server-init", cpus: 2, mem: 4096 },
  { name: "k8s-m2", ip: "192.168.56.31", role: "server-join", cpus: 2, mem: 4096 },
  { name: "k8s-m3", ip: "192.168.56.32", role: "server-join", cpus: 2, mem: 4096 },
  { name: "k8s-w1", ip: "192.168.56.33", role: "agent",       cpus: 2, mem: 4096 },
  { name: "k8s-w2", ip: "192.168.56.34", role: "agent",       cpus: 2, mem: 4096 },
  { name: "k8s-w3", ip: "192.168.56.35", role: "agent",       cpus: 2, mem: 4096 },
  { name: "k8s-w4", ip: "192.168.56.36", role: "agent",       cpus: 2, mem: 4096 },
]

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"

  # Measured on this host over 32 boots (2026-08-14): a healthy node reaches
  # sshd in 39-44s, and a wedged one never reaches it at all -- the failure mode
  # is a guest that stays up with rcu_preempt stalls and no network, which does
  # not recover on its own. So every second past a healthy boot is spent only on
  # nodes that are already lost, delaying the destroy-and-retry in scripts/up.sh
  # that does fix them.
  #
  # 180s is roughly four times the observed healthy boot, which leaves room for
  # a slow one, and cuts the cost of a wedge from 600s to 180s. About one boot
  # in five wedges, so a seven-node run usually pays this at least once.
  config.vm.boot_timeout = Integer(ENV.fetch("FORAIL_BOOT_TIMEOUT", "180"))

  # /vagrant exposes scripts to every VM and lets m1 publish admin.conf
  # back to the host. Default sync is bidirectional on virtualbox.
  config.vm.synced_folder ".", "/vagrant"

  NODES.each do |node|
    config.vm.define node[:name] do |vm|
      vm.vm.hostname = node[:name]
      vm.vm.network "private_network", ip: node[:ip]

      vm.vm.provider "virtualbox" do |vb|
        vb.name   = node[:name]
        vb.cpus   = node[:cpus]
        vb.memory = node[:mem]
        vb.linked_clone = true
        # VBox 7.2 + recent host kernels feed a bad kvmclock to the guest,
        # causing rcu_preempt stalls (jiffies jumping) that hang
        # systemd-networkd/-resolved so sshd never comes up. Disabling the
        # KVM paravirt clock (legacy => effective "none") makes the guest use
        # the hardware clock and boots reliably.
        vb.customize ["modifyvm", :id, "--paravirtprovider", "legacy"]

        # Headless k3s nodes need a text console and nothing more. vboxvga
        # keeps that while avoiding vmsvga, which makes the Linux guest bind
        # the VMware vmwgfx driver to VirtualBox's partial SVGA device --
        # vmwgfx then logs "running on an unsupported hypervisor / this
        # configuration is likely broken". Tidiness, not a bug fix: the boot
        # hangs this repo used to see came from KVM stealing AMD-V, not from
        # the graphics device (see docs/TROUBLESHOOTING-vagrant.md).
        vb.customize ["modifyvm", :id, "--graphicscontroller", "vboxvga"]
        vb.customize ["modifyvm", :id, "--vram", "16"]

        # Log the guest kernel console to the host, so a boot that never gets
        # to sshd is still diagnosable (see SERIAL_LOG_DIR above).
        vb.customize ["modifyvm", :id, "--uart1", "0x3F8", "4"]
        vb.customize ["modifyvm", :id, "--uartmode1", "file",
                      File.join(SERIAL_LOG_DIR, "#{node[:name]}-serial.log")]
      end

      # 1) Common prep (swap off, hosts file, sysctl)
      vm.vm.provision "common", type: "shell",
        path: "scripts/common.sh",
        args: [node[:ip], node[:name]]

      # 2) Role-specific k3s install
      case node[:role]
      when "server-init"
        vm.vm.provision "k3s", type: "shell",
          path: "scripts/server-init.sh",
          args: [node[:ip], K3S_TOKEN, K3S_VERSION]
      when "server-join"
        vm.vm.provision "k3s", type: "shell",
          path: "scripts/server-join.sh",
          args: [node[:ip], INIT_SERVER_IP, K3S_TOKEN, K3S_VERSION]
      when "agent"
        vm.vm.provision "k3s", type: "shell",
          path: "scripts/agent-join.sh",
          args: [node[:ip], INIT_SERVER_IP, K3S_TOKEN, K3S_VERSION]
      end
    end
  end
end
