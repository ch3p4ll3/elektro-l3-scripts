#!/bin/bash
# /usr/local/bin/l3-lrit.sh
#OUT=/home/mattia/Desktop/elektro_l3/$(date -u +%Y%m%d_%H%M)

#mkdir OUT

#exec satdump legacy live elektro_lrit "$OUT" \
#  --source rtlsdr --samplerate 1.024e6 --frequency 1691e6 \
#  --gain 40.2 --bias --dc_block --timeout 1500

#!/bin/bash
# /usr/local/bin/l3-lrit.sh
set -u
STAMP=$(date -u +%Y%m%d_%H%M)
#BASE=/home/mattia/Desktop/elektro_l3/baseband/l3_$STAMP     # no extension: SatDump adds it
OUT=/home/mattia/Desktop/elektro_l3/hrit/products/$STAMP

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
