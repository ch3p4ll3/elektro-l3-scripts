#!/bin/bash
# /usr/local/bin/l3-lrit.sh
#OUT=$L3_HOME/$(date -u +%Y%m%d_%H%M)

#mkdir OUT

#exec satdump legacy live elektro_lrit "$OUT" \
#  --source rtlsdr --samplerate 1.024e6 --frequency 1691e6 \
#  --gain 40.2 --bias --dc_block --timeout 1500

#!/bin/bash
# /usr/local/bin/l3-lrit.sh
set -u

# --- elektro_l3 home folder -------------------------------------------------
# Resolution order (first match wins):
#   1. -d DIR
#   2. $L3_HOME in the environment
#   3. L3_HOME in /etc/elektro-l3.conf (written by install.sh --home DIR)
#   4. $HOME/Desktop/elektro_l3
L3_CONF="${L3_CONF:-/etc/elektro-l3.conf}"
if [[ -z "${L3_HOME:-}" && -r "$L3_CONF" ]]; then
    # shellcheck disable=SC1090
    . "$L3_CONF"
fi
L3_HOME="${L3_HOME:-$HOME/Desktop/elektro_l3}"

while getopts ":d:" opt; do
    case "$opt" in
        d) L3_HOME="$OPTARG" ;;
        *) echo "Usage: $0 [-d L3_HOME]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
L3_HOME="${L3_HOME%/}"

STAMP=$(date -u +%Y%m%d_%H%M)
#BASE=$L3_HOME/baseband/l3_$STAMP     # no extension: SatDump adds it
OUT="$L3_HOME/hrit/products/$STAMP"

mkdir -p "$OUT"

# Record
#satdump legacy record "$BASE" \
#  --source rtlsdr --samplerate 1.024e6 --frequency 1691e6 \
#  --gain 40.2 --bias --baseband_format cs8 --timeout 900

# Decode the recording
#FILE=$(ls "$BASE".* 2>/dev/null | head -n1)
#[ -n "$FILE" ] || { echo "no baseband recorded"; exit 1; }

#satdump pipeline elektro_lrit baseband "$FILE" "$OUT" \
#  --samplerate 1.024e6 --baseband_format cs8 --dc_block true

exec satdump legacy live elektro_hrit "$OUT" \
  --source rtltcp --ip_address 192.168.0.1 --port 1234 --samplerate 2.56e6 --frequency 1691e6 \
  --gain 32.8 --bias --dc_block true --timeout 900 --http_server 0.0.0.0:8080
