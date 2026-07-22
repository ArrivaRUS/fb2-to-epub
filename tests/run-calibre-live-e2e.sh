#!/bin/bash
# run-calibre-live-e2e.sh — ЕДИНСТВЕННЫЙ живой e2e онбординга Calibre (CAL-5, task 5.1).
#
# ЗАЧЕМ (урок 016)
# ---------------
# Перед релизом — РОВНО ОДИН настоящий прогон: реальное скачивание + установка + конвертация
# на живом Calibre. Стабы (CAL-3 fixture-DMG) проверяют КОНТРАКТ, но НЕ реальное поведение
# внешнего бинаря; живой e2e подтверждает гипотезы ресёрча, которые нельзя проверить на стабе:
#   • DMG, скачанный НАШИМ конвейером (URLSession, не браузером) → БЕЗ com.apple.quarantine;
#   • образ подписан Developer ID + нотаризован → codesign --verify --strict и spctl accepted;
#   • настоящий ebook-convert реально конвертирует .fb2 → валидный EPUB из app-owned места.
# Любой красный ассерт может быть ОПРОВЕРЖЕНИЕМ гипотезы ресёрча — и это важно увидеть до релиза.
#
# ЧТО ГОНЯЕТ (только при RUN_LIVE=1)
# ---------------------------------
#   1. Throwaway HOME + СТАБИЛЬНАЯ тест-метка агента com.arrivarus.fb2toepub.test.live-e2e
#      (не плодит launchd-остатки; боевой label com.arrivarus.fb2toepub.agent НЕ трогаем — урок 015).
#   2. Скачивание с прод-URL https://calibre-ebook.com/dist/osx (~330 МБ) ЧЕРЕЗ НАШ конвейер
#      CalibreInstaller (Swift-драйвер tests/CalibreLiveE2E) → SHA-512 → mount/ditto/detach →
#      НАСТОЯЩИЙ codesign --verify --strict (БЕЗ FB2_CALIBRE_SKIP_CODESIGN) → exec --version → своп.
#   3. Активация агента через packaging/installer.sh под тест-меткой (plist → app-owned пути).
#   4. Конвертация реального .fb2 (генерится тут же) настоящим app-owned движком через
#      УСТАНОВЛЕННЫЙ агент-скрипт (runner→watcher) в throwaway-окружении → EPUB в watch-папке.
#   5. Ассерты: EPUB валиден (unzip -t, mimetype=application/epub+zip) · xattr БЕЗ quarantine ·
#      spctl accepted · plist указывает на app-owned пути.
#
# ИЗОЛЯЦИЯ (урок 015 + красная линия «не трогать боевые пути»): ВСЁ во временных папках (mktemp) +
# тест-метка. Боевой ~/Library/Application Support/fb2-to-epub, реальный launchd-домен и настоящий
# Calibre в /Applications — НЕ трогаются. Два ключевых приёма, потому что launchd НЕ пиннит
# throwaway-HOME (агент, поднятый по-настоящему, писал бы state/covers/log в РЕАЛЬНЫЙ ~/Library и
# мог бы слить covers-jobs человека):
#   • Фаза 3: launchctl ПЕРЕХВАЧЕН PATH-шайбой → installer.sh проходит активацию целиком (детект,
#     plist, установка скриптов), но реальный launchd не мутируется; активацию доказывает журнал
#     вызовов launchctl. Настоящий launchd-bootstrap отдельно закрыт CAL-4.
#   • Фаза 4: установленный агент-скрипт (runner→watcher) запускается НАПРЯМУЮ с ЯВНЫМ
#     throwaway-окружением (HOME/WATCH_DIR/FB2_STATE_DIR/COVERS/LOG) → реальный движок, но всё в
#     throwaway. `open -b` watcher'а тоже перехвачен шайбой (не поднимает боевое приложение).
# Смонтированные DMG отмонтируются в trap при ЛЮБОМ исходе; временные папки сносятся.
#
# Usage:
#   tests/run-calibre-live-e2e.sh                 # без RUN_LIVE — вежливо выходит (подсказка)
#   RUN_LIVE=1 tests/run-calibre-live-e2e.sh      # НАСТОЯЩИЙ прогон (~330 МБ, сеть, ~несколько минут)
#   FB2_E2E_DRYRUN=1 tests/run-calibre-live-e2e.sh # СУХОЙ прогон структуры (фикстура+localhost, без сети,
#                                                   # без 330 МБ) — доказывает плумбинг; codesign/spctl
#                                                   # и «настоящий движок» пропускаются как LIVE-ONLY.
# Exit: 0 = зелено (или вежливый выход без RUN_LIVE), 1 = провал ассерта/сборки/инструмента.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_DIR/app"
DRIVER_DIR="$REPO_DIR/tests/CalibreLiveE2E"
INSTALLER="$REPO_DIR/packaging/installer.sh"
MK="$REPO_DIR/tests/make-fake-calibre-dmg.sh"

