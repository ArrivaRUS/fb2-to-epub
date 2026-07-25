// StatusView — the real Status screen (M2). Replaces the M1 debug snapshot.
//
// Built strictly from design/spec-ui.md + design/mockups/ui-native.html. Every
// color/size/inset comes from Tokens (no inline literals). Layout mirrors the
// mockup top-to-bottom: header, hero (status ring + metrics), 3 stat cards, a
// grouped settings list, the recent-conversions list, and the footer.
//
// Data: EngineState (state.json) for numbers/paths/recent + AgentStatus
// (EngineClient) for the live agent/active state. Mutating actions are wired to
// closures the host supplies; only "open folder" is functional in M2.

import SwiftUI
import AppKit

// MARK: - UI glyphs (SF Symbols)

/// A UI glyph rendered as an SF Symbol — the same approach as the sibling
/// mp3-to-m4b app (Image(systemName:)). Replaces the old hand-drawn stroke paths
/// (an enum of SVG `d` builders) that rendered crooked at small sizes (the gear
/// read as a flower, the cover as mush). `size`/`weight` mirror the old glyph box
/// + stroke weight so each icon keeps its slot; color is applied by the caller via
/// `.foregroundColor`. Brand marks (AppIcon below) stay vector — these are only
/// the small functional UI glyphs.
private func sfIcon(_ name: String, size: CGFloat, weight: Font.Weight = .regular) -> some View {
    Image(systemName: name)
        .font(.system(size: size, weight: weight))
}

// MARK: - App icon (brand squircle + book-spark)

private struct AppIcon: View {
    var size: CGFloat = Tokens.M.appIconSize
    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.M.appIconRadius, style: .continuous)
            .fill(Tokens.G.appIcon)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.M.appIconRadius, style: .continuous)
                    .stroke(Color.white(0.4), lineWidth: 0.5)
                    .blendMode(.overlay)
            )
            .overlay(BookSpark().frame(width: size * 0.62, height: size * 0.62))
            .frame(width: size, height: size)
            .shadow(color: Color(.sRGB, red: 1, green: 61/255, blue: 90/255, opacity: 0.55),
                    radius: 8, x: 0, y: 6)
    }

    /// Open book with a spark, white on the gradient — a clean redraw of the
    /// mockup's two pages + center seam + 4-point star.
    private struct BookSpark: View {
        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let cx = w / 2, cy = h / 2
                let u = w / 24 // design unit
                ZStack {
                    // Left page
                    pageLeft(cx: cx, cy: cy, u: u)
                        .fill(Color.white(0.16))
                    pageLeft(cx: cx, cy: cy, u: u)
                        .stroke(Color.white(0.85), lineWidth: 1.1 * u)
                    // Right page
                    pageRight(cx: cx, cy: cy, u: u)
                        .fill(Color.white(0.16))
                    pageRight(cx: cx, cy: cy, u: u)
                        .stroke(Color.white(0.85), lineWidth: 1.1 * u)
                    // Seam
                    Path { p in
                        p.move(to: .init(x: cx, y: cy - 7.5 * u))
                        p.addLine(to: .init(x: cx, y: cy + 8 * u))
                    }.stroke(Color.white(0.6), lineWidth: 1 * u)
                    // Spark (4-point star), top center
                    star(cx: cx, cy: cy, u: u).fill(Color.white)
                }
            }
        }
        private func pageLeft(cx: CGFloat, cy: CGFloat, u: CGFloat) -> Path {
            var p = Path()
            p.move(to: .init(x: cx - 9 * u, y: cy - 7 * u))
            p.addQuadCurve(to: .init(x: cx - 7 * u, y: cy - 8.5 * u),
                           control: .init(x: cx - 9 * u, y: cy - 8.5 * u))
            p.addLine(to: .init(x: cx - 1 * u, y: cy - 7.5 * u))
            p.addLine(to: .init(x: cx - 1 * u, y: cy + 7.5 * u))
            p.addLine(to: .init(x: cx - 7 * u, y: cy + 8.5 * u))
            p.addQuadCurve(to: .init(x: cx - 9 * u, y: cy + 7 * u),
                           control: .init(x: cx - 9 * u, y: cy + 8.5 * u))
            p.closeSubpath()
            return p
        }
        private func pageRight(cx: CGFloat, cy: CGFloat, u: CGFloat) -> Path {
            var p = Path()
            p.move(to: .init(x: cx + 9 * u, y: cy - 7 * u))
            p.addQuadCurve(to: .init(x: cx + 7 * u, y: cy - 8.5 * u),
                           control: .init(x: cx + 9 * u, y: cy - 8.5 * u))
            p.addLine(to: .init(x: cx + 1 * u, y: cy - 7.5 * u))
            p.addLine(to: .init(x: cx + 1 * u, y: cy + 7.5 * u))
            p.addLine(to: .init(x: cx + 7 * u, y: cy + 8.5 * u))
            p.addQuadCurve(to: .init(x: cx + 9 * u, y: cy + 7 * u),
                           control: .init(x: cx + 9 * u, y: cy + 8.5 * u))
            p.closeSubpath()
            return p
        }
        private func star(cx: CGFloat, cy: CGFloat, u: CGFloat) -> Path {
            var p = Path()
            p.move(to: .init(x: cx, y: cy - 12 * u))
            p.addLine(to: .init(x: cx + 1.6 * u, y: cy - 8.4 * u))
            p.addLine(to: .init(x: cx + 5 * u, y: cy - 7 * u))
            p.addLine(to: .init(x: cx + 1.6 * u, y: cy - 5.6 * u))
            p.addLine(to: .init(x: cx, y: cy - 2 * u))
            p.addLine(to: .init(x: cx - 1.6 * u, y: cy - 5.6 * u))
            p.addLine(to: .init(x: cx - 5 * u, y: cy - 7 * u))
            p.addLine(to: .init(x: cx - 1.6 * u, y: cy - 8.4 * u))
            p.closeSubpath()
            return p
        }
    }
}

