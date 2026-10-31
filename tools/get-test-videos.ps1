<#
.SYNOPSIS
  Downloads a curated set of the official Jellyfin test videos into <repo>\media\ so the benchmark can run
  without any personal media. Windows PowerShell 5.1+.

.DESCRIPTION
  Source: https://repo.jellyfin.org/test-videos/  (courtesy of Gnattu, licensed CC BY-SA 4.0).
  Every file is verified against the .sha256sum published next to it. Files that are already present and
  verified are skipped. Nothing is downloaded with -DryRun.

  Sets:
    mini     1080p only: H.264, HEVC 8/10-bit, AV1, HDR10, Dolby Vision P5 and P8.1   (7 files, ~270 MB)
    starter  mini + 4K: H.264, HEVC 10-bit, HDR10 HEVC/AV1, Dolby Vision P5 and P8.1 (13 files, ~1.1 GB)

.PARAMETER Set     mini or starter (default starter).
.PARAMETER Out     Target media folder (default <repo>\media).
.PARAMETER DryRun  List what would be downloaded (with sizes) and exit.
#>
[CmdletBinding()]
param(
    [ValidateSet('mini', 'starter')][string]$Set = 'starter',
    [string]$Out,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Out) { $Out = Join-Path $RootDir 'media' }
$Base = 'https://repo.jellyfin.org/test-videos'

# path on the server  ->  folder under media\
$mini = @(
    @('SDR/AVC/Test Jellyfin 1080p AVC 10M.mp4',                         'h264-1080p-sdr'),
    @('SDR/HEVC 8bit/Test Jellyfin 1080p HEVC 8bit 10M.mp4',             'hevc-1080p-sdr'),
    @('SDR/HEVC 10bit/Test Jellyfin 1080p HEVC 10bit 10M.mp4',           'hevc-1080p-sdr'),
    @('SDR/AV1/Test Jellyfin 1080p AV1 10bit 10M.mp4',                   'other'),
    @('HDR/HDR10/HEVC/Test Jellyfin 1080p HEVC HDR10 10M.mp4',           'hevc-1080p-hdr10'),
    @('HDR/Dolby Vision/Test Jellyfin 1080p DV P8.1.mp4',                'dolby-vision'),
    @('HDR/Dolby Vision/Test Jellyfin 1080p DV P5.mp4',                  'dolby-vision')
)
$fourK = @(
    @('SDR/AVC/Test Jellyfin 4K AVC 40M.mp4',                            'h264-4k-sdr'),
    @('SDR/HEVC 10bit/Test Jellyfin 4K HEVC 10bit 40M.mp4',              'hevc-4k-sdr'),
    @('HDR/HDR10/HEVC/Test Jellyfin 4K HEVC HDR10 40M.mp4',              'hevc-4k-hdr10'),
    @('HDR/HDR10/AV1/Test Jellyfin 4K AV1 HDR10 40M.mp4',                'other'),
    @('HDR/Dolby Vision/Test Jellyfin 4K DV P8.1.mp4',                   'dolby-vision'),
    @('HDR/Dolby Vision/Test Jellyfin 4K DV P5.mp4',                     'dolby-vision')
)
$items = @($mini); if ($Set -eq 'starter') { $items += $fourK }

function Get-Url([string]$rel) { return $Base + '/' + (($rel -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/') }

$total = 0
$plan = foreach ($it in $items) {
    $url = Get-Url $it[0]
    $size = 0
    try { $h = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing; $size = [long]($h.Headers['Content-Length'] | Select-Object -First 1) } catch { Write-Warning "not reachable: $($it[0])" }
    $total += $size
    [pscustomobject]@{ Rel = $it[0]; Folder = $it[1]; Url = $url; Size = $size; Name = (Split-Path $it[0] -Leaf) }
}
Write-Host ("Set '{0}': {1} files, {2:N0} MB total -> {3}" -f $Set, @($plan).Count, ($total / 1MB), $Out)
$plan | ForEach-Object { Write-Host ("  {0,-16} {1,6:N0} MB  {2}" -f $_.Folder, ($_.Size / 1MB), $_.Name) }
if ($DryRun) { Write-Host 'Dry run, nothing downloaded.'; return }

foreach ($p in $plan) {
    $dir = Join-Path $Out $p.Folder
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dest = Join-Path $dir $p.Name
    $expected = $null
    try { $expected = ((Invoke-WebRequest -Uri ($p.Url + '.sha256sum') -UseBasicParsing).Content.ToString().Trim() -split '\s+')[0].ToLower() } catch { Write-Warning "no .sha256sum for $($p.Name)" }
    if ((Test-Path $dest) -and $expected -and ((Get-FileHash $dest -Algorithm SHA256).Hash.ToLower() -eq $expected)) { Write-Host "  have   $($p.Name)"; continue }
    Write-Host "  fetch  $($p.Name)"
    Invoke-WebRequest -Uri $p.Url -OutFile $dest -UseBasicParsing
    if ($expected) {
        $sha = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
        if ($sha -ne $expected) { Remove-Item $dest -Force; throw "SHA256 mismatch for $($p.Name), file removed" }
    }
}
Write-Host 'Done. Test videos: Jellyfin test videos, courtesy of Gnattu, CC BY-SA 4.0 (https://repo.jellyfin.org/test-videos/)' -ForegroundColor Green
