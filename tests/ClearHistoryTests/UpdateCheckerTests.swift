// UpdateCheckerTests.swift — regression tests for the v0.2.2 "auto-update"
// feature, compiled into the same headless CLI runner as the "Очистить" suite
// (tests/run-clear-history-tests.sh). Production code is NOT modified.
//
// GROUPS
// ------
//   C-semver  (UpdateChecker.isNewer)          — pure numeric semver compare.
//   D-trust   (UpdateChecker.isTrustedSource)  — https + GitHub-host allowlist.
//   E-refresh (EngineClient.refreshEngineIfBundledChanged) — on-launch engine
//             re-install ONLY when the bundled scripts differ, driven by a
//             throwaway STUB installer (NO real installer.sh / launchctl / agent).
//
//   (The install SHELL SCRIPT — the one UpdateChecker.launchInstaller builds and
//    writes to NSTemporaryDirectory()/fb2-update.sh — is covered separately, in
//    bash, by tests/run-update-install-test.sh.)
//
// ISOLATION (critical)
// --------------------
//   • isNewer / isTrustedSource are pure functions → no IO at all.
//   • The engine-refresh tests use a throwaway HOME (`mktemp -d`) + a throwaway
//     LaunchAgent label + a STUB installer .sh that only records its argv and
//     exits 0/1. They never run packaging/installer.sh, never call launchctl,
//     never touch the real agent / ~/Library/Application Support / ~/Desktop.
//   • FB2_BUNDLED_RES_DIR is set/cleared per test with setenv/unsetenv so the
//     bundled-scripts dir is a sandbox dir and tests don't leak into each other.
//     The ONLY external tool invoked is /usr/bin/plutil (read-only) against a
//     plist we wrote inside the throwaway HOME.
//
// The `T` harness, `Fixture` helpers and the run/print/exit driver live in
// main.swift; this file only adds test funcs that main.swift registers.

import Foundation

// MARK: - Helpers specific to the update suite

enum UpdateFixture {

    /// `{home}/Library/Application Support/fb2-to-epub/bin` — the installed engine
    /// scripts dir EngineClient compares against (derived from `home`, so isolated).
    static func installedBinDir(_ home: String) -> String {
        "\(home)/Library/Application Support/fb2-to-epub/bin"
    }

    /// `{home}/Library/LaunchAgents/<label>.plist`
    static func plistPath(_ home: String, label: String) -> String {
        "\(home)/Library/LaunchAgents/\(label).plist"
    }

    /// `{home}/Library/Application Support/fb2-to-epub/bin/fb2-to-epub-agent` — the
    /// frozen Mach-O helper path the installed plist's ProgramArguments[0] MUST hold
    /// (v1.0.2+). Mirrors production `EngineClient.installedHelperPath` exactly (that
    /// property is not visible to this bare-CLI test target); a drift surfaces as a
    /// failing E2/E6.
    static func helperPath(_ home: String) -> String {
        "\(installedBinDir(home))/fb2-to-epub-agent"
    }

    /// The engine payload filenames EngineClient.refresh compares (must match
    /// EngineClient+Status.engineScriptNames exactly — that constant is private, so
    /// we keep an identical list here; a drift would surface as a failing test).
    /// v1.0.2 adds the Mach-O agent helper (the binary-runner migration trigger).
    static let engineScriptNames = [
        "fb2-to-epub-agent",
        "fb2-to-epub-runner.sh",
        "fb2-to-epub-watcher.sh",
        "fb2-to-epub-cover-finder.py",
    ]

