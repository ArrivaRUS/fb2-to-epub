# Plans — онбординг Calibre (детект → автоустановка → оживление агента)

## Source

- **Task:** при отсутствии движка приложение честно показывает проблему (гибрид: блокер B без
  истории / баннер A с историей, D37) и ставит Calibre в 1 клик в
  `~/Library/Application Support/fb2-to-epub/calibre.app` (D39), затем оживляет агента.
- **Canonical inputs:**
  - `arch/plan-calibre-onboarding-synthesis.md` — СИНТЕЗ двух архитекторов (канон архитектуры);
    детали каркаса — `arch/plan-calibre-onboarding-claude.md`, находки — `arch/plan-calibre-onboarding-codex.md`.
  - `decisions/log.md` **D37–D42** (гибрид подачи; имя кнопки; место установки; D40 фоновая
    установка при закрытии окна; D41 пре-чек 1,5 ГБ / текст «~1 ГБ»; D42 macOS < 14 → только «Вручную»).
  - `design/calibre-onboarding/flow.md` — машина состояний UX (§3) и таблица состояний (§6).
  - `design/calibre-onboarding/design-spec.md` — **дизайн-спец (G3, готовит Юрка)** — точные
    пиксели/цвета/тексты для CAL-2/CAL-4. Здесь НЕ дублируется; расхождение спека↔plans → вопрос Юрке.
  - `research/calibre-auto-install.md` — URL/SHA-512/quarantine-факты.
- **Repo area:** `app/` (Swift), `packaging/installer.sh`, `bin/fb2-to-epub-watcher.sh`,
  `bin/fb2-to-epub-cover-finder.py`, `tests/`, `build/`.
- **Last updated:** 2026-07-19.

## Инварианты (нарушать нельзя)

1. **D13:** `state.json` пишет только агент; приложение читает + свои маркеры в `state/`.
2. **`runner.sh` неприкосновенен** (FDA-грант по байтам). Plist — только через `plutil` (D5), label стабилен (D7).
3. Установщик пишет ТОЛЬКО в app-owned места: `App Support/fb2-to-epub/{downloads,calibre.app*}`.
   Чужой `/Applications/calibre.app` не трогаем никогда (ни удалить, ни обновить).
4. **GPL-линия:** бинарники Calibre не попадают в git/DMG приложения — только рантайм-скачивание с официального URL.
5. **Контракт детекта:** порядок кандидатов `App Support/fb2-to-epub/calibre.app` →
   `/Applications/calibre.app` → `~/Applications/calibre.app`; валидная локация = все 3 CLI
   (`ebook-convert`, `ebook-meta`, `ebook-polish`) исполняемы. Реализации: Swift (`CalibreLocator`)
   + bash (`installer.sh`), синхронность держит parity-тест. Новые хардкоды
   `/Applications/calibre.app` вне локатора запрещены (grep-тест).
6. **Урок 015 (строгая защёлка):** mutating тест-оверрайды (`FB2_CALIBRE_DMG_URL`,
   `FB2_CALIBRE_SHA512_URL`, `FB2_CALIBRE_DISABLE_SYSTEM`, `FB2_AGENT_LABEL` из приложения)
   действуют ТОЛЬКО при `FB2_CALIBRE_TEST_MODE=1` И install-root внутри канонизированного
   `FB2_CALIBRE_TEST_ROOT`; иначе молча игнорируются. Display-only оверрайд
   `FB2_FORCE_INSTALL_STATE` — без защёлки (зеркало `FB2_FORCE_BATCH`, на диск не пишет).
   *Дополнение D-ревью 2026-07-21:* полузведённая защёлка (`TEST_MODE=1` И задан `DMG_URL`, но
   install-root вне `TEST_ROOT`) = ГРОМКИЙ отказ установки (`.error(.install)` + NSLog), а не тихий уход на прод.