// MARK: - Status ring

/// The hero progress ring. A brand-orange arc fills CLOCKWISE from 12 o'clock as
/// the engine converts a dropped batch, reaching a full circle at 100%. Driven by
/// two inputs the host derives from `state.batch`:
///   • `progress` — done/total (0...1); 1.0 when there's no active batch.
///   • `active`   — a batch is in flight right now (engine `batch.active`).
///
/// Layers, back to front: a dim base track, the trimmed gradient arc (with a soft
/// orange glow for the "красиво"), and a center glyph — the ► play triangle at
/// rest, or a live "M/N" file counter while converting. The arc animates with a
/// short easeInOut keyed on `progress`, so each `done` increment glides the arc
/// forward; a fresh batch (progress jumps back toward 0) eases back smoothly too.
private struct StatusRing: View {
    let progress: Double      // 0...1, clamped by caller
    let active: Bool          // a batch is converting right now
    let done: Int             // current batch's converted count (for "M/N")
    let total: Int            // current batch's total (for "M/N")
    let agentPaused: Bool     // agent off -> rest the ring in a muted state
    /// CAL-2 (banner A): the engine is missing → the ring is muted to just its
    /// track + a grey ► play glyph (no arc, no start-cap, no glow), matching
    /// refs/direction-A-final.png. Default false keeps the normal ring untouched.
    var engineMissing: Bool = false

    /// Drives the optional finish flourish (a brief emerald-tinged pulse the first
    /// time a run reaches 100%). Reset whenever a new batch starts.
    @State private var didFlourish = false

