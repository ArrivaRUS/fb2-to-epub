# Архитектура: онбординг Calibre (детект → автоустановка → оживление) — план Архитектора #1 (Claude)

> Входы: `research/calibre-auto-install.md` · `design/calibre-onboarding/flow.md` (+ макеты A/B) ·
> решения D37–D39 · код `app/*.swift`, `packaging/installer.sh`, `bin/fb2-to-epub-watcher.sh`.
> Контракты, которые план НЕ ломает: D13 (state.json пишет только агент), runner.sh неприкосновенен
> (FDA по байтам), plist через plutil (D5), label стабилен (D7).

---

## 0. Итог подхода

Один новый бизнес-компонент — **CalibreInstaller** (Swift, конвейер скачать→проверить→поставить→оживить)
с одним публикуемым состоянием (**InstallStore**, ObservableObject), которое рендерится в четырёх местах
(блокер B / баннер A / шаг Setup / строка Настроек) одним переиспользуемым вью **EngineSetupCard**.
Детект движка выносится в **единый контракт-резолвер CalibreLocator** (порядок: наша папка →
/Applications → ~/Applications; валидность = все 3 CLI), продублированный в Swift и в installer.sh
с parity-тестом; правда времени выполнения для агента остаётся прежней — абсолютные пути, запечённые
установщиком в plist. «Оживление» = повторный прогон существующего installer.sh (он же перепишет
env-пути и сделает bootout→bootstrap→kickstart) — нового механизма запуска агента не появляется.

---

## 1. Как устроено сейчас (факты из кода, на которые опирается план)

| Факт | Где |
|---|---|
| Проба приложения: `calibreInstalled()` = исполняемость ОДНОГО файла `/Applications/calibre.app/Contents/MacOS/ebook-convert` (путь — параметр init с дефолтом) | `app/EngineClient.swift:87,156-161` |
| installer.sh: детект `EBOOK_CONVERT` (env-оверрайд → `/Applications/...`), при отсутствии — exit 1; требует ВСЕ ТРИ CLI (convert+meta+polish); запекает абсолютные пути в plist `EnvironmentVariables` | `packaging/installer.sh:63-105,194-202` |
| Агент читает пути ТОЛЬКО из env plist'а; фолбэки `/Applications/...` в watcher — на случай ручного запуска | `bin/fb2-to-epub-watcher.sh:22,46,51` |
| Без движка watcher логирует `ebook-convert not found` и выходит; `launchctl print` при этом rc=0 → `agentActive == true` → бейдж «Активен» врёт | `watcher.sh:1238`, `EngineClient.agentStatus()` |
| Первый запуск без Calibre: `firstRunSetupIfNeeded()` → `.blockedNoCalibre`, installer НЕ запускался, plist'а нет; при переезде (Migration Assistant скопировал plist) — `.migratedExisting`, агент загружен, но мёртв | `EngineClient.swift:279-301` |
| SetupView рисует шаг «ДВИЖОК» зелёным даже при `calibreVersion == nil` | `SetupView.swift:150-169,246` |
| SettingsView уже различает nil/«✓»/версию, но строка — тупиковая инфо | `SettingsView.swift:88-225` |
| Live-обновление Status: `StatusStore` + refreshStatusNow (event-driven) — место для нового флага движка | `main.swift:509-694` |
| В репо есть проверенный образец скачивания DMG (URLSession downloadTask, trust-gate хостов, size-sanity) | `app/UpdateChecker.swift:198-287` |
| Env-оверрайды для тестов делаются в духе `FB2_*`; урок 015 — оверрайд НИКОГДА не на геттер, питающий инсталлер/запись plist | `HEARTBEAT.md`, `.patches/015` |

Закрываемая по пути дырка: сегодня проба приложения (1 файл) строже/слабее пробы инсталлера (3 файла) —
частичный Calibre даёт «в приложении зелено, installer падает». Новый резолвер требует все 3 CLI с обеих сторон.

---

## 2. Компонент 1 — детект: CalibreLocator (единая точка правды)

### 2.1 Контракт (фиксированный, документируется в обоих файлах)

