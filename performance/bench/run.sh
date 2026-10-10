#!/usr/bin/env bash
# Runs the kata vs runc benchmark matrix on one node and writes raw
# results plus summary.csv. See ../README.md.
set -euo pipefail
export LC_ALL=C # awk must not use a comma decimal separator

NS=kata-bench
STRESS_IMG=ghcr.io/colinianking/stress-ng:72a9d0cae0f420a887991d4024d3101c4af7a4fc@sha256:2ea9a7c3828eda1b1ca3d0b0c5a669ec252f9caf97a6a33aedcea6b2a66d1cbe
PODMAN_IMG=quay.io/podman/stable:v5.8.7@sha256:74a13ba41b840e83926aa41017fe855c921bf466868f3464a85fc4af5c62503f
FIO_IMG=ghcr.io/smuda/sandboxed-containers/fio:sha-d9f926a8e8b16637c311215fbd6df8505e4ac173@sha256:611749d5b0ebdc0b6684ce4e016d35945bf34625b93585e38d0fe8eb5a4a35d8
SETUPS=(plain-runc plain-kata podman-runc-overlay-disk podman-runc-vfs-disk
  podman-kata-vfs-disk podman-runc-overlay-ram podman-kata-overlay-ram)

HERE=$(cd "$(dirname "$0")" && pwd)
NODE=worker2.okd4.example.com
SMOKE=false
ONLY=

usage() {
  cat <<USAGE
Usage: run.sh [--node NAME] [--smoke] [--setup NAME]

  --node NAME   node to pin all pods to (default $NODE)
  --smoke       1 repetition, short durations, output to a temp dir;
                runs only plain-kata unless --setup is given
  --setup NAME  run one Setup only: ${SETUPS[*]}
USAGE
}

ts() { date "+%Y-%m-%d %H:%M:%S"; }
die() { echo "$(ts) error: $*" >&2; exit 1; }
warn() { echo "$(ts) warn: $*" >&2; }
k() { oc -n "$NS" "$@"; }
px() { k exec bench-probe -- "$@"; }
pexec() { k exec "$1" -- timeout 900 sh -c "$2"; }

while [ $# -gt 0 ]; do
  case $1 in
    --node) NODE=${2:?--node needs a value}; shift 2 ;;
    --smoke) SMOKE=true; shift ;;
    --setup) ONLY=${2:?--setup needs a value}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if $SMOKE; then
  STRESS_SECS=5 FIO_RUNTIME=5 FIO_RAMP=1 FIO_SIZE=64m RUNS=3 IDLE=5 REPS=1
  [ -n "$ONLY" ] || ONLY=plain-kata
else
  STRESS_SECS=60 FIO_RUNTIME=60 FIO_RAMP=10 FIO_SIZE=1g RUNS=20 IDLE=30 REPS=3
fi
if [ -n "$ONLY" ]; then
  found=false
  for s in "${SETUPS[@]}"; do
    if [ "$s" = "$ONLY" ]; then found=true; fi
  done
  $found || die "unknown setup $ONLY"
fi

# Kubernetes quantity (500m, 4Gi, 16254884Ki) -> number of cores/bytes.
qty() {
  awk -v q="$1" 'BEGIN {
    f["m"] = .001; f["Ki"] = 1024; f["Mi"] = 1048576; f["Gi"] = 1073741824
    f["k"] = 1000; f["M"] = 1e6; f["G"] = 1e9; f[""] = 1
    u = match(q, /[A-Za-z]+$/) ? substr(q, RSTART) : ""
    printf "%.3f", (u == "" ? q : substr(q, 1, RSTART - 1)) * f[u]
  }'
}
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

