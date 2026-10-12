# Analysis: OpenShift sandboxed containers vs kata-deploy

Run `2026-10-11-1147-ocp-4.22.17-worker2`: OCP 4.22.17, OpenShift
sandboxed containers 1.13.1, handler `kata`, same worker2
hardware (i7-10710U, 12 CPUs, 62 GiB, KINGSTON SKC3000 NVMe), pods
4 CPU / 4Gi Guaranteed, 3 repetitions, no failed rows. It is compared
with [run 0635](../2026-10-10-0635-5.0.0-okd-scos.1-worker2/analysis.md)
(OKD 5.0.0-okd-scos.1, kata-deploy 4.2.0, `kata-qemu-runtime-rs`,
virtio-fs). Ratios are kata median / runc Baseline median from each
run's `summary.csv`; "OCP/OKD" is the absolute median of this run
over run 0635.

The question: did Red Hat optimise kata in its OCP packaging?

## Summary

No broad optimisation is visible. Where the two stacks share a data
path, OCP is the same or slightly slower; where it is faster, the
numbers point at a different emptyDir path rather than a faster kata.

- CPU and memory bandwidth run at native speed on both, once the
  guest has all its vCPUs. In 4 of 9 kata stress-ng pods it did not
  (see below), which halved CPU throughput in those pods.
- Small virtio-fs I/O is 13-24% slower in absolute terms on OCP
  (about 8-13 µs more per 4k operation); the kata/runc ratios are
  the same or worse.
