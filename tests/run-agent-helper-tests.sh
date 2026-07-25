#!/bin/bash
# run-agent-helper-tests.sh — regression suite for the v1.0.2 "binary runner":
# the frozen Mach-O FDA helper packaging/fb2-to-epub-agent and its integration
# into packaging/installer.sh (arch/plan-binrunner-synthesis.md).
#
# WHAT IS UNDER TEST
# ------------------
#   A. Helper BEHAVIOR (against a STUB watcher, sandboxed copy of the artifact):
#      exit-code passthrough, env inheritance, watcher discovery next to itself
#      (absolute + relative invocation), SIGTERM/SIGINT forwarding to the child
#      (the watcher's traps must run → lock cleanup), missing-watcher error,
#      repeated runs, no stdout noise.
#   B. Artifact FREEZE identity: sha256 of packaging/fb2-to-epub-agent matches
#      PROVENANCE.md (catches an accidental rebuild — new cdhash would silently
#      kill every user's FDA grant), signature verifies, universal 2-arch.
#   C. REAL installer.sh integration (install → idempotent re-run → engine
#      update): helper installed 0755 at App Support/bin, plist
#      ProgramArguments[0] points at it, runner.sh still installed (one-release
#      rollback), byte-identity with the source, TARGETED quarantine strip
#      (installed clean, source keeps its xattr), cmp-preserve (re-runs never
#      churn inode/mtime → the TCC grant axis "bytes+path" is never disturbed),
#      launchctl activation reached for the TEST label only.
#
# ISOLATION (lessons 015/018/019)
# -------------------------------
#   • one mktemp sandbox; throwaway HOME inside it; trap-cleaned;
#   • the FULL mutation latch: FB2_CALIBRE_TEST_MODE=1 + TEST_ROOT=$SANDBOX +
#     HOME inside TEST_ROOT + throwaway FB2_AGENT_LABEL + a fake calibre.app
#     (3 CLI stubs) + FB2_CALIBRE_DISABLE_SYSTEM=1;
#   • installer.sh calls launchctl via PATH → a PATH-shim records the calls and
#     mutates NOTHING in the real launchd (same trick as run-calibre-live-e2e);
#   • bracketed by the shared prod-guard (lib-prod-guard.sh): the user's real
#     plist/state.json/log/covers must stay byte-untouched and the sandbox path
#     must never leak into them.
#
# Usage:  bash tests/run-agent-helper-tests.sh
# Exit:   0 = all green, 1 = a check failed.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT="$REPO_DIR/packaging/fb2-to-epub-agent"
PROVENANCE="$REPO_DIR/packaging/agent-src/PROVENANCE.md"
INSTALLER="$REPO_DIR/packaging/installer.sh"
LABEL="com.arrivarus.fb2toepub.test.agent-helper"

