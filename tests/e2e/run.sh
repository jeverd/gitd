#!/usr/bin/env bash
# End-to-end test: drives a real gitd with curl and the real git client.
#
#   tests/e2e/run.sh [path/to/gitd]
#
# Every check must pass, and the server log must end with no errors, warnings,
# panics, or leak reports. Exits non-zero on the first failure.
set -euo pipefail

BIN="$(cd "$(dirname "${1:-zig-out/bin/gitd}")" && pwd)/$(basename "${1:-zig-out/bin/gitd}")"
[[ -x "$BIN" ]] || { echo "no gitd binary at $BIN; run zig build" >&2; exit 1; }

WORK="$(mktemp -d)"
DATA="$WORK/data"
LOG="$WORK/server.log"
SERVER_PID=""
PASSED=0

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then kill -KILL "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# The git client gets no user or system config, so nothing on this machine
# (credential helpers, URL rewrites) changes what is tested.
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"
GIT_ID=(-c user.name=e2e -c user.email=e2e@example.com -c init.defaultBranch=main)

fail() {
  echo "FAIL: $*" >&2
  echo "--- server log ---" >&2
  cat "$LOG" >&2 || true
  exit 1
}
pass() { PASSED=$((PASSED + 1)); echo "ok   $*"; }
expect_eq() { [[ "$2" == "$3" ]] || fail "$1: expected '$2', got '$3'"; pass "$1"; }

start_server() {
  # Only read log lines this server writes: an earlier run's line has a dead port.
  local skip
  skip=$(($(wc -l <"$LOG" 2>/dev/null || echo 0) + 1))
  PORT=""
  GITD_IDLE_TIMEOUT_SECONDS=2 "$BIN" serve --data "$DATA" --listen 127.0.0.1:0 >>"$LOG" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 100); do
    PORT="$(tail -n +"$skip" "$LOG" | sed -n 's/.*listening on 127\.0\.0\.1:\([0-9]*\),.*/\1/p' | tail -1)"
    [[ -n "$PORT" ]] && break
    sleep 0.05
  done
  [[ -n "${PORT:-}" ]] || fail "server did not start"
  BASE="http://127.0.0.1:$PORT"
}

stop_server() {
  kill -TERM "$SERVER_PID"
  for _ in $(seq 1 100); do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.05
  done
  kill -0 "$SERVER_PID" 2>/dev/null && fail "server did not stop within 5s of SIGTERM"
  local code=0
  wait "$SERVER_PID" || code=$?
  SERVER_PID=""
  expect_eq "server exits 0 on SIGTERM" 0 "$code"
}

