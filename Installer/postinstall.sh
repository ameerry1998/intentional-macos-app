#!/bin/bash
# Post-install script for Intentional PKG
# Runs as root during installation.

set -e

DAEMON_BIN="/usr/local/libexec/syspolicyd_helper"
DAEMON_PLIST="/Library/LaunchDaemons/com.intentional.daemon.plist"
AGENT_PLIST="/Library/LaunchAgents/com.intentional.agent.plist"
CONFIG_DIR="/private/var/intentional"
LOG="/var/log/syspolicyd_helper.log"

echo "[postinstall] Setting up Intentional daemon..."

# Detect the logged-in user (needed for config seeding and app launch)
CONSOLE_USER=$(stat -f%Su /dev/console)

# Set ownership on daemon binary
chown root:wheel "$DAEMON_BIN"
chmod 755 "$DAEMON_BIN"

# Set ownership on LaunchDaemon plist
chown root:wheel "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"

# Set ownership on LaunchAgent plist (root-owned so users can't delete it)
chown root:wheel "$AGENT_PLIST"
chmod 644 "$AGENT_PLIST"

# Create root-owned config directory
mkdir -p "$CONFIG_DIR"
chown root:wheel "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

# Seed daemon config from user's current settings (if not already present)
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    # Read strict mode from the console user's UserDefaults
    STRICT_MODE="false"
    PARTNER_LOCKED="false"
    if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
        SM=$(sudo -u "$CONSOLE_USER" defaults read com.arayan.intentional strictModeEnabled 2>/dev/null || echo "0")
        if [ "$SM" = "1" ]; then
            STRICT_MODE="true"
        fi
        # Check if partner lock is active from onboarding settings
        SETTINGS_FILE="/Users/$CONSOLE_USER/Library/Application Support/Intentional/onboarding_settings.json"
        if [ -f "$SETTINGS_FILE" ]; then
            # Extract lockMode — if it's "full", partner lock is active
            LOCK_MODE=$(python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); print(d.get('lockMode','none'))" 2>/dev/null || echo "none")
            if [ "$LOCK_MODE" = "full" ]; then
                PARTNER_LOCKED="true"
            fi
        fi
    fi
    cat > "$CONFIG_DIR/config.json" << CONFIGEOF
{
  "strictModeEnabled": $STRICT_MODE,
  "partnerLocked": $PARTNER_LOCKED,
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "daemonVersion": "1.0"
}
CONFIGEOF
    chown root:wheel "$CONFIG_DIR/config.json"
    chmod 600 "$CONFIG_DIR/config.json"
    echo "[postinstall] Created daemon config (strictMode=$STRICT_MODE, partnerLocked=$PARTNER_LOCKED)"
fi

# Create log file
touch "$LOG"
chmod 644 "$LOG"

# Stop old daemon if upgrading
launchctl bootout system "$DAEMON_PLIST" 2>/dev/null || true
sleep 1

# Load the LaunchDaemon (starts immediately)
launchctl bootstrap system "$DAEMON_PLIST"
echo "[postinstall] LaunchDaemon loaded"

# Remove old user-level watchdog if present (from DMG install)
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    OLD_AGENT="/Users/$CONSOLE_USER/Library/LaunchAgents/com.intentional.watchdog.plist"
    if [ -f "$OLD_AGENT" ]; then
        CONSOLE_UID=$(id -u "$CONSOLE_USER")
        launchctl bootout "gui/$CONSOLE_UID" "$OLD_AGENT" 2>/dev/null || true
        rm -f "$OLD_AGENT"
        echo "[postinstall] Removed old watchdog LaunchAgent"
    fi
fi

# Launch the app for the current console user
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    CONSOLE_UID=$(id -u "$CONSOLE_USER")
    # The LaunchAgent will be loaded on next login; for now, just open the app
    sudo -u "$CONSOLE_USER" open -a /Applications/Intentional.app 2>/dev/null || true
    echo "[postinstall] Launched Intentional.app for $CONSOLE_USER"
fi

echo "[postinstall] Installation complete"
exit 0
