# speedtest

A PowerShell script that aggregates internet speed measurements across
multiple independent, official speed-test providers and reports a
per-provider and overall average. Built to measure actual circuit/line-rate
capacity (multi-gig connections included), not "how fast does one browser
tab feel."

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
| **[Ookla Speedtest CLI](https://www.speedtest.net/apps/cli)** | Official binary from `install.speedtest.net` | Auto-picks the nearest server from Ookla's global network — for many residential ISPs (Spectrum confirmed) that **is** the ISP's own tester: `speedtest.spectrum.net` itself runs on this same Ookla white-label network. The script flags it in the output when this happens, e.g. `[your ISP's own server: Spectrum]`. |
| **[LibreSpeed CLI](https://github.com/librespeed/speedtest-cli)** | Official binary, fetched from GitHub's latest release | Tests against LibreSpeed.org's public server list — independent infrastructure from Ookla, also nearest-server/regional. |

Both use multiple parallel TCP streams internally, which is what it actually
takes to measure line-rate capacity on a fast (multi-gig) connection.

## What it deliberately skips, and why

- **Cloudflare (`speed.cloudflare.com`)** — tried and cut. Cloudflare's public
  test is intentionally a *single* TCP stream (it's built to emulate one web
  page load, not raw pipe capacity), so on a multi-gig connection it reads far
  below actual line rate — that's a documented design choice on their end, not
  a bug. We tried forcing it into a real multi-stream test by hammering the
  endpoint with parallel `curl` processes; past ~8-12 concurrent streams it
  started failing outright (0 Mbps / timeouts), almost certainly Cloudflare
  rate-limiting per client. It's not built for this and can't be made to do it
  reliably, so rather than ship noisy/wrong data it's cut entirely.
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
```

## Requirements

- Windows 10 (1803+) / Windows 11, PowerShell 5.1+
