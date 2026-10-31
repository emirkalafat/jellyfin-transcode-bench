#!/usr/bin/env bash
# media-test.sh - real-content transcode benchmark for Linux: CPU vs Intel (VAAPI/QSV) vs AMD (VAAPI) vs NVIDIA (NVENC).
# Linux counterpart of media-test.ps1.  Run with:  bash linux/media-test.sh [options]
#
# At start every GPU is inventoried and every hardware path is probed (see "Probing hardware paths").
# Then each clip under ./media is classified (codec / resolution / SDR-HDR10-HLG-Dolby Vision) and a short
# piece is transcoded to H.264 with the scenarios that make sense for it:
#   to1080  fit inside 1920x1080     to720  fit inside 1280x720     same  keep resolution
# HDR sources are tone-mapped to SDR (Dolby Vision profile 5 cannot be: timed without tone-mapping).
# Variants (a variant is skipped with a reason when it cannot work; engines are only used when the GPU exists):
#   cpu          software decode + filters + libx264
#   vaapi        VAAPI decode + scale_vaapi/tonemap_vaapi + h264_vaapi, once per Intel/AMD render node
#                (rows are named vaapi-intel, vaapi-amd, ...)
#   qsv          QSV decode + vpp_qsv + h264_qsv                       (Intel)
#   nv           NVDEC decode + scale_cuda/tonemap_cuda + h264_nvenc   (NVIDIA)
#   hybv hybq hybn   CPU decode + filters, hardware encode (VAAPI / QSV / NVENC)
#   vad nvd      hardware decode, CPU tone-map (HDR only), hardware encode (VAAPI / NVIDIA)
#   cl           CPU decode, OpenCL tone-map (HDR only), hardware or software encode
#   plc          CPU decode, libplacebo (Vulkan GPU) tone-map + scale, hardware or software encode (HDR only, any vendor)
# Then runs N parallel copies of the best non-CPU variant per source class.
# Output: results/media_<host>_<time>/report.md + results.tsv + logs/
#
# Options:
#   --media DIR         clips folder (default <repo>/media)
#   --clip SEC          seconds transcoded per run (default 30; start-up cost is included, so very short clips understate fast GPU paths)
#   --clip-start SEC    seek position for long files (default 120; short clips start at 0)
#   --timeout SEC       per-run timeout (default 240; partial fps still reported)
#   --streams "1 2 3"   parallel-stream steps (default "1 2 3 4")
#   --filter GLOB       only files/classes matching, e.g. '*hdr*' or 'hevc-4k*'
#   --variants "..."    subset of: cpu vaapi qsv nv hybv hybq hybn vad nvd cl plc   (default all)
#   --scenarios "..."   subset of: to1080 to720 same                    (default all)
#   --max-files N       stop after N files
#   --no-concurrency    skip parallel-stream tests
#   --no-local-copy     do not copy clips from a network share to local disk first
#   --quick             10 s clips, 120 s timeout, streams "1 2 3"
#   --ffmpeg PATH  --device /dev/dri/renderDxxx (only probe/test that VAAPI node)  --libva-driver NAME  --keep-work

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"   # repository root: media/, results/, ffmpeg-*/ live here
. "$SCRIPT_DIR/lib-common.sh" || exit 1

MEDIA_DIR="$ROOT_DIR/media"; CLIP=30; CLIP_START=120; TIMEOUT=240; STREAMS="1 2 3 4"; FILTER="*"
VARIANTS="cpu vaapi qsv nv hybv hybq hybn vad nvd cl plc"; SCENARIOS="to1080 to720 same"; MAX_FILES=0
NO_CONC=0; LOCAL_COPY=1; QUICK=0; KEEP_WORK=0; FFMPEG_ARG=""; DEVICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --media) MEDIA_DIR="$2"; shift 2;;
    --clip) CLIP="$2"; shift 2;;
    --clip-start) CLIP_START="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --streams) STREAMS="$2"; shift 2;;
    --filter) FILTER="$2"; shift 2;;
    --variants) VARIANTS="$2"; shift 2;;
    --scenarios) SCENARIOS="$2"; shift 2;;
    --max-files) MAX_FILES="$2"; shift 2;;
    --no-concurrency) NO_CONC=1; shift;;
    --no-local-copy) LOCAL_COPY=0; shift;;
    --quick) QUICK=1; shift;;
    --ffmpeg) FFMPEG_ARG="$2"; shift 2;;
    --device) DEVICE="$2"; shift 2;;
    --libva-driver) export LIBVA_DRIVER_NAME="$2"; shift 2;;
    --keep-work) KEEP_WORK=1; shift;;
    -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown option: $1 (see --help)";;
  esac
done
[ "$QUICK" = 1 ] && { CLIP=10; TIMEOUT=120; STREAMS="1 2 3"; }
want() { case " $2 " in *" $1 "*) return 0;; esac; return 1; }   # want <item> "<list>"

init_run media
trap cleanup_work EXIT
find_ffmpeg

section "GPU inventory"
detect_gpus
print_gpu_inventory
section "System info"
collect_sysinfo
section "ffmpeg capabilities"
load_caps
for n in libx264 h264_vaapi h264_qsv h264_nvenc; do printf '  enc %-12s %s\n' "$n" "$(has_enc $n && echo yes || echo no)"; done
for n in scale_vaapi tonemap_vaapi vpp_qsv scale_cuda tonemap_cuda tonemap_opencl zscale tonemap; do printf '  filter %-14s %s\n' "$n" "$(has_filter $n && echo yes || echo no)"; done
has_enc libx264 || die "this ffmpeg has no libx264"
PROBE_SRC="$WORK/probe_h264.mp4"
ffq -y -f lavfi -i testsrc2=size=1280x720:rate=30 -t 3 -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$PROBE_SRC" >"$LOGDIR/gen_probe.txt" 2>&1 \
  || die "cannot create probe clip (see $LOGDIR/gen_probe.txt)"