Порядок кандидатов (первый валидный побеждает):

1. `~/Library/Application Support/fb2-to-epub/calibre.app/Contents/MacOS` — **наша копия (D39)**
2. `/Applications/calibre.app/Contents/MacOS` — системная установка пользователя
3. `~/Applications/calibre.app/Contents/MacOS` — идиоматичное пользовательское место (дёшево покрыть)

**Валидность локации** = все три файла существуют и исполняемы: `ebook-convert`, `ebook-meta`, `ebook-polish`.
PATH не сканируем (brew-cask всё равно кладёт .app в /Applications; PATH-магия = недетерминизм).

Почему наша копия первая: «оба существуют» возникает практически только когда системная копия была
отсутствующей/битой и мы поставили свою — тогда своя обязана победить; плюс детерминизм (поведение
не меняется от того, что пользователь позже сделает с /Applications). Если у пользователя валидный
/Applications-Calibre — мы просто никогда не ставим свою, конфликт не возникает.

### 2.2 Реализации контракта (две, с parity-тестом)

- **Swift**: `CalibreLocator.swift` — `static func resolve(home: String) -> CalibreLocation?`
  (`CalibreLocation { macosDir, ebookConvert, ebookMeta, ebookPolish, kind: .appOwned/.system/.userApplications }`).
  `EngineClient.calibreInstalled()`/`calibreVersion()` делегируют резолверу. Параметр init
  `ebookConvertPath` сохраняется как **явный тест-оверрайд** (`String? = nil`; nil → резолвер) —
  существующие тесты, передающие путь явно, не ломаются.
- **bash** (`packaging/installer.sh` §1): тот же порядок циклом по кандидатам; env-оверрайд
  `EBOOK_CONVERT` остаётся высшим приоритетом (текущее поведение). Валидность — те же 3 проверки
  (сейчас там уже есть проверка всех трёх — переиспользуется).
- **watcher** (`bin/fb2-to-epub-watcher.sh:22,46,51`): фолбэки-дефолты дополняются той же цепочкой
  (наша папка → /Applications). Косметика для ручных запусков — под launchd пути всегда приходят из plist.
- **Parity-тест** `tests/run-calibre-locator-parity.sh`: фикстурные деревья (только app-owned / только
  /Applications / оба / частичный без polish / ничего) → Swift-резолвер (через тест-бинарь) и
  bash-детект обязаны дать одинаковый ответ на каждом дереве.

**Правда для агента не меняется:** installer.sh по-прежнему запекает разрешённые абсолютные пути в
`EnvironmentVariables` plist'а. То есть «runtime-точка правды» одна — plist; CalibreLocator — точка
правды на момент детекта/установки. UI-проба и installer сходятся, потому что реализуют один контракт
(и это закреплено parity-тестом).

### 2.3 Оверрайд для верификации на машинах с Calibre

`FB2_CALIBRE_DISABLE_SYSTEM=1` (читают Swift-резолвер И installer.sh): пропустить кандидатов 2–3.
Безопасность по уроку 015: оверрайд меняет только ВЫБОР среди реальных валидных локаций и не питает
никакую запись путей «в никуда» — при протечке plist в худшем случае укажет на нашу реальную копию,
агент останется рабочим. Ни в какой геттер, влияющий на WatchPaths/WATCH_DIR, он не входит.

---

## 3. Компонент 2 — установщик: CalibreInstaller (Swift)

Новый файл `app/CalibreInstaller.swift` (+ `InstallStore` в нём же). Владелец — AppDelegate
(живёт весь ран, переживает навигацию экранов). Конвейер на серийной utility-очереди,
состояние публикуется на main.

### 3.1 Машина состояний (1:1 с flow.md §3/§6; внутренние фазы мельче, видимые — ровно как в UX)

