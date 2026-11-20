# gitd

Open-source git storage for AI agents, written in Zig. Create repos over an API, give each agent a scoped token, and let agents push with plain `git` or commit through the API.

Status: early. Repos, tokens, and `git clone`/`git push` work. Everything else in the MVP list is not built yet.

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

## API

All `/v1` routes need `Authorization: Bearer <admin key>`. Errors look like `{"error":{"code":"...","message":"..."}}`.

| Route | Does |
|---|---|
| `POST /v1/repos` `{"name"}` | Create a repo. 201, or 409 if the name is taken |
| `GET /v1/repos` | List repos |
| `GET /v1/repos/{ns}/{repo}` | Get one repo |
| `DELETE /v1/repos/{ns}/{repo}` | Delete a repo and its files. Its tokens stop working |
| `POST /v1/tokens` `{"repo","scopes","ttl_seconds","refs"}` | Mint a repo token. `refs` (optional, up to 4) limits which refs it may write, like `["refs/heads/agent/7/*"]` |
| `GET /healthz` | Liveness, no auth |
| `GET /ui` | Live activity page: repos, branches, and every push. Only with `gitd serve --ui`, only from this machine |
| `/{ns}/{repo}.git/...` | git smart HTTP. The token goes in the password: `http://t:<token>@host/...` |

Repo names are `ns/repo`: lowercase letters, digits, `.`, `_`, `-`, up to 64 characters per part.

## MVP

- **Stack:** Zig, SQLite, and the `git` binary for now (libgit2 comes with the file and commit API). One server, repos on a persistent disk.
- **Features:**
  1. ✅ Repos: create, list, delete over an API
  2. ✅ Git: `git clone` and `git push` work normally
  3. ✅ Tokens: short-lived, limited to ref patterns
  4. Read files, folders, history without cloning
  5. Commit through the API, with a 409 when two agents race
  6. Diff and merge branches
  7. Branches that delete themselves after a set time
  8. Webhooks on push
- **Done when:** 5 fake agents work on separate branches at once, one is blocked from pushing to `main`, the winner is merged, and the rest expire.

## After the MVP

1. Repos in S3, metadata in Postgres
2. Our own git protocol server in Zig
3. SDK and web UI

## Development

```sh
scripts/verify.sh   # the full gate; must print VERIFY PASSED
```

See `AGENTS.md` and `RULES.md`.
