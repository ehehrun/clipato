#!/usr/bin/python3
"""Clipato 本地 DMG 构建与 GitHub Release 发布。"""

import argparse
import curses
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "Sources/Clipato/Resources/Version.plist"
LOCAL_BUILD_MARKER = "Clipato-Local-Build: "


class ReleaseError(Exception):
    pass


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=ROOT, text=True).strip()


def choose(screen, version, build, selected, channel="stable"):
    options = [
        "Apple Silicon · arm64",
        "Intel · x86_64",
        "构建前运行 Release 测试",
        "先备份同名安装包，再重新构建",
        "创建 GitHub Release 并公开发布",
    ]
    current = 0
    message = ""
    screen.keypad(True)
    curses.curs_set(0)
    while True:
        screen.erase()
        height, width = screen.getmaxyx()
        if height < 17 or width < 64:
            screen.addstr(0, 0, "请扩大终端窗口（至少 64 列、17 行）。"[:max(0, width // 2 - 1)])
        else:
            screen.addstr(1, 2, f"Clipato · 本地发布 · {channel.title()}", curses.A_BOLD)
            screen.addstr(3, 2, f"版本 {version} · 构建 {build}")
            screen.addstr(4, 2, "签名：ad hoc · 未公证")
            screen.addstr(5, 2, "上传前需提交所有改动")
            screen.addstr(6, 2, "↑↓ 移动   空格 勾选   Enter 继续")
            screen.addstr(7, 2, "V 修改版本/构建号   C 切换渠道   Esc / q 取消")
            for index, label in enumerate(options):
                prefix = "[x]" if selected[index] else "[ ]"
                style = curses.A_REVERSE if index == current else curses.A_NORMAL
                screen.addstr(8 + index, 2, f" {prefix} {label} ", style)
            if message:
                screen.addstr(14, 2, message, curses.A_BOLD)
        screen.refresh()
        key = screen.get_wch()
        if key in ("q", "Q", "\x1b"):
            return "cancel"
        if height < 17 or width < 64:
            continue
        if key == curses.KEY_UP:
            current = (current - 1) % len(options)
        elif key == curses.KEY_DOWN:
            current = (current + 1) % len(options)
        elif key == " ":
            selected[current] = not selected[current]
            message = ""
        elif key in ("v", "V"):
            return "edit-version"
        elif key in ("c", "C"):
            return "toggle-channel"
        elif key in ("\n", "\r", curses.KEY_ENTER):
            if selected[0] or selected[1]:
                return "continue"
            message = "请至少勾选一种架构。"


def validate_version(version, build):
    number = r"(0|[1-9][0-9]*)"
    if not isinstance(version, str) or not re.fullmatch(rf"{number}\.{number}\.{number}", version):
        raise ReleaseError("版本号必须为 major.minor.patch，例如 0.1.1。")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ReleaseError("构建号必须为正整数，例如 4。")


def read_version():
    with VERSION_FILE.open("rb") as stream:
        info = plistlib.load(stream)
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    validate_version(version, build)
    return version, build


def save_version(version, build, *, dry_run=False):
    validate_version(version, build)
    original = VERSION_FILE.read_bytes()
    info = plistlib.loads(original)
    fields = {"CFBundleShortVersionString": version, "CFBundleVersion": build}
    if all(info[key] == value for key, value in fields.items()):
        print(f"版本未变化：{version} (build {build})")
        return
    if dry_run:
        print(f"仅预览：版本 {info['CFBundleShortVersionString']} → {version}，"
              f"构建 {info['CFBundleVersion']} → {build}；未写入文件。")
        return

    if original.startswith(b"bplist00"):
        info.update(fields)
        updated = plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False)
    else:
        updated = original
        for key, value in fields.items():
            pattern = (rb"(<key>" + key.encode("ascii") +
                       rb"</key>(?:\s|<!--.*?-->)*<string>)[^<]*(</string>)")
            updated, count = re.subn(
                pattern, lambda match: match[1] + value.encode("ascii") + match[2],
                updated, flags=re.DOTALL,
            )
            if count != 1:
                raise ReleaseError(f"Version.plist 中 {key} 必须有且只有一个 string 字段。")

    mode = stat.S_IMODE(VERSION_FILE.stat().st_mode)
    descriptor, temporary = tempfile.mkstemp(prefix=".Version-", suffix=".plist", dir=VERSION_FILE.parent)
    temporary = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(updated)
        if VERSION_FILE.read_bytes() != original:
            raise ReleaseError("保存期间 Version.plist 已被修改，请重新读取后再试。")
        os.replace(temporary, VERSION_FILE)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"已保存：版本 {version} · 构建 {build}\n{VERSION_FILE}")
    print("上传前请提交版本改动；此操作未构建、创建 tag 或上传。")


def edit_version(version, build, dry_run=False):
    print("\n修改本地版本配置，Enter 保留当前值。")
    new_version = input(f"版本号 [{version}]：").strip() or version
    new_build = input(f"构建号 [{build}]：").strip() or build
    validate_version(new_version, new_build)
    if (new_version, new_build) == (version, build):
        print("版本未变化。")
        return version, build
    print(f"版本：{version} → {new_version}\n构建：{build} → {new_build}")
    prompt = "预览这些改动？[y/N]：" if dry_run else "保存到 Version.plist？[y/N]："
    if input(prompt).strip().lower() != "y":
        print("已取消修改。")
        return version, build
    save_version(new_version, new_build, dry_run=dry_run)
    return new_version, new_build


def github_destination():
    origin = git("remote", "get-url", "--push", "origin")
    match = re.fullmatch(r"(?:git@github\.com:|https://github\.com/)([\w.-]+/[\w.-]+)/?", origin)
    if not match:
        raise ReleaseError("上传需要 origin 为 github.com 的 SSH 或 HTTPS 仓库地址。")
    return origin, match[1].removesuffix(".git")


def check_source(commit):
    if git("rev-parse", "HEAD") != commit:
        raise ReleaseError("构建期间 HEAD 已变化，停止上传。请从需要发布的提交重新构建。")
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise ReleaseError("上传需要干净且已提交的工作区，请先提交更改再重新运行。")


def check_new_tag(tag, remote):
    local = subprocess.run(["git", "show-ref", "--verify", "--quiet", f"refs/tags/{tag}"], cwd=ROOT)
    if local.returncode == 0:
        raise ReleaseError(f"本地 tag {tag} 已存在。请使用新版本，不会覆盖现有 tag。")
    if local.returncode != 1:
        local.check_returncode()
    remote = subprocess.run(
        ["git", "ls-remote", "--exit-code", remote, f"refs/tags/{tag}"],
        cwd=ROOT, stdout=subprocess.PIPE, text=True,
    )
    if remote.returncode == 0:
        raise ReleaseError(f"远端 tag {tag} 已存在。请使用新版本，不会覆盖现有 tag。")
    if remote.returncode != 2:
        remote.check_returncode()


def asset_paths(version, build, architectures):
    paths = []
    for architecture in architectures:
        image = ROOT / "dist" / f"Clipato-{version}-{build}-{architecture}.dmg"
        paths.extend([image, image.with_suffix(".dmg.sha256")])
    return paths


def file_hash(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def verify_assets(paths):
    hashes = {}
    for image, checksum in zip(paths[::2], paths[1::2]):
        digest = file_hash(image)
        expected = f"{digest}  {image.name}\n"
        if checksum.read_text(encoding="utf-8") != expected:
            raise ReleaseError(f"SHA-256 校验失败：{image.name}")
        hashes[image] = digest
        hashes[checksum] = file_hash(checksum)
    return hashes


def backup_assets(paths):
    existing = [path for path in paths if path.exists()]
    if not existing:
        return
    archive = ROOT / "dist/archive"
    archive.mkdir(parents=True, exist_ok=True)
    destination = Path(tempfile.mkdtemp(prefix="release-", dir=archive))
    for path in existing:
        shutil.move(str(path), destination / path.name)
    print(f"旧产物已备份：{destination}")


def release_tag(version, build, channel="stable"):
    suffix = {"stable": "", "nightly": f"-nightly.{build}"}[channel]
    return f"v{version}{suffix}"


def release_title(version, build, channel="stable"):
    name = {"stable": "Stable", "nightly": "Nightly"}[channel]
    return f"Clipato {version} (build {build}) · {name}"


def release_notes(version, build, commit, architectures, channel="stable"):
    names = {"arm64": "Apple Silicon（M 系列芯片）", "x86_64": "Intel"}
    lines = [f"# {release_title(version, build, channel)}", ""]
    lines.extend(f"- {names[architecture]}：`-{architecture}.dmg`。" for architecture in architectures)
    lines.extend([
        "- 要求 macOS 14 或以上。",
        "- 使用 Release 优化、调试符号剥离与 ad hoc 签名，未经过 Developer ID 签名和 Apple 公证。",
        "- 升级后可能需要重新授予屏幕录制权限。",
        "- `.sha256` 为对应安装包的 SHA-256 校验文件。",
        "", f"源码提交：`{commit}`", "",
    ])
    return "\n".join(lines)


def upload_release(repository, remote, commit, version, build, paths, hashes, notes, channel="stable"):
    tag = release_tag(version, build, channel)
    check_source(commit)
    print(f"\n将推送 tag、上传附件并公开发布到：{repository}")
    print(f"Tag：{tag}    源码提交：{commit}")
    print(f"发布类型：{channel.title()} · {'预发布版本' if channel == 'nightly' else '正式版本'} · 公开发布")
    for path in paths:
        print(f"  {path.name} · {path.stat().st_size:,} bytes\n    SHA-256 {hashes[path]}")
    print(f"\n更新说明：\n{notes}")
    confirmation = f"publish {tag}"
    if input(f"输入 {confirmation} 才会推送 tag、上传附件并公开发布，其他输入取消：").strip() != confirmation:
        print("已取消发布，本地安装包已保留。")
        return

    check_source(commit)
    check_new_tag(tag, remote)
    if verify_assets(paths) != hashes:
        raise ReleaseError("确认期间安装包或校验文件发生变化，停止上传。")
    annotation = f"{release_title(version, build, channel)}\n\n{LOCAL_BUILD_MARKER}{commit}"
    subprocess.run(["git", "tag", "-a", tag, commit, "-m", annotation], cwd=ROOT, check=True)
    try:
        subprocess.run(["git", "push", "--no-follow-tags", remote, f"refs/tags/{tag}:refs/tags/{tag}"], cwd=ROOT, check=True)
    except subprocess.CalledProcessError as error:
        raise ReleaseError(f"本地 {tag} 已创建，但推送失败。安装包与本地 tag 均已保留，请检查 Git 输出。") from error
    print(f"已推送 {tag}；云端只运行识别步骤，跳过 macOS 打包。", flush=True)

    notes_directory = ROOT / ".build/local-release"
    notes_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", suffix=".md", prefix="notes-", dir=notes_directory,
                                     encoding="utf-8", delete=False) as stream:
        stream.write(notes)
        notes_path = Path(stream.name)
    try:
        command = [
            "gh", "release", "create", tag, *[str(path) for path in paths],
            "--repo", f"github.com/{repository}", "--verify-tag",
            "--title", release_title(version, build, channel), "--notes-file", str(notes_path),
        ]
        if channel == "nightly":
            command.append("--prerelease")
        subprocess.run(command, cwd=ROOT, check=True)
    except subprocess.CalledProcessError as error:
        raise ReleaseError(
            f"{tag} 已推送，但创建或上传 Release 失败。可能已创建 Release 或上传部分附件；请在 GitHub 检查。\n"
            f"本地产物和 tag 均已保留，更新说明：{notes_path}"
        ) from error
    notes_path.unlink()
    print(f"\n{channel.title()} Release 已发布：https://github.com/{repository}/releases/tag/{tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog="↑↓ 移动，空格勾选，V 修改版本，C 切换渠道，Enter 继续，Esc / q 取消。")
    parser.add_argument("--dry-run", action="store_true", help="只显示计划，不写入版本、测试、构建、备份或发布")
    parser.add_argument("--set-version", metavar="VERSION", help="设置 major.minor.patch 版本号后退出")
    parser.add_argument("--set-build", metavar="BUILD", help="设置正整数构建号后退出")
    parser.add_argument("--edit-version", action="store_true", help="交互修改版本号与构建号后退出")
    parser.add_argument("--release-channel", choices=("stable", "nightly"), default="stable", help="发布渠道（默认 stable）；不改变签名方式")
    arguments = parser.parse_args()
    setting_version = arguments.set_version is not None or arguments.set_build is not None
    if arguments.edit_version and setting_version:
        parser.error("--edit-version 不能与 --set-version / --set-build 同时使用。")
    version, build = read_version()
    if setting_version:
        save_version(
            arguments.set_version if arguments.set_version is not None else version,
            arguments.set_build if arguments.set_build is not None else build,
            dry_run=arguments.dry_run,
        )
        return
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise ReleaseError("请在交互式终端中运行此脚本。帮助：./scripts/release-local.py --help")
    if arguments.edit_version:
        edit_version(version, build, arguments.dry_run)
        return
    os.chdir(ROOT)
    selected = [True, True, True, False, False]
    channel = arguments.release_channel
    while True:
        action = curses.wrapper(choose, version, build, selected, channel)
        if action == "cancel":
            print("已取消。")
            return
        if action == "continue":
            break
        if action == "toggle-channel":
            channel = "nightly" if channel == "stable" else "stable"
        else:
            version, build = edit_version(version, build, arguments.dry_run)
    arm64, intel, tests, backup, upload = selected
    architectures = [architecture for architecture, enabled in [("arm64", arm64), ("x86_64", intel)] if enabled]
    paths = asset_paths(version, build, architectures)
    commit = git("rev-parse", "HEAD")
    remote, repository = github_destination() if upload else (None, None)
    print(f"\n{release_title(version, build, channel)}")
    print(f"Tag：{release_tag(version, build, channel)}")
    print("签名：ad hoc · 未公证")
    print(f"架构：{', '.join(architectures)}")
    print(f"Release 测试：{'运行' if tests else '跳过'}")
    print(f"同名产物：{'备份后重建' if backup else '存在时停止'}")
    print(f"GitHub：{'创建 Release 并公开发布到 ' + repository if upload else '仅本地构建'}")
    print(f"输出：{ROOT / 'dist'}")
    if arguments.dry_run:
        print("\n仅预览，未执行任何操作。")
        return

    existing = [str(path) for path in paths if path.exists()]
    if existing and not backup:
        raise ReleaseError("同名产物已存在，请勾选备份或修改版本/构建号：\n" + "\n".join(existing))
    notes = ""
    if upload:
        check_source(commit)
        if shutil.which("gh") is None:
            raise ReleaseError("未安装 GitHub CLI。请先运行 brew install gh，然后 gh auth login。")
        subprocess.run(["gh", "auth", "status", "--hostname", "github.com"], cwd=ROOT, check=True)
        check_new_tag(release_tag(version, build, channel), remote)
        notes_input = input("更新说明 Markdown 文件路径（留空自动生成）：").strip()
        notes = Path(notes_input).expanduser().read_text(encoding="utf-8") if notes_input else release_notes(version, build, commit, architectures, channel)
    if tests:
        subprocess.run([str(ROOT / "scripts/test.sh"), "-c", "release", "--disable-swift-testing"], cwd=ROOT, check=True)
    if upload:
        check_source(commit)
    if backup:
        backup_assets(paths)
    for architecture in architectures:
        subprocess.run([
            str(ROOT / "scripts/build-dmg.sh"), "--arch", architecture, "--channel", "adhoc",
        ], cwd=ROOT, check=True)
    hashes = verify_assets(paths)
    print("\n本地安装包及 SHA-256 校验完成：")
    for path in paths:
        print(f"  {path}")
    if upload:
        upload_release(repository, remote, commit, version, build, paths, hashes, notes, channel)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        print("\n已中断。已生成的安装包和已完成的 tag / Release 操作会保留。", file=sys.stderr)
        sys.exit(130)
    except (ReleaseError, OSError, subprocess.CalledProcessError, ValueError, KeyError, curses.error) as error:
        print(f"\nClipato release: {error}", file=sys.stderr)
        sys.exit(1)
