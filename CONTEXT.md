# sandboxed-containers

Lab notes on running Kata Containers on OpenShift and OKD, and on
what it costs compared with ordinary containers.

## Language

**Runtime**:
The OCI runtime a pod runs under: `runc` (a host process) or `kata`
(a lightweight VM per pod).
_Avoid_: engine, sandbox

**Baseline**:
The runc pod a kata measurement is compared against: same image,
limits, workload and node, differing only in Runtime.
_Avoid_: control, bare metal

**Nested podman**:
Podman running inside a privileged pod and starting its own
containers, under either Runtime.
_Avoid_: podman-in-podman, DinD

**Podman storage**:
Where nested podman keeps images and container layers: a driver
(overlay or vfs) on a backing (node disk or RAM). Kata cannot use
overlay on node disk, because the disk reaches the guest over
virtio-fs.
_Avoid_: graphroot, storage.conf (those are how, not what)

**Setup**:
One cell of the benchmark matrix: a Runtime, plus Podman storage
when nested podman is used. Every Setup is measured on the same node
with the same pod size.
_Avoid_: scenario, variant, case

**Run**:
One execution of the whole matrix on one node of one cluster, made up
of several Repetitions of every Setup.

**Throughput**:
How fast a workload runs, measured inside the pod (operations,
bandwidth, latency).
_Avoid_: performance (too broad)

**Footprint**:
What the node spends to run a pod, measured from the node: CPU time,
memory and disk charged to the pod, including kata's own processes.
_Avoid_: overhead (overhead is footprint kata minus footprint runc)

**OCP**:
Red Hat OpenShift Container Platform, where kata comes from the
OpenShift sandboxed containers operator. Contrast OKD, the community
distribution, where kata comes from kata-deploy.
_Avoid_: OSC, "OpenShift" on its own (ambiguous with OKD)

## Relationships

- Every kata measurement has exactly one **Baseline**
- **Nested podman** is measured under both Runtimes; its Baseline is
  a privileged runc pod

## Flagged ambiguities

- "without kata" meant a runc pod, not a process on the node.
  Resolved: the **Baseline** is always a runc pod.
- "disk performance" meant the I/O path through the storage stack
  (podman layers, virtio-fs, page caches), not the physical disk's
  speed.
