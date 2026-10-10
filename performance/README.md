# Kata vs runc benchmark

Measures what kata costs compared with runc on one node: Throughput
inside the pod and Footprint on the node. Terms are defined in
[CONTEXT.md](../CONTEXT.md). Needs `oc` logged in as cluster admin,
`jq` and `awk`; runs on macOS bash 3.2.

## Usage

```
performance/bench/run.sh [--node NAME] [--smoke] [--setup NAME]
```

- `--node` pins every pod to one node (default
  `worker2.okd4.example.com`).
- `--smoke` does one repetition with short durations and writes to a
  temp dir instead of `results/`. Without `--setup` it runs only
  plain-kata.
- `--setup` restricts the run to one Setup.

A full run does 3 repetitions of every Setup and writes
`results/<date>-<flavour>-<version>-<node>/` with `environment.json`,
`raw/<setup>/<workload>/r<N>/` and `summary.csv`. It does not commit;
the end of the run prints the `git add` and `git commit` command.
`bench/summarize.sh <results-dir>` rebuilds `summary.csv` from `raw/`,
and `bench/test-summarize.sh` checks it against `bench/testdata/`.

The `kata-bench` namespace is created by the run and left in place.
Each workload runs in a fresh pod (4 CPU, 4Gi, Guaranteed) that is
deleted afterwards. A failure is written to `error.txt` in the raw
directory and the run continues. The scheduler places the pods, so
RuntimeClass overhead is accounted for.

## Setups

| Setup | Runtime | Privileged | Podman storage |
|---|---|---|---|
| plain-runc | runc | no | none |
| plain-kata | kata | no | none |
| podman-runc-overlay-disk | runc | yes | overlay on disk |
| podman-runc-vfs-disk | runc | yes | vfs on disk |
| podman-kata-vfs-disk | kata | yes | vfs on disk |
| podman-runc-overlay-ram | runc | yes | overlay in RAM |
| podman-kata-overlay-ram | kata | yes | overlay in RAM |

Plain Setups run stress-ng and fio in the pod, on an emptyDir at
`/bench`. Podman Setups run podman-ops, then stress-ng and fio in
nested containers; fio writes into the nested container's own rootfs.
All pods use the podman image as the Setup's base, run as root and are
admitted through the privileged SCC; only podman Setups are privileged
containers. fio comes from `dnf install` (the openeuler fio image
crashes with SIGILL on some CPUs), run before the first Footprint
snapshot in plain pods and in an untimed image build in podman pods.
The probe pod reads the node's cgroups through a read-only hostPath.
Baselines: plain-kata against plain-runc, podman-kata-vfs-disk against
podman-runc-vfs-disk, podman-kata-overlay-ram against
podman-runc-overlay-ram.

## summary.csv

One row per Setup, workload and metric, sorted in that order.

| Column | Meaning |
|---|---|
| setup, workload, metric | what was measured |
| unit, better | unit, and whether higher or lower is better |
| n | repetitions that produced a value |
| median, min, max | over those repetitions, `failed` when n is 0 |
| baseline | the Baseline's median, kata Setups only |
| ratio | median divided by baseline, 4 decimals |

Metrics:

- stress-ng: `cpu_bogo_ops_s`, `matrix_bogo_ops_s`,
  `stream_bogo_ops_s` (bogo-ops per second, real time)
- fio, per job `<pattern>-<direct|buffered>`: `_iops`, `_bw`
  (bytes/s), `_clat_p99` (ns)
- podman-ops: `pull_stress_ng_s`, `pull_podman_s`, `build_s`,
  `run_rm_mean_s`
- Footprint, every workload: `idle_cpu_mcores`, `idle_mem_bytes`,
  `cpu_s`, `mem_peak_bytes`, `disk_bytes`

The pull timings go over the internet and are noisy; compare the
build and run timings instead. fio with O_DIRECT can be refused on
virtio-fs; the stderr is kept in `error-<job>.txt`.
Prometheus range queries for each pod are saved as
`prometheus-*.json` and are not part of `summary.csv`.