7. **Урок 016:** перед релизом — ровно 1 ЖИВОЙ e2e (реальное скачивание/установка/конвертация); стабы его не заменяют.
8. **Урок 006 (простота):** без докачки/resume, без GPG, без transaction-journal, без legacy-пиннинга (D42).
9. **D40:** закрытие окна НЕ прерывает установку (процесс живёт в Dock); Cmd-Q при скачивании —
   вопрос; во время copy/promote выход откладывается до безопасной точки.
10. Сетевые скачивания — https-only, allow-хосты: `calibre-ebook.com`, `download.calibre-ebook.com`,
    `github.com`, `*.githubusercontent.com`.

## Assumptions

- Дизайн-спец `design/calibre-onboarding/design-spec.md` будет принят (G3) ДО старта CAL-2;
  CAL-1 и CAL-3 от него не зависят и стартуют сразу.
- ОПРОВЕРГНУТО (Darwin 25.5, проба live-verify): `NSHomeDirectory()` у НАПРЯМУЮ запущенного бинаря
  ИГНОРИРУЕТ `$HOME` (отдаёт реальный дом) → throwaway-HOME-харнесс не изолировал приложение.
  Фикс: единый `EngineHome.resolve()` (`CalibreLocator.swift`) — под тест-защёлкой берёт env `HOME`,
  в проде `NSHomeDirectory()` (байт-в-байт); вся engine-часть (локатор/установщик/EngineClient/пути
  state/covers/plist) ходит через него.
- `https://calibre-ebook.com/dist/osx` и `/signatures/<file>.sha512` живы в форме из ресёрча
  (валидация-проба в CAL-3 до кода конвейера).
- Машина разработки/живого e2e — macOS ≥ 14 (exec реального ebook-convert).
- Версию релиза (предлагаю v0.10.0) решает человек при выкладке.

## Validation Assumptions

- Полная сборка: `build/build-app.sh 0.10.0-dev` (компилирует все `app/*.swift`, arm64+x86_64+lipo+codesign).
- Быстрый типчек одного шага: `xcrun swiftc -typecheck app/*.swift` — ДОПУЩЕНИЕ (top-level main.swift
  может потребовать флагов); если не взлетит — валидировать полной сборкой.
- Все `tests/run-*.sh` — самодостаточные раннеры (существующий стиль репо), выход 0 = зелёно.

## Milestone Order

| ID | Title | Depends on | Status |
|---|---|---|---|
| CAL-1 | Контракт детекта: CalibreLocator везде (Swift+bash+watcher+finder) | — | [ ] |
| CAL-2 | Честный UI (read-only): бейдж/Setup/Настройки/скелет EngineSetupCard | CAL-1, design-spec (G3) | [ ] |
| CAL-3 | CalibreInstaller: конвейер скачать→проверить→поставить (headless + fixture-тесты) | CAL-1 | [ ] |
| CAL-4 | Сшивка: оживление агента, действия UI, D40-lifecycle | CAL-2, CAL-3, design-spec (G3) | [ ] |
| CAL-5 | Гейт релиза: живой e2e + live-verify Юрки + регрессия + доки | CAL-4 | [ ] |

CAL-2 ∥ CAL-3 параллелятся после CAL-1.

---

## CAL-1. Контракт детекта: CalibreLocator везде `[ ]`

### Goal — что становится правдой
Знание «где движок» существует в одном контракте (§Инварианты п.5), реализованном в Swift и bash;
частичный Calibre (без polish/meta) больше не считается установленным; cover-finder уважает env;
plist несёт `CALIBRE_MACOS_DIR` + производные `EBOOK_*`; `blockedNoCalibre` разделён на два
честных исхода. Поведение на машинах с валидным `/Applications/calibre.app` не меняется.

### Tasks
- [ ] 1.1 `app/CalibreLocator.swift`: `CalibreLocation {macosDir, ebookConvert, ebookMeta, ebookPolish, kind}` +
      `resolve(home:) -> CalibreLocation?` по контракту; тест-защёлка: при `FB2_CALIBRE_TEST_MODE=1`+
      валидном `FB2_CALIBRE_TEST_ROOT` первым кандидатом становится `<TEST_ROOT>/calibre.app`,
      `FB2_CALIBRE_DISABLE_SYSTEM=1` выключает кандидатов 2–3; без защёлки оба env игнорируются.