# --- preflight ---
oc whoami >/dev/null 2>&1 || die "oc is not logged in"
ready=$(oc get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[ "$ready" = True ] || die "node $NODE does not exist or is not Ready"
rc_json=$(oc get runtimeclass kata -o json 2>/dev/null) || die "RuntimeClass kata not found"
overhead_mem=$(jq -r '.overhead.podFixed.memory // "0"' <<<"$rc_json")
alloc=$(oc get node "$NODE" -o json | jq -r '.status.allocatable | .cpu, .memory')
alloc_cpu=$(qty "$(sed -n 1p <<<"$alloc")")
alloc_mem=$(qty "$(sed -n 2p <<<"$alloc")")
need_mem=$(awk -v a="$(qty 4Gi)" -v b="$(qty "$overhead_mem")" 'BEGIN { printf "%.0f", a + b }')
ge "$alloc_cpu" 4.25 || die "node allocatable cpu $alloc_cpu < 4.25"
ge "$alloc_mem" "$need_mem" || die "node allocatable memory $alloc_mem < $need_mem (4Gi + kata overhead)"
NODE_LABEL=$(oc get node "$NODE" -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}')
[ -n "$NODE_LABEL" ] || die "node $NODE has no kubernetes.io/hostname label"
left=$(oc -n "$NS" get pods -o name 2>/dev/null | grep '^pod/bench-' || true)
[ -z "$left" ] || die "pods already exist in $NS, delete them first: oc -n $NS delete pod $(tr '\n' ' ' <<<"$left" | sed 's|pod/||g')"
noisy=$(oc get pods -A --field-selector "spec.nodeName=$NODE,status.phase=Running" -o json |
  jq -r --arg ns "$NS" '.items[] | select(.metadata.namespace != $ns)
    | select(([.metadata.ownerReferences[]?.kind] | index("DaemonSet")) | not)
    | select(.metadata.annotations["kubernetes.io/config.mirror"] | not)
    | .metadata.namespace + "/" + .metadata.name' | wc -l | tr -d ' ')
[ "$noisy" -eq 0 ] || warn "$noisy non-DaemonSet pods are running on $NODE; results may be noisy"

version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
case $version in
  *okd*) flavour=okd name=$version ;;
  *) flavour=ocp name=ocp-$version ;;
esac
if $SMOKE; then
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/kata-bench-smoke.XXXXXX")
else
  OUT=$HERE/../results/$(date +%Y-%m-%d-%H%M)-$name-${NODE%%.*}
  [ ! -e "$OUT" ] || die "$OUT already exists"
  mkdir -p "$OUT"
fi
mkdir -p "$OUT/raw"
OUT=$(cd "$OUT" && pwd)

