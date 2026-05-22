#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.user.fb2-to-epub"
SCRIPT_DST="$HOME/.local/bin/fb2-to-epub-watcher.sh"
COVER_DST="$HOME/.local/bin/fb2-to-epub-cover-finder.py"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
WATCH_DIR="$HOME/Desktop/fb2-to-epub"
EBOOK_CONVERT="/Applications/calibre.app/Contents/MacOS/ebook-convert"

if [[ ! -x "$EBOOK_CONVERT" ]]; then
  echo "Calibre not found at $EBOOK_CONVERT" >&2
  echo "Install it first: brew install --cask calibre  (or download from https://calibre-ebook.com)" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found; install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

mkdir -p "$(dirname "$SCRIPT_DST")" "$(dirname "$PLIST_DST")" "$WATCH_DIR" "$HOME/Library/Logs"

install -m 0755 "$REPO_DIR/bin/fb2-to-epub-watcher.sh" "$SCRIPT_DST"
install -m 0755 "$REPO_DIR/bin/fb2-to-epub-cover-finder.py" "$COVER_DST"
sed "s|__HOME__|$HOME|g" "$REPO_DIR/launchd/$LABEL.plist.template" > "$PLIST_DST"

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load -w "$PLIST_DST"

cat <<EOF
Installed.
  Watch folder: $WATCH_DIR
  Script:       $SCRIPT_DST
  Cover finder: $COVER_DST
  LaunchAgent:  $PLIST_DST
  Log:          $HOME/Library/Logs/fb2-to-epub.log

Drop .fb2 / .fb2.zip files or folders into the watch folder.
EOF
