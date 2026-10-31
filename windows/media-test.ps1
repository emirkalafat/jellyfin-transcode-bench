<#
.SYNOPSIS
  Real-content transcode benchmark: CPU vs Intel QuickSync (QSV) vs NVIDIA (NVENC) vs AMD (AMF) vs hybrid paths. Windows PowerShell 5.1+.

.DESCRIPTION
  Scans <repo>\media (recursively) for video clips, reads their properties from `ffmpeg -i`, classifies each
  (codec / resolution / SDR-HDR10-HLG-DolbyVision) and transcodes a short clip of every file to H.264
  using the scenarios that make sense for it:

    to1080  fit inside 1920x1080   (4K -> 1080p; HDR sources are tone-mapped to SDR)
    to720   fit inside 1280x720    (4K/1080p -> 720p; HDR sources are tone-mapped to SDR)
    same    keep resolution        (bitrate-only transcode, or HDR -> SDR tone-map at same resolution)

  Variants per scenario (a variant is skipped with a reason when it cannot work):
    CPU  software decode + filters + libx264
    HW   QSV decode + vpp_qsv (scale / tonemap) + h264_qsv       (needs QSV decode support for the codec)
    HYB  software decode + filters, h264_qsv encode               (works on any QSV encoder)
    CL   software decode, OpenCL tone-map, hardware/x264 encode   (HDR sources only; needs ffmpeg with tonemap_opencl)
    PLC  software decode, libplacebo (Vulkan GPU) tone-map+scale, hardware/x264 encode (HDR sources, any vendor)
    NV   NVDEC decode + scale_cuda/tonemap_cuda + h264_nvenc      (NVIDIA GPU)
    HYBN software decode + filters, h264_nvenc encode             (NVIDIA GPU)
    NVD  NVDEC decode, software tone-map, h264_nvenc encode       (NVIDIA GPU, HDR sources only)
    HYBA software decode + filters, h264_amf encode               (AMD GPU)
  All GPUs are inventoried and probed before any test; engines are only used when the GPU is present.

  Then, per source class, runs N parallel copies of the best non-CPU variant to find the stream limit.
  Output: results\media_<host>_<time>\report.md + results.json + logs\

  ffmpeg.exe is looked up in <repo>\ffmpeg-jellyfin\bin (see tools\get-ffmpeg.ps1), <repo>\ffmpeg-full\bin, <repo>\ffmpeg\bin, then PATH. ffprobe is not needed.

.PARAMETER MediaDir      Folder with the clips (default .\media).
.PARAMETER ClipSeconds   Seconds transcoded per run (default 30). Every run includes process start-up (OpenCL/libplacebo compile
                         their kernels on each start), so very short clips understate the fastest GPU paths.
.PARAMETER ClipStart     Seek position in seconds for long files (default 120; short clips start at 0).
.PARAMETER TimeoutSec    Per-run timeout (default 240). A timed-out run still reports its partial fps.
.PARAMETER Streams       Concurrency steps (default 1,2,3,4).
.PARAMETER Filter        Wildcard matched against file name and class, e.g. '*hdr*' or 'hevc-4k*'.
.PARAMETER Variants      Subset of cpu,hw,hyb,cl,plc,nv,hybn,nvd,hyba (default all).
.PARAMETER Scenarios     Subset of to1080,to720,same (default all).
.PARAMETER MaxFiles      Stop after N files.
.PARAMETER NoConcurrency Skip the parallel-stream tests.
.PARAMETER NoLocalCopy   Do not copy clips from a network share to local disk before testing.
.PARAMETER Anonymize     Replace clip file names with clip-01, clip-02 ... in report.md and results.json (logs still contain the names).
.PARAMETER Quick         10 s clips, 120 s timeout, streams 1,2,3.
#>
[CmdletBinding()]
param(
    [string]$FfmpegPath,
    [string]$MediaDir,
    [int]$ClipSeconds = 30,
    [int]$ClipStart = 120,
    [int]$TimeoutSec = 240,
    [string[]]$Streams = @('1', '2', '3', '4'),
    [string]$Filter = '*',
    [string[]]$Variants = @('cpu', 'hw', 'hyb', 'cl', 'plc', 'nv', 'hybn', 'nvd', 'hyba'),
    [string[]]$Scenarios = @('to1080', 'to720', 'same'),
    [int]$MaxFiles = 0,
    [switch]$NoConcurrency,
    [switch]$NoLocalCopy,
    [switch]$Anonymize,
    [switch]$Quick,
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
# `powershell -File` (run-media.bat) passes "-Variants cpu,hyb" as ONE string; split lists on , ; or space.
$Variants  = @($Variants  | ForEach-Object { $_ -split '[,; ]+' } | Where-Object { $_ })
$Scenarios = @($Scenarios | ForEach-Object { $_ -split '[,; ]+' } | Where-Object { $_ })
$Streams   = @($Streams   | ForEach-Object { $_ -split '[,; ]+' } | Where-Object { $_ } | ForEach-Object { [int]$_ })
if ($Quick) { $ClipSeconds = 10; $TimeoutSec = 120; $Streams = @(1, 2, 3) }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir   # repository root: media\, results\, ffmpeg-*\ live here
if (-not $MediaDir) { $MediaDir = Join-Path $RootDir 'media' }
$Stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$HostName = $env:COMPUTERNAME
$OutDir   = Join-Path $RootDir ("results\media_{0}_{1}" -f $HostName, $Stamp)
$LogDir   = Join-Path $OutDir 'logs'
$WorkDir  = Join-Path $env:TEMP 'jtb-media-work'
New-Item -ItemType Directory -Force -Path $OutDir, $LogDir, $WorkDir | Out-Null

# Network share (UNC path or mapped network drive)? Then copy the clips to local disk first, otherwise
# network speed is measured together with decode speed.
function Test-NetworkPath([string]$p) {
    try {
        $full = [IO.Path]::GetFullPath($p)
        if ($full.StartsWith('\\')) { return $true }
        return ((New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))).DriveType -eq 'Network')
    } catch { return $false }
}
$script:LocalCopied = $false
if (-not $NoLocalCopy -and (Test-Path -LiteralPath $MediaDir) -and (Test-NetworkPath $MediaDir)) {
    $localMedia = Join-Path $WorkDir 'media'
    Write-Host "Media folder is on the network; copying clips to $localMedia ..." -ForegroundColor Cyan
    if (Test-Path $localMedia) { Remove-Item $localMedia -Recurse -Force }
    Copy-Item -LiteralPath $MediaDir -Destination $localMedia -Recurse -Force
    $MediaDir = $localMedia
    $script:LocalCopied = $true
}

$script:Warmed  = @{}
$script:Results = New-Object System.Collections.ArrayList
$script:QsvOk   = $false
$script:QsvHwOk = $false
$script:ClOk    = $false
$script:QIn     = ''
$Variants  = @($Variants  | ForEach-Object { $_.ToLower() })
$Scenarios = @($Scenarios | ForEach-Object { $_.ToLower() })

function Write-Section($t) { Write-Host ""; Write-Host ("=== {0} ===" -f $t) -ForegroundColor Cyan }

