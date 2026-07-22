#!/bin/bash
# make-fake-calibre-dmg.sh — фикстурный DMG для тестов CalibreInstaller (CAL-3, task 3.13).
#
# ЗАЧЕМ
# -----
# Весь конвейер CAL-3 гоняется БЕЗ сети и БЕЗ 330 МБ настоящего Calibre. Этот скрипт печёт
# мини-`calibre.app` (три стаб-CLI, отвечающие на `--version`, + Info.plist с
# LSMinimumSystemVersion), заворачивает в read-only DMG (`hdiutil create -format UDZO`) и кладёт
# рядом сайдкар `<dmg>.sha512` (128 hex, как настоящий /signatures/… — без имени файла и \n).
#
# GPL-линия (инв.4): это НАШ синтетический стаб, а не бинарь Calibre — в git он не попадает,
# генерится тестом на лету во временную папку.
#
# Стаб НЕ проходит настоящий `codesign --verify` — поэтому в тест-режиме под защёлкой шаг codesign
# заменяется маркером FB2_CALIBRE_SKIP_CODESIGN=1 (см. run-calibre-install-tests.sh). Живой e2e
# (CAL-5) гоняет настоящий подписанный образ.
#
# ВАРИАНТЫ (для негативов 3.14):
#   (по умолчанию)   happy: 3 рабочих CLI, LSMinimumSystemVersion=14.0
#   --broken-cli     ebook-convert выходит с rc=1 (сценарий verify-fail)
#   --no-app         DMG без calibre.app (в образе посторонняя папка)
#   --lsmin X.Y      подставить LSMinimumSystemVersion (напр. 99.0 — «выше ОС»)
#   --ver X.Y.Z      версия в имени файла и в ответе --version (default 9.11.0)
#   --pad-mb N       нескомпримируемый паддинг (random), чтобы DMG был ~N МБ (default 5)
#
# Usage:  make-fake-calibre-dmg.sh [опции] <outdir>
# Пример: make-fake-calibre-dmg.sh /tmp/fake-calibre
#         → /tmp/fake-calibre/calibre-9.11.0.dmg  (+ .sha512)
# Exit:   0 = собрано, 2 = ошибка аргументов, 1 = сбой hdiutil/сборки.

set -euo pipefail

VER="9.11.0"
LSMIN="14.0"
BROKEN=0
NOAPP=0
PAD_MB=5
OUTDIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lsmin)      LSMIN="${2:?--lsmin требует значение}"; shift 2 ;;
    --ver)        VER="${2:?--ver требует значение}"; shift 2 ;;
    --pad-mb)     PAD_MB="${2:?--pad-mb требует значение}"; shift 2 ;;
    --broken-cli) BROKEN=1; shift ;;
    --no-app)     NOAPP=1; shift ;;
    -*)           echo "make-fake-calibre-dmg: неизвестная опция $1" >&2; exit 2 ;;
    *)            OUTDIR="$1"; shift ;;
  esac
done

[[ -n "$OUTDIR" ]] || { echo "make-fake-calibre-dmg: не задан <outdir>" >&2; exit 2; }
for tool in hdiutil shasum dd; do
  command -v "$tool" >/dev/null 2>&1 || { echo "make-fake-calibre-dmg: нет $tool" >&2; exit 1; }
done

mkdir -p "$OUTDIR"
DMG="$OUTDIR/calibre-$VER.dmg"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fb2-fakecal.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
ROOT="$WORK/root"
mkdir -p "$ROOT"

if [[ "$NOAPP" -eq 1 ]]; then
  # Образ без calibre.app — посторонняя папка (сценарий «DMG без calibre.app»).
  mkdir -p "$ROOT/not-calibre"
  printf 'no calibre bundle here\n' > "$ROOT/not-calibre/readme.txt"
else
  APP="$ROOT/calibre.app"
  MACOS="$APP/Contents/MacOS"
  mkdir -p "$MACOS" "$APP/Contents/Resources"

  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>calibre</string>
	<key>CFBundleIdentifier</key>
	<string>net.kovidgoyal.calibre</string>
	<key>CFBundleShortVersionString</key>
	<string>$VER</string>
	<key>LSMinimumSystemVersion</key>
	<string>$LSMIN</string>
</dict>
</plist>
PLIST

  # Три стаб-CLI: отвечают на --version, как настоящие (детект локатора чисто файловый,
  # но verifyStaged реально запускает ebook-convert --version).
  for cli in ebook-convert ebook-meta ebook-polish; do
    cat > "$MACOS/$cli" <<STUB
#!/bin/bash
case "\$1" in
  --version) echo "$cli (calibre $VER)"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
    chmod +x "$MACOS/$cli"
  done

  if [[ "$BROKEN" -eq 1 ]]; then
    # verify-fail: ebook-convert --version падает (rc=1) — staged-проверка обязана снести staging.
    cat > "$MACOS/ebook-convert" <<'STUB'
#!/bin/bash
echo "ebook-convert: simulated failure" >&2
exit 1
STUB
    chmod +x "$MACOS/ebook-convert"
  fi
fi

# Нескомпримируемый паддинг → DMG реально весит ~PAD_MB (нужно для окна отмены и многочанкового
# SHA-стрима; нули бы схлопнулись под UDZO почти в ноль).
if [[ "$PAD_MB" -gt 0 ]]; then
  dd if=/dev/urandom of="$ROOT/pad.bin" bs=1048576 count="$PAD_MB" status=none
fi

rm -f "$DMG"
hdiutil create -volname "calibre" -srcfolder "$ROOT" -format UDZO -ov "$DMG" >/dev/null

# Сайдкар SHA-512: только hex, без имени файла и завершающего \n (как настоящий /signatures/…).
HASH="$(shasum -a 512 "$DMG" | awk '{print $1}')"
printf '%s' "$HASH" > "$DMG.sha512"

SIZE="$(stat -f '%z' "$DMG")"
echo "make-fake-calibre-dmg: $DMG (${SIZE} байт, LSMinimumSystemVersion=$LSMIN, broken=$BROKEN, no-app=$NOAPP)"
echo "  sha512: $HASH"
