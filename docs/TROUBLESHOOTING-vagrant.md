# Troubleshooting the Vagrant cluster

## VMs die together, or a node never finishes booting

### Symptoms

Either of these, and they are the same fault:

- `vagrant up` ends with *"Timed out while waiting for the machine to boot"*.
  The VM still shows `running`, but it never answers on its
  `192.168.56.x` address. Its console shows systemd retrying forever:

  ```
  rcu: INFO: rcu_preempt detected expedited stalls on CPUs/tasks: { 1-...D } 62703 jiffies
  INFO: task (networkd):520 blocked for more than 122 seconds.
  [FAILED] Failed to start systemd-networkd.service - Network Configuration.
  ```

- Every running VM dies at the same instant and `vagrant status` reports
  `gurumeditation`. The per-VM log under
  `~/VirtualBox VMs/<node>/Logs/VBox.log` contains:

  ```
  Console: Machine state changed to 'Stuck'
  !!         VCPU0: Guru Meditation -4054 (VERR_SVM_IN_USE)
  ```

### Cause

**KVM and VirtualBox cannot both hold AMD-V (SVM) on the same host.**

`VERR_SVM_IN_USE` is VirtualBox reporting that another hypervisor already owns
the CPU's virtualisation extensions. On this host that other hypervisor is
`kvm_amd`, pulled in by `libvirtd` — which is socket-activated, so it can start
on its own in the middle of a cluster run and take AMD-V away from VMs that are
already up.

Measured during one such failure: `libvirtd.service` entered active at
`18:49:06 UTC`, and all six running VMs gurued with `VERR_SVM_IN_USE` at
`18:49:51 UTC` — the same second as each other, 45s after the daemon started.

A vCPU that cannot cleanly enter SVM does not always die outright. Sometimes it
just stops making progress, which the guest sees as a CPU that never reports an
RCU quiescent state — so the next expedited grace period never completes, and
anything calling `synchronize_rcu()` blocks forever. `systemd-networkd` does
exactly that when it configures an interface, which is why the guest ends up
alive but with no network and no reachable `sshd`. That is the first symptom
above; same root cause, softer failure.

### Fix

**Do not run a KVM guest and this cluster at the same time.** One hypervisor
owns AMD-V per boot; there is no setting that makes them share it.

This host also runs a `vagrant-libvirt` lab out of
`~/repos/vagrant-proxmox/test-lab`, which is a KVM guest. Bringing it up while
the cluster is running is what kills the cluster — and the reverse is equally
true. Check before starting either:

```bash
vagrant global-status | grep -E 'libvirt.*running'   # KVM guests
pgrep -af 'qemu-system.*-accel kvm'
```

If one is running, stop it first:

```bash
cd ~/repos/vagrant-proxmox/test-lab && vagrant halt
```

`scripts/up.sh` refuses to start when it sees a live KVM guest, so in practice
you get a clear error instead of six VMs dying mid-run.

Do **not** blacklist `kvm`/`kvm_amd` on this host — that would break the
libvirt lab. Blacklisting is only appropriate on a machine where KVM is
genuinely unused, and even then `sudo systemctl disable --now libvirtd.socket`
is usually enough, since it is socket activation that starts `libvirtd` on its
own mid-run.

Verify AMD-V is free before a cluster run — the reference count must be `0`:

```bash
lsmod | grep '^kvm_amd'
```

### Things that are *not* the cause

Ruled out while chasing this, recorded so nobody re-runs the same dead ends:

- **Host load.** 24 cores, load average below 1, 47 GB free during the failures.
- **x2APIC.** The guest never enables it —
  `x2apic: IRQ remapping doesn't support X2APIC mode`.
- **kvmclock.** `--paravirtprovider legacy` is applied and effective
  (`effparavirtprovider=none`); the hangs happened anyway.
- **`WARNING ... at kernel/rcu/tree_plugin.h:734 rcu_sched_clock_irq`.** This
  fires while udev probes modules on *every* boot of this box, including boots
  that go on to be perfectly healthy. It is noise, not the discriminator.
- **The vmsvga graphics controller / `vmwgfx`.** `vmwgfx` does log that
  VirtualBox is an unsupported hypervisor, and the Vagrantfile now uses
  `vboxvga` for that reason, but swapping it did not stop the hangs.
- **The VirtualBox version.** 7.2.0 was suspected and a downgrade prepared; it
  was never needed once AMD-V stopped being contended.

## Diagnosing a boot that never reaches sshd

`vagrant ssh` is useless on a wedged node, so two things are wired up for it:

- **Serial console log** — `logs/<node>-serial.log`, written by the host. Empty
  on a node's very first boot (the guest only starts echoing to `ttyS0` once
  `scripts/common.sh` has edited GRUB), but complete on every boot after.
- **Console screenshot** — works even on a hung VM:

  ```bash
  VBoxManage controlvm <node> screenshotpng /tmp/<node>.png
  ```

For a VM that died rather than hung, the reason is near the end of
`~/VirtualBox VMs/<node>/Logs/VBox.log`:

```bash
grep -E "Guru Meditation|VERR_|Machine state changed" \
  "$HOME/VirtualBox VMs/<node>/Logs/VBox.log"
```

## Bringing the cluster up

Use the wrapper rather than bare `vagrant up`; it goes node by node in
dependency order and recreates any node whose boot fails:

```bash
scripts/up.sh                 # whole cluster
scripts/up.sh k8s-w1 k8s-w2   # just these
RETRIES=5 scripts/up.sh       # default is 3
```
