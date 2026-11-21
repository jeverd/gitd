# gitd

Open-source git storage for AI agents, written in Zig. Create repos over an API, give each agent a scoped token, and let agents push with plain `git` or commit through the API.

Status: MVP complete. Every feature below works end to end; `tests/demo/agents.sh` runs the whole scenario.

## Quick start

Needs Zig 0.17.1 and git. SQLite comes with macOS (on Linux, install `libsqlite3-dev`).

```sh
zig build
KEY=$(./zig-out/bin/gitd admin create-key --data ./data)
./zig-out/bin/gitd serve --data ./data --listen 127.0.0.1:8080
```

In another terminal:

```sh
# Create a repo
curl -X POST localhost:8080/v1/repos -H "authorization: Bearer $KEY" -d '{"name":"acme/web"}'

# Get a token for an agent (scopes: git:read, git:write; ttl up to 86400s, default 900)
TOKEN=$(curl -s -X POST localhost:8080/v1/tokens -H "authorization: Bearer $KEY" \
  -d '{"repo":"acme/web","scopes":["git:read","git:write"],"ttl_seconds":3600}' | jq -r .token)

# Plain git
git clone "http://t:$TOKEN@127.0.0.1:8080/acme/web.git"
```

### In Docker

```sh
docker build -t gitd .
docker run -d --name gitd -v gitd-data:/data -p 8080:8080 gitd
KEY=$(docker exec gitd cat /data/admin-key)   # made on first start, kept in the volume
```

The container listens on 0.0.0.0:8080 with `/ui` off. To choose the admin key up front, pass
`-e GITD_ADMIN_KEY=gitd_k_...` (any key `gitd admin create-key` printed); the container adds it
on start.

## Speed

`python3 tests/bench/bench.py http://127.0.0.1:8080 "$KEY"` against the Docker image
(Docker Desktop, 4 CPUs, arm64):

| call | p50 | p95 |
|---|---|---|
| commit through the API | 6.7 ms | 7.3 ms |
| commit, 16 agents at once (≈380 commits/s) | 41.6 ms | 56.5 ms |
| git clone | 87.9 ms | 88.6 ms |
| git push, one commit | 37.3 ms | 39.3 ms |
| compare | 6.8 ms | 7.6 ms |
| merge | 10.6 ms | 14.2 ms |

## API

All `/v1` routes need `Authorization: Bearer <admin key>`. Per-repo routes (`/v1/repos/{ns}/{repo}/...`) also accept that repo's token as the Bearer value. `ref` is a branch name, a full ref, or a commit oid, and defaults to `main`. Errors look like `{"error":{"code":"...","message":"..."}}`.

