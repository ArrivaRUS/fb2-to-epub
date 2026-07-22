#!/bin/bash
# run-calibre-ui-fixture.sh — изолированный ЖИВОЙ UI-прогон онбординга Calibre на ФИКСТУРЕ (CAL-4/4.7).
#
# ЗАЧЕМ
# -----
# Запускает СОБРАННОЕ приложение (build/dist/fb2-to-epub.app) в полной изоляции, чтобы РУКАМИ
# (Юрка, computer-use в CAL-5) прокликать весь флоу онбординга — БЕЗ настоящего 330-МБ Calibre и
# БЕЗ касания боевого агента/движка:
#   тап «Установить Calibre» → прогресс скачивания → установка → проверка → «Готово! Движок на
#   месте» → блокер/баннер исчезает → обычный Status. Плюс сценарии D40 (закрыть окно на середине →
#   открыть из Dock; Cmd-Q во время скачивания).
#
# ПОЧЕМУ localhost-HTTP, а не file:// (как в примере plans.md)
# -----------------------------------------------------------
# URLSessionDownloadTask НЕ отдаёт прогресс (а часто и не качает) по схеме file:// — поэтому весь
# конвейер CAL-3 тестируется поверх троттленного localhost-HTTP. Этот харнесс поднимает такой же
# сервер и подсовывает его URL — тогда прогресс-бар реально живёт. Троттлинг ещё и даёт окно, чтобы
# успеть проверить «Отмена» и Cmd-Q-во-время-скачивания. Имя файла — настоящее `calibre-<ver>.dmg`
# (make-fake-calibre-dmg генерит именно его; в примере plans.md «calibre-fake.dmg» — опечатка).
#
# ИЗОЛЯЦИЯ (урок 015): throwaway HOME внутри TEST_ROOT (защёлка мутации взведена) + тест-метка агента
# `com.arrivarus.fb2toepub.test.ui` + FB2_CALIBRE_SKIP_CODESIGN=1 (стаб не подписан). Боевой
# ~/Library/Application Support/fb2-to-epub, реальный launchd и настоящий Calibre — не трогаются.
# По выходу приложения: сервер убит, тест-агент выгружен, временные папки снесены.
#
# Usage:  tests/run-calibre-ui-fixture.sh
#         FB2_FORCE_SETUP=1 tests/run-calibre-ui-fixture.sh   # начать с экрана «Установка» (Setup)
# Требует: собранный build/dist/fb2-to-epub.app (build/build-app.sh 0.10.0-dev).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BIN="$REPO_DIR/build/dist/fb2-to-epub.app/Contents/MacOS/fb2-to-epub"
MK="$REPO_DIR/tests/make-fake-calibre-dmg.sh"
VER="9.11.0"
LABEL="com.arrivarus.fb2toepub.test.ui"   # стабильная тест-метка (одна инертная override-запись)

[[ -x "$APP_BIN" ]] || { echo "run-calibre-ui-fixture: нет собранного приложения — сначала build/build-app.sh 0.10.0-dev" >&2; exit 1; }
[[ -x "$MK" ]] || { echo "run-calibre-ui-fixture: нет $MK" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "run-calibre-ui-fixture: нет python3" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fb2-uifix.XXXXXX")"
# B1(a): HOME_DIR ДОЛЖЕН лежать ВНУТРИ TEST_ROOT — иначе install-root
# ($HOME_DIR/Library/Application Support/fb2-to-epub) оказывается вне TEST_ROOT,
# CalibreTestLatch.allowsMutation=false, и харнесс молча свалился бы на прод (урок 015).
SERVE="$WORK/serve"; TEST_ROOT="$WORK/root"; HOME_DIR="$TEST_ROOT/home"
SRV_PID=""
mkdir -p "$SERVE" "$HOME_DIR" "$TEST_ROOT"

cleanup() {
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  echo "run-calibre-ui-fixture: убрано (сервер, тест-агент $LABEL, $WORK)."
}
trap cleanup EXIT INT TERM

echo "==> печём fixture-DMG (happy)"
# --pad-mb 55: живое приложение держит прод-порог minDownloadBytes=50 МБ (санити «DMG не
# огрызок»); фикстура меньше — конвейер честно даёт .error(.network). Порог в проде не трогаем.
"$MK" --ver "$VER" --pad-mb 55 "$SERVE" >/dev/null

echo "==> троттленный localhost-HTTP над фикстурой"
SRV_PY="$WORK/server.py"
cat > "$SRV_PY" <<'PY'
import sys, os, time, http.server, socketserver
DIR = sys.argv[1]; CHUNK = 131072; DELAY = 0.06   # ~2 МБ/с: 55-МБ фикстура качается ~27с — окно для Отмены/закрытия окна/Cmd-Q
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
                try: self.wfile.write(b); self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError): return
                time.sleep(DELAY)
