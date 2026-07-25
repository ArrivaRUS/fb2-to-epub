# План FDA-онбординга — Архитектор #2 (GPT-5.6 Sol)

> Источник: `codex exec -m gpt-5.6-sol -c model_reasoning_effort=xhigh -s read-only`.
> Сырой вывод: `arch/plan-fda-codex.raw.txt`. Это независимое второе мнение к Архитектору #1;
> суд и синтез — за Юркой. Ключевые ссылки на существующие API сверены с кодом (см. «Проверка Юрки» ниже).

## Итог подхода

Агент на КАЖДОМ запуске явно проверяет читаемость `WATCH_DIR` (не выводит доступ из числа найденных файлов),
классифицирует результат по errno и атомарно публикует его в НОВОМ опциональном поле `agent.watch_dir_access`.
Приложение только читает поле; при `denied` показывает отдельную FDA-карточку по визуальному паттерну
`EngineSetupCard`; отсутствие поля карточку не включает (старые пользователи не мигают).
«Проверить снова» = `launchctl kickstart -k` + ожидание свежего `checked_at` через уже существующий watcher каталога `state/`.

## Компоненты

| Компонент | Ответственность | Зависит от | Как тестировать |
|---|---|---|---|
| `probe_and_publish_watch_dir_access()` (bash/Python в watcher) | `scandir` каталога, классификация errno, атомарная read-modify-write публикация в state.json | `WATCH_DIR`, `STATE_FILE`, Python | пустая папка, `chmod 000`, отсутствующая, файл вместо dir |
| `EngineAgentInfo.watchDirAccess` (Swift) | терпимый декод нового контракта; неизвестное/отсутствующее → `.unknown` | `StateStore` | old / new / future JSON-фикстуры |
| `BlockingIssueRouter` (Swift) | единый приоритет проблем FDA / Calibre / сбой агента | `StatusStore`, `InstallStore` | матрица состояний |
| `FolderAccessSetupCard` (Swift) | подачи banner/blocker, шаги 1-2-3, состояния checking/error | router, runner path | snapshot / UI-фикстуры |
| `FDARecheckCoordinator` (Swift) | kickstart, корреляция по `checked_at`, timeout, обратная связь | `EngineClient`, state-watcher | fake kickstart + отложенные snapshots |
| `EngineClient.readRunnerPath()` (Swift, НОВЫЙ) | фактический FDA-таргет из plist (`ProgramArguments.0` через `plutil`) | `plutil`, `plistPath` | throwaway plist |
| `installer.sh` (правки) | стабильный runner (byte-identity) + тестовая изоляция | `CalibreTestLatch` | runner byte-identity, тестовый plist |

## Решения по 7 пунктам

**1. Детект TCC-отказа.** `os.scandir()` открыть каталог и принудительно прочитать ≥1 запись / EOF.
Проверки количества файлов, glob, `-r`, `stat`, разбор локализованного stderr `ls/find` — ненадёжны. Классификация:
- успешный `scandir` (в т.ч. EOF пустого каталога) → `ok`;
- `EPERM` / `EACCES` → `denied`;
- `ENOENT`, `ENOTDIR` → каталог удалён / путь сломан → `unavailable`;
- `ENXIO`, `EIO`, `ESTALE` → том недоступен → `unavailable` (НЕ FDA-карточка).

Сам errno не доказывает именно TCC (chmod / ACL / TCC дают одинаковый `EACCES`) → текст карточки «Нет доступа к папке»,
а не «FDA точно запрещён». Probe — один раз на запуск event-driven агента, ПОСЛЕ lock и ДО Calibre / `count_pending()` / `find`.
Цена — один запуск Python + один readdir, единицы–десятки мс.
⚠️ Из стартового `mkdir -p` НАДО убрать `WATCH_DIR`, иначе удалённая папка автовоссоздаётся и случай «папка удалена» теряется.

**2. Контракт state.json.** Аддитивный опциональный объект `agent.watch_dir_access`:
`status: ok|denied|unavailable`, `errno: String?` (символическое имя), `checked_at: String` (UTC ISO-8601 с долями секунды).
`schema` остаётся `1` (изменение полностью аддитивное). Старое приложение игнорирует новый ключ; новый UI со старым
агентом получает `.unknown` и карточку не показывает; старый агент от поля не зависит.

