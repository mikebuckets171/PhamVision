#!/bin/bash
# Builds dist/PhamVision.app (universal) and dist/PhamVision-<version>.zip.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
APP="dist/PhamVision.app"
# Where the app looks for updates: the appcast attached to the latest release.
FEED_URL="${FEED_URL:-https://github.com/mikebuckets171/PhamVision/releases/latest/download/appcast.xml}"
# Public half of the update signing key (the private half is a GitHub secret).
SPARKLE_PUBLIC_KEY="nbQzzMRPhjPypSRWIh8QrpCXlrGSZdQhfiZ9vvefHbo="

swift build -c release --arch arm64 --arch x86_64 --product PhamVision
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/PhamVision"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/PhamVision"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
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
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign inside out: Sparkle's helpers, the framework, then the app.
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SPK"/XPCServices/*.xpc "$SPK/Autoupdate" "$SPK/Updater.app"; do
  [ -e "$item" ] && codesign --force --sign - "$item"
done
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" "dist/PhamVision-${VERSION}.zip"
echo "$APP"
echo "dist/PhamVision-${VERSION}.zip"