- [ ] 1.2 `EngineClient`: `ebookConvertPath` → опциональный явный оверрайд (`String? = nil`; nil → локатор);
      `calibreInstalled()`/`calibreVersion()` через локатор; существующие вызовы/тесты не ломаются.
- [ ] 1.3 `EngineClient.FirstRunOutcome`: `blockedNoCalibre` → `needsEngine` (движка нет, installer не звали)
      и `agentSetupFailed` (движок есть, installer упал); обновить switch в `main.swift`
      (`shouldShowSetup`) с прежним поведением для обоих новых случаев.
- [ ] 1.4 `packaging/installer.sh` §1: детект циклом по кандидатам контракта (env `EBOOK_CONVERT` —
      высший приоритет, как сейчас); уважает `FB2_CALIBRE_DISABLE_SYSTEM`; `LABEL="${FB2_AGENT_LABEL:-com.arrivarus.fb2toepub.agent}"`
      (тест-оверрайд для изолированной активации; дефолт байт-в-байт прежний).
- [ ] 1.5 `installer.sh` §4: в `EnvironmentVariables` добавить `CALIBRE_MACOS_DIR`; `EBOOK_*` писать
      как производные от него (значения-абсолюты остаются — обратная совместимость со старым watcher).
- [ ] 1.6 `bin/fb2-to-epub-watcher.sh:22,46,51`: фолбэк-дефолты → цепочка «app-owned → /Applications»
      (под launchd пути всё равно приходят из plist).
- [ ] 1.7 `bin/fb2-to-epub-cover-finder.py:64`: путь ebook-meta из `os.environ["EBOOK_META"]`
      с фолбэком на цепочку локатора (сейчас константа игнорирует env агента — ломало бы
      вшивание обложек при managed-установке).
- [ ] 1.8 Тесты: `tests/run-calibre-locator-tests.sh` (Swift-юниты: 5 фикстурных деревьев — только
      app-owned / только system / оба / частичный без polish / пусто; + защёлка TEST_MODE);
      `tests/run-calibre-locator-parity.sh` (bash-детект installer.sh против Swift на тех же деревьях);
      `tests/run-calibre-hardcode-grep.sh` (новые `/Applications/calibre.app` вне
      локатора/installer-детекта/фолбэков watcher = FAIL).

### Definition of Done
- Один и тот же ответ Swift/bash на всех parity-деревьях; частичная установка → «движка нет» с обеих сторон.
- `plutil -p` сгенерированного plist показывает `CALIBRE_MACOS_DIR` + 3 `EBOOK_*` абсолюта.
- grep по `app/ bin/ packaging/` не находит хардкодов вне разрешённых мест (тест зелёный).
- Все существующие наборы зелёные (поведение при валидном /Applications-Calibre не изменилось).

### Validation
```sh
cd "/Users/arrivarus/Documents/VibeCoding2/2026.06 fb2-to-epub"
tests/run-calibre-locator-tests.sh
tests/run-calibre-locator-parity.sh
tests/run-calibre-hardcode-grep.sh
tests/run-clear-history-tests.sh && tests/run-cover-job-tests.sh
tests/run-fb3-tests.sh && tests/run-fb2-regression-test.sh && tests/run-sticky-batch-test.sh
build/build-app.sh 0.10.0-dev
```

### Known Risks
- Существующие тесты передают `ebookConvertPath` явно — семантика «явный оверрайд» обязана их сохранить.
- Правка installer.sh задевает боевой путь установки — прогонять только на throwaway HOME/label.
- cover-finder: фолбэк обязан сохранить сегодняшнее поведение при пустом env (ручные запуски).

### Stop-and-Fix
Упала parity/регрессия → чинить до старта CAL-2/CAL-3; контракт детекта — фундамент всего.

