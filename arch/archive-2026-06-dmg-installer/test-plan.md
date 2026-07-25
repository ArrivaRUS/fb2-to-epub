# Тест-план — fb2-to-epub (DMG + установщик)

> Гейты валидации. Дата 2026-06-23.

## Регресс ядра (не сломать существующее)
- [ ] .fb2 в WATCH_DIR → рядом .epub.
- [ ] .fb2.zip → .epub.
- [ ] Папка с книгами (вложенность) → зеркало `-epub` со структурой.
- [ ] Идемпотентность: повторный прогон пропускает up-to-date (по mtime).
- [ ] Обложки: встроенная используется; без обложки — онлайн-поиск; нет сети — сборка без обложки.
- [x] Прогресс-кольцо «липкой» пачки: повторный launchd-fire МИДБАТЧ не сбрасывает
  total и не откатывает done (был баг). Авто: `bash tests/run-sticky-batch-test.sh`
  (см. раздел «Прогресс-кольцо…» ниже).

## FB3-трансформ (`bin/fb2-to-epub-fb3.py`) — авто, портативный

> Закрепляет milestone FB3 (M1–M7): FB3 (OPC/ZIP) → один валидный FB2, который
> дальше едет по СУЩЕСТВУЮЩЕМУ пути FB2→EPUB. Тесты ловят регрессии маппинга
> (XSLT-семантика `fb3_2_fb2_*.xsl`), коды возврата для watcher-ветвления и
> неприкосновенность FB2-пути.

**Запуск:**
- `bash tests/run-fb3-tests.sh` — трансформ (Python TAP-раннер,
  `tests/fb3-transform-tests/run.py`).
- `bash tests/run-fb2-regression-test.sh` — регрессия FB2-пути (bash).

**Стек:** только stdlib Python3 (как сам трансформ — БЕЗ pytest/lxml) +
bash/awk. Никакого pip. python3 резолвится как в watcher (env → типовые пути).

**Портативность (главное требование):** весь набор гоняется на **синтетической
FB3-фикстуре**, собираемой в памяти `tests/fb3-transform-tests/make_fixtures.py`
(валидный OPC/ZIP: `[Content_Types].xml`, `_rels/.rels` с Book-rel и
thumbnail-обложкой, `fb3/description.xml`, `fb3/body.xml` + оба `.rels`, 1×1 PNG
i_001/i_002, SVG-картинка, cover). Реальные `~/Desktop/fb2-to-epub/*.fb3` и
calibre `ebook-convert` — **дополнительно**: если есть — гоняются (e2e
FB3→FB2→EPUB + парс реальных книг), если нет — **SKIP** (проверено: на машине
без calibre/Desktop набор = 22/22 + 2 skip, exit 0).

**Изоляция/детерминизм:** каждый тест — свой `mktemp`; диагностика трансформа
глушится в in-process вызовах (stdout/stderr-контракт проверяется отдельным
subprocess-тестом); без сети/времени; повторный прогон даёт байт-в-байт тот же
FB2.

**Статус: трансформ 24/24 ✅ (на машине с calibre+Desktop; иначе 22/22 + 2 skip),
регрессия FB2 20/20 ✅.**

### Покрытие сценариев → тест (`tests/fb3-transform-tests/run.py`)