[[ -f "$ARTIFACT" ]]   || { echo "missing $ARTIFACT" >&2; exit 1; }
[[ -f "$PROVENANCE" ]] || { echo "missing $PROVENANCE" >&2; exit 1; }
[[ -f "$INSTALLER" ]]  || { echo "missing $INSTALLER" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL - %s\n' "$1"; }

# --- prod-guard (lesson 018): snapshot boevoy artifacts BEFORE the suite -----
# shellcheck disable=SC1091
source "$REPO_DIR/tests/lib-prod-guard.sh"
prod_guard_begin

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/fb2-agent-helper.XXXXXX")"
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# ===========================================================================
# A. Helper behavior — sandboxed copy + STUB watcher
# ===========================================================================
echo "# --- A: поведение хелпера (стаб-watcher) ---"

ABIN="$SANDBOX/abin"
mkdir -p "$ABIN"
cp "$ARTIFACT" "$ABIN/fb2-to-epub-agent"
chmod 0755 "$ABIN/fb2-to-epub-agent"

# The stub watcher: writes a marker (proves spawn+wait ran it), records env,
# traps TERM/INT (proves the helper FORWARDS signals to the child), honors
# EXIT_CODE, optionally sleeps (so a signal can arrive mid-run). Writes NOTHING
# to stdout — A9 asserts the helper chain is stdout-silent on success.
cat > "$ABIN/fb2-to-epub-watcher.sh" <<'EOF'
#!/bin/bash
printf 'ran WATCH_DIR=%s\n' "${WATCH_DIR:-}" >> "$STUB_MARKER"
trap 'echo got-TERM >> "$STUB_MARKER"; exit 143' TERM
trap 'echo got-INT  >> "$STUB_MARKER"; exit 130' INT
if [[ "${STUB_MODE:-}" == "sleep" ]]; then sleep 25 & wait $!; fi
exit "${STUB_EXIT:-0}"
EOF
chmod 0755 "$ABIN/fb2-to-epub-watcher.sh"

# A1+A2: exit-code passthrough + env inheritance (absolute invocation).
m="$SANDBOX/a1.marker"; : > "$m"
rc=0
STUB_MARKER="$m" STUB_EXIT=7 WATCH_DIR="$SANDBOX/wd" "$ABIN/fb2-to-epub-agent" || rc=$?
[[ "$rc" == "7" ]] && ok "A1: exit-код ребёнка пробрасывается (7)" || bad "A1: exit-код (got $rc want 7)"
grep -q "ran WATCH_DIR=$SANDBOX/wd" "$m" && ok "A2: env (WATCH_DIR) наследуется ребёнку" || bad "A2: env не доехал ($(cat "$m"))"

# A3: relative-path invocation still finds the watcher NEXT TO THE BINARY.
m="$SANDBOX/a3.marker"; : > "$m"
rc=0
( cd "$SANDBOX" && STUB_MARKER="$m" STUB_EXIT=0 ./abin/fb2-to-epub-agent ) || rc=$?
[[ "$rc" == "0" ]] && grep -q "ran " "$m" \
  && ok "A3: относительный запуск — watcher найден рядом с бинарём" \
  || bad "A3: относительный запуск (rc=$rc marker=$(cat "$m" 2>/dev/null))"

# A4: absolute invocation from a foreign cwd.
m="$SANDBOX/a4.marker"; : > "$m"
rc=0
( cd / && STUB_MARKER="$m" "$ABIN/fb2-to-epub-agent" ) || rc=$?
[[ "$rc" == "0" ]] && grep -q "ran " "$m" \
  && ok "A4: абсолютный запуск из чужого cwd" \
  || bad "A4: абсолютный запуск (rc=$rc)"

# A5: SIGTERM to the HELPER reaches the CHILD (trap marker) and the child's
# post-trap exit code (143) is mirrored by the helper.
m="$SANDBOX/a5.marker"; : > "$m"
STUB_MARKER="$m" STUB_MODE=sleep "$ABIN/fb2-to-epub-agent" &
hp=$!
sleep 1
kill -TERM "$hp" 2>/dev/null || true
rc=0; wait "$hp" || rc=$?
grep -q "got-TERM" "$m" && ok "A5: SIGTERM хелперу доезжает до trap ребёнка" || bad "A5: TERM не дошёл до ребёнка ($(cat "$m"))"
[[ "$rc" == "143" ]] && ok "A5b: exit 143 ребёнка отражён хелпером" || bad "A5b: rc после TERM (got $rc want 143)"

# A6: SIGINT forwarding, same shape.
m="$SANDBOX/a6.marker"; : > "$m"
STUB_MARKER="$m" STUB_MODE=sleep "$ABIN/fb2-to-epub-agent" &
hp=$!
sleep 1
kill -INT "$hp" 2>/dev/null || true
rc=0; wait "$hp" || rc=$?
grep -q "got-INT" "$m" && ok "A6: SIGINT хелперу доезжает до trap ребёнка" || bad "A6: INT не дошёл ($(cat "$m"))"
[[ "$rc" == "130" ]] && ok "A6b: exit 130 ребёнка отражён хелпером" || bad "A6b: rc после INT (got $rc want 130)"

# A7: missing watcher → stderr message + rc 1 (parity with the old runner.sh).
LONELY="$SANDBOX/lonely"; mkdir -p "$LONELY"
cp "$ARTIFACT" "$LONELY/fb2-to-epub-agent"; chmod 0755 "$LONELY/fb2-to-epub-agent"
rc=0; err="$("$LONELY/fb2-to-epub-agent" 2>&1 >/dev/null)" || rc=$?
[[ "$rc" == "1" ]] && ok "A7: нет watcher рядом → rc 1" || bad "A7: rc (got $rc want 1)"
[[ "$err" == *"watcher not found"* ]] && ok "A7b: сообщение об отсутствии watcher в stderr" || bad "A7b: stderr ('$err')"

# A8: repeated run — second invocation works identically (no one-shot state).
m="$SANDBOX/a8.marker"; : > "$m"
rc=0; STUB_MARKER="$m" "$ABIN/fb2-to-epub-agent" || rc=$?
rc2=0; STUB_MARKER="$m" "$ABIN/fb2-to-epub-agent" || rc2=$?
[[ "$rc" == "0" && "$rc2" == "0" && "$(grep -c '^ran ' "$m")" == "2" ]] \
  && ok "A8: повторный запуск ок (2 прогона — 2 маркера)" \
  || bad "A8: повторный запуск (rc=$rc/$rc2 markers=$(grep -c '^ran ' "$m"))"

# A9: stdout is SILENT on success (the agent's log must not get helper noise).
m="$SANDBOX/a9.marker"; : > "$m"
out="$(STUB_MARKER="$m" "$ABIN/fb2-to-epub-agent" 2>/dev/null)"
[[ -z "$out" ]] && ok "A9: stdout хелпера пуст при успехе" || bad "A9: stdout не пуст ('$out')"

# ===========================================================================
# B. Frozen-artifact identity (the anti-rebuild guard)
# ===========================================================================
echo "# --- B: замороженный артефакт (identity) ---"

prov_sha="$(grep -oE '`[0-9a-f]{64}`' "$PROVENANCE" | head -1 | tr -d '\`')"
real_sha="$(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)"
if [[ -n "$prov_sha" && "$prov_sha" == "$real_sha" ]]; then
  ok "B1: sha256 артефакта совпадает с PROVENANCE.md (заморозка не нарушена)"
else
  bad "B1: артефакт ПЕРЕСОБРАН?! sha=$real_sha, PROVENANCE=$prov_sha — новый cdhash молча убьёт гранты (см. PROVENANCE.md)"
fi

codesign --verify --strict "$ARTIFACT" >/dev/null 2>&1 \
  && ok "B2: подпись артефакта валидна (codesign --verify --strict)" \
  || bad "B2: подпись артефакта не проходит верификацию"

archs="$(lipo -archs "$ARTIFACT" 2>/dev/null || true)"
[[ "$archs" == *x86_64* && "$archs" == *arm64* ]] \
  && ok "B3: universal (x86_64 + arm64)" \
  || bad "B3: не universal (archs='$archs')"

# ===========================================================================
# C. Real installer.sh — install → idempotent re-run → engine update
# ===========================================================================
echo "# --- C: интеграция installer.sh (защёлка + launchctl-шайба) ---"

CHOME="$SANDBOX/home"
WATCH="$CHOME/watch"
LSHIM="$SANDBOX/lshim"
LCTL_LOG="$SANDBOX/launchctl-calls.log"
SRCSTAGE="$SANDBOX/src"
mkdir -p "$CHOME" "$WATCH" "$LSHIM" "$SRCSTAGE"
: > "$LCTL_LOG"

# launchctl PATH-shim: record calls, mutate nothing (print → 1 keeps the
# legacy-migration branch quiet; everything else "succeeds").
cat > "$LSHIM/launchctl" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$LCTL_LOG"
case "\${1:-}" in
  print|print-disabled) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$LSHIM/launchctl"

