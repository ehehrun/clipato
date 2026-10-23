#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

fail() { printf '%s\n' "Clipato DMG: $*" >&2; exit 1; }
target_arch="$(uname -m)"
channel=development
while [ "$#" -gt 0 ]; do
    case "$1" in
        --arch)
            [ "$#" -ge 2 ] || fail '--arch 需要 arm64 或 x86_64。'
            target_arch="$2"; shift 2 ;;
        --channel)
            [ "$#" -ge 2 ] || fail '--channel 需要 development、direct 或 adhoc。'
            channel="$2"; shift 2 ;;
        *) fail '用法：build-dmg.sh [--arch arm64|x86_64] [--channel development|direct|adhoc]' ;;
    esac
done
case "$target_arch" in
    arm64|x86_64) ;;
    *) fail "未支持的架构：$target_arch，只支持 arm64 或 x86_64。" ;;
esac
case "$channel" in
    development|direct|adhoc) ;;
    *) fail 'DMG 仅用于 development、direct 或 adhoc 渠道；App Store 使用商店归档。' ;;
esac

mkdir -p "$project_dir/.build"
work_dir="$(mktemp -d "$project_dir/.build/Clipato-dmg.XXXXXX")"
stage_dir=''
mount_dir="$work_dir/mounted"
mounted=false

cleanup() {
    status=$?
    trap - EXIT
    if "$mounted"; then
        if ! hdiutil detach "$mount_dir"; then
            printf 'Clipato DMG: 无法卸载 %s，保留工作目录：%s\n' "$mount_dir" "$work_dir" >&2
            exit 1
        fi
    fi
    if [ -n "$stage_dir" ]; then rm -rf "$stage_dir"; fi
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$project_dir/scripts/build-app.sh" --stage-only --arch "$target_arch" --channel "$channel" | tee "$work_dir/build.log"
stage_app="$(sed -n 's/^Staged: //p' "$work_dir/build.log")"
case "$stage_app" in
    "$project_dir"/dist/.Clipato-build.*/Clipato.app) stage_dir="$(dirname "$stage_app")" ;;
    *) fail '构建未返回预期的暂存应用路径。' ;;
esac

app_plist="$stage_app/Contents/Info.plist"
version_plist="$stage_app/Contents/Resources/Clipato_Clipato.bundle/Version.plist"
app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_plist")"
app_build="$(plutil -extract CFBundleVersion raw -o - "$app_plist")"
[ "$app_version" = "$(plutil -extract CFBundleShortVersionString raw -o - "$version_plist")" ] || fail '应用与资源包的版本号不一致。'
[ "$app_build" = "$(plutil -extract CFBundleVersion raw -o - "$version_plist")" ] || fail '应用与资源包的构建号不一致。'
architectures="$(lipo -archs "$stage_app/Contents/MacOS/Clipato")"
[ "$architectures" = "$target_arch" ] || fail '包内程序架构与请求的架构不一致。'
image_arch="$architectures"

image_name="Clipato-$app_version-$app_build-$image_arch.dmg"
output_image="$project_dir/dist/$image_name"
[ ! -e "$output_image" ] && [ ! -e "$output_image.sha256" ] || fail "已有同名产物：$output_image，请明确移走旧产物后重试。"

payload_dir="$work_dir/payload"
mkdir -p "$payload_dir" "$mount_dir"
ditto "$stage_app" "$payload_dir/Clipato.app"
ln -s /Applications "$payload_dir/Applications"
codesign --verify --strict --verbose=2 "$payload_dir/Clipato.app"
hdiutil create -fs HFS+ -format UDZO -volname Clipato -nospotlight \
    -srcfolder "$payload_dir" "$work_dir/$image_name"
if [ "$channel" = direct ]; then
    signing_identity="$(sed -n 's/^Signing identity: //p' "$work_dir/build.log")"
    [[ "$signing_identity" =~ ^[0-9A-Fa-f]{40}$ ]] || fail '构建未返回有效签名身份。'
    codesign --force --timestamp --sign "$signing_identity" "$work_dir/$image_name"
    codesign --verify --strict --verbose=2 "$work_dir/$image_name"
fi
hdiutil verify -nocache "$work_dir/$image_name"

# Keep the work directory if attachment or detachment fails; never remove a mounted volume.
mounted=true
hdiutil attach -readonly -nobrowse -noautoopen -verify \
    -mountpoint "$mount_dir" "$work_dir/$image_name"
mounted_app="$mount_dir/Clipato.app"
entries=("$mount_dir"/*)
[ "${#entries[@]}" -eq 2 ] && [ -d "$mounted_app" ] || fail '磁盘映像安装内容不符合预期。'
[ -L "$mount_dir/Applications" ] && [ "$(readlink "$mount_dir/Applications")" = /Applications ] || fail '应用程序安装入口无效。'
[ -x "$mounted_app/Contents/MacOS/Clipato" ] || fail '包内程序不可执行。'
codesign --verify --strict --verbose=2 "$mounted_app"
diff -qr "$stage_app" "$mounted_app"
unexpected_files="$(find "$mounted_app" \( -name '*.dSYM' -o -name '*.swift' -o -name '*.swiftmodule' -o -name '*.a' \) -print)"
[ -z "$unexpected_files" ] || fail "磁盘映像中含有开发文件：$unexpected_files"
source_hash="$(shasum -a 256 "$stage_app/Contents/MacOS/Clipato" | awk '{ print $1 }')"
mounted_hash="$(shasum -a 256 "$mounted_app/Contents/MacOS/Clipato" | awk '{ print $1 }')"
[ "$source_hash" = "$mounted_hash" ] || fail '包内程序校验和不一致。'
hdiutil detach "$mount_dir"
mounted=false

(cd "$work_dir" && shasum -a 256 "$image_name") > "$work_dir/$image_name.sha256"
# Hard links publish complete files without overwriting an existing release artifact.
ln "$work_dir/$image_name" "$output_image"
ln "$work_dir/$image_name.sha256" "$output_image.sha256"
printf 'DMG: %s\nSHA-256: %s\nArchitecture: %s\n' "$output_image" "$output_image.sha256" "$architectures"
