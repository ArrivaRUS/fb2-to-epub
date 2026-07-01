#!/bin/bash
# run-cover-edit-test.sh — locks the v0.9.7 cover-edit apply path in
# bin/fb2-to-epub-watcher.sh: the "Утвердить" (apply_confirm) action + the optional
# edited_title/edited_author metadata rewrite that rides EVERY apply action.
#
# WHY this exists
# ---------------
# v0.9.7 lets the user (a) confirm an already-correct auto/embedded cover without
# re-applying anything, and (b) correct the book's Author/Title so the change is
# written INTO the produced EPUB via ebook-meta. Both are drained by the agent
# (this watcher, under Full Disk Access). Two invariants are non-negotiable:
#
#   R1 (CATASTROPHIC under FDA): a user-edited title/author is passed to
#      ebook-meta as a SINGLE argv element via a base64 transport — NEVER
#      interpolated into a command string. Quotes / $() / backticks / ;rm in the
#      value must be inert. A regression here is arbitrary code execution.
#   R4 (EPUB corruption): metadata is rewritten on a WORK COPY, ebook-meta runs
#      BEFORE ebook-polish, and the shipped EPUB is replaced only via `mv -f` on
#      full success — a failed polish leaves the original byte-for-byte intact.
#
# HOW (lesson 015 — NEVER touch the real plist/agent/Desktop): no launchctl, no
# real Calibre, no network. The apply-path functions are extracted VERBATIM from
# the shipping watcher (anchored on `^name() {` .. column-0 `}`, exactly like
# run-sticky-batch-test.sh extracts batch_state) and sourced into a private
# sandbox. EBOOK_META / EBOOK_POLISH are pointed at STUBS that only append their
# argv (NUL-delimited) to a log — so we can assert the EXACT vector each binary
# received, in order, without running Calibre. One real (tiny) EPUB — a zip with a
# `mimetype` first entry — stands in for the produced book so `cp`/`mv` and the
# stubs operate on a genuine file.
#
# Checks (per the M1 brief):
#   (a) edited apply job  -> ebook-meta called with the right argv BEFORE polish
#   (b) no-edit apply job -> ebook-meta NOT called (byte-for-byte old path)
#   (c) apply_confirm     -> NO polish; queue card resolved (removed from pager)
#   (d) injection in title/author -> delivered as ONE argv; the shell never runs it
#   (e) order meta -> polish (global ordering assertion)
#   (f) mv -f atomicity   -> original replaced ONLY on success; untouched on failure
#   plus: back-compat (old 6-field plan line -> no meta), apply_confirm no-edit
#         (file untouched), meta-fail policy (cover lands, meta fails -> resolved).
#
# Usage:  bash tests/run-cover-edit-test.sh
# Exit:   0 = all green, 1 = a check failed (or python3/extraction/zip missing).

# NB: -u and pipefail, but NOT -e. We SOURCE and drive the shipping apply-path
# functions, and the watcher itself runs WITHOUT `set -e` (bin/…: `set -u` +
# `set -o pipefail` only). A helper like apply_meta_and_cover_into_epub returns
# non-zero on a (deliberately stubbed) polish failure and is consumed via
# `cmd; case $?` — a valid idiom the watcher relies on. Under `set -e` that
# non-zero return would abort the harness mid-scenario (a false failure that never
# happens in production). So we mirror the real runtime and gate PASS/FAIL on the
# explicit ok/bad counters, not on `-e`.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHER="$REPO_DIR/bin/fb2-to-epub-watcher.sh"
[[ -f "$WATCHER" ]] || { echo "missing $WATCHER" >&2; exit 1; }

# python3 the same way the watcher resolves it (env -> common paths -> PATH). The
# plan/executor no-op without an executable python3, so a missing one would make
# every check vacuously "pass" — fail loudly instead.
PY="${PYTHON3:-}"
if [[ -z "$PY" || ! -x "$PY" ]]; then
  for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [[ -x "$cand" ]] && { PY="$cand"; break; }
  done
