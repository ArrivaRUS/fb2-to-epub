// main.swift — regression tests for the "Очистить" (clear recent history) fix.
//
// WHAT IS UNDER TEST (app/EngineClient+Status.swift)
// --------------------------------------------------
// The bug: pressing "Очистить" must hide the recent-conversions list, but the
// watcher OWNS state.json (D13) — the app must NOT rewrite it (a race would
// corrupt it). The fix instead writes an app-owned marker
//   {home}/Library/Application Support/fb2-to-epub/state/recent-cleared-at
// (ISO-8601 UTC, atomically) and `loadState()` FILTERS recent[] on read:
//   keep entries strictly NEWER than the marker (ts > cutoff);
//   unparseable ts -> keep (fail-open);
//   if last_conversion.ts <= cutoff -> re-point at recent.first (or nil).
// state.json itself is never written by the app.
//
// ISOLATION (critical)
// --------------------
// Every test runs against a throwaway HOME (`mktemp -d`, created in setUp) and a
// throwaway LaunchAgent label. EngineClient derives ALL paths from `home`, so
// nothing here can touch the real agent, the real ~/Library/Application Support,
// ~/Desktop/fb2-to-epub, or any books. The "Очистить" path under test
// (clearHistory + loadState) shells out to NOTHING — it is pure file IO inside
// the temp HOME. No launchd, no installer, no network -> fully deterministic.
//
// This file is compiled (via tests/run-clear-history-tests.sh) together with the
// real production sources EngineClient.swift / EngineClient+Status.swift /
// StateModel.swift, plus Stubs.swift (inert CoverQueueStore so the engine
// compiles without SwiftUI). Production code is NOT modified.

import Foundation

// MARK: - Tiny assertion harness (deterministic, no XCTest dependency)

// We mirror the project's existing build model (xcrun swiftc, whole-module, no
// SwiftPM/XCTest target — see build/build-app.sh). So tests use a minimal
// TAP-style runner instead of inventing an XCTest target.

final class T {
    static var passed = 0
    static var failed = 0
    static var current = "<none>"

    static func ok(_ cond: @autoclosure () -> Bool, _ msg: String) {
        if cond() {
            passed += 1
            print("  ok   - \(msg)")
        } else {
            failed += 1
            print("  FAIL - \(msg)   [in: \(current)]")
        }
    }

    static func eq<V: Equatable>(_ a: V, _ b: V, _ msg: String) {
        ok(a == b, "\(msg)  (got: \(a), want: \(b))")
    }

    static func run(_ name: String, _ body: () throws -> Void) {
        current = name
        print("# \(name)")
        do {
            try body()
        } catch {
            failed += 1
            print("  FAIL - threw: \(error)   [in: \(name)]")
        }
    }
}

// MARK: - Fixtures / helpers

enum Fixture {
    /// A throwaway label that can NEVER collide with the production agent
    /// (com.arrivarus.fb2toepub.agent). Unique per call.
    static func throwawayLabel() -> String {
        "com.example.fb2toepub.test.\(UUID().uuidString.prefix(8))"
    }

    /// installer.sh from the checkout. The constructor wants a path; the
    /// "Очистить" path under test NEVER invokes the installer, so this is only
    /// here to honour the EngineClient(installerPath:) contract realistically.
    static let installerPath: String = {
        let here = URL(fileURLWithPath: #filePath)            // .../tests/ClearHistoryTests/main.swift
            .deletingLastPathComponent()                      // .../tests/ClearHistoryTests
            .deletingLastPathComponent()                      // .../tests
            .deletingLastPathComponent()                      // repo root
        return here.appendingPathComponent("packaging/installer.sh").path
    }()

    /// A fresh isolated HOME for one test. Caller must remove it (tearDown).
    static func makeHome() -> String {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString)
            .appendingPathComponent("fb2-clearhist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }

    static func removeHome(_ home: String) {
        try? FileManager.default.removeItem(atPath: home)
    }

    /// `{home}/Library/Application Support/fb2-to-epub/state`
    static func stateDir(_ home: String) -> String {
        "\(home)/Library/Application Support/fb2-to-epub/state"
    }
    static func stateJSONPath(_ home: String) -> String {
        "\(stateDir(home))/state.json"
    }
    static func clearMarkerPath(_ home: String) -> String {
        "\(stateDir(home))/recent-cleared-at"
    }
    /// `{home}/Library/Application Support/fb2-to-epub/state/stats-baseline`
    static func statsBaselinePath(_ home: String) -> String {
        "\(stateDir(home))/stats-baseline"
    }
    /// `{home}/Library/Application Support/fb2-to-epub/state/today-baseline`
    static func todayBaselinePath(_ home: String) -> String {
        "\(stateDir(home))/today-baseline"
    }

    /// Local-day string "yyyy-MM-dd" mirroring EngineClient.localDayString /
    /// the watcher's `datetime.now().strftime("%Y-%m-%d")`. Used to stamp
    /// fixtures' `_today_date` so day-aware logic is exercised deterministically.
    static func localDay(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }
    static func today() -> String { localDay() }
    /// A day comfortably AFTER today, to simulate the watcher rolling the day over.
    static func tomorrow() -> String { localDay(Date().addingTimeInterval(86_400)) }

    /// Build a client bound to an isolated HOME + throwaway label.
    static func client(home: String) -> EngineClient {
        EngineClient(label: throwawayLabel(),
                     home: home,
                     installerPath: installerPath)
    }

    // MARK: - stats-baseline helpers (group A)

    /// Read + parse the app-owned `stats-baseline` marker the way the production
    /// `statsBaseline()` does (private there, so we re-read the file directly).
    /// Returns the stored `converted_total`, or nil when absent / malformed.
    static func readBaseline(_ home: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statsBaselinePath(home))),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = obj["converted_total"] as? Int else { return nil }
        return base
    }

