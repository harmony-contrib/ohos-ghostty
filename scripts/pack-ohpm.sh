#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/package"
OUTPUT_DIR="${1:-${OHPM_OUTPUT_DIR:-$ROOT_DIR/dist}}"
OHPM_RS_BIN="${OHPM_RS_BIN:-ohpm-rs}"

if ! command -v "$OHPM_RS_BIN" >/dev/null 2>&1; then
  echo "ohpm-rs was not found. Install it or set OHPM_RS_BIN." >&2
  exit 1
fi

if [[ ! -f "$PACKAGE_DIR/oh-package.json5" ]]; then
  echo "Missing package/oh-package.json5." >&2
  exit 1
fi

# Build every ABI explicitly. A successful build of the default target alone
# is insufficient because ohpm packages must carry all supported native libs.
targets=(
  "arm64-v8a:aarch64-linux-ohos"
  "armeabi-v7a:arm-linux-ohos"
  "x86_64:x86_64-linux-ohos"
)

for entry in "${targets[@]}"; do
  abi="${entry%%:*}"
  target="${entry#*:}"
  echo "Building $abi ($target)..."
  "$ROOT_DIR/scripts/build-ohos.sh" -Dtarget="$target"
done

for entry in "${targets[@]}"; do
  abi="${entry%%:*}"
  library="$PACKAGE_DIR/libs/$abi/libterminal.so"
  if [[ ! -s "$library" ]]; then
    echo "Missing native artifact: $library" >&2
    exit 1
  fi
done

mkdir -p "$OUTPUT_DIR"

echo "Validating package source..."
"$OHPM_RS_BIN" prepublish "$PACKAGE_DIR"

echo "Packing ohpm HAR..."
"$OHPM_RS_BIN" pack "$PACKAGE_DIR" --output "$OUTPUT_DIR"

echo "Package written to $OUTPUT_DIR"