# curl wrappers: print the status code; the body goes to $WORK/body.
status() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }
admin() { status -H "authorization: Bearer $KEY" "$@"; }
json() { python3 -c "import json,sys; print(json.load(open('$WORK/body'))$1)"; }
mint() { # repo scopes-json [ttl]
  local ttl="${3:-900}"
  [[ "$(admin -X POST "$BASE/v1/tokens" -d "{\"repo\":\"$1\",\"scopes\":$2,\"ttl_seconds\":$ttl}")" == 201 ]] || fail "minting token for $1"
  json '["token"]'
}
url() { echo "http://t:$1@127.0.0.1:$PORT/$2.git"; }

echo "== setup"
KEY="$("$BIN" admin create-key --data "$DATA")"
[[ "$KEY" == gitd_k_* ]] || fail "admin create-key printed '$KEY'"
pass "admin create-key"
start_server

echo "== health and admin auth"
expect_eq "healthz" 200 "$(status "$BASE/healthz")"
expect_eq "no admin key" 401 "$(status "$BASE/v1/repos")"
expect_eq "wrong admin key" 401 "$(status -H 'authorization: Bearer gitd_k_nope' "$BASE/v1/repos")"
expect_eq "unknown route" 404 "$(admin "$BASE/v1/nothing")"

echo "== repos API"
expect_eq "create repo" 201 "$(admin -X POST "$BASE/v1/repos" -d '{"name":"acme/web"}')"
expect_eq "create repo name echoed" "acme/web" "$(json '["name"]')"
expect_eq "duplicate repo" 409 "$(admin -X POST "$BASE/v1/repos" -d '{"name":"acme/web"}')"
for bad in '../x' 'acme/../x' 'Acme/web' 'acme/web.git' 'acme' 'acme/.hidden' 'a/b/c'; do
  expect_eq "invalid name '$bad'" 400 "$(admin -X POST "$BASE/v1/repos" -d "{\"name\":\"$bad\"}")"
done
expect_eq "bad json" 400 "$(admin -X POST "$BASE/v1/repos" -d '{"nam":')"
expect_eq "unknown json field" 400 "$(admin -X POST "$BASE/v1/repos" -d '{"name":"a/b","x":1}')"
expect_eq "oversize body" 413 "$(head -c 70000 /dev/zero | tr '\0' 'a' | admin -X POST "$BASE/v1/repos" --data-binary @-)"
expect_eq "list repos" 200 "$(admin "$BASE/v1/repos")"
expect_eq "list has one repo" 1 "$(json '["repos"].__len__()')"
expect_eq "get repo" 200 "$(admin "$BASE/v1/repos/acme/web")"
expect_eq "get missing repo" 404 "$(admin "$BASE/v1/repos/acme/none")"
expect_eq "get invalid repo name" 400 "$(admin "$BASE/v1/repos/acme/We")"
expect_eq "wrong method" 405 "$(admin -X PUT "$BASE/v1/repos")"

echo "== tokens API"
expect_eq "token for missing repo" 404 "$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/none","scopes":["git:read"]}')"
expect_eq "token bad scope" 400 "$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/web","scopes":["admin"]}')"
expect_eq "token no scopes" 400 "$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/web","scopes":[]}')"
expect_eq "token ttl 0" 400 "$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/web","scopes":["git:read"],"ttl_seconds":0}')"
expect_eq "token ttl too long" 400 "$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/web","scopes":["git:read"],"ttl_seconds":86401}')"
RW="$(mint acme/web '["git:read","git:write"]')"
RO="$(mint acme/web '["git:read"]')"
SHORT="$(mint acme/web '["git:read"]' 1)"
pass "minted read-write, read-only, and 1-second tokens"

echo "== push and clone"
SRC="$WORK/src"
git "${GIT_ID[@]}" init -q "$SRC"
echo "hello" >"$SRC/a.txt"
git -C "$SRC" add a.txt
git "${GIT_ID[@]}" -C "$SRC" commit -qm first
git -C "$SRC" push -q "$(url "$RW" acme/web)" main 2>"$WORK/err" || fail "push with read-write token: $(cat "$WORK/err")"
pass "push with read-write token"

for v in 0 2; do
  rm -rf "$WORK/clone$v"
  git -c protocol.version=$v clone -q "$(url "$RO" acme/web)" "$WORK/clone$v" 2>"$WORK/err" || fail "clone v$v: $(cat "$WORK/err")"
  expect_eq "clone over protocol v$v matches" "$(git -C "$SRC" rev-parse HEAD)" "$(git -C "$WORK/clone$v" rev-parse HEAD)"
done
expect_eq "cloned file content" hello "$(cat "$WORK/clone2/a.txt")"

# 8 MiB of random data: bigger than git's 1 MiB post buffer, so the push
# body is sent with chunked transfer encoding.
head -c 8388608 /dev/urandom >"$SRC/big.bin"
for i in $(seq 1 200); do echo "line $i" >"$SRC/f$i.txt"; done
git -C "$SRC" add -A
git "${GIT_ID[@]}" -C "$SRC" commit -qm second
git -C "$SRC" push -q "$(url "$RW" acme/web)" main 2>"$WORK/err" || fail "large push: $(cat "$WORK/err")"
pass "large chunked push"
git -C "$WORK/clone2" pull -q --ff-only 2>"$WORK/err" || fail "fetch after large push: $(cat "$WORK/err")"
expect_eq "fetch sees second commit" "$(git -C "$SRC" rev-parse HEAD)" "$(git -C "$WORK/clone2" rev-parse HEAD)"
expect_eq "large file intact" "$(shasum "$SRC/big.bin" | cut -d' ' -f1)" "$(shasum "$WORK/clone2/big.bin" | cut -d' ' -f1)"

