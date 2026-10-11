# Changes since run 2026-10-10-0635

What differs from
[2026-10-10-0635-5.0.0-okd-scos.1-worker2](../2026-10-10-0635-5.0.0-okd-scos.1-worker2/analysis.md).

## Benchmark scripts

- stress-ng stream runs with `--stream-l3-size 64M`. stress-ng sized
  the arrays from the L3 it detected, which differs in the kata guest
  (12 MiB per instance against 9 MiB under runc). That alone produced
  the old 0.73 stream ratio. Smoke check: both runtimes now use 12288
  pages per instance.
- The stream metric is `stream_read_mb_s` (memory read rate), not
  `stream_bogo_ops_s`. The old run, re-summarised, reads 0.97.
- `disk_bytes` counts allocated blocks (`du -sk`), not apparent size
  (`du -sb`). Needed because block-plain puts a sparse image the size
  of the host filesystem (511 GB) in the emptyDir. Not comparable
  with the old run: plain-runc is unchanged (one large file), but the
  podman runc Setups read 4-9% higher, since directories and small
  files take whole blocks.

## Cluster

- During this run, at 21:21Z, a change to
  `/etc/containers/registries.conf` (not made by the benchmark) was
  rendered for all pools (rendered-worker-76682aa8). MCO drained
  worker2 and evicted podman-kata-overlay-ram fio r3, the last pod of
  the run.
- kata-deploy helm revision 3 adds a drop-in for the qemu-runtime-rs
  shim, from
  [okd/experimental/block-emptydir-values.yaml](../../../okd/experimental/block-emptydir-values.yaml),
  written to `config.d/50-user-overrides.toml`:

  ```toml
  [hypervisor.qemu]
  block_device_driver = "virtio-blk-pci"
  block_device_cache_direct = true
  block_device_aio = "native"

  [runtime]
  emptydir_mode = "block-plain"
  ```

  - `emptydir_mode = "block-plain"`: disk emptyDirs are no longer
    shared over virtio-fs. runtime-rs creates a sparse `disk.img` in
    the emptyDir, hot-plugs it and the guest mounts it as ext4.
  - `block_device_driver = "virtio-blk-pci"`: was `virtio-scsi`.
  - `block_device_cache_direct = true`: guest O_DIRECT now reaches the
    NVMe. In the old run virtiofsd dropped O_DIRECT, so kata "direct"
    rows measured the node page cache.
  - `block_device_aio = "native"`: the default `io_uring` fails the
    hotplug because SCOS sets `kernel.io_uring_disabled = 2`.

## What to expect in this run

From single 5 s smoke runs with a 64 MiB file, so direction only:

- Buffered writes: plain-kata 4k randwrite 1.19x runc (was 0.10).
- Direct I/O: kata now pays the device plus about 30 µs per 4k op at
  queue depth 1 (randread 0.60, randwrite 0.27); 1 MiB direct
  transfers about 0.88.
- Node CPU during fio: 2.8x runc (was 5.1x in the same smoke setup).
- Nested podman on vfs in kata: build 16.7 s, `run --rm` 0.49 s,
  pull 16.2 s, node CPU 80 s, close to runc vfs (old run 53.5 s,
  2.50 s, 50.2 s, 409 s).
- The nested-vs-plain fio difference in "Not explained" should go
  away: both now write to the same guest block device.
- Kata idle CPU rose from about 6 to about 100 mcores. Unverified
  guess: ext4 lazy inode-table init on the large image.

## Caveats of block-plain (kata 4.2.0 docs/Limitations.md)

- The image is sized to the whole host filesystem, and ext4 metadata
  counts toward kubelet's emptyDir usage. `sizeLimit` is still
  enforced by eviction (tested, see analysis.md).
- The data is not visible from the host.
