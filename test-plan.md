# Test-plan — онбординг Calibre

> Гейты валидации для `plans.md` (CAL-1…CAL-5). Тесты привязаны к изменениям поведения,
> не «generic QA». Validation-first: milestone не закрыт, пока его гейт не зелёный.
> Сквозное правило: mutating тест-оверрайды работают ТОЛЬКО под защёлкой
> `FB2_CALIBRE_TEST_MODE=1` + install-root внутри `FB2_CALIBRE_TEST_ROOT` (урок 015);
> display-only `FB2_FORCE_INSTALL_STATE` — без защёлки.

## 1. Уровни тестов

| Уровень | Что проверяет | Раннер | Гейт для |
|---|---|---|---|
| Юниты локатора (Swift) | порядок кандидатов, валидность «все 3 CLI», защёлка TEST_MODE/TEST_ROOT, DISABLE_SYSTEM | `tests/run-calibre-locator-tests.sh` | CAL-1 |
| Parity bash↔Swift | installer.sh-детект ≡ CalibreLocator на одних деревьях | `tests/run-calibre-locator-parity.sh` | CAL-1 |
| Hardcode-grep | новые `/Applications/calibre.app` вне локатора/детекта/фолбэков = FAIL | `tests/run-calibre-hardcode-grep.sh` | CAL-1 (и в постоянный набор) |
| Юниты конвейера | защёлка, precheck-порог, OS-гейт (D42), парс версии из имени/redirect, SHA-512 на известном векторе, маппинг ошибок | внутри `tests/run-calibre-install-tests.sh` | CAL-3 |
| Fixture-DMG интеграция | полный конвейер download→sha→mount→checks→ditto→verify→swap→cleanup в throwaway HOME | `tests/run-calibre-install-tests.sh` | CAL-3 |
| UI-состояния (рендер) | все состояния flow.md §6 через `FB2_FORCE_INSTALL_STATE`, 400px, скриншоты ↔ design-spec | ручной прогон + design-reviewer | CAL-2, CAL-5 |
| Live-интеракция | клики/отмена/D40-жизненный цикл на фикстуре (computer-use / руки Юрки) | сценарии §5 | CAL-4, CAL-5 |
| ЖИВОЙ e2e (урок 016) | реальное скачивание+установка+конвертация, quarantine/notarization-факты | `RUN_LIVE=1 tests/run-calibre-live-e2e.sh` | CAL-5 (обязателен, ровно 1 прогон) |
| Регрессия | старое поведение не задето | существующие `tests/run-*.sh` (§6) | каждый milestone |

## 2. Критичные фикстуры

- **`tests/make-fake-calibre-dmg.sh <out-dir>`** → `calibre-fake.dmg` + `calibre-fake.dmg.sha512`:
  внутри мини-`calibre.app` — три стаб-CLI (`ebook-convert`/`ebook-meta`/`ebook-polish`, `--version`
  отвечает «calibre 9.99»; `ebook-convert` умеет «сконвертировать» = скопировать вход в .epub для
  smoke активации) + `Info.plist` с управляемым `LSMinimumSystemVersion`. Вариации: DMG без .app;
  стаб с rc≠0 (verify-fail); Info.plist с завышенным LSMinimumSystemVersion.
- **Деревья локатора (5):** только app-owned · только /Applications-фикстура · оба · частичный
  (нет ebook-polish) · пусто. Используются и юнитами, и parity.
- **Throwaway-агент:** `FB2_AGENT_LABEL="com.arrivarus.fb2toepub.test.$$"` + `HOME=<mktemp>` —
  боевой label/plist недосягаемы (урок 015). Тест сам делает `launchctl bootout` метки в trap.
- Стаб-CLI не проходят настоящий `codesign --verify` → под защёлкой действует
  `FB2_CALIBRE_SKIP_CODESIGN=1`; НАСТОЯЩИЙ codesign проверяет только живой e2e.

## 3. Smoke (после каждой сборки)

```sh
build/build-app.sh 0.10.0-dev
```
- Машина С валидным /Applications-Calibre: Status/Setup/Настройки выглядят как в v0.9.8 (скриншот-сверка),
  конвертация тестового .fb2 живёт.
- Изолированный запуск без движка (защёлка+throwaway HOME): виден блокер B (истории нет);
  подложить сырую историю в state.json фикстуры → баннер A (проверка «сырого snapshot», не loadState).

## 4. Негативные кейсы (обязательные)

