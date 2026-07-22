#!/bin/bash
# run-calibre-locator-parity.sh — Swift ↔ bash parity контракта детекта (CAL-1).
#
# ЗАЧЕМ
# -----
# Контракт «где движок» намеренно реализован ДВАЖДЫ: app/CalibreLocator.swift
# (приложение — без спавна процессов на каждый refresh) и packaging/installer.sh
# §1 (агент/CLI). Две реализации ДРЕЙФУЮТ, если их не сверять — этот тест и есть
# защита от дрейфа: на одних и тех же деревьях обе обязаны отвечать БАЙТ-В-БАЙТ.
#
# КАК
# ---
# Swift-зонд (tests/CalibreLocatorParity) и installer.sh под
# FB2_CALIBRE_DETECT_ONLY=1 печатают один и тот же формат. Раннер строит
# фикстурные деревья со стабами вместо CLI и сравнивает выводы.
#
# БЕЗОПАСНОСТЬ (урок 015)
# -----------------------
# installer.sh здесь вызывается ТОЛЬКО в detect-only режиме: он печатает
# результат детекта и выходит ДО создания папок, копирования скриптов, генерации
# plist и любых launchctl. Плюс env -i + throwaway HOME: боевой агент, боевой
# plist и отслеживаемая папка человека недостижимы физически.
# Реальный Calibre не нужен: все деревья — стабы.
#
# Usage:  tests/run-calibre-locator-parity.sh
# Exit:   0 = parity держится, 1 = расхождение / сборка упала.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_DIR/app"
TDIR="$REPO_DIR/tests/CalibreLocatorParity"
INSTALLER="$REPO_DIR/packaging/installer.sh"

xcrun --find swiftc >/dev/null 2>&1 || {
  echo "run-calibre-locator-parity: swiftc not found (install Xcode)" >&2; exit 1; }
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
[[ -d "$SDK_PATH" ]] || {
  echo "run-calibre-locator-parity: macOS SDK not found via xcrun" >&2; exit 1; }
[[ -f "$INSTALLER" ]] || {
  echo "run-calibre-locator-parity: missing $INSTALLER" >&2; exit 1; }