fi
[[ -z "$PY" || ! -x "$PY" ]] && PY="$(command -v python3 2>/dev/null || true)"
[[ -n "$PY" && -x "$PY" ]] || { echo "run-cover-edit: python3 not found" >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "run-cover-edit: zip not found" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL - %s\n' "$1"; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cover-edit.XXXXXX")"
[[ -n "$SANDBOX" && -d "$SANDBOX" ]] || { echo "run-cover-edit: could not create sandbox" >&2; exit 1; }
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

echo "==> Cover-edit (v0.9.7): apply_confirm + edited metadata (ebook-meta) apply path"
echo ""

# ---------------------------------------------------------------------------
# Extract the apply-path functions VERBATIM and source them. Each is written with
# a column-0 `name() {` open and a column-0 `}` close (the inner python heredoc
# terminator is indented `PY`, so it never matches `^}`). We pull the exact set
# apply_cover_jobs transitively needs.
# ---------------------------------------------------------------------------
FN_FILE="$SANDBOX/apply_fns.sh"
: > "$FN_FILE"
extract_fn() { # extract_fn <name>  -> append its verbatim body to $FN_FILE
  awk -v name="$1" '
    $0 ~ "^" name "\\(\\) \\{" {grab=1}
    grab {print}
    grab && /^\}/ {exit}
  ' "$WATCHER" >> "$FN_FILE"
  printf '\n' >> "$FN_FILE"
}

# The one-liner log() (not a braced block) is copied by its own grep.
grep -E '^log\(\) \{' "$WATCHER" >> "$FN_FILE" || true
printf '\n' >> "$FN_FILE"

for fn in cover_jobs_plan cover_job_resolve apply_meta_into_epub \
          polish_cover_into_epub apply_meta_and_cover_into_epub \
          apply_meta_only_into_epub remove_queue_entry apply_cover_jobs; do
  extract_fn "$fn"
done

# Sanity: every function we rely on made it into the extract (so a rename upstream
# can't silently make the behaviour checks vacuous).
missing=0
for fn in log cover_jobs_plan cover_job_resolve apply_meta_into_epub \
          polish_cover_into_epub apply_meta_and_cover_into_epub \
          apply_meta_only_into_epub remove_queue_entry apply_cover_jobs; do
  if grep -qE "^${fn}\(\) \{|^${fn}\(\) " "$FN_FILE"; then :; else
    bad "extract function '$fn' from watcher"; missing=1
  fi
done
if [[ "$missing" -eq 0 ]]; then ok "extracted all apply-path functions verbatim"; fi
# The new helpers must actually be present in the shipping source (guards a merge
# that drops them).
grep -q "^apply_meta_into_epub() {"        "$WATCHER" && ok "watcher defines apply_meta_into_epub" || bad "watcher defines apply_meta_into_epub"
grep -q "^apply_meta_and_cover_into_epub() {" "$WATCHER" && ok "watcher defines apply_meta_and_cover_into_epub" || bad "watcher defines apply_meta_and_cover_into_epub"

# shellcheck disable=SC1090
source "$FN_FILE"

# ---------------------------------------------------------------------------
# Sandbox wiring: private covers dir + a stub for each Calibre binary. The stubs
# NUL-append their whole argv to a per-binary log so we can assert the exact
# vector (order + boundaries) each received. ebook-meta edits IN PLACE (no output
# file) so its stub just touches a marker; ebook-polish takes <in> <out> and must
# write <out> for the caller to accept it, so its stub `cp`s in->out.
# ---------------------------------------------------------------------------
export PYTHON3="$PY"
LOG_FILE="$SANDBOX/watcher.log"; export LOG_FILE
: > "$LOG_FILE"

COVERS_DIR="$SANDBOX/covers"
COVERS_QUEUE_DIR="$COVERS_DIR/queue"
COVERS_JOBS_DIR="$COVERS_DIR/jobs"
export COVERS_QUEUE_DIR COVERS_JOBS_DIR
mkdir -p "$COVERS_QUEUE_DIR" "$COVERS_JOBS_DIR"

META_LOG="$SANDBOX/ebook-meta.argv"
POLISH_LOG="$SANDBOX/ebook-polish.argv"
ORDER_LOG="$SANDBOX/order.log"     # append 'meta' / 'polish' as each stub runs

STUB_DIR="$SANDBOX/stubs"; mkdir -p "$STUB_DIR"

# ebook-meta stub: record argv (NUL-delimited, one record per line via `xxd`-free
# printf), note ordering. Exit code is controlled by $FAKE_META_RC (default 0).
# ebook-meta edits IN PLACE, so argv[1] is the EPUB it is rewriting. When
# $FAKE_META_CORRUPT is set, the stub simulates a Calibre crash MIDWAY through an
# in-place OPF rewrite: it CLOBBERS argv[1] with garbage AND exits non-zero. This is
# the M1 scenario — a non-zero ebook-meta that has already trashed the work copy, so
# a caller that publishes it anyway would `mv` a broken file over a good original.
cat > "$STUB_DIR/ebook-meta" <<'STUB'
#!/bin/bash
{ for a in "$@"; do printf '%s\0' "$a"; done; printf '\n'; } >> "$META_LOG"
printf 'meta\n' >> "$ORDER_LOG"
if [[ -n "${FAKE_META_CORRUPT:-}" ]]; then
  # argv[1] is the in-place work EPUB (apply_meta_into_epub passes it first). Trash it.
  printf 'CORRUPTED-BY-CRASHED-EBOOK-META\n' > "$1"
  exit "${FAKE_META_RC:-1}"
