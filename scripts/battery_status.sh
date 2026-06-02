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
  local ess grid
  ess="$(query 4)"  || { echo "query device=4 failed" >&2; return 1; }
  grid="$(query 2)" || { echo "query device=2 failed" >&2; return 1; }

  ESS_JSON="$ess" GRID_JSON="$grid" python3 - <<'PY'
import json, os

ess  = json.loads(os.environ["ESS_JSON"])
grid = json.loads(os.environ["GRID_JSON"])

ppv = ess.get("ppv", 0)          # PV power, W
soc = ess.get("soc", 0)          # state of charge, %
pb  = ess.get("pb", 0)           # battery power, W  (>0 charge, <0 discharge)
vb  = ess.get("vb", 0) / 100.0   # battery voltage, V
pac = grid.get("pac", 0)         # grid power, W     (<0 import, >0 export)

# House load by energy balance: load = PV - battery - grid
load = ppv - pb - pac

batt = "charging   " if pb > 0 else ("discharging" if pb < 0 else "idle       ")
gridflow = "import" if pac < 0 else ("export" if pac > 0 else "idle  ")

print(f"  PV generation     : {ppv:6d} W")
print(f"  Battery charge    : {soc:6d} %   ({vb:.2f} V)")
print(f"  Battery flow      : {abs(pb):6d} W   {batt}")
print(f"  House load        : {load:6d} W")
print(f"  Grid flow         : {abs(pac):6d} W   {gridflow}")
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
