#!/usr/bin/env bash
# dev-launch.sh — Build (optional) + run a fresh Debug build of Intentional
# against the locked-down /Applications install, surviving the LaunchAgent +
# watchdog + main.swift single-instance check.
#
# Background: there are three silent failure modes when trying to run a new
# build on this Mac. Full explanation in docs/dev-build-and-launch.md, but the
# short version is:
#   1. PKG binaries (/tmp/intentional-pkg-build/) get AMFI-killed if exec'd
#      standalone — Developer-ID signing requires the installer context.
#   2. Debug binaries exec'd plainly hit main.swift:169's "duplicate launch"
#      branch and exit silently in <1s with no error.
#   3. The DerivedData hash drifts; hard-coding it breaks across Xcode resets.
#
# This script handles all three: builds Debug, discovers the current
# DerivedData folder, exec's with __XCODE_BUILT_PRODUCTS_DIR_PATHS set (so
# main.swift takes the "Xcode launch — kill existing PID, take over" branch),
# then verifies the new process survived and prints diagnostics if it didn't.
#
# Usage:
#   ./scripts/dev-launch.sh            # build Debug + launch
#   ./scripts/dev-launch.sh --no-build # skip build, just launch the existing
#                                      # newest Debug binary
#
# Exit codes:
#   0 = new instance alive and running
#   1 = build failed
#   2 = no Debug binary found
#   3 = new instance died (see /tmp/intentional-fresh.log)

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_ROOT="$HOME/Library/Developer/Xcode/DerivedData"
LOG_PATH="/tmp/intentional-fresh.log"

DO_BUILD=1
if [[ "${1:-}" == "--no-build" ]]; then
  DO_BUILD=0
fi

cd "$REPO_ROOT"

if [[ "$DO_BUILD" == "1" ]]; then
  echo "→ Building Debug..."
  if ! xcodebuild -project Intentional.xcodeproj -scheme Intentional \
      -configuration Debug build 2>&1 | tail -5; then
    echo "✗ Build failed. Run xcodebuild manually for the full log."
    exit 1
  fi
fi

# Find newest Debug build across all Intentional-* DerivedData folders.
# Hashes change across Xcode resets and worktree-switching, so always
# rediscover instead of hard-coding.
DERIVED_DIR=$(ls -dt "$DERIVED_ROOT"/Intentional-*/Build/Products/Debug 2>/dev/null | head -1)
if [[ -z "$DERIVED_DIR" ]]; then
  echo "✗ No Debug build found in DerivedData. Run with build (without --no-build) first."
  exit 2
fi
DERIVED_BINARY="$DERIVED_DIR/Intentional.app/Contents/MacOS/Intentional"
if [[ ! -x "$DERIVED_BINARY" ]]; then
  echo "✗ Binary not executable: $DERIVED_BINARY"
  exit 2
fi

echo "→ Launching: $DERIVED_BINARY"
echo "  mtime: $(stat -f "%Sm" "$DERIVED_BINARY")"

# Set __XCODE_BUILT_PRODUCTS_DIR_PATHS so main.swift:106 takes the takeover
# branch (terminates the existing PID, bootouts the LaunchAgent + Login Items,
# claims the lock file). Without this env var the new process exits silently
# as a "duplicate launch" — main.swift:169.
nohup env __XCODE_BUILT_PRODUCTS_DIR_PATHS="$DERIVED_DIR" \
  "$DERIVED_BINARY" &> "$LOG_PATH" &
NEW_PID=$!
echo "  launched PID $NEW_PID"

# Give main.swift's takeover sequence enough time to kill the old PID,
# bootout the LaunchAgent, sweep Login Items, and finish applicationDidFinishLaunching.
sleep 5

# Verify the new instance survived.
if ! kill -0 "$NEW_PID" 2>/dev/null; then
  echo ""
  echo "✗ New instance ($NEW_PID) died within 5s."
  echo ""
  echo "── /tmp/intentional-fresh.log (last 20 lines) ─────────────────────"
  tail -20 "$LOG_PATH"
  echo "───────────────────────────────────────────────────────────────────"
  echo ""
  # Auto-diagnose based on log signature
  if grep -q "📡 Launched via extension" "$LOG_PATH" 2>/dev/null && \
     ! grep -q "Creating NSApplication" "$LOG_PATH" 2>/dev/null; then
    echo "Diagnosis: AMFI silent-kill (Developer-ID binary exec'd standalone)."
    echo "Fix: ensure DERIVED_DIR points at DerivedData, not /tmp/intentional-pkg-build/."
  elif grep -q "applicationDidFinishLaunching CALLED" "$LOG_PATH" 2>/dev/null; then
    echo "Diagnosis: main.swift's single-instance check exited as duplicate."
    echo "Fix: __XCODE_BUILT_PRODUCTS_DIR_PATHS env var was likely empty or unset."
  else
    echo "Diagnosis: unknown — full log at $LOG_PATH"
  fi
  exit 3
fi

echo ""
echo "✓ New instance alive (PID $NEW_PID)."
echo "  Log: $LOG_PATH"
echo ""
pgrep -lf "Intentional.app/Contents/MacOS/Intentional" | head -5
