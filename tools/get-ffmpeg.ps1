<#
.SYNOPSIS
  Downloads the latest jellyfin-ffmpeg portable build for Windows into <repo>\ffmpeg-jellyfin\bin\ and verifies its SHA256.

.DESCRIPTION
  jellyfin-ffmpeg is the ffmpeg a Jellyfin server actually runs. It is the only build that contains every filter
  the benchmark can use (tonemap_cuda, tonemap_opencl, libplacebo, vpp_qsv, scale_cuda, zscale ...), so the
  benchmark prefers it over every other ffmpeg it finds.

  Source: https://github.com/jellyfin/jellyfin-ffmpeg/releases  (the SHA256 comes from the GitHub release metadata).

.PARAMETER Version   Release tag, e.g. v8.1.3-1 (default: latest).
.PARAMETER FromFile  Use an already downloaded jellyfin-ffmpeg zip instead of downloading (still extracted to ffmpeg-jellyfin\bin).
.PARAMETER Check     Only show which file would be downloaded and its size / hash; download nothing.
#>
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [string]$FromFile,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Dest = Join-Path $RootDir 'ffmpeg-jellyfin\bin'

$arch = 'win64-clang-gpl'
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'winarm64-clang-gpl' }

if ($Version -eq 'latest') { $api = 'https://api.github.com/repos/jellyfin/jellyfin-ffmpeg/releases/latest' }
else { $api = "https://api.github.com/repos/jellyfin/jellyfin-ffmpeg/releases/tags/$Version" }
Write-Host "Querying $api"
$rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'jellyfin-transcode-bench' }
$asset = $rel.assets | Where-Object { $_.name -like "*_portable_$arch.zip" } | Select-Object -First 1
if (-not $asset) { throw "No portable $arch zip in release $($rel.tag_name)" }
$expected = $null
if ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$') { $expected = $Matches[1].ToLower() }
Write-Host ("Release {0}: {1} ({2:N1} MB), sha256 {3}" -f $rel.tag_name, $asset.name, ($asset.size / 1MB), $(if ($expected) { $expected } else { 'not published' }))
if ($Check) { Write-Host 'Check only, nothing downloaded.'; return }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('jtb-ffmpeg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    if ($FromFile) { $zip = (Resolve-Path $FromFile).Path }
    else {
        $zip = Join-Path $tmp $asset.name
        Write-Host "Downloading $($asset.browser_download_url)"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers @{ 'User-Agent' = 'jellyfin-transcode-bench' }
    }
    $sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($expected) {
        if ($sha -ne $expected) { throw "SHA256 mismatch for $zip`n  expected $expected`n  actual   $sha" }
        Write-Host 'SHA256 verified.' -ForegroundColor Green
    } else { Write-Host "No published hash to compare against (sha256 $sha)." -ForegroundColor Yellow }

    $ex = Join-Path $tmp 'extract'
    Expand-Archive -Path $zip -DestinationPath $ex
    $exe = Get-ChildItem -Path $ex -Recurse -Filter ffmpeg.exe | Select-Object -First 1
    if (-not $exe) { throw 'ffmpeg.exe not found inside the archive' }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Copy-Item $exe.FullName (Join-Path $Dest 'ffmpeg.exe') -Force
    Set-Content -Path (Join-Path $RootDir 'ffmpeg-jellyfin\VERSION.txt') -Value ("{0}`r`n{1}`r`nsha256 {2}" -f $rel.tag_name, $asset.name, $sha)
    Write-Host "Installed: $Dest\ffmpeg.exe" -ForegroundColor Green
    & (Join-Path $Dest 'ffmpeg.exe') -hide_banner -version | Select-Object -First 1
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