echo "== git auth"
git "${GIT_ID[@]}" -C "$SRC" commit -q --allow-empty -m third
if git -C "$SRC" push -q "$(url "$RO" acme/web)" main 2>/dev/null; then fail "read-only token pushed"; fi
expect_eq "read-only token cannot push (info/refs)" 403 "$(status -u "t:$RO" "$BASE/acme/web.git/info/refs?service=git-receive-pack")"
expect_eq "read-only token cannot push (rpc)" 403 "$(status -u "t:$RO" -X POST "$BASE/acme/web.git/git-receive-pack")"
expect_eq "no token" 401 "$(status "$BASE/acme/web.git/info/refs?service=git-upload-pack")"
expect_eq "401 asks for basic auth" 1 "$(curl -s -D - -o /dev/null "$BASE/acme/web.git/info/refs?service=git-upload-pack" | grep -ci '^www-authenticate: basic')"
expect_eq "garbage token" 401 "$(status -u "t:gitd_t_garbage.x" "$BASE/acme/web.git/info/refs?service=git-upload-pack")"
TAMPERED="${RW%?}x"; [[ "$TAMPERED" == "$RW" ]] && TAMPERED="${RW%?}y"
expect_eq "tampered token" 401 "$(status -u "t:$TAMPERED" "$BASE/acme/web.git/info/refs?service=git-upload-pack")"
admin -X POST "$BASE/v1/repos" -d '{"name":"acme/other"}' >/dev/null
OTHER="$(mint acme/other '["git:read","git:write"]')"
expect_eq "token for another repo" 403 "$(status -u "t:$OTHER" "$BASE/acme/web.git/info/refs?service=git-upload-pack")"
if git clone -q "$(url "$OTHER" acme/web)" "$WORK/nope" 2>/dev/null; then fail "cloned with another repo's token"; fi
pass "git refuses another repo's token"
sleep 2
expect_eq "expired token" 401 "$(status -u "t:$SHORT" "$BASE/acme/web.git/info/refs?service=git-upload-pack")"

echo "== protocol hardening"
expect_eq "dumb protocol HEAD" 400 "$(status -u "t:$RO" "$BASE/acme/web.git/HEAD")"
expect_eq "dumb protocol objects" 400 "$(status -u "t:$RO" "$BASE/acme/web.git/objects/info/packs")"
expect_eq "info/refs without service" 400 "$(status -u "t:$RO" "$BASE/acme/web.git/info/refs")"
expect_eq "extra query" 400 "$(status -u "t:$RO" "$BASE/acme/web.git/info/refs?service=git-upload-pack&x=1")"
expect_eq "path traversal" 400 "$(status --path-as-is -u "t:$RO" "$BASE/acme/../../etc.git/info/refs?service=git-upload-pack")"
expect_eq "wrong method on rpc" 405 "$(status -u "t:$RO" "$BASE/acme/web.git/git-upload-pack")"
expect_eq "git route for missing repo" 403 "$(status -u "t:$RO" "$BASE/acme/none.git/info/refs?service=git-upload-pack")"

echo "== connection limits"
# An idle connection is dropped after GITD_IDLE_TIMEOUT_SECONDS (2 here).
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
printf 'GET /healthz HTTP/1.1\r\nHost: x\r\n' >&3
sleep 3
read_status=0
read -r -t 2 _ <&3 || read_status=$?
exec 3<&- 3>&-
[[ "$read_status" -le 128 ]] || fail "idle connection was not closed (read timed out instead of seeing EOF)"
pass "idle connection closed"
# A rejected upload is not invited with 100 Continue, and the connection closes.
head -c 3000000 /dev/zero >"$WORK/zeros"
curl -s -v -o /dev/null -H 'Expect: 100-continue' -u "t:$RO" --data-binary @"$WORK/zeros" \
  "$BASE/acme/web.git/git-receive-pack" 2>"$WORK/curl-v" || true
