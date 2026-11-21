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

RECEIVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then kill -KILL "$SERVER_PID" 2>/dev/null || true; fi
  if [[ -n "$RECEIVER_PID" ]]; then kill "$RECEIVER_PID" 2>/dev/null || true; fi
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
  GITD_IDLE_TIMEOUT_SECONDS=2 GITD_HEAD_TIMEOUT_SECONDS=3 GITD_WEBHOOK_BACKOFF_MS=100 GITD_WEBHOOK_TIMEOUT_MS=1000 "$BIN" serve --data "$DATA" --listen 127.0.0.1:0 --ui >>"$LOG" 2>&1 &
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
events() { curl -s "$BASE/ui/api/events?after=0" >"$WORK/body"; }
count_events() { events; python3 -c "import json,sys; print(sum(1 for e in json.load(open('$WORK/body'))['events'] if all(e[k]==v for k,v in (a.split('=',1) for a in sys.argv[1:]))))" "$@"; }


echo "== setup"
KEY="$("$BIN" admin create-key --data "$DATA")"
[[ "$KEY" == gitd_k_* ]] || fail "admin create-key printed '$KEY'"
pass "admin create-key"
# A key chosen up front (a container's environment) is added from stdin.
CHOSEN_KEY="gitd_k_$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
printf '%s\n' "$CHOSEN_KEY" | "$BIN" admin add-key --data "$DATA" 2>/dev/null || fail "admin add-key"
pass "admin add-key"
printf '%s' "$CHOSEN_KEY" | "$BIN" admin add-key --data "$DATA" 2>/dev/null || fail "admin add-key again"
pass "admin add-key of a present key is a no-op"
for bad in "nope" "${CHOSEN_KEY}0" "gitd_k_$(printf %s "${CHOSEN_KEY#gitd_k_}" | tr a-f A-F)" ""; do
  rc=0; printf '%s' "$bad" | "$BIN" admin add-key --data "$DATA" 2>/dev/null || rc=$?
  expect_eq "admin add-key refuses '${bad:0:12}...'" 2 "$rc"
done
start_server

echo "== health and admin auth"
expect_eq "healthz" 200 "$(status "$BASE/healthz")"
expect_eq "no admin key" 401 "$(status "$BASE/v1/repos")"
expect_eq "wrong admin key" 401 "$(status -H 'authorization: Bearer gitd_k_nope' "$BASE/v1/repos")"
expect_eq "unknown route" 404 "$(admin "$BASE/v1/nothing")"
expect_eq "added admin key works" 200 "$(status -H "authorization: Bearer $CHOSEN_KEY" "$BASE/v1/repos")"

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

echo "== branch limits (R2.2)"

expect_eq "mint limited token" 201 "$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/other","scopes":["git:read","git:write"],"refs":["refs/heads/agent/7/*"]}')"
LIM="$(json '["token"]')"
FULL_OTHER="$(mint acme/other '["git:read","git:write"]')"
expect_eq "invalid ref pattern" 400 "$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/other","scopes":["git:write"],"refs":["main"]}')"
expect_eq "too many ref patterns" 400 "$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/other","scopes":["git:write"],"refs":["refs/heads/a","refs/heads/b","refs/heads/c","refs/heads/d","refs/heads/e"]}')"
LREPO="$WORK/limited"
git "${GIT_ID[@]}" init -q "$LREPO"
echo x >"$LREPO/x.txt"; git -C "$LREPO" add x.txt; git "${GIT_ID[@]}" -C "$LREPO" commit -qm x
git -C "$LREPO" push -q "$(url "$FULL_OTHER" acme/other)" HEAD:refs/heads/main 2>"$WORK/err" || fail "seeding acme/other main: $(cat "$WORK/err")"
OTHER_MAIN="$(git -C "$LREPO" rev-parse HEAD)"
echo y >"$LREPO/x.txt"; git "${GIT_ID[@]}" -C "$LREPO" commit -qam y
git -C "$LREPO" push -q "$(url "$LIM" acme/other)" HEAD:refs/heads/agent/7/a 2>"$WORK/err" || fail "allowed push: $(cat "$WORK/err")"
pass "limited token pushes inside its pattern"
REJ_BEFORE="$(count_events kind=push_rejected)"
if git -C "$LREPO" push "$(url "$LIM" acme/other)" HEAD:refs/heads/main >"$WORK/out" 2>&1; then fail "limited token pushed main"; fi
grep -q "remote rejected.*token may only push to refs/heads/agent/7/\*" "$WORK/out" || fail "git did not show the rejection reason: $(cat "$WORK/out")"
pass "git shows the rejection reason"
expect_eq "main unchanged after rejected push" "$OTHER_MAIN" "$(git ls-remote "$(url "$FULL_OTHER" acme/other)" refs/heads/main | cut -f1)"
expect_eq "rejection logged" "$((REJ_BEFORE + 1))" "$(count_events kind=push_rejected)"
if git -C "$LREPO" push -q "$(url "$LIM" acme/other)" HEAD:refs/heads/agent/7/b HEAD:refs/heads/main 2>/dev/null; then fail "mixed push accepted"; fi
expect_eq "mixed push changes nothing" "" "$(git ls-remote "$(url "$FULL_OTHER" acme/other)" refs/heads/agent/7/b)"
if git -C "$LREPO" push -q "$(url "$LIM" acme/other)" :refs/heads/main 2>/dev/null; then fail "limited token deleted main"; fi
expect_eq "main survives a refused delete" "$OTHER_MAIN" "$(git ls-remote "$(url "$FULL_OTHER" acme/other)" refs/heads/main | cut -f1)"
git -C "$LREPO" push -q "$(url "$LIM" acme/other)" :refs/heads/agent/7/a 2>"$WORK/err" || fail "allowed delete: $(cat "$WORK/err")"
pass "limited token deletes inside its pattern"
# A client that asks for no report gets a plain 403; one that asks for
# report-status without side-band gets bare report lines.
python3 - "$PORT" "$LIM" "$OTHER_MAIN" >"$WORK/raw" <<'PY'
import base64, socket, sys
port, token, old = int(sys.argv[1]), sys.argv[2], sys.argv[3]
auth = base64.b64encode(f"t:{token}".encode()).decode()
def push(caps):
    line = f"{old} {'1'*40} refs/heads/main\0{caps}\n".encode()
    body = b"%04x" % (len(line) + 4) + line + b"0000"
    s = socket.create_connection(("127.0.0.1", port))
    s.sendall((f"POST /acme/other.git/git-receive-pack HTTP/1.1\r\nHost: x\r\nAuthorization: Basic {auth}\r\n"
               f"Content-Type: application/x-git-receive-pack-request\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode() + body)
    data = b""
    while chunk := s.recv(65536):
        data += chunk
    s.close()
    return data
print("NOREPORT", push("agent=test").split(b"\r\n")[0].decode())
print("PLAIN", b"ng refs/heads/main token may only push" in push("report-status"))
PY
grep -q "NOREPORT HTTP/1.1 403" "$WORK/raw" || fail "push without report-status: $(cat "$WORK/raw")"
grep -q "PLAIN True" "$WORK/raw" || fail "plain report-status rejection: $(cat "$WORK/raw")"
pass "rejections without report-status and without side-band"

echo "== read API"
CB="$BASE/v1/repos/acme/other"

git -C "$LREPO" checkout -q -B main "$OTHER_MAIN"
mkdir -p "$LREPO/dir"; echo sub >"$LREPO/dir/sub.txt"; git -C "$LREPO" add dir; git "${GIT_ID[@]}" -C "$LREPO" commit -qm "Add dir/sub.txt"
git -C "$LREPO" push -q "$(url "$FULL_OTHER" acme/other)" main 2>"$WORK/err" || fail "push for read API: $(cat "$WORK/err")"
OTHER_HEAD="$(git -C "$LREPO" rev-parse HEAD)"
READ_TOK="$(mint acme/other '["git:read"]')"
WRITE_ONLY="$(mint acme/other '["git:write"]')"
expect_eq "branches (admin)" 200 "$(admin "$CB/branches")"
expect_eq "branches lists main" "$OTHER_HEAD" "$(json '["branches"][0]["commit"]')"
expect_eq "file (admin)" 200 "$(admin "$CB/files/x.txt")"
expect_eq "file content" x "$(cat "$WORK/body")"
expect_eq "file with read token" 200 "$(status -H "authorization: Bearer $READ_TOK" "$CB/files/dir/sub.txt")"
expect_eq "nested file content" sub "$(cat "$WORK/body")"
expect_eq "file with write-only token" 403 "$(status -H "authorization: Bearer $WRITE_ONLY" "$CB/files/x.txt")"
expect_eq "file with another repo's token" 403 "$(status -H "authorization: Bearer $RO" "$CB/files/x.txt")"
expect_eq "file without auth" 401 "$(status "$CB/files/x.txt")"
expect_eq "file with a bad token" 401 "$(status -H "authorization: Bearer gitd_t_bad.x" "$CB/files/x.txt")"
expect_eq "file at an older commit" 200 "$(admin "$CB/files/x.txt?ref=$OTHER_MAIN")"
expect_eq "older content" x "$(cat "$WORK/body")"
expect_eq "missing file" 404 "$(admin "$CB/files/nope.txt")"
expect_eq "directory is not a file" 404 "$(admin "$CB/files/dir")"
expect_eq "unknown ref" 404 "$(admin "$CB/files/x.txt?ref=nope")"
expect_eq "invalid ref" 400 "$(admin "$CB/files/x.txt?ref=..%2Fmain")"
expect_eq "traversal in path" 400 "$(admin --path-as-is "$CB/files/../x.txt")"
expect_eq "encoded traversal" 400 "$(admin "$CB/files/%2e%2e/x.txt")"
expect_eq ".git in path" 400 "$(admin "$CB/files/.git/config")"
expect_eq "tree root" 200 "$(admin "$CB/tree")"
expect_eq "tree root entries" "dir x.txt" "$(json '' | python3 -c 'import json; print(" ".join(e["name"] for e in json.load(open("'"$WORK"'/body"))["entries"]))')"
expect_eq "subtree" 200 "$(admin "$CB/tree/dir")"
expect_eq "subtree entry" "dir/sub.txt" "$(json '["entries"][0]["path"]')"
expect_eq "missing tree" 404 "$(admin "$CB/tree/nope")"
expect_eq "a file is not a tree" 404 "$(admin "$CB/tree/x.txt")"
expect_eq "log" 200 "$(admin "$CB/log?limit=1")"
expect_eq "log newest first" "$OTHER_HEAD" "$(json '["commits"][0]["sha"]')"
expect_eq "log for a path" "Add dir/sub.txt" "$(admin "$CB/log?path=dir%2Fsub.txt" >/dev/null; json '["commits"][0]["subject"]')"
expect_eq "log limit out of range" 400 "$(admin "$CB/log?limit=0")"
expect_eq "commit by sha" 200 "$(admin "$CB/commits/$OTHER_HEAD")"
expect_eq "commit parent" "$OTHER_MAIN" "$(json '["parents"][0]')"
expect_eq "commit bad sha" 400 "$(admin "$CB/commits/xyz")"
expect_eq "commit unknown sha" 404 "$(admin "$CB/commits/0123456789012345678901234567890123456789")"
expect_eq "read API on missing repo" 404 "$(admin "$BASE/v1/repos/acme/none/files/x.txt")"
expect_eq "UI reads without auth" 200 "$(status "$BASE/ui/api/repos/acme/other/files/x.txt")"
expect_eq "UI reads are read-only" 405 "$(status -X POST "$BASE/ui/api/repos/acme/other/commits")"

echo "== commit API (R3.2)"
commit_body() { # branch expected(json) message changes(json)
  printf '{"branch":"%s","expected_head":%s,"message":"%s","changes":%s}' "$1" "$2" "$3" "$4"
}
expect_eq "commit" 201 "$(admin -X POST "$CB/commits" -d "$(commit_body main "\"$OTHER_HEAD\"" "API commit" '[{"path":"notes/a.md","content":"hello\n"},{"path":"x.txt","delete":true}]')")"
API_HEAD="$(json '["sha"]')"
expect_eq "commit parent" "$OTHER_HEAD" "$(json '["parent"]')"
expect_eq "committed file" 200 "$(admin "$CB/files/notes/a.md")"
expect_eq "committed content" hello "$(cat "$WORK/body")"
expect_eq "deleted file is gone" 404 "$(admin "$CB/files/x.txt")"
expect_eq "commit logged" 1 "$(count_events kind=commit new="$API_HEAD")"
expect_eq "stale expected_head" 409 "$(admin -X POST "$CB/commits" -d "$(commit_body main "\"$OTHER_HEAD\"" late '[{"path":"late.txt","content":"x"}]')")"
expect_eq "409 says where the branch is" "$API_HEAD" "$(json '["current_head"]')"
expect_eq "conflict logged" 1 "$(count_events kind=commit_conflict)"
# Six commits race on the same head: exactly one wins, history stays linear.
RACE_PIDS=()
for i in 1 2 3 4 5 6; do
  printf '{"branch":"main","expected_head":"%s","message":"racer %s","changes":[{"path":"race.txt","content":"%s"}]}' "$API_HEAD" "$i" "$i" >"$WORK/race$i.json"
  curl -s -o "$WORK/race$i" -w '%{http_code}' -H "authorization: Bearer $KEY" -X POST "$CB/commits" --data-binary @"$WORK/race$i.json" >"$WORK/race$i.code" &
  RACE_PIDS+=($!)
done
for pid in "${RACE_PIDS[@]}"; do wait "$pid"; done
expect_eq "race: one winner" 1 "$(grep -l '^201$' "$WORK"/race*.code | wc -l | tr -d ' ')"
expect_eq "race: five 409s" 5 "$(grep -l '^409$' "$WORK"/race*.code | wc -l | tr -d ' ')"
admin "$CB/log?limit=3" >/dev/null
expect_eq "race: the winner sits on the old head" "$API_HEAD" "$(json '["commits"][0]["parents"][0]')"
WINNER="$(json '["commits"][0]["sha"]')"
expect_eq "race: losers see the winner" 5 "$(grep -l "\"current_head\":\"$WINNER\"" "$WORK"/race? | wc -l | tr -d ' ')"
expect_eq "new branch from main" 201 "$(admin -X POST "$CB/commits" -d '{"branch":"feature/x","expected_head":null,"from":"main","message":"start","changes":[{"path":"f.txt","content":"f"}]}')"
expect_eq "new branch parent is main" "$WINNER" "$(json '["parent"]')"
expect_eq "creating an existing branch" 409 "$(admin -X POST "$CB/commits" -d '{"branch":"feature/x","expected_head":null,"from":"main","message":"again","changes":[{"path":"f.txt","content":"g"}]}')"
expect_eq "commit with read token" 403 "$(status -H "authorization: Bearer $READ_TOK" -X POST "$CB/commits" -d '{"branch":"agent/7/r","expected_head":null,"message":"m","changes":[{"path":"a","content":"a"}]}')"
expect_eq "limited token outside its pattern" 403 "$(status -H "authorization: Bearer $LIM" -X POST "$CB/commits" -d "$(commit_body main "\"$WINNER\"" m '[{"path":"a","content":"a"}]')")"
expect_eq "limited token inside its pattern" 201 "$(status -H "authorization: Bearer $LIM" -X POST "$CB/commits" -d '{"branch":"agent/7/api","expected_head":null,"from":"main","message":"agent work","author":{"name":"Agent 7","email":"a7@example.com"},"changes":[{"path":"a.txt","content":"a"}]}')"
expect_eq "author recorded" "Agent 7" "$(admin "$CB/commits/$(json '["sha"]')" >/dev/null; json '["author"]["name"]')"
for bad in '{"branch":"main","expected_head":null,"message":"m","changes":[]}' \
           '{"branch":"main","expected_head":null,"message":"","changes":[{"path":"a","content":"a"}]}' \
           '{"branch":"main","expected_head":null,"message":"m","changes":[{"path":"a","content":"a","delete":true}]}' \
           '{"branch":"main","expected_head":null,"message":"m","changes":[{"path":"../a","content":"a"}]}' \
           '{"branch":"main","expected_head":null,"message":"m","changes":[{"path":"a","content_base64":"!!!"}]}' \
           '{"branch":"main","expected_head":"abc","message":"m","changes":[{"path":"a","content":"a"}]}' \
           '{"branch":"../main","expected_head":null,"message":"m","changes":[{"path":"a","content":"a"}]}' \
           '{"branch":"main","expected_head":null,"message":"m","author":{"name":"a<b","email":"x"},"changes":[{"path":"a","content":"a"}]}' \
           '{"branch":"main","message":"m","changes":[{"path":"a","content":"a"}]}'; do
  expect_eq "invalid commit body rejected" 400 "$(admin -X POST "$CB/commits" -d "$bad")"
done
python3 -c 'import sys; sys.stdout.write("{\"branch\":\"big\",\"expected_head\":null,\"message\":\"m\",\"changes\":[{\"path\":\"b\",\"content\":\"" + "a"*(17*1024*1024) + "\"}]}")' >"$WORK/big.json"
expect_eq "commit body over 16 MiB" 413 "$(admin -X POST "$CB/commits" --data-binary @"$WORK/big.json")"
expect_eq "create branch" 201 "$(admin -X POST "$CB/branches" -d '{"name":"try/1","from":"main"}')"
expect_eq "create existing branch" 409 "$(admin -X POST "$CB/branches" -d '{"name":"try/1","from":"main"}')"
expect_eq "create branch from nothing" 404 "$(admin -X POST "$CB/branches" -d '{"name":"try/2","from":"nope"}')"
expect_eq "delete with wrong expected" 409 "$(admin -X DELETE "$CB/branches/try/1?expected=$OTHER_MAIN")"
expect_eq "delete branch" 204 "$(admin -X DELETE "$CB/branches/try/1")"
expect_eq "delete missing branch" 404 "$(admin -X DELETE "$CB/branches/try/1")"
expect_eq "limited token cannot delete main" 403 "$(status -H "authorization: Bearer $LIM" -X DELETE "$CB/branches/main")"
expect_eq "branch events" "1 1" "$(count_events kind=branch_created) $(count_events kind=branch_deleted)"
expect_eq "no temp index files left" 0 "$(find "$DATA/tmp" -type f | wc -l | tr -d ' ')"
git -C "$LREPO" fetch -q "$(url "$FULL_OTHER" acme/other)" main 2>"$WORK/err" || fail "fetch after API commits: $(cat "$WORK/err")"
expect_eq "git sees API commits" "$WINNER" "$(git -C "$LREPO" rev-parse FETCH_HEAD)"

echo "== diff and merge"
newcommit() { # branch expected_json path content -> sha in $WORK/body
  printf '{"branch":"%s","expected_head":%s,"from":"main","message":"%s","changes":[{"path":"%s","content":"%s"}]}' "$1" "$2" "edit $3 on $1" "$3" "$4" >"$WORK/c.json"
  admin -X POST "$CB/commits" --data-binary @"$WORK/c.json"
}
mergereq() { # base head [expected_base_head] -> JSON file path
  python3 -c 'import json,sys; b={"base":sys.argv[1],"head":sys.argv[2]}; b.update({"expected_base_head":sys.argv[3]} if len(sys.argv)>3 else {}); print(json.dumps(b))' "$@" >"$WORK/m.json"
  echo "@$WORK/m.json"
}
head_of() { admin "$CB/branches" >/dev/null; python3 -c "import json; print(next(b['commit'] for b in json.load(open('$WORK/body'))['branches'] if b['name']=='$1'))"; }
expect_eq "compare" 200 "$(status -H "authorization: Bearer $READ_TOK" "$CB/compare/main...feature/x")"
expect_eq "compare ahead/behind" "1 0" "$(json '["ahead"]') $(json '["behind"]')"
expect_eq "compare files" "A f.txt 1" "$(json '["files"][0]["status"]') $(json '["files"][0]["path"]') $(json '["files"][0]["additions"]')"
grep -q '+f' <(json '["patch"]') || fail "compare patch"
pass "compare patch shows the added line"
expect_eq "compare without ..." 400 "$(admin "$CB/compare/main..feature/x")"
expect_eq "compare unknown ref" 404 "$(admin "$CB/compare/main...nope")"
expect_eq "UI compare" 200 "$(status "$BASE/ui/api/repos/acme/other/compare/main...feature/x")"
FX="$(head_of feature/x)"
expect_eq "fast-forward merge" 201 "$(admin -X POST "$CB/merges" -d '{"base":"main","head":"feature/x"}')"
expect_eq "fast-forward result" "fast_forward $FX" "$(json '["result"]') $(json '["sha"]')"
expect_eq "main moved to feature/x" "$FX" "$(head_of main)"
expect_eq "merging again is a no-op" 200 "$(admin -X POST "$CB/merges" -d '{"base":"main","head":"feature/x"}')"
expect_eq "up to date" up_to_date "$(json '["result"]')"
# agent/7/api forked before main moved, and touches other files: a real merge.
expect_eq "fast-forward only refused when diverged" 409 "$(admin -X POST "$CB/merges" -d '{"base":"main","head":"agent/7/api","strategy":"fast-forward"}')"
expect_eq "stale expected_base_head" 409 "$(admin -X POST "$CB/merges" --data-binary "$(mergereq main agent/7/api "$OTHER_MAIN")")"
expect_eq "limited token cannot merge into main" 403 "$(status -H "authorization: Bearer $LIM" -X POST "$CB/merges" -d '{"base":"main","head":"agent/7/api"}')"
expect_eq "merge commit" 201 "$(admin -X POST "$CB/merges" --data-binary "$(mergereq main agent/7/api "$FX")")"
MERGED="$(json '["sha"]')"
expect_eq "merge result" merged "$(json '["result"]')"
expect_eq "merge commit has two parents" "$FX $(head_of agent/7/api)" "$(admin "$CB/commits/$MERGED" >/dev/null; json '["parents"][0]') $(json '["parents"][1]')"
expect_eq "merged file on main" 200 "$(admin "$CB/files/a.txt")"
expect_eq "squash branch" 201 "$(newcommit sq null s.txt squash-me)"
expect_eq "squash merge" 201 "$(admin -X POST "$CB/merges" -d '{"base":"main","head":"sq","strategy":"squash","message":"Squash sq"}')"
SQ="$(json '["sha"]')"
expect_eq "squash has one parent" "1 $MERGED" "$(admin "$CB/commits/$SQ" >/dev/null; json '["parents"].__len__()') $(json '["parents"][0]')"
expect_eq "squash message" "Squash sq" "$(json '["subject"]')"
expect_eq "conflict branch" 201 "$(newcommit c1 null race.txt from-c1)"
expect_eq "main edits the same file" 201 "$(newcommit main "\"$SQ\"" race.txt from-main)"
MAIN_BEFORE="$(head_of main)"
expect_eq "conflicting merge" 409 "$(admin -X POST "$CB/merges" -d '{"base":"main","head":"c1"}')"
expect_eq "conflict lists the file" race.txt "$(json '["conflicts"][0]')"
expect_eq "conflict leaves main alone" "$MAIN_BEFORE" "$(head_of main)"
expect_eq "merge events" "3 1" "$(count_events kind=merge) $(count_events kind=merge_conflict)"
expect_eq "limited token merges into its own branch" 201 "$(status -H "authorization: Bearer $LIM" -X POST "$CB/merges" -d '{"base":"agent/7/api","head":"main"}')"

