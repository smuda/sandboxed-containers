# Kata Containers on OKD

Test run 2026-10-01. Result: working, with one SELinux fix applied as
a MachineConfig. A pod with `runtimeClassName: kata` runs inside a
QEMU/KVM guest, and podman inside that pod pulls and runs nested
containers.

Progress:

- Sections 1 to 8 done and verified on the lab cluster.
- A security review of `okd/` led to four fixes: the SELinux rule is
  wrapped in an `optional` block, the module ships base64-encoded
  instead of spliced into a shell, and the podman pod gets no
  ServiceAccount token and is admitted through its own `privileged`
  SCC binding. See Security notes.
- The kata-deploy install and the SELinux fix have been run twice.
  While testing the docs, the Cleanup commands (except `helm
  uninstall`) were run by mistake and deleted both namespaces and the
  extra SELinux module. A reinstall reproduced the `append` denial,
  and the fix cleared it again.
- 2026-10-02: the SELinux fix moved from a manual `oc debug` loop to
  a MachineConfig with a node disruption policy (section 3), applied
  without a reboot. The files in `okd/` were renumbered to apply
  order, security first.
- 2026-10-04: sections 1 to 8 run in order on a newly installed
  cluster with no earlier kata install (no kata SELinux modules, no
  `/var/opt/kata`, no kata namespaces or RuntimeClasses). Everything
  worked on the first try: no reboot for the MachineConfig, and the
  kata-deploy pods went straight to `1/1 Running` without the
  `append` denial.
- 2026-10-12: the block-plain + iothread drop-in became the default
  for `kata` (section 5), installed and benchmarked on the reinstalled
  OKD 4.22 cluster (run 2219). The opt-in RuntimeClass
  `kata-block-emptydir` is gone. Run 2219 still had it installed; a
  `helm upgrade` to the current values (revision 2) then removed its
  CRI-O handler and RuntimeClass, and section 6 was re-run on it.
- Not done: no kata pod on worker1 (see Known issues) and `helm
  uninstall` never run.

## Environment

- OKD 4.22.0-okd-scos.9
- 3 control-plane nodes, 2 workers (`worker1`, `worker2`)
- CentOS Stream CoreOS 10.0.20260806-0, kernel 6.12.0-254.el10,
  CRI-O 1.35.5, SELinux enforcing
- Workers are bare metal (`systemd-detect-virt` = `none`) with
  `/dev/kvm`, `/dev/vhost-vsock`, `/dev/vhost-net` and `vmx` CPU
  flags. worker1 has 4 CPUs and 31 GiB, worker2 12 CPUs and 62 GiB.
- At the start the master MachineConfigPool was still rolling out and
  master3 was briefly NotReady while it rebooted.

Manifests are in [`okd/`](okd/).

## 1. Check prerequisites

```sh
oc get clusterversion
oc get nodes -o wide
for n in worker1 worker2; do
  oc debug node/$n.okd4.example.com -q -- chroot /host \
    sh -c 'grep -cE "vmx|svm" /proc/cpuinfo; ls -l /dev/kvm' \
    2>/dev/null
done
```

Expected: a non-zero CPU flag count and `/dev/kvm` on every worker.

## 2. Choosing an install method

Order of preference was: OpenShift sandboxed containers (OSC) from an
open catalog, then a Kata operator, then plain Kata. Red Hat's
`redhat-operators` catalog and registry.redhat.io images are not used,
for licensing reasons, even though a `redhat-operators` CatalogSource
exists on this cluster.

### OpenShift sandboxed containers: not viable

```sh
oc get packagemanifests -n openshift-marketplace | grep -i sandbox
```

`sandboxed-containers-operator` is only offered by `redhat-operators`.
`community-operators` and `operatorhubio-catalog` don't carry it.
Building it from upstream doesn't help either:

- The operator enables kata through the RHCOS extension
  `sandboxed-containers`, i.e. the `kata-containers` RPM. The OKD
  4.22 payload's `stream-coreos-extensions` image has no kata or qemu
  RPMs. openshift/os has the extension commented out in
  `extensions/centos-10.yaml`: "kata-containers is not yet shipped in
  CS10".
- No `kata-containers` RPM exists for CentOS Stream 10 (not in
  AppStream, not in the CS10 virt SIG).
- The newer DaemonSet install mode looks up the release component
  `rhel-coreos-extensions`, which OKD doesn't have, and installs the
  same missing RPM.
- Every public bundle on quay.io/openshift_sandboxed_containers and
  the upstream `config/manager` point their operand images at
  registry.redhat.io.

Making it work would mean building an el10 kata RPM, a custom
extensions image, patching the operator and rebuilding all operand
images: effectively a fork.

### Kata operators: none maintained

OperatorHub.io has `cc-operator` (Confidential Containers runtime,
v0.12.0), which installs kata through the kata-deploy script. The
project is deprecated and replaced by the kata-deploy helm chart, so
it is not used.

### Chosen: upstream kata-deploy helm chart

