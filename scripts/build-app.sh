#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

fail() { printf '%s\n' "Clipato build: $*" >&2; exit 1; }
stage_only=false
target_arch="$(uname -m)"
channel=development
development_signing=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --stage-only) stage_only=true; shift ;;
        --channel)
            [ "$#" -ge 2 ] || fail '--channel 需要 development、direct、adhoc 或 app-store。'
            channel="$2"
            shift 2
            ;;
        --development-signing) development_signing=true; shift ;;
        --arch)
            [ "$#" -ge 2 ] || fail '--arch 需要 arm64 或 x86_64。'
            target_arch="$2"
            shift 2
            ;;
        *) fail '用法：build-app.sh [--stage-only] [--arch arm64|x86_64] [--channel development|direct|adhoc|app-store] [--development-signing]' ;;
    esac
done
case "$target_arch" in
    arm64|x86_64) ;;
    *) fail "未支持的架构：$target_arch，只支持 arm64 或 x86_64。" ;;
esac
case "$channel" in
    development|direct|adhoc|app-store) ;;
    *) fail '发行渠道必须为 development、direct、adhoc 或 app-store。' ;;
esac
if "$development_signing" && [ "$channel" != app-store ]; then
    fail '--development-signing 仅用于 app-store 沙盒预检。'
fi
if [ "$channel" = app-store ]; then
    "$stage_only" || fail '商店沙盒预检必须使用 --stage-only，不能替换现有应用。'
    "$development_signing" || fail '商店渠道当前提供 --development-signing 沙盒预检；正式 Store 归档还需配置 Apple Distribution 证书及描述文件。'
fi
if [ "$channel" = adhoc ]; then
    "$stage_only" || fail 'ad hoc 测试构建必须使用 --stage-only，不能替换现有稳定签名应用。'
    printf '%s\n' 'Clipato build: ad hoc 测试构建未经 Apple 公证，升级后可能需要重新授予屏幕录制权限。' >&2
fi

require_application_stopped() {
    if pgrep -f '/(FrameVault[.]app/Contents/MacOS/FrameVault|Clipato[.]app/Contents/MacOS/Clipato)([[:space:]]|$)' >/dev/null; then
        fail 'Clipato 正在运行。请先从菜单退出；构建不会自动停止应用或录制。'
    else
        process_status=$?
        [ "$process_status" -eq 1 ] || fail '无法检查 Clipato 运行状态，请从正常终端构建。'
    fi
}

identity_file="$project_dir/.build/framevault-signing-identity"
if [ "$channel" = adhoc ]; then
    signing_identity=-
else
    signing_identity="${FRAMEVAULT_SIGNING_IDENTITY-}"
    if [ "${FRAMEVAULT_SIGNING_IDENTITY+x}" = x ]; then
        [[ "$signing_identity" =~ ^[0-9A-Fa-f]{40}$ ]] || fail 'FRAMEVAULT_SIGNING_IDENTITY 必须是签名证书的 40 位 SHA-1 指纹。'
    elif [ "$channel" != direct ] && [ -f "$identity_file" ]; then
        signing_identity="$(cat "$identity_file")"
        [[ "$signing_identity" =~ ^[0-9A-Fa-f]{40}$ ]] || fail '已保存的签名指纹无效，请显式设置 FRAMEVAULT_SIGNING_IDENTITY。'
    fi

    if ! identities="$(security find-identity -v -p codesigning)"; then
        fail '无法读取代码签名身份；请从有钥匙串访问权限的终端运行构建。'
    fi
    identity_kind='Apple Development:'
    if [ "$channel" = direct ]; then identity_kind='Developer ID Application:'; fi
    eligible_identities="$(printf '%s\n' "$identities" | awk -v kind="\"$identity_kind" 'index($0, kind) { print toupper($2) }' | LC_ALL=C sort -u)"
    if [ -z "$eligible_identities" ]; then
        fail "当前进程未取得可用的 $identity_kind 签名身份，不能构建 $channel 渠道。"
    fi
    if [ -z "$signing_identity" ]; then
        signing_identity="$(printf '%s\n' "$eligible_identities" | sed -n '1p')"
    else
        signing_identity="$(printf '%s' "$signing_identity" | tr '[:lower:]' '[:upper:]')"
    fi
    printf '%s\n' "$eligible_identities" | grep -Fqx "$signing_identity" || fail "指定或已缓存的身份不是可用的 $identity_kind 证书；请显式选择有效 SHA-1 指纹。"
