#!/usr/bin/env bash
# Config parsing and credential handling for backend.sh.
#
#   bash backend-config.test.sh
#
# Runs against a stub Seerr on localhost, so it needs no real server and no
# credentials. The stub records the X-Api-Key it was sent, which is the only way
# to prove the key reaching the wire is the key in the config file -- the bug
# this suite exists for sent a *different field's value* as the key and got a
# plausible-looking "auth failed" back.
set -u

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'kill ${STUB_PID:-} 2>/dev/null; rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"   # keep the poll's seen-set out of the real one

PORT="${SEERR_TEST_PORT:-8791}"
GOOD_KEY="realkey-abcdef0123456789"
export STUB_KEY="$GOOD_KEY" STUB_LOG="$WORK/seen-key.txt" STUB_PORT="$PORT"

python3 - <<'PY' &
import http.server, json, os
KEY = os.environ["STUB_KEY"]; LOG = os.environ["STUB_LOG"]


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        got = self.headers.get("X-Api-Key", "")
        with open(LOG, "w") as f:
            f.write(got)
        body = json.dumps({"pending": 0}).encode()
        self.send_response(200 if got == KEY else 401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        got = self.headers.get("X-Api-Key", "")
        with open(LOG, "w") as f:
            f.write(got)
        ok = got == KEY and self.path.startswith("/api/v1/request/")
        body = json.dumps({"id": 7}).encode()
        self.send_response(200 if ok else 401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", int(os.environ["STUB_PORT"])), H).serve_forever()
PY
STUB_PID=$!

for _ in $(seq 30); do
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break
  read -r -t 0.1 < /dev/zero 2>/dev/null || true
done

pass=0
fail=0

run() { # name, expected-substring, config-json ("" means no config file at all), [backend args...]
  local name="$1" want="$2" cfg="$3" out
  shift 3
  rm -f "$WORK/seen-key.txt"
  if [ -z "$cfg" ]; then rm -f "$WORK/config.json"; else printf '%s' "$cfg" >"$WORK/config.json"; fi
  out=$(OMARCHY_SEERR_CONFIG="$WORK/config.json" "$PLUGIN/backend.sh" "$@" 2>&1)
  if [[ "$out" == *"$want"* ]]; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL  %s\n        want %s\n        got  %s\n' "$name" "$want" "$out"
  fi
}

U="http://127.0.0.1:$PORT"

echo "config errors are reported as config errors:"
run "missing file"           '"error":"not configured"' ""
run "unparseable JSON"       '"error":"bad config"'     '{"url": '
run "not a JSON object"      '"error":"bad config"'     '["url","key"]'
# The regression. An absent api_key once collapsed the field split and put
# web_base in the key's place, which the server rejected as "auth failed".
run "api_key absent"         '"error":"bad config"'     "{\"url\":\"$U\",\"web_base\":\"https://web.example\"}"
run "api_key empty"          '"error":"bad config"'     "{\"url\":\"$U\",\"api_key\":\"\",\"web_base\":\"https://web.example\"}"
run "api_key null"           '"error":"bad config"'     "{\"url\":\"$U\",\"api_key\":null,\"web_base\":\"https://web.example\"}"
run "url absent"             '"error":"bad config"'     "{\"api_key\":\"$GOOD_KEY\"}"
run "url empty"              '"error":"bad config"'     "{\"url\":\"\",\"api_key\":\"$GOOD_KEY\"}"

echo "credentials:"
run "a wrong key is still an auth failure" '"error": "auth failed"' "{\"url\":\"$U\",\"api_key\":\"nope\"}"
run "valid config polls"     '"ok": true' "{\"url\":\"$U\",\"api_key\":\"$GOOD_KEY\",\"web_base\":\"https://web.example\"}"
if [ "$(cat "$WORK/seen-key.txt" 2>/dev/null)" = "$GOOD_KEY" ]; then
  pass=$((pass + 1)); echo "  ok    the key on the wire is the key in the file"
else
  fail=$((fail + 1)); echo "  FAIL  sent '$(cat "$WORK/seen-key.txt" 2>/dev/null)' instead of the configured key"
fi
run "key pasted with stray whitespace" '"ok": true' "{\"url\":\"$U\",\"api_key\":\"  $GOOD_KEY \\n\"}"
run "web_base absent falls back to url" '"ok": true' "{\"url\":\"$U\",\"api_key\":\"$GOOD_KEY\"}"
run "trailing slash on url"  '"ok": true' "{\"url\":\"$U/\",\"api_key\":\"$GOOD_KEY\"}"

# Nothing listens on port 1, so the LAN address fails fast and deterministically.
DEAD="http://127.0.0.1:1"
ENDPOINT="$WORK/state/omarchy-seerr/endpoint.json"

echo "endpoint fallback:"
rm -f "$ENDPOINT"
run "LAN dead, public_url answers" '"endpoint": "public"' "{\"url\":\"$DEAD\",\"api_key\":\"$GOOD_KEY\",\"public_url\":\"$U\"}"
if grep -q '"which": *"public"' "$ENDPOINT" 2>/dev/null; then
  pass=$((pass + 1)); echo "  ok    the public choice is remembered for the next poll"
else
  fail=$((fail + 1)); echo "  FAIL  endpoint.json does not record the public choice: $(cat "$ENDPOINT" 2>/dev/null)"
fi
run "an action follows the same fallback" '"ok":true,"id":7,"action":"approve"' "{\"url\":\"$DEAD\",\"api_key\":\"$GOOD_KEY\",\"public_url\":\"$U\"}" approve 7
rm -f "$ENDPOINT"
run "public_url defaults to web_base" '"endpoint": "public"' "{\"url\":\"$DEAD\",\"api_key\":\"$GOOD_KEY\",\"web_base\":\"$U\"}"
rm -f "$ENDPOINT"
run "LAN alive is reported as lan"  '"endpoint": "lan"' "{\"url\":\"$U\",\"api_key\":\"$GOOD_KEY\",\"public_url\":\"$DEAD\"}"
run "no public_url: LAN dead is still unreachable" '"error": "unreachable"' "{\"url\":\"$DEAD\",\"api_key\":\"$GOOD_KEY\"}"
# A wrong key must never fail over: retrying bad credentials against a public
# edge is how you get banned by your own rate limiter.
run "a wrong key does not fail over" '"error": "auth failed"' "{\"url\":\"$U\",\"api_key\":\"nope\",\"public_url\":\"$DEAD\"}"

echo
if [ "$fail" -eq 0 ]; then
  echo "backend config: all $pass assertions passed"
else
  echo "backend config: $fail of $((pass + fail)) failed"
fi
[ "$fail" -eq 0 ]
