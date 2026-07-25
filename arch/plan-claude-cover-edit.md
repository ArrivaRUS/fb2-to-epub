# План (Architect #1 / Claude) — «Выбор обложки»: «Утвердить» + редактируемые Автор/Название

**Проект:** fb2-to-epub (SwiftUI-app + launchd-агент bash/python3)
**Дата:** 2026-07-01 · **Автор:** Architect #1 (Claude)
**Скоуп:** Фича 1 (кнопка «Утвердить») + Фича 2 (правка Автор/Название → превью, веб-поиск, метаданные EPUB)

---

## Итог (суть подхода)

Обе фичи ложатся на **существующий контракт job-файлов** без слома модели «app пишет только jobs,
агент владеет epub/queue». Фича 1 — это по сути **снятие искусственного гейта `canApply`** (переименовать
в «Утвердить», активна при любом валидном выборе) + **новый job-путь `apply_confirm`** для случая
«подтвердить авто-обложку без изменений» (сейчас единственный незакрытый путь — авто уже вшита при
конвертации, надо лишь снять карточку из очереди). Фича 2 — **два опциональных поля в job**
(`edited_title`/`edited_author`), которые агент применяет через `ebook-meta` **строго ПЕРЕД** `ebook-polish`;
на стороне app правка перерисовывает 4 генерённых превью и подставляется как `query` в «Искать ещё».
Ключевой инвариант идемпотентности: если поля не трогали — их в job **нет вообще**, `ebook-meta` не вызывается.
Ключевой инвариант безопасности: `ebook-meta` вызывается **массивом argv** (никакой строки-шелла) → инъекция
кавычек/`$()`/`;` невозможна конструктивно.

---

## Компоненты (ответственность · зависит от · тест)

| Компонент | Ответственность | Зависит от | Тест |
|---|---|---|---|
| **Job-контракт** (расширение) | +поля `edited_title?`, `edited_author?` в apply/apply_generated; новый `action:"apply_confirm"` | — | статические JSON-фикстуры; bash-тест плана |
| `CoverSelectView` state | `@State edits: [bookId: (title,author)]`; геттеры `effTitle/effAuthor`; правка `canApply`→`canConfirm` | wire-модель | unit на чистые хелперы |
| Кнопка «Утвердить» (`applyCTA`/`canApply`) | всегда активна при валидном выборе; ветка авто→`apply_confirm` | selectedId/autoId | unit на предикат `canConfirm` |
| Поля правки Автор/Название | 2 `TextField`, prefill из entry; дебаунс регенерации превью | Tokens (новые CS-токены) | визуально Юркой |
| Регенерация превью | правка → сброс кэша `generated[bookId]` → `kickGenerated` с новым текстом | `CoverGenerator.render` | визуально + ручной |
| Проброс в «Искать ещё» | `query` = effTitle+effAuthor вместо entry.title/author | onResearch | существующий research-путь |
| `EngineClient+Status` (write) | `requestCover`/`requestApplyGenerated` +edited-поля; новый `requestConfirmAuto` | CoverQueueStore.coversDir | unit: job на диске содержит поля |
| Watcher `cover_jobs_plan` | эмиттить edited-поля (base64) + распознавать `apply_confirm` | python3 | bash-тест плана |
| Watcher `apply_meta_into_epub` (**новая**) | `ebook-meta <epub> --title --authors` argv, ПЕРЕД polish | EBOOK_META | bash-тест на реальном/фейковом epub |
| Watcher `apply_cover_jobs` (ветки) | порядок meta→polish; ветка confirm (только meta + снять карточку) | apply_meta_into_epub, polish_cover_into_epub | e2e bash-тест |

---

## 1. Поток данных end-to-end

### Общая топология (без изменений)
```
CoverSelectView (@State) ──► onApply/onApplyGenerated/onConfirm/onResearch (main.swift)
   ──► EngineClient пишет covers/jobs/<job_id>.json (atomic tmp→rename) + kickstart
      ──► watcher (launchd, FDA): apply_cover_jobs → [ebook-meta?] → ebook-polish? → update/remove queue
         ──► covers/queue/<book_id>.json (status/удаление) ──► app перечитывает, бейдж падает
```

### Фича 1 — «Утвердить», три сценария выбора