Kata Containers 4.2.0 (released 2026-09-15), chart
`oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy`, image
`quay.io/kata-containers/kata-deploy:4.2.0`. A DaemonSet copies
statically built kata, qemu and guest kernel to `/opt/kata` (on CoreOS
`/var/opt/kata`), writes the CRI-O drop-in
`/etc/crio/crio.conf.d/99-kata-deploy`, restarts CRI-O and creates
the RuntimeClasses. No RPMs and no reboot.

OKD-specific points:

- The chart knows nothing about SCCs. Its ServiceAccount
  `kata-deploy-sa` needs the `privileged` SCC (hostPath volumes).
- `selinux.enabled: true` (new in 4.2.0) loads an SELinux module so
  the installer can run as `kata_deploy_t` on enforcing nodes.
- kata-deploy doesn't relabel `/var/opt/kata`, so the qemu binary
  stays `usr_t` where policy expects `bin_t`. This turned out not to
  matter: qemu still runs as `container_kvm_t` (section 7).
- The chart's SELinux module lacks an `append` rule, which breaks the
  CRI-O drop-in write. Needs a one-rule fix (section 3).

## 3. Load the SELinux fix for CRI-O

kata-deploy 4.2.0's SELinux module lacks an `append` rule that the
CRI-O drop-in writer needs (see "Without the fix" below).
[`okd/01-kata-deploy-crio-append.cil`](okd/01-kata-deploy-crio-append.cil)
is a one-rule companion module and the source of truth.

- [`okd/01-kata-deploy-crio-append-mc.yaml`](okd/01-kata-deploy-crio-append-mc.yaml)
  is a MachineConfig that writes the module to
  `/etc/kata-deploy-selinux/kata-deploy-crio-append.cil` on every
  worker, plus a oneshot unit `kata-deploy-crio-append.service` that
  loads it with `semodule -X 401 -i` before CRI-O and kubelet start.
  After a load the unit copies the file to
  `/var/lib/kata-deploy-selinux/loaded.cil`, and it skips the load
  while the two match, so a normal boot costs no policy rebuild.
  `semodule` names the module after the file, hence the fixed file
  name.
- [`okd/01-kata-deploy-crio-append-ndp.yaml`](okd/01-kata-deploy-crio-append-ndp.yaml)
  is a node disruption policy: when the MachineConfig adds or changes
  the file or the unit, the MCO restarts the unit instead of
  rebooting the node.

Apply both first; they depend on nothing else. The rule sits in a CIL
`optional` block, so the module loads before the chart's module
exists and the rule switches on once kata-deploy's init container
loads the chart's types (every `semodule` transaction rebuilds the
whole policy). The same block drops the rule instead of failing every
later `semodule` transaction if the types disappear again.

The policy goes in first so the MachineConfig update doesn't reboot.
The merge patch replaces `spec.nodeDisruptionPolicy.files` and
`units` as whole lists; they were empty here. On a cluster that
already has entries, add them to the file first.

```sh
oc patch machineconfiguration cluster --type=merge \
  --patch-file okd/01-kata-deploy-crio-append-ndp.yaml
oc get machineconfiguration cluster -o \
  jsonpath='{.status.nodeDisruptionPolicyStatus.clusterPolicies.units[*].name}{"\n"}'
oc apply -f okd/01-kata-deploy-crio-append-mc.yaml
oc wait mcp/worker --for=condition=Updating=True --timeout=180s
oc wait mcp/worker --for=condition=Updated=True --timeout=1200s
for n in worker1 worker2; do
  oc debug node/$n.okd4.example.com -q -- chroot /host sh -c '
    systemctl is-active kata-deploy-crio-append
    semodule -lfull | grep kata' 2>/dev/null
done
```

Observed: the status lists `kata-deploy-crio-append.service` next to
the cluster's own `iri-registry.service`. On the fresh install the
status read right after the patch still showed only
`iri-registry.service`; the unit appeared a few seconds later. The
worker pool was `Updated` 51 s after the apply (57 s on the fresh
install). Boot IDs were unchanged and no node
was drained; each worker got these events instead:

```
ServiceReload   Config changes do not require reboot. Service daemon-reload was reloaded.
ServiceRestart  Config changes do not require reboot. Service kata-deploy-crio-append.service was restarted.
```

The restart also started the new unit, so nothing else was needed.
Per worker:

```
active
401 kata-deploy                  cil
401 kata-deploy-cri-config-etc_t cil
401 kata-deploy-crio-append      cil
```

The chart was already installed on this run. On the fresh install
only `kata-deploy-crio-append` was listed; the other two appear in
section 5.

After editing the `.cil` file, regenerate the data URL in the
MachineConfig. On an unchanged file this leaves the MachineConfig as
it is, so an empty `git diff` means the two are in sync:

```sh
sed -i.bak "s|base64,.*|base64,$(base64 < okd/01-kata-deploy-crio-append.cil | tr -d '\n')|" \
  okd/01-kata-deploy-crio-append-mc.yaml &&
  rm okd/01-kata-deploy-crio-append-mc.yaml.bak
```

Applying a changed MachineConfig should restart the unit through the
node disruption policy, and the unit reloads the module because the
file no longer matches its copy. Only the first apply has been
tested.