    var body: some View {
        ZStack {
            // Base track — a thin muted ring behind everything (the "unfilled" part).
            Circle()
                .stroke(Tokens.C.barTrack, lineWidth: Tokens.M.ringStroke)

            // Progress arc: brand gradient, round cap, trimmed to `progress`, rotated
            // so 0% sits at 12 o'clock and growth runs clockwise.
            Circle()
                .trim(from: 0, to: max(0.0, min(1.0, progress)))
                .stroke(Tokens.G.ring,
                        style: StrokeStyle(lineWidth: Tokens.M.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Soft brand-orange glow on the filled arc — the "красиво".
                .shadow(color: Tokens.C.accentOrange.opacity(active ? 0.55 : 0.35),
                        radius: active ? 8 : 5)
                // Brief emerald wash the moment a run completes.
                .overlay(finishWash)
                .animation(.easeInOut(duration: 0.5), value: progress)
                .opacity(engineMissing ? 0 : (agentPaused && !active ? 0.85 : 1))

            // Start-cap patch: a solid round dot of the gradient's START color
            // (#FFB23D), exactly the stroke diameter, centered on the 12 o'clock
            // start point. The arc's round START cap overshoots counter-clockwise
            // past 12 o'clock onto the "360°-side" of the angular seam, where the
            // gradient is magenta (#E63CC8) — so the very start read pink/violet
            // instead of orange. This dot repaints just that cap footprint pure
            // orange, leaving the rest of the sweep (orange→red→magenta) and the
            // END cap untouched. Kept as a STABLE element toggled by .opacity (not
            // an `if`) so it can't be inserted-with-transition during a window refit
            // (lesson .patches/011); opacity 0 at progress 0 = no stray dot.
            startCap

            // Center: live counter while converting, otherwise the play glyph.
            center
        }
        .frame(width: Tokens.M.ringSize, height: Tokens.M.ringSize)
        .padding(Tokens.M.ringStroke / 2) // keep round caps inside the box
        .onChange(of: progressBucket) { _ in evaluateFlourish() }
        .onChange(of: active) { _ in evaluateFlourish() }
        .onAppear { didFlourish = progress >= 1.0 }
    }

    // --- Start cap -----------------------------------------------------------
    /// Solid round dot covering the arc's START round cap so 12 o'clock is pure
    /// orange (#FFB23D — the angular gradient's 0.00 stop, NOT accentOrange/#FF8A3D)
    /// instead of bleeding the seam's magenta. Diameter == ringStroke so it matches
    /// the cap exactly; centered on the 12 o'clock path point via a -ringSize/2 y
    /// offset from the ZStack center. Faded out at progress 0 so an idle ring shows
    /// no extra dot; carries the same arc glow so it reads as one continuous fill.
    private var startCap: some View {
        Circle()
            .fill(Color(hex: "#FFB23D"))
            .frame(width: Tokens.M.ringStroke, height: Tokens.M.ringStroke)
            .offset(y: -Tokens.M.ringSize / 2)
            .shadow(color: Tokens.C.accentOrange.opacity(active ? 0.55 : 0.35),
                    radius: active ? 8 : 5)
            .opacity(engineMissing ? 0 : (progress > 0 ? (agentPaused && !active ? 0.85 : 1) : 0))
            .animation(.easeInOut(duration: 0.5), value: progress > 0)
            .allowsHitTesting(false)
    }

    // --- Center content ------------------------------------------------------
    /// Both glyphs live in ONE fixed, centered ZStack and are toggled by OPACITY —
    /// never by an `if/else` that swaps view identity. That distinction is the whole
    /// fix (see .patches/011): the old `if active { Text } else { Icon }` changed the
    /// center's identity on the live `false→true` flip, so SwiftUI treated it as a
    /// remove+insert and animated the inserted `Text` in via `.transition`. When that
    /// insertion coincided with the host's `layoutSubtreeIfNeeded()`/`setFrame` refit
    /// (the window is relaid out the instant a batch starts), the freshly-inserted
    /// Text had no resolved geometry yet and animated from the window's origin —
    /// flying up over the title and oscillating. With a single stable container both
    /// children keep their identity and their centered slot for the whole run; only
    /// `opacity` cross-fades, which cannot move them out of the ring. The breathing
    /// `scaleEffect`/`repeatForever` pulse is dropped on purpose: stability over
    /// "дыхание" (it also fed the oscillation). The arc's own `progress` animation is
    /// untouched.
    private var center: some View {
        let showCounter = active && total > 0
        return ZStack {
            // play.fill (SF Symbol) sized to fill the old 30px ring-center box.
            // Muted to textVeryMute (#5C546B) when the engine is missing (banner A).
            sfIcon("play.fill", size: 23, weight: .semibold)
                .foregroundColor(engineMissing ? Tokens.C.textVeryMute : Tokens.C.accentOrange)
                .opacity(showCounter ? 0 : 1)

            Text("\(done)/\(total)")
                .font(.system(size: 19, weight: .bold))
                .monoDigitsCompat()
                .foregroundColor(Tokens.C.accentOrange)
                .opacity(showCounter ? 1 : 0)
        }
        // A short opacity cross-fade between the two states, scoped strictly to the
        // toggle so nothing else (a sibling `progress` change, a window refit) can be
        // captured as a move. No layout/transition animation here on purpose.
        .animation(.easeInOut(duration: 0.25), value: showCounter)
    }

    // --- Finish flourish -----------------------------------------------------
    /// A short emerald glow layered over the arc the first time it completes.
    @ViewBuilder
    private var finishWash: some View {
        if didFlourish {
            Circle()
                .trim(from: 0, to: 1)
                .stroke(Tokens.C.emerald,
                        style: StrokeStyle(lineWidth: Tokens.M.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Tokens.C.emerald.opacity(0.7), radius: 7)
                .opacity(didFlourish ? 0 : 0.9)
                .animation(.easeOut(duration: 0.9), value: didFlourish)
                .allowsHitTesting(false)
        }
    }

    /// Coarse progress signal so the flourish fires once at completion, not on
    /// every fractional tick. (onChange wants an Equatable; Double works but this
    /// keeps intent clear.)
    private var progressBucket: Int { progress >= 1.0 ? 1 : 0 }

    private func evaluateFlourish() {
        if active {
            // A run is in flight: arm the flourish so it can fire on the next 100%.
            if progress < 1.0 { didFlourish = false }
        } else if progress >= 1.0 && !didFlourish {
            // Completed (batch cleared, ring full): play the one-shot wash.
            didFlourish = true
        }
    }
}

// MARK: - Small reusable pieces

/// Caps label (.cap): 9 / 700 / +1.2 tracking / tertiary.
private struct CapLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Tokens.F.cap)
            .foregroundColor(Tokens.C.textTertiary)
            .trackingCompat(Tokens.Track.cap)
    }
}

/// The status pill / badge. Emerald when `active` (the "красиво" live look), and a
/// muted grey variant when paused — same dot+pill geometry either way so the
/// header badge only changes color, never size, as the agent flips on/off.
private struct EmeraldBadge: View {
    let text: String
    var padded: Bool = true
    var active: Bool = true

    // Muted (paused) palette: tertiary-grey dot/text on a faint white surface,
    // mirroring the emerald set's alphas (.12 fill / .25-ish border) so the pill
    // reads "off" without shouting. Kept local — a paused-badge one-off, not a
    // reusable global role.
    private var dotColor: Color { active ? Tokens.C.emerald : Tokens.C.textTertiary }
    private var textColor: Color { active ? Tokens.C.emerald : Tokens.C.textSecondary }
    private var fillColor: Color { active ? Tokens.C.emeraldBg : Color.white(0.05) }
    private var borderColor: Color { active ? Tokens.C.emeraldBorder : Color.white(0.10) }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
                .shadow(color: active ? Tokens.C.emerald : .clear, radius: 3)
            Text(text)
                .font(Tokens.F.badge)
                .foregroundColor(textColor)
        }
        .padding(.horizontal, padded ? 9 : 0)
        .padding(.vertical, padded ? 3 : 0)
        .background(
            Capsule(style: .continuous).fill(fillColor)
        )
        .overlay(
            Capsule(style: .continuous).stroke(borderColor, lineWidth: 1)
        )
    }
}

