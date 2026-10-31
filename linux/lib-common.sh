#!/usr/bin/env bash
# lib-common.sh - shared helpers for synthetic-test.sh and media-test.sh (source it, do not run it).
# Requires: bash 4+, awk, grep, GNU date, ffmpeg.  Optional: vainfo, intel_gpu_top, nvidia-smi, pkill, lspci.
#
# Hardware engines measured on Linux (all are probed before any test starts):
#   VAAPI  : Intel (i965 / iHD) and AMD (Mesa radeonsi) - one engine per render node, e.g. vaapi-intel, vaapi-amd
#   QSV    : Intel QuickSync through oneVPL/MediaSDK
#   NVENC  : NVIDIA (NVDEC decode, scale_cuda, tonemap_cuda, h264_nvenc)

export LC_ALL=C

C_RESET=$'\033[0m'; C_CYAN=$'\033[36m'; C_YEL=$'\033[33m'; C_RED=$'\033[31m'; C_GRAY=$'\033[90m'; C_GREEN=$'\033[32m'
if [ ! -t 1 ]; then C_RESET=; C_CYAN=; C_YEL=; C_RED=; C_GRAY=; C_GREEN=; fi

log()     { printf '%s\n' "$*"; }
warn()    { printf '%s%s%s\n' "$C_YEL" "$*" "$C_RESET"; }
die()     { printf '%s%s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
section() { printf '\n%s=== %s ===%s\n' "$C_CYAN" "$*" "$C_RESET"; }
now()     { date +%s.%N; }
tsv_clean() { local s="$1"; s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; printf '%s' "$s"; }
last_err() { tr '\r' '\n' <"$1" 2>/dev/null | grep -iE 'error|fail|cannot|not support|unsupported|no such|invalid' | tail -n1 | cut -c1-220; }

# ------------------------------------------------------------------ setup
init_run() {   # init_run <prefix>
  HOSTN="$(hostname)"; STAMP="$(date +%Y%m%d-%H%M%S)"
  OUTDIR="$ROOT_DIR/results/${1}_${HOSTN}_${STAMP}"
  LOGDIR="$OUTDIR/logs"
  WORK="${TMPDIR:-/tmp}/jtb-work-$$"
  mkdir -p "$LOGDIR" "$WORK" || die "cannot create $OUTDIR (is the folder writable?)"
}

cleanup_work() { [ "${KEEP_WORK:-0}" = 1 ] || rm -rf "$WORK"; }

find_ffmpeg() {
  FFMPEG=""
  local c
  if [ -n "${FFMPEG_ARG:-}" ]; then FFMPEG="$FFMPEG_ARG"
  else
    # jellyfin-ffmpeg first (what a Jellyfin server runs; the only build with tonemap_cuda): system package, then the bundled portable build
    for c in /usr/lib/jellyfin-ffmpeg/ffmpeg "$ROOT_DIR/ffmpeg-jellyfin/linux/ffmpeg" "$ROOT_DIR/ffmpeg-full/ffmpeg" "$ROOT_DIR/ffmpeg/ffmpeg"; do
      [ -f "$c" ] && { FFMPEG="$c"; break; }
    done
    [ -n "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg || true)"
  fi
  [ -n "$FFMPEG" ] && [ -f "$FFMPEG" ] || die "ffmpeg not found. Install it (sudo apt install ffmpeg, or jellyfin-ffmpeg) or pass --ffmpeg /path/to/ffmpeg"
  if [ ! -x "$FFMPEG" ]; then   # e.g. binary on an SMB share without the exec bit
    cp "$FFMPEG" "$WORK/ffmpeg" && chmod +x "$WORK/ffmpeg" && FFMPEG="$WORK/ffmpeg"
  fi
  log "ffmpeg: $FFMPEG"
}

# ffq: run ffmpeg quietly for probes (never reads stdin)
ffq() { "$FFMPEG" -hide_banner -nostdin "$@"; }

load_caps() {
  ENCS="$(ffq -encoders 2>/dev/null)"; DECS="$(ffq -decoders 2>/dev/null)"
  FILTS="$(ffq -filters 2>/dev/null)"; HWACCELS="$(ffq -hwaccels 2>/dev/null)"
}
has_enc()    { grep -qE "^ *[A-Z.]+ +$1( |$)" <<<"$ENCS"; }
has_dec()    { grep -qE "^ *[A-Z.]+ +$1( |$)" <<<"$DECS"; }
has_filter() { grep -qE "^ *[A-Z.]+ +$1( |$)" <<<"$FILTS"; }

# ------------------------------------------------------------------ GPU inventory
declare -a GPU_VENDOR GPU_NODE GPU_DESC
GPU_PRESENT_INTEL=0; GPU_PRESENT_AMD=0; GPU_PRESENT_NVIDIA=0

detect_gpus() {
  GPU_VENDOR=(); GPU_NODE=(); GPU_DESC=(); GPU_PRESENT_INTEL=0; GPU_PRESENT_AMD=0; GPU_PRESENT_NVIDIA=0
  local n id vend slot desc
  for n in /sys/class/drm/renderD*; do
    [ -e "$n" ] || continue
    id="$(cat "$n/device/vendor" 2>/dev/null)"
    case "$id" in 0x8086) vend=intel;; 0x1002) vend=amd;; 0x10de) vend=nvidia;; *) vend="other";; esac
    slot="$(basename "$(readlink -f "$n/device")")"
    desc="$(lspci -s "${slot#0000:}" 2>/dev/null | sed 's/^[^ ]* //')"
    GPU_VENDOR+=("$vend"); GPU_NODE+=("/dev/dri/$(basename "$n")"); GPU_DESC+=("${desc:-$slot}")
  done
  # NVIDIA stack without a DRM render node (proprietary driver, or CDI-injected into a container)
  if ! printf '%s\n' "${GPU_VENDOR[@]}" | grep -qx nvidia; then
    if [ -e /dev/nvidia0 ] || { command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; }; then
      desc="$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -n1)"
      GPU_VENDOR+=(nvidia); GPU_NODE+=(""); GPU_DESC+=("${desc:-NVIDIA GPU}")
    fi
  fi
  for n in "${GPU_VENDOR[@]}"; do
    case "$n" in intel) GPU_PRESENT_INTEL=1;; amd) GPU_PRESENT_AMD=1;; nvidia) GPU_PRESENT_NVIDIA=1;; esac
  done
}