# Fake calibre.app inside TEST_ROOT (the latch inserts it as candidate #1;
# FB2_CALIBRE_DISABLE_SYSTEM removes the real-system candidates).
FAKEC="$SANDBOX/calibre.app/Contents/MacOS"
mkdir -p "$FAKEC"
for cli in ebook-convert ebook-meta ebook-polish; do
  printf '#!/bin/bash\nexit 0\n' > "$FAKEC/$cli"
  chmod +x "$FAKEC/$cli"
done

# Stage ALL engine sources (so the "engine update" scenario can mutate the
# staged watcher without touching the repo). The agent copy gets QUARANTINED —
# C5 then proves the TARGETED strip: installed clean, source keeps the xattr.
for f in packaging/fb2-to-epub-agent packaging/fb2-to-epub-runner.sh \
         bin/fb2-to-epub-watcher.sh bin/fb2-to-epub-cover-finder.py \
         bin/fb2-to-epub-fb3.py bin/fb2-to-epub-fb3-genre.json; do
  cp "$REPO_DIR/$f" "$SRCSTAGE/$(basename "$f")"
done
xattr -w com.apple.quarantine "0083;00000000;fb2-test;" "$SRCSTAGE/fb2-to-epub-agent"

run_installer() {
  PATH="$LSHIM:$PATH" \
  HOME="$CHOME" \
  FB2_CALIBRE_TEST_MODE=1 \
  FB2_CALIBRE_TEST_ROOT="$SANDBOX" \
  FB2_CALIBRE_DISABLE_SYSTEM=1 \
  FB2_AGENT_LABEL="$LABEL" \
  FB2_SRC_DIR="$SRCSTAGE" \
  bash "$INSTALLER" "$WATCH" >> "$SANDBOX/installer.log" 2>&1
}