```
idle(notInstalled)
  → precheck            // только ДИСК; сеть не префлайтим (fail-fast первым запросом)
  → downloading(got,total)   // видимое "Скачиваю Calibre… X из Y МБ · NN%", [Отмена]
  → installing               // видимое "Устанавливаю…": attach → ditto → detach (+sha до attach)
  → verifying                // видимое "Проверяю движок…": exec staged CLI + swap + ОЖИВЛЕНИЕ (§4)
  → success                  // "Готово! … агент заработал" → авто-возврат ~2с → idle-и-движок-есть
errors: .space | .network | .install   // из таблицы §6, каждая с [Повторить] и «Вручную»
manual                                  // экран-инструкция: [Открыть сайт] [Проверить снова]
```

Правила: `Отмена` доступна только в `downloading` (отменяет task, стирает частичный файл → idle).
`installing/verifying` неделимы (UX §6 так и говорит). Повтор из любой ошибки = полный рестарт
конвейера (идемпотентно за счёт зачистки staging). Re-entry guard как `isUpdateInFlight`
(плюс взаимоисключение с авто-апдейтом приложения: пока идёт одно — кнопка другого disabled).

### 3.2 Шаги конвейера

1. **Precheck (диск).** `volumeAvailableCapacityForImportantUsageKey` тома App Support ≥ **1.5 ГБ**
   → иначе `.space`. Реальный пик: DMG ~345 МБ + распакованный universal calibre.app ~700–800 МБ
   ≈ 1.1 ГБ (+запас). ⚠️ UX-текст «~500 МБ» занижен — см. открытый вопрос №1.
2. **Выбор URL по ОС.** Наш минимум — macOS 11; текущий Calibre требует macOS 14+ (ресёрч).
   `ProcessInfo.operatingSystemVersion`: ≥14 → `https://calibre-ebook.com/dist/osx` (latest);
   13 → пиннутый `https://download.calibre-ebook.com/7.26.0/calibre-7.26.0.dmg`; 11–12 → пиннутый
   6.29. Точные имена легаси-DMG сверить HEAD-пробой на этапе разработки (микрошаг CAL-0.2).
   Если пиннутый URL не отвечает → сразу `manual`.
3. **Скачивание.** `URLSession downloadTask` + delegate (`didWriteData` → прогресс; total из
   content-length, при −1 — indeterminate + счётчик МБ). Паттерн и trust-gate — из UpdateChecker
   (урок 006 «сначала проверенная реализация соседа»): https-only, allow-хосты `calibre-ebook.com`,
   `download.calibre-ebook.com`, `github.com`, `*.githubusercontent.com` (редирект-цепочка /dist/osx).
   Файл → `App Support/fb2-to-epub/downloads/calibre.dmg` (папка наша, app-owned).
   **Докачки/resume в MVP нет** — «Повторить» качает заново (простота > хрупкая правильность, урок 006).
   Сетевые сбои (URLError, non-2xx, size < 50 МБ) → `.network`.
4. **Определение версии** (нужно для эталона SHA): имя финального файла из redirect-цепочки
   (`response.suggestedFilename` / последний URL) → regex `calibre-(\d+\.\d+\.\d+)\.dmg`;
   не распарсилось → фолбэк GitHub API `releases/latest → tag_name`; и это не вышло → `.install`.
5. **SHA-512 (fail-closed).** GET `https://calibre-ebook.com/signatures/calibre-<ver>.dmg.sha512`
   (128 hex) → сверка со стриминговым SHA-512 файла (CryptoKit, чанки 4 МБ; macOS 11 ок).
   Эталон недоступен или не совпал → стереть DMG → `.install` («битый файл»). GPG — вне MVP
   (ресёрч: опция «максимальной строгости»; SHA-512 по HTTPS с сайта вендора достаточно).
6. **Установка (installing).**
   - зачистить остатки прошлых попыток: `calibre.app.installing`, `calibre.app.old`, `downloads/mnt`;
   - `hdiutil attach downloads/calibre.dmg -nobrowse -readonly -mountpoint <AppSupport>/downloads/mnt`
     (свой mountpoint → нет гонок имён в /Volumes);
   - `ditto <mnt>/calibre.app <AppSupport>/calibre.app.installing` (ditto сохраняет подпись/права);
   - `hdiutil detach` с ретраями 1с/2с/4с, затем `-force`; **неуспех detach НЕ валит установку**
     (копия уже снята; лог + зачистка на следующем запуске) — известные зависания detach, урок 006;
   - ошибки attach/ditto → `.install`; ENOSPC по дороге → `.space`.
