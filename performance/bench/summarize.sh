#!/usr/bin/env bash
# Usage: summarize.sh <results-dir>
# Reads <results-dir>/raw and writes <results-dir>/summary.csv.
set -euo pipefail
export LC_ALL=C # awk and sort must not use a comma decimal separator

R=${1:?usage: summarize.sh <results-dir>}
[ -d "$R/raw" ] || { echo "error: $R/raw not found" >&2; exit 1; }

SETUPS=(plain-runc plain-kata podman-runc-overlay-disk podman-runc-vfs-disk
  podman-kata-vfs-disk podman-runc-overlay-ram podman-kata-overlay-ram)
WLS=(podman-ops stress-ng fio)
JOBS=
for p in randread-4k randwrite-4k seqread-1m seqwrite-1m; do
  for m in direct buffered; do JOBS="$JOBS $p-$m"; done
done

# Sets U and B from the metric name.
meta() {
  case $1 in
    *_iops | *_ops_s) U=ops/s B=higher ;;
    *_bw) U=bytes/s B=higher ;;
    *_mb_s) U=MB/s B=higher ;;
    *_clat_p99) U=ns B=lower ;;
    idle_cpu_mcores) U=mcores B=lower ;;
    *_bytes) U=bytes B=lower ;;
    *) U=s B=lower ;;
  esac
}

# One tab-separated line per metric: order keys, setup, workload,
# metric, unit, better, value. An empty value declares the metric, so a
# workload with no data in any repetition still gets a "failed" row.
emit() {
  meta "$1"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$si" "$wi" "$s" "$w" "$1" "$U" "$B" "${2-}"
}

metrics_for() {
  case $1 in
    podman-ops) echo pull_stress_ng_s pull_podman_s build_s run_rm_mean_s ;;
    stress-ng) echo cpu_bogo_ops_s matrix_bogo_ops_s stream_read_mb_s ;;
    fio) for j in $JOBS; do echo "${j}_iops ${j}_bw ${j}_clat_p99"; done ;;
  esac
  echo idle_cpu_mcores idle_mem_bytes cpu_s mem_peak_bytes disk_bytes
}

collect() {
  local si=0 wi s w d r m v j st f k
  for s in "${SETUPS[@]}"; do
    si=$((si + 1)) wi=0
    for w in "${WLS[@]}"; do
      wi=$((wi + 1))
      d=$R/raw/$s/$w
      [ -d "$d" ] || continue
      for m in $(metrics_for "$w"); do emit "$m" ""; done
      for r in "$d"/r*/; do
        [ -d "$r" ] || continue
        case $w in
          podman-ops)
            if [ -f "$r/timings.json" ]; then
              jq -r '("pull_stress_ng_s", "pull_podman_s", "build_s", "run_rm_mean_s") as $k | select(.[$k] != null) | [$k, .[$k]] | @tsv' "$r/timings.json" |
                while IFS=$'\t' read -r m v; do emit "$m" "$v"; done
            fi ;;
          stress-ng)
            for st in cpu matrix stream; do
              f=$r/stress-$st.yaml
              [ -f "$f" ] || continue
              k=bogo-ops-per-second-real-time m=${st}_bogo_ops_s
              if [ $st = stream ]; then k=mb-per-sec-memory-read-rate m=stream_read_mb_s; fi
              v=$(awk -v s="$st" -v k="$k:" '/stressor:/ { cur = $NF }
                $1 == k && cur == s { print $2; exit }' "$f")
              if [ -n "$v" ]; then emit "$m" "$v"; fi
            done ;;
          fio)
            for j in $JOBS; do
              f=$r/fio-$j.json
              [ -f "$f" ] || continue
              jq -r --arg j "$j" '.jobs[0] | (if .read.io_bytes > 0 then .read else .write end) |
                [["iops", .iops], ["bw", .bw_bytes], ["clat_p99", .clat_ns.percentile["99.000000"]]][] |
                select(.[1] != null) | [$j + "_" + .[0], .[1]] | @tsv' "$f" 2>/dev/null |
                while IFS=$'\t' read -r m v; do emit "$m" "$v"; done
            done ;;
        esac
        if [ -f "$r/footprint.json" ]; then
          jq -r '[["idle_cpu_mcores", (.s1.cpu_usec - .s0.cpu_usec) / (.s1.t - .s0.t) / 1000],
                  ["idle_mem_bytes", .s1.mem_current],
                  ["cpu_s", (.s3.cpu_usec - .s2.cpu_usec) / 1e6],
                  ["mem_peak_bytes", .s3.mem_peak],
                  ["disk_bytes", .s3.disk_bytes]][] |
                select(.[1] != null) | @tsv' "$r/footprint.json" 2>/dev/null |
            while IFS=$'\t' read -r m v; do emit "$m" "$v"; done
        fi
      done
    done
  done
}

echo "setup,workload,metric,unit,better,n,median,min,max,baseline,ratio" > "$R/summary.csv"
collect | awk -F'\t' '
BEGIN {
  base["plain-kata"] = "plain-runc"
  base["podman-kata-vfs-disk"] = "podman-runc-vfs-disk"
  base["podman-kata-overlay-ram"] = "podman-runc-overlay-ram"
}
{
  k = $3 SUBSEP $4 SUBSEP $5
  if (!(k in seen)) {
    seen[k] = 1; keys[++nk] = k
    ord[k] = $1 "\t" $2 "\t" $5; st[k] = $3; wl[k] = $4; met[k] = $5; unit[k] = $6; better[k] = $7
  }
  if ($8 != "") v[k, ++n[k]] = $8 + 0
}
END {
  for (i = 1; i <= nk; i++) {
    k = keys[i]; c = n[k]
    if (c == 0) { med[k] = "failed"; continue }
    for (a = 2; a <= c; a++) {
      x = v[k, a]
      for (b = a - 1; b >= 1 && v[k, b] > x; b--) v[k, b + 1] = v[k, b]
      v[k, b + 1] = x
    }
    med[k] = (c % 2) ? v[k, (c + 1) / 2] : (v[k, c / 2] + v[k, c / 2 + 1]) / 2
  }
  for (i = 1; i <= nk; i++) {
    k = keys[i]; c = n[k]
    if (c == 0) { m = mn = mx = "failed" }
    else { m = sprintf("%.6g", med[k]); mn = sprintf("%.6g", v[k, 1]); mx = sprintf("%.6g", v[k, c]) }
    bl = ratio = ""
    if (st[k] in base) {
      bk = base[st[k]] SUBSEP wl[k] SUBSEP met[k]
      if (bk in med) {
        bl = (med[bk] == "failed") ? "failed" : sprintf("%.6g", med[bk])
        if (c > 0 && med[bk] != "failed" && med[bk] + 0 != 0) ratio = sprintf("%.4f", med[k] / med[bk])
      }
    }
    printf "%s\t%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s\n", ord[k], st[k], wl[k], met[k], unit[k], better[k], c, m, mn, mx, bl, ratio
  }
}' | LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3 | cut -f4- >> "$R/summary.csv"
