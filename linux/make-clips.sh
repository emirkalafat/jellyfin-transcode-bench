#!/usr/bin/env bash
# Cuts short video-only clips (stream copy, no re-encode) from a media library and sorts them
# into <out>/<class> folders for media-test.ps1.
#
# usage: make-clips.sh <source_dir> [out_dir=<repo>/media] [seconds=45] [start=600] [per_class=2]
# needs: ffmpeg in PATH (ffprobe is not required)
set -u
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SRC="${1:?usage: make-clips.sh <source_dir> [out_dir] [seconds] [start] [per_class]}"
OUT="${2:-$ROOT_DIR/media}"
SECS="${3:-45}"
START="${4:-600}"
PERCLASS="${5:-2}"

command -v ffmpeg >/dev/null || { echo "ffmpeg not found in PATH" >&2; exit 1; }
declare -A COUNT

while IFS= read -r -d '' f; do
  info="$(ffmpeg -hide_banner -i "$f" 2>&1 </dev/null)"
  vline="$(printf '%s\n' "$info" | grep -E 'Stream #[0-9]+:[0-9]+.*: Video: ' | grep -v 'attached pic' | head -n1)"
  [ -z "$vline" ] && continue

  codec="$(printf '%s' "$vline" | sed -E 's/.*Video: ([a-z0-9_]+).*/\1/; s/mpeg2video/mpeg2/')"
  dims="$(printf '%s' "$vline" | grep -oE '[0-9]{3,5}x[0-9]{3,5}' | head -n1)"
  w="${dims%x*}"; h="${dims#*x}"
  transfer="$(printf '%s' "$vline" | grep -oE '[a-z0-9]+/[a-z0-9]+/[a-z0-9-]+' | head -n1 | awk -F/ '{print $3}')"
  dvprof="$(printf '%s\n' "$info" | grep -oE 'DOVI configuration record:.*profile: [0-9]+' | head -n1 | grep -oE '[0-9]+$')"

  res=sd
  if [ "$w" -ge 3000 ] || [ "$h" -ge 2000 ]; then res=4k
  elif [ "$w" -ge 1800 ] || [ "$h" -ge 1000 ]; then res=1080p
  elif [ "$w" -ge 1200 ] || [ "$h" -ge 680 ]; then res=720p; fi

  dr=sdr
  if [ -n "$dvprof" ]; then dr="dv-p$dvprof"
  elif [ "$transfer" = "smpte2084" ]; then dr=hdr10
  elif [ "$transfer" = "arib-std-b67" ]; then dr=hlg; fi

  class="$codec-$res-$dr"
  case "$class" in
    *-dv-p*) folder=dolby-vision ;;
    h264-1080p-sdr|h264-4k-sdr|hevc-1080p-sdr|hevc-1080p-hdr10|hevc-4k-sdr|hevc-4k-hdr10|hevc-4k-hlg) folder="$class" ;;
    *) folder=other ;;
  esac

  n="${COUNT[$class]:-0}"
  [ "$n" -ge "$PERCLASS" ] && continue

  dur="$(printf '%s\n' "$info" | grep -oE 'Duration: [0-9]+:[0-9]+:[0-9.]+' | head -n1 | awk '{split($2,t,":"); print int(t[1]*3600+t[2]*60+t[3])}')"
  dur="${dur:-0}"
  ss="$START"
  if [ "$dur" -le $((START + SECS + 10)) ]; then ss=$((dur / 4)); fi

  base="$(basename "${f%.*}" | sed -E 's/[^A-Za-z0-9._-]+/_/g' | cut -c1-50)"
  mkdir -p "$OUT/$folder"
  dest="$OUT/$folder/${base}__${class}.mkv"
  echo "  $(basename "$f") -> $folder/$(basename "$dest")  [${w}x${h}, start ${ss}s]"
  if ffmpeg -hide_banner -loglevel error -y -ss "$ss" -t "$SECS" -i "$f" -map 0:v:0 -c:v copy -an -sn -dn "$dest" </dev/null; then
    COUNT[$class]=$((n + 1))
  else
    echo "    failed" >&2
  fi
done < <(find "$SRC" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mov' -o -iname '*.ts' -o -iname '*.m2ts' -o -iname '*.avi' -o -iname '*.webm' \) -print0)

echo
echo "Clips per class:"
for k in "${!COUNT[@]}"; do printf '  %-24s %s\n' "$k" "${COUNT[$k]}"; done | sort
echo "Done. Output: $OUT"
