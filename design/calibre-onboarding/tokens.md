# Токены — Онбординг Calibre (P9)

> Мост дизайн → код для фичи «Онбординг движка Calibre» (гибрид A+B).
> Источник: `direction-A-banner.html`, `direction-B-blocker.html` (принятые макеты, G2b),
> состояния — `flow.md`. Значения сверены с **computed styles CSS**, не на глаз.
> База существующих токенов: `app/Tokens.swift` (единственный источник текущей системы).
>
> **Легенда токенов:**
> - **= `Tokens.X.y`** — значение уже есть, переиспользовать (не плодить дубликат).
> - **НОВ `CO.y`** — нового нет в системе; предложено имя в стиле `Tokens.swift`.
>   Предлагаемый namespace — `enum CO` (Calibre-Onboarding), по образцу существующего
>   `enum CS` (cover-select): один экран/фича = один namespace = пиксель-диф в один файл.
> - Формат alpha: `white(a)` = `Color.white(a)`; `rgba(r,g,b,a)` = `Color(.sRGB, …, opacity:a)`.
>
> **Что переиспользуется целиком (окно/шапка/футер/кредит/Setup-визард/строка-карточка):**
> оболочка `.win`, `.tbar`, `.hdr`, `.app-icon`, `.icon-btn`, `.card`, `.hairline`, `.cap`,
> `.footer`/`.btn`, `.credit`, `.welcome`/`.wizard`/`.step`/`.field`/`.footnote`, `.set-row`/`.row-ic`
> — всё уже описано в `Tokens.swift` (разделы Header / Footer / Setup / Group rows). Ниже —
> только **НОВЫЕ компоненты фичи** + точки, где нужно сослаться на существующий токен.
> Презентационный каркас галереи (`.intro`, `.gallery`, `figure`, `figcaption`, `.badge-core`,
> `.tag`, `.kick`) — это витрина HTML-демо, НЕ UI приложения → в токены не выносится.

---

## 0. Новые роли цвета (сводка — читать первой)

Главное добавление фичи — **роль danger/error**, которой в `Tokens.swift` нет вовсе
(в системе есть orange, magenta, emerald — красного нет). Вводится `#EB6B73`.

| Роль | Значение (HTML) | Токен | Где применяется |
|---|---|---|---|
| Danger (базовый) | `#EB6B73` (rgb 235,107,115) | **НОВ `CO.danger`** | текст/иконка/кольцо ошибки, foot-dot err |
| Danger — фон баннера | `rgba(235,107,115,.10)` | **НОВ `CO.dangerBg`** | `.banner-err` background |
| Danger — бордер баннера | `rgba(235,107,115,.30)` | **НОВ `CO.dangerBorder`** | `.banner-err` border |
| Danger — тинт иконки | `rgba(235,107,115,.14)` | **НОВ `CO.dangerTint`** | `.b-ic-err` background |
| Warn — фон баннера | `rgba(255,138,61,.10)` | **НОВ `CO.warnBg`** | `.banner-warn` (0.10 ≠ `tintOrange` 0.12) |
| Warn — бордер баннера/пилюли | `rgba(255,138,61,.28)` / `.30` | **НОВ `CO.warnBorder28` / `CO.warnBorder30`** | `.banner-warn` / `.pill-warn` |
| Warn — кольцо-пунктир | `rgba(255,138,61,.35)` | **НОВ `CO.ringWarnDash`** | блокер B, кольцо «нет движка» |
| Тень бренд-CTA (pink-red) | `#FF3D5A` (rgb 255,61,90) | **НОВ `CO.shadowBrand`** | box-shadow бренд-кнопок (стоп бренда, но как отдельный цвет тени) |

Переиспользуются как есть: `accentOrange #FF8A3D`, `magenta #E63CC8`, `emerald #34D399`,
`emeraldDark #1D9E75`, `tintOrange .12`, `tintEmerald .12`, `stepCurBg/stepOkBg .14`, `barTrack .07`.

---

## 1. Баннер-карточка (Направление A) — контейнер `.banner`

| Свойство | Значение (HTML) | Токен |
|---|---|---|
| margin-top | `4px` | = `M.heroTopGap` (4) |
| margin по бокам | `14px` | = `M.cardInset` (14) |
| margin-bottom | `12px` | = `M.cardSpacing` (12) |
| border-radius | `14px` | = `M.groupRadius` (14) |
| padding | `13px 14px` | padH = `M.cardInset` (14); **НОВ `CO.bannerPadV` = 13** |