- Large sequential writes to a disk emptyDir are 2.7-3.6x faster on
  OCP, and kata "direct" writes now beat the device (3.2 GB/s against
  runc's 2.6 GB/s O_DIRECT). That is page cache, not the NVMe: the
  OCP emptyDir lives in the sandbox overlay, not in the kubelet
  directory. It looks like a different durability trade, not an
  optimisation.
- Nested podman on vfs is about 5-10% slower; on RAM it is unchanged.
- Each idle kata pod costs about 500 MB on OCP against 267 MB, and
  slightly less idle CPU (about 3 against 4 mcores).

## Configuration differences

| | OKD run 0635 | OCP this run |
|-|-|-|
| kata runtime | kata-deploy 4.2.0, runtime-rs | OCP 1.13.1, Go runtime 3.31.0 |
| guest kernel | 6.18.35 | 5.14.0-687.53.1.el9_8 |
| host kernel | 6.12.0-260.el10 (CS10) | 5.14.0-687.53.1.el9_8 (RHEL 9.8) |
| CRI-O | 1.36.4 | 1.35.9 |
| `static_sandbox_resource_mgmt` | true | false (hotplug) |
| guest RAM seen by stress-ng | 4.16 GB | 6.28 GB |
| RuntimeClass memory overhead | 320Mi | 350Mi |
| disk emptyDir | kubelet dir over virtio-fs | sandbox overlay `diff/local` over virtio-fs |
| `shared_fs`, `virtio_fs_cache` | virtio-fs, auto | virtio-fs, auto |

The kernels, CRI-O, the RuntimeClass overhead, the guest RAM and
`static_sandbox_resource_mgmt` are from `environment.json` and the
stress-ng system info. The runtime versions and
`disable_guest_empty_dir = false` are not recorded in
`environment.json` and come from inspecting the node. Every
difference in this table changed at once, so none of the results
below can be attributed to one of them with certainty.

## Host confounder: runc moved too

The runc Baselines ran on the same hardware but a different host OS,
and some of them moved a lot:

| runc metric (plain-runc) | OKD | OCP | OCP/OKD |
|-|-|-|-|
| stress-ng cpu ops/s | 6834 | 6627 | 0.97 |
| stress-ng matrix ops/s | 14642 | 13911 | 0.95 |
| stream read MB/s | 5023 | 4509 | 0.90 |
| fio seqwrite 1m buffered | 5.42 GB/s | 1.33 GB/s | 0.25 |
| fio seqread 1m buffered | 3.35 GB/s | 2.84 GB/s | 0.85 |
| fio 4k random, direct | 23k / 97k IOPS | 23k / 93k IOPS | 0.96-0.99 |
| fio node CPU time | 150 s | 180 s | 1.21 |

Buffered streaming writes on the RHEL 9 host are a quarter of the
CentOS Stream 10 host's speed, in all three disk runc Setups. That
alone turns kata's seqwrite-buffered ratio from 0.13 into 1.47
without kata changing. Where runc moved, compare kata's absolute
numbers, not the ratio.

## CPU and memory (stress-ng)

| kata Setup | metric | ratio OKD | ratio OCP | kata OCP/OKD |
|-|-|-|-|-|
| plain | cpu | 0.99 | 0.51 | 0.50 |
| plain | matrix | 0.98 | 0.54 | 0.53 |
| plain | stream | 0.97 | 1.00 | 0.93 |
| nested vfs disk | cpu | 0.99 | 0.96 | 0.94 |
| nested vfs disk | matrix | 0.99 | 0.95 | 0.94 |
| nested vfs disk | stream | 0.97 | 1.02 | 0.96 |
| nested overlay RAM | cpu | 1.00 | 0.98 | 0.95 |
| nested overlay RAM | matrix | 1.01 | 0.95 | 0.93 |
| nested overlay RAM | stream | 0.97 | 1.03 | 0.95 |

The medians hide a vCPU hotplug problem. The guest boots with
`default_vcpus = 1` and is meant to get 4 more by hotplug, 5 online.
stress-ng records `cpus-online`:

| kata Setup | r1 | r2 | r3 |
|-|-|-|-|
| plain | 5 | 2 | 2 |
| nested vfs disk | 3 | 5 | 5 |
| nested overlay RAM | 5 | 1 | 5 |

stress-ng started 96-107 s after guest boot, so this is not a
start-up race that resolves within seconds; the CPUs never arrived in
those pods. The four instances then share 1-3 CPUs and throughput
drops in proportion (cpu_s 359 s against 717 s for plain-kata, i.e.
2 CPUs). The plain-kata median is two short repetitions out of three,
hence 0.51. In the five repetitions with 5 CPUs online, cpu and
matrix are 0.95-1.01 of runc, the same as on OKD. Why hotplug was
incomplete is not known; the OCP node logs from the run would be the
place to start. fio and podman-ops run in separate pods that do not
record the CPU count, so whether they were affected is unknown; fio
runs one psync job and probably does not need more than one CPU.

Stream reads at 1.00-1.03 of runc on OCP against 0.97 on OKD, but
that is runc getting 10% slower on the RHEL host, not kata getting
faster (kata itself is 0.93-0.96 of its OKD speed). Run 0635
predates the fixed stream array size; the MB/s rate is comparable,
peak memory is not.

Verdict for compute: same as stock kata, plus a hotplug reliability
problem that stock kata with static sizing does not have.

## Disk: fio per job

plain-kata, on a disk emptyDir over virtio-fs:

| fio job | ratio OKD | ratio OCP | kata OKD | kata OCP | OCP/OKD |
|-|-|-|-|-|-|
| randread 4k direct | 2.29 | 1.96 | 52.6k IOPS | 44.6k IOPS | 0.85 |
| randread 4k buffered | 2.31 | 2.00 | 51.0k IOPS | 43.5k IOPS | 0.85 |
| randwrite 4k direct | 0.57 | 0.45 | 55.2k IOPS | 42.1k IOPS | 0.76 |
| randwrite 4k buffered | 0.14 | 0.14 | 47.6k IOPS | 41.5k IOPS | 0.87 |
| seqread 1m direct | 2.39 | 2.27 | 5.58 GB/s | 5.95 GB/s | 1.07 |
| seqread 1m buffered | 1.26 | 1.26 | 4.21 GB/s | 3.58 GB/s | 0.85 |
| seqwrite 1m direct | 0.35 | 1.21 | 0.88 GB/s | 3.20 GB/s | 3.63 |
| seqwrite 1m buffered | 0.13 | 1.47 | 0.72 GB/s | 1.96 GB/s | 2.72 |

podman-kata-vfs-disk (nested container rootfs on the same path)
shows the same 4k pattern: 0.77-0.86 of OKD absolute, ratios
unchanged or lower.

Small operations got slower. At queue depth 1 the 4k latencies rose
by about 8-13 µs per operation (randread p99 30 to 40 µs, randwrite
direct p99 30 to 43 µs), while runc's 4k numbers stayed within 4%.
That is the virtio-fs round trip, and on OCP it costs more. Which
part (Go runtime, qemu, virtiofsd, guest kernel 5.14 FUSE) cannot be
told from this data.

Reads are still the node page cache, as in run 0635: kata "direct"
4k reads at 44k IOPS against runc's device-bound 23k. Nothing changed
there except the per-op cost.

Large writes got much faster, and this is the one place OCP looks
better. But kata's O_DIRECT sequential writes (3.20 GB/s) exceed
runc's O_DIRECT to the NVMe (2.64 GB/s), so they do not reach the
device; they end in the host page cache. On OCP the emptyDir is a
directory in the sandbox container's overlay upper layer
(`diff/local/<vol>`). If that overlay is mounted volatile, as seen on
the node, fsync and syncfs are no-ops there, and fio's `end_fsync`
on the buffered jobs, like any fsync a workload issues, returns
without making data durable. The large-write gain is consistent with
that path, or with a larger FUSE request size in the guest kernel,
but not with a faster transport, since small writes got slower. For
an emptyDir, which does not survive the pod anyway, losing durability
matters only if the node crashes mid-job.

Nested podman on vfs: seqwrite direct fell from 5.51 to 2.74 GB/s
(p99 0.2 ms to 6.8 ms, wide spread) and buffered from 2.67 to
1.96 GB/s. On OKD nested writes were unexplainedly faster than plain;
on OCP nested and plain agree (about 2-3 GB/s and 1.96 GB/s), which
fits both landing on the same overlay path.

Overlay on RAM (tmpfs in the guest, no virtio-fs): kata is 0.82-0.97
of its OKD speed, ratios 0.87-1.14 against 0.97-1.12 on OKD. runc
lost 3-16% on the same jobs, so most of this is host or guest kernel,
not kata.

## Nested podman (podman-ops)

| podman-ops | kata OKD | kata OCP | ratio OKD | ratio OCP |
|-|-|-|-|-|
| vfs disk: build | 53.5 s | 58.9 s | 4.15 | 4.54 |
| vfs disk: run --rm per container | 2.50 s | 2.62 s | 5.04 | 5.74 |
| vfs disk: node CPU time | 409 s | 431 s | 9.0 | 9.6 |
| overlay RAM: build | 12.6 s | 12.5 s | 1.70 | 1.57 |
| overlay RAM: run --rm per container | 0.18 s | 0.20 s | 2.69 | 3.40 |
| overlay RAM: node CPU time | 64 s | 64 s | 2.49 | 2.43 |

The runc builds are within 1-7% between runs. kata+vfs on disk is
about 10% slower to build on OCP, in line with the slower small I/O;
the large-write gain does not help layer copies, which are many small
files. On RAM nothing changed beyond noise; the `run --rm` ratio rose
mainly because runc got faster (0.068 to 0.060 s).

Pull timings go over the internet and are not compared. Single
repetitions took 42.5 s (overlay RAM r2, others 10-11 s) and 88.9 s
(vfs disk r3, others 51-53 s).

## Footprint

| | OKD kata | OCP kata | OCP/OKD |
|-|-|-|-|
| idle memory per pod | 265-267 MB | 499-505 MB | 1.89 |
| idle CPU | 4.0-4.3 mcores | 2.8-3.0 mcores | 0.67-0.73 |
| node CPU time during fio, plain | 1147 s (7.7x runc) | 1121 s (6.2x runc) | 0.98 |
| node CPU time during fio, nested vfs | 1409 s (8.7x) | 1276 s (6.5x) | 0.91 |
| node CPU time during fio, RAM | 571 s (1.01x) | 571 s (1.01x) | 1.00 |
| fio peak memory, plain | 2.47 GB | 2.77 GB | 1.12 |

Idle memory nearly doubles: about 235 MB more per kata pod. The guest
boots with 2 GiB and gets the 4Gi limit hotplugged on top (6.28 GB
visible, against 4.16 GB with static sizing), and the RuntimeClass
reserves 350Mi instead of 320Mi. More guest RAM also means more guest
page cache, which explains the higher fio peak. The lower fio CPU
ratio is mostly runc using 21% more CPU on the RHEL host; kata's own
node CPU time is the same within 2-9%. Idle CPU is a third lower,
cause unknown (Go runtime, guest kernel or fewer active vCPUs).

stress-ng peak memory is not comparable: run 0635 predates the fixed
stream array size, and two OCP plain-kata pods had 2 CPUs.

`disk_bytes` is compared within this run only, because its method
changed after run 0635 (allocated bytes, plus the sandbox overlay's
`diff/local` on OCP). Within this run kata matches runc: 1.07 GB for
fio, 7.39 GB for nested vfs podman-ops, 0.45 GB for nested vfs fio,
consistent with the new method finding the OCP emptyDir data.

## What can be attributed to Red Hat packaging

- Hotplug sizing (`static_sandbox_resource_mgmt = false`): the
  doubled idle memory and the incomplete vCPU hotplug follow from
  this OCP default. Attributable, with the caveat that hotplug was
  not tested on kata-deploy.
- The emptyDir path in the sandbox overlay
  (`disable_guest_empty_dir = false`): an OCP default, and the most
  likely reason large writes are faster and possibly no longer
  durable. Plausible, not proven.
- Slower small virtio-fs I/O: real, but the Go runtime, qemu,
  virtiofsd and guest kernel all differ from kata-deploy and the host
  kernel differs too. Not attributable to any one of them.
- CPU and memory bandwidth: no difference to attribute.

## Caveats

- Run 0635 was one day earlier on a different cluster install and OS;
  other pods ran on worker2 in both. With 3 repetitions, treat
  differences under about 10% as noise.
- Four kata stress-ng pods had 1-3 of 5 vCPUs online; their medians
  are not CPU throughput figures. fio and podman-ops pods may have
  been affected without it being visible.
- The large spreads in this run: plain-kata seqwrite-direct p99
  (0.95-6.5 ms), podman-kata-vfs-disk seqwrite-direct (2.2-3.3 GB/s,
  p99 0.95-8.6 ms), plain-runc seqwrite-direct (1.69-2.64 GB/s), and
  the two pull outliers above.
- The runtime versions and `disable_guest_empty_dir` are not in
  `environment.json`; the volatile overlay mount was not re-checked
  during this run.
- The `prometheus-*.json` files are not analysed here.

## Next

A/B on this cluster with `disable_guest_empty_dir = true`, which
should move the emptyDir back to the kubelet directory over virtio-fs
and show how much of the large-write gain is the volatile overlay.
Pinning `static_sandbox_resource_mgmt = true` in the same pass would
remove the hotplug failures and the extra idle memory from the
comparison.
