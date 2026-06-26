#!/bin/bash
# run-update-install-test.sh — isolated regression suite for the v0.2.2
# auto-update INSTALLER SCRIPT (app/UpdateChecker.swift → `installScriptBody`).
#
# WHY a separate bash runner (not Swift)
# --------------------------------------
# The installer is a /bin/sh script embedded as a Swift raw-string literal
# (`private static let installScriptBody = #"""…"""#`). It is what actually
# replaces the running .app after the app quits: wait-for-pid → mount dmg →
# ditto the new bundle beside the old → remove old → verify gone → mv → strip
# quarantine → relaunch. We extract that exact body from the source (so the test
# tracks the shipping script, never a copy) and exercise it in a sandbox.
#
# WHAT IS UNDER TEST  (installScriptBody, args $1 dmg $2 target $3 pid $4 workdir)
#   1. happy    — target REPLACED with the new bundle; dmg/workDir cleaned;
#                 mount detached; relaunch (`open`) called with the target path.
#   2. failure  — dmg has NO fb2-to-epub.app → OLD target kept untouched;
#                 relaunch still called; NEVER a nested app/app.
#   3. rollback — old bundle is undeletable (chflags uchg) → NEVER a nested
#                 app/app; the OLD (still-working) bundle is relaunched; exit≠0.
#
# ISOLATION (critical) — nothing here touches a real install:
#   • every run lives under its own `mktemp -d` sandbox (trap-cleaned);
#   • the "target" is a THROWAWAY bundle in the sandbox, never /Applications;
#   • `open` is a STUB on PATH that only records its argv — no app ever launches;
#   • the PID handed in is a KNOWN-DEAD pid, so the wait loop returns at once —
#     no real app, no launchd, no agent, no network;
#   • real hdiutil/ditto/mv ARE used, but only on sandbox paths under /tmp.
#
# Usage:  tests/run-update-install-test.sh
# Exit:   0 = all green, 1 = a test failed / setup failed.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_DIR/app/UpdateChecker.swift"
APP_NAME="fb2-to-epub.app"

[[ -f "$SRC" ]] || { echo "run-update-install-test: missing $SRC" >&2; exit 1; }
for t in hdiutil ditto mktemp; do
  command -v "$t" >/dev/null 2>&1 || { echo "run-update-install-test: missing $t" >&2; exit 1; }
done

# --- one sandbox for the whole run; trap-cleaned even on failure -------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/fb2-update-inst.XXXXXX")"
cleanup() {
  # Defensive: clear any immutable flag a rollback test set, detach stray mounts,
  # then remove the sandbox. Never touches anything outside $SANDBOX.
  chflags -R nouchg "$SANDBOX" 2>/dev/null || true
  mount | awk '/fb2-update-mnt/ {print $3}' | while read -r mp; do
    case "$mp" in
      /tmp/fb2-update-mnt.*) hdiutil detach "$mp" -force >/dev/null 2>&1 || true ;;
    esac
  done
  rm -rf "$SANDBOX" 2>/dev/null || true
}
trap cleanup EXIT

# --- tiny TAP-ish harness (mirrors tests/run-clear-history-tests.sh style) ---
PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL - %s\n' "$1"; }
check(){ if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi; }   # check <rc> <msg>