    /// Write all three engine scripts into `dir` with the given body. Returns dir.
    @discardableResult
    static func writeEngineScripts(into dir: String, body: String) -> String {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in engineScriptNames {
            try? body.write(toFile: "\(dir)/\(name)", atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// Write a minimal-but-valid LaunchAgent plist carrying EnvironmentVariables.
    /// WATCH_DIR = `watchDir`, so the production `readWatchDir()` (plutil -extract)
    /// reads it back. Lands inside the throwaway HOME.
    ///
    /// `programArg0` (fix #1): when non-nil, the plist also carries
    /// `ProgramArguments = [programArg0]`, so the production PA0 check
    /// (`installedRunnerIsHelper`) reads it back — pass the helper path for the
    /// steady state, or the runner.sh path to simulate the stale-plist bug. nil
    /// (E1/E3/E4/E5) leaves ProgramArguments absent, as before.
    @discardableResult
    static func writePlist(home: String, label: String, watchDir: String,
                           programArg0: String? = nil) -> Bool {
        let path = plistPath(home, label: label)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Build via PropertyListSerialization so arbitrary paths (spaces/unicode)
        // are encoded safely — same spirit as installer.sh using plutil, not sed.
        var plist: [String: Any] = [
            "Label": label,
            "EnvironmentVariables": ["WATCH_DIR": watchDir],
        ]
        if let pa0 = programArg0 { plist["ProgramArguments"] = [pa0] }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    /// Read `ProgramArguments[0]` back from the throwaway plist via the SAME tool the
    /// production code uses (`/usr/bin/plutil -extract … raw`). Used by E6 to prove
    /// the self-heal ended with PA0 == helper. nil = absent/unreadable.
    static func readPA0(home: String, label: String) -> String? {
        let path = plistPath(home, label: label)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        p.arguments = ["-extract", "ProgramArguments.0", "raw", "-o", "-", path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// A throwaway STUB installer that records every arg it was handed (argv,
    /// newline-separated) into `record` and exits `exitCode`. Mirrors how
    /// `runInstaller` invokes `/bin/bash <installerPath> <watchDir>` — so $1 is the
    /// WATCH_DIR. NO launchctl, NO real installer.sh, NO agent. Returns (stub, record).
    ///
    /// `repointPlist` (fix #1, E6): when set to `(plistPath, helperPath)` the stub
    /// ALSO flips `ProgramArguments[0]` of that plist to the helper via `plutil` —
    /// faithfully mimicking the ONE thing gen_plist does to PA0 (it unconditionally
    /// re-bakes it to the helper). Keeps isolation (no launchctl, no real
    /// installer.sh); lets a Swift unit prove the self-heal closes the loop end-to-
    /// end at the plist level. The full plist rebuild is covered in bash by
    /// tests/run-agent-helper-tests.sh (section C9).
    static func writeStubInstaller(home: String, exitCode: Int = 0,
                                   repointPlist: (path: String, helper: String)? = nil)
        -> (stub: String, record: String) {
        let stub = "\(home)/stub-installer.sh"
        let record = "\(home)/installer-args.txt"
        // Append each positional arg on its own line; $1 (WATCH_DIR) is line 1.
        var script = """
        #!/bin/bash
        : > "\(record)"
        for a in "$@"; do printf '%s\\n' "$a" >> "\(record)"; done
        """
        if let rp = repointPlist {
            // The plist already exists with PA0=runner.sh (E6 seeds it), so a
            // single -replace on the existing index flips it to the helper.
            script += "\n/usr/bin/plutil -replace ProgramArguments.0 -string \"\(rp.helper)\" \"\(rp.path)\"\n"
        }
        script += "\nexit \(exitCode)\n"
        try? script.write(toFile: stub, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
        return (stub, record)
    }

    /// Read the WATCH_DIR ($1) the stub captured, or nil if the stub never ran.
    static func capturedWatchDir(_ record: String) -> String? {
        guard let raw = try? String(contentsOfFile: record, encoding: .utf8) else { return nil }
        return raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
    }

    /// True iff the stub installer ran (its record file exists).
    static func stubRan(_ record: String) -> Bool {
        FileManager.default.fileExists(atPath: record)
    }

    /// Build an EngineClient bound to an isolated HOME + throwaway label + the STUB
    /// installer path.
    ///
    /// `ebookConvert` (v1.0.3, fix #1): the PA0 self-heal branch is now GATED on
    /// `calibreInstalled()`. Passing an EXECUTABLE stub path makes `calibreInstalled()`
    /// deterministically TRUE (the override path only checks the file itself); passing a
    /// NON-executable/absent path makes it deterministically FALSE — regardless of
    /// whether the host machine happens to have Calibre. Left nil → real locator
    /// (irrelevant to E1–E5, which either short-circuit on a byte diff or never reach
    /// the gate). The byte-diff branch never probes Calibre either way.
    static func client(home: String, label: String, installer: String,
                       ebookConvert: String? = nil) -> EngineClient {
        EngineClient(label: label, home: home, installerPath: installer,
                     ebookConvertPath: ebookConvert)
    }

    /// Write a throwaway EXECUTABLE stub at `<home>/fake-ebook-convert` and return its
    /// path, so `calibreInstalled()` (via the ebookConvert override) reads TRUE without
    /// a real Calibre on the machine. The file is never executed by refresh — only
    /// `isExecutableRegularFile` stats it — so a trivial body is enough.
    static func writeCalibreStub(home: String) -> String {
        let path = "\(home)/fake-ebook-convert"
        try? "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// A deterministically-ABSENT ebook-convert path (nothing at it) → `calibreInstalled()`
    /// reads FALSE via the override, on any host. Used by the no-loop test (E7).
    static func absentCalibrePath(home: String) -> String {
        "\(home)/no-such-ebook-convert"
    }

    /// Run `body` with FB2_BUNDLED_RES_DIR pointed at `dir`, then restore the prior
    /// value. Keeps the process-global env change scoped to a single test.
    static func withBundledResDir(_ dir: String, _ body: () -> Void) {
        let key = "FB2_BUNDLED_RES_DIR"
        let prior = ProcessInfo.processInfo.environment[key]
        setenv(key, dir, 1)
        body()
        if let prior = prior { setenv(key, prior, 1) } else { unsetenv(key) }
    }
}

// ===========================================================================
// MARK: - Group C — UpdateChecker.isNewer (numeric semver compare)
// ===========================================================================
//
// WHAT IS UNDER TEST (app/UpdateChecker.swift):
//   static func isNewer(_ latest: String, than current: String) -> Bool
//   Split on ".", compare component-by-component as Int (missing trailing -> 0,
//   non-numeric -> 0). true iff latest strictly > current. Pure → deterministic.

func test_C_isNewer_trueCases() {
    T.ok(UpdateChecker.isNewer("0.2.2",  than: "0.2.1"), "0.2.2 > 0.2.1")
    T.ok(UpdateChecker.isNewer("0.10.0", than: "0.9.9"), "0.10.0 > 0.9.9 (numeric, not lexicographic)")
    T.ok(UpdateChecker.isNewer("1.0",    than: "0.9.9"), "1.0 > 0.9.9 (shorter but larger major)")
    T.ok(UpdateChecker.isNewer("0.3.0",  than: "0.2.9"), "0.3.0 > 0.2.9")
}

func test_C_isNewer_falseCases() {
    T.ok(!UpdateChecker.isNewer("0.2.1", than: "0.2.1"), "0.2.1 == 0.2.1 → not newer")
    T.ok(!UpdateChecker.isNewer("0.2.1", than: "0.2.2"), "0.2.1 < 0.2.2 → not newer")
    T.ok(!UpdateChecker.isNewer("0.9.9", than: "1.0"),   "0.9.9 < 1.0 → not newer")
}

func test_C_isNewer_edgeCases_doNotCrash() {
    // Empty / odd / differing-length operands must not crash and must give a sane
    // boolean (the contract: missing -> 0, non-numeric -> 0).
    T.ok(!UpdateChecker.isNewer("", than: ""),        "empty vs empty → not newer (no crash)")
    T.ok(!UpdateChecker.isNewer("", than: "0.0.1"),   "empty vs 0.0.1 → not newer")
    T.ok(UpdateChecker.isNewer("0.0.1", than: ""),    "0.0.1 vs empty → newer")
    T.ok(!UpdateChecker.isNewer("1.0.0", than: "1"),  "1.0.0 vs 1 → equal (trailing zeros) → not newer")
    T.ok(!UpdateChecker.isNewer("1", than: "1.0.0"),  "1 vs 1.0.0 → equal → not newer")
    T.ok(!UpdateChecker.isNewer("1.x.0", than: "1.0.0"), "non-numeric component degrades to 0 (no crash)")
    T.ok(UpdateChecker.isNewer("2.0.0", than: "1.foo.bar"), "2.0.0 > 1.* with junk components (no crash)")
    T.ok(!UpdateChecker.isNewer("...", than: "..."),  "all-dots vs all-dots → not newer (no crash)")
}

// ===========================================================================
// MARK: - Group D — UpdateChecker.isTrustedSource (https + GitHub host)
// ===========================================================================
//
// WHAT IS UNDER TEST (app/UpdateChecker.swift):
//   static func isTrustedSource(_ url: URL) -> Bool
//   true iff scheme == https AND host ∈ {github.com, objects.githubusercontent.com}
//   or host ends with ".githubusercontent.com". Blocks http downgrade + host-swap.
//   isTrustedSource is `static` (NOT private) → directly reachable from the test.

func test_D_isTrustedSource_trusted() {
    let urls = [
        "https://github.com/ArrivaRUS/fb2-to-epub/releases/download/v0.2.3/fb2-to-epub.dmg",
        "https://objects.githubusercontent.com/github-production-release-asset/x",
        "https://release-assets.githubusercontent.com/x.dmg", // any *.githubusercontent.com
    ]
    for s in urls {
        guard let u = URL(string: s) else { T.ok(false, "URL parses: \(s)"); continue }
        T.ok(UpdateChecker.isTrustedSource(u), "trusted: \(s)")
    }
}

func test_D_isTrustedSource_untrusted() {
    // http downgrade, foreign host, and a look-alike host that merely CONTAINS
    // github.com as a prefix (github.com.evil.com) must all be rejected.
    let urls = [
        "http://github.com/ArrivaRUS/x.dmg",        // not https
        "https://evil.com/x.dmg",                    // foreign host
        "https://github.com.evil.com/x",             // look-alike (suffix attack)
        "https://notgithub.com/x.dmg",               // unrelated
        "https://evilgithubusercontent.com/x",       // NOT a *.githubusercontent.com subdomain
        "ftp://github.com/x.dmg",                     // wrong scheme entirely
    ]
    for s in urls {
        guard let u = URL(string: s) else { T.ok(false, "URL parses: \(s)"); continue }
        T.ok(!UpdateChecker.isTrustedSource(u), "untrusted rejected: \(s)")
    }
}

// ===========================================================================
// MARK: - Group E — refreshEngineIfBundledChanged (STUB installer, NO launchctl)
// ===========================================================================
//
// WHAT IS UNDER TEST (app/EngineClient+Status.swift):
//   func refreshEngineIfBundledChanged(extraEnv:) -> EngineRefreshOutcome
//     • no plist                              → .skippedNoPlist (installer NOT run)
//     • plist + bundled == installed + PA0=helper → .upToDate   (installer NOT run)
//     • plist + any script differs            → .refreshed(dir) (installer run ONCE,
//                                          WATCH_DIR == value read from the plist)
//     • plist + installed file missing        → .refreshed      (must be laid down)
//     • plist + differs + installer rc≠0      → .refreshFailed   (no crash)
//     • plist + bundled == installed + Calibre + PA0≠helper → .refreshed  (fix #1
//                                          self-heal: a byte match no longer implies
//                                          up-to-date; a stale ProgramArguments[0]
//                                          forces a refresh — E6)
//     • plist + bundled == installed + PA0≠helper + NO Calibre → .upToDate (fix #1
//                                          LOOP-GUARD: the self-heal can't succeed
//                                          without an engine, so it is NOT attempted
//                                          every cold start — E7)
//     • plist + bundled == installed + Calibre + PA0≠helper + rc≠0 → .refreshFailed,
//                                          PA0 still stale (honest; retried next launch
//                                          — E8, the dead-path signal fix #2 relies on)
//   bundledResourceDir comes from FB2_BUNDLED_RES_DIR in tests. The installer is a
//   throwaway STUB recording its argv — NO real installer.sh / launchctl / agent.
//   Calibre presence is faked deterministically via the ebookConvert override (an
//   executable stub → present; an absent path → absent), never the host's real engine.

// (E1) No plist at all → .skippedNoPlist; the stub installer is NEVER invoked.
func test_E1_noPlist_skips() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = Fixture.throwawayLabel()
    let (stub, record) = UpdateFixture.writeStubInstaller(home: home)

    // Bundled dir exists and even differs — but with no plist we must bail first.
    let bundled = UpdateFixture.writeEngineScripts(into: "\(home)/bundled", body: "v=NEW\n")
    UpdateFixture.writeEngineScripts(into: UpdateFixture.installedBinDir(home), body: "v=OLD\n")

    let ec = UpdateFixture.client(home: home, label: label, installer: stub)
    UpdateFixture.withBundledResDir(bundled) {
        let outcome = ec.refreshEngineIfBundledChanged()
        T.eq(outcome, .skippedNoPlist, "no plist → .skippedNoPlist")
    }
    T.ok(!UpdateFixture.stubRan(record), "installer NOT invoked when there is no plist")
}

// (E2) plist present + bundled == installed (byte-identical) + PA0 ALREADY the
//      helper → .upToDate; no install. This is the steady-state app-only-update
//      path (fix #1: a byte match alone is NO LONGER enough — the plist's PA0 must
//      also already be the helper for us to leave the agent untouched).
//
//      v1.0.3 (re-review nit): Calibre is faked PRESENT via the ebookConvert stub. The
//      production gate is `calibreInstalled() && !installedRunnerIsHelper()` — on a host
//      WITHOUT Calibre the `&&` short-circuits and the PA0 check is never even called, so
//      this test stayed green even with `installedRunnerIsHelper()` broken. With the stub
//      the PA0 branch is always REACHED, so E2's teeth no longer depend on the machine.
func test_E2_identical_andPA0Helper_upToDate() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = Fixture.throwawayLabel()
    let (stub, record) = UpdateFixture.writeStubInstaller(home: home)
    let watch = "\(home)/Desktop/fb2-to-epub"
    // PA0 already points at the helper → nothing to heal.
    T.ok(UpdateFixture.writePlist(home: home, label: label, watchDir: watch,
                                  programArg0: UpdateFixture.helperPath(home)),
         "plist written (PA0 = helper)")

    let body = "#!/bin/sh\n# identical engine v0.2.2\n"
    let bundled = UpdateFixture.writeEngineScripts(into: "\(home)/bundled", body: body)
    UpdateFixture.writeEngineScripts(into: UpdateFixture.installedBinDir(home), body: body)

    // Calibre PRESENT (stub) → the gate does NOT short-circuit; the PA0 read really runs.
    let calibre = UpdateFixture.writeCalibreStub(home: home)
    let ec = UpdateFixture.client(home: home, label: label, installer: stub, ebookConvert: calibre)
    UpdateFixture.withBundledResDir(bundled) {
        let outcome = ec.refreshEngineIfBundledChanged()
        T.eq(outcome, .upToDate, "identical scripts + PA0=helper → .upToDate (touches NOTHING)")
    }
    T.ok(!UpdateFixture.stubRan(record), "installer NOT invoked when scripts match AND PA0 is the helper")
}

// (E3) plist + ONE script differs → .refreshed; installer ran ONCE with the
//      plist's WATCH_DIR (incl. spaces) as $1.
func test_E3_oneDiffers_refreshed_passesWatchDir() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = Fixture.throwawayLabel()
    let (stub, record) = UpdateFixture.writeStubInstaller(home: home, exitCode: 0)
    let watch = "\(home)/Desktop/My Books фб2"   // spaces + unicode: argv safety
    T.ok(UpdateFixture.writePlist(home: home, label: label, watchDir: watch), "plist written")

    // Installed = all-OLD; bundled = OLD for two, NEW for one (watcher.sh).
    let installedDir = UpdateFixture.installedBinDir(home)
    UpdateFixture.writeEngineScripts(into: installedDir, body: "OLD\n")
    let bundled = "\(home)/bundled"
    try? FileManager.default.createDirectory(atPath: bundled, withIntermediateDirectories: true)
    try? "OLD\n".write(toFile: "\(bundled)/fb2-to-epub-runner.sh", atomically: true, encoding: .utf8)
    try? "NEW\n".write(toFile: "\(bundled)/fb2-to-epub-watcher.sh", atomically: true, encoding: .utf8)
    try? "OLD\n".write(toFile: "\(bundled)/fb2-to-epub-cover-finder.py", atomically: true, encoding: .utf8)

    let ec = UpdateFixture.client(home: home, label: label, installer: stub)
    UpdateFixture.withBundledResDir(bundled) {
        let outcome = ec.refreshEngineIfBundledChanged()
        T.eq(outcome, .refreshed(watchDir: watch), "one script differs → .refreshed(plist WATCH_DIR)")
    }
    T.ok(UpdateFixture.stubRan(record), "installer WAS invoked exactly once")
    T.eq(UpdateFixture.capturedWatchDir(record) ?? "<none>", watch,
         "installer received the plist's WATCH_DIR as \\$1 (spaces/unicode intact)")
}

// (E4) plist + an installed script is MISSING (bundled present) → .refreshed
//      (a missing installed copy counts as "different" → engine must be laid down).
func test_E4_installedMissing_refreshed() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = Fixture.throwawayLabel()
    let (stub, record) = UpdateFixture.writeStubInstaller(home: home, exitCode: 0)
    let watch = "\(home)/Desktop/fb2-to-epub"
    T.ok(UpdateFixture.writePlist(home: home, label: label, watchDir: watch), "plist written")

    // Bundled has all three; installed dir has only TWO (cover-finder.py absent).
    let bundled = UpdateFixture.writeEngineScripts(into: "\(home)/bundled", body: "SAME\n")
    let installedDir = UpdateFixture.installedBinDir(home)
    try? FileManager.default.createDirectory(atPath: installedDir, withIntermediateDirectories: true)
    try? "SAME\n".write(toFile: "\(installedDir)/fb2-to-epub-runner.sh", atomically: true, encoding: .utf8)
    try? "SAME\n".write(toFile: "\(installedDir)/fb2-to-epub-watcher.sh", atomically: true, encoding: .utf8)
    // cover-finder.py intentionally NOT written → "installed missing" → differs.

    let ec = UpdateFixture.client(home: home, label: label, installer: stub)
    UpdateFixture.withBundledResDir(bundled) {
        let outcome = ec.refreshEngineIfBundledChanged()
        T.eq(outcome, .refreshed(watchDir: watch), "installed script missing → .refreshed")
    }
    T.ok(UpdateFixture.stubRan(record), "installer invoked to lay down the missing engine")
}

// (E5) plist + differs + installer rc != 0 → .refreshFailed, no crash, agent
//      left as-is (the next launch retries).
func test_E5_installerFails_refreshFailed() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = Fixture.throwawayLabel()
    let (stub, record) = UpdateFixture.writeStubInstaller(home: home, exitCode: 3) // non-zero
    let watch = "\(home)/Desktop/fb2-to-epub"
    T.ok(UpdateFixture.writePlist(home: home, label: label, watchDir: watch), "plist written")

    UpdateFixture.writeEngineScripts(into: UpdateFixture.installedBinDir(home), body: "OLD\n")
    let bundled = UpdateFixture.writeEngineScripts(into: "\(home)/bundled", body: "NEW\n")

    let ec = UpdateFixture.client(home: home, label: label, installer: stub)
    UpdateFixture.withBundledResDir(bundled) {
        let outcome = ec.refreshEngineIfBundledChanged()
        T.eq(outcome, .refreshFailed, "installer rc != 0 → .refreshFailed (swallowed, not fatal)")
    }
    T.ok(UpdateFixture.stubRan(record), "installer WAS reached (it just failed)")
}

// (E6) THE FIX-1 SELF-HEAL: plist points at the dead runner.sh, but the bundled
//      engine bytes ALREADY MATCH the installed copy (the v1.0.2 tail: a pre-laid
//      helper artifact, OR an installer crash window that left the plist stale).
//      Pre-fix this returned .upToDate → the stale PA0 was NEVER healed. Now the
//      direct PA0 check forces a refresh; the (stub) installer re-points the plist,
//      so afterwards PA0 == helper. Proves BOTH the decision (.refreshed) and the
//      effect (PA0 healed).
//      v1.0.3 (fix #1): the PA0 branch is GATED on `calibreInstalled()`, so this test
//      now supplies an executable ebook-convert stub — the self-heal only makes sense
//      when an engine is present (the loop-guard is proven separately in E7).
func test_E6_bytesMatchButPA0Stale_refreshesAndHealsPA0() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = Fixture.throwawayLabel()
    let watch = "\(home)/Desktop/fb2-to-epub"
    let helper = UpdateFixture.helperPath(home)
    let staleRunner = "\(UpdateFixture.installedBinDir(home))/fb2-to-epub-runner.sh"

    // Seed the plist on the DEAD runner.sh (the bug state) …
    T.ok(UpdateFixture.writePlist(home: home, label: label, watchDir: watch,
                                  programArg0: staleRunner),
         "plist written (PA0 = stale runner.sh)")
    T.eq(UpdateFixture.readPA0(home: home, label: label) ?? "<none>", staleRunner,
         "precondition: PA0 is the stale runner.sh")

    // … while the engine BYTES are identical (no byte diff → pre-fix .upToDate).
    let body = "#!/bin/sh\n# identical engine\n"
    let bundled = UpdateFixture.writeEngineScripts(into: "\(home)/bundled", body: body)
    UpdateFixture.writeEngineScripts(into: UpdateFixture.installedBinDir(home), body: body)

    // Stub installer that (like gen_plist) re-points PA0 to the helper.
    let plist = UpdateFixture.plistPath(home, label: label)
    let (stub, record) = UpdateFixture.writeStubInstaller(
        home: home, exitCode: 0, repointPlist: (path: plist, helper: helper))

    // fix #1: Calibre present → the gated PA0 branch is allowed to fire.
    let calibre = UpdateFixture.writeCalibreStub(home: home)
    let ec = UpdateFixture.client(home: home, label: label, installer: stub, ebookConvert: calibre)
    UpdateFixture.withBundledResDir(bundled) {
        let outcome = ec.refreshEngineIfBundledChanged()
        T.eq(outcome, .refreshed(watchDir: watch),
             "bytes match, Calibre present, PA0 stale → .refreshed (self-heal runs the installer)")
    }
    T.ok(UpdateFixture.stubRan(record), "installer WAS invoked to heal the stale plist")
    T.eq(UpdateFixture.readPA0(home: home, label: label) ?? "<none>", helper,
         "after self-heal PA0 == helper (stale target repaired)")
}

// (E7) THE FIX-1 LOOP-GUARD: EXACTLY E6's stale-PA0 state, but Calibre is ABSENT.
//      installer.sh would exit non-zero BEFORE it ever re-points the plist, so a
//      self-heal here can never succeed — pre-guard it would re-run the installer
//      synchronously on EVERY cold start (a permanent boot loop) and still leave PA0
//      stale. With the `calibreInstalled()` gate the branch is skipped: .upToDate and
//      the installer is NOT invoked. PA0 stays stale on purpose — the next launch heals
//      it once the engine is back (documented by E6). This is the anti-loop contract.
func test_E7_bytesMatchPA0StaleNoCalibre_noLoop_upToDate() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = Fixture.throwawayLabel()
    let watch = "\(home)/Desktop/fb2-to-epub"
    let staleRunner = "\(UpdateFixture.installedBinDir(home))/fb2-to-epub-runner.sh"

    T.ok(UpdateFixture.writePlist(home: home, label: label, watchDir: watch,
                                  programArg0: staleRunner),
         "plist written (PA0 = stale runner.sh)")

    let body = "#!/bin/sh\n# identical engine\n"
    let bundled = UpdateFixture.writeEngineScripts(into: "\(home)/bundled", body: body)
    UpdateFixture.writeEngineScripts(into: UpdateFixture.installedBinDir(home), body: body)

    let (stub, record) = UpdateFixture.writeStubInstaller(home: home, exitCode: 0)

    // fix #1: Calibre ABSENT (override points at nothing) → the gate blocks the branch.
    let absent = UpdateFixture.absentCalibrePath(home: home)
    let ec = UpdateFixture.client(home: home, label: label, installer: stub, ebookConvert: absent)
    UpdateFixture.withBundledResDir(bundled) {
        let outcome = ec.refreshEngineIfBundledChanged()
        T.eq(outcome, .upToDate,
             "bytes match, PA0 stale, NO Calibre → .upToDate (no installer loop)")
    }
    T.ok(!UpdateFixture.stubRan(record),
         "installer NOT invoked when Calibre is absent (loop-guard holds)")
    T.eq(UpdateFixture.readPA0(home: home, label: label) ?? "<none>", staleRunner,
         "PA0 stays stale (honest): the next launch heals it once the engine returns")
}

// (E8) PA0 stale + Calibre PRESENT + installer rc≠0 → .refreshFailed, and PA0 is STILL
//      stale afterwards (the failed installer never re-pointed it). Proves the honest
//      failure path the FDA CTA relies on (fix #2): a refreshFailed with a still-stale
//      PA0 is exactly the "dead path, don't copy" signal. The next launch retries.
func test_E8_bytesMatchPA0StaleCalibrePresent_installerFails_refreshFailed_PA0StillStale() {
    let home = Fixture.makeHome(); defer { Fixture.removeHome(home) }
    let label = Fixture.throwawayLabel()
    let watch = "\(home)/Desktop/fb2-to-epub"
    let staleRunner = "\(UpdateFixture.installedBinDir(home))/fb2-to-epub-runner.sh"

    T.ok(UpdateFixture.writePlist(home: home, label: label, watchDir: watch,
                                  programArg0: staleRunner),
         "plist written (PA0 = stale runner.sh)")

    let body = "#!/bin/sh\n# identical engine\n"
    let bundled = UpdateFixture.writeEngineScripts(into: "\(home)/bundled", body: body)
    UpdateFixture.writeEngineScripts(into: UpdateFixture.installedBinDir(home), body: body)

    // Installer FAILS (rc≠0) and does NOT repoint the plist (no repointPlist arg).
    let (stub, record) = UpdateFixture.writeStubInstaller(home: home, exitCode: 3)

    let calibre = UpdateFixture.writeCalibreStub(home: home)
    let ec = UpdateFixture.client(home: home, label: label, installer: stub, ebookConvert: calibre)
    UpdateFixture.withBundledResDir(bundled) {
        let outcome = ec.refreshEngineIfBundledChanged()
        T.eq(outcome, .refreshFailed,
             "bytes match, Calibre present, PA0 stale, installer rc≠0 → .refreshFailed")
    }
    T.ok(UpdateFixture.stubRan(record), "installer WAS reached (Calibre present) but failed")
    T.eq(UpdateFixture.readPA0(home: home, label: label) ?? "<none>", staleRunner,
         "PA0 STILL stale after a failed refresh (the dead-path signal for fix #2)")
}
