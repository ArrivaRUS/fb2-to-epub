// FDAContractTests.swift — unit coverage for the FDA-onboarding contract (v1.0.1).
//
// WHAT IS UNDER TEST (Foundation-only, no SwiftUI):
//   • StateModel decode matrix — the tolerant `folder_access` decode: absent /
//     unknown / non-string → nil (⇒ no FDA surface), ok|denied|missing → enum, and
//     `watch_dir` is NEVER dropped by a bad access value (custom init(from:) guard).
//   • EngineClient.runnerPath() — the clipboard target: plist ProgramArguments[0] via
//     plutil, canonical fallback derived from home when the plist is absent.
//   • FolderRecheck.evaluate() — the «Проверить снова» ts-semantics with INJECTED
//     timestamps: accept a result only on a FRESH folder_access_ts (≠ pressed).
//
// ISOLATION: throwaway-HOME model (same as the rest of this suite); nothing touches
// the real agent / plist / state.json. Production code is NOT modified by the tests.
//
// Compiled by tests/run-clear-history-tests.sh; invoked from main.swift's runner.

import Foundation

// MARK: - decode helpers

private func decodeState(_ json: String) -> EngineState? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(EngineState.self, from: data)
}

/// A minimal state.json with a chosen `agent` block (raw JSON fragment).
private func stateJSON(agent: String) -> String {
    "{\"schema\":1,\"agent\":\(agent),\"totals\":{\"converted_total\":54},\"recent\":[]}"
}

// MARK: - D: decode matrix

func test_FDA_D1_absentField_isNil() {
    let s = decodeState(stateJSON(agent: "{\"watch_dir\":\"/w\"}"))
    T.eq(s?.agent.folderAccess, nil, "absent folder_access → nil (no FDA surface)")
    T.eq(s?.agent.watchDir, "/w", "watch_dir preserved when folder_access absent")
}

func test_FDA_D2_okDeniedMissing_decode() {
    T.eq(decodeState(stateJSON(agent: "{\"folder_access\":\"ok\"}"))?.agent.folderAccess, .ok, "ok → .ok")
    T.eq(decodeState(stateJSON(agent: "{\"folder_access\":\"denied\"}"))?.agent.folderAccess, .denied, "denied → .denied")
    T.eq(decodeState(stateJSON(agent: "{\"folder_access\":\"missing\"}"))?.agent.folderAccess, .missing, "missing → .missing")
}

func test_FDA_D3_unknownString_isNil_forwardCompat() {
    let s = decodeState(stateJSON(agent: "{\"watch_dir\":\"/w\",\"folder_access\":\"future-value\"}"))
    T.eq(s?.agent.folderAccess, nil, "unknown folder_access string → nil (forward-compat)")
    T.eq(s?.agent.watchDir, "/w", "watch_dir preserved despite unknown access value")
}

func test_FDA_D4_nonStringType_isNil_watchDirKept() {
    // A number where a string is expected must NOT throw away the whole agent block.
    let s = decodeState(stateJSON(agent: "{\"watch_dir\":\"/w\",\"folder_access\":7}"))
    T.eq(s?.agent.folderAccess, nil, "non-string folder_access → nil (tolerant)")
    T.eq(s?.agent.watchDir, "/w", "watch_dir NOT dropped by a bad-typed folder_access")
}

func test_FDA_D5_ts_decoded() {
    let s = decodeState(stateJSON(agent: "{\"folder_access\":\"denied\",\"folder_access_ts\":\"2026-07-22T09:31:04Z\"}"))
    T.eq(s?.agent.folderAccess, .denied, "denied with ts → .denied")
    T.eq(s?.agent.folderAccessTs, "2026-07-22T09:31:04Z", "folder_access_ts decoded as String")
}

func test_FDA_D6_endToEnd_stateStoreLoad() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let dir = "\(home)/Library/Application Support/fb2-to-epub/state"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let json = stateJSON(agent: "{\"watch_dir\":\"/w\",\"folder_access\":\"denied\",\"folder_access_ts\":\"2026-07-22T09:31:04Z\"}")
    try? json.write(toFile: "\(dir)/state.json", atomically: true, encoding: .utf8)
    let st = StateStore(home: home).load()
    T.eq(st.agent.folderAccess, .denied, "StateStore.load() surfaces denied end-to-end")
    T.eq(st.totals.convertedTotal, 54, "sibling totals still decode alongside folder_access")
}

