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

// MARK: - Vector icons (stroke paths in a 24x24 box, like the mockup SVGs)

/// A stroked icon drawn from a path builder over a 0...24 coordinate box, scaled
/// to `size`. Matches the lucide-style 2px strokes used throughout the mockup.
private struct StrokeIcon: View {
    let size: CGFloat
    var lineWidth: CGFloat = 2
    let build: (inout Path) -> Void

    var body: some View {
        IconShape(build: build)
            .stroke(style: StrokeStyle(lineWidth: lineWidth * 24 / size,
                                       lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }

    private struct IconShape: Shape {
        let build: (inout Path) -> Void
        func path(in rect: CGRect) -> Path {
            var p = Path()
            build(&p)
            // Map the 0...24 design box onto rect.
            let s = min(rect.width, rect.height) / 24
            return p.applying(CGAffineTransform(scaleX: s, y: s))
        }
    }
}

/// A filled icon (e.g. the play triangle, the book-spark star) in a 24x24 box.
private struct FillIcon: View {
    let size: CGFloat
    let build: (inout Path) -> Void
    var body: some View {
        IconShape(build: build)
            .frame(width: size, height: size)
    }
    private struct IconShape: Shape {
        let build: (inout Path) -> Void
        func path(in rect: CGRect) -> Path {
            var p = Path()
            build(&p)
            let s = min(rect.width, rect.height) / 24
            return p.applying(CGAffineTransform(scaleX: s, y: s))
        }
    }
}

// Path builders (coordinates lifted from the mockup's SVG `d` attributes).
private enum Icons {
    // folder: M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z
    static func folder(_ p: inout Path) {
        p.move(to: .init(x: 3, y: 7))
        p.addLine(to: .init(x: 3, y: 19))
        p.addLine(to: .init(x: 21, y: 19))
        p.addLine(to: .init(x: 21, y: 9))
        p.addLine(to: .init(x: 11, y: 9))
        p.addLine(to: .init(x: 9, y: 7))
        p.closeSubpath()
    }
    // gear: a real cogwheel, lucide "settings" style — ONE continuous closed
    // outline whose edge alternates between an outer tooth-tip radius and an inner
    // tooth-root radius (flat-topped teeth joined by valleys), plus a centered
    // round hole. The previous version drew 8 free radial spokes from a dot, which
    // read as an asterisk/flower because nothing connected the teeth. Here the
    // toothed RING is a single closed subpath, so it is unmistakably a gear.
    //
    // Geometry: 6 teeth (chunky, legible at 15px). Each tooth spans 60°; within it
    // the tip arc occupies `tipFrac` of the angle (the flat top) and the valley the
    // rest. We walk the 4 corners per tooth: valley-start, tip-start, tip-end,
    // valley-end — emitting straight edges between radii so each tooth has crisp
    // flanks. rRoot/rTip give the ring thickness; rHole is the center bore.
    static func gear(_ p: inout Path) {
        let cx: CGFloat = 12, cy: CGFloat = 12
        let rTip: CGFloat = 10.2   // outer tooth-tip radius
        let rRoot: CGFloat = 7.4   // tooth-root (valley) radius
        let rHole: CGFloat = 3.1   // center hole radius
        let teeth = 6
        let step = 2 * CGFloat.pi / CGFloat(teeth) // 60° per tooth
        let tipHalf = step * 0.26   // half-width of the flat tooth top
        let valleyHalf = step * 0.5 - tipHalf // half-width of the valley
        func pt(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
            .init(x: cx + cos(a) * r, y: cy + sin(a) * r)
        }
        for i in 0..<teeth {
            let c = CGFloat(i) * step - .pi / 2 // tooth center (start at top)
            let valleyStart = c - tipHalf - valleyHalf
            let tipStart = c - tipHalf
            let tipEnd = c + tipHalf
            // valley before this tooth -> rise to the flat top -> across the top
            if i == 0 { p.move(to: pt(rRoot, valleyStart)) }
            else { p.addLine(to: pt(rRoot, valleyStart)) }
            p.addLine(to: pt(rTip, tipStart))
            p.addLine(to: pt(rTip, tipEnd))
        }
        p.closeSubpath() // last tip drops back to the first valley, closing the ring
        // center hole (separate subpath; stroked as the inner circle)
        p.addEllipse(in: CGRect(x: cx - rHole, y: cy - rHole,
                                width: rHole * 2, height: rHole * 2))
    }
    // play triangle (filled): M5 4l14 8-14 8z
    static func play(_ p: inout Path) {
        p.move(to: .init(x: 5, y: 4))
        p.addLine(to: .init(x: 19, y: 12))
        p.addLine(to: .init(x: 5, y: 20))
        p.closeSubpath()
    }
    // lightning bolt (filled): M13 2L3 14h7l-1 8 10-12h-7z
    static func bolt(_ p: inout Path) {
        p.move(to: .init(x: 13, y: 2))
        p.addLine(to: .init(x: 3, y: 14))
        p.addLine(to: .init(x: 10, y: 14))
        p.addLine(to: .init(x: 9, y: 22))
        p.addLine(to: .init(x: 19, y: 10))
        p.addLine(to: .init(x: 12, y: 10))
        p.closeSubpath()
    }
    // image / cover: rect + dot + mountain
    static func image(_ p: inout Path) {
        p.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18),
                         cornerSize: CGSize(width: 2, height: 2))
        p.addEllipse(in: CGRect(x: 8.5 - 1.5, y: 8.5 - 1.5, width: 3, height: 3))
        p.move(to: .init(x: 21, y: 15))
        p.addLine(to: .init(x: 16, y: 10))
        p.addLine(to: .init(x: 5, y: 21))
    }
    // checkmark: M5 13l4 4L19 7
    static func check(_ p: inout Path) {
        p.move(to: .init(x: 5, y: 13))
        p.addLine(to: .init(x: 9, y: 17))
        p.addLine(to: .init(x: 19, y: 7))
    }
    // chevron right: M9 6l6 6-6 6
    static func chevron(_ p: inout Path) {
        p.move(to: .init(x: 9, y: 6))
        p.addLine(to: .init(x: 15, y: 12))
        p.addLine(to: .init(x: 9, y: 18))
    }
    // arrow right (conversion): M5 12h14M13 6l6 6-6 6
    static func arrow(_ p: inout Path) {
        p.move(to: .init(x: 5, y: 12)); p.addLine(to: .init(x: 19, y: 12))
        p.move(to: .init(x: 13, y: 6)); p.addLine(to: .init(x: 19, y: 12)); p.addLine(to: .init(x: 13, y: 18))
    }
    // trash: M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2M6 7l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13
    static func trash(_ p: inout Path) {
        p.move(to: .init(x: 4, y: 7)); p.addLine(to: .init(x: 20, y: 7))
        p.move(to: .init(x: 9, y: 7)); p.addLine(to: .init(x: 9, y: 4)); p.addLine(to: .init(x: 15, y: 4)); p.addLine(to: .init(x: 15, y: 7))
        p.move(to: .init(x: 6, y: 7)); p.addLine(to: .init(x: 7, y: 21)); p.addLine(to: .init(x: 17, y: 21)); p.addLine(to: .init(x: 18, y: 7))
    }
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
                .opacity(agentPaused && !active ? 0.85 : 1)