# --- namespace and probe ---
cleanup() {
  local p
  for p in $(oc -n "$NS" get pods -o name 2>/dev/null | grep '^pod/bench-' || true); do
    oc -n "$NS" delete "$p" --wait=false >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

oc apply -f "$HERE/manifests/namespace.yaml" >/dev/null

oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: bench-probe
  namespace: $NS
  annotations:
    openshift.io/required-scc: privileged
spec:
  serviceAccountName: bench
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  activeDeadlineSeconds: 43200
  nodeSelector:
    kubernetes.io/hostname: "$NODE_LABEL"
  containers:
    - name: bench
      image: $PODMAN_IMG
      command: ["sleep", "infinity"]
      # Privileged for SELinux: an unprivileged container cannot read other
      # pods' emptyDirs under /var/lib/kubelet (du fails, disk_bytes would be 0).
      # recursiveReadOnly is refused for hostPath / (CRI-O makes it rslave).
      securityContext:
        privileged: true
        runAsUser: 0
      resources:
        requests: {cpu: 10m, memory: 32Mi}
      volumeMounts:
        - {name: host, mountPath: /host, readOnly: true}
  volumes:
    - name: host
      hostPath: {path: /}
EOF
k wait --for=condition=Ready pod/bench-probe --timeout=300s >/dev/null || die "bench-probe not Ready"
px test -e /host/dev/kvm || die "/dev/kvm missing on $NODE"

# --- environment.json ---
{
  read -r cpu_model
  read -r cpus
  read -r mem_kib
} < <(px sh -c 'sed -n "s/^model name[^:]*: //p" /host/proc/cpuinfo | head -n1
  grep -c ^processor /host/proc/cpuinfo
  sed -n "s/^MemTotal: *\([0-9]*\) kB/\1/p" /host/proc/meminfo')

disks=$(px sh -c 'for d in /host/sys/block/*; do n=${d##*/}
  case $n in loop* | ram* | zram* | dm-* | nbd*) continue ;; esac
  printf "%s\t%s\t%s\t%s\n" "$n" "$(cat $d/device/model 2>/dev/null)" "$(cat $d/queue/rotational)" "$(cat $d/size)"
done' | jq -Rn '[inputs | split("\t") | {name: .[0], model: (.[1] | sub(" +$"; "")),
  rotational: (.[2] == "1"), size_bytes: (.[3] | tonumber * 512)}]')

# find exits 1 for kata dirs that don't exist, so the script ends with
# true; any failure left is the exec itself.
cfg_raw=$(px sh -c "find /host/opt/kata /host/usr/share/kata-containers /host/etc/kata-containers \\
  -name 'configuration*.toml' -exec grep -H -E \\
  '^(sandbox_cgroup_only|static_sandbox_resource_mgmt|shared_fs|virtio_fs_cache|default_vcpus|default_memory)[[:space:]]*=' {} + 2>/dev/null; true") ||
  warn "could not read kata config files from $NODE; kata.config will be empty"
kata_cfg=$(jq -Rn '[inputs | capture("^(?<p>[^:]+):(?<k>[a-z_]+)[ \t]*=[ \t]*(?<v>.*)$")]
    | group_by(.p)
    | map({key: (.[0].p | ltrimstr("/host")),
           value: ({sandbox_cgroup_only: null, static_sandbox_resource_mgmt: null, shared_fs: null,
                    virtio_fs_cache: null, default_vcpus: null, default_memory: null}
                   + (map({key: .k, value: (.v | gsub("^\"|\"$"; ""))}) | from_entries))})
    | from_entries' <<<"$cfg_raw")
# Without sandbox_cgroup_only the kata processes sit outside the pod
# cgroup and Footprint misses them.
for f in $(jq -r 'to_entries[] | select(.value.sandbox_cgroup_only == "false") | .key' <<<"$kata_cfg"); do
  warn "sandbox_cgroup_only = false in $f; Footprint will miss kata processes"
done

ds_images=$(oc -n kata-deploy get ds -o json 2>/dev/null |
  jq '[.items[].spec.template.spec | (.containers + (.initContainers // []))[].image]' || true)
csv=$(oc get csv -A -o json 2>/dev/null |
  jq -r '[.items[] | select(.metadata.name | startswith("sandboxed-containers-operator"))][0].metadata.name // empty' || true)

jq -n --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg flavour "$flavour" --arg version "$version" \
  --arg node "$NODE" --arg cpu_model "$cpu_model" --argjson cpus "$cpus" --argjson mem "$mem_kib" \
  --argjson ni "$(oc get node "$NODE" -o json | jq .status.nodeInfo)" --argjson disks "$disks" \
  --argjson rc "$rc_json" --argjson ds "${ds_images:-[]}" --arg csv "$csv" --argjson cfg "$kata_cfg" \
  --arg stress "$STRESS_IMG" --arg podman "$PODMAN_IMG" --arg fio "$FIO_IMG" \
  --argjson stress_secs "$STRESS_SECS" --argjson fio_runtime "$FIO_RUNTIME" --argjson fio_ramp "$FIO_RAMP" \
  --arg fio_size "$FIO_SIZE" --argjson runs "$RUNS" --argjson idle "$IDLE" --argjson reps "$REPS" \
  '{date: $date, cluster: {flavour: $flavour, version: $version},
    node: {name: $node, cpu_model: $cpu_model, cpus: $cpus, mem_total_kib: $mem,
           kernel: $ni.kernelVersion, os_image: $ni.osImage,
           container_runtime: $ni.containerRuntimeVersion, disks: $disks},
    kata: {handler: $rc.handler, overhead: ($rc.overhead.podFixed // {}), daemonset_images: $ds,
           csv: (if $csv == "" then null else $csv end), config: $cfg},
    pod: {cpu: "4", memory: "4Gi"},
    images: {stress_ng: $stress, podman: $podman, fio: $fio},
    durations: {stress_secs: $stress_secs, fio_runtime: $fio_runtime, fio_ramp: $fio_ramp,
                fio_size: $fio_size, podman_runs: $runs, idle_wait: $idle},
    repetitions: $reps}' >"$OUT/environment.json"

# --- pods ---
# Sets RC, PRIV, MED and DRV for a Setup.
setup_attrs() {
  RC= PRIV=false MED= DRV=
  case $1 in
    plain-runc) ;;
    plain-kata) RC=kata ;;
    podman-runc-overlay-disk) PRIV=true DRV=overlay ;;
    podman-runc-vfs-disk) PRIV=true DRV=vfs ;;
    podman-kata-vfs-disk) RC=kata PRIV=true DRV=vfs ;;
    podman-runc-overlay-ram) PRIV=true DRV=overlay MED="medium: Memory, " ;;
    podman-kata-overlay-ram) RC=kata PRIV=true DRV=overlay MED="medium: Memory, " ;;
  esac
}

