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
  local ess inv
  ess="$(query 4)" || { echo "query device=4 failed" >&2; return 1; }  # ESS / battery
  inv="$(query 2)" || { echo "query device=2 failed" >&2; return 1; }  # inverter AC side

  ESS_JSON="$ess" INV_JSON="$inv" python3 - <<'PY'
import json, os

ess = json.loads(os.environ["ESS_JSON"])
inv = json.loads(os.environ["INV_JSON"])

# NOTE: this dongle's firmware never populates ess["ppv"] (stuck at 0), and the
# grid CT meter (device=3) is disabled (flg=0), so true grid/load split is not
# available locally. PV is derived from the battery + inverter AC balance:
#     PV = battery_power + inverter_AC_output
# Verified against the Solplanet app: 421+420=841 W and 220+81=301 W (~298 shown).
soc = ess.get("soc", 0)           # state of charge, %
pb  = ess.get("pb", 0)            # battery power, W  (>0 charge, <0 discharge)
vb  = ess.get("vb", 0) / 100.0    # battery voltage, V
pac = inv.get("pac", 0)           # inverter AC output, W (>0 to AC bus, <0 from)

pv  = pb + pac                    # derived PV generation, W

batt = "charging   " if pb > 0 else ("discharging" if pb < 0 else "idle       ")
acflow = "to load/grid" if pac > 0 else ("from grid" if pac < 0 else "idle")

print(f"  PV generation     : {pv:6d} W   (derived: battery + inverter)")
print(f"  Battery charge    : {soc:6d} %   ({vb:.2f} V)")
print(f"  Battery flow      : {abs(pb):6d} W   {batt}")
print(f"  Inverter AC output: {abs(pac):6d} W   {acflow}")
print(f"  (house load / grid split unavailable - grid meter disabled)")
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
