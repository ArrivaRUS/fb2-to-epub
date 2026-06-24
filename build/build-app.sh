#!/bin/bash
# Build fb2-to-epub.app from the AppleScript applet.
#
# Steps:
#   1. osacompile the applet -> dist/fb2-to-epub.app
#   2. copy installer.sh + watcher + cover-finder + runner into Contents/Resources
#   3. build AppIcon.icns from branding/icon-concept-1.svg (svg->png->iconutil)
#   4. write Info.plist keys EXPLICITLY: CFBundleIdentifier=com.arrivarus.fb2toepub,
#      version, icon file, display name (osacompile does NOT set a stable id —
#      a drifting id breaks TCC grants on every rebuild)
#   5. ad-hoc codesign (-s -) and verify
#
# Output: build/dist/fb2-to-epub.app
#
# Usage: build/build-app.sh [version]   (default version below)

set -euo pipefail

VERSION="${1:-0.1.0}"
BUNDLE_ID="com.arrivarus.fb2toepub"
APP_NAME="fb2-to-epub"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_DIR/build"
DIST_DIR="$BUILD_DIR/dist"
APP="$DIST_DIR/$APP_NAME.app"
APPLET_SRC="$REPO_DIR/packaging/applet.applescript"
ICON_SVG="$REPO_DIR/branding/icon-concept-1.svg"

# --- tool checks -----------------------------------------------------------
for t in osacompile sips iconutil plutil qlmanage codesign; do
  command -v "$t" >/dev/null 2>&1 || { echo "build-app: required tool '$t' not found" >&2; exit 1; }
done
[[ -f "$APPLET_SRC" ]] || { echo "build-app: missing $APPLET_SRC" >&2; exit 1; }
[[ -f "$ICON_SVG"   ]] || { echo "build-app: missing $ICON_SVG" >&2; exit 1; }

# --- clean + compile -------------------------------------------------------
rm -rf "$APP"
mkdir -p "$DIST_DIR"
echo "==> osacompile -> $APP"
osacompile -o "$APP" "$APPLET_SRC"

RES="$APP/Contents/Resources"
mkdir -p "$RES"

# --- bundle the install logic + scripts ------------------------------------
echo "==> copying scripts into Resources"
install -m 0755 "$REPO_DIR/packaging/installer.sh"             "$RES/installer.sh"
install -m 0755 "$REPO_DIR/packaging/fb2-to-epub-runner.sh"    "$RES/fb2-to-epub-runner.sh"
install -m 0755 "$REPO_DIR/bin/fb2-to-epub-watcher.sh"         "$RES/fb2-to-epub-watcher.sh"
install -m 0755 "$REPO_DIR/bin/fb2-to-epub-cover-finder.py"    "$RES/fb2-to-epub-cover-finder.py"

# --- icon: SVG -> PNG set -> .icns -----------------------------------------
echo "==> building AppIcon.icns from $(basename "$ICON_SVG")"
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

# Render the SVG once at high resolution (no rsvg/inkscape needed; qlmanage can
# rasterize SVG). Then downscale with sips to each required size.
BASE_PNG="$ICON_TMP/base-1024.png"
qlmanage -t -s 1024 -o "$ICON_TMP" "$ICON_SVG" >/dev/null 2>&1 || true
rendered="$ICON_TMP/$(basename "$ICON_SVG").png"
if [[ -f "$rendered" ]]; then
  mv "$rendered" "$BASE_PNG"
fi
if [[ ! -f "$BASE_PNG" ]]; then
  echo "build-app: failed to rasterize SVG to PNG" >&2
  rm -rf "$ICON_TMP"; exit 1
fi

# Apple iconset requires these named sizes (1x + 2x).
make_size() { sips -z "$2" "$2" "$BASE_PNG" --out "$ICONSET/$1" >/dev/null; }
make_size icon_16x16.png        16
make_size icon_16x16@2x.png     32
make_size icon_32x32.png        32
make_size icon_32x32@2x.png     64
make_size icon_128x128.png     128
make_size icon_128x128@2x.png  256
make_size icon_256x256.png     256
make_size icon_256x256@2x.png  512
make_size icon_512x512.png     512
make_size icon_512x512@2x.png 1024

iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
rm -rf "$ICON_TMP"

# --- Info.plist: explicit, stable identity ---------------------------------
echo "==> writing Info.plist identity (id=$BUNDLE_ID, version=$VERSION)"
PLIST="$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier      -string "$BUNDLE_ID"  "$PLIST"
plutil -replace CFBundleName            -string "$APP_NAME"   "$PLIST"
plutil -replace CFBundleDisplayName     -string "$APP_NAME"   "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion         -string "$VERSION"    "$PLIST"
plutil -replace CFBundleIconFile        -string "AppIcon"     "$PLIST"
# Quieter, modern app behavior.
plutil -replace LSMinimumSystemVersion  -string "11.0"        "$PLIST" 2>/dev/null || true
plutil -replace NSHighResolutionCapable -bool true            "$PLIST" 2>/dev/null || true
plutil -lint "$PLIST" >/dev/null

# --- strip extended attributes (MUST be the last mutation before signing) ----
# qlmanage/sips/iconutil/touch leave com.apple.FinderInfo / quarantine xattrs that
# make `codesign --deep --strict` reject the bundle ("resource fork ... detritus
# not allowed"). Note: do NOT `touch` the bundle root afterwards — touch re-adds
# FinderInfo to the directory and re-breaks strict verification.
echo "==> stripping extended attributes"
find "$APP" -name '._*' -delete 2>/dev/null || true
find "$APP" -name '.DS_Store' -delete 2>/dev/null || true
xattr -cr "$APP"

# --- ad-hoc sign + verify (strict) -----------------------------------------
echo "==> ad-hoc codesign"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo ""
echo "Built: $APP"
echo "  CFBundleIdentifier: $(plutil -extract CFBundleIdentifier raw -o - "$PLIST")"
echo "  Version:            $(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
echo "  Icon:               $RES/AppIcon.icns"
