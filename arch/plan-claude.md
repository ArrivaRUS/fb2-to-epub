# Архитектура: fb2-to-epub → дистрибуция «.dmg → .app-установщик → выбор папки → автоконвертация»

> Архитектор #1 (Claude). План, НЕ реализация. Дата: 2026-06-23.
> Вход: текущий код проекта + ресёрч `research/packaging-2026.md`.
> Constraints (не пересматриваются): D1 одноразовый установщик (не резидент), D2 без платной подписи (1 ручной шаг первого запуска), D3 Calibre — внешняя зависимость.

---

## Итог (3–5 строк)

v1 = **AppleScript-applet** (`osacompile`, без Xcode) как тонкая обёртка-«дирижёр», которая зовёт **bundled bash-установщик** (`installer.sh` внутри `.app/Contents/Resources/`), который переиспользует существующий watcher 1:1. Applet нужен ради одного: дать TCC стабильный **«ответственный процесс»** (Mach-O `applet` с фиксированным bundle id и путём `/Applications/...`), а не эфемерный bash — это закрывает главный риск чтения папки фоновым агентом. Вся «настоящая работа» (рендер plist под выбранный `WATCH_DIR`, `launchctl bootstrap`/`kickstart`, детект Calibre) живёт в bash, который тестируется отдельно от GUI. DMG собираем `create-dmg` (npm, есть node v24). Старый `install.sh` остаётся как advanced-CLI-путь. **Главный нерешённый водораздел для человека — TCC-стратегия для произвольной папки (G4).**

---

## Ключевые факты, проверенные вживую (меняют решения)

1. **Среда разработчика — macOS 26.5.1 (Tahoe)**, не 15. Режим Gatekeeper тот же ужесточённый (ПКМ→Открыть мёртв, путь только System Settings → Privacy & Security → Open Anyway). План должен закладываться на 15/26+.
2. **AppleScript-applet от `osacompile` НЕ содержит `CFBundleIdentifier`** (проверено PlistBuddy). TCC-грант привязан к bundle id → **обязаны прописать стабильный `CFBundleIdentifier` руками** в build-скрипте, иначе грант папки теряется при каждой пересборке/переносе.
3. **Executable applet = Mach-O universal `applet`** (osascript-runner), НЕ bash. Для `choose folder`/`do shell script` «ответственным» процессом TCC станет сам `applet` по пути `/Applications/fb2-to-epub Installer.app` — стабильный, в отличие от bash. Это решающий аргумент AppleScript > чистый Platypus-shell для нашего TCC-кейса.
4. **launchd-агент стартует с `PATH => /usr/bin:/bin:/usr/sbin:/sbin`** (проверено `launchctl print`). Homebrew/python3 туда не входят → абсолютные пути к `ebook-convert` и `python3` обязательны (watcher для calibre уже так делает; нужно добить python3).
5. node v24 + osacompile есть в системе; `create-dmg` (npm) ещё не установлен (ставится одной командой).

---

## 1. Стек .app без Xcode: AppleScript vs Platypus → **AppleScript**

**Рекомендация v1: AppleScript-applet (`osacompile`), bash-логика вынесена в bundled-ресурс.**

| Критерий | AppleScript applet | Platypus |
|---|---|---|
| Xcode | не нужен (`osacompile` в системе) | не нужен (но нужен сторонний `platypus_clt`) |
| Зависимость сборки | **только система** (`/usr/bin/osacompile`) | внешний бинарь Platypus в CI |
| TCC «ответственный процесс» | **стабильный Mach-O `applet`** по фикс. пути | slim-лаунчер Platypus (тоже бинарь, но лишняя прослойка) |
| `choose folder` | нативно (`choose folder`) | через тот же `osascript` из скрипта |
| Прогресс-бар/кнопки | беднее (`display dialog`) | богаче (текстовый вывод, progress) |
| Размер | ~КБ + 100 КБ applet | slim app + скрипт |
| CI без GUI | да (`osacompile` — CLI) | да (`platypus_clt` — CLI) |

**Почему AppleScript для v1:**
- D1 = одноразовый установщик → богатый UI Platypus (прогресс-бар резидента) не нужен; хватает 3–4 диалогов.
- Минус зависимость в CI (Platypus-бинарь) — важно для воспроизводимости в публичном репо.
- TCC: applet — стабильный бинарь, который и будет «ответственным» при первом чтении папки. Меньше движущихся частей.