fi
exit "${FAKE_META_RC:-0}"
STUB

# ebook-polish stub: record argv, note ordering, and (on success) write the output
# file so the caller's `[[ -s out ]]` passes. argv is `--cover <file> <in> <out>`.
# Exit code controlled by $FAKE_POLISH_RC (default 0); when non-zero it writes
# NOTHING (mirrors a real polish failure -> caller keeps the original).
cat > "$STUB_DIR/ebook-polish" <<'STUB'
#!/bin/bash
{ for a in "$@"; do printf '%s\0' "$a"; done; printf '\n'; } >> "$POLISH_LOG"
printf 'polish\n' >> "$ORDER_LOG"
rc="${FAKE_POLISH_RC:-0}"
if [[ "$rc" -eq 0 ]]; then
  # last arg = output path; produce a non-empty file so the caller accepts it.
  out="${@: -1}"
  printf 'POLISHED\n' > "$out"
fi
exit "$rc"
STUB

chmod +x "$STUB_DIR/ebook-meta" "$STUB_DIR/ebook-polish"
export META_LOG POLISH_LOG ORDER_LOG
EBOOK_META="$STUB_DIR/ebook-meta"
EBOOK_POLISH="$STUB_DIR/ebook-polish"
export EBOOK_META EBOOK_POLISH

# One real minimal EPUB (zip w/ stored `mimetype` first, per OCF). Rebuilt fresh
# for each scenario so byte-identity checks are meaningful.
EPUB_SEED="$SANDBOX/seed"
make_seed_epub() { # make_seed_epub <path>
  local dst="$1" tmp; tmp="$(mktemp -d "$SANDBOX/epubbuild.XXXXXX")"
  printf 'application/epub+zip' > "$tmp/mimetype"
  mkdir -p "$tmp/META-INF"
  printf '%s\n' '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>' > "$tmp/META-INF/container.xml"
  printf '%s\n' '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Orig Title</dc:title></metadata></package>' > "$tmp/content.opf"
  ( cd "$tmp" && zip -X -q "$dst" mimetype && zip -rX -q "$dst" META-INF content.opf )
  rm -rf "$tmp"
}

# Preview PNG (any non-empty file passes the existence/size gate).
PREVIEW="$SANDBOX/preview.png"; printf 'PNGDATA' > "$PREVIEW"
GEN_PNG="$SANDBOX/generated.png"; printf 'GENPNG' > "$GEN_PNG"

# --- job / queue writers ----------------------------------------------------
# write_queue <book_id> <epub_path> [<cand_id> <preview_path>]
write_queue() {
  local bid="$1" epub="$2" cand="${3:-}" prev="${4:-}"
  "$PY" - "$COVERS_QUEUE_DIR/$bid.json" "$bid" "$epub" "$cand" "$prev" <<'PY'
import json,sys
qf,bid,epub,cand,prev=sys.argv[1:6]
entry={"book_id":bid,"epub_path":epub,"title":"Orig Title","author":"Orig Author",
       "src_file":"x.fb2","status":"pending","candidates":[],
       "best_candidate_id":None,"confident":False,"ts":"2026-07-01T00:00:00Z"}
if cand:
    entry["candidates"]=[{"id":cand,"preview_path":prev}]
    entry["best_candidate_id"]=cand
json.dump(entry,open(qf,"w"))
PY
}

# write_job <job_file> <json...>  — pass a python dict literal as $2
write_job() { # write_job <job_file> <python-dict-expr>
  "$PY" - "$1" "$2" <<'PY'
import json,sys
jf,expr=sys.argv[1],sys.argv[2]
job=eval(expr, {"__builtins__":{}}, {})
json.dump(job,open(jf,"w"))
PY
}

reset_logs() { : > "$META_LOG"; : > "$POLISH_LOG"; : > "$ORDER_LOG"; }

# meta_argv_has <needle>  — is <needle> present as a WHOLE argv element in META_LOG?
# Reads the NUL-delimited records so an element with spaces/specials is matched
# exactly (not as a substring across a space-joined line).
meta_has_elem() { # meta_has_elem <exact-element>
  "$PY" - "$META_LOG" "$1" <<'PY'
import sys
data=open(sys.argv[1],"rb").read()
# records are '\0'-joined per invocation, invocations separated by '\n'
elems=set()
for line in data.split(b"\n"):
    if not line: continue
    for e in line.split(b"\x00"):
        if e: elems.add(e.decode("utf-8","surrogateescape"))
sys.exit(0 if sys.argv[2] in elems else 1)
PY
}