grep -q "HTTP/1.1 403" "$WORK/curl-v" || fail "rejected upload did not get 403: $(cat "$WORK/curl-v")"
if grep -q "100 Continue" "$WORK/curl-v"; then fail "server sent 100 Continue before rejecting"; fi
grep -qi "connection: close" "$WORK/curl-v" || fail "rejected upload did not close the connection"
pass "rejected upload gets no 100 Continue and the connection closes"

echo "== aborted requests clean up"
# Uploads cut off midway never reach git and leave nothing in data/tmp:
# mid-chunk, between chunks, and short of Content-Length.
python3 - "$PORT" "$RW" <<'PY'
import base64, socket, sys, time
port, token = int(sys.argv[1]), sys.argv[2]
auth = base64.b64encode(f"t:{token}".encode()).decode()
head = (f"POST /acme/web.git/git-receive-pack HTTP/1.1\r\nHost: x\r\nAuthorization: Basic {auth}\r\n"
        "Content-Type: application/x-git-receive-pack-request\r\n").encode()
for body in (b"Transfer-Encoding: chunked\r\n\r\n100000\r\n" + b"0" * 300000,
             b"Transfer-Encoding: chunked\r\n\r\n4\r\n0000\r\n",
             b"Content-Length: 500000\r\n\r\n" + b"0" * 1000):
    s = socket.create_connection(("127.0.0.1", port))
    s.sendall(head + body)
    time.sleep(0.2)
    s.close()
time.sleep(0.3)
PY
expect_eq "cut-off uploads rejected before git runs" 3 "$(grep -c 'git-receive-pack: client went away (ClientGone)' "$LOG")"
expect_eq "no spooled body left after cut-off uploads" 0 "$(find "$DATA/tmp" -type f | wc -l | tr -d ' ')"
# A clone cut off midway does not leave git processes behind. The client
# reads at 200 KB/s, so the 8 MiB pack is still streaming when it quits.
TIP="$(git ls-remote "$(url "$RO" acme/web)" refs/heads/main | cut -f1)"
printf '0032want %s\n00000009done\n' "$TIP" >"$WORK/want"
GOT="$(curl -s -o /dev/null -w '%{size_download}' --limit-rate 200k --max-time 1 -u "t:$RO" \
  -H 'Content-Type: application/x-git-upload-pack-request' --data-binary @"$WORK/want" \
  "$BASE/acme/web.git/git-upload-pack" || true)"
[[ "$GOT" -gt 10000 && "$GOT" -lt 4000000 ]] || fail "clone was not cut off midway (downloaded $GOT bytes)"
pass "clone cut off after $GOT bytes"
# git processes a gitd request starts. Anchored to the start of the command
# line, so this script's own command text never matches.
leftover() { ps -eo args= | grep -E "^git(-| )(http-backend|upload-pack|pack-objects)" || true; }
for _ in $(seq 1 40); do [[ -z "$(leftover)" ]] && break; sleep 0.1; done
[[ -z "$(leftover)" ]] || fail "git processes left after an interrupted clone: $(leftover)"
pass "interrupted clone leaves no git processes"
expect_eq "server still serves after interrupted clone" 200 "$(status "$BASE/healthz")"

echo "== hooks never run (R2.4)"
HOOK="$DATA/repos/acme/web.git/hooks/pre-receive"
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$WORK/hook-ran" >"$HOOK"
chmod +x "$HOOK"
git -C "$SRC" push -q "$(url "$RW" acme/web)" main 2>"$WORK/err" || fail "push with planted hook: $(cat "$WORK/err")"
[[ ! -e "$WORK/hook-ran" ]] || fail "a repo hook ran"
pass "planted pre-receive hook did not run"