**Анти-оверинжиниринг:** applet делает МИНИМУМ — диалоги + `do shell script "bash .../Contents/Resources/installer.sh <args>"`. Вся логика (детект, рендер plist, launchctl) — в bash, который запускается и тестируется без GUI. Не «писать установщик на AppleScript».

**Воспроизводимая сборка (иллюстративно):**
```sh
# build/build-app.sh (схема, не финальный код)
osacompile -o "dist/fb2-to-epub Installer.app" packaging/applet.applescript
# Принудительно проставить стабильный bundle id (osacompile его НЕ ставит):
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.arrivarus.fb2-to-epub.installer" \
  "dist/fb2-to-epub Installer.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 11.0" "...Info.plist"
# Положить bash-логику и иконку в Resources:
cp bin/fb2-to-epub-watcher.sh bin/fb2-to-epub-cover-finder.py \
   launchd/com.user.fb2-to-epub.plist.template packaging/installer.sh \
   "dist/fb2-to-epub Installer.app/Contents/Resources/"
cp branding/AppIcon.icns "dist/.../Contents/Resources/applet.icns"
codesign --force --deep --sign - "dist/fb2-to-epub Installer.app"   # ad-hoc (косметика)
```

**Уверенность: med-high.** AppleScript+osascript+do shell script — high (ресёрч + локальная проверка). Что applet окажется корректным TCC-«ответственным» при чтении папки фоновым launchd-агентом — med (это другой процесс; см. п.4 — главный риск).

---

## 2. Поток установщика по шагам

Applet = линейный сценарий. Каждый шаг — отдельная функция bash, applet только показывает диалоги и передаёт результат.

```
[0] Запуск двойным кликом (после Open Anyway при первом старте — см. п.7)
      ▼
[1] ДЕТЕКТ CALIBRE
    bash проверяет -x /Applications/calibre.app/Contents/MacOS/ebook-convert
    есть  → дальше
    нет   → display dialog «Нужен Calibre» с 3 кнопками:
            • "Установить через Homebrew" (если есть brew → do shell script brew install --cask calibre)
            • "Скачать с сайта" (open https://calibre-ebook.com/download_osx)
            • "Отмена"
            после установки — повторный детект; если всё ещё нет → стоп с понятным текстом
      ▼
[2] ВЫБОР ПАПКИ (нативный picker)
    set theFolder to (choose folder with prompt "Выберите папку для автоконвертации FB2→EPUB")
    POSIX path → WATCH_DIR
    (default location — папка пользователя; не Desktop по умолчанию, чтобы не толкать в TCC-зону)
      ▼
[3] TCC-РАЗВИЛКА (если WATCH_DIR в Desktop/Documents/Downloads/iCloud)
    bash определяет, попадает ли путь в защищённую зону.
    v1-дефолт (см. п.4): показать ИНСТРУКЦИЮ-предупреждение, что папке в этой зоне
    может понадобиться выдать доступ, + предложить «безопасную» папку вне зоны.
      ▼
[4] УСТАНОВКА (installer.sh, идемпотентно)
    • mkdir -p ~/.local/bin, ~/Library/LaunchAgents, ~/Library/Logs, "$WATCH_DIR"
    • install -m0755 watcher.sh, cover-finder.py → ~/.local/bin   (из Resources)
    • рендер plist: sed подстановка __HOME__ и __WATCH_DIR__ (см. п.3) → ~/Library/LaunchAgents/<label>.plist
    • watcher теперь читает WATCH_DIR из окружения (EnvironmentVariables в plist), а не хардкодит Desktop
      ▼
[5] (ПЕРЕ)ЗАГРУЗКА АГЕНТА (современный launchctl, идемпотентно — см. п.3)
    launchctl bootout gui/$UID/<label> 2>/dev/null || true
    launchctl bootstrap gui/$UID ~/Library/LaunchAgents/<label>.plist
    launchctl kickstart -k gui/$UID/<label>     # сразу прогнать первый скан
      ▼
[6] ЭКРАН УСПЕХА
    display dialog «Готово. Папка <WATCH_DIR> отслеживается. Бросайте .fb2/.fb2.zip — рядом появятся .epub.»
    кнопки: "Открыть папку" (open "$WATCH_DIR") / "Готово"
      ▼
[7] ВЫХОД (applet завершается; дальше всё фоном через launchd)
```

