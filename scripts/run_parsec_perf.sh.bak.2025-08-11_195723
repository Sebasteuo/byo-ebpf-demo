#!/usr/bin/env bash
set -Eeuo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }

# --- Config base ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSECDIR="${PARSECDIR:-$SCRIPT_DIR}"
PARSECPLAT="${PARSECPLAT:-$(uname -m)-linux}"
PATH="$PARSECDIR/bin:$PATH"
export PARSECDIR PARSECPLAT PATH
[[ -x "$PARSECDIR/bin/parsecmgmt" ]] || die "No encuentro $PARSECDIR/bin/parsecmgmt"

MODE="${1:-}"
if [[ "$MODE" != "baseline" && "$MODE" != "ebpf" ]]; then
  echo "Uso: $0 {baseline|ebpf}"; exit 1
fi

# --- Benchmarks, inputs y configs ---
PKGS=(blackscholes swaptions streamcluster canneal)

# COMM mapping para bpftrace (nombre de proceso por paquete)
declare -A COMM_OF=(
  [blackscholes]="blackscholes"
  [swaptions]="swaptions"
  [streamcluster]="streamcluster"
  [canneal]="canneal"
)


declare -A INPUT_OF
INPUT_OF[blackscholes]="simlarge"   # 1M opciones (se crea si falta)
INPUT_OF[swaptions]="simlarge"      # cambia a simsmall/native si necesitas

declare -A CONFIG_OF
CONFIG_OF[blackscholes]="gcc"
CONFIG_OF[swaptions]="gcc-pthreads" # evita TBB en aarch64

THREADS="${THREADS:-4}"
RUNS="${RUNS:-10}"

# Eventos de perf (reduce si ves "not counted")
EVENTS="${EVENTS:-task-clock,context-switches,cpu-migrations,page-faults}"
TASKSET="${TASKSET:-}"   # ej. TASKSET="taskset -c 0"

# Preflight perf
if [[ -r /proc/sys/kernel/perf_event_paranoid ]]; then
  PVAL=$(cat /proc/sys/kernel/perf_event_paranoid || echo 4)
  if (( PVAL > 2 )); then
    echo "[INFO] kernel.perf_event_paranoid=$PVAL; bajando temporalmente a 1..."
    sudo sysctl -w kernel.perf_event_paranoid=1 >/dev/null
  fi
fi

# --- Asegurar input para blackscholes (simlarge) si falta ---
ensure_input_blackscholes() {
  local ind="$PARSECDIR/pkgs/apps/blackscholes/inputs"
  local input="${INPUT_OF[blackscholes]}"
  [[ -f "$ind/input_${input}.tar" ]] && return 0
  echo "[INFO] Creando input ${input} para blackscholes…"
  local probe f
  probe=$(mktemp)
  parsecmgmt -a run -p blackscholes -i "$input" -n "$THREADS" -c "${CONFIG_OF[blackscholes]}" 2>&1 | tee "$probe" || true
  f=$(sed -n 's/.*blackscholes 4 \([^ ]\+\) prices.txt.*/\1/p' "$probe" | tail -n1)
  [[ -n "$f" ]] || die "No pude detectar el nombre de input para $input"
  mkdir -p "$ind/$input"
  awk 'BEGIN{for(i=1;i<=1000000;i++) printf("100 100 0.02 0.30 1.0\n")}' > "$ind/$input/$f"
  (cd "$ind" && tar -cf "input_${input}.tar" -C "$input" "$f")
}

# --- Directorios de salida ---
ts="$(date +%F_%H%M%S)"
RESULTS="results_perf_${MODE}_${ts}.csv"
LOGDIR="logs_perf_${ts}"
TRACEDIR="traces_${ts}"
PERFDIR="perf_${ts}"
mkdir -p "$LOGDIR" "$TRACEDIR" "$PERFDIR"
echo "timestamp,pkg,input,threads,mode,run_idx,elapsed_s,task_clock_ms,cycles,instructions,branches,branch_misses,context_switches,cpu_migrations,page_faults,exit_code" > "$RESULTS"

# --- Utils de parseo robusto ---
# Busca “time elapsed” si existe
perf_elapsed_seconds() {
  local file="$1"
  awk -F',' 'BEGIN{IGNORECASE=1}
    index($0,"time elapsed")>0 { v=$1; gsub(/^[ \t]+|[ \t]+$/,"",v); print v; exit }
  ' "$file"
}

# Devuelve "valor,unidad" de un evento
perf_event_val_unit() {
  local file="$1" ev="$2"
  awk -F',' -v ev="$ev" 'BEGIN{IGNORECASE=1}
    {u=$2; e=$3; gsub(/^[ \t]+|[ \t]+$/,"",u); gsub(/^[ \t]+|[ \t]+$/,"",e)}
    tolower(e)==tolower(ev) { v=$1; gsub(/^[ \t]+|[ \t]+$/,"",v); print v","u; exit }
  ' "$file"
}

# Devuelve valor de evento simple (ignora <not supported>)
perf_event_val_simple() {
  local file="$1" ev="$2"
  awk -F',' -v ev="$ev" 'BEGIN{IGNORECASE=1}
    {e=$3; gsub(/^[ \t]+|[ \t]+$/,"",e)}
    tolower(e)==tolower(ev) { v=$1; gsub(/^[ \t]+|[ \t]+$/,"",v); if(v!~/<not/){print v; exit} }
  ' "$file"
}

