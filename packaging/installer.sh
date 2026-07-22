#!/bin/bash
# fb2-to-epub installer (all install logic lives here).
#
# Responsibilities:
#   - detect Calibre (ebook-convert) and python3 (clear message if missing)
#   - accept a WATCH_DIR (arg or env); create it if absent
#   - copy watcher + cover-finder + runner into App Support/bin
#   - generate the LaunchAgent plist via `plutil` (NOT sed) so arbitrary paths
#     with spaces / unicode are encoded safely
#   - (re)load the agent idempotently: bootout -> bootstrap -> enable -> kickstart
#   - print Full Disk Access guidance when WATCH_DIR is in a TCC-protected zone
#
# Usage:
#   installer.sh ["/path/to/watch folder"]
#   WATCH_DIR="/path/to/folder" installer.sh
# Default WATCH_DIR: ~/Desktop/fb2-to-epub
#
# Invoked both by the .app applet (do shell script) and by the advanced CLI
# install.sh. Idempotent: re-running re-points the agent without leaving dupes.

set -euo pipefail

# ---------------------------------------------------------------------------
# Тест-защёлка (урок .patches/015) — ДО констант, т.к. от неё зависит LABEL.
#
# Однажды verify-оверрайд протёк в боевой инсталлер и переписал РЕАЛЬНЫЙ plist
# агента человека. Поэтому любой тест-оверрайд здесь двухступенчатый:
#   • read-only  (подмена кандидатов детекта) — нужен FB2_CALIBRE_TEST_MODE=1
#     и существующий FB2_CALIBRE_TEST_ROOT;
#   • MUTATING   (метка агента = какой plist мы перезапишем) — нужно ЕЩЁ и то,
#     чтобы install-root ($HOME/Library/Application Support/fb2-to-epub) лежал
#     ВНУТРИ канонизированного TEST_ROOT.
# Не сошлось — переменные молча игнорируются (боевой путь неотличим от прежнего).
# Swift-близнец: app/CalibreLocator.swift → CalibreTestLatch.
# ---------------------------------------------------------------------------
calibre_test_root() {
  [[ "${FB2_CALIBRE_TEST_MODE:-}" == "1" ]] || return 1
  local raw="${FB2_CALIBRE_TEST_ROOT:-}"
  [[ -n "$raw" && -d "$raw" ]] || return 1
  local root
  root="$(cd "$raw" && pwd -P)" || return 1
  # Ужесточение защёлки (m2-близнец — parity со Swift CalibreTestLatch.testRoot):
  # слишком широкий TEST_ROOT сделал бы боевые пути «внутри TEST_ROOT», и мутирующие
  # оверрайды (метка агента, а с H1 — ещё и HOME/state/covers/log в plist) навелись бы
  # на прод. Такой TEST_ROOT — не защёлка, отвергаем:
  #   • "/" — внутри него вообще всё;
  #   • TEST_ROOT, СОДЕРЖАЩИЙ настоящий домашний каталог пользователя. Берём passwd-home
  #     (dscl NFSHomeDirectory, фолбэк `eval echo ~user`), а НЕ $HOME: изолированные тесты
  #     подменяют $HOME throwaway-путём ВНУТРИ TEST_ROOT — сверять надо с реальным домом.
  [[ "$root" == "/" ]] && return 1
  local uname phome
  uname="$(id -un 2>/dev/null || true)"
  if [[ -n "$uname" ]]; then
    phome="$(dscl . -read "/Users/$uname" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')"
    [[ -z "$phome" ]] && phome="$(eval echo "~$uname" 2>/dev/null || true)"
    if [[ -n "$phome" && -d "$phome" ]]; then
      phome="$(cd "$phome" && pwd -P)"
      # isInside(passwd-home, root): равен корню или лежит под ним (граница сегмента).
      if [[ "$phome" == "$root" || "$phome" == "$root"/* ]]; then
        return 1
      fi
    fi
  fi
  printf '%s' "$root"
}
LATCH_ROOT="$(calibre_test_root || true)"

latch_allows_mutation() {
  [[ -n "$LATCH_ROOT" ]] || return 1
  [[ -d "$HOME" ]] || return 1
  local install_root
  install_root="$(cd "$HOME" && pwd -P)/Library/Application Support/fb2-to-epub"
  case "$install_root" in
    "$LATCH_ROOT"|"$LATCH_ROOT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Read-only режим для parity-теста: напечатать результат детекта и выйти ДО
# любой записи на диск/в launchd. По построению ничего не мутирует.
calibre_detect_only() { [[ "${FB2_CALIBRE_DETECT_ONLY:-}" == "1" ]]; }

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
LABEL="com.arrivarus.fb2toepub.agent"
# Тест-оверрайд метки: изолированная активация агента в тестах. МУТИРУЮЩИЙ —
# только под полной защёлкой (см. выше), иначе игнорируется.
if [[ -n "${FB2_AGENT_LABEL:-}" ]] && latch_allows_mutation; then
  LABEL="$FB2_AGENT_LABEL"
fi
APP_SUPPORT="$HOME/Library/Application Support/fb2-to-epub"
BIN_DIR="$APP_SUPPORT/bin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/fb2-to-epub.log"
AGENT_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
# Cover apply-jobs (M5): the app drops jobs here; this dir is in the agent's
# WatchPaths so a dropped job fires the agent. It must exist before (re)load.
COVERS_JOBS_DIR="$APP_SUPPORT/covers/jobs"

RUNNER_DST="$BIN_DIR/fb2-to-epub-runner.sh"
WATCHER_DST="$BIN_DIR/fb2-to-epub-watcher.sh"
COVER_DST="$BIN_DIR/fb2-to-epub-cover-finder.py"
# FB3 support: transform + its genre map, installed next to the other bin scripts
# so the watcher (which resolves them relative to itself) finds them after install.
FB3_DST="$BIN_DIR/fb2-to-epub-fb3.py"
FB3_GENRE_DST="$BIN_DIR/fb2-to-epub-fb3-genre.json"

# Resolve where our source scripts are. Search order:
#   1) FB2_SRC_DIR override (used by build/tests)
#   2) a sibling layout when run from a checkout (packaging/.. -> bin/, packaging/)
#   3) the same directory as this installer (the .app Resources layout)
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
find_src() {
  local name="$1"
  local c
  for c in \
    "${FB2_SRC_DIR:-}/$name" \
    "$SELF_DIR/$name" \
    "$SELF_DIR/../bin/$name" \
    "$SELF_DIR/bin/$name"; do
    [[ -n "$c" && -f "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# 1. Detect Calibre + python3
# ---------------------------------------------------------------------------
# КОНТРАКТ ДЕТЕКТА (plans.md, инвариант 5) — bash-близнец app/CalibreLocator.swift.
# Порядок кандидатов: app-owned → /Applications → ~/Applications; валидная
# локация = исполняемы ВСЕ ТРИ CLI (частичный Calibre = «движка нет»).
# Синхронность двух реализаций держит tests/run-calibre-locator-parity.sh.
CALIBRE_MACOS_DEFAULT="/Applications/calibre.app/Contents/MacOS"

# Валидна ли папка Contents/MacOS: три CLI, каждый — исполняемый НЕ-каталог.
calibre_dir_valid() {
  local d="$1" cli
  for cli in ebook-convert ebook-meta ebook-polish; do
    [[ -f "$d/$cli" && -x "$d/$cli" ]] || return 1
  done
  return 0
}

# Кандидаты в порядке контракта. Под защёлкой первым ВСТАВЛЯЕТСЯ (не заменяет)
# <TEST_ROOT>/calibre.app, а FB2_CALIBRE_DISABLE_SYSTEM=1 убирает кандидатов 2–3.
CANDIDATES=()
if [[ -n "$LATCH_ROOT" ]]; then
  CANDIDATES+=("$LATCH_ROOT/calibre.app/Contents/MacOS")
fi
CANDIDATES+=("$APP_SUPPORT/calibre.app/Contents/MacOS")
if [[ -z "$LATCH_ROOT" || "${FB2_CALIBRE_DISABLE_SYSTEM:-}" != "1" ]]; then
  CANDIDATES+=("$CALIBRE_MACOS_DEFAULT")
  CANDIDATES+=("$HOME/Applications/calibre.app/Contents/MacOS")
fi

CALIBRE_MACOS_DIR=""
CALIBRE_PARTIAL_DIR=""   # нашли ebook-convert, но набор неполный

if [[ -n "${EBOOK_CONVERT:-}" ]]; then
  # Явный env-оверрайд — ВЫСШИЙ приоритет (как и до CAL-1): CLI-инсталл и
  # нестандартные раскладки Calibre. Кандидаты в этом случае не перебираем.
  if [[ ! -x "$EBOOK_CONVERT" ]]; then
    if calibre_detect_only; then printf 'CALIBRE_MACOS_DIR=NONE\n'; exit 0; fi
    cat >&2 <<EOF
fb2-to-epub: Calibre not found.

Expected: $EBOOK_CONVERT

Install Calibre first:
  - Download: https://calibre-ebook.com/download_osx
  - or:       brew install --cask calibre

Then run this installer again.
EOF
    exit 1
  fi
  CALIBRE_MACOS_DIR="$(cd "$(dirname "$EBOOK_CONVERT")" && pwd)"
else
  for cand in "${CANDIDATES[@]}"; do
    if calibre_dir_valid "$cand"; then
      CALIBRE_MACOS_DIR="$(cd "$cand" && pwd)"
      break
    fi
    if [[ -z "$CALIBRE_PARTIAL_DIR" && -f "$cand/ebook-convert" && -x "$cand/ebook-convert" ]]; then
      CALIBRE_PARTIAL_DIR="$cand"
    fi
  done

  if [[ -z "$CALIBRE_MACOS_DIR" ]]; then
    if calibre_detect_only; then printf 'CALIBRE_MACOS_DIR=NONE\n'; exit 0; fi
    if [[ -n "$CALIBRE_PARTIAL_DIR" ]]; then
      # Calibre вроде есть, но набор неполный — тот же честный отказ, что и раньше.
      {
        echo "fb2-to-epub: Calibre is installed but some required tools are missing:"
        echo
        for cli in ebook-convert ebook-meta ebook-polish; do
          [[ -f "$CALIBRE_PARTIAL_DIR/$cli" && -x "$CALIBRE_PARTIAL_DIR/$cli" ]] || \
            echo "  - $cli   ($CALIBRE_PARTIAL_DIR/$cli)"
        done
        echo
        echo "These ship with a normal Calibre install. Update Calibre, then re-run:"
        echo "  - Download: https://calibre-ebook.com/download_osx"
        echo "  - or:       brew upgrade --cask calibre"
      } >&2
      exit 1
    fi
    {
      echo "fb2-to-epub: Calibre not found."
      echo
      echo "Looked in:"
      for cand in "${CANDIDATES[@]}"; do echo "  - $cand"; done
      echo
      echo "Install Calibre first:"
      echo "  - Download: https://calibre-ebook.com/download_osx"
      echo "  - or:       brew install --cask calibre"
      echo
      echo "Then run this installer again."
    } >&2
    exit 1
  fi
fi

# ebook-convert/meta/polish — производные ОДНОГО CALIBRE_MACOS_DIR (их и пишем в
# plist). Env-оверрайды остаются рабочими для нестандартных раскладок.
EBOOK_CONVERT="${EBOOK_CONVERT:-$CALIBRE_MACOS_DIR/ebook-convert}"
EBOOK_META="${EBOOK_META:-$CALIBRE_MACOS_DIR/ebook-meta}"
EBOOK_POLISH="${EBOOK_POLISH:-$CALIBRE_MACOS_DIR/ebook-polish}"

missing=()
[[ -x "$EBOOK_META" ]]   || missing+=("ebook-meta   ($EBOOK_META)")
[[ -x "$EBOOK_POLISH" ]] || missing+=("ebook-polish ($EBOOK_POLISH)")
if [[ ${#missing[@]} -gt 0 ]]; then
  if calibre_detect_only; then printf 'CALIBRE_MACOS_DIR=NONE\n'; exit 0; fi
  {
    echo "fb2-to-epub: Calibre is installed but some required tools are missing:"
    echo
    for m in "${missing[@]}"; do echo "  - $m"; done
    echo
    echo "These ship with a normal Calibre install. Update Calibre, then re-run:"
    echo "  - Download: https://calibre-ebook.com/download_osx"
    echo "  - or:       brew upgrade --cask calibre"
  } >&2
  exit 1
fi

# Детект завершён и валиден. В detect-only выходим ЗДЕСЬ — до создания папок,
# копирования скриптов, генерации plist и launchctl (parity-тест ничего не пишет).
if calibre_detect_only; then
  printf 'CALIBRE_MACOS_DIR=%s\n' "$CALIBRE_MACOS_DIR"
  printf 'EBOOK_CONVERT=%s\n' "$EBOOK_CONVERT"
  printf 'EBOOK_META=%s\n' "$EBOOK_META"
  printf 'EBOOK_POLISH=%s\n' "$EBOOK_POLISH"
  exit 0
fi

detect_python3() {
  local cand
  for cand in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [[ -x "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  cand="$(command -v python3 2>/dev/null || true)"
  [[ -n "$cand" ]] && { printf '%s' "$cand"; return 0; }
  return 1
}
if ! PYTHON3="$(detect_python3)"; then
  cat >&2 <<EOF
fb2-to-epub: python3 not found.

Install the Xcode Command Line Tools (provides /usr/bin/python3):
  xcode-select --install

Then run this installer again.
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Resolve WATCH_DIR
# ---------------------------------------------------------------------------
WATCH_DIR="${1:-${WATCH_DIR:-$HOME/Desktop/fb2-to-epub}}"
# Normalize a literal leading tilde from user input (it would not expand inside
# the quoted arg/env). We match the literal '~' on purpose, then expand via HOME.
# shellcheck disable=SC2088
case "$WATCH_DIR" in
  "~"|"~/"*) WATCH_DIR="$HOME/${WATCH_DIR#\~/}" ;;
esac
mkdir -p "$WATCH_DIR"
WATCH_DIR="$(cd "$WATCH_DIR" && pwd)"

# ---------------------------------------------------------------------------
# 3. Copy scripts into App Support/bin
# ---------------------------------------------------------------------------
mkdir -p "$BIN_DIR" "$(dirname "$PLIST")" "$(dirname "$LOG_FILE")" "$COVERS_JOBS_DIR"

src_runner="$(find_src fb2-to-epub-runner.sh)"   || { echo "fb2-to-epub: missing fb2-to-epub-runner.sh source" >&2; exit 1; }
src_watcher="$(find_src fb2-to-epub-watcher.sh)" || { echo "fb2-to-epub: missing fb2-to-epub-watcher.sh source" >&2; exit 1; }
src_cover="$(find_src fb2-to-epub-cover-finder.py)" || { echo "fb2-to-epub: missing fb2-to-epub-cover-finder.py source" >&2; exit 1; }
src_fb3="$(find_src fb2-to-epub-fb3.py)"            || { echo "fb2-to-epub: missing fb2-to-epub-fb3.py source" >&2; exit 1; }
src_fb3_genre="$(find_src fb2-to-epub-fb3-genre.json)" || { echo "fb2-to-epub: missing fb2-to-epub-fb3-genre.json source" >&2; exit 1; }

# runner.sh is the FDA-granted "responsible" target — the TCC grant is keyed to
# this file. On update, only (re)install it if missing or actually changed, so an
# idempotent re-run never churns the file and risks dropping the user's FDA grant.
if [[ ! -f "$RUNNER_DST" ]] || ! cmp -s "$src_runner" "$RUNNER_DST"; then
  install -m 0755 "$src_runner" "$RUNNER_DST"
fi
install -m 0755 "$src_watcher" "$WATCHER_DST"
install -m 0755 "$src_cover"   "$COVER_DST"
install -m 0755 "$src_fb3"       "$FB3_DST"
install -m 0644 "$src_fb3_genre" "$FB3_GENRE_DST"

# ---------------------------------------------------------------------------
# 4. Generate the LaunchAgent plist via plutil (safe for spaces/unicode)
#    Build a minimal valid skeleton, then insert/replace typed values whose
#    contents are passed as separate argv -> never spliced into XML.
# ---------------------------------------------------------------------------
gen_plist() {
  local out="$1"
  # Minimal valid empty-dict plist to seed plutil edits.
  cat > "$out" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST

  plutil -replace Label -string "$LABEL" "$out"

  # ProgramArguments -> [ runner ]
  plutil -replace ProgramArguments -json '[]' "$out"
  plutil -insert  ProgramArguments.0 -string "$RUNNER_DST" "$out"

  # WatchPaths -> [ WATCH_DIR, COVERS_JOBS_DIR ]
  # The watch folder fires the agent on new books; covers/jobs fires it when the
  # app drops a cover apply-job (M5) so the agent applies the chosen cover under
  # its Full Disk Access. The dir must EXIST for launchd to watch it (created
  # below before (re)load).
  plutil -replace WatchPaths -json '[]' "$out"
  plutil -insert  WatchPaths.0 -string "$WATCH_DIR" "$out"
  plutil -insert  WatchPaths.1 -string "$COVERS_JOBS_DIR" "$out"

  # EnvironmentVariables -> { WATCH_DIR, PATH, CALIBRE_MACOS_DIR, EBOOK_CONVERT,
  #                           EBOOK_META, EBOOK_POLISH, PYTHON3 }
  #
  # CALIBRE_MACOS_DIR (CAL-1) — ОДИН источник правды о том, где движок: агент
  # переживает переезд Calibre (наша папка ↔ /Applications) без гадания по путям.
  # Три EBOOK_* остаются абсолютами и производными от него — старый watcher,
  # который читает только их, продолжает работать без изменений.
  plutil -replace EnvironmentVariables -json '{}' "$out"
  plutil -insert  EnvironmentVariables.WATCH_DIR     -string "$WATCH_DIR"     "$out"
  plutil -insert  EnvironmentVariables.PATH          -string "$AGENT_PATH"    "$out"
  plutil -insert  EnvironmentVariables.CALIBRE_MACOS_DIR -string "$CALIBRE_MACOS_DIR" "$out"
  plutil -insert  EnvironmentVariables.EBOOK_CONVERT -string "$EBOOK_CONVERT" "$out"
  plutil -insert  EnvironmentVariables.EBOOK_META    -string "$EBOOK_META"    "$out"
  plutil -insert  EnvironmentVariables.EBOOK_POLISH  -string "$EBOOK_POLISH"  "$out"
  plutil -insert  EnvironmentVariables.PYTHON3       -string "$PYTHON3"       "$out"

  # H1 (ре-ревью, цикл 2): ТОЛЬКО под тест-защёлкой мутации закрепляем в plist HOME и
  # пути state/covers/log, ПРОИЗВОДНЫЕ от throwaway-HOME теста. Иначе агент, который
  # РЕАЛЬНЫЙ launchd поднимает по этому plist, не наследует env теста и пишет боевой
  # state.json / дренирует боевые covers-jobs / пишет боевой лог (launchd НЕ пиннит
  # throwaway-HOME). Значения — ровно по формуле дефолтов watcher
  # (bin/fb2-to-epub-watcher.sh §env: LOG_FILE/STATE_DIR/COVERS_DIR); явный env-оверрайд
  # уважается (за throwaway-корректность оверрайдов отвечает харнесс). БЕЗ защёлки
  # (боевая установка) блок пропускается → plist БАЙТ-В-БАЙТ прежний (обязательный
  # негатив-тест). Swift-семантика защёлки — app/CalibreLocator.swift → CalibreTestLatch.
  if latch_allows_mutation; then
    plutil -insert EnvironmentVariables.HOME           -string "$HOME"                                                                      "$out"
    plutil -insert EnvironmentVariables.FB2_STATE_DIR  -string "${FB2_STATE_DIR:-$HOME/Library/Application Support/fb2-to-epub/state}"       "$out"
    plutil -insert EnvironmentVariables.FB2_COVERS_DIR -string "${FB2_COVERS_DIR:-$HOME/Library/Application Support/fb2-to-epub/covers}"     "$out"
    plutil -insert EnvironmentVariables.FB2_LOG_FILE   -string "${FB2_LOG_FILE:-$HOME/Library/Logs/fb2-to-epub.log}"                         "$out"
  fi

  plutil -replace RunAtLoad       -bool true "$out"
  plutil -replace ThrottleInterval -integer 5 "$out"
  plutil -replace StandardOutPath  -string "$LOG_FILE" "$out"
  plutil -replace StandardErrorPath -string "$LOG_FILE" "$out"

  # Final sanity: must be a valid plist.
  plutil -lint "$out" >/dev/null
}

# Generate into a temp file, then atomically move it into place. mktemp gives a
# bare name; appending .plist keeps `plutil` happy without orphaning the base
# file. The trap cleans up the temp on any early exit (set -e).
tmp_plist_base="$(mktemp -t fb2plist)"
tmp_plist="$tmp_plist_base.plist"
trap 'rm -f "$tmp_plist_base" "$tmp_plist"' EXIT
gen_plist "$tmp_plist"
mv -f "$tmp_plist" "$PLIST"
rm -f "$tmp_plist_base"
trap - EXIT

# ---------------------------------------------------------------------------
# 5. (Re)load the agent idempotently
# ---------------------------------------------------------------------------
domain="gui/$(id -u)"

# Migration: remove the legacy hand-installed agent (com.user.fb2-to-epub).
# Earlier manual/CLI installs left a SEPARATE agent watching the same folder,
# which double-converts alongside ours. Remove it (idempotent) so exactly one
# agent (ours) remains. Touches ONLY this specific legacy label + its plist.
LEGACY_LABEL="com.user.fb2-to-epub"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
if [[ -f "$LEGACY_PLIST" ]] || launchctl print "$domain/$LEGACY_LABEL" >/dev/null 2>&1; then
  launchctl bootout "$domain/$LEGACY_LABEL" 2>/dev/null || true
  rm -f "$LEGACY_PLIST"
  echo "migration: removed legacy agent $LEGACY_LABEL"
fi

# bootout is best-effort (agent may not be loaded yet); ignore its failure.
launchctl bootout "$domain/$LABEL" 2>/dev/null || true
launchctl bootstrap "$domain" "$PLIST"
launchctl enable "$domain/$LABEL" 2>/dev/null || true
launchctl kickstart -k "$domain/$LABEL" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Full Disk Access guidance for TCC-protected zones
# ---------------------------------------------------------------------------
needs_fda=0
case "$WATCH_DIR/" in
  "$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Downloads/"*) needs_fda=1 ;;
esac

cat <<EOF
fb2-to-epub installed.

  Watch folder: $WATCH_DIR
  Agent label:  $LABEL
  Runner:       $RUNNER_DST
  LaunchAgent:  $PLIST
  Log:          $LOG_FILE

Drop .fb2 / .fb2.zip files (or folders of them) into the watch folder.
EOF

if [[ "$needs_fda" -eq 1 ]]; then
  cat <<EOF

NOTE: Your watch folder is inside a macOS-protected location. If conversions do
not start, grant Full Disk Access to the runner:

  System Settings -> Privacy & Security -> Full Disk Access -> "+"
  Add: $RUNNER_DST
  (press Cmd-Shift-G in the picker and paste the path above)

Then toggle it on. The grant is keyed to that file and persists across updates.
EOF
fi