| Сценарий (из T3 `arch/plan-claude-fb3.md` / брифа) | Тест |
|---|---|
| трансформ → валидный FB2 (XML парсится) | `e2e: transform -> well-formed FB2` |
| картинки → `<binary>`, кол-во = уникальные img (дедуп) | `binary count == unique images`, `duplicate image deduped` |
| обложка: coverpage + binary `cover` | `cover (coverpage + cover binary)` |
| метаданные: title/author×2/lang/src-lang + жанр через genre-map | `metadata: title/authors/lang/genre-map` |
| `em→emphasis` (+strong/sub/sup/strikethrough), сохранение text/tail (R1) | `em->emphasis + text/tail kept` |
| ссылки: внутр `#id→#uid`, внешняя как есть, `note→a type=note #uid` | `links internal/external/note` |
| целостность id: target ссылки/сноски существует в FB2 | `link/note targets exist` |
| списки `ul`/`ol` → cite+p (маркер/нумерация) | `ul/ol lists` |
| таблица → FB2 table `th`/`td` (+id `u`-префикс) | `table th/td` |
| многосекционность: вложенные `section>section` | `nested sections (multisection)` |
| notes `count>1` → один `<body name="notes">` с 2 секциями | `notes count>1 -> 1 notes body/2 sec` |
| notes `count==1` → один notes-body, одна секция | `notes count==1` |
| SVG-картинка → graceful (инлайн `image/svg+xml`, без падения) | `SVG image graceful (inlined)` |
| без обложки (нет thumbnail) → нет `<coverpage>` (включится finder/генерёжка) | `edge: no cover -> no <coverpage>` |
| не-FB3: обычный zip → rc=2 | `non-OPC zip -> rc=2` |
| не-FB3: не-zip файл → rc=2 | `plain file -> rc=2` |
| битый XML внутри (body.xml) → rc=1 | `broken body.xml -> rc=1` |
| битый XML внутри (description.xml) → rc=1 | `broken description.xml -> rc=1` |
| валидный FB3 через CLI → rc=0 + непустой FB2 | `cli: valid FB3 -> rc=0 + FB2 file` |
| идемпотентность/детерминизм: повторный прогон = байт-в-байт | `determinism: rerun is byte-identical` |
| контракт watcher: без `--out` в stdout только FB2, диагностика в stderr | `cli: stdout is FB2-only, diag on stderr` |
| (доп.) e2e FB3→FB2→EPUB через calibre | `FB3->FB2->EPUB (calibre, optional)` — SKIP без calibre |
| (доп.) реальные книги с Desktop → валидный FB2 | `real: ~/Desktop/*.fb3 (optional)` — SKIP без файлов |

### Регрессия FB2-пути → тест (`tests/run-fb2-regression-test.sh`)

> FB3-врез НЕ должен трогать существующий `.fb2`/`.fb2.zip` путь. Проверяется без
> полного агента (no launchctl/Calibre/сеть): `epub_name()` извлекается дословно
> из shipping-watcher и исполняется; инвариант `convert_book` проверяется
> статически по shipping-исходнику (анкеры, не номера строк).

| Сценарий | Тест |
|---|---|
| `.fb2`/`.fb2.zip` (+ UPPER, юникод, пробелы) → `.epub` (как раньше) | `epub_name 'book.fb2'…'архив.fb2.zip'` |
| `.fb3` → `.epub` (новая ветка) | `epub_name 'novel.fb3'/'NOVEL.FB3'` |
| неизвестное расширение / fb2 в середине имени → пусто (skip) | `epub_name 'notes.txt'/'image.png'/'fb2-notes.md'` |
| `conv_src` по умолчанию = `$src` (FB2 не трансформируется) | `conv_src defaults to "$src"` |
| трансформ вызывается ТОЛЬКО в `*.fb3)` (одна ветка, без `*.fb2)`) | `transform gated by exactly one *.fb3) case`, `no *.fb2)… special-case` |
| `$FB3_TRANSFORM` не утекает за пределы `*.fb3)` | `FB3_TRANSFORM invoked only within…`, `no FB3_TRANSFORM use outside…` |
| downstream идёт через `$conv_src` | `downstream conversion uses $conv_src` |
| find-фильтры всё ещё ловят `*.fb2`/`*.fb2.zip` | `find filters still match *.fb2 and *.fb2.zip` |

### Дыры (осознанно не покрыто авто-тестом)

- **Полный watcher e2e на .fb3** (drop в WATCH_DIR → 2 EPUB, лог `FB3->FB2 ok` +
  `cover (embedded)`, повторный прогон → skip; T4/T6 плана): требует живого
  агента/launchd + Calibre. Регрессия FB2-пути закрывает «не сломали FB2»;
  FB3-трансформ закрывает «FB3→валидный FB2»; стык в watcher — ручной прогон/QA.
- **Установка движка** (`installer.sh` кладёт `*-fb3.py` + genre.json в App
  Support/bin; T6): зона существующего install-теста / QA фазы.
- **`custom-info` глубокая рекурсия** (R2 плана) — частичная по дизайну (MVP),
  тестом не фиксируем глубокие пути.
- **Сортировка notes по `@show`** (R3) — берём порядок документа (упрощение).

## Прогресс-кольцо «липкой» пачки (`batch_state` в watcher) — авто, изолированный

> Закрепляет фикс «липкая очередь конвертации»: одна логическая пачка из N файлов
> поднимает НЕСКОЛЬКО launchd-fire (cover-apply-job в covers/jobs и каждый
> записанный .epub в watch-dir — это WatchPaths-изменения). Каждый fire считает
> pending = `count_pending()` = ОСТАВШИЕСЯ непреобразованные и зовёт
> `batch_state begin "$pending"`. Старый код делал безусловный begin →
> `{active,total=pending,done:0}`, и fire ПОСРЕДИ пачки сбрасывал `{total:15,done:4}`
> в `{total:11,done:0}` — кольцо прыгало назад / «залипало». Фикс: `begin` решает
> continuation-vs-new по on-disk batch и НИКОГДА не откатывает done / не ужимает
> total посреди пачки.