**Повторный запуск / смена папки / идемпотентность:**
- Установщик НЕ ведёт себя как «первый раз»: всегда `bootout || true` перед `bootstrap` → повторный запуск безопасен.
- Смена папки = просто заново выбрать другую в шаге [2]; новый plist перезаписывает старый, агент перезагружается на новый WATCH_DIR.
- Состояние «какая папка сейчас» хранится в самом plist (`EnvironmentVariables.WATCH_DIR` + `WatchPaths`) — единый источник правды, дополнительный конфиг-файл не нужен (анти-оверинжиниринг).
- Старый WATCH_DIR при смене не удаляем (как и текущий uninstall — не трогает данные); опционально показать «прежняя папка <X> больше не отслеживается».

**Состояния (loading/empty/error):**
- loading: `do shell script` блокирующий; на установке Calibre/конвертации показать «Идёт установку Calibre…» (busy-диалог или просто текст перед длинной операцией).
- empty: папка пуста — нормально, агент ждёт; экран успеха это проговаривает.
- error: каждый шаг bash возвращает код; applet ловит ненулевой → `display dialog` с конкретной причиной (нет Calibre / нет прав на папку / launchctl упал) + путь к логу `~/Library/Logs/fb2-to-epub.log`.

---

## 3. launchd: миграция и plist под произвольный WATCH_DIR

**Миграция команд (deprecated → modern):**

| Было (`install.sh`) | Стало |
|---|---|
| `launchctl unload "$PLIST"` | `launchctl bootout gui/$UID/<label> 2>/dev/null \|\| true` |
| `launchctl load -w "$PLIST"` | `launchctl bootstrap gui/$UID "$PLIST"` |
| (нет) первичного прогона | `launchctl kickstart -k gui/$UID/<label>` |

`$UID` — числовой uid (`id -u`), gui-домен пользователя. Проверено: текущий агент живёт в `gui/501`.

**Изменения plist-шаблона** (две правки к текущему `com.user.fb2-to-epub.plist.template`):
1. Параметризовать путь папки: `WatchPaths` → `<string>__WATCH_DIR__</string>` (раньше хардкод `__HOME__/Desktop/fb2-to-epub`).
2. Добавить `EnvironmentVariables`, чтобы watcher узнал папку и нашёл бинарники в урезанном окружении:
```xml
<key>EnvironmentVariables</key>
<dict>
    <key>WATCH_DIR</key>   <string>__WATCH_DIR__</string>
    <key>PATH</key>        <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
</dict>
```
Рендер: `sed -e "s|__HOME__|$HOME|g" -e "s|__WATCH_DIR__|$WATCH_DIR|g"`.
(Осторожно с путями, где есть `|` — крайне маловероятно для папки, но в реализации использовать безопасную подстановку, например через `envsubst` или python, если решим перестраховаться.)

**Чтобы фоновый агент нашёл Calibre/python3:**
- `ebook-convert`: уже абсолютный путь в watcher — оставить.
- `python3`: watcher сейчас зовёт `/usr/bin/env python3` — в урезанном PATH `/usr/bin/env` найдёт системный `/usr/bin/python3` (он есть в составе CLT). **Микро-правка watcher:** заменить на абсолютный `/usr/bin/python3` ИЛИ гарантировать его наличие детектом на шаге установки. Не полагаться на Homebrew-python.
- В plist прописан явный `PATH` (см. выше) как страховка.

**Корректная (пере)загрузка из .app:** applet вызывает bash, bash — `launchctl` в контексте пользователя (gui/$UID). Поскольку applet запущен из Finder сессии пользователя — домен совпадает, прав достаточно, sudo не нужен (это LaunchAgent, не Daemon).

**Watcher: правка чтения WATCH_DIR.** Сейчас `WATCH_DIR="$HOME/Desktop/fb2-to-epub"` захардкожен. Меняем на:
```sh
WATCH_DIR="${WATCH_DIR:-$HOME/Desktop/fb2-to-epub}"   # из launchd EnvironmentVariables, fallback для совместимости с CLI
```
Это сохраняет обратную совместимость со старым `install.sh` (advanced-путь) и одновременно работает с новым plist.

