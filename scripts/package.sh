#!/bin/bash
# Builds dist/PhamVision.app (universal) and dist/PhamVision-<version>.zip.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
APP="dist/PhamVision.app"

swift build -c release --arch arm64 --arch x86_64 --product PhamVision
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/PhamVision"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhamVision"
cp assets/PhamVision.icns "$APP/Contents/Resources/PhamVision.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PhamVision</string>
  <key>CFBundleDisplayName</key><string>PhamVision</string>
  <key>CFBundleIdentifier</key><string>io.github.mikebuckets171.PhamVision</string>
  <key>CFBundleExecutable</key><string>PhamVision</string>
  <key>CFBundleIconFile</key><string>PhamVision</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>org.matroska.mkv</string>
      </array>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" "dist/PhamVision-${VERSION}.zip"
echo "$APP"
echo "dist/PhamVision-${VERSION}.zip"
