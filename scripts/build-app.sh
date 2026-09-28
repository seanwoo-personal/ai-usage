#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) "AI Usage.app" and a distributable DMG in ./dist
#
# Optional environment variables:
#   VERSION          app version (default 1.0.0)
#   BUNDLE_ID        bundle identifier (default com.sean.aiusage)
#   SIGN_IDENTITY    "Developer ID Application: Name (TEAMID)" — omit for ad-hoc signing
#   NOTARY_PROFILE   keychain profile created with `xcrun notarytool store-credentials` — enables notarization
set -euo pipefail
cd "$(dirname "$0")/.."

APP="AI Usage"          # display / bundle name
EXE=AIUsage             # executable (SwiftPM product)
AUTHOR="Sean"
VERSION="${VERSION:-1.0.0}"
BUNDLE_ID="${BUNDLE_ID:-com.sean.aiusage}"
DIST=dist
APPDIR="$DIST/$APP.app"
SLUG="AI-Usage"

echo "▸ Building (arm64 + x86_64)…"
swift build -c release --triple arm64-apple-macosx13.0
swift build -c release --triple x86_64-apple-macosx13.0

rm -rf "$DIST" && mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
lipo -create -output "$APPDIR/Contents/MacOS/$EXE" \
  ".build/arm64-apple-macosx/release/$EXE" ".build/x86_64-apple-macosx/release/$EXE"

echo "▸ Icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APPDIR/Contents/Resources/AppIcon.icns"

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) $AUTHOR</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
</dict></plist>
PLIST

echo "▸ Signing…"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APPDIR"
else
  codesign --force --options runtime --sign - "$APPDIR"   # hardened runtime even without a certificate
  echo "  (ad-hoc signed with hardened runtime — set SIGN_IDENTITY for a Developer ID build)"
fi
codesign --verify --strict "$APPDIR"

echo "▸ DMG…"
STAGE="$(mktemp -d)"; cp -R "$APPDIR" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
cp Resources/*.txt "$STAGE/" 2>/dev/null || true   # first-launch guide
DMG="$DIST/$SLUG-$VERSION.dmg"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
[[ -n "${SIGN_IDENTITY:-}" ]] && codesign --force --sign "$SIGN_IDENTITY" "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "▸ Notarizing…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

(cd "$DIST" && ditto -c -k --keepParent "$APP.app" "$SLUG-$VERSION.zip")
cp "$DIST/$SLUG-$VERSION.zip" "$DIST/$SLUG.zip"   # stable name for releases/latest/download (install.sh)
echo "✓ $APPDIR"
echo "✓ $DMG"
echo "✓ $DIST/$SLUG-$VERSION.zip"