**Уверенность: high.** Команды bootstrap/bootout/kickstart и поведение PATH подтверждены ресёрчем и локально.

---

## 4. TCC: чтобы фоновый watcher реально читал выбранную папку

Это **самый острый архитектурный риск** (выношу на G4 — см. п.8).

**Суть проблемы:** Desktop/Documents/Downloads/iCloud защищены TCC. Фоновый launchd-агент (`/bin/bash watcher.sh`) — это **другой процесс**, не applet. Грант, который пользователь мог бы дать applet'у при `choose folder`, не обязательно покрывает bash-агент. И applet, и agent неподписаны платно → грант хрупок при пересборке (привязан к bundle id + подписи + пути).

**Развилки (от дешёвой к надёжной):**

- **A. Избегать TCC-зоны (рекомендуемый дефолт v1).** default-папка picker'а — НЕ Desktop (например `~/fb2-to-epub` в home root, вне защищённых зон). Если пользователь всё же выбрал Desktop/Documents/Downloads — показать предупреждение и предложить безопасную папку. Плюс: ноль TCC-боли, ноль ручных шагов сверх Open Anyway. Минус: не любая папка «just works» — но D2 уже допускает 1 ручной шаг, а это его вообще убирает для дефолтного сценария.
  *Уверенность high, что это работает; med — что пользователю это приемлемо (UX-компромисс → вопрос человеку).*

- **B. Просить Full Disk Access у фонового агента/applet.** Открыть System Settings → Privacy & Security → Full Disk Access, попросить добавить туда applet (или `/bin/bash`? — нельзя, общий бинарь). Проблема: FDA для неподписанного applet хрупок и пугает пользователя («полный доступ к диску» для конвертера книг — overkill и подозрительно). *Не дефолт.*

- **C. Положиться на «папочный» TCC-грант через applet.** Идея: applet первым читает папку (в do shell script `ls "$WATCH_DIR"`), провоцируя TCC-диалог на стабильный bundle id applet'а. НО грант привязан к процессу applet, а читать будет bash-agent → грант не наследуется. Ненадёжно. *Отвергнуть.*

**Дефолт v1: вариант A** (default вне TCC-зоны + предупреждение при выборе защищённой). Это минимум движущихся частей и согласуется с D2. Вариант B документировать в README как «если очень нужен Desktop». Полное решение TCC «любая папка без единого клика» = только платная подпись + возможно FDA → отложить (как и подпись в D2).

**Риск пересборки:** даже при варианте A, если пользователь выбрал защищённую папку и выдал грант, пересборка/обновление .app со сменой подписи сбросит грант. Митигация: **зафиксировать `CFBundleIdentifier`** (см. п.1) — он стабилен между сборками, это снижает потери TCC. Ad-hoc подпись меняется, но bundle id — нет; для папочных грантов bundle id важнее.

**Уверенность: med.** TCC-поведение для связки «неподписанный applet + отдельный launchd-bash-агент» — наименее проверенная часть; ресёрч даёт принципы, но точное поведение стоит проверить вживую на этапе разработки (тест-гейт). Поэтому A (избегание) — самый предсказуемый дефолт.

---

## 5. DMG

**Инструмент: `create-dmg` (npm, sindresorhus).** node v24 есть. Fallback — чистый `hdiutil` (без зависимостей), если node нежелателен в CI.

**Раскладка тома:**
- `fb2-to-epub Installer.app`
- симлинк на `/Applications` (перетащить для установки) — `create-dmg` делает авто.
- фон тома с инструкцией: 2 строки — «1. Перетащите в Applications. 2. Первый запуск: ПКМ не работает на macOS 15+ → откройте через System Settings → Privacy & Security → Open Anyway» (картинка-инструкция критична, т.к. это единственный ручной шаг по D2).
- иконка тома = AppIcon.

**Скрипт сборки в репо: `build/make-dmg.sh`** — что делает:
1. вызывает `build/build-app.sh` (см. п.1) → `dist/...app`;
2. `create-dmg --no-code-sign --dmg-title="fb2-to-epub" --background packaging/dmg-background.png --overwrite "dist/fb2-to-epub Installer.app" dist/`;
3. (опц., будущее) если есть Developer ID — нотаризация `notarytool submit --wait` + `stapler staple`.

