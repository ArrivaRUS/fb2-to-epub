# Архитектор #2 (GPT-5.6 Sol) — v1.0.2: ProgramArguments[0] → Mach-O runner

> Движок: `codex exec -m gpt-5.6-sol -c model_reasoning_effort="xhigh" -s read-only` (Codex CLI 0.144.6)
> Дата: 2026-07-23 · tokens used: 137 151 · сырой вывод: `arch/plan-binrunner-codex.raw.txt`
> Содержимое ниже — ответ Sol без изменений (только этот заголовок добавлен оператором).

## 1) Вердикт — A: внешний immutable Mach-O + текущий LaunchAgent

Выбрать standalone `~/Library/Application Support/fb2-to-epub/bin/fb2-to-epub-runner` без `.sh`, сохранив обычный plist/`launchctl`.

Механика TCC:

- Для non-bundled binary идентификатором служит абсолютный путь, дополнительно проверяется `CodeRequirement`; для приложения — bundle ID + `CodeRequirement`. Встроенный helper наследует права enclosing app. Это документированная модель TCC/PPPC Apple: [PrivacyPreferencesPolicyControl Identity](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol/services-data.dictionary/identity).
- У ad-hoc подписи нет TeamID/signing identity. Проверка текущего `.app` показывает DR вида `cdhash H"…" or cdhash H"…"` — по одному CDHash на архитектуру universal-бинаря.
- Следовательно, A матчится не «только по пути» и не «только по cdhash», а по стабильной паре: **absolute path + CodeRequirement(cdhash)**. Замена файла байт-в-байт по тому же пути сохраняет грант; inode, mtime и xattr не существенны.
- Авто-апдейт `.app` не затрагивает эту identity, пока установленный helper остаётся байт-в-байт прежним.

Решения внутри A:

- **Артефакт:** хранить в обычном Git canonical, уже собранный и ad-hoc-подписанный Mach-O, плюс исходник, pinned-рецепт, SHA-256 и ожидаемый вывод `codesign -dr -`. Воспроизводимая сборка полезна для аудита, но не должна быть источником release-файла: смена Xcode/SDK/linker может изменить CDHash.
- **Архитектуры:** universal `arm64+x86_64`, поскольку приложение сейчас universal и заявляет macOS 11+. Никогда не делать thinning/lipo/re-sign после фиксации артефакта.
- **Запуск watcher:** helper запускает `/bin/bash watcher.sh` дочерним процессом и ждёт его, сохраняя себя responsible process; не заменяет себя через `exec`.
- **Quarantine:** снимать только `com.apple.quarantine` с установленного helper после проверки подписи и SHA. Это предотвращает безоконный Gatekeeper-блок из launchd и не меняет CDHash. Не применять рекурсивный `xattr -cr` к App Support.
- **Build signing:** перейти с рекурсивного пере-подписания helper к inside-out signing; проверять SHA helper до и после подписи `.app`.

Оценка альтернатив:

