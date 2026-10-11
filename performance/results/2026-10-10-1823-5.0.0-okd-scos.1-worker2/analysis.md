# Analysis: block-plain emptyDir run

Run `2026-10-10-1823-5.0.0-okd-scos.1-worker2`: same node, cluster,
kata-deploy 4.2.0 and pod sizes as
[run 0635](../2026-10-10-0635-5.0.0-okd-scos.1-worker2/analysis.md).
What changed is in [changes.md](changes.md): kata disk emptyDirs are
an ext4 image on a virtio-blk device (`emptydir_mode = "block-plain"`,
`cache_direct`, native aio) instead of virtio-fs, stream uses fixed
64M arrays and reports MB/s, and `disk_bytes` counts allocated blocks.
Ratios are kata median / runc Baseline median from
[summary.csv](summary.csv), 3 repetitions unless noted.

## CPU and memory bandwidth: no cost

| | plain | nested vfs disk | nested overlay RAM |
|-|-|-|-|
| stress-ng cpu ops/s | 0.995 | 0.999 | 0.999 |
| stress-ng matrix ops/s | 1.000 | 1.007 | 1.005 |
| stream read MB/s | 1.03 | 1.03 | 1.04 |

With the same working set on both sides (3 x 64 MiB per instance),
kata reads memory as fast as runc, slightly faster. Absolute numbers
dropped for runc (5020 to 4600 MB/s) because the larger arrays no
longer partly fit in L3. The 0.73 of run 0635 is gone for good; it
was the array size.

## Disk on block-plain: writes fixed, direct I/O now honest

plain-kata vs plain-runc, run 0635 (virtio-fs) and this run:

| fio job | 0635 | 1823 |
|-|-|-|
| randread 4k direct | 2.29 | 0.63 |
| randread 4k buffered | 2.31 | 0.62 |
| seqread 1m direct | 2.39 | 0.73 |
| seqread 1m buffered | 1.26 | 0.87 |
| randwrite 4k direct | 0.57 | 0.25 |
| randwrite 4k buffered | 0.14 | 1.11 |
| seqwrite 1m direct | 0.35 | 0.89 |
| seqwrite 1m buffered | 0.13 | 0.46 |

Buffered 4k writes moved from 0.14 to 1.11: the guest page cache
absorbs them, so they no longer pay a virtio-fs round trip each.

Every kata direct row now reaches the NVMe (`cache_direct`), so they
are device against device for the first time. The virtio-fs "faster"
reads of run 0635 were the node page cache. The real price is about
25-30 µs per 4k operation at queue depth 1: randread 70 µs against
44 µs, randwrite about 40 µs against runc's 10 µs (p99 103 µs
against 14 µs). runc's 4k direct writes land in the drive's write
cache, which makes the relative cost look large. With 1 MiB transfers
the overhead is mostly amortised (0.73-0.89).

runc buffered random reads equal its direct reads (22k IOPS): fio
drops the file from the page cache before each job, so both runtimes
read from the device there too.

Buffered seqwrite at 0.46 is the one remaining large gap, and it is
not a transport cost. kata writes 2.56 GB/s, about the device's
direct speed (2.16 GB/s); runc writes 5.56 GB/s into a 62 GiB host
page cache that never needs to flush 1 GiB within the job. Inference,
not verified: the 4 GiB guest reaches its dirty limits and is
throttled to device speed (p99 3.5 ms against 0.3 ms). Any workload
that streams more data than fits its dirty limit sees the same on
runc.

## Footprint

| | runc | kata 0635 | kata 1823 |
|-|-|-|-|
| idle memory per pod, disk Setups | ~0.6-0.8 MB | ~265 MB | ~322 MB |
| idle CPU, disk Setups | ~0 | ~4 mcores | ~33 mcores |
| node CPU time during fio, disk | 146-157 s | 1150-1400 s | 594-625 s |
| fio peak memory, plain | 1.08 GB | 2.47 GB | 1.54 GB |

