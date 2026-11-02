#!/usr/bin/env bash
#
# Generates a LOSSLESS timelapse video for every composite folder produced by
# elektro_process.sh.
#
# Input layout:
#   <IMAGES_ROOT>/<composite name>/<date>.png
# Output:
#   <TIMELAPSE_ROOT>/<composite name>.mkv
# (kept outside IMAGES_ROOT so it is never mistaken for a composite folder)
#
# Video is encoded with FFV1 (lossless, intra-only): every frame is
# bit-identical to the source PNG, with no resizing, no chroma subsampling
# and no color conversion beyond a lossless RGB channel reorder.
# Existing videos are overwritten. Frames are ordered by file name, which
# works because the date format (YYYYMMDD_HHMM) sorts chronologically.
#
# Note: .mkv/FFV1 plays fine in VLC, mpv, ffplay, but not in web browsers.
#
# A second, phone-compatible H.264 .mp4 (high quality, but NOT lossless:
# phones cannot play lossless video) is also written next to the .mkv.
# Use -L to skip it, -w WIDTH to downscale it (e.g. 2048 for older phones).
#
# <IMAGES_ROOT> = <L3_HOME>/lrit/images, <TIMELAPSE_ROOT> = <L3_HOME>/lrit/timelapses.
# <L3_HOME> defaults to ~/Desktop/elektro_l3; see the config block below.
#
# Usage:
#   ./generate_timelapse.sh [-d L3_HOME] [-j JOBS] [-f FPS] [-w WIDTH] [-L] [composite name]
#
#   ./generate_timelapse.sh                   # all composites, 4 jobs, 10 fps
#   ./generate_timelapse.sh -f 15             # 15 frames per second
#   ./generate_timelapse.sh -d /data/elektro_l3 -j 2 "msu_gs_Natural_Color"

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
FPS=10

PHONE=1     # also create a phone-friendly .mp4 next to the lossless .mkv
WIDTH=0     # width of the phone .mp4 (0 = keep original size)

while getopts ":d:j:f:w:L" opt; do
    case "$opt" in
        d) L3_HOME="$OPTARG" ;;
        j) JOBS="$OPTARG" ;;
        f) FPS="$OPTARG" ;;
        w) WIDTH="$OPTARG" ;;
        L) PHONE=0 ;;
        *) echo "Usage: $0 [-d L3_HOME] [-j JOBS] [-f FPS] [-w WIDTH] [-L] [composite name]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

L3_HOME="${L3_HOME%/}"
IMAGES_ROOT="$L3_HOME/lrit/images"
TIMELAPSE_ROOT="$L3_HOME/lrit/timelapses"

for pair in "JOBS:$JOBS" "FPS:$FPS"; do
    label="${pair%%:*}"; value="${pair#*:}"
    if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: -${label,,} needs a positive integer (got: $value)" >&2
        exit 1
    fi
done

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Error: ffmpeg not found in PATH" >&2
    exit 1
fi

if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE '^ [A-Z.]+ ffv1( |$)'; then
    echo "Error: this ffmpeg build has no FFV1 encoder" >&2
    exit 1
fi

if ! [[ "$WIDTH" =~ ^[0-9]+$ ]]; then
    echo "Error: -w needs a non-negative integer (got: $WIDTH)" >&2
    exit 1
fi

# Phone-friendly H.264 encoder (the lossless .mkv is always made as well)
MP4_ARGS=()
if [[ $PHONE -eq 1 ]]; then
    ENCODERS="$(ffmpeg -hide_banner -encoders 2>/dev/null)"
    if grep -qE '^ [A-Z.]+ libx264( |$)' <<<"$ENCODERS"; then
        MP4_NAME="libx264"
        MP4_ARGS=(-c:v libx264 -preset slow -crf 10 -profile:v high -movflags +faststart)
    elif grep -qE '^ [A-Z.]+ libopenh264( |$)' <<<"$ENCODERS"; then
        MP4_NAME="libopenh264"
        MP4_ARGS=(-c:v libopenh264 -rc_mode bitrate -b:v 100M -profile:v high -movflags +faststart)
    else
        echo "Warning: no H.264 encoder found, skipping phone .mp4 (only .mkv will be made)" >&2
        PHONE=0
    fi
fi

