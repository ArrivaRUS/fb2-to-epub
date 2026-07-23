#!/bin/bash
# run-fda-probe-tests.sh — locks the FDA folder-access detect in the agent
# (probe_watch_dir_access() + folder_access_state() in bin/fb2-to-epub-watcher.sh).
#
# WHY this exists (feature v1.0.1, D46 / arch/plan-fda-synthesis.md)
# -----------------------------------------------------------------
# A background agent without Full Disk Access silently can't read the watch dir, so
# books never convert and the app looked "working". The agent is now the honest
# witness: every run it listdir()s WATCH_DIR and publishes a tristate
# agent.folder_access = ok|denied|missing (+ _ts) into state.json, and pops the app
# once on a ->denied edge. R1 (validation-first) already proved on a REAL launchd
# agent without FDA that the probe returns "denied"; THIS suite locks the function
# contract deterministically without launchd/Calibre/network/TCC.
#
# WHAT this guards (no launchctl, no bootstrap — lesson 018: detect tests don't need
# them): both functions are extracted VERBATIM from the shipping watcher (anchored on
# `^probe_watch_dir_access() {` / `^folder_access_state() {` .. column-0 `}`, like
# run-sticky-batch-test.sh extracts batch_state), sourced into a sandbox, and driven
# directly against a private STATE_FILE / throwaway WATCH_DIR. If someone edits the
# probe/writer logic, this breaks.
#
# ISOLATION: everything lives under a mktemp sandbox. The suite is bracketed by the
# shared prod-guard (lib-prod-guard.sh) — the user's real plist/state.json/log/covers
# must be byte-untouched, and our unique sandbox path must never leak into them.
# chmod-000 simulations run on a THROWAWAY parent and are restored via trap (018).
#
# Usage:  bash tests/run-fda-probe-tests.sh
# Exit:   0 = all green, 1 = a check failed (or python3/extraction missing).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHER="$REPO_DIR/bin/fb2-to-epub-watcher.sh"
[[ -f "$WATCHER" ]] || { echo "missing $WATCHER" >&2; exit 1; }

# python3 the same way the watcher / sibling tests do. Both functions no-op without
# an executable PYTHON3, so a missing interpreter would "pass" vacuously — fail loud.
PY="${PYTHON3:-}"
if [[ -z "$PY" || ! -x "$PY" ]]; then
  for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [[ -x "$cand" ]] && { PY="$cand"; break; }
  done
