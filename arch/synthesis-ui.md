# Синтез архитектуры — нативный UI fb2-to-epub (суд Юрки)

> Два архитектора: `plan-claude-ui.md` (Claude) + `plan-codex.md` (Codex/gpt-5.5, xhigh).
> Оба **независимо** рекомендовали нативный SwiftUI и отвергли webview. Ниже — сведённый план + где я выбрал между ними. Дата: 2026-06-25.

## Подтверждено фактом (Юрка, перед фиксацией)
Полный Xcode (`/Applications/Xcode.app`), Swift 6.3, macOS SDK 26.4, SwiftUI.framework на месте. **Тест-компиляция** `import SwiftUI/AppKit` → собралась+слинковалась+запустилась (`swiftui-toolchain-OK`). arm64 + `lipo` есть → universal-сборка возможна. **Стек реализуем на этой машине.**

## Главное решение: нативный SwiftUI (не webview)
Оба архитектора: «HTML-макет — это готовая картинка, не поведение». В webview каждое действие всё равно идёт через JS↔Swift-мост (это и есть основной объём работы) + теряется нативность + сложнее TCC/файлы + больше бандл. В нативе ту же логику пишешь прямо. «Нативность» — главный критерий человека. **Запасной вариант (WKWebView+HTML+мост) описан в обоих планах — на случай, если человек захочет минимизировать Swift-код.**

## Принцип: движок не трогаем, UI — читатель состояния и «заказчик» работ
Логика конвертации (watcher/Calibre/launchd/cover-finder) остаётся. Приложение НЕ переписывает EPUB на Desktop само (TCC) — все операции с файлами в защищённых зонах делает **стабильный FDA-runner через агент**.

## Компоненты приложения (SwiftUI)
`AppState` · `StatusScreen` · `SetupScreen` · `CoverSelectScreen` · `EngineClient` (launchctl/installer/Calibre) · `StateStore` (state.json) · `CoverQueueStore` · `FolderWatch` (DispatchSource на App Support).

## Стыковка UI ↔ движок
- **Статус агента:** `launchctl print gui/$UID/com.arrivarus.fb2toepub.agent` + `print-disabled`. **Нюанс (Codex):** агент событийный — в норме `loaded`, но НЕ `running`; `running/pid` ≠ «жив». «Активно» = print вернул 0 + plist на месте + не disabled.
- **Статус/конвертации/счётчики:** НЕ парсим human-log. **Watcher пишет структурно** в `~/Library/Application Support/fb2-to-epub/state/`: `state.json` (атомарный snapshot для UI: totals converted_total/today/failed_today, recent[≤50], last_conversion) + `events.jsonl` (append-only). `~/Library/Logs/fb2-to-epub.log` остаётся для диагностики. UI читает + `DispatchSource`-watch.
- **Папка/первый запуск:** UI зовёт `bash "$APP/Contents/Resources/installer.sh" "<dir>"` (без shell-склейки). **Миграция (Codex):** если plist уже есть — читать существующий `WATCH_DIR`, НЕ перетирать папку пользователя. Нет plist → `~/Desktop/fb2-to-epub`. По умолчанию отслеживание включено (D10).

## Очередь обложек (где я выбрал между архитекторами)
- **cover-finder → режим `--json`:** топ-N кандидатов, качает превью в App Support, score, печатает JSON (candidates[]: id/rank/source/url/preview_path/score, best_candidate_id). Ветка: встроенная→нет очереди; 0→без обложки; 1→`--cover`; **2+→лучший сразу + очередь**.
- **СУД 1 — очередь пишет WATCHER, не cover-finder** (Codex). Причина: watcher знает итоговый `epub_path`, держит lock, работает под FDA-runner. У Claude cover-finder был причастен — версия Codex чище.
- **СУД 2 — переобработка `ebook-polish --cover`, НЕ `ebook-meta --cover`** (Codex, оба склонялись). polish реально вставляет/заменяет обложку В epub; meta правит только метаданные.
- **СУД 3 — обложку применяет АГЕНТ/runner, не приложение** (Codex, разрешает R1 Claude). UI пишет apply-job атомарно (`.tmp`→rename) в `covers/jobs/`; **`covers/jobs` добавляем в `WatchPaths`** агента (+`kickstart` как страховка) → агент под своим FDA применяет polish через tmp+`mv -f`. Приложение Desktop-EPUB не трогает.
- Структура: `covers/queue/<book_id>.json` (status pending/apply_requested/resolved/skipped/failed), `covers/previews/<book_id>/<cand>.jpg`, `covers/jobs/<job_id>.json`.
- plist: добавить `EBOOK_META`/`EBOOK_POLISH`; installer проверяет все три бинаря Calibre.

## Сборка / подпись / упаковка
- `build/build-app.sh`: заменить блок `osacompile` на native-сборку — `xcrun swiftc` arm64 + x86_64 → `lipo -create` → `Contents/MacOS/fb2-to-epub`. Дальше как есть: скрипты в Resources, AppIcon.icns, Info.plist (стабильный `CFBundleIdentifier=com.arrivarus.fb2toepub`, CFBundleExecutable, удалить CFBundleIconName).
- **Гонка codesign (FinderInfo) сохраняется** для native-бандла (она на корне директории) → ретрай-цикл codesign **обязателен без изменений** (см. `.patches/003` + делегированная задача-чип).
- **dmgbuild переиспользуется как есть** (пакует любой .app; окно 920×440 и иконки не зависят от типа бинаря).
- App **unsandboxed** (sandbox ломает launchctl/shell/Desktop/Calibre). Без внешних Swift-зависимостей (только SwiftUI/AppKit/Foundation), offline.

## Майлстоуны (validation-first, по зависимостям)
- **M0** — спайк: пустое тёмное окно SwiftUI собирается `swiftc`→`lipo`, ad-hoc codesign проходит (ретрай), запускается.
- **M1** — первый запуск ставит агент через installer; **миграция: существующий WATCH_DIR не перетирается**.
- **M2** — watcher пишет `state.json`/`events.jsonl`; экран **Статус** на реальном state (статусное кольцо, счётчики, агент/папка, последние конвертации).
- **M3** — экран **Установка** (отслеживание по умолчанию, без старта).
- **M4** — бэкенд очереди: `cover-finder --json` top-N + ветка watcher «2+→best+очередь».
- **M5** — экран **Выбор обложки** + применение: apply-job → агент `ebook-polish --cover` (covers/jobs в WatchPaths); **живой FDA-тест**; проверка `ebook-meta --get-cover`.
- **M6** — сборка/подпись/**DMG** (старый layout 920×440).
- **M7** — пиксель-перфект (design-spec G3) + регрессия (desktop, 0 ошибок).

## Открытые развилки для человека (минорные)
1. **Мин. macOS:** держим **11.0** с `if #available`-фолбэками (без регресса совместимости) — рекомендую; либо поднять до 12.0 ради чистого SwiftUI.
2. **Узнавание о новых обложках:** v1 — только **бейдж-счётчик в окне** («Выбрать обложку · 3») + опц. бейдж на Dock-иконке; системные уведомления — НЕ в v1 (человек выбрал «без поп-апов»). Подтвердить.

## Риски
- **R-FDA:** применение polish агентом — та же зона граблей, что с TCC ранее → живой тест на M5.
- **R-pixel:** градиентная рамка выбранного/корешок-блик → дизайн-спец (G3) обязательна до пиксель-перфекта (M7).
- **R-macOS11:** API только-12+ без fallback → `if #available`; запасной ход — флор 12.
