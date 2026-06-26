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
EBOOK_META="${EBOOK_META:-/Applications/calibre.app/Contents/MacOS/ebook-meta}"

# ebook-polish applies a user-chosen cover into an existing EPUB (M5 apply-job).
# Only the agent (this watcher, under its Full Disk Access) ever rewrites EPUBs;
# the app just drops a job. Resolve from the same Calibre MacOS dir.
EBOOK_POLISH="${EBOOK_POLISH:-/Applications/calibre.app/Contents/MacOS/ebook-polish}"

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
    batch = {"active": True, "total": total_arg, "done": 0}
elif mode == "tick":
    # Only advance an active batch; cap at total so the ring never exceeds 100%.
    if batch.get("active"):
        total = int(batch.get("total", 0) or 0)
        done  = int(batch.get("done", 0) or 0) + 1
        if total > 0 and done > total:
            done = total
        batch["done"] = done
elif mode == "end":
    batch["active"] = False
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
      done < <(find "$entry" -type f \( -iname '*.fb2' -o -iname '*.fb2.zip' \) -print0)
    fi
  done
  printf '%s' "$n"
}

# --- cover queue helpers ---------------------------------------------------
# Both delegate JSON work to python3 (bash can't parse JSON safely). Best-effort:
# a failure must never abort a conversion.

