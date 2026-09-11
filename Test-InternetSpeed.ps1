#requires -Version 5.1
<#
.SYNOPSIS
    Aggregates internet speed test results across multiple independent, official
    speed-test providers and reports a per-provider and overall average.

.DESCRIPTION
    Runs each of the following N times (default 5) and averages the results:
      - Ookla Speedtest CLI  (official binary, install.speedtest.net)
                             -> auto-picks the nearest server from Ookla's global
                                network, which includes ISP-operated servers
                                (e.g. speedtest.spectrum.net runs on this same
                                Ookla network - when Ookla picks that server,
                                that IS the ISP's own tester, not a proxy for it).
      - LibreSpeed CLI       (official binary, github.com/librespeed/speedtest-cli)
                             -> tests against LibreSpeed.org's public server list,
                                independent infrastructure from Ookla.

    Both providers use multiple parallel TCP streams internally, which is required
    to measure actual circuit/line-rate capacity on fast (multi-gig) connections -
    that's the goal of this script, not "how fast does one browser tab feel."

    Deliberately excludes:
      - speedtest.net-style scraping of the website itself (Ookla's Terms of Service
        prohibit automated/bulk access to it - the official CLI above is the
        sanctioned way to get the same data).
      - fast.com (Netflix publishes no public API; the only way to use it is
        scraping an undocumented token, which is unsupported and can break anytime).
      - M-Lab's ndt7 client (no official Windows binary, and the common third-party
        prebuilt one has multiple antivirus false-positive reports).
      - Cloudflare's speed.cloudflare.com. Their public test is intentionally a
        SINGLE TCP stream (it's meant to emulate one web page load, not measure raw
        pipe capacity), so on a multi-gig connection it systematically reads far
        below actual line rate - not a fluke, a documented design choice. Forcing
        it into a multi-stream test by hammering their endpoint with many parallel
        curl processes was tried and rejected: past ~8-12 concurrent streams it
        started failing outright (0 Mbps / timeouts), almost certainly Cloudflare
        rate-limiting that endpoint per client. It's not built for this and can't
        be made to do it reliably, so it's cut rather than shipped as noisy data.

.PARAMETER Runs
    Number of test iterations per provider (default 5).

.PARAMETER SkipOokla / SkipLibreSpeed
    Skip an individual provider.

.EXAMPLE
    irm https://raw.githubusercontent.com/matt-magna5/speedtest/main/Test-InternetSpeed.ps1 | iex

.EXAMPLE
    .\Test-InternetSpeed.ps1 -Runs 3
#>
[CmdletBinding()]
param(
    [int]$Runs = 5,
    [switch]$SkipOokla,
    [switch]$SkipLibreSpeed
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
    # Ookla auto-picks the nearest server by latency, which for most residential ISPs
    # (Spectrum/Charter confirmed; many others too) IS the ISP's own white-labeled
    # Ookla server - e.g. speedtest.spectrum.net runs on this same Ookla network.
    # Flag it when that's what happened, since that's as "local ISP tester" as it gets.
    $ispServer = $json.isp -and $json.server.name -and ($json.server.name -like "*$($json.isp)*")
    [PSCustomObject]@{
        Provider     = 'Ookla'
        Server       = "$($json.server.name) ($($json.server.location))"
        ISP          = $json.isp
        ISPOperated  = [bool]$ispServer
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
            $tag = if ($r.ISPOperated) { " [your ISP's own server: $($r.ISP)]" } else { "" }
            Write-Host (" {0} Mbps down / {1} Mbps up / {2} ms - {3}{4}" -f $r.DownloadMbps, $r.UploadMbps, $r.PingMs, $r.Server, $tag)
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
            Write-Host (" {0} Mbps down / {1} Mbps up / {2} ms - {3}" -f $r.DownloadMbps, $r.UploadMbps, $r.PingMs, $r.Server)
            $allResults += $r
        }
    } catch {
        Write-Warning "LibreSpeed test skipped: $_"
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
