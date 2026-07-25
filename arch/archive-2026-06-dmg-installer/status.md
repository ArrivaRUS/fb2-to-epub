# Status — fb2-to-epub (живой лог исполнения)

> Обновляется по ходу. План — `plans.md`, гейты — `test-plan.md`.

## 2026-06-23
- G4 пройдена; дефолт папки = `~/Desktop/fb2-to-epub` (любая разрешена).
- TCC проверен вживую: на этой машине агент читает Desktop-папку успешно.
- M1 стартует (Developer); DMG-фон — дизайнер (параллельно).

### M1 чек — ВСЁ ГОТОВО (Developer, smoke-тест зелёный)
- [x] T1 параметризация watcher + plist (`bin/fb2-to-epub-watcher.sh`: WATCH_DIR/PYTHON3/EBOOK_CONVERT из env; новый шаблон `launchd/com.arrivarus.fb2toepub.agent.plist.template`). Логика конвертации не тронута.
- [x] T2 `packaging/installer.sh` (детект Calibre+python3; копия в App Support/bin; plist через **plutil**; bootout→bootstrap→enable→kickstart; идемпотентно; FDA-подсказка). Проверено: путь с пробелом+кириллицей+скобками round-trip ок, lint ок.
- [x] T3 runner-цель `packaging/fb2-to-epub-runner.sh` — стабильный target в `ProgramArguments` (не голый bash); задокументировано, что FDA выдавать именно ему (`~/Library/Application Support/fb2-to-epub/bin/fb2-to-epub-runner.sh`).
- [x] T4 `packaging/applet.applescript` (Calibre-чек → choose folder с дефолтом → bundled installer → успех/ошибки). osacompile compiles.
- [x] T5 `build/build-app.sh` → `fb2-to-epub.app`; **CFBundleIdentifier=com.arrivarus.fb2toepub** + версия; AppIcon.icns из Концепт 1 (qlmanage→sips→iconutil, 10 размеров); ad-hoc codesign. `codesign --verify --deep --strict` = OK (фикс: strip xattr/FinderInfo перед подписью).
- [x] T6 `build/make-dmg.sh` → `fb2-to-epub-0.1.0.dmg` (+ .sha256). Окно 660×400, app@(165,185), /Applications@(495,185), фон-плейсхолдер. Монтируется, внутри .app+симлинк+фон, размонтируется. **Решение: andreyvit/create-dmg (brew), не npm — npm-версия zero-config и не принимает флаги координат/фона.**
- [x] CLI `install.sh`/`uninstall.sh` мигрированы на новый label, делегируют в `installer.sh` (bootout/bootstrap).
- [x] `.gitignore`: build/dist, *.app, *.dmg, *.dmg.sha256.

Smoke (на временных папках, новый агент only, существующий `com.user.fb2-to-epub` и книги пользователя НЕ тронуты):
.fb2.zip→.epub (RunAtLoad + WatchPaths-триггер), идемпотентность (1 plist/1 инстанс), bundled-installer из .app end-to-end, dmg монтируется. Всё прибрано после теста.

Открытый гейт: живой TCC-тест «как у нового пользователя» (чистый профиль) — вне dev-машины.

## 2026-06-24 — переделка DMG-упаковки + иконки (Developer)

Юрка снял реальный рендер Finder собранного `fb2-to-epub-0.1.0.dmg` — визуально сломан: generic-иконка, окно 920px при фоне 660px (белый провал), тёмные подписи + видно `.app`, мутный фон на Retina. Корень: `create-dmg` задаёт раскладку через скриптинг Finder по Apple Events → в headless-сборке нет Automation (TCC) → шаг молча не применялся.

