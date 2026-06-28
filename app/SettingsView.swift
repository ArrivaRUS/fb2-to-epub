// SettingsView — the "Настройки" screen.
//
// Replaces the old text NSMenu (showSettingsMenu) the gear used to pop. The
// composition follows the sibling "System Control" settings: a "‹ Настройки"
// header, grouped rounded cards whose rows carry an accent-orange stroke icon on
// the left + a label + a right-side affordance (control / chevron / button), a
// version+update card, and a centered credit footer ("… · by Alex Kovalev ·
// GitHub").
//
// STYLE is ours: every color / font / radius / inset comes from Tokens (the same
// values StatusView and CoverSelectView use). Like those screens, this file
// carries its own small file-private icon + card kit (StrokeIcon / SetIcons /
// setCard) so each screen stays a one-file pixel diff — no shared widget coupling.
//
// The view is purely presentational: every action is a closure the host
// (main.swift) supplies. It never touches the engine directly. Version is read
// from CFBundleShortVersionString (the single source of truth for the marketing
// version; more precise than a hardcoded token).

import SwiftUI
import AppKit

// MARK: - Hover cursor (pointer on the GitHub link)

private extension View {
    /// Pointing-hand cursor while hovering — signals "clickable" for the inline
    /// GitHub link in the credit footer (mirrors StatusView's helper).
    func onHoverCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - File-private icon kit (mirrors StatusView / CoverSelectView)

/// Stroke icon drawn in a 0...24 design box, scaled to `size`. Same contract as
/// the other screens' StrokeIcon — lucide-style 2px round strokes.
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
            let s = min(rect.width, rect.height) / 24
            return p.applying(CGAffineTransform(scaleX: s, y: s))
        }
    }
}

/// Path builders — coordinates lifted from the existing screens' SVG `d` attrs so
/// the Settings rows share the exact icon language as Status / Cover-select.
private enum SetIcons {
    // back chevron-left (CoverSelectView .cs-icon-btn): M15 6l-6 6 6 6
    static func back(_ p: inout Path) {
        p.move(to: .init(x: 15, y: 6))
        p.addLine(to: .init(x: 9, y: 12))
        p.addLine(to: .init(x: 15, y: 18))
    }
    // chevron right (StatusView): M9 6l6 6-6 6
    static func chevron(_ p: inout Path) {
        p.move(to: .init(x: 9, y: 6))
        p.addLine(to: .init(x: 15, y: 12))
        p.addLine(to: .init(x: 9, y: 18))
    }
    // folder (StatusView.Icons.folder): the watched-folder row icon. Same `d` as
    // the Status screen so the moved card carries the identical glyph.
    static func folder(_ p: inout Path) {
        p.move(to: .init(x: 3, y: 7))
        p.addLine(to: .init(x: 3, y: 19))
        p.addLine(to: .init(x: 21, y: 19))
        p.addLine(to: .init(x: 21, y: 9))
        p.addLine(to: .init(x: 11, y: 9))
        p.addLine(to: .init(x: 9, y: 7))
        p.closeSubpath()
    }
    // counter-reset (history/rotate-ccw arrow over a tick scale): a circular arrow
    // with a small arrowhead — reads "reset stats" without the aggression of a trash
    // can. Lucide rotate-ccw: arc + arrowhead at the 10-o'clock opening.
    static func reset(_ p: inout Path) {
        // ~300° arc, leaving a gap at top-left for the arrowhead.
        p.addArc(center: .init(x: 12, y: 12), radius: 8,
                 startAngle: .degrees(150), endAngle: .degrees(70),
                 clockwise: false)
        // Arrowhead pointing into the arc's opening (top-left).
        p.move(to: .init(x: 4.7, y: 8.0))
        p.addLine(to: .init(x: 5.05, y: 12.0))
        p.move(to: .init(x: 5.05, y: 12.0))
        p.addLine(to: .init(x: 9.0, y: 11.4))
    }
    // shield (Full Disk Access): M12 3l7 3v5c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z
    static func shield(_ p: inout Path) {
        p.move(to: .init(x: 12, y: 3))
        p.addLine(to: .init(x: 19, y: 6))
        p.addLine(to: .init(x: 19, y: 11))
        // right side curving down to the point
        p.addQuadCurve(to: .init(x: 12, y: 21),
                       control: .init(x: 19, y: 17.5))
        // left side back up
        p.addQuadCurve(to: .init(x: 5, y: 11),
                       control: .init(x: 5, y: 17.5))
        p.addLine(to: .init(x: 5, y: 6))
        p.closeSubpath()
    }
    // download (version/update card): tray + down arrow.
    // M12 3v12  M7 10l5 5 5-5  M5 21h14 (tray base)
    static func download(_ p: inout Path) {
        // shaft
        p.move(to: .init(x: 12, y: 3))
        p.addLine(to: .init(x: 12, y: 15))
        // arrowhead
        p.move(to: .init(x: 7, y: 10))
        p.addLine(to: .init(x: 12, y: 15))
        p.addLine(to: .init(x: 17, y: 10))
        // tray base
        p.move(to: .init(x: 5, y: 20))
        p.addLine(to: .init(x: 19, y: 20))
    }
}