count_calls() { # count_calls <logfile> -> number of invocations (non-empty lines)
  # grep -c already prints 0 (and exits 1) on no match; swallow the exit so the
  # `0` is the ONLY thing emitted (a `|| printf 0` would append a SECOND 0).
  grep -c . "$1" 2>/dev/null || true
}

# ===========================================================================
# (b) no-edit apply job -> polish runs, ebook-meta NOT called, card resolved.
# ===========================================================================
echo "--- (b) no-edit apply job -> ebook-meta NOT called ---"
reset_logs
make_seed_epub "$EPUB_SEED-b.epub"
write_queue "bidB" "$EPUB_SEED-b.epub" "cand1" "$PREVIEW"
write_job "$COVERS_JOBS_DIR/b.json" "{'action':'apply','book_id':'bidB','chosen_candidate_id':'cand1','ts':'t'}"
apply_cover_jobs
[[ "$(count_calls "$META_LOG")" -eq 0 ]] \
  && ok "no-edit apply: ebook-meta was NOT invoked (0 calls)" \
  || bad "no-edit apply: ebook-meta must not run (got $(count_calls "$META_LOG") calls)"
[[ "$(count_calls "$POLISH_LOG")" -eq 1 ]] \
  && ok "no-edit apply: ebook-polish invoked once" \
  || bad "no-edit apply: ebook-polish call count $(count_calls "$POLISH_LOG")"
[[ ! -f "$COVERS_JOBS_DIR/b.json" ]] && ok "no-edit apply: job file consumed" || bad "no-edit apply: job not deleted"
[[ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$COVERS_QUEUE_DIR/bidB.json")" == "resolved" ]] \
  && ok "no-edit apply: queue card status=resolved" || bad "no-edit apply: card not resolved"

# ===========================================================================
# (a) + (e) edited apply job -> ebook-meta called with the right argv, BEFORE
#            polish (global ordering).
# ===========================================================================
echo ""
echo "--- (a)+(e) edited apply job -> ebook-meta right argv, BEFORE polish ---"
reset_logs
make_seed_epub "$EPUB_SEED-a.epub"
write_queue "bidA" "$EPUB_SEED-a.epub" "cand1" "$PREVIEW"
write_job "$COVERS_JOBS_DIR/a.json" \
  "{'action':'apply','book_id':'bidA','chosen_candidate_id':'cand1','edited_title':'New Title','edited_author':'Jane Roe','ts':'t'}"
apply_cover_jobs
[[ "$(count_calls "$META_LOG")" -eq 1 ]] \
  && ok "edited apply: ebook-meta invoked once" \
  || bad "edited apply: ebook-meta call count $(count_calls "$META_LOG")"
meta_has_elem "--title=New Title"  && ok "edited apply: argv has --title=New Title (one element)" || bad "edited apply: missing --title element"
meta_has_elem "--authors=Jane Roe" && ok "edited apply: argv has --authors=Jane Roe (one element)" || bad "edited apply: missing --authors element"
# ordering: first line of ORDER_LOG must be 'meta', then 'polish'.
if [[ "$(sed -n '1p' "$ORDER_LOG")" == "meta" && "$(sed -n '2p' "$ORDER_LOG")" == "polish" ]]; then
  ok "edited apply: order is meta THEN polish"
else
  bad "edited apply: order wrong ($(tr '\n' ',' < "$ORDER_LOG"))"
fi

# ===========================================================================
# (d) injection in title/author -> delivered as ONE argv element; shell inert.
#     The value carries quotes, $(...), backticks and a ;rm — if any of it were
#     evaluated by the shell, the sentinel file would be deleted / a marker made.
# ===========================================================================
echo ""
echo "--- (d) injection in title/author -> single argv, shell never executes it ---"
reset_logs
make_seed_epub "$EPUB_SEED-d.epub"
SENTINEL="$SANDBOX/DO_NOT_DELETE"; printf 'keep' > "$SENTINEL"
PWNED="$SANDBOX/PWNED"; rm -f "$PWNED"
# A title that WOULD wreak havoc under eval/interpolation:
EVIL_TITLE='a"; rm -f '"$SENTINEL"' ; touch '"$PWNED"' ; echo "x'
EVIL_AUTHOR='$(touch '"$PWNED"')`touch '"$PWNED"'`'
write_queue "bidD" "$EPUB_SEED-d.epub" "cand1" "$PREVIEW"
# Use python to embed the evil strings safely into the job JSON (no bash quoting).
EVIL_TITLE="$EVIL_TITLE" EVIL_AUTHOR="$EVIL_AUTHOR" \
"$PY" - "$COVERS_JOBS_DIR/d.json" <<'PY'
import json,os,sys
job={"action":"apply","book_id":"bidD","chosen_candidate_id":"cand1",
     "edited_title":os.environ["EVIL_TITLE"],"edited_author":os.environ["EVIL_AUTHOR"],"ts":"t"}
