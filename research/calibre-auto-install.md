# Техисследование: авто-установка Calibre из приложения (macOS)

**Проект:** fb2-to-epub · **Фаза:** Discovery P2 (техисследование)
**Дата:** 2026-07-19 · **Автор:** Researcher (команда Юрки)
**Все URL/размеры/суммы проверены вживую HEAD/GET-пробами и веб-фетчем в дату отчёта.**

Контекст: наше приложение — нативное macOS (SwiftUI, ad-hoc codesign, БЕЗ sandbox, есть
Full Disk Access) + launchd-агент. Нужны только **CLI-бинари** Calibre
(`ebook-convert`, `ebook-meta`, `ebook-polish`), GUI не запускаем. Задача — кнопка
«Установить Calibre», максимально автоматизирующая скачивание+установку, + fallback-инструкция.

---

## Итог / рекомендуемый путь

**Основной путь:** приложение скачивает официальный DMG по стабильному URL
`https://calibre-ebook.com/dist/osx` (302 → GitHub releases текущей версии) **через
URLSession/curl** (не через браузер) → проверяет целостность по опубликованному
**SHA-512** (`/signatures/<файл>.sha512`) → `hdiutil attach` → копирует `calibre.app`
**в папку, которой владеет наше приложение** (напр. `~/Library/Application Support/fb2-to-epub/`
или `~/Applications/`) через `ditto` → `hdiutil detach` → зовёт CLI по абсолютному пути
`<...>/calibre.app/Contents/MacOS/ebook-convert`.

Почему так работает без трений: Calibre **подписан Developer ID + нотаризован**, а скачивание
через curl/URLSession **не ставит `com.apple.quarantine`** (наше приложение не в sandbox) →
Gatekeeper не блокирует запуск CLI, ручной «Open» не нужен. Установка в свою папку обходит
и права на `/Applications`, и TCC-защиту «App Management», и не требует прав администратора.
Homebrew — только опциональный вторичный путь (на свежем Mac brew обычно нет). Права на
редистрибуцию не нарушаются: GPLv3-софт тянется с официального источника (это не наша
редистрибуция, если мы НЕ бандлим бинарники внутрь приложения).

---

## Находки (факт → источник → уверенность)

### 1. Официальный DMG и стабильный URL «последней версии»

- **`https://calibre-ebook.com/dist/osx` существует и делает 302 → GitHub releases текущей
  версии.** Живая цепочка редиректов: `/dist/osx` → 302 →
  `github.com/kovidgoyal/calibre/releases/download/v9.11.0/calibre-9.11.0.dmg` → 302 →
  `release-assets.githubusercontent.com/...` → HTTP 200,
  `content-disposition: attachment; filename=calibre-9.11.0.dmg`.
  → проба `curl -sIL https://calibre-ebook.com/dist/osx` (2026-07-19) — **high**.
- **Текущая версия — 9.11.0.** → GitHub API
  `https://api.github.com/repos/kovidgoyal/calibre/releases/latest` → `tag_name: v9.11.0` — **high**.
- **Один DMG на macOS = universal binary (arm64 + x86_64).** В GitHub-релизе для macOS
  только `calibre-9.11.0.dmg`; отдельных arm64/x86_64 сборок под macOS нет (файлы
  `calibre-9.11.0-arm64.txz` / `-x86_64.txz` — это **Linux**-сборки). →
  `api.github.com/.../releases/latest` (список ассетов) — **high**.
- **Размер DMG: 344 425 061 байт ≈ 328,5 МБ.** → `content-length` в HEAD-пробе и в GitHub API — **high**.
- **Версионированные URL (стабильные, для конкретной версии):**
  - GitHub: `https://github.com/kovidgoyal/calibre/releases/download/v9.11.0/calibre-9.11.0.dmg` — **high**;
  - Зеркало Calibre: `https://download.calibre-ebook.com/9.11.0/calibre-9.11.0.dmg`
    (HEAD → HTTP 200, тот же размер 344 425 061) — **high**.