# ---------------------------------------------------------------- ffmpeg lookup
function Find-Ffmpeg {
    if ($FfmpegPath -and (Test-Path $FfmpegPath)) { return (Resolve-Path $FfmpegPath).Path }
    foreach ($c in @('ffmpeg-jellyfin\bin\ffmpeg.exe', 'ffmpeg-full\bin\ffmpeg.exe', 'ffmpeg.exe', 'ffmpeg\bin\ffmpeg.exe', 'bin\ffmpeg.exe')) {   # jellyfin-ffmpeg (what a Jellyfin server runs) wins when present
        $p = Join-Path $RootDir $c
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}
$Ffmpeg = Find-Ffmpeg
if (-not $Ffmpeg) {
    Write-Host 'ffmpeg.exe not found. Put it next to this script or in .\ffmpeg\bin\ (gyan.dev essentials/full build).' -ForegroundColor Red
    exit 1
}
Write-Host "ffmpeg: $Ffmpeg"

# ---------------------------------------------------------------- process helpers
function Start-Ff {
    param([string]$FfArgs, [string]$Tag)
    $err = Join-Path $LogDir ("{0}.err.txt" -f $Tag)
    $out = Join-Path $LogDir ("{0}.out.txt" -f $Tag)
    $p = Start-Process -FilePath $Ffmpeg -ArgumentList $FfArgs -NoNewWindow -PassThru `
        -RedirectStandardError $err -RedirectStandardOutput $out
    $null = $p.Handle
    return [pscustomobject]@{ Proc = $p; Err = $err; Out = $out; Tag = $Tag; Args = $FfArgs }
}

function Invoke-FfText {
    param([string]$FfArgs, [string]$Tag)
    $j = Start-Ff $FfArgs $Tag
    $j.Proc.WaitForExit()
    $t = ''
    foreach ($f in @($j.Out, $j.Err)) { if (Test-Path $f) { $t += (Get-Content -Raw -LiteralPath $f) + "`n" } }
    return [pscustomobject]@{ Code = $j.Proc.ExitCode; Text = $t }
}

function Get-SystemSample {
    $s = @{ Cpu = $null; Gpu = @{ VideoDecode = 0.0; VideoEncode = 0.0; VideoProcessing = 0.0 } }
    try {
        $s.Cpu = [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
    } catch { }
    try {
        $rows = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop |
            Where-Object { $_.Name -match 'engtype_Video' }
        $sums = @{}; $types = @{}
        foreach ($e in $rows) {
            if ($e.Name -match '(phys_\d+_eng_\d+_engtype_(\w+))') {
                $k = $Matches[1]; $types[$k] = $Matches[2]
                if (-not $sums.ContainsKey($k)) { $sums[$k] = 0.0 }
                $sums[$k] += [double]$e.UtilizationPercentage
            }
        }
        foreach ($k in $sums.Keys) {
            $t = $types[$k]
            if ($s.Gpu.ContainsKey($t) -and $sums[$k] -gt $s.Gpu[$t]) { $s.Gpu[$t] = $sums[$k] }
        }
    } catch { }
    return $s
}

function Wait-Ff {
    param($Jobs, [int]$Timeout)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $cpu = New-Object 'System.Collections.Generic.List[double]'
    $gmax = @{ VideoDecode = 0.0; VideoEncode = 0.0; VideoProcessing = 0.0 }
    $last = -10000
    $timedOut = $false
    while ($true) {
        $running = @($Jobs | Where-Object { -not $_.Proc.HasExited })
        if ($running.Count -eq 0) { break }
        if ($sw.Elapsed.TotalSeconds -gt $Timeout) {
            $timedOut = $true
            foreach ($j in $running) { try { $j.Proc.Kill() } catch { } }
            break
        }
        if (($sw.ElapsedMilliseconds - $last) -ge 1500) {
            $last = $sw.ElapsedMilliseconds
            $s = Get-SystemSample
            if ($null -ne $s.Cpu) { $cpu.Add($s.Cpu) }
            foreach ($k in @($gmax.Keys)) { if ($s.Gpu[$k] -gt $gmax[$k]) { $gmax[$k] = $s.Gpu[$k] } }
        }
        Start-Sleep -Milliseconds 200
    }
    foreach ($j in $Jobs) { try { $null = $j.Proc.WaitForExit(3000) } catch { } }
    $avg = $null
    if ($cpu.Count -gt 0) { $avg = ($cpu | Measure-Object -Average).Average }
    return [pscustomobject]@{ CpuAvg = $avg; Gpu = $gmax; TimedOut = $timedOut; Wall = $sw.Elapsed.TotalSeconds }
}

function Get-JobResult {
    param($Job, [bool]$TimedOut)
    $txt = ''
    if (Test-Path $Job.Err) { $txt = Get-Content -Raw -LiteralPath $Job.Err }
    if (-not $txt) { $txt = '' }
    $frames = 0
    $m = [regex]::Matches($txt, 'frame=\s*(\d+)')
    if ($m.Count -gt 0) { $frames = [int]$m[$m.Count - 1].Groups[1].Value }
    $secs = 0.0
    try { $secs = ($Job.Proc.ExitTime - $Job.Proc.StartTime).TotalSeconds } catch { }
    $code = -1
    try { $code = $Job.Proc.ExitCode } catch { }
    $status = 'OK'
    if ($TimedOut) { $status = 'TIMEOUT' }
    elseif ($code -ne 0 -or $frames -eq 0) { $status = 'FAIL' }
    $errLines = ''
    if ($status -eq 'FAIL') {
        $errLines = (($txt -split "[\r\n]+") | Where-Object { $_ -and $_ -notmatch '^\s*frame=' } | Select-Object -Last 3) -join ' | '
    }
    $fps = 0.0
    if ($secs -gt 0 -and $frames -gt 0) { $fps = $frames / $secs }
    return [pscustomobject]@{ Status = $status; Frames = $frames; Secs = $secs; Fps = $fps; Error = $errLines }
}

# ---------------------------------------------------------------- media info (from `ffmpeg -i`)
function Split-TopLevel([string]$s) {
    $parts = New-Object System.Collections.ArrayList
    $depth = 0; $cur = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '(' -or $ch -eq '[') { $depth++ }
        elseif ($ch -eq ')' -or $ch -eq ']') { $depth-- }
        if ($ch -eq ',' -and $depth -le 0) { [void]$parts.Add($cur.ToString().Trim()); [void]$cur.Clear() }
        else { [void]$cur.Append($ch) }
    }
    [void]$parts.Add($cur.ToString().Trim())
    return ,@($parts)
}

function Get-MediaInfo([string]$Path, [int]$Index) {
    $r = Invoke-FfText ("-hide_banner -i `"$Path`"") ("probe_{0:D3}" -f $Index)
    $lines = $r.Text -split "[\r\n]+"
    $vIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'Stream #\d+:\d+.*: Video: ' -and $lines[$i] -notmatch 'attached pic') { $vIdx = $i; break }
    }
    if ($vIdx -lt 0) { return $null }
    $line = $lines[$vIdx]
    $body = $line.Substring($line.IndexOf('Video: ') + 7)
    $seg = Split-TopLevel $body

    $codec = ($seg[0] -split '\s+')[0]
    $profile = ''; if ($seg[0] -match '\(([^)]*)\)') { $profile = $Matches[1] }
    $pixfmt = ''; $colorTok = @()
    if ($seg.Count -gt 1) {
        $pixfmt = ($seg[1] -split '\(')[0].Trim()
        if ($seg[1] -match '\(([^)]*)\)') { $colorTok = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() }) }
    }
    $w = 0; $h = 0
    foreach ($sgm in $seg) { if ($sgm -match '^(\d{2,5})x(\d{2,5})') { $w = [int]$Matches[1]; $h = [int]$Matches[2]; break } }
    $fps = 0.0
    foreach ($sgm in $seg) { if ($sgm -match '^([\d.]+)\s+fps') { $fps = [double]$Matches[1]; break } }
    if ($fps -le 0) { foreach ($sgm in $seg) { if ($sgm -match '^([\d.]+)\s+tbr') { $fps = [double]$Matches[1]; break } } }
    if ($fps -le 0) { $fps = 24.0 }

    $transfer = ''; $primaries = ''
    foreach ($t in $colorTok) { if ($t -match '^(\w+)/(\w+)/([\w-]+)$') { $primaries = $Matches[2]; $transfer = $Matches[3] } }
    $interlaced = [bool]($colorTok -match '(top|bottom).*first')

    $dv = $null
    for ($i = $vIdx + 1; $i -lt [math]::Min($vIdx + 15, $lines.Count); $i++) {
        if ($lines[$i] -match 'Stream #\d+:\d+') { break }
        if ($lines[$i] -match 'DOVI configuration record:.*profile:\s*(\d+)') { $dv = [int]$Matches[1] }
    }
    $dur = 0.0; $br = 0.0
    $dl = $lines | Where-Object { $_ -match '^\s*Duration:' } | Select-Object -First 1
    if ($dl -match 'Duration:\s*(\d+):(\d+):([\d.]+)') { $dur = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [double]$Matches[3] }
    if ($dl -match 'bitrate:\s*(\d+)\s*kb/s') { $br = [double]$Matches[1] / 1000 }

    $bits = 8
    if ($pixfmt -match '10') { $bits = 10 } elseif ($pixfmt -match '12') { $bits = 12 }
    $hdrType = 'sdr'
    if ($null -ne $dv) { $hdrType = "dv-p$dv" }
    elseif ($transfer -eq 'smpte2084') { $hdrType = 'hdr10' }
    elseif ($transfer -eq 'arib-std-b67') { $hdrType = 'hlg' }
    $isHdr = ($hdrType -ne 'sdr')
    $tm = ($isHdr -and ($dv -ne 5))   # Dolby Vision profile 5 cannot be tone-mapped with zscale/tonemap

    $res = 'sd'
    if ($w -ge 3000 -or $h -ge 2000) { $res = '4k' }
    elseif ($w -ge 1800 -or $h -ge 1000) { $res = '1080p' }
    elseif ($w -ge 1200 -or $h -ge 680) { $res = '720p' }
    $codecShort = $codec -replace 'mpeg2video', 'mpeg2'
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        Path = $Path; File = $item.Name; SizeMB = [math]::Round($item.Length / 1MB, 1)
        Codec = $codec; CodecShort = $codecShort; Profile = $profile; PixFmt = $pixfmt; Bits = $bits
        Width = $w; Height = $h; Res = $res; Fps = $fps; BitrateMbps = [math]::Round($br, 1); Duration = $dur
        Transfer = $transfer; Primaries = $primaries; Dv = $dv; HdrType = $hdrType; IsHdr = $isHdr; Tm = $tm
        Interlaced = $interlaced; Class = ("{0}-{1}-{2}" -f $codecShort, $res, $hdrType)
    }
}

# ---------------------------------------------------------------- filter chains
function Get-FitSize($Info, [int]$BoxW, [int]$BoxH) {
    if ($BoxW -le 0) { $ratio = 1.0 } else { $ratio = [math]::Min($BoxW / $Info.Width, $BoxH / $Info.Height) }
    $W = [int](2 * [math]::Round($Info.Width * $ratio / 2))
    $H = [int](2 * [math]::Round($Info.Height * $ratio / 2))
    return [pscustomobject]@{ W = $W; H = $H; Ratio = $ratio }
}

function Get-SwChain($Info, [int]$W, [int]$H, [string]$OutFmt) {
    $scale = ($W -ne $Info.Width -or $H -ne $Info.Height)
    if ($Info.Tm) {
        $tin = 'smpte2084'; if ($Info.Transfer -eq 'arib-std-b67') { $tin = 'arib-std-b67' }
        $size = ''; if ($scale) { $size = "w=${W}:h=${H}:" }
        return "zscale=${size}tin=${tin}:min=bt2020nc:pin=bt2020:rin=tv:t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=${OutFmt}"
    }
    $f = @()
    if ($scale) { $f += "scale=${W}:${H}" }
    $f += "format=${OutFmt}"
    return ($f -join ',')
}

function Get-BitrateM([int]$H) {
    if ($H -ge 1800) { return 20 }
    if ($H -ge 900) { return 8 }
    if ($H -ge 600) { return 4 }
    return 2
}

# ---------------------------------------------------------------- reporting helpers
function F($v, $fmt) { if ($null -eq $v) { return 'n/a' } else { return ($fmt -f $v) } }

function Add-Row($row) {
    [void]$script:Results.Add($row)
    $cpuS = 'n/a'; if ($null -ne $row.CpuAvg) { $cpuS = '{0:N0}%' -f $row.CpuAvg }
    $lbl = "{0,-6} {1}" -f $row.Variant.ToUpper(), $row.ScenarioLabel
    if ($row.Status -eq 'OK' -or ($row.Status -eq 'TIMEOUT' -and $row.Fps -gt 0)) {
        $tag = ''; if ($row.Status -eq 'TIMEOUT') { $tag = ' (timeout, partial)' }
        Write-Host ("    {0,-46} {1,7:N1} fps {2,6:N2}x  CPU {3,5}  GPU {4:N0}/{5:N0}/{6:N0}%{7}" -f `
            $lbl, $row.Fps, $row.Realtime, $cpuS, $row.GpuDec, $row.GpuEnc, $row.GpuVpp, $tag)
    } else {
        $col = 'Yellow'; if ($row.Status -eq 'SKIP') { $col = 'DarkGray' }
        Write-Host ("    {0,-46} {1}  {2}" -f $lbl, $row.Status, $row.Error) -ForegroundColor $col
    }
}