# Extrae CPUs utilized desde la línea de task-clock (si perf la emite)
perf_cpus_utilized() {
  local file="$1"
  awk -F',' 'BEGIN{IGNORECASE=1}
    tolower($3)=="task-clock" && index(tolower($7),"cpus utilized")>0 {
      u=$6; gsub(/^[ \t]+|[ \t]+$/,"",u); print u; exit
    }
  ' "$file"
}

run_one() {
  local pkg="$1" idx="$2"
  local input="${INPUT_OF[$pkg]:-simsmall}"
  local cfg="${CONFIG_OF[$pkg]:-gcc}"
  local stamp; stamp="$(date --iso-8601=seconds)"
  local runlog="${LOGDIR}/run_${pkg}_${MODE}_${idx}.log"
  local perfout="${PERFDIR}/perf_${pkg}_${MODE}_${idx}.csv"
  local rc=0

  [[ "$pkg" == "blackscholes" ]] && ensure_input_blackscholes

  # eBPF agregado (poco I/O)
  local BPF_PID=""
  if [[ "$MODE" == "ebpf" ]]; then
    command -v bpftrace >/dev/null || die "bpftrace no instalado"
    sudo -v
    sudo bpftrace -q -e 'tracepoint:syscalls:sys_enter_write /comm=="'"$pkg"'"/ { @writes[pid] = count(); } END { print(@writes); }' \
      > "${TRACEDIR}/${pkg}_${idx}.txt" 2> "${TRACEDIR}/${pkg}_${idx}.err" &
    BPF_PID=$!
  fi

  set +e
  # CSV limpio: LC_ALL=C y --no-big-num
  LC_ALL=C $TASKSET perf stat --no-big-num -x, -o "$perfout" -e "$EVENTS" \
    parsecmgmt -a run -p "$pkg" -i "$input" -n "$THREADS" -c "$cfg" \
    >> "$runlog" 2>&1
  rc=$?
  set -e

  if [[ -n "$BPF_PID" ]]; then
    sudo kill "$BPF_PID" 2>/dev/null || true
    wait "$BPF_PID" 2>/dev/null || true
  fi

  # Parsear métricas
  local elapsed_s task_ms cycles inst branches brmiss ctx migr faults cpus_util

  elapsed_s="$(perf_elapsed_seconds "$perfout" || true)"

  # task-clock: detectar unidad y convertir a ms
  local tvu; tvu="$(perf_event_val_unit "$perfout" "task-clock" || true)"
  if [[ -n "$tvu" ]]; then
    local tval="$(cut -d, -f1 <<<"$tvu")"
    local tunit="$(cut -d, -f2 <<<"$tvu" | tr '[:upper:]' '[:lower:]')"
    case "$tunit" in
      msec) task_ms="$tval" ;;
      sec|second|seconds) task_ms="$(awk -v s="$tval" 'BEGIN{printf "%.3f", s*1000}')" ;;
      usec|microseconds) task_ms="$(awk -v us="$tval" 'BEGIN{printf "%.3f", us/1000}')" ;;
      nsec|nanoseconds)  task_ms="$(awk -v ns="$tval" 'BEGIN{printf "%.6f", ns/1e6}')" ;;
      *) task_ms="$tval" ;;
    esac
  fi

  # CPUs utilized (si está)
  cpus_util="$(perf_cpus_utilized "$perfout" || true)"

  # Fallbacks de elapsed:
  if [[ -z "${elapsed_s:-}" && -n "${task_ms:-}" && -n "${cpus_util:-}" ]]; then
    # Mejor estimación: elapsed ≈ (task_ms/1000) / cpus_util
    elapsed_s="$(awk -v ms="$task_ms" -v u="$cpus_util" 'BEGIN{ if(u>0) printf "%.6f", (ms/1000.0)/u }')"
  fi
  if [[ -z "${elapsed_s:-}" && -n "${task_ms:-}" ]]; then
    # Segundo fallback: sin CPUs utilized
    elapsed_s="$(awk -v ms="$task_ms" 'BEGIN{printf "%.6f", ms/1000.0}')"
  fi

  cycles="$(perf_event_val_simple "$perfout" "cycles" || true)"
  inst="$(perf_event_val_simple "$perfout" "instructions" || true)"
  branches="$(perf_event_val_simple "$perfout" "branches" || true)"
  brmiss="$(perf_event_val_simple "$perfout" "branch-misses" || true)"
  ctx="$(perf_event_val_simple "$perfout" "context-switches" || true)"
  migr="$(perf_event_val_simple "$perfout" "cpu-migrations" || true)"
  faults="$(perf_event_val_simple "$perfout" "page-faults" || true)"

  # Marcar fallo si el log trae ERROR:
  grep -q "ERROR:" "$runlog" && rc=1

  echo "${stamp},${pkg},${input},${THREADS},${MODE},${idx},${elapsed_s:-},${task_ms:-},${cycles:-},${inst:-},${branches:-},${brmiss:-},${ctx:-},${migr:-},${faults:-},${rc}" >> "$RESULTS"
  printf "[%s] %s run=%d mode=%s elapsed=%ss taskclk=%sms rc=%d\n" "$stamp" "$pkg" "$idx" "$MODE" "${elapsed_s:-NA}" "${task_ms:-NA}" "$rc"
}

# --- Bucle principal ---
for pkg in "${PKGS[@]}"; do
  for i in $(seq 1 "$RUNS"); do
    run_one "$pkg" "$i"
  done
done

echo "Resultados en: $RESULTS"
echo "Perf raw en:    $PERFDIR"
echo "Logs en:        $LOGDIR"
echo "Trazas en:      $TRACEDIR"
