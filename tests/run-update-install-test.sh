#!/bin/bash
# run-update-install-test.sh — isolated regression suite for the SIMPLIFIED
# auto-update INSTALLER SCRIPT in app/UpdateChecker.swift (`launchInstaller`).
#
# WHY a separate bash runner (not Swift)
# --------------------------------------
# The installer is a /bin/bash script that UpdateChecker builds at install time
# inside `launchInstaller(dmgPath:)` and writes to NSTemporaryDirectory()/
# fb2-update.sh. It is what actually replaces the running .app AFTER the app
# quits: sleep → mount dmg → (if the dmg holds fb2-to-epub.app) replace the
# running bundle in place → strip quarantine → detach → relaunch → delete the
# dmg+itself. This mirrors the proven minimal installer from the sibling
# "Claude Codex Limits" app — NO checksum sidecar, NO Application-Support
# staging, NO backup-rename/rollback dance (those added moving parts that hung
# `hdiutil detach` and raced and were removed).
#
# We reconstruct that exact script BODY from the source so the test tracks the
# shipping installer instead of a hand-kept copy. The literal is a NON-raw Swift
# `"""…"""` string with three interpolations — `\(dmgPath)`, `\(appPath)`,
# `\(scriptPath)` — so it can't be lifted byte-for-byte; we reproduce what Swift
# does to that literal:
#   (a) strip the closing-delimiter indent (8 spaces) from each content line,
#   (b) collapse `\\` → `\` (the only escape used — inside the sed mount-parse),
#   (c) substitute the three `\(…)` interpolations with sandbox paths.
# The shell control-flow under test (the hdiutil/grep/sed mount parse, the
# `[ -n "$MP" ] && [ -d "$SRC" ]` guard, the rm/cp replace, the unconditional
# final cleanup) is the shipping text, untouched.
#
# ONE documented exception, for ISOLATION only: the shipping body calls utilities
# by ABSOLUTE path (`/usr/bin/open`, `/usr/bin/hdiutil`, `/bin/rm`, `/bin/cp`,
# `/usr/bin/xattr`), so a PATH stub cannot intercept them. All of them are
# harmless against sandbox paths EXCEPT `/usr/bin/open`, which would register our
# throwaway fake .app with the real LaunchServices. So we rewrite exactly that
# one token — `/usr/bin/open` → a recording STUB — which both keeps the test off
# the real system AND gives us a place to observe "relaunch called with $APP".
# Nothing else in the body is altered. (hdiutil/rm/cp/xattr stay REAL; they only
# ever touch sandbox paths, so isolation holds.)
#
# WHAT IS UNDER TEST  (the reconstructed installer; it takes NO args — the dmg,
#                      app and script paths are baked in via interpolation)
#   1. happy   — dmg HAS fb2-to-epub.app → running bundle REPLACED with the new
#                one; relaunch (`open` "$APP") called with the bundle path; dmg +
#                script cleaned up; never a nested app/app.
#   2. no-app  — dmg has NO fb2-to-epub.app → the `[ -d "$SRC" ]` guard is false
#                so the OLD bundle is kept untouched and `open` is NOT called;
#                the unconditional final `rm -f` still cleans up the dmg.
#
#   (There is no rollback scenario anymore: the simplified script has no staging
#    `.new` copy / "verify old gone" step, so there is nothing to roll back.)
#
# ISOLATION (critical) — nothing here touches a real install:
#   • the whole run lives under one `mktemp -d` sandbox (trap-cleaned);
#   • the "running bundle" ($APP) is a THROWAWAY bundle in the sandbox, never the
#     real app and never /Applications;
#   • `/usr/bin/open` is rewritten to a STUB that only records argv — no app
#     launches, no LaunchServices, no real agent / ~/Library / network touched;
#   • the dmg + script path are sandbox mktemp paths; the final `rm -f` only ever
#     deletes those;
#   • real hdiutil IS used (attach/detach), but only on a sandbox-built dmg whose
#     mount is detached in-script and again defensively in cleanup.
#
# NOTE on speed: a real `hdiutil create`/`attach`/`detach` plus the body's own
# `sleep 1.5` is a single-digit number of seconds. `hdiutil` can briefly stall on
# a machine that has churned many mounts this session — that's the environment,
# not the code — so each scenario runs under a watchdog (HDIUTIL_BUDGET seconds);
# a slow/timed-out run is reported, not silently passed.
#
# Usage:  tests/run-update-install-test.sh
# Exit:   0 = all green, 1 = a test failed / setup failed.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_DIR/app/UpdateChecker.swift"
APP_NAME="fb2-to-epub.app"
# Per-scenario watchdog (seconds). A healthy create+attach+detach+sleep1.5 is
# well under this; the budget only trips on a wedged hdiutil.
HDIUTIL_BUDGET="${HDIUTIL_BUDGET:-90}"

