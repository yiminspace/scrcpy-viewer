#!/usr/bin/env python3
"""Release tests use disposable Git repositories and mocked GitHub calls only."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import publish_release as publisher
import release

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release@example.invalid")
        self.git("remote", "add", "origin", "https://github.com/example/scrcpy-viewer.git")
        (self.root / "VERSION").write_text("0.4.0\n")
        shutil.copy(ROOT / "release.toml", self.root)
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n<!-- version list -->\n\n## v0.4.0\n\n- Initial package.\n")
        self.commit("chore: initial package")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True, stderr=subprocess.STDOUT).strip()

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "--allow-empty", "-m", message)

    def baseline(self):
        self.git("tag", "-a", "v0.4.0", "-m", "Initial release")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def semantic(self, *, noop=False):
        command = ["semantic-release", "-c", "release.toml"]
        if noop:
            command.append("--noop")
        command += ["version", "--no-push", "--no-vcs-release", "--skip-build"]
        # Do not inherit a developer or CI token. No network/push is needed.
        environment = {key: value for key, value in os.environ.items()
                       if key not in {"GH_TOKEN", "GITHUB_TOKEN", "GITHUB_ACTIONS", "GITHUB_OUTPUT"}}
        result = subprocess.run(command, cwd=self.root, env=environment, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_first_release_uses_version_file(self):
        self.assertEqual(release.inspect(self.root), {"initial": "true", "version": "0.4.0", "tag": "v0.4.0"})

    def test_existing_baseline_requires_matching_version(self):
        self.baseline()
        self.assertEqual(release.inspect(self.root)["initial"], "false")
        (self.root / "VERSION").write_text("0.5.0\n")
        with self.assertRaises(ValueError):
            release.inspect(self.root)

    def test_exact_annotated_tag_and_main_ancestry(self):
        self.baseline()
        head = self.git("rev-parse", "HEAD")
        self.assertEqual(release.verify(self.root, "v0.4.0", head, True)["commit_sha"], head)

    def test_version_tag_sha_and_checkout_mismatches_fail(self):
        self.baseline()
        with self.assertRaises(ValueError):
            release.verify(self.root, "v0.4.0", SHA)
        with self.assertRaises(ValueError):
            release.verify(self.root, "v0.5.0")
        self.commit("docs: next work")
        with self.assertRaises(ValueError):
            release.verify(self.root, "v0.4.0")

    def test_tag_outside_main_is_rejected(self):
        self.baseline()
        self.commit("fix: side branch")
        self.git("tag", "-f", "v0.4.0")
        with self.assertRaises(subprocess.CalledProcessError):
            release.verify(self.root, "v0.4.0", require_main=True)

    def test_semantic_feature_updates_version_changelog_and_tag(self):
        self.baseline()
        self.commit("feat: add display option")
        self.semantic()
        self.assertEqual(release.read_version(self.root), "0.5.0")
        self.assertEqual(self.git("describe", "--tags", "--exact-match"), "v0.5.0")
        self.assertIn("Add display option", (self.root / "CHANGELOG.md").read_text())
        self.assertIn("add display option", release.release_notes(self.root, "v0.5.0").lower())

    def test_semantic_fix_is_patch(self):
        self.baseline()
        self.commit("fix: prevent stale frame")
        self.semantic()
        self.assertEqual(release.read_version(self.root), "0.4.1")

    def test_semantic_breaking_change_bumps_minor_before_one(self):
        self.baseline()
        self.commit("feat!: replace stream interface")
        self.semantic()
        self.assertEqual(release.read_version(self.root), "0.5.0")

    def test_semantic_docs_only_does_not_release(self):
        self.baseline()
        self.commit("docs: explain installation")
        head = self.git("rev-parse", "HEAD")
        self.semantic()
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.git("tag"), "v0.4.0")

    def test_semantic_preview_does_not_write(self):
        self.baseline()
        self.commit("feat: add display option")
        head = self.git("rev-parse", "HEAD")
        self.semantic(noop=True)
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.git("tag"), "v0.4.0")

    def test_notes_contain_only_requested_version(self):
        with (self.root / "CHANGELOG.md").open("a") as file:
            file.write("\n## v0.3.1\n\n- Old feature.\n")
        notes = release.release_notes(self.root, "v0.4.0")
        self.assertIn("Initial package.", notes)
        self.assertNotIn("Old feature.", notes)
        self.assertIn("not notarized", notes)


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dist = Path(self.temp.name)
        self.archive = self.dist / "Scrcpy-Viewer-0.4.0-macOS-arm64.zip"
        self.write_package(self.dist, b"test archive")
        (self.dist / "RELEASE_NOTES.md").write_text("Release notes")

    def write_package(self, directory, content):
        archive = directory / "Scrcpy-Viewer-0.4.0-macOS-arm64.zip"
        archive.write_bytes(content)
        (directory / "SHA256SUMS").write_text(f"{hashlib.sha256(content).hexdigest()}  {archive.name}\n")

    def result(self, data=None, error=""):
        return subprocess.CompletedProcess([], int(bool(error)), json.dumps(data) if data else "", error)

    def test_manifest_must_match_exact_version_and_bytes(self):
        publisher.verify_files(self.dist, "v0.4.0")
        self.archive.write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            publisher.verify_files(self.dist, "v0.4.0")

    def test_manifest_cannot_include_other_assets(self):
        with (self.dist / "SHA256SUMS").open("a") as file:
            file.write("0" * 64 + "  other.zip\n")
        with self.assertRaises(ValueError):
            publisher.verify_files(self.dist, "v0.4.0")

    def test_remote_lightweight_tag(self):
        with patch.object(publisher, "checked_gh", return_value=json.dumps({"object": {"type": "commit", "sha": SHA}})):
            publisher.verify_remote_tag("v0.4.0", SHA)

    def test_remote_annotated_tag(self):
        with patch.object(publisher, "checked_gh", side_effect=[
            json.dumps({"object": {"type": "tag", "sha": "b" * 40}}),
            json.dumps({"object": {"type": "commit", "sha": SHA}}),
        ]) as api:
            publisher.verify_remote_tag("v0.4.0", SHA)
            self.assertEqual(api.call_count, 2)

    def test_moved_remote_tag_is_rejected(self):
        with patch.object(publisher, "checked_gh", return_value=json.dumps({"object": {"type": "commit", "sha": "b" * 40}})):
            with self.assertRaises(ValueError):
                publisher.verify_remote_tag("v0.4.0", SHA)

    def test_create_draft_upload_then_publish(self):
        with patch.object(publisher, "verify_remote_tag"), patch.object(publisher, "gh", return_value=self.result(error="release not found")), patch.object(publisher, "checked_gh") as calls:
            publisher.publish("v0.4.0", SHA, self.dist)
        self.assertEqual([call.args[1] for call in calls.call_args_list], ["create", "upload", "edit"])
        self.assertIn("--draft", calls.call_args_list[0].args)
        self.assertIn("--clobber", calls.call_args_list[1].args)
        self.assertIn("--draft=false", calls.call_args_list[2].args)

    def test_draft_upload_failure_does_not_publish(self):
        with patch.object(publisher, "verify_remote_tag"), patch.object(publisher, "gh", return_value=self.result({"isDraft": True, "tagName": "v0.4.0"})), patch.object(publisher, "checked_gh", side_effect=RuntimeError("upload failed")) as calls:
            with self.assertRaises(RuntimeError):
                publisher.publish("v0.4.0", SHA, self.dist)
        self.assertEqual([call.args[1] for call in calls.call_args_list], ["upload"])

    def test_inspection_errors_do_not_create_a_release(self):
        with patch.object(publisher, "verify_remote_tag"), patch.object(publisher, "gh", return_value=self.result(error="authentication failed")), patch.object(publisher, "checked_gh") as calls:
            with self.assertRaises(RuntimeError):
                publisher.publish("v0.4.0", SHA, self.dist)
        calls.assert_not_called()

    def check_published(self, content, matches):
        def download(*args):
            self.assertEqual(args[:2], ("release", "download"))
            self.write_package(Path(args[-1]), content)
            return ""
        with patch.object(publisher, "verify_remote_tag"), patch.object(publisher, "gh", return_value=self.result({"isDraft": False, "tagName": "v0.4.0"})), patch.object(publisher, "checked_gh", side_effect=download) as calls:
            if matches:
                self.assertIn("no changes", publisher.publish("v0.4.0", SHA, self.dist))
            else:
                with self.assertRaisesRegex(ValueError, "new version"):
                    publisher.publish("v0.4.0", SHA, self.dist)
        self.assertEqual(calls.call_count, 1)

    def test_identical_published_release_is_unchanged(self):
        self.check_published(b"test archive", True)

    def test_changed_published_release_requires_new_version(self):
        self.check_published(b"previous bytes", False)

    def test_invalid_tags_are_rejected(self):
        for tag in ["0.4.0", "v01.0.0", "v0.4.0;pwd", "v0.4.0-beta", "main"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.tag_version(tag)


if __name__ == "__main__":
    unittest.main(verbosity=2)
