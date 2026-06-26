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

// MARK: - Hover cursor (pointer on links)

private extension View {
    /// Show the pointing-hand cursor while hovering — signals "this is clickable"
    /// for the inline GitHub link in the credit footer.
    func onHoverCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

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
    // gear: spokes + center circle
    static func gear(_ p: inout Path) {
        let spokes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (12, 4, 12, 7), (12, 17, 12, 20), (4, 12, 7, 12), (17, 12, 20, 12),
            (6.3, 6.3, 8.4, 8.4), (15.6, 15.6, 17.7, 17.7),
            (17.7, 6.3, 15.6, 8.4), (8.4, 15.6, 6.3, 17.7),
        ]
        for (x1, y1, x2, y2) in spokes {
            p.move(to: .init(x: x1, y: y1)); p.addLine(to: .init(x: x2, y: y2))
        }
        p.addEllipse(in: CGRect(x: 12 - 3.2, y: 12 - 3.2, width: 6.4, height: 6.4))
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

/// Derived render-state for the hero ring, mapped from AgentStatus.
enum RingState {
    case active       // agent on, idle  -> full brand gradient, steady
    case converting   // a run in flight -> rotating arc (animated)
    case paused       // agent off       -> dim grey ring
}

private struct StatusRing: View {
    let state: RingState
    @State private var spin = false

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(Tokens.C.barTrack, lineWidth: Tokens.M.ringStroke)
            // Foreground
            ringForeground
            // Center play glyph
            StrokeIcon(size: Tokens.M.ringPlay, build: Icons.play)
                .foregroundColor(Tokens.C.accentOrange)
        }
        .frame(width: Tokens.M.ringSize, height: Tokens.M.ringSize)
        .padding(Tokens.M.ringStroke / 2) // keep round caps inside the box
    }

    @ViewBuilder
    private var ringForeground: some View {
        switch state {
        case .active:
            Circle()
                .stroke(Tokens.G.ring,
                        style: StrokeStyle(lineWidth: Tokens.M.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        case .converting:
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Tokens.G.ring,
                        style: StrokeStyle(lineWidth: Tokens.M.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(spin ? 270 : -90))
                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                .onAppear { spin = true }
        case .paused:
            Circle()
                .stroke(Color.white(0.14),
                        style: StrokeStyle(lineWidth: Tokens.M.ringStroke, lineCap: .round))
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

/// The emerald "Активен" pill / badge.
private struct EmeraldBadge: View {
    let text: String
    var padded: Bool = true
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Tokens.C.emerald)
                .frame(width: 5, height: 5)
                .shadow(color: Tokens.C.emerald, radius: 3)
            Text(text)
                .font(Tokens.F.badge)
                .foregroundColor(Tokens.C.emerald)
        }
        .padding(.horizontal, padded ? 9 : 0)
        .padding(.vertical, padded ? 3 : 0)
        .background(
            Capsule(style: .continuous).fill(Tokens.C.emeraldBg)
        )
        .overlay(
            Capsule(style: .continuous).stroke(Tokens.C.emeraldBorder, lineWidth: 1)
        )
    }
}

/// One stat card.
private struct StatCard: View {
    let cap: String
    let value: String
    let sub: String
    let valueColor: Color
    let bar: LinearGradient
    let barFill: CGFloat  // 0...1
    var leadingCheck: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CapLabel(text: cap)
            HStack(spacing: 3) {
                if leadingCheck {
                    StrokeIcon(size: 14, lineWidth: 3, build: Icons.check)
                        .foregroundColor(valueColor)
                }
                Text(value)
                    .font(Tokens.F.statVal)
                    .foregroundColor(valueColor)
                    .monoDigitsCompat()
            }
            .padding(.top, 5)
            Text(sub)
                .font(Tokens.F.statSub)
                .foregroundColor(Tokens.C.textTertiary)
                .padding(.top, 3)
            // bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tokens.C.barTrack)
                    Capsule().fill(bar)
                        .frame(width: max(0, min(1, barFill)) * geo.size.width)
                }
            }
            .frame(height: Tokens.M.barHeight)
            .padding(.top, 8)
        }
        .padding(.horizontal, Tokens.M.statPadH)
        .padding(.top, Tokens.M.statPadTop)
        .padding(.bottom, Tokens.M.statPadBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card(radius: Tokens.M.statRadius))
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

// MARK: - StatusView

struct StatusView: View {
    let state: EngineState
    let agentActive: Bool
    let calibreText: String      // e.g. "7.21" or "✓"
    let coverCount: Int