function Invoke-Variant {
    param($Info, [string]$ScenKey, [string]$ScenLabel, [string]$Variant, [string]$VarLabel, [string]$FfArgs, [string]$SkipReason)
    $base = [ordered]@{
        File = $Info.File; Class = $Info.Class; Scenario = $ScenKey; ScenarioLabel = $ScenLabel; Variant = $Variant; VariantLabel = $VarLabel
        Status = 'SKIP'; Frames = 0; Seconds = 0.0; Fps = 0.0; Realtime = 0.0; CpuAvg = $null
        GpuDec = 0.0; GpuEnc = 0.0; GpuVpp = 0.0; Error = ''; Cmd = $FfArgs
    }
    if ($SkipReason) { $base.Error = $SkipReason; Add-Row ([pscustomobject]$base); return }
    # Warm-up: the first run of a GPU variant pays one-off costs (CUDA kernel JIT compile, driver init) that would
    # otherwise be counted as slow throughput. Run the same command for 2 s once per variant before timing it.
    if ($Variant -ne 'cpu' -and -not $script:Warmed.ContainsKey($Variant)) {
        $script:Warmed[$Variant] = $true
        $warmArgs = $FfArgs -replace ("-t {0} " -f $ClipSeconds), '-t 2 '
        $wj = Start-Ff $warmArgs ('warm_{0}_{1}' -f $Variant, $script:Results.Count)
        [void](Wait-Ff @($wj) 90)
    }
    $fb = [IO.Path]::GetFileNameWithoutExtension($Info.File) -replace '[^A-Za-z0-9]+', '_'
    if ($fb.Length -gt 24) { $fb = $fb.Substring(0, 24) }
    $tag = '{0:D3}_{1}_{2}_{3}' -f $script:Results.Count, $fb, $ScenKey, $Variant
    $job = Start-Ff $FfArgs $tag
    $mon = Wait-Ff @($job) $TimeoutSec
    $r = Get-JobResult $job $mon.TimedOut
    $base.Status = $r.Status; $base.Frames = $r.Frames; $base.Seconds = [math]::Round($r.Secs, 2)
    $base.Fps = [math]::Round($r.Fps, 2); $base.Realtime = [math]::Round($r.Fps / $Info.Fps, 2)
    if ($null -ne $mon.CpuAvg) { $base.CpuAvg = [math]::Round($mon.CpuAvg, 1) }
    $base.GpuDec = [math]::Round($mon.Gpu.VideoDecode, 1); $base.GpuEnc = [math]::Round($mon.Gpu.VideoEncode, 1)
    $base.GpuVpp = [math]::Round($mon.Gpu.VideoProcessing, 1); $base.Error = $r.Error
    Add-Row ([pscustomobject]$base)
}

# ---------------------------------------------------------------- system info
Write-Section 'System info'
$cpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
$gpus    = @(Get-CimInstance Win32_VideoController)
$os      = Get-CimInstance Win32_OperatingSystem
$cs      = Get-CimInstance Win32_ComputerSystem
$plan = ''; try { $plan = ((powercfg /getactivescheme) -join ' ').Trim() } catch { }
$idle = New-Object 'System.Collections.Generic.List[double]'
1..4 | ForEach-Object {
    try { $idle.Add([double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime) } catch { }
    Start-Sleep -Milliseconds 700
}
$idleAvg = $null; if ($idle.Count -gt 0) { $idleAvg = [math]::Round(($idle | Measure-Object -Average).Average, 1) }
$ffVer = ((Invoke-FfText '-hide_banner -version' 'sys_version').Text -split "[\r\n]+" | Select-Object -First 1)
$sys = [ordered]@{
    Host = $HostName; Date = (Get-Date).ToString('s'); OS = "{0} (build {1})" -f $os.Caption, $os.BuildNumber
    CPU = $cpuInfo.Name.Trim(); Cores = $cpuInfo.NumberOfCores; Threads = $cpuInfo.NumberOfLogicalProcessors
    RamGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    GPUs = @($gpus | ForEach-Object { "{0} (driver {1})" -f $_.Name, $_.DriverVersion })
    PowerPlan = $plan; IdleCpuPct = $idleAvg; Ffmpeg = $ffVer
    ClipSeconds = $ClipSeconds; ClipStart = $ClipStart; TimeoutSec = $TimeoutSec
}
$sys.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-14} {1}" -f $_.Key, ($_.Value -join '; ')) }
if ($idleAvg -gt 20) { Write-Host ("  WARNING: CPU is {0}% busy before the tests; close background apps for cleaner CPU numbers." -f $idleAvg) -ForegroundColor Yellow }

# ---------------------------------------------------------------- capabilities and QSV probes
Write-Section 'Capabilities and QSV probes'
$encs = (Invoke-FfText '-hide_banner -encoders' 'sys_encoders').Text
$decs = (Invoke-FfText '-hide_banner -decoders' 'sys_decoders').Text
$fils = (Invoke-FfText '-hide_banner -filters' 'sys_filters').Text
function Has-Name([string]$text, [string]$name) { return [bool]($text -match ("(?m)^\s*\S+\s+{0}\s" -f [regex]::Escape($name))) }
$caps = [ordered]@{
    libx264 = (Has-Name $encs 'libx264'); h264_qsv_enc = (Has-Name $encs 'h264_qsv')
    h264_nvenc = (Has-Name $encs 'h264_nvenc'); h264_amf = (Has-Name $encs 'h264_amf')
    scale_cuda = (Has-Name $fils 'scale_cuda'); tonemap_cuda = (Has-Name $fils 'tonemap_cuda'); libplacebo = (Has-Name $fils 'libplacebo')
    zscale = (Has-Name $fils 'zscale'); tonemap = (Has-Name $fils 'tonemap'); tonemap_opencl = (Has-Name $fils 'tonemap_opencl')
    vpp_qsv = (Has-Name $fils 'vpp_qsv')
}
foreach ($n in 'h264_qsv', 'hevc_qsv', 'av1_qsv', 'vp9_qsv', 'mpeg2_qsv', 'vc1_qsv') { $caps["dec_$n"] = (Has-Name $decs $n) }
$caps.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-16} {1}" -f $_.Key, $_.Value) }
if (-not $caps['libx264']) { Write-Host 'This ffmpeg build has no libx264. Use a gyan.dev build.' -ForegroundColor Red; exit 1 }

$Common = '-hide_banner -nostdin -y -stats'
$ProbeSrc = Join-Path $WorkDir 'probe_h264.mp4'
$g = Invoke-FfText ("$Common -f lavfi -i testsrc2=size=1280x720:rate=30 -t 3 -c:v libx264 -preset ultrafast -pix_fmt yuv420p `"$ProbeSrc`"") 'gen_probe'
if ($g.Code -ne 0) { Write-Host 'Could not create probe clip.' -ForegroundColor Red; Write-Host $g.Text; exit 1 }

if ($caps['h264_qsv_enc']) {
    $q = Invoke-FfText '-hide_banner -nostdin -y -f lavfi -i testsrc2=size=1280x720:rate=30 -t 1 -c:v h264_qsv -f null -' 'sys_qsv_probe'
    $script:QsvOk = ($q.Code -eq 0)
}
Write-Host ("  QSV H.264 encode (software frames): {0}" -f $(if ($script:QsvOk) { 'OK' } else { 'FAILED' }))

$QCands = @(
    [pscustomobject]@{ Name = 'dxva2';    Init = '-init_hw_device qsv=hw:hw_any,child_device_type=dxva2';   Dev = '-hwaccel_device hw' },
    [pscustomobject]@{ Name = 'd3d11va';  Init = '-init_hw_device qsv=hw:hw_any,child_device_type=d3d11va'; Dev = '-hwaccel_device hw' },
    [pscustomobject]@{ Name = 'dxva2-hw'; Init = '-init_hw_device qsv=hw:hw,child_device_type=dxva2';       Dev = '-hwaccel_device hw' },
    [pscustomobject]@{ Name = 'default';  Init = '';                                                          Dev = '' }
)
$QMode = 'none'
if ($script:QsvOk) {
    foreach ($c in $QCands) {
        $cand = ("{0} -hwaccel qsv {1} -hwaccel_output_format qsv" -f $c.Init, $c.Dev).Trim()
        $pr = Invoke-FfText ("$Common $cand -c:v h264_qsv -i `"$ProbeSrc`" -t 1 -vf vpp_qsv=format=nv12 -c:v h264_qsv -f null -") ("sys_qsv_hw_" + $c.Name)
        if ($pr.Code -eq 0) { $script:QsvHwOk = $true; $script:QIn = $cand; $QMode = $c.Name; break }
    }
}
Write-Host ("  QSV hardware path (decode + vpp + encode): {0}" -f $(if ($script:QsvHwOk) { "OK ($QMode)" } else { 'not available' }))