section "Probing hardware paths"
probe_hw
gpu_detect
while IFS= read -r l; do SYS_LINES+=("Engine|$l"); done < <(engine_summary_lines)

# ------------------------------------------------------------------ media discovery
[ -d "$MEDIA_DIR" ] || die "media folder not found: $MEDIA_DIR"
if [ "$LOCAL_COPY" = 1 ]; then
  case "$(stat -f -c %T "$MEDIA_DIR" 2>/dev/null)" in
    nfs*|smb*|cifs|fuse.sshfs|fuse.rclone|9p|ceph|afs)
      section "Media folder is on a network filesystem; copying clips to local disk"
      cp -r "$MEDIA_DIR" "$WORK/media" && MEDIA_DIR="$WORK/media" || die "copy failed";;
  esac
fi

AWK_PROBE='
function trim(s) { gsub(/^ +| +$/, "", s); return s }
function split_top(s, arr,   i, n, ch, d, cur) {
  n = 0; d = 0; cur = ""
  for (i = 1; i <= length(s); i++) {
    ch = substr(s, i, 1)
    if (ch == "(" || ch == "[") d++
    else if (ch == ")" || ch == "]") d--
    if (ch == "," && d <= 0) { arr[++n] = trim(cur); cur = "" } else cur = cur ch
  }
  arr[++n] = trim(cur)
  return n
}
{ line[NR] = $0 }
END {
  vline = -1
  for (i = 1; i <= NR; i++) if (line[i] ~ /Stream #[0-9]+:[0-9]+.*: Video: / && line[i] !~ /attached pic/) { vline = i; break }
  if (vline < 0) exit 1
  body = substr(line[vline], index(line[vline], "Video: ") + 7)
  n = split_top(body, seg)
  codec = seg[1]; sub(/ .*/, "", codec)
  pix = seg[2]; colors = ""
  if (match(pix, /\([^)]*\)/)) colors = substr(pix, RSTART + 1, RLENGTH - 2)
  sub(/\(.*/, "", pix)
  w = 0; h = 0; fps = 0; tbr = 0
  for (k = 1; k <= n; k++) {
    if (seg[k] ~ /^[0-9][0-9]+x[0-9][0-9]+/ && w == 0) { tmp = seg[k]; sub(/[^0-9x].*/, "", tmp); split(tmp, wh, "x"); w = wh[1]; h = wh[2] }
    if (seg[k] ~ /^[0-9.]+ fps/) { tmp = seg[k]; sub(/ .*/, "", tmp); fps = tmp }
    if (seg[k] ~ /^[0-9.k]+ tbr/) { tmp = seg[k]; sub(/ .*/, "", tmp); tbr = tmp }
  }
  if (fps + 0 <= 0) fps = tbr
  if (fps + 0 <= 0) fps = 24
  transfer = ""; interlaced = 0
  nt = split(colors, tk, ",")
  for (k = 1; k <= nt; k++) {
    t = trim(tk[k])
    if (t ~ /^[a-z0-9]+\/[a-z0-9]+\/[a-z0-9-]+$/) { split(t, parts, "/"); transfer = parts[3] }
    if (t ~ /(top|bottom).*first/) interlaced = 1
  }
  dv = ""
  for (j = vline + 1; j <= vline + 15 && j <= NR; j++) {
    if (line[j] ~ /Stream #[0-9]+:[0-9]+/) break
    if (line[j] ~ /DOVI configuration record:/) { s = line[j]; if (match(s, /profile: *[0-9]+/)) { t = substr(s, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); dv = t } }
  }
  dur = 0; br = 0
  for (i = 1; i <= NR; i++) if (line[i] ~ /^ *Duration:/) {
    if (match(line[i], /Duration: *[0-9]+:[0-9]+:[0-9.]+/)) { t = substr(line[i], RSTART + 9, RLENGTH - 9); gsub(/ /, "", t); split(t, hms, ":"); dur = hms[1] * 3600 + hms[2] * 60 + hms[3] }
    if (match(line[i], /bitrate: *[0-9]+/)) { t = substr(line[i], RSTART, RLENGTH); gsub(/[^0-9]/, "", t); br = t / 1000 }
    break
  }
  print "codec=" codec; print "pix=" pix; print "w=" w; print "h=" h; print "fps=" fps; print "transfer=" transfer
  print "dv=" dv; print "dur=" dur; print "br=" br; print "interlaced=" interlaced
}'

probe_media() {   # probe_media <file> -> M_* variables; returns 1 when there is no video stream
  local f="$1" k v
  M_CODEC=""; M_PIX=""; M_W=0; M_H=0; M_FPS=24; M_TRANSFER=""; M_DV=""; M_DUR=0; M_BR=0; M_INTERLACED=0
  while IFS='=' read -r k v; do
    case "$k" in
      codec) M_CODEC="$v";; pix) M_PIX="$v";; w) M_W="$v";; h) M_H="$v";; fps) M_FPS="$v";;
      transfer) M_TRANSFER="$v";; dv) M_DV="$v";; dur) M_DUR="$v";; br) M_BR="$v";; interlaced) M_INTERLACED="$v";;
    esac
  done < <(ffq -i "$f" 2>&1 | awk "$AWK_PROBE")
  [ -n "$M_CODEC" ] && [ "$M_W" -gt 0 ] || return 1
  M_CODEC_SHORT="${M_CODEC/mpeg2video/mpeg2}"
  M_BITS=8; case "$M_PIX" in *10*) M_BITS=10;; *12*) M_BITS=12;; esac
  M_HDRTYPE=sdr
  if [ -n "$M_DV" ]; then M_HDRTYPE="dv-p$M_DV"
  elif [ "$M_TRANSFER" = smpte2084 ]; then M_HDRTYPE=hdr10
  elif [ "$M_TRANSFER" = arib-std-b67 ]; then M_HDRTYPE=hlg; fi
  M_ISHDR=0; [ "$M_HDRTYPE" != sdr ] && M_ISHDR=1
  M_RES=sd
  if [ "$M_W" -ge 3000 ] || [ "$M_H" -ge 2000 ]; then M_RES=4k
  elif [ "$M_W" -ge 1800 ] || [ "$M_H" -ge 1000 ]; then M_RES=1080p
  elif [ "$M_W" -ge 1200 ] || [ "$M_H" -ge 680 ]; then M_RES=720p; fi
  M_CLASS="${M_CODEC_SHORT}-${M_RES}-${M_HDRTYPE}"
  return 0
}