**(A) Выбран веб-кандидат (отличный от авто)** — уже работает сегодня:
```
tap «Утвердить» → onApply(bookId, candidateId)
  → job {book_id, chosen_candidate_id:<id>, ts}
  → watcher: polish_cover_into_epub(preview, epub) → cover_job_resolve(resolved) → карточка status=resolved, job удалён
  → app: dropCurrentBook → пейджер и бейдж уменьшаются
```

**(B) Выбрана генерённая обложка** — уже работает:
```
tap → onApplyGenerated(bookId, png) → saveGeneratedCover → job {action:"apply_generated", png, ts}
  → watcher gen-ветка: polish_cover_into_epub(png, epub) → remove_queue_entry → карточка удалена
```

**(C) Выбрана авто-обложка без изменений (`selectedId == autoId`)** — **НОВЫЙ путь**, сегодня заблокирован `canApply`:
Авто-обложка **уже вшита** в epub при конвертации (`convert_book`, ветка confident → `--cover best_preview`).
Значит epub трогать НЕ надо — надо лишь снять карточку из очереди.
```
tap «Утвердить» → onConfirm(bookId)
  → job {book_id, action:"apply_confirm", ts}   ← НОВОЕ действие
  → watcher confirm-ветка: [если edited-поля → ebook-meta], НЕ вызывать polish → cover_job_resolve(resolved)
  → карточка resolved, job удалён → app: dropCurrentBook
```
Важно: `apply_confirm` — это «зафиксировать то-что-есть». Если пользователь при этом правил метаданные (Фича 2),
единственная работа агента — `ebook-meta`; обложка остаётся той, что вшита.

> **Пограничный подслучай C':** книга `confident==false` (авто-обложки НЕТ, дефолт — первый генерённый).
> Тогда `selectedId` указывает на генерённую (id `-gen-N`) или на веб-кандидат — это сценарии (A)/(B), не (C).
> «Подтвердить пустоту» (epub без обложки) в скоуп не входит: дефолт всегда садится на валидный выбор,
> `canConfirm` требует непустой `selectedId`.

### Фича 2 — правка Автор/Название, три эффекта

**(a) Превью-генерёжка** (локально в app, агент не участвует):
```
пользователь правит поле → edits[bookId] = (t,a) → debounce ~400мс
  → generated[bookId] = nil (сброс кэша) → kickGenerated()
  → ensureGenerated рендерит CoverGenerator.render(author: effAuthor, title: effTitle) ×4 → грид обновляется
```

**(b) «Искать ещё»** (job → агент → finder, путь уже есть):
```
promptResearch: prefill/query = effTitle+" "+effAuthor (вместо entry.title/author)
  → onResearch(bookId, exclude, query) → job {action:"research", query, exclude, ts}
  → watcher apply_research_jobs → finder --query "<effTitle effAuthor>" → rewrite queue
```
Механизм не меняется — finder уже принимает `--query` (перекрывает мету epub). Меняется лишь **источник** строки.

**(c) Метаданные внутри EPUB** (новый write в агенте):
```
tap «Утвердить» → job несёт edited_title/edited_author (если правились)
  → watcher, ЛЮБАЯ apply-ветка (chosen/gen/confirm):
       1) если есть edited-поля → apply_meta_into_epub(epub, edited_title, edited_author)   [ebook-meta]
       2) если ветка chosen/gen → polish_cover_into_epub(cover, epub)                        [ebook-polish]
       3) resolve/remove queue
```
**Порядок meta→polish обязателен** (см. Риски): обе операции переписывают epub целиком; meta должна лечь до polish,
чтобы правки гарантированно уцелели, а не полагаться на коммутативность двух Calibre-инструментов.

---

## 2. Изменения контракта job-файлов (точно; обратная совместимость)

### 2.1 apply-job (chosen candidate) — РАСШИРЯЕТСЯ
Было:
```json
{ "book_id": "...", "chosen_candidate_id": "<id>|skip", "ts": "..." }
```
Стало (edited-поля ОПЦИОНАЛЬНЫ — присутствуют ТОЛЬКО если пользователь правил):
```json
{ "book_id": "...", "chosen_candidate_id": "<id>|skip", "ts": "...",
  "edited_title":  "Категория трудности",     // опц.
  "edited_author": "Владимир Шатаев" }        // опц.
```

### 2.2 apply_generated-job — РАСШИРЯЕТСЯ так же
```json
{ "book_id":"...", "action":"apply_generated", "png":"<abs>", "ts":"...",
  "edited_title":"...", "edited_author":"..." }   // оба опц.
```