### Варианты фона/бордера баннера

| Вариант | background | border | Токен |
|---|---|---|---|
| `.banner-warn` | `rgba(255,138,61,.10)` | `1px rgba(255,138,61,.28)` | **НОВ `CO.warnBg`** / **`CO.warnBorder28`** |
| `.banner-err` | `rgba(235,107,115,.10)` | `1px rgba(235,107,115,.30)` | **НОВ `CO.dangerBg`** / **`CO.dangerBorder`** |
| `.banner-ok` | `rgba(52,211,153,.12)` | `1px rgba(52,211,153,.28)` | bg = `C.emeraldBg` (.12); border **⚠ .28 ≠ `C.emeraldBorder` .25** → см. Риски |

### Внутренности баннера

| Элемент | Свойство | Значение | Токен |
|---|---|---|---|
| `.b-top` | gap | `11px` | = `M.rowGap` (11) |
| `.b-ic` | размер / радиус | `28×28` / `8px` | = `M.rowIcon` (28) / `M.rowIconRadius` (8) |
| `.b-ic-warn` | background | `rgba(255,138,61,.14)` | = `C.stepCurBg` (.14) |
| `.b-ic-err` | background | `rgba(235,107,115,.14)` | **НОВ `CO.dangerTint`** |
| `.b-ic-ok` | background | `rgba(52,211,153,.14)` | = `C.stepOkBg` (.14) |
| `.b-title` | шрифт | `13px / 600` | **НОВ `CO.bannerTitle` = system(13, .semibold)** (в системе нет 13-semibold) |
| `.b-title` | цвет (норма / ok / err) | `#F4F1FA` / `#34D399` / `#EB6B73` | = `C.textPrimary` / `C.emerald` / **`CO.danger`** |
| `.b-sub` | шрифт | `11.5px / 400` (не mono) | **НОВ `CO.bannerSub` = system(11.5, .regular)** |
| `.b-sub` | цвет / line-height / margin-top | `#9A8FB5` / `1.42` / `3px` | = `C.textSecondary` / lh 1.42 / **`CO.bSubTop` = 3** |
| `.b-actions` | gap / margin-top | `12px` / `12px` | **НОВ `CO.bActionsGap` = 12 / `CO.bActionsTop` = 12** |

---

## 2. Прогресс-бар скачивания `.prog` (общий A и B)

Это **отдельный** бар от stat-баров статистики (`M.barHeight` 3 / `M.barRadius` 2) — крупнее.

| Элемент | Свойство | Значение | Токен |
|---|---|---|---|
| `.prog` | height | `6px` | **НОВ `CO.progHeight` = 6** (≠ `M.barHeight` 3) |
| `.prog` | border-radius | `3px` | **НОВ `CO.progRadius` = 3** (≠ `M.barRadius` 2) |
| `.prog` | background (трек) | `rgba(255,255,255,.07)` | = `C.barTrack` (white .07) |
| `.prog > i` | заливка | `linear 90° #FFB23D → #FF6B2C` | = `G.barOrange` |
| `.prog > i` | border-radius | `3px` | **`CO.progRadius`** (3) |
| `.prog.indet > i` | ширина / анимация | `38%` / `slide 1.15s ease-in-out` | **НОВ `CO.progIndetWidth` = 0.38 / `CO.progIndetDur` = 1.15s** |
| `.prog-row` | margin-bottom | `7px` | **НОВ `CO.progRowBottom` = 7** |
| `.prog-label` | шрифт (mono, как «156 из 330 МБ») | `11.5px / 400 mono` | = `F.conv` / `F.fieldMono` (11.5 mono) |
| `.prog-label` | цвет | `#C9BFE0` | = `C.textSoft` |
| `.prog-pct` | шрифт (`.tnum`, «47%») | `11.5px / 700` tabular | **НОВ `CO.progPct` = system(11.5,.bold).monospacedDigit()** |
| `.prog-pct` | цвет | `#F4F1FA` | = `C.textPrimary` |

Подпись-формат (контент, не визуальный токен): **`«{скачано} из {всего} МБ»`** + **`«{N}%»`**;
`всего` = константа размера дистрибутива ≈ **330 МБ** (из flow.md §7).

