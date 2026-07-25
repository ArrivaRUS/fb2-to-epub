# PROVENANCE — packaging/fb2-to-epub-agent (FROZEN artifact)

`packaging/fb2-to-epub-agent` is the pre-built, ad-hoc-signed universal Mach-O
helper that the LaunchAgent's `ProgramArguments[0]` points at. It is the file
users grant **Full Disk Access** to. The grant is pinned to the ad-hoc
designated requirement — i.e. to the **cdhash of these exact bytes**.

## ⚠️ DO NOT REBUILD

Rebuilding (even from identical source, even with the same flags) may produce a
different cdhash → **every existing user's FDA grant dies silently** and they
each get an unexplained trip to System Settings. That is exactly the failure
mode this helper exists to eliminate.

- `build/build-app.sh` only **copies** this file into the .app and **verifies
  its SHA-256** after codesign (release-blocking byte guard).
- `packaging/installer.sh` installs it with a byte-compare preserve: an
  identical installed copy is never rewritten.
- A rebuild is a rare, deliberate event (helper bug / security fix): run
  `FB2_AGENT_REBUILD_I_UNDERSTAND=1 packaging/agent-src/build-once.sh`, update
  this file, and warn in the release notes that access must be re-granted.

## Известные микро-окна (НЕ повод пересобирать; учесть при гипотетической будущей пересборке по иной причине)

Ревью v1.0.2 (2026-07-23) нашло в `fb2-to-epub-agent.c` два теоретических
окна класса tini/dumb-init (вероятность срабатывания ≈0 в нашем launchd-сценарии
с одним долгоживущим ребёнком). Решение ревью: **замораживаем как есть** —
цена пересборки (смена cdhash → молчаливая смерть всех FDA-грантов) на порядки
выше выгоды. Если пересборка когда-нибудь случится ПО ДРУГОЙ причине, заодно
учесть:

1. **Окно pid-reuse после waitpid.** После `waitpid` вернул `w == pid`
   (ребёнок пожат), `g_child` всё ещё хранит его pid до самого выхода
   процесса. Сигнал, прилетевший в этот зазор, уйдёт `kill()`-ом в уже
   мёртвый (и теоретически переиспользованный ОС) pid. При пересборке
   заменить выход из цикла на: `if (w == pid) { g_child = 0; break; }`.

2. **Коллапс пре-spawn сигналов.** `g_pending_sig` — один слот: если ДО
   завершения `posix_spawn` прилетят два разных сигнала (например, INT, затем
   TERM), ребёнку после спавна доставится только последний. Тот же компромисс,
   что у tini/dumb-init; для launchd-агента (шлёт один SIGTERM) не воспроизводим.

## Artifact identity (built 2026-07-23, frozen)

| Field | Value |
|---|---|
| File | `packaging/fb2-to-epub-agent` |
| SHA-256 | `926fc0393ce5e1176a081a22c6d1c0314959c6aee7cb8a3bdc705375589ef649` |
| Size | 117 872 bytes |
| Format | Mach-O universal (x86_64 + arm64) |
| CDHash (arm64 slice) | `6b6429662661132442b94ee5a5551b9fbb8cf62f` |
| CDHash (x86_64 slice) | `030c3d240f48478197039ef80cec67db91dedac4` |
| Designated requirement | `cdhash H"6b6429662661132442b94ee5a5551b9fbb8cf62f" or cdhash H"030c3d240f48478197039ef80cec67db91dedac4"` |
| Signature | ad-hoc (`codesign -s -`) |
| Min macOS | 11.0 |

## Build environment (for audit — reproducing is NOT the release path)

| Field | Value |
|---|---|
| Source | `packaging/agent-src/fb2-to-epub-agent.c` |
| Build script | `packaging/agent-src/build-once.sh` (one-shot) |
| Command | `clang -Os -Wall -Wextra -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -o fb2-to-epub-agent fb2-to-epub-agent.c` then `strip`, `codesign --force -s -` |
| Apple clang | 21.0.0 (clang-2100.1.1.101), target arm64-apple-darwin25.5.0 |
| Xcode | 26.6 (Build 17F113) |
| macOS | 26.5.2 (25F84) |
| Date | 2026-07-23 |

A from-source rebuild with a different Xcode/SDK is useful only to audit that
the source matches the behavior; the release file is always the committed
artifact above, byte-for-byte.
