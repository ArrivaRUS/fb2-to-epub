# Ресёрч: упаковка и дистрибуция fb2-to-epub (macOS), 2026

> Researcher → Юрке. Фаза планирования: выбрать стек для перехода
> `git clone + install.sh` → «скачал .dmg → запустил .app → выбрал ЛЮБУЮ папку → автоконвертация».
> Дата: 2026-06-23. Бэкенд поиска: Яндекс Search API (SEARCH_TYPE_COM) + WebFetch первоисточников.
> Каждый факт — источник + уверенность (high/med/low).

---

## Итог (2–4 строки)

Для v1 минимальный риск/усилие даёт **AppleScript-приложение** (`choose folder` + `do shell script`,
экспорт из Script Editor в `.app`) или **Platypus** как обёртка существующего shell-скрипта — оба
**не требуют Xcode/Swift** и переиспользуют готовый watcher. DMG собирать через **`create-dmg`
(npm, sindresorhus)** или чистый `hdiutil`. Главный барьер дистрибуции — **не сборка, а Gatekeeper
в macOS 15+**: без платной подписи Apple ($99/год) + нотаризации пользователь упрётся в блокировку и
ручной обход через **System Settings → Privacy & Security → Open Anyway** (ПКМ→Открыть в Sequoia
больше не работает). Calibre оставить **внешней зависимостью** с паттерном «детект → подсказать
`brew install --cask calibre`»; встраивать движок не стоит (размер + GPL).

---

## Тема 1. Минимальное macOS-приложение (выбор папки + установка launchd-агента)

Сравнение 4 подходов. Все должны: (а) показать диалог выбора папки, (б) записать per-user LaunchAgent
с `WatchPaths` на выбранный путь и (пере)загрузить его.

| Подход | Нужен Xcode? | Размер | Сложность сборки (вкл. CI без GUI) | UX | Как ставит launchd | Риски / поддержка |
|---|---|---|---|---|---|---|
| **AppleScript .app** (`choose folder` + `do shell script`, экспорт из Script Editor → File→Export→Application) | **Нет** | КБ | Очень низкая; экспорт скриптуем через `osacompile` (CLI, без GUI) | Нативный системный диалог выбора папки; запуск двойным кликом | Скрипт зовёт shell, который пишет plist и делает `launchctl bootstrap` | Встроено в macOS, но «олдскул»; нет современного UI; авторизация прав — через сам диалог |
| **Platypus** (обёртка shell/python → .app, бинарь-лаунчер) | **Нет** (бинарь `platypus_clt` ставится в `/usr/local/bin` без сборки из исходников) | Слим app-бинарь + твой скрипт (КБ–сотни КБ) | Низкая; `platypus_clt` поддерживает все флаги GUI, интегрируется в CI/CD | Можно «прогресс-бар»/текстовый вывод; кнопки. Диалог папки — через сам скрипт (`osascript choose folder`) | Скрипт делает всю работу: plist + `launchctl` | Зрелый (v5.5.0, релиз 2025-12-02), Universal Intel/ARM, требует macOS 11+; зависимость от стороннего тула; ad-hoc подпись лаунчера |
| **Нативный SwiftUI .app** (`NSOpenPanel`/`fileImporter`) | **Да** (Xcode + Swift) | Несколько МБ | Высокая; CI нужен macOS-раннер с Xcode (GitHub Actions `macos-latest` умеет, но дольше/сложнее) | Лучший, «настоящее приложение»; нативный `fileImporter` | Из Swift пишем plist и зовём `launchctl` через `Process` | Будущее-устойчиво, но overkill для утилиты; самый дорогой путь |
| **Menu-bar resident** (SwiftUI `MenuBarExtra`, `LSUIElement=true`, без Dock-иконки) | **Да** (Xcode + Swift) | Несколько МБ | Высокая (как SwiftUI) | Резидент в меню-баре: статус, пауза, смена папки — удобно для «фонового конвертера» | Тот же `launchctl` из Swift; либо сам резидент следит за папкой (FSEvents) вместо launchd | Лучший UX для долгоживущего фонового тула, но самый дорогой; стоит для v2 |

