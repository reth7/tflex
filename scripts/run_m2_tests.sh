#!/usr/bin/env bash
# Milestone 2 regression: CRC, sideband, fault injector, retry and flow-control
# tests. Expects the binaries built by `make test-m2`.
# Writes results/reports/m2_test_summary.txt (all RESULT lines) and
# results/raw/m2/m2_results.csv; exits non-zero if any run fails.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CRC_BIN=build/tb_crc/Vtb_crc
FI_BIN=build/tb_fault_injector/Vtb_fault_injector
SBM_BIN=build/tb_sb_mux/Vtb_sb_mux
LINK_BIN=build/tb_link_m1/Vtb_link_m1
LINK8_BIN=build/tb_link_m1_rd8/Vtb_link_m1
LINKRTO_BIN=build/tb_link_m1_rto/Vtb_link_m1
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

# --- unit tests: CRC (golden vectors, single-bit, bursts), fault injector, sideband mux
for seed in 1 2 3; do
  run "crc seed$seed" $CRC_BIN +VECTORS=build/crc_vectors.txt +NVEC=${CRC_NVEC:-100000} +NBURST=20000 +verilator+seed+$seed
  run "fault_injector seed$seed" $FI_BIN +NCYC=20000 +verilator+seed+$seed
  run "sb_mux seed$seed" $SBM_BIN +NMSG=2000 +verilator+seed+$seed
done

# --- retry / flow-control tests on the simplex link, M1 clock configurations
#     (core / link / mem periods in ps; see run_m1_tests.sh)
while read -r cfg c l m; do
  clk="+CFG=$cfg +CORE_PS=$c +LINK_PS=$l +MEM_PS=$m +SINK_PCT=100"
  for t in crc1 bitflip replay_corrupt nak_first wrap maxretry spare_dead nak_density bp_recover; do
    seeds="1"; [ "$cfg" = nominal ] && case $t in crc1|bitflip|replay_corrupt|maxretry) seeds="1 2 3";; esac
    for seed in $seeds; do
      run "link_m2 $t $cfg seed$seed" $LINK_BIN +TEST=$t $clk +verilator+seed+$seed
    done
  done
  # 8-entry replay buffer: window-limited traffic, NAK of the flit that fills the window
  # (both deterministic: one seed)
  run "link_m2 window $cfg rd8" $LINK8_BIN +TEST=window $clk +verilator+seed+1
  run "link_m2 nak_last $cfg rd8" $LINK8_BIN +TEST=nak_last $clk +verilator+seed+1
  # 20-cycle replay timeout: the timer fires and the receiver drops the duplicates
  run "link_m2 dup $cfg rto20" $LINKRTO_BIN +TEST=dup $clk +verilator+seed+1
done <<'CFGS'
nominal  1000  500 1250
equal    1000 1000 1000
slowlink 1000 2000 1250
fastmem  1000  500  500
odd      1002  576 1630
CFGS

# --- measurement: random single-bit errors per transmitted flit (p = PPM / 1e6),
#     sustained 4 KiB writes; link-limited (equal) and memory-limited (nominal) clocks
while read -r cfg c l m; do
  for ppm in 0 1000 10000 50000; do
    for seed in 1 2 3; do
      run "link_m2 ber $cfg ppm$ppm seed$seed" $LINK_BIN +TEST=ber +PPM=$ppm +NPKT=100 \
          +CFG=$cfg +CORE_PS=$c +LINK_PS=$l +MEM_PS=$m +SINK_PCT=100 +verilator+seed+$seed
    done
  done
done <<'CFGS'
nominal  1000  500 1250
equal    1000 1000 1000
CFGS

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