---

## 3. Кольцо-блокер (Направление B) `.ring-wrap` + состояния

Геометрия кольца общая со Status-кольцом (переиспользуется):

| Свойство | Значение | Токен |
|---|---|---|
| Размер обёртки | `104×104` | = `M.ringSize` (104) |
| Радиус окружности `r` | `44` (viewBox 104, cx/cy 52) | = `M.ringSize`/2 − `M.ringStroke` |
| Толщина штриха | `8px` | = `M.ringStroke` (8) |
| Трек (фон-кольцо) | `rgba(255,255,255,.07)` | = `C.barTrack` |
| Длина окружности (dasharray) | `276.46` (= 2π·44) | **НОВ `CO.ringCircumference` = 276.46** |

### Состояния кольца

| Состояние | Штрих кольца | Иконка в центре | Токены |
|---|---|---|---|
| **warn** (нет движка) | пунктир `rgba(255,138,61,.35)`, `dasharray "4 10"`, round | ⚠ треугольник `34×34`, stroke `#FF8A3D` w2 | **`CO.ringWarnDash`** (.35); центр = `C.accentOrange` |
| **progress** (скачивание) | арк `G.brand` (4-стоп градиент), `dashoffset` по % (147 ≈ 47%), round, rotate −90° | текст `%` (см. ниже) | штрих = `G.ring`/`G.brand135`; см. `CO.ringPct` |
| **installing** (установка) | спиннер `dasharray "70 207"`, градиент `#FFB23D → #E63CC8` (2-стоп ⌀), `spin 1.1s linear` | шестерёнка `30×30`, stroke `#FF8A3D` w1.8 | **НОВ `CO.ringInstallGrad`** (2-стоп); **`CO.spinDur` = 1.1s**; центр = `C.accentOrange` |
| **success** (готово) | полное кольцо `#34D399`, round, rotate −90°, glow `drop-shadow(0 0 6px rgba(52,211,153,.6))` | ✓ галка `40×40`, stroke `#34D399` w2.4 | штрих/центр = `C.emerald`; **НОВ `CO.ringSuccessGlow`** |
| **error** (нет сети) | кольцо `#EB6B73`, `dashoffset` замер на ~47%, round | ✕ крест `34×34`, stroke `#EB6B73` w2.2 | штрих/центр = **`CO.danger`** |

`.ring-pct` (центр в progress): шрифт `22px / 700` tabular, цвет `#FF8A3D` →
**НОВ `CO.ringPct` = system(22,.bold).monospacedDigit()**, цвет = `C.accentOrange`.

**SF Symbols-эквиваленты иконок центра** (для дева, stroke-стиль ≈ `.regular`/`weight`):

| Смысл | SVG-путь (кратко) | SF Symbol |
|---|---|---|
| Предупреждение | треугольник + `!` | `exclamationmark.triangle` |
| Установка/шестерёнка | 8 радиальных лучей | `gearshape` (крутится вместе с кольцом) |
| Успех | `M5 13l4 4L19 7` | `checkmark` |
| Ошибка | `M8 8l8 8 M16 8l-8 8` | `xmark` |
| Скачать (на CTA) | `M12 3v12 M7 11l5 5 5-5 M5 21h14` | `arrow.down.to.line` / `square.and.arrow.down` |
| Повторить (на CTA) | `M20 11a8 8 0 10-2.3 5.7 …` | `arrow.clockwise` |
| Открыть сайт (на CTA) | `M14 5h5v5 M19 5l-9 9 …` | `arrow.up.right.square` |
| Нет сети (иконка баннера err, A) | волны Wi-Fi + слэш | `wifi.slash` |

---

## 4. Блокер — типографика/раскладка (Направление B) `.blocker`