Находки/риски (Тема 1):
- **AppleScript умеет и выбор папки, и shell**: `set theFolder to (choose folder)` + `do shell script`,
  экспорт в `.app` через File→Export (формат Application). Источник:
  https://discussions.apple.com/thread/6890578 ,
  https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/CallCommandLineUtilities.html — **уверенность high**.
- Экспорт AppleScript в .app скриптуем (CLI `osacompile -o App.app script.applescript`), т.е. **CI без GUI возможен**.
  Источник: https://apple.stackexchange.com/questions/206416/applescript-to-export-script-editor-script-as-application — **med** (статья про GUI-экспорт; `osacompile` — общеизвестный CLI, но конкретного гайда в выдаче нет).
- **Platypus**: «creates native Mac applications from command line scripts (shell, Python, …), wrapping
  the script in an application bundle along with a slim app binary». CLI `platypus_clt` повторяет все
  возможности GUI и **интегрируется в CI/CD**. Бинарь можно поставить **без сборки из исходников**
  (Xcode нужен только чтобы собрать сам Platypus, не приложения). Universal Intel/ARM, требует **macOS 11+**.
  Последняя версия **5.5.0 (2025-12-02)** — живой проект.
  Источники: https://github.com/sveinbjornt/Platypus , https://sveinbjorn.org/platypus ,
  https://github.com/sveinbjornt/Platypus/releases , https://deepwiki.com/sveinbjornt/Platypus — **уверенность high**.
- **SwiftUI `MenuBarExtra`** — штатный способ menu-bar утилит; скрытие Dock-иконки делается отдельно
  через `LSUIElement` (он же «Application is agent») в Info.plist. Источники:
  https://developer.apple.com/documentation/swiftui/menubarextra ,
  https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/ ,
  https://yourstash.ai/articles/macos-menu-bar-app-swift (раздел «Decision 3: LSUIElement and the Dock») — **уверенность high**.
- Любой shell/AppleScript-подход можно «сделать .app» вручную (положить скрипт в
  `App.app/Contents/MacOS/`), но это хрупко без Info.plist/иконки — Platypus/AppleScript это делают правильно.
  Источник: https://apple.stackexchange.com/questions/224394/ — **med**.

---

## Тема 2. Сборка DMG (2026)

| Инструмент | Что даёт | Команда | Подпись/нотаризация | Зависимости |
|---|---|---|---|---|
| **`create-dmg` (npm, sindresorhus)** | «Good-looking DMG за секунды»: авто-layout, фон, символьная ссылка на /Applications, позиционирование иконок | `create-dmg <app> [destination]` | Пытается подписать DMG (не критично если упадёт); флаг `--no-code-sign` для CI; флаг `--identity=`. **Нотаризацию делаешь отдельно** | Node.js ≥ 20; результат работает на macOS ≥ 10.13 |
| **`create-dmg` (shell, andreyvit / create-dmg)** | «Shell script to build fancy DMGs»: фон-картинка, позиции иконок, размер окна, симлинк на Applications | `create-dmg --volname ... --background ... --icon ... app.dmg source/` | Не подписывает сам; подпись/нотаризация — отдельно | Чистый bash + системные утилиты |
| **Чистый `hdiutil`** | Полный контроль, без зависимостей; нужно вручную: смонтировать rw, разложить, выставить фон/иконку через AppleScript к Finder, `hdiutil convert` в сжатый ro | `hdiutil create ...` / `hdiutil convert ...` | Ничего не делает за тебя | Только система |

Находки/риски (Тема 2):
- `create-dmg` (npm): «Create a good-looking DMG for your macOS app in seconds»; install
  `npm install --global create-dmg`; usage `create-dmg <app> [destination]`; опции `--overwrite`,
  `--no-version-in-filename`, `--identity=`, `--dmg-title=`, **`--no-code-sign`** (удобно в CI);
  требует **Node.js ≥ 20**; «**Don't forget to notarize your DMG**» (нотаризация — отдельный шаг).
  Источник: https://github.com/sindresorhus/create-dmg — **уверенность high**.