echo "== grep and archive"
expect_eq "grep seed commit" 201 "$(admin -X POST "$CB/commits" -d '{"branch":"grep/test","expected_head":null,"from":"main","message":"seed grep","changes":[{"path":"search/a.txt","content":"HelloWorld [bracket]\n-leading-dash\nneedle one\n"},{"path":"search/b.txt","content":"needle two\n"}]}')"
GREP_SHA="$(json '["sha"]')"
expect_eq "grep basic" 200 "$(status -H "authorization: Bearer $READ_TOK" "$CB/grep?ref=grep/test&q=needle")"
expect_eq "grep match count" 2 "$(json '["matches"].__len__()')"
expect_eq "grep not truncated" False "$(json '["truncated"]')"
expect_eq "grep commit" "$GREP_SHA" "$(json '["commit"]')"
expect_eq "grep first match" "search/a.txt 3 needle one" "$(json '["matches"][0]["path"]') $(json '["matches"][0]["line"]') $(json '["matches"][0]["text"]')"
expect_eq "grep limit truncates" 200 "$(admin "$CB/grep?ref=grep/test&q=needle&limit=1")"
expect_eq "grep truncated flag" "1 True" "$(json '["matches"].__len__()') $(json '["truncated"]')"
expect_eq "grep path filter" 200 "$(admin "$CB/grep?ref=grep/test&q=needle&path=search/b.txt")"
expect_eq "grep path count" "1 search/b.txt" "$(json '["matches"].__len__()') $(json '["matches"][0]["path"]')"
expect_eq "grep fixed strings" 200 "$(admin "$CB/grep?ref=grep/test&q=%5Bbracket%5D&fixed=1")"
expect_eq "grep fixed hit" 1 "$(json '["matches"].__len__()')"
expect_eq "grep bad regex" 400 "$(admin "$CB/grep?ref=grep/test&q=%5Bunclosed")"
expect_eq "grep ignore_case" 200 "$(admin "$CB/grep?ref=grep/test&q=helloworld&ignore_case=1")"
expect_eq "grep ignore_case hit" 1 "$(json '["matches"].__len__()')"
expect_eq "grep leading dash pattern" 200 "$(admin "$CB/grep?ref=grep/test&q=-leading-dash&fixed=1")"
expect_eq "grep leading dash hit" 1 "$(json '["matches"].__len__()')"
expect_eq "grep no matches" 200 "$(admin "$CB/grep?ref=grep/test&q=does-not-exist")"
expect_eq "grep empty matches" 0 "$(json '["matches"].__len__()')"
expect_eq "grep missing q" 400 "$(admin "$CB/grep?ref=grep/test")"
expect_eq "grep bad path" 400 "$(admin "$CB/grep?ref=grep/test&q=a&path=../x")"
expect_eq "grep unknown ref" 404 "$(admin "$CB/grep?ref=nope&q=a")"
expect_eq "grep without auth" 401 "$(status "$CB/grep?ref=grep/test&q=needle")"
expect_eq "UI grep" 200 "$(status "$BASE/ui/api/repos/acme/other/grep?ref=grep/test&q=needle")"
expect_eq "archive tar.gz" 200 "$(status -H "authorization: Bearer $READ_TOK" "$CB/archive?ref=grep/test")"
tar -tzf "$WORK/body" | grep -q '^search/a.txt$' || fail "tar.gz missing search/a.txt"
pass "tar.gz archive contains search/a.txt"
expect_eq "archive tar with path" 200 "$(admin "$CB/archive?ref=grep/test&format=tar&path=search")"
expect_eq "archive tar path entries" "search/a.txt search/b.txt" "$(tar -tf "$WORK/body" | grep -v '/$' | sort | tr '\n' ' ' | sed 's/ $//')"
expect_eq "archive zip" 200 "$(admin "$CB/archive?ref=grep/test&format=zip&path=search/a.txt")"
expect_eq "archive zip entry" "search/a.txt" "$(python3 -c 'import zipfile; print(" ".join(n for n in zipfile.ZipFile("'"$WORK"'/body").namelist() if not n.endswith("/")))')"
expect_eq "archive bad format" 400 "$(admin "$CB/archive?ref=grep/test&format=rar")"
expect_eq "archive missing path" 404 "$(admin "$CB/archive?ref=grep/test&path=no/such/file")"
expect_eq "archive without auth" 401 "$(status "$CB/archive?ref=grep/test")"
expect_eq "UI archive" 200 "$(status "$BASE/ui/api/repos/acme/other/archive?ref=grep/test&format=tar")"

