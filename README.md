# userv.one Speed Test CLI (Yandex CDN edition)

A terminal speed test for headless servers, branded **userv.one**, measuring against **Yandex CDN infrastructure** — a faithful analog of `yandex-speedtest-cli` / `yandex.ru/internet`, with the polished bash-CLI look (box header, spinner, checkmarks, node list, connection info) and a hardened, configurable probe model.

> **Honesty about infrastructure.** The measurement endpoints are Yandex CDN nodes fetched from `https://yandex.ru/internet/api/v0/get-probes` — the same public API the original tool uses. userv.one's own backend / HTTPS-proxy fleet (contract `browser-extension/v1`, `docs/BACKEND_SPEC.md`) is **not deployed yet** (production returns `browser_api_unavailable`), so the tool does not pretend to call live `*.userv.one` probe nodes. When that fleet goes live, point `--config` / `--probes-url` and `--allowed-hosts` at it. No fake endpoints, no invented results.

License: MIT · Dependencies: `curl`, `python3` only (no `bc`, no auto-install, no root).

## Quick Start

```bash
cd userv-speedtest-cli
shasum -a 256 -c SHA256SUMS      # Linux: sha256sum -c SHA256SUMS
bash userv-speedtest.sh --help
bash userv-speedtest.sh          # fetches Yandex probes + measures
```

Short run while evaluating:
```bash
bash userv-speedtest.sh --ping-samples 3 --download-seconds 3 --upload-seconds 3 --payload-bytes 1048576
```

Force the animated spinner even when output is redirected (demos):
```bash
USERV_SPINNER=1 bash userv-speedtest.sh
```

### If you distribute a single-file download
Do **not** pipe remote code into a shell (`curl ... | bash`). Download, verify, inspect, then run:
```bash
curl -fsSLO https://<your-host>/userv-speedtest.sh
curl -fsSLO https://<your-host>/SHA256SUMS
shasum -a 256 -c SHA256SUMS
less userv-speedtest.sh
bash userv-speedtest.sh --validate-config probes.json
```

## What It Measures
- **Download** — up to 8 parallel streams from Yandex CDN `50mb` probes (default 3).
- **Upload** — up to 8 parallel streams POSTing a `/dev/urandom` payload (default 3 × 50 MB).
- **Ping** — HTTP RTT (`time_starttransfer − time_appconnect`), 25% trimmed mean, min / max / jitter.
- **Connection info (opt-in)** — IPv4 / ISP / location via Yandex IP echo + `ipinfo.io`. Off by default: it sends your egress IP to a third party, so it is an explicit flag.

