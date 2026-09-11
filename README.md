# speedtest

A PowerShell script that tests internet speed across multiple independent,
official speed-test providers/servers and reports the **peak (best) result
recorded** — not an average. The goal is "what is this circuit's actual max
throughput," which one congested or off-path run shouldn't drag down.

## Run it

```powershell
irm https://raw.githubusercontent.com/matt-magna5/speedtest/main/Test-InternetSpeed.ps1 | iex
```

No install needed — the first run downloads two small official CLI tools into
`%LOCALAPPDATA%\SpeedTestAggregator` and reuses them on later runs.

## What it tests

| Provider | How | Notes |
|---|---|---|
| **[Ookla Speedtest CLI](https://www.speedtest.net/apps/cli)** | Official binary from `install.speedtest.net` | Tests the **3 nearest datacenters** (by Ookla's own distance ranking), **5 runs each** — 15 runs total, all configurable. After the first server's runs reveal your ISP (free, from the result's own `isp` field), the script checks whether your ISP's own white-labeled Ookla server (e.g. `speedtest.spectrum.net` runs on this same network) is already in that set — if not, it's added automatically, so it's never left to chance that "nearest by distance" happens to skip it. Matched runs are tagged `[your ISP's own server: X]`. |
| **[LibreSpeed CLI](https://github.com/librespeed/speedtest-cli)** | Official binary, fetched from GitHub's latest release | Tests against LibreSpeed.org's public server list — independent infrastructure from Ookla, nearest-server auto-selected, 5 runs. |

Both use multiple parallel TCP streams internally, which is what it actually
takes to measure line-rate capacity on a fast (multi-gig) connection.

## Output

- **Per-provider PEAK** — the single best download/upload result and best
  (lowest) ping seen for that provider across all its runs.
- **OVERALL PEAK** — the single best result across every server and run, plus
  which server produced it.

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
# Default: top 3 Ookla servers + LibreSpeed, 5 runs each
.\Test-InternetSpeed.ps1

# Test more/fewer Ookla datacenters, or change the run count
.\Test-InternetSpeed.ps1 -OoklaServerCount 5 -Runs 3

# Skip a provider
.\Test-InternetSpeed.ps1 -SkipOokla
.\Test-InternetSpeed.ps1 -SkipLibreSpeed
```

## Requirements

- Windows 10 (1803+) / Windows 11, PowerShell 5.1+
