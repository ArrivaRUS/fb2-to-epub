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

# UI state snapshot (read by the SwiftUI app). The watcher OWNS these files; the
# app only reads them. STATE_FILE is rewritten atomically (tmp -> mv) after every
# conversion so a reader never sees a half-written JSON. EVENTS_FILE is an
# append-only journal for diagnostics / rebuilding. Schema: see arch/plans-ui.md.
STATE_DIR="${FB2_STATE_DIR:-$HOME/Library/Application Support/fb2-to-epub/state}"
STATE_FILE="$STATE_DIR/state.json"
EVENTS_FILE="$STATE_DIR/events.jsonl"
STATE_SCHEMA=1
STATE_RECENT_MAX=50

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

mkdir -p "$WATCH_DIR" "$(dirname "$LOG_FILE")" "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# --- UI state writers ------------------------------------------------------
# Both writers are best-effort: a failure here must NEVER abort a conversion, so
# every call is guarded and errors are swallowed (logged at most). They delegate
# JSON encoding to python3 (already resolved above) — bash string-building can't
# safely escape unicode filenames / quotes / control chars.

# One conversion event -> {src,dst,ts,status}. Appended to events.jsonl AND fed
# into the rolling recent[] of state.json. status is "ok" or "failed".
# Args: <src_abs> <dst_abs> <status>
record_conversion() {
  local src="$1" dst="$2" status="$3"
  [[ -z "$PYTHON3" || ! -x "$PYTHON3" ]] && return 0

  STATE_DIR="$STATE_DIR" STATE_FILE="$STATE_FILE" EVENTS_FILE="$EVENTS_FILE" \
  WATCH_DIR="$WATCH_DIR" STATE_SCHEMA="$STATE_SCHEMA" STATE_RECENT_MAX="$STATE_RECENT_MAX" \
  EV_SRC="$src" EV_DST="$dst" EV_STATUS="$status" \
  "$PYTHON3" - <<'PY' 2>>"$LOG_FILE" || return 0
import json, os, sys, time
from datetime import datetime, timezone

state_dir   = os.environ["STATE_DIR"]
state_file  = os.environ["STATE_FILE"]
events_file = os.environ["EVENTS_FILE"]
watch_dir   = os.environ["WATCH_DIR"]
schema      = int(os.environ["STATE_SCHEMA"])
recent_max  = int(os.environ["STATE_RECENT_MAX"])

src    = os.environ["EV_SRC"]
dst    = os.environ["EV_DST"]
status = os.environ["EV_STATUS"]

# ISO-8601 UTC with trailing Z (what the Swift side parses).
ts = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def basename(p):
    return os.path.basename(p) if p else ""

event = {"src": basename(src), "dst": basename(dst), "ts": ts, "status": status}

# Append-only journal first (raw line).
try:
    with open(events_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")
except Exception as e:
    print(f"[state] events append failed: {e}", file=sys.stderr)

# Load (or seed) the snapshot, then mutate.
try:
    with open(state_file, "r", encoding="utf-8") as f:
        state = json.load(f)
    if not isinstance(state, dict):
        raise ValueError("state.json is not an object")
except Exception:
    state = {}

state["schema"] = schema
state.setdefault("agent", {})
state["agent"]["watch_dir"] = watch_dir

totals = state.get("totals")
if not isinstance(totals, dict):
    totals = {}
totals.setdefault("converted_total", 0)
totals.setdefault("today", 0)
totals.setdefault("failed_today", 0)

recent = state.get("recent")
if not isinstance(recent, list):
    recent = []

# "today" / "failed_today" are day-scoped. Reset the day counters when the last
# recorded conversion fell on a previous local day.
today_str = datetime.now().strftime("%Y-%m-%d")
if state.get("_today_date") != today_str:
    totals["today"] = 0
    totals["failed_today"] = 0
    state["_today_date"] = today_str

if status == "ok":
    totals["converted_total"] = int(totals.get("converted_total", 0)) + 1
    totals["today"] = int(totals.get("today", 0)) + 1
else:
    totals["failed_today"] = int(totals.get("failed_today", 0)) + 1

# Newest first, capped.
recent.insert(0, event)
del recent[recent_max:]

state["totals"] = totals
state["recent"] = recent
state["last_conversion"] = event

# Atomic publish: write a sibling tmp in the SAME dir, fsync, then rename over.
tmp = state_file + ".tmp"
try:
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, separators=(",", ":"))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, state_file)
except Exception as e:
    print(f"[state] atomic write failed: {e}", file=sys.stderr)
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.exit(1)
PY
}

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
    record_conversion "$src" "$dst" "ok"
  else
    log "FAIL:    ${src#$WATCH_DIR/}"
    rm -f "$dst" 2>/dev/null || true
    record_conversion "$src" "$dst" "failed"
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
