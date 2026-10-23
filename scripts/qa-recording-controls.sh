#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
qa_directory="$(mktemp -d "${TMPDIR:-/tmp}/clipato-controls-qa.XXXXXX")"
trap 'rm -rf "$qa_directory"' EXIT

swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "${TMPDIR:-/tmp}/clipato-native-qa-modulecache" \
  Sources/Clipato/RecordingRegion.swift \
  Sources/Clipato/RecordingRegionOverlay.swift \
  scripts/qa-recording-controls.swift \
  -o "$qa_directory/RecordingControlsQA"

"$qa_directory/RecordingControlsQA" "$@"