# ------------------------------------------------------------------ chains
fit_size() {   # fit_size <boxw> <boxh> -> FIT_W FIT_H FIT_RATIO
  read -r FIT_W FIT_H FIT_RATIO < <(awk -v w="$M_W" -v h="$M_H" -v bw="$1" -v bh="$2" \
    'BEGIN{ r=1; if (bw>0) { r1=bw/w; r2=bh/h; r=(r1<r2?r1:r2) } printf "%d %d %.4f\n", int(w*r/2+0.5)*2, int(h*r/2+0.5)*2, r }')
}
bitrate_m() { if [ "$1" -ge 1800 ]; then echo 20; elif [ "$1" -ge 900 ]; then echo 8; elif [ "$1" -ge 600 ]; then echo 4; else echo 2; fi; }

TM=0   # 1 = tone-map this source to SDR (set per file)
sw_chain() {   # sw_chain <W> <H> <outfmt>
  local W="$1" H="$2" fmt="$3" scale=0 tin size=""
  { [ "$W" != "$M_W" ] || [ "$H" != "$M_H" ]; } && scale=1
  if [ "$TM" = 1 ]; then
    tin=smpte2084; [ "$M_TRANSFER" = arib-std-b67 ] && tin=arib-std-b67
    [ $scale = 1 ] && size="w=${W}:h=${H}:"
    echo "zscale=${size}tin=${tin}:min=bt2020nc:pin=bt2020:rin=tv:t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=${fmt}"
  elif [ $scale = 1 ]; then echo "scale=${W}:${H},format=${fmt}"
  else echo "format=${fmt}"; fi
}

# ------------------------------------------------------------------ results plumbing
RESULTS_TSV="$OUTDIR/results.tsv"; INV_TSV="$OUTDIR/inventory.tsv"; ROWN=0
printf 'file\tclass\tscenario\tscenario_label\tvariant\tstatus\tframes\tseconds\tfps\trealtime\tcpu\tvcs\tvecs\trcs\terror\n' >"$RESULTS_TSV"
printf 'file\tclass\tresolution\tbits\tfps\tmbps\thdr\tsize_mb\thw_decode\n' >"$INV_TSV"
declare -A ROWCMD HWDEC_CACHE WARMED

# run_variant <variant> <scen_key> <scen_label> <skip_reason> -- <ffmpeg args...>
run_variant() {
  local variant="$1" skey="$2" slabel="$3" skip="$4"; shift 4; [ "$1" = "--" ] && shift
  local rt tag lbl
  ROWN=$((ROWN + 1)); lbl="$(printf '%-12s %s' "$variant" "$slabel")"
  if [ -n "$skip" ]; then
    printf '%s\t%s\t%s\t%s\t%s\tSKIP\t0\t0\t0\t0\t\t\t\t\t%s\n' "$CUR_FILE" "$M_CLASS" "$skey" "$slabel" "$variant" "$(tsv_clean "$skip")" >>"$RESULTS_TSV"
    printf '    %s%-52s SKIP  %s%s\n' "$C_GRAY" "$lbl" "$skip" "$C_RESET"; return
  fi
  ROWCMD["$CUR_FILE|$skey|$variant"]="$(printf '%q ' "$@")"
  # Warm-up: the first run of a GPU variant pays one-off costs (CUDA kernel JIT, driver init) that would be counted as
  # slow throughput. Run the same command for 2 s once per variant before timing it.
  if [ "$variant" != cpu ] && [ -z "${WARMED[$variant]:-}" ]; then
    WARMED[$variant]=1
    local warm=() wprev="" wa
    for wa in "$@"; do if [ "$wprev" = "-t" ] && [ "$wa" = "$CLIP" ]; then warm+=(2); else warm+=("$wa"); fi; wprev="$wa"; done
    timeout 90 "$FFMPEG" -hide_banner -nostdin -y "${warm[@]}" >/dev/null 2>&1
  fi
  tag="$(printf '%03d_%s_%s_%s' "$ROWN" "${CUR_BASE:0:20}" "$skey" "$variant")"
  exec_single "$tag" "$TIMEOUT" "$@"
  rt="$(awk -v f="$R_FPS" -v s="$M_FPS" 'BEGIN{printf "%.2f", f/s}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$CUR_FILE" "$M_CLASS" "$skey" "$slabel" "$variant" "$R_STATUS" "$R_FRAMES" "$R_SECS" \
    "$R_FPS" "$rt" "$M_CPU" "$G_VCS" "$G_VECS" "$G_RCS" "$(tsv_clean "$R_ERR")" >>"$RESULTS_TSV"
  if [ "$R_STATUS" = OK ] || { [ "$R_STATUS" = TIMEOUT ] && [ "$R_FRAMES" -gt 0 ]; }; then
    printf '    %-52s %7s fps %6sx  CPU %5s  GPU %s/%s/%s%s\n' "$lbl" "$R_FPS" "$rt" "$(fmt_or_na "$M_CPU" '%s%%')" "${G_VCS:-n/a}" "${G_VECS:-n/a}" "${G_RCS:-n/a}" \
      "$([ "$R_STATUS" = TIMEOUT ] && echo ' (timeout, partial)')"
  else printf '    %s%-52s %s  %s%s\n' "$C_YEL" "$lbl" "$R_STATUS" "$R_ERR" "$C_RESET"; fi
}