// MARK: - Card surface (fill + 1px border), same as StatusView's `card`

private func setCard(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(Tokens.C.cardBg)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Tokens.C.cardBorder, lineWidth: 1)
        )
}

// MARK: - SettingsView

/// The "Настройки" screen. Purely presentational — the host wires every closure.
///
/// Layout (top → bottom), all metrics from Tokens:
///   header (‹ back + "Настройки")
///   card 1 — Отслеживаемая папка (path + "Сменить")  ← primary setting, first
///   card 2 — Сбросить статистику · Full Disk Access ›
///   card 3 — Версия X.Y.Z + "Проверить обновление" button
///   credit — "fb2-to-epub X.Y.Z · by Alex Kovalev · GitHub" (centered)
///
/// "Отслеживаемая папка" is the main setting, so it sits first; the quick "Открыть
/// папку" action stays on Status's footer.
struct SettingsView: View {
    // Actions — the host (main.swift) proxies these into the engine / AppKit.
    var onDone: () -> Void = {}            // ‹ back → present(.status)
    var onChangeFolder: () -> Void = {}    // NSOpenPanel → re-target the agent
    var onOpenFDA: () -> Void = {}         // jump to Full Disk Access pane
    var onResetStats: () -> Void = {}      // NSAlert-confirmed stats reset (host)
    var onCheckUpdate: () -> Void = {}     // UpdateChecker.checkLatest
    var onOpenGitHub: () -> Void = {}      // NSWorkspace open repo

    /// Current watch folder, tilde-collapsed for display (the host passes the same
    /// collapsed string Status used). Shown as the card's subtext.
    var watchDir: String = "~/Desktop/fb2-to-epub"

