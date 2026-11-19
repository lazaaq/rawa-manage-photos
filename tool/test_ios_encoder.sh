#!/usr/bin/env bash
# Tests ios/Runner/RawJpegEncoder.swift on macOS (same Core Image / ImageIO APIs as iOS),
# without a simulator or device.
#
#   tool/test_ios_encoder.sh                  # synthetic DNG fixtures only
#   CR3_SAMPLES_DIR=~/Pictures/cr3 tool/test_ios_encoder.sh   # + real camera files
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 -I "$ROOT/tool/make_test_dng.py" "$WORK/land.dng" 1200 800 1
python3 -I "$ROOT/tool/make_test_dng.py" "$WORK/port.dng" 1200 800 6

xcrun swiftc -O -target "$(uname -m)-apple-macos13" \
  "$ROOT/ios/Runner/RawJpegEncoder.swift" "$ROOT/ios/EncoderTests/main.swift" \
  -o "$WORK/encoder-tests"

"$WORK/encoder-tests" "$WORK" "${CR3_SAMPLES_DIR:-}"
