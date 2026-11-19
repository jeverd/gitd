#!/usr/bin/env bash
# Checks the CommitCAS model with TLC:
#   CommitCAS.cfg  (gitd's compare-and-swap) must pass every invariant.
#   BlindWrite.cfg (a blind ref write) must violate NoLostUpdate, which
#                  shows the model can catch the bug it is about.
#
# Needs Java and tla2tools.jar: set TLA2TOOLS, or put it at
# ~/.cache/gitd-tla/tla2tools.jar (gh release download v1.7.4 --repo tlaplus/tlaplus --pattern tla2tools.jar).
set -euo pipefail
cd "$(dirname "$0")"
JAR="${TLA2TOOLS:-$HOME/.cache/gitd-tla/tla2tools.jar}"
[[ -f "$JAR" ]] || { echo "tla2tools.jar not found at $JAR" >&2; exit 2; }
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
tlc() { java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -deadlock -metadir "$OUT/states" -config "$1" CommitCAS.tla; }

tlc CommitCAS.cfg >"$OUT/good.log" 2>&1 || { cat "$OUT/good.log"; echo "FAIL: CommitCAS.cfg found a violation" >&2; exit 1; }
grep -q "No error has been found" "$OUT/good.log" || { cat "$OUT/good.log"; exit 1; }
echo "ok   CommitCAS.cfg: $(grep -Eo '[0-9]+ distinct states found' "$OUT/good.log")"

if tlc BlindWrite.cfg >"$OUT/bad.log" 2>&1; then cat "$OUT/bad.log"; echo "FAIL: BlindWrite.cfg passed; the model no longer catches lost updates" >&2; exit 1; fi
grep -q "Invariant NoLostUpdate is violated" "$OUT/bad.log" || { cat "$OUT/bad.log"; echo "FAIL: BlindWrite.cfg failed for another reason" >&2; exit 1; }
echo "ok   BlindWrite.cfg: TLC finds the lost update"
