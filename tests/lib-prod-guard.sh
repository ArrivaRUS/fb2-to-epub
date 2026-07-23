#!/bin/bash
# lib-prod-guard.sh — shared snapshot-guard for the user's LIVE (boevoy) fb2-to-epub
# artifacts (lesson .patches/018, rule #1). Source this in any runner that spawns
# processes with HOME-derived paths or could — via a bug — write to the real files,
# and bracket the suite with prod_guard_begin / prod_guard_end "<sandbox_root>".
#
# The class it closes ("a test reached the boevoy files") recurred THREE times
# (015 → B1 → H1). 018 mandates: snapshot the real artifacts BEFORE the suite and
# compare AFTER; a mismatch is a RED test, not a silent leak.
#
# What it protects (the user's real, in-use files):
#   • ~/Library/LaunchAgents/com.arrivarus.fb2toepub*.plist   (FDA grant lives in the
#     runner path referenced here — a rewrite would drop the grant, lesson 015)
#   • ~/Library/Application Support/fb2-to-epub/state/state.json  (D13: agent-owned)
#   • ~/Library/Application Support/fb2-to-epub/covers/jobs/      (agent queue)
#   • ~/Library/Logs/fb2-to-epub.log                             (leak-checked, see below)
#
# TWO layers, so the guard is leak-tight WITHOUT false-failing on a coincidental
# external agent fire (the boevoy agent is event-driven; it may run a harmless
# no-op cycle mid-suite and append a bare "run start/run end" to the log — that is
# NOT a leak from the test):
#   1. STRICT  — plist(s) identical + state.json identical AFTER normalizing out the one
#                field a harmless boevoy fire bumps on EVERY run: agent.folder_access_ts
#                (v1.0.1's FDA probe writes it each cycle, so a raw sha would false-FAIL on
#                a coincidental external fire). The plist is never rewritten by a run, and
#                state.json MINUS that ts is not either by a no-op cycle — so equality here
#                stays safe and still catches any REAL mutation (totals, batch, recent, the
#                folder_access VALUE itself, …). Falls back to a raw sha if python3 is absent.
#   2. LEAK    — the caller's UNIQUE sandbox root (a random mktemp path) must appear
#                in NONE of the boevoy files (log/state/covers/plist). This catches a
#                test that mistakenly used a boevoy path even when the boevoy agent
#                also fired. The log's mtime is deliberately NOT compared (flaky);
#                only a leak of our own marker fails the log check.
#
# Usage:
#   source "$(dirname "$0")/lib-prod-guard.sh"
#   prod_guard_begin
#   ... run suite in a throwaway sandbox under $SANDBOX ...
#   prod_guard_end "$SANDBOX"      # prints ok/FAIL lines; returns nonzero on breach

# All boevoy paths in one place (real HOME — never overridden here on purpose).
PG_LA_DIR="$HOME/Library/LaunchAgents"
PG_APP_SUPPORT="$HOME/Library/Application Support/fb2-to-epub"
PG_STATE_JSON="$PG_APP_SUPPORT/state/state.json"
PG_COVERS_JOBS="$PG_APP_SUPPORT/covers/jobs"
PG_LOG="$HOME/Library/Logs/fb2-to-epub.log"

PG_SNAP=""        # temp file holding the BEFORE snapshot
PG_FAIL=0         # breach counter (read by the caller after prod_guard_end)
PG_PASS=0         # guard checks that PASSED (so callers can total honestly)

# sha of a file, or the literal "absent" — so "was there / now there" is a mismatch.
_pg_sig() { [[ -f "$1" ]] && shasum -a256 "$1" 2>/dev/null | cut -d' ' -f1 || printf 'absent'; }

# python3 for the normalized state.json signature (resolved locally so the lib is
# self-contained). Honours an already-exported PYTHON3, else the usual candidates.
_pg_python3() {
  local c
  if [[ -n "${PYTHON3:-}" && -x "${PYTHON3:-}" ]]; then printf '%s' "$PYTHON3"; return; fi
  for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return; }
  done
  command -v python3 2>/dev/null || true
}

