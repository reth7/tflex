#!/usr/bin/env bash
# One-time environment setup (Ubuntu 22.04/24.04). Idempotent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
mkdir -p "$TOOLS"

echo "[setup] apt packages (verilator, yosys, iverilog, build tools)"
if command -v apt-get >/dev/null; then
  SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  $SUDO apt-get update -q
  $SUDO apt-get install -y -q verilator yosys iverilog build-essential python3-venv unzip curl
fi

echo "[setup] sv2v v0.0.13 (SystemVerilog -> Verilog front end for Yosys)"
if [ ! -x "$TOOLS/sv2v" ]; then
  curl -sSL -o "$TOOLS/sv2v.zip" https://github.com/zachjs/sv2v/releases/download/v0.0.13/sv2v-Linux.zip
  unzip -oq "$TOOLS/sv2v.zip" -d "$TOOLS" && mv "$TOOLS/sv2v-Linux/sv2v" "$TOOLS/sv2v" && rm -rf "$TOOLS/sv2v-Linux" "$TOOLS/sv2v.zip"
fi

echo "[setup] Python virtual environment"
python3 -m venv "$ROOT/.venv"
"$ROOT/.venv/bin/pip" install -q --upgrade pip
"$ROOT/.venv/bin/pip" install -q -r "$ROOT/requirements.txt"

echo "[setup] done. Run: make check-env"
