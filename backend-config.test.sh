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

# One plain stub, one TLS stub, and three hostile ones: a redirector, the host it
# redirects to, and a server that answers with more bytes than any real reply.
# The TLS cert is self-signed for 127.0.0.1 and trusted through SSL_CERT_FILE,
# so the public-address path runs over real HTTPS rather than being faked.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
export SSL_CERT_FILE="$WORK/cert.pem" STUB_CERT="$WORK/cert.pem" STUB_CERTKEY="$WORK/key.pem"
TLS_PORT=$((PORT + 10)); REDIR_PORT=$((PORT + 11)); CATCH_PORT=$((PORT + 12)); BIG_PORT=$((PORT + 13))
export TLS_PORT REDIR_PORT CATCH_PORT BIG_PORT CATCH_LOG="$WORK/caught-key.txt"

python3 - <<'PY' &
import http.server, json, os, ssl, threading
KEY = os.environ["STUB_KEY"]; LOG = os.environ["STUB_LOG"]; CATCH_LOG = os.environ["CATCH_LOG"]


def reply(h, code, body):
    h.send_response(code)
    h.send_header("Content-Type", "application/json")
    h.send_header("Content-Length", str(len(body)))
    h.end_headers()
    h.wfile.write(body)


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        got = self.headers.get("X-Api-Key", "")
        with open(LOG, "w") as f:
            f.write(got)
        reply(self, 200 if got == KEY else 401, json.dumps({"pending": 0}).encode())

    def do_POST(self):
        got = self.headers.get("X-Api-Key", "")
        with open(LOG, "w") as f:
            f.write(got)
        ok = got == KEY and self.path.startswith("/api/v1/request/")
        reply(self, 200 if ok else 401, json.dumps({"id": 7}).encode())

    def log_message(self, *a):
        pass


class Redirect(H):
    def _go(self):
        self.send_response(302)
        self.send_header("Location", "http://127.0.0.1:%s%s" % (os.environ["CATCH_PORT"], self.path))
        self.send_header("Content-Length", "0")
        self.end_headers()
    do_GET = do_POST = _go


class Catch(H):
    def _got(self):
        with open(CATCH_LOG, "w") as f:
            f.write(self.headers.get("X-Api-Key", ""))
        reply(self, 200, json.dumps({"pending": 0, "id": 7}).encode())
    do_GET = do_POST = _got


class Big(H):
    def do_GET(self):
        reply(self, 200, b'{"pending": 0, "pad": "' + b"x" * (5 * 1024 * 1024) + b'"}')


def serve(port, handler, tls=False):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), handler)
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(os.environ["STUB_CERT"], os.environ["STUB_CERTKEY"])
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()


serve(os.environ["STUB_PORT"], H)
serve(os.environ["TLS_PORT"], H, tls=True)
serve(os.environ["REDIR_PORT"], Redirect)
serve(os.environ["CATCH_PORT"], Catch)
serve(os.environ["BIG_PORT"], Big)
threading.Event().wait()
PY
STUB_PID=$!

for p in "$PORT" "$TLS_PORT" "$REDIR_PORT" "$CATCH_PORT" "$BIG_PORT"; do
  for _ in $(seq 30); do
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && break
    read -r -t 0.1 < /dev/zero 2>/dev/null || true
  done
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
UT="https://127.0.0.1:$TLS_PORT"    # the public address must be HTTPS
UR="http://127.0.0.1:$REDIR_PORT"
UB="http://127.0.0.1:$BIG_PORT"

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
run "LAN dead, public_url answers" '"endpoint": "public"' "{\"url\":\"$DEAD\",\"api_key\":\"$GOOD_KEY\",\"public_url\":\"$UT\"}"
if grep -q '"which": *"public"' "$ENDPOINT" 2>/dev/null; then
  pass=$((pass + 1)); echo "  ok    the public choice is remembered for the next poll"
else
  fail=$((fail + 1)); echo "  FAIL  endpoint.json does not record the public choice: $(cat "$ENDPOINT" 2>/dev/null)"
fi
run "an action follows the same fallback" '"ok":true,"id":7,"action":"approve"' "{\"url\":\"$DEAD\",\"api_key\":\"$GOOD_KEY\",\"public_url\":\"$UT\"}" approve 7
rm -f "$ENDPOINT"
run "public_url defaults to web_base" '"endpoint": "public"' "{\"url\":\"$DEAD\",\"api_key\":\"$GOOD_KEY\",\"web_base\":\"$UT\"}"
rm -f "$ENDPOINT"
run "LAN alive is reported as lan"  '"endpoint": "lan"' "{\"url\":\"$U\",\"api_key\":\"$GOOD_KEY\",\"public_url\":\"$DEAD\"}"
run "no public_url: LAN dead is still unreachable" '"error": "unreachable"' "{\"url\":\"$DEAD\",\"api_key\":\"$GOOD_KEY\"}"
# A wrong key must never fail over: retrying bad credentials against a public
# edge is how you get banned by your own rate limiter.
run "a wrong key does not fail over" '"error": "auth failed"' "{\"url\":\"$U\",\"api_key\":\"nope\",\"public_url\":\"$DEAD\"}"

# Marketplace review (2026-09-11): the key must never follow a redirect, never
# travel to a public address over plain HTTP, and a reply is capped in size
# before it is parsed.
echo "public address safety:"
rm -f "$ENDPOINT"
run "an http:// public_url is refused" '"error": "public_url must be https"' "{\"url\":\"$DEAD\",\"api_key\":\"$GOOD_KEY\",\"public_url\":\"$U\"}"
if [ ! -e "$WORK/seen-key.txt" ]; then
  pass=$((pass + 1)); echo "  ok    the key was never sent to the plain-HTTP public address"
else
  fail=$((fail + 1)); echo "  FAIL  the key reached a plain-HTTP public address"
fi
rm -f "$ENDPOINT" "$CATCH_LOG"
run "a redirect is refused, not followed" '"error": "http 302"' "{\"url\":\"$UR\",\"api_key\":\"$GOOD_KEY\"}"
run "an action refuses a redirect too" '"error":"http 302"' "{\"url\":\"$UR\",\"api_key\":\"$GOOD_KEY\"}" approve 7
if [ ! -e "$CATCH_LOG" ]; then
  pass=$((pass + 1)); echo "  ok    the redirect target never received the key"
else
  fail=$((fail + 1)); echo "  FAIL  the redirect target received the key: '$(cat "$CATCH_LOG")'"
fi
rm -f "$ENDPOINT"
run "an oversized response is refused" '"error": "response too large"' "{\"url\":\"$UB\",\"api_key\":\"$GOOD_KEY\"}"

echo
if [ "$fail" -eq 0 ]; then
  echo "backend config: all $pass assertions passed"
else
  echo "backend config: $fail of $((pass + fail)) failed"
fi
[ "$fail" -eq 0 ]
