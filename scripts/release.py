#!/usr/bin/env python3
"""Small release invariants around python-semantic-release; no network or git writes."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess


VERSION_PATTERN = r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"


def parse_version(value: str) -> tuple[int, int, int]:
    match = re.fullmatch(VERSION_PATTERN, value)
    if not match:
        raise ValueError(f"Expected stable SemVer, got {value!r}")
    return tuple(map(int, match.groups()))


def tag_version(tag: str) -> str:
    if not tag.startswith("v"):
        raise ValueError("Release tag must start with v")
    version = tag[1:]
    parse_version(version)
    return version


def read_version(root: Path) -> str:
    version = (root / "VERSION").read_text().strip()
    parse_version(version)
    return version


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def inspect(root: Path) -> dict[str, str]:
    version = read_version(root)
    tags = [tag for tag in git(root, "tag", "--merged", "HEAD").splitlines()
            if re.fullmatch("v" + VERSION_PATTERN, tag)]
    if tags:
        latest = max(tags, key=lambda tag: parse_version(tag[1:]))
        if latest != f"v{version}":
            raise ValueError(f"VERSION={version} must match latest reachable release {latest}; let semantic-release bump it")
    return {"initial": str(not tags).lower(), "version": version, "tag": f"v{version}"}


def verify(root: Path, tag: str, commit: str | None = None, require_main: bool = False) -> dict[str, str]:
    version = tag_version(tag)
    if read_version(root) != version:
        raise ValueError(f"{tag} does not match VERSION")
    head = git(root, "rev-parse", "HEAD")
    tagged = git(root, "rev-parse", f"refs/tags/{tag}^{{commit}}")
    if tagged != head or (commit is not None and commit != head):
        raise ValueError(f"{tag}, expected commit and checked-out HEAD must identify the same commit")
    if require_main:
        subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", head, "origin/main"], check=True)
    return {"tag": tag, "version": version, "commit_sha": head}


def release_notes(root: Path, tag: str) -> str:
    version = tag_version(tag)
    lines = (root / "CHANGELOG.md").read_text().splitlines()
    header = re.compile(rf"^##\s+\[?v?{re.escape(version)}\]?(?:\s|\(|$)")
    start = next((i for i, line in enumerate(lines) if header.match(line)), None)
    changes = []
    if start is not None:
        for line in lines[start + 1:]:
            if line.startswith("## "):
                break
            changes.append(line)
    return (
        f"# Scrcpy Viewer {tag}\n\n"
        "For **Apple Silicon (arm64), macOS 14 or later**. Intel Macs are not included in this release.\n\n"
        "Download the ZIP and verify it against `SHA256SUMS`. The archive includes the app, installation instructions, "
        "dependency setup script and licenses. Follow the included instructions to install the compatible adb/scrcpy dependencies.\n\n"
        "This build is **ad-hoc signed and not notarized by Apple**. See the installation instructions before first launch.\n\n"
        + ("\n".join(changes).strip() or "See CHANGELOG.md for this version.") + "\n"
    )


def emit(values: dict[str, str], output: str | None) -> None:
    text = "".join(f"{key}={value}\n" for key, value in values.items())
    print(text, end="")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(text)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    commands = parser.add_subparsers(dest="command", required=True)
    inspect_parser = commands.add_parser("inspect")
    inspect_parser.add_argument("--github-output")
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--tag", required=True)
    verify_parser.add_argument("--commit")
    verify_parser.add_argument("--require-main", action="store_true")
    verify_parser.add_argument("--github-output")
    notes_parser = commands.add_parser("notes")
    notes_parser.add_argument("--tag", required=True)
    notes_parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "inspect":
        emit(inspect(args.root), args.github_output)
    elif args.command == "verify":
        emit(verify(args.root, args.tag, args.commit, args.require_main), args.github_output)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(release_notes(args.root, args.tag))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
