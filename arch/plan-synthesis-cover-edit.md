# Синтез-план — «Утвердить» + редактируемые Автор/Название (cover-select)

> Юрка свёл два независимых плана: `arch/plan-claude-cover-edit.md` (Claude) и
> `arch/plan-codex.md` (Codex/GPT-5.5). Оба сошлись на ядре; ниже — единый источник
> правды для разработки. Версия релиза: v0.9.7 (в пакете с правкой надписи бейджа).

## Фичи
1. **Кнопка «Утвердить»** — активна всегда (при валидном выборе), фиксирует текущий
   выбор и убирает книгу из очереди. Чинит ощущение «незавершённого действия».
2. **Редактируемые Автор/Название** — правка на экране влияет на: (a) сгенерированную
   обложку, (b) веб-поиск «Искать ещё», (c) метаданные ВНУТРИ готового EPUB (ebook-meta).

## Контракт job-файлов (covers/jobs/<job_id>.json) — АДДИТИВНО, обратно-совместимо
Существующее не ломаем. Новое:
- **Новый action** `{ "action":"apply_confirm", "book_id":…, "ts":… }` — авто-обложка уже
  вшита при конвертации; агент обложку НЕ трогает, только резолвит карточку.
- **Опциональные поля на ЛЮБОМ job** (apply / apply_generated / apply_confirm):
  `"edited_title": "<str>"`, `"edited_author": "<str>"`. Присутствуют ТОЛЬКО когда
  пользователь реально исправил значение (trimmed, непустое, отличается от оригинала).
  Есть → агент переписывает метаданные EPUB через `ebook-meta`. Нет → агент ведёт себя
  ровно как раньше (старые job без этих полей → прежнее поведение).

Имена полей: плоские `edited_title`/`edited_author` (не вложенный meta{}). Транспорт
значений в watcher — тем же base64-argv механизмом, что уже используется для research `query`
(watcher :636-643): НИКАКОГО eval / интерполяции строк в команды.

## Приложение (app/)
### EngineClient+Status.swift (write-слой, M2)
- `requestCover(bookId:decision:editedTitle:String?=nil, editedAuthor:String?=nil)` —
  добавить edited_* в JSON, когда не-nil.
- `requestApplyGenerated(bookId:pngPath:editedTitle:?, editedAuthor:?)` — то же.
- **Новый** `requestConfirmAuto(bookId:editedTitle:?, editedAuthor:?) -> Bool` — пишет
  `{action:"apply_confirm", book_id, ts, edited_*?}`. Атомарно (tmp→rename), как сейчас.
- Все apply-колбэки возвращают Bool; книга снимается из пейджера только при успешной
  публикации job.

### CoverSelectView.swift (Фича 1 UI + плумбинг под Фичу 2, M3)
- `canApply` → `canConfirm`: `!isResearching && !selectedId.isEmpty` (УБРАТЬ `!= autoId`).
- Кнопка «Применить»/«Применить обложку» → **«Утвердить»**.
- `confirmCurrent()` — маршрутизация по текущему выбору:
  1. выбрана сгенерированная обложка (`selectedGenerated != nil`) → `onApplyGenerated(bookId, png, edited)`.
  2. иначе выбран авто/best И книга `confident` (обложка уже вшита, менять нечего) →
     `onConfirmAuto(bookId, edited)`.
  3. иначе (веб-кандидат) → `onApply(bookId, selectedId, edited)`.
  — во ВСЕХ ветках прокидываем edited-значения (nil, пока их нет).
- Ввести `@State private var edits: [String: MetaEdit]` (пусто) + вычислимые
  `effTitle`/`effAuthor` (edited-или-оригинал) + флаг `metaEdited`. Пока поля ввода не
  добавлены (Фича 2) — `edits` пуст, edited-значения не шлются (forward-compatible).
- `main.swift`: замкнуть `onConfirmAuto` → `engine.requestConfirmAuto`.

### CoverSelectView.swift (Фича 2 UI, M4 — ПОСЛЕ дизайн-спец G3)
- Два редактируемых поля Автор/Название в области карточки книги (дизайн — по G3, см. ниже).
  Предзаполнены из entry.title/author; правка пишет в `edits[bookId]`.
- Правка → debounce (~400 мс) → сбросить `generated[bookId]` → `kickGenerated()` (4 превью
  перерисовываются по effTitle/effAuthor).
- `onResearch` («Искать ещё») использует effTitle/effAuthor как hint/prefill.
- edited-значения уже прокидываются в job через плумбинг M3.
- **R5:** `edits[bookId]` НЕ сбрасывать при `finishResearch` (правка переживает re-search).

### CoverGenerator.swift — без изменений сигнатуры (рендер по переданным author/title).

## Агент (bin/fb2-to-epub-watcher.sh, M1) — независимо от app
⚠️ `EBOOK_META` резолвится (watcher :46), но в watcher НЕ вызывается (только в finder) —
write-путь метаданных создаётся С НУЛЯ.
- **Новый helper** `apply_meta_into_epub(work_epub, title_b64, author_b64)`:
  `"$EBOOK_META" "$work_epub" "--title=$t" "--authors=$a"` — argv-массив, значения из
  base64-декода; без eval. Пустой title/author → соответствующий флаг НЕ добавлять.
