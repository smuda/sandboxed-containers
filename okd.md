# Kata Containers on OKD

Test run 2026-10-01. Result: working, with one manual SELinux fix. A
pod with `runtimeClassName: kata` runs inside a QEMU/KVM guest, and
podman inside that pod pulls and runs nested containers.

Progress:

- Sections 1 to 7 done and verified on the lab cluster.
- A security review of `okd/` led to four fixes: the SELinux rule is
  wrapped in an `optional` block, the module is copied to the nodes
  base64-encoded instead of spliced into a shell, and the podman pod
  gets no ServiceAccount token and is admitted through its own
  `privileged` SCC binding. See Security notes.
- Sections 3 and 4 have been run twice. While testing the docs, the
  Cleanup commands (except `helm uninstall`) were run by mistake and
  deleted both namespaces and the extra SELinux module. A reinstall
  from sections 3 and 4 reproduced the `append` denial, and the
  section 4 fix cleared it again.
- Not done: no kata pod on worker1 (see Known issues), `helm
  uninstall` never run, and the section 4 loop only run in zsh.

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
the RuntimeClasses. No RPMs, no reboot, no MachineConfig.

OKD-specific points:

- The chart knows nothing about SCCs. Its ServiceAccount
  `kata-deploy-sa` needs the `privileged` SCC (hostPath volumes).
- `selinux.enabled: true` (new in 4.2.0) loads an SELinux module so
  the installer can run as `kata_deploy_t` on enforcing nodes.
- kata-deploy doesn't relabel `/var/opt/kata`, so the qemu binary
  stays `usr_t` where policy expects `bin_t`. This turned out not to
  matter: qemu still runs as `container_kvm_t` (section 6).
- The chart's SELinux module lacks an `append` rule, which breaks the
  CRI-O drop-in write. Needs a one-rule fix (section 4).

## 3. Install kata-deploy

[`okd/01-kata-deploy-namespace.yaml`](okd/01-kata-deploy-namespace.yaml)
creates the namespace and binds the `privileged` SCC to
`kata-deploy-sa`.
[`okd/02-kata-deploy-values.yaml`](okd/02-kata-deploy-values.yaml)
holds the helm values:

- `selinux.enabled: true`
- `snapshotter.setup: []`, since nydus/erofs are containerd-only
- only the `qemu-runtime-rs` shim, as default shim. The Go shim
  `qemu` is being deprecated upstream.
- `runtimeClasses.createDefault: true`, giving a RuntimeClass `kata`
  next to `kata-qemu-runtime-rs`
- `nodeSelector` on workers

Make sure both MachineConfigPools are `Updated` first, or the nodes
reboot under the install.

```sh
oc get mcp
oc apply -f okd/01-kata-deploy-namespace.yaml
helm install kata-deploy \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --version 4.2.0 -n kata-deploy -f okd/02-kata-deploy-values.yaml
oc get pods -n kata-deploy -w
```

Without the fix in section 4 the pods crash-loop, so `--wait` is left
out. Continue with section 4 once the pods show `CrashLoopBackOff`;
by then the init container has loaded the chart's SELinux module.

## 4. Fix the SELinux policy for CRI-O

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

### Why it fails

The chart's module (`policy-revision: 1`, readable with `semodule -E
kata-deploy`) allows `create open getattr setattr read write unlink
rename` for the CRI config writer, but not `append`. The CRI-O
drop-in writer opens the file with `O_WRONLY|O_CREAT|O_APPEND`
(syscall flags `0x88441`). The `/opt/kata` rule does include `append`,
so only the CRI config path is affected.

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

### Fix

[`okd/04-kata-deploy-crio-append.cil`](okd/04-kata-deploy-crio-append.cil)
is a one-rule companion module. It uses types from the chart's module,
so it can only be loaded after the init container has run once. Load
it at the same priority on every worker, then restart the DaemonSet
pods:

```sh
b=$(base64 < okd/04-kata-deploy-crio-append.cil | tr -d '\n')
[ -n "$b" ] && for n in worker1 worker2; do
  oc debug node/$n.okd4.example.com -q -- chroot /host sh -c "