fi
[[ -z "$PY" || ! -x "$PY" ]] && PY="$(command -v python3 2>/dev/null || true)"
[[ -n "$PY" && -x "$PY" ]] || { echo "run-fda-probe: python3 not found" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL - %s\n' "$1"; }
expect() { if [[ "$2" == "$3" ]]; then ok "$1 -> $3"; else bad "$1 -> got=$3 want=$2"; fi; }

# --- prod-guard (lesson 018): snapshot boevoy artifacts BEFORE the suite ----------
# shellcheck disable=SC1091
source "$REPO_DIR/tests/lib-prod-guard.sh"
prod_guard_begin

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/fda-probe.XXXXXX")"
cleanup() {
  # Restore any chmod-000 dirs so rm can recurse (belt-and-suspenders over the
  # per-test restores below), then drop the sandbox.
  chmod -R u+rwx "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

echo "==> FDA probe: probe_watch_dir_access() + folder_access_state() contract"
echo ""

# ---------------------------------------------------------------------------
# Extract BOTH functions VERBATIM and source them.
# ---------------------------------------------------------------------------
FN_FILE="$SANDBOX/fda_fns.sh"
awk '/^probe_watch_dir_access\(\) \{/{g=1} g{print} g&&/^\}/{exit}' "$WATCHER"  > "$FN_FILE"
echo "" >> "$FN_FILE"
awk '/^folder_access_state\(\) \{/{g=1} g{print} g&&/^\}/{exit}'  "$WATCHER" >> "$FN_FILE"

if grep -q '^probe_watch_dir_access() {' "$FN_FILE" \
   && grep -q '^folder_access_state() {' "$FN_FILE" \
   && [[ "$(grep -c '^}' "$FN_FILE")" -eq 2 ]] \
   && grep -q "<<'PY'" "$FN_FILE"; then
  ok "extract both functions from watcher (anchors + heredoc found)"
else
  bad "extract both functions from watcher (anchors + heredoc found)"
  echo ""; echo "==> $PASS passed, $FAIL failed"; exit 1
fi

# Pin the branches we exercise so a rename can't make checks vacuous.
grep -q 'PermissionError'                  "$FN_FILE" && ok "probe branch: PermissionError -> denied present" || bad "probe branch PermissionError"
grep -q 'ENOENT'                           "$FN_FILE" && ok "probe branch: ENOENT -> missing present"          || bad "probe branch ENOENT"
grep -q 'folder_access'                    "$FN_FILE" && ok "writer sets folder_access"                        || bad "writer folder_access"
grep -q 'folder_access_ts'                 "$FN_FILE" && ok "writer sets folder_access_ts"                     || bad "writer folder_access_ts"
grep -Eq 'access == "denied" and prev'     "$FN_FILE" && ok "writer edge: prev!=denied -> POP present"         || bad "writer edge POP"

# shellcheck disable=SC1090
source "$FN_FILE"

# ---------------------------------------------------------------------------
# Harness. Both functions read PYTHON3/LOG_FILE from env; folder_access_state()
# also calls log() and (on a ->denied edge) `open -b` in the background — we stub
# `open` on PATH so no real app is raised, and provide a log() -> LOG_FILE.
# ---------------------------------------------------------------------------
export PYTHON3="$PY"
LOG_FILE="$SANDBOX/watcher.log"; export LOG_FILE
: > "$LOG_FILE"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

STUB_BIN="$SANDBOX/bin"; mkdir -p "$STUB_BIN"
OPEN_CALLS="$SANDBOX/open.calls"; : > "$OPEN_CALLS"
cat > "$STUB_BIN/open" <<SH
#!/bin/bash
printf 'OPEN %s\n' "\$*" >> "$OPEN_CALLS"
SH
chmod +x "$STUB_BIN/open"
export PATH="$STUB_BIN:$PATH"

read_fa() {   # print "<folder_access>,<folder_access_ts>"
  "$PY" - "$1" <<'PY'
import json,sys
try:
    a=json.load(open(sys.argv[1])).get("agent") or {}
    print(f'{a.get("folder_access")},{a.get("folder_access_ts")}')
except Exception as e:
    print(f'ERR({e})')
PY
}
read_field() {   # read_field <file> <dotted.path>
  "$PY" - "$1" "$2" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d=d[k]
print(d)
PY
}
edge_count() { grep -c 'folder_access: -> denied (edge)' "$LOG_FILE"; }

# ===========================================================================
# PROBE — ok / denied / missing over fixture trees.
# ===========================================================================
echo ""
echo "--- probe: ok / denied / missing ---"

# ok — empty dir.
WD="$SANDBOX/wd_empty"; mkdir -p "$WD"
expect "probe ok (empty dir)" "ok" "$(WATCH_DIR="$WD" probe_watch_dir_access)"

# ok — dir with files (a non-empty successful listdir is still ok).
WD="$SANDBOX/wd_files"; mkdir -p "$WD"; touch "$WD/a.fb2" "$WD/b.epub"
expect "probe ok (with files)" "ok" "$(WATCH_DIR="$WD" probe_watch_dir_access)"

# denied — chmod 000 on the PARENT (Codex's more-TCC-faithful sim: the child can't
# be traversed -> EACCES). Restored via trap so an abort can't leave a locked dir.
PARENT="$SANDBOX/p_denied"; CHILD="$PARENT/watch"
mkdir -p "$CHILD"; touch "$CHILD/book.fb2"
restore_parent() { chmod 755 "$PARENT" 2>/dev/null || true; }
trap 'restore_parent; cleanup' EXIT
chmod 000 "$PARENT"
expect "probe denied (chmod 000 on parent)" "denied" "$(WATCH_DIR="$CHILD" probe_watch_dir_access)"
restore_parent
trap cleanup EXIT
# denied still reachable via chmod 000 on the dir ITSELF (EACCES on the dir).
WD="$SANDBOX/wd_denied2"; mkdir -p "$WD"; chmod 000 "$WD"
expect "probe denied (chmod 000 on dir itself)" "denied" "$(WATCH_DIR="$WD" probe_watch_dir_access)"
chmod 755 "$WD"

# missing — ENOENT (never-created path).
expect "probe missing (ENOENT)" "missing" "$(WATCH_DIR="$SANDBOX/nope" probe_watch_dir_access)"

# missing — ENOTDIR (a regular file used as the watch dir).
touch "$SANDBOX/afile"
expect "probe missing (ENOTDIR, file as dir)" "missing" "$(WATCH_DIR="$SANDBOX/afile" probe_watch_dir_access)"

# no python3 -> empty (caller no-ops).
expect "probe no-op without python3" "" "$(PYTHON3=/nonexistent probe_watch_dir_access)"

# ===========================================================================
# WRITER — RMW preserves siblings, sets fields, ts monotonic, unknown no-op.
# ===========================================================================
echo ""
echo "--- writer: RMW preserves siblings + sets folder_access(+_ts) ---"
SF="$SANDBOX/state.json"; export STATE_FILE="$SF"
printf '%s' '{"schema":1,"agent":{"watch_dir":"/Users/x/Desktop/fb2-to-epub"},"totals":{"converted_total":54,"today":3},"recent":[{"src":"a.fb2","dst":"a.epub"}],"batch":{"active":true,"total":9,"done":4}}' > "$SF"
folder_access_state "denied"
FA="$(read_fa "$SF")"
[[ "${FA%%,*}" == "denied" ]] && ok "writer set folder_access=denied ($FA)" || bad "writer folder_access ($FA)"
expect "sibling schema preserved"          "1"                                "$(read_field "$SF" schema)"
expect "sibling agent.watch_dir preserved" "/Users/x/Desktop/fb2-to-epub"     "$(read_field "$SF" agent.watch_dir)"
expect "sibling totals.converted_total"    "54"                               "$(read_field "$SF" totals.converted_total)"
expect "sibling batch.total preserved"     "9"                                "$(read_field "$SF" batch.total)"

echo ""
echo "--- writer: unknown access value is a no-op (contract stays clean) ---"
BEFORE="$(read_fa "$SF")"
folder_access_state "garbage" || true
expect "unknown access -> state unchanged" "$BEFORE" "$(read_fa "$SF")"

echo ""
echo "--- writer: ts is refreshed on every run (proof-of-fresh-check) ---"
SF2="$SANDBOX/state2.json"; export STATE_FILE="$SF2"; : > "$SF2"
folder_access_state "ok"; TS1="$(read_fa "$SF2")"; TS1="${TS1#*,}"
"$PY" - <<'PY'
import time; time.sleep(1.1)
PY
folder_access_state "ok"; TS2="$(read_fa "$SF2")"; TS2="${TS2#*,}"
if [[ -n "$TS1" && -n "$TS2" && "$TS2" > "$TS1" ]]; then ok "folder_access_ts advances across runs ($TS1 -> $TS2)"
else bad "folder_access_ts must advance ($TS1 -> $TS2)"; fi

echo ""
echo "--- writer: missing state.json -> created from scratch ---"
SF3="$SANDBOX/state3.json"; export STATE_FILE="$SF3"; rm -f "$SF3"
folder_access_state "missing"
expect "missing state.json -> folder_access=missing" "missing" "$(read_field "$SF3" agent.folder_access)"

# ===========================================================================
# EDGE-POP — the ->denied transition raises the app EXACTLY once per rising edge.
# ===========================================================================
echo ""
echo "--- edge-pop: prev!=denied -> denied fires once; denied->denied no re-pop ---"
SFE="$SANDBOX/state_edge.json"; export STATE_FILE="$SFE"; : > "$SFE"
: > "$LOG_FILE"

folder_access_state "denied"   # prev=absent (nil) != denied -> EDGE #1
expect "edge count after 1st denied (from nil)" "1" "$(edge_count)"
folder_access_state "denied"   # prev=denied -> NO edge
expect "edge count after 2nd denied (no re-pop)" "1" "$(edge_count)"
folder_access_state "ok"       # denied -> ok: no edge (success is self-evident)
expect "edge count after denied->ok (no pop)" "1" "$(edge_count)"
folder_access_state "denied"   # prev=ok != denied -> EDGE #2
expect "edge count after ok->denied (re-armed)" "2" "$(edge_count)"

# The backgrounded `open -b` must have hit our stub, not a real app. It is async
# (backgrounded + disowned), so poll briefly rather than race it.
for _ in $(seq 1 20); do [[ "$(grep -c . "$OPEN_CALLS" 2>/dev/null || echo 0)" -ge 1 ]] && break; sleep 0.1; done
if [[ "$(grep -c 'com.arrivarus.fb2toepub' "$OPEN_CALLS" 2>/dev/null || echo 0)" -ge 1 ]]; then
  ok "edge-pop reached the open stub (open -b com.arrivarus.fb2toepub), not a real app"
else
  bad "edge-pop did not reach the open stub"
fi

# ===========================================================================
# prod-guard: boevoy artifacts untouched + no sandbox leak.
# ===========================================================================
echo ""
echo "--- prod-guard: boevoy artifacts untouched (lesson 018) ---"
prod_guard_end "$SANDBOX" || true
PASS=$((PASS + PG_PASS)); FAIL=$((FAIL + PG_FAIL))

echo ""
echo "==> $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