- Типовое оформление DMG (фон-картинка, иконка тома, симлинк на `/Applications`, позиционирование) —
  устоявшийся паттерн; обзор современных подходов: https://zgcoder.net/ramblings/modern-dmgs/ ,
  классический Q&A по «nice-looking DMG из CLI»: https://stackoverflow.com/questions/96882/ — **уверенность high**.
- Shell-`create-dmg` (andreyvit) — «A shell script to build fancy DMGs», без Node-зависимости.
  Источник: https://git-stars.org/blog/summaries/create-dmg/create-dmg — **med** (репо известное; вторичный источник).
- Риск пользователя: «образ диска повреждён» при открытии .dmg часто = тот же Gatekeeper/quarantine,
  а не битый файл. Источник: https://mac-soft.ru/blog/obraz-diska-povrezhden-dmg-ne-otkryvaetsya — **med**.

**Best practice:** для CI собирать `create-dmg ... --no-code-sign`, затем (если есть Developer ID)
подписать и нотаризовать готовый DMG отдельным шагом, потом `stapler staple` по DMG.

---

## Тема 3. Дистрибуция БЕЗ платного Apple Developer ID — что увидит пользователь (macOS 15+)

Это **главный барьер** и он ужесточился. Точные факты:

- **macOS 15 Sequoia убрал обход ПКМ→Открыть.** Дословно (Apple, цит. по iDownloadBlog):
  «In macOS Sequoia, users will no longer be able to **Control-click to override Gatekeeper** when
  opening software that isn't signed correctly or notarized.» Теперь путь один:
  **System Settings → Privacy & Security → (внизу) Open Anyway → Open**. Делается **только при первом
  запуске**, дальше приложение открывается без алертов.
  Источник: https://www.idownloadblog.com/2024/08/07/apple-macos-sequoia-gatekeeper-change-install-unsigned-apps-mac/ — **уверенность high**.
- **macOS 15.1 ещё жёстче / «Apple Forces Signing».** «Starting with macOS Sequoia 15, the easy
  bypassing of this feature … is now no longer an option», 15.1 закрывает обходы сильнее.
  ВНИМАНИЕ-противоречие (см. ниже): часть комментаторов считает, что в 15.1 секция Open Anyway
  «не появляется как задумано» — возможно баг.
  Источник: https://hackaday.com/2024/11/01/apple-forces-the-signing-of-applications-in-macos-sequoia-15-1/ — **med**.
- **Типичные формулировки Gatekeeper, которые увидит юзер** (по обзору ошибок):
  - «**"[App Name]" was blocked to protect your Mac**» — Gatekeeper заблокировал; нужен обход через System Settings.
  - «**"[App]" can't be opened because Apple cannot check it for malicious software**» (вариант для unidentified developer).
  - «**"[App]" is damaged and can't be opened. You should move it to the Trash**» — частый кейс для
    **скачанного неподписанного/ad-hoc** .app с выставленным `com.apple.quarantine`.
  Источники: https://cloudhousetechnologies.com/blog/mac-app-cannot-be-opened-gatekeeper-fix ,
  https://www.itech4mac.net/2021/01/fix-the-application-is-damaged-and-cant-be-opened/ — **уверенность med-high**.
- **Атрибут `com.apple.quarantine`** вешается на всё скачанное из интернета; Gatekeeper при первом
  запуске проверяет подпись/нотаризацию. Источник:
  https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5 — **уверенность high**.

### Честные способы снизить трение БЕЗ подписи
- **Инструкция «Open Anyway»**: первый запуск → System Settings → Privacy & Security → Open Anyway → Open
  (на 15+ это основной путь, ПКМ→Открыть мёртв). **high**.
- **`xattr -dr com.apple.quarantine /Applications/App.app`** — снимает карантин, продолжает работать в
  Sequoia. Подходит для технически грамотных; в README + можно зашить в установочный шаг.
  Источники: https://github.com/mariopepe/KindleAdRemover/issues/12 ,
  https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5 — **high**.