echo "== expiring branches"
expires_of() { admin "$BASE/v1/repos/acme/other/branches" >/dev/null; python3 -c "import json; print(next((str(b['expires_at']) for b in json.load(open('$WORK/body'))['branches'] if b['name']=='$1'), 'gone'))"; }
EXPIRED_BEFORE="$(count_events kind=branch_expired)"
expect_eq "branch with ttl" 201 "$(admin -X POST "$CB/branches" -d '{"name":"ttl/api","from":"main","ttl_seconds":2}')"
[[ "$(expires_of ttl/api)" =~ ^[0-9]+$ ]] || fail "branch list lacks expires_at"
pass "branch list shows expires_at"
expect_eq "commit creating a branch with ttl" 201 "$(admin -X POST "$CB/commits" -d '{"branch":"ttl/commit","expected_head":null,"from":"main","message":"m","ttl_seconds":2,"changes":[{"path":"t.txt","content":"t"}]}')"
TTL_TOK="$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/other","scopes":["git:read","git:write"],"refs":["refs/heads/ttl/*","refs/heads/main"],"branch_ttl_seconds":2}' >/dev/null; json '["token"]')"
git -C "$LREPO" fetch -q "$(url "$FULL_OTHER" acme/other)" main 2>/dev/null
git -C "$LREPO" push -q "$(url "$TTL_TOK" acme/other)" FETCH_HEAD:refs/heads/ttl/push 2>"$WORK/err" || fail "push with ttl token: $(cat "$WORK/err")"
[[ "$(expires_of ttl/push)" =~ ^[0-9]+$ ]] || fail "pushed branch has no expiry"
pass "a branch created by push gets the token's ttl"
expect_eq "existing branches gain no expiry" None "$(expires_of main)"
expect_eq "branch deleted before it expires" 201 "$(admin -X POST "$CB/branches" -d '{"name":"ttl/gone","from":"main","ttl_seconds":2}')"
expect_eq "delete it now" 204 "$(admin -X DELETE "$CB/branches/ttl/gone")"
admin -X POST "$BASE/v1/repos" -d '{"name":"acme/doomed"}' >/dev/null
DOOMED_TOK="$(mint acme/doomed '["git:read","git:write"]')"
git -C "$LREPO" push -q "$(url "$DOOMED_TOK" acme/doomed)" FETCH_HEAD:refs/heads/main 2>/dev/null
expect_eq "branch in a repo about to be deleted" 201 "$(admin -X POST "$BASE/v1/repos/acme/doomed/branches" -d '{"name":"soon","from":"main","ttl_seconds":2}')"
expect_eq "delete that repo" 204 "$(admin -X DELETE "$BASE/v1/repos/acme/doomed")"
for bad in '{"name":"ttl/bad","from":"main","ttl_seconds":0}' '{"name":"ttl/bad","from":"main","ttl_seconds":604801}'; do
  expect_eq "invalid ttl rejected" 400 "$(admin -X POST "$CB/branches" -d "$bad")"
done
expect_eq "ttl with expected_head rejected" 400 "$(admin -X POST "$CB/commits" -d "{\"branch\":\"main\",\"expected_head\":\"$(head_of main)\",\"message\":\"m\",\"ttl_seconds\":5,\"changes\":[{\"path\":\"a\",\"content\":\"a\"}]}")"
expect_eq "invalid token branch_ttl_seconds" 400 "$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/other","scopes":["git:write"],"branch_ttl_seconds":-1}')"
sleep 4
expect_eq "api branch expired" gone "$(expires_of ttl/api)"
expect_eq "commit-created branch expired" gone "$(expires_of ttl/commit)"
expect_eq "pushed branch expired" gone "$(expires_of ttl/push)"
expect_eq "main survives" None "$(expires_of main)"
expect_eq "three expiries logged" "$((EXPIRED_BEFORE + 3))" "$(count_events kind=branch_expired)"

echo "== webhooks"
python3 "$(dirname "$0")/webhook_receiver.py" "$WORK/hooks.log" "$WORK/hooks.port" &
RECEIVER_PID=$!
for _ in $(seq 1 100); do [[ -s "$WORK/hooks.port" ]] && break; sleep 0.05; done
HP="$(cat "$WORK/hooks.port")"
admin -X POST "$BASE/v1/repos" -d '{"name":"acme/hooks"}' >/dev/null
HB="$BASE/v1/repos/acme/hooks"
hook() { admin -X POST "$HB/webhooks" -d "{\"url\":\"http://127.0.0.1:$HP$1\"}"; }
expect_eq "create webhook" 201 "$(hook /ok)"
HOOK_OK="$(json '["id"]')"; HOOK_SECRET="$(json '["secret"]')"
[[ "$HOOK_SECRET" == whsec_* ]] || fail "webhook secret format"
expect_eq "create flaky webhook" 201 "$(hook /fail/2)"
expect_eq "create dead webhook" 201 "$(hook /down)"
expect_eq "create hanging webhook" 201 "$(hook /hang)"
HOOK_HANG="$(json '["id"]')"
expect_eq "list webhooks" 200 "$(admin "$HB/webhooks")"
expect_eq "four webhooks" 4 "$(json '["webhooks"].__len__()')"
grep -q whsec_ "$WORK/body" && fail "webhook list shows secrets"
pass "webhook list hides secrets"
for bad in ftp://x/y /relative 'http://' 'javascript:alert(1)'; do
  expect_eq "invalid webhook url $bad" 400 "$(admin -X POST "$HB/webhooks" -d "{\"url\":\"$bad\"}")"
done
HOOKS_TOK="$(mint acme/hooks '["git:read","git:write"]')"
expect_eq "tokens cannot manage webhooks" 403 "$(status -H "authorization: Bearer $HOOKS_TOK" -X POST "$HB/webhooks" -d '{"url":"http://127.0.0.1:1/x"}')"
git -C "$LREPO" push -q "$(url "$HOOKS_TOK" acme/hooks)" FETCH_HEAD:refs/heads/main 2>"$WORK/err" || fail "push to acme/hooks: $(cat "$WORK/err")"
HOOKS_MAIN="$(git -C "$LREPO" rev-parse FETCH_HEAD)"
sleep 3
deliveries() { admin "$HB/webhooks/deliveries" >/dev/null; python3 -c "import json; print(' '.join(d['status']+':'+str(d['attempts']) for d in json.load(open('$WORK/body'))['deliveries'] if d['url'].endswith('$1') and d['event']['kind']=='$2'))"; }
expect_eq "push delivered once" "delivered:1" "$(deliveries /ok push)"
expect_eq "flaky endpoint delivered on the third try" "delivered:3" "$(deliveries /fail/2 push)"
expect_eq "dead endpoint gives up after 5 tries" "failed:5" "$(deliveries /down push)"
[[ "$(deliveries /hang push)" =~ ^(pending|sending):[1-9]$ ]] || fail "hanging endpoint: $(deliveries /hang push)"
admin "$HB/webhooks/deliveries" >/dev/null
expect_eq "hanging endpoint times out" "timed out" "$(python3 -c "import json; print(next(d['last_error'] for d in json.load(open('$WORK/body'))['deliveries'] if d['url'].endswith('/hang')))")"
python3 - "$WORK/hooks.log" "$HOOK_SECRET" "$HOOKS_MAIN" >"$WORK/sigcheck" <<'PY'
import hashlib, hmac, json, sys
log, secret, sha = sys.argv[1], sys.argv[2], sys.argv[3]
ok = [json.loads(l) for l in open(log) if json.loads(l)["path"] == "/ok"]
r = ok[0]
body = json.loads(r["body"])
want = "sha256=" + hmac.new(secret.encode(), r["body"].encode(), hashlib.sha256).hexdigest()
print("sig", r["headers"]["x-gitd-signature"] == want)
print("event", r["headers"]["x-gitd-event"], body["event"]["kind"], body["event"]["ref"], body["event"]["new"] == sha)
print("delivery", r["headers"]["x-gitd-delivery"] == str(body["delivery"]))
print("type", r["headers"]["content-type"])
PY
expect_eq "signature verifies" "sig True" "$(sed -n 1p "$WORK/sigcheck")"
expect_eq "payload is the push event" "event push push refs/heads/main True" "$(sed -n 2p "$WORK/sigcheck")"
expect_eq "delivery header matches body" "delivery True" "$(sed -n 3p "$WORK/sigcheck")"
expect_eq "content type" "type application/json" "$(sed -n 4p "$WORK/sigcheck")"
expect_eq "delete hanging webhook" 204 "$(admin -X DELETE "$HB/webhooks/$HOOK_HANG")"
expect_eq "delete it again" 404 "$(admin -X DELETE "$HB/webhooks/$HOOK_HANG")"
expect_eq "delete with a bad id" 400 "$(admin -X DELETE "$HB/webhooks/abc")"
OK_BEFORE="$(grep -c '"path": "/ok"' "$WORK/hooks.log")"
HANG_BEFORE="$(grep -c '"path": "/hang"' "$WORK/hooks.log")"
expect_eq "another event" 201 "$(admin -X POST "$HB/branches" -d '{"name":"b2","from":"main"}')"
sleep 1
expect_eq "remaining webhooks get it" "$((OK_BEFORE + 1))" "$(grep -c '"path": "/ok"' "$WORK/hooks.log")"
expect_eq "deleted webhook gets nothing" "$HANG_BEFORE" "$(grep -c '"path": "/hang"' "$WORK/hooks.log")"
expect_eq "UI deliveries" 200 "$(status "$BASE/ui/api/deliveries")"
grep -q whsec_ "$WORK/body" && fail "UI shows a webhook secret"
pass "UI deliveries hide secrets"
expect_eq "delete repo with webhooks" 204 "$(admin -X DELETE "$HB")"
expect_eq "recreate it" 201 "$(admin -X POST "$BASE/v1/repos" -d '{"name":"acme/hooks"}')"
expect_eq "old webhooks are gone" 0 "$(admin "$HB/webhooks" >/dev/null; json '["webhooks"].__len__()')"

echo "== review regressions"
# A token for one repo must not affect another repo through a body large
# enough to overwrite the request head (cross-repo writes and events).
admin -X POST "$BASE/v1/repos" -d '{"name":"acme/victim"}' >/dev/null
admin -X POST "$BASE/v1/repos" -d '{"name":"acme/evil"}' >/dev/null
VICTIM_TOK="$(mint acme/victim '["git:read","git:write"]')"
git -C "$LREPO" push -q "$(url "$VICTIM_TOK" acme/victim)" FETCH_HEAD:refs/heads/main 2>/dev/null || fail "seeding acme/victim"
EVIL_TOK="$(mint acme/evil '["git:read","git:write"]')"
VICTIM_EVENTS="$(count_events repo=acme/victim)"
for i in $(seq 0 15); do
  python3 -c "import json,sys; i=int(sys.argv[1]); print(json.dumps({'branch':'spray/%d'%i,'expected_head':None,'message':'m'*(i+1),'ttl_seconds':1,'changes':[{'path':'a','content':'acme/victim'*9000}]}))" "$i" >"$WORK/spray.json"
  [[ "$(status -H "authorization: Bearer $EVIL_TOK" -X POST "$BASE/v1/repos/acme/evil/commits" --data-binary @"$WORK/spray.json")" == 201 ]] || fail "spray commit $i"
