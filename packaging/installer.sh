#!/bin/bash
# fb2-to-epub installer (all install logic lives here).
#
# Responsibilities:
#   - detect Calibre (ebook-convert) and python3 (clear message if missing)
#   - accept a WATCH_DIR (arg or env); create it if absent
#   - copy watcher + cover-finder + runner into App Support/bin
#   - generate the LaunchAgent plist via `plutil` (NOT sed) so arbitrary paths
#     with spaces / unicode are encoded safely
#   - (re)load the agent idempotently: bootout -> bootstrap -> enable -> kickstart
#   - print Full Disk Access guidance when WATCH_DIR is in a TCC-protected zone
#
# Usage:
#   installer.sh ["/path/to/watch folder"]
#   WATCH_DIR="/path/to/folder" installer.sh
# Default WATCH_DIR: ~/Desktop/fb2-to-epub
#
# Invoked both by the .app applet (do shell script) and by the advanced CLI
# install.sh. Idempotent: re-running re-points the agent without leaving dupes.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
LABEL="com.arrivarus.fb2toepub.agent"
APP_SUPPORT="$HOME/Library/Application Support/fb2-to-epub"
BIN_DIR="$APP_SUPPORT/bin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/fb2-to-epub.log"
AGENT_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

RUNNER_DST="$BIN_DIR/fb2-to-epub-runner.sh"
WATCHER_DST="$BIN_DIR/fb2-to-epub-watcher.sh"
COVER_DST="$BIN_DIR/fb2-to-epub-cover-finder.py"