- **Ad-hoc подпись `codesign --force --deep --sign - App.app`** — снимает «is damaged» **на машине сборки**,
  НО важное ограничение ниже. **high (с оговоркой)**.
  - ⚠️ **Ключевой нюанс:** «Ad-hoc signed code only works (without user intervention) on the local
    machine that built it. If you copy an ad-hoc signed executable to another computer, macOS will kill
    it … an ad-hoc signed executable needs to be interactively opened via Finder once.» То есть ad-hoc
    **не убирает барьер при дистрибуции через DMG** — у конечного юзера всё равно будет ручной обход.
    Источник: https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5 (+ подтверждение в выдаче) — **уверенность high**.

### Что даёт платная подпись + нотаризация
- **Стоимость: Apple Developer Program — $99/год.** «No way around it.» Подтверждено несколькими
  источниками. Источники: https://byby.dev/distributing-macos-apps ,
  https://www.iridium-works.com/en/blog-post/making-macos-app-bundles-signing-notarizing — **уверенность high**.
- **Шаги** (CLI, актуальные на 2025): нужен **Developer ID Application** сертификат + **hardened runtime**;
  `xcrun notarytool store-credentials …` → `xcrun notarytool submit <app|dmg> --keychain-profile … --wait`
  → `xcrun stapler staple <app|dmg>` → проверка `spctl --assess -vv …`. **`notarytool` заменил `altool`**.
  Источник: https://scriptingosx.com/2021/07/notarize-a-command-line-tool-with-notarytool/ — **уверенность high**.
- **Эффект на UX:** подписанное Developer ID + нотаризованное + застапленное приложение/DMG открывается
  у пользователя **двойным кликом без алертов и без обходов** — это единственный путь к «беспроблемному»
  опыту на 15+. Источник: https://developer.apple.com/videos/play/wwdc2019/703/ (stapling → «ready for
  distribution just like before») + общий консенсус источников — **уверенность high**.

**Вывод по Теме 3:** на macOS 15+ без $99 подписи у любого пользователя будет минимум один ручной шаг
(Open Anyway или `xattr`). Ad-hoc подпись косметику «is damaged» НЕ решает при переносе на чужую машину.

---

## Тема 4. launchd WatchPaths на ПРОИЗВОЛЬНОМ пути — подводные камни

- **TCC / права на папки.** Desktop, Documents, Downloads защищены TCC: фоновый/терминальный процесс
  без разрешения получает отказ/зависание чтения. «macOS may also gate Desktop, Documents, and Downloads
  for terminal/background processes. If file reads or directory listings hang, grant access to the same
  process context.» Если пользователь выберет такую папку — агент может не прочитать содержимое, пока не
  выдано разрешение (Full Disk Access или папочный TCC-грант для агента).
  Источники: https://openclaws.io/docs/platforms/mac/permissions/ ,
  https://docs.openclaw.ai/platforms/mac/permissions , https://afine.com/threat-of-tcc-bypasses-on-macos ,
  https://stackoverflow.com/questions/69609875/ (Desktop → `can't open input file`) — **уверенность med-high**.
- **TCC-грант привязан к подписи + bundle id + пути.** «TCC associates a permission grant with the app's
  code signature, bundle identifier, and on-disk path. If any of those change, macOS treats the app as new
  and may drop the grant.» Практический риск: **ad-hoc/неподписанное приложение** теряет TCC-разрешения
  при пересборке/перемещении — ещё один аргумент за стабильную подпись и фиксированный bundle id.
  Источник: https://openclaws.io/docs/platforms/mac/permissions/ — **уверенность med** (один источник, но детально и согласуется с общеизвестным поведением TCC).