BIN_DIR="$CHOME/Library/Application Support/fb2-to-epub/bin"
PLIST="$CHOME/Library/LaunchAgents/$LABEL.plist"
HELPER="$BIN_DIR/fb2-to-epub-agent"

# --- C-install #1 -----------------------------------------------------------
rc=0; run_installer || rc=$?
[[ "$rc" == "0" ]] && ok "C0: installer.sh отработал (rc 0)" || { bad "C0: installer rc=$rc"; tail -20 "$SANDBOX/installer.log" | sed 's/^/         /'; }

[[ -f "$HELPER" && -x "$HELPER" ]] \
  && ok "C1: helper установлен в App Support/bin и исполняем" \
  || bad "C1: helper не установлен ($HELPER)"

pa0="$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$PLIST" 2>/dev/null || true)"
[[ "$pa0" == "$HELPER" ]] \
  && ok "C2: plist ProgramArguments[0] = helper (не .sh)" \
  || bad "C2: ProgramArguments[0]='$pa0' (want $HELPER)"

[[ -f "$BIN_DIR/fb2-to-epub-runner.sh" ]] \
  && ok "C3: runner.sh всё ещё устанавливается (rollback на один релиз)" \
  || bad "C3: runner.sh пропал из установки"

cmp -s "$SRCSTAGE/fb2-to-epub-agent" "$HELPER" \
  && ok "C4: установленный helper байт-в-байт равен источнику" \
  || bad "C4: helper отличается от источника"

if xattr -p com.apple.quarantine "$HELPER" >/dev/null 2>&1; then
  bad "C5: quarantine НЕ снят с установленного helper"
else
  ok "C5: quarantine снят с установленного helper (после sha-сверки)"
fi
if xattr -p com.apple.quarantine "$SRCSTAGE/fb2-to-epub-agent" >/dev/null 2>&1; then
  ok "C5b: источник сохранил свой quarantine (строго точечный strip, не -cr)"
else
  bad "C5b: quarantine пропал и с ИСТОЧНИКА — strip не точечный"
fi

# --- C-re-run #2: cmp-preserve (идемпотентность не трогает грант-ось) --------
sig_before="$(stat -f '%i %m' "$HELPER")"
sleep 1   # чтобы возможная перезапись гарантированно сменила mtime
rc=0; run_installer || rc=$?
sig_after="$(stat -f '%i %m' "$HELPER")"
[[ "$rc" == "0" ]] && ok "C6: повторный installer rc 0" || bad "C6: повторный installer rc=$rc"
[[ "$sig_before" == "$sig_after" ]] \
  && ok "C6b: идентичный helper НЕ перезаписан (inode+mtime неизменны — cmp-preserve)" \
  || bad "C6b: helper перезаписан при идентичном источнике ($sig_before -> $sig_after)"

# --- C-update #3: «апдейт движка» (watcher изменился) ------------------------
printf '\n# engine-update marker\n' >> "$SRCSTAGE/fb2-to-epub-watcher.sh"
sleep 1
rc=0; run_installer || rc=$?
sig_upd="$(stat -f '%i %m' "$HELPER")"
[[ "$rc" == "0" ]] && ok "C7: installer после «апдейта движка» rc 0" || bad "C7: rc=$rc"
[[ "$sig_after" == "$sig_upd" ]] \
  && ok "C7b: при апдейте движка helper по-прежнему НЕ тронут (грант живёт)" \
  || bad "C7b: апдейт движка переписал helper ($sig_after -> $sig_upd)"