### Ordering and reboot checks

Run on worker1 with the chart installed:

- `semodule -X 401 -r kata-deploy-cri-config-etc_t kata-deploy`
  succeeded and left `kata-deploy-crio-append` loaded on its own.
  After deleting the kata-deploy pod, the new pod's init container
  loaded the chart's modules again, and `kube-kata` wrote the 402
  byte drop-in and ended with "Kata Containers installation completed
  successfully", without restarts and without `kata_deploy` AVCs.
  `sesearch` isn't on the node, so the active rule shows in behaviour
  only. Don't remove the chart's module under a running pod: the old
  pod's process dropped to `unlabeled_t`, ignored SIGTERM and was
  only killed after its 600 s grace period.
- After a reboot the unit ran before CRI-O, took 18 ms (load skipped,
  copy matches), the module was still loaded and the kata-deploy pod
  came back `1/1 Running` with no `kata_deploy` AVCs.

Don't reboot a node with `oc debug ... -- chroot /host systemctl
reboot`: the debug pod ran again after each boot until it was cleaned
up, and worker1 rebooted four times in 14 minutes.

### Without the fix

The `selinux-policy` init container succeeds on both workers and loads
the chart's module at priority 401:

```
install (selinux-policy): policy modules loaded
install (selinux-policy): all 5 domains resolve
```

The main container `kube-kata` then installs the artifacts and fails
when configuring CRI-O, and goes into `CrashLoopBackOff`:

```
install (cri): configuring CRI runtime
kata_deploy::runtime::crio] Add Kata Containers as a supported runtime for CRIO:
Error: Permission denied (os error 13)
```

On the node, `99-kata-deploy` exists but is empty, and the audit log
has the cause:

```
$ ls -laZ /etc/crio/crio.conf.d
-rw-r--r--. root root system_u:object_r:container_config_t:s0 0 99-kata-deploy
$ ausearch -m AVC -ts recent | grep kata_deploy
avc:  denied  { append } for comm="kata-deploy" name="99-kata-deploy"
scontext=system_u:system_r:kata_deploy_t:s0
tcontext=system_u:object_r:container_config_t:s0 tclass=file
```

Loading the module then and deleting the pods
(`oc delete pod -n kata-deploy -l name=kata-deploy`) recovers. That
was tested with the earlier manual `semodule` load, not with the
MachineConfig.

### Why it fails

The chart's module (`policy-revision: 1`, readable with `semodule -E
kata-deploy`) allows `create open getattr setattr read write unlink
rename` for the CRI config writer, but not `append`. The CRI-O
drop-in writer opens the file with `O_WRONLY|O_CREAT|O_APPEND`
(syscall flags `0x88441`). The `/opt/kata` rule does include `append`,
so only the CRI config path is affected.

The writer is `configure_crio()` in
`tools/packaging/kata-deploy/binary/src/runtime/crio.rs`. Line 128
recreates `99-kata-deploy` empty with `fs::File::create` (allowed),
then lines 135-138 reopen it with `OpenOptions::new().create(true)
.append(true)` to write the `[crio]` header, which is the denied open.
That is why the file is left at 0 bytes. The per-shim, custom runtime
and debug writers (lines 76-79, 112-115, 168-171) open the same way.
Line numbers are from main at `645e1f6` (`VERSION` 4.2.0).

It only shows with CRI-O on enforcing nodes, and upstream CI never
covers that combination (checked 2026-10-02):

- The only SELinux job, `run-kata-deploy-selinux-tests` in
  `.github/workflows/run-kata-deploy-tests.yaml`, runs on an Alma
  10.2 + RKE2 cluster, i.e. containerd. The CRI-O tests
  (`run-k8s-tests-crio.yaml`) run on Ubuntu without SELinux.
- `kata-deploy.cil` and `binary/src/runtime/crio.rs` on main are
  unchanged from 4.2.0 here: still no `append`, still
  `.append(true)`.
- No issue or PR covers it. The closest are #13751 (SELinux failure
  on RKE2) and #13777 (the PR adding the policy).


## 4. Require kata in kata-test

The `privileged` SCC binding for the podman pod (section 7) is only
safe under kata, so the guard goes in before the grant.
[`okd/02-require-kata.yaml`](okd/02-require-kata.yaml) is a
ValidatingAdmissionPolicy that rejects any pod create or update in
`kata-test` unless `runtimeClassName` is `kata`. Its binding selects
the namespace by label, so it can be applied before `kata-test`
exists.

The binding takes a few seconds to apply; the first attempts on the
first run were still admitted. Test with a server-side dry run, so no
runc pod is ever created, and loop until it is denied. The dry run
needs the namespace, so create it here; section 7's manifest then
adopts it (`oc apply` warns about the missing last-applied
annotation, which is harmless):

```sh
oc apply -f okd/02-require-kata.yaml
oc create namespace kata-test
until out=$(oc run -n kata-test runc-test --image=quay.io/podman/hello \
    --restart=Never --dry-run=server 2>&1); echo "$out" | grep -q 'denied request'; do
  sleep 2
