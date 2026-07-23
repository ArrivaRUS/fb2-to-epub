// FDAShot — a standalone OFFSCREEN renderer for the FDA-onboarding подачи (v1.0.1).
//
// SAFE BY CONSTRUCTION: it never builds AppDelegate, never spawns launchd, never
// reads/writes the engine home. It constructs a fake StatusStore + an IDLE
// InstallStore (which does nothing until .start(), never called) and drives the FDA
// card purely via `folderForced`/`forcedFolderState`. Every action closure is a
// no-op. So it touches NOTHING of the user's live agent — only pixels → PNG.
//
// Usage: FDAShot <out-dir>   (compiled together with the app view sources minus main.swift)
//
// COMPILE + RENDER (kept here so this harness can't silently rot — no build script wires
// it). Run from the repo root; it links the SAME app sources as build/build-app.sh MINUS
// app/main.swift (this file supplies its own @main entry), plus this file:
//
//   SDK="$(xcrun --show-sdk-path --sdk macosx)"; OUT=/tmp/fda-shots; BIN="$(mktemp -d)/FDAShot"
//   xcrun swiftc -sdk "$SDK" -target "$(uname -m)-apple-macos11.0" \
//     app/CalibreLocator.swift app/CalibreInstaller.swift app/EngineClient.swift \
//     app/EngineClient+Status.swift app/StateModel.swift app/Tokens.swift \
//     app/StatusView.swift app/SetupView.swift app/EngineSetupCard.swift \
//     app/FolderAccessCard.swift app/CoverSelectView.swift app/SettingsView.swift \
//     app/UpdateChecker.swift app/CoverGenerator.swift tests/FDAShot/main.swift -o "$BIN" \
//   && "$BIN" "$OUT"            # writes fda-*.png into $OUT
//
// If the app gains/renames a view source, mirror build/build-app.sh's SWIFT_SRCS here.

import AppKit
import SwiftUI

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no dock icon; we only render offscreen

/// Render any SwiftUI view (fixed 400px width) into a PNG at <out>/<name>.png.
@MainActor
func shoot<V: View>(_ name: String, _ view: V) {
    let host = NSHostingView(rootView: AnyView(view.frame(width: 400)))
    host.frame = NSRect(x: 0, y: 0, width: 400, height: max(1, host.fittingSize.height))
    // Put it in an offscreen window so backgrounds/materials render.
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                       backing: .buffered, defer: false)
    win.contentView = host
    win.appearance = NSAppearance(named: .darkAqua)
    host.layoutSubtreeIfNeeded()
    let bounds = host.bounds
    guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else {
        print("FAIL \(name): no bitmap rep"); return
    }
    host.cacheDisplay(in: bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("FAIL \(name): no png"); return
    }
    let path = (outDir as NSString).appendingPathComponent("\(name).png")
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("OK \(name).png  \(Int(bounds.width))x\(Int(bounds.height))  \(png.count) bytes")
    } catch {
        print("FAIL \(name): \(error)")
    }
}

// Fake engine state: agent present, folder access denied. `recent` non-empty toggles
// the banner (has history) vs blocker (none) hybrid.
func fakeState(recent: [ConversionEntry]) -> EngineState {
    EngineState(
        schema: 1,
        agent: EngineAgentInfo(watchDir: "\(NSHomeDirectory())/Desktop/fb2-to-epub",
                               folderAccess: .denied,
                               folderAccessTs: "2026-07-22T16:00:00Z"),
        totals: EngineTotals(convertedTotal: 54, today: 2, failedToday: 0),
        recent: recent,
        lastConversion: recent.first)
}

let sampleRecent = [
    ConversionEntry(src: "роман.fb2", dst: "роман.epub", ts: "2026-07-22T15:40:00Z", status: "ok"),
    ConversionEntry(src: "повесть.fb2", dst: "повесть.epub", ts: "2026-07-22T15:10:00Z", status: "ok"),
]

// An idle InstallStore drives NOTHING (phase = .idle until .start(), never called).
let idleInstall = InstallStore(config: CalibreInstaller.Config(home: NSHomeDirectory(), env: [:]),
                               activate: { true })

func statusView(history: Bool, state fa: FolderAccessCard.State) -> some View {
    let store = StatusStore(state: fakeState(recent: history ? sampleRecent : []),
                            agentActive: true, coverCount: 0,
                            calibrePresent: true, hasRawHistory: history)
    return StatusView(store: store, installStore: idleInstall,
                      folderForced: true, forcedFolderState: fa)
}

DispatchQueue.main.async {
    // Status blocker (no history) across the automat.
    shoot("fda-blocker-denied",       statusView(history: false, state: .denied))
    shoot("fda-blocker-checking",     statusView(history: false, state: .checking))
    shoot("fda-blocker-stilldenied",  statusView(history: false, state: .stillDenied))
    shoot("fda-blocker-timeout",      statusView(history: false, state: .timeout))
    // Status banner (has history) — content stays visible + muted.
    shoot("fda-banner-denied",        statusView(history: true, state: .denied))
    shoot("fda-banner-checking",      statusView(history: true, state: .checking))
    shoot("fda-banner-timeout",       statusView(history: true, state: .timeout))
    // Settings warn row (denied replaces the passive FDA row).
    shoot("fda-settings-denied",
          SettingsView(installStore: idleInstall, folderDenied: true,
                       watchDir: "~/Desktop/fb2-to-epub", calibreVersion: "7.21"))
    // Setup amber «ДОСТУП К ПАПКЕ» step after ДВИЖОК.
    shoot("fda-setup-denied",
          SetupView(calibreVersion: "7.21", watchDir: "~/Desktop/fb2-to-epub",
                    folderDenied: true))
    NSApp.terminate(nil)
}

app.run()