| Элемент | Свойство | Значение | Токен |
|---|---|---|---|
| `.blocker` | padding | `22px 30px 28px` | **НОВ `CO.blockerPadTop`=22 / `CO.blockerPadH`=30 / `CO.blockerPadBottom`=28** |
| `.blocker` | min-height | `300px` | **НОВ `CO.blockerMinH` = 300** |
| `.bl-title` | шрифт / tracking | `18px / 700` / `-0.3px` | **НОВ `CO.blockerTitle` = system(18,.bold)**; tracking = `Track.welcomeH2` (−0.3) |
| `.bl-title` | цвет (норма / ok / err) | `#F4F1FA` / `#34D399` / `#EB6B73` | = `C.textPrimary` / `C.emerald` / **`CO.danger`** |
| `.bl-title` | margin-top | `18px` | **НОВ `CO.blTitleTop` = 18** |
| `.bl-body` | шрифт / line-height | `12.5px / 400` / `1.45` | = `F.welcomeSub` (12.5) / lh 1.45 |
| `.bl-body` | цвет / margin-top / max-width | `#9A8FB5` / `8px` / `300px` | = `C.textSecondary` / **`CO.blBodyTop`=8** / **`CO.blBodyMaxW`=300** |
| `.bl-body b` | акцент внутри | `#C9BFE0 / 400` | = `C.textSoft`, weight .regular |
| `.bl-mb` | шрифт (tabular, «≈330 МБ · бесплатно») | `11.5px / 400` tabular | **НОВ `CO.blMb` = system(11.5,.regular).monospacedDigit()** |
| `.bl-mb` | цвет / margin-top | `#7E748F` / `7px` | = `C.textTertiary` / **`CO.blMbTop` = 7** |

---

## 5. CTA-кнопки

### 5.1 `.cta-sm` — малая бренд-кнопка (Направление A: баннер/Setup; и Настройки)

| Контекст | padding | шрифт | Значение прочих | Токен |
|---|---|---|---|---|
| Базовая A (баннер, Setup «Установить Calibre») | `9px 15px` | `12.5px / 700` | radius 10, gap 7 | **НОВ `CO.ctaSmPadV`=9 / `CO.ctaSmPadH`=15 / `CO.ctaSmFont`=system(12.5,.bold) / `CO.ctaSmGap`=7**; radius = `M.fieldBtnRadius` (10) |
| В Настройках / базовая B | `8px 13px` | `12px / 700` | radius 10 | **НОВ `CO.ctaSmPadVsm`=8 / `CO.ctaSmPadHsm`=13 / `CO.ctaSmFontSm`=system(12,.bold)** |
| фон (общий) | — | — | `linear 135° #FFB23D→#FF6B2C→#FF3D5A→#E63CC8` | = `G.brand135` |
| цвет текста / border | — | — | `#fff` / none | white / — |
| box-shadow | — | — | `0 6px 16px -6px rgba(255,61,90,.6), inset 0 1px 0 rgba(255,255,255,.3)` | **НОВ `CO.ctaSmShadow`** (цвет = `CO.shadowBrand`) |

Вариант «оранжевый» (`Повторить`, `Открыть сайт Calibre` в A): тот же `.cta-sm`, но фон
`linear 135° #FFB23D → #FF6B2C` → **НОВ `CO.retryOrangeGrad`** (2-стоп 135°; ≠ `G.barOrange` — та 90°).

### 5.2 `.cta` — крупная кнопка блокера (Направление B)

| Свойство | Значение | Токен |
|---|---|---|
| width / margin-top | `100%` / `20px` | full / **НОВ `CO.ctaTop` = 20** |
| padding | `14px` (все стороны) | **НОВ `CO.ctaPad` = 14** |
| border-radius | `13px` | = `M.statRadius` (13) / `CS.ctaRadius` (13) |
| фон | `G.brand135` | = `G.brand135` |
| шрифт / цвет / gap | `15px / 700` / `#fff` / `8px` | = `CS.cta_` (15,.bold) / white / **`CO.ctaGap`=8** |
| box-shadow | `0 10px 24px -8px rgba(255,61,90,.6), inset 0 1px 0 rgba(255,255,255,.35)` | **НОВ `CO.ctaShadow`** (цвет = `CO.shadowBrand`) |

`.cta.orange` (крупная «Повторить»/«Открыть сайт», B): фон **`CO.retryOrangeGrad`**;
box-shadow `0 10px 24px -8px rgba(255,138,61,.55), …` → **НОВ `CO.ctaShadowOrange`** (цвет = `C.accentOrange` .55).

### 5.3 `.cta-ghost` — вторичная «Проверить снова» (Направление B)

