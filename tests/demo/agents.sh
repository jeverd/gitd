#!/usr/bin/env bash
# The MVP scenario, end to end, with a check at every step:
#
#   1. A platform creates demo/app, seeds main, and adds a webhook.
#   2. Five agents each get a token limited to refs/heads/agent/N/* whose
#      branches expire after AGENT_TTL seconds, and push attempts in parallel.
#   3. Agent 3 also tries to push main and is blocked.
#   4. The platform compares every attempt with main and merges the winner.
#   5. The other branches expire; only main is left, with the winner's work.
#   6. Every event reached the webhook.
#
#   tests/demo/agents.sh            fast (used by tests/e2e/run.sh)
#   DEMO_PACE=4 AGENT_TTL=25 DEMO_KEEP=1 tests/demo/agents.sh   paced for /ui, server left running
#
# Uses tests/demo/demo.sh, so DEMO_PORT, DEMO_DIR, and GITD_BIN apply.
# Prints "MVP OK" and exits 0 only if every check passed.
set -euo pipefail
cd "$(dirname "$0")"
PACE="${DEMO_PACE:-0}"
export AGENT_TTL="${AGENT_TTL:-3}"
PORT="${DEMO_PORT:-18910}"
DEMO_DIR="${DEMO_DIR:-/tmp/gitd-demo}"
BASE="http://127.0.0.1:$PORT"
REPO=demo/app
WINNER=2

step() { echo; echo "== $*"; sleep "$PACE"; }
die() { echo "MVP FAILED: $*" >&2; ./demo.sh stop >/dev/null 2>&1 || true; exit 1; }
api() { curl -sf -H "authorization: Bearer $(cat "$DEMO_DIR/key")" "$@"; }
branches() { api "$BASE/v1/repos/$REPO/branches" | python3 -c 'import json,sys; print(" ".join(b["name"] for b in json.load(sys.stdin)["branches"]))'; }
head_of() { ./demo.sh head "$REPO" "$1"; }

step "1. platform: create $REPO, seed main, add a webhook"
./demo.sh start
./demo.sh repo "$REPO"
./demo.sh seed "$REPO"
./demo.sh webhook "$REPO" /ok
SEED="$(head_of main)"

step "2. five agents push attempts in parallel (tokens limited to agent/N/*, branches live ${AGENT_TTL}s)"
pids=()
for n in 1 2 3 4 5; do ./demo.sh agent "$n" "$REPO" & pids+=($!); done
for pid in "${pids[@]}"; do wait "$pid" || die "an agent push failed"; done
[[ "$(branches)" == "agent/1/work agent/2/work agent/3/work agent/4/work agent/5/work main" ]] || die "branches: $(branches)"
echo "ok   five agent branches"

step "3. agent 3 tries to push main"
if ./demo.sh agent 3 "$REPO" main; then die "agent 3 pushed main"; fi
[[ "$(head_of main)" == "$SEED" ]] || die "main moved"
echo "ok   blocked; main unchanged"

step "4. platform compares every attempt with main"
for n in 1 2 3 4 5; do
  api "$BASE/v1/repos/$REPO/compare/main...agent/$n/work" |
    python3 -c "import json,sys; d=json.load(sys.stdin); print('agent $n:', d['ahead'], 'ahead,', ', '.join(f['path']+' +'+str(f['additions']) for f in d['files']))"
done

step "5. platform merges agent $WINNER into main"
WIN_HEAD="$(head_of "agent/$WINNER/work")"
./demo.sh merge "$REPO" main "agent/$WINNER/work" | tee "$DEMO_DIR/merge.txt"
grep -q 'HTTP 201' "$DEMO_DIR/merge.txt" || die "merge failed"
[[ "$(head_of main)" == "$WIN_HEAD" ]] || die "main is not the winner's commit"
api "$BASE/v1/repos/$REPO/files/style.css" | grep -q "agent $WINNER" || die "main lacks the winner's change"
echo "ok   main has agent $WINNER's dark mode"

step "6. waiting for the other attempts to expire"
for _ in $(seq 1 $((AGENT_TTL * 10 + 50))); do [[ "$(branches)" == "main" ]] && break; sleep 0.1; done
[[ "$(branches)" == "main" ]] || die "branches left: $(branches)"
echo "ok   only main is left"

step "7. every event reached the webhook"
sleep 1
api "$BASE/v1/repos/$REPO/webhooks/deliveries?limit=100" | python3 -c '
import json, sys
d = json.load(sys.stdin)["deliveries"]
kinds = sorted({x["event"]["kind"] for x in d})
bad = [x for x in d if x["status"] != "delivered"]
print("deliveries:", len(d), "kinds:", " ".join(kinds))
sys.exit(1 if bad or not {"push", "push_rejected", "merge", "branch_expired"} <= set(kinds) else 0)
' || die "webhook deliveries incomplete"
echo
echo "MVP OK"
[[ "${DEMO_KEEP:-}" == 1 ]] || ./demo.sh stop
