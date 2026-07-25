# Архитектура #2 (GPT-5.5 через Codex) — экран «Выбор обложки»: «Утвердить» + редактируемые Автор/Название

> Движок: gpt-5.5, reasoning effort xhigh, sandbox read-only. Прогон 2026-07-01, ~255s, 154705 tokens.
> Бриф: две фичи (кнопка «Утвердить»; редактируемые Автор/Название → обложка+веб-поиск+метаданные EPUB).

---

Прочитал указанные участки. Ниже план без кода.

**1. Поток Данных**

| Сценарий | App | Job | Watcher | Итог |
|---|---|---|---|---|
| Утвердить авто без правок | `selectedId == autoId`, valid selection | `action:"confirm"` + `chosen_candidate_id:"skip"` | не вызывает `ebook-polish`, помечает resolved/убирает из pending | EPUB не тронут, книга исчезает |
| Утвердить авто с правкой meta | то же, но есть patch | confirm + `meta` | применяет `ebook-meta` к temp-копии, обложку не трогает | meta обновлена, очередь очищена |
| Утвердить web-кандидат | `selectedId` найден в `candidates` | legacy apply + optional `meta` | meta на temp-копию, затем `ebook-polish --cover` | cover + meta в EPUB |
| Утвердить generated | выбран `GeneratedCover` | `action:"apply_generated"`, `png`, optional `meta` | meta на temp-копию, затем polish PNG | generated cover + meta |
| Искать ещё | query из edited title/author | existing `action:"research"` | finder `--query "$query"` | queue rewritten, UI keeps local edits |

**2. Job-Контракт**

Аддитивно, без обязательного schema bump.

| Job | Поля |
|---|---|
| Web apply | `{book_id, chosen_candidate_id:"cand-id", ts, meta?}` |
| Confirm existing/auto | `{book_id, action:"confirm", chosen_candidate_id:"skip", ts, meta?}` |
| Generated | `{book_id, action:"apply_generated", png:"/abs/path.png", ts, meta?}` |
| Research | без изменения: `{book_id, action:"research", exclude:[...], query, ts}` |

`meta`:
```json
{"title":"Исправленное название","author":"Исправленный автор"}
```

Правила: `meta` пишется только если хотя бы одно непустое trimmed-поле реально отличается от исходного `entry.title/author`. Старые jobs без `meta` не вызывают `ebook-meta`. Старый watcher проигнорирует `meta`; новый watcher принимает старые jobs как раньше.

**3. Приложение**

| Компонент | Изменение |
|---|---|
| `CoverSelectView.canApply` | заменить на смысл `canConfirm`: `!isResearching && isValidSelection && !isApplyingCurrentBook`; убрать `selectedId != autoId` |
| CTA | текст `Применить` → `Утвердить`; action остаётся `applyCurrent`, но семантика “зафиксировать выбор” |
| Selection validation | web id должен быть в `entry.candidates`, generated id должен иметь актуальный PNG; stale generated после правки невалиден |
| Edited state | добавить `@State metaDrafts[bookId] = {title, author}`; seed из queue |
| UI fields | в `bookCard` показывать редактируемые Title/Author вместо статичного текста |
| Generated render | `CoverGenerator().render(author: editedAuthor, title: editedTitle, template:)` |
| Debounce | на изменение title/author: mark generated dirty immediately, debounce 300-500 ms, render 4 превью; publish only if renderKey still current |
| Research | prefill диалога и `onResearch` query из edited title/author, а не из `entry` |
| Callbacks | сделать apply callbacks возвращающими `Bool`; drop book только если job/PNG publish successful |

Рекомендую добавить `CoverMetaPatch` как маленький Foundation-only тип: trimmed title/author, `isEmpty`, сравнение с original.

**4. Watcher**

Добавить helper уровня `apply_cover_jobs`:

1. Прочитать `meta` в `cover_jobs_plan`, вывести title/author как base64-поля.
2. В bash собрать argv-массив:
   - `meta_args+=("--title=$title")`
   - `meta_args+=("--authors=$author")`