print_gpu_inventory() {
  local i
  if [ "${#GPU_VENDOR[@]}" -eq 0 ]; then warn "  no GPU render node visible (in a container: pass --device /dev/dri)"; fi
  for i in "${!GPU_VENDOR[@]}"; do
    printf '  GPU %d: %-7s %-48s %s\n' "$i" "${GPU_VENDOR[$i]}" "${GPU_DESC[$i]:0:48}" "${GPU_NODE[$i]:-(no render node)}"
  done
  # GPUs that exist on the PCI bus but are not usable from here (typical for containers / hybrid laptops)
  if command -v lspci >/dev/null; then
    local pci vid
    while IFS= read -r pci; do
      vid="$(grep -oE '\[(8086|10de|1002):' <<<"$pci" | head -n1 | tr -d '[:')"
      case "$vid" in
        8086) [ "$GPU_PRESENT_INTEL" = 1 ]  || warn "  on PCI bus but NOT usable here: Intel GPU - ${pci#* }";;
        10de) [ "$GPU_PRESENT_NVIDIA" = 1 ] || warn "  on PCI bus but NOT usable here: NVIDIA GPU - ${pci#* } (container: use --device nvidia.com/gpu=all with CDI)";;
        1002) [ "$GPU_PRESENT_AMD" = 1 ]    || warn "  on PCI bus but NOT usable here: AMD GPU - ${pci#* }";;
      esac
    done < <(lspci -nn 2>/dev/null | grep -iE 'vga|3d controller|display controller')
  fi
}

