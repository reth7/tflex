#!/usr/bin/env bash
# Milestone 1 regression: async FIFO and simplex-link tests over a matrix of
# clock configurations and seeds. Expects the binaries built by `make`.
# Writes results/reports/m1_test_summary.txt (all RESULT lines) and
# results/raw/m1/m1_results.csv; exits non-zero if any run fails.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FIFO_BIN=build/tb_async_fifo/Vtb_async_fifo
LINK_BIN=build/tb_link_m1/Vtb_link_m1
REPORT=results/reports/m1_test_summary.txt
CSV=results/raw/m1/m1_results.csv
mkdir -p results/reports results/raw/m1 build
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

# --- async FIFO: writer/reader clock periods (ps) and read-clock phase
#     eq: equal clocks; eqphase: equal, read clock lagging by 370 ps;
#     fastw / fastr: 3.3x ratio either way; drift: 0.3% frequency offset
while read -r cfg w r ph; do
  for seed in 1 2 3; do
    run "fifo $cfg seed$seed" $FIFO_BIN +CFG=$cfg +WCLK_PS=$w +RCLK_PS=$r +RPHASE_PS=$ph +verilator+seed+$seed
  done
done <<'CFGS'
eq      1000 1000 0
eqphase 1000 1000 370
fastw   1000 3333 0
fastr   3333 1000 0
drift   1000 1003 0
CFGS

# --- simplex link: core / link / mem clock periods (ps)
#     nominal 1.0/2.0/0.8 GHz; equal 1/1/1 GHz; slowlink link at 0.5 GHz;
#     fastmem mem at 2 GHz (core-limited); odd = unrelated periods
#     (periods are even: the testbench toggles every period/2 ps)
while read -r cfg c l m; do
  for t in single burst sustained backpressure reset; do
    seeds="1"; [ "$t" = burst ] || [ "$t" = backpressure ] && seeds="1 2 3"
    pct=100; [ "$t" = backpressure ] && pct=30
    n=""; [ "$t" = sustained ] && n="+NPKT=300"
    for seed in $seeds; do
      run "link $t $cfg seed$seed" $LINK_BIN +TEST=$t +CFG=$cfg +CORE_PS=$c +LINK_PS=$l +MEM_PS=$m +SINK_PCT=$pct $n +verilator+seed+$seed
    done
  done
done <<'CFGS'
nominal  1000  500 1250
equal    1000 1000 1000
slowlink 1000 2000 1250
fastmem  1000  500  500
odd      1002  576 1630
CFGS

# CSV of all RESULT key=value pairs
python3 - "$REPORT" "$CSV" <<'PY'
import sys, csv
rows = []
for line in open(sys.argv[1]):
    if not line.startswith("RESULT"): continue
    parts = line.split()
    d = {}
    for p in parts[1:]:
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
echo "M1 regression: $pass passed, $fail failed  (summary: $REPORT)"
[ $fail -eq 0 ]