# hwdec_check <engine: vaapi-<label>|qsv|nv> <file> <ss>  -> HWDEC_REASON ("" = hardware can decode this clip)
hwdec_check() {
  local eng="$1" f="$2" ss="$3" key out rc dec L reason=""
  key="$eng|$M_CODEC|$M_PIX"
  if [ -n "${HWDEC_CACHE[$key]+x}" ]; then HWDEC_REASON="${HWDEC_CACHE[$key]}"; return; fi
  case "$eng" in
    vaapi-*)
      L="${eng#vaapi-}"
      if [ "${VA_HW_OK[$L]}" != 1 ]; then reason="VAAPI hardware path not available (${VA_NOTE[$L]:-see probe})"
      else
        # shellcheck disable=SC2086
        out="$(ffq -y -stats ${VA_IN[$L]} -ss "$ss" -t 1 -i "$f" -map 0:v:0 -f null - 2>&1)"; rc=$?
        { [ $rc -eq 0 ] && grep -q 'frame= *[1-9]' <<<"$out"; } || reason="VAAPI ($L) cannot decode $M_CODEC $M_PIX"
      fi;;
    qsv)
      dec="${M_CODEC_SHORT}_qsv"
      if [ $QSV_HW_OK != 1 ]; then reason="QSV hardware path not available${QSV_NOTE:+ ($QSV_NOTE)}"
      elif ! has_dec "$dec"; then reason="no $dec decoder in this ffmpeg build"
      else
        out="$(ffq -y -stats "${QSV_IN[@]}" -c:v "$dec" -ss "$ss" -t 1 -i "$f" -map 0:v:0 -f null - 2>&1)"; rc=$?
        { [ $rc -eq 0 ] && grep -q 'frame= *[1-9]' <<<"$out"; } || reason="QSV cannot decode $M_CODEC $M_PIX"
      fi;;
    nv)
      if [ $NV_HW_OK != 1 ]; then reason="CUDA hardware path not available${NV_NOTE:+ ($NV_NOTE)}"
      else
        out="$(ffq -y -stats "${NV_IN[@]}" -ss "$ss" -t 1 -i "$f" -map 0:v:0 -f null - 2>&1)"; rc=$?
        { [ $rc -eq 0 ] && grep -q 'frame= *[1-9]' <<<"$out"; } || reason="NVDEC cannot decode $M_CODEC $M_PIX"
      fi;;
  esac
  HWDEC_CACHE[$key]="$reason"; HWDEC_REASON="$reason"
}

