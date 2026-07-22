#!/bin/bash
# run-calibre-install-tests.sh — интеграционный прогон конвейера CalibreInstaller (CAL-3, task 3.14).
#
# ЧТО ДЕЛАЕТ
# ---------
# 1. Печёт fixture-DMG (tests/make-fake-calibre-dmg.sh) четырёх видов: happy · brokencli (verify-fail)
#    · noapp (без calibre.app) · highos (LSMinimumSystemVersion=99.0). Плюс bad.sha512 (чужой хеш).
# 2. Поднимает локальный ТРОТТЛЕННЫЙ HTTP-сервер (127.0.0.1, случайный порт) поверх папки с фикстурами
#    — троттлинг даёт окно для теста отмены и заставляет SHA-стрим реально идти чанками.
# 3. Компилирует НАСТОЯЩИЙ движок (app/CalibreLocator.swift + app/CalibreInstaller.swift) вместе с
#    TAP-раннером (tests/CalibreInstallTests/main.swift) — как build-app.sh: xcrun swiftc, whole-module,
#    без SwiftPM/XCTest. Продакшен-код НЕ меняется.
# 4. Гоняет бинарь в throwaway HOME/TEST_ROOT под защёлкой (FB2_CALIBRE_TEST_MODE=1); URL DMG/SHA и
#    маркер пропуска codesign приходят в env (действуют только под защёлкой — урок 015).
#
# ИЗОЛЯЦИЯ: всё во временных папках (mktemp). Реальный ~/Library/Application Support/fb2-to-epub,
# реальный launchd и настоящий Calibre НЕ трогаются; сеть — только loopback.
#
# Usage:  tests/run-calibre-install-tests.sh
# Exit:   0 = всё зелено, 1 = падение теста / сборки / отсутствие инструмента.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_DIR/app"
TDIR="$REPO_DIR/tests/CalibreInstallTests"
MK="$REPO_DIR/tests/make-fake-calibre-dmg.sh"
VER="9.11.0"

# --- проверки инструментов -------------------------------------------------
xcrun --find swiftc >/dev/null 2>&1 || {
  echo "run-calibre-install-tests: swiftc not found (install Xcode)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || {
  echo "run-calibre-install-tests: python3 not found" >&2; exit 1; }
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
[[ -d "$SDK_PATH" ]] || {
  echo "run-calibre-install-tests: macOS SDK not found via xcrun" >&2; exit 1; }

SRCS=(
  "$APP/CalibreLocator.swift"     # контракт детекта (движок ставим ровно туда, где он ищет app-owned)
  "$APP/CalibreInstaller.swift"   # ПОД ТЕСТОМ: конвейер CAL-3 + InstallStore (сшивка CAL-4)
  "$APP/EngineClient.swift"       # CAL-4: оживление агента через installer.sh (runInstaller/agentStatus)
  "$APP/StateModel.swift"         # StateStore — зависимость EngineClient.hasRawHistory
  "$TDIR/main.swift"              # TAP-раннер + сценарии
)
for s in "${SRCS[@]}" "$MK"; do
  [[ -f "$s" ]] || { echo "run-calibre-install-tests: missing $s" >&2; exit 1; }
done

# --- временные ресурсы + гарантированная уборка ----------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fb2-calinstall.XXXXXX")"
SERVE="$WORK/serve"
BIN_DIR="$WORK/bin"
TEST_ROOT="$WORK/root"
HOME_DIR="$WORK/realhome"
SRV_PID=""
mkdir -p "$SERVE" "$BIN_DIR" "$TEST_ROOT" "$HOME_DIR"

