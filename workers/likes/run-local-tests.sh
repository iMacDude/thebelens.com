#!/bin/bash
# run-local-tests.sh -- boot wrangler on a FREE port, wait until the WORKER
# ITSELF answers, run test-local.sh, tear down.
#
# The readiness probe asserts IDENTITY, not liveness. The first version accepted
# any HTTP response, an unrelated service was already on 8787, and its 404s
# stood in for the Worker -- 14 tests failed for the wrong reason and 3 PASSED
# against the wrong server, which is worse. Same shape as a NUT port check
# reading green while the driver was detached: a liveness check cannot see
# whether the thing answering is the thing you meant.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

# Ask the kernel for a port nobody holds, rather than hoping 8787 is free.
PORT=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
LOG=$(mktemp -t wrangler-dev)   # macOS mktemp -t appends its own suffix
echo "  port $PORT (chosen free), log $LOG"

npx wrangler dev --local --port "$PORT" --ip 127.0.0.1 >"$LOG" 2>&1 &
WPID=$!
cleanup() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
trap cleanup EXIT INT TERM   # global, not a `local` -- see the EXIT-trap gotcha

ready=0
for i in $(seq 1 60); do
    # Identity: only OUR worker returns this contract for this path.
    if curl -s --max-time 2 "http://127.0.0.1:$PORT/api/likes/warmup" 2>/dev/null \
         | grep -q '"slug":"warmup"'; then ready=1; break; fi
    sleep 1
done
if [ "$ready" != "1" ]; then
    echo "  *** the Worker never answered on $PORT (something else may have, which is why this checks the body) ***"
    echo "  --- what IS on $PORT ---"; lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sed 's/^/    /'
    echo "  --- wrangler log ---"; tail -30 "$LOG" | sed 's/^/    /'
    exit 1
fi
echo "  Worker confirmed answering after ${i}s"
echo
PORT="$PORT" ./test-local.sh
