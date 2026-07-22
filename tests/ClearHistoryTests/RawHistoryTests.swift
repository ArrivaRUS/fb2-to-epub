// RawHistoryTests.swift — CAL-2 unit coverage for EngineClient.hasRawHistory().
//
// WHAT IS UNDER TEST (app/EngineClient.swift)
// -------------------------------------------
// hasRawHistory() decides the D37 onboarding hybrid: history → banner A (keep the
// user's books visible), none → blocker B. It MUST read the RAW state.json
// snapshot (StateStore.load()), NOT the filtered loadState() — otherwise pressing
// "Сбросить статистику" / "Очистить" (which write app-owned baseline/clear markers)
// would zero the FILTERED view and silently flip the banner into a blocker. That
// regression is exactly what test F5 guards.
//
// Contract: hasRawHistory ==
//   converted_total > 0 || !recent.isEmpty || last_conversion != nil
//
// ISOLATION: same throwaway-HOME model as the rest of this suite — every path
// derives from a mktemp HOME, nothing touches the real agent / state.json.
//
// Compiled by tests/run-clear-history-tests.sh together with the production
// sources; invoked from main.swift's runner. Production code is NOT modified.

import Foundation

// F1 — a truly empty snapshot has no history.
func test_F1_empty_hasNoHistory() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    Fixture.writeState(home: home, recent: [], lastConversion: nil,
                       totals: ["converted_total": 0, "today": 0, "failed_today": 0])
    T.eq(Fixture.client(home: home).hasRawHistory(), false,
         "empty snapshot → hasRawHistory == false (→ blocker B)")
}

// F2 — a lifetime total alone counts as history.
func test_F2_convertedTotal_isHistory() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    Fixture.writeTotals(home: home, convertedTotal: 412)
    T.eq(Fixture.client(home: home).hasRawHistory(), true,
         "converted_total > 0 → hasRawHistory == true (→ banner A)")
}

// F3 — a non-empty recent list alone counts as history.
func test_F3_recent_isHistory() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    Fixture.writeState(home: home,
                       recent: [Fixture.entry(src: "a.fb2", dst: "a.epub", ts: Fixture.pastTs1)],
                       lastConversion: nil,
                       totals: ["converted_total": 0, "today": 0, "failed_today": 0])
    T.eq(Fixture.client(home: home).hasRawHistory(), true,
         "recent non-empty → hasRawHistory == true")
}

// F4 — last_conversion alone counts as history (the third clause).
func test_F4_lastConversion_isHistory() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    Fixture.writeState(home: home,
                       recent: [],
                       lastConversion: Fixture.entry(src: "a.fb2", dst: "a.epub", ts: Fixture.pastTs1),
                       totals: ["converted_total": 0, "today": 0, "failed_today": 0])
    T.eq(Fixture.client(home: home).hasRawHistory(), true,
         "last_conversion != nil → hasRawHistory == true")
}

// F5 — THE D37 GUARD. With real history, "Очистить" + "Сбросить статистику" must
// NOT change hasRawHistory (it reads RAW, not the filtered view). If this ever
// flips to false, the banner would collapse into a blocker after a stats reset.
func test_F5_resetStats_doesNotFlipRawHistory() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    Fixture.writeState(home: home,
                       recent: [Fixture.entry(src: "a.fb2", dst: "a.epub", ts: Fixture.pastTs1)],
                       lastConversion: Fixture.entry(src: "a.fb2", dst: "a.epub", ts: Fixture.pastTs1),
                       totals: ["converted_total": 412, "today": 3, "failed_today": 0])
    let client = Fixture.client(home: home)

    T.eq(client.hasRawHistory(), true, "precondition: history present")

    // Both user-facing resets write app-owned markers; state.json is untouched (D13).
    client.clearHistory()
    client.resetStats()

    // Filtered view is now empty (the point of the resets)…
    let filtered = client.loadState()
    T.eq(filtered.totals.convertedTotal, 0, "filtered total zeroed by resetStats")
    T.ok(filtered.recent.isEmpty, "filtered recent cleared by clearHistory")

    // …but RAW history is unchanged, so the banner stays a banner.
    T.eq(client.hasRawHistory(), true,
         "hasRawHistory STILL true after Очистить+Сбросить (banner stays banner, D37)")
}

// F6 — no state.json at all (fresh machine) → no history (blocker B).
func test_F6_noStateFile_hasNoHistory() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    // Deliberately write nothing.
    T.eq(Fixture.client(home: home).hasRawHistory(), false,
         "absent state.json → hasRawHistory == false")
}