    /// Read + parse the app-owned `today-baseline` marker the way the production
    /// `todayBaseline()` does. Returns (date, today), or nil when absent/malformed.
    static func readTodayBaseline(_ home: String) -> (date: String, today: Int)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: todayBaselinePath(home))),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let date = obj["date"] as? String,
              let today = obj["today"] as? Int else { return nil }
        return (date, today)
    }

    /// Convenience: write a state.json carrying only a `converted_total` (plus
    /// optional today/failed), with an empty recent list and no last_conversion.
    /// Mirrors what the watcher would persist after N lifetime conversions.
    /// `todayDate` injects the watcher's private `_today_date` day stamp so the
    /// day-aware "за сегодня" baseline can be exercised; nil omits it.
    @discardableResult
    static func writeTotals(home: String,
                            convertedTotal: Int,
                            today: Int = 0,
                            failedToday: Int = 0,
                            todayDate: String? = nil) -> Bool {
        writeState(home: home,
                   recent: [],
                   lastConversion: nil,
                   totals: ["converted_total": convertedTotal,
                            "today": today,
                            "failed_today": failedToday],
                   todayDate: todayDate)
    }

    // MARK: - changeWatchFolder helpers (group B)

    /// A client with explicit installer + ebook-convert paths (group B needs to
    /// drive `calibreInstalled()` and capture the installer's WATCH_DIR argument).
    static func client(home: String, installer: String, ebookConvert: String) -> EngineClient {
        EngineClient(label: throwawayLabel(),
                     home: home,
                     installerPath: installer,
                     ebookConvertPath: ebookConvert)
    }

    /// Write a throwaway STUB installer into `home` that records the WATCH_DIR it
    /// was handed ($1, exactly how `runInstaller` invokes `/bin/bash <path> <dir>`)
    /// into `home/installer-watchdir.txt`, then exits 0. NO real launchctl, no
    /// agent — it only proves the production `changeWatchFolder` reached the
    /// installer with the right argument. Returns (stubPath, recordPath).
    static func writeStubInstaller(home: String, exitCode: Int = 0) -> (stub: String, record: String) {
        let stub = "\(home)/stub-installer.sh"
        let record = "\(home)/installer-watchdir.txt"
        // `$1` is the WATCH_DIR; printf (not echo) keeps it byte-exact.
        let script = """
        #!/bin/bash
        printf '%s' "$1" > "\(record)"
        exit \(exitCode)
        """
        try? script.write(toFile: stub, atomically: true, encoding: .utf8)
        // Not strictly required (we run it via `/bin/bash <path>`), but realistic.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: stub)
        return (stub, record)
    }

    /// `/bin/echo` exists and is executable → makes `calibreInstalled()` true
    /// without any real Calibre. A path that cannot exist → false.
    static let realExecutable = "/bin/echo"
    static let missingExecutable = "/nonexistent/ebook-convert-\(UUID().uuidString)"

    /// One recent entry as a JSON-ready dict (newest-first ordering is the
    /// caller's responsibility, matching the watcher contract).
    static func entry(src: String, dst: String, ts: String, status: String = "ok") -> [String: Any] {
        ["src": src, "dst": dst, "ts": ts, "status": status]
    }

    /// Write a state.json exactly in the watcher's schema into the isolated HOME.
    /// `recent` is written verbatim (newest-first), `lastConversion` optional.
    @discardableResult
    static func writeState(home: String,
                           recent: [[String: Any]],
                           lastConversion: [String: Any]?,
                           totals: [String: Int] = ["converted_total": 0, "today": 0, "failed_today": 0],
                           watchDir: String? = nil,
                           todayDate: String? = nil) -> Bool {
        let dir = stateDir(home)
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        var obj: [String: Any] = [
            "schema": 1,
            "agent": ["watch_dir": watchDir ?? "\(home)/Desktop/fb2-to-epub"],
            "totals": totals,
            "recent": recent,
        ]
        if let last = lastConversion { obj["last_conversion"] = last }
        if let td = todayDate { obj["_today_date"] = td }
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.sortedKeys, .prettyPrinted]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: stateJSONPath(home)),
                                options: .atomic)) != nil
    }

    /// Raw bytes of state.json (nil if absent) — used to prove the app never
    /// rewrites it.
    static func stateBytes(_ home: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: stateJSONPath(home)))
    }

    // Deterministic timestamps. "Past" is comfortably before any clear marker
    // we stamp during the run; "future" is comfortably after, so the `ts > cutoff`
    // boundary is never decided by sub-second timing.
    static let pastTs1 = "2020-01-01T10:00:00Z"
    static let pastTs2 = "2020-01-02T11:30:00Z"
    static let pastTs3 = "2020-01-03T09:15:00Z"
    static func futureTs() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date().addingTimeInterval(3600 * 24 * 365)) // +1 year
    }
}

