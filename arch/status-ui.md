# status-ui — живой лог разработки нативного UI

> План — `plans-ui.md`. Дизайн-спец — `design/spec-ui.md`. Дата старта: 2026-06-25.

## Майлстоуны
| M | Что | Статус |
|---|---|---|
| M0 | Спайк стека (swiftc→lipo→bundle, тёмное окно, codesign-ретрай) | ✅ ГОТОВО (скриншот принят) |
| M1 | Установка/агент (EngineClient, миграция WATCH_DIR, Calibre-чек) | ✅ ГОТОВО (скриншот: реальный агент активен/папка/Calibre/миграция) |
| G3 | Дизайн-спец по макетам | ✅ ГОТОВО (`design/spec-ui.md`) |
| M2 | Экран Статус на реальном state.json | ✅ ГОТОВО (скриншот сверен с макетом; кредит-подвал live) |
| M3 | Экран Установка | ✅ ГОТОВО (скриншот сверен с макетом SCREEN 2; кредит-подвал live, без старт-кнопки) |
| M4 | Бэкенд очереди обложек (cover-finder --json, watcher-ветка) | ✅ ГОТОВО (независимо проверено Юркой: 4 кандидата+превью; коммит `a4e4df7`) |
| M5 | Экран Выбор обложки + применение (агент, ebook-polish) | ✅ ГОТОВО — живой FDA-тест на реальной машине пройден end-to-end (конвертация→очередь→выбор не-лучшего→агент вшил байт-в-байт→resolved). Миграция: старый `com.user` снесён. |
| M6 | Сборка/подпись/DMG | ✅ ГОТОВО — DMG 0.2.0 (sha `4ab43069`), app внутри `--deep` ok, окно 920×440 |
| — | **Релиз v0.2.0 опубликован** | ✅ release `v0.2.0` (target native-ui) + DMG; PR #2 native-ui→main (на ревью). main=v0.1.0. |
| M7 | Пиксель-перфект + регрессия | ⬜ (по фидбеку человека после прогона) |

## Файлы приложения (app/, native SwiftUI)
`main.swift` · `EngineClient.swift` · `EngineClient+Status.swift` · `StateModel.swift` · `Tokens.swift` · `StatusView.swift` · `SetupView.swift`. Сборка — `build/build-app.sh` (SWIFT_SRCS = 7 файлов; swiftc arm64+x86_64 → lipo → universal; codesign-ретрай 003). Движок: `bin/fb2-to-epub-watcher.sh` расширен (пишет `~/Library/Application Support/fb2-to-epub/state/state.json` атомарно + `events.jsonl`).

