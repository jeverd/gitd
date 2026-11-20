#!/usr/bin/env bash
# Runs the unit tests and the e2e suite on Linux, in Docker (the image's build stage plus the
# test tools), so a Linux-only bug shows up before the image ships.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DOCKER_BUILDKIT=0 docker build -q --target build -t gitd:build . >/dev/null
docker run --rm -v "$ROOT/tests:/src/tests:ro" gitd:build bash -c '
  set -euo pipefail
  apt-get update -qq >/dev/null && apt-get install -y -qq git python3 curl procps >/dev/null
  /opt/zig/zig build test --summary none
  echo "unit tests: ok"
  for mode in Debug ReleaseSafe; do
    /opt/zig/zig build -Doptimize=$mode
    bash tests/e2e/run.sh zig-out/bin/gitd >/tmp/e2e.log 2>&1 || { tail -40 /tmp/e2e.log; exit 1; }
    echo "e2e $mode: $(grep -c "^ok " /tmp/e2e.log) checks ok"
  done
'