    /// Marketing version straight from the bundle (single source of truth; more
    /// precise than the hardcoded Tokens.Project token). Falls back to the same
    /// constant the rest of the app uses when the key is unreadable.
    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? Tokens.Project.fallbackVersion
    }

    var body: some View {
        ZStack {
            Tokens.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                watchFolderCard
                resetAndAccessCard
                versionCard
                Spacer(minLength: 0)
                credit
            }
        }
        .frame(width: Tokens.M.windowWidth)
    }

    // --- Header (‹ back + title) ---------------------------------------------
    // Mirrors CoverSelectView's header: a bordered ‹ button on the left + the h1
    // title. Tapping ‹ exits back to Status (onDone).
    private var header: some View {
        HStack(spacing: Tokens.M.headerGap - 1) { // CoverSelect uses gap 11
            backButton
            Text("Настройки")
                .font(Tokens.F.h1)
                .foregroundColor(Tokens.C.textPrimary)
                .trackingCompat(Tokens.Track.h1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.M.headerPadH)
        .padding(.top, Tokens.M.headerPadTop)
        .padding(.bottom, Tokens.M.headerPadBottom)
    }

    /// ‹ — exit Settings back to Status (onDone). Reuses CoverSelectView's nav
    /// button language (clear fill + 1px linkBorder + linkText chevron).
    ///
    /// Hit-testing (see .patches/010): the visible surface is a `Color.clear` fill
    /// + a stroked border + a stroke-only chevron — NONE of which are hit-testable.
    /// A `.buttonStyle(.plain)` Button does not synthesize a rectangular tap region,
    /// so the effective target collapsed to ~nothing and ‹ never fired `onDone`. We
    /// drop the Button and use the same proven pattern as every other control on
    /// these screens — `.contentShape(Rectangle())` + `.onTapGesture` — so the whole
    /// padded box is tappable.
    private var backButton: some View {
        StrokeIcon(size: 18, lineWidth: 2.2, build: SetIcons.back)
            .foregroundColor(Tokens.CS.linkText)
            .padding(.vertical, Tokens.CS.linkPadV)
            .padding(.horizontal, Tokens.CS.linkPadH)
            .background(
                RoundedRectangle(cornerRadius: Tokens.CS.linkRadius, style: .continuous)
                    .fill(Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.CS.linkRadius, style: .continuous)
                    .stroke(Tokens.CS.linkBorder, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: onDone)
            .help("Назад к статусу")
    }

    // --- Card 1: Отслеживаемая папка (primary setting, first) ----------------
    // Moved here from the Status screen. Single-row card (same chrome as the
    // version card): an orange folder chip + "Отслеживаемая папка" label with the
    // tilde-collapsed path beneath, and a "Сменить" link on the right that opens
    // the host's NSOpenPanel (changeWatchFolder). Only the explicit "Сменить" link
    // is the tap target — tapping the label/path does nothing, exactly as it
    // behaved on Status.
    private var watchFolderCard: some View {
        HStack(spacing: Tokens.M.rowGap) {
            rowIcon(tint: Tokens.C.tintOrange, color: Tokens.C.accentOrange,
                    SetIcons.folder)
            VStack(alignment: .leading, spacing: 1) {
                Text("Отслеживаемая папка")
                    .font(Tokens.F.rowLabel)
                    .foregroundColor(Tokens.C.textPrimary)
                Text(watchDir)
                    .font(Tokens.F.rowSub)
                    .foregroundColor(Tokens.C.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            changeFolderLink
        }
        .padding(.horizontal, Tokens.M.rowPadH)
        .padding(.vertical, Tokens.M.rowPadV)
        .background(setCard(radius: Tokens.M.groupRadius))
        .padding(.horizontal, Tokens.M.cardInset)
        .padding(.bottom, Tokens.M.cardSpacing)
    }

    /// "Сменить" — the folder-change link (same .link font + accent-orange as the
    /// old Status row). Transparent tap target, so it MUST carry
    /// `.contentShape(Rectangle())` to be clickable (see .patches/010 — a plain
    /// stroked/text-only target collapses to ~no hit area without it).
    private var changeFolderLink: some View {
        Text("Сменить")
            .font(Tokens.F.link)
            .foregroundColor(Tokens.C.accentOrange)
            .contentShape(Rectangle())
            .onTapGesture(perform: onChangeFolder)
    }

    // --- Card 2: Сбросить статистику + Full Disk Access ----------------------
    // The two remaining secondary actions, grouped in one card with a hairline
    // between (same chrome as every other grouped card: setCard + groupRadius).
    private var resetAndAccessCard: some View {
        VStack(spacing: 0) {
            // Сбросить статистику — light destructive hint: a soft warm-red icon
            // chip + label (gentle, not an alarm). Right chevron stays muted.
            row(action: onResetStats) {
                rowIcon(tint: destructiveTintBg, color: destructiveTint,
                        SetIcons.reset)
                Text("Сбросить статистику")
                    .font(Tokens.F.rowLabel)
                    .foregroundColor(destructiveTint)
                Spacer(minLength: 0)
                StrokeIcon(size: 14, build: SetIcons.chevron)
                    .foregroundColor(Tokens.C.textTertiary)
            }

            hairline

            row(action: onOpenFDA) {
                rowIcon(tint: Tokens.C.tintOrange, color: Tokens.C.accentOrange,
                        SetIcons.shield)
                Text("Full Disk Access")
                    .font(Tokens.F.rowLabel)
                    .foregroundColor(Tokens.C.textPrimary)
                Spacer(minLength: 0)
                StrokeIcon(size: 14, build: SetIcons.chevron)
                    .foregroundColor(Tokens.C.textTertiary)
            }
        }
        .background(setCard(radius: Tokens.M.groupRadius))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.M.groupRadius, style: .continuous))
        .padding(.horizontal, Tokens.M.cardInset)
        .padding(.bottom, Tokens.M.cardSpacing)
    }

    // --- Card 3: Версия + Проверить обновление -------------------------------
    private var versionCard: some View {
        HStack(spacing: Tokens.M.rowGap) {
            rowIcon(tint: Tokens.C.tintOrange, color: Tokens.C.accentOrange,
                    SetIcons.download)
            VStack(alignment: .leading, spacing: 2) {
                Text("Версия \(version)")
                    .font(Tokens.F.rowLabel)
                    .foregroundColor(Tokens.C.textPrimary)
                Text("fb2-to-epub")
                    .font(Tokens.F.rowSub)
                    .foregroundColor(Tokens.C.textTertiary)
            }
            Spacer(minLength: 8)
            updateButton
        }
        .padding(.horizontal, Tokens.M.rowPadH)
        .padding(.vertical, Tokens.M.rowPadV)
        .background(setCard(radius: Tokens.M.groupRadius))
        .padding(.horizontal, Tokens.M.cardInset)
        .padding(.bottom, Tokens.M.cardSpacing)
    }

    /// "Проверить обновление" — the app's standard translucent button (same surface
    /// as StatusView's footer .btn: btnBg + btnBorder + btnRadius).
    private var updateButton: some View {
        Text("Проверить обновление")
            .font(Tokens.F.button)
            .foregroundColor(Tokens.C.textPrimary)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Tokens.M.btnPadH)
            .padding(.vertical, Tokens.M.btnPadV)
            .background(
                RoundedRectangle(cornerRadius: Tokens.M.btnRadius, style: .continuous)
                    .fill(Tokens.C.btnBg))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.M.btnRadius, style: .continuous)
                    .stroke(Tokens.C.btnBorder, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: onCheckUpdate)
    }

    // --- Credit footer (centered) --------------------------------------------
    // Reuses StatusView's credit language exactly: 11px muted text + blue,
    // slightly-heavier "GitHub" as the only clickable part. Version from the
    // bundle (CFBundleShortVersionString) — the precise marketing version.
    private var credit: some View {
        HStack(spacing: 0) {
            Text("fb2-to-epub \(version) · by Alex Kovalev · ")
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

    // --- Row primitives (mirror StatusView's grouped-list row) ---------------

    /// One tappable list row: same paddings/gap as StatusView's `row`, wrapped in
    /// a tap target. Hit area covers the full row width.
    private func row<Content: View>(action: @escaping () -> Void,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Tokens.M.rowGap, content: content)
            .padding(.horizontal, Tokens.M.rowPadH)
            .padding(.vertical, Tokens.M.rowPadV)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    /// Tinted 28×28 icon chip (StatusView.rowIcon): tint fill + accent stroke icon.
    private func rowIcon(tint: Color, color: Color,
                         _ build: @escaping (inout Path) -> Void) -> some View {
        RoundedRectangle(cornerRadius: Tokens.M.rowIconRadius, style: .continuous)
            .fill(tint)
            .overlay(StrokeIcon(size: 15, build: build).foregroundColor(color))
            .frame(width: Tokens.M.rowIcon, height: Tokens.M.rowIcon)
    }

    /// Hairline divider between rows (StatusView.hairline).
    private var hairline: some View {
        Rectangle().fill(Tokens.C.hairline)
            .frame(height: 1)
            .padding(.horizontal, Tokens.M.cardInset)
    }

    /// A muted, warm-red destructive hint for "Сбросить статистику" — reads
    /// "careful" without the aggression of a full alarm red. Local blends (kept
    /// here, not new global tokens): the icon/label color + its faint chip tint
    /// (alpha .12, mirroring the Tokens.C.tint* row-icon convention).
    private var destructiveTint: Color {
        Color(.sRGB, red: 0.92, green: 0.42, blue: 0.45, opacity: 1.0)
    }
    private var destructiveTintBg: Color {
        Color(.sRGB, red: 0.92, green: 0.42, blue: 0.45, opacity: 0.12)
    }
}
