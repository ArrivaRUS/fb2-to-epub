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
import Combine

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

    /// CAL-4: the ONE install pipeline for this run. Created at launch (prod config
    /// + agent-activation closure). Owned here; the three onboarding screens observe
    /// it (they repaint on phase change), and we observe it too (`installCancellable`)
    /// for the window refit + the D40 terminate lifecycle. Lives independent of the
    /// window, so closing the window mid-install does NOT interrupt it (D40).
    private var installStore: InstallStore!
    /// Combine sink on `installStore.$phase` → refit the fixed-width window height to
    /// the new content, drive the success normalisation, and honour a deferred Cmd-Q
    /// (`.terminateLater` reply on the next safe/terminal point).
    private var installCancellable: AnyCancellable?
    /// D40: a Cmd-Q arrived while the install was at an UNSAFE point (installing/
    /// verifying/activating) or the user chose "Прервать и выйти" mid-download. We
    /// answered `.terminateLater`; when the pipeline next reaches a terminal phase
    /// (safe point / cleanup done) we reply true and the app quits.
    private var pendingTerminate = false

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
    /// A SECOND directory watcher, on the user's WATCHED FOLDER (the WATCH_DIR the
    /// agent monitors), armed in lockstep with `stateWatcher`. The cover-queue badge
    /// ("Выбрать обложку · N") counts only pending books whose EPUB still exists
    /// (CoverQueueStore.loadPending self-cleans vanished ones); but deleting files
    /// from the watched folder produces NO event on `state/`, so without this the
    /// cached badge stayed stale until the next window focus. Watching the folder
    /// itself fires `refreshStatusNow` the moment its contents change, so the count
    /// (and the row) drop to 0 immediately. Re-armed on a folder change. See
    /// .patches for the rationale.
    private var watchDirWatcher: DispatchSourceFileSystemObject?
    /// The watched-folder path this watcher is currently armed on, so a re-arm is a
    /// no-op when it hasn't changed (and a folder change re-targets it).
    private var watchedDirPath: String?
    /// Separate debounce for the watched-folder watcher so a burst there and a burst
    /// on `state/` never cancel each other's coalesced refresh.
    private var watchDirDebounce: DispatchWorkItem?
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

    /// FDA recheck (v1.0.1) coordinator. When «Проверить снова» is pressed we remember
    /// the `folder_access_ts` at press time, kickstart the agent, and accept the result
    /// only once a FRESH ts (≠ pressed) lands — via the existing stateWatcher, with a
    /// 250 ms fallback poll and an 8 s timeout (ThrottleInterval=5). nil = no recheck.
    private var folderRecheckPressedTs: String?
    private var folderRecheckDeadline: DispatchWorkItem?
    private var folderRecheckPoll: DispatchWorkItem?
    /// fix #2: pending auto-reset of the "Путь скопирован ✓" ack / failure hint (so a
    /// re-press restarts the window instead of leaving a stale reset in flight). The
    /// ack and the hint are mutually exclusive, so one slot serves both.
    private var folderCopyFlashReset: DispatchWorkItem?

    /// Which top-level screen is showing. Setup is decided once at launch; the
    /// rest are navigable (Status <-> Выбор обложки, Status <-> Настройки).
    private enum Screen { case setup, status, coverSelect, settings }

    /// Resolve the bundled installer.sh from Contents/Resources. Falls back to a
    /// checkout layout so the app also works when run from a dev build.
    private func resolveInstallerPath() -> String {
        if let p = Bundle.main.path(forResource: "installer", ofType: "sh") {
            return p
        }
        return "\(EngineHome.resolve())/Library/Application Support/fb2-to-epub/installer.sh"
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
    private func shouldShowSetup(outcome: FirstRunOutcome) -> Bool {
        if ProcessInfo.processInfo.environment["FB2_FORCE_SETUP"] == "1" {
            return true
        }
        let alreadyShown = UserDefaults.standard.bool(forKey: Self.didShowSetupKey)
        guard !alreadyShown else { return false }

        let freshInstall: Bool
        switch outcome {
        case .installedDefault: freshInstall = true
        // CAL-1: blockedNoCalibre разделён на needsEngine / agentSetupFailed.
        // Поведение обоих новых случаев — ровно прежнее (не свежая установка).
        case .migratedExisting, .needsEngine, .agentSetupFailed: freshInstall = false
        }
        // CAL-2: единый helper с гибридом D37 — история по СЫРОМУ снапшоту, а не по
        // отфильтрованному loadState (иначе «Сбросить статистику» меняло бы решение).
        let noHistory = !engine.hasRawHistory()

        if freshInstall || noHistory {
            UserDefaults.standard.set(true, forKey: Self.didShowSetupKey)
            return true
        }
        return false
    }

    /// Collapse the home prefix to "~" for display (matches StatusView).
    private func displayWatchDir(_ raw: String?) -> String {
        let home = EngineHome.resolve()
        let path = raw ?? "\(home)/Desktop/fb2-to-epub"
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// FDA (v1.0.1): the single denied signal that Setup / Настройки consume (both
    /// show the resting `.denied` look — the transient checking/timeout states are
    /// Status-only). Screenshot force wins; otherwise the live agent flag decides.
    /// Absent field / ok / missing → false (no FDA step/row; today's view untouched).
    private func folderDeniedForDisplay() -> Bool {
        if folderForced { return forcedFolderState != nil }
        return engine.loadState().agent.folderAccess == .denied
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
                onOpenGitHub: { Self.openGitHub() },
                // CAL-4: the Setup «ДВИЖОК» step is display-only (it can't render
                // progress), so its install/manual actions hand off to Status, which
                // shows the live blocker/banner progress. After success we land on
                // Status (normal). See startEngineInstallFromSetup / showManualFromSetup.
                onInstallEngine: onboardingAction { [weak self] in self?.startEngineInstallFromSetup() },
                onManualInstall: onboardingAction { [weak self] in self?.showManualFromSetup() },
                // FDA (v1.0.1): amber «ДОСТУП К ПАПКЕ» step after ДВИЖОК; button hands
                // off to Status (live blocker/banner). Inert under the screenshot force.
                folderDenied: folderDeniedForDisplay(),
                onFixFolderAccess: folderAction { [weak self] in self?.present(.status) }
            ))

        case .status:
            // Seed (or refresh) the live store from the current engine reads, then
            // hand the SAME store to the view. The timer mutates this store in place
            // so the screen stays live without rebuilding the view tree.
            let store: StatusStore
            if let existing = statusStore {
                existing.state = loadStateForDisplay()
                existing.agentActive = engine.agentStatus().isActive
                existing.coverCount = engine.coverQueueCount()
                existing.calibrePresent = engine.calibreInstalled()
                existing.hasRawHistory = engine.hasRawHistory()
                store = existing
            } else {
                store = StatusStore(
                    state: loadStateForDisplay(),
                    agentActive: engine.agentStatus().isActive,
                    coverCount: engine.coverQueueCount(),
                    calibrePresent: engine.calibreInstalled(),
                    hasRawHistory: engine.hasRawHistory()
                )
                statusStore = store
            }
            return AnyView(StatusView(
                store: store,
                installStore: installStore,
                onOpenFolder: { [weak self] in self?.engine.openWatchFolder() },
                onClearHistory: { [weak self] in
                    self?.engine.clearHistory()
                    self?.present(.status)   // rebuild Status -> re-read filtered loadState()
                },
                onSettings: { [weak self] in self?.present(.settings) },
                onSelectCovers: { [weak self] in self?.present(.coverSelect) },
                onOpenGitHub: { Self.openGitHub() },
                // CAL-2 screenshot overlay (nil in normal runs); the live phase comes
                // from installStore.
                forcedInstallPhase: forcedInstallPhase,
                // CAL-4: the onboarding actions, now live. m5: no-op под форс-фазой (скриншот-режим).
                onInstallEngine: onboardingAction { [weak self] in self?.startEngineInstall() },
                onCancelInstall: onboardingAction { [weak self] in self?.installStore.cancel() },
                onRetryInstall: onboardingAction { [weak self] in self?.startEngineInstall() },
                onManualInstall: onboardingAction { [weak self] in self?.installStore.showManual() },
                onOpenCalibreSite: onboardingAction { Self.openCalibreSite() },
                onRecheckEngine: onboardingAction { [weak self] in self?.recheckEngine() },
                onRetryAgent: onboardingAction { [weak self] in self?.installStore.activateOnly() },
                // FDA (v1.0.1): screenshot force + live actions (inert under force).
                folderForced: folderForced,
                forcedFolderState: forcedFolderState,
                onOpenFolderAccess: folderAction { [weak self] in self?.openFolderAccessAndCopyPath(fromCardCTA: true) },
                onRecheckFolder: folderAction { [weak self] in self?.recheckFolderAccess() }
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
                onApply: { [weak self] bookId, candidateId, editedTitle, editedAuthor in
                    // Apply only — do NOT navigate; the pager advances internally.
                    // editedTitle/editedAuthor (nil when unchanged) → the agent
                    // rewrites the EPUB metadata via ebook-meta before the cover.
                    self?.engine.requestCover(bookId: bookId,
                                              decision: .apply(candidateId: candidateId),
                                              editedTitle: editedTitle,
                                              editedAuthor: editedAuthor)
                },
                onConfirmAuto: { [weak self] bookId, editedTitle, editedAuthor in
                    // "Утвердить" on the auto cover: it's already embedded, so write
                    // an "apply_confirm" job that just resolves the card (and
                    // rewrites metadata when edited-values are present, no polish).
                    self?.engine.requestConfirmAuto(bookId: bookId,
                                                    editedTitle: editedTitle,
                                                    editedAuthor: editedAuthor)
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
                onApplyGenerated: { [weak self] bookId, pngData, editedTitle, editedAuthor in
                    // Generated cover chosen: save the PNG to
                    // <COVERS_DIR>/generated/<book_id>.png (atomic), then write an
                    // "apply_generated" job pointing at that absolute path. The app
                    // never touches the EPUB — the agent reads the PNG under FDA.
                    // editedTitle/editedAuthor (nil when unchanged) ride along.
                    guard let self = self,
                          let path = self.engine.saveGeneratedCover(bookId: bookId,
                                                                    pngData: pngData)
                    else { return }
                    self.engine.requestApplyGenerated(bookId: bookId, pngPath: path,
                                                      editedTitle: editedTitle,
                                                      editedAuthor: editedAuthor)
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
                installStore: installStore,
                onDone: { [weak self] in self?.present(.status) },
                onChangeFolder: { [weak self] in self?.changeWatchFolder() },
                // fix #2: route the passive FDA row through the SAME copying handler as
                // the warn card — its step 2 promises "путь уже в буфере", so opening
                // the pane WITHOUT copying (the old behaviour) contradicted that.
                // fix #4: fromCardCTA defaults to false here → the clipboard still fills,
                // but no Status ack is flipped (no phantom «✓» on return to Status).
                onOpenFDA: { [weak self] in self?.openFolderAccessAndCopyPath() },
                onResetStats: { [weak self] in self?.resetStatsConfirmed() },
                onCheckUpdate: { [weak self] in self?.checkUpdate() },
                onOpenGitHub: { Self.openGitHub() },
                // CAL-4: the Calibre row's onboarding actions, now live. m5: no-op под форс-фазой.
                onInstallEngine: onboardingAction { [weak self] in self?.startEngineInstall() },
                onCancelInstall: onboardingAction { [weak self] in self?.installStore.cancel() },
                onRetryInstall: onboardingAction { [weak self] in self?.startEngineInstall() },
                onRetryAgent: onboardingAction { [weak self] in self?.installStore.activateOnly() },
                // CAL-2 screenshot overlay (nil in normal runs); the live phase comes
                // from installStore.
                forcedInstallPhase: forcedInstallPhase,
                // FDA (v1.0.1): warn row replaces the passive FDA row while denied.
                folderDenied: folderDeniedForDisplay(),
                onFixFolderAccess: folderAction { [weak self] in self?.openFolderAccessAndCopyPath() },
                watchDir: watchDir,
                calibreVersion: engine.calibreVersion()
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

    /// Screenshot/QA override parsed once at launch from FB2_FORCE_INSTALL_STATE —
    /// the display-only mirror of FB2_FORCE_BATCH for the Calibre-onboarding phases
    /// (plans CAL-2 task 2.8). Feeds the hybrid on Status / the Настройки row, so a
    /// design-reviewer can capture every flow.md §6 state without a real install.
    /// It NEVER writes to disk and NEVER starts the pipeline (CAL-2 is read-only).
    /// Grammar: empty | downloading:DONE/TOTAL | installing | verifying | success |
    ///          error-network | error-space | error-install | manual |
    ///          activation-failed | os-unsupported. Absent/malformed → nil.
    private lazy var forcedInstallPhase: EngineSetupCard.Phase? = Self.parseForcedInstallState()

    private static func parseForcedInstallState() -> EngineSetupCard.Phase? {
        guard let raw = ProcessInfo.processInfo.environment["FB2_FORCE_INSTALL_STATE"],
              !raw.isEmpty else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces)
        switch s {
        case "empty":             return .notInstalled
        case "installing":        return .installing
        case "verifying":         return .verifying
        case "success":           return .success
        case "error-network":     return .errorNetwork
        case "error-space":       return .errorSpace
        case "error-install":     return .errorInstall
        case "manual":            return .manual(osUnsupported: false)
        case "os-unsupported":    return .manual(osUnsupported: true)
        case "activation-failed": return .activationFailed
        default:
            // "downloading:DONE/TOTAL" (e.g. "downloading:94/210").
            guard s.hasPrefix("downloading") else { return nil }
            let nums = s.dropFirst("downloading".count).drop(while: { $0 == ":" || $0 == " " })
            let parts = nums.split(separator: "/", maxSplits: 1)
            if parts.count == 2, let d = Int(parts[0]), let t = Int(parts[1]), t > 0 {
                return .downloading(done: max(0, min(d, t)), total: t)
            }
            return .downloading(done: 156, total: 330) // bare "downloading" → the mockup values
        }
    }

    /// m5: в скриншот-режиме (`FB2_FORCE_INSTALL_STATE` задан) карточка онбординга —
    /// display-only; её нарисованные кнопки НЕ должны запускать настоящую установку/отмену/
    /// активацию. Оборачиваем каждый онбординг-колбэк: живой в норме, no-op под форс-фазой.
    private func onboardingAction(_ live: @escaping () -> Void) -> () -> Void {
        forcedInstallPhase == nil ? live : {}
    }

    /// FDA-2 screenshot overlay (FB2_FORCE_FOLDER_ACCESS): display-only mirror of the
    /// live agent `folder_access` flag, so a design-reviewer can capture every FDA
    /// подача/state without a real TCC block. NEVER writes to disk, NEVER kicks the
    /// agent (the FDA card's buttons are no-ops under the force — see folderAction).
    /// Grammar: ok | denied | denied-checking | denied-still | denied-timeout.
    ///   • env ABSENT → `folderForced=false` → the live flag drives the card;
    ///   • env=`ok`   → `folderForced=true`, state=nil → NO card (проверка миграции);
    ///   • else       → `folderForced=true`, state=the forced FDA state.
    private lazy var folderForced: Bool =
        (ProcessInfo.processInfo.environment["FB2_FORCE_FOLDER_ACCESS"]?.isEmpty == false)
    private lazy var forcedFolderState: FolderAccessCard.State? = Self.parseForcedFolderState()

    private static func parseForcedFolderState() -> FolderAccessCard.State? {
        guard let raw = ProcessInfo.processInfo.environment["FB2_FORCE_FOLDER_ACCESS"],
              !raw.isEmpty else { return nil }
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "denied":         return .denied
        case "denied-checking": return .checking
        case "denied-still":   return .stillDenied
        case "denied-timeout": return .timeout
        case "ok":             return nil   // forced-present but no card (migration proof)
        default:               return nil
        }
    }

    /// Like `onboardingAction` for the FDA card: live in normal runs, no-op while the
    /// screenshot force is active (display-only, FDA-2 red line).
    private func folderAction(_ live: @escaping () -> Void) -> () -> Void {
        folderForced ? {} : live
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

        // Standard AppKit main menu FIRST on every real launch. Without it a bare
        // NSApplication has no "Завершить" item, so Cmd+Q never reaches
        // applicationShouldTerminate (the D40 "Установка движка ещё идёт" dialog is
        // then unreachable from the keyboard) and Cmd+C/V/X/A/Z are dead in the
        // Автор/Название text fields on Выбор обложки. Menu carrier only — no
        // behaviour change (all actions are standard responder-chain selectors).
        installMainMenu()

        // --- Engine bridge + first-run/migration (M1 behavior, unchanged). ---
        // CAL-4: honour a throwaway agent LABEL for isolated runs — but ONLY under
        // the full mutation latch (урок 015): TEST_MODE=1 + the app-owned install
        // root inside a canonicalised TEST_ROOT. The bundled installer.sh gates
        // FB2_AGENT_LABEL the same way, so the Swift side and the bash side agree on
        // which plist we bootout/bootstrap. On a real machine the env is ignored →
        // the production label. HOME follows env only through EngineHome.resolve()
        // (П1: NSHomeDirectory() ignores $HOME for a directly-launched binary), which
        // defaults to NSHomeDirectory() in production — so the whole engine layer sees
        // one consistent home (locator/installer/EngineClient/state/covers/plist).
        let env = ProcessInfo.processInfo.environment
        let home = EngineHome.resolve(env: env)
        var agentLabel = "com.arrivarus.fb2toepub.agent"
        if let testLabel = env["FB2_AGENT_LABEL"], !testLabel.isEmpty,
           CalibreTestLatch.allowsMutation(installRoot: CalibreLocator.appOwnedRoot(home: home), env: env) {
            agentLabel = testLabel
        }
        let engine = EngineClient(label: agentLabel, home: home, installerPath: resolveInstallerPath())
        self.engine = engine

        // CAL-4: the install pipeline + agent-activation ("оживление"). The activate
        // closure is task 4.1: with a plist present we RE-BAKE it (runInstaller re-
        // points CALIBRE_MACOS_DIR/EBOOK_* at the just-installed engine, then
        // bootout→bootstrap→enable→kickstart — all inside installer.sh, not Swift);
        // with no plist we first-run onto the default folder. Non-zero rc while the
        // engine IS present = agent-activation failure (→ .agentActivationFailed), the
        // installer's first stderr line goes to the log (task 4.2).
        let activate: () -> Bool = { [engine] in
            if engine.plistExists() {
                let dir = engine.readWatchDir() ?? "\(engine.home)/Desktop/fb2-to-epub"
                let res = engine.runInstaller(watchDir: dir)
                if res.status != 0 {
                    let firstErr = res.stderr.split(separator: "\n").first.map(String.init)
                        ?? res.stdout.split(separator: "\n").first.map(String.init) ?? ""
                    NSLog("fb2-to-epub: активация агента не удалась (rc=%d): %@", res.status, firstErr)
                    return false
                }
                return true
            } else {
                switch engine.firstRunSetupIfNeeded() {
                case .installedDefault, .migratedExisting:
                    return true
                case .agentSetupFailed, .needsEngine:
                    NSLog("fb2-to-epub: активация агента (первый запуск) не удалась")
                    return false
                }
            }
        }
        let installStore = InstallStore(
            config: CalibreInstaller.Config(home: home, env: env),
            activate: activate)
        self.installStore = installStore
        installCancellable = installStore.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.handleInstallPhase(phase) }

        // Clean up any leftovers from a previous interrupted install (staging/.old/
        // dangling mount/DMG), off the main thread so launch never blocks. Only ever
        // touches our app-owned root; a real calibre.app survives (CAL-3 task 3.12).
        DispatchQueue.global(qos: .utility).async {
            CalibreInstaller.cleanupLeftovers(home: home)
        }
        // Production launch: only install when there is no plist; an existing
        // WATCH_DIR is read and kept (migration). This never clobbers the user.
        let outcome = engine.firstRunSetupIfNeeded()

        // Fix #2 — stale agent after an update. firstRunSetupIfNeeded() leaves an
        // EXISTING plist untouched (.migratedExisting), so after a DMG/auto update
        // the agent keeps running the OLD bin scripts + plist. Here we refresh them
        // ONLY when a refresh is genuinely due: (a) the bundled payload differs from
        // the installed one, OR (b) the plist's ProgramArguments[0] is not the frozen
        // helper (v1.0.3 fix #1 — self-heals a plist stuck on the dead runner.sh even
        // when the bytes match: a pre-laid helper, or an installer crash window). If
        // due, re-run installer.sh once against the user's existing WATCH_DIR
        // (idempotent; the agent-helper/runner preserve keeps FDA). A steady-state
        // app-only update (identical bin AND PA0 already the helper) does NOTHING. Any
        // failure is swallowed (logged) and retried on the next launch — never bricks
        // the agent.
        //
        // v1.0.2, MIGRATION ORDER (arch/plan-binrunner-synthesis.md, решение №3):
        // this refresh is deliberately SYNCHRONOUS, before any UI exists. It is
        // what re-points the plist's ProgramArguments[0] at the new Mach-O helper;
        // the FolderAccessCard CTA copies `runnerPath()` = plist ProgramArguments[0]
        // to the clipboard, so an async refresh would race the card and could hand
        // the user the DEAD runner.sh path. Cost: the differs-check is a few small
        // byte-compares (sub-ms) on every launch; the installer actually runs only
        // on the first launch after an engine-changing update (same synchronous
        // class as firstRunSetupIfNeeded's fresh-install path right above).
        // The FDA CTA does NOT read this outcome: it re-reads the plist's PA0 live
        // (`installedRunnerIsStale()`), which is true on every road to a stale target.
        let refreshResult = engine.refreshEngineIfBundledChanged()
        switch refreshResult {
        case .refreshed(let dir):
            NSLog("fb2-to-epub: engine changed on update → refreshed agent (watch: \(dir))")
        case .refreshFailed:
            NSLog("fb2-to-epub: engine changed but installer refresh failed; leaving agent as-is (will retry next launch)")
        case .skippedNoPlist, .upToDate:
            break // fresh install / nothing changed → no log noise
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
        } else if shouldShowSetup(outcome: outcome) {
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
        // common case). Setup/Выбор обложки start static; the watchers arm when
        // `present(.status)` navigates back.
        if initial == .status {
            startStateWatcher()
            startWatchDirWatcher()
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
        // both watchers down (and closes their fds); returning to Status re-arms them.
        if screen == .status {
            startStateWatcher()
            startWatchDirWatcher()
        } else {
            stopStateWatcher()
            stopWatchDirWatcher()
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
        "\(EngineHome.resolve())/Library/Application Support/fb2-to-epub/state"
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

    /// Arm (or re-arm) a directory watcher on the user's WATCHED FOLDER, so the
    /// cover-queue badge falls to 0 the instant the tracked .fb2/.epub files vanish
    /// (deleting the folder's contents emits no `state/` event, and if the window is
    /// already focused no focus event either — so without this the count stayed
    /// stale). Mirrors `startStateWatcher`: watches the DIRECTORY (events survive the
    /// agent's tmp→rename writes), coalesces a burst, hops to main → refreshStatusNow.
    ///
    /// Idempotent and folder-change-aware: if already armed on the SAME path, it is a
    /// no-op (no fd churn on every present(.status)); a different path tears the old
    /// one down and arms the new one. The path comes from `engine.readWatchDir()`
    /// (the plist value); nil/missing → we don't arm (focus catch-up still covers it,
    /// and the next present(.status) retries once the folder exists).
    private func startWatchDirWatcher() {
        // Watch the REAL folder (the plist's WATCH_DIR), production path only — no
        // test-override lives here. An earlier verify-only FB2_WATCH_DIR override
        // leaked into the installer/refresh path and re-targeted the user's real
        // agent's WatchPaths to a temp dir (see .patches/015); removed entirely.
        let dir: String? = engine.readWatchDir()

        // Already watching this exact folder → nothing to do.
        if let dir = dir, watchDirWatcher != nil, watchedDirPath == dir { return }

        // Path changed (or cleared) → drop the old source before (maybe) re-arming.
        stopWatchDirWatcher()

        guard let dir = dir, !dir.isEmpty else { return }

        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            // Folder not there yet — focus catch-up covers it; next present(.status)
            // retries once the user creates it / the agent's first conversion lands.
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .link],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.watchDirDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                DispatchQueue.main.async { self?.refreshStatusNow() }
            }
            self.watchDirDebounce = work
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 0.15, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchDirWatcher = source
        watchedDirPath = dir
    }

    /// Tear down the watched-folder watcher (entering Setup/Выбор обложки/Настройки,
    /// folder change, or teardown). Mirrors `stopStateWatcher`.
    private func stopWatchDirWatcher() {
        watchDirDebounce?.cancel()
        watchDirDebounce = nil
        watchDirWatcher?.cancel()
        watchDirWatcher = nil
        watchedDirPath = nil
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
        store.coverCount = engine.coverQueueCount()
        // CAL-2: engine presence + raw history for the honest badge/footer + the D37
        // hybrid. calibreInstalled() = locator (3×stat), NO process spawn in the
        // refresh cycle; --version is only read where a version is displayed.
        store.calibrePresent = engine.calibreInstalled()
        store.hasRawHistory = engine.hasRawHistory()

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

        // FDA recheck: if «Проверить снова» is in flight, a fresh folder_access_ts in
        // the state we just re-read resolves it (ok → card dissolves, denied →
        // stillDenied). No-op otherwise.
        evaluateFolderRecheckIfInFlight()
        // A1: a terminal recheck (stillDenied/timeout) is PINNED after the coordinator
        // tears down, so a later live flip back to ok would stay hidden behind it. Once
        // the recheck is no longer in flight and the live flag has recovered, dissolve
        // the pinned card so the surface follows the live truth on its own.
        dissolveStaleTerminalRecheckIfLive()

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
    /// Settings so the user can grant access to the agent. The `Privacy_AllFiles`
    /// anchor is not a stable public API (Codex finding, В5/В-fallback): if the
    /// deep-linked open fails, fall back to the root "Конфиденциальность и
    /// безопасность" pane so the user still lands in the right place.
    private func openFullDiskAccess() {
        let ws = NSWorkspace.shared
        if let deep = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
           ws.open(deep) {
            return
        }
        if let root = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            ws.open(root)
        }
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
    /// Instance method (m3): the failure path also clears `installStore.isUpdateInFlight`.
    private func startAutoUpdate(_ info: UpdateChecker.UpdateInfo) {
        Self.showUpdateProgress()
        UpdateChecker.downloadAndInstall(info) { [weak self] result in
            DispatchQueue.main.async {
                // Success path never calls back (process is terminating). This block
                // only runs on failure → tear down the panel and offer the fallback.
                guard case .failure = result else { return }
                Self.isUpdateInFlight = false
                self?.installStore?.isUpdateInFlight = false
                Self.dismissUpdateProgress()

                let alert = NSAlert()
                alert.messageText = "Не удалось обновить автоматически"
                alert.informativeText = "Открыть страницу загрузки?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Открыть")
                alert.addButton(withTitle: "Отмена")
                if alert.runModal() == .alertFirstButtonReturn {
                    Self.openReleasesPage()
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
        // CAL-4 mutual exclusion: don't self-update the app mid engine install (both
        // fetch + swap large bundles). Ask the user to wait for the engine first.
        if installStore?.isInFlight == true {
            let alert = NSAlert()
            alert.messageText = "Идёт установка движка"
            alert.informativeText = "Дождись завершения установки Calibre, затем проверь обновление."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        Self.isUpdateInFlight = true
        // m3: на время самообновления приложения гасим онбординг движка (start / activateOnly —
        // «Повторить запуск агента» / «Проверить снова») через флаг стора; снимаем во всех
        // ветках, кроме success-пути (там процесс завершается в детач-инсталлер).
        installStore?.isUpdateInFlight = true

        UpdateChecker.checkLatest { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let info) where !info.isNewer:
                    Self.isUpdateInFlight = false
                    self?.installStore?.isUpdateInFlight = false
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
                        // clears both flags on failure (success terminates the app).
                        self?.startAutoUpdate(info)
                    } else {
                        Self.isUpdateInFlight = false
                        self?.installStore?.isUpdateInFlight = false
                    }

                case .failure:
                    Self.isUpdateInFlight = false
                    self?.installStore?.isUpdateInFlight = false
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

    // MARK: - Calibre onboarding actions (CAL-4)

    /// Kick off the full install pipeline (download → verify → install → revive the
    /// agent). Mutually exclusive with the app self-update (don't fetch a 330 MB
    /// engine while a new app build is installing). Re-entry is guarded inside the
    /// store, so a double-tap is a no-op.
    private func startEngineInstall() {
        if Self.isUpdateInFlight {
            let alert = NSAlert()
            alert.messageText = "Идёт обновление приложения"
            alert.informativeText = "Дождись завершения обновления, затем поставь движок."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        installStore.start()
    }

    /// Setup «ДВИЖОК» step → install. That step is display-only (no progress), so we
    /// move to Status (its blocker/banner shows the live progress), then start.
    private func startEngineInstallFromSetup() {
        present(.status)
        startEngineInstall()
    }

    /// Setup «ДВИЖОК» step → «Вручную». Same hand-off to Status, where the manual
    /// steps + [Открыть сайт]/[Проверить снова] render.
    private func showManualFromSetup() {
        present(.status)
        installStore.showManual()
    }

    /// «Проверить снова» (manual branch, task 4.4): re-probe the locator. Found →
    /// revive the agent immediately (no download). Not found → a gentle nudge; the
    /// manual card stays put.
    private func recheckEngine() {
        if engine.calibreInstalled() {
            installStore.activateOnly()
        } else {
            let alert = NSAlert()
            alert.messageText = "Пока не вижу движок"
            alert.informativeText = "Установи Calibre вручную и нажми «Проверить снова»."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// «Открыть сайт Calibre» → the official download page in the default browser.
    private static func openCalibreSite() {
        guard let url = URL(string: "https://calibre-ebook.com") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - FDA onboarding actions (v1.0.1, D46)

    /// FDA CTA «Открыть настройки и скопировать путь»: copy the ACTUAL runner path
    /// (plist ProgramArguments[0], fallback derived from home) to the clipboard FIRST,
    /// then open the Full Disk Access pane. The runner is what launchd spawns, so it is
    /// exactly what the user must add/enable in the pane; step 2 pastes it via Cmd-Shift-G.
    /// Copy on-press only (we never touch the clipboard just because the card appeared);
    /// pressing again re-copies. The runner file itself is NEVER modified (grant by bytes).
    ///
    /// fix #2: `NSPasteboard.setString` can return false (another process owns the
    /// pasteboard, or the type wasn't accepted). We VERIFY the write, retry once, and
    /// only on real success flash «Путь скопирован ✓» on the card CTA — the card's
    /// step 2 promises "путь уже в буфере", so a silent failure would be a lie.
    ///
    /// `fromCardCTA` (fix #4): true ONLY when invoked from the Status FDA card's own
    /// CTA. The Status ack/hint (`folderPathCopied`/`folderCopyHint`) is flashed ONLY
    /// then — a copy triggered from Настройки still fills the clipboard, but must not
    /// flip a Status ack that would flash «✓» on return to a screen the user isn't on.
    ///
    /// fix #2 (dead path): if the plist's PA0 is STILL the dead runner.sh, `runnerPath()`
    /// is a mortician's path — copying it would silently promise success on a route that
    /// can't work. We skip the copy entirely (both entry points) and, on the card CTA,
    /// show an honest hint. Opening the pane is still fine (harmless), so we do that
    /// regardless.
    ///
    /// v1.0.3 (re-review): the guard keys on the INVARIANT «PA0 присутствует и ≠ helper»
    /// (`installedRunnerIsStale()`), NOT on the launch-time refresh outcome. Fix #1 opened
    /// a SECOND road to a stale PA0 — no Calibre ⇒ the self-heal is skipped by the anti-loop
    /// guard ⇒ `.upToDate` with the dead runner.sh still in the plist — which an
    /// outcome-keyed guard let straight through (reachable from Настройки, where the passive
    /// FDA row is always drawn). It is deliberately NOT `!installedRunnerIsHelper()` either:
    /// with an absent/broken/empty PA0 `runnerPath()` returns the CORRECT canonical helper,
    /// and a naive negation would refuse to copy a perfectly good path.
    private func openFolderAccessAndCopyPath(fromCardCTA: Bool = false) {
        if engine.installedRunnerIsStale() {
            NSLog("fb2-to-epub: FDA CTA — PA0 is still the stale runner.sh; NOT copying a dead path")
            if fromCardCTA {
                // Honest about WHY it is stale: without an engine the self-heal is skipped
                // on purpose (anti-loop), and reopening the app alone would not fix it.
                showCopyHint(engine.calibreInstalled()
                    ? "Не удалось обновить движок — переоткрой приложение"
                    : "Сначала установи Calibre — без движка путь не готов")
            }
            openFullDiskAccess()
            return
        }
        let ok = Self.copyToClipboard(engine.runnerPath())
        if fromCardCTA {
            // fix #3: the ack reflects the LAST setString result — success lights «✓»,
            // failure (incl. a 2nd press whose clearContents emptied the buffer) drops
            // any pending ack and shows the honest "couldn't copy" hint.
            if ok { flashPathCopied() } else { showCopyHint("Не удалось скопировать путь — попробуй ещё раз") }
        }
        openFullDiskAccess()
    }

    /// Write `s` to the general pasteboard, VERIFYING the AppKit write took. Retries
    /// once (re-`clearContents` re-declares ownership) and logs on a repeated failure.
    /// Returns whether the string is now on the clipboard.
    private static func copyToClipboard(_ s: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.setString(s, forType: .string) { return true }
        pb.clearContents()                       // retry once
        if pb.setString(s, forType: .string) { return true }
        NSLog("fb2-to-epub: clipboard copy failed twice for FDA path")
        return false
    }

    /// Briefly flip the Status FDA-card CTA to «Путь скопирован ✓» (fix #2). Host-
    /// driven so it reflects a REAL successful copy (never shown on failure); reverts
    /// after ~2.5 s. A no-op visually unless the Status FDA card is the visible surface.
    /// Clears any prior failure hint so the two never coexist.
    private func flashPathCopied() {
        guard let store = statusStore else { return }
        folderCopyFlashReset?.cancel()
        store.folderCopyHint = nil          // ack and hint are mutually exclusive
        store.folderPathCopied = true
        let work = DispatchWorkItem { [weak store] in store?.folderPathCopied = false }
        folderCopyFlashReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// fix #2/#3: show an honest hint at the FDA card CTA and, CRUCIALLY, make sure the
    /// success ack is not left lit — cancel any pending reset and clear folderPathCopied
    /// NOW, so the CTA reflects the LAST result (a failed copy never keeps a stale «✓»).
    /// Reuses the single reset slot (ack and hint never coexist); auto-clears after ~6 s
    /// so a stale error line doesn't linger.
    private func showCopyHint(_ msg: String) {
        guard let store = statusStore else { return }
        folderCopyFlashReset?.cancel()
        store.folderPathCopied = false      // fix #3: drop the ✓ — this press FAILED
        store.folderCopyHint = msg
        let work = DispatchWorkItem { [weak store] in store?.folderCopyHint = nil }
        folderCopyFlashReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// FDA «Проверить снова»: kick the agent (no `-k`) and accept the result only on a
    /// FRESH folder_access_ts. Event-driven via the stateWatcher (already armed on
    /// Status), with a 250 ms fallback poll and an 8 s timeout. A non-zero kickstart
    /// (agent not bootstrapped / off) is «Агент не ответил», NOT another denied.
    private func recheckFolderAccess() {
        guard currentScreen == .status, let store = statusStore else { return }
        // Already rechecking? Ignore re-taps (the button is disabled while checking).
        guard folderRecheckPressedTs == nil else { return }

        folderRecheckPressedTs = engine.loadState().agent.folderAccessTs ?? ""
        store.folderRecheck = .checking

        let kick = engine.kickstartGentle()
        if kick.status != 0 {
            finishFolderRecheck(with: .timeout)
            return
        }

        // 8 s hard timeout (accounts for ThrottleInterval=5) → «Агент не ответил».
        let deadline = DispatchWorkItem { [weak self] in
            self?.finishFolderRecheck(with: .timeout)
        }
        folderRecheckDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
        // Fallback poll (~250 ms) only for the operation's duration — belt over the
        // stateWatcher for the fresh-machine case where the state dir wasn't armed yet.
        scheduleFolderRecheckPoll()
    }

    /// Re-read the engine ~every 250 ms while a recheck is in flight (reschedules
    /// itself). refreshStatusNow → evaluateFolderRecheckIfInFlight resolves it; this
    /// just guarantees a read even if no fs-event fired. Stops when the recheck ends.
    private func scheduleFolderRecheckPoll() {
        folderRecheckPoll?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.folderRecheckPressedTs != nil else { return }
            self.refreshStatusNow()               // re-reads + evaluates
            if self.folderRecheckPressedTs != nil { // still in flight → reschedule
                self.scheduleFolderRecheckPoll()
            }
        }
        folderRecheckPoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Called after every Status refresh: if a recheck is in flight and the freshly
    /// read state carries a NEW folder_access_ts, resolve it (ok/missing → card
    /// dissolves; denied → stillDenied). No-op when no recheck is pending or the ts
    /// hasn't advanced yet.
    private func evaluateFolderRecheckIfInFlight() {
        guard folderRecheckPressedTs != nil, let store = statusStore else { return }
        // Shared pure decision (FolderRecheck.evaluate) — the same logic the unit test
        // drives with injected timestamps. Accept only a FRESH ts (≠ pressed).
        switch FolderRecheck.evaluate(pressedTs: folderRecheckPressedTs,
                                      currentTs: store.state.agent.folderAccessTs,
                                      currentAccess: store.state.agent.folderAccess) {
        case .pending:     return                              // no fresh probe yet
        case .stillDenied: finishFolderRecheck(with: .stillDenied)
        case .cleared:     finishFolderRecheck(with: nil)      // router drops the card
        }
    }

    /// A1: called after every Status refresh. A terminal recheck card (stillDenied/
    /// timeout) is PINNED into the store once the coordinator finishes, so if the user
    /// then grants access the live flag flips to ok but the pinned terminal card keeps
    /// the surface up forever. Only when NO recheck is in flight AND the card is terminal
    /// AND the live flag is no longer denied → clear it, so the card dissolves on its own.
    private func dissolveStaleTerminalRecheckIfLive() {
        guard folderRecheckPressedTs == nil,      // a live recheck owns the card — leave it
              let store = statusStore,
              let card = store.folderRecheck else { return }
        if FolderRecheck.terminalRecheckDissolves(isTerminal: card.isTerminal,
                                                  liveAccess: store.state.agent.folderAccess) {
            store.folderRecheck = nil
        }
    }

    /// Tear down the recheck coordinator and set the terminal card state (nil = the
    /// card dissolves; the live flag then decides — ok → normal Status).
    private func finishFolderRecheck(with state: FolderAccessCard.State?) {
        folderRecheckDeadline?.cancel(); folderRecheckDeadline = nil
        folderRecheckPoll?.cancel(); folderRecheckPoll = nil
        folderRecheckPressedTs = nil
        statusStore?.folderRecheck = state
    }

    /// Combine sink on `installStore.$phase` (main runloop): honour a deferred Cmd-Q,
    /// drive the success normalisation, and refit the fixed-width window to the new
    /// content height.
    private func handleInstallPhase(_ phase: InstallPhase) {
        // D40: a deferred Cmd-Q waits for a safe/terminal point. Honour it FIRST —
        // once safe we quit (and skip the success normalisation below).
        if pendingTerminate, phase.isTerminal {
            pendingTerminate = false
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }

        // Success (task 4.3): hold the ✓ ~2s, then normalise to the current screen.
        if phase == .success {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.finishInstallSuccess()
            }
        }

        // Content height changes across phases (download card vs manual steps vs
        // error). Refit on the NEXT tick so SwiftUI re-lays the observing screen
        // first (same pattern as refitCoverSelectHeight); refit no-ops if unchanged.
        DispatchQueue.main.async { [weak self] in
            self?.hosting?.layoutSubtreeIfNeeded()
            self?.refitWindowHeight()
        }
    }

    /// After the 2s success dwell: drop the install overlay (store → idle), re-read
    /// the engine, and rebuild the current screen (Status normal / Настройки info
    /// card / green Setup). The hybrid blocker/banner disappears because Status now
    /// sees `calibrePresent == true` (task 4.3/4.6); watchers re-arm via present.
    private func finishInstallSuccess() {
        installStore.reset()
        refreshStatusNow()
        present(currentScreen)
    }

    // MARK: - D40 lifecycle (window close / Dock reopen / Cmd-Q during install)

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // D40: closing the window mid-install must NOT quit — the download/install
        // lives on in the Dock. Idle → the original one-window behaviour (close = quit).
        return !(installStore?.isInFlight ?? false)
    }

    /// D40: clicking the Dock icon after the window was closed mid-install re-shows it
    /// with the current progress. `isReleasedWhenClosed = false` kept the window
    /// object alive, so we order it front and re-present the current screen (re-arms
    /// watchers / re-reads live data; StatusView repaints from the live install phase).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            present(currentScreen)
        }
        return true
    }

    /// D40 Cmd-Q policy, keyed to how safely the pipeline can stop right now:
    ///   • downloading (or the sub-second precheck) → ASK. [Продолжить установку] is
    ///     the default (Return) and keeps installing (.cancel); [Прервать и выйти]
    ///     cancels + cleans up the partial, and we defer the quit until the pipeline
    ///     reaches idle (so cleanup finishes first).
    ///   • installing / verifying / activating → UNSAFE to interrupt (mid ditto /
    ///     swap / agent revive) → `.terminateLater`; handleInstallPhase replies true
    ///     at the next terminal phase (end of swap / cleanup).
    ///   • otherwise → quit now.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = installStore else { return .terminateNow }
        switch store.phase {
        case .precheck, .downloading:
            let alert = NSAlert()
            alert.messageText = "Установка движка ещё идёт"
            alert.informativeText = "Скачивание Calibre не завершено. Прервать установку и выйти?"
            alert.alertStyle = .warning
            let keep = alert.addButton(withTitle: "Продолжить установку")
            keep.keyEquivalent = "\r"     // Return = the safe choice
            alert.addButton(withTitle: "Прервать и выйти")
            if alert.runModal() == .alertFirstButtonReturn {
                return .terminateCancel   // keep installing, don't quit
            }
            pendingTerminate = true       // quit once cancel + cleanup reaches idle
            store.cancel()
            return .terminateLater
        case .installing, .verifying, .activating:
            pendingTerminate = true       // quit at the next safe/terminal point
            return .terminateLater
        default:
            return .terminateNow
        }
    }

    // MARK: - Main menu (Cmd+Q, clipboard shortcuts)

    /// Builds the standard AppKit main menu. A bare NSApplication has no menu bar,
    /// so Cmd+Q has no "Завершить" item to fire (→ applicationShouldTerminate and its
    /// D40 "Установка движка ещё идёт" dialog stay unreachable from the keyboard) and
    /// Cmd+C/V/X/A/Z are dead in the Автор/Название fields. Every action is a standard
    /// selector with target = nil, so it resolves through the responder chain (active
    /// text field → key window → NSApp). This only gives those existing selectors a
    /// keyboard-reachable carrier; no behaviour is added or changed.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // Application menu — «Завершить fb2-to-epub» ⌘Q is the carrier for Cmd+Q.
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "О программе fb2-to-epub",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Скрыть fb2-to-epub",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"))
        let hideOthers = NSMenuItem(
            title: "Скрыть остальные",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: "Показать все",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Завершить fb2-to-epub",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — revives Cmd+Z/X/C/V/A in the Автор/Название fields via the
        // responder chain. undo:/redo: are string selectors (routed to the field
        // editor's undo manager); the rest are NSText clipboard selectors.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(NSMenuItem(
            title: "Отменить",
            action: Selector(("undo:")),
            keyEquivalent: "z"))
        let redo = NSMenuItem(
            title: "Повторить",
            action: Selector(("redo:")),
            keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "Вырезать",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(
            title: "Скопировать",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(
            title: "Вставить",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(
            title: "Выбрать всё",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Окно")
        windowMenu.addItem(NSMenuItem(
            title: "Убрать в Dock",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(
            title: "Закрыть",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
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
