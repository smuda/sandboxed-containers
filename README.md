# sandboxed-containers

Test logs for running Kata Containers on OpenShift and OKD lab
clusters. The goal of each run is a pod with a kata RuntimeClass that
runs inside a lightweight VM, and podman inside that pod starting a
nested container.

Each log is written so the install can be reproduced on a fresh
cluster by following it top to bottom. The manifests it applies are
in the matching directory.

## Results

| | OpenShift | OKD |
|---|---|---|
| Log | [openshift.md](openshift.md) | [okd.md](okd.md) |
| Manifests | [`openshift/`](openshift/) | [`okd/`](okd/) |
| Tested | 2026-09-30 | 2026-10-01 |
| Cluster | OpenShift 4.20.24, RHCOS 9.6 | OKD 4.22.0-okd-scos.9, CentOS Stream CoreOS 10 |
| Kata from | OpenShift sandboxed containers operator 1.13.1 (`redhat-operators`) | Upstream kata-deploy helm chart 4.2.0 |
| Enabled by | KataConfig, MachineConfig extension, one reboot per worker | DaemonSet, CRI-O drop-in, no reboot |
| RuntimeClass | `kata` | `kata` (handler `kata-qemu-runtime-rs`) |
| Podman in kata | Works | Works |
| Workarounds | None | One-rule SELinux module for CRI-O |

## Why OKD doesn't use the operator

The sandboxed containers operator installs kata as an RHCOS
extension, i.e. the `kata-containers` RPM. CentOS Stream 10 doesn't
ship that RPM, so OKD's SCOS extensions have no kata, and every
public operator bundle pulls its images from registry.redhat.io.
Red Hat's catalog and registry are not used on OKD, for licensing
reasons. Upstream kata-deploy installs statically built kata, qemu
and guest kernel into `/opt/kata` instead. Details are in section 2
of [okd.md](okd.md).

On OKD, kata-deploy 4.2.0's own SELinux policy lacks an `append`
permission that the CRI-O config writer needs. Section 4 of
[okd.md](okd.md) has the fix; a draft upstream issue is near the end.

## Podman inside a kata pod

Both runs use the same pod setup
([openshift](openshift/03-podman-in-kata.yaml),
[okd](okd/03-podman-in-kata.yaml)). It needs:

- `privileged: true`, which in kata applies inside the guest VM, not
  on the host node
- an `emptyDir` with `medium: Memory` at `/var/lib/containers`,
  because the container rootfs in the guest is virtio-fs, which
  overlay can't use
- a minimal `storage.conf` (native overlay, no `mount_program`, no
  `imagestore`), because the image defaults to fuse-overlayfs and
  kata doesn't pass `/dev/fuse` into the guest

Each log ends with checks that prove the pod is in a VM: guest CPU
count and kernel command line, and the qemu process on the node.

## Other files

- [prompt.md](prompt.md): the prompts used to drive the test runs