grep -q "engine-update marker" "$BIN_DIR/fb2-to-epub-watcher.sh" \
  && ok "C7c: watcher при этом обновился" \
  || bad "C7c: watcher не обновился"
pa0="$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$PLIST" 2>/dev/null || true)"
[[ "$pa0" == "$HELPER" ]] \
  && ok "C7d: plist после апдейта всё ещё указывает на helper" \
  || bad "C7d: ProgramArguments[0]='$pa0'"

# --- C8: активация дошла до launchctl, и ТОЛЬКО для тест-метки ---------------
grep -q "bootstrap gui/$(id -u) $PLIST" "$LCTL_LOG" \
  && ok "C8: launchctl bootstrap тест-plist зафиксирован шайбой" \
  || bad "C8: bootstrap тест-метки не найден в журнале шайбы"
if grep -v "$LABEL" "$LCTL_LOG" | grep -q "com.arrivarus.fb2toepub"; then
  bad "C8b: в журнале launchctl мелькнула НЕ тест-метка (утечка на боевой label!)"
else
  ok "C8b: все launchctl-вызовы — только про тест-метку"
fi

# --- C9: окно сбоя installer (файлы уложены, plist остался на runner.sh) →
#         повторный installer самолечит PA0 обратно на helper --------------------
# Симуляция v1.0.2-хвоста: helper уложен и байт-в-байт верен (нет engine-diff →
# Swift-self-heal увидел бы .upToDate по байтам), НО ProgramArguments[0] указывает
# на мёртвый runner.sh — потому что installer упал/прервался между укладкой файлов
# и записью plist, ЛИБО helper был предзаложен (артефакт) и installer не запускался.
# Свифтовый self-heal (refreshEngineIfBundledChanged) в этом состоянии видит PA0≠helper
# и ГОНИТ installer; здесь доказываем, что installer, который он зовёт, идемпотентно
# чинит PA0 обратно на helper — НЕ трогая байты/inode helper'а (грант живёт).
# Свифт-часть решения покрыта юнитом E6 (tests/ClearHistoryTests/UpdateCheckerTests.swift).
RUNNER_DST_C9="$BIN_DIR/fb2-to-epub-runner.sh"
/usr/bin/plutil -replace ProgramArguments.0 -string "$RUNNER_DST_C9" "$PLIST"
pa0_stale="$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$PLIST" 2>/dev/null || true)"
[[ "$pa0_stale" == "$RUNNER_DST_C9" ]] \
  && ok "C9: предусловие — plist засеян на мёртвый runner.sh (окно сбоя installer)" \
  || bad "C9: не удалось засеять stale PA0 ('$pa0_stale')"
sig_helper_c9_before="$(stat -f '%i %m' "$HELPER")"
sleep 1
rc=0; run_installer || rc=$?
[[ "$rc" == "0" ]] && ok "C9b: самолечащий installer отработал (rc 0)" || { bad "C9b: installer rc=$rc"; tail -20 "$SANDBOX/installer.log" | sed 's/^/         /'; }
pa0_healed="$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$PLIST" 2>/dev/null || true)"
[[ "$pa0_healed" == "$HELPER" ]] \
  && ok "C9c: PA0 самолечён обратно на helper (окно сбоя закрыто)" \
  || bad "C9c: PA0 не восстановлен ('$pa0_healed' want $HELPER)"
sig_helper_c9_after="$(stat -f '%i %m' "$HELPER")"
[[ "$sig_helper_c9_before" == "$sig_helper_c9_after" ]] \
  && ok "C9d: helper при самолечении НЕ перезаписан (inode+mtime неизменны — грант жив)" \
  || bad "C9d: helper тронут самолечением ($sig_helper_c9_before -> $sig_helper_c9_after)"

