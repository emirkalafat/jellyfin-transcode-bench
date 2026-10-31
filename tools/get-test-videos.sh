#!/usr/bin/env bash
# get-test-videos.sh - download a curated set of the official Jellyfin test videos into <repo>/media/ so the
# benchmark can run without any personal media.
#
# Source: https://repo.jellyfin.org/test-videos/  (courtesy of Gnattu, licensed CC BY-SA 4.0).
# Every file is verified against the .sha256sum published next to it; verified files already present are skipped.
#
#   mini     1080p only: H.264, HEVC 8/10-bit, AV1, HDR10, Dolby Vision P5 and P8.1   (7 files, ~270 MB)
#   starter  mini + 4K: H.264, HEVC 10-bit, HDR10 HEVC/AV1, Dolby Vision P5 and P8.1 (13 files, ~1.1 GB)
#
# usage: bash tools/get-test-videos.sh [--set mini|starter] [--out DIR] [--dry-run]
set -u
ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SET=starter; OUT="$ROOT_DIR/media"; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --set) SET="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
done
[ "$SET" = mini ] || [ "$SET" = starter ] || { echo "--set must be mini or starter" >&2; exit 1; }
command -v curl >/dev/null && command -v sha256sum >/dev/null || { echo "needs curl and sha256sum" >&2; exit 1; }
BASE="https://repo.jellyfin.org/test-videos"

# "path on the server|folder under media/"
ITEMS=(
  "SDR/AVC/Test Jellyfin 1080p AVC 10M.mp4|h264-1080p-sdr"
  "SDR/HEVC 8bit/Test Jellyfin 1080p HEVC 8bit 10M.mp4|hevc-1080p-sdr"
  "SDR/HEVC 10bit/Test Jellyfin 1080p HEVC 10bit 10M.mp4|hevc-1080p-sdr"
  "SDR/AV1/Test Jellyfin 1080p AV1 10bit 10M.mp4|other"
  "HDR/HDR10/HEVC/Test Jellyfin 1080p HEVC HDR10 10M.mp4|hevc-1080p-hdr10"
  "HDR/Dolby Vision/Test Jellyfin 1080p DV P8.1.mp4|dolby-vision"
  "HDR/Dolby Vision/Test Jellyfin 1080p DV P5.mp4|dolby-vision"
)
if [ "$SET" = starter ]; then ITEMS+=(
  "SDR/AVC/Test Jellyfin 4K AVC 40M.mp4|h264-4k-sdr"
  "SDR/HEVC 10bit/Test Jellyfin 4K HEVC 10bit 40M.mp4|hevc-4k-sdr"
  "HDR/HDR10/HEVC/Test Jellyfin 4K HEVC HDR10 40M.mp4|hevc-4k-hdr10"
  "HDR/HDR10/AV1/Test Jellyfin 4K AV1 HDR10 40M.mp4|other"
  "HDR/Dolby Vision/Test Jellyfin 4K DV P8.1.mp4|dolby-vision"
  "HDR/Dolby Vision/Test Jellyfin 4K DV P5.mp4|dolby-vision"
); fi

urlenc() { local s="$1" out="" c i; for ((i = 0; i < ${#s}; i++)); do c="${s:i:1}"; case "$c" in [A-Za-z0-9._~/-]) out+="$c";; *) out+="$(printf '%%%02X' "'$c")";; esac; done; printf '%s' "$out"; }

total=0
echo "Set '$SET': ${#ITEMS[@]} files -> $OUT"
for it in "${ITEMS[@]}"; do
  rel="${it%%|*}"; folder="${it##*|}"
  size="$(curl -sI -m 20 "$BASE/$(urlenc "$rel")" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')"; size="${size:-0}"
  total=$((total + size))
  printf '  %-16s %6d MB  %s\n' "$folder" $((size / 1048576)) "$(basename "$rel")"
done
echo "Total: $((total / 1048576)) MB"
[ "$DRY" = 1 ] && { echo "Dry run, nothing downloaded."; exit 0; }

for it in "${ITEMS[@]}"; do
  rel="${it%%|*}"; folder="${it##*|}"; name="$(basename "$rel")"; url="$BASE/$(urlenc "$rel")"
  mkdir -p "$OUT/$folder"; dest="$OUT/$folder/$name"
  expected="$(curl -fsS -m 20 "$url.sha256sum" 2>/dev/null | awk '{print tolower($1); exit}')"
  if [ -f "$dest" ] && [ -n "$expected" ] && [ "$(sha256sum "$dest" | awk '{print $1}')" = "$expected" ]; then echo "  have   $name"; continue; fi
  echo "  fetch  $name"
  curl -fL --progress-bar -o "$dest" "$url" || { echo "download failed: $name" >&2; exit 1; }
  if [ -n "$expected" ] && [ "$(sha256sum "$dest" | awk '{print $1}')" != "$expected" ]; then rm -f "$dest"; echo "SHA256 mismatch for $name, file removed" >&2; exit 1; fi
done
echo "Done. Test videos: Jellyfin test videos, courtesy of Gnattu, CC BY-SA 4.0 (https://repo.jellyfin.org/test-videos/)"