# ------------------------------------------------------------------ system info
collect_sysinfo() {   # fills SYS_LINES (array of "key|value")
  SYS_LINES=()
  local osn cpu cores thr mem gov
  osn="$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  cpu="$(awk -F: '/model name/ {gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)"
  thr="$(grep -c '^processor' /proc/cpuinfo)"
  cores="$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/ {c=$2} /^Socket\(s\)/ {s=$2} END{gsub(/ /,"",c); gsub(/ /,"",s); if (c!="" && s!="") print c*s}')"
  mem="$(awk '/MemTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo)"
  gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  SYS_LINES+=("Host|$HOSTN" "Date|$(date -Is)" "OS|$osn" "Kernel|$(uname -r)" "CPU|$cpu" "Cores|${cores:-n/a}" "Threads|$thr" "RamGB|$mem" "CpuGovernor|$gov")
  local i
  for i in "${!GPU_VENDOR[@]}"; do SYS_LINES+=("GPU $i|${GPU_VENDOR[$i]}: ${GPU_DESC[$i]} ${GPU_NODE[$i]:+[${GPU_NODE[$i]}]}"); done
  local b0 t0 b1 t1
  read -r b0 t0 < <(cpu_read); sleep 3; read -r b1 t1 < <(cpu_read)
  IDLE_CPU=$(( t1 > t0 ? 100 * (b1 - b0) / (t1 - t0) : 0 ))
  SYS_LINES+=("IdleCpuPct|$IDLE_CPU")
  if command -v vainfo >/dev/null && [ "${#GPU_NODE[@]}" -gt 0 ]; then
    for i in "${!GPU_NODE[@]}"; do
      [ -n "${GPU_NODE[$i]}" ] && [ "${GPU_VENDOR[$i]}" != nvidia ] || continue
      VAINFO="$(vainfo --display drm --device "${GPU_NODE[$i]}" 2>&1)"
      SYS_LINES+=("vainfo ${GPU_VENDOR[$i]}|$(grep -m1 -i 'Driver version' <<<"$VAINFO" | sed 's/^vainfo: //') | $(grep -oE 'VAProfile(H264|HEVC|VP9|AV1|MPEG2|JPEG|VC1)[A-Za-z0-9]*[ ]*:[ ]*VAEntrypoint[A-Za-z]+' <<<"$VAINFO" | sed -E 's/VAProfile//; s/VAEntrypoint//; s/ +//g' | paste -sd' ' -)")
    done
  else
    SYS_LINES+=("vainfo|not installed or no render node (sudo apt install vainfo)")
  fi
  command -v nvidia-smi >/dev/null && SYS_LINES+=("nvidia-smi|$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null | head -n1)")
  SYS_LINES+=("ffmpeg|$("$FFMPEG" -hide_banner -version | head -n1)")
  local l
  for l in "${SYS_LINES[@]}"; do printf '  %-16s %s\n' "${l%%|*}" "${l#*|}"; done
  [ "$IDLE_CPU" -gt 20 ] && warn "  WARNING: CPU is ${IDLE_CPU}% busy before the tests; close other workloads (containers etc.) for cleaner CPU numbers."
}

# ------------------------------------------------------------------ hardware probes
declare -A VA_NODE VA_OK VA_HW_OK VA_ENCOPT VA_IN VA_NOTE
VA_LABELS=()
QSV_OK=0; QSV_HW_OK=0; CL_OK=0; PLC_OK=0; CL_DEV="opencl=ocl"; PLC_DEV="vulkan=vk"; QSV_MODE=none; QSV_IN=(); QSV_NOTE=""
NV_OK=0; NV_HW_OK=0; NV_ENCOPT=""; NV_SCALE=0; NV_TM=0; NV_NOTE=""
NV_IN=(-hwaccel cuda -hwaccel_output_format cuda)

probe_vaapi_node() {   # probe_vaapi_node <label> <render node>
  local L="$1" node="$2" opt k=0 cand i=0
  VA_LABELS+=("$L"); VA_NODE[$L]="$node"; VA_OK[$L]=0; VA_HW_OK[$L]=0; VA_ENCOPT[$L]=""; VA_IN[$L]=""; VA_NOTE[$L]=""
  if ! has_enc h264_vaapi; then VA_NOTE[$L]="h264_vaapi encoder not in this ffmpeg"; return; fi
  # rate-control options: Gen11+ Intel needs -low_power 1; some drivers only offer CQP
  local opts=("" "-low_power 1" "-rc_mode CQP -qp 24" "-low_power 1 -rc_mode CQP -qp 24")
  for opt in "${opts[@]}"; do
    k=$((k + 1))
    # shellcheck disable=SC2086
    if ffq -y -vaapi_device "$node" -f lavfi -i testsrc2=size=1280x720:rate=30 -t 1 -vf format=nv12,hwupload \
          -c:v h264_vaapi -b:v 4M $opt -f null - >"$LOGDIR/sys_vaapi_${L}_enc$k.txt" 2>&1; then
      VA_OK[$L]=1; VA_ENCOPT[$L]="$opt"; break
    fi
  done
  if [ "${VA_OK[$L]}" != 1 ]; then VA_NOTE[$L]="encode failed: $(last_err "$LOGDIR/sys_vaapi_${L}_enc$k.txt")"; return; fi
  local cands=("-hwaccel vaapi -hwaccel_device $node -hwaccel_output_format vaapi"
               "-init_hw_device vaapi=va:$node -hwaccel vaapi -hwaccel_device va -hwaccel_output_format vaapi -filter_hw_device va -extra_hw_frames 8")
  for cand in "${cands[@]}"; do
    i=$((i + 1))
    # shellcheck disable=SC2086
    if ffq -y $cand -i "$PROBE_SRC" -t 1 -vf scale_vaapi=w=640:h=360:format=nv12 -c:v h264_vaapi -b:v 4M ${VA_ENCOPT[$L]} -f null - \
          >"$LOGDIR/sys_vaapi_${L}_hw$i.txt" 2>&1; then
      VA_HW_OK[$L]=1; VA_IN[$L]="$cand"; break
    fi
    VA_NOTE[$L]="hardware decode/scale path failed: $(last_err "$LOGDIR/sys_vaapi_${L}_hw$i.txt")"
  done
  [ "${VA_HW_OK[$L]}" = 1 ] && VA_NOTE[$L]=""
}

probe_nvidia() {
  NV_OK=0; NV_HW_OK=0; NV_ENCOPT=""; NV_SCALE=0; NV_TM=0; NV_NOTE=""
  if [ "$GPU_PRESENT_NVIDIA" != 1 ]; then NV_NOTE="no NVIDIA GPU visible"; return; fi
  if ! has_enc h264_nvenc; then NV_NOTE="h264_nvenc not in this ffmpeg"; return; fi
  local opt
  for opt in "-preset p4" "-preset medium" ""; do
    # shellcheck disable=SC2086
    if ffq -y -f lavfi -i testsrc2=size=1280x720:rate=30 -t 1 -c:v h264_nvenc -b:v 4M $opt -f null - >"$LOGDIR/sys_nvenc_probe.txt" 2>&1; then
      NV_OK=1; NV_ENCOPT="$opt"; break
    fi
  done
  if [ $NV_OK != 1 ]; then NV_NOTE="NVENC init failed: $(last_err "$LOGDIR/sys_nvenc_probe.txt")"; return; fi
  has_filter scale_cuda && NV_SCALE=1
  has_filter tonemap_cuda && NV_TM=1
  local vf=(); [ $NV_SCALE = 1 ] && vf=(-vf scale_cuda=w=640:h=360:format=nv12)
  # shellcheck disable=SC2086
  if ffq -y "${NV_IN[@]}" -i "$PROBE_SRC" -t 1 "${vf[@]}" -c:v h264_nvenc -b:v 4M $NV_ENCOPT -f null - >"$LOGDIR/sys_nvenc_hw_probe.txt" 2>&1; then
    NV_HW_OK=1
  else NV_NOTE="CUDA decode/scale path failed: $(last_err "$LOGDIR/sys_nvenc_hw_probe.txt")"; fi
}

probe_hw() {   # needs $PROBE_SRC (small h264 file); honours $DEVICE (restrict VAAPI to one render node)
  VA_LABELS=(); QSV_OK=0; QSV_HW_OK=0; CL_OK=0; QSV_IN=(); QSV_MODE=none; QSV_NOTE=""
  local i vend label node qnode="" cnt_intel=0 cnt_amd=0
  for i in "${!GPU_NODE[@]}"; do
    node="${GPU_NODE[$i]}"; vend="${GPU_VENDOR[$i]}"
    [ -n "$node" ] || continue
    [ -z "${DEVICE:-}" ] || [ "$DEVICE" = "$node" ] || continue
    case "$vend" in
      intel) cnt_intel=$((cnt_intel + 1)); label=intel; [ $cnt_intel -gt 1 ] && label="intel$cnt_intel"; [ -n "$qnode" ] || qnode="$node";;
      amd)   cnt_amd=$((cnt_amd + 1));     label=amd;   [ $cnt_amd -gt 1 ] && label="amd$cnt_amd";;
      *) continue;;
    esac
    probe_vaapi_node "$label" "$node"
    printf '  VAAPI %-6s %s  encode: %s%s   full hardware path: %s%s\n' "$label" "$node" \
      "$([ "${VA_OK[$label]}" = 1 ] && echo OK || echo FAILED)" "$([ -n "${VA_ENCOPT[$label]}" ] && echo " (${VA_ENCOPT[$label]})")" \
      "$([ "${VA_HW_OK[$label]}" = 1 ] && echo OK || echo 'not available')" "$([ -n "${VA_NOTE[$label]}" ] && echo "  <- ${VA_NOTE[$label]}")"
  done
  [ "${#VA_LABELS[@]}" -gt 0 ] || log "  VAAPI: no Intel/AMD render node probed"

  # VA_LABELS holds every probed node; keep only usable ones for the tests
  local usable=() L
  for L in "${VA_LABELS[@]}"; do [ "${VA_OK[$L]}" = 1 ] && usable+=("$L"); done
  ALL_VA_LABELS=("${VA_LABELS[@]}"); VA_LABELS=("${usable[@]}")

  # QSV (Intel only)
  if [ "$GPU_PRESENT_INTEL" != 1 ]; then QSV_NOTE="no Intel GPU visible"
  elif ! has_enc h264_qsv; then QSV_NOTE="h264_qsv not in this ffmpeg"
  elif ffq -y -f lavfi -i testsrc2=size=1280x720:rate=30 -t 1 -c:v h264_qsv -f null - >"$LOGDIR/sys_qsv_probe.txt" 2>&1; then
    QSV_OK=1
    local qdev="${qnode:-$(ls /dev/dri/renderD* 2>/dev/null | head -n1)}"
    local cands=(
      "-init_hw_device vaapi=va:$qdev -init_hw_device qsv=hw@va -hwaccel qsv -hwaccel_device hw -hwaccel_output_format qsv"
      "-init_hw_device qsv=hw:hw_any -hwaccel qsv -hwaccel_device hw -hwaccel_output_format qsv"
      "-hwaccel qsv -hwaccel_output_format qsv" )
    local names=(vaapi-derived hw_any default) k=0 cand
    for cand in "${cands[@]}"; do
      local arr; read -ra arr <<<"$cand"
      if ffq -y "${arr[@]}" -c:v h264_qsv -i "$PROBE_SRC" -t 1 -vf vpp_qsv=format=nv12 -c:v h264_qsv -f null - \
            >"$LOGDIR/sys_qsv_hw_${names[$k]}.txt" 2>&1; then
        QSV_HW_OK=1; QSV_IN=("${arr[@]}"); QSV_MODE="${names[$k]}"; break
      fi
      k=$((k + 1))
    done
    [ $QSV_HW_OK = 1 ] || QSV_NOTE="hardware decode/vpp path failed: $(last_err "$LOGDIR/sys_qsv_hw_default.txt")"
  else QSV_NOTE="encoder init failed: $(last_err "$LOGDIR/sys_qsv_probe.txt") (needs oneVPL runtime + iHD driver, Gen8+)"; fi
  if [ "$GPU_PRESENT_INTEL" = 1 ]; then
    printf '  QSV         encode: %s   full hardware path: %s%s\n' "$([ $QSV_OK = 1 ] && echo OK || echo FAILED)" \
      "$([ $QSV_HW_OK = 1 ] && echo "OK ($QSV_MODE)" || echo 'not available')" "$([ -n "$QSV_NOTE" ] && echo "  <- $QSV_NOTE")"
  else log "  QSV         skipped (no Intel GPU)"; fi

  # NVIDIA
  probe_nvidia
  if [ "$GPU_PRESENT_NVIDIA" = 1 ]; then
    printf '  NVENC       encode: %s%s   full CUDA path: %s   scale_cuda: %s  tonemap_cuda: %s%s\n' "$([ $NV_OK = 1 ] && echo OK || echo FAILED)" \
      "$([ -n "$NV_ENCOPT" ] && echo " ($NV_ENCOPT)")" "$([ $NV_HW_OK = 1 ] && echo OK || echo 'not available')" \
      "$([ $NV_SCALE = 1 ] && echo yes || echo no)" "$([ $NV_TM = 1 ] && echo yes || echo no)" "$([ -n "$NV_NOTE" ] && echo "  <- $NV_NOTE")"
  else log "  NVENC       skipped (no NVIDIA GPU visible)"; fi

  # OpenCL tone-mapping (any vendor with an OpenCL runtime). Plain "opencl=ocl" fails on multi-GPU / multi-platform
  # machines ("No such device"), so explicit platform.device indices are tried too. The probe source must be tagged
  # as PQ/BT.2020, otherwise tonemap_opencl rejects it ("unsupported transfer function").
  CL_DEV="opencl=ocl"; PLC_OK=0; PLC_DEV="vulkan=vk"
  if has_filter tonemap_opencl; then
    local d
    for d in "opencl=ocl" "opencl=ocl:0.0" "opencl=ocl:1.0" "opencl=ocl:0.1" "opencl=ocl:1.1"; do
      if ffq -y -init_hw_device "$d" -filter_hw_device ocl -f lavfi -i testsrc2=size=640x360:rate=30,format=p010le -t 1 \
            -vf setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084:range=tv,hwupload,tonemap_opencl=format=nv12,hwdownload,format=nv12 \
            -c:v libx264 -preset ultrafast -f null - >"$LOGDIR/sys_cl_probe_${d//[^A-Za-z0-9]/_}.txt" 2>&1; then CL_OK=1; CL_DEV="$d"; break; fi
    done
  fi
  log "  OpenCL tone-map: $([ $CL_OK = 1 ] && echo "OK ($CL_DEV)" || { has_filter tonemap_opencl && echo "filter present, no usable OpenCL device (see logs/sys_cl_probe_*.txt)" || echo 'filter not in this ffmpeg build'; })"
  # libplacebo (Vulkan): GPU tone-mapping + scaling on any vendor with a Vulkan driver
  if has_filter libplacebo; then
    for d in "vulkan=vk" "vulkan=vk:0" "vulkan=vk:1"; do
      if ffq -y -init_hw_device "$d" -filter_hw_device vk -f lavfi -i testsrc2=size=640x360:rate=30,format=p010le -t 1 \
            -vf libplacebo=tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=nv12 \
            -c:v libx264 -preset ultrafast -f null - >"$LOGDIR/sys_plc_probe_${d//[^A-Za-z0-9]/_}.txt" 2>&1; then PLC_OK=1; PLC_DEV="$d"; break; fi
    done
  fi
  log "  libplacebo (Vulkan) tone-map: $([ $PLC_OK = 1 ] && echo "OK ($PLC_DEV)" || { has_filter libplacebo && echo "no usable Vulkan device (see logs/sys_plc_probe_*.txt)" || echo 'filter not in this ffmpeg build'; })"
}

