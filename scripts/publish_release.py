#!/usr/bin/env python3
"""Publish a complete draft; an already published release is immutable."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

from release import tag_version


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_files(dist: Path, tag: str) -> tuple[Path, Path]:
    version = tag_version(tag)
    archive = dist / f"Scrcpy-Viewer-{version}-macOS-arm64.zip"
    checksum = dist / "SHA256SUMS"
    expected = digest(archive)
    match = re.fullmatch(r"([a-f0-9]{64}) [ *]([^\r\n]+)\s*", checksum.read_text())
    if not match or match.group(1) != expected or match.group(2) != archive.name:
        raise ValueError("SHA256SUMS must contain exactly the matching versioned arm64 ZIP")
    return archive, checksum


def gh(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["gh", *args], text=True, capture_output=True)


def checked_gh(*args: str) -> str:
    result = gh(*args)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "GitHub release command failed")
    return result.stdout


def verify_remote_tag(tag: str, commit: str) -> None:
    tag_version(tag)
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("Expected the exact 40-character validated commit SHA")
    # Use GH_TOKEN through gh, including private repositories whose checkout
    # intentionally did not retain Git credentials.
    reference = json.loads(checked_gh("api", f"repos/{{owner}}/{{repo}}/git/ref/tags/{tag}"))
    obj = reference["object"]
    for _ in range(5):
        if obj["type"] != "tag":
            break
        obj = json.loads(checked_gh("api", f"repos/{{owner}}/{{repo}}/git/tags/{obj['sha']}"))["object"]
    if obj["type"] != "commit" or obj["sha"] != commit:
        raise ValueError("Remote release tag moved or disappeared after validation; refusing publication")


def publish(tag: str, commit: str, dist: Path) -> str:
    archive, checksum = verify_files(dist, tag)
    notes = dist / "RELEASE_NOTES.md"
    if not notes.is_file():
        raise ValueError("Missing RELEASE_NOTES.md")
    verify_remote_tag(tag, commit)
    result = gh("release", "view", tag, "--json", "isDraft,tagName")
    if result.returncode:
        message = result.stderr.lower()
        if "release not found" not in message and "404" not in message:
            raise RuntimeError(result.stderr.strip() or "Could not inspect existing release")
        checked_gh("release", "create", tag, "--draft", "--verify-tag", "--target", commit,
                   "--title", f"Scrcpy Viewer {tag}", "--notes-file", str(notes))
        is_draft = True
    else:
        existing = json.loads(result.stdout)
        if existing.get("tagName") != tag:
            raise ValueError("GitHub returned an unexpected release tag")
        is_draft = existing["isDraft"]

    if not is_draft:
        # Never silently replace a user's already downloaded version. Exact bytes
        # are an idempotent success; any change requires a new version/tag.
        with tempfile.TemporaryDirectory(prefix="scrcpy-release-verify-") as temp:
            checked_gh("release", "download", tag, "--pattern", archive.name,
                       "--pattern", checksum.name, "--dir", temp)
            previous_archive, _ = verify_files(Path(temp), tag)
            if digest(previous_archive) != digest(archive):
                raise ValueError("Published release bytes differ. Keep that release immutable and publish a new version.")
        return "Existing published release is byte-identical; no changes made."

    # A failed upload leaves a draft that can be safely repaired by rerunning.
    checked_gh("release", "upload", tag, str(archive), str(checksum), "--clobber")
    verify_remote_tag(tag, commit)
    checked_gh("release", "edit", tag, "--notes-file", str(notes), "--draft=false")
    return f"Published complete release {tag}."


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--dist", type=Path, default=Path("dist"))
    args = parser.parse_args()
    print(publish(args.tag, args.commit, args.dist))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
