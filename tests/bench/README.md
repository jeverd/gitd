# gitd Benchmarks

## Scripts

- `bench.py`: fast single-file smoke check against a running `gitd` instance (no keep-alive, synthetic 10-file repo).
- `suite.py`: reproducible agent-workflow benchmark suite covering:
  - **B1**: Zero-clone API loop (`grep` -> `files` -> `commits`) vs. `git clone --depth=1` and full `git clone`, plus subdirectory `archive`.
  - **B2**: Multi-agent fan-out & fan-in (`1..64` concurrent agents), `compare`, `merge`, and branch expiry reaping.
  - **B3**: CAS contention storm on `main` (`expected_head` retries) with strict log + tree integrity verification (`0` lost updates).
  - **B5**: Smart HTTP proxy overhead vs. bare `git http-backend`, scoped-token + locked-branch + 5 MiB push rejection checks, and `1..100`-file commit scaling.
- `compare_forges.py`: Dockerized comparison of `gitd`, Gitea, and Forgejo under identical `--cpus` / `--memory` limits (image size, cold start, idle/peak RSS, repo/token provisioning, and sequential/concurrent API commits).
- `run_ec2.sh`: one-command runner for a Linux / EC2 instance (`Ubuntu 24.04+`).

## Quick Local Run

```sh
zig build -Doptimize=ReleaseSafe
python3 tests/bench/suite.py --gitd-bin ./zig-out/bin/gitd --mode quick --out-dir /tmp/gitd-bench
```

## Full EC2 Run

```sh
tests/bench/run_ec2.sh --mode full --out-dir ./bench-results
```

Pass `--no-forges` to skip the Docker Gitea/Forgejo comparison.