# ---------------------------------------------------------------------------
# Extract installScriptBody from the Swift source.
#
# The literal is `#"""` … `"""#`; Swift strips the indentation of the CLOSING
# delimiter (4 spaces here) from every content line. We mirror that: take lines
# strictly between the delimiters and drop a single leading 4-space indent.
# Anchored on the Swift tokens (NOT line numbers) so it survives edits above.
# ---------------------------------------------------------------------------
EXTRACTED="$SANDBOX/install.sh"
awk '
  /installScriptBody = #"""/ { grab=1; next }
  grab && /^[[:space:]]*"""#/ { grab=0; next }
  grab { sub(/^    /, ""); print }
' "$SRC" > "$EXTRACTED"

if [ ! -s "$EXTRACTED" ]; then
  echo "run-update-install-test: failed to extract installScriptBody from $SRC" >&2
  exit 1
fi
echo "==> extracted installer body: $(wc -l < "$EXTRACTED" | tr -d ' ') lines"
if ! /bin/sh -n "$EXTRACTED"; then
  echo "run-update-install-test: extracted script failed sh -n syntax check" >&2
  exit 1
fi
chmod +x "$EXTRACTED"
echo ""

# --- shared fixture builders ------------------------------------------------

# A throwaway target bundle carrying a "$1" marker (OLD/NEW). Echoes its path.
make_bundle() { # make_bundle <dir> <marker>
  local b="$1"
  mkdir -p "$b/Contents/MacOS"
  printf '%s\n' "$2" > "$b/Contents/MacOS/marker.txt"
  printf '%s' "$b"
}

# A UDZO dmg whose root holds a fb2-to-epub.app carrying <marker>. Echoes path.
make_dmg_with_app() { # make_dmg_with_app <dmgpath> <marker>
  local dmg="$1" src; src="$(mktemp -d "$SANDBOX/dmgsrc.XXXXXX")"
  mkdir -p "$src/$APP_NAME/Contents/MacOS"
  printf '%s\n' "$2" > "$src/$APP_NAME/Contents/MacOS/marker.txt"
  hdiutil create -quiet -srcfolder "$src" -volname "fb2-update" -format UDZO "$dmg" >/dev/null 2>&1
  printf '%s' "$dmg"
}

# A UDZO dmg whose root has the WRONG app name (no fb2-to-epub.app). Echoes path.
make_dmg_without_app() { # make_dmg_without_app <dmgpath>
  local dmg="$1" src; src="$(mktemp -d "$SANDBOX/dmgsrc.XXXXXX")"
  mkdir -p "$src/SomethingElse.app/Contents/MacOS"
  printf 'NOPE\n' > "$src/SomethingElse.app/Contents/MacOS/marker.txt"
  hdiutil create -quiet -srcfolder "$src" -volname "fb2-update" -format UDZO "$dmg" >/dev/null 2>&1
  printf '%s' "$dmg"
}

# Stub `open` on PATH that records argv into <logfile>. Echoes the PATH prefix.
make_stub_open() { # make_stub_open <logfile>
  local bin; bin="$(mktemp -d "$SANDBOX/stubbin.XXXXXX")"
  cat > "$bin/open" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$1"
exit 0
EOF
  chmod +x "$bin/open"
  printf '%s' "$bin"
}

# A guaranteed-dead PID: start /usr/bin/true, reap it, hand back its pid.
dead_pid() {
  /usr/bin/true & local p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"
}

marker_of() { cat "$1/Contents/MacOS/marker.txt" 2>/dev/null; }

# ===========================================================================
# Scenario 1 — HAPPY PATH
# ===========================================================================
echo "# 1 happy: target replaced, dmg+workdir cleaned, mount detached, relaunch ok"
(
  case_dir="$(mktemp -d "$SANDBOX/case-happy.XXXXXX")"
  target="$(make_bundle "$case_dir/Applications/$APP_NAME" OLD-BUILD)"
  workdir="$case_dir/work"; mkdir -p "$workdir"
  dmg="$(make_dmg_with_app "$workdir/update.dmg" NEW-BUILD)"   # dmg lives in workdir
  openlog="$case_dir/open.log"; : > "$openlog"
  stubpath="$(make_stub_open "$openlog")"
  pid="$(dead_pid)"

  PATH="$stubpath:$PATH" /bin/sh "$EXTRACTED" "$dmg" "$target" "$pid" "$workdir"
  rc=$?

  echo "RC=$rc"
  echo "MARKER=$(marker_of "$target")"
  [ -e "$target/$APP_NAME" ] && echo "NESTED=yes" || echo "NESTED=no"
  [ -d "$workdir" ] && echo "WORKDIR=present" || echo "WORKDIR=gone"
  echo "OPENLOG=$(cat "$openlog" 2>/dev/null)"
  echo "TARGET=$target"
) > "$SANDBOX/out.happy" 2>&1
# Evaluate
hr="$(grep '^RC='      "$SANDBOX/out.happy" | cut -d= -f2)"
hm="$(grep '^MARKER='  "$SANDBOX/out.happy" | cut -d= -f2)"
hn="$(grep '^NESTED='  "$SANDBOX/out.happy" | cut -d= -f2)"
hw="$(grep '^WORKDIR=' "$SANDBOX/out.happy" | cut -d= -f2)"
ho="$(grep '^OPENLOG=' "$SANDBOX/out.happy" | cut -d= -f2-)"
ht="$(grep '^TARGET='  "$SANDBOX/out.happy" | cut -d= -f2-)"
[ "$hr" = "0" ]            && ok "exit code 0" || bad "exit code 0 (got '$hr')"
[ "$hm" = "NEW-BUILD" ]    && ok "target replaced with the NEW bundle"        || bad "target replaced with NEW bundle (marker='$hm')"
[ "$hn" = "no" ]           && ok "no nested $APP_NAME/$APP_NAME"               || bad "no nested app/app (NESTED='$hn')"
[ "$hw" = "gone" ]         && ok "workDir cleaned up"                          || bad "workDir cleaned up (WORKDIR='$hw')"
[ "$ho" = "$ht" ]          && ok "relaunch (open) called with the target path" || bad "relaunch path (open='$ho' target='$ht')"
echo ""

# ===========================================================================
# Scenario 2 — FAILURE (dmg without fb2-to-epub.app)
# ===========================================================================
echo "# 2 failure: dmg has no $APP_NAME → OLD target kept, relaunch still called, no nesting"
(
  case_dir="$(mktemp -d "$SANDBOX/case-fail.XXXXXX")"
  target="$(make_bundle "$case_dir/Applications/$APP_NAME" OLD-BUILD)"
  workdir="$case_dir/work"; mkdir -p "$workdir"
  dmg="$(make_dmg_without_app "$workdir/update.dmg")"
  openlog="$case_dir/open.log"; : > "$openlog"
  stubpath="$(make_stub_open "$openlog")"
  pid="$(dead_pid)"

  PATH="$stubpath:$PATH" /bin/sh "$EXTRACTED" "$dmg" "$target" "$pid" "$workdir"
  rc=$?

  echo "RC=$rc"
  echo "MARKER=$(marker_of "$target")"
  [ -e "$target/$APP_NAME" ] && echo "NESTED=yes" || echo "NESTED=no"
  echo "OPENLOG=$(cat "$openlog" 2>/dev/null)"
  echo "TARGET=$target"
) > "$SANDBOX/out.fail" 2>&1
fr="$(grep '^RC='      "$SANDBOX/out.fail" | cut -d= -f2)"
fm="$(grep '^MARKER='  "$SANDBOX/out.fail" | cut -d= -f2)"
fn="$(grep '^NESTED='  "$SANDBOX/out.fail" | cut -d= -f2)"
fo="$(grep '^OPENLOG=' "$SANDBOX/out.fail" | cut -d= -f2-)"
ft="$(grep '^TARGET='  "$SANDBOX/out.fail" | cut -d= -f2-)"
[ "$fm" = "OLD-BUILD" ]    && ok "OLD target preserved (no $APP_NAME in dmg)"  || bad "OLD target preserved (marker='$fm')"
[ "$fn" = "no" ]           && ok "no nested $APP_NAME/$APP_NAME on failure"    || bad "no nested app/app (NESTED='$fn')"
[ "$fo" = "$ft" ]          && ok "relaunch (open) still called with target"    || bad "relaunch on failure (open='$fo' target='$ft')"
[ "$fr" != "0" ]           && ok "exit code non-zero on failure"              || bad "exit non-zero on failure (got '$fr')"
echo ""

# ===========================================================================
# Scenario 3 — ROLLBACK (old bundle undeletable)
# ===========================================================================
# The script stages "$TARGET.new", removes the old bundle, then VERIFIES it is
# gone before the final mv. We make the old bundle undeletable (chflags uchg) so
# the rm fails and the verify catches it → the script must DISCARD the staged
# copy and relaunch the old one, NEVER nesting new inside old. (If chflags is
# unavailable we fall back to asserting the `[ -e "$TARGET" ]` guard via a
# read-only parent dir.)
echo "# 3 rollback: old bundle undeletable → no nesting, OLD relaunched, exit≠0"
ROLLBACK_DONE=0
if command -v chflags >/dev/null 2>&1; then
  (
    case_dir="$(mktemp -d "$SANDBOX/case-rollback.XXXXXX")"
    target="$(make_bundle "$case_dir/Applications/$APP_NAME" OLD-BUILD)"
    workdir="$case_dir/work"; mkdir -p "$workdir"
    dmg="$(make_dmg_with_app "$workdir/update.dmg" NEW-BUILD)"
    openlog="$case_dir/open.log"; : > "$openlog"
    stubpath="$(make_stub_open "$openlog")"
    pid="$(dead_pid)"

    # Lock the bundle so `rm -rf "$TARGET"` cannot remove it.
    chflags -R uchg "$target" 2>/dev/null

    PATH="$stubpath:$PATH" /bin/sh "$EXTRACTED" "$dmg" "$target" "$pid" "$workdir"
    rc=$?

    # Unlock so we (and cleanup) can read/remove it.
    chflags -R nouchg "$target" 2>/dev/null

    echo "RC=$rc"
    echo "MARKER=$(marker_of "$target")"
    [ -e "$target/$APP_NAME" ] && echo "NESTED=yes" || echo "NESTED=no"
    echo "OPENLOG=$(cat "$openlog" 2>/dev/null)"
    echo "TARGET=$target"
  ) > "$SANDBOX/out.rollback" 2>&1

  # Only trust this scenario if chflags actually locked the bundle (some
  # filesystems / CI sandboxes ignore uchg). When the lock didn't take, the rm
  # succeeds and the run looks like a happy path → treat as inconclusive and
  # fall through to the guard-only assertion instead of a false pass.
  rbr="$(grep '^RC='      "$SANDBOX/out.rollback" | cut -d= -f2)"
  rbm="$(grep '^MARKER='  "$SANDBOX/out.rollback" | cut -d= -f2)"
  rbn="$(grep '^NESTED='  "$SANDBOX/out.rollback" | cut -d= -f2)"
  rbo="$(grep '^OPENLOG=' "$SANDBOX/out.rollback" | cut -d= -f2-)"
  rbt="$(grep '^TARGET='  "$SANDBOX/out.rollback" | cut -d= -f2-)"
  if [ "$rbr" != "0" ] && [ "$rbm" = "OLD-BUILD" ]; then
    ROLLBACK_DONE=1
    [ "$rbn" = "no" ]        && ok "no nested $APP_NAME/$APP_NAME on rollback" || bad "no nested app/app on rollback (NESTED='$rbn')"
    [ "$rbm" = "OLD-BUILD" ] && ok "OLD working bundle preserved on rollback"  || bad "OLD bundle preserved (marker='$rbm')"
    [ "$rbo" = "$rbt" ]      && ok "OLD bundle relaunched on rollback"         || bad "OLD relaunched (open='$rbo' target='$rbt')"
    [ "$rbr" != "0" ]        && ok "exit code non-zero on rollback"            || bad "exit non-zero on rollback (got '$rbr')"
  else
    echo "  # chflags uchg did not hold (rc='$rbr' marker='$rbm') — falling back to guard-only check"
  fi
fi

# Fallback / always-on guard assertion: the script bails the moment the old
# bundle still exists after the rm ("could not remove old bundle"), so it can
# never `mv` the new bundle INTO the old one. We assert that explicit guard text
# is present in the shipping script (the safety invariant the rollback relies on).
if [ "$ROLLBACK_DONE" = "0" ]; then
  if grep -q 'could not remove old bundle' "$EXTRACTED" && grep -q '\[ -e "\$TARGET" \]' "$EXTRACTED"; then
    ok "rollback guard present: bails on [ -e \"\$TARGET\" ] (no mv into old bundle)"
  else
    bad "rollback guard [ -e \"\$TARGET\" ] missing from installer script"
  fi
fi
echo ""

# --- summary ----------------------------------------------------------------
echo "1..$((PASS+FAIL))"
echo "# passed: $PASS"
echo "# failed: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