- **Окружение агента минимально (PATH).** launchd-агент стартует с урезанным окружением — нельзя
  полагаться на `PATH`, где лежит Calibre/Homebrew. Текущий скрипт уже использует абсолютный путь
  `/Applications/calibre.app/Contents/MacOS/ebook-convert` — это **правильный паттерн**; так же надо для
  `python3` (абсолютный путь или явный `PATH` в самом скрипте). Это не из веб-выдачи, а из исходников
  проекта (`bin/fb2-to-epub-watcher.sh`) и общеизвестного поведения launchd — **уверенность high** (подтверждается локальным кодом).
- **Современная (пере)загрузка per-user агента.** Использовать:
  - load:   `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/<label>.plist`
  - unload: `launchctl bootout gui/$UID/<label>`
  - restart:`launchctl kickstart -k gui/$UID/<label>`
  - `load`/`unload` (включая `-w`) **deprecated**, но ещё работают. (Текущий `install.sh` использует
    устаревшие `load -w`/`unload` — стоит мигрировать.)
  Источники: https://inventivehq.com/knowledge-base/macos/how-to-manage-launchagents-launchdaemons-macos ,
  https://www.alansiu.net/2023/11/15/launchctl-new-subcommand-basics-for-macos/ ,
  https://apple.stackexchange.com/questions/366281/ — **уверенность high**.
- **Доп. грабли WatchPaths**: триггер срабатывает на изменение метаданных каталога/файла, может
  «дребезжать» — текущий код уже закрывает это `ThrottleInterval` + lock-dir (хорошо). Подтверждение
  паттерна: https://thethracian.com/blog/auto-push-your-notes-repos-on-macos-with-launchd-not-cron/ — **med**.

---

## Тема 5. Calibre как зависимость

- **Надёжный детект наличия.** На macOS CLI-тулзы лежат внутри бандла:
  `/Applications/calibre.app/Contents/MacOS/ebook-convert` (и `ebook-meta`). Проверка `-x` по этому пути —
  правильный способ (текущий код так и делает). Источники:
  https://manual.calibre-ebook.com/generated/en/cli-index.html («On macOS, the command line tools are
  inside the calibre bundle … /Applications/calibre.app/Contents/MacOS/») ,
  https://stackoverflow.com/questions/41258939/ — **уверенность high**.
- **Паттерн «детект → подсказать установку».** Два честных канала:
  - Homebrew cask: `brew install --cask calibre` (есть в Homebrew Formulae). Источники:
    https://formulae.brew.sh/cask/calibre , https://www.z3kit.com/how-to-convert-ebooks-using-calibre/ — **high**.
  - Прямой DMG с https://calibre-ebook.com (для тех, у кого нет Homebrew). — **high** (официальный сайт).
  Рекомендация: при отсутствии Calibre показать диалог с обеими опциями (а не падать молча). Текущий
  `install.sh` уже подсказывает обе — переносим эту логику в .app.
- **Встраивание движка — НЕ рекомендуется.**
  - **Размер**: Calibre — крупный бандл (десятки–сотни МБ, тянет свой Python/Qt). Раздувает .dmg
    несоразмерно утилите. — **med** (точную цифру в выдаче не нашёл → «данных по точному размеру нет»,
    но порядок «крупный» подтверждается тем, что это полноценное GUI-приложение с Qt/Python).
  - **Лицензия**: Calibre — **GPL**. Встраивание/перераспространение накладывает GPL-обязательства на
    дистрибутив, что нежелательно для простой проприетарной/MIT-утилиты. — **med-high** (GPL Calibre —
    общеизвестный факт; в данной выдаче прямой ссылки на текст лицензии нет → пометить как требующее
    подтверждения, но риск реальный).
- **Вывод:** оставить Calibre **внешней зависимостью** с дружелюбным детектом и подсказкой установки.

---

## Рекомендация для v1 (стек)

