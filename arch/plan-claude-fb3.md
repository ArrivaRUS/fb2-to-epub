# План (Архитектор #1, Claude) — поддержка FB3 в конвертере

> Фаза 3, планирование. Путь зафиксирован человеком и НЕ оспаривается:
> **FB3 → FB2 (трансформ на системном python3, только stdlib) → существующий
> конвейер FB2→EPUB** (Calibre `ebook-convert` + наш cover-finder/cover-gen).
> Прямой FB3→EPUB и официальный Perl-инструмент отвергнуты (раздача через DMG —
> нельзя тянуть Perl/CPAN/librsvg на чужой Mac).

---

## Итог

Добавляем один автономный python3-скрипт `fb2-to-epub-fb3.py` (stdlib:
`zipfile`, `xml.etree.ElementTree`, `base64`, `json`, `argparse`), который
распаковывает FB3 (OPC/ZIP) в память, транслирует `body.xml`+`description.xml`
в один FB2-файл (семантика — по официальным XSLT `fb3_2_fb2_body.xsl` /
`fb3_2_fb2_descr.xsl`), инлайнит картинки в `<binary>` base64 и выставляет
обложку из OPC-thumbnail. lxml НЕ нужен — ElementTree корректно пишет дефолтный
namespace gribuser + префикс `l:` (xlink) (проверено). Watcher получает ровно
**одну** новую точку расширения: при детекте `.fb3` зовём трансформ → временный
`.fb2` → дальше СУЩЕСТВУЮЩИЙ `convert_book` без изменений (cover-finder сам
увидит вшитую обложку через `ebook-meta` и не полезет в сеть; книги без обложки
получат нашу генерёжку). Это минимизирует движущиеся части: весь риск — в одном
изолированном, юнит-тестируемом скрипте; конвейер EPUB и cover-логика не трогаются.

**Ключевая находка из реальных файлов:** оба образца с Desktop объявляют обложку
ТОЛЬКО как OPC package thumbnail (`_rels/.rels` → `metadata/thumbnail` →
`fb3/img/cover.jpg`), а НЕ через элемент `<coverpage>` в `description.xml`.
Официальный XSLT эмитит FB2 `<coverpage>` лишь при наличии `fb3d:coverpage` —
т.е. на этих файлах дал бы FB2 БЕЗ обложки. Поэтому в нашем трансформе обложку
резолвим из OPC-thumbnail (надёжнее), а `<coverpage>` поддерживаем как
дополнительный источник. Иначе у книг с родной обложкой зря включалась бы наша
генерёжка.

---

## Архитектура трансформа

**Файл:** `bin/fb2-to-epub-fb3.py` (рядом с `bin/fb2-to-epub-cover-finder.py` и
`bin/fb2-to-epub-cover-gen.py` — единое место, единый путь бандла/установки).

**Зависимости:** только stdlib системного python3.
- `zipfile` — FB3 = OPC/ZIP.
- `xml.etree.ElementTree` — парс FB3, сборка FB2 (lxml отсутствует, проверено
  `python3 -c "import lxml"` → ImportError; ElementTree достаточно).
- `base64` — инлайн картинок в `<binary>`.
- `json` — загрузка `fb3-genre-map.json` (жанры).
- `argparse`, `sys`, `os`, `re` — CLI/утилиты.

**CLI-контракт** (зеркалит стиль cover-finder — argv, коды возврата, абсолютные пути):
```
fb2-to-epub-fb3.py [--out <path.fb2>] [--genre-map <path.json>]
                   [--quiet] <input.fb3>
```
- Вход: позиционный `<input.fb3>` (абсолютный путь).
- Выход:
  - `--out <file>` → пишет FB2 в этот файл (так зовёт watcher: во временный `.fb2`).
  - без `--out` → FB2 в **stdout** (удобно для тестов/отладки).
- `--genre-map` — путь к `fb3-genre-map.json`; по умолчанию ищем рядом со
  скриптом (`os.path.dirname(__file__)/fb3-genre-map.json`), как cover-finder
  ищет соседние ресурсы.
- **Коды возврата** (watcher ветвится по ним, как уже делает с cover-finder):
  - `0` — успех (FB2 записан).
  - `2` — вход не похож на FB3 (нет `[Content_Types].xml` / `description.xml`
    / `body.xml`) → watcher логирует и пропускает (НЕ падает).
  - `1` — внутренняя ошибка трансформа (битый XML и т.п.) → watcher логирует
    FAIL, чистит temp, идёт дальше.
- Диагностика — в **stderr** (watcher уже редиректит `2>>"$LOG_FILE"`), на
  stdout только FB2 (или ничего при `--out`).

**Внутренняя структура (модули в одном файле, чистые функции — легко юнит-тестить):**

