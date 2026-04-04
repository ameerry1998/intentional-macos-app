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
# Installer cert (optional — set to empty string to skip PKG signing)
INSTALLER_SIGNING_IDENTITY=""
# Uncomment when you have the cert:
# INSTALLER_SIGNING_IDENTITY="Developer ID Installer: Amer Raiyan (B7B67856A7)"

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

# Re-sign with Developer ID Application
codesign --deep --force --options runtime --timestamp \
  --sign "$APP_SIGNING_IDENTITY" \
  "$APP_PATH" 2>&1

echo "✅ Intentional.app archived and signed"

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
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 20px; color: #333; }
  h1 { font-size: 24px; margin-bottom: 8px; }
  .subtitle { color: #666; font-size: 14px; margin-bottom: 20px; }
  ul { padding-left: 20px; }
  li { margin-bottom: 8px; font-size: 14px; }
  .note { background: #f5f5f5; padding: 12px; border-radius: 8px; font-size: 13px; color: #555; margin-top: 20px; }
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

# ---- Step 7: Notarize (only if signed) ----
if [ -n "$INSTALLER_SIGNING_IDENTITY" ]; then
  echo "📨 Step 7/7: Notarizing PKG (2-10 minutes)..."
  xcrun notarytool submit "$PKG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$PKG_PATH"
  echo "✅ Notarized and stapled"
else
  echo "⏭️  Step 7/7: Skipping notarization (unsigned PKG)"
fi

echo ""
echo "=== Done! ==="
echo "PKG: $PKG_PATH"
echo "Size: $(du -h "$PKG_PATH" | cut -f1)"
echo ""
echo "To install: double-click the .pkg file"
echo "To test: sudo installer -pkg '$PKG_PATH' -target /"
