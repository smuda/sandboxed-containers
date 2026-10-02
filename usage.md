# Using kata pods on OKD

Tests run 2026-10-02 on the lab cluster from [okd.md](okd.md), with
pod `podman-in-kata` from
[`okd/05-podman-in-kata.yaml`](okd/05-podman-in-kata.yaml) (memory
limit 2Gi) on worker2.

## 1. How much memory does a kata pod allocate?

Question: does the pod allocate the requested memory directly, or
only what is used?

Answer: the VM is sized up front, but host memory is allocated lazily
as the guest touches it, and is not given back when the guest frees
it. Host usage grows to the guest's peak and stays there until the
pod is deleted.

### Configuration

The `kata` handler runs the runtime-rs qemu shim with
`configuration-qemu-runtime-rs.toml`. Relevant settings:

```
default_memory = 2048
static_sandbox_resource_mgmt = true
enable_mem_prealloc = false
enable_hugepages = false
enable_virtio_mem = false
reclaim_guest_freed_memory = false
sandbox_cgroup_only = true
```

With `static_sandbox_resource_mgmt` the VM is sized from the pod's
limits at boot instead of hotplugging memory later. qemu starts with:

```
-m 2080M,slots=10,maxmem=64009M
-object memory-backend-file,id=entire-guest-memory-share,
  mem-path=/dev/shm,size=2080M,share=on,prealloc=off
```

`share=on` is needed for virtio-fs. `prealloc=off` means no pages are
reserved at start. Inside the guest `MemTotal` is 2000556 kB.

On the host the pod cgroup has `memory.max` 2368 MiB: the 2Gi limit
plus the RuntimeClass overhead of 320Mi.

### Measurement

Host side, on worker2:

```sh
oc debug node/worker2.okd4.example.com -q -- chroot /host sh -c '
  id=$(crictl pods --name podman-in-kata -q)
  pid=$(pgrep -f "qemu-system-x86_64 -name sandbox-$id")
  cg=/sys/fs/cgroup$(cut -d: -f3 /proc/$pid/cgroup)
  grep -E "VmRSS|RssShmem" /proc/$pid/status
  echo $(( $(cat $cg/memory.current) / 1048576 )) MiB'
```

Guest side, writing to the tmpfs `emptyDir` so the guest has to back
it with RAM, then freeing it:

```sh
oc exec -n kata-test podman-in-kata -- dd if=/dev/urandom \
  of=/var/lib/containers/memtest bs=1M count=800
oc exec -n kata-test podman-in-kata -- sh -c \
  'rm /var/lib/containers/memtest; sync
   echo 3 > /proc/sys/vm/drop_caches'
```

| Step | qemu RSS | of which shmem | cgroup `memory.current` |
|-|-|-|-|
| Idle | 326 MiB | 180 MiB | 483 MiB |
| After writing 800 MiB | 1130 MiB | 983 MiB | 1292 MiB |
| After rm and drop caches | 1130 MiB | 983 MiB | 1292 MiB |

After the rm the guest reported `MemFree` 1946920 kB, while the host
still charged 1292 MiB to the pod. With no balloon and
`reclaim_guest_freed_memory = false`, nothing tells the host the
pages are free.

### Overhead

The workload is `sleep infinity`, so nearly all idle usage is kata
overhead. Split of the idle numbers above:

| Part | MiB | Derived from |
|-|-|-|
| Guest RAM touched (guest kernel, agent, systemd) | 180 | qemu `RssShmem` |
| qemu itself (anon, binary, guest image mapping) | 146 | `VmRSS` 326 minus shmem 180 |
| Rest of the cgroup (virtiofsd x2, shim, page cache) | 157 | `memory.current` 483 minus `VmRSS` 326 |
| Total at idle | 483 | |

- Fixed overhead is about 300 MiB per pod (guest OS plus qemu), or
  about 480 MiB counting everything in the cgroup. The RuntimeClass
  declares 320Mi.
- Marginal overhead is about 1%: 800 MiB written in the guest raised
  `memory.current` by 809 MiB.
- Caveats: one pod, one sample. `memory.current` includes
  reclaimable page cache, so the 157 MiB is an upper bound. No runc
  pod was measured for comparison, and CPU overhead (250m declared)
  was not measured.

### Consequences

- Scheduling uses the limit plus overhead (2368 MiB here), not
  actual use.
