#!/bin/bash

# Install Native Messaging manifest for Intentional
# This allows the Chrome extension to communicate with the macOS app

set -e

MANIFEST_NAME="com.intentional.social.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_MANIFEST="$SCRIPT_DIR/$MANIFEST_NAME"

# Check if manifest exists
if [ ! -f "$SOURCE_MANIFEST" ]; then
    echo "Error: Manifest not found at $SOURCE_MANIFEST"
    exit 1
fi

# Get extension ID from argument or use placeholder
EXTENSION_ID="${1:-YOUR_EXTENSION_ID_HERE}"

echo "Installing Native Messaging manifest for Intentional..."
echo "Extension ID: $EXTENSION_ID"

# Create manifest with correct extension ID
TEMP_MANIFEST=$(mktemp)
sed "s/YOUR_EXTENSION_ID_HERE/$EXTENSION_ID/g" "$SOURCE_MANIFEST" > "$TEMP_MANIFEST"

# Chrome paths
CHROME_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
CHROME_CANARY_DIR="$HOME/Library/Application Support/Google/Chrome Canary/NativeMessagingHosts"
CHROMIUM_DIR="$HOME/Library/Application Support/Chromium/NativeMessagingHosts"
BRAVE_DIR="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
EDGE_DIR="$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
ARC_DIR="$HOME/Library/Application Support/Arc/User Data/NativeMessagingHosts"

# Install for each browser that has the directory (or create it)
install_manifest() {
    local dir="$1"
    local name="$2"

    mkdir -p "$dir"
    cp "$TEMP_MANIFEST" "$dir/$MANIFEST_NAME"
    echo "✓ Installed for $name"
}

# Install for various Chromium-based browsers
install_manifest "$CHROME_DIR" "Google Chrome"
install_manifest "$BRAVE_DIR" "Brave"

# Only install for others if they exist
[ -d "$HOME/Library/Application Support/Google/Chrome Canary" ] && install_manifest "$CHROME_CANARY_DIR" "Chrome Canary"
[ -d "$HOME/Library/Application Support/Chromium" ] && install_manifest "$CHROMIUM_DIR" "Chromium"
[ -d "$HOME/Library/Application Support/Microsoft Edge" ] && install_manifest "$EDGE_DIR" "Microsoft Edge"
[ -d "$HOME/Library/Application Support/Arc" ] && install_manifest "$ARC_DIR" "Arc"

# Cleanup
rm "$TEMP_MANIFEST"

echo ""
echo "Installation complete!"
echo ""
echo "To find your extension ID:"
echo "1. Go to chrome://extensions"
echo "2. Enable 'Developer mode' (toggle in top right)"
echo "3. Find Intentional extension and copy its ID"
echo "4. Re-run: ./install.sh <your-extension-id>"
echo ""
echo "Note: The Intentional.app must be in /Applications for Native Messaging to work."
