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
#   {"ok":true,"pending":2,"requests":[{...}],"endpoint":"lan"}
#   {"ok":false,"error":"not configured","pending":0,"requests":[]}   and a non-zero exit
#
# Config: ~/.config/omarchy-seerr/config.json
#   {"url":"http://host:5056","api_key":"...","web_base":"https://js.example.com",
#    "public_url":"https://js.example.com"}
set -uo pipefail

CFG="${OMARCHY_SEERR_CONFIG:-$HOME/.config/omarchy-seerr/config.json}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { printf '{"ok":false,"error":"%s","pending":0,"requests":[]}\n' "$1"; exit 1; }

[ -r "$CFG" ] || fail "not configured"

# web_base is the address for BROWSER links; url stays the API endpoint. Separating
# them keeps polling on the fast LAN path instead of crossing the public edge, while
# a click still opens somewhere reachable away from home. Falls back to url when unset.
#
# public_url is the API address tried only when url is unreachable, so the widget
# keeps working away from home. It defaults to web_base: the public web UI is the
# same Seerr, and it serves the API too. Set it to "" to never leave the LAN.
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
if "public_url" in c:
    public_url = str(c.get("public_url") or "").strip().rstrip("/")
else:
    public_url = web_base
if public_url == url:
    public_url = ""   # the same address twice is not a fallback
print(url)
print(api_key)
print(web_base)
print(public_url)
PY
) || fail "bad config"

{ IFS= read -r URL; IFS= read -r API_KEY; IFS= read -r WEB_BASE; IFS= read -r PUBLIC_URL; } <<<"$FIELDS"

# Guarded individually, so a missing field is reported as the config error it is.
[ -n "${URL:-}" ] || fail "bad config"
[ -n "${API_KEY:-}" ] || fail "bad config"

# ---- dispatch ----------------------------------------------------------------
# Polling and the approve/decline POSTs all go through poll.py, so an action
# taken away from home follows the same LAN-then-public choice as the poll that
# showed the request. Credentials travel in the environment, never in argv.
run_py() {
  SEERR_URL="$URL" SEERR_PUBLIC_URL="$PUBLIC_URL" SEERR_API_KEY="$API_KEY" \
    SEERR_WEB_BASE="$WEB_BASE" SEERR_NOTIFY="${NOTIFY:-0}" \
    python3 "$DIR/poll.py" "$@"
}

case "${1:-poll}" in
  approve|decline) run_py "$1" "${2:-}" ;;
  poll) run_py ;;
  --notify) NOTIFY=1 run_py ;;
  *) fail "unknown command" ;;
esac
