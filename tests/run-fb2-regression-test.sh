#!/bin/bash
# run-fb2-regression-test.sh — locks the FB2 path against the FB3 transform врез.
#
# WHY this exists
# ---------------
# The FB3 work added an `.fb3` branch to bin/fb2-to-epub-watcher.sh. The
# non-negotiable invariant is: the EXISTING `.fb2` / `.fb2.zip` path must be
# byte-for-byte unchanged — the FB3 transform must NEVER run for them. This test
# guards that contract at two levels, WITHOUT a full agent run (no launchctl, no
# Calibre, no network, no Desktop):
#
#   A. epub_name() behaviour — extracted verbatim from the shipping watcher and
#      sourced into a sandbox shell, then exercised: .fb2/.fb2.zip/.fb3 (and
#      upper-case) -> .epub; unknown ext -> empty. This is the watcher's only
#      file-type decision and it must keep treating .fb2 exactly as before.
#
#   B. convert_book() structural invariant — static assertions over the shipping
#      source: `conv_src` defaults to `$src`, the transform is reached ONLY under
#      the `*.fb3)` case, and the downstream tools run against `$conv_src`. So for
#      an .fb2/.fb2.zip input `conv_src` stays = src and the transform is not
#      invoked. (We assert the GUARANTEE in code, not a live conversion, because
#      a live FB2->EPUB needs Calibre and is the existing core-regression's job.)
#
# The function/branch text is read from the REAL watcher (anchored on tokens, not
# line numbers) so this test tracks the shipping code, like run-update-install-
# test.sh does for the installer body.
#
# Usage:  bash tests/run-fb2-regression-test.sh
# Exit:   0 = all green, 1 = a check failed.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHER="$REPO_DIR/bin/fb2-to-epub-watcher.sh"
[[ -f "$WATCHER" ]] || { echo "missing $WATCHER" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL - %s\n' "$1"; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/fb2-regr.XXXXXX")"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

echo "==> FB2 regression: FB3 врез must not touch the FB2 path"
echo ""

# ---------------------------------------------------------------------------
# A. epub_name(): extract the function body verbatim and source it.
#    awk grabs from the `epub_name() {` line through its matching closing `}`
#    at column 0 (the function is written with a left-aligned closing brace).
# ---------------------------------------------------------------------------
FN_FILE="$SANDBOX/epub_name.sh"
awk '
  /^epub_name\(\) \{/ {grab=1}
  grab {print}
  grab && /^\}/ {exit}
' "$WATCHER" > "$FN_FILE"

if [[ ! -s "$FN_FILE" ]] || ! grep -q '^epub_name() {' "$FN_FILE" \
   || ! grep -q '^}' "$FN_FILE"; then
  bad "extract epub_name() from watcher (anchors found)"
else
  ok "extract epub_name() from watcher (anchors found)"

  # Source the extracted function into THIS shell (it is pure: only tr + case).
  # shellcheck disable=SC1090
  source "$FN_FILE"

  check_name() {  # check_name <input> <expected>
    local got; got="$(epub_name "$1")"
    if [[ "$got" == "$2" ]]; then ok "epub_name '$1' -> '$2'"
    else bad "epub_name '$1' -> '$got' (expected '$2')"; fi
  }

  # The FB2 cases — these must behave EXACTLY as before the FB3 work.
  check_name "book.fb2"            "book.epub"
  check_name "book.fb2.zip"        "book.epub"
  check_name "My Book (1).fb2"     "My Book (1).epub"
  check_name "BOOK.FB2"            "BOOK.epub"        # case-insensitive
  check_name "BOOK.FB2.ZIP"       "BOOK.epub"
  check_name "архив.fb2.zip"       "архив.epub"       # unicode name
  # The FB3 case — added by this milestone.
  check_name "novel.fb3"           "novel.epub"
  check_name "NOVEL.FB3"           "NOVEL.epub"
  # Unknown extension -> empty (watcher skips it), unchanged behaviour.
  check_name "notes.txt"           ""
  check_name "image.png"           ""
  # A name that merely CONTAINS fb2/fb3 mid-string is not matched.
  check_name "fb2-notes.md"        ""
fi

# ---------------------------------------------------------------------------
# B. convert_book() structural invariant (static assertions on shipping source).
#    Extract the convert_book() body the same way and assert the guarantees.
# ---------------------------------------------------------------------------
CB_FILE="$SANDBOX/convert_book.sh"
awk '
  /^convert_book\(\) \{/ {grab=1}
  grab {print}
  grab && /^\}/ {exit}
' "$WATCHER" > "$CB_FILE"

if [[ ! -s "$CB_FILE" ]] || ! grep -q '^convert_book() {' "$CB_FILE"; then
  bad "extract convert_book() from watcher"
else
  ok "extract convert_book() from watcher"

  # (1) conv_src defaults to the original src (so non-fb3 inputs are untouched).
  if grep -Eq 'local[[:space:]]+conv_src="\$src"' "$CB_FILE"; then
    ok 'conv_src defaults to "$src" (FB2 path unchanged)'
  else
    bad 'conv_src defaults to "$src" (FB2 path unchanged)'
  fi

  # (2) The ONLY case label that triggers transform handling is *.fb3). There
  #     must be exactly one *.fb3) label and NO *.fb2)/*.fb2.zip) label inside
  #     convert_book (the FB2 inputs fall through with conv_src=src).
  fb3_labels="$(grep -cE '^[[:space:]]*\*\.fb3\)' "$CB_FILE" || true)"
  fb2_labels="$(grep -cE '^[[:space:]]*\*\.fb2(\.zip)?\)' "$CB_FILE" || true)"
  if [[ "$fb3_labels" -eq 1 ]]; then
    ok "transform gated by exactly one *.fb3) case (found $fb3_labels)"
  else
    bad "transform gated by exactly one *.fb3) case (found $fb3_labels)"
  fi
  if [[ "$fb2_labels" -eq 0 ]]; then
    ok "no *.fb2)/*.fb2.zip) special-case in convert_book (found $fb2_labels)"
  else
    bad "no *.fb2)/*.fb2.zip) special-case in convert_book (found $fb2_labels)"
  fi

  # (3) The transform invocation ($FB3_TRANSFORM) lives INSIDE the *.fb3) case,
  #     i.e. after the only `*.fb3)` label and before that case's `;;`. If it
  #     ever leaked outside, FB2 inputs could hit it.
  # NOTE: BSD awk does NOT understand \s in regex — use [[:space:]] so this
  # works on macOS (where \s would match a literal 's').
  fb3_block="$(awk '
      /^[[:space:]]*\*\.fb3\)/ {grab=1}
      grab {print}
      grab && /;;/ {exit}
    ' "$CB_FILE")"
  if printf '%s\n' "$fb3_block" | grep -q 'FB3_TRANSFORM'; then
    ok "FB3_TRANSFORM invoked only within the *.fb3) case"
  else
    bad "FB3_TRANSFORM invoked only within the *.fb3) case"
  fi
  # Belt-and-suspenders: the transform token appears exactly as often in the
  # whole function as it does inside the fb3 block (nothing outside it).
  total_tx="$(grep -c 'FB3_TRANSFORM' "$CB_FILE" || true)"
  inblock_tx="$(printf '%s\n' "$fb3_block" | grep -c 'FB3_TRANSFORM' || true)"
  if [[ "$total_tx" -eq "$inblock_tx" && "$total_tx" -ge 1 ]]; then
    ok "no FB3_TRANSFORM use outside the *.fb3) case ($total_tx total)"
  else
    bad "FB3_TRANSFORM leaks outside *.fb3) case (total=$total_tx inblock=$inblock_tx)"
  fi

  # (4) The downstream conversion runs against $conv_src (the indirection point).
  if grep -q 'conv_src' "$CB_FILE"; then
    ok "downstream conversion uses \$conv_src indirection"
  else
    bad "downstream conversion uses \$conv_src indirection"
  fi
fi

# ---------------------------------------------------------------------------
# C. find-filters still include .fb2 and .fb2.zip (folder-tree + count_pending).
#    The FB3 work added '*.fb3' to these globs; the .fb2 globs must remain.
# ---------------------------------------------------------------------------
if grep -Eq "iname '\*\.fb2'" "$WATCHER" \
   && grep -Eq "iname '\*\.fb2\.zip'" "$WATCHER"; then
  ok "find filters still match *.fb2 and *.fb2.zip"
else
  bad "find filters still match *.fb2 and *.fb2.zip"
fi

echo ""
echo "==> $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
