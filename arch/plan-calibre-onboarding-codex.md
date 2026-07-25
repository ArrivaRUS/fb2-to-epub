# Архитектура «Онбординг Calibre» — план Архитектора #2 (Codex / GPT-5.6 Sol)

> Движок: **gpt-5.6-sol**, reasoning effort **xhigh**, sandbox **read-only**.
> Дата: 2026-07-19. Ретраев: **0** (ответ получен с первого вызова на xhigh).
> Токенов использовано: ~186 579. CLI: codex 0.144.6.
> Вызов по канону `.claude/skills/codex-bridge/SKILL.md` (Рецепт 1, Архитектор #2).
> Сырой полный лог сессии Codex сохранён рядом: `plan-calibre-onboarding-codex.raw.txt`.

---

Главная архитектурная развилка: один общий `CalibreLocator`, отдельный транзакционный `CalibreInstaller`, отдельная UI state-machine и сериализованный `AgentCoordinator`. `state.json` не меняется и остаётся собственностью watcher по D13.

Сейчас путь `/Applications` зашит в [EngineClient.swift](</Users/arrivarus/Documents/VibeCoding2/2026.06 fb2-to-epub/app/EngineClient.swift:78>), [installer.sh](</Users/arrivarus/Documents/VibeCoding2/2026.06 fb2-to-epub/packaging/installer.sh:65>), [watcher](</Users/arrivarus/Documents/VibeCoding2/2026.06 fb2-to-epub/bin/fb2-to-epub-watcher.sh:22>) и [cover-finder](</Users/arrivarus/Documents/VibeCoding2/2026.06 fb2-to-epub/bin/fb2-to-epub-cover-finder.py:64>). Последний не использует `EBOOK_META`, уже переданный launchd-агентом. Простого изменения `EngineClient` поэтому недостаточно.

## Компоненты

| Компонент | Ответственность | Зависимости | Как тестировать |
|---|---|---|---|
| `calibre-locator.sh` + Swift-обёртка `CalibreLocator` | Единый порядок кандидатов, проверка трёх CLI, источник и версия | `FileManager`, небольшой `ProcessRunner` | temp-кандидаты, матрица валидных/неполных установок |
| `CalibreInstaller` | Скачать, проверить SHA-512, смонтировать, скопировать в staging, проверить и атомарно опубликовать | `DownloadClient`, `CommandRunner`, `DiskCapacityProvider`, `AtomicPromoter` | URLProtocol/local HTTP + стабы `hdiutil`/`ditto`, temp FS |
| `CalibreInstallStore` | Одна UI state-machine, прогресс, отмена, повтор, ручной режим | `CalibreInstaller`, `AgentCoordinator`, `CalibreLocator` | детерминированные переходы состояний |
| `AgentCoordinator` | Сохранить WATCH_DIR, переписать plist правильными CLI, bootstrap/enable/kickstart | `EngineClient`, locator | stub installer и throwaway HOME/label |
| Agent contract | Передать единый `CALIBRE_MACOS_DIR`, убрать локальные hardcode | locator, installer, watcher, cover-finder, launchd | shell harness с тремя fake CLI |
| `RuntimeHealthStore` | Различать движок, конфигурацию plist и реальную активность агента | locator, `AgentStatus`, plist-reader | матрица missing/misconfigured/disabled/ready |
| Status/Setup/Settings | Представить одну install state-machine в трёх вариантах | runtime/install stores | forced-state harness + live click-test |
| Install transaction journal | Crash cleanup и восстановление незавершённой операции | app-owned каталог, не `state/` | имитация остановки на каждой фазе |

## 1. Детект и единая точка правды

Порядок:

1. `~/Library/Application Support/fb2-to-epub/calibre.app`
2. `/Applications/calibre.app`
3. `~/Applications/calibre.app`
4. `/opt/homebrew/bin` и `/usr/local/bin`, только если рядом доступны все три CLI
5. Тестовый override — исключительно в изолированном test mode

Произвольный `PATH` не использовать: Finder и launchd имеют разные окружения.

Кандидат считается готовым, только если исполняемы:

- `ebook-convert`
- `ebook-meta`
- `ebook-polish`

Дополнительно `ebook-convert --version` должен завершиться успешно с коротким timeout. Неполный managed-кандидат не блокирует поиск: locator продолжает к `/Applications`.

Единая реализация — `packaging/calibre-locator.sh`:

- installer подключает её как shell library;
- Swift вызывает executable-режим и получает структурированный результат;
- locator копируется в App Support `bin/`;
- watcher при отсутствии plist-env использует её как fallback;
- plist хранит `CALIBRE_MACOS_DIR` и, для обратной совместимости, три производных `EBOOK_*`;
- `cover-finder.py` берёт `os.environ["EBOOK_META"]` с locator-default, а не свой hardcode.

Результат locator:

```text
CalibreInstallation {
  source: managed | system | userApplications | homebrew
  appRoot
  macOSDir
  ebookConvert
  ebookMeta
  ebookPolish
  version
}
```

## 2. Установщик

State-machine:

```text
idle
→ preflight
→ downloading(received, total?)
→ verifyingChecksum
→ mounting
→ copying
→ validating
→ promoting
→ activatingAgent
→ success

Любая фаза → failure(kind)
downloading/verifyingChecksum → cancelling → idle
```

Порядок операции:

1. Создать transaction-каталог в App Support с UUID.
2. Проверить доступное место на томе назначения.
3. Разрешить redirect стабильного URL; принимать только HTTPS-хосты Calibre/GitHub.
4. Получить безопасное имя `calibre-X.Y.Z.dmg` из финального URL/Content-Disposition.
5. Скачать через отдельный `URLSession` с `URLSessionDownloadDelegate`.
6. Показывать байты всегда; процент — только при известном `expectedContentLength`.
7. Скачать `https://calibre-ebook.com/signatures/<filename>.sha512`.
8. Посчитать SHA-512 потоково через CryptoKit, не загружая 330 МБ в память.
9. `hdiutil attach -readonly -nobrowse -plist`; plist разобрать через `PropertyListSerialization`, без `grep /Volumes`.
10. Найти `calibre.app`, выполнить `ditto` в скрытый sibling staging-каталог.
11. Проверить staging: три CLI, `ebook-convert --version`, Info.plist, `codesign --verify --deep --strict`.
12. В `defer` закрыть handles и выполнить detach по device identifier. После обычного detach — ограниченный retry, затем `-force`.
13. Опубликовать staging:
    - первая установка — POSIX rename;
    - обновление — `renameatx_np(..., RENAME_SWAP)`;
    - старая версия после swap удаляется только после успеха.
14. Очистить DMG, mount metadata и staging.

Не переиспользовать `UpdateChecker.downloadAndInstall`: его detached-скрипт не даёт прогресса/отмены, не проверяет SHA и применяет другую модель замены приложения.

Ошибки должны быть типизированы:

- `network`
- `noSpace(required, available)`
- `untrustedRedirect`
- `checksumUnavailable`
- `checksumMismatch`
- `invalidDMG`
- `mountFailed`
- `copyFailed`
- `engineValidationFailed`
- `incompatibleMacOS`
- `agentActivationFailed`
- `cancelled`

`agentActivationFailed` не должен объявлять установку Calibre неуспешной: движок уже установлен, UI показывает отдельное действие «Повторить запуск агента».

### Место на диске

Не полагаться только на фиксированные 500 МБ:

- до скачивания: `Content-Length + консервативный reserve`;
- после mount: получить allocated size `calibre.app` и сделать точный второй check;
- DMG и staging держать на том же пользовательском data volume.

### Закрытие окна

Текущий `applicationShouldTerminateAfterLastWindowClosed == true` надо изменить:

- закрытие окна во время операции не отменяет установку;
- процесс остаётся в Dock, загрузка продолжается;
- повторное открытие показывает тот же `CalibreInstallStore`;
- явный Cmd-Q предлагает отменить;
- во время `copying/promoting` выход откладывается до безопасного detach/cleanup;
- при успехе и закрытом окне приложение может завершиться;
- при ошибке остаётся в Dock и запрашивает внимание, чтобы состояние не потерялось.

Background `URLSession` не нужен для MVP: он усложнит восстановление mount/copy. Устойчивость к crash обеспечивается staging и transaction journal.

## 3. Оживление агента

После успешного promotion:

1. Повторно вызвать locator — он обязан выбрать managed-копию первой.
2. Прочитать существующий WATCH_DIR из plist; при отсутствии plist использовать дефолт.
3. Запустить installer с выбранным `CALIBRE_MACOS_DIR`.
4. Installer атомарно переписывает plist и выполняет `bootout → bootstrap → enable → kickstart`.
5. Проверить:
   - plist существует;
   - сервис загружен и не disabled;
   - его `EBOOK_*` совпадают с текущим locator;
   - все пути исполняемы.
6. На main actor обновить runtime/status stores.
7. Переармить watcher `state/` и watcher отслеживаемой папки.
8. `kickstart` запускает разбор книг, уже лежащих в WATCH_DIR.

Все операции с агентом — через одну serial queue/actor. Иначе текущий асинхронный `refreshEngineIfBundledChanged()` может одновременно конфликтовать с установкой или сменой папки.

`FirstRunOutcome.blockedNoCalibre` нужно разделить:

```text
needsEngine
agentReady
agentSetupFailed
```

Сейчас им маскируется и отсутствие Calibre, и любое иное падение installer.

## 4. UI и D13

`CalibreInstallStore` живёт в `AppDelegate` и передаётся во все экраны. Он не является частью `StatusStore` и не привязан к текущему route, поэтому скачивание переживает переход Status → Settings.

`StatusStore` расширяется `RuntimeHealth`, а не вторым булевым флагом:

```text
engineMissing
installing
engineReadyAgentMissing
engineReadyAgentDisabled
engineReadyAgentMisconfigured
ready
```

Честный бейдж:

- нет движка — янтарный «Конвертация недоступна»;
- установка — «Устанавливаю движок»;
- движок есть, агент не готов — «Агент не запущен»;
- движок и plist согласованы, launchd активен — зелёный «Фоновый агент активен».

### Status

- Нет сырой истории — полноэкранный блокер.
- Есть сырая история — баннер-карточка, история остаётся видна.
- Для определения истории читать необработанный snapshot watcher: `converted_total > 0 || recent не пуст || last_conversion != nil`.
- Не использовать отфильтрованный `loadState()`: «Очистить» и «Сбросить статистику» не должны внезапно превращать баннер в блокер.

### Setup

При отсутствии Calibre:

- «Почти готово»;
- шаг движка янтарный;
- CTA «Установить Calibre»;
- footer «Ожидает движок»;
- если plist ещё нет, папка не называется активно отслеживаемой.

Флаг лучше изменить с `didShowSetup` на `didCompleteSetup`: завершение фиксируется только после готовности движка и агента.

### Settings

Строка Calibre становится компактным представлением той же state-machine:

- missing → «Установить»;
- downloading → прогресс и «Отмена»;
- error → «Повторить»;
- ready → версия и источник: «управляется fb2-to-epub» или «системный».

Ручная ветка открывает официальный сайт; «Проверить снова» запускает locator и затем `ensureAgentConfigured`.

### D13

Не меняется:

- приложение не пишет `state.json`;
- состояние установки хранится в памяти и app-owned transaction-каталоге;
- агент остаётся единственным владельцем conversion state и EPUB;
- installer меняет только app-owned Calibre и launchd-конфигурацию.

## 5. Обновления и сосуществование

- Managed Calibre всегда имеет приоритет.
- `/Applications/calibre.app` и `~/Applications/calibre.app` никогда не изменяются и не удаляются.
- Если найден только пользовательский Calibre, приложение использует его без обязательной managed-установки.
- Кнопка обновления внешней установки открывает официальный путь; автоматическое обновление всегда создаёт/обновляет managed-копию.
- Managed update использует тот же download/verify/staging/swap pipeline.
- После обновления агент переустанавливается даже при неизменном абсолютном пути: это гарантирует kickstart и актуальный plist.
- Проверку обновления делать по явному действию или редко по метаданным; 330 МБ никогда не скачивать автоматически.

Критический compatibility-риск: приложение поддерживает macOS 11, а текущий Calibre — macOS 14+. Нужна таблица официальных совместимых релизов:

- macOS 14+ → стабильный `/dist/osx`;
- старые поддерживаемые macOS → закреплённый официальный versioned DMG и его SHA-512;
- после mount всё равно проверить `LSMinimumSystemVersion`.

Альтернатива MVP — честно отключить автоустановку на неподдерживаемой macOS и оставить ручную совместимую установку.

## 6. Тестируемость

Протоколы для подмены:

- `CalibreLocating`
- `Downloading`
- `CommandRunning`
- `DiskCapacityProviding`
- `AtomicPromoting`
- `AgentControlling`

Безопасные overrides:

```text
FB2_FORCE_CALIBRE_STATE=missing|ready|downloading:47|error:network
FB2_CALIBRE_TEST_MODE=1
FB2_CALIBRE_TEST_ROOT=<mktemp>
FB2_CALIBRE_DMG_URL=http://127.0.0.1:...
FB2_CALIBRE_SHA512_URL=http://127.0.0.1:...
FB2_CALIBRE_INSTALL_ROOT=<mktemp>/AppSupport
FB2_CALIBRE_HDIUTIL=<stub>
FB2_CALIBRE_DITTO=<stub>
FB2_SKIP_AGENT_ACTIVATION=1
```

Защита от повторения инцидента с test override:

- mutating overrides принимаются только вместе с `FB2_CALIBRE_TEST_MODE=1`;
- install root обязан находиться внутри канонизированного `FB2_CALIBRE_TEST_ROOT`;
- test harness завершает приложение до обычного production startup;
- никакого test override в геттерах, используемых реальным installer без этой проверки.

Минимальные тесты:

- locator precedence и fallback от битой managed-копии;
- redirect/filename/trusted-host;
- SHA success/mismatch/malformed sidecar;
- download progress, unknown length, cancel, network loss;
- ENOSPC до download и во время ditto;
- attach plist parsing;
- detach вызывается на каждом выходе;
- staging никогда не заменяет рабочий Calibre до полной проверки;
- swap/rollback при существующей версии;
- агент с отсутствующим, устаревшим и правильным plist;
- все UI-состояния на Status/Setup/Settings;
- blocker/banner по сырой истории.

Обязательный живой pre-release e2e — один полный сценарий на чистом тестовом аккаунте:

```text
нет Calibre
→ кнопка
→ реальный официальный DMG
→ SHA-512
→ attach/ditto/detach
→ managed calibre.app
→ три CLI работают
→ quarantine отсутствует
→ launchd plist указывает на managed path
→ FB2 и FB3 из изолированной WATCH_DIR дают валидные EPUB
→ state.json обновлён агентом
```

Отдельно локальным маленьким DMG проверить отмену и закрытие окна; повторно качать официальный DMG ради этих веток не нужно.

## 7. Микрошаги реализации

Каждая строка — одно изменение/проверка менее двух минут.

1. Создать `CalibreInstallation.Source`.
2. Добавить модель `CalibreInstallation`.
3. Добавить `CalibreLocator.swift` в `SWIFT_SRCS`.
4. Создать skeleton `calibre-locator.sh`.
5. Добавить managed-кандидат.
6. Добавить `/Applications`.
7. Добавить `~/Applications`.
8. Добавить два Homebrew bin-кандидата.
9. Добавить проверку трёх executable.
10. Добавить structured output locator.
11. Написать первый precedence-test.
12. Скопировать locator в Resources.
13. Добавить locator в installer `find_src`.
14. Копировать locator в App Support `bin`.
15. Добавить `CALIBRE_MACOS_DIR` в plist.
16. Производить три `EBOOK_*` из одного каталога.
17. Обновить launchd template.
18. Научить watcher брать `CALIBRE_MACOS_DIR`.
19. Научить watcher sourcing locator без env.
20. Перевести cover-finder на env `EBOOK_META`.
21. Перевести `EngineClient.calibreInstalled()` на locator.
22. Перевести `calibreVersion()` на resolved CLI.
23. Разделить `blockedNoCalibre` и installer failure.
24. Добавить `InstallPhase`.
25. Добавить типизированный `InstallFailure`.
26. Создать `DownloadClient` interface.
27. Подключить progress delegate.
28. Подключить отмену task.
29. Добавить SHA-512 parser.
30. Добавить streaming hash.
31. Создать async `CommandRunner`.
32. Добавить разбор `hdiutil -plist`.
33. Добавить sibling staging.
34. Подключить `ditto`.
35. Добавить staged CLI validation.
36. Добавить codesign validation.
37. Добавить atomic rename первой установки.
38. Добавить atomic swap обновления.
39. Добавить unconditional cleanup/defer.
40. Добавить stale-transaction sweep на старте.
41. Создать `AgentCoordinator`.
42. Сериализовать agent mutations.
43. Добавить plist-path consistency check.
44. Создать долгоживущий `CalibreInstallStore`.
45. Добавить dynamic window-termination policy.
46. Добавить `RuntimeHealth` в StatusStore.
47. Реализовать честный badge/footer.
48. Добавить Status blocker.
49. Добавить Status banner.
50. Добавить Setup missing-engine branch.
51. Добавить Settings compact installer.
52. После success обновить stores.
53. После success переармить watchers.
54. Добавить forced UI states.
55. Прогнать stub-suite.
56. Прогнать local-DMG lifecycle test.
57. Прогнать обязательный живой e2e.

Высокорисковые группы: 15–23 — дрейф путей; 31–40 — mount/atomicity; 41–45 — гонки launchd/lifecycle; 48–51 — визуальная и кликовая проверка.

## Milestones

1. **M0 — Locator contract.** Все потребители выбирают один и тот же CLI-каталог; hardcode-тест запрещает новые `/Applications/calibre.app` вне locator.
2. **M1 — Agent contract.** Новый путь проходит через installer → plist → watcher → cover-finder; существующие `/Applications` продолжают работать.
3. **M2 — Installer core.** Download, SHA, DMG, staging, validation, atomic promotion; полностью на стабах.
4. **M3 — Runtime orchestration.** Install store, AgentCoordinator, window lifecycle, live refresh без перезапуска.
5. **M4 — UI.** Status hybrid, Setup, Settings, честные badge/error states.
6. **M5 — Compatibility/update.** OS-релизная матрица и managed update.
7. **M6 — Release gate.** Stub regression, local-DMG e2e, затем один полный e2e с официальным Calibre.

## Ключевые риски и альтернативы

- **macOS 11–13 против latest Calibre:** versioned compatibility manifest либо ручной fallback.
- **Тест заденет production plist:** жёсткий test-root guard; это release blocker.
- **Detach зависнет:** timeout, retry, force-detach, transaction journal.
- **Места окажется больше ожидаемого:** двухфазная проверка, точный размер после mount.