### A — иконка (FIXED)
- Причина generic: osacompile-апплет рендерит Finder-иконку из `Contents/Resources/applet.icns` (старый droplet 71KB); `CFBundleIconFile=AppIcon` это не перекрывал.
- Фикс в `build/build-app.sh`: после `iconutil` дополнительно `cp -f AppIcon.icns applet.icns`. Порядок сохранён: рендер icns → оба icns → Info.plist → `xattr -cr` → codesign.
- Проверено: `applet.icns` теперь md5-идентичен `AppIcon.icns` (1.4MB, оба `4d870f9d…`). codesign --verify --deep --strict = OK.

### B — сборка DMG переведена на dmgbuild (FIXED)
- **create-dmg → dmgbuild 1.6.7** (pip, пишет `.DS_Store` напрямую через ds_store/mac_alias, без Finder → headless-надёжно). Установлен в venv `build/.venv`.
- Новый settings-файл `build/dmg-settings.py`; `build/make-dmg.sh` переписан под dmgbuild (paths через `-D`, версия, volname через CLI).
- Окно = размеру фона **660×400** (нет белого провала); app@(165,185), /Applications@(495,185); icon size 120; подписи снизу.
- Фон Retina: указываю **1x** `branding/dmg-background.png`; dmgbuild авто-находит `@2x` и собирает multi-rep TIFF (`tiffutil -cathidpicheck`).
- Спрятано расширение `.app`; убраны toolbar/sidebar/statusbar/pathbar. Volume icon = `AppIcon.icns`.

### C — самопроверка без GUI (ALL PASS)
- Смонтировал dmg (`hdiutil attach -nobrowse`), прочитал `.DS_Store` через `build/.venv` (ds_store): окно 660×400, app(165,185), Applications(495,185), iconSize 120, backgroundType=2, sidebar/toolbar/pathbar/statusbar=False, labelOnBottom=True — **11/11 PASS**.
- `.background.tiff` = multi-rep HiDPI (рейсы 72 dpi + 144 dpi) → чётко на Retina. `.VolumeIcon.icns` 1.4MB присутствует. `kMDItemFSIsExtensionHidden=1` + бит `E` на app; бит `C` (custom icon) на томе. Размонтировано чисто.
- Новый артефакт: `build/dist/fb2-to-epub-0.1.0.dmg` (5.4M; было 2.1M — вырос за счёт Retina-TIFF), sha256 `9d88e18c58f217381af6544e2033d42630a85813d976aeded5991d64c979e5e8`.

### Грабли Finder при ТВОЕЙ проверке
Размер окна мог «запомниться» Finder'ом после прошлых тест-монтирований тома `fb2-to-epub`. Для чистого рендера: `build/make-dmg.sh 0.1.0 --test` собирает dmg с уникальным volname (`fb2-to-epub-test-<ts>`) → Finder не подставит старую геометрию. Альтернатива: после правок `rm -rf ~/Library/Preferences/com.apple.finder.plist` нежелательно (снесёт все настройки) — лучше уникальный volname.

Открытый гейт: финальный визуальный рендер dmg в Finder — снимает Юрка.

## 2026-06-24 (2) — точечные фиксы по реальному рендеру macOS 26 (Developer)

Юрка инспектировал бандл вживую (Finder, macOS 26). Найдены ДВЕ настоящие причины — обе устранены в скриптах.

### A2 — иконка: НАСТОЯЩАЯ причина (FIXED, проверено)
- Корень глубже, чем applet.icns: собранный `Info.plist` нёс **`CFBundleIconName=applet`** (osacompile сеет это имя asset-catalog иконки). На macOS 13+ `CFBundleIconName` приоритетнее `CFBundleIconFile`. Иконки `applet` в `Assets.car` нет → LaunchServices не резолвит → generic, игнорируя валидный `AppIcon.icns`.
- Фикс `build/build-app.sh`: после `CFBundleIconFile=AppIcon` добавлен `plutil -remove CFBundleIconName "$PLIST" 2>/dev/null || true`. Также удаляется лишний `Contents/Resources/applet.rsrc`. Порядок не нарушен: Info.plist (вкл. remove) → `xattr -cr` → codesign. В финал добавлена самопроверка отсутствия ключа.
- ПРОВЕРКА БЕЗ GUI (как просил Юрка): `plutil -extract CFBundleIconName raw -o - <app>/Contents/Info.plist` → `Could not extract value... No value at that key path: CFBundleIconName`, exit=1. Ключ ОТСУТСТВУЕТ — подтверждено. `CFBundleIconFile=AppIcon` на месте; `AppIcon.icns`+`applet.icns` есть; codesign --deep --strict = OK.

