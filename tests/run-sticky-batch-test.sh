#!/bin/bash
# run-sticky-batch-test.sh — locks the "sticky batch" fix in the progress-ring
# state machine (batch_state() in bin/fb2-to-epub-watcher.sh).
#
# WHY this exists
# ---------------
# One logical batch of N files triggers SEVERAL launchd fires: each cover
# apply-job lands in covers/jobs (a WatchPaths change) and each .epub written
# into the watch dir is itself a WatchPaths change. Every fire recomputes
# pending = count_pending() = the REMAINING unconverted count and calls
# `batch_state begin "$pending"`.
#
# The bug: the old code did an UNCONDITIONAL begin -> {active,total=pending,
# done=0}. So a fire LANDING MID-BATCH reset {total:15,done:4} to
# {total:11,done:0} and the ring visibly jumped backwards / "stuck" restarting
# from the remainder. The fix makes `begin` decide continuation-vs-new from the
# on-disk batch and NEVER rewind `done` or shrink `total` mid-batch.
#
# WHAT this guards (no launchctl, no Calibre, no network, no Desktop, no full
# watcher run): the `batch_state()` function is extracted VERBATIM from the
# shipping watcher (anchored on `^batch_state() {` .. column-0 `}`, like
# run-fb2-regression-test.sh extracts epub_name/convert_book), sourced into a
# sandbox shell, and driven directly with controlled (mode, arg) pairs against a
# private STATE_FILE. So the test tracks the REAL shipping state machine — if
# someone edits the begin/tick/end logic, this breaks.
#
# batch_state()'s entire contract is: argv = (mode, total_arg); env = STATE_FILE,
# PYTHON3, LOG_FILE; effect = read-modify-write STATE_FILE's "batch" object,
# preserving every sibling field. It has NO dependency on count_pending /
# WATCH_DIR / Calibre, which is exactly why it can be unit-tested in isolation.
#
# Usage:  bash tests/run-sticky-batch-test.sh
# Exit:   0 = all green, 1 = a check failed (or python3/extraction missing).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHER="$REPO_DIR/bin/fb2-to-epub-watcher.sh"
[[ -f "$WATCHER" ]] || { echo "missing $WATCHER" >&2; exit 1; }

# Resolve python3 the same way the watcher / run-fb3-tests.sh do (env override
# -> common paths -> PATH). batch_state() no-ops without an executable PYTHON3,
# so a missing interpreter would silently "pass" every check — fail loudly.
PY="${PYTHON3:-}"
if [[ -z "$PY" || ! -x "$PY" ]]; then
  for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [[ -x "$cand" ]] && { PY="$cand"; break; }
  done