# OpenCL: plain "opencl=ocl" fails on multi-GPU / multi-platform machines ("No such device"), so try explicit platform.device indices too.
$script:ClDev = 'opencl=ocl'
$script:PlOk = $false; $script:PlDev = 'vulkan=vk'
if ($caps['tonemap_opencl']) {
    foreach ($d in 'opencl=ocl', 'opencl=ocl:0.0', 'opencl=ocl:1.0', 'opencl=ocl:0.1', 'opencl=ocl:1.1') {
        $cl = Invoke-FfText ("$Common -init_hw_device $d -filter_hw_device ocl -f lavfi -i testsrc2=size=640x360:rate=30,format=p010le -t 1 -vf setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084:range=tv,hwupload,tonemap_opencl=format=nv12,hwdownload,format=nv12 -c:v libx264 -preset ultrafast -f null -") ('sys_cl_probe_' + ($d -replace '[^A-Za-z0-9]', '_'))
        if ($cl.Code -eq 0) { $script:ClOk = $true; $script:ClDev = $d; break }
    }
}
Write-Host ("  OpenCL tone-map (any OpenCL device): {0}" -f $(if ($script:ClOk) { "OK ($($script:ClDev))" } elseif (-not $caps['tonemap_opencl']) { 'not available (filter not in this ffmpeg build; gyan.dev FULL build has it)' } else { 'not available (no usable OpenCL device, see logs\sys_cl_probe_*.err.txt)' }))
# libplacebo (Vulkan): GPU tone-mapping and scaling on any vendor with a Vulkan driver
if ($caps['libplacebo']) {
    foreach ($d in 'vulkan=vk', 'vulkan=vk:0', 'vulkan=vk:1') {
        $pl = Invoke-FfText ("$Common -init_hw_device $d -filter_hw_device vk -f lavfi -i testsrc2=size=640x360:rate=30,format=p010le -t 1 -vf libplacebo=tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=nv12 -c:v libx264 -preset ultrafast -f null -") ('sys_plc_probe_' + ($d -replace '[^A-Za-z0-9]', '_'))
        if ($pl.Code -eq 0) { $script:PlOk = $true; $script:PlDev = $d; break }
    }
}
Write-Host ("  libplacebo (Vulkan) tone-map: {0}" -f $(if ($script:PlOk) { "OK ($($script:PlDev))" } elseif (-not $caps['libplacebo']) { 'not available (filter not in this ffmpeg build; gyan.dev FULL build has it)' } else { 'not available (no usable Vulkan device)' }))