fi

production_dir="$project_dir/.build/production/$target_arch"
if [ "$channel" != development ]; then production_dir="$project_dir/.build/production/$channel/$target_arch"; fi
export CLANG_MODULE_CACHE_PATH="$production_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$production_dir/module-cache"
build_options=(--disable-sandbox --scratch-path "$production_dir" -c release --arch "$target_arch")
if [ "$channel" = app-store ]; then build_options+=(-Xswiftc -DAPP_STORE); fi
swift build "${build_options[@]}" --product Clipato \
    -Xlinker -no_exported_symbols
binary_dir="$(swift build "${build_options[@]}" --show-bin-path)"
app_dir="$project_dir/dist/Clipato.app"
mkdir -p "$project_dir/dist"
stage_dir="$(mktemp -d "$project_dir/dist/.Clipato-build.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage_app="$stage_dir/Clipato.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$binary_dir/Clipato" "$stage_app/Contents/MacOS/Clipato"
cp "$project_dir/Resources/Info.plist" "$stage_app/Contents/Info.plist"
plutil -insert ClipatoDistributionChannel -string "$channel" "$stage_app/Contents/Info.plist"
version_file="$project_dir/Sources/Clipato/Resources/Version.plist"
app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$version_file")"
app_build="$(plutil -extract CFBundleVersion raw -o - "$version_file")"
[[ "$app_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail '版本号必须为 major.minor.patch。'
[[ "$app_build" =~ ^[1-9][0-9]*$ ]] || fail '构建号必须为正整数。'
plutil -insert CFBundleShortVersionString -string "$app_version" "$stage_app/Contents/Info.plist"
plutil -insert CFBundleVersion -string "$app_build" "$stage_app/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$stage_app/Contents/Resources/AppIcon.icns"
cp -R "$binary_dir/Clipato_Clipato.bundle" "$stage_app/Contents/Resources/Clipato_Clipato.bundle"
if [ "$channel" = app-store ]; then
    rm -r "$stage_app/Contents/Resources/Clipato_Clipato.bundle/Skills"
    rm "$stage_app/Contents/Resources/Clipato_Clipato.bundle/UpdateSources.plist"
fi
cp "$project_dir/LICENSE" "$stage_app/Contents/Resources/LICENSE"
cp "$project_dir/Resources/PrivacyInfo.xcprivacy" "$stage_app/Contents/Resources/PrivacyInfo.xcprivacy"
mkdir -p "$stage_app/Contents/Resources/ThirdParty/libwebp"
cp "$project_dir/Vendor/libwebp/"{COPYING,PATENTS,AUTHORS} "$stage_app/Contents/Resources/ThirdParty/libwebp/"
cp "$project_dir/scripts/cli-launcher.sh" "$stage_dir/clipato"
chmod +x "$stage_dir/clipato"

stage_executable="$stage_app/Contents/MacOS/Clipato"
[ "$(lipo -archs "$stage_executable")" = "$target_arch" ] || fail '可执行文件架构与请求的架构不一致。'
binary_uuid="$(xcrun dwarfdump --uuid "$stage_executable" | awk '{ print $2 }')"
[ -n "$binary_uuid" ] || fail '无法读取可执行文件 UUID。'
xcrun dsymutil "$stage_executable" -o "$stage_dir/Clipato.app.dSYM"
symbol_uuid="$(xcrun dwarfdump --uuid "$stage_dir/Clipato.app.dSYM" | awk '{ print $2 }')"
[ "$binary_uuid" = "$symbol_uuid" ] || fail 'dSYM 与可执行文件的 UUID 不匹配。'

xcrun strip -u -r "$stage_executable"
stripped_uuid="$(xcrun dwarfdump --uuid "$stage_executable" | awk '{ print $2 }')"
[ "$binary_uuid" = "$stripped_uuid" ] || fail '剥离符号后可执行文件 UUID 发生变化。'
exports="$(xcrun nm --dyldinfo-only --defined-only --extern-only -j "$stage_executable")"
# Some Apple linkers retain this Mach-O header marker with -no_exported_symbols.
case "$exports" in
    ''|'__mh_execute_header') ;;
    *) fail $'发布可执行文件包含未预期的导出符号：\n'"$exports" ;;