done
sleep 2.5
expect_eq "no events land on another repo" "$VICTIM_EVENTS" "$(count_events repo=acme/victim)"
expect_eq "the other repo's main survives" 200 "$(admin "$BASE/v1/repos/acme/victim/tree?ref=main")"
expect_eq "the sprayed branches expired in their own repo" 16 "$(count_events repo=acme/evil kind=branch_expired)"
# A rejected push without report-status, from a token with long patterns,
# gets a 403 and the server stays up.
LONG_PAT="refs/heads/$(python3 -c 'print("a"*240)')"
LONG_TOK="$(admin -X POST "$BASE/v1/tokens" -d "{\"repo\":\"acme/victim\",\"scopes\":[\"git:write\"],\"refs\":[\"$LONG_PAT/*\",\"$LONG_PAT/b/*\"]}" >/dev/null; json '["token"]')"
python3 - "$PORT" "$LONG_TOK" >"$WORK/raw2" <<'PY'
import base64, socket, sys
port, token = int(sys.argv[1]), sys.argv[2]
auth = base64.b64encode(f"t:{token}".encode()).decode()
line = f"{'0'*40} {'1'*40} refs/heads/main\0ofs-delta\n".encode()
body = b"%04x" % (len(line) + 4) + line + b"0000"
s = socket.create_connection(("127.0.0.1", port))
s.sendall((f"POST /acme/victim.git/git-receive-pack HTTP/1.1\r\nHost: x\r\nAuthorization: Basic {auth}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode() + body)
data = b""
while chunk := s.recv(65536):
    data += chunk
print(data.split(b"\r\n")[0].decode())
PY
expect_eq "long rejection reason without report-status" "HTTP/1.1 403 Forbidden" "$(cat "$WORK/raw2")"
expect_eq "server still up" 200 "$(status "$BASE/healthz")"
# Paths reach git literally (no C-unquoting), and a path git refuses is a
# 400, never a 201 that silently drops the file.
python3 -c 'import json; print(json.dumps({"branch":"q","expected_head":None,"from":"main","message":"q","changes":[{"path":"\"a\\033b\"","content":"q"}]}))' >"$WORK/q.json"
expect_eq "quoted-looking path committed literally" 201 "$(admin -X POST "$BASE/v1/repos/acme/victim/commits" --data-binary @"$WORK/q.json")"
admin "$BASE/v1/repos/acme/victim/tree?ref=q" >/dev/null
python3 -c 'import json,sys; e=[x["name"] for x in json.load(open(sys.argv[1]))["entries"]]; sys.exit(0 if "\"a\\033b\"" in e else 1)' "$WORK/body" || fail "the quoted path was not stored literally: $(cat "$WORK/body")"
pass "literal name in tree"
LOOKALIKE="$(admin -X POST "$BASE/v1/repos/acme/victim/commits" -d '{"branch":"q2","expected_head":null,"from":"main","message":"q","changes":[{"path":".git\u200c/config","content":"x"}]}')"
if [[ "$LOOKALIKE" == 201 ]]; then
  admin "$BASE/v1/repos/acme/victim/tree?ref=q2" >/dev/null
  python3 -c "import json; e=[x['name'] for x in json.load(open('$WORK/body'))['entries']]; assert any(n.startswith('.git') for n in e), e" || fail "201 but the file is missing"
else
  expect_eq "path git refuses is a 400" 400 "$LOOKALIKE"
fi
pass "a .git look-alike is committed in full or refused, never dropped"
expect_eq "NUL in message" 400 "$(admin -X POST "$BASE/v1/repos/acme/victim/commits" -d '{"branch":"n","expected_head":null,"message":"a\u0000b","changes":[{"path":"a","content":"a"}]}')"
expect_eq "branch name ending in a dot" 400 "$(admin -X POST "$BASE/v1/repos/acme/victim/branches" -d '{"name":"x.","from":"main"}')"
# log?path= walks history, not just the tip.
VH="$(admin "$BASE/v1/repos/acme/victim/branches" >/dev/null; python3 -c "import json; print(next(b['commit'] for b in json.load(open('$WORK/body'))['branches'] if b['name']=='main'))")"
for n in 1 2 3; do
  printf '{"branch":"main","expected_head":"%s","message":"readme %s","changes":[{"path":"README","content":"%s"}]}' "$VH" "$n" "$n" >"$WORK/r.json"
  admin -X POST "$BASE/v1/repos/acme/victim/commits" --data-binary @"$WORK/r.json" >/dev/null; VH="$(json '["sha"]')"
done
printf '{"branch":"main","expected_head":"%s","message":"other","changes":[{"path":"OTHER","content":"o"}]}' "$VH" >"$WORK/r.json"
admin -X POST "$BASE/v1/repos/acme/victim/commits" --data-binary @"$WORK/r.json" >/dev/null
expect_eq "log for a path lists every commit touching it" "readme 3 readme 2 readme 1" "$(admin "$BASE/v1/repos/acme/victim/log?path=README" >/dev/null; python3 -c "import json; print(' '.join(c['subject'] for c in json.load(open('$WORK/body'))['commits']))")"
# A token's branch_ttl_seconds also covers branches it makes through the API.
TTL_API_TOK="$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/victim","scopes":["git:read","git:write"],"branch_ttl_seconds":60}' >/dev/null; json '["token"]')"
expect_eq "API branch with a ttl token" 201 "$(status -H "authorization: Bearer $TTL_API_TOK" -X POST "$BASE/v1/repos/acme/victim/branches" -d '{"name":"by-token","from":"main"}')"
[[ "$(admin "$BASE/v1/repos/acme/victim/branches" >/dev/null; python3 -c "import json; print(next(b['expires_at'] for b in json.load(open('$WORK/body'))['branches'] if b['name']=='by-token'))")" =~ ^[0-9]+$ ]] || fail "token ttl not applied to API branch"
pass "token ttl applies to API-created branches"
# An expiry dies with its repo: recreating the repo does not inherit it.
admin -X POST "$BASE/v1/repos" -d '{"name":"acme/reborn"}' >/dev/null
REBORN_TOK="$(mint acme/reborn '["git:read","git:write"]')"
git -C "$LREPO" push -q "$(url "$REBORN_TOK" acme/reborn)" FETCH_HEAD:refs/heads/main 2>/dev/null
admin -X POST "$BASE/v1/repos/acme/reborn/branches" -d '{"name":"keep","from":"main","ttl_seconds":2}' >/dev/null
admin -X DELETE "$BASE/v1/repos/acme/reborn" >/dev/null
admin -X POST "$BASE/v1/repos" -d '{"name":"acme/reborn"}' >/dev/null
REBORN_TOK="$(mint acme/reborn '["git:read","git:write"]')"
git -C "$LREPO" push -q "$(url "$REBORN_TOK" acme/reborn)" FETCH_HEAD:refs/heads/main FETCH_HEAD:refs/heads/keep 2>/dev/null
sleep 3
expect_eq "recreated repo keeps its same-named branch" 200 "$(admin "$BASE/v1/repos/acme/reborn/tree?ref=keep")"
# DNS rebinding: a loopback peer with a foreign Host is refused.
expect_eq "UI with a foreign Host" 403 "$(status -H 'Host: evil.example:80' "$BASE/ui/api/state")"
expect_eq "UI with localhost Host" 200 "$(status -H "Host: localhost:$PORT" "$BASE/ui/api/state")"

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

# A head trickled in one byte a second (under the idle timeout) is still cut
# off by the head timeout (3s here).
python3 - "$PORT" <<'PY' || fail "slow head was not cut off"
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
start = time.time()
try:
    for b in b"GET /healthz HTTP/1.1\r\nHost: x\r\nX-Pad: " + b"a" * 30:
        s.sendall(bytes([b]))
        time.sleep(1)
        if time.time() - start > 8:
            sys.exit(1)
except (BrokenPipeError, ConnectionResetError):
    pass
sys.exit(0 if time.time() - start < 6 else 1)
PY
pass "slow request head cut off by the head timeout"
# One address gets at most 64 connections; the rest are closed at once.
python3 - "$PORT" <<'PY' || fail "per-address connection cap"
import socket, sys, time
port = int(sys.argv[1])
socks = [socket.create_connection(("127.0.0.1", port)) for _ in range(70)]
time.sleep(0.5)
closed = 0
for s in socks:
    s.setblocking(False)
    try:
        if s.recv(1) == b"":
            closed += 1
    except BlockingIOError:
        pass
    except ConnectionResetError:
        closed += 1
for s in socks:
    s.close()
print("closed", closed)
sys.exit(0 if closed == 6 else 1)
PY
pass "65th connection from one address is refused"
sleep 0.5
expect_eq "server serves after the connection-cap test" 200 "$(status "$BASE/healthz")"
# A body on info/refs is refused before git runs, even when cut off, and
# does not take the server down.
python3 - "$PORT" "$RO" <<'PY'
import base64, socket, sys, time
port, token = int(sys.argv[1]), sys.argv[2]
auth = base64.b64encode(f"t:{token}".encode()).decode()
s = socket.create_connection(("127.0.0.1", port))
s.sendall((f"GET /acme/web.git/info/refs?service=git-upload-pack HTTP/1.1\r\nHost: x\r\n"
           f"Authorization: Basic {auth}\r\nContent-Length: 1000\r\n\r\n").encode() + b"0123456789")
time.sleep(0.3)
s.close()
PY
sleep 0.3
expect_eq "server survives a cut-off body on info/refs" 200 "$(status "$BASE/healthz")"
expect_eq "info/refs with a body" 400 "$(status -u "t:$RO" -X GET --data-binary 'x' "$BASE/acme/web.git/info/refs?service=git-upload-pack")"
# A JSON body cut short of its Content-Length creates nothing.
python3 - "$PORT" "$KEY" <<'PY'
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
body = b'{"name":"acme/cut"}'
s.sendall(f"POST /v1/repos HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {sys.argv[2]}\r\nContent-Length: 500\r\n\r\n".encode() + body)
s.shutdown(socket.SHUT_WR)
time.sleep(0.3)
s.close()
PY
expect_eq "truncated JSON body creates no repo" 404 "$(admin "$BASE/v1/repos/acme/cut")"

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
# git processes a gitd request starts: command lines that begin with a git
# binary, possibly by full path (Xcode's git runs as .../usr/bin/git), then
# http-backend, upload-pack, or pack-objects. Anchoring at the start keeps
# shells and scripts that merely mention these names from matching.
leftover() { ps -eo args= | grep -E "^([^ ]*/)?git[ -](http-backend|upload-pack|pack-objects)" || true; }
for _ in $(seq 1 40); do [[ -z "$(leftover)" ]] && break; sleep 0.1; done
[[ -z "$(leftover)" ]] || fail "git processes left after an interrupted clone: $(leftover)"
pass "interrupted clone leaves no git processes"
# A client that asks for a clone and never reads is dropped once writes
# stall past the idle timeout (2s here), and its git processes go with it.
python3 - "$PORT" "$RO" "$TIP" <<'PY' &
import base64, socket, sys, time
port, token, tip = int(sys.argv[1]), sys.argv[2], sys.argv[3]
auth = base64.b64encode(f"t:{token}".encode()).decode()
body = f"0032want {tip}\n00000009done\n".encode()
s = socket.create_connection(("127.0.0.1", port))
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
s.sendall((f"POST /acme/web.git/git-upload-pack HTTP/1.1\r\nHost: x\r\nAuthorization: Basic {auth}\r\n"
           f"Content-Type: application/x-git-upload-pack-request\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body)
time.sleep(9)
s.close()
PY
STALLED=$!
sleep 1
[[ -n "$(leftover)" ]] || fail "stalled-reader test: clone never started"
for _ in $(seq 1 60); do [[ -z "$(leftover)" ]] && break; sleep 0.1; done
[[ -z "$(leftover)" ]] || fail "git processes kept alive by a client that stopped reading: $(leftover)"
pass "client that stops reading is dropped and its git processes killed"
wait "$STALLED" || true
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

echo "== activity log and UI"
expect_eq "UI page served" 200 "$(status "$BASE/ui")"
grep -q "<title>gitd</title>" "$WORK/body" || fail "UI page content"
expect_eq "UI state" 200 "$(status "$BASE/ui/api/state")"
UI_REPOS="$(json '["repos"].__len__()')"
expect_eq "UI state lists every repo the API lists" "$(admin "$BASE/v1/repos" >/dev/null; json '["repos"].__len__()')" "$UI_REPOS"
expect_eq "repo_created events" 10 "$(count_events kind=repo_created)"
expect_eq "repo_deleted event" 1 "$(count_events kind=repo_deleted repo=acme/web)"
expect_eq "first push recorded with its commit" 1 "$(count_events kind=push repo=acme/web ref=refs/heads/main detail=created)"
AGENT_PUSHES="$(events; python3 -c "import json; print(sum(1 for e in json.load(open('$WORK/body'))['events'] if e['kind']=='push' and e['repo']=='acme/web' and e['ref'].startswith('refs/heads/agent/')))")"
expect_eq "agent branch pushes recorded" 8 "$AGENT_PUSHES"
# A push git refuses (not a fast-forward) is not recorded.
FRESH="$WORK/fresh"
git "${GIT_ID[@]}" init -q "$FRESH"
echo one >"$FRESH/f.txt"; git -C "$FRESH" add f.txt; git "${GIT_ID[@]}" -C "$FRESH" commit -qm one
git -C "$FRESH" push -q "$(url "$RW" acme/web)" main 2>"$WORK/err" || fail "push to recreated repo: $(cat "$WORK/err")"
expect_eq "push to recreated repo recorded" 1 "$(count_events kind=push repo=acme/web ref=refs/heads/main new="$(git -C "$FRESH" rev-parse HEAD)")"
# Only refs git actually moved are recorded. Make the server refuse a push:
# between the ref check and the upload, a pre-push hook moves main from
# another clone, so the push arrives with a stale old value.
OTHER_CLONE="$WORK/other-clone"
git clone -q "$(url "$RW" acme/web)" "$OTHER_CLONE"
echo two >"$OTHER_CLONE/f.txt"; git "${GIT_ID[@]}" -C "$OTHER_CLONE" commit -qam two
echo mine >"$FRESH/f.txt"; git "${GIT_ID[@]}" -C "$FRESH" commit -qam mine
printf '#!/bin/sh\ngit -C "%s" push -q origin main\n' "$OTHER_CLONE" >"$FRESH/.git/hooks/pre-push"
chmod +x "$FRESH/.git/hooks/pre-push"
BEFORE="$(count_events kind=push)"
if git -C "$FRESH" push -q "$(url "$RW" acme/web)" main 2>/dev/null; then fail "stale push was accepted"; fi
rm "$FRESH/.git/hooks/pre-push"
expect_eq "only the push git applied is recorded" "$((BEFORE + 1))" "$(count_events kind=push)"
expect_eq "the recorded push is the one that won" 1 "$(count_events kind=push repo=acme/web new="$(git -C "$OTHER_CLONE" rev-parse HEAD)")"
for f in "$WORK/body"; do
  curl -s "$BASE/ui/api/state" >"$f.state"; curl -s "$BASE/ui" >"$f.page"; events
  if grep -qF "$KEY" "$f" "$f.state" "$f.page" || grep -qF "$RW" "$f" "$f.state" "$f.page"; then fail "a secret appears in the UI"; fi
done
pass "UI responses contain no keys or tokens"
# Without --ui the page does not exist.
"$BIN" serve --data "$WORK/noui" --listen 127.0.0.1:0 >"$WORK/noui.log" 2>&1 &
NOUI=$!
for _ in $(seq 1 100); do NOUI_PORT="$(sed -n 's/.*listening on 127\.0\.0\.1:\([0-9]*\),.*/\1/p' "$WORK/noui.log")"; [[ -n "$NOUI_PORT" ]] && break; sleep 0.05; done
expect_eq "no UI without --ui" 404 "$(status "http://127.0.0.1:$NOUI_PORT/ui")"
kill -TERM "$NOUI"; wait "$NOUI" || true

echo "== upstream sync"
sync_body() { # direction url branch [token]
  if [[ -n "${4:-}" ]]; then
    printf '{"direction":"%s","url":"%s","branch":"%s","token":"%s"}' "$1" "$2" "$3" "$4"
  else
    printf '{"direction":"%s","url":"%s","branch":"%s"}' "$1" "$2" "$3"
  fi
}
expect_eq "create mirror repo" 201 "$(admin -X POST "$BASE/v1/repos" -d '{"name":"acme/mirror"}')"
UP_TOK="$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/other","scopes":["git:read","git:write"],"ttl_seconds":3600}' >/dev/null; json '["token"]')"
UP_MAIN="$(head_of main)"
expect_eq "sync fetch from upstream" 200 "$(admin -X POST "$BASE/v1/repos/acme/mirror/sync" -d "$(sync_body fetch "$BASE/acme/other.git" main "$UP_TOK")")"
expect_eq "sync fetch new_sha matches upstream" "$UP_MAIN" "$(json '["new_sha"]')"
expect_eq "mirror has upstream file" 200 "$(admin "$BASE/v1/repos/acme/mirror/files/notes/a.md")"
expect_eq "mirror agent commit on branch" 201 "$(admin -X POST "$BASE/v1/repos/acme/mirror/commits" -d '{"branch":"agent/sync/fix","expected_head":null,"from":"main","message":"sync fix","changes":[{"path":"synced.txt","content":"from mirror\n"}]}')"
SYNC_SHA="$(json '["sha"]')"
expect_eq "sync push branch back to upstream" 200 "$(admin -X POST "$BASE/v1/repos/acme/mirror/sync" -d "$(sync_body push "$BASE/acme/other.git" agent/sync/fix "$UP_TOK")")"
expect_eq "sync push sha" "$SYNC_SHA" "$(json '["sha"]')"
expect_eq "upstream received pushed file" 200 "$(admin "$CB/files/synced.txt?ref=agent/sync/fix")"
expect_eq "upstream file content" "from mirror" "$(cat "$WORK/body")"
expect_eq "sync events logged" "1 1" "$(count_events kind=sync_fetch repo=acme/mirror) $(count_events kind=sync_push repo=acme/mirror)"
expect_eq "sync requires admin key" 403 "$(status -H "authorization: Bearer $UP_TOK" -X POST "$BASE/v1/repos/acme/mirror/sync" -d "$(sync_body fetch "$BASE/acme/other.git" main)")"
expect_eq "sync rejects file:// URL" 400 "$(admin -X POST "$BASE/v1/repos/acme/mirror/sync" -d '{"direction":"fetch","url":"file:///etc/passwd","branch":"main"}')"
expect_eq "sync rejects embedded credentials" 400 "$(admin -X POST "$BASE/v1/repos/acme/mirror/sync" -d '{"direction":"fetch","url":"https://u:p@example.com/r.git","branch":"main"}')"
expect_eq "sync rejects bad direction" 400 "$(admin -X POST "$BASE/v1/repos/acme/mirror/sync" -d "$(sync_body clone "$BASE/acme/other.git" main)")"
expect_eq "sync push missing branch" 404 "$(admin -X POST "$BASE/v1/repos/acme/mirror/sync" -d "$(sync_body push "$BASE/acme/other.git" no-such-branch "$UP_TOK")")"

echo "== private branches (read_refs)"
expect_eq "secret branch commit" 201 "$(admin -X POST "$CB/commits" -d '{"branch":"secret/internal","expected_head":null,"from":"main","message":"top secret","changes":[{"path":"secret.txt","content":"classified\n"}]}')"
SECRET_SHA="$(json '["sha"]')"
PRIV_TOK="$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/other","scopes":["git:read","git:write"],"refs":["refs/heads/agent/7/*"],"read_refs":["refs/heads/main","refs/heads/agent/7/*"],"ttl_seconds":300}' >/dev/null; json '["token"]')"
expect_eq "read_refs branches list" 200 "$(status -H "authorization: Bearer $PRIV_TOK" "$CB/branches")"
expect_eq "secret branch hidden from /branches" "0" "$(python3 -c 'import json; print(sum(1 for b in json.load(open("'"$WORK"'/body"))["branches"] if b["name"]=="secret/internal"))')"
expect_eq "main visible in /branches" "1" "$(python3 -c 'import json; print(sum(1 for b in json.load(open("'"$WORK"'/body"))["branches"] if b["name"]=="main"))')"
expect_eq "read_refs allows reading main file" 200 "$(status -H "authorization: Bearer $PRIV_TOK" "$CB/files/notes/a.md?ref=main")"
expect_eq "read_refs blocks hidden branch file" 403 "$(status -H "authorization: Bearer $PRIV_TOK" "$CB/files/secret.txt?ref=secret/internal")"
expect_eq "read_refs blocks hidden branch grep" 403 "$(status -H "authorization: Bearer $PRIV_TOK" "$CB/grep?ref=secret/internal&q=classified")"
expect_eq "read_refs blocks hidden branch archive" 403 "$(status -H "authorization: Bearer $PRIV_TOK" "$CB/archive?ref=secret/internal")"
expect_eq "read_refs blocks hidden branch compare" 403 "$(status -H "authorization: Bearer $PRIV_TOK" "$CB/compare/main...secret/internal")"
expect_eq "read_refs blocks raw SHA commit lookup" 403 "$(status -H "authorization: Bearer $PRIV_TOK" "$CB/commits/$SECRET_SHA")"
expect_eq "read_refs blocks raw SHA ref param" 403 "$(status -H "authorization: Bearer $PRIV_TOK" "$CB/files/secret.txt?ref=$SECRET_SHA")"
expect_eq "read_refs blocks branching from hidden ref" 403 "$(status -H "authorization: Bearer $PRIV_TOK" -X POST "$CB/branches" -d '{"name":"agent/7/leak","from":"secret/internal"}')"
expect_eq "read_refs blocks merging from hidden ref" 403 "$(status -H "authorization: Bearer $PRIV_TOK" -X POST "$CB/merges" -d '{"base":"agent/7/api","head":"secret/internal"}')"
# Real git client checks (R5.2)
LS_OUT="$(git ls-remote "$(url "$PRIV_TOK" acme/other)" 2>"$WORK/err")" || fail "git ls-remote with read_refs: $(cat "$WORK/err")"
echo "$LS_OUT" | grep -q "refs/heads/main" || fail "git ls-remote missing allowed main"
echo "$LS_OUT" | grep -q "secret/internal" && fail "git ls-remote leaked hidden branch"
pass "git ls-remote hides private branches"
PRIV_CLONE="$WORK/priv-clone"
git clone -q "$(url "$PRIV_TOK" acme/other)" "$PRIV_CLONE" 2>"$WORK/err" || fail "git clone with read_refs: $(cat "$WORK/err")"
if git -C "$PRIV_CLONE" fetch -q origin refs/heads/secret/internal 2>/dev/null; then fail "git fetch retrieved hidden branch"; fi
if git -C "$PRIV_CLONE" fetch -q origin "$SECRET_SHA" 2>/dev/null; then fail "git fetch retrieved hidden SHA"; fi
pass "git fetch cannot retrieve hidden branch or SHA"

echo "== path-scoped permissions (paths)"
expect_eq "seed docs and secrets" 201 "$(admin -X POST "$CB/commits" -d '{"branch":"path/test","expected_head":null,"from":"main","message":"seed paths","changes":[{"path":"docs/guide.md","content":"public doc token-word\n"},{"path":"secrets/prod.env","content":"SECRET=topsecret token-word\n"}]}')"
PATH_BASE="$(json '["sha"]')"
PATH_TOK="$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/other","scopes":["git:read","git:write"],"refs":["refs/heads/path/*"],"paths":["docs/*"],"ttl_seconds":300}' >/dev/null; json '["token"]')"
expect_eq "paths allows reading docs/guide.md" 200 "$(status -H "authorization: Bearer $PATH_TOK" "$CB/files/docs/guide.md?ref=path/test")"
expect_eq "paths blocks reading secrets/prod.env" 403 "$(status -H "authorization: Bearer $PATH_TOK" "$CB/files/secrets/prod.env?ref=path/test")"
expect_eq "paths root tree hides secrets dir" 200 "$(status -H "authorization: Bearer $PATH_TOK" "$CB/tree?ref=path/test")"
expect_eq "paths root tree only shows docs" "docs" "$(python3 -c 'import json; print(" ".join(e["name"] for e in json.load(open("'"$WORK"'/body"))["entries"]))')"
expect_eq "paths blocks secrets tree" 403 "$(status -H "authorization: Bearer $PATH_TOK" "$CB/tree/secrets?ref=path/test")"
expect_eq "paths grep filters out secrets" 200 "$(status -H "authorization: Bearer $PATH_TOK" "$CB/grep?ref=path/test&q=token-word")"
expect_eq "paths grep only hits docs/guide.md" "1 docs/guide.md" "$(json '["matches"].__len__()') $(json '["matches"][0]["path"]')"
expect_eq "paths archive requires allowed path" 403 "$(status -H "authorization: Bearer $PATH_TOK" "$CB/archive?ref=path/test")"
expect_eq "paths archive allows docs" 200 "$(status -H "authorization: Bearer $PATH_TOK" "$CB/archive?ref=path/test&path=docs&format=tar")"
expect_eq "paths archive only contains docs/guide.md" "docs/guide.md" "$(tar -tf "$WORK/body" | grep -v '/$' | tr '\n' ' ' | sed 's/ $//')"
expect_eq "paths blocks raw git clone" 403 "$(status -u "t:$PATH_TOK" "$BASE/acme/other.git/info/refs?service=git-upload-pack")"
expect_eq "paths blocks commit touching secrets" 403 "$(status -H "authorization: Bearer $PATH_TOK" -X POST "$CB/commits" -d "$(commit_body path/test "\"$PATH_BASE\"" bad '[{"path":"secrets/prod.env","content":"pwned"}]')")"
expect_eq "paths allows commit touching docs" 201 "$(status -H "authorization: Bearer $PATH_TOK" -X POST "$CB/commits" -d "$(commit_body path/test "\"$PATH_BASE\"" "update doc" '[{"path":"docs/guide.md","content":"updated doc\n"}]')")"
expect_eq "hidden file preserved intact after path-scoped commit" 200 "$(admin "$CB/files/secrets/prod.env?ref=path/test")"
expect_eq "hidden file content unchanged" "SECRET=topsecret token-word" "$(cat "$WORK/body")"