**Запуск:** `bash tests/run-sticky-batch-test.sh` (из корня репо `fb2-to-epub`).

**Что покрывает (без launchctl/Calibre/сети/Desktop, без полного прогона watcher):**
функция `batch_state()` извлекается ДОСЛОВНО из shipping-watcher (анкеры
`^batch_state() {` … колонка-0 `}`, как `run-fb2-regression-test.sh` тянет
`epub_name`/`convert_book`), сорсится в песочницу и гоняется напрямую парами
(mode, total_arg) против приватного `STATE_FILE`. Так тест отслеживает РЕАЛЬНУЮ
машину состояний: правка логики begin/tick/end — тест краснеет. Контракт функции:
argv=(mode,total_arg); env=STATE_FILE/PYTHON3/LOG_FILE; эффект — read-modify-write
поля `batch` с сохранением соседних ключей. Зависимостей от
`count_pending`/`WATCH_DIR`/Calibre нет → юнит в изоляции.

**Стек:** только bash/awk + stdlib Python3 (как сам watcher; БЕЗ pytest). python3
резолвится как в watcher/`run-fb3-tests.sh` (env → типовые пути → PATH); без
исполняемого python3 — НЕ «молчаливый зелёный», а явный fail.

**Изоляция/детерминизм:** один `mktemp -d` на весь прогон, свой `STATE_FILE` на
сценарий (монотонный счётчик, БЕЗ суффикса у шаблона — BSD `mktemp` на macOS
коллизит на `state.XXXXXX.json`), `trap … EXIT` чистит песочницу; без сети/времени;
два прогона дают байт-в-байт идентичный вывод.

**Статус: 30/30 ✅.**

### Покрытие сценариев → тест (`tests/run-sticky-batch-test.sh`)

| Сценарий (из брифа фикса) | Тест |
|---|---|
| (в) новая пачка на чистом state → begin как раньше: `total=pending, done:0` | `begin on clean -> {active,total=7,done=0}` |
| (а) мидбатч `{15,4}` + повторный fire без новых файлов (pending=11) → total=15, done сохранён, НЕ сброс | `begin keeps total=15, done stays 4 (NOT reset to {11,0})`, `repeat begin still {15,4}` |
| (б) мидбатч `{15,4}` + дроп новых (pending=16) → total растёт (done+pending>total), done сохранён | `begin grows total 15->20, done stays 4` |
| (б′) pending < остатка → total не ужимается (консервативный hold) | `begin holds total=15 when projected<prev (no shrink)` |
| (г) idle-fire (pending==0) → batch не трогается (гард на CALL-SITE: `begin` под `pending_total>0`; `end` под `batch_started==1`) | `watcher gates 'batch_state begin' behind pending_total>0`, `release_batch returns early unless batch_started==1`, `end(0) on finished {false,15,15} leaves it untouched` |
| (г′) stale active `done>=total` → begin стартует новую пачку начисто | `stale active done>=total -> begin starts fresh {3,0}` |
| (д) промежуточный fire без конвертации → `active:true` остаётся | `end on intermediate fire keeps active:true {15,4}` |
| (е) `end` гасит iff `done>=total` ИЛИ `pending==0`; иначе active | `end closes when done>=total`, `end closes when pending==0`, `end stays active when done<total AND pending>0` |
| tick двигает только активную пачку и капится на total (кольцо ≤100%), no-op на неактивной | `tick advances done 3->4`, `tick caps done at total`, `tick is a no-op on an INACTIVE batch` |
| полный жизненный цикл: begin→tick→[мидбатч re-fire begin]→tick→end == 3/3 (монотонно) | `mid-batch re-fire holds {3,1}`, `lifecycle ends finished at 3/3` |
| соседние ключи state.json (history/version/…) не затираются | `sibling 'version'/'history' preserved`, `batch still updated correctly alongside siblings` |
| битый/не-объект/отсутствующий state.json → begin восстанавливается, не падает | `corrupt state.json -> {4,0}`, `non-object -> {2,0}`, `missing -> {5,0}` |
| неизвестный mode → НИЧЕГО не пишет (не корраптит in-flight batch) | `unknown mode is a no-op` |

### Дыры (осознанно не покрыто этим тестом)