done; echo "$out"
```

```
Error from server (Forbidden): pods "runc-test" is forbidden: ValidatingAdmissionPolicy 'require-kata-runtimeclass' with binding 'require-kata-runtimeclass-kata-test' denied request: pods in this namespace must use runtimeClassName: kata
```

A pod with SA `podman`, `privileged: true` and no RuntimeClass gets
the same denial. A kata pod is admitted, labelling the running
`podman-in-kata` (an update) works, and pods in other namespaces are
unaffected. On the fresh install the policy was applied before
`kata-test` existed, and the loop was denied on its second try.

## 5. Install kata-deploy

[`okd/03-kata-deploy-namespace.yaml`](okd/03-kata-deploy-namespace.yaml)
creates the namespace and binds the `privileged` SCC to
`kata-deploy-sa`.
[`okd/04-kata-deploy-values.yaml`](okd/04-kata-deploy-values.yaml)
holds the helm values:

- `selinux.enabled: true`
- `snapshotter.setup: []`, since nydus/erofs are containerd-only
- only the `qemu-runtime-rs` shim, as default shim. The Go shim
  `qemu` is being deprecated upstream.
- `runtimeClasses.createDefault: true`, giving a RuntimeClass `kata`
  next to `kata-qemu-runtime-rs`
- `shims.qemu-runtime-rs.dropIn`: a drop-in on the shim itself, so
  the default RuntimeClass `kata` gets it. Disk emptyDirs sit on a
  guest ext4 block device (`emptydir_mode = "block-plain"`) instead
  of virtio-fs, on virtio-blk with direct I/O, native aio and a qemu
  iothread. "Why these kata settings" below explains each line and
  the caveats.
- `nodeSelector` on workers

Make sure both MachineConfigPools are `Updated` first, or the nodes
reboot under the install.

```sh
oc get mcp
oc apply -f okd/03-kata-deploy-namespace.yaml
helm install kata-deploy \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --version 4.2.0 -n kata-deploy -f okd/04-kata-deploy-values.yaml
oc get pods -n kata-deploy -w
```

With section 3 in place the pods go straight to `1/1 Running`;
without it they crash-loop as described there. On the fresh install
both pods were `1/1 Running` 90 s after `helm install`, with no
restarts. Right after that they dropped to `0/1` for about 15 s
(readiness probe 503 while kata-deploy checks that its node labels
stay set) and then stayed Ready, so wait for Ready rather than trust
the first `1/1`. Their log
(`oc logs -n kata-deploy ds/kata-deploy`) contains:

```
install (cri): crio is serving ["kata-qemu-runtime-rs"]
Setting label katacontainers.io/kata-runtime=true on node worker2.okd4.example.com
Kata Containers installation completed successfully
```

CRI-O restarts without making the nodes `NotReady`, and `ausearch -m
AVC -ts recent | grep kata_deploy` on the workers comes back empty.

### Why these kata settings

The drop-in is written to `config.d/50-user-overrides.toml` of the
`qemu-runtime-rs` shim:

```toml
[hypervisor.qemu]
block_device_driver = "virtio-blk-pci"
block_device_cache_direct = true
block_device_aio = "native"
enable_iothreads = true
indep_iothreads = 1