SRCS=("$APP/CalibreLocator.swift" "$TDIR/main.swift")
for s in "${SRCS[@]}"; do
  [[ -f "$s" ]] || { echo "run-calibre-locator-parity: missing $s" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fb2-calparity.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"   # канонизируем: bash сравнивает pwd -P, Swift — realpath(3)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PROBE="$WORK/bin/calibre-locator-probe"
mkdir -p "$WORK/bin"

echo "==> compiling swift probe (xcrun swiftc, Foundation-only)"
xcrun swiftc -sdk "$SDK_PATH" -target "$(uname -m)-apple-macos11.0" "${SRCS[@]}" -o "$PROBE"
echo ""

PASS=0
FAIL=0

# Собрать calibre.app со списком CLI-стабов: make_calibre <путь к .app> [cli...]
make_calibre() {
  local app="$1"; shift
  local macos="$app/Contents/MacOS" cli
  mkdir -p "$macos"
  for cli in "$@"; do
    printf '#!/bin/bash\necho "%s (calibre 9.9.9)"\n' "$cli" > "$macos/$cli"
    chmod 755 "$macos/$cli"
  done
}

# Прогнать обе реализации на одном дереве и сравнить.
#   check <имя> <HOME> <TEST_ROOT|-> <DISABLE_SYSTEM 0|1> <TEST_MODE 0|1>
check() {
  local name="$1" home="$2" troot="$3" disable="$4" tmode="$5"
  local -a envv=(PATH=/usr/bin:/bin "HOME=$home")
  [[ "$tmode" == "1" ]] && envv+=("FB2_CALIBRE_TEST_MODE=1")
  [[ "$troot" != "-" ]] && envv+=("FB2_CALIBRE_TEST_ROOT=$troot")
  [[ "$disable" == "1" ]] && envv+=("FB2_CALIBRE_DISABLE_SYSTEM=1")

  local swift_out bash_out
  swift_out="$(env -i "${envv[@]}" "$PROBE")"
  bash_out="$(env -i "${envv[@]}" FB2_CALIBRE_DETECT_ONLY=1 /bin/bash "$INSTALLER")"

  if [[ "$swift_out" == "$bash_out" ]]; then
    PASS=$((PASS + 1))
    echo "  ok   - $name"
    echo "         → $(printf '%s' "$swift_out" | head -1)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL - $name"
    echo "         swift: $swift_out"
    echo "         bash : $bash_out"
  fi
}

# Дерево-фикстура: <tag> → канонический HOME внутри WORK.
mkhome() { local h="$WORK/$1/home"; mkdir -p "$h"; printf '%s' "$h"; }
appowned() { printf '%s' "$1/Library/Application Support/fb2-to-epub/calibre.app"; }

echo "# --- parity: одинаковые деревья, две реализации ---"

# T1. Пусто (и системные кандидаты выключены) → обе «движка нет».
H1="$(mkhome t1)"; R1="$WORK/t1"
check "T1 пусто → NONE" "$H1" "$R1" 1 1

# T2. Полная app-owned установка → обе видят наш путь.
H2="$(mkhome t2)"; R2="$WORK/t2"
make_calibre "$(appowned "$H2")" ebook-convert ebook-meta ebook-polish
check "T2 app-owned полный → наш путь" "$H2" "$R2" 1 1

# T3. Частичная (нет ebook-polish) → обе «движка нет» (ключевая новая семантика).
H3="$(mkhome t3)"; R3="$WORK/t3"
make_calibre "$(appowned "$H3")" ebook-convert ebook-meta
check "T3 частичный (без polish) → NONE" "$H3" "$R3" 1 1

# T4. Частичный app-owned + полный TEST_ROOT → обе перескакивают на TEST_ROOT.
H4="$(mkhome t4)"; R4="$WORK/t4"
make_calibre "$(appowned "$H4")" ebook-convert
make_calibre "$R4/calibre.app" ebook-convert ebook-meta ebook-polish
check "T4 частичный app-owned + TEST_ROOT → TEST_ROOT" "$H4" "$R4" 1 1

# T5. Оба полные → обе берут ПЕРВОГО кандидата (TEST_ROOT), т.е. порядок совпал.
H5="$(mkhome t5)"; R5="$WORK/t5"
make_calibre "$(appowned "$H5")" ebook-convert ebook-meta ebook-polish
make_calibre "$R5/calibre.app" ebook-convert ebook-meta ebook-polish
check "T5 оба полные → выигрывает первый кандидат" "$H5" "$R5" 1 1

# T6. ebook-meta без бита +x → обе «движка нет» (правило валидности одинаково).
H6="$(mkhome t6)"; R6="$WORK/t6"
make_calibre "$(appowned "$H6")" ebook-convert ebook-meta ebook-polish
chmod 644 "$(appowned "$H6")/Contents/MacOS/ebook-meta"
check "T6 meta без +x → NONE" "$H6" "$R6" 1 1

# T7. ЗАЩЁЛКИ НЕТ (нет TEST_MODE): обе ОБЯЗАНЫ проигнорировать TEST_ROOT и
# DISABLE_SYSTEM. Дерево в TEST_ROOT полное — и обе всё равно его не берут.
H7="$(mkhome t7)"; R7="$WORK/t7"
make_calibre "$R7/calibre.app" ebook-convert ebook-meta ebook-polish
check "T7 без TEST_MODE → env игнорируются обеими" "$H7" "$R7" 1 0

# T8. Системные кандидаты ВКЛЮЧЕНЫ (реальные /Applications и ~/Applications
# текущей машины). Обе реализации обязаны сойтись на том, что там есть на самом
# деле — это единственный кейс, где парность проверяется на живой системе.
H8="$(mkhome t8)"
check "T8 системные кандидаты включены → одинаковый вердикт" "$H8" "-" 0 0

# T9. TEST_ROOT="/" при TEST_MODE=1 — слишком широкий корень (m2-близнец): обе реализации
# ОБЯЗАНЫ его отвергнуть (иначе боевые пути «внутри TEST_ROOT»). Отвергнутая защёлка = env
# игнорируются → детект как без защёлки. Проверяем именно СОГЛАСИЕ swift↔bash (значение
# зависит от машины, но обе обязаны сойтись на одном вердикте).
H9="$(mkhome t9)"
check "T9 TEST_ROOT=/ отвергнута → env игнорируются обеими (m2)" "$H9" "/" 1 1

echo ""
echo "1..$((PASS + FAIL))"
echo "# passed: $PASS"
echo "# failed: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
