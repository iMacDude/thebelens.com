#!/bin/bash
# NOT #!/usr/bin/env bash -- house rule, see home-networking/CLAUDE.md on TCC
# attribution. Harmless here; every script follows it so nobody has to remember
# which ones are exempt.
#
# deploy.sh -- create the KV namespace if needed, deploy the Worker, then PROVE
# it works against the live URL.
#
# CREDENTIALS. There are deliberately none in this repo, which is PUBLIC. Two
# supported paths, in order of preference:
#
#   1. A SCOPED API TOKEN in ~/.config/homelab/cloudflare.env (chmod 600):
#        CLOUDFLARE_ACCOUNT_ID=...
#        CLOUDFLARE_API_TOKEN=...
#        LIKES_KV_ID=...            # printed once, at namespace creation
#      Token needs: Account > Workers Scripts:Edit, Account > Workers KV
#      Storage:Edit, Zone > Workers Routes:Edit, Zone > Zone:Read (thebelens.com).
#      This matches how the homelab holds every other secret -- a 600 file
#      outside the repo -- and it can be revoked without touching anything else.
#
#   2. `npx wrangler login` (browser OAuth). Simpler, but it grants everything
#      the account can do rather than those four permissions.
#
# The token never reaches argv: wrangler reads it from the environment, because
# `ps` is world-readable on this Mac.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

ENVF="$HOME/.config/homelab/cloudflare.env"
if [ -f "$ENVF" ]; then
    mode=$(stat -f '%Lp' "$ENVF")
    [ "$mode" = "600" ] || { echo "REFUSING: $ENVF is mode $mode, must be 600" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$ENVF"
    echo "  credentials: $ENVF (600)"
else
    echo "  no $ENVF -- relying on \`wrangler login\` session"
fi

: "${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID in $ENVF (it is an identifier, not a secret, but it does not belong in a public repo)}"

if [ -z "${LIKES_KV_ID:-}" ]; then
    cat <<'MSG'

  No LIKES_KV_ID set. Create the namespace once:

      cd workers/likes && npx wrangler kv namespace create LIKES

  It prints an id. Put it in ~/.config/homelab/cloudflare.env as:

      LIKES_KV_ID=<the id>

  Then re-run this script. (Creating it twice makes a SECOND namespace and
  the counts silently split between them, which is why this refuses to guess.)

MSG
    exit 1
fi

# wrangler.toml carries a placeholder so the real id stays out of the public
# repo. Render a deploy-time copy instead of editing the committed file -- a
# sed-in-place here would leave the id in `git status` waiting to be committed.
TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }          # global, not a `local`: see the EXIT-trap gotcha
trap cleanup EXIT INT TERM
sed "s|PLACEHOLDER_SET_BY_DEPLOY|$LIKES_KV_ID|" wrangler.toml > "$TMP/wrangler.toml"
cp -R src "$TMP/src"
grep -q "PLACEHOLDER" "$TMP/wrangler.toml" && { echo "FATAL: placeholder not substituted" >&2; exit 1; }

echo "  deploying..."
( cd "$TMP" && npx --prefix "$OLDPWD" wrangler deploy --config "$TMP/wrangler.toml" ) 2>&1 | sed 's/^/    /'
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || { echo "  deploy FAILED (exit $rc)" >&2; exit "$rc"; }

echo
echo "  --- verifying against the LIVE url (not assuming) ---"
# NB: do not probe thebelens.com mid-deploy for a MISSING path. The zone sends
# max-age=14400 and Cloudflare has cached a 404 here for four hours once. A
# Worker route is served before the CDN cache, which is exactly what the
# cf-cache-status check below confirms rather than takes on faith.
SLUG="deploy-selftest"
URL="https://thebelens.com/api/likes/tb/$SLUG"
FOF="https://footprintsoffrank.com"

hdr=$(curl -sS -D - -o /tmp/.likes-body.$$ --max-time 15 "$URL" 2>/dev/null | tr -d '\r')
body=$(cat /tmp/.likes-body.$$ 2>/dev/null); rm -f /tmp/.likes-body.$$
code=$(printf '%s' "$hdr" | awk 'NR==1{print $2}')
cc=$(printf '%s'  "$hdr" | grep -i '^cache-control:' | head -1 | cut -d' ' -f2-)
cfs=$(printf '%s' "$hdr" | grep -i '^cf-cache-status:' | head -1 | cut -d' ' -f2-)