block-plain halves the node CPU for disk I/O (7.7-8.7x runc down to
4.0-4.1x) and removes most of the double caching (peak memory 1.43x
runc, was 2.29x). The price is about 57 MB and 30 mcores more per idle
pod with a disk emptyDir; the overlay-RAM Setup, which has no block
emptyDir, stays at 265 MB and 4 mcores. The idle CPU is most likely
the guest's ext4 lazy inode-table init on an image the size of the
host filesystem (511 GB apparent), as reported upstream in
[kata#13310](https://github.com/kata-containers/kata-containers/issues/13310);
not measured here.

`disk_bytes` now counts allocated blocks, so the kata emptyDir shows
its real use (1.08 GB for fio against 1.07 GB for runc).

## Nested podman: vfs in kata is now close to runc

| podman-ops | runc vfs | kata vfs 0635 | kata vfs 1823 |
|-|-|-|-|
| build | 12.6 s | 53.5 s (4.2x) | 18.1 s (1.44x) |
| run --rm, per container | 0.50 s | 2.50 s (5.0x) | 0.48 s (0.96x) |
| pull podman image | 15.5 s | 50.2 s (3.3x) | 16.7 s (1.08x) |
| node CPU time | 45 s | 409 s (9.0x) | 96 s (2.1x) |

The layer copies that vfs makes now go to ext4 on a block device
inside the guest instead of across virtio-fs. kata+vfs is still 2.2x
slower to build than runc+overlay (8.1 s), which is the cost of vfs
itself. With a real ext4 in the guest, overlay storage
inside kata may now work on disk too; not tested.

Nested fio in podman-kata-vfs-disk now matches plain-kata within a few
percent on the 4k jobs, so the unexplained difference of run 0635
(nested writes much faster than plain) is gone. Why it existed over
virtio-fs remains unknown; it no longer matters for this setup.

## Overlay on RAM: unchanged

`medium: Memory` emptyDirs are tmpfs in the guest and not affected by
block-plain. fio is within 9% of runc on every job (kata faster on
sequential writes), podman-ops build 1.74x, `run --rm` 2.6x, pull
1.11x. Peak memory 4.6 GB against 3.0 GB. Same picture as run 0635.

## Operational consequences of block-plain

The benchmark shows what block-plain does to throughput. For running
it, what matters more is that a disk emptyDir stops being a directory
on the node and becomes a disk inside the VM. That changes how much
space the container sees, how limits are enforced, who can look at the
data and what an idle pod costs. We tested the most important points
on worker2 on 2026-10-11 with a kata and a runc pod, each with two
containers sharing one emptyDir with `sizeLimit: 200Mi`; the rest
comes from the kata source and upstream issues, linked where used.

### What keeps working

From inside the pod, block-plain behaves like an ordinary emptyDir.
Containers in the same pod share it: a file written by one container
was readable in the other. Deleted data gives its space back to the
node, because the guest mounts the filesystem with `discard`; after
writing and deleting 300 MiB, the image's allocation went from 324 MB
back to 9.9 MB.

`sizeLimit` is also still enforced, in the same way as under runc.
Writing 400 MiB into the 200Mi emptyDir got both pods evicted about
40 s later with the same message: "Usage of EmptyDir volume "data"
exceeds the limit "200Mi"". kubelet measures the allocated blocks of
`disk.img` on the node and sees them grow like any other file. In
neither runtime is the limit a full disk: the write succeeds, and
kubelet evicts the pod afterwards.

### The disk the guest sees is the size of the node's filesystem

What the container can no longer see is the limit, or the node. `df
/data` in kata shows a 476 GB ext4 on `/dev/vda`, nearly empty, where
runc shows the node's XFS with its real usage (43 GB used). The free
space reported in the guest is the size of the image, not what the
node has left. We did not test it, but if the node disk fills up
first, the guest should get I/O errors from its block device rather
than a clean ENOSPC.

Making the guest disk match `sizeLimit` is not possible in kata 4.2.0.
The shim sizes `disk.img` from `statfs()` of the emptyDir directory,
which is the host filesystem
([block_emptydir_volume.rs](https://github.com/kata-containers/kata-containers/blob/4.2.0/src/runtime-rs/crates/resource/src/volume/block_emptydir_volume.rs)).
`sizeLimit` exists only in the pod spec; neither CRI nor OCI passes it
to the runtime. Upstream issue
[kata#13310](https://github.com/kata-containers/kata-containers/issues/13310)
(open) discusses handing it over in a pod annotation, which is not
implemented and is treated with caution, because annotations have been
an attack vector in kata. Today, a size the guest actually sees needs a
generic ephemeral volume from a local block CSI driver (for example
LVM Storage) instead of an emptyDir; kata hot-plugs that device at its
requested size. This cluster only has `nfs-csi`.

### An idle pod can be evicted by filesystem metadata

The large image has a cost of its own, also described in
[kata#13310](https://github.com/kata-containers/kata-containers/issues/13310).
The guest formats the image as ext4 and initialises the inode tables
lazily in the background. That allocates about 0.08% of the image size
on the node, roughly 400 MB for our 511 GB image, without the pod
writing anything. kubelet counts it as emptyDir usage, so a pod with a
small `sizeLimit`, like the 200Mi in our test, can be evicted while
idle. Our test pod showed 9.9 MB right after start and was not watched
long enough to see the growth. The same background work is the most
likely source of the extra idle CPU in the Footprint section. A fix is
proposed upstream behind a `[runtime]` flag that mounts the image with
`noinit_itable`, which brings an empty volume down to about 13 MB
([kata#13977](https://github.com/kata-containers/kata-containers/pull/13977),
open).

### The data lives inside the VM

On the node, the emptyDir directory now holds a single `disk.img`
(511 GB apparent, 9.9 MB allocated when fresh). Inspecting, copying
or collecting files from the node side no longer works; the files are
only reachable through the pod. The same goes for the page cache:
O_DIRECT in the guest reaches the NVMe, and buffered data is cached
only in guest RAM, inside the pod's memory limit, instead of twice
(guest and node) as with virtio-fs.

Each disk emptyDir in a kata pod is a hot-plugged block device. With
the image comes a fixed cost of about 57 MB of memory and 30 mcores
of CPU per idle pod (see Footprint).

### Rolling it out

The setting is per shim, not per pod. With the drop-in in place, every
pod using `kata` or `kata-qemu-runtime-rs` gets block-plain emptyDirs,
and there is no per-pod opt-out; offering both would take a separate
RuntimeClass (kata-deploy `customRuntimes`). The drop-in also has to
set `block_device_aio = "native"`: with the default `io_uring`, every
kata pod with a disk emptyDir fails to start on SCOS, which sets
`kernel.io_uring_disabled = 2`.

## Caveats

- podman-kata-overlay-ram fio r3 failed: machine-config-controller
  evicted the pod two minutes into the job to drain worker2. A change
  to `/etc/containers/registries.conf` was rendered for all pools at
  21:21Z (rendered-worker-76682aa8), not made by the benchmark. Only
  randread-4k-direct has 3 values; the other overlay-RAM fio rows are
  from 2 repetitions, which agree within about 1% and match run 0635.
- environment.json records the kata toml files but not the `config.d`
  drop-in, so the block-plain settings are documented only in
  changes.md.
- runc Baselines reproduce run 0635 within 7%, except
  podman-runc-vfs-disk seqwrite 1m direct (0.82 of run 0635) and the
  stream and stress-ng peak memory rows, which changed with the array
  size.
- Other pods ran on worker2 and there are 3 repetitions; treat
  differences under about 10% as noise.
