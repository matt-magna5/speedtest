#requires -Version 5.1
<#
.SYNOPSIS
    Aggregates internet speed test results across multiple independent, official
    speed-test providers and reports a per-provider and overall average.

.DESCRIPTION
    Runs each of the following N times (default 3) and averages the results:
      - Ookla Speedtest CLI  (official binary, install.speedtest.net)
                             -> auto-picks the nearest server from Ookla's global
                                network, which includes ISP-operated servers
                                (e.g. Spectrum runs its own Ookla-compatible server).
      - LibreSpeed CLI       (official binary, github.com/librespeed/speedtest-cli)
                             -> tests against LibreSpeed.org's public server list,
                                independent infrastructure from Ookla.
      - Cloudflare           (no binary - plain timed HTTP GET/POST against
                                speed.cloudflare.com, Cloudflare's own public,
                                documented speed-test endpoints)

    Deliberately excludes speedtest.net-style scraping (Ookla's Terms of Service
    prohibit automated/bulk access to the website itself - this script instead
    uses their *official* CLI, which is fine) and fast.com (Netflix publishes no
    public API; the only way to use it is scraping an undocumented token, which
    is unsupported and can break at any time). It also skips M-Lab's ndt7 client
    because M-Lab does not publish an official Windows binary and the common
    third-party prebuilt one has multiple antivirus false-positive reports -
    not something to have a public script silently download and execute.

.PARAMETER Runs
    Number of test iterations per provider (default 3).

.PARAMETER SkipOokla / SkipLibreSpeed / SkipCloudflare
    Skip an individual provider.

.EXAMPLE
    irm https://raw.githubusercontent.com/<you>/<repo>/main/Test-InternetSpeed.ps1 | iex

.EXAMPLE
    .\Test-InternetSpeed.ps1 -Runs 5
#>
[CmdletBinding()]
param(
    [int]$Runs = 3,
    [switch]$SkipOokla,
    [switch]$SkipLibreSpeed,
    [switch]$SkipCloudflare
)

$ErrorActionPreference = 'Stop'
$ToolsDir = Join-Path $env:LOCALAPPDATA 'SpeedTestAggregator'
New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null

function Write-Section($text) {
    Write-Host ""
    Write-Host "== $text ==" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Ookla Speedtest CLI (official) - https://www.speedtest.net/apps/cli
# ---------------------------------------------------------------------------
function Get-OoklaCli {
    $exe = Join-Path $ToolsDir 'speedtest.exe'
    if (Test-Path $exe) { return $exe }
    Write-Host "Downloading Ookla Speedtest CLI (official, install.speedtest.net)..." -ForegroundColor DarkGray
    $zip = Join-Path $ToolsDir 'ookla.zip'
    Invoke-WebRequest -Uri 'https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip' -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $ToolsDir -Force
    Remove-Item $zip -Force
    if (-not (Test-Path $exe)) { throw "Ookla Speedtest CLI failed to extract." }
    return $exe
}

function Invoke-OoklaTest {
    param($ExePath)
    $raw = & $ExePath --accept-license --accept-gdpr -f json 2>$null | Select-Object -Last 1
    $json = $raw | ConvertFrom-Json
    [PSCustomObject]@{
        Provider     = 'Ookla'
        Server       = "$($json.server.name) ($($json.server.location))"
        PingMs       = [math]::Round($json.ping.latency, 1)
        DownloadMbps = [math]::Round(($json.download.bandwidth * 8 / 1MB), 2)
        UploadMbps   = [math]::Round(($json.upload.bandwidth * 8 / 1MB), 2)
    }
}

# ---------------------------------------------------------------------------
# LibreSpeed CLI (official) - https://github.com/librespeed/speedtest-cli
# ---------------------------------------------------------------------------
function Get-LibreSpeedCli {
    $exe = Join-Path $ToolsDir 'librespeed-cli.exe'
    if (Test-Path $exe) { return $exe }
    Write-Host "Downloading LibreSpeed CLI (official, github.com/librespeed/speedtest-cli)..." -ForegroundColor DarkGray
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/librespeed/speedtest-cli/releases/latest' -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -match 'windows_amd64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw "Could not find a Windows amd64 asset in the latest LibreSpeed CLI release." }
    $zip = Join-Path $ToolsDir 'librespeed.zip'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $ToolsDir -Force
    Remove-Item $zip -Force
    if (-not (Test-Path $exe)) { throw "LibreSpeed CLI failed to extract." }
    return $exe
}

function Invoke-LibreSpeedTest {
    param($ExePath)
    $raw = & $ExePath --json --duration 5 --no-icmp 2>$null | Select-Object -Last 1
    $json = ($raw | ConvertFrom-Json)[0]
    [PSCustomObject]@{
        Provider     = 'LibreSpeed'
        Server       = $json.server.name
        PingMs       = [math]::Round($json.ping, 1)
        DownloadMbps = [math]::Round($json.download, 2)
        UploadMbps   = [math]::Round($json.upload, 2)
    }
}

