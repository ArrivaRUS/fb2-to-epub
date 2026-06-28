// SetupView — the first-run "Установка / Готово к работе" screen (M3).
//
// Built strictly from design/spec-ui.md + design/mockups/ui-native.html
// (SCREEN 2 — SETUP). Every color/size/inset comes from Tokens (no inline
// literals) so pixel-perfect (G3 / M7) stays a one-file diff.
//
// Layout mirrors the mockup top-to-bottom:
//   header (app icon + title + gear) · welcome ("Готово к работе" + subtitle) ·
//   wizard card with TWO green-check rows (ДВИЖОК / ОТСЛЕЖИВАЕМАЯ ПАПКА) ·
//   footnote (one-time Full Disk Access hint) · footer (● Отслеживание активно +
//   "Открыть папку") · credit footer.
//
// Per D10 (watching is on by default) there is NO "Начать отслеживание" button —
// both rows are already green and the footer reads "Отслеживание активно".
//
// Data is real: Calibre version + watch dir + agent state come from the host via
// the same EngineClient the Status screen uses. Mutating actions are closures the
// host supplies; only "open folder" is functional (read-only w.r.t. the engine).

import SwiftUI
import AppKit

// MARK: - Hover cursor (pointer on the inline GitHub link)

private extension View {
    func onHoverCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Vector icons (stroke paths in a 24x24 box, like the mockup SVGs)

/// A stroked icon over a 0...24 coordinate box, scaled to `size`. Mirrors the
/// lucide-style 2px strokes used throughout the mockup. (Kept local to Setup so
/// it has exactly the four glyphs this screen needs — folder, gear, check, info.)
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

private enum SetupIcons {
    // folder (mockup d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z")
    static func folder(_ p: inout Path) {
        p.move(to: .init(x: 3, y: 7))
        p.addLine(to: .init(x: 3, y: 19))
        p.addLine(to: .init(x: 21, y: 19))
        p.addLine(to: .init(x: 21, y: 9))
        p.addLine(to: .init(x: 11, y: 9))
        p.addLine(to: .init(x: 9, y: 7))
        p.closeSubpath()
    }
    // gear: spokes + center circle (same as the Status header)
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
    // checkmark (mockup d="M5 13l4 4L19 7")
    static func check(_ p: inout Path) {
        p.move(to: .init(x: 5, y: 13))
        p.addLine(to: .init(x: 9, y: 17))
        p.addLine(to: .init(x: 19, y: 7))
    }
    // info circle (mockup: circle r9 + "M12 8v.01M12 11v5")
    static func info(_ p: inout Path) {
        p.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18)) // circle cx12 cy12 r9
        p.move(to: .init(x: 12, y: 8)); p.addLine(to: .init(x: 12, y: 8.01))
        p.move(to: .init(x: 12, y: 11)); p.addLine(to: .init(x: 12, y: 16))
    }
}

// MARK: - App icon (brand squircle + book-spark)

/// Same brand squircle + open-book-with-spark as the Status header. Duplicated
/// locally (StatusView's is private) but every value still comes from Tokens.
private struct SetupAppIcon: View {
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

    private struct BookSpark: View {
        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let cx = w / 2, cy = h / 2
                let u = w / 24
                ZStack {
                    pageLeft(cx: cx, cy: cy, u: u).fill(Color.white(0.16))
                    pageLeft(cx: cx, cy: cy, u: u).stroke(Color.white(0.85), lineWidth: 1.1 * u)
                    pageRight(cx: cx, cy: cy, u: u).fill(Color.white(0.16))
                    pageRight(cx: cx, cy: cy, u: u).stroke(Color.white(0.85), lineWidth: 1.1 * u)
                    Path { p in
                        p.move(to: .init(x: cx, y: cy - 7.5 * u))
                        p.addLine(to: .init(x: cx, y: cy + 8 * u))
                    }.stroke(Color.white(0.6), lineWidth: 1 * u)
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

// MARK: - Caps label (.cap): 9 / 700 / +1.2 tracking / tertiary

private struct CapLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Tokens.F.cap)
            .foregroundColor(Tokens.C.textTertiary)
            .trackingCompat(Tokens.Track.cap)
    }
}

