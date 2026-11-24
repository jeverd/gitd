# Security Policy

## Reporting a vulnerability

Please do **not** open a public GitHub issue for security vulnerabilities.
Instead, use GitHub's private vulnerability reporting on this repository (Security -> Advisories -> Report a vulnerability) and include reproduction steps and impact.

## Deployment & threat model

`gitd` is designed to run behind your platform's control plane and network perimeter:

- **Terminate TLS at a reverse proxy:** `gitd` speaks plain HTTP. Always place it behind a TLS-terminating proxy (e.g., Caddy, Nginx, Envoy, or a cloud load balancer) when exposed beyond loopback.
- **Admin keys vs. repo tokens:** Admin keys (`gitd_k_...`) manage repos, webhooks, locks, rules, and token minting—keep them strictly on your trusted control plane. Give AI agents short-lived, least-privilege repo tokens (`gitd_t_...`) scoped by `scopes`, `refs`, `read_refs`, and `paths`.
- **Activity UI (`/ui`):** Disabled by default. When enabled with `serve --ui`, it is read-only and restricted to loopback clients (`127.0.0.1` / `::1`). Do not reverse-proxy `/ui` to untrusted networks without authentication.
- **Storage scope:** Today `gitd` is a single-node server backed by local disk and SQLite. Back up the data directory (`--data`) and protect its filesystem permissions (`0600` on signing secrets and keys).
- **Untrusted Git input:** `gitd` validates ref names, paths, pkt-lines, and pack files, disables Git hooks and repo-configured helpers (`R2.3`, `R2.4`), and enforces per-peer connection and SSE caps (`R3.4`). See `RULES.md` for the full set of security invariants.
