#!/usr/bin/env bash
# synthetic-test.sh - synthetic hardware-transcode benchmark for Linux: CPU vs Intel (VAAPI/QSV) vs AMD (VAAPI) vs NVIDIA (NVENC).
# Linux counterpart of synthetic-test.ps1.  Run with:  bash linux/synthetic-test.sh [options]
#
# Inventories every GPU and probes every hardware path first, then generates synthetic 1080p sources and
# measures decode / encode / transcode speed on the CPU (libx264/libx265) and on each usable engine
# (VAAPI per Intel/AMD render node, QSV, NVENC), plus a parallel-stream test.
# Output: results/synthetic_<host>_<time>/report.md + results.tsv + logs/
#
# Options:
#   --ffmpeg PATH       ffmpeg binary (default: jellyfin-ffmpeg, ffmpeg-jellyfin/linux/ffmpeg, then PATH)
#   --device PATH       only probe/test this VAAPI render node (default: all Intel/AMD nodes)
#   --libva-driver NAME force LIBVA_DRIVER_NAME (i965 for Haswell, iHD for Broadwell+)
#   --duration SEC      length of the synthetic 1080p source (default 30)
#   --streams "1 2 4"   parallel-stream steps (default "1 2 4 6 8")
#   --timeout SEC       per-test timeout (default 600; partial fps is still reported)
#   --quick             10 s sources, streams "1 2 4"
#   --keep-work         keep generated sources in /tmp
#
# For Intel GPU engine load (VCS/VECS/RCS) install intel-gpu-tools and run with sudo.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"   # repository root: media/, results/, ffmpeg-*/ live here
. "$SCRIPT_DIR/lib-common.sh" || exit 1

DURATION=30; STREAMS="1 2 4 6 8"; TIMEOUT=600; QUICK=0; KEEP_WORK=0; FFMPEG_ARG=""; DEVICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ffmpeg) FFMPEG_ARG="$2"; shift 2;;
    --device) DEVICE="$2"; shift 2;;
    --libva-driver) export LIBVA_DRIVER_NAME="$2"; shift 2;;
    --duration) DURATION="$2"; shift 2;;
    --streams) STREAMS="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --quick) QUICK=1; shift;;
    --keep-work) KEEP_WORK=1; shift;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown option: $1 (see --help)";;
  esac
done
[ "$QUICK" = 1 ] && { DURATION=10; STREAMS="1 2 4"; }

init_run synthetic
trap cleanup_work EXIT
find_ffmpeg

section "GPU inventory"
detect_gpus
print_gpu_inventory
section "System info"
collect_sysinfo

section "ffmpeg capabilities"
load_caps
for n in libx264 libx265 h264_vaapi hevc_vaapi h264_qsv hevc_qsv h264_nvenc hevc_nvenc; do printf '  enc %-14s %s\n' "$n" "$(has_enc $n && echo yes || echo no)"; done
for n in scale_vaapi vpp_qsv scale_cuda tonemap_vaapi tonemap_cuda tonemap_opencl zscale; do printf '  filter %-14s %s\n' "$n" "$(has_filter $n && echo yes || echo no)"; done
has_enc libx264 || die "this ffmpeg has no libx264 (needed to generate sources)"

PROBE_SRC="$WORK/probe_h264.mp4"
ffq -y -f lavfi -i testsrc2=size=1280x720:rate=30 -t 3 -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$PROBE_SRC" >"$LOGDIR/gen_probe.txt" 2>&1 \
  || die "cannot create probe clip (see $LOGDIR/gen_probe.txt)"

section "Probing hardware paths"
probe_hw
gpu_detect
while IFS= read -r l; do SYS_LINES+=("Engine|$l"); done < <(engine_summary_lines)