### B2 — окно/фон: стратегия «фон ≥ окна, top-left anchor» (готово в скриптах; нужен большой фон от дизайнера)
- macOS 26 игнорирует размер окна из `.DS_Store` (920×436 вместо 660×400; закрытие окон Finder не помогает). Решение: фон рисуется БОЛЬШЕ окна (тёмный до краёв), Finder якорит top-left → широкое окно показывает «дизайн 660 + тёмный добор», без белого провала.
- Подтверждено по исходнику dmgbuild 1.6.7 (`core.py`): фон пишется как `backgroundType=2` + `backgroundImageAlias` — **БЕЗ масштабирования и БЕЗ центрирования**; `window_rect` не подгоняется под фон; на размер фона dmgbuild НЕ ругается. `scroll_position=(0,0)` якорит контент в левый-верхний угол. То есть нативный top-left anchor + native size — ровно цель Юрки. Окно оставлено 660×400 (честные macOS покажут ровно дизайн).
- Правки: `dmg-settings.py` — комментарии-намерение (фон может быть больше окна; top-left anchor) + пояснение к `scroll_position`. `make-dmg.sh` — проверка «фон ≥ окна 660×400» с выводом размеров и WARNING, если меньше (вместо прежней проверки только @2x).
- РАСХОЖДЕНИЕ для Юрки: имя `branding/dmg-background@2x.png` из брифа УЖЕ занято честным 2x-фоном (1320×800). Текущий тест-образ собран на честном фоне 660×400 (1x) — на macOS 26 при окне 920 будет белый добор. Нужен НОВЫЙ большой фон (~1100×500, тёмный до краёв) от дизайнера; именование 1x/@2x менять не стал, чтобы не сломать Retina-механику dmgbuild (он ждёт пару `name.png` + `name@2x.png`).

### C2 — тест-образ (готов)
- `bash build/make-dmg.sh 0.1.0 --test` → `build/dist/fb2-to-epub-0.1.0-TEST.dmg` (5.3M), sha256 `6d71c6e574dc3f98fafe79d33b7c5f9d21e7d8f9d4ed77b9be54779e240e1158`.
- Валидация: `bash -n` обоих скриптов OK, `py_compile` settings OK, shellcheck чисто. НЕ коммичено (по инструкции).

Открытые гейты: (1) большой DMG-фон от дизайнера → финальная сборка; (2) визуальный рендер dmg в Finder macOS 26 — снимает Юрка.

## 2026-06-24 (3) — белая рамка-«кружок» вокруг иконки: НАСТОЯЩАЯ причина (Developer, FIXED + проверено)

Юрка замерил пиксели реального рендера: углы `AppIcon.icns` были **(255,255,255,255)** — белые НЕПРОЗРАЧНЫЕ. Тёмный squircle сидел на белом квадрате → в Finder/DMG белая рамка вокруг иконки.

