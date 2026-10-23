#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" != "--run-native" ]]; then
  print -u2 'Usage: scripts/qa-system-image-preview.sh --run-native'
  print -u2 'Runs transparent native image-preview windows and real Live Text analysis with generated fixtures, briefly activates the QA process, then restores the previous app. No screenshots or system input.'
  exit 2
fi

cd "$(dirname "$0")/.."
CLIPATO_NATIVE_PREVIEW_QA=1 ./scripts/test.sh -c release --disable-swift-testing \
  --filter NativeImagePreviewIntegrationTests