| Свойство | Значение | Токен |
|---|---|---|
| width / margin-top / padding | `100%` / `20px` / `13px` | full / **`CO.ctaTop`** (20) / **НОВ `CO.ctaGhostPad` = 13** |
| border-radius | `13px` | = `M.statRadius` (13) |
| border / background | `1px rgba(255,255,255,.12)` / `rgba(255,255,255,.05)` | = `C.fieldBtnBorder` (.12) / `C.btnBg` (.05) |
| шрифт / цвет | `14px / 600` / `#F4F1FA` | = `F.stepTitle` (14,.semibold) / `C.textPrimary` |

### 5.4 `.mini-btn` — «Отмена» в баннере A

| Свойство | Значение | Токен |
|---|---|---|
| padding / radius | `6px 12px` / `8px` | **НОВ `CO.miniBtnPadV`=6 / `CO.miniBtnPadH`=12**; radius = `M.rowIconRadius` (8) |
| border / background | `1px rgba(255,255,255,.12)` / `rgba(255,255,255,.05)` | = `C.fieldBtnBorder` / `C.btnBg` |
| шрифт / цвет | `11.5px / 600` / `#F4F1FA` | **НОВ `CO.miniBtnFont` = system(11.5,.semibold)** / `C.textPrimary` |

### 5.5 `.link-btn` — текстовая вторичная («Установить вручную» / «Отмена» / «Проверить снова»)

| Контекст | Значение | Токен |
|---|---|---|
| Направление A | `12px / 600`, цвет `#9A8FB5` | = `F.link` (12,.semibold) / `C.textSecondary` |
| Направление B | `12.5px / 600`, цвет `#9A8FB5`, margin-top `14px` | **НОВ `CO.linkBtnFontB` = system(12.5,.semibold)** / `C.textSecondary` / **`CO.linkBtnTopB`=14** |
| `.orange` модификатор | цвет `#FF8A3D` | = `C.accentOrange` |

---

## 6. Блок ручной инструкции (нумерованные шаги)

⚠ Стиль шагов **различается** A и B (см. Риски) — привожу оба.

### 6.1 Направление A `.steps`

| Элемент | Свойство | Значение | Токен |
|---|---|---|---|
| `.steps` | gap / margin-top | `9px` / `4px` | **НОВ `CO.stepsGapA`=9 / `CO.stepsTopA`=4** |
| `.step-line` | gap | `9px` | **`CO.stepsGapA`** (9) |
| `.step-badge` | размер / радиус | `18×18` / `50%` | **НОВ `CO.stepBadgeA` = 18** |
| `.step-badge` | background / цвет | `rgba(255,255,255,.06)` / `#C9BFE0` | = `C.cardBorder` (white .06) / `C.textSoft` |
| `.step-badge` | шрифт | `10px / 700` | **НОВ `CO.stepBadgeFontA` = system(10,.bold)** |
| `.step-text` | шрифт / lh / цвет | `11.5px / 400` / `1.4` / `#C9BFE0` | **НОВ `CO.stepTextA` = system(11.5,.regular)** / lh 1.4 / `C.textSoft` |

### 6.2 Направление B `.steps`

| Элемент | Свойство | Значение | Токен |
|---|---|---|---|
| `.steps` | gap / margin-top | `11px` / `18px` | **НОВ `CO.stepsGapB`=11 / `CO.stepsTopB`=18** |
| `.step-line` | gap | `11px` | **`CO.stepsGapB`** (11) |
| `.step-badge` | размер / радиус | `20×20` / `50%` | **НОВ `CO.stepBadgeB` = 20** |
| `.step-badge` | background / border / цвет | `rgba(255,138,61,.14)` / `1px rgba(255,138,61,.3)` / `#FF8A3D` | = `C.stepCurBg` (.14) / **`CO.warnBorder30`** / `C.accentOrange` |
| `.step-badge` | шрифт | `11px / 700` | = `F.pill` (11,.bold) |
| `.step-text` | шрифт / lh / цвет | `12px / 400` / `1.42` / `#C9BFE0` | = `F.headerSub`/`F.rowLabel`-эквив (12,.regular) / lh 1.42 / `C.textSoft` |
| ссылка в шаге | `calibre-ebook.com` | mono, цвет `#F4F1FA` | = `F.conv` (mono) / `C.textPrimary` |

---

## 7. Строка Calibre в Настройках `.set-row` (CORE, общая A/B)

