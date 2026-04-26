#!/bin/bash
# Pre-install script for Intentional PKG
# Handles upgrades: stops old daemon before installing new one.

echo "[preinstall] Preparing for installation..."

# Stop existing daemon if running (upgrade scenario)
if launchctl print system/com.intentional.daemon &>/dev/null; then
  echo "[preinstall] Stopping existing daemon..."
  launchctl bootout system /Library/LaunchDaemons/com.intentional.daemon.plist 2>/dev/null || true
  sleep 1
fi

# Kill running app gracefully
killall Intentional 2>/dev/null || true
sleep 1

echo "[preinstall] Ready for installation"
exit 0
