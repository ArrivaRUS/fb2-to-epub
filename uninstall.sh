#!/bin/bash
set -u

LABEL="com.user.fb2-to-epub"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="$HOME/.local/bin/fb2-to-epub-watcher.sh"
WATCH_DIR="$HOME/Desktop/fb2-to-epub"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST" "$SCRIPT"

echo "Uninstalled LaunchAgent and watcher script."
echo "Watch folder kept at: $WATCH_DIR (delete manually if you want)."