- A long-running pod settles at its peak usage, not its current
  usage. Restarting the pod is the only way to release it.
- Not tested: if the guest touches all 2080M, adding the roughly
  300 MiB of non-RAM overhead gives about 2380 MiB, past the pod
  cgroup's 2368 MiB, and the host OOM killer would kill the whole VM.

## 2. How does networking work inside the pod?

Question: how does networking work inside the pod, and can
docker-compose run against a podman backend with a docker network?

Answer: yes. Compose on the podman API socket creates a netavark
bridge network inside the guest, service-name DNS works, published
ports are reachable on the pod IP from the rest of the cluster, and
egress works.

### Pod network

The guest has one virtio-net interface `eth0` with the pod IP from
OVN-Kubernetes (10.128.3.121/23), MTU 1400, default route via
10.128.2.1. `/etc/resolv.conf` points at the cluster DNS 172.30.0.10
with the usual OKD search list and `ndots:5`.

podman 5.8.7 in `quay.io/podman/stable` runs rootful with the netavark
backend and aardvark-dns. The image has no `ip`, `free` or `which`.

### docker-compose against podman

docker compose v2 is not in the image; v2.40.3 was downloaded from
the GitHub release. `/run/podman` doesn't exist in the image and must
be created before starting the API service. The service runs in the
foreground of the `oc exec`, so compose commands run in the same
exec:

```sh
oc exec -n kata-test podman-in-kata -- sh -c '
  curl -fsSL -o /usr/local/bin/docker-compose \
    https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-x86_64
  chmod +x /usr/local/bin/docker-compose
  mkdir -p /run/podman /tmp/ct && cd /tmp/ct
  cat > compose.yaml <<EOF
services:
  web:
    image: docker.io/library/nginx:alpine
    ports: ["8080:80"]
    networks: [appnet]
  client:
    image: docker.io/library/alpine:3
    command: sh -c "sleep 2; wget -qO- http://web/ | grep -o \"<title>.*</title>\""
    depends_on: [web]
    networks: [appnet]
networks:
  appnet: {}
EOF
  podman system service --time=0 unix:///run/podman/podman.sock &
  sleep 2
  export DOCKER_HOST=unix:///run/podman/podman.sock
  docker-compose up -d
  sleep 10
  docker-compose logs client
  podman network inspect ct_appnet --format \
    "{{range .Subnets}}{{.Subnet}}{{end}} dns={{.DNSEnabled}} if={{.NetworkInterface}}"
  curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/'
```

Observed (trimmed):

```
client-1  | <title>Welcome to nginx!</title>
10.89.0.0/24 dns=true if=podman1
200
```

The compose containers stay up after the exec ends (conmon keeps
them running).

### Results

| Test | Result |
|-|-|
| Compose network `appnet` | netavark bridge `podman1`, 10.89.0.0/24, DNS on |
| `web` by service name | resolves via aardvark-dns (10.89.0.1) to 10.89.0.2 |
| Container MTU | 1400, inherited from `eth0` |
| `127.0.0.1:8080` in the pod | 200 |
| `10.128.3.121:8080` from worker1 | 200 |
| Egress, glibc image (centos), `quay.io` | ok |
| Egress, any image, `quay.io.` (FQDN) | ok |
| Egress, musl image (alpine), `quay.io` | `wget: bad address 'quay.io'` |

Published ports are bound inside the guest, so other pods and nodes
reach them on the pod IP. A Service selecting the pod would expose
them the same way.

### Short-name DNS failure in alpine

The alpine failure is not caused by kata or compose. It also happens
on podman's default network. With `ndots:5`, `quay.io` is first tried
with each search domain. The lab DNS answers
`quay.io.okd4.example.com` with NOERROR and no records. glibc moves on
to the next candidate; musl treats that as final and fails. Not
checked in a plain runc pod.

Workarounds: use a trailing dot, set `dns_opt: [ndots:1]` or
`dns_search: []` on the compose service, or use a glibc-based image.
None of these were tested.

### Cleanup

```sh
oc exec -n kata-test podman-in-kata -- sh -c '
  cd /tmp/ct
  podman system service --time=0 unix:///run/podman/podman.sock &
  sleep 2
  DOCKER_HOST=unix:///run/podman/podman.sock docker-compose down
  kill %1
  rm -rf /tmp/ct /usr/local/bin/docker-compose /run/podman'
```
