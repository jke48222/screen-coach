#!/bin/bash
# Builds ScreenCoach.app — an LSUIElement (menu-bar-only) accessory app.
#
# Signing identity matters more than usual here. Accessibility is a TCC
# permission keyed to the code signature, so an ad-hoc signed build asks for
# permission again on every single rebuild. An Apple Development identity is
# stable across rebuilds, which is the difference between a usable dev loop
# and re-granting Accessibility twenty times an afternoon.
#
# Shipping later needs Developer ID + hardened runtime + notarization:
#   xcrun notarytool submit build/ScreenCoach.zip --keychain-profile <p> --wait
#   xcrun stapler staple build/ScreenCoach.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release >/dev/null
APP=build/ScreenCoach.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ScreenCoachApp "$APP/Contents/MacOS/ScreenCoach"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ScreenCoach</string>
  <key>CFBundleDisplayName</key><string>Screen Coach</string>
  <key>CFBundleIdentifier</key><string>com.funproject.screencoach</string>
  <key>CFBundleExecutable</key><string>ScreenCoach</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Copyright 2026 Jalen Edusei.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>The coach listens only while you hold the shortcut, so you can name what you are looking for out loud. Recognition runs on this Mac; no audio leaves it.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Turns what you say while holding the shortcut into a target to point at. On-device recognition is required — the coach refuses rather than sending audio to a server.</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)
APPLEDEV=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)

if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
  echo "Signed: $IDENTITY (hardened runtime, ready for notarytool)"
elif [ -n "$APPLEDEV" ]; then
  codesign --force --sign "$APPLEDEV" "$APP"
  echo "Signed: $APPLEDEV (stable — TCC grants survive rebuilds)"
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed. WARNING: Accessibility will be revoked on every rebuild."
fi
codesign --verify --strict "$APP" && echo "codesign verify: OK"
echo "Built $APP"
