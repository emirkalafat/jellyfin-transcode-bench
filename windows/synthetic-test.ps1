<#
.SYNOPSIS
  Synthetic hardware-transcode benchmark: CPU vs Intel QuickSync (QSV) vs NVIDIA (NVENC) vs AMD (AMF). Windows PowerShell 5.1+.

.DESCRIPTION
  Inventories every GPU and probes each hardware path, generates synthetic 1080p test sources, then runs
  decode / encode / transcode / parallel-stream tests on the CPU and on every usable engine.
  Writes report.md and results.json under <repo>\results\synthetic_<host>_<time>\

  ffmpeg.exe is looked up in <repo>\ffmpeg-jellyfin\bin (see tools\get-ffmpeg.ps1), <repo>\ffmpeg-full\bin,
  <repo>\ffmpeg\bin, then in PATH.

.PARAMETER Quick      Short run (10 s sources, fewer concurrency steps).
.PARAMETER Duration   Length of the synthetic 1080p source in seconds (default 30).
.PARAMETER Streams    Concurrency steps for the parallel-stream test.
.PARAMETER TimeoutSec Per-test timeout (default 600).
.PARAMETER KeepWork   Keep the generated source files in %TEMP%.
#>
[CmdletBinding()]
param(
    [string]$FfmpegPath,
    [int]$Duration = 30,
    [string[]]$Streams = @('1', '2', '4', '6', '8'),
    [int]$TimeoutSec = 600,
    [switch]$Quick,
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$Streams = @($Streams | ForEach-Object { $_ -split '[,; ]+' } | Where-Object { $_ } | ForEach-Object { [int]$_ })   # "-Streams 1,2" via -File arrives as one string
if ($Quick) { $Duration = 10; $Streams = @(1, 2, 4) }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir   # repository root: media\, results\, ffmpeg-*\ live here
$Stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$HostName  = $env:COMPUTERNAME
$OutDir    = Join-Path $RootDir ("results\synthetic_{0}_{1}" -f $HostName, $Stamp)
$LogDir    = Join-Path $OutDir 'logs'
$WorkDir   = Join-Path $env:TEMP 'jtb-synthetic-work'
New-Item -ItemType Directory -Force -Path $OutDir, $LogDir, $WorkDir | Out-Null

$script:Results = New-Object System.Collections.ArrayList
$script:QsvOk   = $false   # h264_qsv encoder works with software frames
$script:QsvHwOk = $false   # full hardware path (QSV decode / vpp / encode) works
$script:Src10Ok = $false
$script:QIn     = ''

function Write-Section($t) { Write-Host ""; Write-Host ("=== {0} ===" -f $t) -ForegroundColor Cyan }

# ---------------------------------------------------------------- ffmpeg lookup
function Find-Ffmpeg {
    if ($FfmpegPath -and (Test-Path $FfmpegPath)) { return (Resolve-Path $FfmpegPath).Path }
    foreach ($c in @('ffmpeg-jellyfin\bin\ffmpeg.exe', 'ffmpeg-full\bin\ffmpeg.exe', 'ffmpeg.exe', 'ffmpeg\bin\ffmpeg.exe', 'bin\ffmpeg.exe')) {
        $p = Join-Path $RootDir $c
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$Ffmpeg = Find-Ffmpeg
if (-not $Ffmpeg) {
    Write-Host 'ffmpeg.exe not found.' -ForegroundColor Red
    Write-Host 'Run tools\get-ffmpeg.ps1 (downloads the latest jellyfin-ffmpeg), or put ffmpeg.exe in <repo>\ffmpeg-jellyfin\bin\, or pass -FfmpegPath.'
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
    $null = $p.Handle   # keep the handle so ExitCode/ExitTime stay readable
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
    if ($status -ne 'OK') {
        $errLines = (($txt -split "[\r\n]+") | Where-Object { $_ -and $_ -notmatch '^\s*frame=' } | Select-Object -Last 3) -join ' | '
    }
    $fps = 0.0
    if ($secs -gt 0 -and $frames -gt 0) { $fps = $frames / $secs }
    return [pscustomobject]@{ Status = $status; Frames = $frames; Secs = $secs; Fps = $fps; Error = $errLines }
}

function Add-Row($row) {
    [void]$script:Results.Add($row)
    $cpuS = 'n/a'; if ($null -ne $row.CpuAvg) { $cpuS = '{0:N0}%' -f $row.CpuAvg }
    if ($row.Status -eq 'OK') {
        Write-Host ("  {0,-58} {1,7:N1} fps  {2,6:N2}x  CPU {3,5}  GPU dec/enc/vpp {4:N0}/{5:N0}/{6:N0}%" -f `
            $row.Name, $row.Fps, $row.Realtime, $cpuS, $row.GpuDec, $row.GpuEnc, $row.GpuVpp)
    } else {
        Write-Host ("  {0,-58} {1}  {2}" -f $row.Name, $row.Status, $row.Error) -ForegroundColor Yellow
    }
}

function Invoke-Test {
    param(
        [string]$Group, [string]$Pair, [string]$Mode, [string]$Name, [string]$FfArgs,
        [bool]$NeedsQsv = $false, [bool]$Needs10 = $false, [double]$SrcFps = 30, [bool]$NeedsEnc = $false,
        [bool]$NeedsNv = $false, [bool]$NeedsNvHw = $false, [bool]$NeedsAmf = $false, [bool]$NeedsScaleCuda = $false
    )
    # engines whose GPU is not in this machine produce no rows at all
    if ($Mode -eq 'QSV' -and -not $HasIntel) { return }
    if ($Mode -eq 'NV' -and -not $HasNvidia) { return }
    if ($Mode -eq 'AMF' -and -not $HasAmd) { return }
    $base = [ordered]@{
        Group = $Group; Pair = $Pair; Mode = $Mode; Name = $Name; Status = 'SKIP'; Frames = 0; Seconds = 0.0
        Fps = 0.0; Realtime = 0.0; CpuAvg = $null; GpuDec = 0.0; GpuEnc = 0.0; GpuVpp = 0.0; Error = ''; Cmd = $FfArgs
    }
    if (($NeedsQsv -and -not $script:QsvHwOk) -or ($NeedsEnc -and -not $script:QsvOk) -or ($Needs10 -and -not $script:Src10Ok) -or
        ($NeedsNv -and -not $script:NvOk) -or ($NeedsNvHw -and -not $script:NvHwOk) -or ($NeedsAmf -and -not $script:AmfOk) -or ($NeedsScaleCuda -and -not $NvScale)) {
        $base.Error = 'prerequisite missing (hardware path not working or no 10-bit source)'
        Add-Row ([pscustomobject]$base); return
    }
    $tag = '{0:D2}_{1}' -f $script:Results.Count, ($Name -replace '[^A-Za-z0-9]+', '_')
    $job = Start-Ff $FfArgs $tag
    $mon = Wait-Ff @($job) $TimeoutSec
    $r = Get-JobResult $job $mon.TimedOut
    $base.Status = $r.Status; $base.Frames = $r.Frames; $base.Seconds = [math]::Round($r.Secs, 2)
    $base.Fps = [math]::Round($r.Fps, 2); $base.Realtime = [math]::Round($r.Fps / $SrcFps, 2)
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
$plan    = ''
try { $plan = ((powercfg /getactivescheme) -join ' ').Trim() } catch { }
$bg = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'Docker|vmmem|vmwp|com\.docker|wsl' } |
    Select-Object -ExpandProperty ProcessName -Unique)

$idle = New-Object 'System.Collections.Generic.List[double]'
1..5 | ForEach-Object {
    try { $idle.Add([double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime) } catch { }
    Start-Sleep -Milliseconds 800
}
$idleAvg = $null; if ($idle.Count -gt 0) { $idleAvg = [math]::Round(($idle | Measure-Object -Average).Average, 1) }

# Who is using the CPU while the machine should be idle? (3 s window)
$topProcs = @()
try {
    $p0 = @{}; Get-Process -ErrorAction SilentlyContinue | ForEach-Object { if ($null -ne $_.CPU) { $p0["$($_.Id)"] = $_.CPU } }
    Start-Sleep -Seconds 3
    $topProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $null -ne $_.CPU -and $p0.ContainsKey("$($_.Id)") } |
        ForEach-Object { [pscustomobject]@{ Name = $_.ProcessName; Pct = [math]::Round((($_.CPU - $p0["$($_.Id)"]) / 3) * 100 / [Environment]::ProcessorCount, 1) } } |
        Sort-Object Pct -Descending | Select-Object -First 5 | ForEach-Object { "{0} {1}%" -f $_.Name, $_.Pct })
} catch { }
if ($idleAvg -gt 20) { Write-Host ("  WARNING: CPU is {0}% busy before the tests start; CPU results will be skewed. Close background apps." -f $idleAvg) -ForegroundColor Yellow }

$verText = (Invoke-FfText '-hide_banner -version' 'sys_version').Text
$ffVer = ($verText -split "[\r\n]+" | Select-Object -First 1)

$sys = [ordered]@{
    Host        = $HostName
    Date        = (Get-Date).ToString('s')
    OS          = "{0} (build {1})" -f $os.Caption, $os.BuildNumber
    CPU         = $cpuInfo.Name.Trim()
    Cores       = $cpuInfo.NumberOfCores
    Threads     = $cpuInfo.NumberOfLogicalProcessors
    MaxClockMHz = $cpuInfo.MaxClockSpeed
    RamGB       = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    GPUs        = @($gpus | ForEach-Object { "{0} (driver {1})" -f $_.Name, $_.DriverVersion })
    PowerPlan   = $plan
    IdleCpuPct  = $idleAvg
    TopIdleCpuProcs = $topProcs
    BackgroundProcs = $bg
    Ffmpeg      = $ffVer
}
$sys.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-16} {1}" -f $_.Key, ($_.Value -join '; ')) }

# ---------------------------------------------------------------- capabilities
Write-Section 'ffmpeg capabilities'
$encs = (Invoke-FfText '-hide_banner -encoders' 'sys_encoders').Text
$decs = (Invoke-FfText '-hide_banner -decoders' 'sys_decoders').Text
$caps = [ordered]@{}
foreach ($n in 'libx264', 'libx265', 'h264_qsv', 'hevc_qsv', 'av1_qsv', 'vp9_qsv', 'mjpeg_qsv') {
    $caps["enc_$n"] = [bool]($encs -match ("(?m)^\s*V\S*\s+{0}\s" -f $n))
}
foreach ($n in 'h264_qsv', 'hevc_qsv', 'av1_qsv', 'vp9_qsv') {
    $caps["dec_$n"] = [bool]($decs -match ("(?m)^\s*V\S*\s+{0}\s" -f $n))
}
$caps.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-16} {1}" -f $_.Key, $_.Value) }

if (-not $caps['enc_libx264']) {
    Write-Host 'This ffmpeg build has no libx264; cannot generate sources. Use a gyan.dev build.' -ForegroundColor Red
    exit 1
}

$qsvProbe = Invoke-FfText '-hide_banner -nostdin -y -f lavfi -i testsrc2=size=1280x720:rate=30 -t 1 -c:v h264_qsv -f null -' 'sys_qsv_probe'
$script:QsvOk = ($qsvProbe.Code -eq 0)
$qsvLine = ($qsvProbe.Text -split "[\r\n]+" | Where-Object { $_ -and $_ -notmatch '^\s*frame=' } | Select-Object -Last 3) -join ' | '
if ($script:QsvOk) {
    Write-Host '  QSV H.264 encode probe: OK' -ForegroundColor Green
} else {
    Write-Host '  QSV H.264 encode probe: FAILED -> QSV tests will be skipped' -ForegroundColor Red
    Write-Host "  $qsvLine"
    Write-Host '  Check: iGPU enabled in BIOS, Intel graphics driver installed, a monitor/dummy plug if the iGPU is disabled.'
}

# ---------------------------------------------------------------- source generation
Write-Section 'Generating test sources (CPU, may take a while)'
$Common = '-hide_banner -nostdin -y -stats'
$Src264 = Join-Path $WorkDir 'src_h264_1080p.mp4'
$Src10  = Join-Path $WorkDir 'src_hevc10_1080p.mkv'
$Dur10  = [math]::Max(5, [int]($Duration / 2))

$g1 = Invoke-FfText ("$Common -f lavfi -i `"testsrc2=size=1920x1080:rate=30,noise=alls=12:allf=t`" -t $Duration -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p `"$Src264`"") 'gen_h264'
if ($g1.Code -ne 0 -or -not (Test-Path $Src264)) { Write-Host 'Failed to generate H.264 source.' -ForegroundColor Red; Write-Host $g1.Text; exit 1 }
Write-Host ("  H.264 1080p30 {0}s -> {1:N1} MB" -f $Duration, ((Get-Item $Src264).Length / 1MB))

if ($caps['enc_libx265']) {
    $g2 = Invoke-FfText ("$Common -f lavfi -i `"testsrc2=size=1920x1080:rate=30,noise=alls=12:allf=t,format=yuv420p10le`" -t $Dur10 -c:v libx265 -preset ultrafast -crf 20 -pix_fmt yuv420p10le -x265-params log-level=error `"$Src10`"") 'gen_hevc10'
    if ($g2.Code -eq 0 -and (Test-Path $Src10)) {
        $script:Src10Ok = $true
        Write-Host ("  HEVC 10-bit 1080p30 {0}s -> {1:N1} MB" -f $Dur10, ((Get-Item $Src10).Length / 1MB))
    } else { Write-Host '  HEVC 10-bit source could not be generated; 10-bit tests will be skipped.' -ForegroundColor Yellow }
}

# Find a hardware-device init that works (older iGPUs like Haswell often need a DXVA2/D3D9 child device
# instead of the D3D11 one ffmpeg picks by default).
Write-Section 'Probing QSV hardware path (decode + encode on GPU)'
$QCands = @(
    [pscustomobject]@{ Name = 'dxva2';   Init = '-init_hw_device qsv=hw:hw_any,child_device_type=dxva2';   Dev = '-hwaccel_device hw' },
    [pscustomobject]@{ Name = 'd3d11va'; Init = '-init_hw_device qsv=hw:hw_any,child_device_type=d3d11va'; Dev = '-hwaccel_device hw' },
    [pscustomobject]@{ Name = 'dxva2-hw'; Init = '-init_hw_device qsv=hw:hw,child_device_type=dxva2';      Dev = '-hwaccel_device hw' },
    [pscustomobject]@{ Name = 'default'; Init = '';                                                          Dev = '' }
)
$QProbeLog = @()
$QMode = 'none'
if ($script:QsvOk) {
    foreach ($c in $QCands) {
        $cand = ("{0} -hwaccel qsv {1} -hwaccel_output_format qsv" -f $c.Init, $c.Dev).Trim()
        $pr = Invoke-FfText ("$Common $cand -c:v h264_qsv -i `"$Src264`" -t 1 -c:v h264_qsv -f null -") ("sys_qsv_hw_" + $c.Name)
        $why = ($pr.Text -split "[\r\n]+" | Where-Object { $_ -and $_ -match 'rror|fail|No device' } | Select-Object -First 2) -join ' | '
        if ($pr.Code -eq 0) {
            Write-Host ("  [{0}] OK" -f $c.Name) -ForegroundColor Green
            $QProbeLog += ("{0}: OK" -f $c.Name)
            $script:QsvHwOk = $true; $script:QIn = $cand; $QMode = $c.Name
            break
        }
        Write-Host ("  [{0}] failed: {1}" -f $c.Name, $why) -ForegroundColor Yellow
        $QProbeLog += ("{0}: FAIL {1}" -f $c.Name, $why)
    }
}
if (-not $script:QsvHwOk) {
    Write-Host '  QSV hardware decode/vpp path unavailable. Encode-only (software decode + QSV encode) tests will still run.' -ForegroundColor Yellow
    $script:QIn = '-hwaccel qsv -hwaccel_output_format qsv'
}
$QIn = $script:QIn

# ---------------------------------------------------------------- GPU inventory, NVIDIA and AMD probes
Write-Section 'GPU inventory and NVIDIA / AMD probes'
$HasIntel = $false; $HasNvidia = $false; $HasAmd = $false
foreach ($gp in $gpus) {
    $ven = 'other'
    if ($gp.PNPDeviceID -match 'VEN_8086') { $ven = 'intel'; $HasIntel = $true }
    elseif ($gp.PNPDeviceID -match 'VEN_10DE') { $ven = 'nvidia'; $HasNvidia = $true }
    elseif ($gp.PNPDeviceID -match 'VEN_1002') { $ven = 'amd'; $HasAmd = $true }
    Write-Host ("  {0,-7} {1} (driver {2})" -f $ven, $gp.Name, $gp.DriverVersion)
}
function Has-Enc([string]$name) { return [bool]($encs -match ("(?m)^\s*V\S*\s+{0}\s" -f $name)) }
$fils = (Invoke-FfText '-hide_banner -filters' 'sys_filters').Text
$NvScale = [bool]($fils -match '(?m)^\s*\S+\s+scale_cuda\s')
$script:NvOk = $false; $script:NvHwOk = $false; $script:NvEnc = ''; $NvNote = ''
$script:AmfOk = $false; $AmfNote = ''
if ($HasNvidia) {
    if (-not (Has-Enc 'h264_nvenc')) { $NvNote = 'h264_nvenc is not in this ffmpeg build' }
    else {
        foreach ($opt in '-preset p4', '-preset medium', '') {
            $r = Invoke-FfText ("$Common -f lavfi -i testsrc2=size=1280x720:rate=30 -t 1 -c:v h264_nvenc -b:v 4M $opt -f null -") 'sys_nvenc_probe'
            if ($r.Code -eq 0) { $script:NvOk = $true; $script:NvEnc = $opt; break }
        }
        if (-not $script:NvOk) { $NvNote = 'NVENC init failed (see logs\sys_nvenc_probe.err.txt)' }
        else {
            $nvvf = ''; if ($NvScale) { $nvvf = '-vf scale_cuda=w=640:h=360:format=nv12' }
            $r = Invoke-FfText ("$Common -hwaccel cuda -hwaccel_output_format cuda -i `"$Src264`" -t 1 $nvvf -c:v h264_nvenc -b:v 4M $($script:NvEnc) -f null -") 'sys_nvenc_hw_probe'
            $script:NvHwOk = ($r.Code -eq 0)
            if (-not $script:NvHwOk) { $NvNote = 'CUDA decode path failed (see logs\sys_nvenc_hw_probe.err.txt)' }
        }
    }
    Write-Host ("  NVENC encode: {0}   full CUDA path: {1}   scale_cuda: {2}   {3}" -f $(if ($script:NvOk) { "OK ($($script:NvEnc))" } else { 'FAILED' }), $(if ($script:NvHwOk) { 'OK' } else { 'not available' }), $NvScale, $NvNote)
} else { Write-Host '  NVENC: skipped (no NVIDIA GPU)' }
if ($HasAmd) {
    if (-not (Has-Enc 'h264_amf')) { $AmfNote = 'h264_amf is not in this ffmpeg build' }
    else {
        $r = Invoke-FfText ("$Common -f lavfi -i testsrc2=size=1280x720:rate=30 -t 1 -c:v h264_amf -b:v 4M -f null -") 'sys_amf_probe'
        $script:AmfOk = ($r.Code -eq 0)
        if (-not $script:AmfOk) { $AmfNote = 'AMF init failed (see logs\sys_amf_probe.err.txt)' }
    }
    Write-Host ("  AMF encode: {0}   {1}" -f $(if ($script:AmfOk) { 'OK' } else { 'FAILED' }), $AmfNote)
} else { Write-Host '  AMF: skipped (no AMD GPU)' }
$NvE = "$($script:NvEnc)"

# ---------------------------------------------------------------- tests
Write-Section 'Decode (1080p30 -> null)'
Invoke-Test 'Decode' 'dec264' 'SW'  'H.264 1080p decode | CPU'  "$Common -i `"$Src264`" -f null -"
Invoke-Test 'Decode' 'dec264' 'QSV' 'H.264 1080p decode | QSV'  "$Common $QIn -c:v h264_qsv -i `"$Src264`" -f null -" -NeedsQsv $true
Invoke-Test 'Decode' 'dec264' 'NV'  'H.264 1080p decode | NVDEC' "$Common -hwaccel cuda -hwaccel_output_format cuda -i `"$Src264`" -f null -" -NeedsNvHw $true
Invoke-Test 'Decode' 'dec10'  'SW'  'HEVC 10-bit 1080p decode | CPU' "$Common -i `"$Src10`" -f null -" -Needs10 $true
Invoke-Test 'Decode' 'dec10'  'QSV' 'HEVC 10-bit 1080p decode | QSV' "$Common $QIn -c:v hevc_qsv -i `"$Src10`" -f null -" -NeedsQsv $true -Needs10 $true
Invoke-Test 'Decode' 'dec10'  'NV'  'HEVC 10-bit 1080p decode | NVDEC' "$Common -hwaccel cuda -hwaccel_output_format cuda -i `"$Src10`" -f null -" -NeedsNvHw $true -Needs10 $true

Write-Section 'Encode (1080p30)'
Invoke-Test 'Encode' 'enc264' 'SW'  'H.264 8M | libx264 medium'         "$Common -i `"$Src264`" -c:v libx264 -preset medium -b:v 8M -f null -"
Invoke-Test 'Encode' 'enc264' 'QSV' 'H.264 8M | h264_qsv medium (full HW)' "$Common $QIn -c:v h264_qsv -i `"$Src264`" -c:v h264_qsv -preset medium -b:v 8M -f null -" -NeedsQsv $true
Invoke-Test 'Encode' 'enc264' 'NV' 'H.264 8M | h264_nvenc (full HW)' "$Common -hwaccel cuda -hwaccel_output_format cuda -i `"$Src264`" -c:v h264_nvenc $NvE -b:v 8M -f null -" -NeedsNvHw $true
Invoke-Test 'Encode' 'enc264h' 'QSV' 'H.264 8M, CPU decode | h264_qsv medium (hybrid)' "$Common -i `"$Src264`" -c:v h264_qsv -preset medium -b:v 8M -f null -" -NeedsEnc $true
Invoke-Test 'Encode' 'enc264h' 'NV' 'H.264 8M, CPU decode | h264_nvenc (hybrid)' "$Common -i `"$Src264`" -c:v h264_nvenc $NvE -b:v 8M -f null -" -NeedsNv $true
Invoke-Test 'Encode' 'enc264h' 'AMF' 'H.264 8M, CPU decode | h264_amf (hybrid)' "$Common -i `"$Src264`" -c:v h264_amf -b:v 8M -f null -" -NeedsAmf $true
Invoke-Test 'Encode' 'enc264q' 'NV' 'H.264 8M | h264_nvenc p7 (best quality)' "$Common -hwaccel cuda -hwaccel_output_format cuda -i `"$Src264`" -c:v h264_nvenc -preset p7 -b:v 8M -f null -" -NeedsNvHw $true
Invoke-Test 'Encode' 'enc264q' 'QSV' 'H.264 8M | h264_qsv veryslow (best quality)' "$Common $QIn -c:v h264_qsv -i `"$Src264`" -c:v h264_qsv -preset veryslow -b:v 8M -f null -" -NeedsQsv $true
if ($caps['enc_libx265']) {
    Invoke-Test 'Encode' 'enc265' 'SW' 'HEVC 6M | libx265 fast' "$Common -i `"$Src264`" -c:v libx265 -preset fast -b:v 6M -x265-params log-level=error -f null -"
}
Invoke-Test 'Encode' 'enc265' 'QSV' 'HEVC 6M | hevc_qsv medium (full HW)' "$Common $QIn -c:v h264_qsv -i `"$Src264`" -c:v hevc_qsv -preset medium -b:v 6M -f null -" -NeedsQsv $true
Invoke-Test 'Encode' 'enc265' 'NV' 'HEVC 6M | hevc_nvenc (full HW)' "$Common -hwaccel cuda -hwaccel_output_format cuda -i `"$Src264`" -c:v hevc_nvenc $NvE -b:v 6M -f null -" -NeedsNvHw $true
Invoke-Test 'Encode' 'enc265' 'AMF' 'HEVC 6M | hevc_amf (CPU decode)' "$Common -i `"$Src264`" -c:v hevc_amf -b:v 6M -f null -" -NeedsAmf $true
if ($caps['enc_libx265']) {
    Invoke-Test 'Encode' 'enc10' 'SW' 'HEVC 10-bit 6M | libx265 fast' "$Common -i `"$Src10`" -c:v libx265 -preset fast -pix_fmt yuv420p10le -b:v 6M -x265-params log-level=error -f null -" -Needs10 $true
}
Invoke-Test 'Encode' 'enc10' 'QSV' 'HEVC 10-bit 6M | hevc_qsv main10 (full HW)' "$Common $QIn -c:v hevc_qsv -i `"$Src10`" -c:v hevc_qsv -profile:v main10 -preset medium -b:v 6M -f null -" -NeedsQsv $true -Needs10 $true
Invoke-Test 'Encode' 'enc10' 'NV' 'HEVC 10-bit 6M | hevc_nvenc main10 (full HW)' "$Common -hwaccel cuda -hwaccel_output_format cuda -i `"$Src10`" -c:v hevc_nvenc -profile:v main10 $NvE -b:v 6M -f null -" -NeedsNvHw $true -Needs10 $true
Invoke-Test 'Encode' 'enc10' 'AMF' 'HEVC 10-bit 6M | hevc_amf main10 (CPU decode)' "$Common -i `"$Src10`" -vf format=p010le -c:v hevc_amf -profile:v main10 -b:v 6M -f null -" -NeedsAmf $true -Needs10 $true

Write-Section 'Transcode (media-server style)'
Invoke-Test 'Transcode' 'tc720' 'SW'  '1080p -> 720p H.264 4M | CPU (scale+libx264 veryfast)' "$Common -i `"$Src264`" -vf scale=1280:720 -c:v libx264 -preset veryfast -b:v 4M -f null -"
Invoke-Test 'Transcode' 'tc720' 'QSV' '1080p -> 720p H.264 4M | QSV (vpp_qsv+h264_qsv)' "$Common $QIn -c:v h264_qsv -i `"$Src264`" -vf vpp_qsv=w=1280:h=720 -c:v h264_qsv -preset veryfast -b:v 4M -f null -" -NeedsQsv $true
Invoke-Test 'Transcode' 'tc720' 'NV' '1080p -> 720p H.264 4M | NVIDIA (scale_cuda+h264_nvenc)' "$Common -hwaccel cuda -hwaccel_output_format cuda -i `"$Src264`" -vf scale_cuda=w=1280:h=720:format=nv12 -c:v h264_nvenc $NvE -b:v 4M -f null -" -NeedsNvHw $true -NeedsScaleCuda $true
Invoke-Test 'Transcode' 'tc720h' 'QSV' '1080p -> 720p H.264 4M, CPU decode+scale | h264_qsv (hybrid)' "$Common -i `"$Src264`" -vf scale=1280:720 -c:v h264_qsv -preset veryfast -b:v 4M -f null -" -NeedsEnc $true
Invoke-Test 'Transcode' 'tc720h' 'NV' '1080p -> 720p H.264 4M, CPU decode+scale | h264_nvenc (hybrid)' "$Common -i `"$Src264`" -vf scale=1280:720 -c:v h264_nvenc $NvE -b:v 4M -f null -" -NeedsNv $true
Invoke-Test 'Transcode' 'tc720h' 'AMF' '1080p -> 720p H.264 4M, CPU decode+scale | h264_amf (hybrid)' "$Common -i `"$Src264`" -vf scale=1280:720 -c:v h264_amf -b:v 4M -f null -" -NeedsAmf $true
Invoke-Test 'Transcode' 'tc10to8' 'SW'  'HEVC 10-bit -> H.264 8-bit 8M | CPU' "$Common -i `"$Src10`" -pix_fmt yuv420p -c:v libx264 -preset veryfast -b:v 8M -f null -" -Needs10 $true
Invoke-Test 'Transcode' 'tc10to8' 'QSV' 'HEVC 10-bit -> H.264 8-bit 8M | QSV' "$Common $QIn -c:v hevc_qsv -i `"$Src10`" -vf vpp_qsv=format=nv12 -c:v h264_qsv -preset veryfast -b:v 8M -f null -" -NeedsQsv $true -Needs10 $true
Invoke-Test 'Transcode' 'tc10to8' 'NV' 'HEVC 10-bit -> H.264 8-bit 8M | NVIDIA' "$Common -hwaccel cuda -hwaccel_output_format cuda -i `"$Src10`" -vf scale_cuda=format=nv12 -c:v h264_nvenc $NvE -b:v 8M -f null -" -NeedsNvHw $true -NeedsScaleCuda $true -Needs10 $true
Invoke-Test 'Transcode' 'tc10to8' 'AMF' 'HEVC 10-bit -> H.264 8-bit 8M | AMF (CPU decode)' "$Common -i `"$Src10`" -pix_fmt nv12 -c:v h264_amf -b:v 8M -f null -" -NeedsAmf $true -Needs10 $true

Write-Section 'Concurrent 1080p -> 720p transcodes per engine, stops when a stream drops below real time'
$ConcRows = New-Object System.Collections.ArrayList
function Invoke-Conc([string]$Engine, [string]$ConcArgs) {
    foreach ($n in $Streams) {
        $jobs = @()
        for ($i = 1; $i -le $n; $i++) { $jobs += Start-Ff $ConcArgs ("conc_{0}_{1:D2}_s{2:D2}" -f ($Engine -replace '[^A-Za-z0-9]+', '_'), $n, $i) }
        $mon = Wait-Ff $jobs ([math]::Max($TimeoutSec, 900))
        $res = @($jobs | ForEach-Object { Get-JobResult $_ $mon.TimedOut })
        $ok  = @($res | Where-Object { $_.Status -eq 'OK' })
        if ($ok.Count -eq 0) {
            Write-Host ("  {0}: {1} streams: FAIL  {2}" -f $Engine, $n, $res[0].Error) -ForegroundColor Yellow
            [void]$ConcRows.Add([pscustomobject]@{ Engine = $Engine; Streams = $n; Status = 'FAIL'; AggFps = 0; MinFps = 0; MinRealtime = 0; CpuAvg = $mon.CpuAvg; GpuEnc = $mon.Gpu.VideoEncode; GpuDec = $mon.Gpu.VideoDecode; GpuVpp = $mon.Gpu.VideoProcessing; Error = $res[0].Error })
            break
        }
        $agg = ($ok | Measure-Object -Property Fps -Sum).Sum
        $min = ($ok | Measure-Object -Property Fps -Minimum).Minimum
        $minRt = $min / 30
        $cpuS = 'n/a'; if ($null -ne $mon.CpuAvg) { $cpuS = '{0:N0}%' -f $mon.CpuAvg }
        Write-Host ("  {0,-14} {1,2} streams: aggregate {2,7:N1} fps | slowest stream {3,6:N1} fps = {4,5:N2}x realtime | CPU {5,5} | GPU dec/enc/vpp {6:N0}/{7:N0}/{8:N0}%" -f `
            $Engine, $n, $agg, $min, $minRt, $cpuS, $mon.Gpu.VideoDecode, $mon.Gpu.VideoEncode, $mon.Gpu.VideoProcessing)
        [void]$ConcRows.Add([pscustomobject]@{
            Engine = $Engine; Streams = $n; Status = 'OK'; AggFps = [math]::Round($agg, 1); MinFps = [math]::Round($min, 1); MinRealtime = [math]::Round($minRt, 2)
            CpuAvg = $(if ($null -ne $mon.CpuAvg) { [math]::Round($mon.CpuAvg, 1) } else { $null })
            GpuEnc = [math]::Round($mon.Gpu.VideoEncode, 1); GpuDec = [math]::Round($mon.Gpu.VideoDecode, 1); GpuVpp = [math]::Round($mon.Gpu.VideoProcessing, 1); Error = ''
        })
        if ($minRt -lt 1.0) { Write-Host '  -> slowest stream fell below real time, stopping.'; break }
    }
}
$ConcPath = ''
if ($HasIntel) {
    if ($script:QsvOk) {
        if ($script:QsvHwOk) { $ConcPath += 'QSV full-hw; '; Invoke-Conc 'QSV' "$Common $QIn -c:v h264_qsv -i `"$Src264`" -vf vpp_qsv=w=1280:h=720 -c:v h264_qsv -preset veryfast -b:v 4M -f null -" }
        else { $ConcPath += 'QSV hybrid; '; Write-Host '  QSV: using hybrid path (CPU decode+scale, QSV encode)' -ForegroundColor Yellow
            Invoke-Conc 'QSV (hybrid)' "$Common -i `"$Src264`" -vf scale=1280:720 -c:v h264_qsv -preset veryfast -b:v 4M -f null -" }
    } else { Write-Host '  QSV skipped (not working)' -ForegroundColor Yellow }
}
if ($HasNvidia) {
    if ($script:NvHwOk -and $NvScale) { $ConcPath += 'NVENC full-hw; '; Invoke-Conc 'NVENC' "$Common -hwaccel cuda -hwaccel_output_format cuda -i `"$Src264`" -vf scale_cuda=w=1280:h=720:format=nv12 -c:v h264_nvenc $NvE -b:v 4M -f null -" }
    elseif ($script:NvOk) { $ConcPath += 'NVENC hybrid; '; Write-Host '  NVENC: using hybrid path (CPU decode+scale, NVENC encode)' -ForegroundColor Yellow
        Invoke-Conc 'NVENC (hybrid)' "$Common -i `"$Src264`" -vf scale=1280:720 -c:v h264_nvenc $NvE -b:v 4M -f null -" }
    else { Write-Host '  NVENC skipped (not working)' -ForegroundColor Yellow }
}
if ($HasAmd) {
    if ($script:AmfOk) { $ConcPath += 'AMF hybrid; '; Invoke-Conc 'AMF (hybrid)' "$Common -i `"$Src264`" -vf scale=1280:720 -c:v h264_amf -b:v 4M -f null -" }
    else { Write-Host '  AMF skipped (not working)' -ForegroundColor Yellow }
}

# ---------------------------------------------------------------- report
Write-Section 'Writing report'
function F($v, $fmt) { if ($null -eq $v) { return 'n/a' } else { return ($fmt -f $v) } }

$md = New-Object System.Collections.ArrayList
[void]$md.Add("# Jellyfin transcode benchmark (synthetic sources) - $HostName")
[void]$md.Add("")
[void]$md.Add("Run: $($sys.Date) | Duration param: ${Duration}s | Quick: $($Quick.IsPresent)")
[void]$md.Add("")
[void]$md.Add("## System")
[void]$md.Add("")
foreach ($kv in $sys.GetEnumerator()) { [void]$md.Add(("- **{0}:** {1}" -f $kv.Key, ($kv.Value -join '; '))) }
[void]$md.Add("")
[void]$md.Add("## ffmpeg capabilities")
[void]$md.Add("")
[void]$md.Add(($caps.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join ', ')
[void]$md.Add("")
[void]$md.Add("QSV encode probe (software frames): " + $(if ($script:QsvOk) { 'OK' } else { "FAILED - $qsvLine" }))
[void]$md.Add("")
[void]$md.Add("QSV hardware path: " + $(if ($script:QsvHwOk) { "OK (init mode: $QMode)" } else { 'FAILED' }))
foreach ($l in $QProbeLog) { [void]$md.Add("- $l") }
[void]$md.Add("")
[void]$md.Add("## GPUs and engines")
[void]$md.Add("")
foreach ($gp in $gpus) { [void]$md.Add("- $($gp.Name) (driver $($gp.DriverVersion))") }
[void]$md.Add("- NVENC: " + $(if ($HasNvidia) { $(if ($script:NvOk) { "encode OK ($($script:NvEnc)), full CUDA path " + $(if ($script:NvHwOk) { 'OK' } else { 'not available' }) + ", scale_cuda $NvScale" } else { "FAILED $NvNote" }) } else { 'no NVIDIA GPU' }))
[void]$md.Add("- AMF: " + $(if ($HasAmd) { $(if ($script:AmfOk) { 'encode OK' } else { "FAILED $AmfNote" }) } else { 'no AMD GPU' }))
[void]$md.Add("")
[void]$md.Add("## CPU vs hardware summary (fps and speedup vs CPU)")
[void]$md.Add("")
$modeNames = [ordered]@{ QSV = 'QSV'; NV = 'NVIDIA'; AMF = 'AMD AMF' }
$presentModes = @($modeNames.Keys | Where-Object { $m = $_; @($script:Results | Where-Object { $_.Mode -eq $m }).Count -gt 0 })
[void]$md.Add("| Test | CPU fps | CPU load | " + (($presentModes | ForEach-Object { $modeNames[$_] }) -join ' | ') + " |")
[void]$md.Add("|---|---:|---:|" + (($presentModes | ForEach-Object { '---:' }) -join '|') + "|")
foreach ($pair in ($script:Results | Select-Object -ExpandProperty Pair -Unique)) {
    $swPair = $pair -replace '[qh]$', ''
    $sw  = $script:Results | Where-Object { $_.Pair -eq $swPair -and $_.Mode -eq 'SW' } | Select-Object -First 1
    $hwRows = @($script:Results | Where-Object { $_.Pair -eq $pair -and $_.Mode -ne 'SW' })
    if ($hwRows.Count -eq 0) { continue }
    $label = ($hwRows[0].Name -split '\|')[0].Trim()
    if ($pair -match 'q$') { $label += ' (best quality)' }
    $swF = 'n/a'; $swC = 'n/a'
    if ($sw -and $sw.Status -eq 'OK') { $swF = F $sw.Fps '{0:N1}'; $swC = (F $sw.CpuAvg '{0:N0}') + '%' }
    $cells = @()
    foreach ($m in $presentModes) {
        $r = $hwRows | Where-Object { $_.Mode -eq $m } | Select-Object -First 1
        if (-not $r) { $cells += '-' }
        elseif ($r.Status -ne 'OK') { $cells += $r.Status }
        elseif ($sw -and $sw.Status -eq 'OK' -and $sw.Fps -gt 0) { $cells += ('{0:N1} ({1:N1}x)' -f $r.Fps, ($r.Fps / $sw.Fps)) }
        else { $cells += ('{0:N1}' -f $r.Fps) }
    }
    [void]$md.Add("| $label | $swF | $swC | " + ($cells -join ' | ') + " |")
}
[void]$md.Add("")
[void]$md.Add("## All results")
[void]$md.Add("")
[void]$md.Add("| Group | Test | Status | fps | x realtime | CPU % | GPU dec/enc/vpp % | Note |")
[void]$md.Add("|---|---|---|---:|---:|---:|---|---|")
foreach ($r in $script:Results) {
    [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6:N0}/{7:N0}/{8:N0} | {9} |" -f $r.Group, $r.Name, $r.Status, (F $r.Fps '{0:N1}'), (F $r.Realtime '{0:N2}'), (F $r.CpuAvg '{0:N0}'), $r.GpuDec, $r.GpuEnc, $r.GpuVpp, ($r.Error -replace '\|', '/')))
}
[void]$md.Add("")
[void]$md.Add("## Concurrent 1080p30 -> 720p transcodes (H.264 4M) - paths: $ConcPath")
[void]$md.Add("")
[void]$md.Add("| Engine | Streams | Status | Aggregate fps | Slowest stream fps | Slowest x realtime | CPU % | GPU dec/enc/vpp % |")
[void]$md.Add("|---|---:|---|---:|---:|---:|---:|---|")
foreach ($c in $ConcRows) {
    [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7:N0}/{8:N0}/{9:N0} |" -f $c.Engine, $c.Streams, $c.Status, $c.AggFps, $c.MinFps, $c.MinRealtime, (F $c.CpuAvg '{0:N0}'), $c.GpuDec, $c.GpuEnc, $c.GpuVpp))
}
[void]$md.Add("")
foreach ($grp in ($ConcRows | Group-Object Engine)) {
    $okRows = @($grp.Group | Where-Object { $_.Status -eq 'OK' -and $_.MinRealtime -ge 1.0 })
    $mx = 0; if ($okRows.Count -gt 0) { $mx = ($okRows | Measure-Object -Property Streams -Maximum).Maximum }
    [void]$md.Add("Max tested concurrent 1080p->720p streams at >= real time ($($grp.Name)): **$mx**")
    [void]$md.Add("")
}
[void]$md.Add("")
[void]$md.Add("Notes: sources are synthetic (testsrc2 + noise). 'x realtime' = fps / 30. GPU % is the peak of Windows GPU Engine counters (Video Decode / Video Encode / Video Processing) and may read 0 if counters are unavailable. Raw ffmpeg logs are in the logs folder.")

$md | Out-File -FilePath (Join-Path $OutDir 'report.md') -Encoding utf8
[pscustomobject]@{ System = $sys; Capabilities = $caps; QsvProbeOk = $script:QsvOk; QsvHwOk = $script:QsvHwOk; QsvInitMode = $QMode; QsvProbeLog = $QProbeLog; Results = $script:Results; Concurrency = $ConcRows } |
    ConvertTo-Json -Depth 6 | Out-File -FilePath (Join-Path $OutDir 'results.json') -Encoding utf8

if (-not $KeepWork) { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "Done. Copy this folder back: $OutDir" -ForegroundColor Green