/// The honest amber "КОНВЕРТАЦИЯ НЕДОСТУПНА" pill (tokens.md §8), shown in place of
/// the emerald agent badge when the engine is missing. `.pill-warn`: tintOrange
/// fill + warnBorder30 stroke, 7px radius (not a Capsule), accent-orange dot+text.
private struct WarnPill: View {
    let text: String
    var body: some View {
        HStack(spacing: Tokens.CO.pillGap) {
            Circle()
                .fill(Tokens.C.accentOrange)
                .frame(width: Tokens.CO.pillDot, height: Tokens.CO.pillDot)
            Text(text)
                .font(Tokens.F.pill)
                .foregroundColor(Tokens.C.accentOrange)
        }
        .padding(.horizontal, Tokens.CO.pillPadH)
        .padding(.vertical, Tokens.CO.pillPadV)
        .background(
            RoundedRectangle(cornerRadius: Tokens.CO.pillRadius, style: .continuous)
                .fill(Tokens.C.tintOrange))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.CO.pillRadius, style: .continuous)
                .stroke(Tokens.CO.warnBorder30, lineWidth: 1))
    }
}

/// A compact hero counter: a big colored number over a caps label. Reuses the
/// stat-card type scale (statVal value + 9/700 caps label) so the two counters
/// that moved up into the hero keep the exact "крупное число + подпись" look they
/// had as stat cards — just without the card chrome / progress bar.
private struct HeroCounter: View {
    let value: String
    let cap: String
    let valueColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Tokens.F.statVal)
                .foregroundColor(valueColor)
                .monoDigitsCompat()
            CapLabel(text: cap)
        }
    }
}

/// Card surface (fill + 1px border) at a given corner radius.
private func card(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(Tokens.C.cardBg)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Tokens.C.cardBorder, lineWidth: 1)
        )
}

// MARK: - StatusStore (live data source)

/// Observable holder for the four live values the Status screen renders. The host
/// (`AppDelegate`) re-reads the engine when the watcher rewrites state.json (a
/// file-system event on the state dir, debounced) and on window focus, then writes
/// here on the main thread; SwiftUI repaints only the changed bits — no view
/// rebuild, no flicker, no polling. Reads come straight from `engine.loadState()`
/// (already baselined for "Очистить" / "Сбросить статистику"), so live updates
/// honor those resets.
final class StatusStore: ObservableObject {
    @Published var state: EngineState
    @Published var agentActive: Bool
    @Published var coverCount: Int
    /// CAL-2: is the Calibre engine present right now (locator, 3×stat — NO process
    /// spawn in the refresh cycle). Drives the honest badge/footer + the D37 hybrid.
    @Published var calibrePresent: Bool
    /// CAL-2: does the user have RAW conversion history (unfiltered snapshot)? Picks
    /// banner A (has history) vs blocker B (none). Raw so «Сбросить статистику» can't
    /// flip A→B (D37). Refreshed alongside the others.
    @Published var hasRawHistory: Bool
    /// FDA-3: the host-owned TRANSIENT recheck state (checking/stillDenied/timeout)
    /// that «Проверить снова» drives. nil = no recheck in flight → the card renders
    /// straight from the live `state.agent.folderAccess` (denied) instead. Never
    /// persisted; lives only while the app coordinates a kickstart+probe round-trip.
    @Published var folderRecheck: FolderAccessCard.State?

    /// v1.0.3 (fix #2): brief "Путь скопирован ✓" acknowledgement on the FDA card's
    /// primary CTA. Set true by the host ONLY after a VERIFIED successful clipboard
    /// write (never on failure), auto-reset after ~2.5 s (short label swap). Never
    /// persisted; drives a label-only repaint, no view rebuild.
    @Published var folderPathCopied: Bool = false

    /// v1.0.3 (fix #2/#3): an HONEST one-line hint under the FDA CTA when the press
    /// could NOT hand the user a usable path — either the on-launch self-heal failed
    /// and the plist's PA0 is still the dead runner.sh (nothing safe to copy), or the
    /// clipboard write itself did not take. Mutually exclusive with `folderPathCopied`
    /// (a failure never leaves a stale ✓). nil = no hint (the happy path and the
    /// FDAShot harness, which never sets it) → byte-identical rendering.
    @Published var folderCopyHint: String? = nil

    init(state: EngineState, agentActive: Bool, coverCount: Int,
         calibrePresent: Bool = true, hasRawHistory: Bool = false,
         folderRecheck: FolderAccessCard.State? = nil) {
        self.state = state
        self.agentActive = agentActive
        self.coverCount = coverCount
        self.calibrePresent = calibrePresent
        self.hasRawHistory = hasRawHistory
        self.folderRecheck = folderRecheck
    }
}

// MARK: - StatusView

struct StatusView: View {
    @ObservedObject var store: StatusStore
    /// CAL-4: the live install pipeline. When it is in flight (downloading/…/verifying)
    /// its phase drives the hybrid; when idle it defers to `store.calibrePresent`. The
    /// host (AppDelegate) owns the one instance and observes it too (window refit +
    /// D40 lifecycle). Screenshot runs pass the idle store and `forcedInstallPhase`
    /// wins, so they stay unchanged.
    @ObservedObject var installStore: InstallStore