# ------------------------------------------------------------------ scan
section "Scanning $MEDIA_DIR"
mapfile -d '' FILES < <(find "$MEDIA_DIR" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mov' -o -iname '*.ts' \
  -o -iname '*.m2ts' -o -iname '*.mts' -o -iname '*.avi' -o -iname '*.webm' -o -iname '*.wmv' -o -iname '*.mpg' -o -iname '*.mpeg' \) \
  ! -name '_*' -not -path '*/_*/*' -print0 | sort -z)
[ "${#FILES[@]}" -gt 0 ] || die "no video files under $MEDIA_DIR (see docs/media-clips.md)"

declare -a SEL_FILES
count=0
for f in "${FILES[@]}"; do
  probe_media "$f" || { warn "  $(basename "$f"): no video stream, skipped"; continue; }
  if [ "$FILTER" != "*" ]; then
    name="$(basename "$f")"
    # shellcheck disable=SC2053
    [[ "$name" == $FILTER || "$M_CLASS" == $FILTER ]] || continue
  fi
  SEL_FILES+=("$f")
  printf '  %-42s %-22s %sx%s %sbit %sfps %.1fMbps%s\n' "$(basename "$f" | cut -c1-42)" "$M_CLASS" "$M_W" "$M_H" "$M_BITS" "$M_FPS" "$M_BR" "${M_DV:+ DV profile $M_DV}"
  count=$((count + 1)); [ "$MAX_FILES" -gt 0 ] && [ "$count" -ge "$MAX_FILES" ] && break
done
[ "${#SEL_FILES[@]}" -gt 0 ] || die "no usable media files after filtering"

# ------------------------------------------------------------------ tests
section "Running tests (clip ${CLIP}s, timeout ${TIMEOUT}s per run)"
TM_CL='tonemap_opencl=tonemap=hable:desat=0:format=nv12:transfer=bt709:matrix=bt709:primaries=bt709:range=tv'
declare -A RES_NAME=([4k]=4K [1080p]=1080p [720p]=720p [sd]=SD)
SCEN_KEYS=(to1080 to720 same); SCEN_BW=(1920 1280 0); SCEN_BH=(1080 720 0); SCEN_NAME=(1080p 720p "")
declare -A FIRST_OF_CLASS DECR

for idx in "${!SEL_FILES[@]}"; do
  f="${SEL_FILES[$idx]}"; probe_media "$f"
  CUR_FILE="$(basename "$f")"; CUR_BASE="$(echo "${CUR_FILE%.*}" | tr -c 'A-Za-z0-9\n' _)"
  [ -z "${FIRST_OF_CLASS[$M_CLASS]:-}" ] && FIRST_OF_CLASS[$M_CLASS]="$CUR_FILE"
  TM="$M_ISHDR"; [ "$M_DV" = 5 ] && TM=0
  printf '\n  >> %s  [%s]\n' "$CUR_FILE" "$M_CLASS"
  [ "$M_INTERLACED" = 1 ] && warn "     note: interlaced source (not deinterlaced in these tests)"
  [ "$M_DV" = 5 ] && warn "     note: Dolby Vision profile 5 has no HDR10 fallback and cannot be tone-mapped with these filters; timed WITHOUT tone-mapping (needs libplacebo)"
  ss=0; awk -v d="$M_DUR" -v s="$CLIP_START" -v c="$CLIP" 'BEGIN{exit !(d > s + c + 2)}' && ss="$CLIP_START"
  seek=(-ss "$ss" -t "$CLIP")

  # which hardware engines can decode this clip?
  DECR=(); invdec=""
  for L in "${VA_LABELS[@]}"; do hwdec_check "vaapi-$L" "$f" "$ss"; DECR[vaapi-$L]="$HWDEC_REASON"; invdec+="vaapi-$L:$([ -z "$HWDEC_REASON" ] && echo yes || echo no) "; done
  if [ "$GPU_PRESENT_INTEL" = 1 ];  then hwdec_check qsv "$f" "$ss"; DECR[qsv]="$HWDEC_REASON"; invdec+="qsv:$([ -z "$HWDEC_REASON" ] && echo yes || echo no) "; fi
  if [ "$GPU_PRESENT_NVIDIA" = 1 ]; then hwdec_check nv "$f" "$ss";  DECR[nv]="$HWDEC_REASON";  invdec+="nv:$([ -z "$HWDEC_REASON" ] && echo yes || echo no) "; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$CUR_FILE" "$M_CLASS" "${M_W}x${M_H}" "$M_BITS" "$M_FPS" "$M_BR" "$M_HDRTYPE" \
    "$(du -m "$f" | cut -f1)" "${invdec:-none}" >>"$INV_TSV"

  for si in "${!SCEN_KEYS[@]}"; do
    sk="${SCEN_KEYS[$si]}"; want "$sk" "$SCENARIOS" || continue
    fit_size "${SCEN_BW[$si]}" "${SCEN_BH[$si]}"
    if [ "$sk" != same ] && awk -v r="$FIT_RATIO" 'BEGIN{exit !(r>=0.98)}'; then continue; fi   # would not downscale
    W="$FIT_W"; H="$FIT_H"
    dst="${SCEN_NAME[$si]}"; [ "$sk" = same ] && dst="${RES_NAME[$M_RES]}"
    label="${RES_NAME[$M_RES]} -> $dst"
    if [ "$TM" = 1 ]; then label="$label HDR->SDR"
    elif [ "$M_ISHDR" = 1 ]; then label="$label (DV p5, no tone-map)"
    elif [ "$sk" = same ]; then label="$label (bitrate only)"; fi
    B="$(bitrate_m "$H")"; enc=(-preset veryfast -b:v "${B}M")
    swhdr_ok=1; if [ "$TM" = 1 ] && ! { has_filter zscale && has_filter tonemap; }; then swhdr_ok=0; fi

    if want cpu "$VARIANTS"; then
      skip=""; [ $swhdr_ok = 1 ] || skip="zscale/tonemap filters missing in this ffmpeg"
      run_variant cpu "$sk" "$label" "$skip" -- "${seek[@]}" -i "$f" -map 0:v:0 -an -sn -vf "$(sw_chain "$W" "$H" yuv420p)" -c:v libx264 "${enc[@]}" -f null -
    fi

    # ---- VAAPI: one engine per Intel/AMD render node
    for L in "${VA_LABELS[@]}"; do
      if want vaapi "$VARIANTS"; then
        skip="${DECR[vaapi-$L]}"
        vf="scale_vaapi=w=${W}:h=${H}:format=nv12"
        if [ "$TM" = 1 ]; then
          vf="scale_vaapi=w=${W}:h=${H},tonemap_vaapi=format=nv12:t=bt709:m=bt709:p=bt709"
          [ -z "$skip" ] && ! has_filter tonemap_vaapi && skip="tonemap_vaapi filter missing in this ffmpeg"
        fi
        # shellcheck disable=SC2086
        run_variant "vaapi-$L" "$sk" "$label" "$skip" -- ${VA_IN[$L]} "${seek[@]}" -i "$f" -map 0:v:0 -an -sn -vf "$vf" -c:v h264_vaapi -b:v "${B}M" ${VA_ENCOPT[$L]} -f null -
      fi
      if want hybv "$VARIANTS"; then
        skip=""; [ $swhdr_ok = 1 ] || skip="zscale/tonemap filters missing"
        # shellcheck disable=SC2086
        run_variant "hybv-$L" "$sk" "$label" "$skip" -- -vaapi_device "${VA_NODE[$L]}" "${seek[@]}" -i "$f" -map 0:v:0 -an -sn -vf "$(sw_chain "$W" "$H" nv12),hwupload" -c:v h264_vaapi -b:v "${B}M" ${VA_ENCOPT[$L]} -f null -
      fi
      # hardware decode, CPU tone-map/scale, hardware encode (HDR sources only): offloads the heavy 4K HEVC decode
      if want vad "$VARIANTS" && [ "$TM" = 1 ]; then
        skip="${DECR[vaapi-$L]}"; [ -n "$skip" ] || [ $swhdr_ok = 1 ] || skip="zscale/tonemap filters missing"
        # shellcheck disable=SC2086
        run_variant "vad-$L" "$sk" "$label" "$skip" -- ${VA_IN[$L]} "${seek[@]}" -i "$f" -map 0:v:0 -an -sn -vf "hwdownload,format=p010le,$(sw_chain "$W" "$H" nv12),hwupload" -c:v h264_vaapi -b:v "${B}M" ${VA_ENCOPT[$L]} -f null -
      fi
    done

    # ---- QSV (Intel)
    if [ "$GPU_PRESENT_INTEL" = 1 ]; then
      if want qsv "$VARIANTS"; then
        skip="${DECR[qsv]}"; [ -n "$skip" ] || has_filter vpp_qsv || skip="vpp_qsv filter missing"
        vf="vpp_qsv=w=${W}:h=${H}:format=nv12"; [ "$TM" = 1 ] && vf="$vf:tonemap=1"
        run_variant qsv "$sk" "$label" "$skip" -- "${QSV_IN[@]}" -c:v "${M_CODEC_SHORT}_qsv" "${seek[@]}" -i "$f" -map 0:v:0 -an -sn -vf "$vf" -c:v h264_qsv "${enc[@]}" -f null -
      fi
      if want hybq "$VARIANTS"; then
        skip=""; [ $QSV_OK = 1 ] || skip="QSV encoder not working${QSV_NOTE:+ ($QSV_NOTE)}"
        [ -n "$skip" ] || [ $swhdr_ok = 1 ] || skip="zscale/tonemap filters missing"
        run_variant hybq "$sk" "$label" "$skip" -- "${seek[@]}" -i "$f" -map 0:v:0 -an -sn -vf "$(sw_chain "$W" "$H" nv12)" -c:v h264_qsv "${enc[@]}" -f null -
      fi
    fi

    # ---- NVIDIA
    if [ "$GPU_PRESENT_NVIDIA" = 1 ]; then
      if want nv "$VARIANTS"; then
        skip="${DECR[nv]}"
        [ -n "$skip" ] || [ $NV_SCALE = 1 ] || skip="scale_cuda filter missing in this ffmpeg"
        vf="scale_cuda=w=${W}:h=${H}:format=nv12"
        if [ "$TM" = 1 ]; then
          vf="scale_cuda=w=${W}:h=${H}:format=p010le,tonemap_cuda=tonemap=bt2390:format=nv12:p=bt709:t=bt709:m=bt709"
          [ -n "$skip" ] || [ $NV_TM = 1 ] || skip="tonemap_cuda missing (exists only in jellyfin-ffmpeg); use plc / cl for GPU tone-map, nvd / hybn for CPU tone-map + NVENC"
        fi
        # shellcheck disable=SC2086
        run_variant nv "$sk" "$label" "$skip" -- "${NV_IN[@]}" "${seek[@]}" -i "$f" -map 0:v:0 -an -sn -vf "$vf" -c:v h264_nvenc $NV_ENCOPT -b:v "${B}M" -f null -
      fi
      if want hybn "$VARIANTS"; then
        skip=""; [ $NV_OK = 1 ] || skip="NVENC not working${NV_NOTE:+ ($NV_NOTE)}"
        [ -n "$skip" ] || [ $swhdr_ok = 1 ] || skip="zscale/tonemap filters missing"
        # shellcheck disable=SC2086
        run_variant hybn "$sk" "$label" "$skip" -- "${seek[@]}" -i "$f" -map 0:v:0 -an -sn -vf "$(sw_chain "$W" "$H" nv12)" -c:v h264_nvenc $NV_ENCOPT -b:v "${B}M" -f null -
      fi
      # NVDEC decode, CPU tone-map/scale, NVENC encode (HDR sources only): the usual fallback when tonemap_cuda is missing
      if want nvd "$VARIANTS" && [ "$TM" = 1 ]; then
        skip="${DECR[nv]}"; [ -n "$skip" ] || [ $NV_OK = 1 ] || skip="NVENC not working"
        [ -n "$skip" ] || [ $swhdr_ok = 1 ] || skip="zscale/tonemap filters missing"
        # shellcheck disable=SC2086
        run_variant nvd "$sk" "$label" "$skip" -- "${NV_IN[@]}" "${seek[@]}" -i "$f" -map 0:v:0 -an -sn -vf "hwdownload,format=p010le,$(sw_chain "$W" "$H" nv12)" -c:v h264_nvenc $NV_ENCOPT -b:v "${B}M" -f null -
      fi
    fi

    # ---- OpenCL tone-map (HDR only)
    if want cl "$VARIANTS" && [ "$TM" = 1 ]; then
      skip=""
      if ! has_filter tonemap_opencl; then skip="tonemap_opencl is not compiled into this ffmpeg (use jellyfin-ffmpeg)"
      elif [ $CL_OK != 1 ]; then skip="OpenCL probe failed (no usable OpenCL runtime, see logs/sys_cl_probe.txt)"; fi
      pre=""; { [ "$W" != "$M_W" ] || [ "$H" != "$M_H" ]; } && pre="scale=${W}:${H},"
      if [ $QSV_OK = 1 ]; then cenc=(-c:v h264_qsv "${enc[@]}")
      elif [ $NV_OK = 1 ]; then cenc=(-c:v h264_nvenc $NV_ENCOPT -b:v "${B}M")
      else cenc=(-c:v libx264 "${enc[@]}"); fi
      run_variant cl "$sk" "$label" "$skip" -- -init_hw_device "$CL_DEV" -filter_hw_device ocl "${seek[@]}" -i "$f" -map 0:v:0 -an -sn \
        -vf "${pre}format=p010le,hwupload,${TM_CL},hwdownload,format=nv12" "${cenc[@]}" -f null -
    fi

    # ---- libplacebo (Vulkan): GPU tone-map + scale on any vendor; also handles Dolby Vision profile 5
    if want plc "$VARIANTS" && [ "$M_ISHDR" = 1 ]; then
      skip=""
      if ! has_filter libplacebo; then skip="libplacebo is not compiled into this ffmpeg (use jellyfin-ffmpeg)"
      elif [ $PLC_OK != 1 ]; then skip="libplacebo/Vulkan probe failed (no usable Vulkan device, see logs/sys_plc_probe_*.txt)"; fi
      if [ $QSV_OK = 1 ]; then penc=(-c:v h264_qsv "${enc[@]}")
      elif [ $NV_OK = 1 ]; then penc=(-c:v h264_nvenc $NV_ENCOPT -b:v "${B}M")
      elif [ -n "${VA_LABELS[*]}" ]; then L0="${VA_LABELS[0]}"; penc=(-c:v h264_vaapi -b:v "${B}M" ${VA_ENCOPT[$L0]})
      else penc=(-c:v libx264 "${enc[@]}"); fi
      plabel="${label/\(DV p5, no tone-map\)/HDR->SDR (DV p5)}"
      run_variant plc "$sk" "$plabel" "$skip" -- -init_hw_device "$PLC_DEV" -filter_hw_device vk "${seek[@]}" -i "$f" -map 0:v:0 -an -sn \
        -vf "libplacebo=w=${W}:h=${H}:tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=nv12" "${penc[@]}" -f null -
    fi
  done
done

# ------------------------------------------------------------------ concurrency per class
CONC_TSV="$OUTDIR/concurrency.tsv"
printf 'class\tfile\tvariant\tscenario\tstreams\tstatus\tagg_fps\tmin_fps\tmin_realtime\tcpu\tvcs\tvecs\trcs\n' >"$CONC_TSV"
if [ "$NO_CONC" = 0 ]; then
  section "Concurrent streams (best non-CPU variant per class; preferred scenario: to720 > to1080 > same)"
  for cls in "${!FIRST_OF_CLASS[@]}"; do
    cf="${FIRST_OF_CLASS[$cls]}"; best=""; bsk=""
    for sk in to720 to1080 same; do
      best="$(awk -F'\t' -v f="$cf" -v s="$sk" '$1==f && $3==s && $5!="cpu" && $6=="OK" && $10+0>m {m=$10+0; v=$5} END{if(v!="")print v}' "$RESULTS_TSV")"
      [ -n "$best" ] && { bsk="$sk"; break; }
    done
    if [ -z "$best" ]; then log "  $cls: no working non-CPU variant, skipped"; continue; fi
    srcfps="$(awk -F'\t' -v f="$cf" '$1==f {print $5; exit}' "$INV_TSV")"
    slabel="$(awk -F'\t' -v f="$cf" -v s="$bsk" '$1==f && $3==s {print $4; exit}' "$RESULTS_TSV")"
    printf '  %s [%s] variant %s, scenario %s\n' "$cf" "$cls" "$best" "$slabel"
    for n in $STREAMS; do
      pids=(); tags=(); gpu_start "$LOGDIR/conc_${cls}_$n.gpu.csv"
      for ((i = 1; i <= n; i++)); do
        t="conc_${cls}_${best}_n${n}_s${i}"; tags+=("$t")
        eval "launch_ff \"\$t\" ${ROWCMD[$cf|$bsk|$best]}"; pids+=("$L_PID")
      done
      wait_jobs $((TIMEOUT * 2)) "${pids[@]}"; gpu_stop "$LOGDIR/conc_${cls}_$n.gpu.csv"
      agg=0; min=""; ok=0
      for t in "${tags[@]}"; do
        parse_result "$t" "$M_TIMEDOUT"
        if [ "$R_STATUS" = OK ]; then ok=$((ok + 1)); agg="$(awk -v a="$agg" -v f="$R_FPS" 'BEGIN{printf "%.1f", a+f}')"
          min="$(awk -v m="$min" -v f="$R_FPS" 'BEGIN{ if (m=="" || f<m) printf "%.1f", f; else printf "%.1f", m }')"; fi
      done
      if [ "$ok" = 0 ]; then printf '    %2d streams: FAIL %s\n' "$n" "$R_ERR"; break; fi
      minrt="$(awk -v m="$min" -v s="$srcfps" 'BEGIN{printf "%.2f", m/s}')"
      printf '    %2d streams: aggregate %7s fps | slowest %6s fps = %5sx realtime | CPU %5s | GPU %s/%s/%s\n' "$n" "$agg" "$min" "$minrt" \
        "$(fmt_or_na "$M_CPU" '%s%%')" "${G_VCS:-n/a}" "${G_VECS:-n/a}" "${G_RCS:-n/a}"
      printf '%s\t%s\t%s\t%s\t%s\tOK\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cls" "$cf" "$best" "$slabel" "$n" "$agg" "$min" "$minrt" "$M_CPU" "$G_VCS" "$G_VECS" "$G_RCS" >>"$CONC_TSV"
      awk -v m="$minrt" 'BEGIN{exit !(m<1.0)}' && break
    done
  done
fi

# ------------------------------------------------------------------ report
section "Writing report"
{
  echo "# Real-content benchmark (Linux) - $HOSTN"
  echo
  echo "Run: $(date -Is) | clip ${CLIP}s | timeout ${TIMEOUT}s | quick: $QUICK"
  echo
  echo "## System and hardware engines"
  echo
  for l in "${SYS_LINES[@]}"; do echo "- **${l%%|*}:** ${l#*|}"; done
  echo
  echo "## Media inventory"
  echo
  echo "| File | Class | Resolution | Bits | fps | Mbps | HDR | Size MB | Hardware can decode |"
  echo "|---|---|---|---:|---:|---:|---|---:|---|"
  awk -F'\t' 'NR>1 { printf "| %s | %s | %s | %s | %.2f | %.1f | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6,$7,$8,$9 }' "$INV_TSV"
  echo
  echo "## Summary: speed as x real time (1.0 = just real time)"
  echo
  echo 'Variants: `cpu` = software; `vaapi-<gpu>` / `qsv` / `nv` = full hardware path; `hybv-<gpu>` / `hybq` / `hybn` = CPU decode + filters, hardware encode; `cl` = OpenCL tone-map.'
  echo
  awk -F'\t' '
    NR==1 {next}
    { k=$1 "\t" $3; if (!(k in seen)) { seen[k]=1; order[++n]=k; lab[k]=$4 }
      if (!($5 in vseen)) { vseen[$5]=1; vorder[++nv]=$5 }
      st[k,$5]=$6; rt[k,$5]=$10; if (($6=="OK" || $6=="TIMEOUT") && $10+0>best[k]+0) { best[k]=$10; bv[k]=$5 } }
    function cell(k,v) { if (st[k,v]=="") return "-"; if (st[k,v]=="OK") return sprintf("%.2fx", rt[k,v]); if (st[k,v]=="TIMEOUT") return sprintf("%.2fx*", rt[k,v]); return st[k,v] }
    END { printf "| File | Scenario |"; for (j=1;j<=nv;j++) printf " %s |", vorder[j]; print " Best |"
          printf "|---|---|"; for (j=1;j<=nv;j++) printf "---:|"; print "---|"
          for (i=1;i<=n;i++) { k=order[i]; split(k, p, "\t");
            b = (bv[k]=="") ? "none" : sprintf("%s (%.2fx)", bv[k], best[k]);
            printf "| %s | %s |", p[1], lab[k]; for (j=1;j<=nv;j++) printf " %s |", cell(k,vorder[j]); printf " %s |\n", b } }' "$RESULTS_TSV"
  echo
  echo '`*` = run hit the timeout; value is partial throughput. SKIP/FAIL reasons are in the detail table.'
  echo
  echo "## Concurrent streams"
  echo
  if [ "$(wc -l <"$CONC_TSV")" -le 1 ]; then echo "Not run or no working non-CPU variant."; else
    echo "| Class | Variant / scenario | Streams | Aggregate fps | Slowest fps | Slowest x realtime | CPU % | GPU vcs/vecs/rcs % |"
    echo "|---|---|---:|---:|---:|---:|---:|---|"
    awk -F'\t' 'NR>1 { printf "| %s | %s / %s | %s | %s | %s | %s | %s | %s/%s/%s |\n", $1,$3,$4,$5,$7,$8,$9,($10==""?"n/a":$10),($11==""?"n/a":$11),($12==""?"n/a":$12),($13==""?"n/a":$13) }' "$CONC_TSV"
    echo
    echo "Max concurrent streams at >= real time per class:"
    awk -F'\t' 'NR>1 { c[$1]=1; if ($9+0>=1.0 && $5+0>mx[$1]+0) mx[$1]=$5 } END { for (k in c) printf "- **%s**: %d\n", k, mx[k] }' "$CONC_TSV"
  fi
  echo
  echo "## Detail"
  echo
  echo "| File | Scenario | Variant | Status | fps | x realtime | CPU % | GPU vcs/vecs/rcs % | Note |"
  echo "|---|---|---|---|---:|---:|---:|---|---|"
  awk -F'\t' 'NR>1 { gsub(/\|/,"/",$15); printf "| %s | %s | %s | %s | %.1f | %.2f | %s | %s/%s/%s | %s |\n", $1,$4,$5,$6,$9,$10,($11==""?"n/a":$11),($12==""?"n/a":$12),($13==""?"n/a":$13),($14==""?"n/a":$14),$15 }' "$RESULTS_TSV"
  echo
  echo "Notes: only the video stream is transcoded (audio ignored). Output is H.264 at 20/8/4/2 Mbps for 4K/1080p/720p/SD. HDR is tone-mapped to SDR (cpu/hybrid: zscale+hable; vaapi: tonemap_vaapi; qsv: vpp_qsv tonemap; nv: tonemap_cuda; cl: tonemap_opencl). 'x realtime' = fps / source fps. GPU vcs/vecs/rcs columns are Intel engine load via intel_gpu_top (sudo) and read n/a for other vendors; use nvidia-smi dmon / radeontop alongside for those."
} >"$OUTDIR/report.md"

printf '\n%sDone. Results: %s%s\n' "$C_GREEN" "$OUTDIR" "$C_RESET"
