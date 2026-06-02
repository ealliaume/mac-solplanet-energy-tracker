#!/usr/bin/env bash
set -euo pipefail

# Show live battery/solar status from the inverter.
#
# Usage:
#   ./scripts/battery_status.sh            # one-shot
#   ./scripts/battery_status.sh --watch    # refresh every WATCH_INTERVAL sec
#
# Config (env vars, with defaults):
#   INV_HOST   inverter IP                 (default 192.168.4.30)
#   INV_SN     serial number               (default AL010K5SQ2620429)
#   WATCH_INTERVAL  seconds between refresh (default 5)
#
# Requires: curl, python3

INV_HOST="${INV_HOST:-192.168.4.30}"
INV_SN="${INV_SN:-AL010K5SQ2620429}"
WATCH_INTERVAL="${WATCH_INTERVAL:-5}"

for bin in curl python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing: $bin" >&2; exit 1; }
done

query() {
  # $1 = device id -> raw JSON on stdout
  curl -s -k --max-time 10 \
    "https://${INV_HOST}/getdevdata.cgi?device=${1}&sn=${INV_SN}"
}

render() {
  local ess inv meter
  ess="$(query 4)"   || { echo "query device=4 failed" >&2; return 1; }  # ESS / battery
  inv="$(query 2)"   || { echo "query device=2 failed" >&2; return 1; }  # inverter AC side
  meter="$(query 3)" || meter='{"flg":0}'                                # grid CT meter (often disabled)

  ESS_JSON="$ess" INV_JSON="$inv" METER_JSON="$meter" python3 - <<'PY'
import json, os

ess   = json.loads(os.environ["ESS_JSON"])
inv   = json.loads(os.environ["INV_JSON"])
meter = json.loads(os.environ["METER_JSON"])

# See docs/solplanet-api-documentation.md for field meanings & derivations.
#
# Sign conventions (verified against the Solplanet app):
#   pb  < 0 = battery charging, > 0 = discharging
#   pac < 0 = inverter exporting to AC bus, > 0 = drawing from AC
#
# The battery is AC-COUPLED: PV feeds the inverter's AC bus, and the battery
# charges *from* that bus. So the inverter AC output (-pac) already INCLUDES the
# battery-charging power -> PV = -pac. (Do NOT add pb; that double-counts.)
# Confirmed at high PV: app PV 4801 W, -pac ~4274 (lagging/falling); the old
# -(pb+pac) gave ~8300 W, ~1.7x too high.  ess["ppv"] is dead (always 0).
soc = ess.get("soc", 0)           # state of charge, %
pb  = ess.get("pb", 0)            # battery power, W  (<0 charge, >0 discharge)
vb  = ess.get("vb", 0) / 100.0    # battery voltage, V
pac = inv.get("pac", 0)           # inverter AC power, W (<0 export, >0 import)

pv  = max(0, -pac)                # derived PV generation, W (inverter AC output)

batt = "charging" if pb < 0 else ("discharging" if pb > 0 else "idle")

# House load = PV - battery_charge - grid_export.  This is a small difference of
# two large, asynchronously-sampled values (PV ~= battery when charging hard), so
# it is too noisy to derive reliably without the grid CT meter (device=3), which
# is disabled here (flg=0). With the meter present it becomes usable:
#     PV + grid_import = house_load + battery_charge + grid_export
#   => house_load = PV + pb - grid_export        (battery_charge ~= -pb)
# ASSUMPTION (unverified - meter offline here): meter "pac" > 0 = export, < 0 = import.
if meter.get("flg", 0) == 1:
    grid = meter.get("pac", 0)               # signed: >0 export, <0 import
    load = pv + pb - grid                     # house load, W (~ +/- charge effcy)
    gridflow = "export" if grid > 0 else ("import" if grid < 0 else "idle")
    load_str = f"{load:6d} W"
    grid_str = f"{abs(grid):6d} W   {gridflow}"
else:
    # rough only: tiny difference of two large async values; expect big jitter
    load_str = f"~{max(0, pv + pb):5d} W   (rough; needs grid meter)"
    grid_str = "   n/a   (grid meter disabled)"

print(f"  PV production     : {pv:6d} W   (= inverter AC output, -pac)")
print(f"  Battery flow      : {abs(pb):6d} W   {batt}   ({soc}%, {vb:.2f} V)")
print(f"  House load        : {load_str}")
print(f"  Grid flow         : {grid_str}")
PY
}

if [ "${1:-}" = "--watch" ]; then
  while true; do
    clear
    echo "Inverter ${INV_HOST}  ($(date '+%H:%M:%S'))"
    echo "----------------------------------------"
    render || true
    sleep "$WATCH_INTERVAL"
  done
else
  echo "Inverter ${INV_HOST}  ($(date '+%H:%M:%S'))"
  echo "----------------------------------------"
  render
fi
