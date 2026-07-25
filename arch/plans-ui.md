# plans-ui — нативный UI fb2-to-epub (источник правды разработки)

> Основа: `arch/synthesis-ui.md` (суд двух архитекторов), принят человеком 2026-06-25.
> Разработка микрошагами, validation-first. Живой лог — `arch/status-ui.md`. Гейты — здесь, в каждом M.
> Код-репо: `/Users/arrivarus/Documents/VibeCoding2/2026.06 fb2-to-epub`.

## Инварианты (нарушать нельзя)
- Движок (watcher/Calibre/launchd/cover-finder) — логика не меняется, только расширяется (state.json, cover top-N, очередь, polish).
- `runner.sh` — НЕ трогать (TCC-грант привязан к байтам файла).
- Приложение **unsandboxed**, без внешних Swift-зависимостей (SwiftUI/AppKit/Foundation), offline-сборка.
- Стабильный `CFBundleIdentifier=com.arrivarus.fb2toepub`.
- codesign — ретрай-цикл против гонки FinderInfo (iCloud-папка), обязателен (см. `.patches/003`).
- Приложение НЕ пишет/не переобрабатывает EPUB на Desktop — это делает агент (FDA).
- Каждый M: скриншот/проверка; пиксель-перфект — по дизайн-спец (G3).

## Контракты данных (фиксируем до кода)
- `~/Library/Application Support/fb2-to-epub/state/state.json` — атомарный snapshot для UI: `{schema, agent:{watch_dir}, totals:{converted_total,today,failed_today}, recent:[≤50 {src,dst,ts,status}], last_conversion}`. Пишет watcher (tmp→rename).
- `…/state/events.jsonl` — append-only события (диагностика/перестроение).
- `…/covers/queue/<book_id>.json` — `{book_id, epub_path, title, author, src_file, status: pending|apply_requested|resolved|skipped|failed, candidates:[{id,rank,source,url,preview_path,score}], best_candidate_id, ts}`.
- `…/covers/previews/<book_id>/<cand>.jpg` — локальные превью.
- `…/covers/jobs/<job_id>.json` — `{book_id, chosen_candidate_id|skip, ts}` (пишет приложение, читает агент).
- Статус агента: `launchctl print gui/$UID/com.arrivarus.fb2toepub.agent` (rc=0 + plist есть + не disabled = «активно»; событийный — running≠обязательно).

## Майлстоуны

### M0 — спайк стека (developer) [СТАРТ]
- `build/build-app.sh`: ветка native — `xcrun swiftc` arm64 + x86_64 → `lipo` → `Contents/MacOS/fb2-to-epub`; Info.plist (id, CFBundleExecutable, LSMinimumSystemVersion 11.0, remove CFBundleIconName), AppIcon.icns как есть.
- Минимальное окно SwiftUI (тёмное, ~400px, заголовок) — заглушка.
- codesign-ретрай-цикл (как в текущем build-app.sh) применить к native-бандлу.
- **✅ Гейт:** `.app` собирается; `codesign --verify --deep` rc=0; приложение запускается, видно тёмное окно (Юрка — скриншот). Сборка повторяема (2–3 прогона, гонка не валит).

### M1 — установка/агент (developer)
- При старте: нет plist → `installer.sh ~/Desktop/fb2-to-epub`; **plist есть → читать существующий WATCH_DIR, не перетирать** (миграция со старого апплета). Calibre-чек (детект + подсказка).
- `EngineClient`: вызовы `installer.sh`, `launchctl print/bootout/bootstrap/kickstart`.
- **✅ Гейт:** первый запуск ставит агент (на временной папке/HOME для теста); существующая папка не перетёрта; `launchctl print` rc=0.

### Дизайн-спец (G3) — Юкка (перед M2)
- По `design/mockups/ui-native.html` + `cover-select.html` извлечь точные токены/размеры (delegate design-token-extractor) → дизайн-спец. Гейт: спец готова до верстки экранов.

### M2 — экран Статус (developer)
- watcher пишет `state.json`/`events.jsonl` (расширение watcher.sh). Экран Статус на реальном state: статусное кольцо (активно/конвертирую/пауза), счётчики (всего/сегодня/Calibre), агент (вкл/выкл), папка (сменить), вход «Выбрать обложку · N», последние конвертации (+«Очистить»).
- **✅ Гейт:** реальная конвертация → видна в окне; side-by-side с макетом (визуал-верифай).

### M3 — экран Установка (developer)
- Первый запуск: «Готово к работе», обе строки зелёные, без кнопки старта, «Открыть папку».
- **✅ Гейт:** side-by-side с макетом.

### M4 — бэкенд очереди обложек (developer)
- `cover-finder.py` режим `--json` (top-N + превью + score). `watcher.sh`: ветка «нет обложки + 2+ → лучшая сразу (`ebook-convert --cover`) + запись очереди». plist: env `EBOOK_META/EBOOK_POLISH`; installer чек 3 бинарей.
- **✅ Гейт:** на тест-книге без обложки с 2+ кандидатами создаётся queue-entry + превью; epub получает лучшую обложку.

### M5 — экран Выбор обложки + применение (developer)
- Экран на реальной очереди; выбор → apply-job (атомарно); **агент применяет `ebook-polish --cover`** (covers/jobs в WatchPaths + kickstart). 
- **✅ Гейт:** выбор в окне → обложка вшита (`ebook-meta --get-cover` подтверждает); **живой FDA-тест** (Desktop-папка).

### M6 — сборка/подпись/DMG (developer)
- Финальный `.app` (native) → dmgbuild DMG (окно 920×440 как есть) + codesign-ретрай.
- **✅ Гейт:** DMG монтируется; приложение внутри `--deep` валидно; рендер окна DMG как раньше (Юрка).

### M7 — пиксель-перфект + регрессия (design-reviewer · qa)
- Side-by-side всех экранов с макетами (≥1 несовпадение = FAIL). Регрессия: конвертация, очередь, смена папки; 0 ошибок.
- **✅ Гейт:** pixel-perfect OK; релиз-кандидат.

## Ревью/релиз
После M7: CodeReviewer ∥ Codex-проход · DesignReviewer · Tester/QA → TechWriter/Changelog → ⛔ PR/Release (новая версия).