7. **Проверка (verifying).** На staged-копии: exec `Contents/MacOS/ebook-convert --version`
   (rc 0 + парсится версия) + исполняемость meta/polish. Это же — живая проверка гипотезы
   quarantine/Gatekeeper в момент установки, а не при первой конвертации. Провал → снести staging → `.install`.
   Quarantine принудительно НЕ снимаем (xattr -dr не делаем): по ресёрчу URLSession без sandbox его
   не ставит, Calibre нотаризован; честный фэйл → `manual`.
8. **Атомарный своп.** Есть старая `calibre.app` → rename в `calibre.app.old`; rename
   `calibre.app.installing` → `calibre.app`; `rm -rf calibre.app.old`. Всё в одной папке одного
   тома → rename атомарен; любое падение оставляет либо старую, либо новую валидную копию + мусор,
   который зачищается на старте следующей попытки/запуска.
9. **Зачистка.** Удалить `downloads/calibre.dmg` и mnt. (Также фоновая зачистка `.installing/.old/downloads/*`
   при старте приложения — восстановление после крэшей, дёшево.)
10. **Оживление** — §4 (внутри видимой фазы `verifying`, отдельного UX-состояния не добавляем).

### 3.3 Закрытие окна во время установки (открытый вопрос flow.md §10.3 — моё предложение)

Окно одно, `applicationShouldTerminateAfterLastWindowClosed = true` → закрытие = выход = смерть
загрузки. Предлагаю: **NSWindowDelegate.windowShouldClose**: если фаза ∈ {downloading, installing,
verifying} → NSAlert «Установка движка ещё идёт. Прервать?» [Продолжить установку] (default) /
[Прервать и закрыть] → cancel + зачистка + закрыть. Фоновое докачивание без окна отвергаю:
противоречит модели «окно-приложение», а оживление агента всё равно требует живого процесса.
Это ответ по умолчанию — ждёт «да» человека (см. открытые вопросы).

---

## 4. Компонент 3 — оживление агента после установки

Ветвление по `plistExists()` (обе ветки — существующие каналы, нового механизма нет):

- **plist есть** (переезд: Migration Assistant принёс plist, агент загружен, но мёртв):
  `engine.runInstaller(watchDir: readWatchDir() ?? дефолт)` → installer.sh с обновлённым детектом
  (§2.2) находит **нашу** копию → перезапекает `EBOOK_CONVERT/META/POLISH` в plist →
  bootout→bootstrap→enable→kickstart. RunAtLoad + kickstart → watcher сразу разбирает уже лежащие
  книги («уже берусь за книги в папке» — честно).
- **plist'а нет** (свежий Mac, история `.blockedNoCalibre`): `engine.firstRunSetupIfNeeded()` —
  теперь проба проходит → `.installedDefault` (installer ставит дефолтную папку, как задумано M1).

Провал installer.sh на этом шаге (например, нет python3 → нет Xcode CLT; это существующий
пограничный случай продукта, не новый) → `.install` с первой строкой stderr в лог; UI — общая
ошибка + «Вручную». Успех → success; UI оживает **без перезапуска приложения**: store-driven
(§5), после success — `present(текущий экран)` → StatusStore перечитывает всё, вотчеры
`startStateWatcher/startWatchDirWatcher` ре-армятся штатно через `present(.status)`.

D13 не трогается: установщик пишет ТОЛЬКО в app-owned места (`downloads/`, `calibre.app*`),
агент дергается только через installer.sh/kickstart — уже санкционированные каналы. `state.json`
не читается и не пишется установщиком вовсе.

---

## 5. Компонент 4 — UI-интеграция (гибрид D37, честность экранов)

### 5.1 Общий вью EngineSetupCard (одно состояние — четыре подачи)

