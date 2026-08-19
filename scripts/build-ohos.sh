#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${OHOS_NDK_HOME:-}" && -z "${OHOS_SDK_HOME:-}" ]]; then
  echo "Set OHOS_NDK_HOME or OHOS_SDK_HOME before building." >&2
  exit 1
fi

# zig-napi expects OHOS_NDK_HOME to be the SDK root, while the other native
# dependencies accept either the SDK root or its native/ child. Normalize the
# environment once so the whole dependency graph resolves the same sysroot.
if [[ -z "${OHOS_NDK_HOME:-}" ]]; then
  export OHOS_NDK_HOME="$OHOS_SDK_HOME"
elif [[ "$(basename "$OHOS_NDK_HOME")" == "native" ]]; then
  export OHOS_NDK_HOME="$(dirname "$OHOS_NDK_HOME")"
fi

zig build -Doptimize="${OPTIMIZE:-ReleaseFast}" "$@"
zig build dist -Doptimize="${OPTIMIZE:-ReleaseFast}" "$@"

echo "Zig built libterminal.so and installed it into package/libs and example/libs"