echo "== token revocation and branch locks"
expect_eq "mint revocable token" 201 "$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/other","scopes":["git:read","git:write"],"ttl_seconds":300}')"
REV_TOK="$(json '["token"]')"
REV_JTI="$(json '["jti"]')"
expect_eq "token works before revoke" 200 "$(status -H "authorization: Bearer $REV_TOK" "$CB/branches")"
git ls-remote "$(url "$REV_TOK" acme/other)" >/dev/null 2>"$WORK/err" || fail "git ls-remote before revoke"
expect_eq "revoke token" 204 "$(admin -X POST "$BASE/v1/tokens/$REV_JTI/revoke")"
expect_eq "revoked token rejected on API" 401 "$(status -H "authorization: Bearer $REV_TOK" "$CB/branches")"
if git ls-remote "$(url "$REV_TOK" acme/other)" >/dev/null 2>&1; then fail "revoked token still worked for git"; fi
pass "revoked token rejected on git smart HTTP"
expect_eq "lock branch requires admin key" 403 "$(status -H "authorization: Bearer $FULL_OTHER" -X PUT "$CB/branches/path/test/lock" -d '{"reason":"freeze"}')"
expect_eq "lock branch" 200 "$(admin -X PUT "$CB/branches/path/test/lock" -d '{"reason":"release freeze"}')"
LOCK_HEAD="$(head_of path/test)"
expect_eq "locked branch blocks API commit" 423 "$(admin -X POST "$CB/commits" -d "$(commit_body path/test "\"$LOCK_HEAD\"" blocked '[{"path":"docs/x.md","content":"x"}]')")"
expect_eq "locked branch blocks API delete" 423 "$(admin -X DELETE "$CB/branches/path/test")"
# Real git push to locked branch is rejected (R5.2)
LOCK_CLONE="$WORK/lock-clone"
git clone -q "$(url "$FULL_OTHER" acme/other)" "$LOCK_CLONE" 2>"$WORK/err" || fail "clone for lock test"
git -C "$LOCK_CLONE" checkout -q -B path/test origin/path/test
echo locked >>"$LOCK_CLONE/docs/guide.md"
git -C "$LOCK_CLONE" add -A
git "${GIT_ID[@]}" -C "$LOCK_CLONE" commit -qm "try locked push"
if git -C "$LOCK_CLONE" push -q origin path/test 2>"$WORK/lock.err"; then fail "git push succeeded on locked branch"; fi
grep -q "branch is locked" "$WORK/lock.err" || fail "missing lock message: $(cat "$WORK/lock.err")"
pass "git push rejected on locked branch"
expect_eq "unlock branch" 204 "$(admin -X DELETE "$CB/branches/path/test/lock")"
expect_eq "unlock again is 404" 404 "$(admin -X DELETE "$CB/branches/path/test/lock")"
git -C "$LOCK_CLONE" push -q origin path/test 2>"$WORK/err" || fail "git push after unlock: $(cat "$WORK/err")"
pass "git push succeeds after unlock"
expect_eq "lock events logged" "1 1" "$(count_events kind=branch_locked repo=acme/other) $(count_events kind=branch_unlocked repo=acme/other)"