### 2.3 apply_confirm-job — **НОВОЕ действие**
```json
{ "book_id":"...", "action":"apply_confirm", "ts":"...",
  "edited_title":"...", "edited_author":"..." }   // оба опц.
```
Семантика: «зафиксировать текущую (авто) обложку, epub-обложку не менять; при наличии edited-полей — переписать
метаданные; снять карточку из очереди (resolved)».

### 2.4 Правила edited-полей (единые для всех трёх)
- Пишутся **только** если значение отличается от исходного `entry.title`/`entry.author` **после trim**
  и непустое. Пустая/пробельная правка → поле **не** пишется (не даём стереть метаданные в пустоту).
- Тип — строка. Отсутствие поля = «метаданные не трогать».
- Ключи выбраны `edited_*` (а не `title`/`author`), чтобы **не конфликтовать** с полями queue-entry и читаться как «намеренная правка».

### 2.5 Обратная совместимость
- **Старый агент + новый app:** старый watcher игнорирует незнакомые ключи (`job.get(...)` их просто не читает);
  `apply_confirm` старым watcher'ом не распознан → job **зависнет** (не удалится). Это фон-агент, который
  обновляется вместе с app (`refreshEngineIfBundledChanged` перекладывает watcher при апдейте) — на практике
  версии синхронны. **Митигация:** developer обязан обновить watcher В ТОМ ЖЕ PR.
- **Новый агент + старый job** (без edited-полей, без action=confirm): все ветки читают `job.get("edited_title")` →
  `None` → `ebook-meta` не вызывается → поведение байт-в-байт как сегодня. `chosen_candidate_id` / `apply_generated` /
  `research` — без изменений.
- **queue-entry схема НЕ меняется** (Codable-модель `CoverQueueEntry` не трогаем): правки живут только в jobs и
  внутри epub, в очередь не пишутся. Это сознательно — очередь остаётся снимком того, что нашёл finder.

---

## 3. Изменения приложения (файлы/функции/состояние)

### 3.1 `app/CoverSelectView.swift`

**Новое состояние:**
```swift
/// Правки Автор/Название по книге (в памяти, на сессию экрана). Заполняется
/// лениво из entry при первой правке; влияет на превью, research и job.
@State private var edits: [String: (title: String, author: String)] = [:]
/// Debounce-токен регенерации превью (последняя правка выигрывает).
@State private var regenToken: [String: Int] = [:]
```

**Новые derived-геттеры (единый источник «эффективного» текста):**
```swift
private func effTitle(_ e: CoverQueueEntry) -> String {
    edits[e.bookId]?.title.trimmed ?? (e.title ?? "")
}
private func effAuthor(_ e: CoverQueueEntry) -> String {
    edits[e.bookId]?.author.trimmed ?? (e.author ?? "")
}
/// Правились ли метаданные (для решения — слать ли edited-поля в job).
private func metaEdited(_ e: CoverQueueEntry) -> Bool {
    effTitle(e) != (e.title ?? "").trimmed || effAuthor(e) != (e.author ?? "").trimmed
}
```

**Фича 1 — переименование и разблокировка кнопки:**
- `canApply` → **`canConfirm`**: `guard !isResearching, !selectedId.isEmpty else { return false }; return true`
  (убрать `selectedId != autoId` — именно этот предикат блокировал авто).
- `applyCTA`: label `"Применить"` → **`"Утвердить"`**; `.disabled(!canConfirm)`; `enabled = canConfirm`.
- `applyCurrent()` → **`confirmCurrent()`**: диспетчеризация трёх веток:
  ```swift
  private func confirmCurrent() {
      guard canConfirm, let e = entry else { return }
      guard !e.epubPath.isEmpty, FileManager.default.fileExists(atPath: e.epubPath) else {
          dropCurrentBook(showingMissingAlert: true); return
      }
      let ed = metaEdited(e) ? (effTitle(e), effAuthor(e)) : nil   // (t,a) или nil
      if let g = selectedGenerated {
          onApplyGenerated(e.bookId, g.png, ed)          // (B)
      } else if selectedId == autoId, autoId != nil {
          onConfirm(e.bookId, ed)                          // (C) авто без смены обложки
      } else {
          onApply(e.bookId, selectedId, ed)               // (A) веб-кандидат
      }
      dropCurrentBook(showingMissingAlert: false)
  }
  ```