[runtime]
emptydir_mode = "block-plain"
```

The numbers are kata median over runc median (Baseline) on worker2
(i7-10710U, 12 CPUs, 62 GiB, NVMe), pods of 4 CPU / 4Gi, 3
repetitions. Sources, in order:
[stock virtio-fs, run 0635](performance/results/2026-10-10-0635-5.0.0-okd-scos.1-worker2/analysis.md);
[block-plain, run 1823](performance/results/2026-10-10-1823-5.0.0-okd-scos.1-worker2/analysis.md)
([changes](performance/results/2026-10-10-1823-5.0.0-okd-scos.1-worker2/changes.md));
[block-plain with iothread, run 2219](performance/results/2026-10-11-2219-4.22.0-okd-scos.9-worker2/analysis.md)
([changes](performance/results/2026-10-11-2219-4.22.0-okd-scos.9-worker2/changes.md),
effective settings in its
[config/](performance/results/2026-10-11-2219-4.22.0-okd-scos.9-worker2/config/));
[OCP comparison, run 1147](performance/results/2026-10-11-1147-ocp-4.22.17-worker2/analysis.md).
Run 2219 is the current configuration.

- `emptydir_mode = "block-plain"`: runtime-rs creates a sparse
  `disk.img` in the emptyDir, hot-plugs it and the guest mounts it as
  ext4, so disk emptyDirs no longer cross virtio-fs. With the stock
  virtio-fs path, buffered 4k random writes ran at 0.14 of runc and
  the nested podman build on vfs at 4.15x runc. With block-plain they
  are 1.07 and 1.50x (run 2219). Node CPU during fio fell from
  7.7-8.7x runc to 4.0-4.6x.
- `block_device_driver = "virtio-blk-pci"`: the default was
  `virtio-scsi`. It was changed together with block-plain, so its
  effect alone was not measured; the iothread below is set up for
  virtio-blk devices.
- `block_device_cache_direct = true`: guest O_DIRECT reaches the
  NVMe. With virtio-fs, virtiofsd dropped O_DIRECT, so kata "direct"
  reads (2.3x runc) measured the node page cache, not the device.
  After the change the direct rows are device against device.
- `block_device_aio = "native"`: the default `io_uring` makes the
  block device hotplug fail on SCOS, which sets
  `kernel.io_uring_disabled = 2`, and every kata pod with a disk
  emptyDir then fails to start. `native` needs `cache_direct = true`.
- `enable_iothreads = true`, `indep_iothreads = 1`: one dedicated
  qemu iothread for the hot-plugged virtio-blk devices, so their I/O
  is not handled in qemu's main loop. The fixed cost per 4k I/O at
  queue depth 1 fell from 26-32 µs to 7-10 µs: 4k direct writes went
  from 0.25 to 0.51 of runc and 4k reads from 0.62 to 0.87. The price
  is about 12-15% more node CPU under fio (kata also did 1.4x the
  reads and 2.1x the direct writes in the same time) and nothing at
  idle. The iothread is the likely cause, not a proven one: OKD,
  CRI-O and the host kernel changed in the same step, and that the
  disk is attached to the iothread was not checked. An A/B without
  the two lines on this cluster is still open.
- Left at the defaults: the `qemu-runtime-rs` shim (the Go `qemu`
  shim is being deprecated), `static_sandbox_resource_mgmt = true`
  and debug off.

Why the OCP settings were not copied
([run 1147](performance/results/2026-10-11-1147-ocp-4.22.17-worker2/analysis.md)):

- `static_sandbox_resource_mgmt = false` (hotplug sizing) left 1-3 of
  5 vCPUs online in 4 of 9 stress-ng pods, which halved their CPU
  throughput, and an idle pod cost about 500 MB against 265 MB.
  Static sizing has neither problem.
- `disable_guest_empty_dir = false` puts the emptyDir in the sandbox
  overlay. Its fast large writes (3.2 GB/s "direct", more than the
  NVMe does) are the host page cache and probably not durable. The
  option only exists in the Go runtime, which is being deprecated.
- The OCP configuration has `enable_debug = true` in the hypervisor,
  agent and runtime sections.

Current ratios against runc on a block-plain emptyDir (run 2219):

| access pattern | virtio-fs (0635) | block-plain (1823) | plus iothread (2219) |
|-|-|-|-|
| buffered 4k random writes | 0.14 | 1.11 | 1.07 |
| 1 MiB direct writes | 0.35 | 0.89 | 0.95 |
| small random reads, cold | 2.3 (page cache) | 0.62 | 0.86-0.87 |
| 1 MiB reads | 1.26-2.39 (page cache) | 0.73-0.87 | 0.78-0.84 |
| 4k direct writes | 0.57 (page cache) | 0.25 | 0.51 |
| buffered streaming writes | 0.13 | 0.46 | 0.47 |

Footprint and compute (run 2219): an idle pod uses about 314-324 MB
and 32-37 mcores of CPU with a disk emptyDir (runc: under 1 MB and
about 0). Stock virtio-fs was 265 MB and 4 mcores; the 57 MB and 30
mcores extra come with the block device (the CPU is most likely
ext4 lazy inode-table init). CPU and memory bandwidth are about 1.0
of runc. Nested podman on vfs: build 1.50x, `run --rm` 0.93x, pull
1.10x. A tmpfs emptyDir (`medium: Memory`) is not affected.

Caveats of block-plain now apply to every kata pod. They were the
reason it was an opt-in RuntimeClass before; it is the default by
choice, for the performance above.

- ext4 lazy init allocates about 0.08% of the host filesystem per
  emptyDir (roughly 400 MB for the 476 GiB image). kubelet counts
  that against `sizeLimit`, so an idle pod with a small `sizeLimit`
  can be evicted
  ([kata-containers#13310](https://github.com/kata-containers/kata-containers/issues/13310),
  measured in run 1823). Give emptyDirs a generous `sizeLimit`, but
  always set one: the image is as large as the host filesystem, so
  without a limit one pod can fill the worker's `/var`.
- The guest sees the host filesystem's size (476 GiB in the test),
  not `sizeLimit`. kubelet still enforces the limit by eviction, as
  with runc, but it polls: run 1823 saw about 40 s of lag, so a pod
  writing at disk speed can overshoot the limit by tens of GB.
- The files are not visible individually from the host: the emptyDir
  directory holds one sparse `disk.img`. It is not encrypted; host
  root can still read the image.
- Anything outside an emptyDir, the container's own filesystem,
  still goes over virtio-fs at 0.14 of runc for buffered writes.
- There is no per-pod opt-out. A second RuntimeClass would need
  `customRuntimes`.

Deleted files give their space back. The guest mounts the emptyDir
with `discard` (`/dev/vda on /data type ext4 (rw,relatime,discard)`),
so a delete punches holes in `disk.img` right away. Observed with
`du -k` on the host, in a fresh kata pod with a 4Gi `sizeLimit`:

| step | `disk.img` allocated |
|-|-|
| empty | 9.4 MiB |
| after writing 1 GiB with `conv=fsync` | 1033 MiB |
| after `rm` and `sync` | 9.4 MiB |

So usage does not only grow, and workloads that churn temp files are
charged for what they hold, not for what they ever wrote.

## 6. Verify the install

```sh
helm list -n kata-deploy
oc get ds -n kata-deploy
oc get nodes -L katacontainers.io/kata-runtime,kata-deploy.katacontainers.io/default
oc get runtimeclass
oc get runtimeclass kata -o jsonpath='{.overhead}'
for n in worker1 worker2; do
  oc debug node/$n.okd4.example.com -q -- chroot /host \
    grep privileged_without_host_devices \
    /etc/crio/crio.conf.d/99-kata-deploy 2>/dev/null
