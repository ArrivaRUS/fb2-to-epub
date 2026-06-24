#!/bin/bash
# Advanced CLI uninstall path for the fb2-to-epub LaunchAgent.
# Removes the new-label agent, its plist, and the App Support install.
# The watch folder and your converted files are left untouched.
set -uo pipefail

LABEL="com.arrivarus.fb2toepub.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_SUPPORT="$HOME/Library/Application Support/fb2-to-epub"
WATCH_DIR="${WATCH_DIR:-$HOME/Desktop/fb2-to-epub}"

domain="gui/$(id -u)"
launchctl bootout "$domain/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APP_SUPPORT"

echo "Uninstalled fb2-to-epub agent ($LABEL)."
echo "  Removed LaunchAgent: $PLIST"
echo "  Removed scripts:     $APP_SUPPORT"
echo "  Watch folder kept:   $WATCH_DIR (delete manually if you want)."
