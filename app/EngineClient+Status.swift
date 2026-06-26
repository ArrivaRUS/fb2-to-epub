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
        // max(0,…) guards against a stale/over-large baseline.
        if let base = statsBaseline() {
            state.totals.convertedTotal = max(0, state.totals.convertedTotal - base)
        }

        // "За сегодня" reset (D13-safe, DATE-AWARE). The watcher resets `today`
        // daily by comparing its own `_today_date` stamp, so a plain baseline would
        // keep subtracting after midnight and bury tomorrow's count at 0. We instead
        // store {date, today} at reset and apply it ONLY while the day is unchanged:
        //   same day  → today = max(0, raw today − baseline.today)
        //   day rolled → ignore the baseline, show the watcher's fresh `today`.
        // "Same day" compares the baseline's date against the day the snapshot is
        // counting: state.todayDate (the watcher's _today_date) when present, else
        // our own local "today" (matches the watcher's local datetime.now()).
        if let tb = todayBaseline() {
            let currentDay = state.todayDate ?? Self.localDayString()
            if tb.date == currentDay {
                state.totals.today = max(0, state.totals.today - tb.today)
            }
            // Different day → baseline expired: leave state.totals.today as-is.
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

    /// Path to the app-owned "today baseline" marker, rooted at THIS client's home.
    /// `~/Library/Application Support/fb2-to-epub/state/today-baseline`
    /// Schema: {"date":"yyyy-MM-dd","today":<Int>,"ts":<ISO-8601>}. `date` is the
    /// watcher's day stamp at reset time, so loadState() can expire the baseline
    /// once the day rolls over (otherwise it would bury tomorrow's count at 0).
    private var todayBaselinePath: String {
        "\(home)/Library/Application Support/fb2-to-epub/state/today-baseline"
    }

    /// Read + parse the today baseline as (date, today). nil when absent /
    /// unreadable / malformed (fail-open: show the raw `today`).
    private func todayBaseline() -> (date: String, today: Int)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: todayBaselinePath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let date = obj["date"] as? String,
              let today = obj["today"] as? Int else { return nil }
        return (date, today)
    }

    /// Local-day string "yyyy-MM-dd" in the CURRENT timezone — the exact shape the
    /// watcher writes via Python `datetime.now().strftime("%Y-%m-%d")` (local, no
    /// tz suffix). Used as the fallback "today" when state.json has no _today_date,
    /// and to stamp the baseline's date at reset time. POSIX locale keeps it
    /// digits-only regardless of the user's locale.
    static func localDayString(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
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

    /// Latest snapshot of ONE book's queue file (no filtering). Used by the
    /// "Искать ещё" polling loop to watch the agent rewrite the entry with fresh
    /// candidates or set `no_more`. nil when the file is absent/unreadable.
    func loadCoverQueueEntry(bookId: String) -> CoverQueueEntry? {
        coverQueueStore.loadEntry(bookId: bookId)
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

    /// Reset ALL visible statistics shown on the Status screen: "сконвертировано
    /// всего", "за сегодня", AND the recent-conversions list.
    ///
    /// Same contract as clearHistory(): we do NOT rewrite state.json (the watcher
    /// owns it — D13). We capture the current raw counters as app-owned baselines;
    /// `loadState()` then subtracts them so the cards read zero now and future
    /// conversions count again. Three app-owned markers, each written atomically:
    ///   • stats-baseline  = {converted_total} → zeroes "всего" (current − base).
    ///   • today-baseline  = {date, today}     → zeroes "за сегодня" for TODAY only;
    ///     it expires when the watcher rolls the day over (loadState compares
    ///     `date` to the snapshot's day) so tomorrow's count is never buried at 0.
    ///   • recent-cleared-at (via clearHistory) → hides the current recent list.
    /// Best-effort: a failure on any marker simply leaves that part as-is.
    func resetStats() {
        let snapshot = StateStore(home: home).load()
        let fm = FileManager.default

        // 1) "Всего": baseline the raw lifetime total.
        let basePath = statsBaselinePath
        try? fm.createDirectory(atPath: (basePath as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        let totalPayload: [String: Any] = [
            "converted_total": snapshot.totals.convertedTotal,
            "ts": Self.iso8601Now(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: totalPayload,
                                                  options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: basePath), options: .atomic)
        }

        // 2) "За сегодня": date-stamped baseline. The day is the watcher's own
        // _today_date when present (so the comparison in loadState is exact), else
        // our local day (which matches the watcher's local datetime.now()).
        let day = snapshot.todayDate ?? Self.localDayString()
        let todayPath = todayBaselinePath
        try? fm.createDirectory(atPath: (todayPath as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        let todayPayload: [String: Any] = [
            "date": day,
            "today": snapshot.totals.today,
            "ts": Self.iso8601Now(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: todayPayload,
                                                  options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: todayPath), options: .atomic)
        }

        // 3) Recent list: reuse the exact "Очистить" logic (recent-cleared-at).
        clearHistory()
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

    // MARK: - Cover research ("Искать ещё"): write a research-job, then nudge

    /// Ask the agent to re-search covers for one book, excluding the URLs the user
    /// has already seen. Mirrors `requestCover` exactly — same `covers/jobs` dir,
    /// same atomic tmp → rename publish, same kickstart safety net.
    ///
    /// Contract (the agent already implements this side):
    ///   covers/jobs/<book_id>-research-<rand>.json =
    ///     { book_id, action: "research", exclude: [url, …], ts }
    /// The agent re-searches (skipping `exclude`) and REWRITES
    /// covers/queue/<book_id>.json with fresh `candidates` + `best_candidate_id`
    /// (status "pending"). If nothing new is found it sets `"no_more": true` and
    /// keeps the old `candidates`. The app NEVER touches the EPUB or the queue.
    ///
    /// Returns true when the job file was published (kickstart is best-effort).
    @discardableResult
    func requestCoverResearch(bookId: String, excludeUrls: [String]) -> Bool {
        let jobsDir = "\(CoverQueueStore(home: home).coversDir)/jobs"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: jobsDir, withIntermediateDirectories: true)

        let job: [String: Any] = [
            "book_id": bookId,
            "action": "research",
            "exclude": excludeUrls,
            "ts": Self.iso8601Now(),
        ]

        // Unique, traceable id: <book_id>-research-<short-random>. The "-research-"
        // infix distinguishes it from apply-jobs (<book_id>-<rand>) at a glance.
        let jobId = "\(bookId)-research-\(UUID().uuidString.prefix(8))"
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
        if ProcessInfo.processInfo.environment["FB2_SKIP_KICKSTART"] != "1" {
            kickstart()
        }
        return true
    }

    // MARK: - Engine refresh on update (fix #2)

    /// The three engine scripts that installer.sh copies into App Support/bin.
    /// Exact names verified against packaging/installer.sh (RUNNER/WATCHER/COVER
    /// _DST) and build/build-app.sh (what it stages into Contents/Resources).
    /// Both sides use these identical filenames, so a name maps 1:1 from the
    /// bundled copy to the installed copy.
    private static let engineScriptNames = [
        "fb2-to-epub-runner.sh",
        "fb2-to-epub-watcher.sh",
        "fb2-to-epub-cover-finder.py",
    ]

    /// Directory holding the bundled engine scripts. In a real .app this is
    /// `Contents/Resources` (Bundle.main.resourcePath). Tests (which run as a
    /// bare CLI, NOT inside a bundle) point it at a throwaway dir via
    /// FB2_BUNDLED_RES_DIR — same override style as FB2_COVERS_DIR/FB2_SRC_DIR.
    /// nil when neither is available (e.g. a dev binary run outside a bundle and
    /// without the override) → refresh then safely no-ops.
    private var bundledResourceDir: String? {
        if let override = ProcessInfo.processInfo.environment["FB2_BUNDLED_RES_DIR"],
           !override.isEmpty {
            return override
        }
        return Bundle.main.resourcePath
    }

    /// Installed engine bin dir, rooted at THIS client's home (so throwaway-HOME
    /// tests stay isolated): `~/Library/Application Support/fb2-to-epub/bin`.
    private var installedBinDir: String {
        "\(home)/Library/Application Support/fb2-to-epub/bin"
    }

    /// Byte-for-byte compare a bundled script against its installed counterpart.
    /// Treats "installed file missing" as DIFFERENT (the engine must be (re)laid
    /// down). A missing BUNDLED file is treated as "same" (fail-safe: we can't
    /// prove an update, so we don't churn the agent over a packaging gap).
    private func scriptDiffers(name: String, bundledDir: String) -> Bool {
        let bundledPath = "\(bundledDir)/\(name)"
        let installedPath = "\(installedBinDir)/\(name)"
        guard let bundled = try? Data(contentsOf: URL(fileURLWithPath: bundledPath)) else {
            return false // can't read the bundled source → don't trigger a refresh
        }
        guard let installed = try? Data(contentsOf: URL(fileURLWithPath: installedPath)) else {
            return true  // installed copy absent → engine needs to be laid down
        }
        return bundled != installed
    }

    /// True when ANY bundled engine script differs from its installed copy, i.e.
    /// this app build carries a newer (or just changed) engine than what the
    /// agent is currently running. nil bundled dir → false (nothing to compare).
    func bundledEngineDiffersFromInstalled() -> Bool {
        guard let bundledDir = bundledResourceDir else { return false }
        return Self.engineScriptNames.contains { scriptDiffers(name: $0, bundledDir: bundledDir) }
    }

    /// Result of the on-launch engine-refresh check (fix #2), for tests/logging.
    enum EngineRefreshOutcome: Equatable {
        /// No plist → fresh install, not our job (firstRunSetupIfNeeded owns it).
        case skippedNoPlist
        /// Engine scripts already match → agent left completely untouched.
        case upToDate
        /// Engine changed → installer.sh re-ran successfully (bin+plist refreshed).
        case refreshed(watchDir: String)
        /// Engine changed but the installer refresh failed (swallowed, not fatal —
        /// the agent is left as-is and the next launch retries).
        case refreshFailed
    }

    /// Idempotent on-launch repair for the "stale agent after update" bug.
    ///
    /// Runs AFTER firstRunSetupIfNeeded(). It mutates the agent ONLY when the
    /// engine genuinely changed:
    ///   - no plist           → skip (a fresh install is handled elsewhere);
    ///   - plist + scripts same → no-op (e.g. an app-only update like v0.2.2:
    ///                            ZERO agent mutation);
    ///   - plist + any script differs → re-run installer.sh ONCE against the
    ///                            user's EXISTING WATCH_DIR (read from the plist).
    ///                            installer.sh idempotently refreshes bin + plist;
    ///                            its runner-preserve (cmp) keeps the FDA grant.
    ///
    /// The watch folder is NEVER changed. Any installer failure is swallowed and
    /// reported as `.refreshFailed` (we do NOT crash or brick the agent — the
    /// next launch simply retries). Calibre absence ⇒ installer would exit non-
    /// zero ⇒ `.refreshFailed`, which is the correct "leave it as-is" behavior.
    ///
    /// `extraEnv` is forwarded to the installer (tests inject HOME/FB2_SRC_DIR so
    /// the throwaway agent is touched, never the real one).
    @discardableResult
    func refreshEngineIfBundledChanged(extraEnv: [String: String]? = nil) -> EngineRefreshOutcome {
        // Fresh install (no plist) is firstRunSetupIfNeeded's job, not ours.
        guard plistExists() else { return .skippedNoPlist }

        // Engine unchanged → do not touch the agent at all.
        guard bundledEngineDiffersFromInstalled() else { return .upToDate }

        // Engine changed → idempotent refresh against the user's existing folder.
        let watchDir = readWatchDir() ?? "\(home)/Desktop/fb2-to-epub"
        let res = runInstaller(watchDir: watchDir, extraEnv: extraEnv)
        return res.status == 0 ? .refreshed(watchDir: watchDir) : .refreshFailed
    }

    /// ISO-8601 UTC with trailing Z — matches what the watcher/Python side writes.
    private static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
