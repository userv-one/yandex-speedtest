#!/usr/bin/env bash
# userv.one Speed Test CLI (Yandex CDN edition)
# Measures link throughput against Yandex CDN probe nodes.
# Probe URLs are untrusted input: validated against a trusted host allow-list,
# restricted to https/443, and pinned to public IPs before any request.
set -euo pipefail

# ---------- trusted, operator-controlled configuration ----------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

YANDEX_API=${USERV_YANDEX_API:-https://yandex.ru/internet/api/v0/get-probes}
CONFIG=${USERV_CONFIG:-}
PROBES_URL=${USERV_PROBES_URL:-}
ALLOWED_HOSTS=${USERV_ALLOWED_HOSTS:-yandex.ru,yandex.net,yandex.st,yandex.com,yastatic.net,cdn.yandex.net,userv.one}
CONNECTION_INFO=false
DEBUG=false
VALIDATE_ONLY=false
VALIDATE_YANDEX=false
SANITIZE_MODE=false

PING_SAMPLES=${USERV_PING_SAMPLES:-10}
DOWNLOAD_SECONDS=${USERV_DOWNLOAD_SECONDS:-10}
UPLOAD_SECONDS=${USERV_UPLOAD_SECONDS:-10}
PAYLOAD_BYTES=${USERV_PAYLOAD_BYTES:-52428800}

MAX_CONFIG_BYTES=65536
MAX_DOWNLOAD_BYTES=209715200
MAX_PAYLOAD_BYTES=104857600

UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36'
REFERER='https://yandex.ru/internet/'
PROBE_PY=
TMPDIR_ST=
SPINNER_PID=
USE_SPINNER=false
RESOLVE_ARGS=()

# ---------- colors ----------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold 2>/dev/null || true)
  DIM=$(tput dim 2>/dev/null || true)
  RED=$(tput setaf 1 2>/dev/null || true)
  GREEN=$(tput setaf 2 2>/dev/null || true)
  YELLOW=$(tput setaf 3 2>/dev/null || true)
  BLUE=$(tput setaf 4 2>/dev/null || true)
  CYAN=$(tput setaf 6 2>/dev/null || true)
  NC=$(tput sgr0 2>/dev/null || true)
  USE_SPINNER=true
else
  BOLD= DIM= RED= GREEN= YELLOW= BLUE= CYAN= NC=
fi
[[ ${USERV_SPINNER:-} == 1 ]] && USE_SPINNER=true

die() { echo "error: $1" >&2; exit 1; }

need_uint() {
  local name=$1 val=$2 max=$3
  [[ $val =~ ^[0-9]+$ ]] || die "$name must be a positive integer"
  (( val >= 1 && val <= max )) || die "$name out of range (1..$max)"
}

usage() {
  cat <<USAGE
userv.one Speed Test CLI (Yandex CDN edition)

Usage: bash userv-speedtest.sh [options]

  (no flags)             Fetch the Yandex get-probes manifest and measure (default)
  --config FILE          Use a local strict-schema probes JSON instead
  --probes-url URL       Fetch a strict-schema manifest from an allow-listed HTTPS URL
  --allowed-hosts LIST   Trusted host allow-list (default: Yandex + userv.one hosts)
  --connection-info      Show IPv4 / ISP / location (opt-in; Yandex IP echo + ipinfo.io)
  --validate-config F    Validate a strict-schema config offline (no network)
  --validate-yandex F    Validate a raw Yandex get-probes manifest offline
  --sanitize             Read stdin, strip control chars, print (output-encoding helper)
  --debug                Verbose per-stream output
  --ping-samples N       Samples per probe (1..50, default 10)
  --download-seconds N   Download duration (1..60, default 10)
  --upload-seconds N     Upload duration (1..60, default 10)
  --payload-bytes N      Upload payload size (1..104857600, default 52428800)
  -h, --help             Show this help

Env: USERV_YANDEX_API, USERV_CONFIG, USERV_PROBES_URL, USERV_ALLOWED_HOSTS,
USERV_PING_SAMPLES, USERV_DOWNLOAD_SECONDS, USERV_UPLOAD_SECONDS,
USERV_PAYLOAD_BYTES, USERV_SPINNER.
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --config) CONFIG=$2; shift 2;;
    --probes-url) PROBES_URL=$2; shift 2;;
    --allowed-hosts) ALLOWED_HOSTS=$2; shift 2;;
    --connection-info) CONNECTION_INFO=true; shift;;
    --validate-config) VALIDATE_ONLY=true; CONFIG=$2; shift 2;;
    --validate-yandex) VALIDATE_YANDEX=true; CONFIG=$2; shift 2;;
    --sanitize) SANITIZE_MODE=true; shift;;
    --debug) DEBUG=true; shift;;
    --ping-samples) PING_SAMPLES=$2; shift 2;;
    --download-seconds) DOWNLOAD_SECONDS=$2; shift 2;;
    --upload-seconds) UPLOAD_SECONDS=$2; shift 2;;
    --payload-bytes) PAYLOAD_BYTES=$2; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "unknown option: $1";;
  esac