pod_yaml() { # name image
  local mnt=/bench size=3Gi
  if $PRIV; then mnt=/var/lib/containers; fi
  # vfs keeps a full copy of every layer; 3Gi gets the pod evicted.
  if $PRIV && [ -z "$MED" ]; then size=12Gi; fi
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $NS
  annotations:
    openshift.io/required-scc: privileged
spec:
  serviceAccountName: bench
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  activeDeadlineSeconds: 7200
  # nodeName would skip the scheduler, which applies the RuntimeClass overhead.
  nodeSelector:
    kubernetes.io/hostname: "$NODE_LABEL"
EOF
  if [ -n "$RC" ]; then echo "  runtimeClassName: $RC"; fi
  cat <<EOF
  containers:
    - name: bench
      image: $2
      command: ["sleep", "infinity"]
      resources:
        requests: {cpu: "4", memory: 4Gi}
        limits: {cpu: "4", memory: 4Gi}
      securityContext:
        runAsUser: 0
        privileged: $PRIV
      volumeMounts:
        - {name: data, mountPath: $mnt}
EOF
  if $PRIV; then
    echo "        - {name: storage-conf, mountPath: /etc/containers/storage.conf, subPath: storage.conf}"
  fi
  cat <<EOF
  volumes:
    - name: data
      emptyDir: {${MED}sizeLimit: $size}
EOF
  if $PRIV; then
    cat <<EOF
    - name: storage-conf
      configMap:
        name: storage-$DRV
EOF
  fi
}

# --- Footprint ---
snapshot() { # pod -> one JSON line, read from the node via the probe
  local uid out
  uid=$(k get pod "$1" -o jsonpath='{.metadata.uid}') || return 1
  out=$(px sh -c '
    u=$(echo "$1" | tr - _)
    d=$(find /host/sys/fs/cgroup/kubepods.slice -maxdepth 3 -type d -name "*pod${u}.slice" | head -n1)
    [ -n "$d" ] || { echo "no cgroup for pod $1" >&2; exit 1; }
    cpu=$(sed -n "s/^usage_usec //p" "$d/cpu.stat")
    cur=$(cat "$d/memory.current")
    peak=$(cat "$d/memory.peak" 2>/dev/null || echo 0)
    disk=$(du -sb "/host/var/lib/kubelet/pods/$1/volumes/kubernetes.io~empty-dir/" 2>/dev/null | cut -f1)
    printf "{\"t\":%s,\"cpu_usec\":%s,\"mem_current\":%s,\"mem_peak\":%s,\"disk_bytes\":%s}\n" \
      "$(date +%s.%N)" "$cpu" "$cur" "$peak" "$disk"
  ' _ "$uid") || return 1
  jq -e 'all(.[]; type == "number")' >/dev/null <<<"$out" || { echo "non-numeric snapshot for $1: $out" >&2; return 1; }
  echo "$out"
}

prom() { # pod start end dir
  local n q a b
  a=$(printf '%.0f' "$2") b=$(printf '%.0f' "$3")
  for n in cpu mem mem-by-container; do
    case $n in
      cpu) q="sum(rate(container_cpu_usage_seconds_total{namespace=\"$NS\",pod=\"$1\",container=\"\"}[1m]))" ;;
      mem) q="container_memory_working_set_bytes{namespace=\"$NS\",pod=\"$1\",container=\"\"}" ;;
      *) q="sum by (container) (container_memory_working_set_bytes{namespace=\"$NS\",pod=\"$1\",container!=\"\"})" ;;
    esac
    oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- promtool query range -o json \
      --start="$a" --end="$b" --step=15s http://localhost:9090 "$q" >"$4/prometheus-$n.json" 2>/dev/null ||
      { warn "prometheus query $n failed for $1"; rm -f "$4/prometheus-$n.json"; }
  done
}