Контейнер и раскладка целиком на существующих токенах:

| Свойство | Значение | Токен |
|---|---|---|
| `.set-row` gap / padding / margin / radius | `11` / `12 14` / `0 14 12` / `14` | = `M.rowGap` / `M.rowPadV`+`M.rowPadH` / `M.cardInset`+`M.cardSpacing` / `M.groupRadius` |
| `.set-row.card` | fill/border | = `C.cardBg` / `C.cardBorder` |
| `.row-ic` | `28×28` / `8` | = `M.rowIcon` / `M.rowIconRadius` |

Состояния строки (из flow.md §6):

| Состояние | Иконка (тинт / stroke) | Текст | Действие | Токены |
|---|---|---|---|---|
| **не найден** | ⚠ `rgba(255,138,61,.12)` / `#FF8A3D` w2, 15px | `.row-label` `#FF8A3D` «Calibre не найден» + `.row-sub` «движок конвертации · без него…» | `[Установить]` = `.cta-sm` 8×13/12px | тинт = `C.tintOrange`; label = `C.accentOrange`; см. `CO.ctaSm*sm` |
| **скачивание** | — | «Скачиваю… 47%» + тонкий прогресс | `[Отмена]` | прогресс = `CO.prog*` |
| **ошибка** | ✕ `#EB6B73` | «Не удалось установить» | `[Повторить]` | = **`CO.danger`** |
| **установлен** | ✓ `rgba(52,211,153,.12)` / `#34D399` w2.4, 16px | `.row-label` «Calibre 7.21» + `.row-sub` «движок конвертации» | нет | тинт = `C.tintEmerald`; = `C.emerald` |

`.row-label` = `F.rowLabel` (13,.regular) / `C.textPrimary`; `.row-sub` = `F.rowSub` (11,.regular) /
`C.textTertiary`, margin-top 1. Иконки-эквиваленты: `exclamationmark.triangle`, `checkmark.circle`,
`shield` (Full Disk Access, `#FF8A3D`), `chevron.right` (`#7E748F`), `chevron.left` (back, `#9A8FB5`).

---

## 8. Честный бейдж агента `.pill` (янтарный «КОНВЕРТАЦИЯ НЕДОСТУПНА») — Направление A

| Элемент | Свойство | Значение | Токен |
|---|---|---|---|
| `.pill` | gap / padding / radius | `6px` / `3px 9px` / `7px` | **НОВ `CO.pillGap`=6 / `CO.pillPadV`=3 / `CO.pillPadH`=9 / `CO.pillRadius`=7** |
| `.pill-warn` | background | `rgba(255,138,61,.12)` | = `C.tintOrange` (.12) |
| `.pill-warn` | border | `1px rgba(255,138,61,.30)` | **`CO.warnBorder30`** |
| `.pdot` | размер / цвет | `6×6` / `#FF8A3D` | **НОВ `CO.pillDot`=6** / `C.accentOrange` |
| `.ptxt` | шрифт / цвет | `11px / 700` / `#FF8A3D` | = `F.pill` (11,.bold) / `C.accentOrange` |

Успешный бейдж (экран 4, «ФОНОВЫЙ АГЕНТ АКТИВЕН»): фон `rgba(52,211,153,.12)` = `C.emeraldBg`,
border `rgba(52,211,153,.25)` = **`C.emeraldBorder`** (.25 — тут совпадает!), точка `#34D399` +
glow `0 0 6px #34D399` (**НОВ `CO.pillDotGlowOk`**), текст `11px/700 #34D399` = `F.pill` / `C.emerald`.

---

## 9. Футер — точка статуса `.foot-dot`

| Вариант | Значение | Токен |
|---|---|---|
| `.foot-dot.warn` | `#FF8A3D` | = `C.accentOrange` |
| `.foot-dot.ok` | `#34D399` + glow `0 0 7px #34D399` | = `C.emerald` (+ glow, как в Status) |
| `.foot-dot.err` | `#EB6B73` (только в B) | **`CO.danger`** |

Размер точки `7×7` = `M.footDot` (7). Текст футера = `F.headerSub`(12)/`C.textSecondary` (существует).

---

## 10. Сводка предлагаемых НОВЫХ токенов (namespace `enum CO`)