| Функция | Ответственность |
|---|---|
| `open_fb3(path) -> Fb3Package` | Открыть ZIP; прочитать `[Content_Types].xml`, корневой `_rels/.rels`, `fb3/description.xml`, `fb3/_rels/description.xml.rels`, `fb3/body.xml`, `fb3/_rels/body.xml.rels`. Найти путь к body/description через `.rels` по Type (не хардкодить `fb3/body.xml` — резолвить, как делает официальный инструмент через OPC). Вернуть структуру с деревьями ET + словарями rels + zip-handle. |
| `RelResolver` | Аналог Perl-расширений `ltr:RplId`/`RplLocalHref`. `rid_to_target(rid)` — rId→путь файла внутри ZIP (по `body.xml.rels`). `RplId(src)` — нормализует id картинки в FB2 (см. «Картинки»). Хранит карту «rId → выбранный FB2-binary-id», чтобы один файл инлайнился один раз. |
| `map_body(fb3_body_tree, rel) -> (sections, notes_bodies)` | Рекурсивный обход FB3 body → список FB2-элементов `<body>` и (если есть notes) `<body name="notes">`. Реализует таблицу тегов ниже. |
| `map_descr(fb3_descr_tree, rel, genre_map) -> <description>` | FB3 description → FB2 `<title-info>`/`<document-info>`/`<publish-info>`/`<custom-info>`. Реализует таблицу метаданных. |
| `collect_images(rel, zip) -> list[Binary]` | Собрать все картинки, на которые есть ссылки (body `<img>` + обложка), прочитать байты из ZIP, base64, content-type из расширения/`[Content_Types]`. |
| `resolve_cover(pkg, descr_tree) -> cover_id|None` | Источник обложки: (1) `fb3d:coverpage/@href` если есть; иначе (2) OPC-thumbnail из корневого `_rels/.rels` (`metadata/thumbnail` → файл, обычно `fb3/img/cover.jpg`). Вернуть id для `<coverpage><image l:href="#id"/></coverpage>` + пометить картинку на инлайн. SVG → деградация (см. ниже). |
| `build_fb2(descr, body, notes, binaries) -> bytes` | Собрать корень `<FictionBook>` с ns gribuser + xlink, `register_namespace("", FB2)`, `register_namespace("l", XLINK)`. Порядок: `description`, `body`, `body name=notes`, затем все `<binary>`. Сериализовать UTF-8 с XML-декларацией. |
| `main(argv)` | argparse → пайплайн → запись/stdout → коды возврата. |

