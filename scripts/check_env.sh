#!/usr/bin/env bash
# Reports tool versions and fails if a required tool is missing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-$([ -x "$ROOT/.venv/bin/python" ] && echo "$ROOT/.venv/bin/python" || echo python3)}"
SV2V="$([ -x "$ROOT/.tools/sv2v" ] && echo "$ROOT/.tools/sv2v" || command -v sv2v || true)"
fail=0
req() { if command -v "$1" >/dev/null; then printf "  %-10s %s\n" "$1" "$($2 2>&1 | head -1)"; else printf "  %-10s MISSING\n" "$1"; fail=1; fi; }
echo "Required tools:"
req verilator "verilator --version"
req yosys     "yosys -V"
req make      "make --version"
req g++       "g++ --version"
if [ -n "$SV2V" ]; then printf "  %-10s %s\n" sv2v "$($SV2V --version)"; else printf "  %-10s MISSING (run scripts/setup_env.sh)\n" sv2v; fail=1; fi
echo "Optional tools:"
for t in iverilog gtkwave sta openroad; do printf "  %-10s %s\n" "$t" "$(command -v $t >/dev/null && echo found || echo 'not found')"; done
echo "Python ($PY):"
"$PY" - <<'PYEOF' || fail=1
import importlib, sys
print(f"  python     {sys.version.split()[0]}")
for m in ["numpy", "scipy", "pandas", "matplotlib", "networkx", "yaml", "pytest", "cocotb"]:
    try:
        mod = importlib.import_module(m); print(f"  {m:10s} {getattr(mod, '__version__', '?')}")
    except ImportError:
        print(f"  {m:10s} MISSING"); sys.exit(1)
PYEOF
[ $fail -eq 0 ] && echo "Environment OK" || { echo "Environment INCOMPLETE"; exit 1; }