| Решение | Выбор | Обоснование | Уверенность |
|---|---|---|---|
| **Приложение** | **AppleScript .app** (диалог `choose folder` + `do shell script`, экспорт через `osacompile`) **ИЛИ Platypus** как обёртка существующего watcher | Максимально переиспользует готовый shell-код, **без Xcode/Swift**, тривиальная сборка (в т.ч. CI). SwiftUI/MenuBarExtra — отложить на v2, когда захочется резидентный UI в меню-баре | **med-high** |
| **DMG** | **`create-dmg` (npm, sindresorhus)** с `--no-code-sign` в CI; fallback — чистый `hdiutil` | Зрелый, авто-оформление (фон, симлинк /Applications, layout), флаг под CI | **high** |
| **Подпись** | **v1 БЕЗ платной подписи**: ad-hoc `codesign -s -` для косметики + честная инструкция «Open Anyway» и `xattr -dr com.apple.quarantine` в README. **Запланировать $99 Developer ID + нотаризацию** как обязательный шаг к «беспроблемному» релизу | На 15+ без подписи ручной шаг неизбежен; ad-hoc не лечит перенос на чужую машину → либо миримся с одним кликом юзера, либо платим $99 | **high** |
| **Calibre** | **Внешняя зависимость**: детект по абсолютному пути → при отсутствии диалог с `brew install --cask calibre` или ссылкой на calibre-ebook.com. Движок НЕ встраивать | Размер + GPL; детект уже отлажен в текущем коде | **high** |
| **launchd** | Мигрировать на `launchctl bootstrap gui/$UID` / `bootout` / `kickstart`; абсолютные пути к `ebook-convert` и `python3`; сохранить `ThrottleInterval`+lock | Современные команды, надёжность в урезанном окружении агента | **high** |

---

## Противоречия между источниками

1. **Поведение macOS 15.1 «Open Anyway».** iDownloadBlog/Apple: путь через System Settings → Open Anyway
   работает (первый запуск). Часть комментаторов в Hackaday: в 15.1 секция Open Anyway «не появляется как
   задумано» — возможно баг конкретной сборки. → Для нас: **закладываться, что у части пользователей даже
   ручной обход может быть неочевиден** → сильный аргумент за нотаризацию. (high vs med).
2. **Достаточно ли ad-hoc подписи.** Hackaday прямо не разбирает ad-hoc. rsms-gist чётко: ad-hoc работает
   только на машине сборки, на чужой машине процесс убивается без интерактивного первого запуска. →
   Принимаем версию rsms (детальнее и согласуется с практикой). (med vs high).

## Пробелы данных (честно)

- **Точный размер бандла Calibre** в МБ — в выдаче нет (есть только «крупное GUI-приложение с Qt/Python»).
- **Прямая ссылка на лицензию Calibre (GPL)** в этой выдаче не зафиксирована — факт общеизвестен, но
  для решения «встраивать/нет» это и не нужно (мы и так не встраиваем).
- **`osacompile` как CI-команда экспорта .app** — конкретного свежего гайда в выдаче нет; команда
  общеизвестна, но если пойдём этим путём — стоит проверить вживую.

## Открытые вопросы к человеку

1. **Бюджет на подпись:** готовы ли платить **$99/год** Apple Developer для нотаризации? Это водораздел
   между «двойной клик и всё работает» и «пользователь делает 1 ручной шаг Open Anyway». От ответа
   зависит весь UX дистрибуции.
2. **Целевая аудитория:** технари (которым ок `xattr`/Open Anyway) или массовый нетехнический юзер
   (тогда нотаризация почти обязательна)?
3. **UX-амбиция v1:** достаточно «выбрал папку один раз и оно работает фоном» (AppleScript/Platypus +
   launchd), или хочется резидент в меню-баре со статусом/паузой уже в v1 (тогда SwiftUI MenuBarExtra,
   дороже)?
4. **Распространение:** через GitHub Releases (.dmg) — ок? Или планируется свой сайт/Homebrew tap/cask?

## Следующий шаг (рекомендация)

Готово к фазе планирования архитектуры (двойной архитектор). Перед стартом — получить от человека ответ
по **п.1 (подпись $99 да/нет)** и **п.3 (AppleScript/Platypus vs SwiftUI MenuBar)**: эти два решения
определяют execution-pack. Если бюджета на подпись нет и аудитория техническая → v1 = AppleScript/Platypus
.app + `create-dmg` + ad-hoc + инструкция, движемся в архитектуру.
