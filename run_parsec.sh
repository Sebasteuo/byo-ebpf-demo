#!/usr/bin/env bash
set -euo pipefail

# Resolve real script path (follows symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# Repo root (prefer git, fallback to parent of scripts/)
if REPO_DIR="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  if [[ -f "$SCRIPT_DIR/../env.sh" || -d "$SCRIPT_DIR/../.git" ]]; then
    REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  else
    REPO_DIR="$SCRIPT_DIR"
  fi
fi

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

ts="$(date +%F_%H%M%S)"
RESULTS="$REPO_DIR/results_${MODE}_${ts}.csv"
LOGDIR="$REPO_DIR/logs_${ts}"
TRACEDIR="$REPO_DIR/traces_${ts}"
mkdir -p "$LOGDIR" "$TRACEDIR"
echo "timestamp,pkg,input,threads,mode,run_idx,elapsed_s,exit_code" > "$RESULTS"

run_one() {
  local pkg="$1" idx="$2"
  local stamp; stamp="$(date --iso-8601=seconds)"
  local tfile; tfile="$(mktemp)"
  local runlog="${LOGDIR}/run_${pkg}_${MODE}_${idx}.log"
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
    env version=pthreads parsecmgmt -a run -p "$pkg" -i "$INPUT" -n "$THREADS" -c gcc -d "$RUNDIR" \
    >> "$runlog" 2>&1
  rc=$?
  set -e

  [[ -n "${BPF_PID:-}" ]] && { sudo kill "$BPF_PID" 2>/dev/null || true; wait "$BPF_PID" 2>/dev/null || true; }

  # Extract the last numeric (seconds) from time file (even if it prepended an error line)
  local elapsed; elapsed="$(grep -Eo '[0-9]+(\.[0-9]+)?' "$tfile" | tail -n1)"
  rm -f "$tfile"

  echo "${stamp},${pkg},${INPUT},${THREADS},${MODE},${idx},${elapsed:-},${rc}" >> "$RESULTS"
  printf "[%s] %s run=%d mode=%s t=%ss rc=%d\n" "$stamp" "$pkg" "$idx" "$MODE" "${elapsed:-NA}" "$rc"
}

for pkg in "${PKGS[@]}"; do
  for i in $(seq 1 "$RUNS"); do
    run_one "$pkg" "$i"
  done
done

echo "Results: $RESULTS"
echo "Logs:    $LOGDIR"
echo "Traces:  $TRACEDIR"