# one-line-per-engine summary for the report
engine_summary_lines() {
  local L
  for L in "${ALL_VA_LABELS[@]}"; do
    echo "VAAPI $L (${VA_NODE[$L]}): encode $([ "${VA_OK[$L]}" = 1 ] && echo OK || echo FAILED)${VA_ENCOPT[$L]:+ [${VA_ENCOPT[$L]}]}, full hardware path $([ "${VA_HW_OK[$L]}" = 1 ] && echo OK || echo 'not available')${VA_NOTE[$L]:+ - ${VA_NOTE[$L]}}"
  done
  if [ "$GPU_PRESENT_INTEL" = 1 ]; then echo "QSV: encode $([ $QSV_OK = 1 ] && echo OK || echo FAILED), full hardware path $([ $QSV_HW_OK = 1 ] && echo "OK ($QSV_MODE)" || echo 'not available')${QSV_NOTE:+ - $QSV_NOTE}"; fi
  if [ "$GPU_PRESENT_NVIDIA" = 1 ]; then echo "NVENC: encode $([ $NV_OK = 1 ] && echo OK || echo FAILED)${NV_ENCOPT:+ [$NV_ENCOPT]}, full CUDA path $([ $NV_HW_OK = 1 ] && echo OK || echo 'not available'), scale_cuda $([ $NV_SCALE = 1 ] && echo yes || echo no), tonemap_cuda $([ $NV_TM = 1 ] && echo yes || echo no)${NV_NOTE:+ - $NV_NOTE}"; fi
  echo "OpenCL tonemap: $([ $CL_OK = 1 ] && echo "OK ($CL_DEV)" || echo 'not available'); libplacebo (Vulkan): $([ $PLC_OK = 1 ] && echo "OK ($PLC_DEV)" || echo 'not available')"
}