# Normalized signature of state.json: a canonical (sorted-keys) sha256 with
# agent.folder_access_ts REMOVED, so a no-op boevoy fire — which only bumps that ts
# (v1.0.1 FDA probe) — does NOT trip the strict guard, while any real content change
# still does. "absent" for a missing file; falls back to the raw file sha when python3
# is unavailable (the ts-bump flakiness simply returns, but the guard stays functional).
_pg_state_sig() {
  [[ -f "$PG_STATE_JSON" ]] || { printf 'absent'; return; }
  local py; py="$(_pg_python3)"
  if [[ -z "$py" || ! -x "$py" ]]; then _pg_sig "$PG_STATE_JSON"; return; fi
  "$py" - "$PG_STATE_JSON" <<'PY' 2>/dev/null || _pg_sig "$PG_STATE_JSON"
import json, sys, hashlib
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
a = d.get("agent")
if isinstance(a, dict):
    a.pop("folder_access_ts", None)
blob = json.dumps(d, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
sys.stdout.write(hashlib.sha256(blob.encode("utf-8")).hexdigest())
PY
}

# Every boevoy plist (agent + any leftover test labels), sorted, sha'd as one blob.
_pg_plist_sig() {
  local f out=""
  for f in "$PG_LA_DIR"/com.arrivarus.fb2toepub*.plist; do
    [[ -f "$f" ]] || continue
    out+="$(basename "$f"):$(shasum -a256 "$f" 2>/dev/null | cut -d' ' -f1)"$'\n'
  done
  printf '%s' "$out" | shasum -a256 | cut -d' ' -f1
}

prod_guard_begin() {
  PG_SNAP="$(mktemp "${TMPDIR:-/tmp}/prod-guard.XXXXXX")"
  {
    printf 'plist %s\n'  "$(_pg_plist_sig)"
    printf 'state %s\n'  "$(_pg_state_sig)"
  } > "$PG_SNAP"
}

# prod_guard_end <sandbox_root>
prod_guard_end() {
  local sandbox="${1:-}"
  local want_plist want_state got_plist got_state
  want_plist="$(sed -n 's/^plist //p' "$PG_SNAP")"
  want_state="$(sed -n 's/^state //p' "$PG_SNAP")"
  got_plist="$(_pg_plist_sig)"
  got_state="$(_pg_state_sig)"

  # 1. STRICT: plist + state.json (normalized, folder_access_ts excluded) unchanged.
  if [[ "$got_plist" == "$want_plist" ]]; then
    PG_PASS=$((PG_PASS + 1))
    printf '  ok   - prod-guard: boevoy LaunchAgents plist(s) unchanged\n'
  else
    PG_FAIL=$((PG_FAIL + 1))
    printf '  FAIL - prod-guard: boevoy plist CHANGED (was %s now %s) — lesson 015!\n' \
      "${want_plist:0:12}" "${got_plist:0:12}"
  fi
  if [[ "$got_state" == "$want_state" ]]; then
    PG_PASS=$((PG_PASS + 1))
    printf '  ok   - prod-guard: boevoy state.json unchanged (norm %s)\n' "$want_state"
  else
    PG_FAIL=$((PG_FAIL + 1))
    printf '  FAIL - prod-guard: boevoy state.json CHANGED (norm was %s now %s) — D13 leak!\n' \
      "${want_state:0:12}" "${got_state:0:12}"
  fi

  # 2. LEAK: our unique sandbox path must not appear in ANY boevoy file.
  if [[ -n "$sandbox" ]]; then
    local hit=0 f
    for f in "$PG_LOG" "$PG_STATE_JSON"; do
      [[ -f "$f" ]] && grep -qF "$sandbox" "$f" 2>/dev/null && hit=1
    done
    if [[ -d "$PG_COVERS_JOBS" ]] && grep -rqF "$sandbox" "$PG_COVERS_JOBS" 2>/dev/null; then hit=1; fi
    if [[ "$hit" -eq 0 ]]; then
      PG_PASS=$((PG_PASS + 1))
      printf '  ok   - prod-guard: sandbox path never leaked into boevoy log/state/covers\n'
    else
      PG_FAIL=$((PG_FAIL + 1))
      printf '  FAIL - prod-guard: sandbox path LEAKED into a boevoy file — test touched real paths!\n'
    fi
  fi

  rm -f "$PG_SNAP" 2>/dev/null || true
  [[ "$PG_FAIL" -eq 0 ]]
}
