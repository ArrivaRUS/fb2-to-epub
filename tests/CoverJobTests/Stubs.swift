// Stubs.swift — test-only stand-ins for the SwiftUI-file types that the
// Foundation-only engine write-layer references at compile time.
//
// WHY this exists
// ---------------
// `EngineClient+Status.swift` (Foundation) references `CoverQueueStore` /
// `CoverQueueEntry`, but those types are DEFINED inside `CoverSelectView.swift`,
// which `import SwiftUI`. Compiling the real CoverSelectView into a headless CLI
// test runner would drag in the whole SwiftUI/AppKit UI layer for no reason.
//
// The cover-JOB tests here exercise ONLY the write-layer helpers
// (requestCover / requestApplyGenerated / requestConfirmAuto), which touch the
// queue store ONLY through `CoverQueueStore(home:).coversDir` — to compute the
// `covers/jobs` directory. So this inert stub reproduces the ONE thing the
// write-layer needs: a `coversDir` that honors the FB2_COVERS_DIR override, so
// every job lands inside the throwaway temp dir the test set via that env var.
//
// This is TEST CODE ONLY. It does not ship — the production binary compiles the
// real CoverSelectView via build/build-app.sh (SWIFT_SRCS).

import Foundation

/// Inert stand-in. The write-layer never decodes/observes this type; it only
/// exists so `loadCoverQueue()` / `loadPending()` type-check.
struct CoverQueueEntry: Codable, Equatable {
    let bookId: String
}

/// Inert stand-in whose `coversDir` matches the real store's rule EXACTLY: honor
/// FB2_COVERS_DIR when set (the test harness points it at a `mktemp -d`), else
/// root under `home`. That is the only surface the job write-layer touches.
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
    func loadEntry(bookId: String) -> CoverQueueEntry? { nil }
}
