#!/usr/bin/env bash
set -euo pipefail

# Minimal PARSEC harness (baseline vs ebpf) with per-run logs/traces/results.
# No Spanish, no AI mentions. Portable and explicit.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARSECDIR="${PARSECDIR:-$REPO_DIR/parsec-3.0}"
PARSECPLAT="${PARSECPLAT:-$(uname -m)-linux}"
export PARSECDIR PARSECPLAT PATH="$PARSECDIR/bin:$PATH"

# Defaults (can be overridden via env: PKGS, INPUT, THREADS, RUNS)
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

ts="$(date +%F_%H%M%S)"
RESULTS="$REPO_DIR/results_${MODE}_${ts}.csv"
LOGDIR="$REPO_DIR/logs_${ts}"
TRACEDIR="$REPO_DIR/traces_${ts}"
mkdir -p "$LOGDIR" "$TRACEDIR"

echo "timestamp,pkg,input,threads,mode,run_idx,elapsed_s,exit_code" > "$RESULTS"

run_one() {
  local pkg="$1" idx="$2"
  local stamp
  stamp="$(date --iso-8601=seconds)"
  local tfile; tfile="$(mktemp)"
  local runlog="${LOGDIR}/run_${pkg}_${MODE}_${idx}.log"
  local rc=0

  # Dedicated run dir to avoid cross-run contamination
  local RUNDIR; RUNDIR="$(mktemp -d /tmp/parsec_run.XXXXXX)"

  # Optional lightweight syscall trace (only on ebpf mode)
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
    parsecmgmt -a run -p "$pkg" -i "$INPUT" -n "$THREADS" -c gcc -d "$RUNDIR" \
    >> "$runlog" 2>&1
  rc=$?
  set -e

  if [[ -n "$BPF_PID" ]]; then
    sudo kill "$BPF_PID" 2>/dev/null || true
    wait "$BPF_PID" 2>/dev/null || true
  fi

  local elapsed; elapsed="$(tr -d '\r\n' < "$tfile")"
  echo "${stamp},${pkg},${INPUT},${THREADS},${MODE},${idx},${elapsed},${rc}" >> "$RESULTS"
  rm -f "$tfile"

  printf "[%s] %s run=%d mode=%s t=%ss rc=%d\n" "$stamp" "$pkg" "$idx" "$MODE" "$elapsed" "$rc"
}

for pkg in "${PKGS[@]}"; do
  for i in $(seq 1 "$RUNS"); do
    run_one "$pkg" "$i"
  done
done

echo "Results: $RESULTS"
echo "Logs:    $LOGDIR"
echo "Traces:  $TRACEDIR"
