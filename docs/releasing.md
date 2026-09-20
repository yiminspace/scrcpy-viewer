# Releases

The current download targets **Apple Silicon (arm64), macOS 14 or later**. It is ad-hoc signed, without Developer ID signing or Apple notarization. Intel packages are not built. These workflows work while the repository is private; they do not change its visibility.

## Normal changes

Open a PR and use a Conventional Commit title, then **squash merge** so that title becomes the commit on `main`:

- `fix: prevent a stale frame` or `perf: reduce decoding overhead` releases a patch.
- `feat: add a display option` releases a minor version.
- `feat!: change the connection interface` marks a breaking change. While versions are `0.x`, breaking changes also bump the minor version; from `1.0.0` they bump the major version.
- `docs:`, `test:`, `ci:`, `chore:` and other non-release changes alone do not publish a new version.

PR checks validate the title, release tooling, Swift tests and the app build. The `Version and release` workflow runs those checks again on `main`. After success, pinned python-semantic-release updates the single-line `VERSION`, adds release notes to `CHANGELOG.md`, commits them and creates the `vX.Y.Z` tag. Do not manually bump `VERSION` for ordinary changes.

The first release is special: if no stable release tag is reachable, the workflow uses the committed `VERSION` (initially `0.4.1`) and existing changelog to create its first tag after checks pass. No artificial old tag is needed.

The version workflow calls `Package release` directly. A tag pushed by `GITHUB_TOKEN` does not start another push workflow, so publication does not rely on tag events or a personal access token.

## What gets published

Publication verifies that the exact stable tag matches `VERSION`, resolves to the checked-out commit and belongs to `main` history. It pins that commit for tests and packaging. The arm64 runner is checked with `uname -m` before building.

The package job builds and checks the ZIP, installs the checksum-pinned official scrcpy server into a temporary directory, and launches the extracted app with a fake empty adb. This smoke check exercises dependency resolution and clean shutdown without a desktop scrcpy client or a real phone.

The workflow retains a downloadable artifact for 14 days, including:

- `Scrcpy-Viewer-X.Y.Z-macOS-arm64.zip`
- `SHA256SUMS`
- `RELEASE_NOTES.md`

A real publication creates or resumes a **draft** GitHub Release, uploads the ZIP and checksum, then publishes the draft only after all uploads succeed. No private credentials or downloaded runtime dependencies are committed to the repository.

## Preview or publish manually

Run these from a clone authenticated with GitHub CLI, or use the corresponding Actions “Run workflow” form. A preview validates and builds but does not create a version commit, tag or published release.

```bash
# Preview the next Conventional Commit version; no repository writes.
gh workflow run semantic-release.yml --ref main -f dry_run=true

# Force a patch after successful checks, even when commits would not trigger one.
gh workflow run semantic-release.yml --ref main -f force=patch -f dry_run=false

# Validate/package an existing exact tag, retaining workflow artifacts only.
gh workflow run release.yml --ref main -f tag=v0.4.1 -f dry_run=true

# Publish or recover an existing exact tag after validation.
gh workflow run release.yml --ref main -f tag=v0.4.1 -f dry_run=false
```

For the first version, `force` does not override the committed `VERSION`. `dry_run` defaults to true in both manual forms. Manual packaging requires an existing tag; it never invents or moves one.

## Failed or repeated runs

If checks fail, fix the cause before publishing. If the version/tag was pushed but packaging or publication failed, choose **Re-run failed jobs**, or run **Package release** (`release.yml`) manually with that exact existing tag. **Re-run all jobs** may skip publication: the main-commit guard can reject the old run after the version commit, or semantic-release can find no new version to create. It is not the recovery path for an already-created tag.

An unfinished draft can be repaired by rerunning; its assets may be replaced. A **published release is immutable**: a retry only succeeds without changes when the existing ZIP and its checksum match the new local ZIP byte for byte. ZIP member times are normalized to the source commit, but compiler or build-environment changes can still produce different bytes. Different bytes require a new version, even if they came from rebuilding the same source. A GitHub artifact remains available for inspecting a rejected rebuilt package. Never move a released tag or delete a published asset to bypass this check.

If a newer commit reaches `main` during validation, an older run skips versioning; the newer run handles it. Version and publication jobs are serialized to prevent duplicate releases.

## Maintainer setup and local verification

Only the built-in `GITHUB_TOKEN` is required. Workflows request `contents: write` for versioning and publication, while PR jobs have read-only permissions and use `pull_request`, never `pull_request_target`. If branch protection blocks the release bot's version commit, configure an explicit policy for that bot before enabling automatic releases; a failed push must not be bypassed with force pushes.

Use squash merges with the PR title as the commit message. Recommended required PR checks are `pr-title`, `release-tooling` and `macos`. Keep full Git history for releases; build numbers derive from the commit count.

```bash
# Dependencies can instead be installed in a disposable virtual environment.
uv run --with python-semantic-release==10.6.2 python scripts/test_release.py
swift test
./scripts/package-release.sh

# Optional no-device smoke test on a Mac with a GUI session.
./scripts/setup-dependencies.sh --directory /tmp/scrcpy-viewer-release-deps
python3 scripts/smoke-release.py \
  --archive "dist/Scrcpy-Viewer-$(cat VERSION)-macOS-arm64.zip" \
  --server /tmp/scrcpy-viewer-release-deps/scrcpy/3.3.3/scrcpy-server
```

Release tests create temporary Git repositories, run the pinned version tool without pushing, and mock GitHub publication. They do not publish or contact a phone.
