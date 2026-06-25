#!/bin/bash
# run-clear-history-tests.sh — regression suite for the "Очистить" (clear recent
# history) fix in app/EngineClient+Status.swift.
#
# Mirrors the project's build model (build/build-app.sh): compile with
# `xcrun swiftc`, whole-module, Foundation-only, no SwiftPM/XCTest target.
# We compile the REAL production engine sources together with the test files
# and an inert Stubs.swift (so the engine links without dragging in SwiftUI),
# then run the resulting CLI binary. Production code is NOT modified.
#
# Isolation: the tests themselves create throwaway `mktemp -d` HOMEs and a
# throwaway LaunchAgent label — they never touch the real agent, the real
# ~/Library/Application Support/fb2-to-epub, ~/Desktop/fb2-to-epub, or books.
#
# Usage:  tests/run-clear-history-tests.sh
# Exit:   0 = all green, 1 = a test failed / build failed.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_DIR/app"
TDIR="$REPO_DIR/tests/ClearHistoryTests"

# --- tool checks -----------------------------------------------------------
xcrun --find swiftc >/dev/null 2>&1 || {
  echo "run-clear-history-tests: swiftc not found (install Xcode)" >&2; exit 1; }
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
[[ -d "$SDK_PATH" ]] || {
  echo "run-clear-history-tests: macOS SDK not found via xcrun" >&2; exit 1; }

# Production sources under test (Foundation-only subset — NO SwiftUI files).
SRCS=(
  "$APP/EngineClient.swift"
  "$APP/EngineClient+Status.swift"
  "$APP/StateModel.swift"
  "$TDIR/Stubs.swift"     # inert CoverQueueStore so the engine compiles headless
  "$TDIR/main.swift"      # the test runner + cases
)
for s in "${SRCS[@]}"; do
  [[ -f "$s" ]] || { echo "run-clear-history-tests: missing $s" >&2; exit 1; }
done

# --- compile into a throwaway dir, run, clean up ---------------------------
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fb2-clearhist-bin.XXXXXX")"
cleanup() { rm -rf "$BIN_DIR"; }
trap cleanup EXIT

BIN="$BIN_DIR/clear-history-tests"

echo "==> compiling regression suite (xcrun swiftc, Foundation-only)"
xcrun swiftc \
  -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macos11.0" \
  "${SRCS[@]}" \
  -o "$BIN"

echo "==> running"
echo ""
"$BIN"
