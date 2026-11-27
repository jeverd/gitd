#!/usr/bin/env bash
# Checks the PromoteFence model with TLC:
#   PromoteFence.cfg    (gitd's promote_lock) must pass every invariant.
#   UnlockedPromote.cfg (check, then move) must violate NoStalePromote,
#                       which shows the model can catch the bug it is about.
#
# Needs Java and tla2tools.jar: set TLA2TOOLS, or put it at
# ~/.cache/gitd-tla/tla2tools.jar (see tests/tla/commit_cas/check.sh).
set -euo pipefail
cd "$(dirname "$0")"
JAR="${TLA2TOOLS:-$HOME/.cache/gitd-tla/tla2tools.jar}"
[[ -f "$JAR" ]] || { echo "tla2tools.jar not found at $JAR" >&2; exit 2; }
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
tlc() { java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -deadlock -metadir "$OUT/states" -config "$1" PromoteFence.tla; }

tlc PromoteFence.cfg >"$OUT/good.log" 2>&1 || { cat "$OUT/good.log"; echo "FAIL: PromoteFence.cfg found a violation" >&2; exit 1; }
grep -q "No error has been found" "$OUT/good.log" || { cat "$OUT/good.log"; exit 1; }
echo "ok   PromoteFence.cfg: $(grep -Eo '[0-9]+ distinct states found' "$OUT/good.log")"

if tlc UnlockedPromote.cfg >"$OUT/bad.log" 2>&1; then cat "$OUT/bad.log"; echo "FAIL: UnlockedPromote.cfg passed; the model no longer catches stale promotes" >&2; exit 1; fi
grep -q "Invariant NoStalePromote is violated" "$OUT/bad.log" || { cat "$OUT/bad.log"; echo "FAIL: UnlockedPromote.cfg failed for another reason" >&2; exit 1; }
echo "ok   UnlockedPromote.cfg: TLC finds a promote landing on a changed fence"
