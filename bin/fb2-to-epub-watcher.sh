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

# Где движок (CAL-1, инвариант 5). Под launchd все пути приходят из plist
# (EnvironmentVariables), так что ЭТО — путь ручного запуска. Цепочка совпадает
# с контрактом детекта: наша папка → /Applications → ~/Applications; побеждает
# первая ПОЛНАЯ установка (все три CLI). Не нашли ничего — исторический
# /Applications, чтобы сообщение об ошибке осталось прежним.
if [[ -n "${CALIBRE_MACOS_DIR:-}" ]]; then
  # Агент передал единый источник правды (installer.sh §4) — уважаем его.
  CALIBRE_MACOS_FALLBACK="$CALIBRE_MACOS_DIR"
else
  CALIBRE_MACOS_FALLBACK="/Applications/calibre.app/Contents/MacOS"
  for _cand in "$HOME/Library/Application Support/fb2-to-epub/calibre.app/Contents/MacOS" \
               "/Applications/calibre.app/Contents/MacOS" \
               "$HOME/Applications/calibre.app/Contents/MacOS"; do
    if [[ -x "$_cand/ebook-convert" && -x "$_cand/ebook-meta" && -x "$_cand/ebook-polish" ]]; then
      CALIBRE_MACOS_FALLBACK="$_cand"
      break
    fi
  done
  unset _cand
fi

EBOOK_CONVERT="${EBOOK_CONVERT:-$CALIBRE_MACOS_FALLBACK/ebook-convert}"

# UI state snapshot (read by the SwiftUI app). The watcher OWNS these files; the
# app only reads them. STATE_FILE is rewritten atomically (tmp -> mv) after every
# conversion so a reader never sees a half-written JSON. EVENTS_FILE is an
# append-only journal for diagnostics / rebuilding. Schema: see arch/plans-ui.md.
STATE_DIR="${FB2_STATE_DIR:-$HOME/Library/Application Support/fb2-to-epub/state}"
STATE_FILE="$STATE_DIR/state.json"
EVENTS_FILE="$STATE_DIR/events.jsonl"
STATE_SCHEMA=1
STATE_RECENT_MAX=50

# Cover-selection queue (read by the SwiftUI app, written here). When a book has
# no embedded cover and the finder returns 2+ candidates, we apply the best one
# immediately (non-blocking) AND drop a queue entry so the user can later pick a
# different one (M5). Layout/schema: see arch/plans-ui.md.
COVERS_DIR="${FB2_COVERS_DIR:-$HOME/Library/Application Support/fb2-to-epub/covers}"
COVERS_QUEUE_DIR="$COVERS_DIR/queue"
COVERS_PREVIEWS_DIR="$COVERS_DIR/previews"
COVERS_JOBS_DIR="$COVERS_DIR/jobs"

# ebook-meta is used by the finder for embedded-cover detection / metadata; the
# watcher itself only needs ebook-convert, but we resolve EBOOK_META here so the
# plist/installer can supply it (and M5's ebook-polish path stays consistent).
# export: cover-finder.py читает EBOOK_META из окружения (CAL-1 §1.7). Под
# launchd переменная уже экспортирована из plist; export закрывает и ручной запуск.
export EBOOK_META="${EBOOK_META:-$CALIBRE_MACOS_FALLBACK/ebook-meta}"

# ebook-polish applies a user-chosen cover into an existing EPUB (M5 apply-job).
# Only the agent (this watcher, under its Full Disk Access) ever rewrites EPUBs;
# the app just drops a job. Resolve from the same Calibre MacOS dir.
EBOOK_POLISH="${EBOOK_POLISH:-$CALIBRE_MACOS_FALLBACK/ebook-polish}"

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

# fb3-transform lives next to this script too (FB3 -> FB2, stdlib python3). Same
# env-override-then-sibling resolution as COVER_FINDER. The genre-map JSON sits
# beside the transform; we pass it explicitly (dirname of the transform) so a
# relocated bundle still finds it. Both are bundled/installed together with the
# other bin scripts (see build-app.sh / installer.sh).
FB3_TRANSFORM="${FB3_TRANSFORM:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fb2-to-epub-fb3.py}"

mkdir -p "$WATCH_DIR" "$(dirname "$LOG_FILE")" "$STATE_DIR" \
         "$COVERS_QUEUE_DIR" "$COVERS_PREVIEWS_DIR" "$COVERS_JOBS_DIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# Stable book id derived from the final epub path (survives re-runs of the same
# book; distinct books get distinct ids). Used as the queue/previews key so the
# finder and the watcher agree on where previews live. Hex digest, no slashes.
book_id_for() {
  local p="$1"
  printf '%s' "$p" | shasum -a 256 2>/dev/null | cut -c1-16 \
    || printf '%s' "$p" | cksum | tr -d ' \t' | cut -c1-16
}

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

# --- batch progress (ring) -------------------------------------------------
# Additive top-level field state.json["batch"] = {active, total, done} drives the
# app's animated progress ring. The app treats a MISSING batch field as "no
# active batch". Best-effort (like every state writer): a failure must never
# abort a conversion. Goes through the SAME atomic tmp->os.replace publish as
# record_conversion, reusing the existing state, so it composes with the
# per-conversion writes that happen between begin/tick/end.
#
# Modes (arg 1):
#   begin <total>  -> {active:true, total:<total>, done:0}
#   tick           -> if active: done = min(done+1, total)   (subshell-safe: the
#                     counter lives in state.json, not a bash variable that a
#                     piped `while` subshell would lose)
#   end            -> active=false; total/done LEFT AS IS (ring shows 100% and
#                     stays filled until the next batch begins)
batch_state() {
  local mode="$1" total_arg="${2:-0}"
  [[ -z "$PYTHON3" || ! -x "$PYTHON3" ]] && return 0

  STATE_FILE="$STATE_FILE" BATCH_MODE="$mode" BATCH_TOTAL="$total_arg" \
  "$PYTHON3" - <<'PY' 2>>"$LOG_FILE" || return 0
import json, os, sys

state_file = os.environ["STATE_FILE"]
mode       = os.environ["BATCH_MODE"]
total_arg  = int(os.environ.get("BATCH_TOTAL") or 0)

# Load the existing snapshot so we extend it rather than clobber other fields.
try:
    with open(state_file, "r", encoding="utf-8") as f:
        state = json.load(f)
    if not isinstance(state, dict):
        raise ValueError("state.json is not an object")
except Exception:
    state = {}

batch = state.get("batch")
if not isinstance(batch, dict):
    batch = {"active": False, "total": 0, "done": 0}

if mode == "begin":
    # "Sticky" batch: one logical batch of N files triggers SEVERAL launchd fires
    # (cover apply-jobs land in WatchPaths covers/jobs; each .epub written into the
    # watch dir is itself a WatchPaths change). Each fire recomputes pending =
    # count_pending() = the REMAINING unconverted count. The old code did an
    # UNCONDITIONAL begin -> {active,total=pending,done=0}, so a fire LANDING MID-
    # BATCH reset {total:15,done:4} to {total:11,done:0} and the ring restarted
    # from the remainder. Decide continuation vs new batch from the on-disk batch.
    prev_active = bool(batch.get("active"))
    prev_total  = int(batch.get("total", 0) or 0)
    prev_done   = int(batch.get("done", 0) or 0)
    # Stale-state edge: a batch left active whose done already reached total means
    # the previous batch finished (or the session died before `end`); a fresh
    # pending count is a genuinely NEW batch -> start clean.
    if not prev_active or (prev_total > 0 and prev_done >= prev_total):
        batch = {"active": True, "total": total_arg, "done": 0}
    else:
        # Continuation. Reconcile total against (done + remaining) WITHOUT ever
        # rewinding done or shrinking below what we've already shown.
        projected = prev_done + total_arg
        if projected > prev_total:
            # New files dropped mid-batch -> grow total, keep done.
            new_total = projected
        else:
            # projected == prev_total -> exactly the current batch's remainder.
            # projected <  prev_total -> some pending vanished/changed; hold total
            # conservatively rather than shrink the ring. Either way keep total.
            new_total = prev_total
        batch = {"active": True, "total": new_total, "done": prev_done}
elif mode == "tick":
    # Only advance an active batch; cap at total so the ring never exceeds 100%.
    if batch.get("active"):
        total = int(batch.get("total", 0) or 0)
        done  = int(batch.get("done", 0) or 0) + 1
        if total > 0 and done > total:
            done = total
        batch["done"] = done
elif mode == "end":
    # Only mark the batch FINISHED when it really is. A fire that merely applied a
    # cover-job and converted nothing must NOT flip a still-running batch to
    # inactive (that would drop the ring mid-progress). Done iff we've ticked the
    # whole total (done >= total) OR nothing was pending this fire (pending==0,
    # nothing left to convert). Otherwise keep active:true so the next fire resumes.
    total   = int(batch.get("total", 0) or 0)
    done    = int(batch.get("done", 0) or 0)
    pending = total_arg
    if (total > 0 and done >= total) or pending == 0:
        batch["active"] = False
    # else: intermediate fire — leave active:true for the next fire to continue.
else:
    # Unknown mode: write nothing rather than corrupt state.
    sys.exit(0)

state["batch"] = batch

# Atomic publish: sibling tmp in the SAME dir, fsync, rename over.
tmp = state_file + ".tmp"
try:
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, separators=(",", ":"))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, state_file)
except Exception as e:
    print(f"[batch] atomic write failed: {e}", file=sys.stderr)
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.exit(1)
PY
}