echo "== branch protection rules"
expect_eq "GET branches shows unlocked main" "False None" "$(admin "$CB/branches" >/dev/null; python3 -c "import json; b=next(x for x in json.load(open('$WORK/body'))['branches'] if x['name']=='main'); print(b['locked'], b['lock_reason'])")"
admin -X PUT "$CB/branches/path/test/lock" -d '{"reason":"inspect freeze"}' >/dev/null
expect_eq "GET branches shows locked and reason" "True inspect freeze" "$(admin "$CB/branches" >/dev/null; python3 -c "import json; b=next(x for x in json.load(open('$WORK/body'))['branches'] if x['name']=='path/test'); print(b['locked'], b['lock_reason'])")"
admin -X DELETE "$CB/branches/path/test/lock" >/dev/null

admin -X POST "$BASE/v1/repos" -d '{"name":"acme/rules"}' >/dev/null
RB="$BASE/v1/repos/acme/rules"
RTOK="$(mint acme/rules '["git:read","git:write"]')"
RCLONE="$WORK/rules-clone"
git "${GIT_ID[@]}" init -q "$RCLONE"
echo "init" >"$RCLONE/f.txt"; git -C "$RCLONE" add f.txt; git "${GIT_ID[@]}" -C "$RCLONE" commit -qm "seed rules"
git -C "$RCLONE" push -q "$(url "$RTOK" acme/rules)" main 2>"$WORK/err" || fail "seeding acme/rules: $(cat "$WORK/err")"