# Video filter for the phone version: even dimensions, YUV 4:2:0 with the
# BT.709 matrix so colors look right on phones.
if [[ "$WIDTH" -gt 0 ]]; then
    MP4_VF="scale=${WIDTH}:-2:flags=lanczos+accurate_rnd+full_chroma_int:out_color_matrix=bt709:out_range=tv,format=yuv420p"
else
    MP4_VF="scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=lanczos+accurate_rnd+full_chroma_int:out_color_matrix=bt709:out_range=tv,format=yuv420p"
fi

if [[ ! -d "$IMAGES_ROOT" ]]; then
    echo "Error: directory not found: $IMAGES_ROOT" >&2
    exit 1
fi

mkdir -p "$TIMELAPSE_ROOT"

shopt -s nullglob

# Builds the timelapse for one composite folder
make_timelapse() {
    local dir="$1" name out tmp_out log count
    name="$(basename "$dir")"
    out="$TIMELAPSE_ROOT/$name.mkv"
    tmp_out="$TIMELAPSE_ROOT/.$name.tmp.mkv"
    log="$TIMELAPSE_ROOT/.$name.log"

    local frames=("$dir"/*.png)
    count=${#frames[@]}

    if [[ $count -lt 2 ]]; then
        echo "[skip] $name: only $count image(s), need at least 2"
        return 0
    fi

    echo "[run ] $name ($count frames)"
    # No -vf: the pixel format is negotiated automatically and losslessly
    # (RGB PNG -> FFV1 RGB, grayscale PNG -> FFV1 gray).
    if ! ffmpeg -y -hide_banner -loglevel error \
            -framerate "$FPS" -pattern_type glob -i "$dir/*.png" \
            -c:v ffv1 -level 3 -coder 1 -context 1 -g 1 -slicecrc 1 \
            -f matroska "$tmp_out" >"$log" 2>&1; then
        echo "[fail] $name (log: $log)" >&2
        cat "$log" >&2
        rm -f "$tmp_out"
        return 1
    fi

    mv -f "$tmp_out" "$out"
    rm -f "$log"
    echo "[ok  ] $out"

    # Phone-friendly H.264 .mp4, encoded straight from the PNGs
    if [[ $PHONE -eq 1 ]]; then
        local mp4_out="$TIMELAPSE_ROOT/$name.mp4"
        local mp4_tmp="$TIMELAPSE_ROOT/.$name.tmp.mp4"
        if ! ffmpeg -y -hide_banner -loglevel error \
                -framerate "$FPS" -pattern_type glob -i "$dir/*.png" \
                -vf "$MP4_VF" "${MP4_ARGS[@]}" \
                -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
                "$mp4_tmp" >"$log" 2>&1; then
            echo "[fail] $name.mp4 (log: $log)" >&2
            cat "$log" >&2
            rm -f "$mp4_tmp"
            return 1
        fi
        mv -f "$mp4_tmp" "$mp4_out"
        rm -f "$log"
        echo "[ok  ] $mp4_out"
    fi
    return 0
}

# Optional argument: restrict to a single composite folder
if [[ $# -ge 1 ]]; then
    composite_dirs=("$IMAGES_ROOT/$1")
    if [[ ! -d "${composite_dirs[0]}" ]]; then
        echo "Error: composite folder not found: ${composite_dirs[0]}" >&2
        exit 1
    fi
else
    composite_dirs=("$IMAGES_ROOT"/*/)
fi

if [[ ${#composite_dirs[@]} -eq 0 ]]; then
    echo "No composite folders found under $IMAGES_ROOT" >&2
    exit 1
fi

if [[ $PHONE -eq 1 ]]; then
    echo "Found ${#composite_dirs[@]} composite folder(s), running up to $JOBS in parallel (${FPS} fps, lossless FFV1 .mkv + phone .mp4 via $MP4_NAME)"
else
    echo "Found ${#composite_dirs[@]} composite folder(s), running up to $JOBS in parallel (${FPS} fps, lossless FFV1 .mkv only)"
fi

# Run up to $JOBS encodes at the same time
failed=0
for dir in "${composite_dirs[@]}"; do
    dir="${dir%/}"
    while (( $(jobs -rp | wc -l) >= JOBS )); do
        wait -n || failed=$((failed + 1))
    done
    make_timelapse "$dir" &
done

# Wait for the remaining jobs
while (( $(jobs -rp | wc -l) > 0 )); do
    wait -n || failed=$((failed + 1))
done

if [[ $failed -gt 0 ]]; then
    echo "Done, with $failed failed timelapse(s)." >&2
    exit 1
fi

echo "Done."