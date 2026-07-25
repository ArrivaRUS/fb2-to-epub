# Синтез архитектуры — fb2-to-epub (суд Юрки)

> Дата 2026-06-23. Вход: `plan-claude.md` (Архитектор #1, Opus), `plan-codex.md` (Архитектор #2, gpt-5.5/xhigh). Рубрика — `handoff/references/patterns.md` §1.

## Суд (1–5)
| Критерий | #1 Claude | #2 Codex |
|---|---|---|
| Корректность | 5 | 5 |
| Простота | 5 | 4 |
| Соответствие ограничениям | 5 | 5 |
| Риск | 5 | 5 |
| Тестируемость | 5 | 5 |

Планы **сошлись в корне** (один костяк) — коренной развилки нет; человеку на G4 выносится только TCC-дефолт + go-ahead. Каждый добавил ценное:
- **Codex:** `plutil` вместо `sed` для генерации plist (надёжно к пробелам/спецсимволам в произвольном WATCH_DIR); перенос в `~/Library/Application Support/fb2-to-epub`; стабильный bundle id.
- **Claude:** явная установка `CFBundleIdentifier` (osacompile его НЕ ставит → иначе TCC-грант слетает каждую сборку); чистая матрица компонент/тест; уклон к `create-dmg`.

## Единая архитектура (v1)
- **Приложение:** unsigned AppleScript `.app` (osacompile, без Xcode) — тонкий «дирижёр»: диалоги + вызов bundled bash.
- **Логика:** `installer.sh` (в `Contents/Resources/`) — детект Calibre/python3 → выбор папки → генерация LaunchAgent plist через **plutil** под выбранный WATCH_DIR → `launchctl bootout`/`bootstrap gui/$UID`/`kickstart`. Идемпотентно.
- **Расположение:** скрипты+иконка в `~/Library/Application Support/fb2-to-epub/`; LaunchAgent — `~/Library/LaunchAgents/com.arrivarus.fb2toepub.agent.plist`.
- **Watcher:** существующий, 2 микроправки — WATCH_DIR из env, абсолютный python3. Логика конвертации без изменений.
- **Окружение агента:** PATH + абсолютные пути к `ebook-convert`/`python3` в `EnvironmentVariables` plist (агент стартует с голым PATH).
- **TCC (по решению человека):** дефолтная папка — `~/Desktop/fb2-to-epub` (как сейчас); любая папка разрешена. Desktop — защищённая зона, НО проверено вживую: на машине человека агент уже читает её успешно. Для чистого Mac installer ведёт через Full Disk Access (стабильная runner-цель как FDA-target) — теперь **в M1**, не M3. Гейт: живой тест на чистом профиле.
- **DMG:** `create-dmg` (npm, node v24 есть) — .app + симлинк /Applications + фон-картинка с инструкцией первого запуска + иконка тома. Фолбэк — `hdiutil`.
- **Подпись:** ad-hoc `codesign -s -` (косметика локально); нотаризация ($99) — хук в build-dmg, отложена.
- **Первый запуск (D2):** инструкция в DMG-фоне + README: System Settings → Privacy & Security → Open Anyway (1 раз).
- **CLI `install.sh`/`uninstall.sh`:** остаются как advanced-путь; мигрируют на тот же label + bootstrap/bootout; зовут тот же `installer.sh`.

## Решения Юрки (синтез → в decisions/log.md)
- **D4:** DMG = `create-dmg` (надёжная раскладка vs ручной hdiutil+AppleScript).
- **D5:** plist через `plutil` (не `sed`) — произвольный путь с пробелами/спецсимволами.
- **D6:** расположение — `~/Library/Application Support/fb2-to-epub` (идиоматично для GUI-аппа).
- **D7:** bundle id `com.arrivarus.fb2toepub.agent` (стабильный — важно для TCC-грантов).
- **D8 (решено человеком):** дефолт папки = `~/Desktop/fb2-to-epub`, любая папка разрешена; FDA-flow для защищённых зон переносится в M1.

## Milestones (по зависимостям)
- **M1 (ядро, MVP):** параметризация watcher + plist → `installer.sh` → applet → `build-app.sh` (фикс bundle id, .icns Концепт 1) → `build-dmg.sh`. **Done:** собранный .dmg ставит агент на выбранную папку, .fb2 в ней → .epub.
- **M2 (надёжность):** повторный запуск/смена папки/uninstall/repair; миграция старого `com.user.fb2-to-epub`. **Done:** смена папки и переустановка идемпотентны.
- **M3 (TCC protected):** flow для Desktop/Documents/Downloads (FDA-target). **Done:** после выдачи FDA конвертация в защищённой папке идёт.
- **Отложено:** нотаризация, menu-bar app, bundled Calibre, Homebrew cask.

## Тест-гейты
- **Живой тест TCC** (оба пометили med; dev-среда macOS 26.5.1, Gatekeeper ужесточён): реально проверить доступ launchd-агента к выбранной папке. Критичный гейт перед релизом.
- `create-dmg` раскладка/иконка — QA на машине сборки.
- Регресс watcher: .fb2 / .fb2.zip / папка → .epub, идемпотентность.