echo "== concurrent pushes"
PUSH_PIDS=()
for i in 1 2 3 4 5 6 7 8; do
  (
    d="$WORK/agent$i"
    git clone -q "$(url "$RW" acme/web)" "$d" 2>/dev/null
    git -C "$d" checkout -q -b "agent/$i"
    echo "agent $i" >"$d/agent.txt"
    git -C "$d" add agent.txt
    git "${GIT_ID[@]}" -C "$d" commit -qm "agent $i"
    git -C "$d" push -q origin "agent/$i" 2>"$d.err"
  ) &
  PUSH_PIDS+=($!)
done
# Wait for the pushes only; a bare `wait` would also wait for the server.
for pid in "${PUSH_PIDS[@]}"; do wait "$pid" || fail "a parallel push failed: $(cat "$WORK"/agent*.err)"; done
expect_eq "8 parallel branch pushes landed" 8 "$(git ls-remote "$(url "$RO" acme/web)" 'refs/heads/agent/*' | wc -l | tr -d ' ')"

echo "== delete and recreate"
expect_eq "delete repo" 204 "$(admin -X DELETE "$BASE/v1/repos/acme/web")"
expect_eq "delete again" 404 "$(admin -X DELETE "$BASE/v1/repos/acme/web")"
[[ ! -e "$DATA/repos/acme/web.git" ]] || fail "repo directory left after delete"
pass "repo directory removed"
expect_eq "old token after delete" 404 "$(status -u "t:$RW" "$BASE/acme/web.git/info/refs?service=git-upload-pack")"
expect_eq "recreate same name" 201 "$(admin -X POST "$BASE/v1/repos" -d '{"name":"acme/web"}')"
expect_eq "token for the deleted repo does not work on the new one" 403 "$(status -u "t:$RW" "$BASE/acme/web.git/info/refs?service=git-upload-pack")"
RW="$(mint acme/web '["git:read","git:write"]')"
expect_eq "recreated repo is empty" 0 "$(git ls-remote "$(url "$RW" acme/web)" | wc -l | tr -d ' ')"

echo "== restart keeps data and secret"
# Stop while a slow clone is mid-transfer: gitd must still exit promptly and
# take its git processes with it.
head -c 4000000 /dev/urandom >"$SRC/big2.bin"
git -C "$SRC" add big2.bin
git "${GIT_ID[@]}" -C "$SRC" commit -qm big2
git -C "$SRC" push -q "$(url "$RW" acme/web)" main 2>"$WORK/err" || fail "push before shutdown test: $(cat "$WORK/err")"
TIP="$(git -C "$SRC" rev-parse HEAD)"
printf '0032want %s\n00000009done\n' "$TIP" >"$WORK/want"
curl -s -o /dev/null --limit-rate 100k --max-time 20 -u "t:$RW" -H 'Content-Type: application/x-git-upload-pack-request' \
  --data-binary @"$WORK/want" "$BASE/acme/web.git/git-upload-pack" &
SLOW_CLONE=$!
sleep 0.5
stop_server
wait "$SLOW_CLONE" 2>/dev/null || true
for _ in $(seq 1 40); do [[ -z "$(leftover)" ]] && break; sleep 0.1; done
[[ -z "$(leftover)" ]] || fail "git processes left after stopping mid-clone: $(leftover)"
pass "stopping mid-clone leaves no git processes"
start_server
expect_eq "list after restart" 200 "$(admin "$BASE/v1/repos")"
expect_eq "repos survive restart" 2 "$(json '["repos"].__len__()')"
git ls-remote "$(url "$RW" acme/web)" >/dev/null 2>"$WORK/err" || fail "token from before restart: $(cat "$WORK/err")"
pass "token minted before restart still works"
stop_server

echo "== server log is clean"
if grep -nE '^(error|warning)|panic|leak|Segmentation' "$LOG"; then fail "server log has errors, warnings, panics, or leaks"; fi
pass "no errors, warnings, panics, or leaks in server log"
grep -q "$KEY" "$LOG" && fail "admin key appears in server log"
grep -qF "$RW" "$LOG" && fail "token appears in server log"
pass "no secrets in server log"

echo "PASS: $PASSED checks"