func test_FDA_D7_corrupt_degradesToEmpty_noCrash() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let dir = "\(home)/Library/Application Support/fb2-to-epub/state"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? "{ not json".write(toFile: "\(dir)/state.json", atomically: true, encoding: .utf8)
    let st = StateStore(home: home).load()
    T.eq(st.agent.folderAccess, nil, "corrupt state.json → empty model, folderAccess nil (no crash)")
}

// MARK: - R: runnerPath (clipboard target)

func test_FDA_R1_runnerPath_fromPlistProgramArguments0() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = "com.arrivarus.fb2toepub.test.fda-unit"
    let laDir = "\(home)/Library/LaunchAgents"
    try? FileManager.default.createDirectory(atPath: laDir, withIntermediateDirectories: true)
    let runner = "\(home)/Library/Application Support/fb2-to-epub/bin/fb2-to-epub-runner.sh"
    let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [runner],
        "RunAtLoad": true,
    ]
    let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try! data.write(to: URL(fileURLWithPath: "\(laDir)/\(label).plist"))

    let ec = EngineClient(label: label, home: home, installerPath: "/bin/true")
    T.eq(ec.runnerPath(), runner, "runnerPath() reads ProgramArguments[0] from the plist")
}

func test_FDA_R2_runnerPath_fallbackWhenNoPlist() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let ec = EngineClient(label: "com.arrivarus.fb2toepub.test.absent", home: home, installerPath: "/bin/true")
    // v1.0.2: the FDA target is the Mach-O helper, not the legacy runner.sh.
    let want = "\(home)/Library/Application Support/fb2-to-epub/bin/fb2-to-epub-agent"
    T.eq(ec.runnerPath(), want, "no plist → canonical app-owned agent-helper path (derived from home, not literal ~)")
}

// MARK: - CT: copy-target guard (v1.0.3 re-review) — «PA0 есть И ≠ helper»
//
// WHAT IS UNDER TEST (app/EngineClient+Status.swift):
//   func installedRunnerPA0()      -> String?   tri-state read of ProgramArguments[0]
//   func installedRunnerIsStale()  -> Bool      PA0 PRESENT and ≠ the frozen helper
//
// WHY: the FDA CTA (`openFolderAccessAndCopyPath` in app/main.swift) copies
// `runnerPath()` and the card's step 2 promises «он уже в буфере». Copying a STALE PA0
// (the dead v1.0.1 runner.sh) is a silent lie, so the CTA refuses. The guard used to
// key on the launch-time refresh outcome (`.refreshFailed`), which missed the SECOND
// road fix #1 opened: no Calibre ⇒ the self-heal is skipped by the anti-loop guard ⇒
// `.upToDate` with the stale PA0 still in the plist (E7). Keying on the INVARIANT
// covers both roads — and must NOT degrade into a bare `!installedRunnerIsHelper()`,
// which would also fire when PA0 is absent/broken/empty, exactly where `runnerPath()`
// returns the CORRECT canonical helper and copying is the right thing to do.
//
// The predicate is what the CTA branches on, so these tests pin the CTA's decision
// without building AppDelegate (SwiftUI is not in this headless target).
//
// ISOLATION: throwaway HOME + throwaway label; installer "/bin/true" is never run.
// Calibre presence is faked via the ebookConvert override (executable stub = present,
// absent path = absent), never the host's real engine.

/// The frozen helper path for a throwaway HOME — mirrors production
/// `EngineClient.installedHelperPath` deliberately (an independent expectation).
private func ctHelperPath(_ home: String) -> String {
    "\(home)/Library/Application Support/fb2-to-epub/bin/fb2-to-epub-agent"
}

/// The dead v1.0.1 target a stale plist points at.
private func ctStaleRunnerPath(_ home: String) -> String {
    "\(home)/Library/Application Support/fb2-to-epub/bin/fb2-to-epub-runner.sh"
}