| # | Кейс | Ожидание |
|---|---|---|
| N1 | SHA-512 не совпал / эталон недоступен | `.error(.install)`, DMG стёрт, staging нет |
| N2 | DMG без `calibre.app` | `.error(.install)`, mnt отмонтирован, мусора нет |
| N3 | Verify-fail (стаб rc≠0 / нет polish) | `.error(.install)`, staging снесён, старая копия (если была) цела |
| N4 | Нет места (порог поднят выше свободного) | `.error(.space)` ДО скачивания |
| N5 | Обрыв сети на середине (кill localhost-сервера) | `.error(.network)`, частичный файл стёрт, [Повторить] запускает заново |
| N6 | Отмена на середине скачивания | `idle`, частичный файл стёрт, CTA снова доступна |
| N7 | `LSMinimumSystemVersion` staged > текущей ОС | `.error(.install)` до свопа |
| N8 | macOS < 14 (симуляция гейта) | авто-путь недоступен, подача manual-only (D42) |
| N9 | Активация упала при живом движке (сломанный installer в фикстуре) | `agentActivationFailed`, «Повторить запуск агента» чинит БЕЗ повторного скачивания |
| N10 | Env-оверрайды БЕЗ `FB2_CALIBRE_TEST_MODE=1` (или root вне TEST_ROOT) | оверрайды молча игнорируются, прод-пути |
| N11 | Двойной тап «Установить» / установка ∥ авто-апдейт приложения | второй запуск отвергнут (re-entry guard / взаимоисключение) |
| N12 | Повторная установка поверх остатков (`calibre.app.installing`/`.old` от «крэша») | стартовая зачистка, happy-path проходит |
| N13 | «Сбросить статистику» при непустой истории | баннер A НЕ превращается в блокер B (сырой snapshot) |
| N14 | Закрыть окно на середине скачивания (D40) | процесс жив в Dock, reopen показывает прогресс |
| N15 | Cmd-Q на середине скачивания / во время copy-promote (D40) | диалог «Прервать?» / выход отложен до безопасной точки |

## 5. Live-сценарии (CAL-4/CAL-5, руки/computer-use, фикстура под защёлкой)

1. Happy: тап → прогресс → «Устанавливаю…» → «Проверяю…» → success 2с → обычный Status, бейдж «Активен».
2. Отмена → возврат в not-installed → повторный тап работает.
3. Manual: «Установить вручную» → [Открыть сайт] (браузер открылся) → «Проверить снова» без движка
   («пока не вижу») → подложить валидную фикстуру → «Проверить снова» → активация → success.
4. D40: закрыл окно на середине → Dock-клик → окно с прогрессом; Cmd-Q-диалог оба исхода.
5. Строка в Настройках: [Установить] → мини-прогресс+Отмена → error → [Повторить].
6. Setup-подача (свежий профиль): янтарный шаг «ДВИЖОК» → установка из Setup → шаг зелёный, «Готово к работе».

## 6. Регрессия (существующие наборы — зелёные на каждом milestone)

```sh
tests/run-clear-history-tests.sh      # 104 — baselines/история
tests/run-cover-job-tests.sh          # 40  — cover-джобы/утверждение
tests/run-fb3-tests.sh                # 25  — FB3-трансформ
tests/run-fb2-regression-test.sh      # 20  — FB2-путь
tests/run-sticky-batch-test.sh        # 30  — липкая пачка
tests/run-update-install-test.sh      #     — авто-апдейт приложения (взаимоискл. с установкой движка!)
tests/run-cover-edit-test.sh          #     — правка метаданных (использует EBOOK_META → чувствительна к CAL-1.7)
```
Особое внимание: `run-cover-edit-test.sh` и cover-finder-тесты после CAL-1.7 (EBOOK_META из env).

## 7. Acceptance-гейты (сводка по milestone)

- **CAL-1:** locator-юниты + parity + hardcode-grep зелёные; plist содержит `CALIBRE_MACOS_DIR`+`EBOOK_*`;
  вся регрессия §6 зелёная.
- **CAL-2:** скриншоты всех состояний ↔ design-spec; экраны с движком не изменились; N13.
- **CAL-3:** fixture happy-path + N1–N7, N10–N12; идемпотентность повторного прогона.
- **CAL-4:** live-сценарии 1–6 + N8, N9, N14, N15.
- **CAL-5 (готовность к релизу):**
  - [ ] `RUN_LIVE=1 tests/run-calibre-live-e2e.sh` PASS: реальный DMG скачан, SHA-512 сошёлся,
        настоящий `codesign --verify --strict` PASS, `ebook-convert --version` исполнился,
        реальный .fb2 → валидный EPUB app-owned движком, `xattr -l` БЕЗ `com.apple.quarantine`,
        `spctl -a -vv` accepted, plist (тест-label) указывает на app-owned пути.
  - [ ] Живой UI-прогон Юрки (реальные руки) — GREEN.
  - [ ] Design-review пиксель-чеклист PASS (≥1 несовпадение = FAIL).
  - [ ] Вся регрессия §6 + все новые раннеры зелёные, 0 red.
  - [ ] README RU/EN + changelog обновлены.
  - [ ] ⛔ Явное «да» человека (СТОП-точка) — до этого не выкладывать.

Живой e2e красный → СТОП: это опровержение quarantine/notarization-гипотезы ресёрча —
диагностика (debugger) и доклад человеку, НЕ релиз на стабах (урок 016).