`app/EngineSetupCard.swift`: рендерит `InstallStore.phase` в вариантах
`.blocker` (напр. B, полноэкранно вместо контента Status) · `.banner` (напр. A, карточка под шапкой) ·
`.setupStep` (янтарный шаг «ДВИЖОК» с CTA) · `.settingsRow` (компактная строка с [Установить]/прогрессом/[Повторить]).
Тексты/кнопки — строго таблица flow.md §6 (включая disabled-правила и «пока не вижу движок» в manual).
Действия — колбэки в AppDelegate: `onInstall` (старт конвейера), `onCancel`, `onRetry`,
`onManual`, `onOpenSite` (NSWorkspace → calibre-ebook.com), `onRecheck` (ре-проба резолвера).

### 5.2 Точки врезки

- **StatusStore** (+2 поля): `calibrePresent: Bool` и подписка на InstallStore. `refreshStatusNow()`
  дополняется `store.calibrePresent = engine.calibreInstalled()` — проба дешёвая (3×stat, БЕЗ спавна
  процессов; `--version` зовём только там, где показываем номер версии).
- **StatusView**: `!calibrePresent` → гибрид D37: `hasHistory` → баннер A над обычным контентом
  (кольцо/бейджи приглушены), иначе блокер B вместо контента. `hasHistory :=
  state.totals.convertedTotal > 0 || !state.recent.isEmpty` — тот же сигнал, что `noHistory` в
  `shouldShowSetup` (выносится в один helper, чтобы не разъехались).
- **Бейдж агента (честный):** `calibrePresent ? (agentActive ? «Фоновый агент Активен» : «…На паузе»)
  : янтарный «Конвертация недоступна»`; футер-строка агента — «Нет движка». Цветовая пара — янтарь
  из токенов (как step-cur в Setup).
- **SetupView**: шаг «ДВИЖОК» ветвится по `calibreVersion == nil`: янтарный номер-кружок,
  «Calibre не найден · нужен для конвертации», CTA через EngineSetupCard(.setupStep);
  приветствие «Почти готово», футер «Ожидает движок». Флаг `didShowSetup` не переосмысляем:
  после первого показа Setup последующие запуски ведут в Status, где тот же CTA несёт блокер B.
- **SettingsView**: строка Calibre становится stateful (EngineSetupCard(.settingsRow));
  установленный движок — как сегодня, инфо-строка с версией (версию берём от резолвнутой локации).
- **Роутинг main.swift**: не меняется структурно; `blockedNoCalibre` больше не «тихий» — его
  видимость обеспечивают сами экраны по `calibrePresent`. После success из фазы установки —
  `present(currentScreen)` (+ Setup сам перерисуется зелёным).

---

## 6. Обновления Calibre и сосуществование — решение по скоупу

**Обновления нашей копии — ВНЕ MVP.** Обоснование: (1) наши 3 CLI-вызова стабильны между версиями
Calibre; (2) копия не деградирует со временем, security-поверхность локальной CLI-конвертации мала;
(3) механизм «снести и поставить заново» уже заложен (атомарный своп поверх существующей копии,
§3.2.8) — фича апдейта позже добавляется как «проверить версию → тот же конвейер», без перестройки.
В Настройках версия видна уже сейчас — этого достаточно для MVP.

**Сосуществование с /Applications/calibre.app:** чужую копию не трогаем никогда (ни удалить, ни
обновить — и по этике, и из-за TCC App Management). Резолвер предпочитает нашу; снёс пользователь
нашу руками → на следующем запуске резолвер честно падает на его копию или в онбординг.
`uninstall.sh` уже делает `rm -rf "$APP_SUPPORT"` → наша копия движка удаляется вместе с нами
(поведение согласовано, отдельной правки не нужно; упомянуть в README).

---

## 7. Тестируемость (без 330 МБ) + обязательный живой прогон (урок 016)

### 7.1 Стабы и оверрайды (только новый код; патч-015-safe)

