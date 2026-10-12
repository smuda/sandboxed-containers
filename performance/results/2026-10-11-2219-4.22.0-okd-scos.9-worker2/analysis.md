# Analysis: block-plain with a qemu iothread

Run `2026-10-11-2219-4.22.0-okd-scos.9-worker2`: same worker2
hardware, kata-deploy 4.2.0 (`qemu-runtime-rs`), guest kernel and pod
sizes as
[run 1823](../2026-10-10-1823-5.0.0-okd-scos.1-worker2/analysis.md),
on a freshly reinstalled cluster with OKD 4.22.0-okd-scos.9. What
changed is in [changes.md](changes.md): the block-plain drop-in now
also sets `enable_iothreads = true` and `indep_iothreads = 1`, and
CRI-O and the host kernel are slightly different builds. Ratios are
kata median / runc Baseline median from [summary.csv](summary.csv),
3 repetitions, no failed rows.

The question: does the iothread make block-plain faster, and what is
the best kata configuration on OKD?

## Summary

Yes, for small I/O. The fixed per-I/O cost that run 1823 measured
dropped from about 26-32 µs to about 7-10 µs, so 4k direct writes
went from 0.25 to 0.51 of runc and 4k reads from 0.62 to 0.87.
Everything else is unchanged within noise: CPU, memory, buffered and
1 MiB I/O, nested podman and idle Footprint. The price is about
12-15% more node CPU during fio, while kata also did more I/O in the
same time.

| access pattern, block-plain emptyDir | 1823 | this run | cost now |
|-|-|-|-|
| buffered 4k random writes | 1.11 | 1.07 | none |
| 1 MiB direct writes | 0.89 | 0.95 | ~5% |
| small random reads, cold | 0.62 | 0.86-0.87 | ~15% |
| 1 MiB reads | 0.73-0.87 | 0.78-0.84 | ~15-20% |
| 4k direct or fsync-bound writes | 0.25 | 0.51 | ~50% |
| buffered streaming writes | 0.46 | 0.47 | ~55%, guest page cache |

The iothread is the likely cause but not a proven one. runc's 4k
numbers did not move between the runs, the guest kernel and qemu are
the same, and the change appears in both kata disk Setups with tight
spreads. The cluster, CRI-O and host kernel changed at the same time,
so an A/B on this cluster without the two iothread lines is needed to
attribute it with certainty.

Best OKD configuration from the data so far: block-plain with
`cache_direct`, native aio and one independent iothread. It is the
only kata configuration measured here whose direct I/O reaches the
device and still runs at 0.5-0.95 of runc. The opt-in RuntimeClass
`kata-block-emptydir` in `okd/04-kata-deploy-values.yaml` does not
set the iothread yet.

## Host confounder: runc did not move

| runc metric (plain-runc) | 1823 | this run | this/1823 |
|-|-|-|-|
| stress-ng cpu ops/s | 6865 | 6861 | 1.00 |
| stream read MB/s | 4596 | 4513 | 0.98 |
| fio randread 4k direct | 23.0k IOPS | 23.1k IOPS | 1.00 |
| fio randwrite 4k direct | 95.8k IOPS | 100k IOPS | 1.05 |
| fio randwrite 4k buffered | 329k IOPS | 334k IOPS | 1.02 |
| fio seqread 1m direct | 2.24 GB/s | 1.84 GB/s | 0.82 |
| fio seqwrite 1m direct | 2.42 GB/s | 2.27 GB/s | 0.94 |
| fio seqwrite 1m buffered | 5.56 GB/s | 6.42 GB/s | 1.16 |
| fio node CPU time | 146 s | 149 s | 1.02 |

The 4k jobs, where kata changed most, are within 5% on runc. The 1m
rows moved in both directions, but those are the noisy rows in both
runs (plain-runc seqread direct 1.48-2.11 GB/s, seqwrite buffered
p99 0.13-1.99 ms). The two podman runc disk Setups also lost about
7% on seqread direct, so that part is the host or device. Ratios are
usable for the 4k rows; for the 1m rows compare absolutes.

