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

run() { # name, expected-substring, config-json ("" means no config file at all)
  local name="$1" want="$2" cfg="$3" out
  rm -f "$WORK/seen-key.txt"
  if [ -z "$cfg" ]; then rm -f "$WORK/config.json"; else printf '%s' "$cfg" >"$WORK/config.json"; fi
  out=$(OMARCHY_SEERR_CONFIG="$WORK/config.json" "$PLUGIN/backend.sh" 2>&1)
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

echo
if [ "$fail" -eq 0 ]; then
  echo "backend config: all $pass assertions passed"
else
  echo "backend config: $fail of $((pass + fail)) failed"
fi
[ "$fail" -eq 0 ]
