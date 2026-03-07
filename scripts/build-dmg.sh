#!/bin/bash
set -euo pipefail

# ============================================================
# Intentional macOS App — Build, Sign, Notarize, DMG
# ============================================================
#
# Prerequisites:
#   1. Apple Developer Program membership ($99/year)
#   2. "Developer ID Application" certificate installed in Keychain
#      → developer.apple.com/account/resources/certificates → + → Developer ID Application
#   3. Notarization credentials stored (one-time, API key method):
#      xcrun notarytool store-credentials "intentional-notary" \
#        --key /path/to/AuthKey_XXXX.p8 \
#        --key-id "KEY_ID" \
#        --issuer "ISSUER_ID"
#   4. create-dmg installed: brew install create-dmg
#
# Usage:
#   ./scripts/build-dmg.sh
#
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="/tmp/intentional-build"
ARCHIVE_PATH="$BUILD_DIR/Intentional.xcarchive"
APP_PATH="$BUILD_DIR/Intentional.app"
ZIP_PATH="$BUILD_DIR/Intentional.zip"
VERSION=$(grep MARKETING_VERSION "$PROJECT_DIR/Intentional.xcodeproj/project.pbxproj" | head -1 | sed 's/.*= //' | sed 's/;//')
DMG_PATH="$BUILD_DIR/Intentional-${VERSION}.dmg"

SIGNING_IDENTITY="Developer ID Application: Amer Raiyan (B7B67856A7)"
NOTARY_PROFILE="intentional-notary"

echo "=== Intentional Build Pipeline ==="
echo "Version: $VERSION"
echo ""

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---- Step 1: Archive ----
echo "📦 Step 1/6: Archiving..."
xcodebuild -project "$PROJECT_DIR/Intentional.xcodeproj" \
  -scheme Intentional \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  DEVELOPMENT_TEAM=B7B67856A7 \
  CODE_SIGN_STYLE=Automatic \
  2>&1 | tail -5

echo "✅ Archive complete"

# ---- Step 2: Extract and re-sign with Developer ID ----
echo "🔏 Step 2/6: Signing with Developer ID..."

# Copy .app from archive, stripping resource forks and extended attributes
ditto --noextattr --norsrc "$ARCHIVE_PATH/Products/Applications/Intentional.app" "$APP_PATH"

# Re-sign everything with Developer ID Application (deep signs frameworks, helpers, etc.)
codesign --deep --force --options runtime --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$APP_PATH" 2>&1

echo "✅ Signed with Developer ID"

# ---- Step 3: Verify signing ----
echo "🔍 Step 3/6: Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -3
echo "✅ Signature valid"

# ---- Step 4: Notarize ----
echo "📨 Step 4/6: Notarizing (this takes 2-10 minutes)..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "✅ Notarization complete"

# ---- Step 5: Staple ----
echo "📎 Step 5/6: Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"
echo "✅ Stapled"

# ---- Step 6: Create DMG ----
echo "💿 Step 6/6: Creating DMG..."

# Check for create-dmg
if ! command -v create-dmg &> /dev/null; then
  echo "❌ create-dmg not found. Install with: brew install create-dmg"
  echo "   Alternatively, your signed app is ready at: $APP_PATH"
  exit 1
fi

create-dmg \
  --volname "Intentional" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Intentional.app" 150 190 \
  --app-drop-link 450 190 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$APP_PATH"

# Notarize the DMG too
echo "📨 Notarizing DMG..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

xcrun stapler staple "$DMG_PATH"

echo ""
echo "=== Done! ==="
echo "DMG: $DMG_PATH"
echo "Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "Users can now download and install by:"
echo "  1. Double-click the .dmg"
echo "  2. Drag Intentional to Applications"
echo "  3. Open Intentional from Applications"
