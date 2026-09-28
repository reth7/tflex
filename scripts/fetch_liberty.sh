#!/usr/bin/env bash
# Fetches open-source standard-cell liberty files used for pre-layout synthesis
# estimates (Milestone "synthesis"). Not needed for simulation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DST="$ROOT/.tools/liberty"; mkdir -p "$DST"
BASE=https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms
curl -sSL -o "$DST/nangate45_typical.lib" "$BASE/nangate45/lib/NangateOpenCellLibrary_typical.lib"
curl -sSL -o "$DST/sky130hd_tt.lib"       "$BASE/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
ls -l "$DST"
