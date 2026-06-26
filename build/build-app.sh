#!/bin/bash
# Build fb2-to-epub.app — NATIVE SwiftUI app (M0+).
#
# Steps:
#   1. compile app/main.swift for arm64 + x86_64 (xcrun swiftc) and lipo them
#      into a universal Contents/MacOS/fb2-to-epub
#   2. copy installer.sh + watcher + cover-finder + runner into Contents/Resources
#   3. build AppIcon.icns from branding/icon-app.svg (svg->png->iconutil)
#   4. write a clean Info.plist from scratch: CFBundleIdentifier=com.arrivarus.fb2toepub
#      (stable! a drifting id breaks TCC grants on every rebuild),
#      CFBundleExecutable=fb2-to-epub, version, icon, LSMinimumSystemVersion=11.0
#   5. ad-hoc codesign (-s -) and strict verify, inside a retry loop (iCloud
#      FinderInfo race — see .patches/003)
#
# Unsandboxed, no external Swift deps (SwiftUI/AppKit/Foundation), offline build.
#
# Output: build/dist/fb2-to-epub.app
#
# Usage: build/build-app.sh [version]   (default version below)

set -euo pipefail

VERSION="${1:-0.1.0}"
BUNDLE_ID="com.arrivarus.fb2toepub"
APP_NAME="fb2-to-epub"
MIN_MACOS="11.0"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_DIR/build"
DIST_DIR="$BUILD_DIR/dist"
APP="$DIST_DIR/$APP_NAME.app"
# Swift sources (compiled together into one binary, whole-module). main.swift
# drives the AppKit/SwiftUI window; EngineClient(+Status) is the engine bridge
# (M1/M2); Tokens/StateModel/StatusView make up the M2 Status screen;
# SetupView is the M3 first-run "Установка" screen; CoverSelectView is the M5
# "Выбор обложки" screen (reads the cover queue, writes an apply-job);
# SettingsView is the "Настройки" screen (replaces the old gear NSMenu).
SWIFT_SRCS=(
  "$REPO_DIR/app/main.swift"
  "$REPO_DIR/app/EngineClient.swift"
  "$REPO_DIR/app/EngineClient+Status.swift"
  "$REPO_DIR/app/StateModel.swift"
  "$REPO_DIR/app/Tokens.swift"
  "$REPO_DIR/app/StatusView.swift"
  "$REPO_DIR/app/SetupView.swift"
  "$REPO_DIR/app/CoverSelectView.swift"
  "$REPO_DIR/app/SettingsView.swift"
  "$REPO_DIR/app/UpdateChecker.swift"
)
ICON_SVG="$REPO_DIR/branding/icon-app.svg"

# --- tool checks -----------------------------------------------------------
for t in xcrun lipo sips iconutil plutil codesign; do
  command -v "$t" >/dev/null 2>&1 || { echo "build-app: required tool '$t' not found" >&2; exit 1; }
done
xcrun --find swiftc >/dev/null 2>&1 || { echo "build-app: swiftc not found (install Xcode)" >&2; exit 1; }
for s in "${SWIFT_SRCS[@]}"; do
  [[ -f "$s" ]] || { echo "build-app: missing $s" >&2; exit 1; }
done
[[ -f "$ICON_SVG"  ]] || { echo "build-app: missing $ICON_SVG" >&2; exit 1; }

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
[[ -d "$SDK_PATH" ]] || { echo "build-app: macOS SDK not found via xcrun" >&2; exit 1; }

# cairosvg rasterizes the SVG with a TRANSPARENT background (qlmanage forced a WHITE
# backing outside the squircle → opaque white corners in the .icns → a white "frame"
# ring around the icon in Finder/DMG). Resolve the venv binary; require it explicitly.
CAIROSVG="$BUILD_DIR/.venv/bin/cairosvg"
if [[ ! -x "$CAIROSVG" ]]; then
  if command -v cairosvg >/dev/null 2>&1; then
    CAIROSVG="$(command -v cairosvg)"
  else
    echo "build-app: cairosvg not found. Install it:" >&2
    echo "    python3 -m venv build/.venv && build/.venv/bin/pip install cairosvg" >&2
    echo "    (needs system cairo: brew install cairo)" >&2
    exit 1
  fi
fi

# --- clean + build native universal binary ---------------------------------
rm -rf "$APP"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
mkdir -p "$MACOS" "$RES"

echo "==> compiling native SwiftUI binary (arm64 + x86_64)"
BIN_TMP="$(mktemp -d)"
for arch in arm64 x86_64; do
  echo "    swiftc -> $arch"
  xcrun swiftc \
    -sdk "$SDK_PATH" \
    -target "${arch}-apple-macos${MIN_MACOS}" \
    -O \
    "${SWIFT_SRCS[@]}" \
    -o "$BIN_TMP/$APP_NAME-$arch" 2>&1 | sed 's/^/    /'
  # swiftc exit code is hidden by the pipe to sed — verify the artifact exists.
  [[ -f "$BIN_TMP/$APP_NAME-$arch" ]] || {
    echo "build-app: swiftc failed to produce $arch binary" >&2; rm -rf "$BIN_TMP"; exit 1; }
