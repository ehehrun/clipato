"""Run the workflow's source validation against real, isolated Git repositories."""

import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import textwrap
import unittest


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/swift.yml"


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clipato-workflow-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "--quiet", "-b", "main")
        self.git("config", "user.name", "Clipato Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        self.version_file = self.root / "Sources/Clipato/Resources/Version.plist"
        self.version_file.parent.mkdir(parents=True)
        self.write_version("1.2.3", "4")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Release source")
        self.commit = self.git("rev-parse", "HEAD")
        source = WORKFLOW.read_text(encoding="utf-8")
        self.prepare = textwrap.dedent(source.split("python3 - <<'PY'\n", 1)[1].split("\n          PY", 1)[0])

    def git(self, *arguments):
        return subprocess.check_output(
            ["git", *arguments], cwd=self.root, text=True, stderr=subprocess.PIPE,
        ).strip()

    def write_version(self, version, build):
        self.version_file.write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": version, "CFBundleVersion": build,
        }))

    def tag(self, name, annotation=None):
        if annotation is None:
            self.git("tag", name)
        else:
            self.git("tag", "-a", name, "-m", annotation)

    def run_prepare(self, *, tag="", event="push", channel="stable"):
        output = self.root / "outputs"
        output.unlink(missing_ok=True)
        environment = dict(os.environ)
        environment.update({
            "GITHUB_EVENT_NAME": event,
            "GITHUB_REF": f"refs/tags/{tag}" if tag else "refs/heads/main",
            "INPUT_TAG": tag if event == "workflow_dispatch" else "",
            "INPUT_CHANNEL": channel if event == "workflow_dispatch" else "",
            "GITHUB_OUTPUT": str(output),
        })
        result = subprocess.run(
            [sys.executable, "-c", self.prepare], cwd=self.root, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        values = dict(line.split("=", 1) for line in output.read_text().splitlines()) if output.exists() else {}
        return result, values

    def assert_valid(self, expected_channel, **arguments):
        result, values = self.run_prepare(**arguments)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(values["sha"], self.commit)
        self.assertEqual(values["version"], "1.2.3")
        self.assertEqual(values["build"], "4")
        self.assertEqual(values["channel"], expected_channel)
        return values

    def test_stable_tag_uses_stable_channel(self):
        self.tag("v1.2.3")
        values = self.assert_valid("stable", tag="v1.2.3")
        self.assertEqual(values["tag"], "v1.2.3")
        self.assertEqual(values["local_release"], "false")

    def test_nightly_tag_uses_nightly_channel_and_build(self):
        self.tag("v1.2.3-nightly.4")
        values = self.assert_valid("nightly", tag="v1.2.3-nightly.4")
        self.assertEqual(values["tag"], "v1.2.3-nightly.4")
        self.assertEqual(values["local_release"], "false")

    def test_tag_version_and_nightly_build_must_match_source(self):
        for tag in ("v1.2.4", "v1.2.4-nightly.4", "v1.2.3-nightly.5"):
            with self.subTest(tag=tag):
                self.tag(tag)
                result, values = self.run_prepare(tag=tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("does not match", result.stderr)
                self.assertEqual(values, {})

    def test_other_channels_and_invalid_tag_spellings_are_rejected(self):
        for tag in ("v1.2.3-beta.4", "v1.2.3-test", "v01.2.3", "v1.2.3-nightly.0", "v1.2.3-nightly.04"):
            with self.subTest(tag=tag):
                self.tag(tag)
                result, values = self.run_prepare(tag=tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(values, {})

    def test_manual_channel_must_match_tag(self):
        for tag, actual, wrong in (("v1.2.3", "stable", "nightly"), ("v1.2.3-nightly.4", "nightly", "stable")):
            with self.subTest(tag=tag):
                self.tag(tag)
                self.assert_valid(actual, tag=tag, event="workflow_dispatch", channel=actual)
                result, values = self.run_prepare(tag=tag, event="workflow_dispatch", channel=wrong)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(values, {})

    def test_manual_empty_tag_preserves_selected_channel_and_artifact_only_mode(self):
        for channel in ("stable", "nightly"):
            with self.subTest(channel=channel):
                values = self.assert_valid(channel, event="workflow_dispatch", channel=channel)
                self.assertEqual(values["tag"], "")
                self.assertEqual(values["local_release"], "false")

    def test_exact_local_build_marker_skips_push_builds_for_both_channels(self):
        for tag, channel in (("v1.2.3", "stable"), ("v1.2.3-nightly.4", "nightly")):
            with self.subTest(tag=tag):
                self.tag(tag, f"Clipato local release\n\nClipato-Local-Build: {self.commit}")
                values = self.assert_valid(channel, tag=tag)
                self.assertEqual(values["local_release"], "true")
                manual = self.assert_valid(channel, tag=tag, event="workflow_dispatch", channel=channel)
                self.assertEqual(manual["local_release"], "false")

    def test_local_marker_requires_exact_sha_and_complete_annotation_line(self):
        annotations = (
            f"Clipato-Local-Build: {'0' * 40}",
            f"Prefix Clipato-Local-Build: {self.commit}",
            f"Clipato-Local-Build: {self.commit} suffix",
        )
        for annotation in annotations:
            with self.subTest(annotation=annotation):
                self.tag("v1.2.3-nightly.4", f"Clipato\n\n{annotation}")
                values = self.assert_valid("nightly", tag="v1.2.3-nightly.4")
                self.assertEqual(values["local_release"], "false")
                self.git("tag", "--delete", "v1.2.3-nightly.4")

    def test_tag_metadata_is_read_from_tagged_commit_instead_of_current_head(self):
        self.tag("v1.2.3-nightly.4")
        self.write_version("2.0.0", "5")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Later version")
        values = self.assert_valid("nightly", tag="v1.2.3-nightly.4")
        self.assertEqual(values["sha"], self.commit)


if __name__ == "__main__":
    unittest.main()