- Порядок и атомарность (сохранить текущую модель temp→mv):
  - apply / apply_generated с edited: `cp epub work; ebook-meta work (если edited);
    ebook-polish --cover <png> work <final_tmp>; mv -f <final_tmp> epub`.
  - apply_confirm с edited: `cp epub work; ebook-meta work; mv -f work epub` (без polish).
  - apply_confirm без edited: обложку и файл не трогаем — только резолвим карточку.
  - Любая мутация — на temp; оригинал заменяется ТОЛЬКО при полном успехе (mv -f).
- Парсер плана (python3, cover_jobs_plan) + исполнитель (apply_cover_jobs): читать
  optional edited_title/edited_author (base64) и action=="apply_confirm"; эмиттить их
  в план тем же способом, что и `query`/`png`.
- **meta-fail политика (РЕШЕНО):** если `ebook-meta` упал, но обложка легла (или confirm) —
  книга всё равно **resolved** + запись в лог (метаданные не переписаны). НЕ оставляем
  карточку (не мозолим глаза из-за редкого сбоя метаданных). Сбой самой обложки (polish) —
  прежнее поведение `failed`.
- ⛔ НЕ трогать `batch_state` (sticky-batch v0.9.6) и `runner.sh` (FDA-грант по байтам).

## Крайние случаи (свод обоих архитекторов)
- Подтверждение авто без изменений → apply_confirm, без polish, карточка снята.
- Пустые/пробельные поля → edited не шлём (trim → isEmpty → пропуск).
- Правка метаданных + выбор ВЕБ/generated обложки → edited едет в apply/apply_generated,
  агент: meta ПЕРЕД polish.
- Правка + «Искать ещё» → edited в hint; edits НЕ теряются при перезаписи queue (R5).
- epub удалён (гейт существования) → как сейчас (книга выпадает).
- Повторные нажатия «Утвердить» → книга уже снята из пейджера; job идемпотентен.
- Частично записанный job → атомарная запись tmp→rename исключает.
- **Спецсимволы/кавычки/`$()`/бэктики в title/author → argv-массив + base64, шелл-инъекция
  невозможна конструктивно (R1 — КАТАСТРОФА под FDA, закрыта).**

## Риски (закрыты)
R1 инъекция → argv+base64, без eval. R2 sticky-batch → batch_state не трогаем.
R3 урок 015 → тесты только на изолированных temp; `EBOOK_META`/`EBOOK_POLISH` подменяются
фейком в тесте, НЕ в shipped-коде; verify без касания боевого plist/агента. R4 порча epub →
порядок meta→polish + mv -f. R5 потеря правки при research → не сбрасывать edits.

## План валидации/тестов
- **Агентные bash-тесты** (tests/, изолированный temp): stub `EBOOK_META`/`EBOOK_POLISH`
  (логируют argv) + один реальный минимальный temp-EPUB. Проверить: edited-job → ebook-meta
  вызван с верными argv ПЕРЕД polish; no-edit → ebook-meta НЕ вызван; apply_confirm → без
  polish, карточка снята; инъекция (кавычки/`$()`/бэктик) в title → один argv, шелл не
  исполняется; порядок meta→polish; mv -f атомарность.
- **App unit** (temp FB2_COVERS_DIR, FB2_SKIP_KICKSTART=1): requestCover/ApplyGenerated с
  edited пишут поля; requestConfirmAuto пишет action:"apply_confirm"; canConfirm-гейт
  (авто → активна; generated «грязный» до ре-рендера — по месту).
- **Регрессии:** sticky-batch (30/30), FB2/FB3 трансформ, `bash -n`, сборка arm64+x86_64.
- **Visual-verify (Юрка):** обе фичи в изолированном харнессе (real HOME, `FB2_BUNDLED_RES_DIR`=
  пустая → refresh=upToDate; `FB2_COVERS_DIR`=temp-очередь) — агент/plist НЕ трогаем.

## Майлстоны (по зависимостям)
- **M0** Контракт job (этот файл) — зафиксирован.
- **M1** Агент/watcher: helper ebook-meta + план/исполнитель (edited + apply_confirm) + порядок
  meta→polish + bash-тесты. *(независимо от app)*
- **M2** App write-слой (EngineClient): edited-параметры + requestConfirmAuto + unit.
- **M3** App Фича 1 UI (CoverSelectView): canConfirm/«Утвердить»/confirmCurrent + edits-плумбинг
  (пусто) + main.swift onConfirmAuto. *(зависит от M2)*
- **G3** Дизайн-спец полей правки (ux-analyst → показ человеку → «да»). *(блокирует M4)*
- **M4** App Фича 2 UI: поля TextField + debounce-регенерация + research-hint + запись в edits.
  *(зависит от M3 + G3)*
- **M5** e2e + все регрессы + visual-verify Юркой → релиз.

M1 ∥ (M2→M3) идут параллельно; дизайн полей (G3) — параллельно, блокирует только M4.