json.dump(job,open(sys.argv[1],"w"))
PY
apply_cover_jobs
[[ -f "$SENTINEL" ]] && ok "injection: sentinel file survived (no 'rm' executed)" || bad "injection: SENTINEL WAS DELETED — shell executed the payload!"
[[ ! -e "$PWNED" ]] && ok "injection: no 'touch \$PWNED' side effect (no \$()/backtick eval)" || bad "injection: PWNED created — command substitution ran!"
# And the evil title must have reached ebook-meta as ONE intact argv element.
meta_has_elem "--title=$EVIL_TITLE" && ok "injection: full evil title delivered as a single argv element" || bad "injection: evil title not passed verbatim as one element"

# ===========================================================================
# (c) apply_confirm (no edits) -> NO polish, NO meta; card resolved, file byte-
#     identical (agent must not touch the cover).
# ===========================================================================
echo ""
echo "--- (c) apply_confirm (no edits) -> no polish, card resolved, file untouched ---"
reset_logs
make_seed_epub "$EPUB_SEED-c.epub"
BEFORE_C="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$EPUB_SEED-c.epub")"
write_queue "bidC" "$EPUB_SEED-c.epub"
write_job "$COVERS_JOBS_DIR/c.json" "{'action':'apply_confirm','book_id':'bidC','ts':'t'}"
apply_cover_jobs
[[ "$(count_calls "$POLISH_LOG")" -eq 0 ]] && ok "apply_confirm(no-edit): ebook-polish NOT called" || bad "apply_confirm(no-edit): polish ran ($(count_calls "$POLISH_LOG"))"
[[ "$(count_calls "$META_LOG")" -eq 0 ]] && ok "apply_confirm(no-edit): ebook-meta NOT called" || bad "apply_confirm(no-edit): meta ran"
[[ ! -f "$COVERS_JOBS_DIR/c.json" ]] && ok "apply_confirm(no-edit): job consumed" || bad "apply_confirm(no-edit): job not deleted"
[[ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$COVERS_QUEUE_DIR/bidC.json")" == "resolved" ]] \
  && ok "apply_confirm(no-edit): queue card resolved (removed from pager)" || bad "apply_confirm(no-edit): card not resolved"
AFTER_C="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$EPUB_SEED-c.epub")"
[[ "$BEFORE_C" == "$AFTER_C" ]] && ok "apply_confirm(no-edit): EPUB byte-identical (cover untouched)" || bad "apply_confirm(no-edit): EPUB changed!"

# ===========================================================================
# (c2) apply_confirm WITH edits -> ebook-meta runs, NO polish, card resolved.
# ===========================================================================
echo ""
echo "--- (c2) apply_confirm WITH edits -> ebook-meta runs, NO polish, resolved ---"
reset_logs
make_seed_epub "$EPUB_SEED-c2.epub"
write_queue "bidC2" "$EPUB_SEED-c2.epub"
write_job "$COVERS_JOBS_DIR/c2.json" \
  "{'action':'apply_confirm','book_id':'bidC2','edited_title':'Confirmed','edited_author':'A B','ts':'t'}"
apply_cover_jobs
[[ "$(count_calls "$META_LOG")" -eq 1 ]] && ok "apply_confirm(edit): ebook-meta invoked once" || bad "apply_confirm(edit): meta count $(count_calls "$META_LOG")"
[[ "$(count_calls "$POLISH_LOG")" -eq 0 ]] && ok "apply_confirm(edit): ebook-polish NOT called (no cover change)" || bad "apply_confirm(edit): polish ran"
meta_has_elem "--title=Confirmed" && ok "apply_confirm(edit): title argv correct" || bad "apply_confirm(edit): title missing"
[[ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$COVERS_QUEUE_DIR/bidC2.json")" == "resolved" ]] \
  && ok "apply_confirm(edit): card resolved" || bad "apply_confirm(edit): card not resolved"

# ===========================================================================
# empty/whitespace edited fields -> treated as "no edit": meta NOT called. Guards
# the trim/skip contract (blank values must never spawn ebook-meta or a work copy).
# ===========================================================================
echo ""
echo "--- (edge) blank edited fields -> no meta (trim -> skip) ---"
reset_logs
make_seed_epub "$EPUB_SEED-w.epub"
write_queue "bidW" "$EPUB_SEED-w.epub" "cand1" "$PREVIEW"
write_job "$COVERS_JOBS_DIR/w.json" \
  "{'action':'apply','book_id':'bidW','chosen_candidate_id':'cand1','edited_title':'   ','edited_author':'','ts':'t'}"
