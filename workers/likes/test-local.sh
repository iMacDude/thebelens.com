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
pass=0; fail=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n       expected %s, got %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

# $1 label  $2 expected-code  $3.. curl args
code_is() {
    local label="$1" want="$2"; shift 2
    local got; got=$(curl -s -o /dev/null -w '%{http_code}' "$@")
    [ "$got" = "$want" ] && ok "$label" || no "$label" "$want" "$got"
}
# $1 label  $2 expected-count  $3.. curl args
count_is() {
    local label="$1" want="$2"; shift 2
    local got; got=$(curl -s "$@" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
    [ "$got" = "$want" ] && ok "$label" || no "$label" "count=$want" "count=${got:-none}"
}

echo "--- happy path ---"
S="test-post-$RANDOM"
count_is "GET on an unknown slug returns 0, not an error" 0 "$BASE/$S"
count_is "first POST increments to 1"                     1 -X POST "$BASE/$S"
count_is "second POST increments to 2"                    2 -X POST "$BASE/$S"
count_is "GET reads back the written value"               2 "$BASE/$S"

echo "--- the cache trap: no-store on EVERY response, including errors ---"
for u in "$BASE/$S" "$BASE/BAD_SLUG" "$BASE/x/y/z"; do
    h=$(curl -s -D - -o /dev/null "$u" | tr -d '\r' | grep -i '^cache-control:' | head -1)
    case "$h" in
        *no-store*) ok "no-store present on $(basename "$u")" ;;
        *) no "no-store on $(basename "$u")" "cache-control: no-store" "${h:-ABSENT}" ;;
    esac
done

echo "--- rejected slugs (unchecked slugs would let anyone fill KV) ---"
# Uppercase is NORMALISED, not rejected: the Worker lowercases before it
# validates, so a hand-typed or copy-pasted capital still lands on the one
# canonical key instead of silently starting a second counter for the same
# post. That shared-key behaviour is the part worth asserting -- the status
# code alone would not have caught a regression that split the two.
U="case-test-$RANDOM"
count_is "mixed-case POST accepted (normalised)" 1 -X POST "$BASE/$(printf '%s' "$U" | tr 'a-z' 'A-Z')"
count_is "lower-case GET sees the SAME key"      1 "$BASE/$U"
code_is "underscore rejected"             400 "$BASE/has_underscore"
code_is "leading dash rejected"           400 "$BASE/-leading"
code_is "space rejected"                  400 "$BASE/has%20space"
code_is "over 80 chars rejected"          400 "$BASE/$(printf 'a%.0s' $(seq 1 81))"
code_is "empty slug is not our route"     404 "$BASE/"

echo "--- method and route guards ---"
code_is "PUT not allowed"                 405 -X PUT  "$BASE/$S"
code_is "DELETE not allowed"              405 -X DELETE "$BASE/$S"
code_is "unrelated path is 404"           404 "http://127.0.0.1:$PORT/api/other"
code_is "nested path is 404"              404 "$BASE/a/b"

echo "--- origin guard on POST ---"
code_is "foreign Origin refused"          403 -X POST -H "Origin: https://evil.example" "$BASE/$S"
code_is "own Origin accepted"             200 -X POST -H "Origin: https://thebelens.com" "$BASE/$S"
code_is "no Origin (curl) accepted"       200 -X POST "$BASE/$S"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