// MARK: - Tests

// (1) before-clear: a populated state.json reads back fully (no marker yet).
func test_beforeClear_readsAllEntries() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let recent = [
        Fixture.entry(src: "c.fb2", dst: "c.epub", ts: Fixture.pastTs3),
        Fixture.entry(src: "b.fb2", dst: "b.epub", ts: Fixture.pastTs2),
        Fixture.entry(src: "a.fb2", dst: "a.epub", ts: Fixture.pastTs1),
    ]
    let last = Fixture.entry(src: "c.fb2", dst: "c.epub", ts: Fixture.pastTs3)
    T.ok(Fixture.writeState(home: home, recent: recent, lastConversion: last),
         "state.json written")

    let st = Fixture.client(home: home).loadState()
    T.eq(st.recent.count, 3, "loadState().recent.count == N before clear")
    T.ok(st.lastConversion != nil, "loadState().lastConversion != nil before clear")
}

// (2) clear writes the marker, and it is parseable by RelativeTime.parse.
func test_clear_writesParseableMarker() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    Fixture.writeState(home: home,
                       recent: [Fixture.entry(src: "a.fb2", dst: "a.epub", ts: Fixture.pastTs1)],
                       lastConversion: Fixture.entry(src: "a.fb2", dst: "a.epub", ts: Fixture.pastTs1))

    let path = Fixture.clearMarkerPath(home)
    T.ok(!FileManager.default.fileExists(atPath: path), "no marker before clear")

    Fixture.client(home: home).clearHistory()

    T.ok(FileManager.default.fileExists(atPath: path), "marker file exists after clear")
    let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    T.ok(RelativeTime.parse(trimmed) != nil,
         "marker parses via RelativeTime.parse (\"\(trimmed)\")")
}

// (3) after-clear: entries older than the marker disappear; last_conversion -> nil.
func test_afterClear_hidesOldEntries() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let recent = [
        Fixture.entry(src: "b.fb2", dst: "b.epub", ts: Fixture.pastTs2),
        Fixture.entry(src: "a.fb2", dst: "a.epub", ts: Fixture.pastTs1),
    ]
    Fixture.writeState(home: home, recent: recent,
                       lastConversion: Fixture.entry(src: "b.fb2", dst: "b.epub", ts: Fixture.pastTs2))

    let ec = Fixture.client(home: home)
    T.eq(ec.loadState().recent.count, 2, "two entries visible before clear")

    ec.clearHistory()

    let st = ec.loadState()
    T.ok(st.recent.isEmpty, "loadState().recent.isEmpty after clear")
    T.ok(st.lastConversion == nil, "loadState().lastConversion == nil after clear")
}

// (4) state.json is byte-identical before and after clear (the app never writes it).
func test_clear_doesNotTouchStateJSON() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let recent = [
        Fixture.entry(src: "b.fb2", dst: "b.epub", ts: Fixture.pastTs2),
        Fixture.entry(src: "a.fb2", dst: "a.epub", ts: Fixture.pastTs1),
    ]
    Fixture.writeState(home: home, recent: recent,
                       lastConversion: Fixture.entry(src: "b.fb2", dst: "b.epub", ts: Fixture.pastTs2))

    let before = Fixture.stateBytes(home)
    T.ok(before != nil, "state.json exists before clear")

    Fixture.client(home: home).clearHistory()

    let after = Fixture.stateBytes(home)
    T.ok(after != nil, "state.json still exists after clear")
    T.ok(before == after, "state.json bytes identical before/after clear")
}

// (5) new conversions reappear: an entry strictly newer than the marker survives.
//     We clear first (marker = now), THEN append a future-dated entry to
//     state.json (simulating the watcher writing a new conversion after clear).
func test_newConversionsReappearAfterClear() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    // Old history that the clear will hide.
    Fixture.writeState(home: home,
                       recent: [Fixture.entry(src: "old.fb2", dst: "old.epub", ts: Fixture.pastTs1)],
                       lastConversion: Fixture.entry(src: "old.fb2", dst: "old.epub", ts: Fixture.pastTs1))

    let ec = Fixture.client(home: home)
    ec.clearHistory()
    T.ok(ec.loadState().recent.isEmpty, "history hidden right after clear")

    // The watcher publishes a brand-new conversion (future ts, newest-first).
    let fresh = Fixture.entry(src: "new.fb2", dst: "new.epub", ts: Fixture.futureTs())
    Fixture.writeState(home: home,
                       recent: [fresh, Fixture.entry(src: "old.fb2", dst: "old.epub", ts: Fixture.pastTs1)],
                       lastConversion: fresh)

    let st = ec.loadState()
    T.eq(st.recent.count, 1, "only the post-clear conversion is visible")
    T.eq(st.recent.first?.dst ?? "", "new.epub", "the new conversion reappears")
    T.ok(st.lastConversion?.dst == "new.epub", "last_conversion re-points to the new entry")
}