apply_cover_jobs
[[ "$(count_calls "$META_LOG")" -eq 0 ]] && ok "blank edits: ebook-meta NOT called (whitespace trimmed away)" || bad "blank edits: meta ran on blank values"
[[ "$(count_calls "$POLISH_LOG")" -eq 1 ]] && ok "blank edits: cover still applied (polish once)" || bad "blank edits: polish count $(count_calls "$POLISH_LOG")"

# ===========================================================================
# only ONE field edited -> only that flag present (the other omitted).
# ===========================================================================
echo ""
echo "--- (edge) only title edited -> --authors flag omitted ---"
reset_logs
make_seed_epub "$EPUB_SEED-t.epub"
write_queue "bidT" "$EPUB_SEED-t.epub" "cand1" "$PREVIEW"
write_job "$COVERS_JOBS_DIR/t.json" \
  "{'action':'apply','book_id':'bidT','chosen_candidate_id':'cand1','edited_title':'Only Title','ts':'t'}"
apply_cover_jobs
meta_has_elem "--title=Only Title" && ok "single-field: --title present" || bad "single-field: --title missing"
if "$PY" - "$META_LOG" <<'PY'
import sys
data=open(sys.argv[1],"rb").read()
sys.exit(1 if b"--authors=" in data else 0)   # exit 0 == NO --authors present
PY
then ok "single-field: --authors flag omitted (not edited)"; else bad "single-field: --authors leaked in"; fi

# ===========================================================================
# (f) mv -f atomicity: a FAILED polish must leave the original EPUB byte-for-byte
#     intact (edited path — meta ran on the work copy, but polish failed -> the
#     shipped file is never mv'd over). Card -> failed.
# ===========================================================================
echo ""
echo "--- (f) polish failure -> original untouched (mv -f only on success), card=failed ---"
reset_logs
make_seed_epub "$EPUB_SEED-f.epub"
BEFORE_F="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$EPUB_SEED-f.epub")"
write_queue "bidF" "$EPUB_SEED-f.epub" "cand1" "$PREVIEW"
write_job "$COVERS_JOBS_DIR/f.json" \
  "{'action':'apply','book_id':'bidF','chosen_candidate_id':'cand1','edited_title':'Wont Land','ts':'t'}"
FAKE_POLISH_RC=1 apply_cover_jobs
AFTER_F="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$EPUB_SEED-f.epub")"
[[ "$BEFORE_F" == "$AFTER_F" ]] && ok "polish-fail: original EPUB byte-identical (mv -f never happened)" || bad "polish-fail: original was modified!"
[[ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$COVERS_QUEUE_DIR/bidF.json")" == "failed" ]] \
  && ok "polish-fail: queue card status=failed" || bad "polish-fail: card not marked failed"

# Success mutates the file (positive control for the atomicity assertion above).
echo ""
echo "--- (f2) polish success -> original REPLACED (positive control) ---"
reset_logs
make_seed_epub "$EPUB_SEED-f2.epub"
BEFORE_F2="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$EPUB_SEED-f2.epub")"
write_queue "bidF2" "$EPUB_SEED-f2.epub" "cand1" "$PREVIEW"
write_job "$COVERS_JOBS_DIR/f2.json" \
  "{'action':'apply','book_id':'bidF2','chosen_candidate_id':'cand1','edited_title':'Will Land','ts':'t'}"
apply_cover_jobs
AFTER_F2="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$EPUB_SEED-f2.epub")"
[[ "$BEFORE_F2" != "$AFTER_F2" ]] && ok "polish-ok: original replaced on success (content changed)" || bad "polish-ok: file unchanged after success"
[[ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$COVERS_QUEUE_DIR/bidF2.json")" == "resolved" ]] \
  && ok "polish-ok: card resolved" || bad "polish-ok: card not resolved"

# ===========================================================================
# meta-fail policy: ebook-meta fails but polish succeeds -> book STILL resolved
# (cover landed; a metadata slip must not strand the card).
# ===========================================================================
echo ""
echo "--- (policy) meta fails but cover lands -> card STILL resolved ---"
reset_logs
make_seed_epub "$EPUB_SEED-m.epub"
write_queue "bidM" "$EPUB_SEED-m.epub" "cand1" "$PREVIEW"
write_job "$COVERS_JOBS_DIR/m.json" \
  "{'action':'apply','book_id':'bidM','chosen_candidate_id':'cand1','edited_title':'Meta Will Fail','ts':'t'}"