/// An EngineClient on a throwaway HOME. `calibre: true` → an executable stub makes
/// `calibreInstalled()` deterministically TRUE; `false` → a path with nothing at it.
private func ctClient(home: String, label: String, calibre: Bool) -> EngineClient {
    let path = calibre
        ? UpdateFixture.writeCalibreStub(home: home)
        : "\(home)/no-such-ebook-convert"
    return EngineClient(label: label, home: home, installerPath: "/bin/true",
                        ebookConvertPath: path)
}

// (CT1) THE BUG: PA0 stale + Calibre ABSENT — the road fix #1 opened (`.upToDate`,
//       self-heal skipped by the anti-loop guard). The guard MUST fire here, so the
//       CTA shows an honest hint instead of copying the dead path `runnerPath()` holds.
func test_FDA_CT1_pa0Stale_noCalibre_isStale_noCopy() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = Fixture.throwawayLabel()
    let stale = ctStaleRunnerPath(home)
    T.ok(UpdateFixture.writePlist(home: home, label: label,
                                  watchDir: "\(home)/Desktop/fb2-to-epub", programArg0: stale),
         "plist written (PA0 = stale runner.sh)")

    let ec = ctClient(home: home, label: label, calibre: false)
    T.eq(ec.installedRunnerPA0() ?? "<none>", stale, "PA0 read back as the stale runner.sh")
    T.ok(ec.installedRunnerIsStale(),
         "PA0 present and ≠ helper → STALE ⇒ the CTA must NOT copy (no Calibre road)")
    T.eq(ec.runnerPath(), stale,
         "…and this is the dead path the CTA would otherwise have put on the clipboard")
}

// (CT2) The same stale PA0 with Calibre PRESENT (the `.refreshFailed` road, E8) — the
//       guard is invariant-based, so it fires here too, independent of any outcome.
func test_FDA_CT2_pa0Stale_withCalibre_isStale() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = Fixture.throwawayLabel()
    let stale = ctStaleRunnerPath(home)
    T.ok(UpdateFixture.writePlist(home: home, label: label,
                                  watchDir: "\(home)/Desktop/fb2-to-epub", programArg0: stale),
         "plist written (PA0 = stale runner.sh)")

    let ec = ctClient(home: home, label: label, calibre: true)
    T.ok(ec.installedRunnerIsStale(), "stale PA0 is stale with Calibre present too (both roads)")
    T.ok(!ec.installedRunnerIsHelper(), "…and the refresh gate still reads it as 'not the helper'")
}

// (CT3) CONTROL — plist present but WITHOUT ProgramArguments: PA0 has NO value, so
//       `runnerPath()` returns the CORRECT canonical helper. Copying must WORK. A bare
//       `!installedRunnerIsHelper()` guard would have wrongly blocked this.
func test_FDA_CT3_pa0Absent_notStale_copyWorks_helperPath() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = Fixture.throwawayLabel()
    T.ok(UpdateFixture.writePlist(home: home, label: label,
                                  watchDir: "\(home)/Desktop/fb2-to-epub"),
         "plist written WITHOUT ProgramArguments")

    let ec = ctClient(home: home, label: label, calibre: false)
    T.eq(ec.installedRunnerPA0() ?? "<none>", "<none>", "no ProgramArguments → PA0 is nil (tri-state)")
    T.ok(!ec.installedRunnerIsStale(), "no PA0 value → NOT stale ⇒ copying is allowed")
    T.eq(ec.runnerPath(), ctHelperPath(home), "…and the copied path is the canonical helper")
    T.ok(!ec.installedRunnerIsHelper(),
         "installedRunnerIsHelper() keeps its old meaning here (a refresh IS due) — the two differ on purpose")
}

