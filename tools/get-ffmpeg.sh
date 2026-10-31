#!/usr/bin/env bash
# get-ffmpeg.sh - download the latest jellyfin-ffmpeg portable build for Linux into <repo>/ffmpeg-jellyfin/linux/
# and verify its SHA256 (hash taken from the GitHub release metadata).
#
# jellyfin-ffmpeg is the ffmpeg a Jellyfin server actually runs and the only build with every filter the benchmark can
# use (tonemap_cuda, tonemap_opencl, libplacebo, vpp_qsv, scale_cuda, zscale ...); the benchmark prefers it over any other ffmpeg.
# Source: https://github.com/jellyfin/jellyfin-ffmpeg/releases
#
# usage: bash tools/get-ffmpeg.sh [--version v8.1.3-1] [--from-file archive.tar.xz] [--check]
set -u
ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
DEST="$ROOT_DIR/ffmpeg-jellyfin/linux"
VERSION=latest; FROM_FILE=""; CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2;;
    --from-file) FROM_FILE="$2"; shift 2;;
    --check) CHECK=1; shift;;
    -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
done
for t in curl sha256sum tar awk; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

case "$(uname -m)" in x86_64|amd64) ARCH=linux64-gpl;; aarch64|arm64) ARCH=linuxarm64-gpl;; *) echo "unsupported CPU: $(uname -m)" >&2; exit 1;; esac
if [ "$VERSION" = latest ]; then API="https://api.github.com/repos/jellyfin/jellyfin-ffmpeg/releases/latest"
else API="https://api.github.com/repos/jellyfin/jellyfin-ffmpeg/releases/tags/$VERSION"; fi

echo "Querying $API"
JSON="$(curl -fsSL -A jellyfin-transcode-bench "$API")" || { echo "GitHub API request failed" >&2; exit 1; }
TAG="$(grep -m1 '"tag_name"' <<<"$JSON" | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
ASSET="jellyfin-ffmpeg_${TAG#v}_portable_${ARCH}.tar.xz"
grep -q "\"name\": *\"$ASSET\"" <<<"$JSON" || { echo "No asset $ASSET in release $TAG" >&2; exit 1; }
# The API answers with one compact JSON line: cut everything up to this asset's name, then take the first digest after it.
EXPECTED="$(printf '%s' "$JSON" | sed -E "s/.*\"name\": *\"$ASSET\"//" | grep -oE '"digest": *"sha256:[0-9a-f]{64}"' | head -n1 | sed -E 's/.*sha256:([0-9a-f]+)".*/\1/')"
URL="https://github.com/jellyfin/jellyfin-ffmpeg/releases/download/$TAG/$ASSET"
echo "Release $TAG: $ASSET, sha256 ${EXPECTED:-not published}"
[ "$CHECK" = 1 ] && { echo "Check only, nothing downloaded."; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ -n "$FROM_FILE" ]; then ARCHIVE="$FROM_FILE"
else ARCHIVE="$TMP/$ASSET"; echo "Downloading $URL"; curl -fL --progress-bar -o "$ARCHIVE" "$URL" || exit 1; fi
SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
if [ -n "$EXPECTED" ]; then
  [ "$SHA" = "$EXPECTED" ] || { echo "SHA256 mismatch: expected $EXPECTED, got $SHA" >&2; exit 1; }
  echo "SHA256 verified."
else echo "No published hash to compare against (sha256 $SHA)."; fi

mkdir -p "$TMP/extract" "$DEST"
tar -xf "$ARCHIVE" -C "$TMP/extract" || exit 1
BIN="$(find "$TMP/extract" -type f -name ffmpeg | head -n1)"
[ -n "$BIN" ] || { echo "ffmpeg not found inside the archive" >&2; exit 1; }
cp "$BIN" "$DEST/ffmpeg" && chmod +x "$DEST/ffmpeg"
printf '%s\n%s\nsha256 %s\n' "$TAG" "$ASSET" "$SHA" >"$ROOT_DIR/ffmpeg-jellyfin/VERSION.txt"
echo "Installed: $DEST/ffmpeg"
"$DEST/ffmpeg" -hide_banner -version | head -n1