expect_eq "rules require admin key" 403 "$(status -H "authorization: Bearer $RTOK" "$RB/rules")"
expect_eq "invalid rule pattern" 400 "$(admin -X POST "$RB/rules" -d '{"pattern":"main"}')"
expect_eq "invalid merge strategy" 400 "$(admin -X POST "$RB/rules" -d '{"pattern":"refs/heads/main","required_merge_strategy":"rebase"}')"
expect_eq "create main rule" 201 "$(admin -X POST "$RB/rules" -d '{"pattern":"refs/heads/main","allow_direct_push":false,"allow_force_push":false,"allow_delete":false,"required_merge_strategy":"squash"}')"
MAIN_RULE_ID="$(json '["id"]')"
expect_eq "create release rule" 201 "$(admin -X POST "$RB/rules" -d '{"pattern":"refs/heads/release/*","allow_direct_push":true,"allow_force_push":false,"allow_delete":false}')"
expect_eq "list rules shows two" 2 "$(admin "$RB/rules" >/dev/null; json '["rules"].__len__()')"

RHEAD="$(git -C "$RCLONE" rev-parse HEAD)"
expect_eq "direct API commit blocked by rule" 403 "$(admin -X POST "$RB/commits" -d "$(commit_body main "\"$RHEAD\"" nope '[{"path":"f.txt","content":"x"}]')")"
expect_eq "branch delete API blocked by rule" 403 "$(admin -X DELETE "$RB/branches/main")"

echo "direct push" >"$RCLONE/f.txt"; git "${GIT_ID[@]}" -C "$RCLONE" commit -qam "direct"
if git -C "$RCLONE" push "$(url "$RTOK" acme/rules)" main >"$WORK/rulepush.out" 2>&1; then fail "direct git push to protected main succeeded"; fi
grep -q "branch rule forbids direct push" "$WORK/rulepush.out" || fail "missing rule message on direct git push: $(cat "$WORK/rulepush.out")"
pass "git push blocked on protected main"
if git -C "$RCLONE" push "$(url "$RTOK" acme/rules)" :refs/heads/main >"$WORK/ruledel.out" 2>&1; then fail "git delete on protected main succeeded"; fi
grep -q "branch rule forbids deleting" "$WORK/ruledel.out" || fail "missing rule message on git delete: $(cat "$WORK/ruledel.out")"
pass "git branch delete blocked on protected main"

# Release branch allows fast-forward push, blocks force push and delete
git -C "$RCLONE" reset -q --hard HEAD~1
git -C "$RCLONE" push -q "$(url "$RTOK" acme/rules)" main:refs/heads/release/v1 2>"$WORK/err" || fail "initial release push: $(cat "$WORK/err")"
echo "v1.1" >"$RCLONE/f.txt"; git "${GIT_ID[@]}" -C "$RCLONE" commit -qam "v1.1"
git -C "$RCLONE" push -q "$(url "$RTOK" acme/rules)" main:refs/heads/release/v1 2>"$WORK/err" || fail "ff push to release: $(cat "$WORK/err")"
pass "fast-forward git push allowed on release/*"
git "${GIT_ID[@]}" -C "$RCLONE" commit --amend -qm "rewritten v1.1"
if git -C "$RCLONE" push --force "$(url "$RTOK" acme/rules)" main:refs/heads/release/v1 >"$WORK/force.out" 2>&1; then fail "force push to release/* succeeded"; fi
grep -qE "non-fast-forward|denied" "$WORK/force.out" || fail "missing non-ff rejection on force push: $(cat "$WORK/force.out")"
pass "force push blocked on allow_force_push=false branch"
if git -C "$RCLONE" push "$(url "$RTOK" acme/rules)" :refs/heads/release/v1 2>/dev/null; then fail "delete push to release/* succeeded"; fi
pass "delete git push blocked on release/*"

# Merge strategy enforcement on main
expect_eq "feature branch commit" 201 "$(admin -X POST "$RB/commits" -d '{"branch":"feat/1","expected_head":null,"from":"main","message":"feat commit","changes":[{"path":"feat.txt","content":"feat\n"}]}')"
expect_eq "disallowed merge strategy rejected" 403 "$(admin -X POST "$RB/merges" -d '{"base":"main","head":"feat/1","strategy":"merge"}')"
expect_eq "required squash strategy allowed" 201 "$(admin -X POST "$RB/merges" -d '{"base":"main","head":"feat/1","strategy":"squash","message":"Squashed feat"}')"
expect_eq "delete main rule" 204 "$(admin -X DELETE "$RB/rules/$MAIN_RULE_ID")"
expect_eq "delete missing rule" 404 "$(admin -X DELETE "$RB/rules/$MAIN_RULE_ID")"
expect_eq "rule events logged" "2 1 3" "$(count_events repo=acme/rules kind=rule_created) $(count_events repo=acme/rules kind=rule_deleted) $(count_events repo=acme/rules kind=rule_rejected)"

# Deleting repo clears rules on recreate
expect_eq "delete rules repo" 204 "$(admin -X DELETE "$RB")"
expect_eq "recreate rules repo" 201 "$(admin -X POST "$BASE/v1/repos" -d '{"name":"acme/rules"}')"
expect_eq "rules cleared after repo delete" 0 "$(admin "$RB/rules" >/dev/null; json '["rules"].__len__()')"
expect_eq "delete temporary rules repo" 204 "$(admin -X DELETE "$RB")"

echo "== dry-run merge and conflict radar"
admin -X POST "$BASE/v1/repos" -d '{"name":"acme/radar"}' >/dev/null
RDB="$BASE/v1/repos/acme/radar"
RDR_RO="$(mint acme/radar '["git:read"]')"
expect_eq "radar seed main" 201 "$(admin -X POST "$RDB/commits" -d '{"branch":"main","expected_head":null,"message":"init","changes":[{"path":"auth.py","content":"line1\nline2\nline3\nline4\n"},{"path":"docs.md","content":"docs\n"}]}')"
RADAR_MAIN="$(admin "$RDB/branches" >/dev/null; python3 -c "import json; print(next(b['commit'] for b in json.load(open('$WORK/body'))['branches'] if b['name']=='main'))")"
expect_eq "radar agent a" 201 "$(admin -X POST "$RDB/commits" -d '{"branch":"radar/a","expected_head":null,"from":"main","message":"a","changes":[{"path":"auth.py","content":"LINE1_A\nline2\nline3\nline4\n"}]}')"
expect_eq "radar agent b" 201 "$(admin -X POST "$RDB/commits" -d '{"branch":"radar/b","expected_head":null,"from":"main","message":"b","changes":[{"path":"auth.py","content":"LINE1_B\nline2\nline3\nline4\n"}]}')"
expect_eq "radar agent c" 201 "$(admin -X POST "$RDB/commits" -d '{"branch":"radar/c","expected_head":null,"from":"main","message":"c","changes":[{"path":"docs.md","content":"docs updated\n"}]}')"
expect_eq "radar agent d non-conflicting same file" 201 "$(admin -X POST "$RDB/commits" -d '{"branch":"radar/d","expected_head":null,"from":"main","message":"d","changes":[{"path":"auth.py","content":"line1\nline2\nline3\nLINE4_D\n"}]}')"

expect_eq "read-only token runs dry_run fast_forward" 200 "$(status -H "authorization: Bearer $RDR_RO" -X POST "$RDB/merges" -d '{"base":"main","head":"radar/a","dry_run":true}')"
expect_eq "dry_run result" "True fast_forward" "$(json '["mergeable"]') $(json '["result"]')"
admin -X PUT "$RDB/branches/main/lock" -d '{"reason":"freeze"}' >/dev/null
expect_eq "dry_run sees branch_locked" 200 "$(status -H "authorization: Bearer $RDR_RO" -X POST "$RDB/merges" -d '{"base":"main","head":"radar/a","dry_run":true}')"
expect_eq "dry_run locked blocked_by" "False branch_locked" "$(json '["mergeable"]') $(json '["blocked_by"]')"
admin -X DELETE "$RDB/branches/main/lock" >/dev/null
admin -X POST "$RDB/rules" -d '{"pattern":"refs/heads/main","required_merge_strategy":"squash"}' >/dev/null
expect_eq "dry_run sees rule_violation" 200 "$(status -H "authorization: Bearer $RDR_RO" -X POST "$RDB/merges" -d '{"base":"main","head":"radar/a","strategy":"merge","dry_run":true}')"
expect_eq "dry_run rule blocked_by" "False rule_violation" "$(json '["mergeable"]') $(json '["blocked_by"]')"

# Check multi-branch conflict matrix (a, b, c, d vs main)
expect_eq "merges/check validation rejects duplicates" 400 "$(status -H "authorization: Bearer $RDR_RO" -X POST "$RDB/merges/check" -d '{"base":"main","heads":["radar/a","radar/a"]}')"
expect_eq "merges/check multi-branch matrix" 200 "$(status -H "authorization: Bearer $RDR_RO" -X POST "$RDB/merges/check" -d '{"base":"main","heads":["radar/a","radar/b","radar/c","radar/d"],"include_file_overlaps":true}')"
python3 - "$WORK/body" <<'PY' || fail "merges/check result unexpected: $(cat "$WORK/body")"
import json, sys
d = json.load(open(sys.argv[1]))
assert all(b["mergeable"] is True for b in d["branches"]), d["branches"]
pairs = {(p["a"], p["b"]): p["conflicts"] for p in d["pair_conflicts"]}
assert pairs == {("radar/a", "radar/b"): ["auth.py"]}, pairs
overlaps = {(o["a"], o["b"]): o["paths"] for o in d["file_overlaps"]}
assert ("radar/a", "radar/d") in overlaps and overlaps[("radar/a", "radar/d")] == ["auth.py"], overlaps
assert ("radar/b", "radar/d") in overlaps and overlaps[("radar/b", "radar/d")] == ["auth.py"], overlaps
assert all("radar/c" not in pair for pair in overlaps), overlaps
PY
pass "merges/check catches pairwise collision and non-conflicting file overlap"
expect_eq "radar main untouched" "$RADAR_MAIN" "$(admin "$RDB/branches" >/dev/null; python3 -c "import json; print(next(b['commit'] for b in json.load(open('$WORK/body'))['branches'] if b['name']=='main'))")"
expect_eq "dry_run + check generated zero merge events" 0 "$(count_events repo=acme/radar kind=merge)"
expect_eq "dry_run + check generated zero conflict events" 0 "$(count_events repo=acme/radar kind=merge_conflict)"
expect_eq "delete temporary radar repo" 204 "$(admin -X DELETE "$RDB")"

echo "== quotas, stats, and safe GC"
admin -X POST "$BASE/v1/repos" -d '{"name":"acme/quota"}' >/dev/null
QB="$BASE/v1/repos/acme/quota"
QTOK="$(mint acme/quota '["git:read","git:write"]')"
expect_eq "quotas require admin key" 403 "$(status -H "authorization: Bearer $QTOK" "$QB/quotas")"
expect_eq "stats require admin key" 403 "$(status -H "authorization: Bearer $QTOK" "$QB/stats")"
expect_eq "gc require admin key" 403 "$(status -H "authorization: Bearer $QTOK" -X POST "$QB/gc")"
expect_eq "default quotas unlimited" "0 0" "$(admin "$QB/quotas" >/dev/null; json '["effective_max_branches"]') $(json '["effective_max_repo_bytes"]')"

expect_eq "seed quota main" 201 "$(admin -X POST "$QB/commits" -d '{"branch":"main","expected_head":null,"message":"init","changes":[{"path":"a.txt","content":"hello\n"}]}')"
expect_eq "set max_branches 2" 200 "$(admin -X PUT "$QB/quotas" -d '{"max_branches":2,"max_repo_bytes":0}')"
expect_eq "second branch allowed" 201 "$(admin -X POST "$QB/branches" -d '{"name":"b2","from":"main"}')"
expect_eq "third API branch blocked by quota" 429 "$(admin -X POST "$QB/branches" -d '{"name":"b3","from":"main"}')"
expect_eq "third API commit new branch blocked by quota" 429 "$(admin -X POST "$QB/commits" -d '{"branch":"b3","expected_head":null,"from":"main","message":"over","changes":[{"path":"b.txt","content":"b"}]}')"

QCLONE="$WORK/quota-clone"
git clone -q "$(url "$QTOK" acme/quota)" "$QCLONE" 2>"$WORK/err" || fail "clone acme/quota: $(cat "$WORK/err")"
if git -C "$QCLONE" push "$(url "$QTOK" acme/quota)" HEAD:refs/heads/b3 >"$WORK/qpush.out" 2>&1; then fail "git push over branch quota succeeded"; fi
grep -q "branch quota exceeded" "$WORK/qpush.out" || fail "missing branch quota message: $(cat "$WORK/qpush.out")"
pass "git push over branch quota rejected before writing"

CUR_BYTES="$(admin "$QB/stats" >/dev/null; json '["disk_bytes"]')"
[[ "$CUR_BYTES" -gt 0 ]] || fail "disk_bytes was $CUR_BYTES"
LIMIT_BYTES=$((CUR_BYTES + 10000))
QBODY="{\"max_branches\":10,\"max_repo_bytes\":$LIMIT_BYTES}"
expect_eq "set tight disk quota" 200 "$(admin -X PUT "$QB/quotas" -d "$QBODY")"
python3 -c 'import json; print(json.dumps({"branch":"b3","expected_head":None,"from":"main","message":"big","changes":[{"path":"big.bin","content":"X"*25600}]}))' >"$WORK/qbig.json"
expect_eq "oversize API commit blocked by disk quota" 413 "$(admin -X POST "$QB/commits" --data-binary @"$WORK/qbig.json")"
head -c 30720 /dev/urandom >"$QCLONE/rand.bin"
git -C "$QCLONE" add rand.bin && git "${GIT_ID[@]}" -C "$QCLONE" commit -qm "too big"
if git -C "$QCLONE" push "$(url "$QTOK" acme/quota)" HEAD:refs/heads/bigpush >"$WORK/qdisk.out" 2>&1; then fail "git push over disk quota succeeded"; fi
grep -q "disk quota exceeded" "$WORK/qdisk.out" || fail "missing disk quota message: $(cat "$WORK/qdisk.out")"
pass "git push over disk quota rejected before writing"

# Raise quota, create an expiring branch with a 200 KiB uncompressible blob, let it expire, and GC
expect_eq "clear quotas" 200 "$(admin -X PUT "$QB/quotas" -d '{"max_branches":0,"max_repo_bytes":0}')"
Q_EXP_TOK="$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/quota","scopes":["git:read","git:write"],"branch_ttl_seconds":1}' >/dev/null; json '["token"]')"
head -c 204800 /dev/urandom >"$QCLONE/rand.bin"
git -C "$QCLONE" add rand.bin && git "${GIT_ID[@]}" -C "$QCLONE" commit --amend -qm "200k expiring blob"
git -C "$QCLONE" push -q "$(url "$Q_EXP_TOK" acme/quota)" HEAD:refs/heads/ttl/big 2>"$WORK/err" || fail "push expiring blob: $(cat "$WORK/err")"
for _ in $(seq 1 40); do
  admin "$QB/branches" >/dev/null
  if python3 -c "import json,sys; sys.exit(0 if not any(b['name']=='ttl/big' for b in json.load(open('$WORK/body'))['branches']) else 1)"; then break; fi
  sleep 0.25
done
expect_eq "expired_since_gc recorded" 1 "$(admin "$QB/stats" >/dev/null; json '["expired_since_gc"]')"
expect_eq "run gc prune_seconds=0" 200 "$(admin -X POST "$QB/gc" -d '{"prune_seconds":0}')"
RECLAIMED="$(json '["reclaimed_bytes"]')"
BEFORE_GC="$(json '["before_bytes"]')"
AFTER_GC="$(json '["after_bytes"]')"
[[ "$RECLAIMED" -gt 100000 && "$AFTER_GC" -lt "$BEFORE_GC" ]] || fail "expected GC to reclaim >100KB: before=$BEFORE_GC after=$AFTER_GC reclaimed=$RECLAIMED"
pass "gc reclaimed $RECLAIMED bytes from expired branch"
expect_eq "expired_since_gc reset and last_gc_at set" 0 "$(admin "$QB/stats" >/dev/null; json '["expired_since_gc"]')"
[[ "$(json '["last_gc_at"]')" =~ ^[0-9]+$ ]] || fail "missing last_gc_at after gc"
pass "stats updated after gc"
expect_eq "main intact after gc" 200 "$(admin "$QB/files/a.txt?ref=main")"

# Concurrent GC + deleteRepo race leaves server clean (RepoGC.tla)
admin -X POST "$BASE/v1/repos" -d '{"name":"acme/gc-race"}' >/dev/null
admin -X POST "$BASE/v1/repos/acme/gc-race/commits" -d '{"branch":"main","expected_head":null,"message":"race","changes":[{"path":"r.txt","content":"race"}]}' >/dev/null
curl -s -o "$WORK/gcr1" -w '%{http_code}' -H "authorization: Bearer $KEY" -X POST "$BASE/v1/repos/acme/gc-race/gc" >"$WORK/gcr1.code" &
PID_GC=$!
curl -s -o "$WORK/gcr2" -w '%{http_code}' -H "authorization: Bearer $KEY" -X DELETE "$BASE/v1/repos/acme/gc-race" >"$WORK/gcr2.code" &
PID_DEL=$!
wait "$PID_GC" "$PID_DEL"
C1="$(cat "$WORK/gcr1.code")"; C2="$(cat "$WORK/gcr2.code")"
[[ "$C1" =~ ^(200|404|409)$ && "$C2" =~ ^(204|404)$ ]] || fail "unexpected status in gc+delete race: gc=$C1 del=$C2"
pass "concurrent gc and deleteRepo resolved safely (gc=$C1, del=$C2)"
expect_eq "delete temporary quota repo" 204 "$(admin -X DELETE "$QB")"

echo "== commit checks and required-check merge gates"
admin -X POST "$BASE/v1/repos" -d '{"name":"acme/checks"}' >/dev/null
CB="$BASE/v1/repos/acme/checks"
CK_CODE="$(mint acme/checks '["git:read","git:write"]')"
CK_CI="$(mint acme/checks '["git:read","checks:write"]')"
expect_eq "seed checks main" 201 "$(admin -X POST "$CB/commits" -d '{"branch":"main","expected_head":null,"message":"init","changes":[{"path":"app.txt","content":"v1\n"}]}')"
expect_eq "agent branch commit" 201 "$(status -H "authorization: Bearer $CK_CODE" -X POST "$CB/commits" -d '{"branch":"agent/work","expected_head":null,"from":"main","message":"work 1","changes":[{"path":"app.txt","content":"v2\n"}]}')"
SHA1="$(json '["sha"]')"

# Coding agent cannot post checks, checker token can
expect_eq "coding token cannot post checks" 403 "$(status -H "authorization: Bearer $CK_CODE" -X POST "$CB/commits/$SHA1/checks" -d '{"name":"tests","status":"passed"}')"
expect_eq "checker posts running" 200 "$(status -H "authorization: Bearer $CK_CI" -X POST "$CB/commits/$SHA1/checks" -d '{"name":"tests","status":"running","summary":"started"}')"
expect_eq "checker posts failed" 200 "$(status -H "authorization: Bearer $CK_CI" -X POST "$CB/commits/$SHA1/checks" -d '{"name":"tests","status":"failed","summary":"1 failing test"}')"
expect_eq "checker posts passed" 200 "$(status -H "authorization: Bearer $CK_CI" -X POST "$CB/commits/$SHA1/checks" -d '{"name":"tests","status":"passed","summary":"12 passed","url":"https://ci.example/1"}')"
expect_eq "checks list rollup before second check" "passed" "$(status -H "authorization: Bearer $CK_CODE" "$CB/commits/$SHA1/checks" >/dev/null; json '["rollup"]')"

# Rule requiring tests + lint blocks merge until both pass on exact HEAD commit
expect_eq "create required_checks rule" 201 "$(admin -X POST "$CB/rules" -d '{"pattern":"refs/heads/main","required_merge_strategy":"squash","required_checks":["tests","lint"]}')"
expect_eq "dry_run blocked by missing lint" 200 "$(status -H "authorization: Bearer $CK_CODE" -X POST "$CB/merges" -d '{"base":"main","head":"agent/work","strategy":"squash","dry_run":true}')"
expect_eq "dry_run missing_required_check" "False missing_required_check lint" "$(json '["mergeable"]') $(json '["blocked_by"]') $(json '["missing_checks"][0]')"
expect_eq "merge rejected while lint missing" 403 "$(admin -X POST "$CB/merges" -d '{"base":"main","head":"agent/work","strategy":"squash"}')"
expect_eq "missing_required_check code" "missing_required_check" "$(json '["error"]["code"]')"

expect_eq "post lint passed on SHA1" 200 "$(status -H "authorization: Bearer $CK_CI" -X POST "$CB/commits/$SHA1/checks" -d '{"name":"lint","status":"passed"}')"
expect_eq "dry_run mergeable once checks pass" "True" "$(admin -X POST "$CB/merges" -d '{"base":"main","head":"agent/work","strategy":"squash","dry_run":true}' >/dev/null; json '["mergeable"]')"

# New git push commit SHA2 invalidates SHA1 checks until SHA2 is checked
CK_CLONE="$WORK/checks-clone"
git clone -q "$(url "$CK_CODE" acme/checks)" "$CK_CLONE" 2>"$WORK/err" || fail "clone acme/checks: $(cat "$WORK/err")"
git -C "$CK_CLONE" checkout -q -b agent/work origin/agent/work
echo "v3" >"$CK_CLONE/app.txt"
git "${GIT_ID[@]}" -C "$CK_CLONE" commit -qam "push v3"
git -C "$CK_CLONE" push -q "$(url "$CK_CODE" acme/checks)" agent/work 2>"$WORK/err" || fail "push SHA2: $(cat "$WORK/err")"
SHA2="$(git -C "$CK_CLONE" rev-parse HEAD)"
expect_eq "new commit invalidates old checks" 403 "$(admin -X POST "$CB/merges" -d '{"base":"main","head":"agent/work","strategy":"squash"}')"
expect_eq "pass tests on SHA2" 200 "$(status -H "authorization: Bearer $CK_CI" -X POST "$CB/commits/$SHA2/checks" -d '{"name":"tests","status":"passed"}')"
expect_eq "pass lint on SHA2" 200 "$(status -H "authorization: Bearer $CK_CI" -X POST "$CB/commits/$SHA2/checks" -d '{"name":"lint","status":"passed"}')"
expect_eq "ui state includes branch check badges" 200 "$(status "$BASE/ui/api/state")"
python3 - "$WORK/body" <<'PY' || fail "missing check badges in ui state: $(cat "$WORK/body")"
import json, sys
s = json.load(open(sys.argv[1]))
repo = next(r for r in s["repos"] if r["name"] == "acme/checks")
b = next(br for br in repo["branches"] if br["name"] == "agent/work")
assert {(c["name"], c["status"]) for c in b["checks"]} == {("tests", "passed"), ("lint", "passed")}, b
PY
pass "ui exposes commit check badges on branch heads"
expect_eq "merge succeeds after SHA2 checks pass" 201 "$(admin -X POST "$CB/merges" -d '{"base":"main","head":"agent/work","strategy":"squash"}')"
expect_eq "delete checks repo" 204 "$(admin -X DELETE "$CB")"

echo "== surgical patch and edit commits"
admin -X POST "$BASE/v1/repos" -d '{"name":"acme/patch"}' >/dev/null
PB="$BASE/v1/repos/acme/patch"
P_DOCS_TOK="$(mint acme/patch '["git:read","git:write"]' 900)"
expect_eq "seed patch main" 201 "$(admin -X POST "$PB/commits" -d '{"branch":"main","expected_head":null,"message":"seed","changes":[{"path":"code.py","content":"l1\nval = 10\nl3\nother = 1\nl5\nother = 2\n"},{"path":"secret.txt","content":"keep\n"}]}')"
P_BASE="$(admin "$PB/branches" >/dev/null; python3 -c "import json; print(next(b['commit'] for b in json.load(open('$WORK/body'))['branches'] if b['name']=='main'))")"

# Surgical edits change target while leaving surrounding lines intact
P_BODY_EDIT="{\"branch\":\"agent/patch\",\"expected_head\":null,\"from\":\"main\",\"message\":\"edit code.py\",\"changes\":[{\"path\":\"code.py\",\"edits\":[{\"old\":\"val = 10\",\"new\":\"val = 42\"}]}]}"
expect_eq "surgical multi-edit commit" 201 "$(admin -X POST "$PB/commits" -d "$P_BODY_EDIT")"
expect_eq "read patched code.py" 200 "$(admin "$PB/files/code.py?ref=agent/patch")"
expect_eq "patched file preserves surrounding lines" $'l1\nval = 42\nl3\nother = 1\nl5\nother = 2\nx' "$(cat "$WORK/body"; echo x)"
P_H1="$(admin "$PB/branches" >/dev/null; python3 -c "import json; print(next(b['commit'] for b in json.load(open('$WORK/body'))['branches'] if b['name']=='agent/patch'))")"

# Unified diff patch commit
P_BODY_DIFF="{\"branch\":\"agent/patch\",\"expected_head\":\"$P_H1\",\"message\":\"diff code.py\",\"changes\":[{\"path\":\"code.py\",\"patch\":\"--- a/code.py\\n+++ b/code.py\\n@@ -1,3 +1,3 @@\\n l1\\n-val = 42\\n+val = 99\\n l3\\n\"}]}"
expect_eq "unified diff patch commit" 201 "$(admin -X POST "$PB/commits" -d "$P_BODY_DIFF")"
P_H2="$(json '["sha"]')"
expect_eq "read diffed code.py" 200 "$(admin "$PB/files/code.py?ref=$P_H2")"
expect_eq "diff applied cleanly" $'l1\nval = 99\nl3\nother = 1\nl5\nother = 2\nx' "$(cat "$WORK/body"; echo x)"

# Missing/ambiguous/hunk mismatch -> 422 patch_failed without moving branch
P_BAD_MISS="{\"branch\":\"agent/patch\",\"expected_head\":\"$P_H2\",\"message\":\"bad\",\"changes\":[{\"path\":\"code.py\",\"edits\":[{\"old\":\"nope\",\"new\":\"y\"}]}]}"
expect_eq "missing old returns 422" 422 "$(admin -X POST "$PB/commits" -d "$P_BAD_MISS")"
P_BAD_AMBIG="{\"branch\":\"agent/patch\",\"expected_head\":\"$P_H2\",\"message\":\"ambig\",\"changes\":[{\"path\":\"code.py\",\"edits\":[{\"old\":\"other\",\"new\":\"x\"}]}]}"
expect_eq "ambiguous old returns 422" 422 "$(admin -X POST "$PB/commits" -d "$P_BAD_AMBIG")"
P_BAD_HUNK="{\"branch\":\"agent/patch\",\"expected_head\":\"$P_H2\",\"message\":\"stale diff\",\"changes\":[{\"path\":\"code.py\",\"patch\":\"@@ -1,2 +1,2 @@\\n l1\\n-wrong\\n+x\\n\"}]}"
expect_eq "stale diff hunk returns 422" 422 "$(admin -X POST "$PB/commits" -d "$P_BAD_HUNK")"
P_STALE="{\"branch\":\"agent/patch\",\"expected_head\":\"$P_H1\",\"message\":\"cas race\",\"changes\":[{\"path\":\"code.py\",\"edits\":[{\"old\":\"val = 42\",\"new\":\"val = 77\"}]}]}"
expect_eq "stale expected_head returns 409" 409 "$(admin -X POST "$PB/commits" -d "$P_STALE")"

# Disk quota enforces post-patch file size
expect_eq "set tiny disk quota for patch test" 200 "$(admin -X PUT "$PB/quotas" -d '{"max_branches":10,"max_repo_bytes":100}')"
P_BIG="{\"branch\":\"agent/patch\",\"expected_head\":\"$P_H2\",\"message\":\"over quota\",\"changes\":[{\"path\":\"code.py\",\"edits\":[{\"old\":\"l1\",\"new\":\"$(python3 -c "print('Z'*200)")\"}]}]}"
expect_eq "patch over disk quota returns 413" 413 "$(admin -X POST "$PB/commits" -d "$P_BIG")"

# Path-restricted token cannot patch excluded path
P_PATH_TOK="$(admin -X POST "$BASE/v1/tokens" -d '{"repo":"acme/patch","scopes":["git:read","git:write"],"paths":["code.py"]}' >/dev/null; json '["token"]')"
P_ACL="{\"branch\":\"agent/patch\",\"expected_head\":\"$P_H2\",\"message\":\"acl\",\"changes\":[{\"path\":\"secret.txt\",\"edits\":[{\"old\":\"keep\",\"new\":\"hack\"}]}]}"
expect_eq "path ACL blocks patch to secret.txt" 403 "$(status -H "authorization: Bearer $P_PATH_TOK" -X POST "$PB/commits" -d "$P_ACL")"
expect_eq "patch branch stayed at P_H2" "$P_H2" "$(admin "$PB/branches" >/dev/null; python3 -c "import json; print(next(b['commit'] for b in json.load(open('$WORK/body'))['branches'] if b['name']=='agent/patch'))")"
expect_eq "delete patch repo" 204 "$(admin -X DELETE "$PB")"

echo "== SDKs (TypeScript and Python)"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -d "$ROOT_DIR/sdk/python" ]]; then
  if GITD_URL="$BASE" GITD_KEY="$KEY" PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$ROOT_DIR/sdk/python" -p "test_*.py" >"$WORK/py-sdk.out" 2>&1; then
    pass "Python SDK end-to-end"
  else
    fail "Python SDK: $(cat "$WORK/py-sdk.out")"
  fi
fi
if command -v node >/dev/null && node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)'; then
  if GITD_URL="$BASE" GITD_KEY="$KEY" node --test "$ROOT_DIR/sdk/ts/test.ts" >"$WORK/ts-sdk.out" 2>&1; then
    pass "TypeScript SDK end-to-end"
  else
    fail "TypeScript SDK: $(cat "$WORK/ts-sdk.out")"
  fi
fi

echo "== restart keeps data and secret"
REPOS_BEFORE="$(admin "$BASE/v1/repos" >/dev/null; json '["repos"].__len__()')"
expect_eq "branch that expires across a restart" 201 "$(admin -X POST "$BASE/v1/repos/acme/other/branches" -d '{"name":"ttl/restart","from":"main","ttl_seconds":3}')"
# Stop while a slow clone is mid-transfer: gitd must still exit promptly and
# take its git processes with it.
head -c 4000000 /dev/urandom >"$SRC/big2.bin"
git -C "$SRC" add big2.bin
git "${GIT_ID[@]}" -C "$SRC" commit -qm big2
git -C "$SRC" push -q "$(url "$RW" acme/web)" HEAD:refs/heads/big 2>"$WORK/err" || fail "push before shutdown test: $(cat "$WORK/err")"
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
expect_eq "repos survive restart" "$REPOS_BEFORE" "$(json '["repos"].__len__()')"
git ls-remote "$(url "$RW" acme/web)" >/dev/null 2>"$WORK/err" || fail "token from before restart: $(cat "$WORK/err")"
pass "token minted before restart still works"
sleep 4
expect_eq "expiry survives a restart" gone "$(expires_of ttl/restart)"
stop_server

echo "== MVP scenario (tests/demo/agents.sh)"
MVP_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
if GITD_BIN="$BIN" DEMO_PORT="$MVP_PORT" DEMO_DIR="$WORK/mvp" AGENT_TTL=3 "$(dirname "$0")/../demo/agents.sh" >"$WORK/mvp.out" 2>&1; then
  grep -q "^MVP OK$" "$WORK/mvp.out" || fail "MVP scenario did not finish: $(tail -20 "$WORK/mvp.out")"
else
  fail "MVP scenario: $(tail -20 "$WORK/mvp.out")"
fi
pass "five agents, one blocked from main, winner merged, the rest expired, webhooks delivered"
sleep 0.5
pgrep -f "gitd serve --data $WORK/mvp" >/dev/null && fail "MVP server still running"
pass "MVP scenario stopped its server"
if grep -nE '^(error|warning)|panic|leak' "$WORK/mvp/server.log"; then fail "MVP server log has errors"; fi
pass "MVP server log is clean"

echo "== server log is clean"
if grep -nE '^(error|warning)|panic|leak|Segmentation' "$LOG"; then fail "server log has errors, warnings, panics, or leaks"; fi
pass "no errors, warnings, panics, or leaks in server log"
grep -q "$KEY" "$LOG" && fail "admin key appears in server log"
grep -qF "$RW" "$LOG" && fail "token appears in server log"
grep -qF "$UP_TOK" "$LOG" && fail "sync token appears in server log"
grep -qF "$HOOK_SECRET" "$LOG" && fail "webhook secret appears in server log"
grep -qF "127.0.0.1:$HP" "$LOG" && fail "a webhook URL appears in server log"
pass "no secrets in server log"

echo "PASS: $PASSED checks"