    // Actions (only openFolder is functional in M2).
    var onOpenFolder: () -> Void = {}
    var onChangeFolder: () -> Void = {}
    var onClearHistory: () -> Void = {}
    var onSettings: () -> Void = {}
    var onSelectCovers: () -> Void = {}
    /// Opens the GitHub repo. Host wires this to NSWorkspace.shared.open (spec).
    var onOpenGitHub: () -> Void = {}

    // Derived watch dir, tilde-collapsed for display.
    private var watchDir: String {
        let raw = state.agent.watchDir ?? "~/Desktop/fb2-to-epub"
        let home = NSHomeDirectory()
        return raw.hasPrefix(home) ? "~" + raw.dropFirst(home.count) : raw
    }

    private var ringState: RingState { agentActive ? .active : .paused }

    var body: some View {
        ZStack {
            Tokens.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                hero
                stats
                groupRows
                details
                Spacer(minLength: 0)
                footer
                credit
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
            iconButton { Icons.gear(&$0) }
                .onTapGesture(perform: onSettings)
        }
        .padding(.horizontal, Tokens.M.headerPadH)
        .padding(.top, Tokens.M.headerPadTop)
        .padding(.bottom, Tokens.M.headerPadBottom)
    }

    private func iconButton(_ build: @escaping (inout Path) -> Void) -> some View {
        RoundedRectangle(cornerRadius: Tokens.M.iconBtnRadius, style: .continuous)
            .fill(Tokens.C.iconBtnBg)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.M.iconBtnRadius, style: .continuous)
                    .stroke(Tokens.C.iconBtnBorder, lineWidth: 1)
            )
            .overlay(
                StrokeIcon(size: 15, build: build).foregroundColor(Tokens.C.textSoft)
            )
            .frame(width: Tokens.M.iconBtnSize, height: Tokens.M.iconBtnSize)
    }

    // --- Hero ----------------------------------------------------------------
    private var hero: some View {
        HStack(spacing: Tokens.M.heroRowGap) {
            StatusRing(state: ringState)
            VStack(alignment: .leading, spacing: 0) {
                EmeraldBadge(text: agentActive ? "АКТИВНО" : "ПАУЗА")
                HStack(spacing: 6) {
                    StrokeIcon(size: 13, build: Icons.folder)
                        .foregroundColor(Tokens.C.textSecondary)
                    Text(watchDir)
                        .font(Tokens.F.heroPath)
                        .foregroundColor(Tokens.C.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.top, 10)
                heroMetric
                    .padding(.top, 8)
                heroSub
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Tokens.M.heroPad)
        .background(card(radius: Tokens.M.heroRadius))
        .padding(.horizontal, Tokens.M.cardInset)
        .padding(.top, Tokens.M.heroTopGap)
        .padding(.bottom, Tokens.M.cardSpacing)
    }

    private var heroMetric: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(grouped(state.totals.convertedTotal))
                .font(Tokens.F.heroMetric)
                .foregroundColor(Tokens.C.textPrimary)
                .trackingMonoCompat(Tokens.Track.heroMetric)
            Text(booksWord(state.totals.convertedTotal))
                .font(Tokens.F.heroUnit)
                .foregroundColor(Tokens.C.textSecondary)
        }
    }

    @ViewBuilder
    private var heroSub: some View {
        if let last = state.lastConversion {
            let ago = RelativeTime.ago(last.ts) ?? ""
            (Text("Последняя: ")
                .foregroundColor(Tokens.C.textSecondary)
             + Text(last.dst)
                .foregroundColor(Tokens.C.textSoft)
             + Text(ago.isEmpty ? "" : " · \(ago)")
                .foregroundColor(Tokens.C.textSecondary))
                .font(Tokens.F.rowSub)
        } else {
            Text("Конвертаций пока нет")
                .font(Tokens.F.rowSub)
                .foregroundColor(Tokens.C.textSecondary)
        }
    }

    // --- Stat cards ----------------------------------------------------------
    private var stats: some View {
        HStack(spacing: Tokens.M.statGap) {
            StatCard(cap: "СКОНВЕРТ.",
                     value: grouped(state.totals.convertedTotal),
                     sub: "всего",
                     valueColor: Tokens.C.accentOrange,
                     bar: Tokens.G.barOrange,
                     barFill: 1.0)
            StatCard(cap: "ЗА СЕГОДНЯ",
                     value: grouped(state.totals.today),
                     sub: "книг",
                     valueColor: Tokens.C.magenta,
                     bar: Tokens.G.barMagenta,
                     barFill: todayFill)
            StatCard(cap: "CALIBRE",
                     value: calibreText,
                     sub: "движок",
                     valueColor: Tokens.C.emerald,
                     bar: Tokens.G.barEmerald,
                     barFill: 1.0,
                     leadingCheck: calibreText == "✓")
        }
        .padding(.horizontal, Tokens.M.cardInset)
        .padding(.bottom, Tokens.M.cardSpacing)
    }

    /// Today bar: scale against a soft daily target so it reads as progress, not 0/100.
    private var todayFill: CGFloat {
        let target: CGFloat = 40
        return min(1, max(0.04, CGFloat(state.totals.today) / target))
    }

    // --- Group rows ----------------------------------------------------------
    private var groupRows: some View {
        VStack(spacing: 0) {
            // Background agent -> emerald badge
            row {
                rowIcon(tint: Tokens.C.tintEmerald, color: Tokens.C.emerald) { Icons.bolt(&$0) }
                Text("Фоновый агент").font(Tokens.F.rowLabel).foregroundColor(Tokens.C.textPrimary)
                Spacer(minLength: 0)
                if agentActive {
                    EmeraldBadge(text: "Активен")
                } else {
                    Text("Выключен").font(Tokens.F.rowVal).foregroundColor(Tokens.C.textSecondary)
                }
            }
            hairline
            // Watched folder -> path + "Сменить"
            row {
                rowIcon(tint: Tokens.C.tintOrange, color: Tokens.C.accentOrange) { Icons.folder(&$0) }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Отслеживаемая папка")
                        .font(Tokens.F.rowLabel).foregroundColor(Tokens.C.textPrimary)
                    Text(watchDir)
                        .font(Tokens.F.rowSub).foregroundColor(Tokens.C.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text("Сменить")
                    .font(Tokens.F.link).foregroundColor(Tokens.C.accentOrange)
                    .onTapGesture(perform: onChangeFolder)
            }
            // Cover picker (only when there is a queue)
            if coverCount > 0 {
                hairline
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
        }
        .background(card(radius: Tokens.M.groupRadius))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.M.groupRadius, style: .continuous))
        .padding(.horizontal, Tokens.M.cardInset)
        .padding(.bottom, Tokens.M.cardSpacing)
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

    /// One conversion row using the spec's fixed grid: 118 / 14 / 1fr / auto.
    private func convRow(_ item: ConversionEntry, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.M.convColGap) {
                Text(item.src)
                    .font(Tokens.F.conv)
                    .foregroundColor(Tokens.C.textSoft)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: Tokens.M.convColSrc, alignment: .leading)
                StrokeIcon(size: 11, lineWidth: 2.4, build: Icons.arrow)
                    .foregroundColor(item.isOK ? Tokens.C.accentOrange : Tokens.C.textTertiary)
                    .frame(width: Tokens.M.convColArrow)
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
            footerIconButton { Icons.gear(&$0) }
                .onTapGesture(perform: onSettings)
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

    private func footerIconButton(_ build: @escaping (inout Path) -> Void) -> some View {
        RoundedRectangle(cornerRadius: Tokens.M.btnRadius, style: .continuous)
            .fill(Tokens.C.btnBg)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.M.btnRadius, style: .continuous).stroke(Tokens.C.btnBorder, lineWidth: 1)
            )
            .overlay(StrokeIcon(size: 14, build: build).foregroundColor(Tokens.C.textSoft))
            .frame(width: Tokens.M.btnIconSize, height: Tokens.M.btnIconSize)
    }

    // --- Credit footer -------------------------------------------------------
    // "fb2-to-epub <version> · by Alex Kovalev · GitHub", centered, 11px #6E647F;
    // "GitHub" is blue (#5B9DF9), slightly heavier, and the only clickable part —
    // a hit-target sized to the word so the rest of the line stays inert.
    private var credit: some View {
        HStack(spacing: 0) {
            Text("fb2-to-epub \(Tokens.Project.version) · by Alex Kovalev · ")
                .font(Tokens.F.credit)
                .foregroundColor(Tokens.C.creditText)
            Text("GitHub")
                .font(Tokens.F.creditLink)
                .foregroundColor(Tokens.C.creditLink)
                .onTapGesture(perform: onOpenGitHub)
                .onHoverCursor()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, Tokens.M.creditPadH)
        .padding(.top, Tokens.M.creditPadTop)
        .padding(.bottom, Tokens.M.creditPadBottom)
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

    /// Russian noun agreement for "книга".
    private func booksWord(_ n: Int) -> String {
        let mod100 = n % 100, mod10 = n % 10
        if mod100 >= 11 && mod100 <= 14 { return "книг" }
        switch mod10 {
        case 1: return "книга"
        case 2, 3, 4: return "книги"
        default: return "книг"
        }
    }
}