- **Полный watcher e2e на «липкой» пачке** (реальные launchd-fire подряд: drop N
  книг → кольцо растёт монотонно до N/N, окно всплывает РОВНО раз): требует живого
  агента/launchd + Calibre. Здесь зафиксирована машина состояний `batch_state` и
  гард на call-site; живой стык launchd↔кольцо — ручной прогон/QA.
- **`count_pending()` (источник `total_arg`)** покрыт косвенно: тест подаёт pending
  как аргумент. Точность самого подсчёта pending (top-level + папки, up-to-date
  skip по mtime) — зона ядрового регресса/QA, не этого юнита.
- **UI прогресс-кольца** (`StatusView.swift` рисует `done/total`): значения из
  state.json проверены здесь; визуал кольца — визуальная верификация Юрки/QA.

## Установщик
- [ ] `bash installer.sh "<папка с пробелом/юникодом>"` — plist корректен (plutil), агент грузится.
- [ ] Смена папки повторным запуском — старый агент снят, новый на новый путь, без дублей.
- [ ] Нет Calibre → понятное сообщение, не падает молча.
- [ ] Агент стартует с голым PATH и всё равно находит ebook-convert/python3 (абсолютные пути).

## TCC (критично из-за Desktop-дефолта)
- [x] На этой машине: агент читает `~/Desktop/fb2-to-epub` (проверено: да).
- [ ] **Живой тест «как у нового пользователя»** (чистый профиль/доброволец): пройти DMG→установка→drop; если Desktop блокируется — guided-FDA flow реально разблокирует.

## Сборка/дистрибуция
- [ ] build-app.sh: Info.plist содержит `CFBundleIdentifier=com.arrivarus.fb2toepub`; AppIcon.icns на месте; `codesign --verify` ок.
- [ ] make-dmg.sh: .dmg монтируется, раскладка (фон, /Applications, иконка) корректна.
- [ ] Первый запуск без подписи: путь Open Anyway работает (документирован в DMG-фоне + README).

## Визуальная верификация (Юрка)
- [ ] Иконка .app в Finder/Dock = Концепт 1 (поэлементно).
- [ ] DMG-окно: фон-инструкция читается, элементы на местах.

## Регресс «Очистить» (история конвертаций) — авто, изолированный

> Закрепляет фикс кнопки «Очистить» (M2+, ветка `native-ui`).
> Логика: `clearHistory()` пишет app-owned маркер
> `…/state/recent-cleared-at` (ISO-8601 UTC, atomically); `loadState()`
> фильтрует `recent[]` — оставляет только `ts > cutoff` (fail-open на битом ts),
> переустанавливает `last_conversion`. `state.json` приложение НЕ пишет.

**Запуск:** `bash tests/run-clear-history-tests.sh` (из корня репо `fb2-to-epub`).
**Стек:** `xcrun swiftc` (как `build/build-app.sh`), без SwiftPM/XCTest — мини
TAP-раннер. Компилирует продакшн `EngineClient.swift` / `EngineClient+Status.swift`
/ `StateModel.swift` / `UpdateChecker.swift` + `tests/ClearHistoryTests/{Stubs.swift,
main.swift,UpdateCheckerTests.swift}`.
**Изоляция:** throwaway-лейбл `com.example.fb2toepub.test.*` + `mktemp -d` HOME на
КАЖДЫЙ тест; реальный агент/`~/Library/Application Support/fb2-to-epub`/Desktop/книги
не трогаются; temp прибирается (`trap`). Детерминирован (без сети/сна; ts — явные
константы прошлое/будущее). **Статус всего Swift-набора: 90/90 ✅** (включает
группы A «Сбросить статистику», B «Сменить папку» и C/D/E авто-обновления — см. ниже).

- [x] before-clear: state.json с N записями + last_conversion → `recent.count == N`, `lastConversion != nil`.
- [x] clear пишет маркер: после `clearHistory()` файл `recent-cleared-at` есть и парсится `RelativeTime.parse`.
- [x] after-clear скрывает старое: все ts < маркера → `recent.isEmpty`, `lastConversion == nil`.
- [x] state.json не тронут: байты идентичны до/после `clearHistory()` (приложение в него не пишет).
- [x] новые конвертации возвращаются: запись с ts строго НОВЕЕ маркера снова видна, `last_conversion` указывает на неё.
- [x] персист: новый `EngineClient(same home)` после clear → список всё ещё отфильтрован (маркер на диске).
- [x] fail-open: запись с битым ts остаётся видимой после clear; парсящаяся старая — скрыта.

