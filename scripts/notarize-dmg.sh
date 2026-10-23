#!/bin/bash
set -euo pipefail

fail() { printf 'Clipato notarization: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 3 ] && [ "$1" = --submit ] || fail '用法：notarize-dmg.sh --submit /path/Clipato.dmg KEYCHAIN_PROFILE；--submit 会上传安装包到 Apple。'
image="$2"
profile="$3"
[[ "$image" = *.dmg ]] && [ -f "$image" ] || fail '请指定已完成 Developer ID 签名的 DMG。'
image_dir="$(cd "$(dirname "$image")" && pwd)"
image_name="$(basename "$image")"
image="$image_dir/$image_name"
receipt="$image.notarization.json"
[ ! -e "$receipt" ] || fail "已有提交记录：$receipt，请先检查该记录，避免重复上传。"
codesign --verify --strict --verbose=2 "$image"
signature="$(codesign --display --verbose=4 "$image" 2>&1)"
case "$signature" in
    *'Authority=Developer ID Application:'*) ;;
    *) fail 'DMG 必须由 Developer ID Application 证书签名。' ;;
esac

xcrun notarytool submit "$image" --keychain-profile "$profile" --wait --output-format json > "$receipt"
/usr/bin/python3 - "$receipt" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
if result['status'] != 'Accepted':
    sys.exit(f"Apple notarization did not accept this submission; inspect {sys.argv[1]} (id {result['id']}).")
PY
xcrun stapler staple "$image"
xcrun stapler validate "$image"
codesign --verify --strict --verbose=2 "$image"
(cd "$image_dir" && shasum -a 256 "$image_name") > "$image.sha256"
printf 'Notarized DMG: %s\nSubmission record: %s\n' "$image" "$receipt"