**Цвета/тинты**
```
danger        = #EB6B73                      // danger base (текст/иконка/кольцо/foot-dot)
dangerBg      = rgba(235,107,115, .10)       // .banner-err bg
dangerBorder  = rgba(235,107,115, .30)       // .banner-err border
dangerTint    = rgba(235,107,115, .14)       // .b-ic-err bg
warnBg        = rgba(255,138,61,  .10)       // .banner-warn bg  (≠ tintOrange .12)
warnBorder28  = rgba(255,138,61,  .28)       // .banner-warn border
warnBorder30  = rgba(255,138,61,  .30)       // .pill-warn / step-badge B border
ringWarnDash  = rgba(255,138,61,  .35)       // блокер B, пунктир «нет движка»
shadowBrand   = #FF3D5A                        // цвет теней бренд-CTA (rgba 255,61,90)
```
**Градиенты**
```
retryOrangeGrad  = linear 135° [#FFB23D, #FF6B2C]     // .cta.orange / cta-sm orange
ringInstallGrad  = linear ⌀   [#FFB23D → #E63CC8]     // спиннер установки (2-стоп)
```
**Тени**
```
ctaSmShadow      = 0 6px 16px -6px shadowBrand@.6,  inset 0 1px 0 white@.3
ctaShadow        = 0 10px 24px -8px shadowBrand@.6, inset 0 1px 0 white@.35
ctaShadowOrange  = 0 10px 24px -8px accentOrange@.55, inset 0 1px 0 white@.35
ringSuccessGlow  = drop-shadow 0 0 6px rgba(52,211,153,.6)
pillDotGlowOk    = 0 0 6px #34D399
```
**Шрифты**
```
bannerTitle = system(13,   .semibold)                 // .b-title
bannerSub   = system(11.5, .regular)                  // .b-sub (non-mono)
progPct     = system(11.5, .bold).monospacedDigit()   // .prog-pct
ringPct     = system(22,   .bold).monospacedDigit()   // .ring-pct
blockerTitle= system(18,   .bold)                     // .bl-title  (tracking = Track.welcomeH2 −0.3)
blMb        = system(11.5, .regular).monospacedDigit()// .bl-mb
ctaSmFont   = system(12.5, .bold)                     // .cta-sm base (A)
ctaSmFontSm = system(12,   .bold)                     // .cta-sm (Настройки/B)
miniBtnFont = system(11.5, .semibold)                 // .mini-btn
linkBtnFontB= system(12.5, .semibold)                 // .link-btn (B)
stepBadgeFontA = system(10, .bold)                    // .step-badge (A)
stepTextA   = system(11.5, .regular)                  // .step-text (A)
// переиспользуются: F.welcomeSub(12.5) bl-body · CS.cta_(15,bold) .cta · F.stepTitle(14,semibold)
// .cta-ghost · F.pill(11,bold) .ptxt/step-badge B · F.conv/F.fieldMono(11.5 mono) .prog-label
```
**Метрики**
```
bannerPadV=13 · bSubTop=3 · bActionsGap=12 · bActionsTop=12
progHeight=6 · progRadius=3 · progRowBottom=7 · progIndetWidth=0.38 · progIndetDur=1.15
ringCircumference=276.46 · spinDur=1.1
blockerPadTop=22 · blockerPadH=30 · blockerPadBottom=28 · blockerMinH=300
blTitleTop=18 · blBodyTop=8 · blBodyMaxW=300 · blMbTop=7
ctaSmPadV=9 · ctaSmPadH=15 · ctaSmGap=7 · ctaSmPadVsm=8 · ctaSmPadHsm=13
ctaTop=20 · ctaPad=14 · ctaGap=8 · ctaGhostPad=13
miniBtnPadV=6 · miniBtnPadH=12
linkBtnTopB=14
pillGap=6 · pillPadV=3 · pillPadH=9 · pillRadius=7 · pillDot=6
stepsGapA=9 · stepsTopA=4 · stepBadgeA=18 · stepsGapB=11 · stepsTopB=18 · stepBadgeB=20
// переиспользуются: M.ringSize(104) · M.ringStroke(8) · M.rowIcon(28) · M.rowIconRadius(8)
// M.groupRadius(14) · M.statRadius(13) · M.cardInset(14) · M.cardSpacing(12) · M.heroTopGap(4)
// M.rowGap(11) · M.fieldBtnRadius(10) · Track.welcomeH2(−0.3)
```