done
oc debug node/worker2.okd4.example.com -q -- chroot /host cat \
  /var/opt/kata/share/defaults/kata-containers/runtime-rs/runtimes/qemu-runtime-rs/config.d/50-user-overrides.toml
```

Observed (trimmed):

```
kata-deploy  kata-deploy  2  deployed  kata-deploy-4.2.0  4.2.0
kata-deploy   2 2 2 2 2   node-role.kubernetes.io/worker=
worker1.okd4.example.com   Ready  worker  ...  true  true
worker2.okd4.example.com   Ready  worker  ...  true  true
NAME                   HANDLER
kata                   kata-qemu-runtime-rs
kata-qemu-runtime-rs   kata-qemu-runtime-rs
{"podFixed":{"cpu":"250m","memory":"320Mi"}}
        privileged_without_host_devices = true
        privileged_without_host_devices = true
```

The masters are not labelled. On each worker the CRI-O drop-in
`/etc/crio/crio.conf.d/99-kata-deploy` (402 bytes) holds:

```
[crio]
  storage_option = [
        "overlay.skip_mount_home=true",
  ]

[crio.runtime.runtimes.kata-qemu-runtime-rs]
        runtime_path = "/opt/kata/runtime-rs/bin/containerd-shim-kata-v2"
        runtime_type = "vm"
        runtime_root = "/run/vc"
        runtime_config_path = "/opt/kata/share/defaults/kata-containers/runtime-rs/runtimes/qemu-runtime-rs/configuration-qemu-runtime-rs.toml"
        privileged_without_host_devices = true
```

The shim drop-in from section 5 must be in place on each worker. The
`cat` above prints the same seven lines as the TOML in "Why these
kata settings" (observed on both workers after the `helm upgrade`,
byte for byte the same as run 2219's
[50-user-overrides.toml](performance/results/2026-10-11-2219-4.22.0-okd-scos.9-worker2/config/50-user-overrides.toml)).
An empty or missing file means the pods still get virtio-fs
emptyDirs.

Upgrading from the values with `kata-block-emptydir`: the upgrade
removes the RuntimeClass and the CRI-O handler (`99-kata-deploy` is
back to the 402 bytes above), but leaves the directory
`/var/opt/kata/share/defaults/kata-containers/custom-runtimes/kata-block-emptydir/`
on the nodes. Nothing refers to it any more; it is harmless.

kata-deploy also writes an empty `100-debug`. The kata files live in
`/var/opt/kata` (`usr_t`) and `getenforce` stays `Enforcing`; no
relabeling or `disable_selinux` is needed.

## 7. Run podman inside a kata pod

[`okd/05-podman-in-kata.yaml`](okd/05-podman-in-kata.yaml) is based on
[`openshift/03-podman-in-kata.yaml`](openshift/03-podman-in-kata.yaml):
namespace `kata-test`, a ServiceAccount allowed to use the `privileged`
SCC, a podman `storage.conf` and pod `podman-in-kata` with
`runtimeClassName: kata`. The reasons for its shape (virtiofs rootfs,
no `/dev/fuse`, tmpfs graphroot) are in
[openshift.md](openshift.md#why-the-pod-looks-the-way-it-does).

Two additions over the OpenShift version: no ServiceAccount token is
mounted, and the pod carries `openshift.io/required-scc: privileged`.
Without the annotation, a pod created as cluster admin is admitted
under one of the admin's own SCCs (here it was
`insights-runtime-extractor-scc`), so the RoleBinding was never what
let it in.

```sh
oc apply -f okd/05-podman-in-kata.yaml
oc wait -n kata-test pod/podman-in-kata --for=condition=Ready \
  --timeout=300s
oc get pod -n kata-test podman-in-kata \
  -o jsonpath='{.metadata.annotations.openshift\.io/scc}{"\n"}'
oc exec -n kata-test podman-in-kata -- ls /var/run/secrets/kubernetes.io
oc exec -n kata-test podman-in-kata -- podman run --rm \
  quay.io/podman/hello
oc exec -n kata-test podman-in-kata -- podman run --rm \
  quay.io/centos/centos:stream10 cat /etc/os-release
oc exec -n kata-test podman-in-kata -- podman info \
  --format '{{.Store.GraphDriverName}} {{.Host.Security.SELinuxEnabled}}'
