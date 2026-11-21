#!/usr/bin/env bash
# The verification gate. Run before saying any change is done.
#
#   scripts/verify.sh          full run (about a minute)
#   scripts/verify.sh --quick  skip fuzzing and the ReleaseSafe end-to-end run
#
# Each step must pass. Stops at the first failure and says which step.
set -euo pipefail
cd "$(dirname "$0")/.."

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1
FUZZ_RUNS="${FUZZ_RUNS:-200K}"
FUZZ_TARGETS=("repo_name.test.fuzz parse" "fuzz verify" "fuzz match and parseCgiHead" "fuzz validate and matches" "fuzz parse commands" "fuzz validate path" "fuzz match path pattern" "fuzz parse grep" "fuzz validate sync url")
ZIG_VERSION="$(sed -n 's/.*\.minimum_zig_version = "\(.*\)".*/\1/p' build.zig.zon)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

step() { echo; echo "== $*"; }
die() { echo "VERIFY FAILED: $*" >&2; exit 1; }

step "toolchain"
[[ "$(zig version)" == "$ZIG_VERSION" ]] || die "zig $(zig version) found, build.zig.zon pins $ZIG_VERSION"
command -v git >/dev/null || die "git is not installed"
echo "zig $ZIG_VERSION, $(git --version)"

step "format"
zig build fmt-check || die "run: zig build fmt"

step "no removed or deprecated Zig 0.17 APIs"
python3 .claude/skills/zig/scripts/check_deprecated.py --review src build.zig || die "deprecated API scan"

step "unit tests (Debug)"
zig build test --summary all 2>&1 | tail -3
zig build test || die "unit tests in Debug"

step "unit tests (ReleaseSafe)"
zig build test -Doptimize=ReleaseSafe || die "unit tests in ReleaseSafe"

step "TLA+ models"
for check in tests/tla/*/check.sh; do "$check" || die "TLA+ model $(dirname "$check")"; done

step "end-to-end (Debug: safety checks and leak reports on exit)"
zig build || die "Debug build"
tests/e2e/run.sh zig-out/bin/gitd >"$OUT/e2e-debug.log" 2>&1 || { tail -40 "$OUT/e2e-debug.log"; die "end-to-end in Debug"; }
grep "^PASS:" "$OUT/e2e-debug.log"

if [[ "$QUICK" == 0 ]]; then
  step "end-to-end (ReleaseSafe)"
  zig build -Doptimize=ReleaseSafe --prefix "$OUT/safe" || die "ReleaseSafe build"
  tests/e2e/run.sh "$OUT/safe/bin/gitd" >"$OUT/e2e-safe.log" 2>&1 || { tail -40 "$OUT/e2e-safe.log"; die "end-to-end in ReleaseSafe"; }
  grep "^PASS:" "$OUT/e2e-safe.log"

  step "fuzz ($FUZZ_RUNS runs per target)"
  for target in "${FUZZ_TARGETS[@]}"; do
    # Zig 0.17 exits 0 even when the fuzzer finds a failure, so read the output.
    zig build test -Dtest-filter="$target" --fuzz="$FUZZ_RUNS" >"$OUT/fuzz.log" 2>&1 || true
    if grep -qE "^error: |failed with" "$OUT/fuzz.log"; then
      cat "$OUT/fuzz.log"
      die "fuzzer found a failing input for '$target' (saved under .zig-cache/f/); add it as a unit test"
    fi
    grep -q "Fuzz test:.*$target" "$OUT/fuzz.log" || { cat "$OUT/fuzz.log"; die "fuzz target '$target' did not run"; }
    echo "ok   $target: $(grep -m1 'Runs:' "$OUT/fuzz.log" | sed 's/.*-> //') runs"
  done
fi

echo
echo "VERIFY PASSED$([[ "$QUICK" == 1 ]] && echo " (quick)")"