| Route | Does |
|---|---|
| `POST /v1/repos` `{"name"}` | Create a repo. 201, or 409 if the name is taken |
| `GET /v1/repos` | List repos |
| `GET /v1/repos/{ns}/{repo}` | Get one repo |
| `DELETE /v1/repos/{ns}/{repo}` | Delete a repo and its files. Its tokens stop working |
| `POST /v1/tokens` `{"repo","scopes","ttl_seconds","refs","read_refs","paths","branch_ttl_seconds"}` | Mint a repo token (scopes: `git:read`, `git:write`, `checks:write`; returns `token`, `jti`, `expires_at`). `refs` limits writes, `read_refs` limits reads & `git clone`/`ls-remote` visibility, `paths` limits API reads/writes to matching files. With `branch_ttl_seconds`, branches it creates expire after that long |
| `POST /v1/tokens/{jti}/revoke` | Immediately revoke a minted token by its `jti` (admin key only) |
| `GET /v1/repos/{ns}/{repo}/branches` | Branches with their commits, expiry, and `locked` / `lock_reason` |
| `POST /v1/repos/{ns}/{repo}/rules` `{"pattern","allow_direct_push","allow_force_push","allow_delete","required_merge_strategy","required_checks"}` | Create a branch protection rule (admin key only; denies matching pushes, force pushes, deletes, disallowed merge strategies, or merges missing passing `required_checks`) |
| `GET /v1/repos/{ns}/{repo}/rules` | List branch protection rules (admin key only) |
| `DELETE /v1/repos/{ns}/{repo}/rules/{id}` | Delete a branch protection rule (admin key only) |
| `GET /v1/repos/{ns}/{repo}/files/{path}?ref=` | Raw file contents (up to 10 MiB) |
| `GET /v1/repos/{ns}/{repo}/tree[/{path}]?ref=` | Directory listing |
| `GET /v1/repos/{ns}/{repo}/log?ref=&limit=&path=` | Commits, newest first |
| `GET /v1/repos/{ns}/{repo}/commits/{sha}` | One commit |
| `POST /v1/repos/{ns}/{repo}/commits/{sha}/checks` `{"name","status","summary","url"}` | Post or update a commit check (`pending`, `running`, `passed`, `failed`; admin key or `checks:write` scope) |
| `GET /v1/repos/{ns}/{repo}/commits/{sha}/checks` | List checks and overall rollup for a commit (`git:read`) |
| `POST /v1/repos/{ns}/{repo}/commits` | Commit file changes to a branch. Send `expected_head` (the commit you built on, or `null` for a new branch); if the branch moved, you get 409 with `current_head` |
| `POST /v1/repos/{ns}/{repo}/branches` `{"name","from","ttl_seconds"}` | Create a branch (409 if it exists); with `ttl_seconds` it is deleted after that long. Commits that create a branch take `ttl_seconds` too |
| `DELETE /v1/repos/{ns}/{repo}/branches/{name}?expected=` | Delete a branch, optionally only if it is at `expected` |
| `PUT /v1/repos/{ns}/{repo}/branches/{name}/lock` `{"reason"}` | Lock a branch against commits, merges, deletes, and `git push` (admin key only; blocked writes return 423) |
| `DELETE /v1/repos/{ns}/{repo}/branches/{name}/lock` | Unlock a locked branch (admin key only) |
| `GET /v1/repos/{ns}/{repo}/compare/{base}...{head}` | Ahead/behind, changed files, and the patch (up to 1 MiB) |
| `GET /v1/repos/{ns}/{repo}/grep?q=&ref=&path=&fixed=&ignore_case=&limit=` | Search text files at `ref` without cloning (returns matching paths, line numbers, lines) |
| `GET /v1/repos/{ns}/{repo}/archive?ref=&format=&path=` | Download a `tar.gz` (default), `tar`, or `zip` archive of `ref` (or `path` within it) |
| `POST /v1/repos/{ns}/{repo}/sync` `{"direction","url","branch","remote_branch","token","force"}` | Fetch a branch from or push a branch back to an upstream Git remote (admin key only; per-request token, never stored or logged) |
| `POST /v1/repos/{ns}/{repo}/merges` `{"base","head","strategy","dry_run"}` | Merge `head` into `base`: fast-forward when possible, else a merge commit (`merge`) or one squashed commit (`squash`). With `dry_run: true`, checks lock/rule/conflict status with only `git:read` and mutates nothing |
| `POST /v1/repos/{ns}/{repo}/merges/check` `{"base","heads","include_file_overlaps"}` | Multi-branch conflict radar: check up to 16 heads vs `base` and pairwise in memory without mutating any ref (`git:read`) |
| `GET /v1/repos/{ns}/{repo}/quotas` | Get configured and effective `max_branches` / `max_repo_bytes` quotas (admin key only) |
| `PUT /v1/repos/{ns}/{repo}/quotas` `{"max_branches","max_repo_bytes"}` | Set per-repo quotas; `0` falls back to server defaults (admin key only) |
| `GET /v1/repos/{ns}/{repo}/stats` | Repo branch count, disk usage, object counts, and maintenance state (admin key only) |
| `POST /v1/repos/{ns}/{repo}/gc` `{"prune_seconds"}` | Run safe garbage collection/repack on the repo and return reclaimed bytes (admin key only) |
| `POST /v1/repos/{ns}/{repo}/webhooks` `{"url"}` | Add a webhook (admin key only). The response has the signing `secret`, shown once |
| `GET /v1/repos/{ns}/{repo}/webhooks` | List webhooks (no secrets) |
| `DELETE /v1/repos/{ns}/{repo}/webhooks/{id}` | Remove a webhook and its queued deliveries |
| `GET /v1/repos/{ns}/{repo}/webhooks/deliveries` | Recent deliveries: status, attempts, last error |
| `GET /healthz` | Liveness, no auth |
| `GET /ui` | Live activity page: repos, branches, and every push. Only with `gitd serve --ui`, only from this machine |
| `/{ns}/{repo}.git/...` | git smart HTTP. The token goes in the password: `http://t:<token>@host/...` |

