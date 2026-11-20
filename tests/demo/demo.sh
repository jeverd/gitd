#!/usr/bin/env bash
# Drives a local gitd for demos and screen recordings.
#
#   tests/demo/demo.sh start                 fresh gitd with --ui on $DEMO_PORT (default 18910)
#   tests/demo/demo.sh repo NAME             create a repo
#   tests/demo/demo.sh seed REPO             push a small app to main
#   tests/demo/demo.sh agent N REPO [BRANCH] clone, change a file, push (default branch agent/N/work)
#                                            with a token limited to refs/heads/agent/N/*
#   tests/demo/demo.sh head REPO BRANCH      print a branch's commit
#   tests/demo/demo.sh race REPO BRANCH N    N agents commit to BRANCH at once via the API
#   tests/demo/demo.sh merge REPO BASE HEAD [merge|squash|fast-forward]
#   tests/demo/demo.sh stop
#
# State (admin key, port) lives in $DEMO_DIR (default /tmp/gitd-demo).
# Tokens and keys are never printed in the page, only used here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${GITD_BIN:-$ROOT/zig-out/bin/gitd}"
DEMO_DIR="${DEMO_DIR:-/tmp/gitd-demo}"
PORT="${DEMO_PORT:-18910}"
BASE="http://127.0.0.1:$PORT"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
GIT_ID=(-c user.name=agent -c user.email=agent@example.com -c init.defaultBranch=main)

key() { cat "$DEMO_DIR/key"; }
api() { curl -sf -H "authorization: Bearer $(key)" "$@"; }

# token REPO SCOPES_JSON [EXTRA_JSON_FIELDS]
token() {
  local extra="${3:-}"
  api -X POST "$BASE/v1/tokens" -d "{\"repo\":\"$1\",\"scopes\":$2,\"ttl_seconds\":3600${extra:+,$extra}}" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}
url() { echo "http://t:$1@127.0.0.1:$PORT/$2.git"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  start)
    pkill -f "gitd serve --data $DEMO_DIR/data" 2>/dev/null || true
    rm -rf "$DEMO_DIR"; mkdir -p "$DEMO_DIR"
    "$BIN" admin create-key --data "$DEMO_DIR/data" >"$DEMO_DIR/key"
    "$BIN" serve --data "$DEMO_DIR/data" --listen "127.0.0.1:$PORT" --ui >"$DEMO_DIR/server.log" 2>&1 &
    for _ in $(seq 1 100); do curl -sf "$BASE/healthz" >/dev/null && break; sleep 0.05; done
    echo "gitd at $BASE/ui"
    ;;
  stop)
    pkill -TERM -f "gitd serve --data $DEMO_DIR/data" || true
    ;;
  repo)
    api -X POST "$BASE/v1/repos" -d "{\"name\":\"$1\"}" >/dev/null
    echo "created $1"
    ;;
  seed)
    repo="$1"; dir="$DEMO_DIR/seed"
    rm -rf "$dir"; git "${GIT_ID[@]}" init -q "$dir"
    printf '<button id="theme">Toggle theme</button>\n' >"$dir/index.html"
    printf 'body { background: white; color: black; }\n' >"$dir/style.css"
    git -C "$dir" add -A; git "${GIT_ID[@]}" -C "$dir" commit -qm "Initial app"
    git -C "$dir" push -q "$(url "$(token "$repo" '["git:read","git:write"]')" "$repo")" main
    echo "seeded $repo main"
    ;;
  agent)
    n="$1"; repo="$2"; branch="${3:-agent/$n/work}"
    # Each agent may only write under refs/heads/agent/N/.
    tok="${AGENT_TOKEN:-$(token "$repo" '["git:read","git:write"]' "\"refs\":[\"refs/heads/agent/$n/*\"]")}"
    dir="$DEMO_DIR/agent$n"
    rm -rf "$dir"; git clone -q "$(url "$tok" "$repo")" "$dir"
    printf 'body.dark { background: black; color: white; } /* agent %s */\n' "$n" >>"$dir/style.css"
    git -C "$dir" add -A; git "${GIT_ID[@]}" -C "$dir" commit -qm "Agent $n: add dark mode styles"
    if git -C "$dir" push -q origin "HEAD:refs/heads/$branch" 2>"$dir.err"; then
      echo "agent $n pushed $branch"
    else
      echo "agent $n push to $branch rejected:"; sed 's/^/  /' "$dir.err"; exit 1
    fi
    ;;
  head)
    # head REPO BRANCH: print the branch's commit
    api "$BASE/v1/repos/$1/branches" | python3 -c "import json,sys; print(next(b['commit'] for b in json.load(sys.stdin)['branches'] if b['name']=='$2'))"
    ;;
  merge)
    # merge REPO BASE HEAD [STRATEGY]: merge HEAD into BASE through the API
    printf '{"base":"%s","head":"%s","strategy":"%s"}' "$2" "$3" "${4:-merge}" >"$DEMO_DIR/merge.json"
    code="$(curl -s -o "$DEMO_DIR/merge.out" -w '%{http_code}' -H "authorization: Bearer $(key)" -X POST \
      "$BASE/v1/repos/$1/merges" --data-binary @"$DEMO_DIR/merge.json")"
    echo "merge $3 into $2: HTTP $code $(cat "$DEMO_DIR/merge.out")"
    ;;
  race)
    # race REPO BRANCH N: N agents commit to BRANCH at once, all built on its
    # current head. Each token may only write that branch.
    repo="$1"; branch="$2"; n="$3"
    head="$("$0" head "$repo" "$branch")"
    for i in $(seq 1 "$n"); do
      tok="$(token "$repo" '["git:read","git:write"]' "\"refs\":[\"refs/heads/$branch\"]")"
      printf '{"branch":"%s","expected_head":"%s","message":"Agent %s: update plan","author":{"name":"Agent %s","email":"agent%s@example.com"},"changes":[{"path":"PLAN.md","content":"Plan by agent %s\\n"}]}' \
        "$branch" "$head" "$i" "$i" "$i" "$i" >"$DEMO_DIR/race$i.json"
      ( code="$(curl -s -o "$DEMO_DIR/race$i.out" -w '%{http_code}' -H "authorization: Bearer $tok" -X POST \
          "$BASE/v1/repos/$repo/commits" --data-binary @"$DEMO_DIR/race$i.json")"
        echo "agent $i: HTTP $code $(cat "$DEMO_DIR/race$i.out")" ) &
    done
    wait
    ;;
  *)
    sed -n '2,14p' "$0"; exit 2
    ;;
esac
