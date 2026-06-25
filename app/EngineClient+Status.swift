// EngineClient+Status — M2 additions for the Status screen, kept in a separate
// file as a Swift extension (same struct, same target). This avoids editing the
// M1 EngineClient.swift while still exposing the read-only data + the one live
// action (open folder) the Status screen needs.
//
// Contract reminders (arch/plans-ui.md):
//   - We only READ engine state (state.json) and reveal the watch folder.
//   - Mutating actions (change folder, toggle agent, clear history) are PREPARED
//     here but intentionally inert in M2 — the destructive, live wiring lands in
//     later milestones with explicit testing. They must NOT touch the real agent.

import Foundation

extension EngineClient {

    // MARK: - Calibre version (for the CALIBRE stat card)

    /// Best-effort Calibre version string for the stat card. Returns the numeric
    /// version (e.g. "7.21") when `ebook-convert --version` parses, else "✓" when
    /// the binary merely exists, else nil. Never throws.
    func calibreVersion() -> String? {
        guard calibreInstalled() else { return nil }
        let r = run(ebookConvertPath, ["--version"])
        guard r.status == 0 else { return "✓" }
        // Output looks like: "ebook-convert (calibre 7.21)".
        if let range = r.stdout.range(of: #"calibre\s+[0-9]+(\.[0-9]+)+"#,
                                      options: .regularExpression) {
            let token = r.stdout[range]
            if let v = token.range(of: #"[0-9]+(\.[0-9]+)+"#, options: .regularExpression) {
                return String(token[v])
            }
        }
        return "✓"
    }

    // MARK: - State snapshot for the Status screen (read-only)

    /// Load the engine's state.json snapshot (totals + recent + watch_dir). Reads
    /// from the SAME home as this client, so isolated tests stay isolated.
    func loadState() -> EngineState {
        StateStore(home: home).load()
    }

    // MARK: - Cover queue (M5, read-only)

    /// The cover-selection queue store, rooted at this client's home (so tests
    /// stay isolated). Honors FB2_COVERS_DIR for the temp-dir test harness.
    private var coverQueueStore: CoverQueueStore { CoverQueueStore(home: home) }

    /// Count of pending books awaiting a cover decision (Status row badge).
    func coverQueueCount() -> Int {
        coverQueueStore.pendingCount()
    }

    /// Pending queue entries, newest-first, for the Выбор обложки screen.
    func loadCoverQueue() -> [CoverQueueEntry] {
        coverQueueStore.loadPending()
    }

    // MARK: - Actions

    /// Open the watch folder in Finder. The only mutating-ish action wired live in
    /// M2, and it is read-only w.r.t. the engine (just reveals a folder). Falls
    /// back to the default path if no plist/WATCH_DIR is present.
    @discardableResult
    func openWatchFolder() -> Bool {
        let dir = readWatchDir() ?? "\(home)/Desktop/fb2-to-epub"
        // Ensure it exists so `open` doesn't error on a fresh setup.
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        let r = run("/usr/bin/open", [dir])
        return r.status == 0
    }

    // --- Mutating actions: PREPARED but intentionally inert in M2 -------------

    /// Change the watched folder. STUB (later/live): would re-run installer.sh on
    /// the new dir and rebootstrap the agent. No-op for now.
    func changeWatchFolder(to _: String) {
        // Intentionally not implemented in M2 (would mutate the live agent).
    }

    /// Toggle the background agent on/off. STUB (live): bootout / bootstrap.
    func setAgentEnabled(_: Bool) {
        // Intentionally not implemented in M2 (would mutate the live agent).
    }

    /// Clear the recent-conversions history shown in the Status screen. STUB:
    /// will rewrite state.json's recent[] atomically in a later milestone.
    func clearHistory() {
        // Intentionally not implemented in M2.
    }

    // MARK: - Cover decision (M5): write an apply-job, then nudge the agent

    /// The user's cover decision for one book. `.apply(id)` picks a specific
    /// candidate; `.skip` keeps whatever the agent already embedded (best/auto)
    /// and just clears the queue entry.
    enum CoverDecision {
        case apply(candidateId: String)
        case skip
    }

    /// Write the apply-job atomically, then kickstart the agent as a safety net.
    ///
    /// Contract (synthesis-ui.md D13, arch/plans-ui.md "Контракты данных"):
    ///   covers/jobs/<job_id>.json = { book_id, chosen_candidate_id | "skip", ts }
    /// The app NEVER touches the EPUB. The agent — triggered by `covers/jobs`
    /// being in its WatchPaths (and by this kickstart) — reads the job under its
    /// Full Disk Access and applies the cover via ebook-polish, then clears it.
    ///
    /// Atomic publish: write `<job_id>.json.tmp` in the SAME dir, fsync, rename
    /// over the final name — a reader never sees a half-written job.
    /// Returns true when the job file was published (kickstart is best-effort).
    @discardableResult
    func requestCover(bookId: String, decision: CoverDecision) -> Bool {
        let jobsDir = "\(CoverQueueStore(home: home).coversDir)/jobs"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: jobsDir, withIntermediateDirectories: true)

        let ts = Self.iso8601Now()
        var job: [String: Any] = ["book_id": bookId, "ts": ts]
        switch decision {
        case .apply(let candidateId): job["chosen_candidate_id"] = candidateId
        case .skip:                   job["chosen_candidate_id"] = "skip"
        }

        // A unique, traceable job id: <book_id>-<short-random>. Distinct decisions
        // never collide; the book_id stays readable in the filename.
        let jobId = "\(bookId)-\(UUID().uuidString.prefix(8))"
        let finalPath = "\(jobsDir)/\(jobId).json"
        let tmpPath = "\(finalPath).tmp"

        guard let data = try? JSONSerialization.data(withJSONObject: job,
                                                     options: [.sortedKeys]) else {
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
            // Rename over the final name (atomic within the same dir).
            if fm.fileExists(atPath: finalPath) { try? fm.removeItem(atPath: finalPath) }
            try fm.moveItem(atPath: tmpPath, toPath: finalPath)
        } catch {
            try? fm.removeItem(atPath: tmpPath)
            return false
        }

        // Safety net: nudge the agent in case the WatchPaths event is coalesced.
        // Best-effort; tests pass a throwaway label so this never hits the real
        // agent, and the env-only temp test skips it entirely.
        if ProcessInfo.processInfo.environment["FB2_SKIP_KICKSTART"] != "1" {
            kickstart()
        }
        return true
    }

    /// ISO-8601 UTC with trailing Z — matches what the watcher/Python side writes.
    private static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