done

echo "==> lipo -> universal $MACOS/$APP_NAME"
lipo -create "$BIN_TMP/$APP_NAME-arm64" "$BIN_TMP/$APP_NAME-x86_64" \
  -output "$MACOS/$APP_NAME"
chmod 0755 "$MACOS/$APP_NAME"
rm -rf "$BIN_TMP"
lipo -info "$MACOS/$APP_NAME" | sed 's/^/    /'

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

# Render the SVG once at high resolution with cairosvg (transparent background, exact
# 1024x1024). Then downscale with sips to each required size — sips preserves the alpha
# channel, so the squircle's rounded corners stay transparent all the way down.
BASE_PNG="$ICON_TMP/base-1024.png"
"$CAIROSVG" "$ICON_SVG" -o "$BASE_PNG" --output-width 1024 --output-height 1024 2>&1 | sed 's/^/    /' || true
if [[ ! -f "$BASE_PNG" ]]; then
  echo "build-app: failed to rasterize SVG to PNG via cairosvg" >&2
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
# Native bundle: the icon resolves straight from CFBundleIconFile=AppIcon → AppIcon.icns.
# No applet.icns / applet.rsrc legacy carriers here (those were osacompile artifacts).
rm -rf "$ICON_TMP"

# --- Info.plist: clean, written from scratch (native bundle) ---------------
# A native bundle has NO pre-seeded Info.plist (unlike osacompile, which dumped a
# pile of Carbon/AppleEvents keys). Write exactly the keys we want — stable id,
# native executable name, dark-capable windowed app. No LSUIElement (plain window).
# No CFBundleIconName (that key would override CFBundleIconFile and, without an
# Assets.car, fall back to the generic icon — see .patches/002).
echo "==> writing Info.plist (id=$BUNDLE_ID, exec=$APP_NAME, version=$VERSION)"
PLIST="$APP/Contents/Info.plist"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<true/>
	<key>NSSupportsSuddenTermination</key>
	<true/>
</dict>
</plist>
PLIST_EOF
plutil -lint "$PLIST" >/dev/null

# --- strip xattrs + ad-hoc sign + verify (strict), with retry --------------
# cairosvg/sips/iconutil/touch leave com.apple.FinderInfo / quarantine xattrs that
# make `codesign --deep --strict` reject the bundle ("resource fork ... detritus
# not allowed"). Worse: when the repo lives in a synced folder (iCloud/fileprovider),
# the daemon re-stamps com.apple.FinderInfo onto the bundle ROOT directory
# ASYNCHRONOUSLY — sometimes between the strip and codesign, or between codesign and
# strict verify — so the failure is a RACE and reproduces only intermittently. That
# xattr sits on the wrapper DIRECTORY, not on any signed payload, so clearing it just
# before signing/verify is safe and does not invalidate the signature.
# Note: do NOT `touch` the bundle root — touch re-adds FinderInfo and re-breaks strict.
#
# Strategy: run the full strip→sign→clean→verify sequence inside a retry loop (up to 5
# attempts, ~1s pause between). Both codesign calls are guarded by `if` so a failed
# attempt RETRIES instead of killing the script under `set -euo pipefail`.
echo "==> ad-hoc codesign + strict verify (with retry)"
CODESIGN_OK=0
for attempt in 1 2 3 4 5; do
  echo "==> codesign attempt $attempt/5"
  # Full cleanup on every attempt — FinderInfo may have been re-stamped since last try.
  find "$APP" -name '._*' -delete 2>/dev/null || true
  find "$APP" -name '.DS_Store' -delete 2>/dev/null || true
  xattr -cr "$APP" 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true

  if ! codesign --force --deep -s - "$APP"; then
    echo "    codesign --force failed (attempt $attempt/5), retrying after 1s" >&2
    sleep 1
    continue
  fi

  # Dechunk FinderInfo again RIGHT before strict verify — this is the race guard.
  xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true

  if codesign --verify --deep --strict "$APP"; then
    CODESIGN_OK=1
    break
  fi
  echo "    strict verify failed (attempt $attempt/5), retrying after 1s" >&2
  sleep 1
done

if [[ "$CODESIGN_OK" -ne 1 ]]; then
  echo "build-app: codesign failed strict verify after 5 attempts (iCloud/fileprovider FinderInfo race)" >&2
  exit 1
fi
{ codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 || true; } | sed 's/^/    /'

echo ""
echo "Built: $APP"
echo "  CFBundleIdentifier: $(plutil -extract CFBundleIdentifier raw -o - "$PLIST")"
echo "  CFBundleExecutable: $(plutil -extract CFBundleExecutable raw -o - "$PLIST")"
echo "  Version:            $(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
echo "  Architectures:      $(lipo -archs "$MACOS/$APP_NAME")"
echo "  Icon:               $RES/AppIcon.icns"
