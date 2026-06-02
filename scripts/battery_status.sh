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
# ess["ppv"] is dead on this firmware (always 0), so PV is reconstructed from the
# energy balance  PV = battery_charge + inverter_export = -(pb + pac):
#   - now:      -(-871 + -967) = 1838 W   (app showed ~2791, lagging/falling)
#   - original: -(-421 + -420) =  841 W   (matches app 841, load 425, grid 5)
soc = ess.get("soc", 0)           # state of charge, %
pb  = ess.get("pb", 0)            # battery power, W  (<0 charge, >0 discharge)
vb  = ess.get("vb", 0) / 100.0    # battery voltage, V
pac = inv.get("pac", 0)           # inverter AC power, W (<0 export, >0 import)

pv  = -(pb + pac)                 # derived PV generation, W
if pv < 0:                        # opposite-sign cancel = no PV (e.g. night)
    pv = 0

batt = "charging" if pb < 0 else ("discharging" if pb > 0 else "idle")

UNAVAIL = "n/a (grid meter disabled)"

# House load + grid flow require the grid CT meter (device=3). It is disabled on
# this install (flg=0); when present we split them via the node balance:
#     PV + grid_import = house_load + battery_charge + grid_export
#   => house_load = PV + pb - grid_export   (battery_charge = -pb)
# ASSUMPTION (unverified - meter offline here): meter "pac" > 0 = export, < 0 = import.
if meter.get("flg", 0) == 1:
    grid = meter.get("pac", 0)               # signed: >0 export, <0 import
    load = pv + pb - grid                     # house load, W
    gridflow = "export" if grid > 0 else ("import" if grid < 0 else "idle")
    load_str = f"{load:6d} W"
    grid_str = f"{abs(grid):6d} W   {gridflow}"
else:
    load_str = UNAVAIL
    grid_str = UNAVAIL

print(f"  PV production     : {pv:6d} W   (derived: battery + inverter)")
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