**3. Состав подач и приоритет.** Отдельный `FolderAccessSetupCard` (НЕ добавлять FDA-фазы в семантически
Calibre-специфичный `EngineSetupCard`), переиспользуя его токены / CTA / подачи:
- есть история → компактный `.banner` над приглушённым Status;
- истории нет → `.blocker`;
- `unavailable` → отдельная подача «Папка недоступна» (смена папки, без FDA-утверждения).

Единый `BlockingIssueRouter` показывает ТОЛЬКО одну проблему. Приоритет:
`активная установка Calibre → сбой запуска агента → доступ к папке → отсутствие Calibre → обычный Status`.
При одновременном `denied` + нет Calibre — СНАЧАЛА FDA (доступ блокирует обнаружение книг независимо от движка);
после `ok` всплывает Calibre-карточка. Уже НАЧАТУЮ установку Calibre FDA-карточка не перебивает.

**4. «Проверить снова».** Существующий `EngineClient.kickstart()` → `/bin/launchctl kickstart -k gui/<uid>/<label>`, вне main-thread.
Перед вызовом запомнить текущий `checked_at`. Пока ждём новый: карточка «Проверяю доступ…», кнопки заблокированы,
постоянный polling НЕ вводится. Основной канал ответа — уже существующий watcher каталога `state/` (debounce 150 мс);
fallback только на время операции: перечитывание ~раз в 250 мс, timeout 8 с (с учётом `ThrottleInterval=5`).
Результат принимается ТОЛЬКО при изменившемся `checked_at`: `ok` убирает карточку; `denied` → «Доступ пока не появился»;
`unavailable` → переключение подачи. Ошибка `launchctl` / timeout = «Агент не ответил» (не повторный `denied`).

**5. Путь раннера для клипборда.** Копировать `ProgramArguments.0` установленного plist
(`~/Library/Application Support/fb2-to-epub/bin/fb2-to-epub-runner.sh`). Источник истины — новый
`EngineClient.readRunnerPath()`, читающий `ProgramArguments.0` через `plutil`. НЕ копировать путь watcher, `/bin/bash`
или бинарь приложения. Производный от `engine.home` путь допустим лишь как fallback диагностики; при существующем
plist использовать его фактическое значение. CTA сначала пишет путь в `NSPasteboard`, затем расширенная `openFullDiskAccess()`.
Runner в этой фиче НЕ менять (текущий `installer.sh` сохраняет его через `cmp` — важно для уже выданного FDA).

**6. Тестируемость без TCC.** `chmod 000` годится для ветки `EACCES`, но поведение TCC не доказывает; надёжнее закрывать
права на родительский каталог, после теста ОБЯЗАТЕЛЬНО восстанавливать через trap. Изоляция от боевого агента:
- отдельные `HOME`, `WATCH_DIR`, `FB2_STATE_DIR`, `FB2_COVERS_DIR`, `FB2_LOG_FILE`;
- добавить `FB2_LOCK_DIR` — иначе тест пересекается с боевым `/tmp/fb2-to-epub.lock.d`;
- прямой запуск watcher без production launchd;
- `EngineClient` с UUID-label и throwaway-home;
- unit-тест recheck — инъекция kickstart / process-runner, без `/bin/launchctl`;
- launchd-интеграция — только с тестовой защёлкой `CalibreTestLatch` и уникальной меткой.

**7. Миграция пользователей с уже выданным FDA.** Отсутствие `watch_dir_access` = ВСЕГДА `.unknown`, никогда `denied`.
UI никогда не выводит проблему из пустой истории / пустой папки / статуса «агент активен». После обновления изменившийся
watcher заставит `refreshEngineIfBundledChanged()` переустановить watcher/plist и сделать kickstart; runner останется
байтово прежним; первый probe запишет `ok`; переход `.unknown → .ok` визуально ничего не меняет — карточка НЕ мигает.

## Контракт-дифф state.json

| Поле | Before | After |
|---|---|---|
| `schema` | `1` | `1` (без изменения) |
| `agent.watch_dir` | `String` | без изменения |
| `agent.watch_dir_access` | отсутствует | опциональный объект (аддитивно) |
| `agent.watch_dir_access.status` | — | `String`: `ok` \| `denied` \| `unavailable` |
| `agent.watch_dir_access.errno` | — | `String?` (напр. `EPERM`, `EACCES`, `ENOENT`) |
| `agent.watch_dir_access.checked_at` | — | `String` ISO-8601 UTC с долями секунды |