// (6) persistence: a fresh EngineClient on the SAME home still sees the filtered
//     view, because the marker lives on disk (not in memory).
func test_markerPersistsAcrossClients() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    Fixture.writeState(home: home,
                       recent: [Fixture.entry(src: "a.fb2", dst: "a.epub", ts: Fixture.pastTs1)],
                       lastConversion: Fixture.entry(src: "a.fb2", dst: "a.epub", ts: Fixture.pastTs1))

    Fixture.client(home: home).clearHistory()   // client #1 stamps the marker

    // Brand-new client, same HOME, no shared in-memory state.
    let ec2 = Fixture.client(home: home)
    let st = ec2.loadState()
    T.ok(st.recent.isEmpty, "second client still sees an empty filtered list")
    T.ok(st.lastConversion == nil, "second client still sees nil last_conversion")
}

// (7) fail-open: an entry with a deliberately broken ts stays visible after clear
//     (we must never hide an event just because its timestamp is unparseable).
func test_failOpen_unparseableTsStaysVisible() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let broken = Fixture.entry(src: "weird.fb2", dst: "weird.epub", ts: "NOT-A-DATE")
    let old = Fixture.entry(src: "old.fb2", dst: "old.epub", ts: Fixture.pastTs1)
    Fixture.writeState(home: home, recent: [broken, old], lastConversion: broken)

    let ec = Fixture.client(home: home)
    ec.clearHistory()

    let st = ec.loadState()
    // The parseable-old entry is hidden; the broken-ts one survives (fail-open).
    T.ok(st.recent.contains(where: { $0.ts == "NOT-A-DATE" }),
         "entry with unparseable ts remains visible after clear (fail-open)")
    T.ok(!st.recent.contains(where: { $0.dst == "old.epub" }),
         "the parseable old entry is still hidden")
}

// MARK: - Group A — resetStats / stats-baseline ("Сбросить статистику")
//
// WHAT IS UNDER TEST (app/EngineClient+Status.swift)
// --------------------------------------------------
// Same contract as "Очистить": the watcher OWNS state.json (D13) — the app must
// NOT rewrite it. `resetStats()` instead captures the CURRENT raw lifetime total
// as an app-owned baseline marker
//   {home}/.../state/stats-baseline   = {"converted_total":<raw>,"ts":...}
// written atomically. `loadState()` then subtracts it:
//   convertedTotal = max(0, current - baseline)
// ONLY convertedTotal is baselined — today / failedToday are reset DAILY by the
// watcher (via _today_date), so baselining them would corrupt the day counter.
// Malformed baseline -> ignored (fail-open: show the raw total).
//
// Isolation: throwaway HOME + throwaway label, pure file IO inside the temp HOME.
// resetStats()/loadState() shell out to NOTHING -> fully deterministic.

// (A1) seed converted_total=N, no baseline yet -> loadState reads N verbatim.
func test_A1_noBaseline_readsRawTotal() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let N = 1235
    T.ok(Fixture.writeTotals(home: home, convertedTotal: N), "state.json with converted_total=N")

    let st = Fixture.client(home: home).loadState()
    T.eq(st.totals.convertedTotal, N, "convertedTotal == N when no baseline exists")
    T.ok(!FileManager.default.fileExists(atPath: Fixture.statsBaselinePath(home)),
         "no stats-baseline file before reset")
}

// (A2) resetStats() writes a parseable baseline whose converted_total == raw N.
func test_A2_reset_writesBaselineMarker() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let N = 1235
    Fixture.writeTotals(home: home, convertedTotal: N)

    let path = Fixture.statsBaselinePath(home)
    T.ok(!FileManager.default.fileExists(atPath: path), "no baseline before reset")

    Fixture.client(home: home).resetStats()

    T.ok(FileManager.default.fileExists(atPath: path), "stats-baseline exists after reset")
    T.eq(Fixture.readBaseline(home) ?? -1, N, "baseline converted_total == raw N")
}

// (A3) after reset, the card reads zero (current − baseline = N − N = 0).
func test_A3_afterReset_totalIsZero() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let N = 1235
    Fixture.writeTotals(home: home, convertedTotal: N)

    let ec = Fixture.client(home: home)
    T.eq(ec.loadState().totals.convertedTotal, N, "raw N before reset")

    ec.resetStats()

    T.eq(ec.loadState().totals.convertedTotal, 0, "convertedTotal == 0 right after reset")
}

// (A4) new conversions count again: baseline=N, watcher writes N+3 -> shows 3.
func test_A4_newConversionsCountFromZero() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let N = 1235
    Fixture.writeTotals(home: home, convertedTotal: N)

    let ec = Fixture.client(home: home)
    ec.resetStats()
    T.eq(ec.loadState().totals.convertedTotal, 0, "zero right after reset")

    // The watcher publishes 3 more lifetime conversions.
    Fixture.writeTotals(home: home, convertedTotal: N + 3)

    T.eq(ec.loadState().totals.convertedTotal, 3, "shows 3 post-reset conversions (N+3 − N)")
}

// (A5) max(0,…) guard: baseline=N, then state.json regresses to N−5 -> 0 (never <0).
func test_A5_maxZero_guardsAgainstUnderflow() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let N = 1235
    Fixture.writeTotals(home: home, convertedTotal: N)

    let ec = Fixture.client(home: home)
    ec.resetStats()                                   // baseline = N

    // A stale/over-large baseline vs a smaller current total must clamp to 0.
    Fixture.writeTotals(home: home, convertedTotal: N - 5)

    T.eq(ec.loadState().totals.convertedTotal, 0, "convertedTotal clamps to 0, not negative")
}

