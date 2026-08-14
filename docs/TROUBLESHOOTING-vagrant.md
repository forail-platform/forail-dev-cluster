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

**VirtualBox is the only supported provider, and libvirt/KVM is kept off the
host.** One hypervisor owns AMD-V per boot; there is no setting that makes them
share it, so the fix is to remove the competition rather than to schedule
around it:

```bash
sudo systemctl disable --now libvirtd.service libvirtd{,-ro,-admin}.socket
sudo systemctl mask    libvirtd.service libvirtd{,-ro,-admin}.socket
vagrant plugin uninstall vagrant-libvirt    # if it was ever installed
```

A live guest is not the only trigger: `libvirtd` merely being *active* was
enough to kill a running cluster, and it starts itself, being socket-activated.
Masking the sockets is what actually stops that; disabling the service alone
does not.

Do **not** blacklist `kvm`/`kvm_amd`. Masking `libvirtd` is sufficient and
reversible, and blacklisting breaks any other KVM tooling on the machine.

`scripts/up.sh` refuses to start if it finds `libvirtd` active or a live KVM
guest, so you get a clear error instead of six VMs dying mid-run. It does not
call `vagrant global-status` — that call is one of the things that used to wake
`libvirtd` up.

Verify AMD-V is free before a cluster run — the reference count must be `0`,
and nothing should be holding it:

```bash
lsmod | grep '^kvm_amd'
systemctl is-active libvirtd            # expect: inactive (or: masked)
pgrep -af 'qemu-system.*-accel kvm'     # expect: no output
```

### Things that are *not* the cause

Ruled out while chasing this, recorded so nobody re-runs the same dead ends:

- **Host load.** 24 cores, load average below 1, 47 GB free during the failures.
- **x2APIC.** The guest never enables it —
  `x2apic: IRQ remapping doesn't support X2APIC mode`.
- **kvmclock.** `--paravirtprovider legacy` is applied and effective
  (`effparavirtprovider=none`); the hangs happened anyway. Measured directly on
  2026-08-14, 16 boots per setting with `vagrant up --no-provision`: `legacy`
  wedged 3 of 16, `default` wedged 3 of 16. The setting makes no difference to
  the wedge rate, so do not spend another afternoon on it. (A first round of 6
  per setting read 0/6 against 2/6 and looked conclusive; it was noise.)
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

## Destroying a server node takes the control plane with it

`vagrant destroy k8s-m2` on a *server* node does not remove it from the
embedded etcd cluster. With `k8s-m1` and `k8s-m2` up, etcd has two members and
quorum is two — so destroying one leaves the survivor unable to elect a leader.
`k8s-m1` then sits in an endless pre-vote loop and its API server answers
`ServiceUnavailable`, which looks like m1 having failed rather than m2 having
been removed:

```
failed to get etcd MemberList: context deadline exceeded
prober detected unhealthy status ... dial tcp 192.168.56.31:2380: connect: connection refused
7a3a42e9f89c112c is starting a new election at term 2
```

Recover by destroying the whole cluster and bringing it up again; there is no
state here worth saving. When testing one node's boot repeatedly, use
`vagrant up <node> --no-provision` — the wedge being chased happens long before
the provisioner runs, and skipping it keeps etcd out of the experiment.

## Bringing the cluster up

Use the wrapper rather than bare `vagrant up`; it goes node by node in
dependency order and recreates any node whose boot fails:

```bash
scripts/up.sh                 # whole cluster
scripts/up.sh k8s-w1 k8s-w2   # just these
RETRIES=5 scripts/up.sh       # default is 3
```