# ------------------------------------------------------------------ monitoring
cpu_read() { local a b c d e f g h; read -r _ a b c d e f g h _ </proc/stat; echo "$((a+b+c+f+g+h)) $((a+b+c+d+e+f+g+h))"; }

GPU_TOP=0
gpu_detect() {
  GPU_TOP=0
  command -v intel_gpu_top >/dev/null || return
  [ "$GPU_PRESENT_INTEL" = 1 ] || return
  local f="$WORK/gputop_probe.csv"; rm -f "$f"
  timeout 3 intel_gpu_top -c -s 500 -o "$f" >/dev/null 2>&1
  [ "$(wc -l <"$f" 2>/dev/null || echo 0)" -ge 2 ] && GPU_TOP=1
  [ "$GPU_TOP" = 1 ] || warn "  intel_gpu_top unavailable or needs root (sudo ./script): Intel GPU engine load will show n/a"
}
gpu_start() { G_PID=""; [ "$GPU_TOP" = 1 ] || return; rm -f "$1"; intel_gpu_top -c -s 1000 -o "$1" >/dev/null 2>&1 & G_PID=$!; }
gpu_stop()  {
  G_VCS=""; G_VECS=""; G_RCS=""
  [ -n "${G_PID:-}" ] || return
  kill -INT "$G_PID" 2>/dev/null; wait "$G_PID" 2>/dev/null
  read -r G_VCS G_VECS G_RCS < <(awk -F, '
    NR==1 { for (i=1;i<=NF;i++) { h=$i; gsub(/^ +| +$/,"",h); if (h=="VCS %") v=i; else if (h=="VECS %") e=i; else if (h=="RCS %") r=i } next }
    { if (v && $v+0>mv) mv=$v+0; if (e && $e+0>me) me=$e+0; if (r && $r+0>mr) mr=$r+0 }
    END { printf "%.0f %.0f %.0f\n", mv, me, mr }' "$1" 2>/dev/null)
}

# launch_ff <tag> <ffmpeg args...>  -> L_PID  (subshell records its own start/end time for accurate fps)
launch_ff() {
  local tag="$1"; shift
  ( s=$(now); "$FFMPEG" -hide_banner -nostdin -y -stats "$@" >"$LOGDIR/$tag.out.txt" 2>"$LOGDIR/$tag.err.txt"
    rc=$?; e=$(now); echo "$rc $s $e" >"$LOGDIR/$tag.time" ) &
  L_PID=$!
}

# wait_jobs <timeout_s> <pid...>  -> M_TIMEDOUT M_CPU (avg %)
wait_jobs() {
  local timeout="$1"; shift
  local pids=("$@") start p alive b0 t0 b1 t1 cpusum=0 cpucnt=0
  start=$(now); M_TIMEDOUT=0; M_CPU=""
  read -r b0 t0 < <(cpu_read)
  while :; do
    alive=0
    for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ "$alive" = 0 ] && break
    if awk -v e="$(now)" -v s="$start" -v t="$timeout" 'BEGIN{exit !((e-s)>t)}'; then
      M_TIMEDOUT=1
      for p in "${pids[@]}"; do pkill -TERM -P "$p" 2>/dev/null; done
      break
    fi
    sleep 1
    read -r b1 t1 < <(cpu_read)
    if [ $((t1 - t0)) -gt 0 ]; then cpusum=$((cpusum + 100 * (b1 - b0) / (t1 - t0))); cpucnt=$((cpucnt + 1)); fi
    b0=$b1; t0=$t1
  done
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null; done
  [ "$cpucnt" -gt 0 ] && M_CPU=$((cpusum / cpucnt))
}

