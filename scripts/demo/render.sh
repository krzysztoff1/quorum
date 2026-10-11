#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${WORK:-/tmp/quorum-demo}"
TAKE1="${TAKE1:-$WORK/take1}"
TAKE2="${TAKE2:-$WORK/take2}"
OUT="${OUT:-$WORK/out}"

mkdir -p "$WORK/bin" "$OUT"

swiftc -O -o "$WORK/bin/record" "$HERE/record.swift"
swiftc -O -o "$WORK/bin/director" "$HERE/director.swift"
swiftc -O -o "$WORK/bin/edit" "$HERE/edit.swift"

constant_frame_rate() {
    local source="$1"
    local target="${source%.mov}_cfr.mov"
    ffmpeg -v error -y -i "$source" -vf fps=60 -c:v hevc_videotoolbox -b:v 40M -tag:v hvc1 "$target"
    cp "$source.epoch" "$target.epoch"
}

if [ "${1:-}" = "cfr" ]; then
    constant_frame_rate "$TAKE1/live.mov"
    constant_frame_rate "$TAKE2/answer.mov"
    exit 0
fi

sed -e "s#\$REPO#$REPO#g" -e "s#\$TAKE1#$TAKE1#g" -e "s#\$TAKE2#$TAKE2#g" -e "s#\$OUT#$OUT#g" \
    "$HERE/edl.template.json" > "$OUT/edl.json"

"$WORK/bin/edit" "$OUT/edl.json"

ffmpeg -v error -y -ss 50 -i "$OUT/demo.mp4" -frames:v 1 "$OUT/demo-poster.png"
ffmpeg -v error -y -ss 43 -t 11 -i "$OUT/demo.mp4" \
    -vf "fps=10,scale=640:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=48:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
    "$OUT/demo-preview.gif"

echo "$OUT/demo.mp4  $OUT/demo-poster.png  $OUT/demo-preview.gif"