- Callback-сигнатуры расширяются edited-аргументом:
  ```swift
  var onApply:          (_ bookId: String, _ candidateId: String, _ edited: (String,String)?) -> Void
  var onApplyGenerated: (_ bookId: String, _ pngData: Data,       _ edited: (String,String)?) -> Void
  var onConfirm:        (_ bookId: String, _ edited: (String,String)?) -> Void   // НОВЫЙ
  ```

**Фича 2 — поля правки (UI):**
- В `bookCard(entry:)` (или отдельной секцией над гридом «КАНДИДАТЫ») — два `TextField`
  (Название, Автор), prefill = `entry.title`/`entry.author`. Каждый `onChange`/commit →
  `edits[bookId] = (...)` + запуск debounce-регенерации.
- Дизайн полей (размеры/цвета/отступы) — **гейт G3**: developer НЕ придумывает, ждёт дизайн-спец от Юрки/UX.
  Пока — плейсхолдер-заметка: «поля стилизуются по дизайн-спец, до неё разработка UI полей не стартует».

**Фича 2 — регенерация превью (debounce):**
```swift
private func onMetaEdited(_ e: CoverQueueEntry) {
    let bookId = e.bookId
    let token = (regenToken[bookId] ?? 0) + 1
    regenToken[bookId] = token
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        guard regenToken[bookId] == token else { return }   // пришла новая правка — эта устарела
        generated[bookId] = nil                              // инвалидация кэша
        kickGenerated()                                      // ре-рендер с effTitle/effAuthor
    }
}
```
`ensureGenerated(for:)` меняет источник текста: `gen.render(author: effAuthor(entry), title: effTitle(entry), ...)`
вместо `entry.author/entry.title`.

**Фича 2 — «Искать ещё»:**
- `promptResearch`: `prefill = [effTitle(entry), effAuthor(entry)]` (вместо `entry.title/author`).

### 3.2 `app/EngineClient+Status.swift`

- `requestCover(bookId:decision:)` → добавить параметр `edited: (title:String, author:String)?`;
  при non-nil дописать `job["edited_title"]/["edited_author"]`.
- `requestApplyGenerated(bookId:pngPath:)` → тот же опциональный `edited`.
- **Новый** `requestConfirmAuto(bookId:edited:)`:
  ```swift
  @discardableResult
  func requestConfirmAuto(bookId: String, edited: (title:String, author:String)?) -> Bool {
      var job: [String:Any] = ["book_id": bookId, "action":"apply_confirm", "ts": Self.iso8601Now()]
      if let ed = edited { job["edited_title"] = ed.title; job["edited_author"] = ed.author }
      // ... тот же atomic tmp→rename + kickstart, jobId = "<book_id>-confirm-<rand8>"
  }
  ```
  Полностью повторяет проверенный паттерн `requestApplyGenerated` (atomic publish + `FB2_SKIP_KICKSTART`-гейт).

### 3.3 `app/main.swift`
Расширить 3 замыкания + добавить `onConfirm`:
```swift
onApply: { bookId, candidateId, edited in
    self?.engine.requestCover(bookId: bookId, decision: .apply(candidateId: candidateId), edited: edited)
},
onApplyGenerated: { bookId, png, edited in
    guard let path = self.engine.saveGeneratedCover(bookId: bookId, pngData: png) else { return }
    self.engine.requestApplyGenerated(bookId: bookId, pngPath: path, edited: edited)
},
onConfirm: { bookId, edited in
    self?.engine.requestConfirmAuto(bookId: bookId, edited: edited)
},
```

### 3.4 `app/Tokens.swift`
Добавить CS-токены для полей правки (высота, паддинги, цвет бордера/текста/плейсхолдера) — **после дизайн-спец**.

---

## 4. Изменения агента (watcher)

Все правки — только в `bin/fb2-to-epub-watcher.sh`. `runner.sh` не трогаем (FDA-байты, ⛔).
`EBOOK_META` уже резолвится (строка 46), но **нигде в watcher не вызывается** — путь целиком новый.

