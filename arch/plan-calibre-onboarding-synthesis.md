# Синтез архитектуры: онбординг Calibre — суд Юрки

> Входы: `plan-calibre-onboarding-claude.md` (Архитектор #1, Fable 5 max) ·
> `plan-calibre-onboarding-codex.md` (Архитектор #2, GPT-5.6 Sol xhigh, 0 ретраев).
> Дата: 2026-07-19. Судья: Юрка. Спорные факты сверены с кодом ДО суда:
> MIN_MACOS="11.0" (`build/build-app.sh:26`) — конфликт с Calibre 9.x (требует macOS 14+) РЕАЛЕН;
> хардкоды `/Applications/calibre.app` подтверждены: `packaging/installer.sh:65`,
> `bin/fb2-to-epub-watcher.sh:22,46,51`, `bin/fb2-to-epub-cover-finder.py:64` (env EBOOK_META
> игнорируется — константа), `app/EngineClient.swift:87` (дефолт init).

## Рубрика (1–5)

| Критерий | #1 Claude | #2 Codex |
|---|---|---|
| Корректность | 5 — всё заземлено на код, факты сошлись при проверке | 5 — поймал cover-finder и «сырую историю», факты сошлись |
| Простота | 5 — 3 новых файла, поверх существующих каналов | 3 — transaction-journal, 6-state RuntimeHealth, homebrew-кандидаты, renameatx_np — тяжелее нужного |
| Соответствие ограничениям | 5 — D13/уроки 006·015·016 явно вшиты | 5 — D13 цел, 015-guard даже строже |
| Риск-менеджмент | 4 — ПРОПУСТИЛ хардкод cover-finder (обложки бы сломались при managed-установке) | 5 — самый полный список ловушек (agentActivationFailed, LSMinimumSystemVersion, сырая история) |
| Тестируемость | 5 — parity-тест, fixture-DMG, живой e2e с xattr/spctl | 5 — протоколы подмены, test-root guard, live e2e-сценарий |

**Вердикт:** каркас берём у #1 (проще и точнее лёг на код), критические находки и защёлки — у #2.
Это синтез, не «победитель целиком».

## Взято из #1 (Claude) — каркас

- **3 новых Swift-файла:** `CalibreLocator` + `CalibreInstaller` (+`InstallStore` у AppDelegate) +
  `EngineSetupCard` (одно состояние — 4 подачи: блокер B / баннер A / шаг Setup / строка Настроек).
- **Детект:** двойная реализация Swift+bash одного контракта с **parity-тестом** (не спавнить
  процесс на каждый `refreshStatusNow`). Порядок: наша папка → /Applications → ~/Applications;
  валидность = все 3 CLI. PATH/homebrew-bin НЕ сканируем (cask кладёт .app в /Applications).
- **Оживление** без новых механизмов: plist есть → `runInstaller(watchDir)`; нет →
  `firstRunSetupIfNeeded()`; installer перепекает пути → bootout→bootstrap→kickstart.
- **Атомарность по-простому:** staging `calibre.app.installing` → rename (+`.old` при обновлении);
  зачистка остатков на старте. Transaction-journal Codex — отвергнут (оверкилл для MVP).
- **Конвейер и константы:** precheck диска **1.5 ГБ**, выбор URL по ОС с пиннутыми легаси
  (CAL-0 HEAD-пробы до кода), SHA-512 fail-closed, detach не-фатален (ретраи → -force),
  докачка/GPG — вне MVP, паттерн скачивания от UpdateChecker (но СВОЯ реализация — см. Codex ниже).
- **Майлстоуны CAL-0…CAL-5** как основа execution-pack; обновления Calibre — вне MVP.

## Взято из #2 (Codex) — находки и защёлки

- **cover-finder.py: перевести на `os.environ["EBOOK_META"]`** (сейчас хардкод игнорирует env
  агента) — без этого managed-установка ломает вшивание обложек. ВКЛЮЧЕНО в скоуп (M1, диф маленький).
- **plist несёт `CALIBRE_MACOS_DIR`** + производные `EBOOK_*` (обратная совместимость).
- **Блокер vs баннер — по СЫРОМУ snapshot watcher** (`converted_total>0 || recent непуст ||
  last_conversion!=nil`), не по отфильтрованному `loadState()` — иначе «Сбросить статистику»
  превращает баннер в блокер.
- **`agentActivationFailed` ≠ провал установки движка:** движок уже стоит — отдельное состояние
  «Движок установлен, агент не запустился» с действием «Повторить запуск агента».
- **Разделить `blockedNoCalibre`** на `needsEngine` / `agentSetupFailed` (сейчас маскирует два
  разных сбоя). Полный 6-state RuntimeHealth — отвергнут (сверх нужды MVP); честный бейдж строим
  на calibrePresent + agentActive + installing.
- **`codesign --verify --strict`** на staged-копии до свопа (в довесок к exec `--version`).
- **`LSMinimumSystemVersion`** staged-копии сверить с текущей ОС после mount (страховка гейта по ОС).
- **hdiutil attach `-plist`** + PropertyListSerialization (не grep /Volumes); detach по device id в defer.
- **Не переиспользовать `UpdateChecker.downloadAndInstall`** (нет прогресса/отмены/SHA) — берём
  только паттерн/trust-gate, реализация своя.
- **Hardcode-тест:** grep-тест в постоянном наборе — новые `/Applications/calibre.app` вне
  локатора запрещены.
- **Тест-защёлка урока 015 строже:** mutating-оверрайды только при `FB2_CALIBRE_TEST_MODE=1` и
  install-root внутри канонизированного `FB2_CALIBRE_TEST_ROOT`.

## Отброшено (с причиной)

- Transaction-journal с UUID (Codex) — staging + стартовая зачистка покрывают crash-recovery дешевле.
- Homebrew-bin кандидаты и сканирование PATH (Codex) — cask кладёт .app в /Applications, уже покрыто.
- `renameatx_np(RENAME_SWAP)` (Codex) — первая установка = простой rename; обновления вне MVP.
- Смена семантики `didShowSetup`→`didCompleteSetup` (Codex) — не трогаем поведение существующих
  пользователей; честность обеспечивают сами экраны по calibrePresent.
- Полный 6-state `RuntimeHealth` (Codex) — сверх нужды; подмножество состояний хватает.
- Единая bash-реализация детекта, вызываемая из Swift (Codex) — спавн процесса на каждый refresh;
  parity-тест решает дрейф дешевле.

## Развилки к человеку (⛔ G4) — РЕШЕНЫ 2026-07-19 (D40–D42)

> Итог: (1) закрытие окна НЕ прерывает установку — фон в Dock, Cmd-Q спрашивает (D40);
> (2) пре-чек 1,5 ГБ, текст «~1 ГБ» (D41); (3) macOS < 14 → автоустановки нет, сразу
> «Вручную», легаси-пиннинг НЕ строим (D42) — ветка CAL-0.2/выбор URL по ОС упрощается:
> один URL /dist/osx + гейт по версии ОС. Ниже — как ставился вопрос.

1. **Закрытие окна во время установки** — единственное корневое расхождение:
   - A (Claude): диалог «Прервать/Продолжить», закрытие = отмена + зачистка. Проще.
   - B (Codex): закрытие окна НЕ прерывает — процесс живёт в Dock, загрузка идёт, повторное
     открытие показывает прогресс; Cmd-Q спрашивает. Дружелюбнее для 330 МБ.
   - **Рекомендация Юрки: B** — сценарий «нажал установить и свернул» естественен; store уже
     живёт в AppDelegate, цена — динамическая terminate-policy.
2. **Текст места на диске:** макеты говорят «~500 МБ», реальный пик ~1.1 ГБ → precheck 1.5 ГБ и
   текст «Нужно ~1 ГБ свободного места». Требует правки макетов (раунд 2 из 2).
3. **macOS 11–13 (наш минимум 11.0, свежий Calibre требует 14+):** пиннутые легаси-DMG
   (7.26/6.29, если CAL-0-пробы подтвердят URL) с фолбэком в «Вручную» — рекомендация; либо
   сразу «Вручную» на старых ОС.

## Следующий шаг

Ответы человека на 3 развилки → зафиксировать в decisions/log.md → execution-pack
(plans/status/test-plan) на базе CAL-0…CAL-5 с влитыми пунктами Codex → разработка микрошагами.