d=\$(mktemp -d) && f=\$d/kata-deploy-crio-append.cil &&
echo $b | base64 -d > \$f && [ -s \$f ] && semodule -X 401 -i \$f
rc=\$?; rm -rf \$d; semodule -lfull | grep kata; exit \$rc"
done
oc delete pod -n kata-deploy -l name=kata-deploy --wait=false
```

The file goes over as base64, which has no shell metacharacters, so
its content can't break out of the quoted command that runs as root on
the node. `semodule` names the module after the file, hence the fixed
file name in a temporary directory. Running the loop again replaces
the module in place.

Expected `semodule` output per worker:

```
401 kata-deploy                  cil
401 kata-deploy-cri-config-etc_t cil
401 kata-deploy-crio-append      cil
```

The module persists in the node's policy store across reboots, and
the chart's own module reloads don't touch it because the name
differs. The rule sits in a CIL `optional` block: if the chart's types
disappear (module removed, or renamed by an upgrade) the rule is
dropped instead of failing every later `semodule` transaction. Check
what is loaded with `semodule -X 401 -E kata-deploy-crio-append` (run
in a writable directory such as `/tmp`; it writes the `.cil` file
there). A MachineConfig would also work but costs a reboot of every
worker and has the same ordering problem.

Both pods are `1/1 Running` within about 30 s. Their log
(`oc logs -n kata-deploy ds/kata-deploy`) ends with:

```
install (cri): crio is serving ["kata-qemu-runtime-rs"]
Setting label katacontainers.io/kata-runtime=true on node worker2.okd4.example.com
Kata Containers installation completed successfully
```

CRI-O restarts without making the nodes `NotReady`, and `ausearch -m
AVC -ts recent | grep kata_deploy` on the workers comes back empty.
Use `oc get pods -n kata-deploy` to check the restart: `oc wait -l
name=kata-deploy` resolves the selector to the deleted pods and times
out.

## 5. Verify the install

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
```

Observed (trimmed):

```
kata-deploy  kata-deploy  1  deployed  kata-deploy-4.2.0  4.2.0
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

kata-deploy also writes an empty `100-debug`. The kata files live in
`/var/opt/kata` (`usr_t`) and `getenforce` stays `Enforcing`; no
relabeling or `disable_selinux` is needed.

## 6. Run podman inside a kata pod

[`okd/03-podman-in-kata.yaml`](okd/03-podman-in-kata.yaml) is based on
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
oc apply -f okd/03-podman-in-kata.yaml
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
```

Observed output (trimmed). The pod was Ready after 13 s including the
image pull, and everything worked on the first try:

```
privileged
ls: cannot access '/var/run/secrets/kubernetes.io': No such file or directory
!... Hello Podman World ...!
...
ID="centos"
VERSION_ID="10"
PRETTY_NAME="CentOS Stream 10 (Coughlan)"
overlay false
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

## 7. Unprivileged kata pods

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
  `podman` in `kata-test` may be privileged, including a runc pod
  with hostPath volumes. Privileged is only contained in the guest
  because `podman-in-kata` sets `runtimeClassName: kata`. Enforcing
  that would need e.g. a ValidatingAdmissionPolicy; not done here.
- The upstream chart's ClusterRole gives `kata-deploy-sa` `patch` on
  `nodes` and `get` on `nodes/proxy`, cluster-wide. `kube-kata` also
  mounts the host `/` and `/run/systemd/private`, which is
  root-equivalent on the node. Both are upstream design.
- Images and chart are pinned by tag only:
  `kata-deploy:4.2.0` with `imagePullPolicy: Always`, the cleanup
  job's `kubectl:latest` and `podman/stable:latest`. Fine for a dated
  lab log; pin digests for anything real.
- `privileged_without_host_devices = true` in the CRI-O drop-in keeps
  the host's `/dev` out of privileged kata pods. Section 5 checks it.
- The guest kernel runs with `selinux=0`, so the boundary is the
  host-side confinement of the VMM: `container_kvm_t` with per-pod MCS
  categories (section 6).

## Known issues

- The SELinux fix in section 4 is manual and per node. A new worker
  or a reinstalled one needs it again, after kata-deploy's init
  container has run. If upstream bumps `policy-revision` and renames
  the attributes, the `optional` block turns the rule off; that is
  harmless and probably means the fix is no longer needed. Not yet
  reported upstream; the fix there is adding `append` to the CRI
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

```sh
oc delete -f okd/03-podman-in-kata.yaml
helm uninstall kata-deploy -n kata-deploy
for n in worker1 worker2; do
  oc debug node/$n.okd4.example.com -q -- chroot /host \
    semodule -X 401 -r kata-deploy-crio-append
done
oc delete namespace kata-deploy kata-test
```

The chart's own modules (`kata-deploy`, `kata-deploy-cri-config-etc_t`)
stay loaded after uninstall; remove them with `semodule -X 401 -r` if
needed, after `kata-deploy-crio-append`. Whether the chart's
uninstall also removes `/var/opt/kata` and
the CRI-O drop-in has not been checked.

Only part of this has been run: removing the extra module and
deleting the namespaces (by mistake, see the top of this log). Both
worked. `helm uninstall` and its post-delete cleanup Job have not been
run.
