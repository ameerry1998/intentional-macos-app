#!/bin/bash
set -euo pipefail

# ============================================================
# Intentional macOS App — PKG Installer Build
# ============================================================
#
# Builds a signed PKG installer containing:
#   1. Intentional.app → /Applications/
#   2. syspolicyd_helper (daemon) → /usr/local/libexec/
#   3. LaunchDaemon plist → /Library/LaunchDaemons/
#   4. LaunchAgent plist → /Library/LaunchAgents/
#
# The PKG requires admin password to install (standard for macOS).
# Post-install script sets root ownership and loads the daemon.
#
# Prerequisites:
#   Same as build-dmg.sh + "Developer ID Installer" cert (optional for testing)
#
# Usage:
#   ./scripts/build-pkg.sh
#
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="/tmp/intentional-pkg-build"
ARCHIVE_PATH="$BUILD_DIR/Intentional.xcarchive"
VERSION=$(grep MARKETING_VERSION "$PROJECT_DIR/Intentional.xcodeproj/project.pbxproj" | head -1 | sed 's/.*= //' | sed 's/;//')
PKG_PATH="$BUILD_DIR/Intentional-${VERSION}.pkg"

APP_SIGNING_IDENTITY="Developer ID Application: Amer Raiyan (B7B67856A7)"
INSTALLER_SIGNING_IDENTITY="Developer ID Installer: Amer Raiyan (B7B67856A7)"

NOTARY_PROFILE="intentional-notary"
TEAM_ID="B7B67856A7"
DAEMON_PRODUCT_NAME="syspolicyd_helper"

echo "=== Intentional PKG Build Pipeline ==="
echo "Version: $VERSION"
echo ""

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---- Step 1: Build the main app (Release) ----
echo "📦 Step 1/7: Archiving Intentional.app..."
xcodebuild -project "$PROJECT_DIR/Intentional.xcodeproj" \
  -scheme Intentional \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  DEVELOPMENT_TEAM=$TEAM_ID \
  CODE_SIGN_STYLE=Automatic \
  2>&1 | tail -5

# Extract .app from archive
APP_PATH="$BUILD_DIR/Intentional.app"
ditto --noextattr --norsrc "$ARCHIVE_PATH/Products/Applications/Intentional.app" "$APP_PATH"

# Embed Developer ID provisioning profile and re-sign with Developer ID Application.
# The profile must match the signing cert (check fingerprints if AMFI Error 163).
DEVID_PROFILE="$PROJECT_DIR/Intentional/Intentional_Developer_ID.provisionprofile"
if [ -f "$DEVID_PROFILE" ]; then
  cp "$DEVID_PROFILE" "$APP_PATH/Contents/embedded.provisionprofile"
  echo "   Embedded Developer ID provisioning profile"
else
  echo "⚠️  Developer ID profile not found — keeping Xcode archive signing"
fi

# Re-sign with Developer ID Application + secure timestamps
# Sign inside-out: embedded components first, then the main app
# Create a modified entitlements for Developer ID signing:
# - Development profile uses "content-filter-provider"
# - Developer ID profile uses "content-filter-provider-systemextension"
ENTITLEMENTS_PATH="$BUILD_DIR/Intentional-DevID.entitlements"
# Transform entitlements for Developer ID signing:
# 1. content-filter-provider → content-filter-provider-systemextension (profile value)
# 2. Remove sensitivecontentanalysis.client — Apple doesn't authorize it for Developer ID
#    distribution. The app falls back to NudeNet v3 when analysisPolicy == .disabled.
#    The SOURCE entitlements file is NOT modified (keeps working for Xcode dev builds).
sed 's/content-filter-provider/content-filter-provider-systemextension/' \
  "$PROJECT_DIR/Intentional/Intentional.entitlements" | \
  perl -0777 -pe 's/\t<key>com\.apple\.developer\.sensitivecontentanalysis\.client<\/key>\n\t<array>\n\t\t<string>analysis<\/string>\n\t<\/array>\n//' \
  > "$ENTITLEMENTS_PATH"
echo "   Created Developer ID entitlements"

# Sign FilterExtension with its own entitlements
FILTER_EXT="$APP_PATH/Contents/Library/SystemExtensions/FilterExtension.systemextension"
if [ -d "$FILTER_EXT" ]; then
  FILTER_ENTITLEMENTS="$PROJECT_DIR/FilterExtension/FilterExtension.entitlements"
  codesign --force --options runtime --timestamp \
    --entitlements "$FILTER_ENTITLEMENTS" \
    --sign "$APP_SIGNING_IDENTITY" \
    "$FILTER_EXT" 2>&1
  echo "   Signed FilterExtension"
