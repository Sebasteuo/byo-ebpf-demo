#!/usr/bin/env bash
set -euo pipefail

# PARSEC + perf harness (baseline vs ebpf) writing CSV with task-clock and friends.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARSECDIR="${PARSECDIR:-$REPO_DIR/parsec-3.0}"
PARSECPLAT="${PARSECPLAT:-$(uname -m)-linux}"
export PARSECDIR PARSECPLAT PATH="$PARSECDIR/bin:$PATH"

PKGS=(${PKGS:-blackscholes swaptions streamcluster canneal})
INPUT="${INPUT:-simlarge}"
THREADS="${THREADS:-4}"
RUNS="${RUNS:-10}"

MODE="${1:-}"
[[ "$MODE" == "baseline" || "$MODE" == "ebpf" ]] || { echo "Usage: $0 {baseline|ebpf}"; exit 1; }

command -v parsecmgmt >/dev/null || {
  echo "ERROR: parsecmgmt not in PATH. Export PARSECDIR so that \$PARSECDIR/bin is in PATH."
  exit 1
}
command -v perf >/dev/null || { echo "ERROR: perf not installed."; exit 1; }

EVENTS="task-clock,cycles,instructions,branches,branch-misses,context-switches,cpu-migrations,page-faults"

ts="$(date +%F_%H%M%S)"
RESULTS="$REPO_DIR/results_perf_${MODE}_${ts}.csv"
PERFDIR="$REPO_DIR/perf_${ts}"
LOGDIR="$REPO_DIR/logs_perf_${ts}"
TRACEDIR="$REPO_DIR/traces_${ts}"
mkdir -p "$PERFDIR" "$LOGDIR" "$TRACEDIR"

echo "timestamp,pkg,input,threads,mode,run_idx,elapsed_s,task_clock_ms,cycles,instructions,branches,branch_misses,ctx_switches,cpu_migrations,page_faults,exit_code" > "$RESULTS"

run_one() {
  local pkg="$1" idx="$2"
  local stamp; stamp="$(date --iso-8601=seconds)"
  local tfile; tfile="$(mktemp)"
  local runlog="${LOGDIR}/run_${pkg}_${MODE}_${idx}.log"
  local perfout="${PERFDIR}/perf_${pkg}_${MODE}_${idx}.csv"
  local rc=0

  local RUNDIR; RUNDIR="$(mktemp -d /tmp/parsec_run.XXXXXX)"

  if [[ "$MODE" == "ebpf" ]]; then
    command -v bpftrace >/dev/null || { echo "ERROR: bpftrace not installed."; exit 1; }
    sudo -n true 2>/dev/null || sudo -v
    sudo bpftrace -e "tracepoint:syscalls:sys_enter_write /comm == \"$pkg\"/ { printf(\"%s %d write %d\\n\", strftime(\"%F %T\", nsecs), pid, args->count); }" \
      > "${TRACEDIR}/${pkg}_${idx}.bpf.txt" 2> "${TRACEDIR}/${pkg}_${idx}.bpf.err" &
    BPF_PID=$!
  else
    BPF_PID=""
  fi

  set +e
  /usr/bin/time -f '%e' -o "$tfile" \
    perf stat --no-big-num -x, -o "$perfout" -e "$EVENTS" \
    parsecmgmt -a run -p "$pkg" -i "$INPUT" -n "$THREADS" -c gcc -d "$RUNDIR" \
    >> "$runlog" 2>&1
  rc=$?
  set -e

  if [[ -n "$BPF_PID" ]]; then
    sudo kill "$BPF_PID" 2>/dev/null || true
    wait "$BPF_PID" 2>/dev/null || true
  fi

  # Parse perf CSV (best effort)
  parse_field() { awk -F, -v ev="$1" '$3==ev {print $1" "$2}' "$perfout" | head -n1; }
  read -r taskclk unit_tc <<<"$(parse_field task-clock)"
  read -r cycles  unit_cy <<<"$(parse_field cycles)"
  read -r instr   unit_in <<<"$(parse_field instructions)"
  read -r branches unit_br <<<"$(parse_field branches)"
  read -r brmiss  unit_bm <<<"$(parse_field branch-misses)"
  read -r ctx     unit_ctx <<<"$(parse_field context-switches)"
  read -r mig     unit_mig <<<"$(parse_field cpu-migrations)"
  read -r pf      unit_pf  <<<"$(parse_field page-faults)"

  # Normalize task-clock to ms if possible
  tc_ms=""
  if [[ "${unit_tc:-}" == "msec" ]]; then tc_ms="$taskclk"
  elif [[ "${unit_tc:-}" == "sec" ]]; then
    tc_ms="$(awk -v s="$taskclk" 'BEGIN{printf("%.2f", s*1000)}')"
  else tc_ms=""; fi

  for v in cycles instr branches brmiss ctx mig pf; do
    [[ -n "${!v:-}" ]] || eval "$v=''"
  done

  local elapsed; elapsed="$(tr -d '\r\n' < "$tfile")"
  echo "${stamp},${pkg},${INPUT},${THREADS},${MODE},${idx},${elapsed},${tc_ms},${cycles},${instr},${branches},${brmiss},${ctx},${mig},${pf},${rc}" >> "$RESULTS"
  rm -f "$tfile"

  printf "[%s] %s run=%d mode=%s elapsed=%ss taskclk=%sms rc=%d\n" "$stamp" "$pkg" "$idx" "$MODE" "${elapsed:-NA}" "${tc_ms:-NA}" "$rc"
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