// (A6) "за сегодня" IS now zeroed by reset (same-day): seed today=7 + reset ->
//      today reads 0. failedToday is NOT baselined (the card shows only "сегодня").
func test_A6_today_isZeroedSameDay() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let N = 1235
    Fixture.writeTotals(home: home, convertedTotal: N, today: 7, failedToday: 2,
                        todayDate: Fixture.today())

    let ec = Fixture.client(home: home)
    T.eq(ec.loadState().totals.today, 7, "raw today == 7 before reset")

    ec.resetStats()

    let st = ec.loadState()
    T.eq(st.totals.convertedTotal, 0, "convertedTotal reset to 0")
    T.eq(st.totals.today, 0, "today zeroed by reset (same day) == 0")
    T.eq(st.totals.failedToday, 2, "failedToday untouched by reset (== 2)")
}

// (A7) idempotence: a SECOND resetStats() re-captures the CURRENT raw total as the
//      new baseline, so the card is zero again (even after new conversions).
func test_A7_reset_isIdempotent_recapturesBaseline() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let N = 1235
    Fixture.writeTotals(home: home, convertedTotal: N)

    let ec = Fixture.client(home: home)
    ec.resetStats()                                   // baseline = N -> shows 0
    Fixture.writeTotals(home: home, convertedTotal: N + 4)
    T.eq(ec.loadState().totals.convertedTotal, 4, "shows 4 after some new conversions")

    ec.resetStats()                                   // baseline = N+4 now

    T.eq(Fixture.readBaseline(home) ?? -1, N + 4, "baseline re-captured at current raw (N+4)")
    T.eq(ec.loadState().totals.convertedTotal, 0, "card is zero again after second reset")
}

// (A8) fail-open: a garbage/corrupt stats-baseline is IGNORED -> raw total shown.
func test_A8_failOpen_corruptBaselineIgnored() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let N = 1235
    Fixture.writeTotals(home: home, convertedTotal: N)

    // Hand-write a corrupt baseline (not JSON / wrong shape) where reset would.
    let dir = Fixture.stateDir(home)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? "}{ not json at all".write(toFile: Fixture.statsBaselinePath(home),
                                    atomically: true, encoding: .utf8)

    let st = Fixture.client(home: home).loadState()
    T.eq(st.totals.convertedTotal, N, "corrupt baseline ignored -> raw N still shown")
}

// (A9) ONE reset now zeroes EVERYTHING visible: "всего" + "за сегодня" + recent.
//      This is the headline of the new behavior — a single resetStats() call must
//      stamp all three markers and leave the Status screen blank.
func test_A9_reset_zeroesEverything() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let N = 1235
    let recent = [
        Fixture.entry(src: "b.fb2", dst: "b.epub", ts: Fixture.pastTs2),
        Fixture.entry(src: "a.fb2", dst: "a.epub", ts: Fixture.pastTs1),
    ]
    Fixture.writeState(home: home, recent: recent,
                       lastConversion: Fixture.entry(src: "b.fb2", dst: "b.epub", ts: Fixture.pastTs2),
                       totals: ["converted_total": N, "today": 9, "failed_today": 0],
                       todayDate: Fixture.today())

    let ec = Fixture.client(home: home)
    ec.resetStats()     // ONE call → stats-baseline + today-baseline + recent-cleared-at

    // All three app-owned markers now exist side by side.
    T.ok(FileManager.default.fileExists(atPath: Fixture.statsBaselinePath(home)),
         "stats-baseline present")
    T.ok(FileManager.default.fileExists(atPath: Fixture.todayBaselinePath(home)),
         "today-baseline present")
    T.ok(FileManager.default.fileExists(atPath: Fixture.clearMarkerPath(home)),
         "recent-cleared-at present")

    let st = ec.loadState()
    T.eq(st.totals.convertedTotal, 0, "«всего» == 0 after reset")
    T.eq(st.totals.today, 0, "«за сегодня» == 0 after reset")
    T.ok(st.recent.isEmpty, "recent list cleared after reset")
    T.ok(st.lastConversion == nil, "last_conversion cleared after reset")
}

// (A10) today-baseline is written with the CURRENT day + raw today value.
func test_A10_reset_writesTodayBaselineMarker() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    Fixture.writeTotals(home: home, convertedTotal: 100, today: 5,
                        todayDate: Fixture.today())

    T.ok(!FileManager.default.fileExists(atPath: Fixture.todayBaselinePath(home)),
         "no today-baseline before reset")

    Fixture.client(home: home).resetStats()

    let tb = Fixture.readTodayBaseline(home)
    T.ok(tb != nil, "today-baseline parseable after reset")
    T.eq(tb?.date ?? "", Fixture.today(), "today-baseline.date == watcher's _today_date")
    T.eq(tb?.today ?? -1, 5, "today-baseline.today == raw today (5)")
}

// (A11) DATE-AWARE expiry — the day-after: baseline captured for TODAY must NOT
//       bury TOMORROW's count. We reset today (today-baseline.date = today), then
//       the watcher rolls the day over (_today_date = tomorrow, today = 4 fresh).
//       loadState() must IGNORE the stale baseline and show the fresh 4.
func test_A11_todayBaseline_expiresWhenDayRolls() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    Fixture.writeTotals(home: home, convertedTotal: 100, today: 8,
                        todayDate: Fixture.today())

    let ec = Fixture.client(home: home)
    ec.resetStats()
    T.eq(ec.loadState().totals.today, 0, "today == 0 right after reset (same day)")

    // Next day: the watcher reset `today` to a fresh count under a NEW _today_date.
    Fixture.writeTotals(home: home, convertedTotal: 104, today: 4,
                        todayDate: Fixture.tomorrow())

    T.eq(ec.loadState().totals.today, 4,
         "stale today-baseline expired -> shows tomorrow's fresh count (4), NOT 0")
}

