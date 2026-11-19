# gitd

Open-source git storage for AI agents, written in Zig. Create repos over an API, give each agent a scoped token, and let agents push with plain `git` or commit through the API.

Status: early, not usable yet.

## MVP

- **Stack:** Zig, libgit2, SQLite. One server, repos on a persistent disk.
- **Features:**
  1. Repos: create, list, delete over an API
  2. Git: `git clone` and `git push` work normally
  3. Tokens: short-lived, limited to one branch pattern
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

## Build

Needs Zig 0.17 and libgit2 (`brew install libgit2`).

```sh
zig build
./zig-out/bin/gitd
```
