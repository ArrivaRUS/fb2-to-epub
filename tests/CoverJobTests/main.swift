// main.swift — regression tests for the cover-JOB write-layer (Фича 1 + Фича 2
// плумбинг) in app/EngineClient+Status.swift.
//
// WHAT IS UNDER TEST
// ------------------
// The app writes cover-decision jobs into covers/jobs/<id>.json for the agent to
// apply. This suite verifies the M2 additions:
//   • requestCover(.apply, editedTitle:, editedAuthor:)  — adds edited_* fields
//     ONLY when the value is non-nil AND non-empty (trimmed); omits them otherwise
//     (back-compat: old jobs have no such fields).
//   • requestApplyGenerated(pngPath:, editedTitle:, editedAuthor:) — same, plus
//     action="apply_generated" + png.
//   • requestConfirmAuto(editedTitle:, editedAuthor:) — NEW: writes
//     action="apply_confirm" (meta-only; the auto cover is already embedded), with
//     the same optional edited_* fields.
// It also checks the injection-safety property at the transport boundary: quotes /
// $() / backticks in title/author survive VERBATIM in the JSON value (the agent
// consumes them via base64+argv, never a shell) — the string is not mangled here.
//
// ISOLATION (critical)
// --------------------
// Every test points FB2_COVERS_DIR at a throwaway `mktemp -d` and sets
// FB2_SKIP_KICKSTART=1, so:
//   - jobs are written into the temp dir, never the real
//     ~/Library/Application Support/fb2-to-epub/covers;
//   - the kickstart safety-net is skipped, so NO launchctl / real agent is touched.
// EngineClient also gets a throwaway HOME + label. Pure file IO -> deterministic.
//
// Compiled (via tests/run-cover-job-tests.sh) together with the REAL production
// sources EngineClient.swift / EngineClient+Status.swift / StateModel.swift, plus
// Stubs.swift (inert CoverQueueStore so the engine compiles without SwiftUI).
// Production code is NOT modified.

import Foundation

// MARK: - Tiny assertion harness (TAP-style, no XCTest dependency)

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
    /// A throwaway label that can NEVER collide with the production agent.
    static func throwawayLabel() -> String {
        "com.example.fb2toepub.test.\(UUID().uuidString.prefix(8))"
    }

    /// installer.sh path (the constructor wants one; the job write-layer NEVER
    /// invokes the installer, so this is only to honor the init contract).
    static let installerPath: String = {
        let here = URL(fileURLWithPath: #filePath)            // .../tests/CoverJobTests/main.swift
            .deletingLastPathComponent()                      // .../tests/CoverJobTests
            .deletingLastPathComponent()                      // .../tests
            .deletingLastPathComponent()                      // repo root
        return here.appendingPathComponent("packaging/installer.sh").path
    }()

    /// A fresh isolated HOME for one test. Caller must remove it.
    static func makeHome() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fb2-coverjob-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A fresh isolated covers dir (the FB2_COVERS_DIR override target).
    static func makeCoversDir() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("fb2-coverjob-covers-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func client(home: String) -> EngineClient {
        EngineClient(label: throwawayLabel(), home: home, installerPath: installerPath)
    }

    /// The jobs dir under a covers dir.
    static func jobsDir(_ coversDir: String) -> String { "\(coversDir)/jobs" }

    /// Every published job file (.json, excluding any leftover .tmp) in the jobs dir.
    static func jobFiles(_ coversDir: String) -> [String] {
        let dir = jobsDir(coversDir)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".tmp") }.sorted()
    }

    /// Decode THE single job in the jobs dir as a JSON object. Fails the current
    /// test (via a nil return the caller asserts on) if there isn't exactly one.
    static func soleJob(_ coversDir: String) -> [String: Any]? {
        let files = jobFiles(coversDir)
        guard files.count == 1 else { return nil }
        let path = "\(jobsDir(coversDir))/\(files[0])"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    static func soleJobName(_ coversDir: String) -> String {
        jobFiles(coversDir).first ?? "<none>"
    }
}

