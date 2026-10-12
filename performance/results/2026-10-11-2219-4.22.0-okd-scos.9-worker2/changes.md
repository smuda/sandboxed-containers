# Changes since run 2026-10-10-1823

What differs from
[2026-10-10-1823-5.0.0-okd-scos.1-worker2](../2026-10-10-1823-5.0.0-okd-scos.1-worker2/analysis.md).

## Benchmark scripts

- `disk_bytes` also counts the sandbox container's overlay
  `diff/local`, where OCP keeps disk emptyDirs. On OKD that directory
  holds nothing, so the values are comparable with run 1823.
- The run directory has a `config/` directory: helm values, the
  effective kata toml and `50-user-overrides.toml` drop-in, CRI-O
  drop-ins, RuntimeClasses, the qemu command line and the host OS.

## Cluster

- Freshly reinstalled cluster on OKD 4.22.0-okd-scos.9 (was
  5.0.0-okd-scos.1). Same worker2 hardware, kata-deploy 4.2.0 chart,
  guest kernel 6.18.35.

  | | run 1823 | this run |
  |-|-|-|
  | OKD | 5.0.0-okd-scos.1 | 4.22.0-okd-scos.9 |
  | CRI-O | 1.36.4 | 1.35.5 |
  | host kernel | 6.12.0-260.el10 | 6.12.0-254.el10 |
  | CoreOS image | 10.0.20260819-0 | 10.0.20260806-0 |

- environment.json lists a USB stick on worker2 (U3 Cruzer Micro,
  `sda` and `sr0`), most likely the install medium. Not in the data
  path.
- run.sh warned about 13 non-DaemonSet pods on worker2.
- kata-deploy is helm revision 1, installed with
  [05-shim-block-plain-values.yaml](config/05-shim-block-plain-values.yaml)
  on top of [04-kata-deploy-values.yaml](config/04-kata-deploy-values.yaml).
  The RuntimeClass `kata`, which run.sh uses, gets this drop-in in
  `config.d/50-user-overrides.toml`; the two iothread lines are new:

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

  - `enable_iothreads = true`, `indep_iothreads = 1`: qemu starts one
    dedicated iothread (`-object iothread,id=indep_iothread_0` in
    [qemu-cmdline.txt](config/qemu-cmdline.txt)) for hot-plugged
    virtio-blk devices, so their I/O is no longer handled in qemu's
    main loop. The emptyDir disk is attached over QMP after boot;
    that it uses the iothread was not checked.
- The opt-in RuntimeClass `kata-block-emptydir` now exists from the
  04 values (block-plain without iothread). It was not used in this
  run.