printf '    GET  %-28s http=%s\n' "/api/likes/tb/$SLUG" "${code:-none}"
printf '    cache-control:    %s\n' "${cc:-ABSENT}"
printf '    cf-cache-status:  %s\n' "${cfs:-absent (good: the CDN is not caching it)}"
printf '    body:             %s\n' "${body:-none}"

fail=0
[ "$code" = "200" ] || { echo "    *** expected 200 ***"; fail=1; }
case "$cc" in *no-store*) ;; *) echo "    *** cache-control is not no-store -- counts WILL freeze ***"; fail=1;; esac
case "$cfs" in HIT|hit) echo "    *** cf-cache-status HIT -- the CDN is serving a cached counter ***"; fail=1;; esac

before=$(printf '%s' "$body" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
after=$(curl -sS --max-time 15 -X POST -H "Origin: https://thebelens.com" "$URL" 2>/dev/null \
        | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
printf '    POST increments:  %s -> %s\n' "${before:-?}" "${after:-?}"
[ -n "$before" ] && [ -n "$after" ] && [ "$after" -eq $((before + 1)) ] \
    || { echo "    *** POST did not increment by exactly 1 ***"; fail=1; }

# ---- FRANK'S CROSS-ORIGIN PATH -------------------------------------------
# footprintsoffrank.com has no Cloudflare zone and cannot host a Worker route,
# so its button calls this Worker cross-origin. If the CORS header is wrong the
# browser drops the response and Frank's button NEVER APPEARS -- the block only
# reveals itself on a successful fetch. That is a silent, invisible failure, so
# it has to be proven here rather than discovered by looking at Frank's site and
# seeing nothing, which is also what a correctly-disabled flag looks like.
# NB: this is only meaningful against the DEPLOYED Worker. `wrangler dev`
# textually rewrites the routed hostname in outgoing headers (an echoed
# `https://thebelens.com` returns as `https://127.0.0.1:<port>`), so a local
# run cannot verify this -- see the note in test-local.sh.
echo
echo "  --- Frank's cross-origin access (his button is invisible without it) ---"
fhdr=$(curl -sS -D - -o /dev/null --max-time 15 -H "Origin: $FOF" \
       "https://thebelens.com/api/likes/fof/$SLUG" 2>/dev/null | tr -d '\r')
facao=$(printf '%s' "$fhdr" | grep -i '^access-control-allow-origin:' | head -1 | cut -d' ' -f2- | tr -d ' ')
fvary=$(printf '%s' "$fhdr" | grep -i '^vary:' | head -1 | cut -d' ' -f2-)
printf '    allow-origin:     %s\n' "${facao:-ABSENT}"
printf '    vary:             %s\n' "${fvary:-absent}"
[ "$facao" = "$FOF" ] || { echo "    *** Frank's origin is not allowed -- his button will not appear ***"; fail=1; }

# A foreign origin must NOT be echoed. Without this the check above passes
# just as happily against an open "allow anyone" policy.
ehdr=$(curl -sS -D - -o /dev/null --max-time 15 -H "Origin: https://evil.example" \
       "https://thebelens.com/api/likes/tb/$SLUG" 2>/dev/null | tr -d '\r')
if printf '%s' "$ehdr" | grep -qi '^access-control-allow-origin:'; then
    echo "    *** a foreign origin was echoed -- CORS is open to anyone ***"; fail=1
else
    echo "    foreign origin: correctly refused"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "  OK -- live, uncached, incrementing, and reachable from both sites."
    echo "  (the 'tb:$SLUG' and 'fof:$SLUG' keys are test artifacts; delete with:"
    echo "     npx wrangler kv key delete --namespace-id \$LIKES_KV_ID tb:$SLUG"
    echo "     npx wrangler kv key delete --namespace-id \$LIKES_KV_ID fof:$SLUG )"
else
    echo "  VERIFICATION FAILED -- the deploy may be up but is not behaving." >&2
    exit 1
fi
