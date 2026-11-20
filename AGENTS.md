# AGENTS.md

Instructions for coding agents working in this repo.

Read `RULES.md` before any change and cite its IDs in reviews. It wins over this file.

For any `.zig` or `build.zig` edit, load the `zig` skill in `.claude/skills/zig/`. Zig 0.17 changed many std APIs, and older Zig knowledge is often wrong.

## What gitd is

A git server for AI agents. Platforms create repos over an HTTP API, hand each agent a short-lived token scoped to its branches, and agents push with plain `git` or commit through the API. See `README.md` for the MVP.

## Toolchain

- Zig 0.17.1 (`build.zig.zon` sets the minimum). Check `zig version` first.
- libgit2 and SQLite, linked from Homebrew for now.
- The real `git` binary, for `git http-backend` and end-to-end tests.

## Commands

```sh
zig build             # build ./zig-out/bin/gitd
zig build run -- ...  # build and run
zig build test        # unit tests
zig build fmt         # format
zig build fmt-check   # fail if anything is unformatted
tests/e2e/run.sh      # end-to-end: real server, curl, and the real git client
scripts/verify.sh     # the full gate: everything below, plus fuzzing
```

## Layout

```text
src/
  main.zig          entry point and CLI; wires modules together, no feature logic
  server.zig        HTTP server: connections, routing, admin auth, repo and token API
  git_http.zig      git smart HTTP URL matching and CGI response parsing (pure)
  git_proxy.zig     runs `git http-backend` for one request
  auth.zig          admin keys, signed repo tokens, the signing secret
  repo_name.zig     repo name validation
  db.zig            SQLite metadata (hand-declared sqlite3 functions)
  store.zig         data directory, repo storage on disk, safe `git` environment
  timed_stream.zig  socket reader and writer with per-operation timeouts
  http_util.zig     keep-alive rules and the per-address connection cap
  api.zig           shared handler helpers: JSON bodies, errors, headers, clock
  events.zig        the activity log (pushes, rejections, merges, ...)
  ui.zig, ui.html   read-only activity page at /ui (`serve --ui`, loopback only)
  git_cmd.zig       runs one git plumbing command safely, with bounded output
  repo_git.zig      repo operations built on git plumbing (branches, refs, ...)
  ref_name.zig      ref name and ref pattern validation (pure)
  receive_pack.zig  reads the ref update commands at the start of a push (pure)
  repo_path.zig     file path validation (pure)
  content.zig       per-repo content API: branches, files, trees, log, commits, merges
  expiry.zig        the reaper that deletes expired branches
  webhooks.zig      webhook API and the delivery worker (signed, retried, concurrent)
tests/e2e/run.sh    end-to-end test
tests/demo/demo.sh  drives a UI-enabled gitd for demos and recordings
tests/demo/agents.sh  the full MVP scenario with checks (e2e runs it)
tests/tla/          TLA+ models; each folder has a check.sh that verify.sh runs
scripts/verify.sh   verification gate
```

List new modules here with one line each.

## Before saying work is done

`scripts/verify.sh` must print `VERIFY PASSED`. It checks, in order:

1. The pinned Zig version, formatting, and no removed or deprecated 0.17 APIs.
2. Unit tests in Debug and ReleaseSafe.
3. `tests/e2e/run.sh` against Debug and ReleaseSafe builds. That means a real server, real `git clone` and `git push`, and a server log with no errors, warnings, panics, leaks, or secrets.
4. 200K fuzz runs per fuzz target. Zig 0.17 exits 0 even when the fuzzer finds a failure, so the script reads the output.

Use `scripts/verify.sh --quick` while iterating; the full run is required at the end.

- **A new behavior** gets an end-to-end check that fails without the change. Confirm that by breaking the code on purpose once.
- **A fuzzer finding** becomes a unit test with the failing input (R5.1).
- **New parsing of untrusted bytes** gets a fuzz target. Add its name to `FUZZ_TARGETS` in `scripts/verify.sh`.
- **New concurrency protocols** get a TLA+ model in `tests/tla/<name>/` with a config that plants the bug and must fail. Cite the model and property from the code. Change the model with the code.

If you could not run something, say which step and why.

## Style

- Zig naming: `camelCase` functions, `snake_case` variables, fields, and files, `PascalCase` types.
- Unit tests sit in `test` blocks next to the code they cover.
- Comments say only what the code cannot: why a rule holds, who owns returned memory, why a `catch {}` is safe.