| Env | Что делает | Почему безопасно |
|---|---|---|
| `FB2_CALIBRE_DMG_URL` | подменить URL DMG (file:// на фикстуру) | читается только CalibreInstaller'ом |
| `FB2_CALIBRE_SHA512_URL` | подменить URL эталона (file://) | то же |
| `FB2_CALIBRE_DISABLE_SYSTEM=1` | резолвер/installer игнорируют /Applications и ~/Applications | меняет только выбор реальных локаций, записи путей не питает (§2.3) |
| `FB2_FORCE_INSTALL_STATE` | оверлей фазы для скриншотов (`downloading:94/210` и т.п.), зеркало FB2_FORCE_BATCH | display-only, на диск не пишет |

Назначение установки отдельного оверрайда НЕ получает — оно выводится из `home`, который в
EngineClient уже инжектится (throwaway-HOME-харнесс существует).

### 7.2 Пирамида

1. **Unit (Swift)**: резолвер по фикстурным деревьям (5 кейсов §2.2) · SHA-512 на известном векторе ·
   парс версии из имени файла/redirect · маппинг ошибок URLError→.network/.space/.install ·
   precheck-порог.
2. **Fixture-DMG интеграция** (`tests/make-fake-calibre-dmg.sh` создаёт мини-calibre.app с тремя
   стаб-CLI, отвечающими на `--version`, + `hdiutil create` + сайдкар .sha512): полный конвейер в
   throwaway HOME + throwaway label — скачал(file://)→sha→attach→ditto→verify→swap→installer.sh
   (FB2_SRC_DIR+HOME) → assert: `calibre.app` на месте, plist env указывает на app-owned пути,
   агент (тестовый label) bootstrapped. Плюс негативы: битый sha, DMG без calibre.app, отказ verify.
3. **Parity-тест** резолвера bash↔Swift (§2.2).
4. **UI-состояния**: скриншоты всех строк таблицы §6 через FB2_FORCE_INSTALL_STATE (блокер/баннер/Setup/Настройки).
5. **Живой e2e — ОБЯЗАТЕЛЕН, ровно 1 прогон перед релизом** (урок .patches/016: стабы не ловят
   реальную порчу): `tests/run-calibre-install-live-e2e.sh` (запуск только с `RUN_LIVE=1`):
   throwaway HOME + label, РЕАЛЬНОЕ скачивание с `/dist/osx` (~330 МБ), реальный SHA-512, реальные
   hdiutil/ditto/verify, затем реальная конвертация одного FB2 через app-owned движок; ассерты
   `xattr -l` (нет com.apple.quarantine) и `spctl -a -vv` на скопированном .app — полевое
   подтверждение quarantine-гипотезы ресёрча. Плюс живой UI-прогон Юрки (computer-use) с
   `FB2_CALIBRE_DISABLE_SYSTEM=1` + фикстурным URL — кликается весь флоу, включая Отмену и ошибки.

---

## 8. Порядок сборки (майлстоуны по зависимостям + микрошаги)

Зависимости: CAL-1 (контракт детекта) — фундамент всего; CAL-2 (честный UI) зависит только от CAL-1;
CAL-3 (конвейер) независим от CAL-2 (можно параллелить); CAL-4 сшивает; CAL-5 гейтит релиз.
Всё уходит одним релизом (честный UI без кнопки в проде не показываем).

**CAL-0 — полевые пробы (дев-тайм, до кода)**
- 0.1 HEAD-проба `/dist/osx` + `/signatures/<file>.sha512` сегодня (URL живы, размер совпадает с ресёрчем).
- 0.2 HEAD-проба легаси-DMG для macOS 11–13 (точные имена 7.26.0/6.29.0) → зафиксировать в константах.
  Риск: имена не подтвердятся → легаси-ветка сужается до `manual` (решение на месте, см. вопрос №3).

**CAL-1 — CalibreLocator (контракт детекта)**
- 1.1 `app/CalibreLocator.swift`: типы + resolve() + FB2_CALIBRE_DISABLE_SYSTEM.
- 1.2 EngineClient: `ebookConvertPath` → опциональный оверрайд; calibreInstalled/calibreVersion через резолвер.
- 1.3 installer.sh §1: цикл кандидатов (env-оверрайд сверху) + FB2_CALIBRE_DISABLE_SYSTEM.
- 1.4 watcher: фолбэк-цепочка дефолтов (наша папка → /Applications).
- 1.5 `tests/run-calibre-locator-parity.sh` + Swift-юниты резолвера.
- Риск шага: сломать существующие тесты, передающие ebookConvertPath — прогнать текущие наборы (104+ шт.).

**CAL-2 — честный UI (read-only)**
- 2.1 StatusStore.calibrePresent + refreshStatusNow + helper hasHistory (общий с shouldShowSetup).
- 2.2 Бейдж/футер агента: ветка «Конвертация недоступна»/«Нет движка».
- 2.3 SetupView: янтарная ветка шага «ДВИЖОК» + «Почти готово»/«Ожидает движок».
- 2.4 SettingsView: строка Calibre — ветка not-installed (пока CTA-заглушка, оживёт в CAL-4).
- 2.5 Скелет EngineSetupCard: state → верстка по макетам A/B (без действий).
- Риск: refit высоты окна при появлении/уходе баннера/блокера — тот же путь, что у cover-строки
  (present/refitWindowHeight), кейсы из .patches/011/013 проверить на макс/мин контенте.

**CAL-3 — CalibreInstaller (конвейер, без UI)**
- 3.1 InstallStore + фазы + re-entry guard (+взаимоисключение с авто-апдейтом).
- 3.2 Precheck диска (порог константой; см. вопрос №1).
- 3.3 Выбор URL по ОС (константы из CAL-0.2).
- 3.4 Download: downloadTask + delegate-прогресс + Отмена + trust-gate + переезд файла в downloads/.
- 3.5 Версия из suggestedFilename/redirect + фолбэк GitHub API.
- 3.6 SHA-512: fetch эталона + стриминговый хеш + fail-closed.
- 3.7 attach → ditto → detach(ретраи/-force, не-фатален) → verify staged CLI → атомарный своп → зачистка.
- 3.8 Зачистка остатков на старте приложения (`.installing/.old/downloads/*`).
- 3.9 Fixture-харнесс (make-fake-calibre-dmg.sh) + интеграционные тесты конвейера (+негативы).
- Риск: verify staged-CLI на CI/чужой машине зависит от macOS-версии Calibre — в fixture-тестах CLI стабовые.

**CAL-4 — сшивка: оживление + действия UI**
- 4.1 Ветка оживления (runInstaller vs firstRunSetupIfNeeded) внутри фазы verifying.
- 4.2 Колбэки EngineSetupCard → AppDelegate (install/cancel/retry/manual/site/recheck) во всех 4 подачах.
- 4.3 success → 2с → present(текущий экран); Setup перерисовывается зелёным; Status — обычным.
- 4.4 windowShouldClose-гард с подтверждением (по ответу на вопрос №2).
- 4.5 FB2_FORCE_INSTALL_STATE + скриншоты всех состояний §6 (дизайн-ревью пиксель-в-пиксель).
- Риск: гонка «success пришёл, пока пользователь в Настройках» — store-driven рендер везде, present
  только текущего экрана (не насильственная навигация).

**CAL-5 — гейт релиза**
- 5.1 Живой e2e (RUN_LIVE=1) — 1 прогон, ассерты xattr/spctl/конвертация (§7.2.5).
- 5.2 Живой UI-прогон Юрки (computer-use, FB2_CALIBRE_DISABLE_SYSTEM=1 + фикстура): happy path,
  Отмена, обрыв сети (выключить Wi-Fi на середине), manual → «Проверить снова».
- 5.3 Регрессия существующих наборов (clear-history 104, cover-job 40, fb3 25, sticky-batch 30).
- 5.4 README RU/EN: «движок ставится сам» + примечание про uninstall; changelog.

---

## 9. Риски и альтернативы

| # | Риск | Вероятность/цена | Митигация в плане |
|---|---|---|---|
| R1 | macOS < 14: latest-Calibre не заведётся (наш минимум 11.0) | низкая (у целевой аудитории свежие маки), цена высокая (битая установка) | гейт по ОС → пиннутые легаси-URL, пробы CAL-0.2; не подтвердится → `manual` для старых ОС |
| R2 | Форма redirect-цепочки `/dist/osx` изменится → версия не парсится → SHA не сверить | низкая | фолбэк GitHub API tag_name; дальше честный `.install` + manual; версионированное зеркало download.calibre-ebook.com как запасной URL |
| R3 | Зависание `hdiutil detach` (наблюдалось в проекте, урок 006) | средняя | detach не-фатален: ретраи → -force → лог; установка засчитывается по факту скопированной+проверенной копии |
| R4 | Порог места: UX-текст 500 МБ vs реальный пик ~1.1 ГБ | точно случится у части пользователей | precheck 1.5 ГБ + синхронизация текста (вопрос №1) — иначе `error/space` посреди установки |
| R5 | Quarantine-гипотеза (curl/URLSession без карантина) не подтвердится на живой машине | низкая (ресёрч high), цена средняя | verify-шаг ловит ДО объявления успеха; живой e2e с xattr/spctl — гейт релиза; фолбэк manual |
| R6 | Частичный/битый staged-своп при крэше | низкая | staging+rename в одной папке; зачистка `.installing/.old` на старте; повтор идемпотентен |
| R7 | Свежий Mac без Xcode CLT: `/usr/bin/python3` дернёт системный диалог установки CLT | средняя (существующий кейс продукта, не новый) | оживление честно даст `.install` + manual; в план не тащим (отдельная фича), но фиксируем в известных ограничениях |
| R8 | Расхождение двух реализаций детекта (Swift vs bash) со временем | средняя | parity-тест в постоянном наборе + контракт-комментарий в обоих файлах |
| R9 | Юзер запустил установку и ушёл в другие экраны/закрыл окно | средняя | store у AppDelegate (переживает навигацию); windowShouldClose-гард (вопрос №2) |

Альтернативы, которые я осознанно отверг: докачка/resume (сложность без нужды — канал обычно
позволяет 330 МБ за минуты, retry дешевле багов) · GPG-верификация (SHA-512 по HTTPS достаточно
для MVP, ресёрч согласен) · единый детект «Swift зовёт installer.sh --detect» (спавн процесса в
каждом refreshStatusNow — дороже и грязнее, чем parity-тест на 3 кандидата) · фоновая загрузка
после закрытия окна (ломает модель приложения) · установка в /Applications (отвергнута ещё в D39).

---

## 10. Соответствие требованиям (самопроверка)

- Детект: порядок + единая правда → §2 (app и агент сходятся через контракт+plist). ✔
- Установщик: URL/прогресс/отмена/SHA-512/hdiutil/ditto/атомарность/зачистка/ретраи/ошибки → §3. ✔
- Закрытие окна во время скачивания: предложено поведение → §3.3 (+вопрос №2). ✔
- Оживление без перезапуска: §4 (installer.sh re-run + kickstart + store-driven UI). ✔
- UI: гибрид D37, честные Setup/Настройки/бейдж, state-машина ↔ StatusStore/роутинг, D13 цел → §5. ✔
- Обновления/сосуществование: решено и обосновано → §6. ✔
- Тестируемость: стабы в духе FB2_* + 1 обязательный живой прогон (урок 016) → §7. ✔
- Микрошаги с порядком и рисками → §8. Состояния loading/empty/error — таблица §6 flow.md,
  все отражены в фазах и подачах. Оверинжиниринга нет: 3 новых файла Swift
  (CalibreLocator, CalibreInstaller, EngineSetupCard) + точечные правки существующих.

## 11. Открытые вопросы к человеку

1. **Порог/текст места:** ставлю precheck 1.5 ГБ и текст «Нужно ~1 ГБ свободного места» вместо
   «~500 МБ» из макетов (реальный пик ~1.1 ГБ). Ок?
2. **Закрытие окна во время установки:** подтверждающий диалог «Прервать/Продолжить», отмена и
   зачистка при «Прервать» (без фоновой докачки). Ок?
3. **macOS 11–13:** ставить пиннутые легаси-версии Calibre (7.26/6.29) или сразу вести «Вручную»?
   Рекомендую пиннутые с фолбэком в manual, если пробы CAL-0.2 подтвердят URL.
