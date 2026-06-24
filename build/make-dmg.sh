#!/bin/bash
# Package build/dist/fb2-to-epub.app into a distributable .dmg.
#
# Uses dmgbuild (Python) — NOT create-dmg. create-dmg lays out the window by
# scripting Finder over Apple Events; a headless build has no Automation (TCC)
# grant, so that step silently no-ops and you get a broken window (wrong size →
# white gap, generic icon positions). dmgbuild writes the .DS_Store directly
# (ds_store/mac_alias), so the layout is baked in without any Finder, working
# headless. Layout/geometry live in build/dmg-settings.py; this script feeds it
# the concrete paths and the version.
#
# Layout (design-agreed, enforced in dmg-settings.py):
#   window 920x440 (macOS 26 opens the DMG window ~920 wide; matched → no white gap)
#   background 960x440 (>= window, dark to the edges)
#   app icon at (290,190), /Applications drop link at (630,190), icon size 120 (centered)
#   background = branding/dmg-background.png (+ @2x sibling → Retina-crisp TIFF)
#   app .app extension hidden; no toolbar/sidebar/statusbar/pathbar
#   volume icon = the app icon (.icns)
#
# Output: build/dist/fb2-to-epub-<version>.dmg  (+ .sha256)
#
# Usage:
#   build/make-dmg.sh [version]          # normal release build (volname fb2-to-epub)
#   build/make-dmg.sh [version] --test   # unique volname → dodge Finder's remembered
#                                        # window size when test-mounting repeatedly

set -euo pipefail

VERSION="${1:-0.1.0}"
MODE="${2:-}"
APP_NAME="fb2-to-epub"
VOLNAME="fb2-to-epub"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_DIR/build"
DIST_DIR="$BUILD_DIR/dist"
APP="$DIST_DIR/$APP_NAME.app"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
BG="$REPO_DIR/branding/dmg-background.png"        # 1x; @2x sibling auto-picked
ICON="$APP/Contents/Resources/AppIcon.icns"      # volume icon
SETTINGS="$BUILD_DIR/dmg-settings.py"
VENV_DMGBUILD="$BUILD_DIR/.venv/bin/dmgbuild"

# Test mode: unique volume name so Finder can't reuse a stale remembered window
# geometry for a volume it has seen before. Writes a throwaway dmg next to dist.
if [[ "$MODE" == "--test" ]]; then
  VOLNAME="fb2-to-epub-test-$(date +%s)"
  DMG="$DIST_DIR/$APP_NAME-$VERSION-TEST.dmg"
fi

# --- preconditions ---------------------------------------------------------
if [[ -x "$VENV_DMGBUILD" ]]; then
  DMGBUILD="$VENV_DMGBUILD"
elif command -v dmgbuild >/dev/null 2>&1; then
  DMGBUILD="$(command -v dmgbuild)"
else
  echo "make-dmg: dmgbuild not found. Install it:" >&2
  echo "    python3 -m venv build/.venv && build/.venv/bin/pip install dmgbuild" >&2
  exit 1
fi
[[ -d "$APP"      ]] || { echo "make-dmg: $APP not found — run build/build-app.sh first" >&2; exit 1; }
[[ -f "$SETTINGS" ]] || { echo "make-dmg: missing $SETTINGS" >&2; exit 1; }
[[ -f "$BG"       ]] || { echo "make-dmg: missing background $BG" >&2; exit 1; }
[[ -f "$ICON"     ]] || { echo "make-dmg: missing volume icon $ICON" >&2; exit 1; }
if [[ ! -f "${BG%.png}@2x.png" ]]; then
  echo "make-dmg: WARNING — ${BG%.png}@2x.png missing; background will be 1x only (blurry on Retina)" >&2
fi
# Background must be >= the window (920x440) so the Finder window (macOS 26 opens the
# DMG window ~920 wide, ignoring the remembered size) is fully covered — dark filler to
# the edges, never a white gap. dmgbuild anchors the bg top-left and does NOT scale/center
# it, so a larger image is safe; a smaller one risks white. Warn (don't fail) if under.
BG_W=$(sips -g pixelWidth  "$BG" 2>/dev/null | awk '/pixelWidth/{print $2}')
BG_H=$(sips -g pixelHeight "$BG" 2>/dev/null | awk '/pixelHeight/{print $2}')
echo "==> background 1x: ${BG_W:-?}x${BG_H:-?}  (window 920x440; bg >= window avoids white gap on macOS 26)"
if [[ -n "$BG_W" && -n "$BG_H" ]] && { [[ "$BG_W" -lt 920 ]] || [[ "$BG_H" -lt 440 ]]; }; then
  echo "make-dmg: WARNING — background ${BG_W}x${BG_H} is smaller than the 920x440 window" >&2
fi

# --- build the dmg ---------------------------------------------------------
rm -f "$DMG"
echo "==> dmgbuild  vol='$VOLNAME'  (window 920x440, app@(290,190), /Applications@(630,190))"
"$DMGBUILD" \
  -s "$SETTINGS" \
  -D app="$APP" \
  -D appname="$APP_NAME" \
  -D bg="$BG" \
  -D icon="$ICON" \
  "$VOLNAME" \
  "$DMG"

# --- checksum --------------------------------------------------------------
( cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

echo ""
echo "Built: $DMG"
echo "  size:   $(du -h "$DMG" | cut -f1)"
echo "  sha256: $(cut -d' ' -f1 < "$DMG.sha256")"