## CPU and memory bandwidth: no cost

| | plain | nested vfs disk | nested overlay RAM |
|-|-|-|-|
| stress-ng cpu ops/s | 1.001 | 0.997 | 0.995 |
| stress-ng matrix ops/s | 0.998 | 0.988 | 0.995 |
| stream read MB/s | 1.05 | 1.02 | 1.03 |

kata's absolute numbers are within 1% of run 1823; the stream ratio
rose only because runc read 2% slower.

## Disk on block-plain: the fixed per-I/O cost shrank

plain-kata vs plain-runc:

| fio job | 0635 virtio-fs | 1823 | this run | kata this/1823 |
|-|-|-|-|-|
| randread 4k direct | 2.29 | 0.63 | 0.86 | 1.37 |
| randread 4k buffered | 2.31 | 0.62 | 0.87 | 1.41 |
| seqread 1m direct | 2.39 | 0.73 | 0.78 | 0.87 |
| seqread 1m buffered | 1.26 | 0.87 | 0.84 | 0.97 |
| randwrite 4k direct | 0.57 | 0.25 | 0.51 | 2.12 |
| randwrite 4k buffered | 0.14 | 1.11 | 1.07 | 0.98 |
| seqwrite 1m direct | 0.35 | 0.89 | 0.95 | 1.00 |
| seqwrite 1m buffered | 0.13 | 0.46 | 0.47 | 1.19 |

Mean completion latency at queue depth 1, from the raw fio JSON
(the same in all three repetitions within 1-2 µs):

| 4k direct | runc | kata 1823 | kata this run | kata cost 1823 | kata cost now |
|-|-|-|-|-|-|
| randread | 42 µs | 68 µs | 49 µs | 26 µs | 7 µs |
| randwrite | 9 µs | 41 µs | 19 µs | 32 µs | 10 µs |

randwrite p99 fell from 103 µs to 38 µs (runc 13 µs). That matches
what an iothread should change: the virtio-blk request no longer
waits for qemu's main loop. podman-kata-vfs-disk, whose nested fio
writes to the same guest block device, shows the same change
(randwrite 4k direct 22.0k to 47.9k IOPS, ratio 0.23 to 0.48;
randread 0.63 to 0.86).

A possible mechanism, not verified: qemu iothreads poll adaptively
for completions (`poll-max-ns`, 32 µs by default) instead of sleeping
until the next event. That would remove a wake-up per request, and
would also explain the extra node CPU below.

Large transfers were already mostly amortised and stayed so.
seqwrite 1m direct is the device speed on both sides (kata 2.16 GB/s
in both runs). seqread 1m direct fell from 1.64 to 1.43 GB/s
(1.29-1.62, p99 0.91 to 1.17 ms) while runc also fell, so the ratio
barely moved. Buffered seqwrite is still about 0.47: kata wrote
3.05 GB/s against 2.56 GB/s in run 1823, runc 6.42 against 5.56, and
both are the guest dirty limit against the 62 GiB host page cache, as
described in run 1823.

4k direct writes at 0.51 are still the largest gap. runc's 9 µs is
the drive's write cache, so 19 µs in kata is not slow in absolute
terms, but an fsync-heavy database still pays about twice as much per
commit.

## Footprint

| | runc | kata 1823 | kata this run |
|-|-|-|-|
| idle memory per pod, disk Setups | ~0.6-0.8 MB | ~322 MB | ~314-324 MB |
| idle CPU, disk Setups | ~0 | ~31-35 mcores | ~32-37 mcores |
| node CPU time during fio, plain | 149 s | 594 s (4.07x) | 686 s (4.60x) |
| node CPU time during fio, nested vfs | 159 s | 625 s (3.99x) | 702 s (4.42x) |
| fio peak memory, plain | 1.08 GB | 1.54 GB | 1.55 GB |

