#!/usr/bin/env bash
#
# Processes every ELEKTRO-L3 product with SatDump (in parallel) and copies
# the generated composites into:
#   <OUT_ROOT>/<composite name>/<date of image>.png
# Products whose images already exist for that acquisition are skipped
# (SatDump is not run); pass -o to regenerate and overwrite them.
#
# Expected input layout:
#   <PRODUCTS_ROOT>/<date>/IMAGES/ELEKTRO-L3/<date>/.../product.cbor
# (product.cbor is searched at any depth under each acquisition folder)
#
# <PRODUCTS_ROOT> = <L3_HOME>/lrit/products, <OUT_ROOT> = <L3_HOME>/lrit/images.
# <L3_HOME> defaults to ~/Desktop/elektro_l3; see the config block below.
#
# Usage:
#   ./generate_images.sh [-d L3_HOME] [-j JOBS] [-o] [products date folder]
#
#   -o   overwrite: do not skip already generated images, run SatDump again
#        and replace them
#
#   ./generate_images.sh                      # everything new, JOBS = 4
#   ./generate_images.sh -o                   # regenerate everything
#   ./generate_images.sh -j 8                 # 8 parallel satdump processes
#   ./generate_images.sh 20261028_1241        # only products/20261028_1241
#   ./generate_images.sh -d /data/elektro_l3 -j 2 20261028_1241

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
JOBS=4
OVERWRITE=0

while getopts ":d:j:o" opt; do
    case "$opt" in
        d) L3_HOME="$OPTARG" ;;
        j) JOBS="$OPTARG" ;;
        o) OVERWRITE=1 ;;
        *) echo "Usage: $0 [-d L3_HOME] [-j JOBS] [-o] [products date folder]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

L3_HOME="${L3_HOME%/}"
PRODUCTS_ROOT="$L3_HOME/lrit/products"
OUT_ROOT="$L3_HOME/lrit/images"

if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: -j needs a positive integer" >&2
    exit 1
fi

if ! command -v satdump >/dev/null 2>&1; then
    echo "Error: satdump not found in PATH" >&2
    exit 1
fi

if [[ ! -d "$PRODUCTS_ROOT" ]]; then
    echo "Error: directory not found: $PRODUCTS_ROOT" >&2
    exit 1
fi

# Temporary working directory, removed on exit
TMP_ROOT="$(mktemp -d /tmp/elektro_satdump.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

shopt -s nullglob

# Processes one product folder: runs satdump in a tmp dir, copies the PNGs
process_one() {
    local acq_dir="$1" cbor="$2"
    local image_date folder rel name safe_name tmp_out img composite dest_dir found

    image_date="$(basename "$acq_dir")"
    folder="$(dirname "$cbor")"
    rel="${folder#"$acq_dir"}"
    rel="${rel#/}"
    name="${rel:-.}"
    safe_name="${rel//\//_}"
    safe_name="${safe_name:-root}"
    tmp_out="$TMP_ROOT/${image_date}_${safe_name}"
    mkdir -p "$tmp_out"

    echo "[run ] $image_date/$name"
    if ! satdump process "$folder" "$tmp_out" >"$tmp_out.log" 2>&1; then
        echo "[fail] $image_date/$name (log: $tmp_out.log)" >&2
        cat "$tmp_out.log" >&2
        rm -rf "$tmp_out"
        return 1
    fi

    found=0
    while IFS= read -r -d '' img; do
        found=1
        composite="$(basename "$img" .png)"
        dest_dir="$OUT_ROOT/$composite"
        mkdir -p "$dest_dir"
        cp -f "$img" "$dest_dir/$image_date.png"
        echo "[ok  ] $dest_dir/$image_date.png"
    done < <(find "$tmp_out" -type f -name '*.png' -print0)

    [[ $found -eq 0 ]] && echo "[warn] $image_date/$name: no PNG generated"

    rm -rf "$tmp_out" "$tmp_out.log"
    return 0
}

# True if at least one composite PNG already exists for this acquisition
# (<OUT_ROOT>/<composite>/<image_date>.png). The composite set is only known
# after SatDump has run, so any existing output counts as "already generated".
already_generated() {
    local image_date="$1" f
    for f in "$OUT_ROOT"/*/"$image_date.png"; do
        [[ -e "$f" ]] && return 0
    done
    return 1
}

# Optional argument: restrict to a single products/<date> folder
if [[ $# -ge 1 ]]; then
    product_dirs=("$PRODUCTS_ROOT/$1")
else
    product_dirs=("$PRODUCTS_ROOT"/*/)
fi

# Collect every (acquisition folder, product.cbor) pair first
tasks=()
skipped=0
for product_dir in "${product_dirs[@]}"; do
    product_dir="${product_dir%/}"
    for acq_dir in "$product_dir"/IMAGES/ELEKTRO-L3/*/; do
        acq_dir="${acq_dir%/}"
        if [[ $OVERWRITE -eq 0 ]] && already_generated "$(basename "$acq_dir")"; then
            echo "[skip] $(basename "$acq_dir"): images already generated (use -o to overwrite)"
            skipped=$((skipped + 1))
            continue
        fi
        while IFS= read -r -d '' cbor; do
            tasks+=("$acq_dir|$cbor")
        done < <(find "$acq_dir" -type f -name 'product.cbor' -print0 | sort -z)
    done
done

if [[ ${#tasks[@]} -eq 0 ]]; then
    if [[ $skipped -gt 0 ]]; then
        echo "Nothing to do: $skipped acquisition(s) already generated (use -o to overwrite)."
        exit 0
    fi
    echo "No product.cbor found under $PRODUCTS_ROOT" >&2
    exit 1
fi

echo "Found ${#tasks[@]} product(s), running up to $JOBS in parallel"

# Run up to $JOBS tasks at the same time
failed=0
for task in "${tasks[@]}"; do
    while (( $(jobs -rp | wc -l) >= JOBS )); do
        wait -n || failed=$((failed + 1))
    done
    process_one "${task%%|*}" "${task#*|}" &
done

# Wait for the remaining jobs
while (( $(jobs -rp | wc -l) > 0 )); do
    wait -n || failed=$((failed + 1))
done

if [[ $failed -gt 0 ]]; then
    echo "Done, with $failed failed product(s)." >&2
    exit 1
fi

echo "Done."
