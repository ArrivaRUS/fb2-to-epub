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
                onChangeFolder: {},
                onSettings: {},
                onOpenGitHub: { Self.openGitHub() }
            ))

        case .status:
            return AnyView(StatusView(
                state: engine.loadState(),
                agentActive: engine.agentStatus().isActive,
                calibreText: engine.calibreVersion() ?? "—",
                coverCount: engine.coverQueueCount(),
                onOpenFolder: { [weak self] in self?.engine.openWatchFolder() },
                onChangeFolder: {},   // prepared but inert (mutates the live agent).
                onClearHistory: {},   // prepared but inert.
                onSettings: {},       // Settings screen lands later.
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

    /// Open the project's GitHub repo in the default browser (spec: credit footer
    /// link → NSWorkspace.shared.open).
    private static func openGitHub() {
        guard let url = URL(string: Tokens.Project.githubURL) else { return }
        NSWorkspace.shared.open(url)
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