**Счёт:** ~**79** значений покрыто. Из них **~34 переиспользуют** существующие токены
`Tokens.swift` (дубликаты не заведены), **~45 новых** предложено под `enum CO`
(9 цветов, 2 градиента, 5 теней/glow, 13 шрифтов, 16 метрик).

Покрытые группы: цвета/тинты · градиенты · тени · типографика · spacing/паддинги ·
радиусы · размеры иконок/колец · состояния (warn/downloading/installing/success/error/manual).
Брейкпоинт — один (400px `M.windowWidth`, тёмная тема безусловна), новых нет.

---

## 11. Находки / риски (несоответствия)

1. **Нет роли danger в `Tokens.swift`.** Красного/ошибочного цвета в системе не было; фича
   вводит `#EB6B73` (+ 3 alpha-варианта). Это осознанное расширение палитры — предложено
   как `CO.danger*`. Стоит решить: держать в `CO` или поднять `danger` в общий `Tokens.C`
   (он пригодится и другим экранам). **Рекомендация:** поднять базовый `#EB6B73` в `C.danger`.

2. **Emerald-border баннера ≠ токен.** `.banner-ok` border = `rgba(52,211,153,.28)`, а в системе
   `C.emeraldBorder = .25`. При этом успешный **пилюль-бейдж** в том же макете использует `.25`
   (= токен). То есть один «зелёный бордер» в макете задан двумя значениями (.28 и .25).
   **Рекомендация:** привести баннер к `.25` (`C.emeraldBorder`) — расхождение косметическое.

3. **`.cta-sm` имеет два размера.** База A (баннер/Setup) = `9×15 / 12.5px`; в Настройках и в
   базе B = `8×13 / 12px`. Один компонент — два набора. Это не баг макета (крупная кнопка в
   баннере vs компактная в строке настроек), но деву нужно 2 варианта. Заведены оба
   (`ctaSm*` / `ctaSm*sm`). **Вопрос-кандидат:** свести к одному размеру или оставить два?

4. **Manual-steps стилизованы по-разному в A и B.** A: бейдж `18px`, серый фон, `#C9BFE0` текст,
   `11.5/1.4`. B: бейдж `20px`, оранжевый фон+бордер, `#FF8A3D`, `12/1.42`. Гибрид A+B
   показывает разные подачи в разных ветках (§5 flow) — формально ок, но «ручная инструкция»
   выглядит неодинаково. Заведены оба. **Рекомендация:** если хочется единообразия — выбрать
   один стиль бейджа шага для обеих веток.

5. **`.link-btn` расходится A (12px) vs B (12.5px)** — вероятно случайный дрейф, не намеренный.
   **Рекомендация:** унифицировать до `12px` (`F.link`), убрать `linkBtnFontB`.

6. **Прогресс-бар vs stat-бары.** `.prog` = `6px/3r`, а статистические бары в системе `3px/2r`.
   Это разные сущности (загрузка ≠ статистика), поэтому не переиспользуются — новые `CO.prog*`.
   Флажок, чтобы дев случайно не подставил `M.barHeight`.

7. **Теней нет в `Tokens.swift`.** Система сейчас не токенизирует box-shadow (в т.ч. у
   существующей `.app-icon`/`.win`). Новые CTA несут заметные тени — предложены как значения
   `CO.*Shadow`. Если решим не тянуть тени в токены — дев берёт их как константы из этого
   файла (значения точные, приведены).

8. **`retryOrangeGrad` ≈ `G.barOrange`, но другой угол** (135° кнопка vs 90° бар). Стопы те же
   (`#FFB23D → #FF6B2C`). Не переиспользовал `G.barOrange`, чтобы не смешивать направление.

---

## 12. Вопросы к человеку

Нет (все развилки подачи сняты на G2b — гибрид A+B зафиксирован в flow.md §5).
Пункты 2–5 из «Находки/риски» — рекомендации по унификации, их можно решить на дизайн-спеке
(P10) без блокировки; поведение/значения от этого не ломаются.

**Следующий шаг (рекомендация):** готово для **дизайн-спец** (P10, гейт G3) — свести эти токены
с раскладкой каждого экрана в пиксельную спецификацию перед стартом разработки.