esac
xcrun nm --no-dyldinfo -ap "$stage_executable" > "$stage_dir/symbols.txt"
# Apple's strip retains an N_OPT marker for dSYM compatibility, without source records.
if awk '$2 == "-" && $5 != "OPT" { found = 1 } END { exit !found }' "$stage_dir/symbols.txt"; then
    fail '发布可执行文件仍包含调试符号。'
fi

sign_options=(--force --sign "$signing_identity" --options runtime)
if [ "$channel" = direct ]; then sign_options+=(--timestamp); fi
if [ "$channel" = app-store ]; then sign_options+=(--entitlements "$project_dir/Resources/Clipato-AppStore.entitlements"); fi
codesign "${sign_options[@]}" "$stage_app"
codesign --verify --strict --verbose=2 "$stage_app"
if [ "$channel" != adhoc ]; then
    requirements="$(codesign --display -r- "$stage_app" 2>&1)"
    case "$requirements" in
        *'cdhash '*) fail '签名仍以构建哈希作为指定要求，无法稳定保留屏幕录制授权。' ;;
    esac
fi
printf '%s\n' "$signing_identity" > "$stage_dir/signing-identity"
codesign --display --entitlements - --xml "$stage_app" > "$stage_dir/entitlements.plist"
if [ -s "$stage_dir/entitlements.plist" ]; then
    plutil -convert json -o - "$stage_dir/entitlements.plist" | /usr/bin/python3 -c '
import json, plistlib, sys
entitlements = json.load(sys.stdin)
if entitlements.get("com.apple.security.get-task-allow") is True:
    sys.exit("Clipato build: 发布应用不能包含 get-task-allow 调试授权。")
if sys.argv[1] == "app-store":
    with open(sys.argv[2], "rb") as stream:
        expected = plistlib.load(stream)
    if entitlements != expected:
        sys.exit("Clipato build: 实际商店沙盒授权与批准的 entitlement 不一致。")
elif entitlements.get("com.apple.security.app-sandbox") is True:
    sys.exit("Clipato build: 独立发行配置意外启用了 App Sandbox。")
' "$channel" "$project_dir/Resources/Clipato-AppStore.entitlements"
elif [ "$channel" = app-store ]; then
    fail '商店预检应用缺少签名沙盒授权。'
fi
rm "$stage_dir/entitlements.plist"
symbol_archive="$project_dir/.build/symbols/$app_version-$app_build/$binary_uuid"
mkdir -p "$symbol_archive"
ditto "$stage_dir/Clipato.app.dSYM" "$symbol_archive/Clipato.app.dSYM"
rm -rf "$stage_dir/Clipato.app.dSYM"
rm "$stage_dir/symbols.txt"

if "$stage_only"; then
    trap - EXIT
    printf 'Staged: %s\nSymbols: %s\nSigning identity: %s\n' "$stage_app" "$symbol_archive/Clipato.app.dSYM" "$signing_identity"
    exit 0
fi

# Swap complete bundles atomically; the old application stays intact until signing succeeds.
require_application_stopped
swift "$project_dir/scripts/install-built-app.swift" "$stage_app" "$app_dir"
mv -f "$stage_dir/clipato" "$project_dir/dist/clipato"
mv -f "$stage_dir/signing-identity" "$identity_file"
printf 'Built: %s\nSymbols: %s\nSigning identity: %s\n' "$app_dir" "$symbol_archive/Clipato.app.dSYM" "$signing_identity"