- **B — отклонить.** Да, embedded helper получает FDA приложения без второго UX. Но у текущего ad-hoc bundle DR закреплён на CDHash; изменение executable, `Info.plist` или ресурсов и новая подпись дают другой CDHash. Старое правило TCC может остаться в базе/UI, но новый `.app` ему не соответствует — функционально грант мёртв. Стабильного bundle ID недостаточно. Apple прямо предупреждает, что ad-hoc code не позволяет распознать N+1 как то же приложение: [On File System Permissions](https://developer.apple.com/forums/thread/678819), [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/). `identifier`-only custom DR небезопасен: его сможет воспроизвести любой ad-hoc binary.
- **C — отклонить для v1.0.2.** `SMAppService`/`BundleProgram` решает регистрацию и bundle-relative путь, но не создаёт стабильную signing identity. Helper всё равно должен быть Mach-O, а FDA всё равно наследует обновляемый ad-hoc bundle и ломается по CDHash. Дополнительно: API только macOS 13+, появляется отдельное одобрение Background Items, а динамические `WatchPaths`/пути Calibre нельзя записывать в подписанный bundled plist без переделки агента на внешнюю конфигурацию. Это крупный рефакторинг без решения исходной проблемы. См. [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) и [BundleProgram migration](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos).

## 2) Компоненты

| Компонент | Ответственность / зависимости | Как тестировать |
|---|---|---|
| Native runner | Минимальный POSIX Mach-O; находит соседний watcher, порождает `/bin/bash`, ждёт, передаёт сигналы/exit code. Зависимости: libc, `/bin/bash` | Fake watcher: env, cwd, exit code, сигналы; `file`, `lipo`, `codesign`; Tahoe tccd-log показывает runner responsible |
| Golden artifact pipeline | Source + canonical universal binary + SHA/DR fixture; штатная сборка только копирует, не компилирует и не подписывает его заново | SHA до/после сборки `.app` и DMG одинаков; две сборки приложения содержат идентичный helper |
| `installer.sh` | Проверить артефакт, атомарно установить в новый путь, точечно снять quarantine, заменить `ProgramArguments[0]`, перезагрузить тот же label | Изолированный HOME; fresh/legacy/idempotent/corrupt-helper сценарии; сохранение `WATCH_DIR` и env |
| Build/update refresh | Положить golden payload в bundle без мутации; добавить native runner в перечень engine payload; legacy `.sh` считать обязательной миграцией | После замены `.app` новый helper обнаруживается как missing; повторный апдейт не меняет установленный SHA |
| `EngineClient` + FDA UI | Новый fallback-path; clipboard по-прежнему читает plist; карточка показывает `fb2-to-epub-runner`, не `.sh` | FDAContract: plist/fallback; UI-состояния denied/checking/recovered |
| README RU/EN | Исправить путь, схему responsible process и ложное утверждение, что один bundle ID сохраняет ad-hoc TCC | Поиск старого `runner.sh`; ручная сверка инструкции на чистом Tahoe |

## 3) Milestones по зависимостям

1. **M0 — TCC spike:** native prototype → реальный запуск на Tahoe 26.5.2 → доказать subject/responsible chain и сценарий child-not-exec.
2. **M1 — Freeze artifact:** universal build → ad-hoc sign один раз → зафиксировать binary/SHA/DR/source.
3. **M2 — Packaging и миграция:** build не мутирует artifact → installer ставит новый путь → plist переключается → update-refresh распознаёт legacy.
4. **M3 — UI, тесты, README:** новый fallback/текст/имя; обновить FDA, updater и live-E2E тесты.
5. **M4 — Release gate:** upgrade v1.0.1→v1.0.2 и v1.0.2→изменённый тестовый N+1 на чистой VM; Apple Silicon и Intel.

## 4) Миграция

- На запуске v1.0.2 явно распознать `ProgramArguments[0]` с `fb2-to-epub-runner.sh`; не ждать случайного изменения watcher.
- Считать существующий `WATCH_DIR`, установить и проверить Mach-O, затем `bootout` старого job, атомарно записать plist с новым `ProgramArguments[0]`, `bootstrap/enable/kickstart`.
- Миграция должна завершиться до показа FDA CTA, иначе clipboard кратковременно скопирует старый `.sh`.
- Старый `.sh` оставить неиспользуемым на один релиз для rollback; позже удалить. Старую запись FDA приложение удалить не может — после успешного нового гранта README предлагает удалить строку `.sh` вручную.
- Перенести старый грант невозможно: фактическим subject был `/bin/bash`. Для существующих установок неизбежен один новый FDA grant к Mach-O.

## 5) Тест «апдейт приложения → грант жив»

1. Чистая Tahoe 26.5.2 VM; убедиться, что FDA нет у приложения, Terminal и `/bin/bash`.
2. Установить N, зафиксировать path, SHA, DR и CDHash helper; выдать FDA только ему.
3. Доказать реальным чтением/конвертацией из Desktop и tccd-логом, что subject/responsible — native runner.
4. Установить N+1 штатным авто-апдейтом: `.app` и его CDHash обязаны измениться, watcher можно изменить, helper — нет.
5. Не трогая FDA, подтвердить прежние path/SHA/DR helper и успешную новую конвертацию.
6. Negative control: заменить helper пересобранным вариантом с другим CDHash — доступ обязан пропасть до нового гранта. Состояние переключателя само по себе не является доказательством; критерий — фактический доступ.

## 6) Риски

- **TCC остаётся implementation-sensitive:** возможность добавлять CLI в FDA уже регрессировала в macOS 26.2; обязательный реальный gate на поддерживаемых версиях.
- **Golden helper почти неизменяем:** любой баг/уязвимость в нём означает новый CDHash и повторный FDA UX. Поэтому код должен быть предельно мал и не парсить пользовательские данные.
- **Mutable watcher получает FDA через responsible runner:** проверять fixed path, regular file, owner/mode, запретить symlink. Полная защита от same-user tampering потребует подписи manifest/payload проектным ключом с публичным ключом внутри immutable helper.
- **Build может незаметно пере-подписать/thin helper:** SHA-check после `.app` signing и после извлечения из DMG должен быть release-blocking.
- **Миграционная гонка:** сначала валидный helper, затем переключение plist; при неуспешном bootstrap сохранять диагностируемое состояние и повторять миграцию, не менять `WATCH_DIR`.
- **B/C:** остаются допустимыми только после появления стабильного сертификатного anchor/TeamID; при текущем ad-hoc ограничении они не выполняют требование update-survival.
