#!/usr/bin/env bash
# Milestone 2 regression: CRC, sideband, fault injector, retry and flow-control
# tests. Expects the binaries built by `make test-m2`.
# Writes results/reports/m2_test_summary.txt (all RESULT lines) and
# results/raw/m2/m2_results.csv; exits non-zero if any run fails.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CRC_BIN=build/tb_crc/Vtb_crc
REPORT=results/reports/m2_test_summary.txt
CSV=results/raw/m2/m2_results.csv
mkdir -p results/reports results/raw/m2 build
: > "$REPORT"
pass=0; fail=0

run() {  # label, binary, args...
  local label=$1 bin=$2; shift 2
  local out; out=$("$bin" "$@" 2>&1); local rc=$?
  local res; res=$(echo "$out" | grep -E '^RESULT' | tail -1)
  if [ $rc -eq 0 ] && echo "$res" | grep -q ' PASS$'; then
    pass=$((pass+1)); echo "PASS  $label"
  else
    fail=$((fail+1)); echo "FAIL  $label"; echo "$out" | grep -E 'Error|CHECK|FAIL' | head -5
    [ -z "$res" ] && res="RESULT label=$label FAIL(no result line, rc=$rc)"
  fi
  echo "$res" >> "$REPORT"
}

# --- CRC: golden vectors (Python), single-bit and burst detection
for seed in 1 2 3; do
  run "crc seed$seed" $CRC_BIN +VECTORS=build/crc_vectors.txt +NVEC=${CRC_NVEC:-100000} +NBURST=20000 +verilator+seed+$seed
done

# CSV of all RESULT key=value pairs
python3 - "$REPORT" "$CSV" <<'PY'
import sys, csv
rows = []
for line in open(sys.argv[1]):
    if not line.startswith("RESULT"): continue
    d = {}
    for p in line.split()[1:]:
        if "=" in p: k, v = p.split("=", 1); d[k] = v
        else: d["status"] = p
    rows.append(d)
keys = []
for r in rows:
    for k in r:
        if k not in keys: keys.append(k)
with open(sys.argv[2], "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=keys); w.writeheader(); w.writerows(rows)
PY
echo "M2 regression: $pass passed, $fail failed  (summary: $REPORT)"
[ $fail -eq 0 ]
