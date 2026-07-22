#!/bin/bash
# run-cover-job-tests.sh — regression suite for the cover-JOB write-layer in
# app/EngineClient+Status.swift (Фича 1 "Утвердить" + Фича 2 плумбинг):
#   • requestCover(.apply, editedTitle:, editedAuthor:)   — optional edited_* fields
#   • requestApplyGenerated(pngPath:, editedTitle:, editedAuthor:)  — same + png
#   • requestConfirmAuto(editedTitle:, editedAuthor:)     — action "apply_confirm"
#
# Mirrors the project's build model (build/build-app.sh + run-clear-history-tests):
# compile with `xcrun swiftc`, whole-module, Foundation-only, no SwiftPM/XCTest.
# We compile the REAL production write-layer sources together with an inert
# Stubs.swift (so EngineClient links without SwiftUI) and the TAP runner main.swift,
# then run the resulting CLI binary. Production code is NOT modified.
#
# Isolation: each test points FB2_COVERS_DIR at a throwaway `mktemp -d` and sets
# FB2_SKIP_KICKSTART=1, so jobs land in the temp dir and NO launchctl / real agent
# is touched. HOME + LaunchAgent label are throwaway too. Fully deterministic.
#
# Usage:  tests/run-cover-job-tests.sh
# Exit:   0 = all green, 1 = a test failed / build failed.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_DIR/app"
TDIR="$REPO_DIR/tests/CoverJobTests"

# --- tool checks -----------------------------------------------------------
xcrun --find swiftc >/dev/null 2>&1 || {
  echo "run-cover-job-tests: swiftc not found (install Xcode)" >&2; exit 1; }
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
[[ -d "$SDK_PATH" ]] || {
  echo "run-cover-job-tests: macOS SDK not found via xcrun" >&2; exit 1; }

# Production sources under test (Foundation-only subset — NO SwiftUI files).
SRCS=(
  "$APP/CalibreLocator.swift"    # CAL-1: контракт детекта, на него опирается EngineClient
  "$APP/EngineClient.swift"
  "$APP/EngineClient+Status.swift"
  "$APP/StateModel.swift"
  "$TDIR/Stubs.swift"    # inert CoverQueueStore so the engine compiles headless
  "$TDIR/main.swift"     # the TAP runner + cover-job write-layer cases
)
for s in "${SRCS[@]}"; do
  [[ -f "$s" ]] || { echo "run-cover-job-tests: missing $s" >&2; exit 1; }
done

# --- compile into a throwaway dir, run, clean up ---------------------------
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fb2-coverjob-bin.XXXXXX")"
cleanup() { rm -rf "$BIN_DIR"; }
trap cleanup EXIT

BIN="$BIN_DIR/cover-job-tests"

echo "==> compiling cover-job suite (xcrun swiftc, Foundation-only)"
xcrun swiftc \
  -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macos11.0" \
  "${SRCS[@]}" \
  -o "$BIN"

echo "==> running"
echo ""
"$BIN"
