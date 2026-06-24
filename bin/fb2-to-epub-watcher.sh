#!/bin/bash
# Watches ~/Desktop/fb2-to-epub. For each top-level entry:
#   - .fb2 / .fb2.zip file  -> sibling .epub
#   - folder                -> sibling "<name>-epub" with mirrored tree of .epub files
#
# Cover handling:
#   - If FB2 has an embedded cover, Calibre keeps it as-is.
#   - Otherwise the cover-finder script searches Google Books for a match.
#   - If nothing is found (or no network), the EPUB is produced without a cover
#     (Calibre's default placeholder is suppressed via --no-default-epub-cover).
#
# Idempotent: skips outputs that are newer than their source.

set -u
set -o pipefail

# WATCH_DIR is supplied by the LaunchAgent (EnvironmentVariables) or the caller's
# environment; it falls back to the historical default when run standalone.
WATCH_DIR="${WATCH_DIR:-$HOME/Desktop/fb2-to-epub}"
LOG_FILE="${FB2_LOG_FILE:-$HOME/Library/Logs/fb2-to-epub.log}"
LOCK_DIR="/tmp/fb2-to-epub.lock.d"
EBOOK_CONVERT="${EBOOK_CONVERT:-/Applications/calibre.app/Contents/MacOS/ebook-convert}"

# python3 absolute path: env override (set by installer) -> common locations ->
# bare-PATH lookup. The agent starts with PATH=/usr/bin:/bin so we never rely on
# a login shell having resolved a custom interpreter.
PYTHON3="${PYTHON3:-}"
if [[ -z "$PYTHON3" || ! -x "$PYTHON3" ]]; then
  for cand in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [[ -x "$cand" ]]; then PYTHON3="$cand"; break; fi
  done
fi
[[ -z "$PYTHON3" || ! -x "$PYTHON3" ]] && PYTHON3="$(command -v python3 2>/dev/null || true)"

# cover-finder lives next to this script; allow an env override for installs that
# relocate the bundle.
COVER_FINDER="${COVER_FINDER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fb2-to-epub-cover-finder.py}"

mkdir -p "$WATCH_DIR" "$(dirname "$LOG_FILE")"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "another run in progress; exiting"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

if [[ ! -x "$EBOOK_CONVERT" ]]; then
  log "ebook-convert not found at $EBOOK_CONVERT"
  exit 1
fi

log "=== run start ==="

epub_name() {
  local name="$1" lower
  lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.fb2.zip) printf '%s' "${name%.[fF][bB]2.[zZ][iI][pP]}.epub" ;;
    *.fb2)     printf '%s' "${name%.[fF][bB]2}.epub" ;;
    *)         printf '' ;;
  esac
}

convert_book() {
  local src="$1" dst="$2"
  if [[ -e "$dst" ]] && [[ "$dst" -nt "$src" ]]; then
    log "skip (up-to-date): ${dst#$WATCH_DIR/}"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"

  local cover_args=("--no-default-epub-cover")
  local cover_tmp_dir cover_tmp rc
  cover_tmp_dir="$(mktemp -d -t fb2cover)"
  cover_tmp="$cover_tmp_dir/cover.jpg"

  if [[ -x "$COVER_FINDER" && -n "$PYTHON3" ]]; then
    rc=0
    "$PYTHON3" "$COVER_FINDER" "$src" "$cover_tmp" >/dev/null 2>>"$LOG_FILE" || rc=$?
    case $rc in
      0) cover_args=(--cover "$cover_tmp" --no-default-epub-cover)
         log "cover (online): ${src#$WATCH_DIR/}" ;;
      3) log "cover (embedded): ${src#$WATCH_DIR/}" ;;
      *) log "cover (none):    ${src#$WATCH_DIR/}" ;;
    esac
  fi

  log "convert: ${src#$WATCH_DIR/}"
  if "$EBOOK_CONVERT" "$src" "$dst" "${cover_args[@]}" >>"$LOG_FILE" 2>&1; then
    log "ok:      ${dst#$WATCH_DIR/}"
  else
    log "FAIL:    ${src#$WATCH_DIR/}"
    rm -f "$dst" 2>/dev/null || true
  fi

  rm -rf "$cover_tmp_dir"
}

process_folder_tree() {
  local src_root="$1" mirror_root="$2"
  mkdir -p "$mirror_root"
  find "$src_root" -type f \( -iname '*.fb2' -o -iname '*.fb2.zip' \) -print0 \
    | while IFS= read -r -d '' f; do
        local rel base out_name out_path dir_part
        rel="${f#$src_root/}"
        base="${rel##*/}"
        out_name="$(epub_name "$base")"
        [[ -z "$out_name" ]] && continue
        if [[ "$rel" == */* ]]; then
          dir_part="${rel%/*}"
          out_path="$mirror_root/$dir_part/$out_name"
        else
          out_path="$mirror_root/$out_name"
        fi
        convert_book "$f" "$out_path"
      done
}

shopt -s nullglob dotglob
for entry in "$WATCH_DIR"/*; do
  name="${entry##*/}"
  case "$name" in
    .DS_Store|.localized) continue ;;
  esac
  if [[ -f "$entry" ]]; then
    out_name="$(epub_name "$name")"
    [[ -z "$out_name" ]] && continue
    convert_book "$entry" "$WATCH_DIR/$out_name"
  elif [[ -d "$entry" ]]; then
    case "$name" in
      *-epub) continue ;;
    esac
    process_folder_tree "$entry" "$WATCH_DIR/${name}-epub"
  fi
done

log "=== run end ==="
