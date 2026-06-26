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

    /// Which top-level screen is showing. Setup is decided once at launch; the
    /// other two are navigable (Status <-> Выбор обложки).
    private enum Screen { case setup, status, coverSelect }

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
                onSettings: { [weak self] in self?.showSettingsMenu() },
                onOpenGitHub: { Self.openGitHub() }
            ))

        case .status:
            return AnyView(StatusView(
                state: engine.loadState(),
                agentActive: engine.agentStatus().isActive,
                calibreText: engine.calibreVersion() ?? "—",
                coverCount: engine.coverQueueCount(),
                onOpenFolder: { [weak self] in self?.engine.openWatchFolder() },
                onChangeFolder: { [weak self] in self?.changeWatchFolder() },
                onClearHistory: { [weak self] in
                    self?.engine.clearHistory()
                    self?.present(.status)   // rebuild Status -> re-read filtered loadState()
                },
                onSettings: { [weak self] in self?.showSettingsMenu() },
                onSelectCovers: { [weak self] in self?.present(.coverSelect) },
                onOpenGitHub: { Self.openGitHub() }
            ))

        case .coverSelect:
            let queue = engine.loadCoverQueue()
            guard let first = queue.first else {
                // Queue drained (last book resolved/skipped) -> back to Status.
                return buildRoot(.status)
            }
            return AnyView(CoverSelectView(
                entry: first,
                queueTotal: queue.count,
                queueIndex: 1,
                onApply: { [weak self] candidateId in
                    self?.engine.requestCover(bookId: first.bookId,
                                              decision: .apply(candidateId: candidateId))
                    self?.present(.status)
                },
                onKeepAuto: { [weak self] candidateId in
                    self?.engine.requestCover(bookId: first.bookId,
                                              decision: .apply(candidateId: candidateId))
                    self?.present(.status)
                },
                onSkip: { [weak self] in
                    self?.engine.requestCover(bookId: first.bookId, decision: .skip)
                    self?.present(.status)
                },
                onBack: { [weak self] in self?.present(.status) }
            ))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // --- Engine bridge + first-run/migration (M1 behavior, unchanged). ---
        let engine = EngineClient(installerPath: resolveInstallerPath())
        self.engine = engine
        // Production launch: only install when there is no plist; an existing
        // WATCH_DIR is read and kept (migration). This never clobbers the user.
        let outcome = engine.firstRunSetupIfNeeded()

        // --- Decide the initial screen. ---
        // Setup is shown exactly once after the agent gets installed, then never
        // again (a persisted flag flips on first show). The decision is read-only.
        // FB2_FORCE_COVER=1 jumps straight to Выбор обложки for screenshots (it
        // never flips any persisted flag — purely a viewing aid).
        let state = engine.loadState()
        let initial: Screen
        if ProcessInfo.processInfo.environment["FB2_FORCE_COVER"] == "1" {
            initial = .coverSelect
        } else if shouldShowSetup(outcome: outcome, state: state) {
            initial = .setup
        } else {
            initial = .status
        }

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
    }

    /// Navigate to a screen: rebuild the hosting rootView (re-reads live engine
    /// data) and refit the fixed-width window's height to the new content. Used
    /// for Status <-> Выбор обложки. The width stays locked at 400px.
    private func present(_ screen: Screen) {
        guard let hosting = hosting, let window = window else { return }
        hosting.rootView = buildRoot(screen)
        hosting.layoutSubtreeIfNeeded()

        let newHeight = hosting.fittingSize.height
        let newSize = NSSize(width: UI.windowWidth, height: newHeight)
        // Re-lock min == max so the resize sticks and the window stays fixed-width.
        window.minSize = newSize
        window.maxSize = newSize

        // Preserve the top-left corner so the window doesn't jump as height changes.
        var frame = window.frame
        let newFrame = window.frameRect(forContentRect:
            NSRect(x: 0, y: 0, width: UI.windowWidth, height: newHeight))
        let topY = frame.origin.y + frame.size.height
        frame.size = newFrame.size
        frame.origin.y = topY - newFrame.size.height
        window.setFrame(frame, display: true, animate: false)
    }

    /// "Сменить папку" — let the user pick a new watch folder, then re-target the
    /// agent at it via installer.sh. Wired from BOTH the Status and Setup screens.
    ///
    /// Flow:
    ///   1. NSOpenPanel (directories only), pre-seeded with the current watch dir.
    ///   2. On pick → engine.changeWatchFolder(to:). On success → show Status,
    ///      which re-reads the plist and renders the new path (Setup also advances
    ///      to Status — its natural post-setup destination).
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
            present(.status) // rebuild Status -> re-reads the new WATCH_DIR
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

    // MARK: - Settings menu (gear button)

    /// The gear button (`onSettings`) on Status/Setup opens this native NSMenu —
    /// not a new SwiftUI screen. It groups the secondary actions that don't earn a
    /// dedicated control: change folder, open the log, jump to Full Disk Access,
    /// and an About box. Popped at the cursor so it appears right under the gear
    /// the user clicked. All actions run on the main thread (menu actions already
    /// dispatch on main).
    private func showSettingsMenu() {
        let menu = NSMenu()

        let changeItem = NSMenuItem(
            title: "Сменить папку…",
            action: #selector(settingsChangeFolder),
            keyEquivalent: ""
        )
        changeItem.target = self
        menu.addItem(changeItem)

        let resetStatsItem = NSMenuItem(
            title: "Сбросить статистику…",
            action: #selector(settingsResetStats),
            keyEquivalent: ""
        )
        resetStatsItem.target = self
        menu.addItem(resetStatsItem)

        let logItem = NSMenuItem(
            title: "Открыть лог",
            action: #selector(settingsOpenLog),
            keyEquivalent: ""
        )
        logItem.target = self
        menu.addItem(logItem)

        let fdaItem = NSMenuItem(
            title: "Full Disk Access…",
            action: #selector(settingsOpenFullDiskAccess),
            keyEquivalent: ""
        )
        fdaItem.target = self
        menu.addItem(fdaItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(
            title: "О программе",
            action: #selector(settingsAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Pop at the cursor (screen coordinates) so the menu lands at the gear the
        // user just clicked.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Menu: "Сменить папку…" — reuse the existing watch-folder flow (NSOpenPanel).
    @objc private func settingsChangeFolder() {
        changeWatchFolder()
    }

    /// Menu: "Сбросить статистику…" — confirm, then zero the "сконвертировано всего"
    /// counter via an app-owned baseline (engine.resetStats() never touches
    /// state.json). On confirm, rebuild Status so the card re-reads from zero.
    /// "Отмена" is the default/cancel button so a stray Return doesn't reset.
    @objc private func settingsResetStats() {
        let alert = NSAlert()
        alert.messageText = "Сбросить статистику?"
        alert.informativeText = "Счётчик сконвертированных книг обнулится. "
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
            engine.resetStats()
            present(.status) // rebuild Status -> re-reads loadState() (now baselined)
        }
    }

    /// Menu: "Открыть лог" — open ~/Library/Logs/fb2-to-epub.log in the default
    /// app. If the log file doesn't exist yet, fall back to the Logs directory; if
    /// even that is missing, show a non-fatal alert instead of crashing.
    @objc private func settingsOpenLog() {
        let logsDir = "\(NSHomeDirectory())/Library/Logs"
        let logPath = "\(logsDir)/fb2-to-epub.log"
        let fm = FileManager.default
        if fm.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        } else if fm.fileExists(atPath: logsDir) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logsDir))
        } else {
            let alert = NSAlert()
            alert.messageText = "Лог ещё не создан"
            alert.informativeText = "Файл ~/Library/Logs/fb2-to-epub.log появится "
                + "после первой конвертации."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Menu: "Full Disk Access…" — jump straight to the Full Disk Access pane in
    /// System Settings so the user can grant access to the agent.
    @objc private func settingsOpenFullDiskAccess() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Menu: "О программе" — a small About box with the app version, offering to
    /// open the GitHub repo.
    @objc private func settingsAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "—"
        let alert = NSAlert()
        alert.messageText = "fb2-to-epub"
        alert.informativeText = "Версия \(version)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Открыть на GitHub")
        alert.addButton(withTitle: "ОК")
        if alert.runModal() == .alertFirstButtonReturn {
            Self.openGitHub()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.regular) // dock icon + menu bar — a normal windowed app
let delegate = AppDelegate()
app.delegate = delegate
app.run()