// (CT4) CONTROL — a BROKEN plist (garbage bytes) and an EMPTY PA0: both are "no usable
//       value" → not stale, fallback path, copying works.
func test_FDA_CT4_brokenOrEmptyPA0_notStale_copyWorks() {
    // (a) unreadable / not a plist at all
    let homeA = Fixture.makeHome(); defer { Fixture.removeHome(homeA) }
    let labelA = Fixture.throwawayLabel()
    let laDir = "\(homeA)/Library/LaunchAgents"
    try? FileManager.default.createDirectory(atPath: laDir, withIntermediateDirectories: true)
    try? "{ not a plist".write(toFile: "\(laDir)/\(labelA).plist", atomically: true, encoding: .utf8)
    let ecA = ctClient(home: homeA, label: labelA, calibre: false)
    T.eq(ecA.installedRunnerPA0() ?? "<none>", "<none>", "broken plist → PA0 nil (plutil fails)")
    T.ok(!ecA.installedRunnerIsStale(), "broken plist → NOT stale ⇒ copying is allowed")
    T.eq(ecA.runnerPath(), ctHelperPath(homeA), "broken plist → canonical helper is copied")

    // (b) ProgramArguments[0] present but EMPTY
    let homeB = Fixture.makeHome(); defer { Fixture.removeHome(homeB) }
    let labelB = Fixture.throwawayLabel()
    T.ok(UpdateFixture.writePlist(home: homeB, label: labelB,
                                  watchDir: "\(homeB)/Desktop/fb2-to-epub", programArg0: ""),
         "plist written with an EMPTY PA0")
    let ecB = ctClient(home: homeB, label: labelB, calibre: false)
    T.eq(ecB.installedRunnerPA0() ?? "<none>", "<none>", "empty PA0 → nil (no usable value)")
    T.ok(!ecB.installedRunnerIsStale(), "empty PA0 → NOT stale ⇒ copying is allowed")
    T.eq(ecB.runnerPath(), ctHelperPath(homeB), "empty PA0 → canonical helper is copied")
}

// (CT5) CONTROL — no plist at all (a machine before the first install): fallback path,
//       copying works, nothing to guard.
func test_FDA_CT5_noPlist_notStale_copyWorks() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let ec = ctClient(home: home, label: Fixture.throwawayLabel(), calibre: false)
    T.eq(ec.installedRunnerPA0() ?? "<none>", "<none>", "no plist → PA0 nil")
    T.ok(!ec.installedRunnerIsStale(), "no plist → NOT stale ⇒ copying is allowed")
    T.eq(ec.runnerPath(), ctHelperPath(home), "no plist → canonical helper is copied")
}

// (CT6) THE LIVE AGENT (PA0 == helper — the human's working install): NOT stale, so the
//       CTA copies exactly as it did before this fix. The behaviour-preservation pin.
func test_FDA_CT6_pa0Helper_notStale_copyUnchanged() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = Fixture.throwawayLabel()
    let helper = ctHelperPath(home)
    T.ok(UpdateFixture.writePlist(home: home, label: label,
                                  watchDir: "\(home)/Desktop/fb2-to-epub", programArg0: helper),
         "plist written (PA0 = helper — the healthy production state)")

    let ec = ctClient(home: home, label: label, calibre: true)
    T.ok(ec.installedRunnerIsHelper(), "PA0 == helper → isHelper (refresh gate: nothing to heal)")
    T.ok(!ec.installedRunnerIsStale(), "PA0 == helper → NOT stale ⇒ the CTA copies as before")
    T.eq(ec.runnerPath(), helper, "…and the copied path is the helper itself")
}

// MARK: - P: router priority (CJM order engine → access → normal)

func test_FDA_P1_engineWins_overFolder() {
    T.eq(StatusRouter.surface(engineOnboardingActive: true, folderAccessActive: true),
         .engineOnboarding, "engine + folder both active → engine card (CJM: engine first)")
    T.eq(StatusRouter.surface(engineOnboardingActive: true, folderAccessActive: false),
         .engineOnboarding, "engine only → engine card")
}

func test_FDA_P2_folderWhenEnginePresent() {
    T.eq(StatusRouter.surface(engineOnboardingActive: false, folderAccessActive: true),
         .folderAccess, "engine present + denied → FDA card")
}

func test_FDA_P3_normalWhenNeither() {
    T.eq(StatusRouter.surface(engineOnboardingActive: false, folderAccessActive: false),
         .normal, "engine present + access ok → normal Status")
}

// MARK: - RC: FolderRecheck.evaluate ts-semantics (injected clocks)