fi

# Sign all embedded frameworks and bundles (no entitlements needed)
find "$APP_PATH/Contents" \( -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" \) -maxdepth 3 2>/dev/null | while read component; do
  codesign --force --options runtime --timestamp \
    --sign "$APP_SIGNING_IDENTITY" \
    "$component" 2>&1 || true
done

# Sign the main app LAST with its entitlements
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS_PATH" \
  --sign "$APP_SIGNING_IDENTITY" \
  "$APP_PATH" 2>&1

echo "✅ Intentional.app signed with Developer ID (profile cert matched)"

# ---- Step 2: Build the daemon ----
echo "🔧 Step 2/7: Building $DAEMON_PRODUCT_NAME..."
DAEMON_BUILD_DIR="$BUILD_DIR/daemon-build"
xcodebuild -project "$PROJECT_DIR/Intentional.xcodeproj" \
  -scheme "$DAEMON_PRODUCT_NAME" \
  -configuration Release \
  -derivedDataPath "$DAEMON_BUILD_DIR" \
  build \
  DEVELOPMENT_TEAM=$TEAM_ID \
  CODE_SIGN_STYLE=Automatic \
  2>&1 | tail -5

DAEMON_BIN=$(find "$DAEMON_BUILD_DIR" -name "$DAEMON_PRODUCT_NAME" -type f -perm +111 | head -1)
if [ -z "$DAEMON_BIN" ]; then
  echo "❌ Daemon binary not found!"
  exit 1
fi

# Sign daemon with Developer ID Application (hardened runtime)
codesign --force --options runtime --timestamp \
  --sign "$APP_SIGNING_IDENTITY" \
  "$DAEMON_BIN" 2>&1

echo "✅ $DAEMON_PRODUCT_NAME built and signed"

# ---- Step 3: Create component payloads ----
echo "📁 Step 3/7: Creating component payloads..."

# App component: /Applications/Intentional.app
APP_PAYLOAD="$BUILD_DIR/payload-app"
mkdir -p "$APP_PAYLOAD/Applications"
cp -R "$APP_PATH" "$APP_PAYLOAD/Applications/"

# Daemon component: daemon binary + plists
DAEMON_PAYLOAD="$BUILD_DIR/payload-daemon"
mkdir -p "$DAEMON_PAYLOAD/usr/local/libexec"
mkdir -p "$DAEMON_PAYLOAD/Library/LaunchDaemons"
mkdir -p "$DAEMON_PAYLOAD/Library/LaunchAgents"
cp "$DAEMON_BIN" "$DAEMON_PAYLOAD/usr/local/libexec/$DAEMON_PRODUCT_NAME"
cp "$PROJECT_DIR/IntentionalDaemon/com.intentional.daemon.plist" "$DAEMON_PAYLOAD/Library/LaunchDaemons/"
cp "$PROJECT_DIR/Installer/com.intentional.agent.plist" "$DAEMON_PAYLOAD/Library/LaunchAgents/"

echo "✅ Payloads created"

# ---- Step 4: Create component packages ----
echo "📦 Step 4/7: Building component packages..."

# Scripts directory (pre/post install)
SCRIPTS_DIR="$BUILD_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"
cp "$PROJECT_DIR/Installer/postinstall.sh" "$SCRIPTS_DIR/postinstall"
chmod +x "$SCRIPTS_DIR/postinstall"

# Preinstall (optional — for upgrades)
if [ -f "$PROJECT_DIR/Installer/preinstall.sh" ]; then
  cp "$PROJECT_DIR/Installer/preinstall.sh" "$SCRIPTS_DIR/preinstall"
  chmod +x "$SCRIPTS_DIR/preinstall"
fi

# App component package
pkgbuild \
  --root "$APP_PAYLOAD" \
  --identifier "com.intentional.app" \
  --version "$VERSION" \
  --install-location "/" \
  "$BUILD_DIR/IntentionalApp.pkg"

# Daemon component package (with scripts)
pkgbuild \
  --root "$DAEMON_PAYLOAD" \
  --identifier "com.intentional.daemon" \
  --version "$VERSION" \
  --install-location "/" \
  --scripts "$SCRIPTS_DIR" \
  "$BUILD_DIR/IntentionalDaemon.pkg"

echo "✅ Component packages built"

# ---- Step 5: Create Distribution.xml ----
echo "📝 Step 5/7: Creating distribution..."

cat > "$BUILD_DIR/Distribution.xml" << 'DISTXML'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Intentional</title>
    <organization>com.intentional</organization>
    <domains enable_localSystem="true"/>
    <options customize="never" require-scripts="true" rootVolumeOnly="true"/>

    <welcome file="welcome.html" mime-type="text/html"/>

    <choices-outline>
        <line choice="app"/>
        <line choice="daemon"/>
    </choices-outline>

    <choice id="app" visible="false" enabled="true"
            title="Intentional App"
            description="The main Intentional application.">
        <pkg-ref id="com.intentional.app"/>
    </choice>

    <choice id="daemon" visible="false" enabled="true"
            title="Intentional Service"
            description="Background service for app persistence.">
        <pkg-ref id="com.intentional.daemon"/>
    </choice>

    <pkg-ref id="com.intentional.app" version="VERSION" onConclusion="none">IntentionalApp.pkg</pkg-ref>
    <pkg-ref id="com.intentional.daemon" version="VERSION" onConclusion="none">IntentionalDaemon.pkg</pkg-ref>
</installer-gui-script>
DISTXML

# Replace VERSION placeholder
sed -i '' "s/VERSION/$VERSION/g" "$BUILD_DIR/Distribution.xml"

# Create welcome page
RESOURCES_DIR="$BUILD_DIR/resources"
mkdir -p "$RESOURCES_DIR"
cat > "$RESOURCES_DIR/welcome.html" << 'WELCOMEHTML'
<!DOCTYPE html>
<html>
<head>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 20px; color: #e0e0e0; background: transparent; }
  h1 { font-size: 24px; margin-bottom: 8px; }
  .subtitle { color: #999; font-size: 14px; margin-bottom: 20px; }
  ul { padding-left: 20px; }
  li { margin-bottom: 8px; font-size: 14px; }
  .note { background: rgba(255,255,255,0.08); padding: 12px; border-radius: 8px; font-size: 13px; color: #aaa; margin-top: 20px; border: 1px solid rgba(255,255,255,0.1); }
</style>
</head>
<body>
  <h1>Intentional</h1>
  <div class="subtitle">Focus &amp; accountability for your Mac</div>
  <p>This installer will set up:</p>
  <ul>
    <li><strong>Intentional.app</strong> in your Applications folder</li>
    <li>A background service that keeps the app running when persistence mode is enabled</li>
    <li>Automatic launch on login</li>
  </ul>
  <div class="note">
    <strong>Admin password required.</strong> The background service needs system-level access
    to provide tamper-resistant app persistence. This is standard for accountability software.
  </div>
</body>
</html>
WELCOMEHTML

echo "✅ Distribution created"

# ---- Step 6: Build final PKG ----
echo "📦 Step 6/7: Building final installer package..."

if [ -n "$INSTALLER_SIGNING_IDENTITY" ]; then
  productbuild \
    --distribution "$BUILD_DIR/Distribution.xml" \
    --package-path "$BUILD_DIR" \
    --resources "$RESOURCES_DIR" \
    --sign "$INSTALLER_SIGNING_IDENTITY" \
    "$PKG_PATH"
  echo "✅ PKG built and signed"
else
  productbuild \
    --distribution "$BUILD_DIR/Distribution.xml" \
    --package-path "$BUILD_DIR" \
    --resources "$RESOURCES_DIR" \
    "$PKG_PATH"
  echo "✅ PKG built (unsigned — get Developer ID Installer cert for production)"
fi

# ---- Step 7: Notarize (only if signed and NOTARIZE=1) ----
if [ -n "$INSTALLER_SIGNING_IDENTITY" ] && [ "${NOTARIZE:-1}" = "1" ]; then
  echo "📨 Step 7/7: Notarizing PKG (2-10 minutes)..."
  xcrun notarytool submit "$PKG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$PKG_PATH"
  echo "✅ Notarized and stapled"
else
  echo "⏭️  Step 7/7: Skipping notarization"
fi

echo ""
echo "=== Done! ==="
echo "PKG: $PKG_PATH"
echo "Size: $(du -h "$PKG_PATH" | cut -f1)"
echo ""
echo "To install: double-click the .pkg file"
echo "To test: sudo installer -pkg '$PKG_PATH' -target /"