# --- workloads: each takes pod and raw dir, records failures in error.txt ---
wl_stress_ng() {
  local s cmd
  for s in cpu matrix stream; do
    cmd="stress-ng --$s 4 --timeout ${STRESS_SECS}s --metrics --yaml /tmp/$s.yaml >/dev/null 2>&1; cat /tmp/$s.yaml"
    if $PRIV; then cmd="podman run --rm --network none --entrypoint sh $STRESS_IMG -c '$cmd'"; fi
    pexec "$1" "$cmd" >"$2/stress-$s.yaml" 2>>"$2/error.txt" || echo "stress-ng $s failed" >>"$2/error.txt"
  done
}

wl_fio() {
  local pat mode job rw bs flags dir cmd
  dir=/bench
  if $PRIV; then dir=/fio-test; fi
  for pat in randread-4k randwrite-4k seqread-1m seqwrite-1m; do
    case $pat in
      randread-4k) rw=randread bs=4k ;;
      randwrite-4k) rw=randwrite bs=4k ;;
      seqread-1m) rw=read bs=1m ;;
      seqwrite-1m) rw=write bs=1m ;;
    esac
    for mode in direct buffered; do
      job=$pat-$mode
      if [ $mode = direct ]; then flags=--direct=1; else flags="--direct=0 --end_fsync=1"; fi
      cmd="fio --name=$job --rw=$rw --bs=$bs --ioengine=psync --numjobs=1 --size=$FIO_SIZE --time_based --runtime=$FIO_RUNTIME --ramp_time=$FIO_RAMP --filename=$dir/fio.dat $flags --output-format=json"
      # Nested: fio writes into the nested container's own rootfs.
      if $PRIV; then cmd="podman run --rm --network none --entrypoint sh $FIO_IMG -c 'mkdir -p $dir && $cmd'"; fi
      # O_DIRECT can be refused (e.g. virtio-fs); keep stderr and move on.
      if pexec "$1" "$cmd" >"$2/fio-$job.json" 2>"$2/error-$job.txt"; then
        rm -f "$2/error-$job.txt"
      else
        rm -f "$2/fio-$job.json"
      fi
    done
  done
}

wl_podman_ops() {
  local script out
  IFS= read -r -d '' script <<EOF || true
set -e
t() { date +%s.%N; }
a=\$(t); podman pull -q $STRESS_IMG >/dev/null; b=\$(t); echo pull_stress_ng_s \$a \$b
a=\$(t); podman pull -q $PODMAN_IMG >/dev/null; b=\$(t); echo pull_podman_s \$a \$b
cat > /tmp/Containerfile <<'CF'
FROM $STRESS_IMG
RUN dd if=/dev/zero of=/big bs=1M count=512 status=none
RUN mkdir /small && i=0; while [ \$i -lt 5000 ]; do echo \$i > /small/f\$i; i=\$((i+1)); done
RUN rm /big
CF
a=\$(t); podman build -q -t bench-build -f /tmp/Containerfile /tmp >/dev/null; b=\$(t); echo build_s \$a \$b
i=0; a=\$(t)
while [ \$i -lt $RUNS ]; do podman run --rm --network none --entrypoint true $STRESS_IMG; i=\$((i+1)); done
b=\$(t); echo run_rm_mean_s \$a \$b
EOF
  out=$(pexec "$1" "$script" 2>>"$2/error.txt") || { echo "podman-ops failed" >>"$2/error.txt"; return 0; }
  awk -v runs="$RUNS" 'NF == 3 { v = $3 - $2; if ($1 == "run_rm_mean_s") v /= runs; printf "%s %.3f\n", $1, v }' <<<"$out" |
    jq -Rn '[inputs | split(" ") | {key: .[0], value: (.[1] | tonumber)}] | from_entries' >"$2/timings.json"
}

