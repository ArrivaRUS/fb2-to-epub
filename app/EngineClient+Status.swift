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
    ///
    /// "Очистить" semantics: we never touch state.json (the watcher owns it — a
    /// race would corrupt it). Instead we keep an app-owned "recent-cleared-at"
    /// marker and FILTER `recent[]` on read — only events strictly NEWER than the
    /// marker survive, so future conversions reappear naturally. `totals` are left
    /// untouched (we clear the visible list, not the lifetime counters).
    func loadState() -> EngineState {
        var state = StateStore(home: home).load()

        // "Сбросить статистику" semantics: like the clear marker, we never touch
        // state.json (the watcher owns it — D13). We stash an app-owned baseline =
        // the raw lifetime total at reset time, then subtract it here so the card
        // reads from zero and new conversions count again (current − baseline).
        // ONLY convertedTotal is adjusted: today/failedToday are reset daily by the
        // watcher via _today_date, so baselining them would break the day counter
        // after midnight. max(0,…) guards against a stale/over-large baseline.
        if let base = statsBaseline() {
            state.totals.convertedTotal = max(0, state.totals.convertedTotal - base)
        }

        guard let cutoff = recentClearedAt() else { return state }

        // Keep entries strictly newer than the cutoff. Unparseable ts -> keep
        // (fail-open: never hide an event just because its timestamp is odd).
        state.recent = state.recent.filter { entry in
            guard let ts = RelativeTime.parse(entry.ts) else { return true }
            return ts > cutoff
        }

        // If last_conversion was cleared (ts <= cutoff), re-point it at whatever
        // survived the filter (newest-first), or nil when the list is now empty.
        if let last = state.lastConversion,
           let lastTs = RelativeTime.parse(last.ts),
           lastTs <= cutoff {
            state.lastConversion = state.recent.first
        }
        return state
    }

    /// Path to the app-owned "recent cleared at" marker, rooted at THIS client's
    /// home (so throwaway-HOME tests never touch the real file).
    /// `~/Library/Application Support/fb2-to-epub/state/recent-cleared-at`
    private var recentClearedAtPath: String {
        "\(home)/Library/Application Support/fb2-to-epub/state/recent-cleared-at"
    }

    /// Read + parse the clear marker. nil when absent / empty / unparseable.
    private func recentClearedAt() -> Date? {
        guard let raw = try? String(contentsOfFile: recentClearedAtPath,
                                    encoding: .utf8) else { return nil }
        return RelativeTime.parse(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Path to the app-owned "stats baseline" marker, rooted at THIS client's home
    /// (so throwaway-HOME tests never touch the real file).
    /// `~/Library/Application Support/fb2-to-epub/state/stats-baseline`
    private var statsBaselinePath: String {
        "\(home)/Library/Application Support/fb2-to-epub/state/stats-baseline"
    }

    /// Read + parse the stats baseline (the `converted_total` captured at reset).
    /// nil when absent / unreadable / malformed (fail-open: show the raw total
    /// rather than hide a number because the marker is odd).
    private func statsBaseline() -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statsBaselinePath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = obj["converted_total"] as? Int else { return nil }
        return base
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

    // --- Mutating actions ------------------------------------------------------

    /// Re-point the watched folder at `newDir` by re-running installer.sh, which
    /// idempotently rewrites the plist's WATCH_DIR and re-bootstraps the agent
    /// (bootout→bootstrap→kickstart). Returns true on success (installer rc == 0).
    ///
    /// Scope: ONLY re-targets the agent. We do NOT move existing files and do NOT
    /// re-scan — no other side effects. Calibre is required (the installer exits
    /// non-zero without it), so we short-circuit to false when it's absent and let
    /// the UI surface guidance.
    @discardableResult
    func changeWatchFolder(to newDir: String) -> Bool {
        guard calibreInstalled() else { return false }
        let res = runInstaller(watchDir: newDir)
        return res.status == 0
    }

    /// Toggle the background agent on/off. STUB (live): bootout / bootstrap.
    func setAgentEnabled(_: Bool) {
        // Intentionally not implemented in M2 (would mutate the live agent).
    }

    /// Clear the recent-conversions history shown in the Status screen.
    ///
    /// We do NOT rewrite state.json — the watcher owns it (D13), so touching it
    /// would race the agent. Instead we stamp an app-owned "cleared at" marker in
    /// our OWN App Support dir; `loadState()` then filters out every event at or
    /// before that instant. Newer conversions reappear; `totals` are unaffected.
    /// Written atomically (tmp -> rename via .atomic). Best-effort: a write
    /// failure simply leaves the history as-is.
    func clearHistory() {
        let path = recentClearedAtPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        // ISO-8601 UTC with trailing Z — same shape RelativeTime.parse expects.
        let stamp = Self.iso8601Now()
        try? stamp.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Reset the "сконвертировано всего" counter shown in the Status screen.
    ///
    /// Same contract as clearHistory(): we do NOT rewrite state.json (the watcher
    /// owns it — D13). We capture the CURRENT raw lifetime total as an app-owned
    /// baseline; `loadState()` then subtracts it so the card reads zero now and
    /// future conversions count again (current − baseline). Written atomically
    /// (.atomic). Best-effort: a write failure simply leaves the counter as-is.
    func resetStats() {
        let rawTotal = StateStore(home: home).load().totals.convertedTotal
        let path = statsBaselinePath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "converted_total": rawTotal,
            "ts": Self.iso8601Now(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
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