Остальные поля сохраняются через read-modify-write; приложение их не записывает (инвариант: state.json пишет только агент).

## Порядок сборки (майлстоуны по зависимостям)

1. **Контракт + agent-probe:** порядок startup, атомарная запись, `FB2_LOCK_DIR`, снятие `WATCH_DIR` из стартового `mkdir`.
2. **Swift-модель + `readRunnerPath()`** — зависят от контракта.
3. **`BlockingIssueRouter` + `FolderAccessSetupCard`** — зависят от модели.
4. **`FDARecheckCoordinator` + live-feedback** — зависят от probe и существующего state-watcher.
5. **Регрессия installer / migration + полный тест-план** — после сквозного сценария.

## Тест-план

- **Probe:** пустая папка = `ok`; `chmod 000` = `denied/EACCES`; отсутствующая = `unavailable/ENOENT`; файл вместо каталога = `ENOTDIR`.
- **Снятие запрета:** `denied → ok`; история, totals и batch не теряются.
- **Контракт:** старый JSON, новый JSON, неизвестный status, malformed object — во всех случаях без crash.
- **UI-матрица:** FDA / Calibre / история / install-in-flight; одновременно FDA+Calibre показывает FDA первой.
- **Recheck:** успешный kickstart + свежий `checked_at`; повторный denied; timeout; ненулевой launchctl.
- **Инвариант писателя:** байты state.json не меняются от CTA приложения до запуска тестового агента.
- **Миграция:** «поле отсутствует → `ok`» не создаёт ни одного FDA-render.
- **Перед релизом — ручной smoke на чистом macOS-пользователе:** реальный `EPERM`, добавление runner в FDA, kickstart,
  конвертация и сохранение FDA после обновления. (Не автоматизируется.)

## Риски и альтернативы (что подсветил GPT)

- `EPERM/EACCES` не отличает TCC от ACL/chmod → диагностика/текст должны оставаться общими («нет доступа»), не «FDA запрещён».
- Если macOS вернёт успешный ПУСТОЙ `scandir` под блоком — отличить от честно пустой папки нельзя без sentinel-файла;
  sentinel Codex добавлять НЕ рекомендует.
- `kickstart -k` способен прервать работающий процесс; CTA доступен только при явном `denied`, когда конвертаций идти не должно.
- Deep-link в System Settings (`Privacy_AllFiles`) — не стабильный публичный API; нужен fallback на корневой раздел Privacy & Security.
- В более крупной версии Codex заменил бы shell-runner подписанным helper-бинарём с собственным диагностическим IPC;
  для v1.0.1 это несоразмерно малой фиче.

## Проверка Юрки (сверка утверждений Sol с кодом)

Спорные ссылки на существующие API сверены — фабрикаций не найдено:
- ✅ `mkdir -p "$WATCH_DIR" ...` реально в `bin/fb2-to-epub-watcher.sh:99` → catch про автовоссоздание удалённой папки ВЕРЕН.
- ✅ `EngineClient.kickstart()` есть (`app/EngineClient.swift:291`, `launchctl kickstart -k`).
- ✅ `plistPath` + `plutil -extract` — паттерн реален (`app/EngineClient.swift:108,215`); `readRunnerPath()` через
  `ProgramArguments.0` — правдоподобный сиблинг. Архитектурно верно: FDA даётся тому, что реально спавнит launchd = `ProgramArguments.0`.
- ✅ `CalibreTestLatch` — реальный harness изоляции (`app/CalibreLocator.swift:69`).
- ⚠️ Ключевая тонкость, которую Codex решил корректно: state.json сейчас пишется ТОЛЬКО внутри `record_conversion`
  (после конверсии). Под TCC-блоком конверсий нет → файл бы никогда не обновился. Отдельный `probe_and_publish` каждый
  запуск (независимо от конверсии, read-modify-write) — правильный ответ на это.

**Движок:** GPT-5.6 Sol, reasoning effort `xhigh`, sandbox `read-only`. Время ~5.5 мин, 0 ретраев.