section "Generating test sources (CPU, may take a while)"
SRC264="$WORK/src_h264_1080p.mp4"; SRC10="$WORK/src_hevc10_1080p.mkv"; SRC10_OK=0
DUR10=$(( DURATION / 2 > 5 ? DURATION / 2 : 5 ))
ffq -y -f lavfi -i "testsrc2=size=1920x1080:rate=30,noise=alls=12:allf=t" -t "$DURATION" -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p "$SRC264" \
  >"$LOGDIR/gen_h264.txt" 2>&1 || die "cannot generate H.264 source (see $LOGDIR/gen_h264.txt)"
log "  H.264 1080p30 ${DURATION}s -> $(du -m "$SRC264" | cut -f1) MB"
if has_enc libx265; then
  if ffq -y -f lavfi -i "testsrc2=size=1920x1080:rate=30,noise=alls=12:allf=t,format=yuv420p10le" -t "$DUR10" -c:v libx265 -preset ultrafast -crf 20 \
        -pix_fmt yuv420p10le -x265-params log-level=error "$SRC10" >"$LOGDIR/gen_hevc10.txt" 2>&1; then
    SRC10_OK=1; log "  HEVC 10-bit 1080p30 ${DUR10}s -> $(du -m "$SRC10" | cut -f1) MB"
  else warn "  HEVC 10-bit source could not be generated; 10-bit tests will be skipped"; fi
fi

# ------------------------------------------------------------------ test runner
RESULTS_TSV="$OUTDIR/results.tsv"; ROWN=0
printf 'group\tpair\tmode\tname\tstatus\tframes\tseconds\tfps\trealtime\tcpu\tvcs\tvecs\trcs\terror\n' >"$RESULTS_TSV"

check_needs() {   # prints a skip reason, or nothing when all prerequisites are met
  local n L
  for n in $1; do
    case "$n" in
      va:*)   L="${n#va:}";   [ "${VA_OK[$L]:-0}" = 1 ]    || { echo "VAAPI $L encoder not working"; return; };;
      vahw:*) L="${n#vahw:}"; [ "${VA_HW_OK[$L]:-0}" = 1 ] || { echo "VAAPI $L hardware decode/scale path not available"; return; };;
      qsv)    [ $QSV_OK = 1 ]    || { echo "QSV encoder not working"; return; };;
      qsvhw)  [ $QSV_HW_OK = 1 ] || { echo "QSV hardware decode/vpp path not available"; return; };;
      nv)     [ $NV_OK = 1 ]     || { echo "NVENC not working"; return; };;
      nvhw)   [ $NV_HW_OK = 1 ]  || { echo "CUDA hardware decode path not available"; return; };;
      nvscale) [ $NV_SCALE = 1 ] || { echo "scale_cuda filter missing in this ffmpeg"; return; };;
      10)     [ $SRC10_OK = 1 ]  || { echo "no 10-bit source"; return; };;
      x265)   has_enc libx265    || { echo "libx265 missing in this ffmpeg"; return; };;
    esac
  done
}