> **Известная граница (не баг):** маркер пишется с секундной точностью
> (`ISO8601` без долей), фильтр строгий `ts > cutoff`. Конвертация с ts ровно в
> ту же секунду, что и нажатие «Очистить», скроется — осознанно («очистить всё до
> текущего момента включительно»); под-секундная гонка на практике неактуальна.

## Регресс v0.2.2 «авто-обновление» — авто, изолированный

> Закрепляет фичу авто-обновления: `app/UpdateChecker.swift` (semver-сравнение,
> проверка источника, скачивание+sha256, detached install-скрипт) и on-launch
> авто-рефреш движка `EngineClient.refreshEngineIfBundledChanged()`.

**Две связки:**
1. **Swift-юниты** — внутри того же раннера: `bash tests/run-clear-history-tests.sh`
   (группы C/D/E; стек/изоляция те же, что выше).
2. **Bash, install-скрипт** — отдельный раннер: `bash tests/run-update-install-test.sh`.
   Извлекает тело install-скрипта из строкового литерала `installScriptBody`
   (`app/UpdateChecker.swift`) по Swift-делимитерам `#"""…"""#` (снимает 4-пробельный
   отступ) и гоняет его в песочнице: `mktemp`-target-бандл + `mktemp`-dmg с
   `fb2-to-epub.app` (`hdiutil create`) + **stub `open`** в PATH + **заведомо мёртвый
   PID** + workDir-аргумент. Реальные `installer.sh`/`launchctl`/агент НЕ запускаются;
   `/Applications` и реальный App Support не трогаются; всё под `mktemp -d`, прибор `trap`.
   **Статус: 13/13 ✅.**

### C — semver `UpdateChecker.isNewer(_:than:)`
- [x] true: `0.2.2>0.2.1`, `0.10.0>0.9.9` (числовое, не лексикографическое), `1.0>0.9.9`, `0.3.0>0.2.9`.
- [x] false: `0.2.1==0.2.1`, `0.2.1<0.2.2`, `0.9.9<1.0`.
- [x] краевые без крэша: пустые операнды, разная длина (`1`↔`1.0.0`), нечисловые компоненты, `...`.

### D — `UpdateChecker.isTrustedSource(_:)`
> Функция `static` (не private) → тестируется напрямую.
- [x] доверенные: `https://github.com/…dmg`, `https://objects.githubusercontent.com/…`, `https://*.githubusercontent.com`.
- [x] отклонены: `http://…` (downgrade), `https://evil.com/…`, look-alike `https://github.com.evil.com/…`, `https://evilgithubusercontent.com` (не subdomain), `ftp://…`.

### E — on-launch авто-рефреш `refreshEngineIfBundledChanged()` (stub-installer, env `FB2_BUNDLED_RES_DIR`)
> Stub-installer = throwaway `.sh`, пишет свой argv и `exit 0/1`; НЕ реальный `packaging/installer.sh`.
- [x] нет plist → `.skippedNoPlist`, installer НЕ вызван.
- [x] bundled == installed (байт-в-байт) → `.upToDate`, installer НЕ вызван (app-only апдейт ничего не трогает).
- [x] один скрипт отличается → `.refreshed`, installer вызван 1×, переданный `WATCH_DIR` == значение из plist (пробелы/юникод целы).
- [x] установленный скрипт отсутствует → `.refreshed` (движок надо разложить).
- [x] differs + installer rc≠0 → `.refreshFailed`, без падения (агент как есть, ретрай на следующем запуске).

### Install-скрипт `installScriptBody` (bash, песочница)
- [x] **happy:** target заменён новым бандлом; dmg/workDir вычищены; mount отмонтирован; relaunch (`open`) вызван с верным путём target; `exit 0`.
- [x] **failure** (dmg без `fb2-to-epub.app`): старый target СОХРАНЁН; relaunch вызван; нет вложенного `app/app`; `exit ≠ 0`.
- [x] **rollback** (target неудаляем, `chflags uchg`): нет вложенного `app/app`; запущен старый рабочий бандл; `exit ≠ 0`. Доп. always-on проверка наличия guard-ветки `[ -e "$TARGET" ]` в скрипте.

> **Покрытие на уровне сети не автоматизировано (осознанно):** `checkLatest` /
> `downloadAndInstall` / GitHub-парсинг / sha256-mismatch требуют сетевых моков
> (URLSession) либо живого GitHub — вне изолированного offline-харнеса. Логика
> разнесена: чистые ветки (semver, проверка источника) и пост-quit install
> покрыты здесь; сетевой happy-path — ручной прогон при релизе.