- **Минимальная macOS для 9.11.0 — 14.0 (Sonoma) и выше.** Легаси-версии для старых ОС:
  7.26 (до Sonoma), 6.29 (до Ventura). → `calibre-ebook.com/download_osx` (WebFetch) — **high**.
- Способ определить «последнюю версию» программно: либо всегда качать `/dist/osx` (сам ведёт
  на актуальную), либо читать `tag_name` из GitHub API. Отдельного текстового
  version-endpoint у calibre-ebook.com нет: `/dist/version`, `/latest` → 404;
  `code.calibre-ebook.com/latest` — не отвечает (HTTP 000). → живые пробы — **high**.

### 2. Тихая установка из DMG (наш сценарий)

- **Сценарий реалистичен:** `hdiutil attach <dmg>` (смонтировать) → `ditto <mount>/calibre.app
  <dest>/calibre.app` (скопировать) → `hdiutil detach <mount>`. Официальная инструкция
  Calibre прямо разрешает копировать `.app` «в любую папку файловой системы (Desktop,
  Applications, куда угодно)», запускать прямо из образа не надо. →
  `calibre-ebook.com/download_osx` (WebFetch) — **high**.
- **Права администратора для нашего кейса НЕ нужны**, если ставить в папку пользователя
  (`~/Library/Application Support/…` или `~/Applications/`). Это и есть рекомендованное место,
  т.к. нам нужен только CLI по абсолютному пути. — **high** (следствие модели прав macOS).
- **Про `/Applications` (если всё же туда):** админ-пользователь может записать **новый**
  `.app` в `/Applications` без sudo (папка группы `admin`, `rwxrwxr-x`). **Но** macOS 13+
  вводит TCC-защиту «App Management»: приложение НЕ может **перезаписать/обновить чужой**
  app-бандл в `/Applications`, который оно не устанавливало → ошибка «Operation not permitted»,
  пока пользователь не выдаст разрешение в System Settings → Privacy & Security → App
  Management. Т.е. первый install может пройти, а **обновление** существующего
  `/Applications/calibre.app` — упрётся в TCC. → Apple/eclecticlight/HackTricks по App
  Management + сообщения о «ditto /Applications → Operation not Permitted» — **med-high**.
  Вывод: ставить в свою папку — обходит проблему целиком.
- **Quarantine/Gatekeeper — ключевой момент, играет за нас:** `com.apple.quarantine`
  проставляют только приложения, включившие File Quarantine (`LSFileQuarantineEnabled`) —
  браузеры (Safari/Chrome/Firefox) ставят; **`curl`/`wget` и обычный URLSession
  не-sandbox-приложения — НЕ ставят**. Наше приложение без sandbox → DMG, скачанный им через
  curl/URLSession, будет **без карантина** → скопированный `calibre.app` тоже без карантина →
  `ebook-convert` запускается сразу, без диалога «Open». → Apple LSFileQuarantineEnabled +
  eclecticlight «Quarantine and the quarantine flag» + Red Canary Gatekeeper Bypass — **high**.
- **Calibre подписан Developer ID и нотаризован Apple.** Подтверждается build-кодом самого
  Calibre: `calibre/bypy/macos/sign.py` импортирует из `bypy.macos_sign` функции
  `codesign, create_entitlements_file, make_certificate_useable, notarize_app,
  verify_signature`. Практическое следствие: **даже** если DMG попадёт под карантин (напр.
  fallback через браузер) — после проверки Gatekeeper `.app` пройдёт как доверенный, а CLI
  внутри нотаризованного бандла исполнится. → GitHub `kovidgoyal/calibre/bypy/macos/sign.py`
  (WebSearch/исходник) — **high**.
- **Путь к CLI:** `calibre.app/Contents/MacOS/` — там `ebook-convert`, `ebook-meta`,
  `ebook-polish`, `calibre-debug`, `calibre` и др. Подтверждено stanza Homebrew-cask
  (`$APPDIR/calibre.app/Contents/MacOS/calibre` → симлинк в bin). →
  `formulae.brew.sh/api/cask/calibre.json` — **high**.

