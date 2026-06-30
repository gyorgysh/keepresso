#!/usr/bin/env bash
#
# build-dmg.sh — build, sign, notarize, and package Keepresso as a DMG.
#
# Produces a Developer-ID-signed, notarized, stapled DMG in dist/, ready to
# attach to a GitHub Release. Run scripts/release.sh afterwards to sign the
# Sparkle appcast and upload.
#
#   ./scripts/build-dmg.sh
#
# Required environment (these are YOUR Apple credentials; never commit them):
#
#   DEVELOPER_ID_APP   Codesigning identity, e.g.
#                      "Developer ID Application: Your Name (TEAMID)".
#                      Find it with:  security find-identity -p codesigning -v
#   TEAM_ID            Your 10-char Apple Developer Team ID.
#   NOTARY_PROFILE     Name of a notarytool keychain profile you created once with:
#                      xcrun notarytool store-credentials NOTARY_PROFILE \
#                        --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#
# Optional:
#   SKIP_NOTARIZE=1    Build and sign only (for a local smoke test).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

SCHEME="Keepresso"
APP_NAME="Keepresso"
PROJECT="Keepresso.xcodeproj"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

: "${DEVELOPER_ID_APP:?Set DEVELOPER_ID_APP (see header for how to find it)}"
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID}"
command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"

# Read the marketing version straight from project.yml so the DMG is named after it.
VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
[ -n "$VERSION" ] || die "Couldn't read MARKETING_VERSION from project.yml"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

info "Generating $PROJECT"
xcodegen generate

info "Archiving $SCHEME (Release, Developer ID, hardened runtime)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APP"

# Export the archive as a Developer ID build. This re-signs the app and every
# nested framework / XPC service (including Sparkle's) with the same identity.
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
</dict>
</plist>
PLIST

info "Exporting signed app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
[ -d "$APP_PATH" ] || die "Export produced no $APP_NAME.app"

info "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Build a simple DMG with the app and an /Applications drop target.
info "Building DMG"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "$APP_NAME" \
    --app-drop-link 480 200 \
    --icon "$APP_NAME.app" 160 200 \
    --window-size 640 400 \
    "$DMG_PATH" "$APP_PATH"
else
  # Fallback: stage a folder with an Applications symlink, then hdiutil.
  STAGE="$BUILD_DIR/dmg"
  mkdir -p "$STAGE"
  cp -R "$APP_PATH" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
fi

info "Signing DMG"
codesign --force --sign "$DEVELOPER_ID_APP" "$DMG_PATH"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  info "SKIP_NOTARIZE set — done (DMG is signed but NOT notarized): $DMG_PATH"
  exit 0
fi

: "${NOTARY_PROFILE:?Set NOTARY_PROFILE (a notarytool keychain profile) or SKIP_NOTARIZE=1}"

info "Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

info "Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

info "Done: $DMG_PATH"