# ---------------------------------------------------------------- GPU inventory, NVIDIA and AMD probes
Write-Section 'GPU inventory'
$HasIntel = $false; $HasNvidia = $false; $HasAmd = $false
foreach ($gp in $gpus) {
    $ven = 'other'
    if ($gp.PNPDeviceID -match 'VEN_8086') { $ven = 'intel'; $HasIntel = $true }
    elseif ($gp.PNPDeviceID -match 'VEN_10DE') { $ven = 'nvidia'; $HasNvidia = $true }
    elseif ($gp.PNPDeviceID -match 'VEN_1002') { $ven = 'amd'; $HasAmd = $true }
    Write-Host ("  {0,-7} {1} (driver {2})" -f $ven, $gp.Name, $gp.DriverVersion)
}
$script:NvOk = $false; $script:NvHwOk = $false; $script:NvEnc = ''; $NvNote = ''
$script:AmfOk = $false; $AmfNote = ''
if ($HasNvidia) {
    if (-not $caps['h264_nvenc']) { $NvNote = 'h264_nvenc is not in this ffmpeg build' }
    else {
        foreach ($opt in '-preset p4', '-preset medium', '') {
            $r = Invoke-FfText ("$Common -f lavfi -i testsrc2=size=1280x720:rate=30 -t 1 -c:v h264_nvenc -b:v 4M $opt -f null -") 'sys_nvenc_probe'
            if ($r.Code -eq 0) { $script:NvOk = $true; $script:NvEnc = $opt; break }
        }
        if (-not $script:NvOk) { $NvNote = 'NVENC init failed (driver too old for this ffmpeg? see logs\sys_nvenc_probe.err.txt)' }
        else {
            $nvvf = ''; if ($caps['scale_cuda']) { $nvvf = '-vf scale_cuda=w=640:h=360:format=nv12' }
            $r = Invoke-FfText ("$Common -hwaccel cuda -hwaccel_output_format cuda -i `"$ProbeSrc`" -t 1 $nvvf -c:v h264_nvenc -b:v 4M $($script:NvEnc) -f null -") 'sys_nvenc_hw_probe'
            $script:NvHwOk = ($r.Code -eq 0)
            if (-not $script:NvHwOk) { $NvNote = 'CUDA decode path failed (see logs\sys_nvenc_hw_probe.err.txt)' }
        }
    }
    Write-Host ("  NVENC encode: {0}   full CUDA path: {1}   scale_cuda: {2}   tonemap_cuda: {3}   {4}" -f $(if ($script:NvOk) { "OK ($($script:NvEnc))" } else { 'FAILED' }),
        $(if ($script:NvHwOk) { 'OK' } else { 'not available' }), $caps['scale_cuda'], $caps['tonemap_cuda'], $NvNote)
} else { Write-Host '  NVENC: skipped (no NVIDIA GPU)' }
if ($HasAmd) {
    if (-not $caps['h264_amf']) { $AmfNote = 'h264_amf is not in this ffmpeg build' }
    else {
        $r = Invoke-FfText ("$Common -f lavfi -i testsrc2=size=1280x720:rate=30 -t 1 -c:v h264_amf -b:v 4M -f null -") 'sys_amf_probe'
        $script:AmfOk = ($r.Code -eq 0)
        if (-not $script:AmfOk) { $AmfNote = 'AMF init failed (see logs\sys_amf_probe.err.txt)' }
    }
    Write-Host ("  AMF encode: {0}   {1}" -f $(if ($script:AmfOk) { 'OK' } else { 'FAILED' }), $AmfNote)
} else { Write-Host '  AMF: skipped (no AMD GPU)' }
$sys['Engines'] = @(
    "QSV encode " + $(if ($script:QsvOk) { 'OK' } else { 'FAILED' }) + ", full path " + $(if ($script:QsvHwOk) { "OK ($QMode)" } else { 'not available' }),
    "OpenCL tonemap " + $(if ($script:ClOk) { 'OK' } else { 'not available' }),
    $(if ($HasNvidia) { "NVENC " + $(if ($script:NvOk) { 'OK' } else { 'FAILED' }) + ", CUDA path " + $(if ($script:NvHwOk) { 'OK' } else { 'not available' }) + ", tonemap_cuda " + $caps['tonemap_cuda'] + " " + $NvNote } else { "NVENC: no NVIDIA GPU" }),
    $(if ($HasAmd) { "AMF " + $(if ($script:AmfOk) { 'OK' } else { 'FAILED' }) + " " + $AmfNote } else { "AMF: no AMD GPU" })
)

# ---------------------------------------------------------------- inventory
Write-Section "Scanning $MediaDir"
if (-not (Test-Path $MediaDir)) { Write-Host "Media folder not found: $MediaDir" -ForegroundColor Red; exit 1 }
$exts = '.mkv', '.mp4', '.m4v', '.mov', '.ts', '.m2ts', '.mts', '.avi', '.webm', '.wmv', '.mpg', '.mpeg'
$files = @(Get-ChildItem -Path $MediaDir -Recurse -File | Where-Object {
        $exts -contains $_.Extension.ToLower() -and $_.Name -notlike '_*' -and $_.FullName -notmatch '[\\/]_[^\\/]*[\\/]' })
$infos = New-Object System.Collections.ArrayList
$idx = 0
foreach ($f in $files) {
    $idx++
    $info = Get-MediaInfo $f.FullName $idx
    if (-not $info) { Write-Host ("  {0}: no video stream, skipped" -f $f.Name) -ForegroundColor Yellow; continue }
    if ($Filter -ne '*' -and ($info.File -notlike $Filter) -and ($info.Class -notlike $Filter)) { continue }
    [void]$infos.Add($info)
    if ($MaxFiles -gt 0 -and $infos.Count -ge $MaxFiles) { break }
}
if ($infos.Count -eq 0) {
    Write-Host 'No usable media files found. Put clips under .\media\<category>\ (see docs\media-clips.md).' -ForegroundColor Red
    exit 1
}
foreach ($i in $infos) {
    $dvTxt = ''; if ($null -ne $i.Dv) { $dvTxt = " DV profile $($i.Dv)" }
    Write-Host ("  {0,-40} {1,-22} {2}x{3} {4}bit {5:N2}fps {6:N1}Mbps{7}" -f $i.File, $i.Class, $i.Width, $i.Height, $i.Bits, $i.Fps, $i.BitrateMbps, $dvTxt)
}

# ---------------------------------------------------------------- tests
$NvDecCache = @{}
function Test-NvDecode($Info) {
    $key = "{0}|{1}" -f $Info.Codec, $Info.PixFmt
    if ($NvDecCache.ContainsKey($key)) { return $NvDecCache[$key] }
    $res = [pscustomobject]@{ Ok = $false; Reason = '' }
    if (-not $script:NvHwOk) { $res.Reason = 'CUDA hardware path not available' }
    else {
        $ss = 0; if ($Info.Duration -gt ($ClipStart + $ClipSeconds + 2)) { $ss = $ClipStart }
        $r = Invoke-FfText ("$Common -hwaccel cuda -hwaccel_output_format cuda -ss $ss -t 1 -i `"$($Info.Path)`" -map 0:v:0 -f null -") ("nvdec_probe_{0}" -f $NvDecCache.Count)
        if ($r.Code -eq 0 -and $r.Text -match 'frame=\s*[1-9]') { $res.Ok = $true } else { $res.Reason = "NVDEC cannot decode $($Info.Codec) $($Info.PixFmt) (probe failed)" }
    }
    $NvDecCache[$key] = $res
    return $res
}

$HwDecCache = @{}
function Test-HwDecode($Info) {
    $key = "{0}|{1}|{2}" -f $Info.Codec, $Info.PixFmt, $Info.Profile
    if ($HwDecCache.ContainsKey($key)) { return $HwDecCache[$key] }
    $dec = "{0}_qsv" -f $Info.CodecShort
    $res = [pscustomobject]@{ Ok = $false; Reason = '' }
    if (-not $script:QsvHwOk) { $res.Reason = 'QSV hardware path not available' }
    elseif (-not $caps.Contains("dec_$dec")) { $res.Reason = "no $dec decoder in this ffmpeg build" }
    else {
        $ss = 0; if ($Info.Duration -gt ($ClipStart + $ClipSeconds + 2)) { $ss = $ClipStart }
        $r = Invoke-FfText ("$Common $($script:QIn) -c:v $dec -ss $ss -t 1 -i `"$($Info.Path)`" -map 0:v:0 -f null -") ("hwdec_probe_{0}" -f $HwDecCache.Count)
        if ($r.Code -eq 0 -and $r.Text -match 'frame=\s*[1-9]') { $res.Ok = $true } else { $res.Reason = "QSV hardware cannot decode $($Info.Codec) $($Info.PixFmt) (probe failed)" }
    }
    $HwDecCache[$key] = $res
    return $res
}

$Scen = @(
    [pscustomobject]@{ Key = 'to1080'; BoxW = 1920; BoxH = 1080; Name = '1080p' },
    [pscustomobject]@{ Key = 'to720';  BoxW = 1280; BoxH = 720;  Name = '720p' },
    [pscustomobject]@{ Key = 'same';   BoxW = 0;    BoxH = 0;    Name = '' }
)
$ResLabel = @{ '4k' = '4K'; '1080p' = '1080p'; '720p' = '720p'; 'sd' = 'SD' }

Write-Section ("Running tests (clip {0}s, timeout {1}s per run)" -f $ClipSeconds, $TimeoutSec)
foreach ($info in $infos) {
    Write-Host ""
    Write-Host ("  >> {0}  [{1}]" -f $info.File, $info.Class) -ForegroundColor White
    if ($info.Interlaced) { Write-Host '     note: interlaced source (not deinterlaced in these tests)' -ForegroundColor DarkYellow }
    if ($info.Dv -eq 5) { Write-Host '     note: Dolby Vision profile 5 has no HDR10 fallback and cannot be tone-mapped with these filters; timed WITHOUT tone-mapping (needs libplacebo)' -ForegroundColor DarkYellow }
    $ss = 0; if ($info.Duration -gt ($ClipStart + $ClipSeconds + 2)) { $ss = $ClipStart }
    $seek = "-ss $ss -t $ClipSeconds -i `"$($info.Path)`""
    $hw = Test-HwDecode $info
    $nvd = [pscustomobject]@{ Ok = $false; Reason = 'no NVIDIA GPU' }
    if ($HasNvidia) { $nvd = Test-NvDecode $info }
    $dec = "{0}_qsv" -f $info.CodecShort

    foreach ($sc in $Scen) {
        if ($Scenarios -notcontains $sc.Key) { continue }
        $fit = Get-FitSize $info $sc.BoxW $sc.BoxH
        if ($sc.Key -ne 'same' -and $fit.Ratio -ge 0.98) { continue }   # would not downscale
        $W = $fit.W; $H = $fit.H
        $dstName = $sc.Name; if ($sc.Key -eq 'same') { $dstName = $ResLabel[$info.Res] }
        $label = "{0} -> {1}" -f $ResLabel[$info.Res], $dstName
        if ($info.Tm) { $label += ' HDR->SDR' } elseif ($info.IsHdr) { $label += ' (DV p5, no tone-map)' } elseif ($sc.Key -eq 'same') { $label += ' (bitrate only)' }
        $B = Get-BitrateM $H
        $enc = "-preset veryfast -b:v ${B}M"
        $mapArgs = '-map 0:v:0 -an -sn'

        $swOk = $true; if ($info.Tm -and -not ($caps['zscale'] -and $caps['tonemap'])) { $swOk = $false }
        $nvOpts = "$($script:NvEnc) -b:v ${B}M"

        # CPU
        if ($Variants -contains 'cpu') {
            $skip = ''
            if (-not $swOk) { $skip = 'zscale/tonemap filters missing in this ffmpeg build' }
            $chain = Get-SwChain $info $W $H 'yuv420p'
            Invoke-Variant $info $sc.Key $label 'cpu' 'CPU (libx264)' "$Common $seek $mapArgs -vf `"$chain`" -c:v libx264 $enc -f null -" $skip
        }
        if ($HasIntel) {
            # QSV full hardware
            if ($Variants -contains 'hw') {
                $skip = ''
                if (-not $hw.Ok) { $skip = $hw.Reason }
                elseif (-not $caps['vpp_qsv']) { $skip = 'vpp_qsv filter missing' }
                $vpp = "vpp_qsv=w=${W}:h=${H}:format=nv12"
                if ($info.Tm) { $vpp += ':tonemap=1' }
                Invoke-Variant $info $sc.Key $label 'hw' 'QSV full HW' "$Common $($script:QIn) -c:v $dec -ss $ss -t $ClipSeconds -i `"$($info.Path)`" $mapArgs -vf `"$vpp`" -c:v h264_qsv $enc -f null -" $skip
            }
            # hybrid: CPU decode+filters, QSV encode
            if ($Variants -contains 'hyb') {
                $skip = ''
                if (-not $script:QsvOk) { $skip = 'QSV encoder not working' }
                elseif (-not $swOk) { $skip = 'zscale/tonemap filters missing' }
                $chain = Get-SwChain $info $W $H 'nv12'
                Invoke-Variant $info $sc.Key $label 'hyb' 'CPU filters + QSV encode' "$Common $seek $mapArgs -vf `"$chain`" -c:v h264_qsv $enc -f null -" $skip
            }
        }
        if ($HasNvidia) {
            # NVIDIA full hardware: NVDEC + scale_cuda (+ tonemap_cuda) + NVENC
            if ($Variants -contains 'nv') {
                $skip = ''
                if (-not $nvd.Ok) { $skip = $nvd.Reason }
                elseif (-not $caps['scale_cuda']) { $skip = 'scale_cuda filter missing in this ffmpeg build' }
                elseif ($info.Tm -and -not $caps['tonemap_cuda']) { $skip = 'tonemap_cuda exists only in jellyfin-ffmpeg (not in upstream/gyan builds); use PLC / CL for GPU tone-map, NVD / HYBN for CPU tone-map + NVENC' }
                $nvf = "scale_cuda=w=${W}:h=${H}:format=nv12"
                if ($info.Tm) { $nvf = "scale_cuda=w=${W}:h=${H}:format=p010le,tonemap_cuda=tonemap=bt2390:format=nv12:p=bt709:t=bt709:m=bt709" }
                Invoke-Variant $info $sc.Key $label 'nv' 'NVIDIA full HW (NVDEC+NVENC)' "$Common -hwaccel cuda -hwaccel_output_format cuda -ss $ss -t $ClipSeconds -i `"$($info.Path)`" $mapArgs -vf `"$nvf`" -c:v h264_nvenc $nvOpts -f null -" $skip
            }
            # hybrid: CPU decode+filters, NVENC encode
            if ($Variants -contains 'hybn') {
                $skip = ''
                if (-not $script:NvOk) { $skip = "NVENC not working $NvNote" } elseif (-not $swOk) { $skip = 'zscale/tonemap filters missing' }
                $chain = Get-SwChain $info $W $H 'nv12'
                Invoke-Variant $info $sc.Key $label 'hybn' 'CPU filters + NVENC' "$Common $seek $mapArgs -vf `"$chain`" -c:v h264_nvenc $nvOpts -f null -" $skip
            }
            # NVDEC decode, CPU tone-map, NVENC encode (HDR only): the usual fallback when tonemap_cuda is missing
            if ($Variants -contains 'nvd' -and $info.Tm) {
                $skip = ''
                if (-not $nvd.Ok) { $skip = $nvd.Reason } elseif (-not $script:NvOk) { $skip = 'NVENC not working' } elseif (-not $swOk) { $skip = 'zscale/tonemap filters missing' }
                $chain = "hwdownload,format=p010le," + (Get-SwChain $info $W $H 'nv12')
                Invoke-Variant $info $sc.Key $label 'nvd' 'NVDEC + CPU tonemap + NVENC' "$Common -hwaccel cuda -hwaccel_output_format cuda -ss $ss -t $ClipSeconds -i `"$($info.Path)`" $mapArgs -vf `"$chain`" -c:v h264_nvenc $nvOpts -f null -" $skip
            }
        }
        if ($HasAmd -and $Variants -contains 'hyba') {
            # hybrid: CPU decode+filters, AMD AMF encode
            $skip = ''
            if (-not $script:AmfOk) { $skip = "AMF not working $AmfNote" } elseif (-not $swOk) { $skip = 'zscale/tonemap filters missing' }
            $chain = Get-SwChain $info $W $H 'nv12'
            Invoke-Variant $info $sc.Key $label 'hyba' 'CPU filters + AMD AMF encode' "$Common $seek $mapArgs -vf `"$chain`" -c:v h264_amf -b:v ${B}M -f null -" $skip
        }
        # OpenCL tone-map (HDR only)
        if ($Variants -contains 'cl' -and $info.Tm) {
            $skip = ''
            if (-not $caps['tonemap_opencl']) { $skip = 'tonemap_opencl is not compiled into this ffmpeg (use the gyan.dev FULL build)' }
            elseif (-not $script:ClOk) { $skip = 'OpenCL probe failed (no usable OpenCL device/runtime, see logs\sys_cl_probe_*.err.txt)' }
            $pre = ''; if ($W -ne $info.Width -or $H -ne $info.Height) { $pre = "scale=${W}:${H}," }
            $tm = 'tonemap_opencl=tonemap=hable:desat=0:format=nv12:transfer=bt709:matrix=bt709:primaries=bt709:range=tv'
            $chain = "${pre}format=p010le,hwupload,${tm},hwdownload,format=nv12"
            $clEnc = "-c:v libx264 $enc"; $clName = 'OpenCL tonemap + x264 encode'
            if ($script:QsvOk) { $clEnc = "-c:v h264_qsv $enc"; $clName = 'OpenCL tonemap + QSV encode' }
            elseif ($script:NvOk) { $clEnc = "-c:v h264_nvenc $nvOpts"; $clName = 'OpenCL tonemap + NVENC encode' }
            Invoke-Variant $info $sc.Key $label 'cl' $clName "$Common -init_hw_device $($script:ClDev) -filter_hw_device ocl $seek $mapArgs -vf `"$chain`" $clEnc -f null -" $skip
        }
        # libplacebo (Vulkan): GPU tone-map + scale for any vendor; also handles Dolby Vision profile 5 properly
        if ($Variants -contains 'plc' -and $info.IsHdr) {
            $skip = ''
            if (-not $caps['libplacebo']) { $skip = 'libplacebo filter is not compiled into this ffmpeg (use the gyan.dev FULL build)' }
            elseif (-not $script:PlOk) { $skip = 'libplacebo/Vulkan probe failed (no usable Vulkan device, see logs\sys_plc_probe_*.err.txt)' }
            $pf = "libplacebo=w=${W}:h=${H}:tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=nv12"
            $plEnc = "-c:v libx264 $enc"; $plName = 'libplacebo (Vulkan) tonemap + x264 encode'
            if ($script:QsvOk) { $plEnc = "-c:v h264_qsv $enc"; $plName = 'libplacebo (Vulkan) tonemap + QSV encode' }
            elseif ($script:NvOk) { $plEnc = "-c:v h264_nvenc $nvOpts"; $plName = 'libplacebo (Vulkan) tonemap + NVENC encode' }
            elseif ($script:AmfOk) { $plEnc = "-c:v h264_amf -b:v ${B}M"; $plName = 'libplacebo (Vulkan) tonemap + AMF encode' }
            $plLabel = $label -replace '\(DV p5, no tone-map\)', 'HDR->SDR (DV p5)'
            Invoke-Variant $info $sc.Key $plLabel 'plc' $plName "$Common -init_hw_device $($script:PlDev) -filter_hw_device vk $seek $mapArgs -vf `"$pf`" $plEnc -f null -" $skip
        }
    }
}

# ---------------------------------------------------------------- concurrency per class
$ConcRows = New-Object System.Collections.ArrayList
if (-not $NoConcurrency) {
    Write-Section 'Concurrent streams (best non-CPU variant per class, preferred scenario: to720 > to1080 > same)'
    $seen = @{}
    foreach ($info in $infos) {
        if ($seen.ContainsKey($info.Class)) { continue }
        $seen[$info.Class] = $true
        $best = $null
        foreach ($sk in 'to720', 'to1080', 'same') {
            $cand = @($script:Results | Where-Object { $_.File -eq $info.File -and $_.Scenario -eq $sk -and $_.Variant -ne 'cpu' -and $_.Status -eq 'OK' } |
                Sort-Object Realtime -Descending)
            if ($cand.Count -gt 0) { $best = $cand[0]; break }
        }
        if (-not $best) { Write-Host ("  {0}: no working non-CPU variant, skipped" -f $info.Class) -ForegroundColor DarkGray; continue }
        Write-Host ("  {0}  [{1}]  variant {2}, scenario {3}" -f $info.File, $info.Class, $best.Variant, $best.ScenarioLabel) -ForegroundColor White
        foreach ($n in $Streams) {
            $jobs = @()
            for ($i = 1; $i -le $n; $i++) {
                $tag = "conc_{0}_{1}_n{2:D2}_s{3:D2}" -f ($info.Class -replace '[^A-Za-z0-9]+', '_'), $best.Variant, $n, $i
                $jobs += Start-Ff $best.Cmd $tag
            }
            $mon = Wait-Ff $jobs ($TimeoutSec * 2)
            $res = @($jobs | ForEach-Object { Get-JobResult $_ $mon.TimedOut })
            $ok = @($res | Where-Object { $_.Status -eq 'OK' })
            if ($ok.Count -eq 0) { Write-Host ("    {0} streams: FAIL {1}" -f $n, $res[0].Error) -ForegroundColor Yellow; break }
            $agg = ($ok | Measure-Object -Property Fps -Sum).Sum
            $min = ($ok | Measure-Object -Property Fps -Minimum).Minimum
            $minRt = $min / $info.Fps
            $cpuS = 'n/a'; if ($null -ne $mon.CpuAvg) { $cpuS = '{0:N0}%' -f $mon.CpuAvg }
            Write-Host ("    {0,2} streams: aggregate {1,7:N1} fps | slowest {2,6:N1} fps = {3,5:N2}x realtime | CPU {4,5} | GPU {5:N0}/{6:N0}/{7:N0}%" -f `
                $n, $agg, $min, $minRt, $cpuS, $mon.Gpu.VideoDecode, $mon.Gpu.VideoEncode, $mon.Gpu.VideoProcessing)
            [void]$ConcRows.Add([pscustomobject]@{
                Class = $info.Class; File = $info.File; Variant = $best.Variant; Scenario = $best.ScenarioLabel; Streams = $n
                AggFps = [math]::Round($agg, 1); MinFps = [math]::Round($min, 1); MinRealtime = [math]::Round($minRt, 2)
                CpuAvg = $(if ($null -ne $mon.CpuAvg) { [math]::Round($mon.CpuAvg, 1) } else { $null })
                GpuDec = [math]::Round($mon.Gpu.VideoDecode, 1); GpuEnc = [math]::Round($mon.Gpu.VideoEncode, 1); GpuVpp = [math]::Round($mon.Gpu.VideoProcessing, 1)
            })
            if ($minRt -lt 1.0) { break }
        }
    }
}

# ---------------------------------------------------------------- report
Write-Section 'Writing report'

# ---- naming helpers
$CodecNames = @{ h264 = 'H.264'; hevc = 'HEVC'; av1 = 'AV1'; mpeg2 = 'MPEG-2'; mpeg4 = 'MPEG-4'; vp9 = 'VP9'; vc1 = 'VC-1' }
function Get-ClassLabel([string]$c) {
    $p = $c -split '-'
    $codec = $p[0]; if ($CodecNames.ContainsKey($codec)) { $codec = $CodecNames[$codec] } else { $codec = $codec.ToUpper() }
    $res = $p[1]; if ($res -eq '4k') { $res = '4K' } elseif ($res -eq 'sd') { $res = 'SD' }
    $dr = ($p[2..($p.Count - 1)] -join '-')
    if ($dr -eq 'sdr') { $dr = 'SDR' } elseif ($dr -eq 'hdr10') { $dr = 'HDR10' } elseif ($dr -eq 'hlg') { $dr = 'HLG' } elseif ($dr -match '^dv-p(\d+)$') { $dr = "Dolby Vision P$($Matches[1])" }
    return "$res $codec $dr"
}
$VarName = @{
    cpu = 'CPU only'; hw = 'Intel QuickSync (all on GPU)'; hyb = 'CPU decode + QuickSync encode'; cl = 'OpenCL GPU tone-map'
    plc = 'libplacebo (Vulkan) GPU tone-map'; nv = 'NVIDIA all on GPU (NVDEC + NVENC)'; hybn = 'CPU decode + NVENC encode'
    nvd = 'NVDEC decode + CPU tone-map + NVENC'; hyba = 'CPU decode + AMD AMF encode'
}
function Get-VarName([string]$v) { if ($VarName.ContainsKey($v)) { return $VarName[$v] } else { return $v } }
$GpuToneVars = @('hw', 'cl', 'plc', 'nv')                       # tone-mapping runs on a GPU
$EngineOf = @{ hw = 'Intel QuickSync (QSV)'; hyb = 'Intel QuickSync (QSV)'; nv = 'NVIDIA NVENC'; hybn = 'NVIDIA NVENC'; nvd = 'NVIDIA NVENC'; hyba = 'AMD AMF' }
function Get-Verdict([double]$rt) { if ($rt -ge 2.0) { return 'Comfortable' } elseif ($rt -ge 1.0) { return 'Borderline' } else { return 'Too slow' } }

# ---- clip labels (optionally anonymised)
$fileLabel = @{}; $fi = 0
foreach ($i in $infos) { $fi++; if ($Anonymize) { $fileLabel[$i.File] = ('clip-{0:D2}' -f $fi) } else { $fileLabel[$i.File] = $i.File } }
function Get-FileLabel([string]$f) { if ($fileLabel.ContainsKey($f)) { return $fileLabel[$f] } else { return $f } }

# ---- aggregate: one entry per source class + scenario (mean x-realtime over the clips of that class)
$aggRows = New-Object System.Collections.ArrayList
foreach ($cls in @($script:Results | Select-Object -ExpandProperty Class -Unique)) {
    $clipCount = @($infos | Where-Object { $_.Class -eq $cls }).Count
    foreach ($sk in 'to1080', 'to720', 'same') {
        $rows = @($script:Results | Where-Object { $_.Class -eq $cls -and $_.Scenario -eq $sk })
        if ($rows.Count -eq 0) { continue }
        $byVar = @{}
        foreach ($g in ($rows | Group-Object Variant)) {
            $good = @($g.Group | Where-Object { ($_.Status -eq 'OK' -or $_.Status -eq 'TIMEOUT') -and $_.Fps -gt 0 })
            if ($good.Count -gt 0) {
                $cpuVals = @($good | Where-Object { $null -ne $_.CpuAvg })
                $cpuMean = $null; if ($cpuVals.Count -gt 0) { $cpuMean = ($cpuVals | Measure-Object -Property CpuAvg -Average).Average }
                $byVar[$g.Name] = [pscustomobject]@{ Var = $g.Name; Rt = ($good | Measure-Object -Property Realtime -Average).Average; Load = $cpuMean }
            }
        }
        if ($byVar.Count -eq 0) { continue }
        $best = $byVar.Values | Sort-Object Rt -Descending | Select-Object -First 1
        $cpu = $null; if ($byVar.ContainsKey('cpu')) { $cpu = $byVar['cpu'] }
        $target = $rows[0].ScenarioLabel; if ($target -match ' -> (.*)$') { $target = $Matches[1] }
        [void]$aggRows.Add([pscustomobject]@{
            Class = $cls; Clips = $clipCount; Scen = $sk; Target = $target; BestVar = $best.Var; BestRt = $best.Rt; BestLoad = $best.Load
            CpuRt = $(if ($cpu) { $cpu.Rt } else { $null }); CpuLoad = $(if ($cpu) { $cpu.Load } else { $null })
        })
    }
}

# ---- hardware decode support per clip (QSV / NVDEC); AMF decode is not tested
function Get-DecodeEngines($i) {
    $e = @()
    if ($HasIntel) { if ((Test-HwDecode $i).Ok) { $e += 'QSV' } }
    if ($HasNvidia) { if ((Test-NvDecode $i).Ok) { $e += 'NVDEC' } }
    return $e
}

# ---- findings and recommendations
$find = New-Object System.Collections.ArrayList
$wins = @{}
foreach ($a in $aggRows) { if ($a.BestVar -ne 'cpu' -and $EngineOf.ContainsKey($a.BestVar)) { $en = $EngineOf[$a.BestVar]; if (-not $wins.ContainsKey($en)) { $wins[$en] = 0 }; $wins[$en]++ } }
if ($wins.Count -gt 0) {
    $top = ($wins.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    [void]$find.Add("**Best hardware acceleration for this machine: $($top.Key).** It is the fastest path in $($top.Value) of $($aggRows.Count) source/target combinations. In Jellyfin: Dashboard > Playback > Transcoding > Hardware acceleration.")
} elseif ($aggRows.Count -gt 0) {
    [void]$find.Add("**No GPU path beat the CPU on this machine** (or none worked, see the engine table below). Software transcoding is the best option here.")
}
foreach ($cls in @($aggRows | Select-Object -ExpandProperty Class -Unique)) {
    $hdrRows = @($aggRows | Where-Object { $_.Class -eq $cls -and $_.Target -match 'HDR->SDR' })
    if ($hdrRows.Count -eq 0) { continue }
    $hard = $hdrRows | Sort-Object BestRt | Select-Object -First 1
    $cpuTxt = 'n/a'; if ($null -ne $hard.CpuRt) { $cpuTxt = ('{0:N1}x' -f $hard.CpuRt) }
    if ($GpuToneVars -contains $hard.BestVar) {
        [void]$find.Add(("**{0}: GPU tone-mapping works.** Hardest case ({1}) runs at {2:N1}x real time with '{3}' (CPU only: {4})." -f (Get-ClassLabel $cls), $hard.Target, $hard.BestRt, (Get-VarName $hard.BestVar), $cpuTxt))
    } else {
        [void]$find.Add(("**{0}: tone-mapping runs on the CPU and limits capacity.** Hardest case ({1}) reaches {2:N1}x with '{3}' (CPU only: {4}). No working GPU tone-mapping path was faster; see the engine table (OpenCL, libplacebo, tonemap_cuda) for why." -f (Get-ClassLabel $cls), $hard.Target, $hard.BestRt, (Get-VarName $hard.BestVar), $cpuTxt))
    }
}
if ($HasIntel -or $HasNvidia) {
    foreach ($cls in @($infos | Select-Object -ExpandProperty Class -Unique)) {
        $ci = $infos | Where-Object { $_.Class -eq $cls } | Select-Object -First 1
        $de = @(Get-DecodeEngines $ci)
        if ($de.Count -eq 0) { [void]$find.Add(("**No hardware decoder for {0}** on this machine (codec or bit depth not supported by the GPU): the CPU decodes it, which limits how many streams you can run." -f (Get-ClassLabel $cls))) }
    }
}
foreach ($a in ($aggRows | Where-Object { $_.BestRt -lt 1.0 })) {
    [void]$find.Add(("**Too slow: {0} to {1}.** Even the best path ('{2}') reaches only {3:N2}x real time. Viewers will see stuttering: prefer direct play or a pre-transcoded version." -f (Get-ClassLabel $a.Class), $a.Target, (Get-VarName $a.BestVar), $a.BestRt))
}
if ($HasIntel -and -not $script:QsvOk) { [void]$find.Add("**Intel QuickSync is not usable** on this machine: the GPU or driver is not exposing the encoder (check the driver, and that the iGPU is enabled).") }
elseif ($HasIntel -and -not $script:QsvHwOk) { [void]$find.Add("**Intel QuickSync encodes, but the full hardware path (decode + scaling) does not work.** Only the encoder is used, so the CPU still decodes.") }
if ($HasNvidia -and -not $script:NvOk) { [void]$find.Add("**NVIDIA NVENC is not usable:** $NvNote") }
elseif ($HasNvidia -and -not $script:NvHwOk) { [void]$find.Add("**NVIDIA CUDA decode path does not work:** $NvNote") }
if ($HasNvidia -and $script:NvOk -and -not $caps['tonemap_cuda']) { [void]$find.Add("**tonemap_cuda is missing** in this ffmpeg. It exists only in jellyfin-ffmpeg (run tools\get-ffmpeg.ps1); until then NVIDIA HDR tone-mapping can use OpenCL or libplacebo.") }
if ($HasAmd -and -not $script:AmfOk) { [void]$find.Add("**AMD AMF is not usable:** $AmfNote") }
if (-not $script:ClOk -and $aggRows.Count -gt 0 -and @($infos | Where-Object { $_.Tm }).Count -gt 0) { [void]$find.Add("**OpenCL tone-mapping is unavailable** (no OpenCL runtime/device, or ffmpeg lacks tonemap_opencl).") }
if (@($infos | Where-Object { $_.Dv -eq 5 }).Count -gt 0) { [void]$find.Add("Dolby Vision profile 5 clips have no HDR10 fallback layer: they are timed **without** tone-mapping, except in the libplacebo variant (which handles profile 5).") }
if ($find.Count -eq 0) { [void]$find.Add("No findings.") }

# ---- write the report
$md = New-Object System.Collections.ArrayList
[void]$md.Add("# Jellyfin transcode benchmark - $HostName")
[void]$md.Add("")
[void]$md.Add("Run: $($sys.Date) | clips of $ClipSeconds s | timeout $TimeoutSec s per run$(if ($Quick) { ' | quick mode' })$(if ($Anonymize) { ' | clip names anonymised' })")
[void]$md.Add("")
[void]$md.Add("**How to read the numbers:** speeds are *times real time*. 1.0x keeps up with exactly one viewer; 4.0x is roughly four simultaneous transcodes if nothing else is running. Verdict: >= 2.0x comfortable, 1.0-2.0x borderline, < 1.0x too slow.")
[void]$md.Add("")

[void]$md.Add("## Summary")
[void]$md.Add("")
$nComf = @($aggRows | Where-Object { $_.BestRt -ge 2.0 }).Count; $nBord = @($aggRows | Where-Object { $_.BestRt -ge 1.0 -and $_.BestRt -lt 2.0 }).Count; $nSlow = @($aggRows | Where-Object { $_.BestRt -lt 1.0 }).Count
[void]$md.Add("**Bottom line:** $($aggRows.Count) source/target combinations tested: **$nComf comfortable** (2x real time or more), **$nBord borderline** (1-2x), **$nSlow too slow** (below real time).")
[void]$md.Add("")
[void]$md.Add("For each source type and target, the fastest path found on this machine (mean over the clips of that type).")
[void]$md.Add("")
[void]$md.Add("| Source | Target | Verdict | Best path | Speed | CPU only | Gain vs CPU |")
[void]$md.Add("|---|---|---|---|---:|---:|---:|")
foreach ($a in $aggRows) {
    $src = Get-ClassLabel $a.Class; if ($a.Clips -gt 1) { $src += " ($($a.Clips) clips)" }
    $cpuTxt = 'n/a'; $gain = 'n/a'
    if ($null -ne $a.CpuRt) { $cpuTxt = ('{0:N1}x' -f $a.CpuRt); if ($a.BestVar -eq 'cpu') { $gain = 'CPU is best' } elseif ($a.CpuRt -gt 0) { $gain = ('{0:N1}x faster' -f ($a.BestRt / $a.CpuRt)) } }
    [void]$md.Add(("| {0} | {1} | {2} | {3} | {4:N1}x | {5} | {6} |" -f $src, $a.Target, (Get-Verdict $a.BestRt), (Get-VarName $a.BestVar), $a.BestRt, $cpuTxt, $gain))
}
[void]$md.Add("")

[void]$md.Add("## Findings and recommendations")
[void]$md.Add("")
foreach ($f in $find) { [void]$md.Add("- $f") }
[void]$md.Add("")

[void]$md.Add("## Parallel streams")
[void]$md.Add("")
if ($ConcRows.Count -eq 0) { [void]$md.Add("Not run, or no GPU path worked.") } else {
    [void]$md.Add("How many copies of the same transcode run at real time or faster at once (the best non-CPU path of each source type).")
    [void]$md.Add("")
    [void]$md.Add("| Source | Target | Path | Parallel streams at real time | Tested up to |")
    [void]$md.Add("|---|---|---|---:|---:|")
    foreach ($grp in ($ConcRows | Group-Object Class)) {
        $okRows = @($grp.Group | Where-Object { $_.MinRealtime -ge 1.0 })
        $mx = 0; if ($okRows.Count -gt 0) { $mx = ($okRows | Measure-Object -Property Streams -Maximum).Maximum }
        $tested = ($grp.Group | Measure-Object -Property Streams -Maximum).Maximum
        $first = $grp.Group[0]; $tgt = $first.Scenario; if ($tgt -match ' -> (.*)$') { $tgt = $Matches[1] }
        $mxTxt = "$mx"; if ($mx -ge $tested) { $mxTxt = "$mx+ (test ceiling)" }
        [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} |" -f (Get-ClassLabel $grp.Name), $tgt, (Get-VarName $first.Variant), $mxTxt, $tested))
    }
    [void]$md.Add("")
    [void]$md.Add("<details><summary>Parallel-stream measurements</summary>")
    [void]$md.Add("")
    [void]$md.Add("| Source | Path | Streams | Total fps | Slowest stream fps | Slowest x realtime | CPU % | GPU dec/enc/vpp % |")
    [void]$md.Add("|---|---|---:|---:|---:|---:|---:|---|")
    foreach ($c in $ConcRows) {
        [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7:N0}/{8:N0}/{9:N0} |" -f (Get-ClassLabel $c.Class), (Get-VarName $c.Variant), $c.Streams, $c.AggFps, $c.MinFps, $c.MinRealtime, (F $c.CpuAvg '{0:N0}'), $c.GpuDec, $c.GpuEnc, $c.GpuVpp))
    }
    [void]$md.Add("")
    [void]$md.Add("</details>")
}
[void]$md.Add("")

[void]$md.Add("## Your hardware")
[void]$md.Add("")
[void]$md.Add("- **CPU:** $($sys['CPU']) ($($sys['Cores']) cores / $($sys['Threads']) threads), $($sys['RamGB']) GB RAM")
[void]$md.Add("- **GPUs:** $(($gpus | ForEach-Object { '{0} (driver {1})' -f $_.Name, $_.DriverVersion }) -join '; ')")
$pp = "$($sys['PowerPlan'])"; if ($pp -match '\(([^)]+)\)\s*$') { $pp = $Matches[1] }
[void]$md.Add("- **OS:** $($sys['OS']) | **Power plan:** $pp")
[void]$md.Add("- **ffmpeg:** $($sys['Ffmpeg'])")
$idleNote = ''; if ($null -ne $sys['IdleCpuPct'] -and $sys['IdleCpuPct'] -gt 20) { $idleNote = ' (high: other programs were using the CPU, CPU numbers may be pessimistic)' }
[void]$md.Add("- **CPU load before the test:** $($sys['IdleCpuPct']) %$idleNote")
[void]$md.Add("")
[void]$md.Add("| Engine | Status | Details |")
[void]$md.Add("|---|---|---|")
[void]$md.Add("| CPU (libx264) | OK | software transcoding, always available |")
if ($HasIntel) {
    if ($script:QsvHwOk) { [void]$md.Add("| Intel QuickSync | OK, full GPU path | init mode $QMode |") }
    elseif ($script:QsvOk) { [void]$md.Add("| Intel QuickSync | Encode only | the full hardware decode + scaling path did not start |") }
    else { [void]$md.Add("| Intel QuickSync | Not working | encoder did not initialise |") }
} else { [void]$md.Add("| Intel QuickSync | No Intel GPU | |") }
if ($HasNvidia) {
    if ($script:NvOk) { [void]$md.Add(("| NVIDIA NVENC | {0} | encode preset '{1}', scale_cuda {2}, tonemap_cuda {3} |" -f $(if ($script:NvHwOk) { 'OK, full GPU path' } else { 'Encode only' }), $script:NvEnc.Trim(), $caps['scale_cuda'], $caps['tonemap_cuda'])) }
    else { [void]$md.Add("| NVIDIA NVENC | Not working | $NvNote |") }
} else { [void]$md.Add("| NVIDIA NVENC | No NVIDIA GPU | |") }
if ($HasAmd) {
    if ($script:AmfOk) { [void]$md.Add("| AMD AMF | OK, encode | decode is done by the CPU in these tests |") } else { [void]$md.Add("| AMD AMF | Not working | $AmfNote |") }
} else { [void]$md.Add("| AMD AMF | No AMD GPU | |") }
[void]$md.Add("| OpenCL tone-map | $(if ($script:ClOk) { 'OK' } else { 'Not available' }) | $(if ($script:ClOk) { $script:ClDev } elseif (-not $caps['tonemap_opencl']) { 'ffmpeg has no tonemap_opencl' } else { 'no usable OpenCL device' }) |")
[void]$md.Add("| libplacebo (Vulkan) tone-map | $(if ($script:PlOk) { 'OK' } else { 'Not available' }) | $(if ($script:PlOk) { $script:PlDev } elseif (-not $caps['libplacebo']) { 'ffmpeg has no libplacebo' } else { 'no usable Vulkan device' }) |")
[void]$md.Add("| CPU tone-map (zscale) | $(if ($caps['zscale'] -and $caps['tonemap']) { 'OK' } else { 'Not available' }) | used by the CPU and hybrid variants |")
[void]$md.Add("")

[void]$md.Add("## Clips tested")
[void]$md.Add("")
[void]$md.Add("| Clip | Source type | Resolution | fps | Mbps | HDR | Size MB | Hardware decode |")
[void]$md.Add("|---|---|---|---:|---:|---|---:|---|")
foreach ($i in $infos) {
    $de = @(Get-DecodeEngines $i); $deTxt = 'none (CPU)'; if ($de.Count -gt 0) { $deTxt = $de -join ' + ' } elseif (-not ($HasIntel -or $HasNvidia)) { $deTxt = 'not tested' }
    [void]$md.Add(("| {0} | {1} | {2}x{3} | {4:N2} | {5} | {6} | {7} | {8} |" -f (Get-FileLabel $i.File), (Get-ClassLabel $i.Class), $i.Width, $i.Height, $i.Fps, $i.BitrateMbps, $i.HdrType, $i.SizeMB, $deTxt))
}
[void]$md.Add("")

[void]$md.Add("## All paths side by side (x real time, per clip)")
[void]$md.Add("")
$colNames = [ordered]@{ cpu = 'CPU'; hw = 'QSV full GPU'; hyb = 'CPU + QSV enc'; cl = 'OpenCL tone-map'; plc = 'libplacebo'; nv = 'NVIDIA full GPU'; hybn = 'CPU + NVENC'; nvd = 'NVDEC + CPU tone-map'; hyba = 'CPU + AMF' }
$presentVars = @($colNames.Keys | Where-Object { $k = $_; @($script:Results | Where-Object { $_.Variant -eq $k }).Count -gt 0 })
[void]$md.Add("| Clip | Target | " + (($presentVars | ForEach-Object { $colNames[$_] }) -join ' | ') + " | Best |")
[void]$md.Add("|---|---|" + (($presentVars | ForEach-Object { '---:' }) -join '|') + "|---|")
$groups = $script:Results | Group-Object { "{0}|{1}" -f $_.File, $_.Scenario }
foreach ($grp in $groups) {
    $rows = @($grp.Group)
    $cells = @()
    foreach ($v in $presentVars) {
        $r = $rows | Where-Object { $_.Variant -eq $v } | Select-Object -First 1
        if (-not $r) { $cells += '-' }
        elseif ($r.Status -eq 'OK') { $cells += ('{0:N2}x' -f $r.Realtime) }
        elseif ($r.Status -eq 'TIMEOUT') { $cells += ('{0:N2}x*' -f $r.Realtime) }
        else { $cells += $r.Status }
    }
    $bestRow = $rows | Where-Object { $_.Status -eq 'OK' -or $_.Status -eq 'TIMEOUT' } | Sort-Object Realtime -Descending | Select-Object -First 1
    $bt = 'none'; if ($bestRow) { $bt = "{0} ({1:N2}x)" -f $colNames[$bestRow.Variant], $bestRow.Realtime }
    [void]$md.Add(("| {0} | {1} | {2} | {3} |" -f (Get-FileLabel $rows[0].File), $rows[0].ScenarioLabel, ($cells -join ' | '), $bt))
}
[void]$md.Add("")
[void]$md.Add("`*` = the run hit the timeout; the value is partial throughput. `SKIP` / `FAIL`: the reason is in the table below.")
[void]$md.Add("")

[void]$md.Add("## Every run")
[void]$md.Add("")
[void]$md.Add("<details><summary>Show all runs</summary>")
[void]$md.Add("")
[void]$md.Add("| Clip | Target | Path | Status | fps | x realtime | CPU % | GPU dec/enc/vpp % | Note |")
[void]$md.Add("|---|---|---|---|---:|---:|---:|---|---|")
foreach ($r in $script:Results) {
    [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7:N0}/{8:N0}/{9:N0} | {10} |" -f (Get-FileLabel $r.File), $r.ScenarioLabel, (Get-VarName $r.Variant), $r.Status, (F $r.Fps '{0:N1}'), (F $r.Realtime '{0:N2}'), (F $r.CpuAvg '{0:N0}'), $r.GpuDec, $r.GpuEnc, $r.GpuVpp, ($r.Error -replace '\|', '/')))
}
[void]$md.Add("")
[void]$md.Add("</details>")
[void]$md.Add("")

[void]$md.Add("## Notes")
[void]$md.Add("")
[void]$md.Add("- Only the **video** stream is transcoded; audio is ignored. Output is H.264 at 20 / 8 / 4 / 2 Mbps for 4K / 1080p / 720p / SD.")
[void]$md.Add("- HDR sources (HDR10, HLG, Dolby Vision) are tone-mapped to SDR. 'CPU tone-map' uses zscale + hable; the GPU variants use QuickSync VPP, tonemap_cuda, OpenCL or libplacebo.")
[void]$md.Add("- Every run includes process start-up. OpenCL and libplacebo compile their kernels on each start, so they are slightly understated on short clips. The first run of each GPU path is preceded by a 2 s warm-up.")
[void]$md.Add("- GPU dec/enc/vpp % are Windows GPU engine counters summed over all adapters; they read 0 when the counters are unavailable.")
[void]$md.Add("- Raw ffmpeg output of every run is in the logs folder next to this report. It contains the clip file names and paths: delete it before sharing results publicly$(if ($Anonymize) { ' (this report itself uses anonymised clip names)' }).")

$md | Out-File -FilePath (Join-Path $OutDir 'report.md') -Encoding utf8

# ---- machine-readable export (clip names anonymised on request)
$jsonMedia = $infos; $jsonResults = $script:Results; $jsonConc = $ConcRows
if ($Anonymize) {
    $jsonMedia = @($infos | ForEach-Object { $c = $_.PSObject.Copy(); $c.File = (Get-FileLabel $_.File); $c.Path = ''; $c })
    $jsonResults = @($script:Results | ForEach-Object { $c = $_.PSObject.Copy(); $c.File = (Get-FileLabel $_.File); $c.Cmd = ''; $c })
    $jsonConc = @($ConcRows | ForEach-Object { $c = $_.PSObject.Copy(); $c.File = (Get-FileLabel $_.File); $c })
}
[pscustomobject]@{ System = $sys; Capabilities = $caps; QsvOk = $script:QsvOk; QsvHwOk = $script:QsvHwOk; QsvInitMode = $QMode; OpenClOk = $script:ClOk; OpenClDevice = $script:ClDev
    LibplaceboOk = $script:PlOk; NvencOk = $script:NvOk; AmfOk = $script:AmfOk
    Media = $jsonMedia; Results = $jsonResults; Concurrency = $jsonConc; Findings = @($find) } | ConvertTo-Json -Depth 6 | Out-File -FilePath (Join-Path $OutDir 'results.json') -Encoding utf8

if (-not $KeepWork) { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ""
Write-Host "Done. Copy this folder back: $OutDir" -ForegroundColor Green