### 3. Homebrew (вторичная опция, не основной путь)

- **`brew install --cask calibre` существует и рабочий** (cask `calibre`, version 9.11.0,
  url `download.calibre-ebook.com/9.11.0/calibre-9.11.0.dmg`, ставит в `/Applications/calibre.app`,
  симлинкует CLI в `$HOMEBREW_PREFIX/bin`). → `formulae.brew.sh/api/cask/calibre.json` — **high**.
- **Полагаться как на ОСНОВНОЙ путь нельзя:** на свежем Mac Homebrew обычно отсутствует,
  его установка требует Xcode Command Line Tools и запуска стороннего `curl … | bash`
  инсталлятора → тяжелее, дольше, и это уже «поставь сначала другой менеджер». Годится как
  **опциональная** ветка «если brew уже есть — предложить `brew install --cask calibre`». — **high**.

### 4. Официальный CLI-инсталлер Calibre для macOS?

- **НЕТ.** Официальный однострочный инсталлер (`wget -nv -O-
  https://download.calibre-ebook.com/linux-installer.sh | sh /dev/stdin`) существует **только
  для Linux**. Для macOS официальный способ — **только DMG** (drag-install), CLI-инсталлера
  нет. → `calibre-ebook.com/download_osx` (нет упоминания CLI-установки для macOS) +
  общеизвестный linux-installer.sh — **high**.

### 5. Правовое/этичное (GPLv3, откуда качать)

- **Calibre — GPL v3.** Автоматическое скачивание официального дистрибутива с сайта
  вендора и локальная установка на машину пользователя — это **получение софта из
  официального источника, а не наша редистрибуция**. GPLv3 такое не ограничивает; никаких
  обязательств по передаче исходников у нас не возникает, **пока мы не бандлим бинарники
  Calibre внутрь своего приложения**. → GPLv3 (общая норма) + модель распространения Calibre — **high** (правовое рассуждение; окончательный вывод по комплаенсу — за legal-analyst/Юркой).
- **Откуда качать:** оба канала официальные и эквивалентны —
  `calibre-ebook.com/dist/osx` (редиректит на GitHub) и зеркало
  `download.calibre-ebook.com/<ver>/…`. GitHub releases — это и есть штатный хостинг релизов
  Calibre (тот же файл, тот же размер). Рекомендация: бить в `/dist/osx` (всегда актуальная
  версия), зеркало `download.calibre-ebook.com` — как запасной. — **high**.
- ⚠️ Красная линия: **не** класть скачанные бинарники Calibre в git/в дистрибутив нашего
  приложения и не выдавать их за своё — тянуть строго в рантайме с официального URL. — **high**.

### 6. Проверка целостности скачанного

- **SHA-512 публикуется по каждому файлу:**
  `https://calibre-ebook.com/signatures/calibre-9.11.0.dmg.sha512`
  (HTTP 200, 128 hex-символов). Реальное значение для 9.11.0:
  `6506431a9142688f993364f327b7b93cebb1ef9318cda4ada27629236daa9e6ad0ebcc8eafd5d050ae677f564b364a1454fa20a3f815ceb8db81e2e44475cba4`.
  → GET содержимого файла (2026-07-19) — **high**.
- **Детач-подпись GPG публикуется по каждому файлу:**
  `https://calibre-ebook.com/signatures/calibre-9.11.0.dmg.sig`
  (HTTP 200, `application/pgp-signature`, 566 байт). Паттерн каталога `/signatures/`:
  на каждый релиз — `<файл>.sha512` + `<файл>.sig`. → HEAD-пробы + листинг `/signatures/` — **high**.
- **Независимый третий контрольный канал — Homebrew** держит **SHA-256** того же DMG:
  `300c1acf1f8b941e265d0f8c39fc608c3cfea865a31702e084643d536b78c951`. →
  `formulae.brew.sh/api/cask/calibre.json` — **high**.
- **GPG-ключ подписи — Kovid Goyal, key ID `06BC317B515ACE7C`.** → WebSearch (не сверял
  отпечаток независимо в этой сессии) — **med**.