/// Card surface (fill + 1px border) at a given corner radius — same as Status.
private func card(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(Tokens.C.cardBg)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Tokens.C.cardBorder, lineWidth: 1)
        )
}

// MARK: - SetupView

struct SetupView: View {
    /// Calibre version for the engine row, e.g. "7.21". When nil the row still
    /// reads green ("Calibre найден") — the host only routes to Setup once the
    /// engine is ready, so a missing version is a display gap, not a failure.
    let calibreVersion: String?
    /// The watched folder, already tilde-collapsed for display by the host.
    let watchDir: String

    // Actions (only openFolder is functional; change/settings prepared).
    var onOpenFolder: () -> Void = {}
    var onChangeFolder: () -> Void = {}
    var onSettings: () -> Void = {}
    /// Opens the GitHub repo (host wires this to NSWorkspace.shared.open).
    var onOpenGitHub: () -> Void = {}

    /// "Calibre 7.21 найден" when the version is known, else "Calibre найден".
    private var engineTitle: String {
        if let v = calibreVersion, !v.isEmpty, v != "✓" {
            return "Calibre \(v) найден"
        }
        return "Calibre найден"
    }

    var body: some View {
        ZStack {
            Tokens.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                welcome
                wizard
                footnote
                Spacer(minLength: 0)
                footer
                credit
            }
        }
        .frame(width: Tokens.M.windowWidth)
    }

    // --- Header (identical structure to the Status header) -------------------
    private var header: some View {
        HStack(spacing: Tokens.M.headerGap) {
            SetupAppIcon()
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
            iconButton { SetupIcons.gear(&$0) }
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

    // --- Welcome -------------------------------------------------------------
    private var welcome: some View {
        VStack(spacing: Tokens.M.welcomeSubGap) {
            Text("Готово к работе")
                .font(Tokens.F.welcomeH2)
                .foregroundColor(Tokens.C.textPrimary)
                .trackingCompat(Tokens.Track.welcomeH2)
            Text("Уже отслеживаю папку ниже — кидай в неё\n.fb2, .fb2.zip или .fb3, рядом появится .epub.")
                .font(Tokens.F.welcomeSub)
                .foregroundColor(Tokens.C.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(Tokens.M.welcomeLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Tokens.M.welcomePadH)
        .padding(.top, Tokens.M.welcomePadTop)
        .padding(.bottom, Tokens.M.welcomePadBottom)
    }

    // --- Wizard (two green-check rows) ---------------------------------------
    private var wizard: some View {
        VStack(spacing: 0) {
            // Row 1 — ДВИЖОК (Calibre found / ready)
            stepRow {
                stepNumOK()
                VStack(alignment: .leading, spacing: 0) {
                    CapLabel(text: "ДВИЖОК")
                    Text(engineTitle)
                        .font(Tokens.F.stepTitle)
                        .foregroundColor(Tokens.C.textPrimary)
                        .padding(.top, Tokens.M.stepTitleTop)
                    Text("Готов к конвертации")
                        .font(Tokens.F.stepOkSub)
                        .foregroundColor(Tokens.C.emerald)
                        .padding(.top, Tokens.M.stepOkSubTop)
                }
                Spacer(minLength: 0)
            }

            // hairline (mockup: margin 0 16)
            Rectangle().fill(Tokens.C.hairline)
                .frame(height: 1)
                .padding(.horizontal, Tokens.M.stepHairlineH)

            // Row 2 — ОТСЛЕЖИВАЕМАЯ ПАПКА (path + "Сменить…")
            stepRow {
                stepNumOK()
                VStack(alignment: .leading, spacing: 0) {
                    CapLabel(text: "ОТСЛЕЖИВАЕМАЯ ПАПКА")
                    folderField
                        .padding(.top, Tokens.M.fieldTop)
                }
            }
        }
        .padding(.vertical, Tokens.M.wizardPadV)
        .background(card(radius: Tokens.M.wizardRadius))
        .padding(.horizontal, Tokens.M.wizardMarginH)
        .padding(.top, Tokens.M.wizardMarginTop)
        .padding(.bottom, Tokens.M.wizardMarginBottom)
    }

    /// One wizard step: 26x26 number bubble + body, top-aligned, gap 12.
    private func stepRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Tokens.M.stepGap, content: content)
            .padding(.horizontal, Tokens.M.stepPadH)
            .padding(.vertical, Tokens.M.stepPadV)
    }

    /// The green "done" step bubble: emerald-tinted circle with a check glyph.
    private func stepNumOK() -> some View {
        Circle()
            .fill(Tokens.C.stepOkBg)
            .overlay(Circle().stroke(Tokens.C.stepOkBorder, lineWidth: 1))
            .overlay(
                StrokeIcon(size: 14, lineWidth: 3, build: SetupIcons.check)
                    .foregroundColor(Tokens.C.emerald)
            )
            .frame(width: Tokens.M.stepNumSize, height: Tokens.M.stepNumSize)
    }

    /// The folder row: read-only path field (folder icon + mono path) + "Сменить…".
    private var folderField: some View {
        HStack(spacing: Tokens.M.fieldGap) {
            HStack(spacing: Tokens.M.fieldInputGap) {
                StrokeIcon(size: 14, build: SetupIcons.folder)
                    .foregroundColor(Tokens.C.textSecondary)
                Text(watchDir)
                    .font(Tokens.F.fieldMono)
                    .foregroundColor(Tokens.C.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.M.fieldInputPadH)
            .padding(.vertical, Tokens.M.fieldInputPadV)
            .background(
                RoundedRectangle(cornerRadius: Tokens.M.fieldInputRadius, style: .continuous)
                    .fill(Tokens.C.inputBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.M.fieldInputRadius, style: .continuous)
                    .stroke(Tokens.C.fieldBorder, lineWidth: 1)
            )

            Text("Сменить…")
                .font(Tokens.F.fieldBtn)
                .foregroundColor(Tokens.C.textPrimary)
                .padding(.horizontal, Tokens.M.fieldBtnPadH)
                .padding(.vertical, Tokens.M.fieldBtnPadV)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.M.fieldBtnRadius, style: .continuous)
                        .fill(Tokens.C.fieldBtnBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.M.fieldBtnRadius, style: .continuous)
                        .stroke(Tokens.C.fieldBtnBorder, lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: onChangeFolder)
        }
    }

    // --- Footnote (one-time Full Disk Access hint) ---------------------------
    private var footnote: some View {
        HStack(alignment: .top, spacing: Tokens.M.footnoteGap) {
            StrokeIcon(size: 13, build: SetupIcons.info)
                .foregroundColor(Tokens.C.textTertiary)
                .padding(.top, 1)
            Text("При папке в Desktop / Documents может понадобиться разовый Full Disk Access.")
                .font(Tokens.F.footnote)
                .foregroundColor(Tokens.C.textTertiary)
                .lineSpacing(Tokens.M.footnoteLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.M.footnotePadH)
        .padding(.top, Tokens.M.footnotePadTop)
        .padding(.bottom, Tokens.M.footnotePadBottom)
    }

    // --- Footer (active by default, NO start button) -------------------------
    private var footer: some View {
        HStack(spacing: Tokens.M.footerGap) {
            Circle()
                .fill(Tokens.C.emerald)
                .frame(width: Tokens.M.footDot, height: Tokens.M.footDot)
                .shadow(color: Tokens.C.emerald, radius: 3)
            Text("Отслеживание активно")
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
            StrokeIcon(size: 13, build: SetupIcons.folder).foregroundColor(Tokens.C.accentOrange)
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

    // --- Credit footer (reused style from Status) ----------------------------
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
}
