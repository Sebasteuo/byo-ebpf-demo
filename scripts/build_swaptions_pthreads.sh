#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Asume layout del repo: parsec-3.0 en la raíz del proyecto
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARSECDIR="${PARSECDIR:-$REPO_ROOT/parsec-3.0}"
PARSECPLAT="${PARSECPLAT:-$(uname -m)-linux}"

APP_DIR="$PARSECDIR/pkgs/apps/swaptions"
BIN="$APP_DIR/inst/${PARSECPLAT}.gcc/bin/swaptions"

if [[ -x "$BIN" ]]; then
  echo "[build-swaptions] OK, already present: $BIN"
  exit 0
fi

echo "[build-swaptions] Building swaptions (pthreads) for $PARSECPLAT ..."
cd "$APP_DIR/src"
make clean || true
env version=pthreads make -j"$(nproc)"

mkdir -p "$APP_DIR/inst/${PARSECPLAT}.gcc/bin"
cp -v swaptions "$BIN"
echo "[build-swaptions] Done: $BIN"
