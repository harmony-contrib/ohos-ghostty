#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

./scripts/build-ohos.sh

HVIGOR_BIN="${HVIGOR_BIN:-}"
if [[ -z "$HVIGOR_BIN" && -n "${DEVECO_SDK_HOME:-}" ]]; then
  CANDIDATE="$(dirname "$DEVECO_SDK_HOME")/tools/hvigor/bin/hvigorw"
  if [[ -x "$CANDIDATE" ]]; then
    HVIGOR_BIN="$CANDIDATE"
  fi
fi

if [[ -z "$HVIGOR_BIN" ]]; then
  echo "Native libraries are ready. Open this directory in DevEco Studio to assemble the HAP."
  exit 0
fi

"$HVIGOR_BIN" assembleHap --no-daemon
echo "HAP assembled"