// (A12) same-day NEW conversions count from zero: reset today=2, watcher bumps to
//       today=5 (same _today_date) -> card shows 3 (5 − 2), not buried.
func test_A12_today_sameDayCountsFromZero() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let day = Fixture.today()
    Fixture.writeTotals(home: home, convertedTotal: 100, today: 2, todayDate: day)

    let ec = Fixture.client(home: home)
    ec.resetStats()
    T.eq(ec.loadState().totals.today, 0, "today == 0 right after reset")

    // Two more conversions land the SAME day (watcher bumps today, same stamp).
    Fixture.writeTotals(home: home, convertedTotal: 102, today: 4, todayDate: day)

    T.eq(ec.loadState().totals.today, 2, "same-day post-reset conversions show (4 − 2 == 2)")
}

// (A13) max(0,…) guard for "за сегодня": baseline today=5, then the watcher's
//       today regresses to 3 (same day) -> clamps to 0, never negative.
func test_A13_today_maxZeroGuard() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let day = Fixture.today()
    Fixture.writeTotals(home: home, convertedTotal: 100, today: 5, todayDate: day)

    let ec = Fixture.client(home: home)
    ec.resetStats()                                  // today-baseline = 5 @ day

    // Same-day regression (e.g. a corrected count) must clamp, not go negative.
    Fixture.writeTotals(home: home, convertedTotal: 100, today: 3, todayDate: day)

    T.eq(ec.loadState().totals.today, 0, "today clamps to 0, not negative")
}

// (A14) fail-open: a corrupt today-baseline is IGNORED -> raw today shown.
func test_A14_failOpen_corruptTodayBaselineIgnored() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    Fixture.writeTotals(home: home, convertedTotal: 100, today: 6, todayDate: Fixture.today())

    let dir = Fixture.stateDir(home)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? "}{ not json".write(toFile: Fixture.todayBaselinePath(home),
                             atomically: true, encoding: .utf8)

    let st = Fixture.client(home: home).loadState()
    T.eq(st.totals.today, 6, "corrupt today-baseline ignored -> raw today (6) shown")
}

// (A15) no _today_date in state.json (older/fresh writer): the baseline still
//       applies for the local day it was stamped on (fallback path in loadState).
func test_A15_today_fallbackWhenNoStateDayStamp() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    // No todayDate passed -> state.json carries NO _today_date.
    Fixture.writeTotals(home: home, convertedTotal: 100, today: 7)

    let ec = Fixture.client(home: home)
    ec.resetStats()   // baseline.date falls back to localDayString() == today

    // Snapshot still has no _today_date; loadState's fallback day == baseline.date.
    T.eq(ec.loadState().totals.today, 0,
         "baseline applies via local-day fallback when state has no _today_date")
}

// MARK: - Group B — changeWatchFolder (STUB installer, NO real launchctl)
//
// WHAT IS UNDER TEST (app/EngineClient+Status.swift)
// --------------------------------------------------
//   changeWatchFolder(to:) = calibreInstalled() guard  +  runInstaller(watchDir:)
//   runInstaller invokes `/bin/bash <installerPath> <watchDir>` (argv, no shell
//   glue) and returns true iff rc == 0.
// We point installerPath at a throwaway STUB .sh that records its $1 (the
// WATCH_DIR) and exits 0 — proving the production code reached the installer with
// the right argument WITHOUT booting any real agent. ebookConvertPath is set to
// `/bin/echo` (exists+executable) so calibreInstalled() is true without Calibre.
//
// Isolation: throwaway HOME + throwaway label; the stub never calls launchctl and
// never touches the real plist / agent / watch folder.

// (B1) Calibre present + stub installer rc 0 -> returns true AND the stub captured
//      the exact newDir we passed.
func test_B1_changeWatchFolder_callsInstallerWithDir() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let (stub, record) = Fixture.writeStubInstaller(home: home, exitCode: 0)
    let newDir = "\(home)/Desktop/another fb2 folder"   // spaces on purpose (argv safety)

    let ec = Fixture.client(home: home, installer: stub, ebookConvert: Fixture.realExecutable)
    T.ok(ec.calibreInstalled(), "precondition: calibreInstalled() true via /bin/echo")

    let ok = ec.changeWatchFolder(to: newDir)

    T.ok(ok, "changeWatchFolder returns true when installer exits 0")
    let captured = (try? String(contentsOfFile: record, encoding: .utf8)) ?? "<none>"
    T.eq(captured, newDir, "stub installer received the exact WATCH_DIR argument")
}