/// Run `body` with FB2_COVERS_DIR + FB2_SKIP_KICKSTART set for the duration, then
/// restore the previous environment. Keeps every job inside the temp dir and never
/// nudges the real agent.
func withIsolatedEnv(coversDir: String, _ body: () -> Void) {
    let priorCovers = getenv("FB2_COVERS_DIR").map { String(cString: $0) }
    let priorSkip = getenv("FB2_SKIP_KICKSTART").map { String(cString: $0) }
    setenv("FB2_COVERS_DIR", coversDir, 1)
    setenv("FB2_SKIP_KICKSTART", "1", 1)
    defer {
        if let p = priorCovers { setenv("FB2_COVERS_DIR", p, 1) } else { unsetenv("FB2_COVERS_DIR") }
        if let p = priorSkip { setenv("FB2_SKIP_KICKSTART", p, 1) } else { unsetenv("FB2_SKIP_KICKSTART") }
    }
    body()
}

// MARK: - requestCover (apply) + edited_* fields

// (1) apply with edited title+author -> job carries chosen id + both edited fields.
func test_apply_withEdited_writesFields() {
    let home = Fixture.makeHome(); defer { Fixture.remove(home) }
    let covers = Fixture.makeCoversDir(); defer { Fixture.remove(covers) }

    withIsolatedEnv(coversDir: covers) {
        let ok = Fixture.client(home: home).requestCover(
            bookId: "book1", decision: .apply(candidateId: "book1-2"),
            editedTitle: "Новое название", editedAuthor: "Лев Толстой")
        T.ok(ok, "requestCover returned true")
    }

    guard let job = Fixture.soleJob(covers) else {
        T.ok(false, "exactly one job written & decodable"); return
    }
    T.eq(job["book_id"] as? String ?? "", "book1", "book_id present")
    T.eq(job["chosen_candidate_id"] as? String ?? "", "book1-2", "chosen_candidate_id present")
    T.eq(job["edited_title"] as? String ?? "", "Новое название", "edited_title present")
    T.eq(job["edited_author"] as? String ?? "", "Лев Толстой", "edited_author present")
    T.ok(job["ts"] as? String != nil, "ts present")
}

// (2) apply with NO edited -> back-compat: no edited_* keys at all.
func test_apply_noEdited_omitsFields() {
    let home = Fixture.makeHome(); defer { Fixture.remove(home) }
    let covers = Fixture.makeCoversDir(); defer { Fixture.remove(covers) }

    withIsolatedEnv(coversDir: covers) {
        _ = Fixture.client(home: home).requestCover(
            bookId: "book2", decision: .apply(candidateId: "book2-1"))
    }

    guard let job = Fixture.soleJob(covers) else {
        T.ok(false, "exactly one job written & decodable"); return
    }
    T.eq(job["chosen_candidate_id"] as? String ?? "", "book2-1", "chosen_candidate_id present")
    T.ok(job["edited_title"] == nil, "edited_title absent when not provided")
    T.ok(job["edited_author"] == nil, "edited_author absent when not provided")
}

// (3) blank / whitespace-only edited values -> omitted (trim -> empty -> skip).
func test_apply_blankEdited_omitsFields() {
    let home = Fixture.makeHome(); defer { Fixture.remove(home) }
    let covers = Fixture.makeCoversDir(); defer { Fixture.remove(covers) }

    withIsolatedEnv(coversDir: covers) {
        _ = Fixture.client(home: home).requestCover(
            bookId: "book3", decision: .apply(candidateId: "book3-1"),
            editedTitle: "   ", editedAuthor: "\t\n")
    }

    guard let job = Fixture.soleJob(covers) else {
        T.ok(false, "exactly one job written & decodable"); return
    }
    T.ok(job["edited_title"] == nil, "blank edited_title omitted")
    T.ok(job["edited_author"] == nil, "whitespace edited_author omitted")
}

// (4) only ONE of the two edited fields set -> only that one is written.
func test_apply_partialEdited_writesOnlyProvided() {
    let home = Fixture.makeHome(); defer { Fixture.remove(home) }
    let covers = Fixture.makeCoversDir(); defer { Fixture.remove(covers) }

    withIsolatedEnv(coversDir: covers) {
        _ = Fixture.client(home: home).requestCover(
            bookId: "book4", decision: .apply(candidateId: "book4-1"),
            editedTitle: "Только название", editedAuthor: nil)
    }

    guard let job = Fixture.soleJob(covers) else {
        T.ok(false, "exactly one job written & decodable"); return
    }
    T.eq(job["edited_title"] as? String ?? "", "Только название", "edited_title present")
    T.ok(job["edited_author"] == nil, "edited_author absent (was nil)")
}

