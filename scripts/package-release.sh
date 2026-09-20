#!/bin/bash
# Produce an Apple Silicon download with no paid signing or bundled device data.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  printf 'Release packaging currently requires an Apple Silicon Mac.\n' >&2
  exit 1
fi
"$project_dir/scripts/build-app.sh"
version="$(cat VERSION)"
archive="Scrcpy-Viewer-${version}-macOS-arm64.zip"
staging_dir="$(mktemp -d "$project_dir/dist/.release.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
ditto "$project_dir/dist/Scrcpy Viewer.app" "$staging_dir/Scrcpy Viewer.app"
cp docs/install.md "$staging_dir/INSTALL.md"
cp LICENSE THIRD_PARTY_NOTICES.md "$staging_dir/"
cp -R LICENSES "$staging_dir/"
cp scripts/setup-dependencies.sh "$staging_dir/"
cp VERSION "$staging_dir/"
# Keep ZIP member times stable when packaging the same commit again. Compilers
# can still produce different bytes; published releases must never be replaced.
source_date_epoch="$(git log -1 --format=%ct)"
python3 - "$staging_dir" "$source_date_epoch" <<'PY'
import os
from pathlib import Path
import sys
root, timestamp = Path(sys.argv[1]), int(sys.argv[2])
for path in [*root.rglob('*'), root]:
    os.utime(path, (timestamp, timestamp), follow_symlinks=False)
PY
# The archive contains only these allowlisted distribution files.
COPYFILE_DISABLE=1 ditto -c -k --norsrc "$staging_dir" "$project_dir/dist/$archive"
(cd dist && shasum -a 256 "$archive" > SHA256SUMS)
"$project_dir/scripts/check-release.sh"
printf 'Packaged: %s/dist/%s\n' "$project_dir" "$archive"
