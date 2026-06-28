#!/bin/bash
# run-fb3-tests.sh — entry point for the FB3->FB2 transform test suite.
#
# Thin wrapper (mirrors the project's other tests/run-*.sh) around the stdlib
# Python TAP runner in tests/fb3-transform-tests/run.py. No pip install, no
# pytest, no lxml: the transform under test (bin/fb2-to-epub-fb3.py) is itself
# stdlib-only, and so is this suite, so it runs anywhere python3 exists.
#
# What it covers (all on a SYNTHETIC in-process FB3 fixture — portable, the real
# ~/Desktop/*.fb3 are NOT in the repo/CI):
#   • e2e: transform -> well-formed FB2; binaries == unique images; cover;
#     metadata incl. genre-map;
#   • mapping: em->emphasis, internal/external/note links, ul/ol, table,
#     nested sections, notes count==1 and count>1, SVG graceful, image dedup,
#     text/tail preservation;
#   • errors: non-FB3 -> rc=2, broken XML -> rc=1;
#   • determinism: re-run is byte-identical.
# Optional, auto-SKIP when the tool/files are absent:
#   • FB3->FB2->EPUB via calibre `ebook-convert`;
#   • the real ~/Desktop/fb2-to-epub/*.fb3 books.
#
# Usage:  bash tests/run-fb3-tests.sh
# Exit:   0 = all passed (skips allowed), 1 = a test failed / no python3.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_DIR/tests/fb3-transform-tests/run.py"
[[ -f "$RUNNER" ]] || { echo "run-fb3-tests: missing $RUNNER" >&2; exit 1; }

# Resolve python3 the same way the watcher does (env override -> common paths).
PY="${PYTHON3:-}"
if [[ -z "$PY" || ! -x "$PY" ]]; then
  for cand in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [[ -x "$cand" ]] && { PY="$cand"; break; }
  done
fi
[[ -z "$PY" ]] && PY="$(command -v python3 2>/dev/null || true)"
[[ -n "$PY" ]] || { echo "run-fb3-tests: python3 not found" >&2; exit 1; }

echo "==> FB3 transform suite ($("$PY" --version 2>&1))"
echo ""
exec "$PY" "$RUNNER"
