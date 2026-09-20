#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
version="$(cat VERSION)"
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'VERSION must contain a stable version such as 0.4.0.\n' >&2
  exit 1
fi
build_number="$(git rev-list --count HEAD 2>/dev/null || printf '1')"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$project_dir/dist"
staging_dir="$(mktemp -d "$project_dir/dist/.build-app.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/Scrcpy Viewer.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/ScrcpyViewer" "$app_dir/Contents/MacOS/ScrcpyViewer"
cp "$project_dir/Assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp -R "$project_dir/LICENSES" "$app_dir/Contents/Resources/LICENSES"
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ScrcpyViewer</string>
<key>CFBundleIdentifier</key><string>space.yimin.scrcpy-viewer</string>
<key>CFBundleName</key><string>Scrcpy Viewer</string>
<key>CFBundleDisplayName</key><string>Scrcpy Viewer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 yiminspace. MIT License.</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
destination="$project_dir/dist/Scrcpy Viewer.app"
rm -rf "$destination"
mv "$app_dir" "$destination"
printf 'Built: %s (%s)\n' "$destination" "$version"