oc get pods -n kata-test \
  -o custom-columns=NAME:.metadata.name,RC:.spec.runtimeClassName
```

Observed output (trimmed). The pod was Ready after 13 s including the
image pull (11 s on the fresh install), and everything worked on the
first try:

```
privileged
ls: cannot access '/var/run/secrets/kubernetes.io': No such file or directory
!... Hello Podman World ...!
...
ID="centos"
VERSION_ID="10"
PRETTY_NAME="CentOS Stream 10 (Coughlan)"
overlay false
NAME             RC
podman-in-kata   kata
```

### Verify the pod really is in a VM

| | Guest (in pod) | Host (worker2) |
|-|----------------|----------------|
| `uname -r` | 6.18.35 | 6.12.0-254.el10.x86_64 |
| `nproc` | 1 | 12 |
| `MemTotal` | 2000556 kB (limit 2Gi) | |

Unlike on OpenShift, the guest kernel differs from the host kernel,
so `uname -r` is proof by itself. Guest `/proc/cmdline`:

```
reboot=k panic=1 systemd.unit=kata-containers.target
systemd.mask=systemd-networkd.service
systemd.mask=systemd-networkd.socket root=/dev/pmem0p1
rootflags=dax,data=ordered,errors=remount-ro ro rootfstype=ext4
agent.cdh_api_timeout=50 cgroup_no_v1=all
systemd.unified_cgroup_hierarchy=1 selinux=0 console=hvc0
```

On the node a `qemu-system-x86_64` process is named after the pod
sandbox, and runs confined:

```sh
oc debug node/worker2.okd4.example.com -q -- chroot /host sh -c '
  id=$(crictl pods --name podman-in-kata -q)
  pgrep -af "qemu-system-x86_64 -name sandbox-$id" | cut -c1-110
  ps -eZ | grep -E "qemu|virtiofsd"'
```

```
1134207 /var/opt/kata/bin/qemu-system-x86_64 -name sandbox-aaae66ad0103...
system_u:system_r:container_kvm_t:s0:c427,c564 1134195 ? virtiofsd
system_u:system_r:container_kvm_t:s0:c427,c564 1134197 ? virtiofsd
system_u:system_r:container_kvm_t:s0:c427,c564 1134207 ? qemu-system-x86
```

The VMM is `container_kvm_t` with per-pod MCS categories even though
the binary is `usr_t`. The guest has `selinux=0` (kata guest default),
so host-side confinement is what applies. The only AVCs from qemu are
denied probes of `sgx_vepc` and `sgx_provision`, which are harmless.

## 8. Unprivileged kata pods

A plain `oc run` as cluster admin is admitted under SCC `anyuid`,
because the creating user's SCCs count too. That is not a real test.
The annotation `openshift.io/required-scc` forces the SCC to use:

```sh
oc run kata-restricted -n kata-test \
  --image=quay.io/centos/centos:stream10 --restart=Never \
  --annotations=openshift.io/required-scc=restricted-v2 \
  --overrides='{"spec":{"runtimeClassName":"kata"}}' \
  -- sh -c 'uname -r; nproc; id; sleep 3600'
oc wait -n kata-test pod/kata-restricted --for=condition=Ready \
  --timeout=180s