    // Actions (only openFolder is functional in M2).
    var onOpenFolder: () -> Void = {}
    var onClearHistory: () -> Void = {}
    var onSettings: () -> Void = {}
    var onSelectCovers: () -> Void = {}
    /// Opens the GitHub repo. Host wires this to NSWorkspace.shared.open (spec).
    var onOpenGitHub: () -> Void = {}

    /// CAL-2 screenshot overlay (FB2_FORCE_INSTALL_STATE): forces a specific install
    /// phase into the hybrid, independent of the real engine. nil = drive off the
    /// live `store.calibrePresent`. Display-only; never persisted.
    var forcedInstallPhase: EngineSetupCard.Phase? = nil

    /// CAL-2 read-only actions on the onboarding card. All default to no-ops — the
    /// buttons render but do nothing (the real pipeline lands in CAL-4).
    var onInstallEngine: () -> Void = {}
    var onCancelInstall: () -> Void = {}
    var onRetryInstall: () -> Void = {}
    var onManualInstall: () -> Void = {}
    var onOpenCalibreSite: () -> Void = {}
    var onRecheckEngine: () -> Void = {}
    var onRetryAgent: () -> Void = {}

    /// FDA-2 screenshot overlay (FB2_FORCE_FOLDER_ACCESS): forces an FDA card state
    /// independent of the live agent. `folderForced` = the env var was present (so an
    /// `ok`/`nil` force means "show NO card"); `forcedFolderState` = the parsed state.
    var folderForced: Bool = false
    var forcedFolderState: FolderAccessCard.State? = nil
    /// FDA actions (inert in FDA-2; wired at FDA-3). onOpenFolderAccess opens the FDA
    /// pane AND copies the runner path; onRecheckFolder kicks the agent + waits.
    var onOpenFolderAccess: () -> Void = {}
    var onRecheckFolder: () -> Void = {}

    // Live data, proxied from the store so the rest of the view reads the same
    // names as before. Touching these inside `body` registers the @ObservedObject
    // dependency, so SwiftUI repaints when the host updates the store (on a
    // state.json change or window focus).
    private var state: EngineState { store.state }
    private var agentActive: Bool { store.agentActive }
    private var coverCount: Int { store.coverCount }

    // Derived watch dir, tilde-collapsed for display.
    private var watchDir: String {
        let raw = state.agent.watchDir ?? "~/Desktop/fb2-to-epub"
        let home = EngineHome.resolve()
        return raw.hasPrefix(home) ? "~" + raw.dropFirst(home.count) : raw
    }

    // Hero-ring inputs, derived from the live batch in state.json. Absent batch
    // (older state / nothing in flight) → progress 1.0 (calm full circle), not
    // converting. `EngineBatch.progress` already clamps and handles total==0.
    private var batchActive: Bool { state.batch?.active ?? false }
    private var batchProgress: Double { state.batch?.progress ?? 1.0 }
    private var batchDone: Int { state.batch?.done ?? 0 }
    private var batchTotal: Int { state.batch?.total ?? 0 }

    /// The effective onboarding phase for this render. Priority:
    ///   1. the screenshot overlay (`forcedInstallPhase`) — design-review aid;
    ///   2. the LIVE install pipeline (CAL-4) — downloading/installing/verifying/
    ///      success/error/agentActivationFailed/manual while a run is in flight;
    ///   3. idle → engine presence decides: present → nil (normal Status, pixel-
    ///      identical to before — red line), missing → notInstalled (or manual on
    ///      macOS < 14, D42).
    private var effectivePhase: EngineSetupCard.Phase? {
        if let forced = forcedInstallPhase { return forced }
        if let live = EngineSetupCard.Phase.from(installStore.phase,
                                                 autoInstallSupported: installStore.autoInstallSupported) {
            return live
        }
        if store.calibrePresent { return nil }
        return installStore.autoInstallSupported ? .notInstalled : .manual(osUnsupported: true)
    }

    /// The effective FDA card state for this render, or nil for no FDA card. Priority:
    ///   1. the screenshot overlay (`folderForced`) — may force nil (ok = no card);
    ///   2. the host-owned transient recheck state (checking/stillDenied/timeout);
    ///   3. the LIVE agent flag: folder_access == .denied → .denied, else nil.
    /// Absent field / .ok / .missing → nil (no surface; missing has no UI in v1.0.1).
    /// NOTE: this is only consulted when `effectivePhase == nil` (engine present) —
    /// the CJM order is engine → access (arch/plan-fda-synthesis.md «Развилка»).
    private var effectiveFolderState: FolderAccessCard.State? {
        if folderForced { return forcedFolderState }
        if let r = store.folderRecheck { return r }
        return store.state.agent.folderAccess == .denied ? .denied : nil
    }

