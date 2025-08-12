#!/usr/bin/env bash
set -euo pipefail
OUTDIR="${1:-reports}"
mkdir -p "$OUTDIR"

python3 summarize_results.py --out "$OUTDIR"

# grab the most recent summary CSV we just wrote
SUMMARY="$(ls -t "$OUTDIR"/summary_by_pkg_mode_*.csv | head -n1 || true)"
if [[ -z "$SUMMARY" ]]; then
  echo "No summary CSV found in $OUTDIR"
  exit 1
fi

python3 plot_overhead.py --summary "$SUMMARY" --metric elapsed   --input simlarge --out "$OUTDIR/figure_elapsed_minmax.png"
python3 plot_overhead.py --summary "$SUMMARY" --metric taskclock --input simlarge --out "$OUTDIR/figure_taskclock_minmax.png"

echo "[OK] Report artifacts in: $OUTDIR"
ls -lh "$OUTDIR" | sed -n '1,200p'