// (B2) Calibre absent -> returns false AND the installer is NOT invoked.
func test_B2_changeWatchFolder_blockedWhenNoCalibre() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let (stub, record) = Fixture.writeStubInstaller(home: home, exitCode: 0)
    let newDir = "\(home)/Desktop/folder"

    // Missing ebook-convert -> calibreInstalled() == false -> short-circuit.
    let ec = Fixture.client(home: home, installer: stub, ebookConvert: Fixture.missingExecutable)
    T.ok(!ec.calibreInstalled(), "precondition: calibreInstalled() false (missing binary)")

    let ok = ec.changeWatchFolder(to: newDir)

    T.ok(!ok, "changeWatchFolder returns false when Calibre is absent")
    T.ok(!FileManager.default.fileExists(atPath: record),
         "installer was NOT invoked (no record file written)")
}

// (B3) Calibre present but installer FAILS (rc != 0) -> returns false, surfaces the
//      failure rather than pretending success. (The stub was reached.)
func test_B3_changeWatchFolder_falseWhenInstallerFails() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let (stub, record) = Fixture.writeStubInstaller(home: home, exitCode: 7)
    let newDir = "\(home)/Desktop/folder"

    let ec = Fixture.client(home: home, installer: stub, ebookConvert: Fixture.realExecutable)
    let ok = ec.changeWatchFolder(to: newDir)

    T.ok(!ok, "changeWatchFolder returns false when installer exits non-zero")
    // The stub still ran (Calibre was present), so the record proves we reached it.
    T.ok(FileManager.default.fileExists(atPath: record),
         "installer WAS invoked (Calibre present) even though it failed")
}

// MARK: - Runner

print("TAP version 13")
print("# fb2-to-epub — Status actions regression suite (Очистить + Сбросить + Сменить папку)")

T.run("1 before-clear reads all entries", test_beforeClear_readsAllEntries)
T.run("2 clear writes parseable marker", test_clear_writesParseableMarker)
T.run("3 after-clear hides old entries", test_afterClear_hidesOldEntries)
T.run("4 clear does not touch state.json", test_clear_doesNotTouchStateJSON)
T.run("5 new conversions reappear after clear", test_newConversionsReappearAfterClear)
T.run("6 marker persists across clients", test_markerPersistsAcrossClients)
T.run("7 fail-open: unparseable ts stays visible", test_failOpen_unparseableTsStaysVisible)

print("# --- Сбросить статистику (resetStats / baseline) ---")
T.run("A1 no baseline reads raw total", test_A1_noBaseline_readsRawTotal)
T.run("A2 reset writes baseline marker", test_A2_reset_writesBaselineMarker)
T.run("A3 after reset total is zero", test_A3_afterReset_totalIsZero)
T.run("A4 new conversions count from zero", test_A4_newConversionsCountFromZero)
T.run("A5 max(0,…) guards underflow", test_A5_maxZero_guardsAgainstUnderflow)
T.run("A6 today zeroed same-day by reset", test_A6_today_isZeroedSameDay)
T.run("A7 reset is idempotent (recapture)", test_A7_reset_isIdempotent_recapturesBaseline)
T.run("A8 fail-open: corrupt baseline ignored", test_A8_failOpen_corruptBaselineIgnored)
T.run("A9 reset zeroes EVERYTHING (всего+сегодня+recent)", test_A9_reset_zeroesEverything)
T.run("A10 reset writes today-baseline marker", test_A10_reset_writesTodayBaselineMarker)
T.run("A11 today-baseline EXPIRES when day rolls", test_A11_todayBaseline_expiresWhenDayRolls)
T.run("A12 today same-day counts from zero", test_A12_today_sameDayCountsFromZero)
T.run("A13 today max(0,…) guard", test_A13_today_maxZeroGuard)
T.run("A14 fail-open: corrupt today-baseline ignored", test_A14_failOpen_corruptTodayBaselineIgnored)
T.run("A15 today baseline via local-day fallback", test_A15_today_fallbackWhenNoStateDayStamp)

print("# --- Сменить папку (changeWatchFolder, STUB installer) ---")
T.run("B1 changeWatchFolder calls installer with dir", test_B1_changeWatchFolder_callsInstallerWithDir)
T.run("B2 changeWatchFolder blocked when no Calibre", test_B2_changeWatchFolder_blockedWhenNoCalibre)
T.run("B3 changeWatchFolder false when installer fails", test_B3_changeWatchFolder_falseWhenInstallerFails)

// ── CAL-2 hasRawHistory (D37 hybrid: banner vs blocker) ────────────────────
print("# --- Онбординг: hasRawHistory (гибрид D37) ---")
T.run("F1 empty → no history", test_F1_empty_hasNoHistory)
T.run("F2 converted_total → history", test_F2_convertedTotal_isHistory)
T.run("F3 recent → history", test_F3_recent_isHistory)
T.run("F4 last_conversion → history", test_F4_lastConversion_isHistory)
T.run("F5 reset does NOT flip raw history (banner stays)", test_F5_resetStats_doesNotFlipRawHistory)
T.run("F6 no state.json → no history", test_F6_noStateFile_hasNoHistory)

// ── v0.2.2 auto-update feature (UpdateCheckerTests.swift) ──────────────────
print("# --- Авто-обновление: semver (UpdateChecker.isNewer) ---")
T.run("C-semver isNewer true cases", test_C_isNewer_trueCases)
T.run("C-semver isNewer false cases", test_C_isNewer_falseCases)
T.run("C-semver isNewer edge cases (no crash)", test_C_isNewer_edgeCases_doNotCrash)