# СТАБИЛЬНАЯ тест-метка (не pid/uuid): ровно одна инертная launchd-override-запись на все прогоны,
# а не по одной за запуск. installer.sh делает bootout ПЕРЕД bootstrap → повторный прогон
# идемпотентен. Боевой com.arrivarus.fb2toepub.agent не затрагивается (метка .test.*, урок 015).
LABEL="com.arrivarus.fb2toepub.test.live-e2e"
PROD_URL="https://calibre-ebook.com/dist/osx"

# ---------------------------------------------------------------------------
# Режим: RUN_LIVE (настоящий) · FB2_E2E_DRYRUN (сухой) · иначе — вежливый выход.
# ---------------------------------------------------------------------------
RUN_LIVE="${RUN_LIVE:-0}"
DRYRUN="${FB2_E2E_DRYRUN:-0}"

if [[ "$RUN_LIVE" == "1" && "$DRYRUN" == "1" ]]; then
  echo "run-calibre-live-e2e: RUN_LIVE и FB2_E2E_DRYRUN взаимоисключающи — выбери один режим." >&2
  exit 1
fi

if [[ "$RUN_LIVE" != "1" && "$DRYRUN" != "1" ]]; then
  cat <<EOF
run-calibre-live-e2e: это ЖИВОЙ прогон — реальное скачивание ~330 МБ с $PROD_URL,
настоящий codesign/spctl и конвертация на живом Calibre. По умолчанию он НЕ запускается.

  Запустить по-настоящему:   RUN_LIVE=1 tests/run-calibre-live-e2e.sh
  Сухой прогон структуры:    FB2_E2E_DRYRUN=1 tests/run-calibre-live-e2e.sh  (фикстура, без сети)

Выхожу без действий (exit 0).
EOF
  exit 0
fi

# Латч-переменные НИКОГДА не живут в собственном env скрипта: живой прогон обязан идти прод-URL'ом
# с настоящим codesign. Чистим их здесь один раз; dry-run передаёт нужные ЯВНО через `env KEY=val …`
# только дочерним процессам (драйвер/installer.sh), не в env скрипта.
unset FB2_CALIBRE_TEST_MODE FB2_CALIBRE_TEST_ROOT FB2_CALIBRE_DISABLE_SYSTEM \
      FB2_CALIBRE_DMG_URL FB2_CALIBRE_SHA512_URL FB2_CALIBRE_SKIP_CODESIGN 2>/dev/null || true

# ---------------------------------------------------------------------------
# Проверки инструментов.
# ---------------------------------------------------------------------------
need_tool() { command -v "$1" >/dev/null 2>&1 || { echo "run-calibre-live-e2e: нет инструмента '$1'" >&2; exit 1; }; }
xcrun --find swiftc >/dev/null 2>&1 || { echo "run-calibre-live-e2e: swiftc не найден (Xcode)" >&2; exit 1; }
for t in python3 hdiutil ditto unzip plutil launchctl spctl xattr; do need_tool "$t"; done
[[ "$RUN_LIVE" == "1" ]] && need_tool codesign
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
[[ -d "$SDK_PATH" ]] || { echo "run-calibre-live-e2e: macOS SDK не найден" >&2; exit 1; }

