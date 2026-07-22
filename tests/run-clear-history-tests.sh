#!/bin/bash
# run-clear-history-tests.sh — regression suite for the Status-screen actions in
# app/EngineClient+Status.swift:
#   • "Очистить"          — clear recent history       (recent-cleared-at marker)
#   • "Сбросить статистику" — reset lifetime counter    (stats-baseline marker)
#   • "Сменить папку"      — changeWatchFolder          (installer guard + rc)
#
# (Name kept for back-compat; covers all three actions now.)
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
# "Сменить папку" runs a throwaway STUB installer (records its WATCH_DIR arg and
# exits) — NO real launchctl, NO real installer.sh, NO agent boot.
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
# UpdateChecker.swift imports CryptoKit + AppKit (NOT SwiftUI); it links fine into
# a headless CLI and the tests never invoke its UI/terminate paths — only the pure
# isNewer / isTrustedSource functions are exercised.
SRCS=(
  "$APP/CalibreLocator.swift"         # CAL-1: контракт детекта, на него опирается EngineClient
  "$APP/EngineClient.swift"
  "$APP/EngineClient+Status.swift"
  "$APP/StateModel.swift"
  "$APP/UpdateChecker.swift"          # v0.2.2 auto-update: isNewer / isTrustedSource
  "$TDIR/Stubs.swift"                 # inert CoverQueueStore so the engine compiles headless
  "$TDIR/main.swift"                  # the TAP runner + "Очистить"/reset/change-folder cases
  "$TDIR/UpdateCheckerTests.swift"    # v0.2.2 auto-update cases (semver/trust/engine-refresh)
  "$TDIR/RawHistoryTests.swift"       # CAL-2 hasRawHistory (D37 hybrid: banner vs blocker)
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