# ---------------------------------------------------------------------------
# Cloudflare - plain timed HTTP against speed.cloudflare.com (no binary needed)
# ---------------------------------------------------------------------------
function Get-CurlExe {
    # curl.exe ships built into Windows 10 (1803+) / Windows 11. Invoke-WebRequest
    # buffers/parses the whole response in PowerShell, which adds enough overhead
    # to badly undercount high-speed connections - curl.exe measures the raw
    # transfer instead, same as the reference timings this script was validated against.
    $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "curl.exe not found (expected built into Windows 10 1803+/11)." }
    return $cmd.Source
}

function Invoke-CloudflareTest {
    $curl = Get-CurlExe

    $downBytes = 25000000
    $downOut = & $curl -s -o NUL -w "%{size_download} %{time_total}" "https://speed.cloudflare.com/__down?bytes=$downBytes"
    $downParts = $downOut -split '\s+'
    $downMbps = [math]::Round(([double]$downParts[0] * 8 / 1MB) / [double]$downParts[1], 2)

    $upBytes = 5000000
    $upFile = Join-Path $env:TEMP "cf_upload_payload.bin"
    if (-not (Test-Path $upFile)) {
        $payload = New-Object byte[] $upBytes
        (New-Object Random).NextBytes($payload)
        [System.IO.File]::WriteAllBytes($upFile, $payload)
    }
    $upTime = & $curl -s -o NUL -w "%{time_total}" -X POST --data-binary "@$upFile" "https://speed.cloudflare.com/__up"
    $upMbps = [math]::Round(($upBytes * 8 / 1MB) / [double]$upTime, 2)

    $pingTime = & $curl -s -o NUL -w "%{time_total}" "https://speed.cloudflare.com/__down?bytes=0"

    [PSCustomObject]@{
        Provider     = 'Cloudflare'
        Server       = 'speed.cloudflare.com'
        PingMs       = [math]::Round([double]$pingTime * 1000, 1)
        DownloadMbps = $downMbps
        UploadMbps   = $upMbps
    }
}

# ---------------------------------------------------------------------------
# Run everything
# ---------------------------------------------------------------------------
$allResults = @()

if (-not $SkipOokla) {
    Write-Section "Ookla Speedtest CLI x$Runs"
    try {
        $exe = Get-OoklaCli
        for ($i = 1; $i -le $Runs; $i++) {
            Write-Host "  Run $i/$Runs..." -NoNewline
            $r = Invoke-OoklaTest -ExePath $exe
            Write-Host (" {0} Mbps down / {1} Mbps up / {2} ms" -f $r.DownloadMbps, $r.UploadMbps, $r.PingMs)
            $allResults += $r
        }
    } catch {
        Write-Warning "Ookla test skipped: $_"
    }
}

if (-not $SkipLibreSpeed) {
    Write-Section "LibreSpeed CLI x$Runs"
    try {
        $exe = Get-LibreSpeedCli
        for ($i = 1; $i -le $Runs; $i++) {
            Write-Host "  Run $i/$Runs..." -NoNewline
            $r = Invoke-LibreSpeedTest -ExePath $exe
            Write-Host (" {0} Mbps down / {1} Mbps up / {2} ms" -f $r.DownloadMbps, $r.UploadMbps, $r.PingMs)
            $allResults += $r
        }
    } catch {
        Write-Warning "LibreSpeed test skipped: $_"
    }
}

if (-not $SkipCloudflare) {
    Write-Section "Cloudflare x$Runs"
    try {
        for ($i = 1; $i -le $Runs; $i++) {
            Write-Host "  Run $i/$Runs..." -NoNewline
            $r = Invoke-CloudflareTest
            Write-Host (" {0} Mbps down / {1} Mbps up / {2} ms" -f $r.DownloadMbps, $r.UploadMbps, $r.PingMs)
            $allResults += $r
        }
    } catch {
        Write-Warning "Cloudflare test skipped: $_"
    } finally {
        Remove-Item (Join-Path $env:TEMP "cf_upload_payload.bin") -Force -ErrorAction SilentlyContinue
    }
}

if ($allResults.Count -eq 0) {
    Write-Error "No providers produced results."
    return
}

Write-Section "Per-provider average"
$byProvider = $allResults | Group-Object Provider | ForEach-Object {
    [PSCustomObject]@{
        Provider     = $_.Name
        AvgDownMbps  = [math]::Round(($_.Group.DownloadMbps | Measure-Object -Average).Average, 2)
        AvgUpMbps    = [math]::Round(($_.Group.UploadMbps   | Measure-Object -Average).Average, 2)
        AvgPingMs    = [math]::Round(($_.Group.PingMs       | Measure-Object -Average).Average, 1)
        Runs         = $_.Count
    }
}
$byProvider | Format-Table -AutoSize

Write-Section "OVERALL AVERAGE (across all providers/runs)"
$overall = [PSCustomObject]@{
    DownloadMbps = [math]::Round(($allResults.DownloadMbps | Measure-Object -Average).Average, 2)
    UploadMbps   = [math]::Round(($allResults.UploadMbps   | Measure-Object -Average).Average, 2)
    PingMs       = [math]::Round(($allResults.PingMs       | Measure-Object -Average).Average, 1)
    TotalRuns    = $allResults.Count
}
$overall | Format-List
