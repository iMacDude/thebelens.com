#!/bin/bash
# test-local.sh -- exercise the likes Worker against a REAL local runtime
# (wrangler dev --local / miniflare, with real KV emulation). No Cloudflare
# account, no network, nothing deployed.
#
# It tests the FAILURE branches as hard as the success ones, because a check
# that cannot fail is blind -- the house rule that caught a gitleaks hook
# certifying nothing and an alert rule that could never fire.
set -uo pipefail

# Port is overridable: 8787 is the wrangler default and was ALREADY OCCUPIED
# on this Mac by an unrelated service, whose 404s silently stood in for the
# Worker and produced three false PASSes. run-local-tests.sh picks a free one.
PORT="${PORT:-8787}"
BASE="http://127.0.0.1:$PORT/api/likes"
TB="https://thebelens.com"
FOF="https://footprintsoffrank.com"
pass=0; fail=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n       expected %s, got %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

code_is() {
    local label="$1" want="$2"; shift 2
    local got; got=$(curl -s -o /dev/null -w '%{http_code}' "$@")
    [ "$got" = "$want" ] && ok "$label" || no "$label" "$want" "$got"
}
count_is() {
    local label="$1" want="$2"; shift 2
    local got; got=$(curl -s "$@" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
    [ "$got" = "$want" ] && ok "$label" || no "$label" "count=$want" "count=${got:-none}"
}
hdr_is() {   # label  header-name  expected-substring  curl args...
    local label="$1" h="$2" want="$3"; shift 3
    local got; got=$(curl -s -D - -o /dev/null "$@" | tr -d '\r' | grep -i "^$h:" | head -1 | cut -d' ' -f2-)
    case "$got" in *"$want"*) ok "$label" ;; *) no "$label" "$h ~ $want" "${got:-ABSENT}" ;; esac
}

echo "--- happy path, both sites ---"
S="test-post-$RANDOM"
count_is "tb:  GET unknown slug returns 0, not an error" 0 "$BASE/tb/$S"
count_is "tb:  first POST increments to 1"               1 -X POST "$BASE/tb/$S"
count_is "tb:  second POST increments to 2"              2 -X POST "$BASE/tb/$S"
count_is "tb:  GET reads back the written value"         2 "$BASE/tb/$S"
count_is "fof: first POST increments to 1"               1 -X POST "$BASE/fof/$S"

echo "--- THE COLLISION GUARD: same slug, two sites, separate counters ---"
# This is the whole reason the site code is in the path. If these ever share a
# key, two unrelated posts silently merge into one count and it cannot be undone.
count_is "tb  still reads 2 after fof was written"       2 "$BASE/tb/$S"
count_is "fof still reads 1 after tb was written"        1 "$BASE/fof/$S"

echo "--- the cache trap: no-store on EVERY response, including errors ---"
for u in "$BASE/tb/$S" "$BASE/tb/BAD_SLUG" "$BASE/nope/$S" "$BASE/tb/x/y"; do
    hdr_is "no-store on ${u##*/api/likes/}" cache-control no-store "$u"
done

echo "--- CORS, which is what makes Frank's cross-origin site work ---"
# WRANGLER DEV REWRITES THE ROUTED HOSTNAME IN OUTGOING HEADERS, and it is a
# blind string substitution, not a URL-aware one. With the route
# `thebelens.com/api/likes/*` configured, an echoed `https://thebelens.com`
# comes back as `https://127.0.0.1:<port>` -- and `https://www.thebelens.com`
# comes back as the nonsense `https://www.127.0.0.1:<port>`, which is the proof
# it is textual. It happens on the /fof/ path too, so it is keyed on the route's
# zone_name and has nothing to do with this Worker: tb and fof take the
# IDENTICAL code path, which can only ever echo the request's own Origin.
#
# So the expectation here is rewrite-aware rather than relaxed. Accepting any
# ACAO would be the real mistake -- "foreign origin NOT echoed" below is what
# makes this assertion mean something, and a test that cannot fail is blind.
acao_is() {   # label  expected-origin  curl args...
    local label="$1" want="$2"; shift 2
    local got rewritten
    got=$(curl -s -D - -o /dev/null "$@" | tr -d '\r' \
          | grep -i '^access-control-allow-origin:' | head -1 | cut -d' ' -f2- | tr -d ' ')
    rewritten=${want//thebelens.com/127.0.0.1:$PORT}
    if [ "$got" = "$want" ] || [ "$got" = "$rewritten" ]; then
        ok "$label"
    else
        no "$label" "$want (or dev-rewritten $rewritten)" "${got:-ABSENT}"
    fi
}
acao_is "tb  origin echoed back"       "$TB"  -H "Origin: $TB"  "$BASE/tb/$S"
# Frank's origin is NOT the routed zone, so it passes through untouched --
# this is the uncontaminated control for exact-echo behaviour.
acao_is "fof origin echoed back (exact, unrewritten)" "$FOF" -H "Origin: $FOF" "$BASE/fof/$S"
hdr_is "Vary: Origin always present"   vary Origin "$BASE/tb/$S"
code_is "OPTIONS preflight answered"   204 -X OPTIONS -H "Origin: $FOF" "$BASE/fof/$S"
# A foreign origin must NOT be echoed -- that would be an open CORS policy.
foreign=$(curl -s -D - -o /dev/null -H "Origin: https://evil.example" "$BASE/tb/$S" \
          | tr -d '\r' | grep -ci '^access-control-allow-origin:')
[ "$foreign" = "0" ] && ok "foreign origin NOT echoed" || no "foreign origin NOT echoed" "no ACAO header" "present"

echo "--- rejected slugs and sites ---"
code_is "unknown site rejected"           404 "$BASE/zz/$S"
code_is "underscore slug rejected"        400 "$BASE/tb/has_underscore"
code_is "leading dash rejected"           400 "$BASE/tb/-leading"
code_is "space rejected"                  400 "$BASE/tb/has%20space"
code_is "over 80 chars rejected"          400 "$BASE/tb/$(printf 'a%.0s' $(seq 1 81))"
code_is "old 1-segment path is gone"      404 "$BASE/$S"
code_is "empty slug is not our route"     404 "$BASE/tb/"
# Uppercase is NORMALISED, not rejected: the Worker lowercases before it
# validates, so a hand-typed capital still lands on the one canonical key
# instead of silently starting a second counter for the same post.
U="case-test-$RANDOM"
count_is "mixed-case POST accepted (normalised)" 1 -X POST "$BASE/tb/$(printf '%s' "$U" | tr 'a-z' 'A-Z')"
count_is "lower-case GET sees the SAME key"      1 "$BASE/tb/$U"

echo "--- method and route guards ---"
code_is "PUT not allowed"                 405 -X PUT  "$BASE/tb/$S"
code_is "DELETE not allowed"              405 -X DELETE "$BASE/tb/$S"
code_is "unrelated path is 404"           404 "http://127.0.0.1:$PORT/api/other"
code_is "too many segments is 404"        404 "$BASE/tb/a/b"

echo "--- origin guard on POST ---"
code_is "foreign Origin refused"          403 -X POST -H "Origin: https://evil.example" "$BASE/tb/$S"
code_is "tb Origin accepted"              200 -X POST -H "Origin: $TB"  "$BASE/tb/$S"
code_is "fof Origin accepted"             200 -X POST -H "Origin: $FOF" "$BASE/fof/$S"
code_is "no Origin (curl) accepted"       200 -X POST "$BASE/tb/$S"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