**Почему ElementTree, а не ручная сборка строк:** stdlib ET корректно
эмитит `xmlns="…gribuser…"` + `xmlns:l="…xlink"` и атрибуты `l:href`
(проверено round-trip'ом). Это даёт валидный FB2 без ручного экранирования
unicode/кавычек/control-байт (та же причина, по которой watcher делегирует JSON
питону). Текстовые узлы и `tail` ET сохраняет — это критично для смешанного
inline-контента (`<p>текст <em>курсив</em> ещё текст</p>`).

---

## Маппинг (таблицы тегов + метаданных)

Источник истины — `fb3_2_fb2_body.xsl` и `fb3_2_fb2_descr.xsl`. Namespaces:
FB3 body `http://www.fictionbook.org/FictionBook3/body`, FB3 descr
`http://www.fictionbook.org/FictionBook3/description`, xlink
`http://www.w3.org/1999/xlink` → FB2 `http://www.gribuser.ru/xml/fictionbook/2.0`
+ xlink. **Правило id:** при копировании любого `@id`/целевого id в FB2 — префикс
`u` (XSLT делает так везде: `id="u{...}"`), чтобы id были валидны и не сталкивались.

### BODY (`fb3_2_fb2_body.xsl`)

| FB3 (body ns) | FB2 | Примечания / условия из XSLT |
|---|---|---|
| `fb3-body` | `body` (+ опц. `body name="notes"`) | Порядок детей body: `title`, `epigraph`, `preamble`, `section`. Сноски — отдельным `<body name="notes">` после основного. |
| `title` (родитель ≠ blockquote) | `title` | |
| `title` (родитель = blockquote) | `subtitle` | XSLT: title внутри цитаты → subtitle. |
| `subtitle` | `subtitle` (`id`→`u{id}`) | |
| `annotation` | `annotation` | |
| `epigraph` | `epigraph` | |
| `preamble` | `section` | Обернуть в section. |
| `section` | `section` (`id`→`u{id}`) | Рекурсивно, вложенность сохраняется. |
| `p` (обычный) | `p` (`id`→`u{id}`) | |
| `p` (ровно 1 `img`, без др. тегов, текст пуст, родитель ≠ title) | разворачивается: только `<image>` + `<empty-line/>` (если родитель ≠ div) | XSLT спец-кейс «картинка-абзац»: НЕ оборачивать в `<p>`. |
| `p` (родитель = title внутри blockquote) | inline-контент без обёртки | |
| `br` | `empty-line` | |
| `strong` | `strong` | |
| `em` | `emphasis` | Ключевое переименование! |
| `sub` | `sub` | |
| `sup` | `sup` | |
| `strikethrough` | `strikethrough` | |
| `span` | (разворачивается, контент наследуется) | Нет обёртки. |
| `underline`, `spacing`, `marker`, `paper-page-break` | (убрать обёртку, контент сохранить) | Нет аналога в FB2 — «just kill». |
| `code` (вне stanza) | `code` | |
| `code` (внутри stanza) | (без обёртки) | |
| `pre` | `cite > p > code` | |
| `blockquote` | `cite` (`id`→`u{id}`) | |
| `div[@on-one-page='true']` | контент + `empty-line` | Без обёртки. |
| `div` (обычный), если содержит `p` с одним `img` и пустым текстом | контент + `empty-line` | Картиночный div. |
| `div` (обычный, прочее) | `cite` (`id`→`u{id}`) | |
| `img` | `image l:href="#u{RplId(@src)}"` (+ `alt`, + `id`→`u{RplId(@id)}`) | `@src`=rId → файл → FB2-binary-id (см. «Картинки»). |
| `a` (`@l:href`) | `a l:href="…"` | Внутр. ссылка: `RplLocalHref(RplId(@l:href),'u')` — если href вида `#id`, заменить на `#u{id}`; внешние URL — как есть. |
| `note` (`@href`) | `a l:href="#u{@href}" type="note"` | Сноска-ссылка в тексте. (Реальный пример: `<note href="n_1" xlink:role="footnote">1</note>` → `<a l:href="#un_1" type="note">1</a>`.) |
| `poem` | `poem` | |
| `stanza` | `stanza`; внутри `p`→`v`, `br`→(удалить) | |
| `subscription` (вне poem) | (контент без обёртки) | |
| `subscription` (в poem) | `text-author` | |
| `table` | `table` (`id`→`u{id}`) | |
| `tr` | `tr` | |
| `th` | `th`; `th/p`→контент без обёртки | |
| `td` | `td` (`id,align,colspan,rowspan`); `td/p`→контент без обёртки | |
| `ul` | `cite` со списком; каждый `li`→`p` с префиксом `@type` (или `•`) | FB2 не имеет списков → эмулируем через cite+p. |
| `ol` | `cite`; каждый `li`→`p` с префиксом = номер позиции | |
| `li` | `p` (префикс + ` ` + контент) | Префикс приходит параметром от ul/ol. |
| `notes` (единственный) | `body name="notes"`; `notebody`→`section id="u{id}"` | |
| `notes` (несколько, count>1) | один `body name="notes"`, каждый `notes`→`section` | XSLT сортирует по `@show desc`; для нашей задачи порядок документа достаточен (отметить как допустимое упрощение). |
| `notebody` | `section id="u{id}"` | |

> **Реальные образцы покрывают:** `p, em, strong, br, section, title, subtitle,
> div(on-one-page), blockquote, img, epigraph, subscription, poem, stanza, notes,
> notebody, note`. Остальные (`table/ul/ol/pre/sub/sup/strikethrough/a`) есть в
> схеме `fb3_body.xsd` — мапим по XSLT, но на образцах не отрабатываются →
> добавить синтетический тест (см. тест-план).

### DESCRIPTION (`fb3_2_fb2_descr.xsl`)

| FB3 (descr ns) | FB2 | Примечания |
|---|---|---|
| `fb3-description` | `description` | Контейнер. |
| `fb3-classification/subject` | `title-info/genre` (lowercased, через genre-map) | Текст subject → lower → ключ в `fb3-genre-map.json` → FB2-жанр. См. «жанры» ниже. |
| `fb3-relations/subject[@link='author']` | `title-info/author` | `first-name`/`middle-name?`/`last-name`/`id`. Если авторов нет → `<author><nickname>Аноним</nickname></author>`. |
| `fb3-relations/subject[@link='translator']` | `title-info/translator` | Та же структура. |
| `title/main` | `title-info/book-title` | |
| `annotation` | `title-info/annotation` (inline: `p/br/strong/em/a`) | |
| `keywords` | `title-info/keywords` | |
| `written/date` | `title-info/date value=…` | Текст = текст date или год из `@value`. |
| `coverpage` (если есть) | `title-info/coverpage/image l:href="#{RplId(@href)}"` | На образцах ОТСУТСТВУЕТ → обложку берём из OPC-thumbnail (см. «Картинки+обложка»). |
| `lang` | `title-info/lang` | |
| `written/lang` | `title-info/src-lang` | |
| `sequence` | `title-info/sequence name=… number=…?` (рекурс.) | name = `sequence/title/main`. |
| `document-info` (атрибуты) | `document-info/author><nickname>{@editor||Аноним}` + `program-used?` + `date value=created` + `src-url?` + `src-ocr?` | |
| `@id` (корня), `@version` | `document-info/id`, `document-info/version` | |
| `history` | `document-info/history` (inline) | |
| `paper-publish-info` | `publish-info` (`book-name`=@title, `publisher?`, `city?`, `year?`, `isbn?`, `sequence?`) | |
| `custom-info` | `custom-info info-type=…` | |
| `periodical/title/sequence/fb3-classification/written/translated/copyrights` | `custom-info` (по `mode="custom-info"`) | XSLT раскладывает доп. поля в плоские `custom-info` с `info-type`-путём. **MVP:** воспроизвести базовый набор (title/sequence/classification/written/translated/copyrights → custom-info), сложную рекурсию атрибутов — пометить как частичную (см. риски). |

**Жанры (`fb3-genre-map.json`):** это `dict` (906 ключей), ключ = русский текст
subject в нижнем регистре, значение = FB2-жанр (например
`"личные финансы" → "global_economy"`, `"астрономия" → "sci_phys"`).
Алгоритм для каждого `fb3d:fb3-classification/subject`:
1. `key = subject.text.strip().lower()` (XSLT-шаблон `lower` translate'ит кириллицу+латиницу — повторяем питоновским `.lower()`).
2. если `key in map` → `<genre>` = `map[key]`; иначе → пропустить subject (или
   эмитить как `custom-info`, чтобы не терять; решение — см. вопрос Q3).
3. дедуп получившихся FB2-жанров (несколько subject могут смапиться в один).
4. если в итоге 0 жанров → не добавлять `<genre>` (FB2 допускает; либо дефолт
   `prose_contemporary` — вопрос Q3).

**Бандлинг genre-map:** скопировать `fb3_to_fb2_genre.json` в репо как
`bin/fb2-to-epub-fb3-genre.json` (рядом со скриптом) и забандлить в Resources +
поставить в App Support/bin вместе со скриптом (см. «Сборка+установка»).
НЕ хардкодить подмножество — 906 строк, полная таблица даёт корректные жанры и
почти ничего не весит (~55 КБ).

---

## Картинки + обложка

**Резолв rId → файл (аналог `ltr:RplId`):**
1. Распарсить `fb3/_rels/body.xml.rels` → `{Id: Target}` (Target относителен к
   `fb3/`, напр. `img2 → img/i_001.jpg` → полный zip-путь `fb3/img/i_001.jpg`).
2. `<img src="img2"/>`: `@src` — это rId. `RplId("img2")` →
   находим Target → выбираем стабильный **FB2-binary-id** = basename без
   директории (`i_001.jpg`), пер-файл уникализируем (если коллизия basename —
   добавить суффикс). Карта «rId → binary-id» кешируется в `RelResolver`.
3. В body: `<image l:href="#u{binary_id}"/>` (с префиксом `u`, как в XSLT).
4. В конце документа: один `<binary id="u{binary_id}" content-type="image/jpeg">
   {base64}</binary>` на каждый РЕАЛЬНО использованный файл (дедуп: один файл —
   один binary, даже если на него N ссылок).

> Тонкость: XSLT кладёт `id="u{RplId(@id)}"` на сам `<image>` только если у
> `<img>` был `@id`; href-id (`#u{RplId(@src)}`) — всегда. У `<binary>` id
> должен совпадать с тем, на что ссылается href. Берём единый `u{binary_id}`
> для href и binary; `@id` самого image (если есть) — отдельный, как в XSLT.

**Content-type:** по расширению Target (`.jpg/.jpeg→image/jpeg`,
`.png→image/png`, `.gif→image/gif`, `.svg→image/svg+xml`); сверяем с
`[Content_Types].xml` (Default Extension) — он у FB3 как раз это и задаёт.

**Обложка (порядок источников):**
1. Если в `description.xml` есть `fb3d:coverpage/@href` → это rId в
   `description.xml.rels` → файл → инлайн как `<binary>` + FB2
   `<coverpage><image l:href="#u{cover_id}"/></coverpage>` в `title-info`.
2. Иначе (как в ОБОИХ реальных образцах) — корневой `_rels/.rels`, отношение
   `…/metadata/thumbnail` → Target (`fb3/img/cover.jpg`). Инлайним этот файл,
   FB2-binary-id фиксируем = `cover` (конвенция FB2; Calibre ищет
   `coverpage/image` или binary с id `cover`). Эмитим `<coverpage><image
   l:href="#cover"/></coverpage>`.
3. Если ни того, ни другого нет → FB2 без обложки → на следующем шаге наш
   cover-finder/cover-gen сработает (как для FB2 без обложки сейчас).

> **Итог для cover-логики watcher'а:** для FB3 с обложкой FB2 получит вшитую
> обложку → `ebook-meta` в cover-finder увидит embedded cover → finder вернёт
> rc=3 → Calibre оставит родную → сеть/генерёжка НЕ задействуются. Для FB3 без
> обложки — обычный путь (finder ищет / генерёжка). Никаких изменений в
> cover-finder/cover-gen/cover-queue не нужно.

**SVG-деградация (мягко, по приоритету):**
- FB2 `<binary>` исторически ждёт растр; SVG-обложка/картинка может не показаться
  в части читалок, но **Calibre понимает SVG в FB2 binary** — поэтому
  **базовый план: инлайнить SVG как есть** (content-type `image/svg+xml`),
  base64, и проверить на Calibre (шаг теста). Конвертить SVG→PNG нечем (нет
  зависимостей) — НЕ пытаемся.
- Если Calibre споткнётся на SVG-картинке в теле → деградация: **пропустить
  именно эту картинку** (не эмитить ни `<image>`, ни `<binary>`), залогировать
  `WARN svg-skipped <file>`; текст книги не страдает.
- Если SVG — это ОБЛОЖКА и Calibre её не берёт → **не эмитить coverpage** →
  включится наша генерёжка (нативный путь). Логировать `WARN svg-cover-skipped`.
- Решение «инлайнить или пропускать SVG» вынесем во флаг по результату теста на
  Calibre (Q4). На реальных образцах все картинки — JPEG/PNG, SVG не встречается.

---

## Интеграция в watcher

Принцип: **минимальная хирургия**. FB3 «переводится» в FB2 ДО входа в
существующий `convert_book`, который дальше работает без изменений.

**1. Резолв пути к трансформу** (рядом с резолвом `COVER_FINDER`, строки ~64-66):
```bash
FB3_TRANSFORM="${FB3_TRANSFORM:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fb2-to-epub-fb3.py}"
```
genre-map скрипт находит сам рядом с собой (передадим `--genre-map` явно для
надёжности при relocate, путь = `dirname(FB3_TRANSFORM)/fb2-to-epub-fb3-genre.json`).

**2. Распознавание расширения** — расширить `epub_name()` (строки 919-927), чтобы
`.fb3` тоже давал `<name>.epub`:
```bash
*.fb3)     printf '%s' "${name%.[fF][bB]3}.epub" ;;
```
Это автоматически включает `.fb3` в: главный цикл по файлам (через `epub_name`),
`count_pending()` (использует `epub_name`), и в обработку папок —
НО `find` в `process_folder_tree` и `count_pending` фильтрует по
`-iname '*.fb2' -o -iname '*.fb2.zip'`: **добавить `-o -iname '*.fb3'`** в ОБА
`find` (строки ~309 и ~1012), чтобы FB3 внутри папок тоже конвертились.

**3. Точка трансформа** — в начале `convert_book()` (после up-to-date проверки,
строки 929-935), ДО cover-finder. Определяем, FB3 ли это, и если да — гоним
трансформ во временный `.fb2`, дальше работаем с ним как с источником:
```bash
convert_book() {
  local src="$1" dst="$2"
  if [[ -e "$dst" ]] && [[ "$dst" -nt "$src" ]]; then
    log "skip (up-to-date): ${dst#$WATCH_DIR/}"; return 0
  fi
  mkdir -p "$(dirname "$dst")"

  # FB3: transform to a temp .fb2, then reuse the entire existing FB2 path
  # (cover-finder + ebook-convert). Everything downstream sees a normal .fb2.
  local conv_src="$src" fb3_tmp_dir=""
  case "$(printf '%s' "$src" | tr '[:upper:]' '[:lower:]')" in
    *.fb3)
      if [[ -x "$FB3_TRANSFORM" || -n "$PYTHON3" ]]; then
        fb3_tmp_dir="$(mktemp -d -t fb2fb3)"
        local fb2_tmp="$fb3_tmp_dir/book.fb2" rc3=0
        "$PYTHON3" "$FB3_TRANSFORM" --out "$fb2_tmp" \
          --genre-map "$(dirname "$FB3_TRANSFORM")/fb2-to-epub-fb3-genre.json" \
          "$src" >>"$LOG_FILE" 2>&1 || rc3=$?
        if [[ "$rc3" -ne 0 || ! -s "$fb2_tmp" ]]; then
          log "FB3 FAIL (rc=$rc3): ${src#$WATCH_DIR/}"
          rm -rf "$fb3_tmp_dir"
          record_conversion "$src" "$dst" "failed"
          return 0          # skip this book, keep batch going
        fi
        conv_src="$fb2_tmp"
        log "FB3->FB2 ok: ${src#$WATCH_DIR/}"
      else
        log "FB3 skip (no python3/transform): ${src#$WATCH_DIR/}"
        return 0
      fi
      ;;
  esac
  # ... existing cover-finder block, but using $conv_src instead of $src ...
  # ... existing ebook-convert call: "$EBOOK_CONVERT" "$conv_src" "$dst" ...
  rm -rf "$fb3_tmp_dir" 2>/dev/null || true   # add to the function's cleanup tail
}
```
**Важно:** внутри `convert_book` после трансформа заменить `"$src"` на
`"$conv_src"` в ДВУХ местах — вызов cover-finder (строка ~959) и вызов
`ebook-convert` (строка ~989). Лог-строки и `record_conversion`/queue оставить с
исходным `$src` (пользователь видит имя своего `.fb3`). `book_id_for "$dst"` —
без изменений (id от dst). cover_tmp_dir и fb3_tmp_dir чистятся в конце.

> Почему трансформ ВНУТРИ `convert_book`, а не отдельной веткой в главном цикле:
> `convert_book` — единственная точка, через которую идут И файлы из корня, И
> файлы из папок (`process_folder_tree`). Один врез → обе ветки покрыты. DRY.

**4. Cover для FB3:** cover-finder получает `$conv_src` (наш FB2). Если в нём
вшита обложка из OPC-thumbnail → finder через `ebook-meta` вернёт rc=3 →
ветка «embedded» → Calibre оставит родную. Если обложки не было → обычный путь
(finder/queue/генерёжка). **Логика cover-finder/queue не меняется ни на байт.**

**5. Идемпотентность:** `epub_name()` теперь даёт `.epub` и для `.fb3`, а
up-to-date проверка (`[[ "$dst" -nt "$src" ]]`) и `count_pending()` работают по
исходному `.fb3` → `.epub новее .fb3` ⇒ skip. Работает «из коробки» после правок
`epub_name`/`find`.

**6. Логирование:** новые строки `FB3->FB2 ok`, `FB3 FAIL (rc=…)`,
`FB3 skip (no python3)`, плюс WARN'ы трансформа (svg-skipped и т.п.) идут в тот
же `$LOG_FILE`. Формат — как у существующих строк (`log "…: ${src#$WATCH_DIR/}"`).

> ⛔ `runner.sh` (`packaging/fb2-to-epub-runner.sh`) НЕ трогаем — он лишь
> «ответственный» FDA-таргет, запускающий watcher; знать про FB3 ему не нужно.

---

## Сборка + установка

**`build/build-app.sh`** — два `install`-вызова рядом с копированием
cover-finder (строки 111-114):
```bash
install -m 0755 "$REPO_DIR/bin/fb2-to-epub-fb3.py"          "$RES/fb2-to-epub-fb3.py"
install -m 0644 "$REPO_DIR/bin/fb2-to-epub-fb3-genre.json"  "$RES/fb2-to-epub-fb3-genre.json"
```
(скрипт — исполняемый 0755, как cover-finder; JSON — 0644, как cover-templates).

**`packaging/installer.sh`** — поставить трансформ + genre-map в App Support/bin
рядом с cover-finder:
- добавить пути-назначения (рядом со строкой 38 `COVER_DST`):
  ```bash
  FB3_DST="$BIN_DIR/fb2-to-epub-fb3.py"
  FB3_GENRE_DST="$BIN_DIR/fb2-to-epub-fb3-genre.json"
  ```
- найти исходники (рядом со строкой 144):
  ```bash
  src_fb3="$(find_src fb2-to-epub-fb3.py)"          || { echo "fb2-to-epub: missing fb2-to-epub-fb3.py" >&2; exit 1; }
  src_fb3_genre="$(find_src fb2-to-epub-fb3-genre.json)" || { echo "fb2-to-epub: missing fb2-to-epub-fb3-genre.json" >&2; exit 1; }
  ```
  (`find_src` уже ищет в FB2_SRC_DIR / SELF_DIR / ../bin / bin — JSON тоже
  найдётся, т.к. функция матчит любое имя файла.)
- скопировать (рядом со строкой 152-153):
  ```bash
  install -m 0755 "$src_fb3"       "$FB3_DST"
  install -m 0644 "$src_fb3_genre" "$FB3_GENRE_DST"
  ```

> Никаких новых переменных окружения в plist НЕ требуется: watcher резолвит
> `FB3_TRANSFORM` относительно `BASH_SOURCE` (как `COVER_FINDER`), genre-map —
> относительно скрипта. Calibre/python3 уже в env (`EBOOK_CONVERT`/`PYTHON3`).
> Версию DMG поднять как обычно (build-app.sh аргумент).

---

## Тест-план

> Чем проверять: `unzip -p book.epub` + grep по тексту; Calibre `ebook-meta`
> для метаданных/обложки; визуально открыть .epub (Книги.app / Calibre viewer).
> Для трансформа — прямой запуск `python3 bin/fb2-to-epub-fb3.py --out … file.fb3`
> и валидация FB2 (`xmllint --noout` если есть, либо ET-парс в тесте).

**T0. lxml-free smoke:** `python3 -c "import lxml"` падает; трансформ
импортируется и гоняется только на stdlib (CI-инвариант).

**T1. Реальный №1 — «Самый богатый человек в Вавилоне» (есть обложка, notes,
poem, stanza, epigraph, blockquote, div-картинки):**
- трансформ даёт валидный FB2 (ET парсится, есть `<description>`, `<body>`,
  `<body name="notes">`, 13 `<binary>`).
- `ebook-convert` → EPUB без ошибок.
- EPUB: текст глав на месте (grep «Бансир», «Вавилон»); 12 иллюстраций + обложка
  присутствуют (`unzip -l` images); метаданные — автор «Джордж Сэмюэль Клейсон»,
  переводчик «Сергей Борич», заголовок, lang ru, жанры (личные финансы→…); 2
  сноски кликабельны (notes body); обложка = родная `cover.jpg` (Calibre НЕ
  звал finder — лог `cover (embedded)`).

**T2. Реальный №2 — «10-минутное чтение… Мой сосед миллионер» (обложка,
subtitle, меньше картинок):**
- то же: валидный FB2 → EPUB; текст, 1 иллюстрация + обложка, `<subtitle>`
  отрабатывает, метаданные/обложка на месте.

**T3. Краевые (синтетические мини-FB3, собрать в тесте из шаблонов):**
- **без обложки:** удалить thumbnail-rel и coverpage → FB2 без `<coverpage>` →
  EPUB получает обложку через наш finder/генерёжку (проверить, что путь
  включился: лог `cover (none)`/`cover (online…)`/queue).
- **многосекционность:** вложенные `section>section>section` → FB2 сохраняет
  вложенность (XPath глубина в EPUB nav).
- **сноски `count>1`:** два `<notes>` блока → один `<body name="notes">` с двумя
  `<section>`.
- **inline-форматирование:** `<p>a <em>b</em> <strong>c</strong> <sub>d</sub>
  <sup>e</sup> <strikethrough>f</strikethrough></p>` → правильные FB2-теги
  (особенно `em→emphasis`), текст и хвосты (`tail`) не теряются.
- **списки/таблица** (нет в образцах): `<ul>/<ol>/<table>` → cite+p / FB2 table;
  проверить, что не падает и читаемо.
- **внутренняя ссылка + note:** `<a l:href="#sec1">` и `<note href="n_1">` →
  `<a l:href="#usec1">` / `<a l:href="#un_1" type="note">`; target id
  (`section id="usec1"`, `notebody`→`section id="un_1"`) совпадает.
- **битый/не-FB3 вход:** переименованный `.zip` без description → трансформ
  rc=2; `.fb3` с битым XML → rc=1; watcher логирует и НЕ роняет батч, остальные
  книги конвертятся.
- **SVG-картинка:** мини-FB3 с `image/svg+xml` → проверить поведение Calibre
  (показалась / деградировала); зафиксировать решение Q4.

**T4. Идемпотентность:** повторный прогон watcher по тем же `.fb3` → `skip
(up-to-date)`, EPUB не пересобирается; `count_pending` не считает уже готовые.

**T5. Регрессия FB2:** существующие `.fb2`/`.fb2.zip` (и папки с ними)
по-прежнему конвертятся как раньше (FB3-врез их не задевает — `conv_src=src`).

**T6. Сборка/установка:** `build-app.sh` кладёт `fb2-to-epub-fb3.py` +
`…-genre.json` в Resources; `installer.sh` (в изолированном `FB2_SRC_DIR`-режиме,
как существующий install-тест) ставит оба в App Support/bin; watcher их находит.

---

## Микрошаги (каждый < 2 мин, validation-first порядок по зависимостям)

> Milestone'ы по зависимостям: сперва каркас+метаданные (дают валидный FB2 без
> картинок), затем body, затем картинки/обложка, затем интеграция, затем сборка.
> После КАЖДОГО шага — скриншот/прогон (политика студии).

**M1. Каркас трансформа (CLI + OPC-распаковка):**
1. Завести `bin/fb2-to-epub-fb3.py`: argparse (`<input>`, `--out`,
   `--genre-map`, `--quiet`), коды возврата-заглушки, `main`.
2. `open_fb3()`: открыть ZIP, проверить `[Content_Types].xml`; резолв путей
   body/description через `_rels/.rels` + `description.xml.rels` (по Type).
   Не-FB3 → rc=2.
3. Распарсить `description.xml` и `body.xml` в ET; распарсить оба `.rels` в
   словари. Прогон: печать в stderr найденных путей/rId на реальном №1.

**M2. Метаданныe (`map_descr`) + genre-map:**
4. Скопировать `fb3_to_fb2_genre.json` → `bin/fb2-to-epub-fb3-genre.json`;
   загрузка + lookup-функция (lower→FB2-жанр, дедуп).
5. `map_descr`: title-info (genre, author/translator, book-title, annotation,
   keywords, date, lang, src-lang, sequence) по таблице.
6. `map_descr`: document-info (editor/Аноним, program-used, date=created, id,
   version, history) + publish-info + базовые custom-info.
7. `build_fb2` (пока: description + пустой body) + сериализация с ns. Прогон:
   FB2 с метаданными на №1, ET-парсится, автор/жанры верны.

**M3. Body (`map_body`) — текст и форматирование:**
8. Рекурсивный обходчик: `section`(+id u), `title`/`subtitle`, `p`(+id u),
   inline `em→emphasis`/`strong`/`sub`/`sup`/`strikethrough`/`span`/«kill»-теги
   — с сохранением text/tail.
9. Блоки: `epigraph`, `blockquote→cite`, `div`(on-one-page / картиночный /
   cite), `br→empty-line`, `pre`, `code`.
10. `poem`/`stanza`(`p→v`)/`subscription`(→text-author в poem); `preamble→
    section`; `annotation`. Прогон: текст №1 в FB2, спец-кейсы из образца ок.
11. Списки/таблицы: `ul`/`ol`/`li`(префиксы)→cite+p; `table`/`tr`/`th`/`td`.
12. Ссылки/сноски: `a`(`l:href`+RplLocalHref), `note→a type=note`,
    `notes`/`notebody→section` (+ `body name=notes`, кейс count>1).

**M4. Картинки + обложка:**
13. `RelResolver.RplId` + `collect_images`: rId→файл→binary-id, чтение байт из
    ZIP, base64, content-type. `<img>`→`<image l:href=#u…>`.
14. `resolve_cover`: coverpage-элемент ИЛИ OPC-thumbnail → `<coverpage>` +
    binary id `cover`. SVG: инлайн как есть + WARN-хук.
15. Дедуп binary, добавить все `<binary>` в конец FB2. Прогон: №1 и №2 → FB2 с
    13/2 binary + обложкой; ET-парс; затем `ebook-convert` → EPUB вручную,
    открыть, картинки+обложка на месте.

**M5. Интеграция в watcher:**
16. `epub_name()`: ветка `*.fb3`→`.epub`. Добавить `-o -iname '*.fb3'` в оба
    `find` (`process_folder_tree`, `count_pending`).
17. Резолв `FB3_TRANSFORM`; в `convert_book` врез трансформа (src→conv_src) +
    замена `$src`→`$conv_src` в cover-finder и ebook-convert; чистка fb3_tmp_dir;
    обработка rc (FAIL/ skip без падения батча).
18. Прогон: положить оба `.fb3` в watch-папку, дернуть watcher → 2 EPUB с
    обложками; лог `FB3->FB2 ok` + `cover (embedded)`; повторный прогон → skip.

**M6. Сборка/установка:**
19. `build-app.sh`: 2 install-строки (скрипт+JSON в Resources).
20. `installer.sh`: FB3_DST/FB3_GENRE_DST + find_src + install. Прогон
    изолированного install-теста → оба файла в App Support/bin.

**M7. Тесты:**
21. Тест-харнесс трансформа (прямые вызовы на 2 реальных + синтетические
    краевые из T3), плюс регрессия FB2 (T5) и идемпотентность (T4). Обновить
    `test-plan.md`.

---

## Риски / открытые вопросы для Юрки

**Риски (где можно ошибиться):**
- **R1. ET и mixed-content.** Главный риск трансформа — потеря `text`/`tail`
  при разворачивании обёрток (`span`, «kill»-теги, картиночный `p`). ElementTree
  хранит хвост в `.tail` — обходчик обязан переносить и `text`, и `tail`
  родителю/предыдущему сиблингу при «развороте». Смягчение: M3 шаг 8 — отдельный
  юнит-тест на `<p>a <em>b</em> c</p>` с проверкой склейки.
- **R2. `custom-info` рекурсия.** XSLT `mode="custom-info"` раскладывает
  произвольные поля в плоские `custom-info` со сложными `info-type`-путями.
  Полное воспроизведение — дорого и почти невидимо в EPUB. MVP покрывает
  основные блоки; глубокая атрибутная рекурсия — допустимая частичная потеря
  (метаданные второго порядка). Логировать пропуски.
- **R3. Сортировка notes по `@show`.** XSLT при count>1 сортирует notes по
  `@show desc`. Берём порядок документа — на практике совпадает; помечаем как
  упрощение. Низкий риск (1 notes-блок в обоих образцах).
- **R4. namespace на выходе.** Если читалка капризна к префиксу xlink (`l:` vs
  `xlink:`) — FB2-стандарт допускает `l:`/`xlink:`; Calibre ест оба. Проверено
  ET round-trip'ом. Низкий риск, но фиксируется тестом T1.
- **R5. id-коллизии binary.** basename-id может совпасть у файлов из разных
  папок. Смягчение: уникализация в `RelResolver` (суффикс при коллизии). На
  образцах структура плоская — риска нет.

**Открытые вопросы (нужно решение человека):**
- **Q1 (обложка).** Подтвердить выбор: обложку для FB3 берём из **OPC-thumbnail**
  (`_rels/.rels`), даже когда в description нет `<coverpage>`. Это даёт родную
  обложку в EPUB (оба образца). Альтернатива — игнорировать thumbnail и всегда
  отдавать на нашу генерёжку (хуже: теряем издательскую обложку). → Рекомендую
  OPC-thumbnail.
- **Q2 (расположение/имя).** ОК ли имя `bin/fb2-to-epub-fb3.py` и genre-map
  `bin/fb2-to-epub-fb3-genre.json` (единый префикс семейства, рядом с
  cover-finder)? Или предпочесть `…-fb3-to-fb2.py`?
- **Q3 (неизвестные жанры / пустой genre).** Если subject нет в genre-map или
  жанров вышло 0 — (а) пропускать молча, (б) класть в `custom-info`, (в) дефолт
  `prose_contemporary`? → Рекомендую (а)+пустой genre опустить; на спорных —
  лог WARN.
- **Q4 (SVG).** План: инлайнить SVG как есть и проверить Calibre на тесте T3.
  Если Calibre портит вёрстку/падает — переключаемся на «пропускать SVG-картинку
  / отдавать обложку генерёжке». Нужно ли заранее жёстко выбрать «всегда
  пропускать SVG» ради предсказуемости, или решаем по результату теста?
  → Рекомендую решать по тесту (на образцах SVG нет — низкий приоритет).
- **Q5 (формат вывода файла).** ОК ли что watcher гонит трансформ во временный
  `.fb2` (через `--out`), а не пайпит stdout? `--out` проще для логов/диагностики
  и устойчивее к бинарным/большим телам. → Рекомендую `--out`.

**Артефакт:** этот план —
`/Users/arrivarus/Documents/VibeCoding2/2026.06 fb2-to-epub/arch/plan-claude-fb3.md`.
