#!/usr/bin/env bash
set -euo pipefail

# Ensure PARSECDIR/PATH when running from the repo root
if ! command -v parsecmgmt >/dev/null 2>&1; then
  export PARSECDIR="$HOME/byo-ebpf-demo/parsec-3.0"
  export PATH="$PARSECDIR/bin:$PATH"
fi
command -v parsecmgmt >/dev/null 2>&1 || { echo "ERROR: parsecmgmt not in PATH. Export PARSECDIR so that \$PARSECDIR/bin is in PATH." >&2; exit 1; }

MODE="${1:-}"; [[ "$MODE" == "baseline" || "$MODE" == "ebpf" ]] || { echo "Usage: $0 {baseline|ebpf}"; exit 1; }

# Workload set (extend up to ~10 apps as requested)
PKGS=(blackscholes swaptions streamcluster canneal)

declare -A INPUT_OF
INPUT_OF[blackscholes]="simlarge"
INPUT_OF[swaptions]="simlarge"
INPUT_OF[streamcluster]="simlarge"
INPUT_OF[canneal]="simlarge"

declare -A CONFIG_OF
CONFIG_OF[blackscholes]="gcc"
CONFIG_OF[swaptions]="gcc-pthreads"   # avoids TBB
CONFIG_OF[streamcluster]="gcc"
CONFIG_OF[canneal]="gcc"

THREADS=${THREADS:-4}
RUNS=${RUNS:-10}

# Perf settings
EVENTS="task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses"

ts="$(date +%F_%H%M%S)"
RESULTS="results_perf_${MODE}_${ts}.csv"
LOGDIR="logs_perf_${ts}"
PERFDIR="perf_${ts}"
TRACEDIR="traces_${ts}"
mkdir -p "$LOGDIR" "$PERFDIR" "$TRACEDIR"
echo "timestamp,pkg,input,threads,mode,run_idx,elapsed_s,task_clock_ms,cycles,instructions,branches,branch_misses,ctx_switches,migrations,page_faults,exit_code" > "$RESULTS"

run_one() {
  local pkg="$1" idx="$2"
  local input="${INPUT_OF[$pkg]}"
  local cfg="${CONFIG_OF[$pkg]}"
  local stamp; stamp="$(date --iso-8601=seconds)"
  local runlog="${LOGDIR}/run_${pkg}_${MODE}_${idx}.log"
  local rc=0
  local RUNDIR; RUNDIR="$(mktemp -d /tmp/parsec_run.XXXXXX)"

  # Optional eBPF load to create/measure overhead
  local BPF_PID=""
  if [[ "$MODE" == "ebpf" ]]; then
    command -v bpftrace >/dev/null || { echo "ERROR: bpftrace not installed"; exit 1; }
    sudo -n true 2>/dev/null || echo "[WARN] sudo password may be requested for bpftrace"
    sudo bpftrace -e "tracepoint:syscalls:sys_enter_write /comm == \"$pkg\"/ { printf(\"%s %d write %d\n\", strftime(\"%F %T\", nsecs), pid, args->count); }" \
      > "${TRACEDIR}/${pkg}_${idx}.bpf.txt" 2> "${TRACEDIR}/${pkg}_${idx}.bpf.err" &
    BPF_PID=$!
  fi

  # Run under perf stat (CSV), plus get wall-clock via /usr/bin/time
  local perfout="${PERFDIR}/perf_${pkg}_${MODE}_${idx}.csv"
  local tfile; tfile="$(mktemp)"
  set +e
  /usr/bin/time -f '%e' -o "$tfile" \
  perf stat --no-big-num -x, -o "$perfout" -e "$EVENTS" \
    parsecmgmt -a run -p "$pkg" -i "$input" -n "$THREADS" -c "$cfg" -d "$RUNDIR" \
    >> "$runlog" 2>&1
  rc=$?
  set -e

  # Stop eBPF if active
  if [[ -n "$BPF_PID" ]]; then
    sudo kill "$BPF_PID" 2>/dev/null || true
    wait "$BPF_PID" 2>/dev/null || true
  fi

  # Grab metrics from perf CSV
  # Expected lines (LC_ALL=C):
  #  <ms>,msec,task-clock,....
  #  <val>,,context-switches,....
  #  ...
  LC_ALL=C
  local taskclk cycles instructions branches br_miss ctx mig pf
  taskclk="$(awk -F, '$3=="task-clock"{print $1}' "$perfout")"
  cycles="$(awk -F, '$3=="cycles"{print $1}' "$perfout")"
  instructions="$(awk -F, '$3=="instructions"{print $1}' "$perfout")"
  branches="$(awk -F, '$3=="branches"{print $1}' "$perfout")"
  br_miss="$(awk -F, '$3=="branch-misses"{print $1}' "$perfout")"
  ctx="$(awk -F, '$3=="context-switches"{print $1}' "$perfout")"
  mig="$(awk -F, '$3=="cpu-migrations"{print $1}' "$perfout")"
  pf="$(awk -F, '$3=="page-faults"{print $1}' "$perfout")"

  # Wall time
  local elapsed; elapsed="$(tr -d '\r\n' < "$tfile")"; rm -f "$tfile"

  # Fallbacks in case of unsupported counters
  [[ -z "${taskclk}" ]] && taskclk=""; [[ -z "${cycles}" ]] && cycles="<not supported>"
  [[ -z "${instructions}" ]] && instructions="<not supported>"
  [[ -z "${branches}" ]] && branches="<not supported>"
  [[ -z "${br_miss}" ]] && br_miss="<not supported>"
  [[ -z "${ctx}" ]] && ctx=""; [[ -z "${mig}" ]] && mig=""; [[ -z "${pf}" ]] && pf=""

  echo "${stamp},${pkg},${input},${THREADS},${MODE},${idx},${elapsed},${taskclk},${cycles},${instructions},${branches},${br_miss},${ctx},${mig},${pf},${rc}" >> "$RESULTS"
  printf "[%s] %s run=%d mode=%s elapsed=%ss taskclk=%sms rc=%d\n" "$stamp" "$pkg" "$idx" "$MODE" "${elapsed:-NA}" "${taskclk:-NA}" "$rc"
}

for pkg in "${PKGS[@]}"; do
  for i in $(seq 1 "$RUNS"); do
    run_one "$pkg" "$i"
  done
done

echo "Results: $RESULTS"
echo "Perf raw: $PERFDIR"
echo "Logs:     $LOGDIR"
echo "Traces:   $TRACEDIR"