[[ -f "$SRC" ]] || { echo "run-update-install-test: missing $SRC" >&2; exit 1; }
for t in hdiutil mktemp perl awk; do
  command -v "$t" >/dev/null 2>&1 || { echo "run-update-install-test: missing $t" >&2; exit 1; }
done

# --- one sandbox for the whole run; trap-cleaned even on failure -------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/fb2-update-inst.XXXXXX")"
cleanup() {
  # Defensive: detach any volume that came from a dmg we built in this sandbox,
  # then remove the sandbox. Never touches anything outside $SANDBOX. Our dmgs
  # use volname "fb2-update", so the mountpoint is /Volumes/fb2-update[ N].
  mount | awk '/\/Volumes\/fb2-update/ {print $3}' | while read -r mp; do
    case "$mp" in
      /Volumes/fb2-update*) hdiutil detach "$mp" -force >/dev/null 2>&1 || true ;;
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

# ---------------------------------------------------------------------------
# Reconstruct the installer body from app/UpdateChecker.swift.
#
# launchInstaller(dmgPath:) builds it as:
#     let script = """
#     #!/bin/bash
#     …                 <- 8-space indented (matches the closing delimiter)
#     """
# Reproduce Swift's handling of a NON-raw multiline literal — strip the closing
# delimiter indent (8 spaces), collapse `\\`→`\`, expand the three `\(…)`
# interpolations — then rewrite `/usr/bin/open` to the stub (isolation; see top).
# Anchored on the Swift tokens (`let script = """` … a line that is only `"""`),
# NOT on line numbers, so it survives edits above/below.
# ---------------------------------------------------------------------------
build_script() {  # build_script <out> <dmgPath> <appPath> <scriptPath> <openStub>
  local out="$1"
  # Export so EVERY stage of the pipe (awk + both perls) sees the paths — a
  # `VAR=val cmd1 | cmd2` prefix would scope the vars to cmd1 only.
  (
    export DMG_PATH="$2" APP_PATH="$3" SCRIPT_PATH="$4" OPEN_STUB="$5"
    awk '
      /let script = """/        { grab=1; next }
      grab && /^[[:space:]]*"""[[:space:]]*$/ { grab=0; next }
      grab                      { sub(/^        /, ""); print }
    ' "$SRC" \
    | perl -0777 -pe 's/\\\\/\\/g' \
    | perl -0777 -pe '
        my ($d,$a,$s,$o)=($ENV{DMG_PATH},$ENV{APP_PATH},$ENV{SCRIPT_PATH},$ENV{OPEN_STUB});
        s/\\\(dmgPath\)/$d/g;
        s/\\\(appPath\)/$a/g;
        s/\\\(scriptPath\)/$s/g;
        # ISOLATION: redirect the absolute /usr/bin/open (would hit LaunchServices)
        # to a recording stub. Quote the replacement so a spaced path survives.
        s{/usr/bin/open\b}{"$o"}g;
      '
  ) > "$out"
}

# --- shared fixture builders ------------------------------------------------

# A throwaway "running bundle" carrying a "$2" marker (OLD/NEW). Echoes its path.
make_bundle() { # make_bundle <dir> <marker>
  local b="$1"
  mkdir -p "$b/Contents/MacOS"
  printf '%s\n' "$2" > "$b/Contents/MacOS/marker.txt"
  printf '%s' "$b"
}

# A UDZO dmg (volname fb2-update) whose root holds fb2-to-epub.app with <marker>.
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