SRCS=(
  "$APP/CalibreLocator.swift"     # контракт детекта (движок ложится ровно туда, где ищется app-owned)
  "$APP/CalibreInstaller.swift"   # РЕАЛЬНЫЙ конвейер CAL-3 (скачать→SHA→mount→codesign→своп)
  "$DRIVER_DIR/main.swift"        # тонкий драйвер конвейера (этот e2e)
)
for s in "${SRCS[@]}" "$INSTALLER" "$MK"; do
  [[ -f "$s" ]] || { echo "run-calibre-live-e2e: отсутствует $s" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Счётчик ассертов.
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
# Немедленный красный выход с внятным сообщением ЧТО не совпало (может быть опровержением гипотезы).
die_fail() { bad "$1"; echo ""; echo "==> ЖИВОЙ e2e КРАСНЫЙ: $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Временные ресурсы + гарантированная уборка (никаких артефактов при ЛЮБОМ исходе).
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fb2-live-e2e.XXXXXX")"
HOME_DIR="$WORK/home"                 # throwaway HOME
TEST_ROOT="$WORK"                     # install-root окажется внутри → защёлка (для тест-метки/dry-run)
WATCH="$HOME_DIR/watch"               # throwaway watch-папка
SHIM="$WORK/shim"                     # PATH-шайба: no-op `open`, чтобы watcher не поднимал боевое приложение
LSHIM="$WORK/lshim"                   # PATH-шайба для installer.sh: перехват launchctl (нет мутаций launchd)
LCTL_LOG="$WORK/launchctl-calls.log"  # журнал перехваченных вызовов launchctl (доказать, что активация дошла)
SERVE="$WORK/serve"                   # dry-run: папка фикстур под localhost-сервень
BIN_DIR="$WORK/bin"
RUNLOG="$WORK/e2e-run.log"            # лог прогона (сохраняем в вывод при провале)
APP_SUPPORT="$HOME_DIR/Library/Application Support/fb2-to-epub"
INSTALLED_APP="$APP_SUPPORT/calibre.app"
PLIST="$HOME_DIR/Library/LaunchAgents/$LABEL.plist"
SRV_PID=""
mkdir -p "$HOME_DIR" "$WATCH" "$SHIM" "$LSHIM" "$SERVE" "$BIN_DIR"

# no-op `open`: watcher делает `open -b com.arrivarus.fb2toepub` на старте пакета — без шайбы это
# подняло бы РЕАЛЬНОЕ приложение человека. Шайба ловит вызов и молча выходит.
cat > "$SHIM/open" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$SHIM/open"

# ПЕРЕХВАТ launchctl для installer.sh (изоляция, красная линия брифа + урок 015).
# installer.sh зовёт `launchctl bootout/bootstrap/enable/kickstart` через PATH. Настоящий bootstrap
# поднял бы агент в РЕАЛЬНОМ gui-домене, а launchd НЕ пиннит throwaway-HOME → фоновый прогон watcher'а
# создал бы папки/тронул covers-jobs в БОЕВОМ ~/Library и оставил override-запись в /var/db. Чтобы
# «не трогать боевые пути ни при каком исходе», перехватываем launchctl: installer.sh проходит ВСЮ
# активацию (детект, plutil-plist, установка скриптов), но реальный launchd не мутируется. Журнал
# вызовов доказывает, что активация дошла до bootstrap/kickstart тест-метки. Настоящий launchd-bootstrap
# отдельно закрыт CAL-4 (run-calibre-install-tests: test_realInstallerActivation). Конвертацию гоним
# установленным агент-скриптом напрямую (Фаза 4) — реальный движок, но без launchd-мутации.
cat > "$LSHIM/launchctl" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$LCTL_LOG"
case "\${1:-}" in
  print|print-disabled) exit 1 ;;   # «не найдено» → миграция в installer.sh пропускается (нет ложных срабатываний)
  *) exit 0 ;;                        # bootout/bootstrap/enable/kickstart → «успех» БЕЗ реальной мутации launchd
esac
SH
chmod +x "$LSHIM/launchctl"

# detach с ретраями — как CalibreInstaller.detach (Swift): вежливый detach, затем ретраи
# 1с/2с/4с, и лишь потом -force. Меньше шансов оставить залипший mnt под throwaway-корнем
# (одиночный -force иногда бьётся о busy-том, который через секунду отдался бы штатно).
# Срабатывает лишь при реально залипшем mnt (обычно к моменту trap Фаза 1 уже отмонтировала).
detach_with_retries() {   # detach_with_retries <mountpoint|dev>
  local target="$1" d
  hdiutil detach "$target" >/dev/null 2>&1 && return 0
  for d in 1 2 4; do
    sleep "$d"
    hdiutil detach "$target" >/dev/null 2>&1 && return 0
  done
  hdiutil detach "$target" -force >/dev/null 2>&1 || true
  return 0
}