---

## CAL-2. Честный UI (read-only) `[ ]`

### Goal — что становится правдой
Без движка приложение не врёт нигде: Status показывает гибрид D37 (блокер B без истории / баннер A
с историей — по СЫРОМУ snapshot watcher), бейдж — янтарный «Конвертация недоступна», Setup — янтарный
шаг «ДВИЖОК» + «Почти готово»/«Ожидает движок», Настройки — строка-действие. Пиксели/тексты —
строго `design/calibre-onboarding/design-spec.md` (G3).

### Tasks
- [ ] 2.1 `EngineClient.hasRawHistory()` — по НЕфильтрованному `StateStore.load()`:
      `converted_total > 0 || !recent.isEmpty || lastConversion != nil` (иначе «Сбросить статистику»
      превращал бы баннер в блокер); использовать и в `shouldShowSetup` (единый helper).
- [ ] 2.2 `StatusStore` + `calibrePresent: Bool`; `refreshStatusNow()`/`buildRoot(.status)` заполняют
      через локатор (3×stat, БЕЗ спавна процессов в refresh-цикле).
- [ ] 2.3 Бейдж/футер Status: `!calibrePresent` → янтарный «Конвертация недоступна» / футер «Нет движка»
      (поверх agentActive-веток); цвета/типографика — из design-spec.
- [ ] 2.4 `app/EngineSetupCard.swift` (скелет, без действий): рендер `InstallPhase` в 4 подачах
      `.blocker`/`.banner`/`.setupStep`/`.settingsRow` по таблице flow.md §6 + design-spec;
      D42-вариант «автоустановка недоступна на этой macOS» (manual-only).
- [ ] 2.5 StatusView: врезка гибрида (блокер вместо контента / баннер под шапкой, `hasRawHistory`);
      refit высоты окна на появление/уход (пути `present`/`refitWindowHeight`, уроки 011/013).
- [ ] 2.6 SetupView: янтарная ветка шага «ДВИЖОК» (`calibreVersion == nil`) + «Почти готово» + футер
      «Ожидает движок»; зелёная ветка не тронута. `didShowSetup`-семантику НЕ менять (синтез).
- [ ] 2.7 SettingsView: строка Calibre → EngineSetupCard(.settingsRow); installed-вид как сегодня.
- [ ] 2.8 `FB2_FORCE_INSTALL_STATE` (display-only, зеркало FB2_FORCE_BATCH): оверлей фазы для
      скриншотов (`empty|downloading:94/210|installing|verifying|success|error-network|error-space|error-install|manual|activation-failed|os-unsupported`).

### Definition of Done
- Скриншоты всех состояний §6 (через FB2_FORCE_INSTALL_STATE) сняты на 400px и совпадают с design-spec
  (проверка design-reviewer — пиксель-чеклист в CAL-5).
- С движком (валидный /Applications) ни один экран не изменился (скриншот-сравнение Status/Setup/Настройки).
- «Сбросить статистику» при истории НЕ переключает баннер→блокер (ручная проверка + юнит на hasRawHistory).

### Validation
```sh
cd "/Users/arrivarus/Documents/VibeCoding2/2026.06 fb2-to-epub"
build/build-app.sh 0.10.0-dev
# скриншот-прогон состояний (пример):
FB2_CALIBRE_TEST_MODE=1 FB2_CALIBRE_TEST_ROOT="$(mktemp -d)" FB2_CALIBRE_DISABLE_SYSTEM=1 \
  FB2_FORCE_INSTALL_STATE="downloading:94/210" open build/dist/*.app
tests/run-clear-history-tests.sh && tests/run-sticky-batch-test.sh
```

### Known Risks
- Refit-гонки высоты при смене блокер↔баннер↔обычный Status (уроки 011/013) — проверять на макс/мин контенте.
- Design-spec может уточнить состав состояний — plans не дублирует пиксели, но состав состояний
  EngineSetupCard при расхождении сверить с Юркой (Stop-and-Ask).