## Example Output (real verified run)
```
  ╔══════════════════════════════════════╗
  ║        userv.one Speed Test CLI      ║
  ║        powered by Yandex CDN        ║
  ╚══════════════════════════════════════╝

  .. Fetching probe servers...
  ✓ Probe servers fetched
  Probe servers: 2 Yandex CDN nodes
    -> cloudcdn-ams-07.cdn.yandex.net
    -> cloudcdn-fra-01.cdn.yandex.net

  (connection info hidden - use --connection-info)

  .. Measuring ping...
  ✓ Ping measured
  .. Testing download speed...
  ✓ Download measured
  .. Testing upload speed...
  ✓ Upload measured

  ────────────────────────────────────────
  Results
  ────────────────────────────────────────

  ↓ Download:  37.81 Mbit/s
  ↑ Upload:    11.65 Mbit/s

  ● Ping:      238.98 ms
    min: 213.05 ms / max: 250.26 ms / jitter: 9.30 ms

  ────────────────────────────────────────
  Server: Yandex CDN | 2026-11-10 15:05:03 +07
```
(Values from a verified short run with reduced durations; yours will differ. In this environment Yandex's IP echo returns a bogon, so `--connection-info` honestly reports `unavailable`.)

## Configuration

Default (no flags) fetches the live Yandex `get-probes` manifest, maps it into the strict internal schema below and validates it — so `mid`/`lid` session tokens are always fresh. `probes.json` is a **snapshot / offline example** generated from that API; its tokens expire, so prefer the default dynamic fetch.

Strict schema (unknown fields are rejected):

| Field | Type | Meaning |
| --- | --- | --- |
| `version` | int | must be `1` |
| `ping` | string[] | 1–8 HTTPS URLs for RTT probes |
| `download` | string[] | 1–8 HTTPS URLs returning a byte stream |
| `upload` | string[] | 1–8 HTTPS URLs accepting `POST` octet-stream |
| `ipEcho` | string | optional HTTPS URL returning a plain IP; `""` disables |

Every URL must be `https`, host inside `--allowed-hosts`, port `443` (or none), no userinfo, no fragment, no control chars, ≤ 2048 chars. Config / raw manifest capped at 64 KiB.

Sources (mutually exclusive):
1. **(default)** Yandex `get-probes` → adapter → strict schema → validate.
2. `--config FILE` / `USERV_CONFIG` — local strict-schema file.
3. `--probes-url URL` / `USERV_PROBES_URL` — remote strict-schema manifest (allow-listed HTTPS, TLS, size limit, no redirects). The fetched body is still fully re-validated.

`probes.example.json` shows the intended `*.userv.one` shape (placeholder hostnames — edit them):
```bash
bash userv-speedtest.sh --validate-config probes.example.json --allowed-hosts '.userv.one'
```

## Flags & Environment
| Flag | Env | Default |
| --- | --- | --- |
| `--config FILE` | `USERV_CONFIG` | (none — dynamic Yandex fetch) |
| `--probes-url URL` | `USERV_PROBES_URL` | (none) |
| `--allowed-hosts LIST` | `USERV_ALLOWED_HOSTS` | `yandex.ru,yandex.net,yandex.st,yandex.com,yastatic.net,cdn.yandex.net,userv.one` |
| `--connection-info` | — | off |
| `--validate-config F` | — | — (offline) |
| `--validate-yandex F` | — | — (offline, raw manifest) |
| `--sanitize` | — | — (output-encoding helper) |
| `--debug` | — | off |
| `--ping-samples N` | `USERV_PING_SAMPLES` | 10 (1–50) |
| `--download-seconds N` | `USERV_DOWNLOAD_SECONDS` | 10 (1–60) |
| `--upload-seconds N` | `USERV_UPLOAD_SECONDS` | 10 (1–60) |
| `--payload-bytes N` | `USERV_PAYLOAD_BYTES` | 52428800 (≤ 104857600) |
| — | `USERV_YANDEX_API` | `https://yandex.ru/internet/api/v0/get-probes` |
| — | `USERV_SPINNER` | (set to `1` to force animation) |
| `-h, --help` | — | — |

All numeric flags are validated as bounded positive integers.

## Dependencies & Install
Only `curl` and `python3` (stdlib only — no pip packages). Missing dependencies are **reported, never auto-installed**; the tool never calls `sudo`, `apt-get`, `yum` or `apk`:
```bash
# Debian / Ubuntu
sudo apt-get install -y curl python3
# RHEL / Fedora / CentOS
sudo dnf install -y curl python3
# Alpine
sudo apk add curl python3
```

## How It Works
1. Fetch the Yandex `get-probes` manifest (TLS, size limit, no redirects, allow-listed URL), or read a local/remote strict-schema config.
2. The Yandex adapter maps `latency` / `download` (filter `50mb`) / `upload` (filter out `timeout`) into the strict schema; **every resulting URL is still validated** — strict field allow-list, ≤ 64 KiB, `https`/443/no-userinfo/allow-list/no-control-chars, IP literals rejected unless public and allow-listed.
3. Resolve each probe host with a 5 s timeout, reject any private / loopback / link-local / reserved answer, and pin curl to a verified public IP via `--resolve` — a DNS-rebinding / SSRF guard. Fails closed.
4. Ping: warm-up plus `PING_SAMPLES` GETs per probe; compute `(time_starttransfer − time_appconnect) × 1000`, 25% trimmed mean + jitter, in Python.
5. Download: N parallel `--max-time` streams, capture `size_download / time_total`.
6. Upload: generate one `/dev/urandom` payload (crypto-secure RNG) and POST it in N parallel streams, capture `size_upload / time_total`.
7. Sum per-stream bytes/sec × 8 → total bit/s, format, print sanitized results, remove the temp dir (`trap ... EXIT`).

TLS verification is always on (`-k` / `--insecure` never used), minimum TLS 1.2, redirects disabled (`--max-redirs 0`), `--proto '=https'`, plus connect/read timeouts and byte caps everywhere. The spinner auto-disables when stdout is not a TTY (clean logs); `USERV_SPINNER=1` forces it.

## Security / Threat model (STRIDE)

Trust boundaries:
```
[operator env / CLI: allowed-hosts, numeric flags, compiled-in Yandex API] = TRUSTED control
[Yandex get-probes body | --probes-url body | --config file | ipEcho / geo reply | curl metrics] = UNTRUSTED -> validated
```

| Flow | Threat | Control | Negative test |
| --- | --- | --- | --- |
| manifest → curl | S / T / A10 SSRF | strict host allow-list, https/443, no userinfo, reject private/loopback/metadata IP literals, DNS resolve + `--resolve` pin, `--max-redirs 0`, `--proto '=https'` | http/file/js scheme, userinfo, 10./127./169.254/8.8.8.8, off-list host, suffix confusion, non-443 port — in both strict-schema and raw-Yandex modes |
| manifest → shell | A03 injection | URLs are separate argv elements, never concatenated into a command; no `eval`; `json.loads` (not `pickle` / `yaml.load`) | backslash / ANSI / newline / wrong-type / malformed JSON |
| network → terminal | A03 output encoding | node names, IP echo and geo fields pass `sanitize` (C0/C1/ESC stripped) before display; egress IP must be a valid global IP before being interpolated into the geo URL | `--sanitize` case |
| manifest → memory | A04 / A05 DoS | 64 KiB cap, ≤ 8 URLs/kind, ≤ 2048 chars/URL, payload cap, timeouts, `--max-filesize`, `--max-time` | oversized / too-many-URLs / empty-probes |
| deps / supply chain | A06 / A08 | no auto-install, no `curl | bash`, checksum verification in docs, fixed schema, no wildcard versions | documented |
| errors / logs | A09 | generic messages; validation errors name the field but never echo URL contents (no secret leakage from query strings) | — |

Applicability of the task's extra rules: **FILES** — the tool accepts no uploads and serves nothing; temp files live under a self-made `mktemp -d` with fixed names, size caps and `trap` cleanup, so there is no user-controlled path, magic-byte or `Content-Disposition` surface. **API** — the tool is a client, not a server; the only inbound bodies are the probes manifests, validated by the strict schema above; there is no auth (public probes), no webhooks and no replay surface. Secrets: none in code, logs, URL or errors (`secret_scan` → 0 findings). RNG: `/dev/urandom`. Cookies / CORS / CSRF / rate-limiting / webhooks: N/A (no HTTP server).

### AppSec review outcome
`security_scan` (directory), `security_review` (script) and `secret_scan` (directory) were run on the final code. **0 critical, 0 high, 0 secrets.** `security_scan`: 37 medium, all heuristic **false positives** — `CFG-006` matches the `http` substring inside `https://` (a `grep 'http://'` finds only the two intentional plain-HTTP negative-test fixtures, and the validator enforces `scheme == https`), `CFG-001` flags the user-facing `--debug` flag which is off by default and prints only sanitized URLs locally, `CRY-005` flags `--tlsv1.2` which sets the *minimum* TLS version to 1.2 (exactly the required control). `security_review`: 3 medium, verdict REVIEW, `blocking_findings: 0`. An earlier high finding (`SEC-008`, a `user:pass@` literal used as an attack fixture) was removed by constructing that fixture at runtime; the negative test remains.

## Tests
```bash
python3 tests/test_validation.py          # 32 negative/positive cases + output-encoding check
bash -n userv-speedtest.sh                # syntax
bash userv-speedtest.sh --validate-config probes.json
bash userv-speedtest.sh --validate-yandex /path/to/raw-get-probes.json
```
Every rejected input above has an assertion that the validator exits non-zero; the valid baseline and a valid raw Yandex manifest must be accepted.

## Supported OS
Linux (Ubuntu/Debian, RHEL/Fedora/CentOS, Alpine) and macOS with bash 3.2+, `curl` and `python3`. On Windows use WSL.

## License
MIT. Original concept: `StealthSurf-VPN/yandex-speedtest-cli` (MIT). Reimplemented independently for userv.one with a secure, configurable probe model and the Yandex CDN measurement backend.
