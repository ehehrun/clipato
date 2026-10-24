"""Release boundaries use real local Git repositories; DMG fixtures are plain bytes."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "release-local.py"
SPEC = importlib.util.spec_from_file_location("release_local", SCRIPT)
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class LocalReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clipato-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root = self.directory / "source"
        self.origin = self.directory / "origin.git"
        self.bin = self.directory / "bin"
        self.calls = self.directory / "gh-calls.jsonl"
        self.failure = self.directory / "gh-fail"
        self.bin.mkdir()
        self.run_git("init", "--quiet", "--bare", str(self.origin), cwd=self.directory)
        self.run_git("init", "--quiet", "-b", "main", str(self.root), cwd=self.directory)
        self.git("config", "user.name", "Clipato Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        (self.root / ".gitignore").write_text("dist/\n.build/\n", encoding="utf-8")
        (self.root / "source.swift").write_text("let version = 1\n", encoding="utf-8")
        self.version_file = self.root / "Sources/Clipato/Resources/Version.plist"
        self.version_file.parent.mkdir(parents=True)
        with self.version_file.open("wb") as stream:
            plistlib.dump({"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "4"}, stream)
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Initial source")
        self.initial_commit = self.git("rev-parse", "HEAD")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "--quiet", "origin", "main")
        executable = self.bin / "gh"
        executable.write_text(
            f"#!{sys.executable}\n"
            "import json, pathlib, sys\n"
            "arguments = sys.argv[1:]\n"
            "record = {'arguments': arguments}\n"
            "if '--notes-file' in arguments:\n"
            "    record['notes'] = pathlib.Path(arguments[arguments.index('--notes-file') + 1]).read_text()\n"
            f"with open({str(self.calls)!r}, 'a') as stream:\n"
            "    stream.write(json.dumps(record) + '\\n')\n"
            f"sys.exit(12 if pathlib.Path({str(self.failure)!r}).exists() else 0)\n",
            encoding="utf-8",
        )
        executable.chmod(0o755)
        for change in (
            patch.object(release, "ROOT", self.root),
            patch.object(release, "VERSION_FILE", self.version_file),
            patch.dict(os.environ, {"PATH": str(self.bin) + os.pathsep + os.environ["PATH"]}),
        ):
            change.start()
            self.addCleanup(change.stop)

    def run_git(self, *arguments, cwd):
        return subprocess.check_output(
            ["git", *arguments], cwd=cwd, text=True, stderr=subprocess.PIPE,
        ).strip()

    def git(self, *arguments):
        return self.run_git(*arguments, cwd=self.root)

    def remote_git(self, *arguments):
        return self.run_git(*arguments, cwd=self.origin)

    def assets(self, architectures=("arm64",)):
        paths = release.asset_paths("1.2.3", "4", architectures)
        for image, checksum in zip(paths[::2], paths[1::2]):
            image.parent.mkdir(exist_ok=True)
            image.write_bytes(b"test package bytes: " + image.name.encode())
            self.write_checksum(image, checksum)
        return paths

    @staticmethod
    def write_checksum(image, checksum):
        checksum.write_text(
            f"{hashlib.sha256(image.read_bytes()).hexdigest()}  {image.name}\n", encoding="utf-8",
        )

    def upload(self, paths, answer, hashes=None, channel="stable"):
        commit = self.git("rev-parse", "HEAD")
        if hashes is None:
            hashes = release.verify_assets(paths)
        with patch("builtins.input", side_effect=answer), contextlib.redirect_stdout(io.StringIO()):
            release.upload_release(
                "example/clipato", str(self.origin), commit, "1.2.3", "4", paths, hashes, "Release notes\n", channel,
            )
        return commit

    def assert_no_release_mutation(self):
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertEqual(self.remote_git("tag", "--list"), "")
        self.assertEqual(self.remote_git("rev-parse", "refs/heads/main"), self.initial_commit)
        self.assertFalse(self.calls.exists())

    def test_checksum_rejects_content_and_filename_mismatches(self):
        paths = self.assets()
        original = paths[1].read_text()
        for invalid in ("0" * 64 + "  " + paths[0].name + "\n", original.replace("arm64", "x86_64")):
            with self.subTest(checksum=invalid):
                paths[1].write_text(invalid)
                with self.assertRaisesRegex(release.ReleaseError, "SHA-256"):
                    release.verify_assets(paths)

    def test_backup_preserves_selected_artifacts_and_leaves_other_architecture(self):
        selected = self.assets()
        unselected = self.assets(("x86_64",))
        previous = {path.name: path.read_bytes() for path in selected}
        with contextlib.redirect_stdout(io.StringIO()):
            release.backup_assets(selected)
        archives = list((self.root / "dist/archive").iterdir())
        self.assertEqual(len(archives), 1)
        self.assertEqual({path.name: path.read_bytes() for path in archives[0].iterdir()}, previous)
        self.assertTrue(all(not path.exists() for path in selected))
        self.assertTrue(all(path.exists() for path in unselected))

    def test_source_rejects_tracked_and_untracked_changes(self):
        source = self.root / "source.swift"
        source.write_text("let version = 2\n")
        with self.assertRaisesRegex(release.ReleaseError, "工作区"):
            release.check_source(self.initial_commit)
        self.git("restore", "source.swift")
        (self.root / "uncommitted.swift").write_text("let extra = true\n")
        with self.assertRaisesRegex(release.ReleaseError, "工作区"):
            release.check_source(self.initial_commit)

    def test_source_rejects_head_change(self):
        self.git("commit", "--quiet", "--allow-empty", "-m", "Later source")
        with self.assertRaisesRegex(release.ReleaseError, "HEAD"):
            release.check_source(self.initial_commit)

    def test_new_tag_accepts_absence_and_rejects_existing_local_tag(self):
        release.check_new_tag("v1.2.3", str(self.origin))
        self.git("tag", "v1.2.3")
        with self.assertRaisesRegex(release.ReleaseError, "本地 tag"):
            release.check_new_tag("v1.2.3", str(self.origin))

    def test_new_tag_rejects_remote_only_tag(self):
        self.git("tag", "v1.2.3")
        self.git("push", "--quiet", "origin", "refs/tags/v1.2.3")
        self.git("tag", "--delete", "v1.2.3")
        with self.assertRaisesRegex(release.ReleaseError, "远端 tag"):
            release.check_new_tag("v1.2.3", str(self.origin))

    def test_remote_failure_is_not_treated_as_missing_tag(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                release.check_new_tag("v1.2.3", str(self.directory / "missing.git"))
        self.assertNotIn(failure.exception.returncode, (0, 2))
        self.assert_no_release_mutation()

    def test_github_destination_uses_push_target_instead_of_fetch_repository(self):
        target = "git@github.com:example/clipato.git"
        self.git("remote", "set-url", "--push", "origin", target)
        self.assertEqual(release.github_destination(), (target, "example/clipato"))
        self.git("remote", "set-url", "--push", "origin", str(self.origin))
        with self.assertRaisesRegex(release.ReleaseError, "github.com"):
            release.github_destination()

    def test_final_cancellation_leaves_tags_and_assets_untouched(self):
        paths = self.assets()
        before = {path: path.read_bytes() for path in paths}
        self.upload(paths, lambda _: "yes")
        self.assert_no_release_mutation()
        self.assertEqual({path: path.read_bytes() for path in paths}, before)

    def test_previous_upload_confirmation_does_not_authorize_publication(self):
        paths = self.assets()
        before = {path: path.read_bytes() for path in paths}
        for channel, tag in (("stable", "v1.2.3"), ("nightly", "v1.2.3-nightly.4")):
            with self.subTest(channel=channel):
                self.upload(paths, lambda _: f"upload {tag}", channel=channel)
                self.assert_no_release_mutation()
                self.assertEqual({path: path.read_bytes() for path in paths}, before)

    def test_end_of_input_does_not_create_tag_or_upload(self):
        paths = self.assets()

        def cancel(_):
            raise EOFError

        with self.assertRaises(EOFError):
            self.upload(paths, cancel)
        self.assert_no_release_mutation()

    def test_source_change_during_confirmation_stops_before_creating_tag(self):
        paths = self.assets()

        def confirm(_):
            (self.root / "source.swift").write_text("let version = 2\n")
            return "publish v1.2.3"

        with self.assertRaisesRegex(release.ReleaseError, "工作区"):
            self.upload(paths, confirm)
        self.assert_no_release_mutation()

    def test_confirmed_upload_tags_exact_commit_without_pushing_branch_or_stray_assets(self):
        self.git("commit", "--quiet", "--allow-empty", "-m", "Local release commit")
        self.git("config", "push.followTags", "true")
        self.git("tag", "-a", "v1.0.0", self.initial_commit, "-m", "Earlier local version")
        paths = self.assets()
        self.assets(("x86_64",))
        (self.root / "dist/Clipato-old-arm64.dmg").write_bytes(b"old package")
        commit = self.upload(paths, lambda _: "publish v1.2.3")
        self.assertEqual(self.git("cat-file", "-t", "refs/tags/v1.2.3"), "tag")
        self.assertEqual(self.remote_git("rev-parse", "refs/tags/v1.2.3^{commit}"), commit)
        self.assertIn(release.LOCAL_BUILD_MARKER + commit, self.remote_git("cat-file", "-p", "refs/tags/v1.2.3"))
        self.assertEqual(self.remote_git("rev-parse", "refs/heads/main"), self.initial_commit)
        self.assertEqual(self.remote_git("tag", "--list"), "v1.2.3")
        records = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(records), 1)
        arguments = records[0]["arguments"]
        self.assertEqual(arguments[:3], ["release", "create", "v1.2.3"])
        self.assertEqual(arguments[3:arguments.index("--repo")], [str(path) for path in paths])
        self.assertEqual(arguments[arguments.index("--repo") + 1], "github.com/example/clipato")
        self.assertIn("--verify-tag", arguments)
        self.assertNotIn("--draft", arguments)
        self.assertNotIn("--prerelease", arguments)
        self.assertEqual(arguments[arguments.index("--title") + 1], "Clipato 1.2.3 (build 4) · Stable")
        self.assertEqual(records[0]["notes"], "Release notes\n")
        self.assertTrue(all(path.exists() for path in paths))
        self.assertFalse(Path(arguments[arguments.index("--notes-file") + 1]).exists())

    def test_release_tags_and_titles_distinguish_stable_and_nightly(self):
        self.assertEqual(release.release_tag("1.2.3", "4", "stable"), "v1.2.3")
        self.assertEqual(release.release_tag("1.2.3", "4", "nightly"), "v1.2.3-nightly.4")
        self.assertEqual(release.release_title("1.2.3", "4"), "Clipato 1.2.3 (build 4) · Stable")
        self.assertEqual(release.release_title("1.2.3", "4", "nightly"), "Clipato 1.2.3 (build 4) · Nightly")

    def test_notes_describe_release_channel_independently_of_signing(self):
        for channel, title in (("stable", "Stable"), ("nightly", "Nightly")):
            with self.subTest(channel=channel):
                notes = release.release_notes("1.2.3", "4", self.initial_commit, ["arm64"], channel)
                self.assertIn(title, notes.splitlines()[0])
                self.assertNotIn("测试", notes)
                self.assertIn("未经过 Developer ID", notes)
                self.assertIn("Apple 公证", notes)
                self.assertIn("arm64.dmg", notes)
                self.assertIn(self.initial_commit, notes)

    def test_nightly_confirmation_requires_its_exact_tag_before_any_mutation(self):
        paths = self.assets()
        before = {path: path.read_bytes() for path in paths}
        self.upload(paths, lambda _: "publish v1.2.3", channel="nightly")
        self.assert_no_release_mutation()
        self.assertEqual({path: path.read_bytes() for path in paths}, before)

    def test_nightly_upload_keeps_stable_tag_available_and_pushes_only_exact_source(self):
        self.git("commit", "--quiet", "--allow-empty", "-m", "Nightly source")
        self.git("config", "push.followTags", "true")
        self.git("tag", "-a", "v1.0.0", self.initial_commit, "-m", "Unrelated local tag")
        paths = self.assets(("arm64", "x86_64"))
        commit = self.upload(paths, lambda _: "publish v1.2.3-nightly.4", channel="nightly")
        tag = "v1.2.3-nightly.4"
        self.assertEqual(self.git("cat-file", "-t", f"refs/tags/{tag}"), "tag")
        self.assertEqual(self.remote_git("rev-parse", f"refs/tags/{tag}^{{commit}}"), commit)
        annotation = self.remote_git("cat-file", "-p", f"refs/tags/{tag}")
        self.assertIn(release.LOCAL_BUILD_MARKER + commit, annotation.splitlines())
        self.assertIn("Nightly", annotation)
        self.assertEqual(self.remote_git("tag", "--list"), tag)
        self.assertEqual(self.remote_git("rev-parse", "refs/heads/main"), self.initial_commit)
        release.check_new_tag("v1.2.3", str(self.origin))
        records = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(records), 1)
        arguments = records[0]["arguments"]
        self.assertEqual(arguments[:3], ["release", "create", tag])
        self.assertEqual(arguments[3:arguments.index("--repo")], [str(path) for path in paths])
        for flag in ("--verify-tag", "--prerelease"):
            self.assertIn(flag, arguments)
        self.assertNotIn("--draft", arguments)
        self.assertEqual(arguments[arguments.index("--title") + 1], "Clipato 1.2.3 (build 4) · Nightly")
        self.assertEqual(arguments[arguments.index("--repo") + 1], "github.com/example/clipato")
        self.assertEqual(records[0]["notes"], "Release notes\n")

    def test_nightly_can_build_after_stable_tag_already_exists(self):
        self.git("tag", "-a", "v1.2.3", self.initial_commit, "-m", "Stable version")
        self.git("push", "--quiet", "origin", "refs/tags/v1.2.3")
        paths = self.assets()
        self.upload(paths, lambda _: "publish v1.2.3-nightly.4", channel="nightly")
        self.assertEqual(self.remote_git("tag", "--list"), "v1.2.3\nv1.2.3-nightly.4")
        self.assertEqual(self.remote_git("rev-parse", "refs/tags/v1.2.3^{commit}"), self.initial_commit)

    def test_gh_failure_keeps_pushed_tag_assets_and_notes_with_partial_state_error(self):
        paths = self.assets()
        self.failure.touch()
        with self.assertRaisesRegex(release.ReleaseError, "已推送.*Release 失败"):
            self.upload(paths, lambda _: "publish v1.2.3")
        self.assertEqual(self.remote_git("rev-parse", "refs/tags/v1.2.3^{commit}"), self.initial_commit)
        self.assertTrue(all(path.exists() for path in paths))
        arguments = json.loads(self.calls.read_text())["arguments"]
        notes = Path(arguments[arguments.index("--notes-file") + 1])
        self.assertEqual(notes.read_text(), "Release notes\n")

    def test_asset_change_during_confirmation_stops_before_creating_tag(self):
        paths = self.assets()
        hashes = release.verify_assets(paths)

        def confirm(_):
            paths[0].write_bytes(b"replaced during confirmation")
            self.write_checksum(*paths)
            return "publish v1.2.3"

        with self.assertRaisesRegex(release.ReleaseError, "确认期间.*变化"):
            self.upload(paths, confirm, hashes)
        self.assert_no_release_mutation()

    def test_changing_origin_pushurl_during_confirmation_cannot_redirect_upload(self):
        paths = self.assets()
        unexpected = self.directory / "unexpected.git"
        self.run_git("init", "--quiet", "--bare", str(unexpected), cwd=self.directory)

        def confirm(_):
            self.git("remote", "set-url", "--push", "origin", str(unexpected))
            return "publish v1.2.3"

        self.upload(paths, confirm)
        self.assertEqual(self.remote_git("tag", "--list"), "v1.2.3")
        self.assertEqual(self.run_git("tag", "--list", cwd=unexpected), "")


class VersionEditingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clipato-version-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.version_file = self.root / "Sources/Clipato/Resources/Version.plist"
        self.version_file.parent.mkdir(parents=True)
        self.original = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n<dict>\n'
            '\t<!-- Keep the original 1.2.3 / 4 release notes. -->\n'
            '\t<key>UnrelatedVersion</key><string>1.2.3</string>\n'
            '\t<key>CFBundleVersion</key>\n\t<string>4</string>\n'
            '\t<key>CFBundleShortVersionString</key>\n\t<string>1.2.3</string>\n'
            '\t<key>UnrelatedBuild</key><string>4</string>\n'
            '</dict>\n</plist>\n'
        ).encode()
        self.version_file.write_bytes(self.original)
        self.version_file.chmod(0o640)
        for change in (
            patch.object(release, "ROOT", self.root),
            patch.object(release, "VERSION_FILE", self.version_file),
        ):
            change.start()
            self.addCleanup(change.stop)

    def metadata(self):
        return plistlib.loads(self.version_file.read_bytes())

    def identity(self):
        info = self.version_file.stat()
        return info.st_ino, info.st_mtime_ns, info.st_mode

    def expected_xml(self, version="1.2.3", build="4"):
        return self.original.replace(
            b'<key>CFBundleVersion</key>\n\t<string>4</string>',
            f'<key>CFBundleVersion</key>\n\t<string>{build}</string>'.encode(),
        ).replace(
            b'<key>CFBundleShortVersionString</key>\n\t<string>1.2.3</string>',
            f'<key>CFBundleShortVersionString</key>\n\t<string>{version}</string>'.encode(),
        )

    def run_cli(self, *arguments):
        script = self.root / "scripts/release-local.py"
        script.parent.mkdir(exist_ok=True)
        script.write_bytes(SCRIPT.read_bytes())
        self.bin = self.root / "bin"
        self.bin.mkdir(exist_ok=True)
        self.external_calls = self.root / "external-calls"
        for name in ("git", "gh", "swift"):
            executable = self.bin / name
            executable.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$0" >> "$CLIPATO_TEST_CALLS"\nexit 97\n',
                encoding="utf-8",
            )
            executable.chmod(0o755)
        environment = dict(os.environ)
        environment["PATH"] = str(self.bin) + os.pathsep + environment["PATH"]
        environment["CLIPATO_TEST_CALLS"] = str(self.external_calls)
        return subprocess.run(
            [sys.executable, str(script), *arguments], cwd=self.root, env=environment,
            input="", text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def test_save_updates_only_target_xml_values_and_preserves_mode(self):
        with contextlib.redirect_stdout(io.StringIO()):
            release.save_version("2.3.4", "12")
        self.assertEqual(self.version_file.read_bytes(), self.expected_xml("2.3.4", "12"))
        self.assertEqual(self.version_file.stat().st_mode & 0o777, 0o640)

    def test_binary_plist_stays_binary_and_preserves_unrelated_fields(self):
        original = {
            "CFBundleVersion": "4", "Other": {"Data": b"\x00\xff", "Enabled": True},
            "CFBundleShortVersionString": "1.2.3", "Order": [3, 1, 2],
        }
        self.version_file.write_bytes(plistlib.dumps(original, fmt=plistlib.FMT_BINARY, sort_keys=False))
        with contextlib.redirect_stdout(io.StringIO()):
            release.save_version("2.0.1", "8")
        self.assertTrue(self.version_file.read_bytes().startswith(b"bplist00"))
        expected = dict(original, CFBundleVersion="8", CFBundleShortVersionString="2.0.1")
        self.assertEqual(self.metadata(), expected)

    def test_invalid_version_or_build_does_not_partially_write(self):
        original_identity = self.identity()
        for version, build in (("1.2", "5"), ("02.0.0", "5"), ("2.0.0", "0"), ("2.0.0", "5.0")):
            with self.subTest(version=version, build=build):
                with self.assertRaises(release.ReleaseError):
                    release.save_version(version, build)
                self.assertEqual(self.version_file.read_bytes(), self.original)
                self.assertEqual(self.identity(), original_identity)

    def test_unchanged_metadata_does_not_rewrite_file(self):
        original_identity = self.identity()
        with contextlib.redirect_stdout(io.StringIO()):
            release.save_version("1.2.3", "4")
        self.assertEqual(self.version_file.read_bytes(), self.original)
        self.assertEqual(self.identity(), original_identity)

    def test_save_dry_run_previews_without_writing(self):
        original_identity = self.identity()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            release.save_version("2.3.4", "12", dry_run=True)
        self.assertIn("2.3.4", output.getvalue())
        self.assertIn("12", output.getvalue())
        self.assertEqual(self.version_file.read_bytes(), self.original)
        self.assertEqual(self.identity(), original_identity)

    def test_interactive_cancellation_keeps_original_values(self):
        with patch("builtins.input", side_effect=["2.0.1", "8", "n"]), contextlib.redirect_stdout(io.StringIO()):
            result = release.edit_version("1.2.3", "4")
        self.assertEqual(result, ("1.2.3", "4"))
        self.assertEqual(self.version_file.read_bytes(), self.original)

    def test_interactive_confirmation_saves_both_values(self):
        with patch("builtins.input", side_effect=["2.0.1", "8", "y"]), contextlib.redirect_stdout(io.StringIO()):
            result = release.edit_version("1.2.3", "4")
        self.assertEqual(result, ("2.0.1", "8"))
        self.assertEqual(self.version_file.read_bytes(), self.expected_xml("2.0.1", "8"))

    def test_interactive_empty_input_keeps_defaults_without_rewriting(self):
        original_identity = self.identity()
        with patch("builtins.input", side_effect=["", "", "y"]), contextlib.redirect_stdout(io.StringIO()):
            result = release.edit_version("1.2.3", "4")
        self.assertEqual(result, ("1.2.3", "4"))
        self.assertEqual(self.version_file.read_bytes(), self.original)
        self.assertEqual(self.identity(), original_identity)

    def test_interactive_dry_run_returns_candidate_without_writing(self):
        with patch("builtins.input", side_effect=["2.0.1", "8", "y"]), contextlib.redirect_stdout(io.StringIO()):
            result = release.edit_version("1.2.3", "4", dry_run=True)
        self.assertEqual(result, ("2.0.1", "8"))
        self.assertEqual(self.version_file.read_bytes(), self.original)

    def test_partial_cli_edits_work_without_tty_git_or_build(self):
        for arguments, version, build in (
            (("--set-version", "2.3.4"), "2.3.4", "4"),
            (("--set-build", "12"), "1.2.3", "12"),
        ):
            with self.subTest(arguments=arguments):
                self.version_file.write_bytes(self.original)
                result = self.run_cli(*arguments)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.version_file.read_bytes(), self.expected_xml(version, build))
                self.assertFalse(self.external_calls.exists())

    def test_cli_dry_run_previews_both_values_without_writing(self):
        result = self.run_cli("--set-version", "2.3.4", "--set-build", "12", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2.3.4", result.stdout)
        self.assertIn("12", result.stdout)
        self.assertEqual(self.version_file.read_bytes(), self.original)
        self.assertFalse(self.external_calls.exists())

    def test_atomic_replace_failure_keeps_original_and_removes_temporary_file(self):
        original_identity = self.identity()
        with patch.object(release.os, "replace", side_effect=OSError("Test disk failure")):
            with self.assertRaises((OSError, release.ReleaseError)):
                release.save_version("2.3.4", "12")
        self.assertEqual(self.version_file.read_bytes(), self.original)
        self.assertEqual(self.identity(), original_identity)
        self.assertEqual(list(self.version_file.parent.iterdir()), [self.version_file])

    def test_concurrent_metadata_edit_is_not_overwritten_and_temporary_file_is_removed(self):
        create_temporary = release.tempfile.mkstemp
        concurrent = self.expected_xml("1.3.0", "5")

        def create_and_edit(*arguments, **keywords):
            result = create_temporary(*arguments, **keywords)
            self.version_file.write_bytes(concurrent)
            return result

        with patch.object(release.tempfile, "mkstemp", side_effect=create_and_edit):
            with self.assertRaises(release.ReleaseError):
                release.save_version("2.3.4", "12")
        self.assertEqual(self.version_file.read_bytes(), concurrent)
        self.assertEqual(list(self.version_file.parent.iterdir()), [self.version_file])


if __name__ == "__main__":
    unittest.main()
