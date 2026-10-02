# OpenShift sandboxed containers on OpenShift

Test run 2026-09-30. Result: working. A pod with `runtimeClassName:
kata` runs inside a QEMU/KVM guest, and podman inside that pod pulls
and runs nested containers.

## Environment

- OpenShift 4.20.24, platform BareMetal
- 3 control-plane nodes, 2 workers (`worker1`, `worker2`)
- RHCOS 9.6, kernel 5.14.0-570.117.1.el9_6, CRI-O 1.33.12
- Workers are bare metal (`systemd-detect-virt` = `none`) with
  `/dev/kvm` present and `vmx` CPU flags
- `oc` client 4.22.13, logged in as cluster admin
- OpenShift sandboxed containers operator 1.13.1 from
  `redhat-operators`, channel `stable`

Manifests are in [`openshift/`](openshift/).

## 1. Check prerequisites

Kata needs hardware virtualization on the workers. Nested
virtualization works too if the workers are VMs, but these are bare
metal.

```sh
oc get clusterversion
oc get packagemanifest sandboxed-containers-operator \
  -n openshift-marketplace \
  -o jsonpath='{.status.defaultChannel}{"\n"}'
for n in worker1 worker2; do
  oc debug node/$n.okd4.example.com -q -- chroot /host \
    sh -c 'grep -cE "vmx|svm" /proc/cpuinfo; ls -l /dev/kvm'
done
```

Expected: default channel `stable`, a non-zero CPU flag count and
`/dev/kvm` on every worker.

## 2. Install the operator

[`openshift/01-operator.yaml`](openshift/01-operator.yaml) creates the
`openshift-sandboxed-containers-operator` namespace, an OperatorGroup
and a Subscription to channel `stable`.

```sh
oc apply -f openshift/01-operator.yaml
oc get csv -n openshift-sandboxed-containers-operator -w
```

Wait until `sandboxed-containers-operator.v1.13.1` is `Succeeded`.
This took about two minutes; the Subscription sat in `BundleUnpacking`
for most of it. Other operators' copied CSVs also show up in the
namespace list and can be ignored.

## 3. Create the KataConfig

[`openshift/02-kataconfig.yaml`](openshift/02-kataconfig.yaml):

- `checkNodeEligibility` is a required field in 1.13. `true` needs the
  Node Feature Discovery operator, so it is set to `false`.
- No `kataConfigPoolSelector`, so all worker nodes get kata.

```sh
oc apply -f openshift/02-kataconfig.yaml
```

The operator moves the workers into a new `kata-oc`
MachineConfigPool and adds the `sandboxed-containers` RHCOS extension
with MachineConfig `50-enable-sandboxed-containers-extension`. MCO
then drains and reboots the workers one at a time.

Follow progress:

```sh
oc get mcp kata-oc -w
oc get kataconfig example-kataconfig -o jsonpath='{.status}'
```

Done when the `InProgress` condition is `False` and
`kataNodes.readyNodeCount` equals `nodeCount`. Here that took about 11
minutes for two workers. Afterwards:

```sh
$ oc get runtimeclass
NAME              HANDLER           AGE
kata              kata              6s
kata-nvidia-gpu   kata-nvidia-gpu   6s
```

## 4. Run podman inside a kata pod

[`openshift/03-podman-in-kata.yaml`](openshift/03-podman-in-kata.yaml)
creates namespace `kata-test`, a ServiceAccount allowed to use the
`privileged` SCC, a ConfigMap with a podman `storage.conf`, and pod
`podman-in-kata` running `quay.io/podman/stable` with
`runtimeClassName: kata`.

```sh
oc apply -f openshift/03-podman-in-kata.yaml
oc wait -n kata-test pod/podman-in-kata --for=condition=Ready \
  --timeout=300s
oc exec -n kata-test podman-in-kata -- podman run --rm \
  quay.io/podman/hello
oc exec -n kata-test podman-in-kata -- podman run --rm \
  registry.access.redhat.com/ubi9/ubi-minimal cat /etc/redhat-release
```

Observed output (trimmed):

```
!... Hello Podman World ...!
...
Red Hat Enterprise Linux release 9.8 (Plow)
```

### Why the pod looks the way it does

The first attempt used the podman image as-is with only
`privileged: true`. It failed:

```
using mount program /usr/bin/fuse-overlayfs: fuse: device /dev/fuse
not found. Kernel module not loaded?
```

Causes found in the guest:

- The container rootfs inside the VM is `virtiofs`
  (`none on / type virtiofs`), which cannot be an overlay upper dir.
- The kata runtime does not pass host devices into the guest for
  privileged pods, so there is no `/dev/fuse`.
- The image's `/etc/containers/storage.conf` sets
  `mount_program = "/usr/bin/fuse-overlayfs"` and an `imagestore` under
  `/usr/lib/containers/storage`, i.e. on the virtiofs rootfs. Removing
  only `mount_program` then failed with `invalid argument` on the
  overlay mount.

Fix, both in the manifest:

- Mount an `emptyDir` with `medium: Memory` at `/var/lib/containers`.
  This is a tmpfs inside the guest, which native overlay accepts.
- Replace `storage.conf` with a minimal one (driver `overlay`,
  graphroot on the tmpfs, no mount program, no imagestore).

`privileged: true` only grants privileges inside the guest VM, which
is the point of running podman in kata rather than in a plain runc pod.

## 5. Verify the pod really is in a VM

Inside the pod the kernel command line is the kata guest's, and the
guest has 1 vCPU while the host has 12:

```sh
$ oc exec -n kata-test podman-in-kata -- nproc
1
$ oc exec -n kata-test podman-in-kata -- cat /proc/cmdline
... console=hvc0 console=hvc1 debug panic=1 nr_cpus=12 selinux=0 ...
agent.log=debug ...
```

The guest kernel version equals the host kernel version, because the
RHCOS extension ships the guest kernel from the same build, so
`uname -r` alone proves nothing.

On the node a `qemu-kvm` process is named after the pod sandbox:

```sh
oc debug node/worker2.okd4.example.com -q -- chroot /host sh -c '
  id=$(crictl pods --name podman-in-kata -q)
  pgrep -af "qemu-kvm -name sandbox-$id" | cut -c1-110'
```

```
19631 /usr/libexec/qemu-kvm -name sandbox-220d94abd1e5...
```

## Cleanup

```sh
oc delete -f openshift/03-podman-in-kata.yaml
# Removing kata reboots the workers again:
oc delete -f openshift/02-kataconfig.yaml
oc delete -f openshift/01-operator.yaml
```

The cleanup steps have not been run in this test.
