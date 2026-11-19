# AGENTS.md

Instructions for coding agents working in this repo.

Read `RULES.md` before any change and cite its IDs in reviews. It wins over this file.

For any `.zig` or `build.zig` edit, load the `zig` skill in `.claude/skills/zig/`. Zig 0.17 changed many std APIs, and older Zig knowledge is often wrong.

## What gitd is

A git server for AI agents. Platforms create repos over an HTTP API, hand each agent a short-lived token scoped to its branches, and agents push with plain `git` or commit through the API. See `README.md` for the MVP.

## Toolchain

- Zig 0.17 (`build.zig.zon` sets the minimum). Check `zig version` first.
- libgit2 and SQLite, linked from Homebrew for now.
- The real `git` binary, for `git http-backend` and end-to-end tests.

## Commands

```sh
zig build             # build ./zig-out/bin/gitd
zig build run -- ...  # build and run
zig build test        # unit tests
zig build fmt         # format
zig build fmt-check   # fail if anything is unformatted
```

## Layout

```text
src/
  main.zig     entry point; wires modules together, no feature logic
```

Add modules under `src/` as features land (for example `http/`, `git/`, `store/`, `auth/`), and list them here with one line each.

## Before saying work is done

1. `zig build`, `zig build test`, and `zig build fmt-check` pass.
2. Run `./zig-out/bin/gitd` from this checkout, never a `gitd` on `PATH`, and exercise the change for real. For git features that means a real `git clone` or `git push` against it.
3. stderr is clean and the behavior matches what you report.

If you could not run something, say which step and why.

## Style

- Zig naming: `camelCase` functions, `snake_case` variables, fields, and files, `PascalCase` types.
- Unit tests sit in `test` blocks next to the code they cover.
- Comments say only what the code cannot: why a rule holds, who owns returned memory, why a `catch {}` is safe.
