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
    /// Kept so action closures can call back into the engine for the whole run.
    private var engine: EngineClient!

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

    /// Build the SwiftUI root: Setup (first run) or Status (steady state).
    private func rootView(engine: EngineClient, outcome: FirstRunOutcome,
                          state: EngineState, agentActive: Bool,
                          calibreText: String, coverCount: Int) -> AnyView {
        if shouldShowSetup(outcome: outcome, state: state) {
            let watchDir = displayWatchDir(engine.readWatchDir())
            return AnyView(SetupView(
                calibreVersion: engine.calibreVersion(),
                watchDir: watchDir,
                onOpenFolder: { [weak self] in self?.engine.openWatchFolder() },
                onChangeFolder: {},   // M3: prepared but inert (mutates the live agent).
                onSettings: {},       // Settings screen lands later.
                onOpenGitHub: { Self.openGitHub() }
            ))
        }
        return AnyView(StatusView(
            state: state,
            agentActive: agentActive,
            calibreText: calibreText,
            coverCount: coverCount,
            onOpenFolder: { [weak self] in self?.engine.openWatchFolder() },
            onChangeFolder: {},   // prepared but inert (mutates the live agent).
            onClearHistory: {},   // prepared but inert.
            onSettings: {},       // Settings screen lands later.
            onSelectCovers: {},   // Cover picker is M5.
            onOpenGitHub: { Self.openGitHub() }
        ))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // --- Engine bridge + first-run/migration (M1 behavior, unchanged). ---
        let engine = EngineClient(installerPath: resolveInstallerPath())
        self.engine = engine
        // Production launch: only install when there is no plist; an existing
        // WATCH_DIR is read and kept (migration). This never clobbers the user.
        let outcome = engine.firstRunSetupIfNeeded()

        // --- M2/M3: read the data both screens render. ---
        let state = engine.loadState()
        let agentActive = engine.agentStatus().isActive
        let calibreText = engine.calibreVersion() ?? "—"
        // Cover queue lands at M4/M5; the row stays hidden while the count is 0.
        let coverCount = 0

        // --- M3: pick the first-run Setup screen vs. the steady Status screen. ---
        // Setup is shown exactly once after the agent gets installed, then never
        // again (a persisted flag flips on first show). The decision is read-only:
        // we never mutate the agent here.
        let hosting = NSHostingView(rootView: rootView(
            engine: engine, outcome: outcome, state: state,
            agentActive: agentActive, calibreText: calibreText, coverCount: coverCount
        ))
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