FAKE_META_RC=1 apply_cover_jobs
[[ "$(count_calls "$POLISH_LOG")" -eq 1 ]] && ok "meta-fail: cover still applied (polish ran)" || bad "meta-fail: polish did not run"
[[ ! -f "$COVERS_JOBS_DIR/m.json" ]] && ok "meta-fail: job consumed" || bad "meta-fail: job not deleted"
[[ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$COVERS_QUEUE_DIR/bidM.json")" == "resolved" ]] \
  && ok "meta-fail: card STILL resolved (policy: cover wins)" || bad "meta-fail: card not resolved (policy violated)"

# meta-fail on apply_confirm -> also resolved (never strand a confirm).
reset_logs
make_seed_epub "$EPUB_SEED-mc.epub"
write_queue "bidMC" "$EPUB_SEED-mc.epub"
write_job "$COVERS_JOBS_DIR/mc.json" \
  "{'action':'apply_confirm','book_id':'bidMC','edited_title':'X','ts':'t'}"
FAKE_META_RC=1 apply_cover_jobs
[[ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$COVERS_QUEUE_DIR/bidMC.json")" == "resolved" ]] \
  && ok "meta-fail confirm: card resolved (never stranded)" || bad "meta-fail confirm: card not resolved"

# ===========================================================================
# (M1) CORRUPTING meta-fail on apply_confirm -> the confirm-only path (NO polish, so
#      it publishes the WORK copy directly) must NOT ship a torn file. Simulate a
#      Calibre crash midway through the in-place OPF rewrite: ebook-meta CLOBBERS the
#      work copy with garbage AND exits non-zero. The prior code did `mv -f work ->
#      epub` UNCONDITIONALLY, so it would overwrite the GOOD original with the broken
#      work copy. Correct behaviour: original stays BYTE-FOR-BYTE intact; card still
#      resolved (per the confirm policy). This is the check the clean-fail stub above
#      cannot make — clean-fail never touches the file, so it can't catch the mv.
echo ""
echo "--- (M1) corrupting meta-fail (confirm-only) -> ORIGINAL EPUB untouched, card resolved ---"
reset_logs
make_seed_epub "$EPUB_SEED-corrupt.epub"
BEFORE_CORRUPT="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$EPUB_SEED-corrupt.epub")"
write_queue "bidCorrupt" "$EPUB_SEED-corrupt.epub"
write_job "$COVERS_JOBS_DIR/corrupt.json" \
  "{'action':'apply_confirm','book_id':'bidCorrupt','edited_title':'Will Corrupt Work','ts':'t'}"
FAKE_META_CORRUPT=1 FAKE_META_RC=1 apply_cover_jobs
AFTER_CORRUPT="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$EPUB_SEED-corrupt.epub")"
[[ "$(count_calls "$META_LOG")" -eq 1 ]] && ok "corrupt meta-fail: ebook-meta was invoked (crash simulated)" || bad "corrupt meta-fail: ebook-meta not invoked ($(count_calls "$META_LOG"))"
[[ "$(count_calls "$POLISH_LOG")" -eq 0 ]] && ok "corrupt meta-fail: no polish (confirm-only path)" || bad "corrupt meta-fail: polish ran (should be confirm-only)"
[[ "$BEFORE_CORRUPT" == "$AFTER_CORRUPT" ]] \
  && ok "corrupt meta-fail: ORIGINAL EPUB byte-identical (broken work copy NOT published)" \
  || bad "corrupt meta-fail: ORIGINAL EPUB WAS OVERWRITTEN with the corrupt work copy (M1 regression!)"
# Belt-and-suspenders: the crashed-meta garbage marker must NOT have leaked into the
# original. (The real OPF text lives DEFLATE-compressed inside the zip, so it isn't
# grep-able as plaintext — byte-identity above is the authoritative integrity check;
# here we just assert the corrupt sentinel never overwrote the file.)
if "$PY" - "$EPUB_SEED-corrupt.epub" <<'PY'
import sys
data=open(sys.argv[1],"rb").read()
sys.exit(0 if b"CORRUPTED-BY-CRASHED-EBOOK-META" not in data else 1)
PY
then ok "corrupt meta-fail: garbage marker absent from original (not clobbered)"; else bad "corrupt meta-fail: corrupt marker found in original — it WAS clobbered"; fi
[[ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$COVERS_QUEUE_DIR/bidCorrupt.json")" == "resolved" ]] \
  && ok "corrupt meta-fail: card STILL resolved (confirm policy honoured)" || bad "corrupt meta-fail: card not resolved"