// (5) edited values are TRIMMED before writing (leading/trailing whitespace gone).
func test_apply_editedIsTrimmed() {
    let home = Fixture.makeHome(); defer { Fixture.remove(home) }
    let covers = Fixture.makeCoversDir(); defer { Fixture.remove(covers) }

    withIsolatedEnv(coversDir: covers) {
        _ = Fixture.client(home: home).requestCover(
            bookId: "book5", decision: .apply(candidateId: "book5-1"),
            editedTitle: "  Война и мир  ", editedAuthor: " Толстой ")
    }

    guard let job = Fixture.soleJob(covers) else {
        T.ok(false, "exactly one job written & decodable"); return
    }
    T.eq(job["edited_title"] as? String ?? "", "Война и мир", "edited_title trimmed")
    T.eq(job["edited_author"] as? String ?? "", "Толстой", "edited_author trimmed")
}

// MARK: - requestApplyGenerated + edited_*

// (6) apply_generated with edited -> action + png + both edited fields.
func test_applyGenerated_withEdited_writesFields() {
    let home = Fixture.makeHome(); defer { Fixture.remove(home) }
    let covers = Fixture.makeCoversDir(); defer { Fixture.remove(covers) }

    withIsolatedEnv(coversDir: covers) {
        let ok = Fixture.client(home: home).requestApplyGenerated(
            bookId: "gbook", pngPath: "/tmp/whatever/gbook.png",
            editedTitle: "Сген. название", editedAuthor: "Автор Икс")
        T.ok(ok, "requestApplyGenerated returned true")
    }

    guard let job = Fixture.soleJob(covers) else {
        T.ok(false, "exactly one job written & decodable"); return
    }
    T.eq(job["action"] as? String ?? "", "apply_generated", "action == apply_generated")
    T.eq(job["png"] as? String ?? "", "/tmp/whatever/gbook.png", "png path present")
    T.eq(job["edited_title"] as? String ?? "", "Сген. название", "edited_title present")
    T.eq(job["edited_author"] as? String ?? "", "Автор Икс", "edited_author present")
    // File id uses the "-gen-" infix so it's distinguishable at a glance.
    T.ok(Fixture.soleJobName(covers).contains("-gen-"), "job filename carries -gen- infix")
}

// (7) apply_generated with NO edited -> just action + png (back-compat).
func test_applyGenerated_noEdited_omitsFields() {
    let home = Fixture.makeHome(); defer { Fixture.remove(home) }
    let covers = Fixture.makeCoversDir(); defer { Fixture.remove(covers) }

    withIsolatedEnv(coversDir: covers) {
        _ = Fixture.client(home: home).requestApplyGenerated(
            bookId: "gbook2", pngPath: "/tmp/gbook2.png")
    }

    guard let job = Fixture.soleJob(covers) else {
        T.ok(false, "exactly one job written & decodable"); return
    }
    T.eq(job["action"] as? String ?? "", "apply_generated", "action == apply_generated")
    T.ok(job["edited_title"] == nil, "edited_title absent")
    T.ok(job["edited_author"] == nil, "edited_author absent")
}

// MARK: - requestConfirmAuto (NEW) — action == apply_confirm

// (8) confirm with NO edited -> action apply_confirm, book_id + ts, NO cover keys.
func test_confirmAuto_noEdited_writesConfirmAction() {
    let home = Fixture.makeHome(); defer { Fixture.remove(home) }
    let covers = Fixture.makeCoversDir(); defer { Fixture.remove(covers) }

    withIsolatedEnv(coversDir: covers) {
        let ok = Fixture.client(home: home).requestConfirmAuto(bookId: "cbook")
        T.ok(ok, "requestConfirmAuto returned true")
    }

    guard let job = Fixture.soleJob(covers) else {
        T.ok(false, "exactly one job written & decodable"); return
    }
    T.eq(job["action"] as? String ?? "", "apply_confirm", "action == apply_confirm")
    T.eq(job["book_id"] as? String ?? "", "cbook", "book_id present")
    T.ok(job["ts"] as? String != nil, "ts present")
    // A confirm job never carries a cover selection or PNG.
    T.ok(job["chosen_candidate_id"] == nil, "no chosen_candidate_id on confirm")
    T.ok(job["png"] == nil, "no png on confirm")
    T.ok(job["edited_title"] == nil, "no edited_title when not provided")
    T.ok(job["edited_author"] == nil, "no edited_author when not provided")
    // Filename carries the "-confirm-" infix.
    T.ok(Fixture.soleJobName(covers).contains("-confirm-"), "job filename carries -confirm- infix")
}