### Stop-and-Fix
Скриншоты не совпали со спекой / регрессия старых экранов → чинить до CAL-4.

---

## CAL-3. CalibreInstaller: конвейер (headless) `[ ]`

### Goal — что становится правдой
`CalibreInstaller` проводит машину состояний flow.md §3: precheck (диск 1,5 ГБ, D41; OS-гейт ≥14,
D42) → download (прогресс, отмена, trust-gate) → SHA-512 fail-closed → mount (`-plist`) →
LSMinimumSystemVersion-чек → ditto в staging → `codesign --verify --strict` + exec `--version` →
атомарный своп → зачистка. Всё тестируемо fixture-DMG без сети и без 330 МБ.

### Tasks
- [ ] 3.0 Пробы вживую (до кода, фиксация констант): `curl -sIL https://calibre-ebook.com/dist/osx`
      (цепочка/размер/имя файла) + HEAD `/signatures/calibre-<ver>.dmg.sha512`.
- [ ] 3.1 `app/CalibreInstaller.swift`: `InstallPhase` (`idle, precheck, downloading(got,total),
      installing, verifying, activating, success, error(.network|.space|.install),
      agentActivationFailed, manual`) + `InstallStore: ObservableObject` (владелец — AppDelegate);
      re-entry guard + взаимоисключение с авто-апдейтом приложения (`isUpdateInFlight`).
- [ ] 3.2 Тест-защёлка (инвариант 6): mutating-оверрайды читаются одной функцией
      `testLatch() -> Latch?`; без `TEST_MODE=1` + канонизированного `TEST_ROOT`,
      содержащего install-root, — все игнорируются. Юнит на защёлку (env есть, латча нет → прод-пути).
- [ ] 3.3 Precheck: `volumeAvailableCapacityForImportantUsageKey` тома App Support ≥ 1,5 ГБ →
      иначе `.error(.space)` (текст «~1 ГБ» — design-spec). Порог — инжектируемая константа (тестам — маленькая).
- [ ] 3.4 OS-гейт: `ProcessInfo.operatingSystemVersion.majorVersion >= 14` → авто-путь; иначе
      `autoInstallSupported=false` → только manual-подача (D42). Никаких легаси-URL.
- [ ] 3.5 Download: СВОЯ реализация (не переиспользовать `UpdateChecker.downloadAndInstall` — нет
      прогресса/отмены/SHA; берём паттерн: downloadTask + delegate `didWriteData`, User-Agent,
      trust-gate hosts из инварианта 10). Файл → `App Support/fb2-to-epub/downloads/calibre.dmg`.
      Отмена: `task.cancel()` + стереть частичное → `idle`. Сбои (URLError/non-2xx/<50 МБ) → `.error(.network)`.
- [ ] 3.6 Версия: из `suggestedFilename`/финального URL (`calibre-(\d+\.\d+\.\d+)\.dmg`), фолбэк —
      GitHub API `releases/latest → tag_name`; иначе `.error(.install)`.
- [ ] 3.7 SHA-512 fail-closed: GET `https://calibre-ebook.com/signatures/calibre-<ver>.dmg.sha512`
      (128 hex) ↔ стриминговый `CryptoKit.SHA512` (чанки 4 МБ). Не совпало/недоступен → стереть DMG → `.error(.install)`.
- [ ] 3.8 Mount: `hdiutil attach downloads/calibre.dmg -nobrowse -readonly -plist -mountpoint
      downloads/mnt`; парсинг вывода `PropertyListSerialization` (не grep /Volumes); device id
      запомнить; detach по device id в defer: ретраи 1с/2с/4с → `-force`; неуспех detach НЕ фатален
      (лог + зачистка на следующем старте).
- [ ] 3.9 Пост-mount чек: `LSMinimumSystemVersion` из `mnt/calibre.app/Contents/Info.plist` ≤ текущая
      ОС; иначе `.error(.install)` (страховка OS-гейта против будущих сдвигов требований Calibre).
