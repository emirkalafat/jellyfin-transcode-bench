<#
.SYNOPSIS
  Cuts short video-only clips (stream copy, no re-encode) out of a media library and sorts them
  into .\media\<class> folders for media-test.ps1. Windows PowerShell 5.1+.

.PARAMETER Source    Folder with your media files (searched recursively).
.PARAMETER Out       Output media folder (default .\media).
.PARAMETER Seconds   Clip length (default 45).
.PARAMETER Start     Seconds into the file where the clip starts (default 600; short files use 25% instead).
.PARAMETER PerClass  Max clips kept per class folder (default 2).
.PARAMETER Recurse   Search sub-folders (default on).
.PARAMETER DryRun    Only list what would be cut.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Source,
    [string]$Out,
    [int]$Seconds = 45,
    [int]$Start = 600,
    [int]$PerClass = 2,
    [string]$FfmpegPath,
    [int]$MaxProbe = 0,
    [int]$Seed = 0,
    [switch]$NoShuffle,
    [switch]$Exhaustive,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir
if (-not $Out) { $Out = Join-Path $RootDir 'media' }

$ff = $FfmpegPath
if (-not $ff) {
    foreach ($c in @('ffmpeg-jellyfin\bin\ffmpeg.exe', 'ffmpeg-full\bin\ffmpeg.exe', 'ffmpeg.exe', 'ffmpeg\bin\ffmpeg.exe', 'bin\ffmpeg.exe')) { $p = Join-Path $RootDir $c; if (Test-Path $p) { $ff = $p; break } }
}
if (-not $ff) { $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue; if ($cmd) { $ff = $cmd.Source } }
if (-not $ff) { Write-Host 'ffmpeg.exe not found (next to this script, in .\ffmpeg\bin, or in PATH).' -ForegroundColor Red; exit 1 }

function Split-TopLevel([string]$s) {
    $parts = New-Object System.Collections.ArrayList
    $depth = 0; $cur = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '(' -or $ch -eq '[') { $depth++ } elseif ($ch -eq ')' -or $ch -eq ']') { $depth-- }
        if ($ch -eq ',' -and $depth -le 0) { [void]$parts.Add($cur.ToString().Trim()); [void]$cur.Clear() } else { [void]$cur.Append($ch) }
    }
    [void]$parts.Add($cur.ToString().Trim())
    return ,@($parts)
}