Repo names are `ns/repo`: lowercase letters, digits, `.`, `_`, `-`, up to 64 characters per part.

Webhook deliveries are `POST`s of `{"delivery": id, "event": {...}}` with `x-gitd-event`, `x-gitd-delivery`, and `x-gitd-signature: sha256=<hex HMAC-SHA256 of the body>`. A 2xx answer counts; anything else is retried after 1, 2, 4, and 8 seconds, then marked failed.

## SDKs

Zero-dependency clients live in [`sdk/ts`](sdk/ts) (Node 22+ / native `fetch`) and [`sdk/python`](sdk/python) (Python 3.10+ / stdlib `urllib`), covering the full `/v1` API plus automatic 409 compare-and-swap retry (`commitWithRetry` / `commit_with_retry`):

```ts
import { GitdClient } from "./sdk/ts/index.ts";

const admin = new GitdClient({ baseUrl: "http://127.0.0.1:8080", token: process.env.GITD_KEY! });
await admin.createRepo("acme/web");
const { token } = await admin.createToken({
  repo: "acme/web",
  scopes: ["git:read", "git:write"],
  refs: ["refs/heads/agent/1/*"],
});
const agent = admin.withToken(token);
const hits = await agent.grep("acme/web", "TODO", { ref: "main" });
await agent.commitWithRetry("acme/web", "agent/1/work", () => ({
  message: "Update file",
  changes: [{ path: "notes.md", content: "done\n" }],
}));
```

```python
from gitd import GitdClient

admin = GitdClient("http://127.0.0.1:8080", key)
tok = admin.create_token("acme/web", ["git:read", "git:write"], refs=["refs/heads/agent/1/*"])["token"]
agent = admin.with_token(tok)
hits = agent.grep("acme/web", "TODO", ref="main")
agent.commit_with_retry("acme/web", "agent/1/work", lambda head: {
    "message": "Update file",
    "changes": [{"path": "notes.md", "content": "done\n"}],
})
```

## MVP

- **Stack:** Zig, SQLite, and git plumbing commands (no libgit2 needed so far). One server, repos on a persistent disk.
- **Features:**
  1. ✅ Repos: create, list, delete over an API
  2. ✅ Git: `git clone` and `git push` work normally
  3. ✅ Tokens: short-lived, limited to ref patterns
  4. ✅ Read files, folders, history without cloning
  5. ✅ Commit through the API, with a 409 when two agents race (TLA+ model in `tests/tla/commit_cas`)
  6. ✅ Diff and merge branches
  7. ✅ Branches that delete themselves after a set time
  8. ✅ Webhooks on every event (signed, retried, survive restarts)
- ✅ **Done when:** 5 fake agents work on separate branches at once, one is blocked from pushing to `main`, the winner is merged, and the rest expire. Run it:

  ```sh
  zig build
  DEMO_PACE=3 AGENT_TTL=20 DEMO_KEEP=1 tests/demo/agents.sh   # then open http://127.0.0.1:18910/ui
  ```

## After the MVP

1. Repos in S3, metadata in Postgres
2. Our own git protocol server in Zig
3. SDK and web UI

## Development

```sh
scripts/verify.sh         # the full gate; must print VERIFY PASSED (needs Java and tla2tools.jar, see tests/tla/commit_cas/check.sh)
scripts/verify-linux.sh   # unit tests and e2e on Linux, in Docker
```

See `AGENTS.md` and `RULES.md`.