cleanup() {
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" >/dev/null 2>&1 || true
  # Подстраховка: размонтировать возможные залипшие фикстуры (тесты чистят сами).
  for mp in "$TEST_ROOT"/home-*/Library/Application\ Support/fb2-to-epub/downloads/mnt; do
    [[ -d "$mp" ]] && hdiutil detach "$mp" -force >/dev/null 2>&1 || true
  done
  # CAL-4: belt-and-suspenders — выгрузить любые оставшиеся throwaway-агенты активации
  # (тест сам делает bootout в defer; это на случай падения посередине). Боевой агент
  # com.arrivarus.fb2toepub.agent НЕ трогаем — только .test.* метки.
  launchctl print "gui/$(id -u)" 2>/dev/null \
    | grep -oE 'com\.arrivarus\.fb2toepub\.test\.[A-Za-z0-9._-]+' | sort -u \
    | while read -r lbl; do launchctl bootout "gui/$(id -u)/$lbl" >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- фикстуры --------------------------------------------------------------
echo "==> печём fixture-DMG (happy · brokencli · noapp · highos)"
"$MK" --ver "$VER" "$SERVE/happy"                 >/dev/null
"$MK" --ver "$VER" --broken-cli "$SERVE/brokencli" >/dev/null
"$MK" --ver "$VER" --no-app "$SERVE/noapp"          >/dev/null
"$MK" --ver "$VER" --lsmin 99.0 "$SERVE/highos"     >/dev/null
# Чужой хеш (128 hex нулей) — для сценария «битый sha».
printf '%0128d' 0 > "$SERVE/bad.sha512"

# --- троттленный HTTP-сервер ----------------------------------------------
SRV_PY="$WORK/server.py"
cat > "$SRV_PY" <<'PY'
import sys, os, time, http.server, socketserver
DIR = sys.argv[1]
CHUNK = 131072      # 128 КБ
DELAY = 0.005       # окно для отмены + многочанковый SHA-стрим

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        rel = self.path.split('?', 1)[0].lstrip('/')
        full = os.path.normpath(os.path.join(DIR, rel))
        if not full.startswith(os.path.abspath(DIR)) or not os.path.isfile(full):
            self.send_response(404); self.end_headers(); return
        size = os.path.getsize(full)
        self.send_response(200)
        self.send_header('Content-Length', str(size))
        self.send_header('Content-Type', 'application/octet-stream')
        self.end_headers()
        with open(full, 'rb') as f:
            while True:
                b = f.read(CHUNK)
                if not b: break
                try:
                    self.wfile.write(b); self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return          # клиент отменил загрузку — это ОК
                time.sleep(DELAY)

class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

srv = S(('127.0.0.1', 0), H)
print('PORT %d' % srv.server_address[1], flush=True)
srv.serve_forever()
PY

SRV_OUT="$WORK/server.out"
python3 "$SRV_PY" "$SERVE" > "$SRV_OUT" 2>"$WORK/server.err" &
SRV_PID=$!
disown "$SRV_PID" 2>/dev/null || true   # убрать из таблицы задач, чтобы bash не печатал «Terminated» при уборке

# дождаться строки PORT
PORT=""
for _ in $(seq 1 100); do
  PORT="$(sed -n 's/^PORT //p' "$SRV_OUT" 2>/dev/null | head -1)"
  [[ -n "$PORT" ]] && break
  kill -0 "$SRV_PID" 2>/dev/null || { echo "run-calibre-install-tests: сервер не стартовал" >&2; cat "$WORK/server.err" >&2; exit 1; }
  sleep 0.05
done
[[ -n "$PORT" ]] || { echo "run-calibre-install-tests: не получили порт сервера" >&2; exit 1; }
BASE="http://127.0.0.1:$PORT"
echo "==> локальный сервень фикстур: $BASE"

# --- компиляция ------------------------------------------------------------
BIN="$BIN_DIR/calibre-install-tests"
echo "==> компиляция (xcrun swiftc, whole-module, Foundation+Combine+CryptoKit)"
xcrun swiftc \
  -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macos11.0" \
  "${SRCS[@]}" \
  -o "$BIN"

# --- прогон ----------------------------------------------------------------
echo "==> прогон"
echo ""
env \
  HOME="$HOME_DIR" \
  FB2_CALIBRE_TEST_MODE=1 \
  FB2_CALIBRE_TEST_ROOT="$TEST_ROOT" \
  FB2_TEST_SERVER="$BASE" \
  FB2_TEST_VER="$VER" \
  FB2_REPO_DIR="$REPO_DIR" \
  "$BIN"
