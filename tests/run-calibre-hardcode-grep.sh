#!/bin/bash
# run-calibre-hardcode-grep.sh — запрет НОВЫХ хардкодов пути к Calibre (CAL-1).
#
# ЗАЧЕМ
# -----
# До CAL-1 знание «движок лежит в /Applications/calibre.app» было размазано по
# пяти файлам, и одно из этих мест (cover-finder.py) молча игнорировало env
# агента — при установке движка в нашу папку вшивание обложек ломалось бы.
# Теперь путь знает контракт детекта (инвариант 5). Этот тест не даёт хардкоду
# расползтись обратно.
#
# ПРАВИЛО
# -------
# Литерал `/Applications/calibre.app` допустим ТОЛЬКО в разрешённых местах
# (реестр ниже) и не чаще, чем сейчас. Любое вхождение в любом другом файле
# внутри app/ bin/ packaging/ = FAIL. Потолки не дают дописать новые вхождения
# даже в разрешённые файлы; уменьшать их не запрещено (снёс хардкод — молодец,
# просто опусти потолок).
#
# Usage:  tests/run-calibre-hardcode-grep.sh
# Exit:   0 = чисто, 1 = найден новый хардкод.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

NEEDLE="/Applications/calibre\.app"
SCOPE=(app bin packaging)

# --- Реестр разрешённых мест: "<путь>|<потолок>|<почему можно>" -------------
# ВАЖНО: подстрока ловится и внутри "$HOME/Applications/calibre.app" — поэтому
# у файлов с полной цепочкой кандидатов потолок больше единицы.
ALLOW=(
  "app/CalibreLocator.swift|7|сам контракт детекта — единственный источник правды"
  "packaging/installer.sh|2|bash-близнец контракта (§1 детект)"
  "bin/fb2-to-epub-watcher.sh|3|фолбэк-цепочка для ручного запуска (под launchd пути из plist)"
  "bin/fb2-to-epub-cover-finder.py|1|последний фолбэк, чтобы ручной запуск вёл себя как раньше"
  "packaging/applet.applescript|1|легаси-апплет, в сборку не входит (build-app.sh его не кладёт)"
)

allow_limit() {   # печатает потолок для файла или "-" если файла нет в реестре
  local f="$1" row
  for row in "${ALLOW[@]}"; do
    [[ "${row%%|*}" == "$f" ]] || continue
    row="${row#*|}"
    printf '%s' "${row%%|*}"
    return 0
  done
  printf '%s' "-"
}

PASS=0
FAIL=0

echo "# --- CAL-1: хардкоды /Applications/calibre.app ---"

FILES="$(grep -rlE "$NEEDLE" "${SCOPE[@]}" 2>/dev/null | grep -v '__pycache__' | sort || true)"

if [[ -n "$FILES" ]]; then
  while IFS= read -r f; do
    n="$(grep -oE "$NEEDLE" "$f" | wc -l | tr -d ' ')"
    limit="$(allow_limit "$f")"
    if [[ "$limit" == "-" ]]; then
      FAIL=$((FAIL + 1))
      echo "  FAIL - $f: $n хардкод(ов) в НЕразрешённом файле"
      echo "         путь к движку берут CalibreLocator (Swift) / контракт installer.sh (bash);"
      echo "         если место действительно исключительное — впиши его в реестр ALLOW с обоснованием."
      grep -nE "$NEEDLE" "$f" | sed 's/^/           /'
    elif [[ "$n" -gt "$limit" ]]; then
      FAIL=$((FAIL + 1))
      echo "  FAIL - $f: $n вхождений при потолке $limit — добавлен новый хардкод"
      grep -nE "$NEEDLE" "$f" | sed 's/^/           /'
    else
      PASS=$((PASS + 1))
      echo "  ok   - $f: $n ≤ $limit (разрешено)"
    fi
  done <<< "$FILES"
fi

# --- Точечные регрессии: места, откуда хардкод УБРАН в CAL-1 ---------------
echo "# --- CAL-1: места, где хардкода больше быть не должно ---"
for f in app/EngineClient.swift app/EngineClient+Status.swift app/main.swift; do
  if grep -qE "$NEEDLE" "$f" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    echo "  FAIL - $f снова содержит хардкод (должен ходить через CalibreLocator)"
  else
    PASS=$((PASS + 1))
    echo "  ok   - $f чист"
  fi
done

# --- D40-lifecycle: ключи авто/мгновенной терминации в build-app.sh -----------
# NSSupportsSuddenTermination=true заставляет AppKit завершать процесс через
# exit() на terminate:/quit-AppleEvent, НЕ вызывая applicationShouldTerminate →
# весь D40-lifecycle (диалог «Установка движка ещё идёт», terminateLater,
# зачистка частичной загрузки) отрезан. NSSupportsAutomaticTermination — тот же
# класс риска (система вправе убить приложение без видимых окон, а D40 обещает
# «закрыл окно — установка живёт в Dock»). Оба ключа убраны; см. диагноз
# 2026-07-22. Этот страж не даёт им вернуться в шаблон Info.plist.
echo "# --- D40: build-app.sh не объявляет NSSupports*Termination ---"
for key in NSSupportsSuddenTermination NSSupportsAutomaticTermination; do
  if grep -qE "$key" build/build-app.sh 2>/dev/null; then
    FAIL=$((FAIL + 1))
    echo "  FAIL - build/build-app.sh содержит $key — ключ отрезает D40-lifecycle, см. диагноз 2026-07-22"
    grep -nE "$key" build/build-app.sh | sed 's/^/           /'
  else
    PASS=$((PASS + 1))
    echo "  ok   - build/build-app.sh без $key"
  fi
done

# --- Реестр не должен протухать -------------------------------------------
for row in "${ALLOW[@]}"; do
  f="${row%%|*}"
  if [[ ! -f "$f" ]]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL - реестр ALLOW ссылается на несуществующий $f"
  fi
done

echo ""
echo "1..$((PASS + FAIL))"
echo "# passed: $PASS"
echo "# failed: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
