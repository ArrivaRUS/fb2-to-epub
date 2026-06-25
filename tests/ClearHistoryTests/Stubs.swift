// Stubs.swift — test-only stand-ins for the SwiftUI-file types that the
// Foundation-only engine logic references at compile time.
//
// WHY this exists
// ---------------
// `EngineClient+Status.swift` (Foundation) references `CoverQueueStore` /
// `CoverQueueEntry`, but those types are DEFINED inside `CoverSelectView.swift`,
// which `import SwiftUI`. Compiling the real CoverSelectView into a headless
// CLI test runner would drag in the whole SwiftUI/AppKit UI layer for no reason.
//
// These regression tests exercise ONLY the "Очистить" history logic
// (clearHistory + loadState filtering), which never calls into the cover queue.
// So we provide a minimal, inert stub with the exact surface EngineClient+Status
// needs to compile:
//   - CoverQueueEntry  : referenced as the element type of loadCoverQueue()
//   - CoverQueueStore  : referenced for coversDir / pendingCount / loadPending
//
// This is TEST CODE ONLY. It does not ship and does not touch production
// behaviour — the production binary compiles the real CoverSelectView via
// build/build-app.sh (SWIFT_SRCS). If the real CoverQueueStore surface ever
// changes in a way these tests start to depend on, this stub is the one place
// to update — but the "Очистить" path under test does not use it.

import Foundation

/// Inert stand-in. The real one (CoverSelectView.swift) is a Codable model; the
/// only field these tests would ever observe is bookId, so that is all we keep.
struct CoverQueueEntry: Codable, Equatable {
    let bookId: String
}

/// Inert stand-in. Rooted at `home` like the real store, so even if some path
/// were exercised it would stay inside the throwaway HOME. All reads return
/// "empty" — the "Очистить" logic never invokes these.
struct CoverQueueStore {
    let home: String
    init(home: String) { self.home = home }

    var coversDir: String {
        if let override = ProcessInfo.processInfo.environment["FB2_COVERS_DIR"],
           !override.isEmpty {
            return override
        }
        return "\(home)/Library/Application Support/fb2-to-epub/covers"
    }

    func pendingCount() -> Int { 0 }
    func loadPending() -> [CoverQueueEntry] { [] }
}