[[ ! -f "$COVERS_JOBS_DIR/corrupt.json" ]] && ok "corrupt meta-fail: job consumed" || bad "corrupt meta-fail: job not deleted"
# M2 hygiene: no .fb2work.* / .fb2polish.* temp left orphaned next to the target.
leftover_tmp="$(find "$(dirname "$EPUB_SEED-corrupt.epub")" -maxdepth 1 \( -name '.fb2work.*' -o -name '.fb2polish.*' \) 2>/dev/null | wc -l | tr -d ' ')"
[[ "$leftover_tmp" -eq 0 ]] && ok "corrupt meta-fail: no orphaned .fb2work/.fb2polish temp beside the EPUB" || bad "corrupt meta-fail: $leftover_tmp orphaned temp file(s) left behind"

# ===========================================================================
# back-compat: an OLD-shape apply job with NO edited_* fields behaves exactly as
# before (polish only, no meta). Same as (b) but asserts the plan/executor treat a
# job that never had the new keys identically — the M1 back-compat contract.
# ===========================================================================
echo ""
echo "--- (back-compat) apply_generated legacy job -> polish only, card dropped ---"
reset_logs
make_seed_epub "$EPUB_SEED-g.epub"
write_queue "bidG" "$EPUB_SEED-g.epub"
write_job "$COVERS_JOBS_DIR/g.json" "{'action':'apply_generated','book_id':'bidG','png':'$GEN_PNG','ts':'t'}"
apply_cover_jobs
[[ "$(count_calls "$META_LOG")" -eq 0 ]] && ok "legacy apply_generated: no ebook-meta" || bad "legacy apply_generated: meta ran"
[[ "$(count_calls "$POLISH_LOG")" -eq 1 ]] && ok "legacy apply_generated: polish once" || bad "legacy apply_generated: polish count $(count_calls "$POLISH_LOG")"
[[ ! -f "$COVERS_QUEUE_DIR/bidG.json" ]] && ok "legacy apply_generated: queue card removed (done)" || bad "legacy apply_generated: card not removed"

# edited apply_generated -> meta before polish, card removed.
echo ""
echo "--- edited apply_generated -> meta THEN polish, card removed ---"
reset_logs
make_seed_epub "$EPUB_SEED-ge.epub"
write_queue "bidGE" "$EPUB_SEED-ge.epub"
write_job "$COVERS_JOBS_DIR/ge.json" \
  "{'action':'apply_generated','book_id':'bidGE','png':'$GEN_PNG','edited_author':'Gen Author','ts':'t'}"
apply_cover_jobs
[[ "$(count_calls "$META_LOG")" -eq 1 ]] && ok "edited apply_generated: meta ran" || bad "edited apply_generated: meta count $(count_calls "$META_LOG")"
if [[ "$(sed -n '1p' "$ORDER_LOG")" == "meta" && "$(sed -n '2p' "$ORDER_LOG")" == "polish" ]]; then
  ok "edited apply_generated: order meta THEN polish"; else bad "edited apply_generated: order wrong ($(tr '\n' ',' < "$ORDER_LOG"))"; fi
meta_has_elem "--authors=Gen Author" && ok "edited apply_generated: --authors argv correct" || bad "edited apply_generated: --authors missing"
[[ ! -f "$COVERS_QUEUE_DIR/bidGE.json" ]] && ok "edited apply_generated: card removed" || bad "edited apply_generated: card not removed"

# ===========================================================================
# static: no eval/interpolation of job values into a command (R1 belt-and-suspenders).
# The apply path must never `eval` a decoded value nor build a command string from
# title/author. We assert the shipping source uses only argv vectors + base64.
# ===========================================================================
echo ""
echo "--- (static) R1: apply path uses argv+base64, never eval of a decoded value ---"
APPLY_BLOCK="$(awk '/^apply_cover_jobs\(\) \{/{g=1} g{print} g&&/^\}/{exit}' "$WATCHER")"
if printf '%s\n' "$APPLY_BLOCK" | grep -qE '\beval\b'; then
  bad "R1: apply_cover_jobs contains eval (must not)"
else
  ok "R1: apply_cover_jobs contains no eval"
fi
# apply_meta_into_epub builds a `meta_args` argv vector and calls "$EBOOK_META" "${meta_args[@]}".
if grep -q 'meta_args+=("--title=$t")' "$WATCHER" && grep -q '"\$EBOOK_META" "\${meta_args\[@\]}"' "$WATCHER"; then
  ok "R1: ebook-meta invoked via argv vector (\"\${meta_args[@]}\")"
else
  bad "R1: ebook-meta not invoked via a clean argv vector"
fi

echo ""
echo "==> $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