# ===========================================================================
# D. Name parity — имя helper'а согласовано по всем shipped-поверхностям
# ===========================================================================
# Литерал `fb2-to-epub-agent` продублирован в 5 shipped-поверхностях (плюс
# документированное зеркало в tests/ClearHistoryTests/UpdateCheckerTests.swift,
# чей дрейф ловят сами Swift-тесты). Переименование, задевшее не все сразу,
# ломается МОЛЧА: FolderAccessCard покажет пользователю НЕ ту строку FDA,
# fallback EngineClient укажет на несуществующий бинарь, engineScriptNames
# перестанет триггерить миграцию на binary runner, а PA0-self-heal (fix #1,
# installedHelperPath) начнёт сравнивать ProgramArguments[0] с НЕ тем путём и
# либо зациклит installer, либо перестанет лечить стухший plist. Извлекаем литерал
# из каждой поверхности и требуем полного совпадения. Коммент у step3accent в
# app/FolderAccessCard.swift ссылается именно на ЭТОТ guard.
echo "# --- D: имя helper'а (name parity по 5 поверхностям) ---"

# installer.sh: AGENT_BIN_DST="$BIN_DIR/<имя>" → basename
n_installer="$(grep -E '^AGENT_BIN_DST=' "$INSTALLER" | head -1 \
               | sed -E 's|.*/([^/"]+)"[[:space:]]*$|\1|')" || n_installer=""
# FolderAccessCard.swift: константа шага 3 (имя строки FDA, которое видит пользователь)
n_card="$(grep -E 'static let step3accent' "$REPO_DIR/app/FolderAccessCard.swift" | head -1 \
          | sed -E 's/.*"([^"]+)".*/\1/')" || n_card=""
# EngineClient.swift: plist-less fallback в runnerPath() → basename
n_fallback="$(grep -E 'let fallback' "$REPO_DIR/app/EngineClient.swift" | head -1 \
              | sed -E 's|.*/([^/"]+)".*|\1|')" || n_fallback=""
# EngineClient+Status.swift: безрасширенный элемент engineScriptNames
# (Mach-O helper среди .sh/.py payload'ов)
n_list="$(awk '/engineScriptNames = \[/{f=1; next} f && /\]/{exit} f' \
              "$REPO_DIR/app/EngineClient+Status.swift" \
          | grep -oE '"[^"]+"' | tr -d '"' | grep -vE '\.[a-z0-9]+$' | head -1)" || n_list=""
# EngineClient+Status.swift: installedHelperPath (fix #1) — ожидаемый PA0 для self-heal.
# basename из первого строкового литерала "\(installedBinDir)/<имя>" после её объявления.
n_helper="$(awk '/var installedHelperPath/{f=1} f && /installedBinDir\)\//{print; exit}' \
                "$REPO_DIR/app/EngineClient+Status.swift" \
            | sed -E 's|.*/([^/"]+)".*|\1|')" || n_helper=""

if [[ -n "$n_installer" && -n "$n_card" && -n "$n_fallback" && -n "$n_list" && -n "$n_helper" ]]; then
  ok "D1: имя извлечено со всех 5 поверхностей (installer/card/fallback/list/helperPath)"
else
  bad "D1: не извлеклось имя (installer='$n_installer' card='$n_card' fallback='$n_fallback' list='$n_list' helperPath='$n_helper') — якоря greps сгнили, чини сам guard"
fi
if [[ -n "$n_installer" && "$n_card" == "$n_installer" \
      && "$n_fallback" == "$n_installer" && "$n_list" == "$n_installer" \
      && "$n_helper" == "$n_installer" ]]; then
  ok "D2: все 5 поверхностей совпадают ('$n_installer')"
else
  bad "D2: имя helper'а РАЗЪЕХАЛОСЬ: installer.sh='$n_installer' FolderAccessCard='$n_card' EngineClient.fallback='$n_fallback' engineScriptNames='$n_list' installedHelperPath='$n_helper' — переименование обязано менять все поверхности разом (+ зеркало в UpdateCheckerTests)"
fi

# ===========================================================================
# prod-guard + summary
# ===========================================================================
echo "# --- страж боевых артефактов (урок 018) ---"
prod_guard_end "$SANDBOX" || true
PASS=$((PASS + PG_PASS))
FAIL=$((FAIL + PG_FAIL))

echo ""
echo "1..$((PASS+FAIL))"
echo "# passed: $PASS"
echo "# failed: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
