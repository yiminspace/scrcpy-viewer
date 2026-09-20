#!/bin/bash
# Verify the downloaded layout as well as the local build, without a phone.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
version="$(cat VERSION)"
archive="$project_dir/dist/Scrcpy-Viewer-${version}-macOS-arm64.zip"
(cd dist && shasum -a 256 --check SHA256SUMS)
staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT
ditto -x -k "$archive" "$staging_dir"
app_dir="$staging_dir/Scrcpy Viewer.app"
plist="$app_dir/Contents/Info.plist"
plutil -lint "$plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == space.yimin.scrcpy-viewer ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" == 14.0 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")" == AppIcon.icns ]]
[[ "$(lipo -archs "$app_dir/Contents/MacOS/ScrcpyViewer")" == arm64 ]]
codesign --verify --deep --strict "$app_dir"
signature_description="$(codesign -d -v "$app_dir" 2>&1)"
[[ "$signature_description" == *'Signature=adhoc'* ]]
for file in INSTALL.md LICENSE THIRD_PARTY_NOTICES.md setup-dependencies.sh VERSION; do
  [[ -s "$staging_dir/$file" ]] || { printf 'Missing distribution file: %s\n' "$file" >&2; exit 1; }
done
[[ -x "$staging_dir/setup-dependencies.sh" ]]
cmp VERSION "$staging_dir/VERSION"
cmp Assets/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
cmp LICENSE "$app_dir/Contents/Resources/LICENSE"
cmp THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
cmp LICENSES/scrcpy-Apache-2.0.txt "$app_dir/Contents/Resources/LICENSES/scrcpy-Apache-2.0.txt"
cmp LICENSES/scrcpy-Apache-2.0.txt "$staging_dir/LICENSES/scrcpy-Apache-2.0.txt"
printf 'Release archive verified: version, architecture, signature, icon, install files and SHA-256.\n'
