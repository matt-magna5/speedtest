# speedtest

A PowerShell script that aggregates internet speed measurements across three
independent, official speed-test providers and reports a per-provider and
overall average.

## Run it

```powershell
irm https://raw.githubusercontent.com/matt-magna5/speedtest/main/Test-InternetSpeed.ps1 | iex
```

No install needed — the first run downloads two small official CLI tools into
`%LOCALAPPDATA%\SpeedTestAggregator` and reuses them on later runs.

## What it tests

Each provider is run 5 times (configurable) and averaged:

| Provider | How | Notes |
|---|---|---|
| **[Ookla Speedtest CLI](https://www.speedtest.net/apps/cli)** | Official binary from `install.speedtest.net` | Auto-picks the nearest server from Ookla's global network, which includes ISP-operated servers (e.g. Spectrum runs its own) |
| **[LibreSpeed CLI](https://github.com/librespeed/speedtest-cli)** | Official binary, fetched from GitHub's latest release | Tests against LibreSpeed.org's public server list — independent infrastructure from Ookla |
| **Cloudflare** | Plain timed HTTP GET/POST against `speed.cloudflare.com` | No binary needed — Cloudflare's own public, documented speed-test endpoints |

## What it deliberately skips, and why

- **Speedtest.net website scraping** — Ookla's Terms of Service prohibit
  automated/bulk access to the *website*. The official CLI above is the
  sanctioned way to get the same data.
- **fast.com (Netflix)** — no public API. The only way to use it is scraping
  an undocumented token out of the page, which isn't supported and can break
  without warning.
- **M-Lab ndt7** — M-Lab doesn't publish an official Windows binary, and the
  common third-party prebuilt one has multiple antivirus false-positive
  reports. Not something a public script should silently download and run.

## Usage

```powershell
# Default: 5 runs per provider
.\Test-InternetSpeed.ps1

# Fewer runs for a quicker check
.\Test-InternetSpeed.ps1 -Runs 3

# Skip a provider
.\Test-InternetSpeed.ps1 -SkipOokla
.\Test-InternetSpeed.ps1 -SkipLibreSpeed
.\Test-InternetSpeed.ps1 -SkipCloudflare
```

## Requirements

- Windows 10 (1803+) / Windows 11, PowerShell 5.1+
- `curl.exe` (ships built into Windows 10/11 by default) — used for the
  Cloudflare timing, since `Invoke-WebRequest`'s buffering overhead badly
  undercounts high-speed connections