Иллюстративно:
```sh
# build/make-dmg.sh
./build/build-app.sh
npx --yes create-dmg --overwrite --no-code-sign \
  --dmg-title "fb2-to-epub" \
  "dist/fb2-to-epub Installer.app" dist/ || true   # create-dmg даёт ненулевой код при ad-hoc, это ок
```
(Известная особенность sindresorhus/create-dmg: ненулевой exit при неудачной подписи — оборачиваем `|| true` и проверяем наличие `.dmg`.)

**Риск «образ диска повреждён»:** у пользователя это обычно карантин/Gatekeeper, не битый dmg. Лечится тем же Open Anyway/`xattr -dr com.apple.quarantine`. Проговорить в README.

**Уверенность: high.** create-dmg — зрелый, node есть. Особенность exit-кода — известна, заложена.

---

## 6. Структура репо

```
fb2-to-epub/
├── bin/                              # БЕЗ изменений (кроме 2 микроправок watcher: WATCH_DIR из env, python3 абс. путь)
│   ├── fb2-to-epub-watcher.sh
│   └── fb2-to-epub-cover-finder.py
├── launchd/
│   └── com.user.fb2-to-epub.plist.template   # +__WATCH_DIR__, +EnvironmentVariables
├── packaging/                       # НОВОЕ — исходники .app-обёртки
│   ├── applet.applescript           # тонкий дирижёр (диалоги + do shell script)
│   ├── installer.sh                 # bash-логика установки (детект/рендер/launchctl) — копируется в Resources
│   ├── dmg-background.png           # фон тома с инструкцией Open Anyway
│   └── README-packaging.md          # как собрать локально
├── build/                           # НОВОЕ — сборка артефактов
│   ├── build-app.sh                 # osacompile + PlistBuddy(bundle id) + копир. Resources + ad-hoc codesign
│   └── make-dmg.sh                  # build-app + create-dmg
├── branding/
│   └── AppIcon.icns                 # НОВОЕ — из существующих icon-concept-*.svg (выбрать 1 → .icns)
├── dist/                            # gitignored — артефакты сборки (.app, .dmg)
├── install.sh                       # ОСТАЁТСЯ — advanced CLI-путь (правка: миграция launchctl + WATCH_DIR опц.)
├── uninstall.sh                     # ОСТАЁТСЯ — правка: bootout вместо unload; работает и для .app-установки
├── README.md                        # переписать: .dmg как основной путь, install.sh как advanced
└── .gitignore                       # +dist/
```

**Сосуществование старого CLI и нового .app:**
- Оба ставят **один и тот же** label/plist/scripts → не конфликтуют, второй просто перезаписывает (идемпотентность п.2).
- `installer.sh` (в .app) и `install.sh` (CLI) делят максимум логики; чтобы не дублировать — `install.sh` после миграции может тоже читать опц. `WATCH_DIR` env (по умолчанию Desktop, для обратной совместимости). Минимально: вынести общие функции, но не переусложнять — допустимо лёгкое дублирование двух коротких bash-скриптов.
- `uninstall.sh` один на оба пути (удаляет тот же label/файлы) → правим только команду выгрузки.

**README меняется:** новый раздел «Установка (рекомендуется): скачайте .dmg из Releases → перетащите в Applications → ПЕРВЫЙ запуск через System Settings → Open Anyway (скрин) → выберите папку». Старый раздел про `git clone + install.sh` → в «Для разработчиков / advanced».

**Иконка:** `branding/` уже содержит 3 концепта `.svg`. Нужен один шаг конвертации выбранного концепта в `.icns` (через `sips`/`iconutil` из png-рендеров svg) — оформить в `build/build-app.sh` или один раз закоммитить `AppIcon.icns`. Выбор концепта — вопрос человеку (косметика, не блокирует архитектуру).

---

## 7. Распространение