function Get-Probe([string]$Path) {
    $tmp = [IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $ff -ArgumentList "-hide_banner -i `"$Path`"" -NoNewWindow -PassThru -Wait -RedirectStandardError $tmp -RedirectStandardOutput "$tmp.out"
    $lines = (Get-Content -LiteralPath $tmp) ; Remove-Item $tmp, "$tmp.out" -ErrorAction SilentlyContinue
    $v = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'Stream #\d+:\d+.*: Video: ' -and $lines[$i] -notmatch 'attached pic') { $v = $i; break } }
    if ($v -lt 0) { return $null }
    $body = $lines[$v].Substring($lines[$v].IndexOf('Video: ') + 7)
    $seg = Split-TopLevel $body
    $codec = ($seg[0] -split '\s+')[0] -replace 'mpeg2video', 'mpeg2'
    $transfer = ''
    if ($seg.Count -gt 1 -and $seg[1] -match '\(([^)]*)\)') { foreach ($t in ($Matches[1] -split ',')) { if ($t.Trim() -match '^(\w+)/(\w+)/([\w-]+)$') { $transfer = $Matches[3] } } }
    $w = 0; $h = 0
    foreach ($s in $seg) { if ($s -match '^(\d{2,5})x(\d{2,5})') { $w = [int]$Matches[1]; $h = [int]$Matches[2]; break } }
    $dv = $null
    for ($i = $v + 1; $i -lt [math]::Min($v + 15, $lines.Count); $i++) {
        if ($lines[$i] -match 'Stream #\d+:\d+') { break }
        if ($lines[$i] -match 'DOVI configuration record:.*profile:\s*(\d+)') { $dv = [int]$Matches[1] }
    }
    $dur = 0.0
    $dl = $lines | Where-Object { $_ -match '^\s*Duration:' } | Select-Object -First 1
    if ($dl -match 'Duration:\s*(\d+):(\d+):([\d.]+)') { $dur = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [double]$Matches[3] }
    $res = 'sd'
    if ($w -ge 3000 -or $h -ge 2000) { $res = '4k' } elseif ($w -ge 1800 -or $h -ge 1000) { $res = '1080p' } elseif ($w -ge 1200 -or $h -ge 680) { $res = '720p' }
    $dr = 'sdr'
    if ($null -ne $dv) { $dr = "dv-p$dv" } elseif ($transfer -eq 'smpte2084') { $dr = 'hdr10' } elseif ($transfer -eq 'arib-std-b67') { $dr = 'hlg' }
    return [pscustomobject]@{ Codec = $codec; Res = $res; Dr = $dr; Dur = $dur; Class = "$codec-$res-$dr"; W = $w; H = $h }
}

function Get-Folder($Class) {
    if ($Class -like 'dv-*' -or $Class -match '-dv-p') { return 'dolby-vision' }
    switch -Wildcard ($Class) {
        'h264-1080p-sdr' { return 'h264-1080p-sdr' }
        'h264-4k-sdr'    { return 'h264-4k-sdr' }
        'hevc-1080p-sdr' { return 'hevc-1080p-sdr' }
        'hevc-1080p-hdr10' { return 'hevc-1080p-hdr10' }
        'hevc-4k-sdr'    { return 'hevc-4k-sdr' }
        'hevc-4k-hdr10'  { return 'hevc-4k-hdr10' }
        'hevc-4k-hlg'    { return 'hevc-4k-hlg' }
        default          { return 'other' }
    }
}

$exts = '.mkv', '.mp4', '.m4v', '.mov', '.ts', '.m2ts', '.mts', '.avi', '.webm', '.wmv', '.mpg', '.mpeg'
# `powershell -File` passes -Source a,b as ONE string; accept comma or semicolon separated paths too.
$Source = @($Source | ForEach-Object { $_ -split '"?\s*[,;]\s*"?' } | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
$files = @()
foreach ($src in $Source) {
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "Source not found: $src" -ForegroundColor Yellow; continue }
    $found = @(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $exts -contains $_.Extension.ToLower() -and $_.Name -notmatch '(?i)sample|trailer|-extra|featurette' })
    Write-Host ("{0,6} video files in {1}" -f $found.Count, $src)
    $files += $found
}
if ($files.Count -eq 0) { Write-Host 'No video files found.' -ForegroundColor Red; exit 1 }
# Shuffle so clips come from all over the library (not just the first folder alphabetically).
if (-not $NoShuffle) {
    if ($Seed -ne 0) { $rnd = New-Object System.Random($Seed) } else { $rnd = New-Object System.Random }
    $files = @($files | Sort-Object { $rnd.Next() })
}
# Classes media-test cares about; the scan stops early once all of them have $PerClass clips.
$core = 'h264-1080p-sdr', 'h264-4k-sdr', 'hevc-1080p-sdr', 'hevc-1080p-hdr10', 'hevc-4k-sdr', 'hevc-4k-hdr10', 'hevc-4k-hlg'
$count = @{}
$probed = 0
foreach ($f in $files) {
    if (-not $Exhaustive) {
        $full = $true
        foreach ($c in $core) { if (-not $count.ContainsKey($c) -or $count[$c] -lt $PerClass) { $full = $false; break } }
        if ($full) { Write-Host 'All core classes are filled, stopping early (use -Exhaustive to scan everything).'; break }
    }
    if ($MaxProbe -gt 0 -and $probed -ge $MaxProbe) { Write-Host "Reached -MaxProbe $MaxProbe, stopping."; break }
    $probed++
    if (($probed % 25) -eq 0) { Write-Host ("  ... probed {0}/{1} files" -f $probed, $files.Count) -ForegroundColor DarkGray }
    $pr = Get-Probe $f.FullName
    if (-not $pr) { continue }
    $folder = Get-Folder $pr.Class
    $key = $pr.Class
    if (-not $count.ContainsKey($key)) { $count[$key] = 0 }
    if ($count[$key] -ge $PerClass) { continue }
    $ss = $Start
    if ($pr.Dur -le ($Start + $Seconds + 10)) { $ss = [math]::Floor($pr.Dur * 0.25) }
    $dir = Join-Path $Out $folder
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $safe = ([IO.Path]::GetFileNameWithoutExtension($f.Name) -replace '[^A-Za-z0-9._-]+', '_')
    if ($safe.Length -gt 50) { $safe = $safe.Substring(0, 50) }
    $dest = Join-Path $dir ("{0}__{1}.mkv" -f $safe, $pr.Class)
    Write-Host ("  {0,-48} -> {1}\{2}  [{3}x{4}, start {5}s]" -f $f.Name, $folder, (Split-Path $dest -Leaf), $pr.W, $pr.H, $ss)
    if ($DryRun) { $count[$key]++; continue }
    $a = "-hide_banner -loglevel error -y -ss $ss -t $Seconds -i `"$($f.FullName)`" -map 0:v:0 -c:v copy -an -sn -dn `"$dest`""
    $p = Start-Process -FilePath $ff -ArgumentList $a -NoNewWindow -PassThru -Wait
    if ($p.ExitCode -eq 0 -and (Test-Path $dest)) { $count[$key]++ } else { Write-Host "    failed (exit $($p.ExitCode))" -ForegroundColor Yellow }
}
Write-Host ""
Write-Host ("Probed {0} files. Clips per class:" -f $probed)
$count.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-24} {1}" -f $_.Key, $_.Value) }
$missing = @($core | Where-Object { -not $count.ContainsKey($_) -or $count[$_] -lt $PerClass })
if ($missing.Count -gt 0) { Write-Host ("Not found (or fewer than {0}): {1}" -f $PerClass, ($missing -join ', ')) -ForegroundColor Yellow }
Write-Host ("Done. Output: {0}" -f $Out)