done

need_uint ping-samples "$PING_SAMPLES" 50
need_uint download-seconds "$DOWNLOAD_SECONDS" 60
need_uint upload-seconds "$UPLOAD_SECONDS" 60
need_uint payload-bytes "$PAYLOAD_BYTES" "$MAX_PAYLOAD_BYTES"

command -v curl >/dev/null 2>&1 || die 'curl is required; install it with your package manager'
command -v python3 >/dev/null 2>&1 || die 'python3 is required; install it with your package manager'
[[ -n $ALLOWED_HOSTS ]] || die 'no host allow-list configured (USERV_ALLOWED_HOSTS / --allowed-hosts)'

TMPDIR_ST=$(mktemp -d "${TMPDIR:-/tmp}/userv_speedtest.XXXXXX")
PROBE_PY=$TMPDIR_ST/probe.py

cleanup() {
  if [[ -n ${SPINNER_PID:-} ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
  fi
  local p
  for p in $(jobs -p 2>/dev/null); do kill "$p" 2>/dev/null || true; done
  [[ -n $TMPDIR_ST && -d $TMPDIR_ST ]] && rm -rf -- "$TMPDIR_ST"
  return 0
}
trap cleanup EXIT

# ---------- embedded static Python helper (operates on DATA; never execs input) ----------
cat > "$PROBE_PY" <<'PY'
import sys, os, json, ipaddress, socket
from urllib.parse import urlsplit

MAX_CONFIG_BYTES = 65536
MAX_URLS = 8
MAX_URL_LEN = 2048
FIELDS = {'version', 'ping', 'download', 'upload', 'ipEcho'}

class BadInput(Exception):
    pass

def valid_hostname(h):
    if len(h) > 253:
        return False
    try:
        h.encode('ascii')
    except UnicodeEncodeError:
        return False
    for p in h.split('.'):
        if not p or len(p) > 63 or p[0] == '-' or p[-1] == '-':
            return False
        for c in p:
            if not (c.isalnum() or c == '-'):
                return False
    return True

def host_allowed(host, allowed):
    h = host.lower().rstrip('.')
    for a in allowed:
        a = a.lower().lstrip('.')
        if h == a or h.endswith('.' + a):
            return True
    return False

def check_url(raw, allowed, label):
    if not isinstance(raw, str):
        raise BadInput(label + ': URL must be a string')
    if len(raw) > MAX_URL_LEN:
        raise BadInput(label + ': URL too long')
    for c in raw:
        o = ord(c)
        if o < 32 or 127 <= o <= 159 or c == chr(92) or c == ' ':
            raise BadInput(label + ': control char/whitespace/backslash in URL')
    p = urlsplit(raw)
    if p.scheme != 'https':
        raise BadInput(label + ': only https scheme allowed')
    if p.username is not None or p.password is not None or '@' in p.netloc:
        raise BadInput(label + ': credentials in URL forbidden')
    if not p.hostname:
        raise BadInput(label + ': missing host')
    host = p.hostname.lower()
    try:
        port = p.port
    except ValueError:
        raise BadInput(label + ': invalid port')
    if port not in (None, 443):
        raise BadInput(label + ': only port 443 allowed')
    if p.fragment:
        raise BadInput(label + ': fragments not allowed')
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        if not valid_hostname(host):
            raise BadInput(label + ': invalid hostname')
        if not host_allowed(host, allowed):
            raise BadInput(label + ': host not in allow-list')
    else:
        if (not ip.is_global) or ip.is_loopback or ip.is_private or ip.is_link_local or ip.is_reserved or ip.is_multicast:
            raise BadInput(label + ': IP literal is not a permitted public address')
        if not host_allowed(host, allowed):
            raise BadInput(label + ': host not in allow-list')
    return raw

def sanitize_text(text):
    out = []
    for c in text:
        o = ord(c)
        if o < 32 or 127 <= o <= 159:
            continue
        out.append(c)
    return ' '.join(''.join(out).split())

def read_config(allowed):
    data = sys.stdin.buffer.read(MAX_CONFIG_BYTES + 1)
    if len(data) > MAX_CONFIG_BYTES:
        raise BadInput('config exceeds size limit')
    try:
        cfg = json.loads(data.decode('utf-8'))
    except Exception:
        raise BadInput('config is not valid UTF-8 JSON')
    if not isinstance(cfg, dict):
        raise BadInput('config must be a JSON object')
    unknown = set(cfg) - FIELDS
    if unknown:
        raise BadInput('unknown fields: ' + ','.join(sorted(unknown)))
    if cfg.get('version') != 1:
        raise BadInput('version must be 1')
    result = {}
    for kind in ('ping', 'download', 'upload'):
        arr = cfg.get(kind, [])
        if not isinstance(arr, list):
            raise BadInput(kind + ' must be a list')
        if not arr:
            raise BadInput(kind + ' must contain at least one URL')
        if len(arr) > MAX_URLS:
            raise BadInput(kind + ': too many URLs')
        result[kind] = [check_url(u, allowed, kind + '[' + str(i) + ']') for i, u in enumerate(arr)]
    echo = cfg.get('ipEcho')
    if echo is None or echo == '':
        result['ipEcho'] = ''
    else:
        result['ipEcho'] = check_url(echo, allowed, 'ipEcho')
    return result

def cmd_validate(out, allowed_hosts):
    allowed = [a for a in allowed_hosts.split(',') if a]
    cfg = read_config(allowed)
    for kind in ('ping', 'download', 'upload'):
        with open(os.path.join(out, kind + '_urls'), 'w') as f:
            for u in cfg[kind]:
                print(u, file=f)
    with open(os.path.join(out, 'ip_echo'), 'w') as f:
        f.write(cfg['ipEcho'])
    hosts = set()
    for kind in ('ping', 'download', 'upload'):
        for u in cfg[kind]:
            hosts.add(urlsplit(u).hostname.lower())
    if cfg['ipEcho']:
        hosts.add(urlsplit(cfg['ipEcho']).hostname.lower())
    with open(os.path.join(out, 'hosts'), 'w') as f:
        for h in sorted(hosts):
            print(h, file=f)
    print('VALID ' + str(sum(len(cfg[k]) for k in ('ping', 'download', 'upload'))))

def cmd_validate_url(allowed_hosts):
    allowed = [a for a in allowed_hosts.split(',') if a]
    raw = sys.stdin.buffer.read(4096).decode('utf-8').strip()
    check_url(raw, allowed, 'url')
    print(urlsplit(raw).hostname.lower())

def cmd_yandex(raw_path, out):
    data = open(raw_path, 'rb').read(MAX_CONFIG_BYTES + 1)
    if len(data) > MAX_CONFIG_BYTES:
        raise BadInput('yandex manifest exceeds size limit')
    try:
        d = json.loads(data.decode('utf-8'))
    except Exception:
        raise BadInput('yandex manifest is not valid JSON')
    if not isinstance(d, dict):
        raise BadInput('bad yandex manifest')

    def collect(section, pred):
        s = d.get(section)
        if not isinstance(s, dict):
            return []
        arr = s.get('probes')
        if not isinstance(arr, list):
            return []
        found = []
        for p in arr[:32]:
            if not isinstance(p, dict):
                continue
            u = p.get('url')
            if not isinstance(u, str):
                continue
            if pred(u):
                found.append(u)
            if len(found) >= MAX_URLS:
                break
        return found

    cfg = {
        'version': 1,
        'ping': collect('latency', lambda u: True),
        'download': collect('download', lambda u: '50mb' in u),
        'upload': collect('upload', lambda u: 'timeout' not in u),
        'ipEcho': '',
    }
    with open(os.path.join(out, 'yandex_strict.json'), 'w') as f:
        json.dump(cfg, f)
    print('YANDEX')

def _on_alarm(signum, frame):
    raise TimeoutError('dns timeout')

def cmd_resolve(out):
    import signal
    with open(os.path.join(out, 'hosts')) as f:
        hosts = [l.strip() for l in f if l.strip()]
    args = []
    if hasattr(signal, 'SIGALRM'):
        signal.signal(signal.SIGALRM, _on_alarm)
    for h in hosts:
        try:
            if hasattr(signal, 'SIGALRM'):
                signal.setitimer(signal.ITIMER_REAL, 5.0)
            infos = socket.getaddrinfo(h, 443, proto=socket.IPPROTO_TCP)
            ips = []
            for info in infos:
                addr = info[4][0].split('%')[0]
                ip = ipaddress.ip_address(addr)
                if (not ip.is_global) or ip.is_loopback or ip.is_private or ip.is_link_local or ip.is_reserved:
                    raise BadInput(h + ': resolves to a non-public address')
                ips.append(addr)
            pick = next((a for a in ips if ':' not in a), ips[0])
            args.append(h + ':443:' + pick)
        except TimeoutError:
            raise BadInput(h + ': DNS resolution timed out')
        except socket.gaierror:
            raise BadInput(h + ': DNS resolution failed')
        finally:
            if hasattr(signal, 'SIGALRM'):
                signal.setitimer(signal.ITIMER_REAL, 0)
    with open(os.path.join(out, 'resolve_args'), 'w') as f:
        for a in args:
            print(a, file=f)
    print('PINNED ' + str(len(args)))

def cmd_ping(path):
    vals = []
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) != 2:
                continue
            try:
                ts = float(parts[0]); ta = float(parts[1])
            except ValueError:
                continue
            v = (ts - ta) * 1000.0
            if 0 < v < 60000:
                vals.append(v)
    if not vals:
        print('0.00|0.00|0.00|0.00'); return
    vals.sort()
    trim = len(vals) // 4
    t = vals[trim: len(vals) - trim] if trim else vals
    if not t:
        print('0.00|0.00|0.00|0.00'); return
    avg = sum(t) / len(t)
    jit = sum(abs(t[i] - t[i-1]) for i in range(1, len(t))) / (len(t) - 1) if len(t) > 1 else 0.0
    print('%.2f|%.2f|%.2f|%.2f' % (avg, min(t), max(t), jit))

def cmd_speed(paths):
    total = 0.0
    for path in paths:
        try:
            with open(path) as f:
                parts = f.read().split()
            if len(parts) != 2:
                continue
            size = float(parts[0]); t = float(parts[1])
            if t > 0 and size >= 0:
                total += size / t
        except (OSError, ValueError):
            continue
    print('%.2f' % (total * 8.0))

def cmd_fmt(bps):
    b = float(bps)
    if b >= 1e9: print('%.2f Gbit/s' % (b / 1e9))
    elif b >= 1e6: print('%.2f Mbit/s' % (b / 1e6))
    elif b >= 1e3: print('%.2f Kbit/s' % (b / 1e3))
    else: print('%.0f bit/s' % b)

def cmd_check_ip():
    raw = sys.stdin.buffer.read(256).decode('utf-8', 'replace').strip().strip('"').strip()
    try:
        ip = ipaddress.ip_address(raw)
    except ValueError:
        sys.exit(1)
    if (not ip.is_global) or ip.is_loopback or ip.is_private or ip.is_link_local or ip.is_reserved or ip.is_multicast:
        sys.exit(1)
    print(raw)

def cmd_geo():
    data = sys.stdin.buffer.read(8192)
    try:
        d = json.loads(data.decode('utf-8', 'replace'))
    except Exception:
        raise BadInput('bad geo response')
    if not isinstance(d, dict):
        raise BadInput('bad geo response')
    vals = []
    for k in ('city', 'region', 'country', 'org'):
        v = d.get(k, '')
        if v is None:
            v = ''
        vals.append(sanitize_text(str(v)).replace('|', ''))
    print('|'.join(vals))

def cmd_sanitize():
    print(sanitize_text(sys.stdin.buffer.read(4096).decode('utf-8', 'replace')))

def main():
    a = sys.argv[1:]
    if not a:
        print('usage: probe.py <command> ...', file=sys.stderr); sys.exit(2)
    cmd = a[0]
    try:
        if cmd == 'validate': cmd_validate(a[1], a[2])
        elif cmd == 'validate_url': cmd_validate_url(a[1])
        elif cmd == 'yandex': cmd_yandex(a[1], a[2])
        elif cmd == 'resolve': cmd_resolve(a[1])
        elif cmd == 'ping': cmd_ping(a[1])
        elif cmd == 'speed': cmd_speed(a[1:])
        elif cmd == 'fmt': cmd_fmt(a[1])
        elif cmd == 'check_ip': cmd_check_ip()
        elif cmd == 'geo': cmd_geo()
        elif cmd == 'sanitize': cmd_sanitize()
        else: raise BadInput('unknown command')
    except BadInput as e:
        print('config error: ' + str(e), file=sys.stderr); sys.exit(1)
    except SystemExit:
        raise
    except Exception:
        print('internal error', file=sys.stderr); sys.exit(1)

if __name__ == '__main__':
    main()
PY

run_validate() {
  local input=$1
  python3 "$PROBE_PY" validate "$TMPDIR_ST" "$ALLOWED_HOSTS" < "$input" > "$TMPDIR_ST/validate_out" 2> "$TMPDIR_ST/validate_err" || {
    echo 'error: probes config rejected:' >&2
    cat "$TMPDIR_ST/validate_err" >&2
    return 1
  }
  cat "$TMPDIR_ST/validate_out"
}

if $SANITIZE_MODE; then
  python3 "$PROBE_PY" sanitize
  exit 0
fi

if $VALIDATE_ONLY; then
  [[ -f $CONFIG ]] || die "config file not found: $CONFIG"
  run_validate "$CONFIG" || exit 1
  exit 0
fi

if $VALIDATE_YANDEX; then
  [[ -f $CONFIG ]] || die "manifest file not found: $CONFIG"
  python3 "$PROBE_PY" yandex "$CONFIG" "$TMPDIR_ST" >/dev/null 2> "$TMPDIR_ST/yandex_err" || {
    echo 'error: yandex manifest rejected:' >&2; cat "$TMPDIR_ST/yandex_err" >&2; exit 1; }
  run_validate "$TMPDIR_ST/yandex_strict.json" || exit 1
  exit 0
fi

curl_fetch() {
  curl -fsS --proto '=https' --proto-redir '=https' --max-redirs 0 \
    --connect-timeout 5 --max-time 12 --max-filesize "$MAX_CONFIG_BYTES" \
    --tlsv1.2 -H "User-Agent: $UA" -H "Referer: $REFERER" \
    -H 'Accept: application/json' "$@"
}

curl_checked() {
  curl -sS --proto '=https' --proto-redir '=https' --max-redirs 0 \
    --connect-timeout 5 --tlsv1.2 -H "User-Agent: $UA" -H "Referer: $REFERER" \
    "${RESOLVE_ARGS[@]}" "$@"
}

debug() { if $DEBUG; then echo "  [debug] $1" >&2; fi; }

print_header() {
  echo
  echo "  ${BOLD}${CYAN}╔══════════════════════════════════════╗${NC}"
  echo "  ${BOLD}${CYAN}║        userv.one Speed Test CLI      ║${NC}"
  echo "  ${BOLD}${CYAN}║        powered by Yandex CDN        ║${NC}"
  echo "  ${BOLD}${CYAN}╚══════════════════════════════════════╝${NC}"
  echo
}

start_spinner() {
  local msg=$1
  if ! $USE_SPINNER; then echo "  .. $msg"; return; fi
  {
    local chars='|/-\' i=0
    while true; do
      printf '\r  %s%s%s %s ' "$CYAN" "${chars:$i:1}" "$NC" "$msg"
      i=$(( (i + 1) % 4 ))
      sleep 0.1
    done
  } &
  SPINNER_PID=$!
}

stop_spinner() {
  local msg=$1
  if [[ -n ${SPINNER_PID:-} ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=
  fi
  if $USE_SPINNER; then
    printf '\r  %s✓%s %-40s' "$GREEN" "$NC" "$msg"
    echo
  else
    echo "  ${GREEN}✓${NC} $msg"
  fi
}

stop_spinner_fail() {
  local msg=$1
  if [[ -n ${SPINNER_PID:-} ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=
  fi
  if $USE_SPINNER; then
    printf '\r  %s✗%s %-40s' "$RED" "$NC" "$msg"
    echo
  else
    echo "  ${RED}✗${NC} $msg"
  fi
}

obtain_config() {
  local cfg
  if [[ -n $CONFIG ]]; then
    [[ -f $CONFIG ]] || { echo "config file not found: $CONFIG" >&2; return 1; }
    cfg=$CONFIG
  elif [[ -n $PROBES_URL ]]; then
    printf '%s' "$PROBES_URL" | python3 "$PROBE_PY" validate_url "$ALLOWED_HOSTS" >/dev/null 2>&1 || {
      echo 'error: --probes-url rejected by allow-list' >&2; return 1; }
    curl_fetch -o "$TMPDIR_ST/probes_strict.json" "$PROBES_URL" 2>/dev/null || {
      echo 'error: failed to fetch probes manifest (TLS/allow-list/size limit)' >&2; return 1; }
    cfg=$TMPDIR_ST/probes_strict.json
  else
    printf '%s' "$YANDEX_API" | python3 "$PROBE_PY" validate_url "$ALLOWED_HOSTS" >/dev/null 2>&1 || {
      echo 'error: Yandex API URL rejected by allow-list' >&2; return 1; }
    curl_fetch -o "$TMPDIR_ST/yandex_raw.json" "$YANDEX_API" 2>/dev/null || {
      echo 'error: failed to fetch Yandex get-probes manifest' >&2; return 1; }
    python3 "$PROBE_PY" yandex "$TMPDIR_ST/yandex_raw.json" "$TMPDIR_ST" >/dev/null 2> "$TMPDIR_ST/yandex_err" || {
      cat "$TMPDIR_ST/yandex_err" >&2; return 1; }
    cfg=$TMPDIR_ST/yandex_strict.json
  fi

  run_validate "$cfg" >/dev/null || return 1
  cp "$TMPDIR_ST/hosts" "$TMPDIR_ST/probe_hosts"

  if $CONNECTION_INFO; then
    printf '%s\n' 'ipv4-internet.yandex.net' 'ipinfo.io' >> "$TMPDIR_ST/hosts"
    sort -u -o "$TMPDIR_ST/hosts" "$TMPDIR_ST/hosts"
  fi

  python3 "$PROBE_PY" resolve "$TMPDIR_ST" >/dev/null 2> "$TMPDIR_ST/resolve_err" || {
    cat "$TMPDIR_ST/resolve_err" >&2; return 1; }

  local n
  n=$(wc -l < "$TMPDIR_ST/probe_hosts" | tr -d ' ')
  echo "  ${DIM}Probe servers: ${n} Yandex CDN nodes${NC}"
  while IFS= read -r h; do
    [[ -z $h ]] && continue
    echo "  ${DIM}  -> $(printf '%s' "$h" | python3 "$PROBE_PY" sanitize)${NC}"
  done < "$TMPDIR_ST/probe_hosts"
  echo
}

get_connection_info() {
  local ipurl='https://ipv4-internet.yandex.net/api/v0/ip'
  printf '%s' "$ipurl" | python3 "$PROBE_PY" validate_url 'ipv4-internet.yandex.net,yandex.net' >/dev/null 2>&1 || {
    echo '  (connection info unavailable)'; return; }
  local raw ip geourl geo city region country org loc
  raw=$(curl_checked --max-time 5 "$ipurl" 2>/dev/null) || true
  ip=$(printf '%s' "$raw" | python3 "$PROBE_PY" check_ip 2>/dev/null) || ip=''
  echo "  ${DIM}----------------------------------------${NC}"
  echo "  ${BOLD}Connection Info${NC}"
  echo "  ${DIM}----------------------------------------${NC}"
  if [[ -z $ip ]]; then
    echo "  ${DIM}IPv4:${NC}      unavailable (bogon / filtered)"
    echo
    return
  fi
  echo "  ${DIM}IPv4:${NC}      $ip"
  geourl="https://ipinfo.io/${ip}/json"
  if printf '%s' "$geourl" | python3 "$PROBE_PY" validate_url 'ipinfo.io' >/dev/null 2>&1; then
    geo=$(curl_checked --max-time 5 "$geourl" 2>/dev/null | python3 "$PROBE_PY" geo 2>/dev/null) || geo=''
    IFS='|' read -r city region country org <<< "${geo:-|||}"
    [[ -n $org ]] && echo "  ${DIM}ISP:${NC}       $org"
    loc=$city
    [[ -n $region ]] && loc="$loc, $region"
    [[ -n $country ]] && loc="$loc, $country"
    [[ -n $loc ]] && echo "  ${DIM}Location:${NC}  $loc"
  fi
  echo
}

measure_ping() {
  : > "$TMPDIR_ST/ping_samples"
  while IFS= read -r url; do
    [[ -z $url ]] && continue
    curl_checked -o /dev/null --max-time 5 "$url" >/dev/null 2>&1 || true
    for ((i=1; i<=PING_SAMPLES; i++)); do
      w=$(curl_checked -o /dev/null -w '%{time_starttransfer} %{time_appconnect}' --max-time 5 "$url" 2>/dev/null) || true
      echo "$w" >> "$TMPDIR_ST/ping_samples"
    done
    debug "ping probe: $(printf '%s' "$url" | python3 "$PROBE_PY" sanitize)"
  done < "$TMPDIR_ST/ping_urls"
  python3 "$PROBE_PY" ping "$TMPDIR_ST/ping_samples"
}

download_stream() {
  local url=$1 out=$2 dur=$3 w
  w=$(curl_checked -o /dev/null -w '%{size_download} %{time_total}' \
        --max-time "$dur" --max-filesize "$MAX_DOWNLOAD_BYTES" "$url" 2>/dev/null) || true
  echo "$w" > "$out"
}

measure_download() {
  local idx=0 pids=()
  while IFS= read -r url; do
    [[ -z $url ]] && continue
    idx=$((idx + 1))
    debug "download stream $idx: $(printf '%s' "$url" | python3 "$PROBE_PY" sanitize)"
    download_stream "$url" "$TMPDIR_ST/dlspeed_$idx" "$DOWNLOAD_SECONDS" &
    pids+=($!)
  done < "$TMPDIR_ST/download_urls"
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  python3 "$PROBE_PY" speed "$TMPDIR_ST"/dlspeed_*
}

upload_stream() {
  local url=$1 out=$2 payload=$3 dur=$4 w
  w=$(curl_checked -X POST --data-binary @"$payload" -o /dev/null \
        -w '%{size_upload} %{time_total}' --max-time "$dur" \
        -H 'Content-Type: application/octet-stream' "$url" 2>/dev/null) || true
  echo "$w" > "$out"
}

measure_upload() {
  head -c "$PAYLOAD_BYTES" /dev/urandom > "$TMPDIR_ST/upload_payload"
  local idx=0 pids=()
  while IFS= read -r url; do
    [[ -z $url ]] && continue
    idx=$((idx + 1))
    debug "upload stream $idx: $(printf '%s' "$url" | python3 "$PROBE_PY" sanitize)"
    upload_stream "$url" "$TMPDIR_ST/ulspeed_$idx" "$TMPDIR_ST/upload_payload" "$UPLOAD_SECONDS" &
    pids+=($!)
  done < "$TMPDIR_ST/upload_urls"
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  python3 "$PROBE_PY" speed "$TMPDIR_ST"/ulspeed_*
}

print_results() {
  local ping_data=$1 dl=$2 ul=$3 avg mn mx jit dlf ulf
  IFS='|' read -r avg mn mx jit <<< "$ping_data"
  dlf=$(python3 "$PROBE_PY" fmt "$dl")
  ulf=$(python3 "$PROBE_PY" fmt "$ul")
  echo "  ${DIM}────────────────────────────────────────${NC}"
  echo "  ${BOLD}Results${NC}"
  echo "  ${DIM}────────────────────────────────────────${NC}"
  echo
  echo "  ${GREEN}↓${NC} ${BOLD}Download:${NC}  $dlf"
  echo "  ${BLUE}↑${NC} ${BOLD}Upload:${NC}    $ulf"
  echo
  echo "  ${YELLOW}●${NC} ${BOLD}Ping:${NC}      ${avg} ms"
  echo "    ${DIM}min: ${mn} ms / max: ${mx} ms / jitter: ${jit} ms${NC}"
  echo
  echo "  ${DIM}────────────────────────────────────────${NC}"
  echo "  ${DIM}Server: Yandex CDN | $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
  echo
}

main() {
  print_header

  start_spinner 'Fetching probe servers...'
  if ! obtain_config > "$TMPDIR_ST/fetch_out" 2> "$TMPDIR_ST/fetch_err"; then
    stop_spinner_fail 'Probe servers fetch failed'
    cat "$TMPDIR_ST/fetch_err" >&2
    exit 1
  fi
  stop_spinner 'Probe servers fetched'
  cat "$TMPDIR_ST/fetch_out"

  while IFS= read -r line; do
    [[ -n $line ]] && RESOLVE_ARGS+=(--resolve "$line")
  done < "$TMPDIR_ST/resolve_args"

  if $CONNECTION_INFO; then
    start_spinner 'Getting connection info...'
    get_connection_info > "$TMPDIR_ST/conn_out" 2>/dev/null
    stop_spinner 'Connection info received'
    cat "$TMPDIR_ST/conn_out"
  else
    echo "  ${DIM}(connection info hidden - use --connection-info)${NC}"
    echo
  fi

  start_spinner 'Measuring ping...'
  ping_data=$(measure_ping)
  stop_spinner 'Ping measured'

  start_spinner 'Testing download speed...'
  dl=$(measure_download)
  stop_spinner 'Download measured'

  start_spinner 'Testing upload speed...'
  ul=$(measure_upload)
  stop_spinner 'Upload measured'

  echo
  print_results "$ping_data" "$dl" "$ul"
}

main