# A stub `open` that records argv into <logfile>. Echoes the stub's path.
make_open_stub() { # make_open_stub <logfile>
  local bin; bin="$(mktemp -d "$SANDBOX/stubbin.XXXXXX")"
  cat > "$bin/open" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >> "$1"
exit 0
EOF
  chmod +x "$bin/open"
  printf '%s' "$bin/open"
}

marker_of() { cat "$1/Contents/MacOS/marker.txt" 2>/dev/null; }

# Run a command under a wall-clock watchdog using perl's alarm (no `timeout` on
# stock macOS). Echoes the exit code; 124 if the watchdog fired. Crucially this
# does NOT leak fds into a command-substitution the way a backgrounded
# `( sleep; kill )` subshell would.
run_with_budget() { # run_with_budget <script> <budget-seconds>
  perl -e '
    my ($script,$budget)=@ARGV;
    my $pid=fork();
    if ($pid==0){ exec("/bin/bash",$script) or exit 127; }
    local $SIG{ALRM}=sub { kill "TERM",$pid; };
    alarm $budget;
    waitpid($pid,0);
    my $rc=$?;
    alarm 0;
    if ($rc & 127) { exit 124; }       # killed by signal (watchdog) → 124
    exit($rc >> 8);
  ' "$1" "$2"
  printf '%s' "$?"
}

# ===========================================================================
# Scenario 1 — HAPPY PATH (dmg holds fb2-to-epub.app)
# ===========================================================================
echo "# 1 happy: dmg has $APP_NAME → running bundle replaced, relaunch called, dmg cleaned"
SECONDS=0
(
  case_dir="$(mktemp -d "$SANDBOX/case-happy.XXXXXX")"
  app="$(make_bundle "$case_dir/Applications/$APP_NAME" OLD-BUILD)"
  dmg="$(make_dmg_with_app "$case_dir/update.dmg" NEW-BUILD)"
  scriptpath="$case_dir/fb2-update.sh"
  openlog="$case_dir/open.log"; : > "$openlog"
  openstub="$(make_open_stub "$openlog")"

  installer="$case_dir/installer.sh"
  build_script "$installer" "$dmg" "$app" "$scriptpath" "$openstub"
  /bin/sh -n "$installer" || { echo "SYNTAX=fail"; exit 1; }
  # The shipping script self-deletes "$scriptpath" at the end, so run a COPY at
  # that exact path (the body's final `rm -f "$DMG" "$scriptpath"` then removes
  # the copy + dmg — exactly what ships).
  cp "$installer" "$scriptpath"

  rc="$(run_with_budget "$scriptpath" "$HDIUTIL_BUDGET")"

  echo "RC=$rc"
  echo "MARKER=$(marker_of "$app")"
  [ -e "$app/$APP_NAME" ] && echo "NESTED=yes" || echo "NESTED=no"
  [ -e "$dmg" ] && echo "DMG=present" || echo "DMG=gone"
  [ -e "$scriptpath" ] && echo "SCRIPT=present" || echo "SCRIPT=gone"
  echo "OPENLOG=$(cat "$openlog" 2>/dev/null)"
  echo "APP=$app"
) > "$SANDBOX/out.happy" 2>&1
HAPPY_SECS=$SECONDS
# Evaluate
hr="$(grep '^RC='      "$SANDBOX/out.happy" | cut -d= -f2)"
hm="$(grep '^MARKER='  "$SANDBOX/out.happy" | cut -d= -f2)"
hn="$(grep '^NESTED='  "$SANDBOX/out.happy" | cut -d= -f2)"
hd="$(grep '^DMG='     "$SANDBOX/out.happy" | cut -d= -f2)"
hs="$(grep '^SCRIPT='  "$SANDBOX/out.happy" | cut -d= -f2)"
ho="$(grep '^OPENLOG=' "$SANDBOX/out.happy" | cut -d= -f2-)"
ha="$(grep '^APP='     "$SANDBOX/out.happy" | cut -d= -f2-)"
if grep -q '^SYNTAX=fail' "$SANDBOX/out.happy"; then bad "reconstructed installer passes sh -n"; else ok "reconstructed installer passes sh -n"; fi
[ "$hr" = "0" ]         && ok "exit code 0"                                  || bad "exit code 0 (got '$hr'${hr:+; 124=watchdog})"
[ "$hm" = "NEW-BUILD" ] && ok "running bundle replaced with the NEW build"   || bad "bundle replaced with NEW (marker='$hm')"
[ "$hn" = "no" ]        && ok "no nested $APP_NAME/$APP_NAME"                 || bad "no nested app/app (NESTED='$hn')"
[ "$ho" = "$ha" ]       && ok "relaunch (open) called with the bundle path"  || bad "relaunch path (open='$ho' app='$ha')"
[ "$hd" = "gone" ]      && ok "dmg cleaned up by final rm"                   || bad "dmg cleaned up (DMG='$hd')"
[ "$hs" = "gone" ]      && ok "installer self-deleted (final rm of script)"  || bad "installer self-deleted (SCRIPT='$hs')"
echo "  # happy scenario took ${HAPPY_SECS}s"
[ "$HAPPY_SECS" -ge "$HDIUTIL_BUDGET" ] && echo "  # NOTE: hit the ${HDIUTIL_BUDGET}s watchdog — hdiutil is slow on this machine (environment, not code)"
echo ""