### A3 — иконка: растеризация qlmanage → cairosvg (FIXED, alpha=0 подтверждено)
- Корень: `build/build-app.sh` растеризовал `branding/icon-concept-1.svg` через `qlmanage -t -s 1024`, а qlmanage подкладывает БЕЛЫЙ фон (теряет прозрачность SVG вне squircle).
- Фикс: растеризация переведена на **cairosvg 2.9.0** (рендерит прозрачный фон, точный размер). Установлен в venv `build/.venv` (системный cairo через homebrew уже был). `qlmanage` убран из обязательных тулов; добавлен резолв `$CAIROSVG` (venv → PATH → понятная ошибка). Рендер базы: `cairosvg ... --output-width 1024 --output-height 1024` → `sips -z` 10 размеров (сохраняет альфу) → `iconutil -c icns`. И `AppIcon.icns`, и `applet.icns` (cp). Порядок прежний: icns → Info.plist (CFBundleIconFile=AppIcon, remove CFBundleIconName) → strip xattr → codesign.
- ПРОВЕРКА БЕЗ GUI (PIL): углы базового PNG, обоих `.icns` в бандле И `AppIcon.icns` ВНУТРИ смонтированного dmg → все четыре угла + (6,6) = **alpha 0 (прозрачные)**; центр (253,221,198,255) непрозрачный. End-to-end подтверждено.

### B3 — фон DMG: перерендер через cairosvg (FIXED, без правки SVG)
- Содержимое `branding/dmg-background.svg` НЕ трогал (Юрка уже отредактировал: убрал контуры-слоты, опустил плашки до y≈246). Только перерендерил PNG через cairosvg (qlmanage отдавал устаревший кэш).
- `cairosvg dmg-background.svg --output-width 1100 --output-height 500` → `branding/dmg-background.png`; `--output-width 2200 --output-height 1000` → `@2x`. **Грабли:** короткие флаги `-W/-H` cairosvg игнорирует, если в SVG задан `width/height` — нужны ДЛИННЫЕ `--output-width/--output-height`.
- ПРОВЕРКА: размеры 1100×500 и 2200×1000 (sips); светлая плашка в зоне y250–295/x80–250 — яркость min 218 / mean 229 (ВЫСОКАЯ → светлая, не тёмная). Подтверждено.

### C3 — побочный блокер сборки: FinderInfo от iCloud (FIXED)
- Сборка падала на `codesign --verify --deep --strict`: «resource fork, Finder information ... not allowed». Причина — репо в **синхронизируемой папке** (`com.apple.fileprovider.fpfs#P`): демон асинхронно ставит `com.apple.FinderInfo` на КОРЕНЬ бандла между `xattr -cr` и verify. Не связано с моим фиксом (предсуществующее окружение).
- Фикс `build/build-app.sh`: между `codesign --force` и `--verify` добавлено снятие FinderInfo с корня обёртки (`xattr -c` + `xattr -d com.apple.FinderInfo`). Безопасно — xattr на каталоге-обёртке, не на подписанном payload. После фикса: `valid on disk` + `satisfies its Designated Requirement`, exit 0.

### Артефакт (готов, НЕ коммичено)
- `build/dist/fb2-to-epub-0.1.0.dmg` (2.8M), sha256 `d8fdd1e42d9cde3286f63a9e0da66e8a8a01aa45cc54fbafc397207ab9a4e884`.
- Валидация: `bash -n` обоих скриптов OK. Изменены мной: `build/build-app.sh` + перерендер `dmg-background.png`/`@2x.png` (содержимое SVG не трогал).

### РАСХОЖДЕНИЯ для Юрки
- **Геометрия фон/окно:** фон 1100×500, но `make-dmg.sh`/`dmg-settings.py` держат окно 660×400 и координаты иконок app@(165,185)/Applications@(495,185) рассчитаны под 660-ширину. Фон шире окна (top-left anchor, безопасно от белого провала по логике скрипта), НО логические X-координаты светлых плашек/подписей в SVG (холст 1100) могут НЕ совпасть с позициями иконок в окне 660. Проверять визуально в Finder.
- `make-dmg.sh` и `dmg-background.svg` помечены git как M — это НЕ мои правки (были в рабочем дереве worktree от предыдущих шагов до меня).

Открытый гейт: визуальный рендер dmg в Finder — снимает Юрка (углы иконки теперь прозрачны на уровне пикселей; рамки быть не должно).
