# Execution plan — fb2-to-epub (DMG + установщик)

> Источник истины для разработки. База: `arch/synthesis.md`. Живой статус — `status.md` / HEARTBEAT.
> Дата 2026-06-23.

## Инварианты (не нарушать)
- Логика конвертации/обложек в `watcher.sh` НЕ меняется по поведению — только параметризация пути + абсолютный python3.
- Все пути к инструментам — абсолютные (агент стартует с `PATH=/usr/bin:/bin:/usr/sbin:/sbin`).
- Идемпотентность: повторный запуск установщика / смена папки не плодят дубли и не ломают существующее.
- bundle id фиксируется ЯВНО: `com.arrivarus.fb2toepub.agent` (иначе TCC-грант слетает каждую сборку).
- Существующий CLI `install.sh`/`uninstall.sh` остаётся рабочим (advanced-путь), мигрирует на новый label.
- Дефолт папки = `~/Desktop/fb2-to-epub`; любая папка разрешена.

## M1 — ядро (MVP): собранный .dmg ставит автоматизацию на выбранную папку
Порядок по зависимостям:

### T1. Параметризация ядра
- `bin/fb2-to-epub-watcher.sh`: WATCH_DIR из env (фолбэк `~/Desktop/fb2-to-epub`); python3 — абсолютный путь/детект. Логику конвертации/обложек НЕ трогать.
- Новый шаблон LaunchAgent под label `com.arrivarus.fb2toepub.agent`: `WatchPaths`=<WATCH_DIR>, `EnvironmentVariables` (WATCH_DIR, PATH, EBOOK_CONVERT, PYTHON3), RunAtLoad, ThrottleInterval=5, StandardOut/Error → лог.
- **Done:** отрендеренный plist + watcher с подменённым WATCH_DIR конвертит .fb2 в произвольной папке.

### T2. packaging/installer.sh (вся bash-логика установки)
- Детект Calibre (`/Applications/calibre.app/Contents/MacOS/ebook-convert`) и python3; нет → понятный текст что установить.
- Принять WATCH_DIR; создать папку, если нет.
- Скопировать watcher + cover-finder в `~/Library/Application Support/fb2-to-epub/bin`.
- Сгенерировать plist **через `plutil`** (структурно вставить WatchPaths/Env с реальными путями) → `~/Library/LaunchAgents/com.arrivarus.fb2toepub.agent.plist`.
- (Пере)загрузка: `launchctl bootout gui/$UID/<label> 2>/dev/null; bootstrap gui/$UID <plist>; enable; kickstart -k`.
- Идемпотентность: повторный запуск перезаписывает конфиг и перезагружает агент без дублей.
- TCC: если WATCH_DIR под `~/Desktop|~/Documents|~/Downloads` → вывести инструкцию Full Disk Access для runner-цели (T3).
- **Done:** `bash installer.sh "<любая папка>"` ставит рабочий агент; drop .fb2 → .epub.

### T3. Runner-цель для FDA (нужно из-за Desktop-дефолта)
- `ProgramArguments` launchd должны указывать на стабильную «ответственную» цель, которой можно выдать Full Disk Access (не голый `/bin/bash`). Минимальный рабочий вариант (runner-скрипт/бандл с фикс. путём в App Support) — выбрать и проверить, что выдача FDA этой цели открывает доступ к Desktop.
- **Done (гейт):** на этой машине агент читает `~/Desktop/fb2-to-epub` (уже да); задокументировать, какой именно цели выдавать FDA на чистом Mac.

### T4. packaging/applet.applescript (UI-дирижёр)
- Диалоги: (1) проверка Calibre/python3 (нет → предложить открыть страницу установки), (2) `choose folder` с дефолтом `~/Desktop/fb2-to-epub` (создать, если нет), (3) вызов bundled `installer.sh` с выбранным путём через `do shell script`, (4) экран успеха с короткой инструкцией (куда кидать файлы), (5) аккуратные ошибки.
- **Done:** запуск .app проводит весь путь и ставит агент.

### T5. build/build-app.sh
- `osacompile` applet → `fb2-to-epub.app`; скопировать installer.sh + watcher + cover-finder в `Contents/Resources`; **явно прописать CFBundleIdentifier** (`com.arrivarus.fb2toepub`) + версию в Info.plist; AppIcon.icns из `branding/icon-concept-1.svg` (svg→png набор размеров→`iconutil`); ad-hoc `codesign -s -`.
- **Done:** двойной клик по .app (после Open Anyway) работает; `codesign --verify` ок.

### T6. build/make-dmg.sh
- `create-dmg` (npm): .app + симлинк `/Applications` + фон `branding/dmg-background.png` + иконка тома; имя `fb2-to-epub-<version>.dmg` + sha256. Если фон ещё не готов — плейсхолдер, чтобы скрипт был тестируем.
- **Done:** смонтированный .dmg показывает .app, /Applications, фон-инструкцию.

## M2 — надёжность (после M1)
Повторный запуск (читать текущий конфиг), смена папки, uninstall/repair из .app, best-effort миграция старого `com.user.fb2-to-epub`.

## M3 — TCC protected (полировка)
Гладкий guided-FDA flow (если живой тест на чистом профиле покажет необходимость), self-check «доступ есть/нет» + Re-check.

## Отложено
Нотаризация ($99, хук в make-dmg), menu-bar app, bundled Calibre, Homebrew cask.

## Артефакты сборки
`*.app`, `*.dmg`, `build/dist/` — в `.gitignore` (не коммитим бинарники; .dmg уходит в GitHub Release).
