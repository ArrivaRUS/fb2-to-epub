#!/bin/bash
# run-calibre-locator-tests.sh — юниты контракта детекта Calibre (CAL-1).
#
# Под тестом app/CalibreLocator.swift:
#   • порядок кандидатов app-owned → /Applications → ~/Applications;
#   • валидная локация = исполняемы ВСЕ ТРИ CLI (частичный Calibre = «движка нет»);
#   • тест-защёлка урока 015 (FB2_CALIBRE_TEST_MODE / _TEST_ROOT / _DISABLE_SYSTEM)
#     + мутирующая защёлка allowsMutation(installRoot:).
#
# Модель сборки — как у остальных наборов репо (build/build-app.sh,
# run-clear-history-tests.sh): `xcrun swiftc`, whole-module, Foundation-only,
# без SwiftPM/XCTest. Компилируем НАСТОЯЩИЙ продакшен-локатор вместе с
# TAP-раннером и запускаем получившийся CLI. Продакшен-код не меняется.
#
# Изоляция: все деревья — фикстуры в `mktemp -d` со стабами вместо CLI; реальный
# Calibre не нужен и не используется. Ничего не пишется вне временных папок,
# никаких процессов, launchctl, сети — полностью детерминированно.
#
# Usage:  tests/run-calibre-locator-tests.sh
# Exit:   0 = всё зелено, 1 = падение теста / сборки.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_DIR/app"
TDIR="$REPO_DIR/tests/CalibreLocatorTests"

# --- проверки инструментов -------------------------------------------------
xcrun --find swiftc >/dev/null 2>&1 || {
  echo "run-calibre-locator-tests: swiftc not found (install Xcode)" >&2; exit 1; }
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
[[ -d "$SDK_PATH" ]] || {
  echo "run-calibre-locator-tests: macOS SDK not found via xcrun" >&2; exit 1; }

SRCS=(
  "$APP/CalibreLocator.swift"   # продакшен-контракт детекта (Foundation-only)
  "$TDIR/main.swift"            # TAP-раннер + фикстурные деревья
)
for s in "${SRCS[@]}"; do
  [[ -f "$s" ]] || { echo "run-calibre-locator-tests: missing $s" >&2; exit 1; }
done

# --- компиляция во временную папку, прогон, уборка -------------------------
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fb2-callocator-bin.XXXXXX")"
cleanup() { rm -rf "$BIN_DIR"; }
trap cleanup EXIT

BIN="$BIN_DIR/calibre-locator-tests"

echo "==> compiling calibre-locator suite (xcrun swiftc, Foundation-only)"
xcrun swiftc \
  -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macos11.0" \
  "${SRCS[@]}" \
  -o "$BIN"

echo "==> running"
echo ""
"$BIN"