- [ ] 3.10 Staging: зачистить остатки (`calibre.app.installing`, `calibre.app.old`, `downloads/*`) →
      `ditto mnt/calibre.app → calibre.app.installing`.
- [ ] 3.11 Verify staged: `codesign --verify --strict --deep` + exec `Contents/MacOS/ebook-convert
      --version` (rc 0 + версия парсится) + исполняемость meta/polish. Провал → снести staging → `.error(.install)`.
      Quarantine НЕ снимаем (честный фэйл → manual).
- [ ] 3.12 Атомарный своп: существующая `calibre.app` → rename `.old`; `calibre.app.installing` →
      rename `calibre.app`; `rm -rf calibre.app.old`; зачистка DMG+mnt. Стартовая зачистка остатков —
      в init приложения (фоново).
- [ ] 3.13 Фикстура: `tests/make-fake-calibre-dmg.sh` — мини-`calibre.app` (3 стаб-CLI, отвечают на
      `--version`; Info.plist с LSMinimumSystemVersion) → `hdiutil create` → сайдкар `.sha512`.
      Замечание: стаб не проходит `codesign --verify` → в тест-режиме (под защёлкой) codesign-шаг
      заменяется маркером `FB2_CALIBRE_SKIP_CODESIGN=1` (тоже под защёлкой); живой e2e гоняет настоящий codesign.
- [ ] 3.14 `tests/run-calibre-install-tests.sh` — тест-бинарь (стиль ClearHistoryTests) в throwaway
      HOME под защёлкой: happy path (движок лёг, локатор его видит) + негативы: битый sha · DMG без
      calibre.app · verify-fail (стаб rc≠0) · нет места (порог↑) · отмена на середине (частичное стёрто) ·
      LSMinimumSystemVersion выше ОС · защёлка выключена → env игнорируются.

### Definition of Done
- Полный happy-path на fixture-DMG в throwaway HOME: `calibre.app` на месте, локатор возвращает
  app-owned, повторный запуск идемпотентен (staging-остатки зачищены).
- Все негативы дают ожидаемые `.error(...)` без мусора на диске (папка downloads пуста, staging снесён).
- Отмена и re-entry guard работают (двойной старт невозможен).

### Validation
```sh
cd "/Users/arrivarus/Documents/VibeCoding2/2026.06 fb2-to-epub"
curl -sIL https://calibre-ebook.com/dist/osx | grep -Ei 'HTTP/|location|content-length' # 3.0, вживую
tests/make-fake-calibre-dmg.sh /tmp/fake-calibre && ls /tmp/fake-calibre
tests/run-calibre-install-tests.sh
build/build-app.sh 0.10.0-dev
```

### Known Risks
- URLSession + file:// URL для фикстуры: прогресс-колбэки могут не прийти → тест прогресса на
  localhost-HTTP (python3 -m http.server) либо на моке delegate.
- Формат `-plist` у hdiutil стабилен, но парсер обязан переживать несколько entities (system-entities[]).
- `codesign --verify` staged-копии Calibre долгий (~секунды на 800 МБ) — допустимо внутри фазы verifying.

### Stop-and-Fix
Любой негатив-тест красный или мусор после отмены → чинить до CAL-4 (сшивка поверх дырявого
конвейера умножает стоимость).

---

## CAL-4. Сшивка: оживление, действия UI, D40-lifecycle `[ ]`

### Goal — что становится правдой
Кнопка «Установить Calibre» из любой подачи проводит весь путь до «агент заработал — уже берусь за
книги» без перезапуска приложения; провал запуска агента при установленном движке — отдельное
честное состояние с «Повторить запуск агента»; закрытие окна не прерывает установку (D40).

### Tasks
- [ ] 4.1 Активация (фаза `activating`, видимый текст — «Проверяю движок…», спека): plist есть →
      `runInstaller(watchDir: readWatchDir())`; нет → `firstRunSetupIfNeeded()`. Installer
      перепекает `CALIBRE_MACOS_DIR`/`EBOOK_*` → bootout→bootstrap→enable→kickstart.