## Лог
### 2026-06-25
- Архитектура принята (D12 SwiftUI, D13 движок-не-трогаем). Execution-pack создан.
- **M0 ✅** native-окно собирается/подписывается/запускается (universal, codesign rc=0, повторяемо).
- **M1 ✅** EngineClient (launchctl/installer/Calibre + first-run/миграция), 23/23 теста, изоляция бит-в-бит; окно показывает реальный статус агента.
- **G3 ✅** дизайн-спец `design/spec-ui.md`. **Кредит-подвал** добавлен в макеты+спец (по просьбе человека: «fb2-to-epub <вер> · by Alex Kovalev · GitHub», GitHub голубой #5B9DF9 + ссылка).
- **⚠ Инцидент:** в ходе M2 macOS TCC отозвал доступ на запись во ВСЁ `~/Documents/VibeCoding2` (EPERM, /tmp писался; не дефект кода). Человек вернул доступ (Files&Folders/FDA) → продолжили. M2 перезапущен; ничего не потеряно (watcher.sh успел сохраниться до блокировки).
- **M2 ✅** экран Статус (SwiftUI) на реальном state.json + live статус агента/Calibre; кредит-подвал с голубым кликабельным GitHub; сборка 0.2.0 codesign PASS. Скриншот сверен с макетом — совпадает.
- **M4 🟢** бэкенд очереди обложек (движок, ветка `native-ui`). **cover-finder.py:** новый режим `--json --book-id <id> --previews-dir <dir> <src>` — топ-N (≤4) кандидатов, качает превью в `<previews-dir>/<book_id>/<rank>.jpg`, детерминированный `score` (0.5 разрешение + 0.35 близость к аспекту 1.5 + 0.15 бонус каталога OpenLibrary), печатает в stdout JSON `{book_id,title,author,candidates:[{id,rank,source,url,preview_path,score}],best_candidate_id}` (отсортирован по score, best=макс). Легаси-вызов `<src> <dst>` сохранён бит-в-бит (источники OpenLibrary+DDG, фильтр аспект 1.0–2.5 / ширина ≥200). **watcher.sh:** в `convert_book` ветка по числу кандидатов — embedded(rc3)→ничего · 0→без обложки · 1→`--cover` превью · **2+→лучшую сразу `--cover` (не блокируя) + после успешной конвертации `covers/queue/<book_id>.json`** (status `pending`, candidates, best_candidate_id, ts ISO-Z); `book_id` = sha256 итогового epub-пути (16 hex); идемпотентность/lock не тронуты; queue/JSON-парсинг делегирован python3 (как state.json); создаёт `covers/{queue,previews,jobs}`. **plist-шаблон + installer:** env `EBOOK_META`/`EBOOK_POLISH` (рядом с `EBOOK_CONVERT`, выводятся из его папки); installer детектит и валидирует все 3 бинаря Calibre ДО касания launchctl (внятная подсказка при нехватке). **Тест (строгая изоляция, mktemp -d):** FB2 «Война и мир»/«Лев Толстой» без обложки → `cover-finder --json` 4 кандидата + 4 реальных превью на диске; watcher (вызван напрямую на temp с `WATCH_DIR`/`FB2_STATE_DIR`/`FB2_COVERS_DIR`/`FB2_LOG_FILE`, НЕ через launchd) создал `queue/<id>.json` + вшил лучшую (score 0.94) — `ebook-meta --get-cover` подтвердил, вшитая обложка байт-в-байт = превью best (452226=452226). Легаси-вызов rc0, bad-args rc2, 2-й прогон «skip up-to-date». **Изоляция подтверждена:** реальный `com.arrivarus.fb2toepub.agent` (state=active) и его plist (mtime вчера) не тронуты, runner.sh не трогал, launchd не запускал; temp прибран. Валидация: py_compile + bash -n ×2 + shellcheck (0 warning) + plutil -lint — всё зелёное. Ждёт приёмки гейта M4 Юркой.
- **M3 🟢** экран Установка `app/SetupView.swift` по макету SCREEN 2: хедер · welcome «Готово к работе»+подзаголовок · wizard-карточка с ДВУМЯ зелёными галками (ДВИЖОК: «Calibre <вер> найден»/«Готов к конвертации» + ОТСЛЕЖИВАЕМАЯ ПАПКА: моно-путь + «Сменить…») · footnote (Full Disk Access) · футер «● Отслеживание активно»+«Открыть папку» **без** старт-кнопки (D10) · кредит-подвал переиспользован. Роутинг в `main.swift`: first-run → Setup (persisted-флаг `didShowSetup` в UserDefaults; триггер — свежий install ИЛИ нет конвертаций), иначе Status. Реальные данные (Calibre-версия, watch-dir) из EngineClient. Setup-токены добавлены в `Tokens.swift`. build-app.sh: SWIFT_SRCS 6→7. Сборка 0.2.0 codesign PASS (ретрай 2/5). **Демо-форс:** `FB2_FORCE_SETUP=1` env (не флипает флаг). Изоляция: реальные агенты/runner.sh не тронуты, мутации — заглушки. Ждёт скриншота Юрки (G3 side-by-side).

### 2026-06-26 (пострелизные правки по фидбеку)
- **Багфикс «Очистить»** (человек: кнопка не работает). Корень: inert-заглушка с M2 (пустое `onClearHistory` + пустой `clearHistory()`). Фикс: app-owned маркер `state/recent-cleared-at` + фильтр в `loadState()` (D13: `state.json`/watcher не трогаем). debugger→developer→tester. Регресс **20/20** (`tests/ClearHistoryTests`, throwaway+temp HOME, реальный `state.json` байт-в-байт цел). Коммит `f52936e` (native-ui). Урок: `.patches/004` (Spotlight-дубль), `.patches/005` (неживые кнопки).
- **⚠ Системное (патч 005):** в релиз попали ещё видимые неживые кнопки — **«Сменить» (папка)** и **шестерёнка** (Статус+Установка): `onChangeFolder: {}`, `onSettings: {}` в `main.swift`; `changeWatchFolder`/`setAgentEnabled` — заглушки. Ждёт решения человека: реализовать vs скрыть/задизейблить.

- **v0.2.1 ОПУБЛИКОВАН 2026-06-26 (Release target `main`, sha `828bc04a`, сверен; PR #2 смёржен → `main`=нативная версия, скриншоты на главной HTTP 200):** оживлены ВСЕ кнопки. «Сменить папку» (Статус+Установка): `NSOpenPanel`→`changeWatchFolder` (re-point агента через installer)→`present(.status)`, ошибки→`NSAlert`. Меню настроек ⚙ (нативное NSMenu у курсора): Сменить папку / **Сбросить статистику** / Открыть лог / Full Disk Access / О программе+GitHub. «Сбросить статистику» — baseline-маркер `state/stats-baseline`, `loadState()` вычитает `max(0,current−base)`, `today` НЕ baseline-ится; `state.json` watcher'а не трогаем (D13).
- **Статистика — разбор (debugger):** завышенный `converted_total=1235` при 0 .epub — НЕ баг кода (счётчик растёт строго на `ok`, скипы не считаются; форензика: events.jsonl=1, ≤70 ok за всю историю, 54 уникальных) → наследие снесённого агента `com.user` (период двух агентов писали в один state.json). Watcher НЕ меняли; сброс обнуляет отображение app-стороной.
- **Тесты/сборка v0.2.1:** весь набор **19 кейсов / 51 проверка — зелёный** (Очистить + reset A1–A9 + change-folder B1–B3). DMG `fb2-to-epub-0.2.1.dmg` собран (sha `828bc04a`). README (RU+EN): честный скриншот Статуса (54 вместо 1235; временная подмена state.json с trap-восстановлением — реальные данные целы) + описан просмотр/выбор обложек в приложении. Коммиты `f52936e`, `6401e81` (native-ui). Wiring всех кнопок + логика проверены; живой клик на боевом агенте не гоняли (changeWatchFolder меняет реальный агент) — за человеком. Опубликовано + смёржено в main. Осталось (по фидбеку): M7 пиксель-перфект; человек ставит v0.2.1 и жмёт «Сбросить статистику» для обнуления старого счётчика.

## Открытые вопросы/риски
- R-FDA: применение обложки агентом — живой тест на M5.
- R-pixel: пиксель-перфект — M7 (side-by-side всех экранов).
- Гонка codesign (FinderInfo) — ретрай-цикл в build-app.sh гасит.
- Git: M0–M3 закоммичены в ветку **`native-ui`** (`4691e55`, локально, без push) по «да» человека. `main` = v0.1.0 (апплет). M4+ коммитить туда же по ходу.
- Миграция рантайма: возможен старый `com.user.fb2-to-epub` + новый агент на одной папке — учесть при релизе.