### 4.1 Новая функция `apply_meta_into_epub` (argv, БЕЗ шелл-строки)
```bash
# Переписать title/author внутри EPUB через ebook-meta (in-place). Вызывается ДО
# polish. argv-массив → спецсимволы/кавычки в тексте безопасны конструктивно
# (никакой eval/строки шелла). Пустые значения НЕ передаются (не затираем мету).
# Идемпотентно: ebook-meta переписывает те же поля тем же значением без вреда.
# Args: <epub_path> <title|""> <author|"">
apply_meta_into_epub() {
  local epub="$1" title="$2" author="$3"
  [[ -x "$EBOOK_META" ]] || { log "meta: ebook-meta unavailable ($EBOOK_META)"; return 1; }
  local -a args=("$epub")
  [[ -n "$title"  ]] && args+=(--title   "$title")
  [[ -n "$author" ]] && args+=(--authors "$author")
  [[ ${#args[@]} -eq 1 ]] && return 0     # оба пусты — успех-no-op
  if "$EBOOK_META" "${args[@]}" >>"$LOG_FILE" 2>&1; then
    return 0
  else
    log "meta: ebook-meta FAILED for $epub"
    return 1
  fi
}
```
> `ebook-meta <epub> --title/--authors` правит EPUB **на месте** (не требует out-файла, в отличие от polish).
> Если нужна полная атомарность — можно обернуть tmp→mv как polish; развилку решает developer (ориентир — проще/безопаснее).

### 4.2 `cover_jobs_plan` (python-плей) — эмиттить edited + распознавать confirm
Сейчас план кодирует по 5 base64-полей на строку с action-токеном `apply`/`gen`.
Расширяем на **2 доп. поля** (edited_title, edited_author) и **новый токен `confirm`**:
```
apply   <job> <book> <epub> <chosen>  <preview>  <et> <ea>
gen     <job> <book> <epub> <png>     <"">       <et> <ea>
confirm <job> <book> <epub> <"">      <"">       <et> <ea>
```
- В python: читать `job.get("edited_title")`/`edited_author` → `b64(... or "")`.
- `action == "apply_confirm"` → эмиттить строку `confirm` (epub_path из queue, как для остальных).
- Незнакомое `action` → пропустить с логом, НЕ удалять вслепую.

### 4.3 `apply_cover_jobs` (bash-луп) — раскодировать edited, вставить meta, добавить ветку confirm
Каждая ветка (`gen`/`confirm`/chosen) ПЕРЕД `polish` (или вместо него для confirm) делает:
```bash
et="$(printf '%s' "$f6" | base64 --decode 2>/dev/null || true)"
ea="$(printf '%s' "$f7" | base64 --decode 2>/dev/null || true)"
# ... валидация epub существует ...
if [[ -n "$et" || -n "$ea" ]]; then
    apply_meta_into_epub "$epub_path" "$et" "$ea" \
      || log "apply: meta write failed ${book_id} (continuing to cover)"
fi
```
- **chosen-ветка:** meta → `polish_cover_into_epub(preview)` → `cover_job_resolve(resolved/failed)`.
- **gen-ветка:** meta → `polish_cover_into_epub(png)` → `remove_queue_entry`.
- **confirm-ветка (НОВАЯ):** meta → **НЕ polish** → `cover_job_resolve(resolved)` (карточка снимается).
  Если epub исчез → drop job, `cover_job_resolve(failed)` (как остальные), лог.

### 4.4 Порядок и идемпотентность
- **Порядок meta ПЕРЕД polish** (см. 1c и Риски). Явно фиксируем.
- **Идемпотентность:** повторный тот же job (дубликат нажатия) → `ebook-meta` перепишет те же значения (no-op по
  смыслу), `polish` перевшьёт ту же обложку. Оба безопасны при повторе. Но повторов **не будет**: app сразу
  `dropCurrentBook` (книга уходит из пейджера), а `cover_job_resolve`/`remove_queue_entry` снимают карточку —
  второй job на ту же книгу пользователь физически не создаст (её нет в очереди).
- **meta failed, cover ok:** не абортим — вшиваем обложку, логируем провал меты (частичный успех лучше застрявшего
  job). Дефолт плана — **resolved с логом** (см. вопрос 1).

### 4.5 Поведение при отсутствии/ошибке ebook-meta
- `EBOOK_META` не исполняем → `apply_meta_into_epub` возвращает 1, логирует, ветка продолжается (обложка/резолв
  идут своим чередом). Метаданные просто не переписаны — деградация, не поломка.
- Неизвестное `action` в незнакомой версии агента → лог + оставить job (шанс более новой версии). Т.к. агент кладётся
  вместе с app — до расхождения не дойдёт.

---

## 5. Крайние случаи (и решение)