- **GitHub Release с .dmg.** `gh release create vX.Y.Z dist/fb2-to-epub-X.Y.Z.dmg --title "..." --notes "..."`.
- Тег = версия; имя dmg с версией (или `--no-version-in-filename` для стабильного URL «latest» — решить).
- README: бейдж/ссылка «Скачать .dmg (последний релиз)» → на `releases/latest`. Плюс явный блок про первый запуск (Open Anyway) с картинкой — это критично, т.к. по D2 ручной шаг неизбежен и должен быть понятен.
- Опционально (будущее): Homebrew cask в своём tap (`brew install --cask arrivarus/tap/fb2-to-epub`) — но это v2, требует поддержки cask-формулы.

**Уверенность: high.** `gh release create` — стандарт.

---

## 8. Риски и развилки для человека (→ G4) + этапность

### Развилки для человека (существенные — на G4):
1. **TCC-дефолт (САМОЕ важное).** Принять ли вариант A («дефолтная папка вне Desktop/Documents/Downloads; защищённые — с предупреждением»)? Альтернатива — заявлять «любая папка», но тогда либо платная подпись+FDA, либо у пользователя возможны молчаливые отказы чтения. **Рекомендую A.** Это компромисс UX vs предсказуемость.
2. **Подпись (подтверждение D2).** Ресёрч: на 15/26+ без $99 ручной Open Anyway неизбежен; ad-hoc не лечит перенос на чужую машину. D2 уже принял «1 ручной шаг» — подтвердить, что это ОК для целевой аудитории (технари vs массовый юзер). Если позже массовый → закладывать $99-нотаризацию (план её предусматривает как опц. шаг в make-dmg).
3. **AppleScript vs Platypus.** Рекомендую AppleScript (ноль внешних зависимостей сборки, стабильный applet для TCC). Platypus — если позже захочется прогресс-бар. Подтвердить выбор.
4. **Версионирование URL dmg** (фикс. имя для «latest» vs имя с версией) — мелочь, но решить до релиза.
5. **Выбор иконного концепта** (1 из 3 в branding/) — косметика.

### Этапность

**v1 (минимум, в скоупе D1–D3):**
- packaging/applet.applescript (диалоги: Calibre-детект, choose folder, успех, ошибки).
- packaging/installer.sh (детект → рендер plist под WATCH_DIR → bootstrap/kickstart, идемпотентно).
- 2 микроправки watcher (WATCH_DIR из env + python3 абс. путь) + правка plist-шаблона (__WATCH_DIR__, EnvironmentVariables).
- Миграция launchctl в install.sh/uninstall.sh.
- build/build-app.sh (+ принудительный CFBundleIdentifier) и build/make-dmg.sh (create-dmg).
- AppIcon.icns из выбранного концепта.
- README: .dmg-путь + блок Open Anyway с картинкой; install.sh → advanced.
- GitHub Release с .dmg.
- TCC = вариант A (избегание зоны + предупреждение).

**Отложить (v2+):**
- Платная подпись Developer ID + нотаризация (notarytool/stapler) — план оставляет хук в make-dmg.
- Резидент в меню-баре (SwiftUI MenuBarExtra) со статусом/паузой/сменой папки — противоречит D1, отдельный продукт.
- «Любая папка без единого ручного шага» в TCC-зонах (нужна подпись + FDA-флоу).
- Homebrew cask / свой сайт.
- Авто-апдейт (Sparkle и т.п.).

---

## Сводка уверенности по ключевым решениям

| Решение | Уверенность | Главная неопределённость |
|---|---|---|
| AppleScript-applet (не Platypus) для v1 | med-high | поведение applet как TCC-«ответственного» для фонового bash-агента |
| Bash-логика в Resources, applet — тонкий дирижёр | high | — |
| Обяз. фикс. CFBundleIdentifier (osacompile не ставит) | high | проверено локально |
| launchctl bootstrap/bootout/kickstart + EnvironmentVariables PATH | high | проверено локально (PATH агента урезан) |
| TCC = вариант A (избегать защищённых зон по умолчанию) | med | приемлемость UX-компромисса (вопрос человеку); точное TCC-поведение проверить на разработке |
| create-dmg (npm) для DMG | high | exit-код create-dmg при ad-hoc (заложено `|| true`) |
| Старый install.sh как advanced-путь, общий plist | high | — |
| По D2 ручной Open Anyway неизбежен на 15/26+ | high | возможный баг секции Open Anyway в части сборок 15.1 (ресёрч) |