# Untimed setup step; podman chatter on stderr only matters on failure.
prep() { # pod cmd dir
  local out
  out=$(pexec "$1" "$2" 2>&1) || { echo "$out" >>"$3/error.txt"; return 1; }
}

measure() { # pod workload dir
  local pod=$1 wl=$2 dir=$3 s0 s1 s2 s3
  s0=$(snapshot "$pod") || return 1
  sleep "$IDLE"
  s1=$(snapshot "$pod") || return 1
  if $PRIV && [ "$wl" = stress-ng ]; then # untimed, before s2
    prep "$pod" "podman pull -q $STRESS_IMG" "$dir" || return 1
  elif $PRIV && [ "$wl" = fio ]; then
    prep "$pod" "podman pull -q $FIO_IMG" "$dir" || return 1
  fi
  s2=$(snapshot "$pod") || return 1
  "wl_${wl//-/_}" "$pod" "$dir"
  s3=$(snapshot "$pod") || return 1
  jq -n --argjson s0 "$s0" --argjson s1 "$s1" --argjson s2 "$s2" --argjson s3 "$s3" \
    '{s0: $s0, s1: $s1, s2: $s2, s3: $s3}' >"$dir/footprint.json"
  prom "$pod" "$(jq .t <<<"$s2")" "$(jq .t <<<"$s3")" "$dir"
}

rmpod() { # waits until the pod is gone, so the next one never overlaps it
  k delete pod "$1" --ignore-not-found --wait=false >/dev/null 2>&1
  k wait --for=delete "pod/$1" --timeout=300s >/dev/null 2>&1
}

run_one() { # setup workload rep
  local setup=$1 wl=$2 rep=$3 pod dir image
  setup_attrs "$setup"
  pod=bench-$setup-${wl/stress-ng/stressng}-r$rep
  dir=$OUT/raw/$setup/$wl/r$rep
  mkdir -p "$dir"
  N=$((N + 1))
  echo "$(ts) [$N/$TOTAL] == $pod" >&2
  image=$PODMAN_IMG
  if [ "$wl" = stress-ng ] && ! $PRIV; then image=$STRESS_IMG; fi
  if [ "$wl" = fio ] && ! $PRIV; then image=$FIO_IMG; fi
  pod_yaml "$pod" "$image" >"$dir/pod.yaml"
  rmpod "$pod" || warn "could not clear old $pod"
  if k apply -f "$dir/pod.yaml" >/dev/null 2>>"$dir/error.txt" &&
    k wait --for=condition=Ready "pod/$pod" --timeout=300s >/dev/null 2>>"$dir/error.txt"; then
    measure "$pod" "$wl" "$dir" || echo "$wl failed" >>"$dir/error.txt"
  else
    echo "pod $pod not Ready" >>"$dir/error.txt"
  fi
  rmpod "$pod" || warn "could not delete $pod"
  [ -s "$dir/error.txt" ] || rm -f "$dir/error.txt"
  if ls "$dir"/error*.txt >/dev/null 2>&1; then warn "FAILED $pod: see $dir/error*.txt"; fi
}

wls_for() { if $PRIV; then echo "podman-ops stress-ng fio"; else echo "stress-ng fio"; fi; }

N=0 TOTAL=0
for setup in "${SETUPS[@]}"; do
  if [ -n "$ONLY" ] && [ "$setup" != "$ONLY" ]; then continue; fi
  setup_attrs "$setup"
  set -- $(wls_for)
  TOTAL=$((TOTAL + $# * REPS))
done

for rep in $(seq 1 "$REPS"); do
  for setup in "${SETUPS[@]}"; do
    if [ -n "$ONLY" ] && [ "$setup" != "$ONLY" ]; then continue; fi
    setup_attrs "$setup"
    for wl in $(wls_for); do run_one "$setup" "$wl" "$rep"; done
  done
done

"$HERE/summarize.sh" "$OUT"
echo "$(ts) results: $OUT"
if ! $SMOKE; then
  echo "commit with: git add \"$OUT\" && git commit -m \"test: add kata benchmark run $(basename "$OUT")\""
fi
