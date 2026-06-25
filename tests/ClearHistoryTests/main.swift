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

    /// Build a client bound to an isolated HOME + throwaway label.
    static func client(home: String) -> EngineClient {
        EngineClient(label: throwawayLabel(),
                     home: home,
                     installerPath: installerPath)
    }

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
                           watchDir: String? = nil) -> Bool {
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

// MARK: - Runner

print("TAP version 13")
print("# fb2-to-epub — Очистить (clear history) regression suite")

T.run("1 before-clear reads all entries", test_beforeClear_readsAllEntries)
T.run("2 clear writes parseable marker", test_clear_writesParseableMarker)
T.run("3 after-clear hides old entries", test_afterClear_hidesOldEntries)
T.run("4 clear does not touch state.json", test_clear_doesNotTouchStateJSON)
T.run("5 new conversions reappear after clear", test_newConversionsReappearAfterClear)
T.run("6 marker persists across clients", test_markerPersistsAcrossClients)
T.run("7 fail-open: unparseable ts stays visible", test_failOpen_unparseableTsStaysVisible)

print("")
print("1..\(T.passed + T.failed)")
print("# passed: \(T.passed)")
print("# failed: \(T.failed)")
exit(T.failed == 0 ? 0 : 1)