print("# --- Авто-обновление: trusted source (UpdateChecker.isTrustedSource) ---")
T.run("D-trust trusted https GitHub hosts", test_D_isTrustedSource_trusted)
T.run("D-trust untrusted (http/foreign/look-alike)", test_D_isTrustedSource_untrusted)

print("# --- Авто-обновление: engine refresh (refreshEngineIfBundledChanged, STUB installer) ---")
T.run("E1 no plist → skippedNoPlist (no install)", test_E1_noPlist_skips)
T.run("E2 identical + PA0=helper → upToDate (no install)", test_E2_identical_andPA0Helper_upToDate)
T.run("E3 one differs → refreshed + WATCH_DIR passed", test_E3_oneDiffers_refreshed_passesWatchDir)
T.run("E4 installed script missing → refreshed", test_E4_installedMissing_refreshed)
T.run("E5 installer rc≠0 → refreshFailed (no crash)", test_E5_installerFails_refreshFailed)
T.run("E6 bytes match + Calibre + PA0 stale → refreshed + PA0 healed (fix #1)", test_E6_bytesMatchButPA0Stale_refreshesAndHealsPA0)
T.run("E7 bytes match + PA0 stale + NO Calibre → upToDate, no loop (fix #1 guard)", test_E7_bytesMatchPA0StaleNoCalibre_noLoop_upToDate)
T.run("E8 bytes match + Calibre + PA0 stale + rc≠0 → refreshFailed, PA0 still stale (fix #2 signal)", test_E8_bytesMatchPA0StaleCalibrePresent_installerFails_refreshFailed_PA0StillStale)

// --- FDA-onboarding contract (v1.0.1): decode matrix / runnerPath / recheck ------
T.run("FDA-D1 absent folder_access → nil", test_FDA_D1_absentField_isNil)
T.run("FDA-D2 ok/denied/missing decode", test_FDA_D2_okDeniedMissing_decode)
T.run("FDA-D3 unknown string → nil (forward-compat)", test_FDA_D3_unknownString_isNil_forwardCompat)
T.run("FDA-D4 non-string → nil, watch_dir kept", test_FDA_D4_nonStringType_isNil_watchDirKept)
T.run("FDA-D5 folder_access_ts decoded", test_FDA_D5_ts_decoded)
T.run("FDA-D6 StateStore.load end-to-end denied", test_FDA_D6_endToEnd_stateStoreLoad)
T.run("FDA-D7 corrupt state → empty, no crash", test_FDA_D7_corrupt_degradesToEmpty_noCrash)
T.run("FDA-R1 runnerPath from plist ProgramArguments[0]", test_FDA_R1_runnerPath_fromPlistProgramArguments0)
T.run("FDA-R2 runnerPath fallback (no plist)", test_FDA_R2_runnerPath_fallbackWhenNoPlist)
// v1.0.3 (re-review): the FDA-CTA dead-path guard — «PA0 есть И ≠ helper».
T.run("FDA-CT1 PA0 stale + no Calibre → stale (no copy)", test_FDA_CT1_pa0Stale_noCalibre_isStale_noCopy)
T.run("FDA-CT2 PA0 stale + Calibre → stale (both roads)", test_FDA_CT2_pa0Stale_withCalibre_isStale)
T.run("FDA-CT3 PA0 absent → not stale, copy = helper", test_FDA_CT3_pa0Absent_notStale_copyWorks_helperPath)
T.run("FDA-CT4 PA0 broken/empty → not stale, copy = helper", test_FDA_CT4_brokenOrEmptyPA0_notStale_copyWorks)
T.run("FDA-CT5 no plist → not stale, copy = helper", test_FDA_CT5_noPlist_notStale_copyWorks)
T.run("FDA-CT6 PA0 = helper → not stale (live agent unchanged)", test_FDA_CT6_pa0Helper_notStale_copyUnchanged)
T.run("FDA-P1 router: engine wins over folder", test_FDA_P1_engineWins_overFolder)
T.run("FDA-P2 router: folder when engine present", test_FDA_P2_folderWhenEnginePresent)
T.run("FDA-P3 router: normal when neither", test_FDA_P3_normalWhenNeither)
T.run("FDA-RC1 not in flight → pending", test_FDA_RC1_notInFlight_isPending)
T.run("FDA-RC2 no fresh ts → pending", test_FDA_RC2_noFreshTs_isPending)
T.run("FDA-RC3 fresh denied → stillDenied", test_FDA_RC3_freshDenied_isStillDenied)
T.run("FDA-RC4 fresh ok → cleared", test_FDA_RC4_freshOk_isCleared)
T.run("FDA-RC5 fresh missing/nil → cleared", test_FDA_RC5_freshMissingOrNil_isCleared)
T.run("FDA-RC6 empty pressed ts (old agent) resolves", test_FDA_RC6_emptyPressedTs_oldAgent_anyFreshResolves)
T.run("FDA-TD1 terminal + live ok → dissolves (A1)", test_FDA_TD1_terminalPlusLiveOk_dissolves)
T.run("FDA-TD2 terminal + still denied → keeps", test_FDA_TD2_terminalStillDenied_keeps)
T.run("FDA-TD3 non-terminal → not this path", test_FDA_TD3_nonTerminal_neverDissolvesHere)

print("")
print("1..\(T.passed + T.failed)")
print("# passed: \(T.passed)")
print("# failed: \(T.failed)")
exit(T.failed == 0 ? 0 : 1)