| Случай | Решение |
|---|---|
| **Подтвердить авто без изменений** | Ветка (C): job `apply_confirm`, агент только снимает карточку (+meta если правили), epub-обложку не трогает. |
| **Пустые/пробельные поля** | app: правка не пишется в job, если после trim пусто ИЛИ == исходному. Агент: `apply_meta_into_epub` не добавляет `--title/--authors` для пустых. Метаданные в пустоту не стираются. |
| **Правка меты + выбор ВЕБ-обложки** | Ветка (A): job несёт `chosen_candidate_id` + edited-поля. Агент: `ebook-meta` → `ebook-polish(preview)`. Обе правки в epub. |
| **Правка меты + «Искать ещё»** | `query`=effTitle+effAuthor. Finder ищет по правке; edited-поля в research-job НЕ нужны (research не пишет epub, только rewrite queue). **Тонкость:** после research queue перезаписывается finder'ом с ЕГО `title/author` (из меты epub). `edits[bookId]` в app **сохраняется** (не сбрасывать в `finishResearch`) → превью/«Утвердить» продолжают использовать правку. |
| **EPUB удалён** | app: повторная проверка в `confirmCurrent` (как в текущем `applyCurrent`) → alert + drop. Агент: все ветки проверяют `-f "$epub_path"` → drop job + failed/лог. Двойная защита сохранена. |
| **Повторные нажатия** | Книга уходит из пейджера сразу (`dropCurrentBook`); карточка снимается агентом. Дубликат job невозможен; даже если бы — meta/polish идемпотентны. |
| **Частично записанный job** | Публикация atomic tmp→rename (уже так во всех `request*`). Читатель не видит полу-job. python `json.load` на битом файле → `except` → skip с логом (уже так в `cover_jobs_plan`). |
| **Спецсимволы/кавычки/`$()`/`;`/emoji в тексте** | **Конструктивно безопасно:** (1) app пишет JSON через `JSONSerialization` (экранирование автоматом). (2) Агент декодирует значения из **base64** (не парсит из шелл-строки). (3) `ebook-meta` вызывается **argv-массивом** `"${args[@]}"` — нет `eval`, нет интерполяции в команду. Инъекция невозможна. Кириллица/юникод — ok (`ensure_ascii=False`, bash передаёт байты как есть). |
| **Очень длинный title/author** | ebook-meta примет; ограничение по длине не в скоупе. Опц. app обрезает поле визуально. |
| **`skip` + edited-поля** | `chosen_candidate_id:"skip"` = «оставить что вшито» ≈ confirm. **План: `apply_confirm` — основной путь для «оставить как есть»; skip остаётся легаси-путём, но meta в нём тоже применяем для единообразия** (дёшево: та же вставка `apply_meta_into_epub` перед `cover_job_resolve(skipped)`). |
| **`confident==false`, дефолт — генерённая** | selectedId → `-gen-N` → ветка (B). Всё как для генерённой + edited-поля. |
| **Правка → навигация на др. книгу → возврат** | `edits`/`generated` кэшируются по bookId → правка и перерисованные превью сохраняются (как сейчас `generated`). |

---

## 6. Риски (что может КАТАСТРОФИЧЕСКИ сломаться) и предотвращение

| Риск | Тяжесть | Предотвращение |
|---|---|---|
| **R1. Шелл-инъекция через title/author в `ebook-meta`** (напр. `"; rm -rf ~ ;`) | КАТАСТРОФА (агент под FDA) | argv-массив `"$EBOOK_META" "${args[@]}"`, **никогда** строкой/eval. Значения из base64-декода, не из парсинга шелл-строки. Тест с payload `$(touch /tmp/pwned)`/`"; touch …` → файл НЕ создан. |
| **R2. Регресс sticky-batch v0.9.6** | Высокая (ломает прогресс-ринг) | `batch_state`/`batch_is_fresh` **не трогаем**. Новый код — только в `apply_cover_jobs`/`cover_jobs_plan` + новая `apply_meta_into_epub`. `apply_cover_jobs` уже вызывается ДО конвертаций и вне batch-логики. Регресс-тест sticky-batch прогнать без изменений — должен пройти. |
| **R3. Verify-оверрайд протекает в installer/plist (урок 015)** | КАТАСТРОФА (переписал реальный plist) | Никаких новых env-оверрайдов на геттерах, питающих installer. Тесты пишут в изолированный `FB2_COVERS_DIR`/`HOME`. `ebook-meta`-тесты — только на temp-epub, `EBOOK_META` подменяется фейк-скриптом через env **в тесте** (не в shipped-коде). Путь verify физически не достаёт до `~/Library/LaunchAgents`. |
| **R4. ebook-meta повреждает/обнуляет epub** | Высокая (потеря книги) | ebook-meta пишет in-place — теоретически может оставить битый файл при краше. Митигация: (опц.) meta через tmp→mv как polish; либо принять риск (Calibre устойчив). Тест: после meta `ebook-meta <epub>` читается, размер > 0, обложка на месте. **Порядок meta→polish** страхует: последующий polish перепаковывает epub. |
| **R5. Потеря правки при research-перезаписи queue** | Средняя (сбивает с толку) | finder перезаписывает `title/author` в queue своими значениями. `edits[bookId]` в app НЕ сбрасывать на research-финише → «Утвердить»/превью используют правку. Явный тест логики `finishResearch`. |
| **R6. `apply_confirm` завис у старого агента** | Средняя (job копится) | Watcher обновляется в ТОМ ЖЕ PR (версии синхронны). App делает `dropCurrentBook` оптимистично (книга уходит из UI сразу) — завис job визуально не блокирует. Агент на неизвестном action логирует. |
| **R7. Регенерация превью на каждый keystroke → лаг WebView** | Низкая (UX-джанк) | Debounce ~400мс + токен «последняя правка выигрывает». `CoverGenerator` сериализует рендеры (WebKit) — не параллелит. |
| **R8. edited-поля затирают корректную мету при случайном касании поля** | Низкая | Пишем edited только при **отличии от исходного** после trim. Фокус/расфокус без изменения текста → поле не уходит в job. |