- **Практичная рекомендация по проверке:** минимально — сверять **SHA-512** скачанного DMG
  со значением из `/signatures/…​.sha512` (оба по HTTPS с calibre-ebook.com; при желании
  «пояс+подтяжки» — ещё и SHA-256 из Homebrew). GPG-верификация даёт **аутентичность**
  (не только целостность), но требует вшить/импортировать публичный ключ Kovid и наличие
  `gpg` — это опция «максимальной строгости», не обязательная для MVP. — **high** (инженерная рекомендация).

### 7. Как другие приложения решают «нужна внешняя зависимость → кнопка установить» (кратко)

- Типовые паттерны (не копал глубоко): (а) **скачать официальный артефакт зависимости в
  свою папку + проверить контрольную сумму + звать по абсолютному пути** — так делают
  обёртки над ffmpeg/yt-dlp и т.п.; (б) **предложить установку через пакетный менеджер**
  (`brew install …`) с кнопкой-хелпером; (в) **направить пользователя на официальный
  установщик** с краткой инструкцией (fallback). Для нашего кейса оптимален (а) +
  (в) как запасной. — **med** (обзорно, без глубокой выборки примеров).

---

## Таблица вариантов (trade-off)

| Вариант | Автоматизация | Права admin | Quarantine-риск | Зависимости | Надёжность на свежем Mac | Вердикт |
|---|---|---|---|---|---|---|
| **DMG + curl/URLSession → ditto в свою папку** | высокая | не нужны | нет (curl не ставит карантин) | нет | высокая | **основной** |
| DMG → ditto в `/Applications` | высокая | не нужны для 1-го install | нет | нет | средняя (TCC App Management на update) | запасной |
| `brew install --cask calibre` | средняя | зависит от префикса brew | нет (brew снимает) | **нужен Homebrew + Xcode CLT** | низкая (brew часто отсутствует) | опция «если brew есть» |
| Ручная инструкция (скачать DMG, перетащить) | нулевая | — | да (браузер ставит карантин), но Calibre нотаризован → GUI-запуск ок | нет | высокая | **fallback-инструкция** |
| Бандлить бинарники Calibre в наше приложение | — | — | — | — | — | ❌ GPLv3-обязательства + вес; не делаем |

---

## Противоречия между источниками

**Нет.** Данные из calibre-ebook.com, GitHub API, Homebrew-cask и build-исходника Calibre
согласованы (версия 9.11.0, размер 344 425 061 Б, пути CLI, факт подписи/нотаризации).

## Пробелы данных

- **Точное поведение Gatekeeper при exec CLI из карантинного, но нотаризованного бандла** —
  нюансно; но для основного пути **неактуально** (curl не ставит карантин).
- **Отпечаток GPG-ключа Kovid** не сверял независимо в этой сессии (**med**).
- **Полевая проверка на целевой машине** (реальные `hdiutil`/`ditto`/`spctl -a`/xattr)
  не проводилась — 328 МБ здесь не качал. Рекомендуется прогнать точную последовательность
  на новом Mac до релиза фичи.

---

## Открытые вопросы к человеку

1. **Куда ставить `calibre.app`?** Рекомендация — папка приложения
   (`~/Library/Application Support/fb2-to-epub/calibre.app`), не `/Applications` (обходит
   admin/TCC, GUI нам не нужен). Подтвердить выбор места.
2. **Строгость проверки целостности для MVP:** достаточно ли SHA-512 по HTTPS, или сразу
   закладываем и GPG-верификацию (вшить публичный ключ Kovid)?

## Предлагаемый следующий шаг

Фактура для решения собрана — **готово к передаче в планирование фичи** (PRD/архитектура
кнопки «Установить Calibre»). Перед реализацией — короткая полевая проверка точной
последовательности `curl → shasum -a 512 → hdiutil attach → ditto → hdiutil detach → exec
ebook-convert` на новом Mac (валидирует quarantine-гипотезу вживую).