# Resolve where our source scripts are. Search order:
#   1) FB2_SRC_DIR override (used by build/tests)
#   2) a sibling layout when run from a checkout (packaging/.. -> bin/, packaging/)
#   3) the same directory as this installer (the .app Resources layout)
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
find_src() {
  local name="$1"
  local c
  for c in \
    "${FB2_SRC_DIR:-}/$name" \
    "$SELF_DIR/$name" \
    "$SELF_DIR/../bin/$name" \
    "$SELF_DIR/bin/$name"; do
    [[ -n "$c" && -f "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# 1. Detect Calibre + python3
# ---------------------------------------------------------------------------
CALIBRE_MACOS_DEFAULT="/Applications/calibre.app/Contents/MacOS"
EBOOK_CONVERT_DEFAULT="$CALIBRE_MACOS_DEFAULT/ebook-convert"
EBOOK_CONVERT="${EBOOK_CONVERT:-$EBOOK_CONVERT_DEFAULT}"
if [[ ! -x "$EBOOK_CONVERT" ]]; then
  cat >&2 <<EOF
fb2-to-epub: Calibre not found.

Expected: $EBOOK_CONVERT_DEFAULT

Install Calibre first:
  - Download: https://calibre-ebook.com/download_osx
  - or:       brew install --cask calibre

Then run this installer again.
EOF
  exit 1
fi

# ebook-meta + ebook-polish live next to ebook-convert. The watcher/finder use
# ebook-meta (metadata + embedded-cover detection); the agent uses ebook-polish
# to apply a chosen cover (M5). Resolve them from the same Calibre MacOS dir and
# verify all three so a partial/old Calibre is caught up front.
CALIBRE_MACOS_DIR="$(cd "$(dirname "$EBOOK_CONVERT")" && pwd)"
EBOOK_META="${EBOOK_META:-$CALIBRE_MACOS_DIR/ebook-meta}"
EBOOK_POLISH="${EBOOK_POLISH:-$CALIBRE_MACOS_DIR/ebook-polish}"

missing=()
[[ -x "$EBOOK_META" ]]   || missing+=("ebook-meta   ($EBOOK_META)")
[[ -x "$EBOOK_POLISH" ]] || missing+=("ebook-polish ($EBOOK_POLISH)")
if [[ ${#missing[@]} -gt 0 ]]; then
  {
    echo "fb2-to-epub: Calibre is installed but some required tools are missing:"
    echo
    for m in "${missing[@]}"; do echo "  - $m"; done
    echo
    echo "These ship with a normal Calibre install. Update Calibre, then re-run:"
    echo "  - Download: https://calibre-ebook.com/download_osx"
    echo "  - or:       brew upgrade --cask calibre"
  } >&2
  exit 1
fi

detect_python3() {
  local cand
  for cand in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [[ -x "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  cand="$(command -v python3 2>/dev/null || true)"
  [[ -n "$cand" ]] && { printf '%s' "$cand"; return 0; }
  return 1
}
if ! PYTHON3="$(detect_python3)"; then
  cat >&2 <<EOF
fb2-to-epub: python3 not found.

Install the Xcode Command Line Tools (provides /usr/bin/python3):
  xcode-select --install

Then run this installer again.
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Resolve WATCH_DIR
# ---------------------------------------------------------------------------
WATCH_DIR="${1:-${WATCH_DIR:-$HOME/Desktop/fb2-to-epub}}"
# Normalize a literal leading tilde from user input (it would not expand inside
# the quoted arg/env). We match the literal '~' on purpose, then expand via HOME.
# shellcheck disable=SC2088
case "$WATCH_DIR" in
  "~"|"~/"*) WATCH_DIR="$HOME/${WATCH_DIR#\~/}" ;;
esac
mkdir -p "$WATCH_DIR"
WATCH_DIR="$(cd "$WATCH_DIR" && pwd)"

# ---------------------------------------------------------------------------
# 3. Copy scripts into App Support/bin
# ---------------------------------------------------------------------------
mkdir -p "$BIN_DIR" "$(dirname "$PLIST")" "$(dirname "$LOG_FILE")"

src_runner="$(find_src fb2-to-epub-runner.sh)"   || { echo "fb2-to-epub: missing fb2-to-epub-runner.sh source" >&2; exit 1; }
src_watcher="$(find_src fb2-to-epub-watcher.sh)" || { echo "fb2-to-epub: missing fb2-to-epub-watcher.sh source" >&2; exit 1; }
src_cover="$(find_src fb2-to-epub-cover-finder.py)" || { echo "fb2-to-epub: missing fb2-to-epub-cover-finder.py source" >&2; exit 1; }

install -m 0755 "$src_runner"  "$RUNNER_DST"
install -m 0755 "$src_watcher" "$WATCHER_DST"
install -m 0755 "$src_cover"   "$COVER_DST"

# ---------------------------------------------------------------------------
# 4. Generate the LaunchAgent plist via plutil (safe for spaces/unicode)
#    Build a minimal valid skeleton, then insert/replace typed values whose
#    contents are passed as separate argv -> never spliced into XML.
# ---------------------------------------------------------------------------
gen_plist() {
  local out="$1"
  # Minimal valid empty-dict plist to seed plutil edits.
  cat > "$out" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST

  plutil -replace Label -string "$LABEL" "$out"

  # ProgramArguments -> [ runner ]
  plutil -replace ProgramArguments -json '[]' "$out"
  plutil -insert  ProgramArguments.0 -string "$RUNNER_DST" "$out"

  # WatchPaths -> [ WATCH_DIR ]
  plutil -replace WatchPaths -json '[]' "$out"
  plutil -insert  WatchPaths.0 -string "$WATCH_DIR" "$out"

  # EnvironmentVariables -> { WATCH_DIR, PATH, EBOOK_CONVERT, EBOOK_META,
  #                           EBOOK_POLISH, PYTHON3 }
  plutil -replace EnvironmentVariables -json '{}' "$out"
  plutil -insert  EnvironmentVariables.WATCH_DIR     -string "$WATCH_DIR"     "$out"
  plutil -insert  EnvironmentVariables.PATH          -string "$AGENT_PATH"    "$out"
  plutil -insert  EnvironmentVariables.EBOOK_CONVERT -string "$EBOOK_CONVERT" "$out"
  plutil -insert  EnvironmentVariables.EBOOK_META    -string "$EBOOK_META"    "$out"
  plutil -insert  EnvironmentVariables.EBOOK_POLISH  -string "$EBOOK_POLISH"  "$out"
  plutil -insert  EnvironmentVariables.PYTHON3       -string "$PYTHON3"       "$out"

  plutil -replace RunAtLoad       -bool true "$out"
  plutil -replace ThrottleInterval -integer 5 "$out"
  plutil -replace StandardOutPath  -string "$LOG_FILE" "$out"
  plutil -replace StandardErrorPath -string "$LOG_FILE" "$out"

  # Final sanity: must be a valid plist.
  plutil -lint "$out" >/dev/null
}

# Generate into a temp file, then atomically move it into place. mktemp gives a
# bare name; appending .plist keeps `plutil` happy without orphaning the base
# file. The trap cleans up the temp on any early exit (set -e).
tmp_plist_base="$(mktemp -t fb2plist)"
tmp_plist="$tmp_plist_base.plist"
trap 'rm -f "$tmp_plist_base" "$tmp_plist"' EXIT
gen_plist "$tmp_plist"
mv -f "$tmp_plist" "$PLIST"
rm -f "$tmp_plist_base"
trap - EXIT

# ---------------------------------------------------------------------------
# 5. (Re)load the agent idempotently
# ---------------------------------------------------------------------------
domain="gui/$(id -u)"
# bootout is best-effort (agent may not be loaded yet); ignore its failure.
launchctl bootout "$domain/$LABEL" 2>/dev/null || true
launchctl bootstrap "$domain" "$PLIST"
launchctl enable "$domain/$LABEL" 2>/dev/null || true
launchctl kickstart -k "$domain/$LABEL" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Full Disk Access guidance for TCC-protected zones
# ---------------------------------------------------------------------------
needs_fda=0
case "$WATCH_DIR/" in
  "$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Downloads/"*) needs_fda=1 ;;
esac

cat <<EOF
fb2-to-epub installed.

  Watch folder: $WATCH_DIR
  Agent label:  $LABEL
  Runner:       $RUNNER_DST
  LaunchAgent:  $PLIST
  Log:          $LOG_FILE

Drop .fb2 / .fb2.zip files (or folders of them) into the watch folder.
EOF

if [[ "$needs_fda" -eq 1 ]]; then
  cat <<EOF

NOTE: Your watch folder is inside a macOS-protected location. If conversions do
not start, grant Full Disk Access to the runner:

  System Settings -> Privacy & Security -> Full Disk Access -> "+"
  Add: $RUNNER_DST
  (press Cmd-Shift-G in the picker and paste the path above)

Then toggle it on. The grant is keyed to that file and persists across updates.
EOF
fi