- [ ] 4.2 Провал активации при живом движке → `agentActivationFailed` («Движок установлен, агент не
      запустился») + действие «Повторить запуск агента» = повтор 4.1 БЕЗ повторного скачивания;
      первая строка stderr installer'а — в лог.
- [ ] 4.3 `success` → 2с → `present(текущий экран)`: Status обычный / Setup зелёный; StatusStore
      перечитан; вотчеры state/watchDir ре-армятся штатным `present(.status)`.
- [ ] 4.4 Колбэки EngineSetupCard во всех 4 подачах: `onInstall / onCancel / onRetry / onManual /
      onOpenSite / onRecheck` (+ `onRetryActivation`); disabled-правила по flow.md §6.
      `onRecheck` («Проверить снова», manual-ветка): ре-проба локатора; нашёл движок → сразу 4.1
      (активация), не найдя — «пока не вижу движок».
- [ ] 4.5 D40-lifecycle: `applicationShouldTerminateAfterLastWindowClosed` → false при активной
      установке (download/install/verify/activating); reopen (`applicationShouldHandleReopen` /
      клик в Dock) показывает окно с текущим прогрессом; `applicationShouldTerminate`:
      downloading → NSAlert «Установка идёт — прервать?» [Продолжить установку]=default /
      [Прервать и выйти]=отмена+зачистка+terminate; installing/verifying/activating →
      `.terminateLater` + reply после ближайшей безопасной точки (конец свопа/зачистки).
- [ ] 4.6 Гибрид-подача жива: success убирает блокер/баннер; появление движка извне (юзер поставил
      вручную пока окно открыто) ловится focus-refresh (`refreshStatusNow` → calibrePresent).
- [ ] 4.7 Прогон всех состояний живыми руками на фикстуре (под защёлкой): happy, отмена, обрыв сети
      (выключить Wi-Fi на середине при live-URL / убить localhost-сервер), manual → Проверить снова,
      закрыть окно на середине скачивания → открыть из Dock (прогресс жив), Cmd-Q-диалог.

### Definition of Done
- Полный happy-path на фикстуре из окна: тап → прогресс → success → блокер исчез → бейдж зелёный
  «Активен» → (в throwaway-агенте) конвертация стаб-книги стартует от kickstart.
- Закрытие окна на середине скачивания не убивает процесс; повторное открытие показывает прогресс;
  Cmd-Q в download спрашивает; в installing — откладывает выход.
- `agentActivationFailed` достижим (сломать installer в тесте) и «Повторить запуск агента» чинит без скачивания.

### Validation
```sh
cd "/Users/arrivarus/Documents/VibeCoding2/2026.06 fb2-to-epub"
build/build-app.sh 0.10.0-dev
# изолированный UI-прогон (фикстура, throwaway HOME + тест-label):
TESTROOT="$(mktemp -d)"; tests/make-fake-calibre-dmg.sh "$TESTROOT/fx"
HOME="$TESTROOT/home" FB2_CALIBRE_TEST_MODE=1 FB2_CALIBRE_TEST_ROOT="$TESTROOT" \
  FB2_CALIBRE_DISABLE_SYSTEM=1 FB2_CALIBRE_SKIP_CODESIGN=1 \
  FB2_CALIBRE_DMG_URL="file://$TESTROOT/fx/calibre-fake.dmg" \
  FB2_CALIBRE_SHA512_URL="file://$TESTROOT/fx/calibre-fake.dmg.sha512" \
  FB2_AGENT_LABEL="com.arrivarus.fb2toepub.test.$$" \
  build/dist/fb2-to-epub.app/Contents/MacOS/fb2-to-epub
tests/run-calibre-install-tests.sh
tests/run-clear-history-tests.sh && tests/run-cover-job-tests.sh && tests/run-sticky-batch-test.sh
```