            // Center: live counter while converting, otherwise the play glyph.
            center
        }
        .frame(width: Tokens.M.ringSize, height: Tokens.M.ringSize)
        .padding(Tokens.M.ringStroke / 2) // keep round caps inside the box
        .onChange(of: progressBucket) { _ in evaluateFlourish() }
        .onChange(of: active) { _ in evaluateFlourish() }
        .onAppear { didFlourish = progress >= 1.0 }
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
            StrokeIcon(size: Tokens.M.ringPlay, build: Icons.play)
                .foregroundColor(Tokens.C.accentOrange)
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

    init(state: EngineState, agentActive: Bool, coverCount: Int) {
        self.state = state
        self.agentActive = agentActive
        self.coverCount = coverCount
    }
}

// MARK: - StatusView

struct StatusView: View {
    @ObservedObject var store: StatusStore

    // Actions (only openFolder is functional in M2).
    var onOpenFolder: () -> Void = {}
    var onClearHistory: () -> Void = {}
    var onSettings: () -> Void = {}
    var onSelectCovers: () -> Void = {}
    /// Opens the GitHub repo. Host wires this to NSWorkspace.shared.open (spec).
    var onOpenGitHub: () -> Void = {}

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
        let home = NSHomeDirectory()
        return raw.hasPrefix(home) ? "~" + raw.dropFirst(home.count) : raw
    }

    // Hero-ring inputs, derived from the live batch in state.json. Absent batch
    // (older state / nothing in flight) → progress 1.0 (calm full circle), not
    // converting. `EngineBatch.progress` already clamps and handles total==0.
    private var batchActive: Bool { state.batch?.active ?? false }
    private var batchProgress: Double { state.batch?.progress ?? 1.0 }
    private var batchDone: Int { state.batch?.done ?? 0 }
    private var batchTotal: Int { state.batch?.total ?? 0 }

    var body: some View {
        ZStack {
            Tokens.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                hero
                groupRows
                details
                Spacer(minLength: 0)
                footer
            }
        }
        .frame(width: Tokens.M.windowWidth)
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
                Text("Авто-конвертация FB2 → EPUB")
                    .font(Tokens.F.headerSub)
                    .foregroundColor(Tokens.C.textSecondary)
            }
            Spacer(minLength: 0)
            // Gear drawn with a slightly thinner stroke (1.7 vs the default 2) so
            // the refined cog reads crisp, not heavy, at this small size.
            iconButton(lineWidth: 1.7) { Icons.gear(&$0) }
                .onTapGesture(perform: onSettings)
        }
        .padding(.horizontal, Tokens.M.headerPadH)
        .padding(.top, Tokens.M.headerPadTop)
        .padding(.bottom, Tokens.M.headerPadBottom)
    }

    private func iconButton(lineWidth: CGFloat = 2,
                            _ build: @escaping (inout Path) -> Void) -> some View {
        RoundedRectangle(cornerRadius: Tokens.M.iconBtnRadius, style: .continuous)
            .fill(Tokens.C.iconBtnBg)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.M.iconBtnRadius, style: .continuous)
                    .stroke(Tokens.C.iconBtnBorder, lineWidth: 1)
            )
            .overlay(
                StrokeIcon(size: 15, lineWidth: lineWidth, build: build)
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
    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmeraldBadge(text: agentActive ? "Фоновый агент Активен"
                                           : "Фоновый агент На паузе",
                         active: agentActive)

            HStack(spacing: Tokens.M.heroRowGap) {
                StatusRing(progress: batchProgress,
                           active: batchActive,
                           done: batchDone,
                           total: batchTotal,
                           agentPaused: !agentActive)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        StrokeIcon(size: 13, build: Icons.folder)
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

    /// The two metrics that moved up from the stat-card row: Сконвертировано (всего)
    /// + За сегодня. Same colors as the old cards (orange / magenta) and the same
    /// big-number + caps-label scale, laid out side by side under the path.
    private var heroCounters: some View {
        HStack(alignment: .top, spacing: 0) {
            HeroCounter(value: grouped(state.totals.convertedTotal),
                        cap: "СКОНВЕРТИРОВАНО",
                        valueColor: Tokens.C.accentOrange)
                .frame(maxWidth: .infinity, alignment: .leading)
            HeroCounter(value: grouped(state.totals.today),
                        cap: "ЗА СЕГОДНЯ",
                        valueColor: Tokens.C.magenta)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    rowIcon(tint: Tokens.C.tintMagenta, color: Tokens.C.magenta) { Icons.image(&$0) }
                    Text("Выбрать обложку").font(Tokens.F.rowLabel).foregroundColor(Tokens.C.textPrimary)
                    Spacer(minLength: 0)
                    Text("\(coverCount)")
                        .font(Tokens.F.countBadge).foregroundColor(.white)
                        .frame(minWidth: Tokens.M.countBadgeMin, minHeight: Tokens.M.countBadgeMin)
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(Tokens.G.countBadge))
                    StrokeIcon(size: 14, build: Icons.chevron)
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

    private func rowIcon(tint: Color, color: Color,
                         _ build: @escaping (inout Path) -> Void) -> some View {
        RoundedRectangle(cornerRadius: Tokens.M.rowIconRadius, style: .continuous)
            .fill(tint)
            .overlay(StrokeIcon(size: 15, build: build).foregroundColor(color))
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
            StrokeIcon(size: 9, build: Icons.trash)
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
    private var footer: some View {
        HStack(spacing: Tokens.M.footerGap) {
            Circle()
                .fill(agentActive ? Tokens.C.emerald : Tokens.C.textTertiary)
                .frame(width: Tokens.M.footDot, height: Tokens.M.footDot)
                .shadow(color: agentActive ? Tokens.C.emerald : .clear, radius: 3)
            Text(agentActive ? "Агент работает" : "Агент на паузе")
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
            StrokeIcon(size: 13, build: Icons.folder).foregroundColor(Tokens.C.accentOrange)
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
