#!/usr/bin/env bash
# Seerr pending-request queue -> one compact JSON line on stdout.
#
# The ONLY thing in this plugin that talks to Seerr. Kept as a script, not QML,
# so it can be run and diffed over SSH — the widget itself can only be checked by
# eye on the owner's screen.
#
#   backend.sh                    poll; print state, update seen-set, no toasts
#   backend.sh --notify           same, and notify-send anything newly pending
#   backend.sh approve <id>       approve one request
#   backend.sh decline <id>       decline one request
#
#   {"ok":true,"pending":2,"requests":[{...}]}
#   {"ok":false,"error":"not configured","pending":0,"requests":[]}   and a non-zero exit
#
# Config: ~/.config/omarchy-seerr/config.json
#   {"url":"http://host:5056","api_key":"...","web_base":"https://js.example.com"}
set -uo pipefail

CFG="${OMARCHY_SEERR_CONFIG:-$HOME/.config/omarchy-seerr/config.json}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { printf '{"ok":false,"error":"%s","pending":0,"requests":[]}\n' "$1"; exit 1; }

[ -r "$CFG" ] || fail "not configured"

# web_base is the address for BROWSER links; url stays the API endpoint. Separating
# them keeps polling on the fast LAN path instead of crossing the public edge, while
# a click still opens somewhere reachable away from home. Falls back to url when unset.
#
# One field per line, and read one at a time. A space-separated `read -r A B C`
# collapses runs of whitespace, so an empty middle field silently shifts the rest
# along: a config missing `api_key` used to put web_base in its place, pass the
# non-empty guard, and report "auth failed" — sending the reader after a
# credential problem that did not exist. None of these values may contain a
# newline, so line-delimiting is unambiguous.
FIELDS=$(python3 - "$CFG" <<'PY'
import json, sys
try:
    c = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if not isinstance(c, dict):
    sys.exit(1)
url = str(c.get("url") or "").strip().rstrip("/")
# Stripped because an API key pasted from a web UI often carries a trailing
# newline or space, which the server rejects as an invalid key.
api_key = str(c.get("api_key") or "").strip()
web_base = (str(c.get("web_base") or "").strip().rstrip("/")) or url
print(url)
print(api_key)
print(web_base)
PY
) || fail "bad config"

{ IFS= read -r URL; IFS= read -r API_KEY; IFS= read -r WEB_BASE; } <<<"$FIELDS"

# Guarded individually, so a missing field is reported as the config error it is.
[ -n "${URL:-}" ] || fail "bad config"
[ -n "${API_KEY:-}" ] || fail "bad config"

# ---- actions -----------------------------------------------------------------
# Approve/decline are a single POST each, so they stay in bash where curl lives.
# Polling is many correlated requests plus two caches, so it lives in poll.py.
act() {
  local verb="$1" id="$2"
  case "$id" in
    ''|*[!0-9]*) printf '{"ok":false,"error":"bad request id"}\n'; exit 1 ;;
  esac

  local body code
  body=$(curl -s -m 10 -w $'\n%{http_code}' -X POST \
    -H "X-Api-Key: $API_KEY" -H "Content-Type: application/json" \
    "$URL/api/v1/request/$id/$verb" 2>/dev/null) \
    || { printf '{"ok":false,"error":"unreachable"}\n'; exit 1; }

  code=$(printf '%s' "$body" | tail -n1)
  case "$code" in
    200|201|202) printf '{"ok":true,"id":%s,"action":"%s"}\n' "$id" "$verb" ;;
    401|403) printf '{"ok":false,"error":"auth failed"}\n'; exit 1 ;;
    404) printf '{"ok":false,"error":"request %s is gone"}\n' "$id"; exit 1 ;;
    000|"") printf '{"ok":false,"error":"unreachable"}\n'; exit 1 ;;
    *) printf '{"ok":false,"error":"http %s"}\n' "$code"; exit 1 ;;
  esac
}

case "${1:-poll}" in
  approve) act approve "${2:-}" ;;
  decline) act decline "${2:-}" ;;
  poll|--notify)
    NOTIFY=0
    [ "${1:-}" = "--notify" ] && NOTIFY=1
    SEERR_URL="$URL" SEERR_API_KEY="$API_KEY" SEERR_WEB_BASE="$WEB_BASE" SEERR_NOTIFY="$NOTIFY" \
      python3 "$DIR/poll.py"
    ;;
  *) fail "unknown command" ;;
esac
