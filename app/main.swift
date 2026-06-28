// fb2-to-epub — native SwiftUI window.
//
// M0: prove the native stack builds, codesigns, and launches a dark window.
// M1: wire EngineClient + first-run logic and prove the bridge.
// M2: render the real Status screen (StatusView) from the engine's state.json
//     snapshot + live agent status. The Setup screen lands at M3.
//
// Plain windowed app (NOT LSUIElement). Unsandboxed, no external deps:
// SwiftUI + AppKit + Foundation only. macOS 11.0 target.
//
// We drive the window via AppKit (NSApplication + NSWindow + NSHostingView)
// instead of the SwiftUI `App`/`WindowGroup` lifecycle: it gives precise
// control over the fixed width and the dark titlebar on macOS 11, and keeps the
// minimum-deployment surface small.

import AppKit
import SwiftUI

// MARK: - Window constants

private enum UI {
    /// Fixed content width per the design spec (400px window).
    static let windowWidth: CGFloat = Tokens.M.windowWidth
}

// MARK: - App delegate (AppKit lifecycle)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    /// The window's single hosting view; we swap its rootView to navigate.
    private var hosting: NSHostingView<AnyView>!
    /// Kept so action closures can call back into the engine for the whole run.
    private var engine: EngineClient!

    /// Live data for the Status screen. Created/updated on each `buildRoot(.status)`
    /// and refreshed in place (see `refreshStatusNow`) so the window updates while a
    /// batch conversion runs — instead of freezing on the snapshot taken when it opened.
    private var statusStore: StatusStore?
    /// Event-driven refresh: a directory watcher on the engine's `state/` folder. The
    /// background agent rewrites `state.json` atomically (tmp → rename) after each
    /// conversion, so watching the FILE would go stale on the inode swap — we watch
    /// the directory instead and re-read on its change. No polling. Lifecycle tied to
    /// Status being visible (armed on present(.status), torn down otherwise).
    private var stateWatcher: DispatchSourceFileSystemObject?
    /// Coalesces a burst of directory events (a batch writes several files) into one
    /// refresh ~150ms after the last event. Rescheduled on every event.
    private var watchDebounce: DispatchWorkItem?
    /// Window-focus observers (catch-up refresh when the user looks at the window),
    /// kept so they can be removed on teardown. Belt-and-suspenders for any event the
    /// directory watcher might miss; also event-driven, not a timer.
    private var focusObservers: [NSObjectProtocol] = []
    /// The screen currently shown. Used to refresh only while Status is visible
    /// (we never live-update Setup/Выбор обложки).
    private var currentScreen: Screen = .status

    /// Previous `state.batch?.active` value, for rising-edge detection in
    /// `refreshStatusNow`. When a fresh state flips this false→true (a new batch
    /// STARTED), we bring the window forward so the user sees the conversion begin.
    /// We react ONLY to the rising edge — not to every `done` tick or to active
    /// falling back to false — so focus doesn't dither during a run. Seeded at
    /// launch from the initial state (see applicationDidFinishLaunching) so the
    /// agent-launched "already active" case doesn't trigger a redundant raise on
    /// top of the launch-time NSApp.activate.
    private var lastBatchActive = false

    /// Which top-level screen is showing. Setup is decided once at launch; the
    /// rest are navigable (Status <-> Выбор обложки, Status <-> Настройки).
    private enum Screen { case setup, status, coverSelect, settings }

    /// Resolve the bundled installer.sh from Contents/Resources. Falls back to a
    /// checkout layout so the app also works when run from a dev build.
    private func resolveInstallerPath() -> String {
        if let p = Bundle.main.path(forResource: "installer", ofType: "sh") {
            return p
        }
        return "\(NSHomeDirectory())/Library/Application Support/fb2-to-epub/installer.sh"
    }

    /// UserDefaults flag: has the first-run Setup screen been shown already?
    /// Once true, launches always go straight to Status.
    private static let didShowSetupKey = "didShowSetup"

    /// Decide which screen to show on this launch.
    ///
    /// Setup wins when ANY of:
    ///   - FB2_FORCE_SETUP=1 in the environment (demo/screenshot override) — this
    ///     never flips the persisted flag, so it is purely a viewing aid;
    ///   - the agent was just installed this launch (.installedDefault) and Setup
    ///     hasn't been shown yet;
    ///   - Setup hasn't been shown yet AND there are no conversions on record
    ///     (a fresh machine that migrated an empty older applet still deserves the
    ///     welcome once).
    /// On a real (non-forced) Setup show we set the flag so it won't reappear.
    private func shouldShowSetup(outcome: FirstRunOutcome, state: EngineState) -> Bool {
        if ProcessInfo.processInfo.environment["FB2_FORCE_SETUP"] == "1" {
            return true
        }
        let alreadyShown = UserDefaults.standard.bool(forKey: Self.didShowSetupKey)
        guard !alreadyShown else { return false }

        let freshInstall: Bool
        switch outcome {
        case .installedDefault: freshInstall = true
        case .migratedExisting, .blockedNoCalibre: freshInstall = false
        }
        let noHistory = state.totals.convertedTotal == 0 && state.recent.isEmpty

        if freshInstall || noHistory {
            UserDefaults.standard.set(true, forKey: Self.didShowSetupKey)
            return true
        }
        return false
    }

    /// Collapse the home prefix to "~" for display (matches StatusView).
    private func displayWatchDir(_ raw: String?) -> String {
        let path = raw ?? "\(NSHomeDirectory())/Desktop/fb2-to-epub"
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Build the SwiftUI root for a given screen. Setup is built directly in
    /// `applicationDidFinishLaunching`; this builds the navigable Status and
    /// Выбор обложки screens (both re-read live engine data on each present).
    private func buildRoot(_ screen: Screen) -> AnyView {
        switch screen {
        case .setup:
            // Built once at launch (see applicationDidFinishLaunching); never
            // re-entered here. Kept exhaustive for the switch.
            let watchDir = displayWatchDir(engine.readWatchDir())
            return AnyView(SetupView(
                calibreVersion: engine.calibreVersion(),
                watchDir: watchDir,
                onOpenFolder: { [weak self] in self?.engine.openWatchFolder() },
                onChangeFolder: { [weak self] in self?.changeWatchFolder() },
                onSettings: { [weak self] in self?.present(.settings) },
                onOpenGitHub: { Self.openGitHub() }
            ))

        case .status:
            // Seed (or refresh) the live store from the current engine reads, then
            // hand the SAME store to the view. The timer mutates this store in place
            // so the screen stays live without rebuilding the view tree.
            let store: StatusStore
            if let existing = statusStore {
                existing.state = loadStateForDisplay()
                existing.agentActive = engine.agentStatus().isActive
                existing.calibreText = engine.calibreVersion() ?? "—"
                existing.coverCount = engine.coverQueueCount()
                store = existing
            } else {
                store = StatusStore(
                    state: loadStateForDisplay(),
                    agentActive: engine.agentStatus().isActive,
                    calibreText: engine.calibreVersion() ?? "—",
                    coverCount: engine.coverQueueCount()
                )
                statusStore = store
            }
            return AnyView(StatusView(
                store: store,
                onOpenFolder: { [weak self] in self?.engine.openWatchFolder() },
                onClearHistory: { [weak self] in
                    self?.engine.clearHistory()
                    self?.present(.status)   // rebuild Status -> re-read filtered loadState()
                },
                onSettings: { [weak self] in self?.present(.settings) },
                onSelectCovers: { [weak self] in self?.present(.coverSelect) },
                onOpenGitHub: { Self.openGitHub() }
            ))

        case .coverSelect:
            let queue = engine.loadCoverQueue()
            guard !queue.isEmpty else {
                // Queue drained (nothing pending) -> back to Status.
                return buildRoot(.status)
            }
            // CoverSelectView is a self-contained pager over the whole pending
            // queue: it owns the current index + per-book selection. The host only
            // commits one book (writes the apply-job) and goes back to Status when
            // the pager is exhausted. Navigation (Назад/Вперёд) never round-trips
            // here — but the row count can differ per book, so we let the view ask
            // for a window refit via onHeightMayChange.
            return AnyView(CoverSelectView(
                queue: queue,
                onApply: { [weak self] bookId, candidateId in
                    // Apply only — do NOT navigate; the pager advances internally.
                    self?.engine.requestCover(bookId: bookId,
                                              decision: .apply(candidateId: candidateId))
                },
                onDone: { [weak self] in self?.present(.status) },
                onHeightMayChange: { [weak self] in self?.refitCoverSelectHeight() },
                onResearch: { [weak self] bookId, excludeUrls, query in
                    // "Искать ещё с подсказкой": write a research-job carrying the
                    // user's free-text hint (author+title); the view polls the queue
                    // for the agent's rewrite (new candidates or no_more).
                    self?.engine.requestCoverResearch(bookId: bookId,
                                                      excludeUrls: excludeUrls,
                                                      query: query)
                },
                reloadEntry: { [weak self] bookId in
                    // Read ONE book's queue file fresh for the polling loop.
                    self?.engine.loadCoverQueueEntry(bookId: bookId)
                },
                onApplyGenerated: { [weak self] bookId, pngData in
                    // Generated cover chosen: save the PNG to
                    // <COVERS_DIR>/generated/<book_id>.png (atomic), then write an
                    // "apply_generated" job pointing at that absolute path. The app
                    // never touches the EPUB — the agent reads the PNG under FDA.
                    guard let self = self,
                          let path = self.engine.saveGeneratedCover(bookId: bookId,
                                                                    pngData: pngData)
                    else { return }
                    self.engine.requestApplyGenerated(bookId: bookId, pngPath: path)
                }
            ))

        case .settings:
            // The "Настройки" screen replaces the old text NSMenu. Every action
            // reuses the host's existing logic (factored into plain methods that
            // the menu's @objc shims used to wrap). It now leads with the
            // "Отслеживаемая папка" card (moved off Status): its "Сменить" link
            // reuses changeWatchFolder() — the SAME flow Status/Setup use — and the
            // current path is read fresh on every (re)build via readWatchDir, so a
            // change made from here re-renders with the new path. Below it: the two
            // rows (Сбросить статистику · Full Disk Access) + version/update + credit.
            let watchDir = displayWatchDir(engine.readWatchDir())
            return AnyView(SettingsView(
                onDone: { [weak self] in self?.present(.status) },
                onChangeFolder: { [weak self] in self?.changeWatchFolder() },
                onOpenFDA: { [weak self] in self?.openFullDiskAccess() },
                onResetStats: { [weak self] in self?.resetStatsConfirmed() },
                onCheckUpdate: { [weak self] in self?.checkUpdate() },
                onOpenGitHub: { Self.openGitHub() },
                watchDir: watchDir
            ))
        }
    }

    /// Screenshot/QA override parsed once at launch from FB2_FORCE_BATCH="done/total"
    /// (e.g. "3/10"). When set, it OVERLAYS an active batch onto every state we load
    /// for display so the Status ring renders "converting" in isolation, without a
    /// real conversion. It is layered onto the in-memory snapshot ONLY — state.json
    /// on disk is never written — so the real engine/agent are untouched. Absent /
    /// malformed → nil → normal behavior. Mirrors FB2_FORCE_COVER / FB2_FORCE_SETTINGS.
    private lazy var forcedBatch: EngineBatch? = Self.parseForcedBatch()

    private static func parseForcedBatch() -> EngineBatch? {
        guard let raw = ProcessInfo.processInfo.environment["FB2_FORCE_BATCH"] else {
            return nil
        }
        let parts = raw.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2,
              let done = Int(parts[0]),
              let total = Int(parts[1]),
              total > 0 else { return nil }
        return EngineBatch(active: true, total: total, done: max(0, min(done, total)))
    }

    /// `engine.loadState()` with the FB2_FORCE_BATCH overlay applied (no-op when the
    /// var is unset). Used everywhere the Status store is seeded/refreshed so the
    /// forced batch survives focus refreshes — it's re-applied on every read and
    /// never persisted. Without an override this is exactly `engine.loadState()`.
    private func loadStateForDisplay() -> EngineState {
        var s = engine.loadState()
        if let forced = forcedBatch { s.batch = forced }
        return s
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // --- Cover-generator test harness (renderer step 1, NO normal launch). ---
        // FB2_GENCOVER_TEST="<author>|<title>|<out-dir>": render ALL 4 fallback-cover
        // templates via CoverGenerator (offscreen WKWebView) into <out-dir> as
        // cover-tmpl<N>.png, then terminate. Anything other than this env var → the
        // app launches normally (the branch below is skipped entirely).
        if let spec = ProcessInfo.processInfo.environment["FB2_GENCOVER_TEST"], !spec.isEmpty {
            runCoverGenTestHarness(spec: spec)
            return
        }

        // --- Engine bridge + first-run/migration (M1 behavior, unchanged). ---
        let engine = EngineClient(installerPath: resolveInstallerPath())
        self.engine = engine
        // Production launch: only install when there is no plist; an existing
        // WATCH_DIR is read and kept (migration). This never clobbers the user.
        let outcome = engine.firstRunSetupIfNeeded()

        // Fix #2 — stale agent after an update. firstRunSetupIfNeeded() leaves an
        // EXISTING plist untouched (.migratedExisting), so after a DMG/auto update
        // the agent keeps running the OLD bin scripts + plist. Here we refresh them
        // ONLY when the engine genuinely changed: compare the bundled scripts
        // against the installed ones and, if any differ, re-run installer.sh once
        // against the user's existing WATCH_DIR (idempotent; runner-preserve keeps
        // FDA). An app-only update (identical bin, e.g. v0.2.2) does NOTHING. Run
        // off the main thread so launch/UI never blocks; any failure is swallowed
        // (logged) and retried on the next launch — never bricks the agent.
        DispatchQueue.global(qos: .utility).async {
            let result = engine.refreshEngineIfBundledChanged()
            switch result {
            case .refreshed(let dir):
                NSLog("fb2-to-epub: engine changed on update → refreshed agent (watch: \(dir))")
            case .refreshFailed:
                NSLog("fb2-to-epub: engine changed but installer refresh failed; leaving agent as-is (will retry next launch)")
            case .skippedNoPlist, .upToDate:
                break // fresh install / nothing changed → no log noise
            }
        }

        // --- Decide the initial screen. ---
        // Setup is shown exactly once after the agent gets installed, then never
        // again (a persisted flag flips on first show). The decision is read-only.
        // FB2_FORCE_COVER=1 jumps straight to Выбор обложки for screenshots (it
        // never flips any persisted flag — purely a viewing aid).
        let state = loadStateForDisplay()
        let initial: Screen
        if ProcessInfo.processInfo.environment["FB2_FORCE_COVER"] == "1" {
            initial = .coverSelect
        } else if ProcessInfo.processInfo.environment["FB2_FORCE_SETTINGS"] == "1" {
            initial = .settings
        } else if shouldShowSetup(outcome: outcome, state: state) {
            initial = .setup
        } else {
            initial = .status
        }
        currentScreen = initial

        let hosting = NSHostingView(rootView: buildRoot(initial))
        self.hosting = hosting

        // Let SwiftUI compute the natural height for the fixed 400px width.
        let fitting = hosting.fittingSize
        let contentSize = NSSize(width: UI.windowWidth, height: fitting.height)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "fb2-to-epub"
        window.contentView = hosting
        window.isReleasedWhenClosed = false

        // Fixed width: lock min == max so the window cannot be resized.
        window.minSize = NSSize(width: UI.windowWidth, height: contentSize.height)
        window.maxSize = NSSize(width: UI.windowWidth, height: contentSize.height)

        // Dark appearance so the titlebar/chrome matches the dark content.
        window.appearance = NSAppearance(named: .darkAqua)

        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Plain app: take focus on launch even when started via `open`.
        NSApp.activate(ignoringOtherApps: true)

        // Seed the rising-edge baseline from the state we just loaded. If the agent
        // launched us because a batch is ALREADY active, the activate() above has
        // handled visibility — recording it here prevents the first refresh from
        // re-detecting a false→true edge and raising the window a second time.
        lastBatchActive = state.batch?.active ?? false

        // Catch-up refresh whenever the window regains focus / the app activates —
        // covers any event the directory watcher might miss and gives a fresh view
        // the moment the user looks at the window. Installed once for the run.
        installFocusObservers()

        // Start event-driven live updates if we launched straight into Status (the
        // common case). Setup/Выбор обложки start static; the watcher arms when
        // `present(.status)` navigates back.
        if initial == .status {
            startStateWatcher()
        }
    }

    /// Navigate to a screen: rebuild the hosting rootView (re-reads live engine
    /// data) and refit the fixed-width window's height to the new content. Used
    /// for Status <-> Выбор обложки and Status <-> Настройки (the Settings screen
    /// is shorter than Status, so the refit shrinks the window). Width stays locked
    /// at 400px.
    private func present(_ screen: Screen) {
        guard let hosting = hosting else { return }
        currentScreen = screen
        hosting.rootView = buildRoot(screen)
        hosting.layoutSubtreeIfNeeded()
        refitWindowHeight()  // guards on window itself
        // Live-refresh only on Status. Entering Setup/Выбор обложки/Настройки tears
        // the watcher down (and closes its fd); returning to Status re-arms it.
        if screen == .status {
            startStateWatcher()
        } else {
            stopStateWatcher()
        }
    }

    /// Refit the fixed-width window's height to the current hosting content,
    /// preserving the top-left corner so the window doesn't jump. Width is locked
    /// (min == max == 400px) and never touched. `setFrame` is skipped when the
    /// height is unchanged, so per-second live refreshes don't cause jitter.
    /// Caller must `layoutSubtreeIfNeeded()` first when content just changed.
    ///
    /// Screen-height cap: the content's natural height (`fittingSize`) can exceed
    /// the screen — Выбор обложки with many candidates (web + generated) wants a
    /// window taller than the display, which pushed the bottom bar (‹ Назад ·
    /// Применить · Вперёд › + «Искать ещё») off-screen. We clamp the WINDOW frame
    /// height to the screen's `visibleFrame` minus a small margin; the Cover-select
    /// view's middle ScrollView then absorbs the squeeze (the grid scrolls) while
    /// header + bottom bar stay on-screen. Short screens (Status/Настройки) fit
    /// well under the cap, so this is a no-op for them. After resizing we also
    /// nudge the origin so the whole window sits inside `visibleFrame` (top AND
    /// bottom on-screen).
    private func refitWindowHeight() {
        guard let hosting = hosting, let window = window else { return }
        let naturalContentHeight = hosting.fittingSize.height
        let naturalFrame = window.frameRect(forContentRect:
            NSRect(x: 0, y: 0, width: UI.windowWidth, height: naturalContentHeight))

        // Cap the FRAME height to the visible screen area minus a margin for the
        // menu bar / window shadow / breathing room. visibleFrame already excludes
        // the menu bar + Dock; the margin keeps a hair of gap top & bottom.
        let margin: CGFloat = 32
        let screen = window.screen ?? NSScreen.main
        let availableHeight = (screen?.visibleFrame.height ?? naturalFrame.size.height) - margin
        let cappedHeight = min(naturalFrame.size.height, max(0, availableHeight))
        let newSize = NSSize(width: naturalFrame.size.width, height: cappedHeight)

        // Re-lock min == max so the resize sticks and the window stays fixed-width
        // (and, when capped, fixed-height at the screen limit).
        window.minSize = newSize
        window.maxSize = newSize

        // Preserve the top-left corner so the window doesn't jump as height changes.
        var frame = window.frame
        let topY = frame.origin.y + frame.size.height
        frame.size = newSize
        frame.origin.y = topY - newSize.height

        // Keep the whole window inside the visible screen area: if the (possibly
        // capped) frame would poke past the top or below the bottom, shift the
        // origin so both edges land on-screen. Without this, a tall window keeps
        // its old top-left and the capped bottom can still sit under the Dock edge.
        if let vf = screen?.visibleFrame {
            if frame.maxY > vf.maxY { frame.origin.y = vf.maxY - frame.size.height }
            if frame.origin.y < vf.minY { frame.origin.y = vf.minY }
        }

        // No real change in height AND origin → nothing to do (avoids per-tick
        // dithering on live Status refreshes).
        if abs(window.frame.size.height - frame.size.height) < 0.5,
           abs(window.frame.origin.y - frame.origin.y) < 0.5 {
            return
        }

        window.setFrame(frame, display: true, animate: false)
    }

    /// Re-fit the window after the Cover-select pager changed its OWN @State (the
    /// user flipped to another book, or applied one and advanced). Unlike `present`,
    /// the rootView is NOT rebuilt — SwiftUI re-lays the existing view tree, and
    /// that happens on a later runloop tick. So we hop to the next tick, force a
    /// layout pass, then refit the fixed-width window's height to the new content
    /// (book ↔ book candidate counts differ → height changes). No-ops off the
    /// Cover-select screen.
    private func refitCoverSelectHeight() {
        guard currentScreen == .coverSelect else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentScreen == .coverSelect else { return }
            self.hosting?.layoutSubtreeIfNeeded()
            self.refitWindowHeight()
        }
    }

    // MARK: - Live Status refresh (event-driven: directory watch + window focus)

    /// Absolute path to the engine's state directory. The agent writes `state.json`
    /// inside it atomically after each conversion; watching this directory is our
    /// change signal.
    private var stateDirPath: String {
        "\(NSHomeDirectory())/Library/Application Support/fb2-to-epub/state"
    }

    /// Arm (or re-arm) the directory watcher on the engine's `state/` folder. Idempotent
    /// — tears down any prior source first. Watches the DIRECTORY (not the file) because
    /// the agent rewrites `state.json` via tmp → rename, which swaps the file's inode; a
    /// file watcher would die on the swap, a directory watcher catches the change and
    /// needs no re-arm.
    ///
    /// Edge: on a fresh machine with no conversions yet the directory may not exist.
    /// `open` then fails (guarded), so we simply don't arm here — the focus observers
    /// keep the view fresh, and the next `present(.status)` re-arms once the directory
    /// appears.
    private func startStateWatcher() {
        stopStateWatcher()

        let fd = open(stateDirPath, O_EVTONLY)
        guard fd >= 0 else {
            // Directory not there yet (fresh install) — rely on focus catch-up; the
            // next present(.status) will try again once the agent creates it.
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        // Coalesce a burst (a batch writes several files) into one refresh ~150ms
        // after the last event, then hop to main to mutate the store + refit.
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.watchDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                DispatchQueue.main.async { self?.refreshStatusNow() }
            }
            self.watchDebounce = work
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 0.15, execute: work)
        }
        // Close the fd exactly once, when the source is fully cancelled — never leak it.
        source.setCancelHandler { close(fd) }
        source.resume()
        stateWatcher = source
    }

    /// Tear down the directory watcher (entering Setup/Выбор обложки, or teardown).
    /// Cancelling the source fires its cancel handler, which closes the fd. Also
    /// drops any pending debounce so a stale refresh can't land after teardown.
    private func stopStateWatcher() {
        watchDebounce?.cancel()
        watchDebounce = nil
        stateWatcher?.cancel()
        stateWatcher = nil
    }

    /// Install window-focus / app-activation observers for a catch-up refresh. Both
    /// are event-driven (no timer): they fire when the window becomes key or the app
    /// comes to the foreground, so the user always sees fresh data the moment they
    /// look — and any directory event that slipped through is reconciled. Installed
    /// once for the run; the refresh itself no-ops off Status.
    private func installFocusObservers() {
        let nc = NotificationCenter.default
        let becameKey = nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: .main
        ) { [weak self] _ in self?.refreshStatusNow() }
        let becameActive = nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshStatusNow() }
        focusObservers = [becameKey, becameActive]
    }

    /// Re-read the four live engine values and push them into the store, then refit
    /// the window height. Must run on the main thread (callers dispatch there).
    /// No-ops unless Status is the current screen and the store exists. Reads go
    /// through `engine.loadState()`, which already applies the "Очистить" /
    /// "Сбросить статистику" baselines, so resets stay reflected live.
    private func refreshStatusNow() {
        guard currentScreen == .status, let store = statusStore else { return }

        // Engine reads are cheap (state.json + launchctl/plist checks); on the main
        // thread so the store mutation and SwiftUI repaint stay coherent.
        store.state = loadStateForDisplay()
        store.agentActive = engine.agentStatus().isActive
        store.calibreText = engine.calibreVersion() ?? "—"
        store.coverCount = engine.coverQueueCount()

        // Rising edge of batch.active (false/nil → true) means a NEW conversion just
        // STARTED — bring the (already-running) window forward so the user sees it.
        // Compare against the previous value and react ONLY on the up-transition, then
        // record the new value. A `done` tick or active falling to false changes
        // nothing here, so the window isn't yanked around mid-run.
        let nowActive = store.state.batch?.active ?? false
        if nowActive && !lastBatchActive {
            bringWindowForward()
        }
        lastBatchActive = nowActive

        // Content height can change (a new conversion row, the cover-picker row
        // appearing). Re-layout, then refit — refit no-ops if height is unchanged.
        hosting?.layoutSubtreeIfNeeded()
        refitWindowHeight()
    }

    /// Bring the already-running window to the foreground (the app is launched, but
    /// may be minimized or behind other windows). Called on the rising edge of a
    /// batch start. The "app was fully closed" case is handled elsewhere (the agent
    /// re-opens the bundle); this only un-buries a live instance.
    private func bringWindowForward() {
        guard let window = window else { return }
        window.deminiaturize(nil)        // restore if minimized to the Dock
        window.makeKeyAndOrderFront(nil) // raise + focus the window
        NSApp.activate(ignoringOtherApps: true) // pull the app itself to the front
    }

    /// "Сменить папку" — let the user pick a new watch folder, then re-target the
    /// agent at it via installer.sh. Wired from the Status footer-era flow, the Setup
    /// screen, and (now) the Настройки "Отслеживаемая папка" card.
    ///
    /// Flow:
    ///   1. NSOpenPanel (directories only), pre-seeded with the current watch dir.
    ///   2. On pick → engine.changeWatchFolder(to:). On success → re-present so the
    ///      new path shows: when invoked FROM Настройки we rebuild Настройки (its
    ///      card re-reads readWatchDir and renders the new path in place); from
    ///      Status/Setup we land on Status (Setup's natural post-setup destination),
    ///      which re-reads the plist and renders the new path. Both paths rebuild the
    ///      whole rootView via `present(...)` — the established navigation path — so
    ///      there is no in-view identity swap racing an AppKit refit (cf .patches/011).
    ///   3. On failure (Calibre missing / installer failed) → an explanatory alert.
    /// Cancel changes nothing. This only re-targets the agent — no files are moved.
    /// All AppKit UI here runs on the main thread (the SwiftUI action closures that
    /// invoke it already dispatch on main).
    private func changeWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.message = "Выберите папку, за которой будет следить fb2-to-epub. "
            + "Новые .fb2 здесь будут автоматически конвертироваться в EPUB."
        if let current = engine.readWatchDir() {
            panel.directoryURL = URL(fileURLWithPath: current)
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return // cancelled — nothing changes
        }

        let ok = engine.changeWatchFolder(to: url.path)
        if ok {
            // Re-present so the new path renders. Stay on Настройки when the change
            // started there (its card re-reads readWatchDir on rebuild); otherwise
            // land on Status (Setup's natural post-setup destination too).
            present(currentScreen == .settings ? .settings : .status)
        } else {
            let alert = NSAlert()
            alert.messageText = "Не удалось сменить папку"
            alert.informativeText = "Проверьте, установлен ли Calibre, и попробуйте снова."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Open the project's GitHub repo in the default browser (spec: credit footer
    /// link → NSWorkspace.shared.open).
    private static func openGitHub() {
        guard let url = URL(string: Tokens.Project.githubURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Settings screen actions (gear button → SettingsView)

    // The gear (`onSettings`) on Status/Setup now opens the SwiftUI "Настройки"
    // screen (present(.settings)), replacing the old NSMenu. The secondary actions
    // that screen's rows trigger live here as plain reusable methods (the menu's
    // @objc shims are gone; "Сменить папку" reuses changeWatchFolder() directly,
    // and "О программе" is replaced by the screen's version row + credit footer).
    // All run on the main thread (the SwiftUI action closures already dispatch on
    // main).

    /// "Сбросить статистику" — confirm, then zero the "сконвертировано всего"
    /// counter via an app-owned baseline (engine.resetStats() never touches
    /// state.json). The reset takes effect when the user returns to Status (‹),
    /// which re-reads loadState() from the new baseline — Настройки itself shows no
    /// statistics, so it never needs re-presenting here.
    /// "Отмена" is the default/cancel button so a stray Return doesn't reset.
    ///
    /// IMPORTANT (see .patches/010): this is invoked from SettingsView's row
    /// `.onTapGesture`. Running NSAlert.runModal() *synchronously inside* that
    /// gesture handler ran a nested modal event loop on top of a live SwiftUI
    /// gesture, leaving the NSHostingView's gesture recognizers wedged — afterwards
    /// every tap on the screen (incl. the ‹ back Button) was dead. We hop to the
    /// next main-runloop tick so the tap handler fully unwinds BEFORE the modal
    /// opens; the gesture system is then idle and stays responsive after the alert.
    private func resetStatsConfirmed() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let alert = NSAlert()
            alert.messageText = "Сбросить статистику?"
            alert.informativeText = "Счётчики (всего и за сегодня) обнулятся, "
                + "список последних конвертаций очистится. "
                + "Файлы и книги не удаляются."
            alert.alertStyle = .warning
            // "Отмена" added first => it's the default (Return) and we make it cancel
            // (Esc) too: a stray keystroke never triggers a destructive reset. "Сброс."
            // is flagged destructive (red) per HIG.
            let cancelButton = alert.addButton(withTitle: "Отмена")
            cancelButton.keyEquivalent = "\u{1b}" // Esc cancels
            let resetButton = alert.addButton(withTitle: "Сбросить")
            if #available(macOS 11.0, *) { resetButton.hasDestructiveAction = true }
            // First button (= Отмена) is .alertFirstButtonReturn; reset is the second.
            if alert.runModal() == .alertSecondButtonReturn {
                self.engine.resetStats()
                // No re-present: Настройки shows no stats; Status re-reads the
                // baseline when the user taps ‹ back.
            }
        }
    }

    /// "Full Disk Access" — jump straight to the Full Disk Access pane in System
    /// Settings so the user can grant access to the agent.
    private func openFullDiskAccess() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// GitHub releases page — opened from the update alerts (the "Обновить" /
    /// "Открыть страницу релизов" buttons). Hardcoded to the latest-release page.
    private static func openReleasesPage() {
        guard let url = URL(string:
            "https://github.com/ArrivaRUS/fb2-to-epub/releases/latest")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// A small modeless "Загружаю обновление…" window. Kept modeless (not app-modal)
    /// so the background download completion can dismiss it and the runloop stays
    /// live for URLSession. Held while the download runs; closed on failure (on
    /// success the app quits and the installer takes over).
    private static var updateProgressWindow: NSWindow?

    /// Guards the whole update flow (check → download → install) against re-entry: a
    /// second "Проверить обновление" click while one is in flight is ignored. Set on
    /// entry to `checkUpdate()`, cleared in every branch that does NOT hand off
    /// to the installer (up-to-date, any failure, "Позже"). The success path never
    /// clears it — the process is terminating into the detached installer.
    private static var isUpdateInFlight = false

    /// Show the progress panel and start the download/verify/install. On any
    /// pre-handoff failure: close the panel, then offer the manual releases page
    /// (reusing `openReleasesPage`). On success there is no callback — the app
    /// terminates and the detached installer relaunches the new build.
    private static func startAutoUpdate(_ info: UpdateChecker.UpdateInfo) {
        showUpdateProgress()
        UpdateChecker.downloadAndInstall(info) { result in
            DispatchQueue.main.async {
                // Success path never calls back (process is terminating). This block
                // only runs on failure → tear down the panel and offer the fallback.
                guard case .failure = result else { return }
                isUpdateInFlight = false
                dismissUpdateProgress()

                let alert = NSAlert()
                alert.messageText = "Не удалось обновить автоматически"
                alert.informativeText = "Открыть страницу загрузки?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Открыть")
                alert.addButton(withTitle: "Отмена")
                if alert.runModal() == .alertFirstButtonReturn {
                    openReleasesPage()
                }
            }
        }
    }

    /// Build + show the modeless progress panel (idempotent).
    private static func showUpdateProgress() {
        if updateProgressWindow != nil { return }

        let label = NSTextField(labelWithString: "Загружаю обновление…")
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 72),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "Обновление"
        window.isReleasedWhenClosed = false
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateProgressWindow = window
    }

    /// Close + release the progress panel.
    private static func dismissUpdateProgress() {
        updateProgressWindow?.orderOut(nil)
        updateProgressWindow = nil
    }

    /// "Проверить обновление" (Settings card) — ask GitHub for the latest published
    /// release and report the result in a native alert. The network call may finish
    /// on a background thread, so EVERY alert below is dispatched onto the main thread.
    ///
    /// Outcomes:
    ///   - success, up to date  → informational "Установлена последняя версия";
    ///   - success, newer found → "Доступна версия …" with [Обновить][Позже];
    ///     "Обновить" downloads + installs (UpdateChecker.downloadAndInstall);
    ///   - failure              → warning with [Открыть страницу релизов][OK].
    private func checkUpdate() {
        // Re-entry guard: ignore a second click while a check/download/install runs.
        // Set+read on the main thread (the SwiftUI action closure runs there), so no
        // race with the resets inside the dispatched blocks below / in startAutoUpdate.
        if Self.isUpdateInFlight { return }
        Self.isUpdateInFlight = true

        UpdateChecker.checkLatest { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let info) where !info.isNewer:
                    Self.isUpdateInFlight = false
                    let alert = NSAlert()
                    alert.messageText = "Установлена последняя версия"
                    alert.informativeText = "Версия \(UpdateChecker.currentVersion)."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()

                case .success(let info):
                    let alert = NSAlert()
                    alert.messageText = "Доступна версия \(info.latestVersion)"
                    alert.informativeText = "Сейчас установлена "
                        + "\(UpdateChecker.currentVersion). Обновить?"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Обновить")
                    alert.addButton(withTitle: "Позже")
                    if alert.runModal() == .alertFirstButtonReturn {
                        // Stays in-flight through download/install; startAutoUpdate
                        // clears the flag on failure (success terminates the app).
                        Self.startAutoUpdate(info)
                    } else {
                        Self.isUpdateInFlight = false
                    }

                case .failure:
                    Self.isUpdateInFlight = false
                    let alert = NSAlert()
                    alert.messageText = "Не удалось проверить обновление"
                    alert.informativeText = "Проверьте соединение с интернетом."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Открыть страницу релизов")
                    alert.addButton(withTitle: "OK")
                    if alert.runModal() == .alertFirstButtonReturn {
                        Self.openReleasesPage()
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Cover-generator test harness

    /// Render all 4 fallback-cover templates for the given "author|title|out-dir"
    /// spec and terminate. Used to eyeball the native WKWebView renderer
    /// (CoverGenerator) against the Python prototype before it is wired into the
    /// cover-pick window. Never invoked on a normal launch.
    private func runCoverGenTestHarness(spec: String) {
        let parts = spec.components(separatedBy: "|")
        guard parts.count == 3 else {
            FileHandle.standardError.write(Data(
                "FB2_GENCOVER_TEST must be \"<author>|<title>|<out-dir>\"\n".utf8))
            NSApp.terminate(nil)
            return
        }
        let author = parts[0]
        let title = parts[1]
        let outDir = (parts[2] as NSString).expandingTildeInPath

        do {
            try FileManager.default.createDirectory(
                atPath: outDir, withIntermediateDirectories: true)
        } catch {
            NSLog("cover-gen harness: cannot create out dir %@: %@", outDir, String(describing: error))
            NSApp.terminate(nil)
            return
        }

        NSLog("cover-gen harness: author=%@ title=%@ out=%@", author, title, outDir)
        let generator = CoverGenerator()
        Task { @MainActor in
            var okCount = 0
            for t in 1...4 {
                if let data = await generator.render(author: author, title: title, template: t) {
                    let path = (outDir as NSString)
                        .appendingPathComponent("cover-tmpl\(t).png")
                    do {
                        try data.write(to: URL(fileURLWithPath: path))
                        okCount += 1
                        NSLog("cover-gen harness: wrote %@ (%d bytes)", path, data.count)
                        print("OK cover-tmpl\(t).png \(data.count) bytes -> \(path)")
                    } catch {
                        NSLog("cover-gen harness: write failed %@: %@", path, String(describing: error))
                        print("FAIL write cover-tmpl\(t).png: \(error)")
                    }
                } else {
                    NSLog("cover-gen harness: render FAILED for template %d", t)
                    print("FAIL render cover-tmpl\(t).png")
                }
            }
            print("cover-gen harness done: \(okCount)/4 templates rendered into \(outDir)")
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.regular) // dock icon + menu bar — a normal windowed app
let delegate = AppDelegate()
app.delegate = delegate
app.run()