---

## 7. План валидации / тестов (safe, урок 015)

Все тесты — на **изолированных temp-путях** (`HOME`/`FB2_COVERS_DIR`/`FB2_STATE_DIR` в throwaway-dir),
`FB2_SKIP_KICKSTART=1`, боевой агент/plist не трогаются. Образец — `tests/run-clear-history-tests.sh`,
`tests/run-sticky-batch-test.sh`.

### 7.1 Unit (Swift, стиль ClearHistoryTests)
- **U1** `canConfirm`: активна при непустом `selectedId` (включая `selectedId==autoId`); false при researching / пустом выборе.
- **U2** `requestCover` с `edited` → на диске job содержит `edited_title/edited_author`; без edited → полей нет.
- **U3** `requestConfirmAuto` → job `{action:"apply_confirm", edited?}`, atomic, jobId c `-confirm-`.
- **U4** `metaEdited`/`effTitle`/`effAuthor`: правка меняет eff-значения; пустая/== исходной правка → `metaEdited==false`.
- **U5** `finishResearch` НЕ сбрасывает `edits[bookId]` (правка переживает research).

### 7.2 Агентные bash-тесты (новый `tests/run-cover-meta-tests.sh`)
Фейковый `ebook-meta`/`ebook-polish` через env (`EBOOK_META=<temp stub>`, `EBOOK_POLISH=<temp stub>`), stub логирует argv:
- **B1 (инъекция)** job `edited_title='"; touch /tmp/PWNED_$$ ; echo "'` → `apply_cover_jobs` → файл `/tmp/PWNED_*` НЕ создан; stub получил заголовок как ОДИН argv-аргумент.
- **B2 (порядок)** chosen+edited → stub-лог: `ebook-meta` вызван РАНЬШЕ `ebook-polish`.
- **B3 (confirm)** `apply_confirm` без edited → `ebook-polish` НЕ вызван, `ebook-meta` НЕ вызван, queue-карточка → resolved, job удалён.
- **B4 (confirm+edited)** → `ebook-meta` вызван (title+author в argv), polish НЕ вызван, resolved.
- **B5 (пустые поля)** edited_title=" " → `--title` в argv НЕ появляется.
- **B6 (нет edited)** легаси-job без полей → `ebook-meta` не вызван, поведение == сегодня.
- **B7 (meta-fail)** stub ebook-meta exit 1 → обложка всё равно вшита (polish вызван), resolved, в логе meta FAILED.
- **B8 (обратная совм.)** старый queue-entry + новый watcher → chosen-путь без изменений.

### 7.3 e2e (опц., с реальным Calibre, на temp watch-dir)
- Один fb2 с мусорной метой → convert → правка Автор/Название → «Утвердить» → `ebook-meta <epub>` печатает
  **исправленные** Title/Authors (acceptance Фичи 2c). CI-guard если Calibre установлен.

### 7.4 Регресс (обязательно прогнать без изменений)
- `run-sticky-batch-test.sh` (R2), `run-fb2-regression-test.sh`, `run-clear-history-tests.sh`, `run-update-install-test.sh` — все зелёные.