# Cheap PRE-count of files that WOULD be converted this run = batch total. Mirrors
# the main loop's discovery + convert_book's up-to-date skip EXACTLY (top-level
# .fb2/.fb2.zip files -> sibling .epub; folders -> mirrored "<name>-epub" tree),
# but only stat()s instead of converting. A file is "pending" if its output is
# missing OR not newer than the source (same test as `[[ "$dst" -nt "$src" ]]`).
# Prints a single integer.
count_pending() {
  local n=0
  shopt -s nullglob dotglob
  local entry name out_name
  for entry in "$WATCH_DIR"/*; do
    name="${entry##*/}"
    case "$name" in
      .DS_Store|.localized) continue ;;
    esac
    if [[ -f "$entry" ]]; then
      out_name="$(epub_name "$name")"
      [[ -z "$out_name" ]] && continue
      local dst="$WATCH_DIR/$out_name"
      if [[ ! -e "$dst" ]] || [[ ! "$dst" -nt "$entry" ]]; then
        n=$((n + 1))
      fi
    elif [[ -d "$entry" ]]; then
      case "$name" in
        *-epub) continue ;;
      esac
      local mirror_root="$WATCH_DIR/${name}-epub" f rel base fout dir_part out_path
      while IFS= read -r -d '' f; do
        rel="${f#$entry/}"
        base="${rel##*/}"
        fout="$(epub_name "$base")"
        [[ -z "$fout" ]] && continue
        if [[ "$rel" == */* ]]; then
          dir_part="${rel%/*}"
          out_path="$mirror_root/$dir_part/$fout"
        else
          out_path="$mirror_root/$fout"
        fi
        if [[ ! -e "$out_path" ]] || [[ ! "$out_path" -nt "$f" ]]; then
          n=$((n + 1))
        fi
      done < <(find "$entry" -type f \( -iname '*.fb2' -o -iname '*.fb2.zip' -o -iname '*.fb3' \) -print0)
    fi
  done
  printf '%s' "$n"
}

# --- cover queue helpers ---------------------------------------------------
# Both delegate JSON work to python3 (bash can't parse JSON safely). Best-effort:
# a failure must never abort a conversion.

# Read the finder's --json output (file) and print three shell-safe lines meant
# to be consumed via `eval`:
#   cand_count=<N>
#   best_preview=<abs path or empty>
#   confident=<0|1>
# best_preview is the preview of best_candidate_id (the top TITLE-MATCH candidate)
# and is EMPTY when the finder set best_candidate_id=null (no candidate's caption
# matched the book title) — so the watcher won't auto-embed a wrong cover. We do
# NOT fall back to cands[0] anymore: a null best means "not confident, leave the
# choice to the user". confident mirrors the finder's flag (legacy outputs that
# predate the flag are treated as confident iff a best_preview resolved). Prints
# cand_count=0 / confident=0 on error.
cover_json_summary() {
  local json_file="$1"
  [[ -z "$PYTHON3" || ! -x "$PYTHON3" ]] && { printf 'cand_count=0\nbest_preview=\nconfident=0\n'; return 0; }
  CJ_FILE="$json_file" "$PYTHON3" - <<'PY' 2>>"$LOG_FILE" || printf 'cand_count=0\nbest_preview=\nconfident=0\n'
import json, os, sys, shlex
try:
    with open(os.environ["CJ_FILE"], "r", encoding="utf-8") as f:
        d = json.load(f)
    cands = d.get("candidates") or []
    best_id = d.get("best_candidate_id")
    best = ""
    if best_id:
        for c in cands:
            if c.get("id") == best_id:
                best = c.get("preview_path") or ""
                break
    # confident: prefer the finder's explicit flag; if the field is absent
    # (older finder), fall back to "we resolved a best preview".
    if "confident" in d:
        confident = 1 if d.get("confident") else 0
    else:
        confident = 1 if best else 0
    # shlex.quote keeps a path with spaces/unicode safe for `eval`.
    print(f"cand_count={len(cands)}")
    print(f"best_preview={shlex.quote(best)}")
    print(f"confident={confident}")
except Exception as e:
    print(f"[queue] summary failed: {e}", file=sys.stderr)
    print("cand_count=0")
    print("best_preview=")
    print("confident=0")
PY
}

# Write covers/queue/<book_id>.json atomically (tmp -> rename), merging the
# finder's candidates with the conversion facts (epub_path/src/title/author/ts).
# Args: <book_id> <json_file> <epub_path> <src_file> <status>
write_queue_entry() {
  local book_id="$1" json_file="$2" epub_path="$3" src_file="$4" status="$5"
  [[ -z "$PYTHON3" || ! -x "$PYTHON3" ]] && return 0
  mkdir -p "$COVERS_QUEUE_DIR" 2>/dev/null || true

  QE_BOOK_ID="$book_id" QE_JSON="$json_file" QE_EPUB="$epub_path" \
  QE_SRC="$src_file" QE_STATUS="$status" QE_QUEUE_DIR="$COVERS_QUEUE_DIR" \
  "$PYTHON3" - <<'PY' 2>>"$LOG_FILE" || return 0
import json, os, sys
from datetime import datetime, timezone

book_id = os.environ["QE_BOOK_ID"]
status  = os.environ["QE_STATUS"]
qdir    = os.environ["QE_QUEUE_DIR"]

try:
    with open(os.environ["QE_JSON"], "r", encoding="utf-8") as f:
        finder = json.load(f)
except Exception as e:
    print(f"[queue] cannot read finder json: {e}", file=sys.stderr)
    sys.exit(1)

ts = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

# confident: carry the finder's title-match verdict into the queue so the app
# knows nothing was auto-embedded (best_candidate_id is null) and can lead with
# the generated fallbacks. Fall back to "a best id resolved" for older finders.
confident = finder.get("confident")
if confident is None:
    confident = bool(finder.get("best_candidate_id"))

entry = {
    "book_id":           book_id,
    "epub_path":         os.environ["QE_EPUB"],
    "title":             finder.get("title"),
    "author":            finder.get("author"),
    "src_file":          os.environ["QE_SRC"],
    "status":            status,
    "candidates":        finder.get("candidates") or [],
    "best_candidate_id": finder.get("best_candidate_id"),
    "confident":         bool(confident),
    "ts":                ts,
}

dst = os.path.join(qdir, f"{book_id}.json")
tmp = dst + ".tmp"
try:
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(entry, f, ensure_ascii=False, separators=(",", ":"))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, dst)
except Exception as e:
    print(f"[queue] atomic write failed: {e}", file=sys.stderr)
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.exit(1)
PY
}

# --- cover apply-jobs (M5) -------------------------------------------------
# The app writes covers/jobs/<job_id>.json = {book_id, chosen_candidate_id|"skip", ts}
# atomically. When the agent fires (covers/jobs is in WatchPaths + a kickstart),
# we drain those jobs HERE — under the agent's Full Disk Access — applying the
# chosen cover to the already-produced EPUB via ebook-polish. The app never
# touches the EPUB. Best-effort: a failure must never abort the rest of the run.

# Print one base64-encoded plan line per job (NUL-free, space/unicode safe). The
# FIRST field is an action token so the bash loop dispatches without re-parsing.
# Every line carries EIGHT base64 fields; the last two (edited title/author) are
# the v0.9.7 additions and are EMPTY for jobs that predate them (back-compat):
#   apply   <job> <book_id> <epub_path> <chosen>  <preview>  <etitle> <eauthor>
#   gen     <job> <book_id> <epub_path> <png>     <"">       <etitle> <eauthor>
#   confirm <job> <book_id> <epub_path> <"">      <"">       <etitle> <eauthor>
# - apply:   the original M5 chosen-cover path. chosen is "skip" or a candidate id;
#   preview is the local preview of that candidate (empty for skip / not found).
# - gen:     action=="apply_generated" — the app pre-rendered a fallback cover PNG;
#   we vend it the SAME way as a web cover (ebook-polish --cover <png>). The png
#   path comes straight from the job; the 5th field is unused (kept for symmetry).
# - confirm: action=="apply_confirm" (v0.9.7) — the auto/embedded cover is already
#   correct; the agent does NOT touch the cover. If edited title/author are present
#   it rewrites metadata (ebook-meta) on a temp copy; otherwise it merely resolves
#   the queue card. arg1/arg2 unused (kept for a uniform 8-field line).
# edited_title/edited_author (fields 7-8) are the OPTIONAL user-corrected metadata,
# present on ANY action ONLY when the user actually changed the value; when absent
# they encode as "" and the agent behaves exactly as before these fields existed.
# They ride base64 the SAME way as the research `query` — no eval, no interpolation
# (R1: injection is constructively impossible).
# "research" jobs are drained by a separate pass; ignored (and never deleted) here.
cover_jobs_plan() {
  [[ -z "$PYTHON3" || ! -x "$PYTHON3" ]] && return 0
  [[ -d "$COVERS_JOBS_DIR" ]] || return 0
  CJP_JOBS_DIR="$COVERS_JOBS_DIR" CJP_QUEUE_DIR="$COVERS_QUEUE_DIR" \
  "$PYTHON3" - <<'PY' 2>>"$LOG_FILE"
import base64, glob, json, os, sys

jobs_dir  = os.environ["CJP_JOBS_DIR"]
queue_dir = os.environ["CJP_QUEUE_DIR"]

def b64(s):
    return base64.b64encode((s or "").encode("utf-8")).decode("ascii")

# Positional plan fields are space-separated and read back with `read -r` (default
# IFS): a run of spaces collapses, so an EMPTY middle field would shift every field
# after it. base64 never emits a bare "-", so we use "-" as an explicit EMPTY
# sentinel for any value field that could be blank (epub_path when the queue entry
# is gone, arg1/arg2 on actions that don't use them, an un-edited title/author).
# The bash reader maps "-" back to "" before decoding. This keeps every line at a
# fixed 8 fields regardless of which values are empty.
def slot(s):
    v = b64(s)
    return v if v else "-"

def edited(job):
    # The optional user-corrected metadata. Present ONLY when the app decided the
    # value truly changed (trimmed, non-empty, differs from the original); we still
    # defensively trim and drop non-strings so a malformed job can't inject a flag.
    # Returns (title_slot, author_slot) — "-" when the field is absent/blank/non-str.
    t = job.get("edited_title")
    a = job.get("edited_author")
    t = t.strip() if isinstance(t, str) else ""
    a = a.strip() if isinstance(a, str) else ""
    return slot(t), slot(a)

for job_file in sorted(glob.glob(os.path.join(jobs_dir, "*.json"))):
    if job_file.endswith(".tmp"):
        continue
    try:
        with open(job_file, "r", encoding="utf-8") as f:
            job = json.load(f)
    except Exception as e:
        print(f"[apply] bad job {job_file}: {e}", file=sys.stderr)
        continue

    action = job.get("action") or ""
    # "research" jobs ("Search more") are drained by a separate pass; ignore them
    # here so the apply loop never touches them (and never deletes them).
    if action == "research":
        continue

    book_id = job.get("book_id") or ""
    if not book_id:
        print(f"[apply] job missing book_id: {job_file}", file=sys.stderr)
        continue

    et, ea = edited(job)

    # epub_path comes from the queue entry for ALL branches; the original fb2 is
    # usually gone by the time the user acts.
    epub_path = ""
    qpath = os.path.join(queue_dir, f"{book_id}.json")
    q = None
    try:
        with open(qpath, "r", encoding="utf-8") as f:
            q = json.load(f)
        epub_path = q.get("epub_path") or ""
    except Exception as e:
        print(f"[apply] no queue entry for {book_id}: {e}", file=sys.stderr)
        # Still emit the job (epub_path empty) so it can be cleared — no retry loop.

    if action == "apply_confirm":
        # v0.9.7 "Утвердить" on an already-correct auto/embedded cover. The agent
        # never touches the cover; it only (optionally) rewrites metadata and then
        # resolves the card. arg1/arg2 empty (no cover to vend) -> "-" sentinels.
        print(" ".join(["confirm", slot(job_file), slot(book_id),
                        slot(epub_path), slot(""), slot(""), et, ea]))
        continue

    if action == "apply_generated":
        # App-generated fallback cover: the PNG already exists on disk.
        png = job.get("png") or ""
        if not png:
            print(f"[apply] apply_generated job missing png: {job_file}", file=sys.stderr)
        print(" ".join(["gen", slot(job_file), slot(book_id),
                        slot(epub_path), slot(png), slot(""), et, ea]))
        continue

    # Default branch: M5 chosen-candidate (or "skip").
    chosen = job.get("chosen_candidate_id") or ""
    if not chosen:
        print(f"[apply] job missing fields: {job_file}", file=sys.stderr)
        continue

    preview = ""
    if q is not None and chosen != "skip":
        for c in (q.get("candidates") or []):
            if c.get("id") == chosen:
                preview = c.get("preview_path") or ""
                break

    print(" ".join(["apply", slot(job_file), slot(book_id),
                    slot(epub_path), slot(chosen), slot(preview), et, ea]))
PY
}

# Update a queue entry's status (resolved|skipped|failed) atomically, then delete
# the job file. Args: <book_id> <new_status> <job_file>
cover_job_resolve() {
  local book_id="$1" new_status="$2" job_file="$3"
  [[ -z "$PYTHON3" || ! -x "$PYTHON3" ]] && { rm -f "$job_file" 2>/dev/null || true; return 0; }
  CJR_BOOK_ID="$book_id" CJR_STATUS="$new_status" CJR_JOB="$job_file" \
  CJR_QUEUE_DIR="$COVERS_QUEUE_DIR" "$PYTHON3" - <<'PY' 2>>"$LOG_FILE"
import json, os, sys

book_id = os.environ["CJR_BOOK_ID"]
status  = os.environ["CJR_STATUS"]
job     = os.environ["CJR_JOB"]
qdir    = os.environ["CJR_QUEUE_DIR"]

qpath = os.path.join(qdir, f"{book_id}.json")
try:
    with open(qpath, "r", encoding="utf-8") as f:
        entry = json.load(f)
    entry["status"] = status
    tmp = qpath + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(entry, f, ensure_ascii=False, separators=(",", ":"))
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp, qpath)
except Exception as e:
    print(f"[apply] could not update queue {book_id}: {e}", file=sys.stderr)

# Always remove the job, even if the queue update failed: keeping it would make
# the agent retry forever on every fire.
try:
    os.unlink(job)
except OSError:
    pass
PY
}

# Rewrite the title/author metadata INSIDE an EPUB via ebook-meta (v0.9.7 edited
# fields). Both values arrive BASE64-ENCODED and are decoded here, then passed as
# an argv VECTOR — never interpolated into a command string — so quotes / $() /
# backticks / ; in a user-edited title or author are inert (R1: shell-injection is
# constructively impossible under the agent's Full Disk Access). This mirrors the
# base64-argv transport the research path already uses for the user's `query`
# (see apply_research_jobs). An EMPTY decoded value means "user did not edit this
# field" -> that --title/--authors flag is OMITTED entirely (ebook-meta leaves the
# existing value untouched). If BOTH are empty there is nothing to do -> return 0
# without calling ebook-meta. ebook-meta edits the EPUB IN PLACE, so the caller is
# responsible for operating on a temp copy (order: meta on the temp, THEN polish,
# THEN mv -f) — this helper never touches the shipped/original path itself.
# Returns 0 on success (or nothing-to-do), non-zero if ebook-meta failed.
# Args: <work_epub> <title_b64> <author_b64>
apply_meta_into_epub() {
  local work_epub="$1" title_b64="${2:-}" author_b64="${3:-}"
  local t a
  t="$(printf '%s' "$title_b64"  | base64 --decode 2>/dev/null || true)"
  a="$(printf '%s' "$author_b64" | base64 --decode 2>/dev/null || true)"

  # Build the argv vector: the binary + the epub, then ONLY the flags whose value
  # is non-empty. Values ride as single argv elements (no word-splitting, no eval).
  local -a meta_args=("$work_epub")
  [[ -n "$t" ]] && meta_args+=("--title=$t")
  [[ -n "$a" ]] && meta_args+=("--authors=$a")

  # Nothing edited (both empty) -> no-op success; the caller should not have called
  # us, but guard anyway so a stray empty job never spawns ebook-meta needlessly.
  [[ ${#meta_args[@]} -le 1 ]] && return 0

  if [[ ! -x "$EBOOK_META" ]]; then
    log "meta: ebook-meta not found at $EBOOK_META"
    return 1
  fi

  "$EBOOK_META" "${meta_args[@]}" >>"$LOG_FILE" 2>&1
}

# Vend a cover file into an EPUB the M5 way: ebook-polish --cover <cover_file>
# into a tmp (D13: tmp + mv -f), then atomically replace the EPUB. Shared by the
# chosen-candidate path and the apply_generated path so both use the EXACT same
# mechanism. Returns 0 on success, non-zero on any failure (caller logs/cleans up).
# Args: <cover_file> <epub_path>
polish_cover_into_epub() {
  local cover_file="$1" epub_path="$2"
  local out_tmp rc=0
  # D13/M2: polish output alongside the target so the replace `mv` stays a same-volume
  # rename (atomic), not a cross-volume copy+unlink from $TMPDIR. Dot-hidden + no
  # .epub suffix -> epub_name() returns "" -> never treated as a book to convert.
  out_tmp="$(mktemp "$(dirname "$epub_path")/.fb2polish.XXXXXX")" || return 1
  if "$EBOOK_POLISH" --cover "$cover_file" "$epub_path" "$out_tmp" >>"$LOG_FILE" 2>&1 \
     && [[ -s "$out_tmp" ]]; then
    mv -f "$out_tmp" "$epub_path" || rc=1
  else
    rc=1
  fi
  [[ "$rc" -ne 0 ]] && rm -f "$out_tmp" 2>/dev/null || true
  return "$rc"
}

# Ordered, atomic "edited metadata + new cover" vend (v0.9.7). Runs the FULL plan
# sequence on a private WORK copy so the shipped EPUB is replaced only on success:
#   cp epub -> work
#   ebook-meta work (--title/--authors)     [ONLY if the user edited a value]
#   ebook-polish --cover <cover> work final_tmp
#   mv -f final_tmp -> epub                  [atomic replace]
# Meta ALWAYS precedes polish (R4: never a half-metadata'd cover on the live file).
# Return codes let the caller apply the meta-fail policy WITHOUT re-inspecting:
#   0 -> polish ok AND (no edits OR meta ok)         -> resolve "resolved"
#   2 -> polish ok BUT meta failed (cover landed)    -> STILL resolve "resolved"
#        (log the meta miss; a rare metadata slip must not strand the queue card)
#   1 -> polish failed (cover NOT applied)           -> resolve "failed", original
#        left byte-for-byte intact (we never mv over it)
# Args: <cover_file> <epub_path> <title_b64> <author_b64>
apply_meta_and_cover_into_epub() {
  local cover_file="$1" epub_path="$2" title_b64="${3:-}" author_b64="${4:-}"
  local work final_tmp meta_rc=0 rc=0
  # D13/M2: both the work copy and the polish output live ALONGSIDE the target so the
  # final `mv` is a same-volume rename (atomic), never a cross-volume copy+unlink out
  # of $TMPDIR that could tear the destination. Dot-hidden, no .epub suffix -> never
  # seen as a book to convert (epub_name() -> "").
  local epub_dir; epub_dir="$(dirname "$epub_path")"
  work="$(mktemp "$epub_dir/.fb2work.XXXXXX")" || return 1
  if ! final_tmp="$(mktemp "$epub_dir/.fb2polish.XXXXXX")"; then
    rm -f "$work" 2>/dev/null || true
    return 1
  fi

  # Work on a COPY; the original is untouched until the final mv -f.
  if ! cp -f "$epub_path" "$work" 2>>"$LOG_FILE"; then
    rm -f "$work" "$final_tmp" 2>/dev/null || true
    return 1
  fi

  # Metadata first (no-op if both edited values are empty). A meta failure is
  # remembered but does NOT abort the cover — policy: cover wins, meta is best-effort.
  apply_meta_into_epub "$work" "$title_b64" "$author_b64" || meta_rc=1

  # Cover onto the (possibly meta-rewritten) work copy, into a SEPARATE final tmp.
  if "$EBOOK_POLISH" --cover "$cover_file" "$work" "$final_tmp" >>"$LOG_FILE" 2>&1 \
     && [[ -s "$final_tmp" ]]; then
    if mv -f "$final_tmp" "$epub_path"; then
      rc=0
    else
      rc=1
    fi
  else
    rc=1
  fi

  rm -f "$work" 2>/dev/null || true
  [[ "$rc" -ne 0 ]] && rm -f "$final_tmp" 2>/dev/null || true

  # polish failed -> hard fail; polish ok but meta failed -> soft (rc=2).
  [[ "$rc" -ne 0 ]] && return 1
  [[ "$meta_rc" -ne 0 ]] && return 2
  return 0
}

# Ordered, atomic "edited metadata only, cover unchanged" vend (v0.9.7 apply_confirm
# WITH edits). The auto/embedded cover is already correct, so there is NO polish:
#   cp epub -> work
#   ebook-meta work (--title/--authors)
#   mv -f work -> epub                       [atomic replace]
# Return codes mirror the cover helper's meta-fail policy:
#   0 -> meta ok                             -> resolve "resolved"
#   2 -> meta failed -> we DO NOT publish the work copy (it may be CORRUPT: a crash
#        mid in-place edit can leave a half-rewritten OPF / broken zip). We rm the
#        work copy and leave the ORIGINAL byte-for-byte intact. The caller STILL
#        resolves the card "resolved" per the confirm policy (a metadata slip must
#        not strand a book) — resolving the card and NOT corrupting the file are
#        independent: rc=2 means "card done, file untouched, meta missed".
#   1 -> could not even stage the copy (fs error) -> caller decides (we still resolve
#        the card per policy: a confirm must never strand a book on a metadata slip).
# Args: <epub_path> <title_b64> <author_b64>
apply_meta_only_into_epub() {
  local epub_path="$1" title_b64="${2:-}" author_b64="${3:-}"
  local work meta_rc=0
  # D13/M2: stage the work copy ALONGSIDE the target so the final `mv` is a rename
  # on the SAME volume (atomic), never a cross-volume copy+unlink into $TMPDIR that
  # could tear the destination mid-write. The .fb2work.* name is dot-hidden AND has
  # no .epub suffix -> epub_name() returns "" for it, so it is never picked up as a
  # book to convert (count_pending / the folder find both filter by extension).
  work="$(mktemp "$(dirname "$epub_path")/.fb2work.XXXXXX")" || return 1

  if ! cp -f "$epub_path" "$work" 2>>"$LOG_FILE"; then
    rm -f "$work" 2>/dev/null || true
    return 1
  fi

  apply_meta_into_epub "$work" "$title_b64" "$author_b64" || meta_rc=1

  # If ebook-meta failed, the work copy may be CORRUPT (Calibre can crash partway
  # through an in-place OPF rewrite / repack). Publishing it would `mv` a broken
  # file over a GOOD original — the exact bug M1 fixes. So on meta-fail: discard the
  # work copy, DO NOT mv, and return 2 (original stays byte-for-byte intact).
  if [[ "$meta_rc" -ne 0 ]]; then
    rm -f "$work" 2>/dev/null || true
    return 2
  fi

  # Meta succeeded: publish the edited copy atomically (same-volume rename).
  if ! mv -f "$work" "$epub_path"; then
    rm -f "$work" 2>/dev/null || true
    return 1
  fi
  return 0
}

# Remove the queue entry for a finished book (the apply_generated contract: once
# the generated cover is vended, the book is DONE — drop the queue card, no status
# carried). Best-effort. Args: <book_id>
remove_queue_entry() {
  local book_id="$1"
  rm -f "$COVERS_QUEUE_DIR/${book_id}.json" 2>/dev/null || true
}

# Drain all pending apply-jobs. Run once per agent fire, before conversions.
apply_cover_jobs() {
  [[ -x "$EBOOK_POLISH" ]] || { log "apply: ebook-polish not found at $EBOOK_POLISH"; }
  local plan
  plan="$(cover_jobs_plan)" || return 0
  [[ -z "$plan" ]] && return 0

  local action job_file book_id epub_path arg1 arg2
  # etitle_b64 / eauthor_b64 stay BASE64: the meta helpers decode internally (same
  # b64-in contract as apply_meta_into_epub), so an edited value never lands in a
  # bash variable that could be word-split before it reaches the argv vector.
  local etitle_b64 eauthor_b64 edited
  # cover_jobs_plan emits "-" for an empty value field (so runs of spaces never
  # collapse and shift the columns). Map the sentinel back to "" here per field.
  while IFS=' ' read -r act jf bid ep a1 a2 et ea; do
    [[ -z "$act" ]] && continue
    action="$act"
    [[ "$jf"  == "-" ]] && jf=""
    [[ "$bid" == "-" ]] && bid=""
    [[ "$ep"  == "-" ]] && ep=""
    [[ "$a1"  == "-" ]] && a1=""
    [[ "$a2"  == "-" ]] && a2=""
    [[ "${et:-}" == "-" ]] && et=""
    [[ "${ea:-}" == "-" ]] && ea=""
    job_file="$(printf '%s'  "$jf"  | base64 --decode 2>/dev/null || true)"
    book_id="$(printf '%s'   "$bid" | base64 --decode 2>/dev/null || true)"
    epub_path="$(printf '%s' "$ep"  | base64 --decode 2>/dev/null || true)"
    arg1="$(printf '%s'      "$a1"  | base64 --decode 2>/dev/null || true)"
    arg2="$(printf '%s'      "${a2:-}" | base64 --decode 2>/dev/null || true)"
    # Keep the edited fields ENCODED; only presence is decided here (non-empty b64
    # token == the app sent an edit for that field). Back-compat: a job that never
    # carried edited_* encodes both slots as "-" -> cleared to "" -> edited=0 ->
    # the exact pre-v0.9.7 behaviour.
    etitle_b64="${et:-}"
    eauthor_b64="${ea:-}"
    edited=0
    [[ -n "$etitle_b64" || -n "$eauthor_b64" ]] && edited=1

    # --- v0.9.7 "Утвердить" on an already-correct auto/embedded cover ------
    # The cover is NOT touched. With edits -> rewrite metadata on a temp copy and
    # publish atomically; without edits -> just resolve the card (file untouched).
    # Either way the book leaves the queue as "resolved" (a confirm must never
    # strand a card — meta-fail policy).
    if [[ "$action" == "confirm" ]]; then
      if [[ "$edited" -eq 0 ]]; then
        # Pure confirm: nothing to write, just clear the card.
        cover_job_resolve "$book_id" "resolved" "$job_file"
        log "apply_confirm: resolved ${book_id} (no edits, cover untouched)"
        continue
      fi
      # Edited confirm: need a real epub to rewrite metadata into.
      if [[ -z "$epub_path" || ! -f "$epub_path" ]]; then
        # Book gone: still resolve the card (idempotent; no cover/meta to apply).
        log "apply_confirm: resolved ${book_id} (epub missing: ${epub_path:-<none>}, edits dropped)"
        cover_job_resolve "$book_id" "resolved" "$job_file"
        continue
      fi
      apply_meta_only_into_epub "$epub_path" "$etitle_b64" "$eauthor_b64"
      case $? in
        0) log "apply_confirm: resolved ${book_id} (metadata updated)" ;;
        2) log "apply_confirm: resolved ${book_id} (WARN meta-fail, card cleared)" ;;
        *) log "apply_confirm: resolved ${book_id} (WARN could not stage copy, card cleared)" ;;
      esac
      # Policy: a confirm ALWAYS resolves the card, even on a metadata slip.
      cover_job_resolve "$book_id" "resolved" "$job_file"
      continue
    fi

    # --- app-generated fallback cover -------------------------------------
    # arg1 = absolute PNG path the app already wrote. Vend it like a web cover.
    if [[ "$action" == "gen" ]]; then
      local png="$arg1"
      # Book gone (epub deleted before the user acted): drop the job, no retry,
      # and don't touch the queue — there's nothing left to cover.
      if [[ -z "$epub_path" || ! -f "$epub_path" ]]; then
        log "apply_generated: drop ${book_id} (epub missing: ${epub_path:-<none>})"
        rm -f "$job_file" 2>/dev/null || true
        continue
      fi
      if [[ -z "$png" || ! -s "$png" ]]; then
        log "apply_generated: FAIL ${book_id} (png missing: ${png:-<none>})"
        rm -f "$job_file" 2>/dev/null || true
        continue
      fi
      if [[ ! -x "$EBOOK_POLISH" ]]; then
        log "apply_generated: FAIL ${book_id} (ebook-polish unavailable)"
        rm -f "$job_file" 2>/dev/null || true
        continue
      fi
      if [[ "$edited" -eq 1 ]]; then
        # Ordered edited vend: meta -> polish -> mv -f (all on a work copy).
        apply_meta_and_cover_into_epub "$png" "$epub_path" "$etitle_b64" "$eauthor_b64"
        case $? in
          0) remove_queue_entry "$book_id"; rm -f "$job_file" 2>/dev/null || true
             log "apply_generated: ok ${book_id} -> ${epub_path} (metadata updated)" ;;
          2) # Cover landed, metadata slipped -> book is still done (policy).
             remove_queue_entry "$book_id"; rm -f "$job_file" 2>/dev/null || true
             log "apply_generated: ok ${book_id} -> ${epub_path} (WARN meta-fail)" ;;
          *) rm -f "$job_file" 2>/dev/null || true
             log "apply_generated: FAIL ${book_id} (ebook-polish error)" ;;
        esac
      else
        # No edits: byte-for-byte the pre-v0.9.7 vend (web-cover mechanism).
        if polish_cover_into_epub "$png" "$epub_path"; then
          remove_queue_entry "$book_id"
          rm -f "$job_file" 2>/dev/null || true
          log "apply_generated: ok ${book_id} -> ${epub_path}"
        else
          # Best-effort: a polish failure must not loop. Drop the job; leave the
          # queue card so the user can still pick a cover another way.
          rm -f "$job_file" 2>/dev/null || true
          log "apply_generated: FAIL ${book_id} (ebook-polish error)"
        fi
      fi
      continue
    fi

    # --- M5 chosen-candidate / skip ---------------------------------------
    local chosen="$arg1" preview="$arg2"
    if [[ "$chosen" == "skip" ]]; then
      cover_job_resolve "$book_id" "skipped" "$job_file"
      log "apply: skip ${book_id}"
      continue
    fi

    # chosen candidate: validate inputs before touching the EPUB.
    if [[ -z "$epub_path" || ! -f "$epub_path" ]]; then
      log "apply: FAIL ${book_id} (epub missing: ${epub_path:-<none>})"
      cover_job_resolve "$book_id" "failed" "$job_file"
      continue
    fi
    if [[ -z "$preview" || ! -s "$preview" ]]; then
      log "apply: FAIL ${book_id} (preview missing: ${preview:-<none>})"
      cover_job_resolve "$book_id" "failed" "$job_file"
      continue
    fi
    if [[ ! -x "$EBOOK_POLISH" ]]; then
      log "apply: FAIL ${book_id} (ebook-polish unavailable)"
      cover_job_resolve "$book_id" "failed" "$job_file"
      continue
    fi

    if [[ "$edited" -eq 1 ]]; then
      # Ordered edited vend: meta -> polish -> mv -f (all on a work copy).
      apply_meta_and_cover_into_epub "$preview" "$epub_path" "$etitle_b64" "$eauthor_b64"
      case $? in
        0) cover_job_resolve "$book_id" "resolved" "$job_file"
           log "apply: ok ${book_id} -> ${epub_path} (metadata updated)" ;;
        2) # Cover landed, metadata slipped -> still resolved (policy).
           cover_job_resolve "$book_id" "resolved" "$job_file"
           log "apply: ok ${book_id} -> ${epub_path} (WARN meta-fail)" ;;
        *) log "apply: FAIL ${book_id} (ebook-polish error)"
           cover_job_resolve "$book_id" "failed" "$job_file" ;;
      esac
    else
      # No edits: byte-for-byte the pre-v0.9.7 vend.
      if polish_cover_into_epub "$preview" "$epub_path"; then
        cover_job_resolve "$book_id" "resolved" "$job_file"
        log "apply: ok ${book_id} -> ${epub_path}"
      else
        log "apply: FAIL ${book_id} (ebook-polish error)"
        cover_job_resolve "$book_id" "failed" "$job_file"
      fi
    fi
  done <<< "$plan"
}

# --- cover research-jobs ("Search more") -----------------------------------
# The app writes covers/jobs/<book_id>-research-<rand>.json =
#   {book_id, action:"research", exclude:[<url>,...], query?:"<text>", ts}
# atomically. We drain those HERE: read the queue entry for the book to recover
# epub_path (the original fb2 may be long gone), re-run the finder in --json mode
# with --exclude <the already-shown urls> and, when the optional `query` is a
# non-blank string, --query <that text> (overrides the epub metadata so the user
# can search by their own author+title hint), then REWRITE the queue with the
# fresh candidate set. Best-effort: a failure must never abort the rest of the
# run, and the job is always deleted so a bad job can't loop forever.

# Print one plan line per research job (base64, space-separated, NUL-free):
#   <job_file_b64> <book_id_b64> <epub_path_b64> <exclude_b64> <query_b64>
# epub_path is read from the queue entry. exclude is the job's url list joined by
# newlines then base64'd (empty if none). query is the job's optional free-text
# search hint (base64 of the string, empty if absent/blank). Non-research jobs
# are ignored here.
research_jobs_plan() {
  [[ -z "$PYTHON3" || ! -x "$PYTHON3" ]] && return 0
  [[ -d "$COVERS_JOBS_DIR" ]] || return 0
  RJP_JOBS_DIR="$COVERS_JOBS_DIR" RJP_QUEUE_DIR="$COVERS_QUEUE_DIR" \
  "$PYTHON3" - <<'PY' 2>>"$LOG_FILE"
import base64, glob, json, os, sys

jobs_dir  = os.environ["RJP_JOBS_DIR"]
queue_dir = os.environ["RJP_QUEUE_DIR"]

def b64(s):
    return base64.b64encode((s or "").encode("utf-8")).decode("ascii")

for job_file in sorted(glob.glob(os.path.join(jobs_dir, "*.json"))):
    if job_file.endswith(".tmp"):
        continue
    try:
        with open(job_file, "r", encoding="utf-8") as f:
            job = json.load(f)
    except Exception as e:
        print(f"[research] bad job {job_file}: {e}", file=sys.stderr)
        continue
    if (job.get("action") or "") != "research":
        continue
    # Optional user query (free-text author+title). A non-string or blank value
    # means "no query" -> finder falls back to epub metadata as before.
    query = job.get("query")
    query = query.strip() if isinstance(query, str) else ""

    book_id = job.get("book_id") or ""
    if not book_id:
        print(f"[research] job missing book_id: {job_file}", file=sys.stderr)
        # Emit with empty fields so the bash side can delete it (no retry loop).
        print(" ".join([b64(job_file), b64(""), b64(""), b64(""), b64("")]))
        continue

    exclude = job.get("exclude") or []
    if not isinstance(exclude, list):
        exclude = []
    exclude = [u for u in exclude if isinstance(u, str) and u]
    exclude_blob = "\n".join(exclude)

    epub_path = ""
    qpath = os.path.join(queue_dir, f"{book_id}.json")
    try:
        with open(qpath, "r", encoding="utf-8") as f:
            q = json.load(f)
        epub_path = q.get("epub_path") or ""
    except Exception as e:
        print(f"[research] no queue entry for {book_id}: {e}", file=sys.stderr)
        # Still emit (epub_path empty) so the job is cleared rather than retried.

    print(" ".join([b64(job_file), b64(book_id), b64(epub_path),
                    b64(exclude_blob), b64(query)]))
PY
}

# Rewrite covers/queue/<book_id>.json from a fresh finder --json result, per the
# research contract. Replaces candidates + best_candidate_id, sets status=pending,
# refreshes ts, and PRESERVES epub_path/title/author/src_file from the existing
# entry. If the finder returned 0 candidates -> keep the OLD candidates and set
# no_more=true (so the app still has something to show); otherwise clear/false
# no_more. Args: <book_id> <finder_json_file>
research_rewrite_queue() {
  local book_id="$1" json_file="$2"
  [[ -z "$PYTHON3" || ! -x "$PYTHON3" ]] && return 1
  RRQ_BOOK_ID="$book_id" RRQ_JSON="$json_file" RRQ_QUEUE_DIR="$COVERS_QUEUE_DIR" \
  "$PYTHON3" - <<'PY' 2>>"$LOG_FILE"
import json, os, sys
from datetime import datetime, timezone

book_id = os.environ["RRQ_BOOK_ID"]
qdir    = os.environ["RRQ_QUEUE_DIR"]
qpath   = os.path.join(qdir, f"{book_id}.json")

# Existing queue entry is the source of truth for the conversion facts; without
# it we have nowhere to write the refreshed candidates.
try:
    with open(qpath, "r", encoding="utf-8") as f:
        entry = json.load(f)
    if not isinstance(entry, dict):
        raise ValueError("queue entry is not an object")
except Exception as e:
    print(f"[research] cannot read queue {book_id}: {e}", file=sys.stderr)
    sys.exit(1)

try:
    with open(os.environ["RRQ_JSON"], "r", encoding="utf-8") as f:
        finder = json.load(f)
except Exception as e:
    print(f"[research] cannot read finder json: {e}", file=sys.stderr)
    sys.exit(1)

new_cands = finder.get("candidates") or []
ts = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

if new_cands:
    entry["candidates"]        = new_cands
    entry["best_candidate_id"] = finder.get("best_candidate_id")
    # Carry the finder's title-match verdict (older finders: derive from best id).
    conf = finder.get("confident")
    if conf is None:
        conf = bool(finder.get("best_candidate_id"))
    entry["confident"]         = bool(conf)
    entry["no_more"]           = False
else:
    # No fresh covers: keep whatever we already had so the UI isn't left empty,
    # and flag that there is nothing more to find.
    entry["no_more"] = True

entry["status"] = "pending"
entry["ts"]     = ts

tmp = qpath + ".tmp"
try:
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(entry, f, ensure_ascii=False, separators=(",", ":"))
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp, qpath)
except Exception as e:
    print(f"[research] atomic write failed {book_id}: {e}", file=sys.stderr)
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.exit(1)

print("ok" if new_cands else "no_more")
PY
}

# Drain all pending research-jobs. Run once per agent fire, alongside apply-jobs.
apply_research_jobs() {
  [[ -x "$COVER_FINDER" && -n "$PYTHON3" ]] || return 0
  local plan
  plan="$(research_jobs_plan)" || return 0
  [[ -z "$plan" ]] && return 0

  local jf bid ep exb qy job_file book_id epub_path exclude_blob query
  while IFS=' ' read -r jf bid ep exb qy; do
    [[ -z "$jf" ]] && continue
    job_file="$(printf '%s'  "$jf"  | base64 --decode)"
    book_id="$(printf '%s'   "$bid" | base64 --decode)"
    epub_path="$(printf '%s' "$ep"  | base64 --decode)"
    exclude_blob="$(printf '%s' "$exb" | base64 --decode)"
    # query is the LAST field. It may be empty (no user hint); decode tolerantly.
    query="$(printf '%s' "${qy:-}" | base64 --decode 2>/dev/null || true)"

    # Guard: need a book_id and a real epub to feed the finder its metadata.
    if [[ -z "$book_id" ]]; then
      log "research: FAIL (job without book_id, dropped)"
      rm -f "$job_file" 2>/dev/null || true
      continue
    fi
    if [[ -z "$epub_path" || ! -f "$epub_path" ]]; then
      log "research: FAIL ${book_id} (epub missing: ${epub_path:-<none>})"
      rm -f "$job_file" 2>/dev/null || true
      continue
    fi

    # Rebuild the --exclude argument vector from the newline-joined blob.
    local -a exclude_args=()
    if [[ -n "$exclude_blob" ]]; then
      while IFS= read -r u; do
        [[ -n "$u" ]] && exclude_args+=("$u")
      done <<< "$exclude_blob"
    fi

    # Assemble the finder argv: base flags, then optional --query (user's hint,
    # overrides epub meta) and optional --exclude (URLs already shown). The src
    # epub path always comes last. Both options are independent — any combination
    # (query only / exclude only / both / neither) is valid.
    local -a finder_args=(--json --book-id "$book_id"
                          --previews-dir "$COVERS_PREVIEWS_DIR")
    if [[ -n "$query" ]]; then
      finder_args+=(--query "$query")
    fi
    if [[ ${#exclude_args[@]} -gt 0 ]]; then
      finder_args+=(--exclude "${exclude_args[@]}")
    fi
    finder_args+=("$epub_path")

    local research_tmp json_file rc=0
    research_tmp="$(mktemp -d -t fb2research)"
    json_file="$research_tmp/finder.json"
    "$PYTHON3" "$COVER_FINDER" "${finder_args[@]}" \
      >"$json_file" 2>>"$LOG_FILE" || rc=$?

    if [[ "$rc" -eq 0 && -s "$json_file" ]]; then
      local result rrc=0
      result="$(research_rewrite_queue "$book_id" "$json_file")" || rrc=$?
      if [[ "$rrc" -eq 0 ]]; then
        local q_flag="no"; [[ -n "$query" ]] && q_flag="yes"
        log "research: ${result} ${book_id} (exclude=${#exclude_args[@]} query=${q_flag})"
      else
        log "research: FAIL ${book_id} (queue rewrite error)"
      fi
    else
      # rc=3 (embedded cover) or 1 (giving up) or non-empty stderr only: leave the
      # existing queue untouched, just clear the job so we don't loop.
      log "research: FAIL ${book_id} (finder rc=${rc}, no usable output)"
    fi

    rm -rf "$research_tmp"
    rm -f "$job_file" 2>/dev/null || true
  done <<< "$plan"
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "another run in progress; exiting"
  exit 0
fi
# batch_started gates the on-exit ring release: only touch the batch field if this
# run actually opened/continued a batch (pending>0). This keeps an idle/no-op fire
# from touching it at all. The EXIT trap also keeps the lock cleanup so the ring
# never hangs "active" if the run dies mid-conversion (error/early exit).
#
# release_batch passes the CURRENT remainder to `end`: by exit time convert_book
# has run, so count_pending() is what's STILL unconverted. end finishes the batch
# only when done>=total OR that remainder is 0 (nothing left); an intermediate fire
# that converted nothing real (e.g. just applied a cover-job, files still pending)
# leaves active:true so the next fire resumes. On an early/error exit before the
# loop, the remainder is still >0 while done<total, so the batch correctly stays
# active rather than being falsely marked complete.
batch_started=0
release_batch() {
  [[ "$batch_started" -eq 1 ]] || return 0
  batch_state end "$(count_pending)"
}
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; release_batch' EXIT

if [[ ! -x "$EBOOK_CONVERT" ]]; then
  log "ebook-convert not found at $EBOOK_CONVERT"
  exit 1
fi

log "=== run start ==="

# Drain any cover apply-jobs the app dropped (M5) before processing new files.
apply_cover_jobs
# Drain any "Search more" research-jobs (refresh the candidate set for a book).
apply_research_jobs

epub_name() {
  local name="$1" lower
  lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.fb2.zip) printf '%s' "${name%.[fF][bB]2.[zZ][iI][pP]}.epub" ;;
    *.fb2)     printf '%s' "${name%.[fF][bB]2}.epub" ;;
    *.fb3)     printf '%s' "${name%.[fF][bB]3}.epub" ;;
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

  # FB3 врез: an .fb3 is first transformed (stdlib python3) into a temp .fb2, then
  # the ENTIRE existing path below (cover-finder + ebook-convert) runs against that
  # .fb2 — i.e. everything downstream sees a normal FB2 and is untouched. For
  # .fb2/.fb2.zip conv_src stays = src, so the FB2/.fb2.zip path is byte-for-byte
  # unchanged. The transform's embedded cover (from the FB3 OPC thumbnail) makes
  # the finder report rc=3 (embedded) -> no online/generated cover, as for a native
  # FB2 with a cover. Log lines and queue/state keep the user's original .fb3 name.
  local conv_src="$src" fb3_tmp_dir=""
  case "$(printf '%s' "$src" | tr '[:upper:]' '[:lower:]')" in
    *.fb3)
      if [[ -f "$FB3_TRANSFORM" && -n "$PYTHON3" && -x "$PYTHON3" ]]; then
        fb3_tmp_dir="$(mktemp -d -t fb2fb3)"
        local fb2_tmp="$fb3_tmp_dir/book.fb2" rc3=0
        "$PYTHON3" "$FB3_TRANSFORM" --out "$fb2_tmp" \
          --genre-map "$(dirname "$FB3_TRANSFORM")/fb2-to-epub-fb3-genre.json" \
          "$src" >>"$LOG_FILE" 2>&1 || rc3=$?
        if [[ "$rc3" -ne 0 || ! -s "$fb2_tmp" ]]; then
          # Transform failure (bad/not-FB3 etc.): log + skip THIS book, but keep the
          # batch going. Record a failed conversion so the UI reflects it.
          log "FB3 FAIL (rc=$rc3): ${src#$WATCH_DIR/}"
          rm -rf "$fb3_tmp_dir"
          rm -f "$dst"   # drop any stale .epub from a previous successful run
          record_conversion "$src" "$dst" "failed"
          return 0
        fi
        conv_src="$fb2_tmp"
        log "FB3->FB2 ok: ${src#$WATCH_DIR/}"
      else
        # No python3 / transform available: skip the FB3 (don't fail the batch).
        log "FB3 skip (no python3/transform): ${src#$WATCH_DIR/}"
        return 0
      fi
      ;;
  esac

  local cover_args=("--no-default-epub-cover")
  local cover_tmp_dir rc
  local bid="" json_file="" cand_count=0 best_preview="" confident=0 queue_pending=0
  cover_tmp_dir="$(mktemp -d -t fb2cover)"

  # Cover finder runs in --json mode: it returns the top-N candidates with local
  # previews under covers/previews/<book_id>/. The finder also TITLE-MATCHES each
  # candidate's caption against the book title and only sets best_candidate_id /
  # confident when at least one candidate actually matches. We branch on that:
  #   embedded (rc=3)           -> Calibre keeps the embedded cover, no finder cover.
  #   no candidates (rc=1)      -> convert with no cover (placeholder suppressed).
  #   candidates + confident    -> auto-embed the BEST (title-matched) preview now,
  #                                and (if 2+) queue the set for later re-pick.
  #   candidates + NOT confident-> DON'T auto-embed (the matches are other books by
  #                                the same author, not THIS one); leave the book
  #                                cover-less but STILL queue so the user can pick a
  #                                web candidate or one of the app's generated covers.
  if [[ -x "$COVER_FINDER" && -n "$PYTHON3" ]]; then
    bid="$(book_id_for "$dst")"
    json_file="$cover_tmp_dir/finder.json"
    rc=0
    "$PYTHON3" "$COVER_FINDER" --json --book-id "$bid" \
      --previews-dir "$COVERS_PREVIEWS_DIR" "$conv_src" \
      >"$json_file" 2>>"$LOG_FILE" || rc=$?
    case $rc in
      0)
        eval "$(cover_json_summary "$json_file")"
        if [[ "${confident:-0}" -eq 1 && -n "$best_preview" && -s "$best_preview" ]]; then
          # Confident title-match: auto-embed the best preview now.
          cover_args=(--cover "$best_preview" --no-default-epub-cover)
          if [[ "${cand_count:-0}" -ge 2 ]]; then
            queue_pending=1
            log "cover (best of $cand_count, queued): ${src#$WATCH_DIR/}"
          else
            log "cover (online, 1): ${src#$WATCH_DIR/}"
          fi
        elif [[ "${cand_count:-0}" -ge 1 ]]; then
          # Candidates exist but none title-match (or best preview missing): do
          # NOT auto-embed a likely-wrong cover. Convert cover-less, but queue the
          # set so the user can choose (web candidate or app-generated fallback).
          queue_pending=1
          log "cover (no title-match, queued, no auto): ${src#$WATCH_DIR/}"
        else
          log "cover (none):    ${src#$WATCH_DIR/}"
        fi
        ;;
      3) log "cover (embedded): ${src#$WATCH_DIR/}" ;;
      *) log "cover (none):    ${src#$WATCH_DIR/}" ;;
    esac
  fi

  log "convert: ${src#$WATCH_DIR/}"
  if "$EBOOK_CONVERT" "$conv_src" "$dst" "${cover_args[@]}" >>"$LOG_FILE" 2>&1; then
    log "ok:      ${dst#$WATCH_DIR/}"
    record_conversion "$src" "$dst" "ok"
    # Advance the batch ring (no-op if no batch is active). Subshell-safe: the
    # counter lives in state.json, not a bash var the piped folder loop would lose.
    batch_state tick
    # Queue only after a successful conversion: the entry points at a real epub.
    if [[ "$queue_pending" -eq 1 ]]; then
      write_queue_entry "$bid" "$json_file" "$dst" "$src" "pending" \
        && log "queue:   ${bid} (${COVERS_QUEUE_DIR}/${bid}.json)"
    fi
  else
    log "FAIL:    ${src#$WATCH_DIR/}"
    rm -f "$dst" 2>/dev/null || true
    record_conversion "$src" "$dst" "failed"
  fi

  rm -rf "$cover_tmp_dir"
  [[ -n "$fb3_tmp_dir" ]] && rm -rf "$fb3_tmp_dir" 2>/dev/null || true
}

process_folder_tree() {
  local src_root="$1" mirror_root="$2"
  mkdir -p "$mirror_root"
  find "$src_root" -type f \( -iname '*.fb2' -o -iname '*.fb2.zip' -o -iname '*.fb3' \) -print0 \
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

# Is there already a sticky batch in flight on disk? "Fresh" iff no active batch
# OR an active one whose done already reached total (stale: previous batch done /
# session died). This MUST mirror begin's new-vs-continuation choice so the app is
# surfaced exactly once per logical batch. Prints 1 (fresh/new) or 0 (continuation).
batch_is_fresh() {
  [[ -z "$PYTHON3" || ! -x "$PYTHON3" ]] && { printf '1'; return 0; }
  STATE_FILE="$STATE_FILE" "$PYTHON3" - <<'PY' 2>>"$LOG_FILE" || printf '1'
import json, os
try:
    with open(os.environ["STATE_FILE"], "r", encoding="utf-8") as f:
        b = json.load(f).get("batch") or {}
    active = bool(b.get("active"))
    total  = int(b.get("total", 0) or 0)
    done   = int(b.get("done", 0) or 0)
    fresh  = (not active) or (total > 0 and done >= total)
except Exception:
    fresh = True
print("1" if fresh else "0")
PY
}

# Open the batch BEFORE converting: pre-count the files that would actually be
# converted (output missing/stale) = total. >0 -> begin publishes a STICKY batch
# (new {active,total,done:0}, or continuation that preserves total/done — see
# batch_state). ==0 (idle/holdout fire) -> leave the batch field untouched per the
# contract (no active batch). convert_book ticks done as it goes; the EXIT trap
# (release_batch) flips active->false only when the batch is truly finished.
pending_total="$(count_pending)"
if [[ "$pending_total" -gt 0 ]]; then
  # Read fresh-vs-continuation BEFORE begin rewrites the batch field.
  batch_fresh="$(batch_is_fresh)"
  batch_started=1
  batch_state begin "$pending_total"
  log "batch: start total=$pending_total fresh=$batch_fresh"
  # Surface the app ONLY at the start of a NEW batch (exactly once per logical
  # batch), NOT on every continuation fire (cover-apply / .epub-write re-fires) —
  # otherwise the window would pop to the front on each mid-batch fire.
  # `open -b <bundle-id>` needs no app path. Best-effort & non-blocking:
  # backgrounded, every failure swallowed — a missing/broken `open` must never
  # delay or abort the run.
  if [[ "$batch_fresh" == "1" ]] && command -v open >/dev/null 2>&1; then
    ( open -b com.arrivarus.fb2toepub >/dev/null 2>&1 || true ) &
    disown 2>/dev/null || true
    log "app: open -b com.arrivarus.fb2toepub (new batch start)"
  fi
fi

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