# ===========================================================================
# Scenario 2 — NO-APP (dmg without fb2-to-epub.app)
# ===========================================================================
echo "# 2 no-app: dmg has no $APP_NAME → guard skips replace, OLD bundle kept, open NOT called, dmg still cleaned"
SECONDS=0
(
  case_dir="$(mktemp -d "$SANDBOX/case-noapp.XXXXXX")"
  app="$(make_bundle "$case_dir/Applications/$APP_NAME" OLD-BUILD)"
  dmg="$(make_dmg_without_app "$case_dir/update.dmg")"
  scriptpath="$case_dir/fb2-update.sh"
  openlog="$case_dir/open.log"; : > "$openlog"
  openstub="$(make_open_stub "$openlog")"

  installer="$case_dir/installer.sh"
  build_script "$installer" "$dmg" "$app" "$scriptpath" "$openstub"
  cp "$installer" "$scriptpath"

  rc="$(run_with_budget "$scriptpath" "$HDIUTIL_BUDGET")"

  echo "RC=$rc"
  echo "MARKER=$(marker_of "$app")"
  [ -e "$app/$APP_NAME" ] && echo "NESTED=yes" || echo "NESTED=no"
  [ -e "$dmg" ] && echo "DMG=present" || echo "DMG=gone"
  echo "OPENLOG=$(cat "$openlog" 2>/dev/null)"
  echo "APP=$app"
) > "$SANDBOX/out.noapp" 2>&1
NOAPP_SECS=$SECONDS
fm="$(grep '^MARKER='  "$SANDBOX/out.noapp" | cut -d= -f2)"
fn="$(grep '^NESTED='  "$SANDBOX/out.noapp" | cut -d= -f2)"
fd="$(grep '^DMG='     "$SANDBOX/out.noapp" | cut -d= -f2)"
fo="$(grep '^OPENLOG=' "$SANDBOX/out.noapp" | cut -d= -f2-)"
[ "$fm" = "OLD-BUILD" ] && ok "OLD bundle preserved (no $APP_NAME in dmg → guard skipped replace)" || bad "OLD bundle preserved (marker='$fm')"
[ "$fn" = "no" ]        && ok "no nested $APP_NAME/$APP_NAME on no-app"        || bad "no nested app/app (NESTED='$fn')"
[ -z "$fo" ]            && ok "relaunch (open) NOT called when no app in dmg"  || bad "open must not run on no-app (open='$fo')"
[ "$fd" = "gone" ]      && ok "dmg still cleaned up by unconditional final rm" || bad "dmg cleaned up on no-app (DMG='$fd')"
echo "  # no-app scenario took ${NOAPP_SECS}s"
[ "$NOAPP_SECS" -ge "$HDIUTIL_BUDGET" ] && echo "  # NOTE: hit the ${HDIUTIL_BUDGET}s watchdog — hdiutil is slow on this machine (environment, not code)"
echo ""

# --- summary ----------------------------------------------------------------
echo "1..$((PASS+FAIL))"
echo "# passed: $PASS"
echo "# failed: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
