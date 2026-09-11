#requires -Version 5.1
<#
.SYNOPSIS
    Tests internet speed across multiple independent, official speed-test
    providers/servers and reports the PEAK (best) result recorded, not an
    average - the goal is "what is this circuit's actual max throughput",
    which a single slow/congested run shouldn't drag down.

.DESCRIPTION
    Ookla Speedtest CLI (official binary, install.speedtest.net):
      - Lists the nearest servers via `speedtest -L` (Ookla-ranked by distance/
        latency) and runs the closest $OoklaServerCount of them, $Runs times
        each. For most residential ISPs this set includes the ISP's own
        white-labeled Ookla server (e.g. speedtest.spectrum.net runs on this
        same Ookla network) - when a run lands on that server it's tagged
        [your ISP's own server: X].
      - "Nearest by distance" isn't guaranteed to include the ISP's own server
        (a non-ISP datacenter can be closer). So after the first server's runs
        reveal your ISP (from the test result's own `isp` field - free, no
        extra call needed), the script searches Ookla's full nearby-server list
        for one operated by that ISP and adds it to the test set if it wasn't
        already picked up - so your ISP's own server is always included when
        Ookla has one near you, not left to chance.

    LibreSpeed CLI (official binary, github.com/librespeed/speedtest-cli):
      - Tests against LibreSpeed.org's public server list (independent
        infrastructure from Ookla), auto-picking the nearest server, $Runs times.

    Both use multiple parallel TCP streams internally, which is required to
    measure actual circuit/line-rate capacity on fast (multi-gig) connections.

    Deliberately excludes:
      - speedtest.net-style scraping of the website itself (Ookla's Terms of
        Service prohibit automated/bulk access to it - the official CLI above
        is the sanctioned way to get the same data).
      - fast.com (Netflix publishes no public API; the only way to use it is
        scraping an undocumented token, which is unsupported and can break
        anytime).
      - M-Lab's ndt7 client (no official Windows binary, and the common
        third-party prebuilt one has multiple antivirus false-positive reports).
      - Cloudflare's speed.cloudflare.com. Their public test is intentionally a
        SINGLE TCP stream (it's meant to emulate one web page load, not measure
        raw pipe capacity), so on a multi-gig connection it systematically reads
        far below actual line rate - a documented design choice, not a fluke.
        Forcing it into a multi-stream test by hammering their endpoint with
        many parallel curl processes was tried and rejected: past ~8-12
        concurrent streams it started failing outright (0 Mbps / timeouts),
        almost certainly Cloudflare rate-limiting per client. Not reliable, so
        cut rather than shipped as noisy data.

.PARAMETER Runs
    Number of test iterations per server (default 5).

.PARAMETER OoklaServerCount
    How many of the nearest Ookla servers to test, each $Runs times (default 3).

.PARAMETER SkipOokla / SkipLibreSpeed
    Skip an individual provider.

.EXAMPLE
    irm https://raw.githubusercontent.com/matt-magna5/speedtest/main/Test-InternetSpeed.ps1 | iex

.EXAMPLE
    .\Test-InternetSpeed.ps1 -Runs 3 -OoklaServerCount 5
