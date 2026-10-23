#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
qa_directory="$(mktemp -d "${TMPDIR:-/tmp}/clipato-region-qa.XXXXXX")"
trap 'rm -rf "$qa_directory"' EXIT

swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "${TMPDIR:-/tmp}/clipato-native-qa-modulecache" \
  Sources/Clipato/ScreenshotController.swift \
  Sources/Clipato/SelectionView.swift \
  Sources/Clipato/ImageAnnotation.swift \
  Sources/Clipato/ScreenCapturePermission.swift \
  Sources/Clipato/RecordingRegion.swift \
  Sources/Clipato/RecordingRegionOverlay.swift \
  scripts/qa-recording-region.swift \
  -o "$qa_directory/RecordingRegionQA"

"$qa_directory/RecordingRegionQA" "$@"