cleanup() {
  local rc=$?
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" >/dev/null 2>&1 || true
  # Выгрузить тест-агент (bootout идемпотентен; боевой .agent НЕ трогаем — только .test.live-e2e).
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  # Подстраховка: отмонтировать возможный залипший fixture/боевой mnt под throwaway-корнем.
  local mp="$APP_SUPPORT/downloads/mnt"
  if [[ -d "$mp" ]]; then detach_with_retries "$mp"; fi
  if [[ "$rc" -ne 0 && -f "$RUNLOG" ]]; then
    echo ""
    echo "==> лог прогона (последние строки, $RUNLOG):"
    tail -n 40 "$RUNLOG" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

MODE_LABEL="ЖИВОЙ (RUN_LIVE=1)"
[[ "$DRYRUN" == "1" ]] && MODE_LABEL="СУХОЙ (fixture, без сети)"
echo "==> Calibre live e2e — режим: $MODE_LABEL"
echo "    throwaway HOME: $HOME_DIR"
echo "    тест-метка:     $LABEL"
echo ""

# ---------------------------------------------------------------------------
# Компиляция драйвера конвейера.
# ---------------------------------------------------------------------------
DRIVER_BIN="$BIN_DIR/calibre-live-e2e-driver"
echo "==> компиляция драйвера конвейера (xcrun swiftc, whole-module)"
xcrun swiftc \
  -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macos11.0" \
  "${SRCS[@]}" \
  -o "$DRIVER_BIN"

# ---------------------------------------------------------------------------
# dry-run: печём fixture-DMG и поднимаем троттленный localhost-HTTP (как run-calibre-install-tests).
#          file:// не даёт прогресса/докачки у URLSessionDownloadTask — поэтому только HTTP.
# ---------------------------------------------------------------------------
VER="9.11.0"
DRV_ENV=()          # окружение драйвера конвейера (Phase 1)
INSTALLER_LATCH=()  # окружение installer.sh (тест-метка требует защёлки)

if [[ "$DRYRUN" == "1" ]]; then
  echo "==> печём fixture-DMG (happy) и поднимаем localhost-сервень"
  "$MK" --ver "$VER" --pad-mb 5 "$SERVE" >/dev/null

  SRV_PY="$WORK/server.py"
  cat > "$SRV_PY" <<'PY'
import sys, os, time, http.server, socketserver
DIR = sys.argv[1]; CHUNK = 131072; DELAY = 0.003
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
  disown "$SRV_PID" 2>/dev/null || true
  PORT=""
  for _ in $(seq 1 100); do
    PORT="$(sed -n 's/^PORT //p' "$WORK/server.out" 2>/dev/null | head -1)"
    [[ -n "$PORT" ]] && break
    kill -0 "$SRV_PID" 2>/dev/null || { echo "run-calibre-live-e2e: сервень не стартовал" >&2; cat "$WORK/server.err" >&2; exit 1; }
    sleep 0.05
  done
  [[ -n "$PORT" ]] || { echo "run-calibre-live-e2e: не получили порт сервера" >&2; exit 1; }
  BASE="http://127.0.0.1:$PORT"
  echo "    сервень фикстур: $BASE"

  # Драйвер: защёлка ВЗВЕДЕНА → конвейер берёт фикстуру и пропускает codesign (стаб не подписан).
  DRV_ENV=(
    "FB2_CALIBRE_TEST_MODE=1"
    "FB2_CALIBRE_TEST_ROOT=$TEST_ROOT"
    "FB2_CALIBRE_DISABLE_SYSTEM=1"
    "FB2_CALIBRE_DMG_URL=$BASE/calibre-$VER.dmg"
    "FB2_CALIBRE_SHA512_URL=$BASE/calibre-$VER.dmg.sha512"
    "FB2_CALIBRE_SKIP_CODESIGN=1"
    "E2E_MIN_DL_BYTES=1000000"     # фикстура ~5 МБ < дефолтных 50 МБ
    "E2E_DISK_BYTES=1"             # порог диска почти нулевой (реального места хватает всегда)
  )
  # installer.sh: та же защёлка → тест-метка применяется, /Applications-кандидаты выключены.
  INSTALLER_LATCH=(
    "FB2_CALIBRE_TEST_MODE=1"
    "FB2_CALIBRE_TEST_ROOT=$TEST_ROOT"
    "FB2_CALIBRE_DISABLE_SYSTEM=1"
  )
else
  # ЖИВОЙ: драйвер БЕЗ защёлки (латч уже вычищен выше) → прод-URL + настоящий codesign. installer.sh —
  # защёлка ТОЛЬКО ради тест-метки и выключения /Applications-кандидата (иначе plist уехал бы на
  # системный Calibre, если он есть на машине).
  DRV_ENV=()
  INSTALLER_LATCH=(
    "FB2_CALIBRE_TEST_MODE=1"
    "FB2_CALIBRE_TEST_ROOT=$TEST_ROOT"
    "FB2_CALIBRE_DISABLE_SYSTEM=1"
  )
fi

# ===========================================================================
# ФАЗА 1. Установка движка ЧЕРЕЗ НАШ конвейер (скачать→SHA→mount→codesign→своп).
# ===========================================================================
echo ""
echo "==> Фаза 1: установка движка через конвейер CalibreInstaller"
[[ "$RUN_LIVE" == "1" ]] && echo "    (реальное скачивание ~330 МБ с $PROD_URL — это займёт время)"
# Наследуем нормальное окружение (URLSession/сеть/прокси/temp) + переопределяем нужное. Латч уже
# вычищен из env скрипта; в live драйвер защёлки не видит → прод-URL + настоящий codesign.
set +e
env \
  HOME="$HOME_DIR" \
  E2E_HOME="$HOME_DIR" \
  ${DRV_ENV[@]+"${DRV_ENV[@]}"} \
  "$DRIVER_BIN" 2>&1 | tee -a "$RUNLOG"
DRV_RC="${PIPESTATUS[0]}"
set -e
[[ "$DRV_RC" -eq 0 ]] || die_fail "конвейер установки вернул ненулевой код ($DRV_RC) — движок НЕ уложен"
[[ -d "$INSTALLED_APP" ]] || die_fail "после конвейера нет $INSTALLED_APP"
ok "конвейер уложил calibre.app в app-owned место"

# Локатор (bash-близнец детекта) должен видеть app-owned как валидный (все 3 CLI).
CONV="$INSTALLED_APP/Contents/MacOS/ebook-convert"
META="$INSTALLED_APP/Contents/MacOS/ebook-meta"
POLISH="$INSTALLED_APP/Contents/MacOS/ebook-polish"
for cli in "$CONV" "$META" "$POLISH"; do
  [[ -x "$cli" ]] || die_fail "нет исполняемого CLI: $cli (установка неполная)"
done
ok "все три CLI (ebook-convert/meta/polish) исполняемы"

# downloads зачищены после свопа (никакого мусора).
[[ ! -e "$APP_SUPPORT/downloads/calibre.dmg" ]] && ok "downloads/calibre.dmg убран после установки" \
  || bad "downloads/calibre.dmg остался (мусор)"
[[ ! -e "$APP_SUPPORT/calibre.app.installing" ]] && ok "staging (calibre.app.installing) убран" \
  || bad "staging calibre.app.installing остался (мусор)"

# ===========================================================================
# ФАЗА 2. Целостность движка: quarantine · codesign · spctl · exec --version.
# ===========================================================================
echo ""
echo "==> Фаза 2: целостность установленного движка"

# (a) quarantine НЕ проставлен (гипотеза ресёрча: URLSession non-sandbox не ставит карантин).
#     Проверяем и бандл, и сам бинарь ebook-convert (то, что реально исполняется).
q_bundle="$(xattr "$INSTALLED_APP" 2>/dev/null | grep -c 'com.apple.quarantine' || true)"
q_bin="$(xattr "$CONV" 2>/dev/null | grep -c 'com.apple.quarantine' || true)"
if [[ "$q_bundle" -eq 0 && "$q_bin" -eq 0 ]]; then
  ok "com.apple.quarantine ОТСУТСТВУЕТ на calibre.app и ebook-convert (гипотеза подтверждена)"
else
  die_fail "com.apple.quarantine ПРИСУТСТВУЕТ (bundle=$q_bundle bin=$q_bin) — ОПРОВЕРЖЕНИЕ гипотезы ресёрча!"
fi

if [[ "$RUN_LIVE" == "1" ]]; then
  # (b) НАСТОЯЩИЙ codesign --verify --strict (конвейер его уже гонял; здесь — явный внешний контроль).
  if codesign --verify --strict --deep "$INSTALLED_APP" >>"$RUNLOG" 2>&1; then
    ok "codesign --verify --strict --deep: подпись валидна"
  else
    die_fail "codesign --verify --strict провалился на установленном calibre.app"
  fi
  # (c) spctl — Gatekeeper-оценка: accepted (Developer ID + нотаризация).
  spctl_out="$(spctl -a -vv "$INSTALLED_APP" 2>&1 || true)"
  echo "$spctl_out" >> "$RUNLOG"
  if printf '%s' "$spctl_out" | grep -qi 'accepted'; then
    spctl_src="$(printf '%s\n' "$spctl_out" | grep -i 'source=' | head -1 || true)"
    ok "spctl -a -vv: accepted (${spctl_src:-notarized})"
  else
    die_fail "spctl -a -vv НЕ accepted: $spctl_out"
  fi
else
  echo "  skip - codesign --verify (LIVE-ONLY: стаб-фикстура не подписана; конвейер пропускал под защёлкой)"
  echo "  skip - spctl -a -vv accepted (LIVE-ONLY: стаб-фикстура не нотаризована)"
fi

# (d) exec ebook-convert --version — бинарь реально запускается (не заблокирован Gatekeeper'ом).
ver_out="$("$CONV" --version 2>>"$RUNLOG" || true)"
if printf '%s' "$ver_out" | grep -Eq '[0-9]+\.[0-9]+'; then
  ok "ebook-convert --version исполнился: $(printf '%s' "$ver_out" | head -1)"
else
  die_fail "ebook-convert --version не запустился/без версии (вывод: '$ver_out')"
fi

# ===========================================================================
# ФАЗА 3. Активация через installer.sh (тест-метка) → plist на app-owned.
#   launchctl перехвачен шайбой (LSHIM впереди PATH) → реальный launchd НЕ мутируется, боевой
#   ~/Library не трогается. installer.sh проходит активацию целиком; журнал вызовов launchctl
#   доказывает, что дошло до bootstrap/kickstart тест-метки.
# ===========================================================================
echo ""
echo "==> Фаза 3: активация через installer.sh (метка $LABEL, launchctl перехвачен → без мутаций launchd)"
set +e
env \
  PATH="$LSHIM:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$HOME_DIR" \
  FB2_SRC_DIR="$REPO_DIR/bin" \
  FB2_AGENT_LABEL="$LABEL" \
  ${INSTALLER_LATCH[@]+"${INSTALLER_LATCH[@]}"} \
  bash "$INSTALLER" "$WATCH" >>"$RUNLOG" 2>&1
INST_RC=$?
set -e
[[ "$INST_RC" -eq 0 ]] || die_fail "installer.sh активация вернула ненулевой код ($INST_RC)"
ok "installer.sh отработал (rc=0)"
[[ -f "$PLIST" ]] || die_fail "plist не создан: $PLIST"
ok "plist создан под тест-меткой"

# plist указывает на app-owned пути (не на системный /Applications).
plist_get() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null | tr -d '\n'; }
CAL_DIR="$(plist_get EnvironmentVariables.CALIBRE_MACOS_DIR)"
EBK_CONV="$(plist_get EnvironmentVariables.EBOOK_CONVERT)"
WP0="$(plist_get WatchPaths.0)"
WANT_CAL="$APP_SUPPORT/calibre.app/Contents/MacOS"
# Канонизируем оба (installer.sh пишет через `cd && pwd` → возможен /private-префикс).
canon() { [[ -e "$1" ]] && (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
if [[ "$(canon "$CAL_DIR")" == "$(canon "$WANT_CAL")" ]]; then
  ok "plist CALIBRE_MACOS_DIR = app-owned ($CAL_DIR)"
else
  die_fail "plist CALIBRE_MACOS_DIR НЕ app-owned: got='$CAL_DIR' want='$WANT_CAL'"
fi
case "$CAL_DIR" in
  /Applications/*) die_fail "plist указывает на СИСТЕМНЫЙ /Applications/calibre.app (ожидался app-owned)" ;;
  *) ok "plist НЕ указывает на /Applications (изоляция соблюдена)" ;;
esac
[[ "$EBK_CONV" == *"/calibre.app/Contents/MacOS/ebook-convert" ]] \
  && ok "plist EBOOK_CONVERT производный от app-owned движка" \
  || bad "plist EBOOK_CONVERT неожиданный: '$EBK_CONV'"
[[ "$(canon "$WP0")" == "$(canon "$WATCH")" ]] \
  && ok "plist WatchPaths[0] = throwaway watch-папка" \
  || bad "plist WatchPaths[0] неожиданный: '$WP0'"

# Активация дошла до конца: журнал шайбы должен показать bootstrap + kickstart нашей тест-метки на
# throwaway-plist (реальный launchd при этом не тронут). Так проверяем «installer.sh активировал бы
# агента» без мутации боевого домена; настоящий launchd-bootstrap закрыт CAL-4.
UID_N="$(id -u)"
if grep -qF "bootstrap gui/$UID_N $PLIST" "$LCTL_LOG" 2>/dev/null; then
  ok "installer.sh дошёл до launchctl bootstrap throwaway-plist (активация выполнена)"
else
  bad "в журнале launchctl нет bootstrap throwaway-plist (активация не дошла)"
fi
if grep -qF "kickstart -k gui/$UID_N/$LABEL" "$LCTL_LOG" 2>/dev/null; then
  ok "installer.sh дошёл до launchctl kickstart тест-метки"
else
  bad "в журнале launchctl нет kickstart тест-метки"
fi

# ===========================================================================
# ФАЗА 4. Конвертация реального .fb2 настоящим движком → валидный EPUB.
# ===========================================================================
echo ""
echo "==> Фаза 4: конвертация реального .fb2 app-owned движком"

# Минимальный, но валидный FB2 (генерим на лету — в tests/ нет статичного .fb2-фикстура; вся
# фикстурная политика репо «на лету»). Достаточно description + body с реальным текстом.
FB2_NAME="live-e2e-book.fb2"
FB2_PATH="$WATCH/$FB2_NAME"
EPUB_PATH="$WATCH/live-e2e-book.epub"
cat > "$FB2_PATH" <<'FB2'
<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
  <description>
    <title-info>
      <genre>sf</genre>
      <author><first-name>Test</first-name><last-name>Author</last-name></author>
      <book-title>Live E2E Test Book</book-title>
      <lang>en</lang>
    </title-info>
    <document-info>
      <author><nickname>fb2-to-epub-tests</nickname></author>
      <program-used>fb2-to-epub live e2e</program-used>
      <date value="2026-07-21">2026-07-21</date>
      <id>fb2-to-epub-live-e2e-0001</id>
      <version>1.0</version>
    </document-info>
  </description>
  <body>
    <title><p>Live E2E Test Book</p></title>
    <section>
      <title><p>Chapter One</p></title>
      <p>Hello from the fb2-to-epub live end-to-end test.</p>
      <p>This paragraph exists so Calibre has real content to convert into EPUB.</p>
    </section>
  </body>
</FictionBook>
FB2

# В dry-run настоящего Calibre нет — подменяем ТОЛЬКО ebook-convert локальным стабом, который пишет
# валидный минимальный EPUB. Так плумбинг watcher→конвертер→EPUB→ассерты проверяется без 330 МБ.
# В живом прогоне EBOOK_CONVERT = настоящий app-owned бинарь.
CONV_FOR_WATCHER="$CONV"
if [[ "$DRYRUN" == "1" ]]; then
  FAKE_CONV="$WORK/fake-ebook-convert"
  cat > "$FAKE_CONV" <<'SH'
#!/bin/bash
# Стаб ebook-convert для dry-run: `--version` → строка с версией; `<src> <dst> ...` → валидный EPUB в <dst>.
if [[ "${1:-}" == "--version" ]]; then echo "ebook-convert (calibre 9.11.0)"; exit 0; fi
dst="$2"
python3 - "$dst" <<'PY'
import sys, zipfile
dst = sys.argv[1]
with zipfile.ZipFile(dst, "w") as z:
    z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    z.writestr("META-INF/container.xml",
        '<?xml version="1.0"?>\n<container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
        '<rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>'
        '</rootfiles></container>')
    z.writestr("content.opf",
        '<?xml version="1.0"?>\n<package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
        'unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>Live E2E Test Book</dc:title><dc:identifier id="id">e2e</dc:identifier>'
        '</metadata><manifest><item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/>'
        '</manifest><spine><itemref idref="c1"/></spine></package>')
    z.writestr("chap1.xhtml",
        '<?xml version="1.0"?>\n<html xmlns="http://www.w3.org/1999/xhtml"><head><title>c1</title>'
        '</head><body><p>hi</p></body></html>')
PY
SH
  chmod +x "$FAKE_CONV"
  CONV_FOR_WATCHER="$FAKE_CONV"
fi

# Запускаем УСТАНОВЛЕННЫЙ агент-скрипт (runner→watcher) НАПРЯМУЮ с ЯВНЫМ throwaway-окружением.
# Не через launchd kickstart: launchd не пиннит HOME, и фоновый прогон писал бы state/covers/log
# в РЕАЛЬНЫЙ ~/Library. Здесь всё уходит в throwaway (FB2_STATE_DIR/COVERS_DIR/LOG_FILE + HOME).
# COVER_FINDER=/nonexistent → пропускаем сетевой поиск обложки (не относится к гипотезе; детерминизм).
RUNNER="$APP_SUPPORT/bin/fb2-to-epub-runner.sh"
[[ -x "$RUNNER" ]] || die_fail "installer.sh не установил runner: $RUNNER"

# Наследуем нормальное окружение (настоящий Calibre ebook-convert может хотеть USER/TMPDIR/lang —
# как под launchd) + ПЕРЕОПРЕДЕЛЯЕМ всё, что решает изоляцию. PATH с шайбой впереди → `open` = no-op.
run_watcher() {
  env \
    PATH="$SHIM:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$HOME_DIR" \
    WATCH_DIR="$WATCH" \
    CALIBRE_MACOS_DIR="$INSTALLED_APP/Contents/MacOS" \
    EBOOK_CONVERT="$CONV_FOR_WATCHER" \
    EBOOK_META="$META" \
    EBOOK_POLISH="$POLISH" \
    PYTHON3="$(command -v python3)" \
    COVER_FINDER="/nonexistent-cover-finder" \
    FB2_STATE_DIR="$APP_SUPPORT/state" \
    FB2_COVERS_DIR="$APP_SUPPORT/covers" \
    FB2_LOG_FILE="$WORK/watcher.log" \
    "$RUNNER" >>"$RUNLOG" 2>&1 || true
}

echo "    .fb2 положен в watch, запускаю установленный агент-скрипт (runner→watcher)…"
run_watcher

# Ждём EPUB (первый запуск ebook-convert прогревается несколько секунд).
DEADLINE=$(( $(date +%s) + 120 ))
while [[ ! -s "$EPUB_PATH" && "$(date +%s)" -lt "$DEADLINE" ]]; do
  sleep 1
  # Один повторный пинок watcher'а на случай гонки/лока (идемпотентно — up-to-date выход).
  [[ -s "$EPUB_PATH" ]] || run_watcher
done

if [[ -s "$EPUB_PATH" ]]; then
  ok "EPUB создан: ${EPUB_PATH##*/} ($(wc -c < "$EPUB_PATH" | tr -d ' ') байт)"
else
  [[ -f "$WORK/watcher.log" ]] && { echo "  --- watcher.log ---"; tail -n 20 "$WORK/watcher.log"; }
  die_fail "EPUB не появился за 120с (конвертация не прошла)"
fi

# Валидность EPUB: непустой (проверено выше) · unzip -t · mimetype.
if unzip -t "$EPUB_PATH" >/dev/null 2>&1; then
  ok "unzip -t: архив EPUB целостен"
else
  die_fail "unzip -t провалился — EPUB битый"
fi
MIME="$(unzip -p "$EPUB_PATH" mimetype 2>/dev/null | tr -d '\n' || true)"
if [[ "$MIME" == "application/epub+zip" ]]; then
  ok "mimetype = application/epub+zip"
else
  die_fail "mimetype неверный: '$MIME' (ожидалось application/epub+zip)"
fi

# ===========================================================================
# Итог.
# ===========================================================================
echo ""
echo "==> $PASS passed, $FAIL failed  (режим: $MODE_LABEL)"
if [[ "$FAIL" -eq 0 ]]; then
  if [[ "$RUN_LIVE" == "1" ]]; then
    echo "==> ЖИВОЙ e2e ЗЕЛЁНЫЙ: quarantine нет · codesign/spctl ок · настоящий движок сконвертировал .fb2 → EPUB."
  else
    echo "==> СУХОЙ прогон ЗЕЛЁНЫЙ: плумбинг доказан (codesign/spctl/настоящий движок — LIVE-ONLY, пропущены)."
  fi
  exit 0
fi
exit 1