# parse_result <tag> <timed_out 0|1>  -> R_STATUS R_FRAMES R_SECS R_FPS R_ERR
parse_result() {
  local tag="$1" to="$2" rc=-1 s=0 e=0
  [ -f "$LOGDIR/$tag.time" ] && read -r rc s e <"$LOGDIR/$tag.time"
  R_FRAMES="$(tr '\r' '\n' <"$LOGDIR/$tag.err.txt" 2>/dev/null | grep -o 'frame= *[0-9]*' | tail -n1 | tr -dc '0-9')"; R_FRAMES="${R_FRAMES:-0}"
  R_SECS="$(awk -v s="$s" -v e="$e" 'BEGIN{printf "%.2f", e-s}')"
  R_FPS="$(awk -v f="$R_FRAMES" -v t="$R_SECS" 'BEGIN{ if (t>0) printf "%.2f", f/t; else print "0.00" }')"
  R_STATUS=OK
  if [ "$to" = 1 ]; then R_STATUS=TIMEOUT; elif [ "$rc" != 0 ] || [ "$R_FRAMES" = 0 ]; then R_STATUS=FAIL; fi
  R_ERR=""
  [ "$R_STATUS" = FAIL ] && R_ERR="$(tr '\r' '\n' <"$LOGDIR/$tag.err.txt" 2>/dev/null | grep -v '^ *frame=' | grep -v '^$' | tail -n3 | tr '\n\t' '  ')"
}

# exec_single <tag> <timeout_s> <ffmpeg args...>  -> R_* M_CPU G_*
exec_single() {
  local tag="$1" timeout="$2"; shift 2
  gpu_start "$LOGDIR/$tag.gpu.csv"
  launch_ff "$tag" "$@"
  wait_jobs "$timeout" "$L_PID"
  gpu_stop "$LOGDIR/$tag.gpu.csv"
  parse_result "$tag" "$M_TIMEDOUT"
}

fmt_or_na() { if [ -z "$1" ]; then printf 'n/a'; else printf "$2" "$1"; fi; }