# Read the finder's --json output (file) and print two shell-safe lines meant to
# be consumed via `eval`:
#   cand_count=<N>
#   best_preview=<abs path or empty>
# best_preview is the preview of best_candidate_id. Prints cand_count=0 on error.
cover_json_summary() {
  local json_file="$1"
  [[ -z "$PYTHON3" || ! -x "$PYTHON3" ]] && { printf 'cand_count=0\nbest_preview=\n'; return 0; }
  CJ_FILE="$json_file" "$PYTHON3" - <<'PY' 2>>"$LOG_FILE" || printf 'cand_count=0\nbest_preview=\n'
import json, os, sys, shlex
try:
    with open(os.environ["CJ_FILE"], "r", encoding="utf-8") as f:
        d = json.load(f)
    cands = d.get("candidates") or []
    best_id = d.get("best_candidate_id")
    best = ""
    for c in cands:
        if c.get("id") == best_id:
            best = c.get("preview_path") or ""
            break
    if not best and cands:
        best = cands[0].get("preview_path") or ""
    # shlex.quote keeps a path with spaces/unicode safe for `eval`.
    print(f"cand_count={len(cands)}")
    print(f"best_preview={shlex.quote(best)}")
except Exception as e:
    print(f"[queue] summary failed: {e}", file=sys.stderr)
    print("cand_count=0")
    print("best_preview=")
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

entry = {
    "book_id":           book_id,
    "epub_path":         os.environ["QE_EPUB"],
    "title":             finder.get("title"),
    "author":            finder.get("author"),
    "src_file":          os.environ["QE_SRC"],
    "status":            status,
    "candidates":        finder.get("candidates") or [],
    "best_candidate_id": finder.get("best_candidate_id"),
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

# Print one base64-encoded plan line per job (NUL-free, space/unicode safe):
#   <job_file_b64> <book_id_b64> <chosen_b64> <epub_path_b64> <preview_path_b64>
# chosen is the literal "skip" or the chosen candidate id. preview_path is the
# local preview of the chosen candidate (empty for skip / when not found).
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

for job_file in sorted(glob.glob(os.path.join(jobs_dir, "*.json"))):
    if job_file.endswith(".tmp"):
        continue
    try:
        with open(job_file, "r", encoding="utf-8") as f:
            job = json.load(f)
    except Exception as e:
        print(f"[apply] bad job {job_file}: {e}", file=sys.stderr)
        continue
    # "research" jobs ("Search more") are drained by a separate pass; ignore them
    # here so the apply loop never touches them (and never deletes them).
    if (job.get("action") or "") == "research":
        continue
    book_id = job.get("book_id") or ""
    chosen  = job.get("chosen_candidate_id") or ""
    if not book_id or not chosen:
        print(f"[apply] job missing fields: {job_file}", file=sys.stderr)
        continue

    epub_path = ""
    preview   = ""
    qpath = os.path.join(queue_dir, f"{book_id}.json")
    try:
        with open(qpath, "r", encoding="utf-8") as f:
            q = json.load(f)
        epub_path = q.get("epub_path") or ""
        if chosen != "skip":
            for c in (q.get("candidates") or []):
                if c.get("id") == chosen:
                    preview = c.get("preview_path") or ""
                    break
    except Exception as e:
        print(f"[apply] no queue entry for {book_id}: {e}", file=sys.stderr)
        # Still emit the job so it can be cleared (avoids an infinite retry loop).

    print(" ".join([b64(job_file), b64(book_id), b64(chosen),
                    b64(epub_path), b64(preview)]))
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

# Drain all pending apply-jobs. Run once per agent fire, before conversions.
apply_cover_jobs() {
  [[ -x "$EBOOK_POLISH" ]] || { log "apply: ebook-polish not found at $EBOOK_POLISH"; }
  local plan
  plan="$(cover_jobs_plan)" || return 0
  [[ -z "$plan" ]] && return 0

  local job_file book_id chosen epub_path preview
  while IFS=' ' read -r jf bid ch ep pv; do
    [[ -z "$jf" ]] && continue
    job_file="$(printf '%s' "$jf" | base64 --decode)"
    book_id="$(printf '%s'  "$bid" | base64 --decode)"
    chosen="$(printf '%s'   "$ch" | base64 --decode)"
    epub_path="$(printf '%s' "$ep" | base64 --decode)"
    preview="$(printf '%s'  "$pv" | base64 --decode)"

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

    # Polish into a tmp output (D13: tmp + mv -f), then atomically replace the
    # EPUB. ebook-polish only rewrites the cover, minimizing other changes.
    local out_tmp rc=0
    out_tmp="$(mktemp -t fb2polish).epub"
    if "$EBOOK_POLISH" --cover "$preview" "$epub_path" "$out_tmp" >>"$LOG_FILE" 2>&1 \
       && [[ -s "$out_tmp" ]]; then
      if mv -f "$out_tmp" "$epub_path"; then
        cover_job_resolve "$book_id" "resolved" "$job_file"
        log "apply: ok ${book_id} -> ${epub_path}"
      else
        rc=1
      fi
    else
      rc=1
    fi
    if [[ "$rc" -ne 0 ]]; then
      rm -f "$out_tmp" 2>/dev/null || true
      log "apply: FAIL ${book_id} (ebook-polish error)"
      cover_job_resolve "$book_id" "failed" "$job_file"
    fi
  done <<< "$plan"
}

# --- cover research-jobs ("Search more") -----------------------------------
# The app writes covers/jobs/<book_id>-research-<rand>.json =
#   {book_id, action:"research", exclude:[<url>,...], ts}
# atomically. We drain those HERE: read the queue entry for the book to recover
# epub_path (the original fb2 may be long gone), re-run the finder in --json mode
# with --exclude <the already-shown urls>, then REWRITE the queue with the fresh
# candidate set. Best-effort: a failure must never abort the rest of the run, and
# the job is always deleted so a bad job can't loop forever.

# Print one plan line per research job (base64, space-separated, NUL-free):
#   <job_file_b64> <book_id_b64> <epub_path_b64> <exclude_b64>
# epub_path is read from the queue entry. exclude is the job's url list joined by
# newlines then base64'd (empty if none). Non-research jobs are ignored here.
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
    book_id = job.get("book_id") or ""
    if not book_id:
        print(f"[research] job missing book_id: {job_file}", file=sys.stderr)
        # Emit with empty fields so the bash side can delete it (no retry loop).
        print(" ".join([b64(job_file), b64(""), b64(""), b64("")]))
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

    print(" ".join([b64(job_file), b64(book_id), b64(epub_path), b64(exclude_blob)]))
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

  local jf bid ep exb job_file book_id epub_path exclude_blob
  while IFS=' ' read -r jf bid ep exb; do
    [[ -z "$jf" ]] && continue
    job_file="$(printf '%s'  "$jf"  | base64 --decode)"
    book_id="$(printf '%s'   "$bid" | base64 --decode)"
    epub_path="$(printf '%s' "$ep"  | base64 --decode)"
    exclude_blob="$(printf '%s' "$exb" | base64 --decode)"

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

    local research_tmp json_file rc=0
    research_tmp="$(mktemp -d -t fb2research)"
    json_file="$research_tmp/finder.json"
    if [[ ${#exclude_args[@]} -gt 0 ]]; then
      "$PYTHON3" "$COVER_FINDER" --json --book-id "$book_id" \
        --previews-dir "$COVERS_PREVIEWS_DIR" --exclude "${exclude_args[@]}" \
        "$epub_path" >"$json_file" 2>>"$LOG_FILE" || rc=$?
    else
      "$PYTHON3" "$COVER_FINDER" --json --book-id "$book_id" \
        --previews-dir "$COVERS_PREVIEWS_DIR" \
        "$epub_path" >"$json_file" 2>>"$LOG_FILE" || rc=$?
    fi

    if [[ "$rc" -eq 0 && -s "$json_file" ]]; then
      local result rrc=0
      result="$(research_rewrite_queue "$book_id" "$json_file")" || rrc=$?
      if [[ "$rrc" -eq 0 ]]; then
        log "research: ${result} ${book_id} (exclude=${#exclude_args[@]})"
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
# batch_started gates the on-exit ring release: only flip active->false if this
# run actually opened a batch (pending>0). This keeps an idle/no-op fire from
# touching the batch field at all. The EXIT trap also keeps the lock cleanup so
# the ring never hangs "active" if the run dies mid-conversion (error/early exit).
batch_started=0
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; [[ "$batch_started" -eq 1 ]] && batch_state end' EXIT

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
  local cover_tmp_dir rc
  local bid="" json_file="" cand_count=0 best_preview="" queue_pending=0
  cover_tmp_dir="$(mktemp -d -t fb2cover)"

  # Cover finder runs in --json mode: it returns the top-N candidates with local
  # previews under covers/previews/<book_id>/. We then branch on the count:
  #   embedded (rc=3) -> Calibre keeps the embedded cover, no finder cover.
  #   0 candidates    -> convert with no cover (placeholder suppressed).
  #   1 candidate     -> apply that preview as the cover.
  #   2+ candidates   -> apply the BEST preview now (non-blocking) AND queue the
  #                      set so the user can pick another later (M5).
  if [[ -x "$COVER_FINDER" && -n "$PYTHON3" ]]; then
    bid="$(book_id_for "$dst")"
    json_file="$cover_tmp_dir/finder.json"
    rc=0
    "$PYTHON3" "$COVER_FINDER" --json --book-id "$bid" \
      --previews-dir "$COVERS_PREVIEWS_DIR" "$src" \
      >"$json_file" 2>>"$LOG_FILE" || rc=$?
    case $rc in
      0)
        eval "$(cover_json_summary "$json_file")"
        if [[ "${cand_count:-0}" -ge 1 && -n "$best_preview" && -s "$best_preview" ]]; then
          cover_args=(--cover "$best_preview" --no-default-epub-cover)
          if [[ "$cand_count" -ge 2 ]]; then
            queue_pending=1
            log "cover (best of $cand_count, queued): ${src#$WATCH_DIR/}"
          else
            log "cover (online, 1): ${src#$WATCH_DIR/}"
          fi
        else
          log "cover (none):    ${src#$WATCH_DIR/}"
        fi
        ;;
      3) log "cover (embedded): ${src#$WATCH_DIR/}" ;;
      *) log "cover (none):    ${src#$WATCH_DIR/}" ;;
    esac
  fi

  log "convert: ${src#$WATCH_DIR/}"
  if "$EBOOK_CONVERT" "$src" "$dst" "${cover_args[@]}" >>"$LOG_FILE" 2>&1; then
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

# Open the batch BEFORE converting: pre-count the files that would actually be
# converted (output missing/stale) = total. >0 -> publish {active:true,total,done:0}
# so the ring starts at 0%. ==0 (idle/holdout fire) -> leave the batch field
# untouched per the contract (no active batch). convert_book ticks done as it goes;
# the EXIT trap flips active->false at the end (and on error).
pending_total="$(count_pending)"
if [[ "$pending_total" -gt 0 ]]; then
  batch_started=1
  batch_state begin "$pending_total"
  log "batch: start total=$pending_total"
  # Surface the app at batch START (exactly once per batch): launch it if closed,
  # bring it to front if already running. `open -b <bundle-id>` needs no app path.
  # Best-effort & non-blocking: backgrounded, every failure swallowed — a missing/
  # broken `open` must never delay or abort the run. NOT in tick/end (one open per
  # batch); idle fires (pending==0) skip this whole block, so no open.
  if command -v open >/dev/null 2>&1; then
    ( open -b com.arrivarus.fb2toepub >/dev/null 2>&1 || true ) &
    disown 2>/dev/null || true
    log "app: open -b com.arrivarus.fb2toepub (batch start)"
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
