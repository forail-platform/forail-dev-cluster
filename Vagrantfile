# -*- mode: ruby -*-
# vi: set ft=ruby :
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

# Pre-shared token for all k3s nodes. Dev-only — do not reuse for prod.
K3S_TOKEN = "forail-dev-cluster-shared-token-do-not-reuse"
K3S_VERSION = "v1.30.4+k3s1"
INIT_SERVER_IP = "192.168.56.30"

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

  # /vagrant exposes scripts to every VM and lets m1 publish admin.conf
  # back to the host. Default sync is bidirectional on virtualbox/libvirt.
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
      end

      vm.vm.provider "libvirt" do |lv|
        lv.cpus   = node[:cpus]
        lv.memory = node[:mem]
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
