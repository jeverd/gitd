# RULES.md

Hard rules. Cite the ID when a change touches one. To change a rule, ask the maintainer first.

## R1 Structure

- **R1.1** `src/main.zig` only wires modules. Feature logic lives in the module that owns it.
- **R1.2** Storage sits behind one interface, so disk can be swapped for S3 without touching callers.
- **R1.3** Repo metadata lives in the database, not inferred from folders on disk.

## R2 Security

- **R2.1** Every request except `GET /healthz` and the read-only `/ui` page (only with `serve --ui`, only to loopback clients) is authenticated. Admin keys manage the server; repo tokens are scoped to one repo (by id, so a deleted repo's tokens die with it), scopes, a branch pattern, and an expiry.
- **R2.2** Branch limits are checked before git writes anything. A rejected push changes nothing.
- **R2.3** Git data from clients and from repos is untrusted: pack files, pkt-lines, paths, ref names, and repo config. Validate and bound every length before use.
- **R2.4** When gitd runs `git`, it disables hooks and any program a repo's config can name.
- **R2.5** Secrets never appear in logs, errors, or URLs that gitd prints.

## R3 Reliability

- **R3.1** Bad input never crashes or hangs gitd. Handle every error path. A new `catch {}` says why in a comment.
- **R3.2** Concurrent writes to one branch use compare-and-swap. The loser gets a 409, never a silent overwrite.
- **R3.3** Every allocation has one owner and is freed on both success and failure. Tests use `std.testing.allocator`.
- **R3.4** A client cannot hold resources without limit: connections are capped, idle reads time out, unread request bodies are never drained, and every git process a request starts is killed if the request ends early.

## R4 Dependencies

- **R4.1** One binary. Dependencies beyond the Zig standard library, libgit2, and SQLite need approval first.

## R5 Testing

- **R5.1** A bug fix lands with a test that fails without it.
- **R5.2** Git features are proven with the real `git` client, not only unit tests.
