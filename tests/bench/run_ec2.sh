#!/usr/bin/env bash
# End-to-end benchmark runner for a Linux / EC2 host (Ubuntu 24.04+).
#
# Usage:
#   tests/bench/run_ec2.sh [--mode full|quick] [--with-forges|--no-forges] [--out-dir DIR]
set -euo pipefail

cd "$(dirname "$0")/../.."

MODE="full"
WITH_FORGES=1
OUT_DIR="bench-results-$(date -u +%Y%m%d-%H%M%S)"
DATA_DIR="$HOME/gitd-bench-data"
OSS_CACHE="$HOME/gitd-bench-oss"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --with-forges) WITH_FORGES=1; shift ;;
    --no-forges) WITH_FORGES=0; shift ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --oss-cache) OSS_CACHE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

export PATH="/opt/zig:$PATH"
ZIG_VERSION="$(sed -n 's/.*\.minimum_zig_version = "\(.*\)".*/\1/p' build.zig.zon)"
if ! command -v zig >/dev/null || [[ "$(zig version)" != "$ZIG_VERSION" ]]; then
  arch="$(uname -m)"
  echo "[ec2] installing Zig $ZIG_VERSION ($arch)..."
  tmp_zig="$(mktemp -d)"
  curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" -o "$tmp_zig/zig.tar.xz"
  sudo mkdir -p /opt/zig
  sudo tar -xJf "$tmp_zig/zig.tar.xz" -C /opt/zig --strip-components=1
  export PATH="/opt/zig:$PATH"
  rm -rf "$tmp_zig"
fi

for cmd in git python3; do
  command -v "$cmd" >/dev/null || { echo "missing required tool: $cmd" >&2; exit 1; }
done

ulimit -n 65536 2>/dev/null || true
mkdir -p "$OUT_DIR"

echo "[ec2] building gitd (ReleaseSafe)..."
zig build -Doptimize=ReleaseSafe

rm -rf "$DATA_DIR" && mkdir -p "$DATA_DIR"
SUITE_ARGS=(
  --gitd-bin ./zig-out/bin/gitd
  --mode "$MODE"
  --oss-repos
  --oss-cache "$OSS_CACHE"
  --data-dir "$DATA_DIR"
  --out-dir "$OUT_DIR/suite"
)

echo "[ec2] running gitd benchmark suite ($MODE)..."
python3 tests/bench/suite.py "${SUITE_ARGS[@]}"

if [[ "$WITH_FORGES" == 1 ]]; then
  command -v docker >/dev/null || { echo "docker not installed; rerun with --no-forges" >&2; exit 1; }
  echo "[ec2] building gitd:bench docker image..."
  docker build -t gitd:bench .
  echo "[ec2] running forge comparison ($MODE)..."
  python3 tests/bench/compare_forges.py --mode "$MODE" --out-dir "$OUT_DIR/forges"
fi

{
  cat "$OUT_DIR/suite/results.md"
  if [[ "$WITH_FORGES" == 1 && -f "$OUT_DIR/forges/results.md" ]]; then
    echo
    cat "$OUT_DIR/forges/results.md"
  fi
} > "$OUT_DIR/REPORT.md"

echo
echo "[ec2] combined report saved to $OUT_DIR/REPORT.md"