The iothread costs nothing at idle. During fio kata uses 12-15% more
node CPU. The fio jobs are time-based, and kata completed about
1.4x the 4k reads and 2.1x the 4k direct writes in the same time, so
CPU per I/O went down; per-job CPU is not recorded, so this cannot be
split further. The overlay-RAM Setup, which has no block device, is
unchanged (571 s, 263-267 MB, 4 mcores).

`disk_bytes` is unchanged: the new `diff/local` path is empty on OKD
(1.08 GB for plain-kata fio, 7.54 GB for nested vfs podman-ops, as
in run 1823).

## Nested podman: unchanged

| podman-ops | runc vfs | kata vfs 1823 | kata vfs this run |
|-|-|-|-|
| build | 12.7 s | 18.1 s (1.44x) | 19.1 s (1.50x) |
| run --rm, per container | 0.49 s | 0.48 s (0.96x) | 0.46 s (0.93x) |
| pull podman image | 14.9 s | 16.7 s (1.08x) | 16.4 s (1.10x) |
| node CPU time | 45 s | 96 s (2.1x) | 92 s (2.1x) |

Image builds and container starts are dominated by buffered
small-file I/O, which the iothread does not touch. The build spread
is wide (17.5-20.2 s), so 18.1 against 19.1 s is noise. Overlay on
RAM is as in run 1823: build 1.72x, `run --rm` 2.8x, fio within 11%
of runc, now with 3 repetitions on every row.

## Against the OCP run

Compared with
[run 1147](../2026-10-11-1147-ocp-4.22.17-worker2/analysis.md)
(OCP 4.22.17, virtio-fs, emptyDir in the sandbox overlay), for
plain-kata:

| | OCP 1147 | OKD this run |
|-|-|-|
| randread 4k direct | 44.6k IOPS, host page cache | 19.8k IOPS, NVMe |
| randwrite 4k direct | 42.1k IOPS, host page cache | 50.7k IOPS, NVMe |
| randwrite 4k buffered | 41.5k IOPS (0.14) | 358k IOPS (1.07) |
| seqwrite 1m direct | 3.20 GB/s, host page cache | 2.16 GB/s, NVMe |
| seqwrite 1m buffered | 1.96 GB/s | 3.05 GB/s |
| idle memory per pod | ~500 MB | ~314-324 MB |
| vCPUs online | 1-5 of 5 (hotplug) | 5 of 5 (static) |

OCP's faster rows are the host page cache and probably not durable;
on every row where both reach the same layer, OKD with block-plain
and the iothread is faster, and it costs less memory per pod. The
host OS and runc Baselines differ between these runs (see run 1147),
so this is direction, not a ratio comparison.

## Caveats

- The iothread was changed together with the OKD version, CRI-O
  (1.36.4 to 1.35.5), the host kernel (6.12.0-260 to -254) and a
  fresh cluster install. runc's unchanged 4k numbers make a host
  cause unlikely, but only an A/B on this cluster isolates it.
- That the hot-plugged emptyDir disk is attached to
  `indep_iothread_0` was not checked (it is attached over QMP, so it
  does not show in qemu-cmdline.txt).
- Wide spreads: plain-runc seqread 1m direct (1.48-2.11 GB/s),
  plain-runc seqwrite 1m buffered p99 (0.13-1.99 ms), plain-kata
  seqread 1m direct (1.29-1.62 GB/s), plain-kata and nested kata
  seqwrite 1m buffered p99 (2.1-4.0 ms, 2.0-5.9 ms), podman-kata-vfs
  build (17.5-20.2 s) and idle CPU (22.8-33.4 mcores).
- 13 other pods ran on worker2 and there are 3 repetitions; treat
  differences under about 10% as noise.
- The `prometheus-*.json` files are not analysed here.

## Next

One plain-kata run on this cluster with the two iothread lines
removed (`run.sh --setup plain-kata`) would show how much of the
change is the iothread. If it holds, add the iothread to the
`kata-block-emptydir` RuntimeClass.
