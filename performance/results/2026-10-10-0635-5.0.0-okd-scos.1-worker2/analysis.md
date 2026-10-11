# Analysis: first full run

Run `2026-10-10-0635-5.0.0-okd-scos.1-worker2`: OKD 5.0.0-okd-scos.1,
kata-deploy 4.2.0 (`kata-qemu-runtime-rs`), worker2 (i7-10710U,
12 CPUs, 62 GiB, KINGSTON SKC3000 NVMe). Pods 4 CPU / 4Gi Guaranteed,
3 repetitions, no failed rows. Ratios are kata median / runc Baseline
median, from [summary.csv](summary.csv).

## CPU: no cost

| | plain | nested vfs disk | nested overlay RAM |
|-|-|-|-|
| stress-ng cpu ops/s | 0.995 | 0.993 | 0.998 |
| stress-ng matrix ops/s | 0.982 | 0.991 | 1.006 |

Compute-bound work runs at native speed in kata. Nested podman adds
nothing either: nested stress-ng matches plain stress-ng under the
same Runtime.

## Memory bandwidth: about 3% slower

stress-ng stream reads at 0.97 of runc in all three kata Setups
(about 4860 against 5010 MB/s).

An earlier version of this summary used stream bogo-ops/s and
reported 0.73. That was a measurement artefact: stress-ng sizes the
stream arrays from the L3 size it detects, and the kata guest detects
a different one. Each instance used 12 MiB in kata against 9 MiB
under runc (`pages-mmapped` 3072 against 2304), so each bogo-op moved
a third more memory. 9/12 x 0.97 = 0.73. This run predates the fixed
`--stream-l3-size 64M`; the read rate is comparable regardless.

## Footprint: the fixed price of kata

| | runc | kata |
|-|-|-|
| idle memory per pod | ~0.8 MB | ~265 MB |
| idle CPU | ~0 | ~4 mcores |
| node CPU time during fio, disk | 150-162 s | 1150-1400 s (7.7-8.7x) |
| node CPU time during fio, RAM | 564 s | 571 s (1.0x) |

The 265 MB idle cost matches [usage.md](../../../usage.md). New is
the CPU cost of disk I/O: through virtio-fs, kata spends about 8x the
node CPU for the same work, in virtiofsd and qemu. When I/O stays
inside the guest (RAM), that cost disappears.

## Disk via virtio-fs: reads look fast, writes are slow

plain-kata vs plain-runc:

| fio job | ratio |
|-|-|
| randread 4k, direct and buffered | 2.3 (faster) |
| seqread 1m direct | 2.4 (faster) |
| randwrite 4k direct | 0.57 |
| randwrite 4k buffered | 0.14 |
| seqwrite 1m direct | 0.35 |
| seqwrite 1m buffered | 0.13 |

Reads are not really faster. runc direct 4k reads give 23k IOPS at
queue depth 1, which is realistic for NVMe. kata gives 52k, which is
the node's page cache: with `virtio_fs_cache = auto`, O_DIRECT in the
guest does not reach the disk. kata's "direct" read numbers measure
memory, not the device.

Writes are the real cost. Buffered writes run at 13-14% of runc
speed. The runc side is not the disk either: fio fsyncs only at the
end, so runc writes land in the node page cache (331k IOPS 4k, 5.4
GB/s 1m, at queue depth 1; peak memory 1.08 GB is the 1 GiB file).
In kata every write crosses the guest, virtio-fs and virtiofsd before
it reaches that same cache. The ratio is page cache against
virtio-fs, which is what a buffered writer on a disk emptyDir gets.

## Nested podman: vfs and kata compound

| podman-ops | runc overlay | runc vfs | kata vfs | kata / runc vfs |
|-|-|-|-|-|
| build | 7.7 s | 12.9 s | 53.5 s | 4.2x |
| run --rm, per container | | 0.50 s | 2.50 s | 5.0x |
| pull podman image | 8.5 s | 15.1 s | 50.2 s | 3.3x |
| node CPU time | 26 s | 45 s | 409 s | 9.0x |
| disk used | 1.3 GB | 7.1 GB | 7.1 GB | 1.0x |

vfs on its own costs about 1.7x in time and 5.4x in disk. kata on top
of vfs multiplies that by another 3-5x, because every layer copy
crosses virtio-fs. End to end, a kata+vfs build is 7x slower than
runc+overlay.

## Overlay on RAM: kata's cost mostly disappears

fio is within 12% of runc on every job (kata faster on buffered
seqwrite). podman-ops: build 1.7x, `run --rm` 2.7x (0.18 s per
container), pull 1.17x. The price is RAM, and in kata that RAM is
never given back (see usage.md): peak memory 4.5 GB against 3.0 GB
for runc.

For podman in kata, overlay on RAM is roughly 4x faster than vfs on
disk.

## Not explained

In podman-kata-vfs-disk, nested fio writes are much faster than in
plain-kata: seqwrite direct 5.5 GB/s against 0.88 GB/s, buffered
2.7 GB/s against 0.72 GB/s. Both go through virtio-fs to the same node
disk. The summary cannot explain it; possibly the nested container's
rootfs changes the caching path. Start with the raw fio JSON under
`raw/podman-kata-vfs-disk/fio/`.

## Caveats

- 21 other pods ran on worker2 and there are only 3 repetitions. A few
  metrics have a wide min-max range (buffered randwrite, and pull
  times, which go over the internet). Treat differences under about
  10% as noise.
- runc idle CPU reads 0: the 30 s idle window is below what the cgroup
  counter resolves for an idle runc pod. It means "too small to
  measure", not zero.
- The `prometheus-*.json` files are not analysed here.
