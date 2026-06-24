#!/bin/bash
# Package build/dist/fb2-to-epub.app into a distributable .dmg.
#
# Uses create-dmg (andreyvit, Homebrew) for reliable window layout: it supports
# the exact knobs the design needs (--window-size, --background, --icon x y,
# --app-drop-link x y). The sindresorhus npm `create-dmg` is zero-config and does
# NOT accept those flags, so we standardize on the Homebrew tool here.
#
# Layout (coordinates agreed with the background designer):
#   window 660x400, app icon at (165,185), /Applications drop link at (495,185)
#
# Background: branding/dmg-background.png. If absent, a placeholder is generated
# so the script stays testable before the final art lands.
#
# Output: build/dist/fb2-to-epub-<version>.dmg  (+ .sha256)
#
# Usage: build/make-dmg.sh [version]   (default matches build-app default)

set -euo pipefail

VERSION="${1:-0.1.0}"
APP_NAME="fb2-to-epub"
VOLNAME="fb2-to-epub"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_DIR/build/dist"
APP="$DIST_DIR/$APP_NAME.app"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
BG="$REPO_DIR/branding/dmg-background.png"

# Layout constants (design-agreed).
WIN_W=660
WIN_H=400
ICON_SIZE=120
APP_X=165;  APP_Y=185
DROP_X=495; DROP_Y=185

# --- preconditions ---------------------------------------------------------
command -v create-dmg >/dev/null 2>&1 || {
  echo "make-dmg: create-dmg not found. Install it:  brew install create-dmg" >&2
  exit 1
}
[[ -d "$APP" ]] || { echo "make-dmg: $APP not found — run build/build-app.sh first" >&2; exit 1; }

# --- background: use real art, else generate a placeholder -----------------
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

if [[ ! -f "$BG" ]]; then
  echo "==> branding/dmg-background.png missing — generating placeholder"
  # Brand-ish dark/indigo placeholder at 2x (1320x800) so it looks crisp on retina.
  cat > "$TMP/bg.svg" <<SVG
<svg width="1320" height="800" viewBox="0 0 660 400" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <radialGradient id="bg" cx="50%" cy="35%" r="80%">
      <stop offset="0%" stop-color="#1A1422"/>
      <stop offset="60%" stop-color="#100C18"/>
      <stop offset="100%" stop-color="#0A0A0F"/>
    </radialGradient>
  </defs>
  <rect width="660" height="400" fill="url(#bg)"/>
  <text x="330" y="60" text-anchor="middle" fill="#EDE7F6"
        font-family="-apple-system, Helvetica, Arial, sans-serif" font-size="26" font-weight="600">
    Install fb2-to-epub
  </text>
  <text x="330" y="92" text-anchor="middle" fill="#9B8CC4"
        font-family="-apple-system, Helvetica, Arial, sans-serif" font-size="15">
    Drag the app onto the Applications folder
  </text>
  <!-- arrow from app icon toward /Applications -->
  <line x1="245" y1="185" x2="415" y2="185" stroke="#6C4CB6" stroke-width="4" stroke-linecap="round"/>
  <polygon points="415,178 433,185 415,192" fill="#6C4CB6"/>
  <text x="330" y="330" text-anchor="middle" fill="#7A6CA0"
        font-family="-apple-system, Helvetica, Arial, sans-serif" font-size="12">
    First launch: right-click the app → Open, then confirm (one time, unsigned build)
  </text>
</svg>
SVG
  qlmanage -t -s 1320 -o "$TMP" "$TMP/bg.svg" >/dev/null 2>&1 || true
  if [[ -f "$TMP/bg.svg.png" ]]; then
    # qlmanage fits within the bounding box; normalize to an exact 1320x800 canvas.
    sips -p 800 1320 "$TMP/bg.svg.png" --out "$TMP/bg.png" >/dev/null 2>&1 || cp "$TMP/bg.svg.png" "$TMP/bg.png"
    BG="$TMP/bg.png"
  else
    echo "make-dmg: could not generate placeholder background" >&2
    exit 1
  fi
fi

# --- build the dmg ---------------------------------------------------------
rm -f "$DMG"
# Stage only the .app; create-dmg adds the /Applications drop link itself.
STAGE="$TMP/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# Avoid signing detritus inside the staged copy.
xattr -cr "$STAGE/$APP_NAME.app" 2>/dev/null || true

echo "==> create-dmg ($WIN_W x $WIN_H, app@($APP_X,$APP_Y), /Applications@($DROP_X,$DROP_Y))"
create-dmg \
  --volname "$VOLNAME" \
  --background "$BG" \
  --window-pos 200 120 \
  --window-size "$WIN_W" "$WIN_H" \
  --icon-size "$ICON_SIZE" \
  --icon "$APP_NAME.app" "$APP_X" "$APP_Y" \
  --app-drop-link "$DROP_X" "$DROP_Y" \
  --hide-extension "$APP_NAME.app" \
  --no-internet-enable \
  "$DMG" \
  "$STAGE"

# --- checksum --------------------------------------------------------------
( cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

echo ""
echo "Built: $DMG"
echo "  size:   $(du -h "$DMG" | cut -f1)"
echo "  sha256: $(cut -d' ' -f1 < "$DMG.sha256")"