### 7.5 Визуальная верификация (Юрка, `visual-verify`)
- Кнопка «Утвердить» активна на авто-книге; после нажатия книга исчезает, бейдж падает.
- Поля Автор/Название; правка → 4 превью перерисовываются с новым текстом.

---

## 8. Разбивка на микрозадачи-майлстоны (по зависимостям, для developer)

**Гейт G3 (дизайн-спец полей правки)** блокирует только UI-часть полей (M4.2). Всё остальное (job-контракт,
агент, «Утвердить», проброс в research/превью) от дизайн-спец НЕ зависит и может идти раньше/параллельно.

### Milestone 0 — Контракт (документ, без кода)
- **M0.1** Зафиксировать расширение job-схемы (2.1–2.5): edited-поля + `apply_confirm`. (Основа для всех.)

### Milestone 1 — Агент: метаданные + confirm (bash, независимо от UI)
- **M1.1** `apply_meta_into_epub` (argv, безопасная) + stub-тесты B1(инъекция), B5(пустые).
- **M1.2** `cover_jobs_plan`: +2 base64-поля (edited), +токен `confirm`. Тест плана.
- **M1.3** `apply_cover_jobs`: раскодировать edited; meta ПЕРЕД polish в chosen/gen; ветка `confirm` (meta→resolve, без polish); skip-ветка +meta. Тесты B2/B3/B4/B7.
- **M1.4** Прогнать регресс sticky-batch + fb2-regression (R2). Зелёные.
> Зависимость: M1.1 → M1.3; M1.2 → M1.3.

### Milestone 2 — App write-слой (Swift, независимо от UI-полей)
- **M2.1** `requestCover`/`requestApplyGenerated` +опц. `edited`. Тест U2.
- **M2.2** `requestConfirmAuto`. Тест U3.
- **M2.3** main.swift: расширить замыкания onApply/onApplyGenerated + добавить onConfirm.
> Зависимость: M0.1.

### Milestone 3 — Фича 1 UI-логика (кнопка «Утвердить»)
- **M3.1** `canApply`→`canConfirm` (снять `!= autoId`); label «Утвердить»; `confirmCurrent()` с 3 ветками. Тест U1.
- **M3.2** Проброс `onConfirm`/edited в `confirmCurrent`. Визуальная проверка Юркой (кнопка активна на авто, книга уходит).
> Зависимость: M2.2, M2.3.

### Milestone 4 — Фича 2 UI (поля + превью + research)
- **M4.1** State `edits`/`effTitle`/`effAuthor`/`metaEdited`. Тест U4.
- **M4.2** Два `TextField` по дизайн-спец (Tokens.CS.*). ⛔ **Блокировано G3.**
- **M4.3** Debounce-регенерация превью (сброс `generated[bookId]` → kickGenerated с eff-текстом). Ручная/визуальная проверка.
- **M4.4** `promptResearch` prefill = eff-значения; `finishResearch` НЕ сбрасывает `edits`. Тест U5.
- **M4.5** Проброс edited в `confirmCurrent` (все 3 ветки несут `metaEdited ? (t,a) : nil`).
> Зависимость: M3.1 (общий confirmCurrent), M2.1 (write с edited). M4.2 — от G3.

### Milestone 5 — Интеграция + приёмка
- **M5.1** e2e (реальный Calibre, temp watch): правка → «Утвердить» → `ebook-meta <epub>` = исправленные (acceptance 2c).
- **M5.2** Прогон всех регресс-тестов (7.4). Сборка ad-hoc (swiftc arm64+x86_64 → lipo → codesign).
- **M5.3** Юрка: side-by-side + visual-verify обеих фич; журнал решений; урок-патч если были грабли.

---

## Артефакты
- Этот план: `/Users/arrivarus/Documents/VibeCoding2/2026.06 fb2-to-epub/arch/plan-claude-cover-edit.md`

## Вопросы к человеку
1. **meta-fail политика** (4.4/B7): при неудаче `ebook-meta`, но успешной обложке — считать книгу **resolved**
   (обложка применилась, метаданные не переписаны, лог) или **failed** (карточка остаётся, чтобы повторить)?
   Дефолт плана — **resolved с логом**.
2. **Дизайн полей правки** (M4.2, гейт G3): нужны точные размеры/цвета/отступы двух `TextField` от UX/дизайн-спец
   до старта UI-части Фичи 2. Остальное строим не дожидаясь.