oc logs -n kata-test kata-restricted
```

```
6.18.35
1
uid=1000960000(1000960000) gid=0(root) groups=0(root),1000960000
```

The pod ran with `restricted-v2` (non-root, all capabilities dropped,
no privilege escalation) on an enforcing node, so ordinary kata pods
need no special SCC.

## SCC summary

- `kata-deploy-sa` needs `privileged` (hostPath volumes, privileged
  init container). The post-delete cleanup ServiceAccount
  `kata-deploy-sa-cleanup` runs kubectl unprivileged and is not bound.
- `podman-in-kata` needs `privileged`, which applies inside the guest
  VM only.
- Ordinary kata pods need nothing beyond `restricted-v2`.

## Security notes

- The `podman` RoleBinding is not limited to kata. Any pod using SA
  `podman` in `kata-test` may be privileged. The policy from section
  4 makes every pod in `kata-test` use `runtimeClassName: kata`. That
  keeps privileged in a guest VM only while that RuntimeClass points
  to a kata handler: anyone who can
  create or delete RuntimeClasses, or run `helm upgrade` on
  kata-deploy, can undo it,
  and so can anyone with write access to `validatingadmissionpolicies`
  or `validatingadmissionpolicybindings`. The policy checks nothing
  else: hostPath and other host access the `privileged` SCC allows
  are still admitted. A hostPath in a kata pod is shared into the
  guest over virtio-fs and is writable by privileged root in the
  guest; host SELinux (`container_kvm_t` with per-pod MCS
  categories) is then the remaining check.
- The upstream chart's ClusterRole gives `kata-deploy-sa` `patch` on
  `nodes` and `get` on `nodes/proxy`, cluster-wide. `kube-kata` also
  mounts the host `/` and `/run/systemd/private`, which is
  root-equivalent on the node. Both are upstream design.
- Images and chart are pinned by tag only:
  `kata-deploy:4.2.0` with `imagePullPolicy: Always`, the cleanup
  job's `kubectl:latest` and `podman/stable:latest`. Fine for a dated
  lab log; pin digests for anything real.
- `privileged_without_host_devices = true` in the CRI-O drop-in keeps
  the host's `/dev` out of privileged kata pods. Section 6 checks it.
- The guest kernel runs with `selinux=0`, so the boundary is the
  host-side confinement of the VMM: `container_kvm_t` with per-pod MCS
  categories (section 7).

## Known issues

- The SELinux fix in section 3 depends on the chart's attribute names
  `kata_deploy_cri_config_writer` and `kata_deploy_cri_config_target`.
  If an upgrade renames them, the `optional` block turns the rule off
  silently; if `append` is still missing then, kata-deploy
  crash-loops again with the AVC from section 3. Not yet reported
  upstream; the fix there is adding `append` to the CRI
  config file rule in `kata-deploy.cil`. A draft issue is below.
- worker1 has 4 CPUs (3500m allocatable, 96% requested), and the
  `kata` RuntimeClass adds 250m CPU and 320Mi memory overhead per pod,
  so a kata pod pinned to worker1 stays `Pending` with `Insufficient
  cpu`. All test pods ran on worker2. worker1's install is verified
  (labels, drop-in, CRI-O serving the handler), but no VM was started
  there. This is a lab capacity issue, not a kata one.
- Whether `kata-deploy-sa-cleanup` works under `restricted-v2` is
  unconfirmed until an uninstall is run.

## Suggested upstream issue

Draft for github.com/kata-containers/kata-containers, not yet filed.

````markdown
kata-deploy: SELinux policy lacks `append` for CRI-O drop-in

### Environment

kata-deploy 4.2.0 (helm chart, `selinux.enabled: true`), OKD 4.22 on
CentOS Stream CoreOS 10, CRI-O 1.35.5, SELinux enforcing,
container-selinux 2.250.

### What happens

The `selinux-policy` init container loads the policy fine, then
`kube-kata` crash-loops:

```
install (cri): configuring CRI runtime
kata_deploy::runtime::crio] Add Kata Containers as a supported runtime for CRIO:
Error: Permission denied (os error 13)
```

`/etc/crio/crio.conf.d/99-kata-deploy` is created but left empty.
Audit log:

```
avc: denied { append } for comm="kata-deploy" name="99-kata-deploy"
scontext=system_u:system_r:kata_deploy_t:s0
tcontext=system_u:object_r:container_config_t:s0 tclass=file
```

### Cause

`binary/src/runtime/crio.rs` opens the drop-in with
`OpenOptions::new().create(true).append(true)`, but the CRI config
rule in `selinux/kata-deploy.cil` grants
`(file (create open getattr setattr read write unlink rename))`,
without `append`. The SELinux CI job runs RKE2 (containerd), so the
CRI-O path (`container_config_t`) is never exercised. Same on main.

### Workaround / proposed fix

Adding `append` to that rule fixes it. As a companion module loaded at
the same priority:

```
(optional kata_deploy_crio_append
  (allow kata_deploy_cri_config_writer kata_deploy_cri_config_target
    (file (append))))
```

With it, the install completes, CRI-O serves the `kata-qemu-runtime-rs`
handler, and kata pods run with SELinux enforcing (VMM as
`container_kvm_t`).
````

## Cleanup

Remove the grant before the guard: the podman manifest (with
namespace `kata-test`) first, the policy last.

```sh
oc delete -f okd/05-podman-in-kata.yaml
helm uninstall kata-deploy -n kata-deploy
oc delete -f okd/03-kata-deploy-namespace.yaml
oc delete -f okd/01-kata-deploy-crio-append-mc.yaml
oc wait mcp/worker --for=condition=Updated=True --timeout=1200s
for n in worker1 worker2; do
  oc debug node/$n.okd4.example.com -q -- chroot /host sh -c '
    semodule -X 401 -r kata-deploy-crio-append
    rm -rf /var/lib/kata-deploy-selinux'
done
oc patch machineconfiguration cluster --type=json \
  -p '[{"op":"remove","path":"/spec/nodeDisruptionPolicy"}]'
oc delete -f okd/02-require-kata.yaml
```

Deleting the MachineConfig removes the file and the unit but not the
loaded module, hence the `semodule -r`. The copy in
`/var/lib/kata-deploy-selinux` goes too, or a later reapply would
skip the load. The JSON patch drops the whole node disruption policy,
which held only these entries here. Whether deleting the
MachineConfig reboots the workers despite the policy has not been
tested.

The chart's own modules (`kata-deploy`, `kata-deploy-cri-config-etc_t`)
stay loaded after uninstall; remove them with `semodule -X 401 -r` if
needed. Whether the chart's uninstall also removes `/var/opt/kata`
and the CRI-O drop-in has not been checked.

Only part of this has been run, in an older form: removing the extra
module and deleting the namespaces (by mistake, see the top of this
log). Both worked. `helm uninstall` and its post-delete cleanup Job,
deleting the MachineConfig and removing the policy have not been run.