### Known Risks
- `HOME=`-подмена для UI-прогона: если NSHomeDirectory() её не уважает (см. Assumptions) —
  переключиться на «реальный home + защёлка + TEST_ROOT-install-root + FB2_AGENT_LABEL», НИКОГДА
  не трогая боевой label (урок 015).
- `.terminateLater` + reply — редкий путь AppKit; проверить руками оба исхода (double-Cmd-Q, reopen).
- Гонка «success пока юзер в Настройках» — store-driven рендер, `present` только текущего экрана.

### Stop-and-Fix
Любой из ручных прогонов 4.7 падает → чинить до CAL-5; жизненный цикл D40 — обещание человеку.

---

## CAL-5. Гейт релиза `[ ]`

### Goal — что становится правдой
Единственный обязательный ЖИВОЙ e2e (урок 016) подтверждает quarantine-гипотезу и работу настоящего
движка; UI совпадает со спекой; регрессия зелёная; доки честные. После этого — СТОП-точка человека.

### Tasks
- [ ] 5.1 `tests/run-calibre-live-e2e.sh` (только при `RUN_LIVE=1`; throwaway HOME + FB2_AGENT_LABEL):
      РЕАЛЬНОЕ скачивание `/dist/osx` (~330 МБ) → SHA-512 → mount/ditto/detach → НАСТОЯЩИЙ
      `codesign --verify --strict` → exec `--version` → своп → активация (тест-label) → конвертация
      реального .fb2 app-owned движком → ассерты: EPUB валиден, `xattr -l` на calibre.app БЕЗ
      `com.apple.quarantine`, `spctl -a -vv` accepted, plist указывает на app-owned пути.
- [ ] 5.2 Live-verify Юрки (computer-use, изолированный прогон из CAL-4 Validation): кликается весь
      флоу + D40-сценарии; финальный GREEN — только реальными руками (правило 3 CLAUDE.md).
- [ ] 5.3 Пиксель-чеклист design-reviewer: скриншоты всех состояний ↔ design-spec (≥1 несовпадение = FAIL).
- [ ] 5.4 Полная регрессия существующих наборов + новые наборы (список — test-plan.md §6).
- [ ] 5.5 README RU/EN: «движок ставится сам» (1 клик, куда ставим, что при ручной установке),
      примечание про uninstall (сносит и движок); changelog. Скриншоты онбординга.
- [ ] 5.6 СТОП-точка: показать человеку живой прогон + скриншоты → «выкладывай» → релиз (версию решает человек).

### Definition of Done
- `run-calibre-live-e2e.sh` прошёл на этой машине (лог сохранён в тест-выводе).
- Design-review PASS; регрессия 0 red; README/changelog смёржены в PR фичи.
- Явное «да» человека получено (гейт).

### Validation
```sh
cd "/Users/arrivarus/Documents/VibeCoding2/2026.06 fb2-to-epub"
RUN_LIVE=1 tests/run-calibre-live-e2e.sh
tests/run-calibre-locator-tests.sh && tests/run-calibre-locator-parity.sh && tests/run-calibre-hardcode-grep.sh
tests/run-calibre-install-tests.sh
tests/run-clear-history-tests.sh && tests/run-cover-job-tests.sh && tests/run-fb3-tests.sh \
  && tests/run-fb2-regression-test.sh && tests/run-sticky-batch-test.sh \
  && tests/run-update-install-test.sh && tests/run-cover-edit-test.sh
build/build-app.sh 0.10.0-dev
```

### Known Risks
- Живой e2e качает 330 МБ и зависит от сети/сайта Calibre — гонять один раз, осознанно (RUN_LIVE-гейт).
- `/dist/osx` может отдать версию новее ресёрча — конвейер version-agnostic, но сверить SHA-URL на месте.

### Stop-and-Fix
Живой e2e красный (например, quarantine всё-таки появился) → это опровержение гипотезы ресёрча:
СТОП, диагностика (debugger), доклад человеку — НЕ выпускать на стабах.