func test_FDA_RC1_notInFlight_isPending() {
    T.eq(FolderRecheck.evaluate(pressedTs: nil, currentTs: "2026-07-22T10:00:00Z", currentAccess: .denied),
         .pending, "pressedTs nil (not in flight) → pending")
}

func test_FDA_RC2_noFreshTs_isPending() {
    // Same ts as pressed → the agent hasn't re-probed yet.
    T.eq(FolderRecheck.evaluate(pressedTs: "2026-07-22T10:00:00Z", currentTs: "2026-07-22T10:00:00Z", currentAccess: .denied),
         .pending, "currentTs == pressedTs → pending (no fresh probe)")
    // No ts at all yet.
    T.eq(FolderRecheck.evaluate(pressedTs: "2026-07-22T10:00:00Z", currentTs: nil, currentAccess: .denied),
         .pending, "currentTs nil → pending")
}

func test_FDA_RC3_freshDenied_isStillDenied() {
    T.eq(FolderRecheck.evaluate(pressedTs: "2026-07-22T10:00:00Z", currentTs: "2026-07-22T10:00:06Z", currentAccess: .denied),
         .stillDenied, "fresh ts + denied → stillDenied")
}

func test_FDA_RC4_freshOk_isCleared() {
    T.eq(FolderRecheck.evaluate(pressedTs: "2026-07-22T10:00:00Z", currentTs: "2026-07-22T10:00:06Z", currentAccess: .ok),
         .cleared, "fresh ts + ok → cleared (card dissolves)")
}

func test_FDA_RC5_freshMissingOrNil_isCleared() {
    T.eq(FolderRecheck.evaluate(pressedTs: "t0", currentTs: "t1", currentAccess: .missing),
         .cleared, "fresh ts + missing → cleared (no FDA card for missing)")
    T.eq(FolderRecheck.evaluate(pressedTs: "t0", currentTs: "t1", currentAccess: nil),
         .cleared, "fresh ts + nil access → cleared")
}

func test_FDA_RC6_emptyPressedTs_oldAgent_anyFreshResolves() {
    // Old agent had no prior ts (pressed = ""); the first probe's ts is fresh (≠ "").
    T.eq(FolderRecheck.evaluate(pressedTs: "", currentTs: "2026-07-22T10:00:06Z", currentAccess: .denied),
         .stillDenied, "pressed empty + any real ts → treated as fresh (resolves)")
}

// MARK: - TD: terminal-recheck dissolve (A1 — a pinned stillDenied/timeout must not
// outlive the live flag). The refresh cycle drives FolderRecheck.terminalRecheckDissolves.

func test_FDA_TD1_terminalPlusLiveOk_dissolves() {
    // The regression from review A1: card pinned terminal, agent flag arrives ok → clear.
    T.eq(FolderRecheck.terminalRecheckDissolves(isTerminal: true, liveAccess: .ok),
         true, "terminal + live ok → dissolve (card resolves to normal Status)")
    T.eq(FolderRecheck.terminalRecheckDissolves(isTerminal: true, liveAccess: .missing),
         true, "terminal + live missing → dissolve (no FDA surface for missing)")
    T.eq(FolderRecheck.terminalRecheckDissolves(isTerminal: true, liveAccess: nil),
         true, "terminal + live nil (flag cleared) → dissolve")
}

func test_FDA_TD2_terminalStillDenied_keeps() {
    // Live flag still denied → keep the richer terminal feedback (stillDenied/timeout).
    T.eq(FolderRecheck.terminalRecheckDissolves(isTerminal: true, liveAccess: .denied),
         false, "terminal + live still denied → keep (do not dissolve)")
}

func test_FDA_TD3_nonTerminal_neverDissolvesHere() {
    // A non-terminal card (.checking or none) is driven by evaluate(), not this path.
    T.eq(FolderRecheck.terminalRecheckDissolves(isTerminal: false, liveAccess: .ok),
         false, "non-terminal + live ok → not this path (evaluate() owns it)")
    T.eq(FolderRecheck.terminalRecheckDissolves(isTerminal: false, liveAccess: .denied),
         false, "non-terminal + live denied → not this path")
}