fi
[[ -z "$PY" || ! -x "$PY" ]] && PY="$(command -v python3 2>/dev/null || true)"
[[ -n "$PY" && -x "$PY" ]] || { echo "run-sticky-batch: python3 not found" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL - %s\n' "$1"; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sticky-batch.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

echo "==> Sticky batch: batch_state() must not rewind/reset the ring mid-batch"
echo ""

# ---------------------------------------------------------------------------
# Extract batch_state() VERBATIM and source it. awk grabs from the
# `batch_state() {` line through its matching column-0 closing `}` (the inner
# python heredoc terminator is indented ` PY`, so it does NOT match `^}`).
# ---------------------------------------------------------------------------
FN_FILE="$SANDBOX/batch_state.sh"
awk '
  /^batch_state\(\) \{/ {grab=1}
  grab {print}
  grab && /^\}/ {exit}
' "$WATCHER" > "$FN_FILE"

if [[ ! -s "$FN_FILE" ]] || ! grep -q '^batch_state() {' "$FN_FILE" \
   || ! grep -q '^}' "$FN_FILE" || ! grep -q "<<'PY'" "$FN_FILE"; then
  bad "extract batch_state() from watcher (anchors + heredoc found)"
  echo ""
  echo "==> $PASS passed, $FAIL failed"
  exit 1
fi
ok "extract batch_state() from watcher (anchors + heredoc found)"

# Sanity-pin the THREE branches we exercise still exist in the extracted body,
# so a refactor that renames a mode can't make the behaviour checks vacuous.
for mode in begin tick end; do
  if grep -Eq "mode == \"$mode\"" "$FN_FILE"; then ok "branch '$mode' present in batch_state"
  else bad "branch '$mode' present in batch_state"; fi
done

# shellcheck disable=SC1090
source "$FN_FILE"

# ---------------------------------------------------------------------------
# Harness: a private STATE_FILE per scenario + helpers to seed/read it.
# batch_state() reads $STATE_FILE/$PYTHON3/$LOG_FILE from the environment.
# ---------------------------------------------------------------------------
export PYTHON3="$PY"
LOG_FILE="$SANDBOX/watcher.log"; export LOG_FILE
: > "$LOG_FILE"

SF=""                       # current scenario's state file
SF_N=0                      # monotonic id -> a unique file per scenario
new_state() {               # fresh empty state file for the next scenario
  SF_N=$((SF_N+1))
  SF="$SANDBOX/state.$SF_N.json"
  : > "$SF"                 # start empty (state={} -> no prior batch)
  STATE_FILE="$SF"; export STATE_FILE
}

# seed_batch <active true|false> <total> <done>  -> write {"batch":{...}}
seed_batch() {
  "$PY" - "$SF" "$1" "$2" "$3" <<'PY'
import json,sys
f,active,total,done=sys.argv[1:5]
json.dump({"batch":{"active":active=="true","total":int(total),"done":int(done)}},open(f,"w"))
PY
}

# seed_raw <json>  -> write arbitrary state (corrupt-input / sibling-field tests)
seed_raw() { printf '%s' "$1" > "$SF"; }

# read_batch -> "active,total,done" (or NO_BATCH(...) on any failure)
read_batch() {
  "$PY" - "$SF" <<'PY'
import json,sys
try:
    b=json.load(open(sys.argv[1])).get("batch") or {}
    print(f'{bool(b.get("active"))},{int(b.get("total",0) or 0)},{int(b.get("done",0) or 0)}')
except Exception as e:
    print(f'NO_BATCH({e})')
PY
}

# read_field <dotted.path> -> value (for sibling-field preservation check)
read_field() {
  "$PY" - "$SF" "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d=d[k]
print(d)
PY
}

expect() { # expect <label> <want> <got>
  if [[ "$2" == "$3" ]]; then ok "$1 -> $3"
  else bad "$1 -> got=$3 want=$2"; fi
}

# ===========================================================================
# (в) NEW batch on clean state -> begin as before: total=pending, done=0.
# ===========================================================================
echo ""
echo "--- (в) new batch on clean state -> total=pending, done:0 ---"
new_state                       # empty file -> state={} -> no prior batch
seed_batch false 0 0            # explicit inactive baseline
batch_state begin 7             # 7 pending discovered
expect "begin on clean -> {active,total=7,done=0}" "True,7,0" "$(read_batch)"

# ===========================================================================
# (а) mid-batch {15,4} + RE-FIRE, NO new files -> total stays 15, done kept,
#     NOT reset. (pending this fire = remaining = 15-4 = 11.)
# ===========================================================================
echo ""
echo "--- (а) mid-batch {15,4} + re-fire (pending=11, no new files) ---"
new_state
seed_batch true 15 4
batch_state begin 11            # remaining 11, no growth: 4+11 == 15
expect "begin keeps total=15, done stays 4 (NOT reset to {11,0})" "True,15,4" "$(read_batch)"
# A second mid-batch fire (e.g. fewer remain after some ticks) still must not rewind.
batch_state begin 11
expect "repeat begin still {15,4} (idempotent, no drift)" "True,15,4" "$(read_batch)"

# ===========================================================================
# (б) mid-batch {15,4} + DROP new files -> total grows, done kept.
#     pending jumps to 16 (11 orig remainder + 5 new): 4+16 = 20 > 15 -> grow.
# ===========================================================================
echo ""
echo "--- (б) mid-batch {15,4} + 5 new files dropped (pending=16) ---"
new_state
seed_batch true 15 4
batch_state begin 16            # 4 + 16 = 20 > 15 -> grow to 20, done kept
expect "begin grows total 15->20, done stays 4 (done+pending>total)" "True,20,4" "$(read_batch)"

# Conservative hold: pending shrank below the remainder (e.g. a pending file
# vanished). projected (4+9=13) < prev_total(15) -> hold total at 15, never shrink.
new_state
seed_batch true 15 4
batch_state begin 9
expect "begin holds total=15 when projected<prev (no shrink)" "True,15,4" "$(read_batch)"

# ===========================================================================
# (г) FINISHED batch {false,15,15} + idle fire -> untouched.
#     An idle/holdout fire (pending==0) is guarded at the CALL SITE, not inside
#     batch_state: the watcher only calls `batch_state begin` under
#     `pending_total > 0`, and only calls `batch_state end` when batch_started==1
#     (a flag set in that same >0 block). So on an idle fire NEITHER begin nor
#     end runs and the batch field is left exactly as-is. We lock that guard
#     STATICALLY over the shipping source (like run-fb2-regression-test.sh does
#     for convert_book) — asserting it via batch_state(begin,0) would test a
#     contract the function does not have (begin always (re)writes batch).
# ===========================================================================
echo ""
echo "--- (г) idle fire (pending==0) -> batch untouched (call-site guard) ---"
# (г1) `begin` is reached ONLY under `pending_total > 0`.
if grep -Eq '\[\[[[:space:]]+"\$pending_total"[[:space:]]+-gt[[:space:]]+0[[:space:]]+\]\]' "$WATCHER" \
   && awk '
       /\[\[[[:space:]]+"\$pending_total"[[:space:]]+-gt[[:space:]]+0[[:space:]]+\]\]/ {g=1}
       g {print}
       g && /^fi$/ {exit}
     ' "$WATCHER" | grep -q 'batch_state begin'; then
  ok "watcher gates 'batch_state begin' behind pending_total>0 (idle fire skips begin)"
else
  bad "watcher gates 'batch_state begin' behind pending_total>0 (idle fire skips begin)"
fi
# (г2) `end` (release_batch) is reached ONLY when a batch was actually started.
if awk '
      /^release_batch\(\) \{/ {g=1}
      g {print}
      g && /^\}/ {exit}
    ' "$WATCHER" | grep -Eq 'batch_started.*-eq 1.*\|\|.*return'; then
  ok "release_batch returns early unless batch_started==1 (idle fire skips end)"
else
  bad "release_batch returns early unless batch_started==1 (idle fire skips end)"
fi
# (г3) Behavioural: the path that DOES run on a finished/idle fire is `end` with
# pending=0 against an already-inactive batch — it must stay inactive, untouched.
new_state
seed_batch false 15 15
batch_state end 0
expect "end(0) on finished {false,15,15} leaves it untouched" "False,15,15" "$(read_batch)"
# (г4) A finished-but-still-active stale snapshot (done>=total) is treated as a
# NEW batch by begin (not a continuation) -> clean restart on real new pending.
new_state
seed_batch true 15 15           # active, but done==total -> stale
batch_state begin 3
expect "stale active done>=total -> begin starts fresh {3,0}" "True,3,0" "$(read_batch)"

# ===========================================================================
# (д) intermediate fire that converted NOTHING -> active stays true.
#     Simulate a fire that applied a cover-job only: begin(continuation) then
#     end(pending>0) with done<total. end must NOT flip active to false.
# ===========================================================================
echo ""
echo "--- (д) intermediate fire (nothing converted) -> active stays true ---"
new_state
seed_batch true 15 4
batch_state begin 11            # continuation, {15,4}
# no tick this fire (conversion produced nothing / only a cover applied)
batch_state end 11              # pending still 11 (>0) and done(4)<total(15)
expect "end on intermediate fire keeps active:true {15,4}" "True,15,4" "$(read_batch)"

# ===========================================================================
# (е) end gates: closes the batch iff done>=total OR pending==0.
# ===========================================================================
echo ""
echo "--- (е) end closes iff done>=total OR pending==0 ---"
# (е1) done reached total -> close even if pending arg is nonzero (defensive).
new_state
seed_batch true 15 15
batch_state end 3
expect "end closes when done>=total (15>=15)" "False,15,15" "$(read_batch)"
# (е2) nothing left pending this fire -> close even with done<total.
new_state
seed_batch true 15 9
batch_state end 0
expect "end closes when pending==0 (even if done<total)" "False,15,9" "$(read_batch)"
# (е3) neither condition -> stay active (already covered in (д), re-assert tightly).
new_state
seed_batch true 15 9
batch_state end 6
expect "end stays active when done<total AND pending>0" "True,15,9" "$(read_batch)"

# ===========================================================================
# tick: advances only an ACTIVE batch and caps at total (ring never exceeds 100%).
# ===========================================================================
echo ""
echo "--- tick: advances active, caps at total, no-op when inactive ---"
new_state
seed_batch true 5 3
batch_state tick
expect "tick advances done 3->4 on active batch" "True,5,4" "$(read_batch)"
batch_state tick                # ->5 (== total)
batch_state tick                # would be 6 -> capped at total 5
expect "tick caps done at total (never >100%)" "True,5,5" "$(read_batch)"
new_state
seed_batch false 5 2
batch_state tick
expect "tick is a no-op on an INACTIVE batch" "False,5,2" "$(read_batch)"

# ===========================================================================
# A FULL sticky lifecycle: begin(new) -> ticks -> mid-batch re-fire begin
# (the exact bug) -> more ticks -> end. The ring must climb monotonically to 3/3.
# ===========================================================================
echo ""
echo "--- full lifecycle: begin->tick->[mid re-fire begin]->tick->end == 3/3 ---"
new_state
seed_batch false 0 0
batch_state begin 3             # new batch of 3 -> {3,0}
batch_state tick                # {3,1}
expect "after 1 convert -> {3,1}" "True,3,1" "$(read_batch)"
batch_state begin 2             # MID-BATCH re-fire (1 done, 2 remain): must hold
expect "mid-batch re-fire holds {3,1} (the bug would reset to {2,0})" "True,3,1" "$(read_batch)"
batch_state tick                # {3,2}
batch_state tick                # {3,3}
batch_state end 0               # nothing left -> close at 3/3
expect "lifecycle ends finished at 3/3" "False,3,3" "$(read_batch)"

# ===========================================================================
# Sibling-field preservation: batch_state() read-modify-writes; it must NOT
# clobber other top-level keys (the real state.json also holds conversion
# history, version, etc.). Atomic write keeps them intact.
# ===========================================================================
echo ""
echo "--- robustness: preserve sibling fields, survive corrupt/empty state ---"
new_state
seed_raw '{"version":7,"history":["a","b"],"batch":{"active":true,"total":15,"done":4}}'
batch_state begin 11
expect "sibling 'version' preserved" "7" "$(read_field version)"
expect "sibling 'history' preserved" "['a', 'b']" "$(read_field history)"
expect "batch still updated correctly alongside siblings" "True,15,4" "$(read_batch)"

# Corrupt JSON -> batch_state starts from a clean batch (doesn't crash the ring).
new_state
seed_raw '{ this is not json'
batch_state begin 4
expect "corrupt state.json -> begin recovers to {4,0}" "True,4,0" "$(read_batch)"

# Non-object JSON (array) -> treated as empty -> clean begin.
new_state
seed_raw '[1,2,3]'
batch_state begin 2
expect "non-object state.json -> begin recovers to {2,0}" "True,2,0" "$(read_batch)"

# Missing file entirely -> clean begin (first-ever run).
new_state
rm -f "$SF"
batch_state begin 5
expect "missing state.json -> begin creates {5,0}" "True,5,0" "$(read_batch)"

# Unknown mode -> writes NOTHING (must not corrupt an in-flight batch).
new_state
seed_batch true 15 4
batch_state frobnicate 99 || true
expect "unknown mode is a no-op (state untouched)" "True,15,4" "$(read_batch)"

echo ""
echo "==> $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