class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True; daemon_threads = True
srv = S(('127.0.0.1', 0), H); print('PORT %d' % srv.server_address[1], flush=True); srv.serve_forever()
PY
python3 "$SRV_PY" "$SERVE" > "$WORK/server.out" 2>"$WORK/server.err" &
SRV_PID=$!
PORT=""
for _ in $(seq 1 100); do
  PORT="$(sed -n 's/^PORT //p' "$WORK/server.out" 2>/dev/null | head -1)"
  [[ -n "$PORT" ]] && break
  kill -0 "$SRV_PID" 2>/dev/null || { echo "run-calibre-ui-fixture: сервер не стартовал" >&2; cat "$WORK/server.err" >&2; exit 1; }
  sleep 0.05
done
[[ -n "$PORT" ]] || { echo "run-calibre-ui-fixture: не получили порт" >&2; exit 1; }
BASE="http://127.0.0.1:$PORT"
echo "==> сервень: $BASE"

# --- Самопроверка защёлки (B1b): install-root ОБЯЗАН лежать внутри канонизированного
# TEST_ROOT — иначе CalibreTestLatch.allowsMutation=false, и приложение молча пошло бы на
# ПРОД-URL/прод-агента (урок 015). Повторяем формулу приложения на bash: `cd … && pwd -P`
# = realpath-семантика canonical(); граница сегмента — как isInside(). Несовпадение → abort.
canon() { ( cd "$1" 2>/dev/null && pwd -P ); }
TR_CANON="$(canon "$TEST_ROOT")"
HOME_CANON="$(canon "$HOME_DIR")"
[[ -n "$TR_CANON" && -n "$HOME_CANON" ]] || {
  echo "run-calibre-ui-fixture: не удалось канонизировать TEST_ROOT/HOME_DIR (нет каталога?)" >&2; exit 1; }
INSTALL_ROOT="$HOME_CANON/Library/Application Support/fb2-to-epub"
case "$INSTALL_ROOT/" in
  "$TR_CANON"/*) : ;;   # install-root внутри TEST_ROOT — защёлка мутации взведётся, ок
  *)
    echo "run-calibre-ui-fixture: ABORT — install-root ВНЕ TEST_ROOT: тест-защёлка мутации не взведётся," >&2
    echo "  и приложение пошло бы на ПРОД-URL/прод-агента (урок 015). HOME_DIR должен лежать внутри TEST_ROOT." >&2
    echo "    install-root: $INSTALL_ROOT" >&2
    echo "    TEST_ROOT:    $TR_CANON" >&2
    exit 1 ;;
esac
echo "==> защёлка ок: install-root внутри TEST_ROOT ($TR_CANON)"

echo "==> запуск приложения (изолированный HOME=$HOME_DIR, метка=$LABEL)."
echo "    Кликай флоу; закрой окно / Cmd-Q — сервер и тест-агент уберутся сами."
# m1: FB2_FORCE_SETUP/FB2_FORCE_COVER НЕ пробрасываем префиксом — они уже в окружении
# скрипта (запуск `FB2_FORCE_SETUP=1 tests/run-calibre-ui-fixture.sh`) и наследуются дочерним
# процессом. Прежний `${FB2_FORCE_SETUP:+…}` в позиции env-assignment ломал запуск
# (`command not found`): расширение параметра не распознаётся как присваивание.
HOME="$HOME_DIR" \
FB2_CALIBRE_TEST_MODE=1 \
FB2_CALIBRE_TEST_ROOT="$TEST_ROOT" \
FB2_CALIBRE_DISABLE_SYSTEM=1 \
FB2_CALIBRE_SKIP_CODESIGN=1 \
FB2_CALIBRE_DMG_URL="$BASE/calibre-$VER.dmg" \
FB2_CALIBRE_SHA512_URL="$BASE/calibre-$VER.dmg.sha512" \
FB2_AGENT_LABEL="$LABEL" \
"$APP_BIN"