#>
[CmdletBinding()]
param(
    [int]$Runs = 5,
    [int]$OoklaServerCount = 3,
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

function Get-OoklaCandidateServers {
    param($ExePath)
    $raw = & $ExePath --servers --accept-license --accept-gdpr -f json 2>$null | Select-Object -Last 1
    $json = $raw | ConvertFrom-Json
    # `speedtest -L` returns every server Ookla considers "nearby", ranked
    # nearest-first (distance/latency) - typically ~10-15 for a given location.
    $json.servers
}

function Invoke-OoklaTest {
    param($ExePath, [int]$ServerId)
    $raw = & $ExePath -s $ServerId --accept-license --accept-gdpr -f json 2>$null | Select-Object -Last 1
    $json = $raw | ConvertFrom-Json
    # For most residential ISPs (Spectrum/Charter confirmed; many others too) the
    # nearest server IS the ISP's own white-labeled Ookla server - e.g.
    # speedtest.spectrum.net runs on this same Ookla network. Flag it when that's
    # what happened, since that's as "local ISP tester" as it gets.
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
    try {
        $exe = Get-OoklaCli
        $candidates = Get-OoklaCandidateServers -ExePath $exe
        if (-not $candidates -or $candidates.Count -eq 0) { throw "No nearby Ookla servers returned." }

        # A mutable queue (not a plain array/foreach) because we may append the
        # ISP's own server mid-loop, once we learn who the ISP is from run #1.
        $serverQueue = [System.Collections.Generic.List[object]]::new()
        $serverQueue.AddRange([object[]]($candidates | Select-Object -First $OoklaServerCount))

        $idx = 0
        while ($idx -lt $serverQueue.Count) {
            $srv = $serverQueue[$idx]
            Write-Section "Ookla - $($srv.name) ($($srv.location)) x$Runs"
            for ($i = 1; $i -le $Runs; $i++) {
                Write-Host "  Run $i/$Runs..." -NoNewline
                try {
                    $r = Invoke-OoklaTest -ExePath $exe -ServerId $srv.id
                    $tag = if ($r.ISPOperated) { " [your ISP's own server: $($r.ISP)]" } else { "" }
                    Write-Host (" {0} Mbps down / {1} Mbps up / {2} ms{3}" -f $r.DownloadMbps, $r.UploadMbps, $r.PingMs, $tag)
                    $allResults += $r
                } catch {
                    Write-Host " failed: $_" -ForegroundColor DarkYellow
                }
            }

            # After the first server's runs, we know the ISP for free (every Ookla
            # result carries it) - make sure the ISP's own server is in the queue.
            if ($idx -eq 0) {
                $isp = ($allResults | Where-Object { $_.Provider -eq 'Ookla' -and $_.ISP } | Select-Object -First 1).ISP
                if ($isp) {
                    $alreadyQueued = $serverQueue | Where-Object { $_.name -like "*$isp*" }
                    if (-not $alreadyQueued) {
                        $ispMatch = $candidates | Where-Object { $_.name -like "*$isp*" } | Select-Object -First 1
                        if ($ispMatch) {
                            $serverQueue.Add($ispMatch)
                            Write-Host "  -> Adding your ISP's own server to the test set: $($ispMatch.name) ($($ispMatch.location))" -ForegroundColor DarkGray
                        } else {
                            Write-Host "  -> No $isp-operated Ookla server found nearby; sticking with the nearest $OoklaServerCount." -ForegroundColor DarkGray
                        }
                    }
                }
            }
            $idx++
        }
    } catch {
        Write-Warning "Ookla tests skipped: $_"
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

Write-Section "Per-provider PEAK (best of all runs)"
$byProvider = $allResults | Group-Object Provider | ForEach-Object {
    $bestDown = $_.Group | Sort-Object DownloadMbps -Descending | Select-Object -First 1
    $bestUp   = $_.Group | Sort-Object UploadMbps -Descending | Select-Object -First 1
    [PSCustomObject]@{
        Provider     = $_.Name
        MaxDownMbps  = $bestDown.DownloadMbps
        DownServer   = $bestDown.Server
        MaxUpMbps    = $bestUp.UploadMbps
        BestPingMs   = ($_.Group.PingMs | Measure-Object -Minimum).Minimum
        Runs         = $_.Count
    }
}
$byProvider | Format-Table -AutoSize

Write-Section "OVERALL PEAK (best single result across every provider/server/run)"
$bestDownOverall = $allResults | Sort-Object DownloadMbps -Descending | Select-Object -First 1
$bestUpOverall   = $allResults | Sort-Object UploadMbps -Descending | Select-Object -First 1
$bestPingOverall = $allResults | Sort-Object PingMs | Select-Object -First 1
[PSCustomObject]@{
    MaxDownloadMbps = $bestDownOverall.DownloadMbps
    OnServer        = $bestDownOverall.Server
    MaxUploadMbps   = $bestUpOverall.UploadMbps
    OnServer_       = $bestUpOverall.Server
    BestPingMs      = $bestPingOverall.PingMs
    TotalRuns       = $allResults.Count
} | Format-List