# run_test <group> <pair> <mode> <name> <needs> <srcfps> -- <ffmpeg args...>
run_test() {
  local group="$1" pair="$2" mode="$3" name="$4" needs="$5" srcfps="$6"; shift 6; [ "$1" = "--" ] && shift
  local skip tag rt cpuS
  skip="$(check_needs "$needs")"
  ROWN=$((ROWN + 1))
  if [ -n "$skip" ]; then
    printf '%s\t%s\t%s\t%s\tSKIP\t0\t0\t0\t0\t\t\t\t\t%s\n' "$group" "$pair" "$mode" "$(tsv_clean "$name")" "$(tsv_clean "$skip")" >>"$RESULTS_TSV"
    printf '  %s%-66s SKIP  %s%s\n' "$C_GRAY" "$name" "$skip" "$C_RESET"; return
  fi
  tag="$(printf '%02d_%s' "$ROWN" "${pair}_${mode//[^A-Za-z0-9]/_}")"
  exec_single "$tag" "$TIMEOUT" "$@"
  rt="$(awk -v f="$R_FPS" -v s="$srcfps" 'BEGIN{printf "%.2f", f/s}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$group" "$pair" "$mode" "$(tsv_clean "$name")" "$R_STATUS" "$R_FRAMES" "$R_SECS" "$R_FPS" "$rt" \
    "$M_CPU" "$G_VCS" "$G_VECS" "$G_RCS" "$(tsv_clean "$R_ERR")" >>"$RESULTS_TSV"
  cpuS="$(fmt_or_na "$M_CPU" '%s%%')"
  if [ "$R_STATUS" = OK ] || { [ "$R_STATUS" = TIMEOUT ] && [ "$R_FRAMES" -gt 0 ]; }; then
    printf '  %-66s %7s fps %6sx  CPU %5s  GPU vcs/vecs/rcs %s/%s/%s%s\n' "$name" "$R_FPS" "$rt" "$cpuS" "${G_VCS:-n/a}" "${G_VECS:-n/a}" "${G_RCS:-n/a}" \
      "$([ "$R_STATUS" = TIMEOUT ] && echo ' (timeout, partial)')"
  else
    printf '  %s%-66s %s  %s%s\n' "$C_YEL" "$name" "$R_STATUS" "$R_ERR" "$C_RESET"
  fi
}

# Per-engine helpers: one run_test line per engine, so the console reads group by group.
# va_each <group> <pair> <name base> <needs-suffix kind: hw|enc> <srcfps> -- <builder function name>
declare -a VIN VENC
va_split() { read -ra VIN <<<"${VA_IN[$1]}"; read -ra VENC <<<"${VA_ENCOPT[$1]}"; }
NVE=(); nv_split() { read -ra NVE <<<"$NV_ENCOPT"; }
nv_split

section "Decode (1080p30 -> null)"
run_test Decode dec264 CPU "H.264 1080p decode | CPU" "" 30 -- -i "$SRC264" -f null -
for L in "${VA_LABELS[@]}"; do va_split "$L"; run_test Decode dec264 "VAAPI-$L" "H.264 1080p decode | VAAPI $L" "vahw:$L" 30 -- "${VIN[@]}" -i "$SRC264" -f null -; done
[ "$GPU_PRESENT_INTEL" = 1 ]  && run_test Decode dec264 QSV "H.264 1080p decode | QSV" qsvhw 30 -- "${QSV_IN[@]}" -c:v h264_qsv -i "$SRC264" -f null -
[ "$GPU_PRESENT_NVIDIA" = 1 ] && run_test Decode dec264 NVENC "H.264 1080p decode | NVDEC" nvhw 30 -- "${NV_IN[@]}" -i "$SRC264" -f null -
run_test Decode dec10 CPU "HEVC 10-bit 1080p decode | CPU" "10" 30 -- -i "$SRC10" -f null -
for L in "${VA_LABELS[@]}"; do va_split "$L"; run_test Decode dec10 "VAAPI-$L" "HEVC 10-bit 1080p decode | VAAPI $L" "vahw:$L 10" 30 -- "${VIN[@]}" -i "$SRC10" -f null -; done
[ "$GPU_PRESENT_INTEL" = 1 ]  && run_test Decode dec10 QSV "HEVC 10-bit 1080p decode | QSV" "qsvhw 10" 30 -- "${QSV_IN[@]}" -c:v hevc_qsv -i "$SRC10" -f null -
[ "$GPU_PRESENT_NVIDIA" = 1 ] && run_test Decode dec10 NVENC "HEVC 10-bit 1080p decode | NVDEC" "nvhw 10" 30 -- "${NV_IN[@]}" -i "$SRC10" -f null -

section "Encode (1080p30)"
run_test Encode enc264 CPU "H.264 8M | libx264 medium" "" 30 -- -i "$SRC264" -c:v libx264 -preset medium -b:v 8M -f null -
for L in "${VA_LABELS[@]}"; do va_split "$L"; run_test Encode enc264 "VAAPI-$L" "H.264 8M | h264_vaapi $L (full HW)" "vahw:$L" 30 -- "${VIN[@]}" -i "$SRC264" -c:v h264_vaapi -b:v 8M "${VENC[@]}" -f null -; done
[ "$GPU_PRESENT_INTEL" = 1 ]  && run_test Encode enc264 QSV "H.264 8M | h264_qsv medium (full HW)" qsvhw 30 -- "${QSV_IN[@]}" -c:v h264_qsv -i "$SRC264" -c:v h264_qsv -preset medium -b:v 8M -f null -
[ "$GPU_PRESENT_NVIDIA" = 1 ] && run_test Encode enc264 NVENC "H.264 8M | h264_nvenc (full HW)" nvhw 30 -- "${NV_IN[@]}" -i "$SRC264" -c:v h264_nvenc "${NVE[@]}" -b:v 8M -f null -
for L in "${VA_LABELS[@]}"; do va_split "$L"; run_test Encode enc264h "VAAPI-$L" "H.264 8M, CPU decode | h264_vaapi $L (hybrid)" "va:$L" 30 -- -vaapi_device "${VA_NODE[$L]}" -i "$SRC264" -vf format=nv12,hwupload -c:v h264_vaapi -b:v 8M "${VENC[@]}" -f null -; done
[ "$GPU_PRESENT_INTEL" = 1 ]  && run_test Encode enc264h QSV "H.264 8M, CPU decode | h264_qsv (hybrid)" qsv 30 -- -i "$SRC264" -c:v h264_qsv -preset medium -b:v 8M -f null -
[ "$GPU_PRESENT_NVIDIA" = 1 ] && run_test Encode enc264h NVENC "H.264 8M, CPU decode | h264_nvenc (hybrid)" nv 30 -- -i "$SRC264" -c:v h264_nvenc "${NVE[@]}" -b:v 8M -f null -
[ "$GPU_PRESENT_INTEL" = 1 ]  && run_test Encode enc264q QSV "H.264 8M | h264_qsv veryslow (best quality)" qsvhw 30 -- "${QSV_IN[@]}" -c:v h264_qsv -i "$SRC264" -c:v h264_qsv -preset veryslow -b:v 8M -f null -
[ "$GPU_PRESENT_NVIDIA" = 1 ] && run_test Encode enc264q NVENC "H.264 8M | h264_nvenc p7 (best quality)" nvhw 30 -- "${NV_IN[@]}" -i "$SRC264" -c:v h264_nvenc -preset p7 -b:v 8M -f null -
run_test Encode enc265 CPU "HEVC 6M | libx265 fast" x265 30 -- -i "$SRC264" -c:v libx265 -preset fast -b:v 6M -x265-params log-level=error -f null -
for L in "${VA_LABELS[@]}"; do va_split "$L"; run_test Encode enc265 "VAAPI-$L" "HEVC 6M | hevc_vaapi $L (full HW)" "vahw:$L" 30 -- "${VIN[@]}" -i "$SRC264" -c:v hevc_vaapi -b:v 6M "${VENC[@]}" -f null -; done
[ "$GPU_PRESENT_INTEL" = 1 ]  && run_test Encode enc265 QSV "HEVC 6M | hevc_qsv medium (full HW)" qsvhw 30 -- "${QSV_IN[@]}" -c:v h264_qsv -i "$SRC264" -c:v hevc_qsv -preset medium -b:v 6M -f null -
[ "$GPU_PRESENT_NVIDIA" = 1 ] && run_test Encode enc265 NVENC "HEVC 6M | hevc_nvenc (full HW)" nvhw 30 -- "${NV_IN[@]}" -i "$SRC264" -c:v hevc_nvenc "${NVE[@]}" -b:v 6M -f null -
run_test Encode enc10 CPU "HEVC 10-bit 6M | libx265 fast" "x265 10" 30 -- -i "$SRC10" -c:v libx265 -preset fast -pix_fmt yuv420p10le -b:v 6M -x265-params log-level=error -f null -
for L in "${VA_LABELS[@]}"; do va_split "$L"; run_test Encode enc10 "VAAPI-$L" "HEVC 10-bit 6M | hevc_vaapi $L main10" "vahw:$L 10" 30 -- "${VIN[@]}" -i "$SRC10" -c:v hevc_vaapi -profile:v main10 -b:v 6M "${VENC[@]}" -f null -; done
[ "$GPU_PRESENT_INTEL" = 1 ]  && run_test Encode enc10 QSV "HEVC 10-bit 6M | hevc_qsv main10" "qsvhw 10" 30 -- "${QSV_IN[@]}" -c:v hevc_qsv -i "$SRC10" -c:v hevc_qsv -profile:v main10 -preset medium -b:v 6M -f null -
[ "$GPU_PRESENT_NVIDIA" = 1 ] && run_test Encode enc10 NVENC "HEVC 10-bit 6M | hevc_nvenc main10" "nvhw 10" 30 -- "${NV_IN[@]}" -i "$SRC10" -c:v hevc_nvenc -profile:v main10 "${NVE[@]}" -b:v 6M -f null -

section "Transcode (media-server style)"
run_test Transcode tc720 CPU "1080p -> 720p H.264 4M | CPU (scale+libx264 veryfast)" "" 30 -- -i "$SRC264" -vf scale=1280:720 -c:v libx264 -preset veryfast -b:v 4M -f null -
for L in "${VA_LABELS[@]}"; do va_split "$L"; run_test Transcode tc720 "VAAPI-$L" "1080p -> 720p H.264 4M | VAAPI $L (scale_vaapi+h264_vaapi)" "vahw:$L" 30 -- "${VIN[@]}" -i "$SRC264" -vf scale_vaapi=w=1280:h=720:format=nv12 -c:v h264_vaapi -b:v 4M "${VENC[@]}" -f null -; done
[ "$GPU_PRESENT_INTEL" = 1 ]  && run_test Transcode tc720 QSV "1080p -> 720p H.264 4M | QSV (vpp_qsv+h264_qsv)" qsvhw 30 -- "${QSV_IN[@]}" -c:v h264_qsv -i "$SRC264" -vf vpp_qsv=w=1280:h=720:format=nv12 -c:v h264_qsv -preset veryfast -b:v 4M -f null -
[ "$GPU_PRESENT_NVIDIA" = 1 ] && run_test Transcode tc720 NVENC "1080p -> 720p H.264 4M | NVIDIA (scale_cuda+h264_nvenc)" "nvhw nvscale" 30 -- "${NV_IN[@]}" -i "$SRC264" -vf scale_cuda=w=1280:h=720:format=nv12 -c:v h264_nvenc "${NVE[@]}" -b:v 4M -f null -
for L in "${VA_LABELS[@]}"; do va_split "$L"; run_test Transcode tc720h "VAAPI-$L" "1080p -> 720p H.264 4M, CPU decode+scale | h264_vaapi $L (hybrid)" "va:$L" 30 -- -vaapi_device "${VA_NODE[$L]}" -i "$SRC264" -vf scale=1280:720,format=nv12,hwupload -c:v h264_vaapi -b:v 4M "${VENC[@]}" -f null -; done
[ "$GPU_PRESENT_INTEL" = 1 ]  && run_test Transcode tc720h QSV "1080p -> 720p H.264 4M, CPU decode+scale | h264_qsv (hybrid)" qsv 30 -- -i "$SRC264" -vf scale=1280:720 -c:v h264_qsv -preset veryfast -b:v 4M -f null -
[ "$GPU_PRESENT_NVIDIA" = 1 ] && run_test Transcode tc720h NVENC "1080p -> 720p H.264 4M, CPU decode+scale | h264_nvenc (hybrid)" nv 30 -- -i "$SRC264" -vf scale=1280:720 -c:v h264_nvenc "${NVE[@]}" -b:v 4M -f null -
run_test Transcode tc10to8 CPU "HEVC 10-bit -> H.264 8-bit 8M | CPU" 10 30 -- -i "$SRC10" -pix_fmt yuv420p -c:v libx264 -preset veryfast -b:v 8M -f null -
for L in "${VA_LABELS[@]}"; do va_split "$L"; run_test Transcode tc10to8 "VAAPI-$L" "HEVC 10-bit -> H.264 8-bit 8M | VAAPI $L" "vahw:$L 10" 30 -- "${VIN[@]}" -i "$SRC10" -vf scale_vaapi=format=nv12 -c:v h264_vaapi -b:v 8M "${VENC[@]}" -f null -; done
[ "$GPU_PRESENT_INTEL" = 1 ]  && run_test Transcode tc10to8 QSV "HEVC 10-bit -> H.264 8-bit 8M | QSV" "qsvhw 10" 30 -- "${QSV_IN[@]}" -c:v hevc_qsv -i "$SRC10" -vf vpp_qsv=format=nv12 -c:v h264_qsv -preset veryfast -b:v 8M -f null -
[ "$GPU_PRESENT_NVIDIA" = 1 ] && run_test Transcode tc10to8 NVENC "HEVC 10-bit -> H.264 8-bit 8M | NVIDIA" "nvhw nvscale 10" 30 -- "${NV_IN[@]}" -i "$SRC10" -vf scale_cuda=format=nv12 -c:v h264_nvenc "${NVE[@]}" -b:v 8M -f null -

# ------------------------------------------------------------------ concurrency
CONC_TSV="$OUTDIR/concurrency.tsv"
printf 'engine\tstreams\tstatus\tagg_fps\tmin_fps\tmin_realtime\tcpu\tvcs\tvecs\trcs\n' >"$CONC_TSV"

# conc_run <label> -- <ffmpeg args...>
conc_run() {
  local label="$1"; shift; [ "$1" = "--" ] && shift
  local n i pids tags ok agg min minrt t
  for n in $STREAMS; do
    pids=(); tags=()
    gpu_start "$LOGDIR/conc_${label}_$n.gpu.csv"
    for ((i = 1; i <= n; i++)); do
      t="conc_${label}_n${n}_s${i}"; tags+=("$t"); launch_ff "$t" "$@"; pids+=("$L_PID")
    done
    wait_jobs $((TIMEOUT * 2)) "${pids[@]}"
    gpu_stop "$LOGDIR/conc_${label}_$n.gpu.csv"
    agg=0; min=""; ok=0
    for t in "${tags[@]}"; do
      parse_result "$t" "$M_TIMEDOUT"
      if [ "$R_STATUS" = OK ]; then ok=$((ok + 1)); agg="$(awk -v a="$agg" -v f="$R_FPS" 'BEGIN{printf "%.1f", a+f}')"
        min="$(awk -v m="$min" -v f="$R_FPS" 'BEGIN{ if (m=="" || f<m) printf "%.1f", f; else printf "%.1f", m }')"; fi
    done
    if [ "$ok" = 0 ]; then
      printf '  %s: %2d streams FAIL %s\n' "$label" "$n" "$R_ERR"
      printf '%s\t%s\tFAIL\t0\t0\t0\t%s\t%s\t%s\t%s\n' "$label" "$n" "$M_CPU" "$G_VCS" "$G_VECS" "$G_RCS" >>"$CONC_TSV"; break
    fi
    minrt="$(awk -v m="$min" 'BEGIN{printf "%.2f", m/30}')"
    printf '  %-12s %2d streams: aggregate %7s fps | slowest %6s fps = %5sx realtime | CPU %5s | GPU vcs/vecs/rcs %s/%s/%s\n' \
      "$label" "$n" "$agg" "$min" "$minrt" "$(fmt_or_na "$M_CPU" '%s%%')" "${G_VCS:-n/a}" "${G_VECS:-n/a}" "${G_RCS:-n/a}"
    printf '%s\t%s\tOK\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$n" "$agg" "$min" "$minrt" "$M_CPU" "$G_VCS" "$G_VECS" "$G_RCS" >>"$CONC_TSV"
    awk -v m="$minrt" 'BEGIN{exit !(m<1.0)}' && { log "  -> slowest stream fell below real time, stopping."; break; }
  done
}

section "Concurrent 1080p -> 720p transcodes (stops when a stream drops below real time)"
for L in "${VA_LABELS[@]}"; do
  va_split "$L"
  if [ "${VA_HW_OK[$L]}" = 1 ]; then conc_run "VAAPI-$L" -- "${VIN[@]}" -i "$SRC264" -vf scale_vaapi=w=1280:h=720:format=nv12 -c:v h264_vaapi -b:v 4M "${VENC[@]}" -f null -
  else warn "  VAAPI $L: full path unavailable, using hybrid (CPU decode+scale)"
    conc_run "VAAPIh-$L" -- -vaapi_device "${VA_NODE[$L]}" -i "$SRC264" -vf scale=1280:720,format=nv12,hwupload -c:v h264_vaapi -b:v 4M "${VENC[@]}" -f null -
  fi
done
if [ "$GPU_PRESENT_INTEL" = 1 ]; then
  if [ $QSV_HW_OK = 1 ]; then conc_run QSV -- "${QSV_IN[@]}" -c:v h264_qsv -i "$SRC264" -vf vpp_qsv=w=1280:h=720:format=nv12 -c:v h264_qsv -preset veryfast -b:v 4M -f null -
  elif [ $QSV_OK = 1 ]; then warn "  QSV: full path unavailable, using hybrid (CPU decode+scale)"
    conc_run QSVh -- -i "$SRC264" -vf scale=1280:720 -c:v h264_qsv -preset veryfast -b:v 4M -f null -
  else log "  QSV skipped"; fi
fi
if [ "$GPU_PRESENT_NVIDIA" = 1 ]; then
  if [ $NV_HW_OK = 1 ] && [ $NV_SCALE = 1 ]; then conc_run NVENC -- "${NV_IN[@]}" -i "$SRC264" -vf scale_cuda=w=1280:h=720:format=nv12 -c:v h264_nvenc "${NVE[@]}" -b:v 4M -f null -
  elif [ $NV_OK = 1 ]; then warn "  NVENC: full path unavailable, using hybrid (CPU decode+scale)"
    conc_run NVENCh -- -i "$SRC264" -vf scale=1280:720 -c:v h264_nvenc "${NVE[@]}" -b:v 4M -f null -
  else log "  NVENC skipped"; fi
fi

# ------------------------------------------------------------------ report
section "Writing report"
{
  echo "# Hardware transcode benchmark (Linux) - $HOSTN"
  echo
  echo "Run: $(date -Is) | source ${DURATION}s | timeout ${TIMEOUT}s | quick: $QUICK"
  echo
  echo "## System and hardware engines"
  echo
  for l in "${SYS_LINES[@]}"; do echo "- **${l%%|*}:** ${l#*|}"; done
  echo
  echo "## CPU vs hardware summary (fps and speedup vs CPU)"
  echo
  awk -F'\t' '
    NR==1 {next}
    { p=$2; if (!(p in seen)) { seen[p]=1; order[++n]=p; lab[p]=$4; sub(/ \|.*/,"",lab[p]); if (p ~ /q$/) lab[p]=lab[p] " (best quality)" }
      if ($3!="CPU" && !($3 in mseen)) { mseen[$3]=1; morder[++nm]=$3 }
      st[p,$3]=$5; fps[p,$3]=$8; cpu[p,$3]=$10 }
    function cell(p,m,   b, s) {
      if (st[p,m]=="") return "-"
      if (st[p,m]!="OK") return st[p,m]
      b=p; sub(/[qh]$/,"",b)
      if (st[b,"CPU"]=="OK" && fps[b,"CPU"]>0) return sprintf("%.1f (%.1fx)", fps[p,m], fps[p,m]/fps[b,"CPU"])
      return sprintf("%.1f", fps[p,m]) }
    END { printf "| Test | CPU fps | CPU load |"; for (j=1;j<=nm;j++) printf " %s |", morder[j]; print ""
          printf "|---|---:|---:|"; for (j=1;j<=nm;j++) printf "---:|"; print ""
          for (i=1;i<=n;i++) { p=order[i]; b=p; sub(/[qh]$/,"",b); any=0
            for (j=1;j<=nm;j++) if (st[p,morder[j]]!="") any=1
            if (!any) continue
            c=(st[b,"CPU"]=="OK") ? sprintf("%.1f", fps[b,"CPU"]) : "n/a"; cl=(cpu[b,"CPU"]!="") ? cpu[b,"CPU"] "%" : "n/a"
            printf "| %s | %s | %s |", lab[p], c, cl; for (j=1;j<=nm;j++) printf " %s |", cell(p,morder[j]); print "" } }' "$RESULTS_TSV"
  echo
  echo "## All results"
  echo
  echo "| Group | Test | Status | fps | x realtime | CPU % | GPU vcs/vecs/rcs % | Note |"
  echo "|---|---|---|---:|---:|---:|---|---|"
  awk -F'\t' 'NR>1 { gsub(/\|/,"/",$14); printf "| %s | %s | %s | %.1f | %.2f | %s | %s/%s/%s | %s |\n", $1,$4,$5,$8,$9,($10==""?"n/a":$10),($11==""?"n/a":$11),($12==""?"n/a":$12),($13==""?"n/a":$13),$14 }' "$RESULTS_TSV"
  echo
  echo "## Concurrent 1080p30 -> 720p transcodes (H.264 4M)"
  echo
  echo "| Engine | Streams | Status | Aggregate fps | Slowest fps | Slowest x realtime | CPU % | GPU vcs/vecs/rcs % |"
  echo "|---|---:|---|---:|---:|---:|---:|---|"
  awk -F'\t' 'NR>1 { printf "| %s | %s | %s | %s | %s | %s | %s | %s/%s/%s |\n", $1,$2,$3,$4,$5,$6,($7==""?"n/a":$7),($8==""?"n/a":$8),($9==""?"n/a":$9),($10==""?"n/a":$10) }' "$CONC_TSV"
  echo
  awk -F'\t' 'NR>1 && $3=="OK" && $6>=1.0 { if ($2>mx[$1]) mx[$1]=$2 } NR>1 {eng[$1]=1}
    END { for (e in eng) printf "Max tested concurrent streams at >= real time (%s): **%d**\n\n", e, mx[e] }' "$CONC_TSV"
  echo "Notes: sources are synthetic (testsrc2 + noise). 'x realtime' = fps / 30. Rows marked TIMEOUT report partial throughput. GPU vcs/vecs/rcs is Intel engine load via intel_gpu_top (sudo); n/a otherwise - watch nvidia-smi dmon / radeontop for other vendors."
} >"$OUTDIR/report.md"

# minimal JSON export
awk -F'\t' 'function esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
  BEGIN { printf "[" } NR>1 { printf "%s{\"group\":\"%s\",\"pair\":\"%s\",\"mode\":\"%s\",\"name\":\"%s\",\"status\":\"%s\",\"frames\":%d,\"seconds\":%s,\"fps\":%s,\"realtime\":%s,\"cpu\":\"%s\",\"error\":\"%s\"}", (NR>2?",":""), esc($1),esc($2),esc($3),esc($4),$5,$6,$7,$8,$9,$10,esc($14) }
  END { print "]" }' "$RESULTS_TSV" >"$OUTDIR/results.json"

printf '\n%sDone. Results: %s%s\n' "$C_GREEN" "$OUTDIR" "$C_RESET"