    var body: some View {
        ZStack {
            Tokens.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
                Spacer(minLength: 0)
                footer
            }
        }
        .frame(width: Tokens.M.windowWidth)
    }

    // --- Content router: normal Status / banner A / blocker B ----------------
    // D37 hybrid: engine present → normal content; engine missing → banner A over
    // (muted) content when there IS raw history, else blocker B replacing content.
    @ViewBuilder private var content: some View {
        // CJM priority via the shared StatusRouter (engine → access → normal). The
        // if-lets inside each case are guaranteed by the surface we just computed.
        switch StatusRouter.surface(engineOnboardingActive: effectivePhase != nil,
                                    folderAccessActive: effectiveFolderState != nil) {
        case .engineOnboarding:
            if let phase = effectivePhase {
                if store.hasRawHistory {
                    engineCard(.banner, phase)
                    heroView(enginePhase: phase)
                    groupRows
                    details
                } else {
                    engineCard(.blocker, phase)
                }
            }
        case .folderAccess:
            // Engine present but the agent can't read the folder. Same D37 hybrid:
            // banner over muted content when there IS history, else a full-screen
            // blocker (nothing to keep visible).
            if let faState = effectiveFolderState {
                if store.hasRawHistory {
                    folderCard(.banner, faState)
                    heroView(folderDenied: true)
                    groupRows
                    details
                } else {
                    folderCard(.blocker, faState)
                }
            }
        case .normal:
            heroView(enginePhase: nil)
            groupRows
            details
        }
    }

    /// FolderAccessCard with the FDA callbacks wired (inert in FDA-2).
    private func folderCard(_ presentation: FolderAccessCard.Presentation,
                            _ state: FolderAccessCard.State) -> some View {
        FolderAccessCard(
            state: state,
            presentation: presentation,
            justCopied: store.folderPathCopied,   // fix #2: brief "Путь скопирован ✓" ack
            copyHint: store.folderCopyHint,        // fix #2/#3: honest failure hint
            onOpenSettings: onOpenFolderAccess,
            onRecheck: onRecheckFolder)
    }

    /// EngineSetupCard with the read-only CAL-2 callbacks wired (all inert here).
    private func engineCard(_ presentation: EngineSetupCard.Presentation,
                            _ phase: EngineSetupCard.Phase) -> some View {
        EngineSetupCard(
            phase: phase,
            presentation: presentation,
            onInstall: onInstallEngine,
            onCancel: onCancelInstall,
            onRetry: onRetryInstall,
            onManual: onManualInstall,
            onOpenSite: onOpenCalibreSite,
            onRecheck: onRecheckEngine,
            onRetryAgent: onRetryAgent)
    }

    // --- Header --------------------------------------------------------------
    private var header: some View {
        HStack(spacing: Tokens.M.headerGap) {
            AppIcon()
            VStack(alignment: .leading, spacing: 2) {
                Text("fb2-to-epub")
                    .font(Tokens.F.h1)
                    .foregroundColor(Tokens.C.textPrimary)
                    .trackingCompat(Tokens.Track.h1)
                Text("Авто-конвертация FB2 и FB3 → EPUB")
                    .font(Tokens.F.headerSub)
                    .foregroundColor(Tokens.C.textSecondary)
            }
            Spacer(minLength: 0)
            // A settings gear (SF gearshape) in the icon-button chip.
            iconButton("gearshape")
                .onTapGesture(perform: onSettings)
        }
        .padding(.horizontal, Tokens.M.headerPadH)
        .padding(.top, Tokens.M.headerPadTop)
        .padding(.bottom, Tokens.M.headerPadBottom)
    }

    private func iconButton(_ systemName: String) -> some View {
        RoundedRectangle(cornerRadius: Tokens.M.iconBtnRadius, style: .continuous)
            .fill(Tokens.C.iconBtnBg)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.M.iconBtnRadius, style: .continuous)
                    .stroke(Tokens.C.iconBtnBorder, lineWidth: 1)
            )
            .overlay(
                sfIcon(systemName, size: 14)
                    .foregroundColor(Tokens.C.textSoft)
            )
            .frame(width: Tokens.M.iconBtnSize, height: Tokens.M.iconBtnSize)
    }

    // --- Hero ----------------------------------------------------------------
    // Composition (top → bottom inside the card):
    //   • the agent-status badge ("Фоновый агент Активен/На паузе"), full width;
    //   • a row: the progress ring on the left, and a right column holding the
    //     watched-folder path + the two metrics (Сконвертировано всего / За сегодня).
    // The old "N книги / Последняя …" sub-block is gone — the two counters that
    // used to be stat cards now live here (big number + caps label), and "last
    // conversion" is already visible in the "Последние конвертации" list below.
    private func heroView(enginePhase: EngineSetupCard.Phase? = nil,
                          folderDenied: Bool = false) -> some View {
        // Engine-missing (banner A) mutes the ring and swaps the emerald badge for
        // the honest amber pill; success un-mutes and shows the emerald "active"
        // badge (refs/direction-A-final.png). FDA-denied (banner) mutes the ring the
        // same way — conversion is equally impossible. Engine present + access ok →
        // untouched.
        let engineMissing = enginePhase != nil && enginePhase != .success
        let ringMuted = engineMissing || folderDenied
        return VStack(alignment: .leading, spacing: 0) {
            heroBadge(enginePhase: enginePhase, folderDenied: folderDenied)

            HStack(spacing: Tokens.M.heroRowGap) {
                StatusRing(progress: batchProgress,
                           active: batchActive,
                           done: batchDone,
                           total: batchTotal,
                           agentPaused: !agentActive,
                           engineMissing: ringMuted)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        sfIcon("folder", size: 12)
                            .foregroundColor(Tokens.C.textSecondary)
                        Text(watchDir)
                            .font(Tokens.F.heroPath)
                            .foregroundColor(Tokens.C.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    heroCounters
                        .padding(.top, 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)
        }
        .padding(Tokens.M.heroPad)
        .background(card(radius: Tokens.M.heroRadius))
        .padding(.horizontal, Tokens.M.cardInset)
        .padding(.top, Tokens.M.heroTopGap)
        .padding(.bottom, Tokens.M.cardSpacing)
    }

    /// The hero's status badge, honest about the engine: amber "КОНВЕРТАЦИЯ
    /// НЕДОСТУПНА" while the engine is missing, emerald "ФОНОВЫЙ АГЕНТ АКТИВЕН" on
    /// success, otherwise the normal live agent badge (present engine).
    @ViewBuilder private func heroBadge(enginePhase: EngineSetupCard.Phase?,
                                        folderDenied: Bool = false) -> some View {
        if folderDenied {
            WarnPill(text: "НЕТ ДОСТУПА К ПАПКЕ")
        } else if let phase = enginePhase {
            if phase == .success {
                EmeraldBadge(text: "ФОНОВЫЙ АГЕНТ АКТИВЕН", active: true)
            } else {
                WarnPill(text: "КОНВЕРТАЦИЯ НЕДОСТУПНА")
            }
        } else {
            EmeraldBadge(text: agentActive ? "Фоновый агент Активен"
                                           : "Фоновый агент На паузе",
                         active: agentActive)
        }
    }

    /// The two metrics that moved up from the stat-card row: Сконвертировано (всего)
    /// + За сегодня. Same colors as the old cards (orange / magenta) and the same
    /// big-number + caps-label scale — now STACKED vertically (one above the other)
    /// under the path. Side-by-side starved the right column's width, so the longer
    /// caps label ("СКОНВЕРТИРОВАНО") clipped to "СКОНВЕРТИРО…". Stacked, each
    /// counter spans the full available width, so both captions fit in full with no
    /// truncation. 14pt between the two blocks keeps the same breathing room the row
    /// gap used to give them.
    private var heroCounters: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeroCounter(value: grouped(state.totals.convertedTotal),
                        cap: "СКОНВЕРТИРОВАНО",
                        valueColor: Tokens.C.accentOrange)
            HeroCounter(value: grouped(state.totals.today),
                        cap: "ЗА СЕГОДНЯ",
                        valueColor: Tokens.C.magenta)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // --- Group rows ----------------------------------------------------------
    // Only the cover-picker row remains here, and only when a queue exists. The
    // "Фоновый агент" status row moved into the hero badge, and "Отслеживаемая
    // папка" moved to Настройки (v0.9.1). With nothing to show we render NOTHING
    // (an EmptyView), so there's no empty card/border left behind.
    @ViewBuilder
    private var groupRows: some View {
        if coverCount > 0 {
            VStack(spacing: 0) {
                row {
                    rowIcon(tint: Tokens.C.tintMagenta, color: Tokens.C.magenta, "photo")
                    Text("Уточнить выбор обложки").font(Tokens.F.rowLabel).foregroundColor(Tokens.C.textPrimary)
                    Spacer(minLength: 0)
                    Text("\(coverCount)")
                        .font(Tokens.F.countBadge).foregroundColor(.white)
                        .frame(minWidth: Tokens.M.countBadgeMin, minHeight: Tokens.M.countBadgeMin)
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(Tokens.G.countBadge))
                    sfIcon("chevron.right", size: 12, weight: .semibold)
                        .foregroundColor(Tokens.C.textTertiary)
                        .padding(.leading, 2)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelectCovers)
            }
            .background(card(radius: Tokens.M.groupRadius))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.M.groupRadius, style: .continuous))
            .padding(.horizontal, Tokens.M.cardInset)
            .padding(.bottom, Tokens.M.cardSpacing)
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Tokens.M.rowGap, content: content)
            .padding(.horizontal, Tokens.M.rowPadH)
            .padding(.vertical, Tokens.M.rowPadV)
    }

    private func rowIcon(tint: Color, color: Color, _ systemName: String) -> some View {
        RoundedRectangle(cornerRadius: Tokens.M.rowIconRadius, style: .continuous)
            .fill(tint)
            .overlay(sfIcon(systemName, size: 13, weight: .semibold).foregroundColor(color))
            .frame(width: Tokens.M.rowIcon, height: Tokens.M.rowIcon)
    }

    private var hairline: some View {
        Rectangle().fill(Tokens.C.hairline)
            .frame(height: 1)
            .padding(.horizontal, Tokens.M.cardInset)
    }

    // --- Details (recent conversions) ----------------------------------------
    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CapLabel(text: "ПОСЛЕДНИЕ КОНВЕРТАЦИИ")
                Spacer(minLength: 0)
                clearButton
            }
            .padding(.bottom, 6)

            if state.recent.isEmpty {
                Text("Здесь появятся сконвертированные книги")
                    .font(Tokens.F.rowSub)
                    .foregroundColor(Tokens.C.textTertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(state.recent.prefix(5).enumerated()), id: \.element.id) { idx, item in
                    convRow(item, isLast: idx == min(4, state.recent.count - 1))
                }
            }
        }
        .padding(.horizontal, Tokens.M.detailsPadH)
        .padding(.top, Tokens.M.detailsPadTop)
        .padding(.bottom, Tokens.M.detailsPadBottom)
        .background(card(radius: Tokens.M.detailsRadius))
        .padding(.horizontal, Tokens.M.cardInset)
        .padding(.bottom, Tokens.M.cardSpacing)
    }

    private var clearButton: some View {
        HStack(spacing: 3) {
            sfIcon("trash", size: 9)
            Text("Очистить").font(Tokens.F.clearBtn)
        }
        .foregroundColor(Tokens.C.textTertiary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white(0.07), lineWidth: 1)
        )
        .onTapGesture(perform: onClearHistory)
    }

    /// One conversion row: the OUTPUT (.epub) filename on the full available width
    /// + the wall-clock time on the right. The source column and the arrow glyph
    /// were dropped (118 / 14 cols ate the width and neither name was readable) so
    /// the result name now gets the whole 1fr and truncates in the middle only when
    /// it actually overflows. Same row font / vertical padding / divider as before.
    private func convRow(_ item: ConversionEntry, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.M.convColGap) {
                Text(item.dst)
                    .font(Tokens.F.conv)
                    .foregroundColor(item.isOK ? Tokens.C.textPrimary : Tokens.C.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(RelativeTime.clock(item.ts))
                    .font(Tokens.F.conv)
                    .foregroundColor(Tokens.C.textTertiary)
            }
            .padding(.vertical, Tokens.M.convRowPadV)
            if !isLast {
                Rectangle().fill(Tokens.C.convDivider).frame(height: 1)
            }
        }
    }

    // --- Footer --------------------------------------------------------------
    // Honest about the engine: while it's missing the dot goes amber and the text
    // reflects the install phase ("Ставлю движок…" / "Нет движка …" for banner A /
    // "Конвертация недоступна" for blocker B). Engine present → unchanged.
    private var footerDotIsOk: Bool {
        if let phase = effectivePhase { return phase == .success }
        if effectiveFolderState != nil { return false }   // FDA-denied: not ok
        return agentActive
    }
    private var footerDotColor: Color {
        if footerDotIsOk { return Tokens.C.emerald }
        // Errors get the danger dot (mockup .foot-dot.err = #EB6B73), not warn orange;
        // other in-flight/blocked phases stay warn; no phase + paused → tertiary.
        switch effectivePhase {
        case .errorNetwork, .errorSpace, .errorInstall: return Tokens.C.danger
        case .some:                                     return Tokens.C.accentOrange // warn
        case .none:
            // Engine present: FDA-denied → warn dot; otherwise present + paused.
            return effectiveFolderState != nil ? Tokens.C.accentOrange : Tokens.C.textTertiary
        }
    }
    private var footerText: String {
        if let phase = effectivePhase {
            switch phase {
            case .downloading, .installing, .verifying: return "Ставлю движок…"
            case .success:                              return "Агент работает"
            default:
                // Banner A keeps history visible → its own line; blocker B is terse.
                return store.hasRawHistory ? "Нет движка — конвертация не идёт"
                                           : "Конвертация недоступна"
            }
        }
        if effectiveFolderState != nil {
            return store.hasRawHistory ? "Нет доступа к папке — конвертация стоит"
                                       : "Конвертация недоступна"
        }
        return agentActive ? "Агент работает" : "Агент на паузе"
    }

    private var footer: some View {
        HStack(spacing: Tokens.M.footerGap) {
            Circle()
                .fill(footerDotColor)
                .frame(width: Tokens.M.footDot, height: Tokens.M.footDot)
                .shadow(color: footerDotIsOk ? Tokens.C.emerald : .clear, radius: 3)
            Text(footerText)
                .font(Tokens.F.headerSub)
                .foregroundColor(Tokens.C.textSecondary)
            Spacer(minLength: 0)
            footerButton
        }
        .padding(.horizontal, Tokens.M.footerPadH)
        .padding(.vertical, Tokens.M.footerPadV)
        .background(
            Color(.sRGB, red: 8/255, green: 8/255, blue: 12/255, opacity: 0.4)
        )
        .overlay(
            Rectangle().fill(Tokens.C.cardBorder).frame(height: 1),
            alignment: .top
        )
    }

    private var footerButton: some View {
        HStack(spacing: 6) {
            sfIcon("folder", size: 12).foregroundColor(Tokens.C.accentOrange)
            Text("Открыть папку").font(Tokens.F.button).foregroundColor(Tokens.C.textPrimary)
        }
        .padding(.horizontal, Tokens.M.btnPadH)
        .padding(.vertical, Tokens.M.btnPadV)
        .background(
            RoundedRectangle(cornerRadius: Tokens.M.btnRadius, style: .continuous).fill(Tokens.C.btnBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.M.btnRadius, style: .continuous).stroke(Tokens.C.btnBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenFolder)
    }

    // --- Number formatting ---------------------------------------------------
    /// Space-grouped thousands ("1 234"), matching the mockup's tnum metric.
    private func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