// (9) confirm WITH edited -> action apply_confirm + both edited fields.
func test_confirmAuto_withEdited_writesFields() {
    let home = Fixture.makeHome(); defer { Fixture.remove(home) }
    let covers = Fixture.makeCoversDir(); defer { Fixture.remove(covers) }

    withIsolatedEnv(coversDir: covers) {
        _ = Fixture.client(home: home).requestConfirmAuto(
            bookId: "cbook2", editedTitle: "Испр. название", editedAuthor: "Испр. автор")
    }

    guard let job = Fixture.soleJob(covers) else {
        T.ok(false, "exactly one job written & decodable"); return
    }
    T.eq(job["action"] as? String ?? "", "apply_confirm", "action == apply_confirm")
    T.eq(job["edited_title"] as? String ?? "", "Испр. название", "edited_title present")
    T.eq(job["edited_author"] as? String ?? "", "Испр. автор", "edited_author present")
    T.ok(job["png"] == nil, "still no png on confirm-with-edited")
}

// MARK: - Injection safety at the transport boundary

// (10) quotes / $() / backticks in the edited values survive VERBATIM in the JSON
//      (proves the value is a plain string, never spliced into a shell here).
func test_edited_injectionCharsSurviveVerbatim() {
    let home = Fixture.makeHome(); defer { Fixture.remove(home) }
    let covers = Fixture.makeCoversDir(); defer { Fixture.remove(covers) }

    let nasty = "\"; rm -rf / #$(whoami)`id`'"
    withIsolatedEnv(coversDir: covers) {
        _ = Fixture.client(home: home).requestConfirmAuto(
            bookId: "cbook3", editedTitle: nasty, editedAuthor: nil)
    }

    guard let job = Fixture.soleJob(covers) else {
        T.ok(false, "exactly one job written & decodable"); return
    }
    // JSONSerialization round-trips the exact string (only surrounding whitespace,
    // of which there is none here, would be trimmed by the write-layer).
    T.eq(job["edited_title"] as? String ?? "", nasty,
         "injection-y title stored verbatim (single JSON string, no shell)")
}

// (11) atomic publish leaves no .tmp behind for a confirm job.
func test_confirmAuto_noTmpLeftover() {
    let home = Fixture.makeHome(); defer { Fixture.remove(home) }
    let covers = Fixture.makeCoversDir(); defer { Fixture.remove(covers) }

    withIsolatedEnv(coversDir: covers) {
        _ = Fixture.client(home: home).requestConfirmAuto(bookId: "cbook4")
    }

    let dir = Fixture.jobsDir(covers)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    T.ok(!names.contains(where: { $0.hasSuffix(".tmp") }),
         "no .tmp leftover after atomic publish")
    T.eq(names.filter { $0.hasSuffix(".json") }.count, 1, "exactly one .json job published")
}

// MARK: - Runner

print("TAP version 13")
print("# fb2-to-epub — cover-job write-layer suite (edited_* + apply_confirm)")

print("# --- requestCover(.apply) + edited_* ---")
T.run("1 apply with edited writes fields", test_apply_withEdited_writesFields)
T.run("2 apply no edited omits fields (back-compat)", test_apply_noEdited_omitsFields)
T.run("3 apply blank/whitespace edited omitted", test_apply_blankEdited_omitsFields)
T.run("4 apply partial edited writes only provided", test_apply_partialEdited_writesOnlyProvided)
T.run("5 apply edited is trimmed", test_apply_editedIsTrimmed)

print("# --- requestApplyGenerated + edited_* ---")
T.run("6 apply_generated with edited writes fields", test_applyGenerated_withEdited_writesFields)
T.run("7 apply_generated no edited omits fields", test_applyGenerated_noEdited_omitsFields)

print("# --- requestConfirmAuto (apply_confirm) ---")
T.run("8 confirm no edited writes confirm action", test_confirmAuto_noEdited_writesConfirmAction)
T.run("9 confirm with edited writes fields", test_confirmAuto_withEdited_writesFields)

print("# --- injection safety / atomicity ---")
T.run("10 injection chars survive verbatim", test_edited_injectionCharsSurviveVerbatim)
T.run("11 confirm leaves no .tmp behind", test_confirmAuto_noTmpLeftover)

print("")
print("1..\(T.passed + T.failed)")
print("# passed: \(T.passed)")
print("# failed: \(T.failed)")
exit(T.failed == 0 ? 0 : 1)
