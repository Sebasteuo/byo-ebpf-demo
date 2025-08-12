#!/usr/bin/env bash
set -euo pipefail

# Detectar si fue "sourceado" para no matar la shell
_is_sourced=0
if [[ "${BASH_SOURCE[0]-x}" != "${0-}" ]]; then _is_sourced=1; fi
die(){ echo "ERROR: $*" >&2; if (( _is_sourced )); then return 1; else exit 1; fi; }

# --- Config ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSECDIR="${PARSECDIR:-$SCRIPT_DIR}"
PARSECPLAT="${PARSECPLAT:-$(uname -m)-linux}"
PATH="$PARSECDIR/bin:$PATH"
export PARSECDIR PARSECPLAT PATH

PKGS=("blackscholes")
INPUT="simlarge"     # input grande
THREADS=4
RUNS=10             # 10 corridas por modo

MODE="${1-}"
[[ "$MODE" == "baseline" || "$MODE" == "ebpf" ]] || die "Uso: $0 {baseline|ebpf}"

# --- Asegurar input grande para blackscholes (crea input_simlarge.tar si falta) ---
if [[ " ${PKGS[*]} " == *" blackscholes "* ]]; then
  INDIR="$PARSECDIR/pkgs/apps/blackscholes/inputs"
  if [[ ! -f "$INDIR/input_${INPUT}.tar" ]]; then
    echo "[INFO] Creando input ${INPUT} para blackscholes..."
    PROBE=$(mktemp)
    parsecmgmt -a run -p blackscholes -i "$INPUT" -n "$THREADS" -c gcc 2>&1 | tee "$PROBE" || true
    F=$(sed -n 's/.*blackscholes 4 \([^ ]\+\) prices.txt.*/\1/p' "$PROBE" | tail -n1)
    [[ -n "$F" ]] || die "No pude detectar el nombre de input para $INPUT"
    mkdir -p "$INDIR/$INPUT"
    # 1e6 opciones, formato sin encabezado (5 campos) que ya funciona en tu build
    awk 'BEGIN{for(i=1;i<=1000000;i++) printf("100 100 0.02 0.30 1.0\n")}' > "$INDIR/$INPUT/$F"
    (cd "$INDIR" && tar -cf "input_${INPUT}.tar" -C "$INPUT" "$F")
  fi
fi

ts="$(date +%F_%H%M%S)"
RESULTS="results_${MODE}_${ts}.csv"
LOGDIR="logs_${ts}"
TRACEDIR="traces_${ts}"
mkdir -p "$LOGDIR" "$TRACEDIR"
echo "timestamp,pkg,input,threads,mode,run_idx,elapsed_s,exit_code" > "$RESULTS"

run_one(){
  local pkg="$1" idx="$2"
  local stamp="$(date --iso-8601=seconds)"
  local tfile; tfile="$(mktemp)"
  local runlog="${LOGDIR}/run_${pkg}_${MODE}_${idx}.log"
  local rc=0

  # Creamos un RUNDIR dedicado por corrida y lo forzamos con -d
  local RUNDIR; RUNDIR="$(mktemp -d /tmp/parsec_run.XXXXXX)"

  # eBPF solo en modo ebpf (el script pedirá sudo SOLO aquí)
  if [[ "$MODE" == "ebpf" ]]; then
    command -v bpftrace >/dev/null || die "bpftrace no instalado (sudo apt -y install bpftrace)"
    sudo -v  # pide password una vez si hace falta
    sudo bpftrace -e 'tracepoint:syscalls:sys_enter_write /comm == "blackscholes"/ { printf("%s %d write %d\n", strftime("%F %T", nsecs), pid, args->count); }' \
      > "${TRACEDIR}/${pkg}_${idx}.txt" &
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

  # Parar el collector si estaba activo
  if [[ -n "$BPF_PID" ]]; then
    sudo kill "$BPF_PID" 2>/dev/null || true
    wait "$BPF_PID" 2>/dev/null || true
  fi

  # ---- Verificación robusta de salida ----
  # Busca prices.txt debajo de RUNDIR (sin asumir estructura interna)
  local OUTFILE=""
  OUTFILE=$(find "$RUNDIR" -type f -name prices.txt -print -quit 2>/dev/null || true)
  if [[ -z "$OUTFILE" || ! -s "$OUTFILE" ]]; then
    echo "[WARN] prices.txt no encontrado bajo $RUNDIR" >> "$runlog"
    rc=1
  else
    echo "[INFO] Output: $OUTFILE" >> "$runlog"
  fi

  # Si el log contiene "ERROR:", también marcamos fallo
  grep -q "ERROR:" "$runlog" && rc=1

  # Registrar métrica
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

echo "Resultados en: $RESULTS"
echo "Logs en:        $LOGDIR"
echo "Trazas en:      $TRACEDIR"
