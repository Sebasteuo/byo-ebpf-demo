#!/usr/bin/env bash
set -euo pipefail

# Ensure PARSECDIR/PATH when running from the repo root
if ! command -v parsecmgmt >/dev/null 2>&1; then
  export PARSECDIR="$HOME/byo-ebpf-demo/parsec-3.0"
  export PATH="$PARSECDIR/bin:$PATH"
fi
command -v parsecmgmt >/dev/null 2>&1 || { echo "ERROR: parsecmgmt not in PATH. Export PARSECDIR so that \$PARSECDIR/bin is in PATH." >&2; exit 1; }

MODE="${1:-}"; [[ "$MODE" == "baseline" || "$MODE" == "ebpf" ]] || { echo "Usage: $0 {baseline|ebpf}"; exit 1; }

PKGS=(blackscholes)          # add more later
INPUT="simlarge"
THREADS=4
RUNS=${RUNS:-10}

ts="$(date +%F_%H%M%S)"
RESULTS="results_${MODE}_${ts}.csv"
LOGDIR="logs_${ts}"
TRACEDIR="traces_${ts}"
mkdir -p "$LOGDIR" "$TRACEDIR"
echo "timestamp,pkg,input,threads,mode,run_idx,elapsed_s,exit_code" > "$RESULTS"

run_one() {
  local pkg="$1" idx="$2"
  local stamp="$(date --iso-8601=seconds)"
  local tfile; tfile="$(mktemp)"
  local runlog="${LOGDIR}/run_${pkg}_${MODE}_${idx}.log"
  local rc=0
  local RUNDIR; RUNDIR="$(mktemp -d /tmp/parsec_run.XXXXXX)"

  if [[ "$MODE" == "ebpf" ]]; then
    command -v bpftrace >/dev/null || { echo "ERROR: bpftrace is not installed"; exit 1; }
    sudo -n true 2>/dev/null || echo "[WARN] sudo password may be requested for bpftrace"
    sudo bpftrace -e 'tracepoint:syscalls:sys_enter_write /comm == "blackscholes"/ { printf("%s %d write %d\n", strftime("%F %T", nsecs), pid, args->count); }' \
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

  if [[ -n "${BPF_PID:-}" ]]; then
    sudo kill "$BPF_PID" 2>/dev/null || true
    wait "$BPF_PID" 2>/dev/null || true
  fi

  local outf; outf="$(find "$RUNDIR" -type f -name prices.txt -print -quit 2>/dev/null || true)"
  [[ -s "${outf:-}" ]] || rc=1

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