3. Для cover+meta использовать temp workflow:
   - copy EPUB → temp input;
   - если `meta_args` не пуст: `"$EBOOK_META" "$work_tmp" "${meta_args[@]}"`;
   - если cover нужен: `ebook-polish --cover <cover> "$work_tmp" "$out_tmp"`;
   - только после успеха `mv -f "$out_tmp_or_work_tmp" "$epub_path"`.
4. Порядок: metadata first on temp copy, cover polish last. Это сохраняет смысл “polish last” и не пишет частичный результат в оригинал.
5. `action:"confirm"`: cover не применять; если meta нет, просто resolved/remove pending.
6. Ошибка `ebook-meta`: job удалить, queue status `failed` или оставить pending. Я бы выбрал `failed` для совместимости с текущими apply-fail ветками и чтобы не было retry-loop; оригинальный EPUB не менять.

**5. Крайние Случаи**

| Случай | Поведение |
|---|---|
| Auto без правок | confirm-job, no `ebook-meta`, no `ebook-polish`, status resolved |
| Пустой title/author | не передавать пустое поле в `meta`; не затирать EPUB пустотой |
| Правка + web cover | один apply-job: meta + chosen candidate |
| Правка + generated | PNG уже с edited text; job несёт meta |
| Правка + Искать ещё | query из edited fields; queue rewrite не сбрасывает local drafts |
| EPUB удалён | app gate уже есть; watcher дополнительно drops/failed без retry |
| Повторный клик | `applyingBookIds` disables CTA; watcher second job без queue очищает job без retry |
| Спецсимволы | JSONSerialization в app; в watcher base64 transport; команды только через quoted argv arrays, без `eval` |

**6. Риски**

| Риск | Предотвращение |
|---|---|
| Порча EPUB | все rewrite операции на temp copy; final `mv -f` только после успеха |
| Shell injection | никаких строк команд; только массивы argv |
| Sticky-batch regression | не трогать `batch_state`, не добавлять begin/end/tick в apply/meta |
| FDA-грант | не трогать `bin/fb2-to-epub-runner.sh`, installer/plist пути |
| App пишет EPUB/state | запрет сохранить: app пишет только `covers/jobs` и generated PNG |

**7. Валидация**

Только temp-пути, без launchd/installer/plist.

| Проверка | Как |
|---|---|
| Job JSON | Swift/Fundation test с `FB2_COVERS_DIR=$(mktemp -d)`, `FB2_SKIP_KICKSTART=1`; assert `meta`, `action:"confirm"` |
| Watcher parser | bash test извлекает/вызывает apply helpers в temp; stub `EBOOK_META`/`EBOOK_POLISH` логируют argv |
| Real `ebook-meta` | создать минимальный temp EPUB, выполнить `ebook-meta "$epub" --title ... --authors ...`, прочитать обратно |
| Cover+meta transaction | temp EPUB + temp PNG; проверить оба эффекта и отсутствие изменений при stub failure |
| UI gates | fake queue: auto selected → CTA enabled; generated dirty → disabled until rerender; edited query reaches research |
| Regression | `bash -n bin/fb2-to-epub-watcher.sh`, `bash tests/run-sticky-batch-test.sh`, FB2/FB3 tests, `build/build-app.sh` |

**8. Микрозадачи**

1. Ввести `CoverMetaPatch` и job-contract tests.
2. Расширить `EngineClient.requestCover/requestApplyGenerated` на optional `meta`.
3. Добавить `action:"confirm"` decision.
4. Обновить `CoverSelectView`: drafts, CTA, validation, callbacks.
5. Подключить edited values к generated render и research query.
6. Обновить watcher plan parser и temp rewrite helper.
7. Добавить изолированные watcher tests со stubs.
8. Прогнать sticky-batch/build/regression.

| Компонент | Ответственность | Зависит от | Тест |
|---|---|---|---|
| `CoverSelectView` | UX, edited state, selection confirmation | job API | UI/pure gate tests |
| `EngineClient+Status` | atomic job publish | `CoverMetaPatch` | temp JSON tests |
| `CoverGenerator` | render edited title/author | existing API | visual/snapshot smoke |
| `fb2-to-epub-watcher.sh` | apply meta/cover under FDA | job contract | stub + real temp EPUB |
| Tests | prevent regressions, lesson 015 | temp roots only | no launchd/plist |
