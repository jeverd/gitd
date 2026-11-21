#!/usr/bin/env bash
# Checks the RepoGC model with TLC:
#   RepoGC.cfg   (coordinated GC + delete/recreate) must pass every invariant.
#   UnsafeGC.cfg (uncoordinated delete) must violate NoGCOnDeletedRepo.
set -euo pipefail
cd "$(dirname "$0")"
JAR="${TLA2TOOLS:-$HOME/.cache/gitd-tla/tla2tools.jar}"
[[ -f "$JAR" ]] || { echo "tla2tools.jar not found at $JAR" >&2; exit 2; }
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
tlc() { java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -deadlock -metadir "$OUT/states" -config "$1" RepoGC.tla; }

tlc RepoGC.cfg >"$OUT/good.log" 2>&1 || { cat "$OUT/good.log"; echo "FAIL: RepoGC.cfg found a violation" >&2; exit 1; }
grep -q "No error has been found" "$OUT/good.log" || { cat "$OUT/good.log"; exit 1; }
echo "ok   RepoGC.cfg: $(grep -Eo '[0-9]+ distinct states found' "$OUT/good.log")"

if tlc UnsafeGC.cfg >"$OUT/bad.log" 2>&1; then cat "$OUT/bad.log"; echo "FAIL: UnsafeGC.cfg passed; the model no longer catches unsafe GC" >&2; exit 1; fi
grep -q "Invariant NoGCOnDeletedRepo is violated" "$OUT/bad.log" || { cat "$OUT/bad.log"; echo "FAIL: UnsafeGC.cfg failed for another reason" >&2; exit 1; }
echo "ok   UnsafeGC.cfg: TLC finds GC running on a deleted repo"
