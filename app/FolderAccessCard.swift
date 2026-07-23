// FolderAccessCard — the FDA-onboarding component (v1.0.1, D46), rendered in four
// presentations, mirroring EngineSetupCard's visual grammar and tokens WITHOUT
// touching it (its Phase automat is a just-shipped v1.0.0 surface — coupling the two
// would blow up the "4 подачи × N states" matrix, arch/plan-fda-synthesis.md).
//
// One problem (the agent has no Full Disk Access, so the watch folder is unreadable
// and books silently don't convert), FOUR подачи (mirror the engine onboarding):
//   • .blocker     — full-screen: warn ring + title + steps + CTA (replaces Status
//                    content when there is NO conversion history).
//   • .banner      — warn card under the header, Status content stays visible+muted
//                    (there IS history — conversion is equally blocked either way).
//   • .setupStep   — amber «ДОСТУП К ПАПКЕ» step body on first-run Setup (display-only,
//                    hands off to Status where the live flow lives).
//   • .settingsRow — the compact warn row in Настройки (replaces the passive FDA row
//                    only while denied; ok/absent keeps today's byte-identical row).
//
// A tiny automat drives blocker/banner:  denied / checking / stillDenied / timeout.
// FDA-2 is DISPLAY-ONLY: every button defaults to a no-op; the real recheck/clipboard/
// panel pipeline is wired at FDA-3. Screenshots come via FB2_FORCE_FOLDER_ACCESS.

import SwiftUI
import AppKit

// MARK: - Local glyph helper (file-private; mirrors StatusView/EngineSetupCard)

private func faIcon(_ name: String, size: CGFloat, weight: Font.Weight = .regular) -> some View {
    Image(systemName: name)
        .font(.system(size: size, weight: weight))
}

// MARK: - FolderAccessCard

struct FolderAccessCard: View {

    /// The tiny recheck automat. `denied` is the resting problem state; the other
    /// three are transient states the host drives during «Проверить снова» (FDA-3).
    enum State: Equatable {
        case denied         // no access — the resting problem
        case checking       // «Проверить снова» pressed, waiting for a fresh probe
        case stillDenied    // the fresh probe still says denied
        case timeout        // the agent never answered (kickstart failed / agent off)

        /// The two RESTING outcomes the host may PIN after a recheck coordinator tears
        /// down. Distinguished from the transient `.checking` and the live-derived
        /// `.denied` so the refresh cycle can dissolve a stale terminal card once the
        /// live flag recovers (A1, via `FolderRecheck.terminalRecheckDissolves`).
        var isTerminal: Bool { self == .stillDenied || self == .timeout }
    }

    /// Which of the four surfaces to render.
    enum Presentation { case blocker, banner, setupStep, settingsRow }

    let state: State
    let presentation: Presentation

    // Actions — DRAWN but inert in FDA-2 (defaults are no-ops). Wired at FDA-3.
    /// Primary: open the Full Disk Access pane AND copy the runner path to the clipboard.
    var onOpenSettings: () -> Void = {}
    /// Secondary: kick the agent and wait for a fresh probe.
    var onRecheck: () -> Void = {}
    /// Setup step only: hand off to Status (where the live blocker/banner lives).
    var onFixFromSetup: () -> Void = {}

    var body: some View {
        switch presentation {
        case .blocker:     blocker
        case .banner:      banner
        case .setupStep:   setupStep
        case .settingsRow: settingsRow
        }
    }

    // MARK: - Shared texts (ты-форма, honest — never asserts "FDA запрещён")

    // The three numbered steps (same wording A/B; the badge style differs by direction).
    private static let step1 = "Нажми «+» под списком."
    private static let step2 = "Cmd-Shift-G и вставь путь — он уже в буфере."
    private static let step3lead = "Включи переключатель у "
    private static let step3accent = "fb2-to-epub-runner.sh"

    private var blockerTitleText: String {
        state == .timeout ? "Агент не ответил" : "Нет доступа к папке"
    }
    private var bodyText: String {
        state == .timeout
            ? "Фоновый агент не отозвался. Проверь, что он активен, и попробуй ещё раз."
            : "macOS прячет «Рабочий стол», «Документы» и «Загрузки» от фоновых программ. "
              + "Разреши доступ один раз — и конвертация заработает."
    }
    /// The status/feedback line above the buttons, per automat state (nil = none).
    private var feedbackText: String? {
        switch state {
        case .denied:      return nil
        case .checking:    return "Проверяю доступ…"
        case .stillDenied: return "Доступа пока нет — проверь шаги и попробуй ещё раз."
        case .timeout:     return nil    // the timeout message is the body itself
        }
    }
    private var isChecking: Bool { state == .checking }
}

// MARK: - Reusable buttons (tokens-exact; file-private mirrors of EngineSetupCard's)

/// `.cta` — the big blocker button (Direction B). Orange fill for FDA.
private struct FaCtaBig: View {
    let title: String
    var icon: String? = nil
    var disabled: Bool = false
    let action: () -> Void
    var body: some View {
        HStack(spacing: Tokens.CO.ctaGap) {
            if let icon = icon {
                faIcon(icon, size: 16, weight: .bold).foregroundColor(.white)
            }
            Text(title).font(Tokens.CS.cta_).foregroundColor(.white)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(Tokens.CO.ctaPad)
        .background(
            RoundedRectangle(cornerRadius: Tokens.CO.ctaBigRadius, style: .continuous)
                .fill(Tokens.CO.retryOrangeGrad))
        .shadow(color: Tokens.CO.ctaShadowOrangeColor,
                radius: Tokens.CO.ctaShadowRadius, x: 0, y: Tokens.CO.ctaShadowY)
        .padding(.top, Tokens.CO.ctaTop)
        .opacity(disabled ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !disabled { action() } }
    }
}

/// `.cta-ghost` — secondary "Проверить снова" (Direction B).
private struct FaCtaGhost: View {
    let title: String
    var icon: String? = nil
    var disabled: Bool = false
    let action: () -> Void
    var body: some View {
        HStack(spacing: Tokens.CO.ctaGap) {
            if let icon = icon {
                faIcon(icon, size: 15, weight: .regular).foregroundColor(Tokens.C.textSoft)
            }
            Text(title).font(Tokens.F.stepTitle).foregroundColor(Tokens.C.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(Tokens.CO.ctaGhostPad)
        .background(
            RoundedRectangle(cornerRadius: Tokens.CO.ctaBigRadius, style: .continuous)
                .fill(Tokens.C.btnBg))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.CO.ctaBigRadius, style: .continuous)
                .stroke(Tokens.C.fieldBtnBorder, lineWidth: 1))
        .padding(.top, Tokens.CO.ctaTop)
        .opacity(disabled ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !disabled { action() } }
    }
}

/// `.cta-sm` — the small brand/orange button (banner A + Setup + Settings).
private struct FaCtaSmall: View {
    enum Size { case big, compact }
    enum Fill { case brand, orange }
    let title: String
    var icon: String? = nil
    var size: Size = .big
    var fill: Fill = .orange
    var disabled: Bool = false
    let action: () -> Void
    var body: some View {
        HStack(spacing: Tokens.CO.ctaSmGap) {
            if let icon = icon {
                faIcon(icon, size: size == .big ? 13 : 12, weight: .bold).foregroundColor(.white)
            }
            Text(title)
                .font(size == .big ? Tokens.CO.ctaSmFont : Tokens.CO.ctaSmFontSm)
                .foregroundColor(.white)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, size == .big ? Tokens.CO.ctaSmPadV : Tokens.CO.ctaSmPadVsm)
        .padding(.horizontal, size == .big ? Tokens.CO.ctaSmPadH : Tokens.CO.ctaSmPadHsm)
        .background(fillShape)
        .shadow(color: Tokens.CO.ctaSmShadowColor,
                radius: Tokens.CO.ctaSmShadowRadius, x: 0, y: Tokens.CO.ctaSmShadowY)
        .opacity(disabled ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !disabled { action() } }
    }

    // @ViewBuilder switch (not AnyShapeStyle, which is macOS 12+) — the app targets 11.0.
    @ViewBuilder private var fillShape: some View {
        switch fill {
        case .brand:
            RoundedRectangle(cornerRadius: Tokens.CO.ctaRadius, style: .continuous).fill(Tokens.G.brand135)
        case .orange:
            RoundedRectangle(cornerRadius: Tokens.CO.ctaRadius, style: .continuous).fill(Tokens.CO.retryOrangeGrad)
        }
    }
}

/// `.link-btn` — text-only secondary (12px everywhere).
private struct FaLinkBtn: View {
    let title: String
    var orange: Bool = false
    var disabled: Bool = false
    let action: () -> Void
    var body: some View {
        Text(title)
            .font(Tokens.F.link)
            .foregroundColor(orange ? Tokens.C.accentOrange : Tokens.C.textSecondary)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .opacity(disabled ? 0.5 : 1)
            .contentShape(Rectangle())
            .onTapGesture { if !disabled { action() } }
    }
}

// MARK: - Numbered step (mirrors EngineSetupCard.ManualStep)

private struct FaStep: View {
    enum Direction { case a, b }
    let dir: Direction
    let n: Int
    let leading: String
    var accent: String? = nil
    var accentMono: Bool = false
    var trailing: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: dir == .a ? Tokens.CO.stepsGapA : Tokens.CO.stepsGapB) {
            badge
            line.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var badge: some View {
        Text("\(n)")
            .font(dir == .a ? Tokens.CO.stepBadgeFontA : Tokens.F.pill)
            .foregroundColor(dir == .a ? Tokens.C.textSoft : Tokens.C.accentOrange)
            .frame(width: dir == .a ? Tokens.CO.stepBadgeA : Tokens.CO.stepBadgeB,
                   height: dir == .a ? Tokens.CO.stepBadgeA : Tokens.CO.stepBadgeB)
            .background(Circle().fill(dir == .a ? Tokens.C.cardBorder : Tokens.C.stepCurBg))
            .overlay(dir == .b ? Circle().stroke(Tokens.CO.warnBorder30, lineWidth: 1) : nil)
            .padding(.top, 1)
    }

    private var line: some View {
        let bodyFont = dir == .a ? Tokens.CO.stepTextA : Tokens.F.headerSub
        let accentText: Text = accent.map { word in
            accentMono
                ? Text(word).font(Tokens.F.convSemibold).foregroundColor(Tokens.C.textPrimary)
                : Text(word).font(bodyFont).fontWeight(.semibold).foregroundColor(Tokens.C.textSoft)
        } ?? Text("")
        return (Text(leading) + accentText + Text(trailing))
            .font(bodyFont)
            .foregroundColor(Tokens.C.textSoft)
            .lineSpacing(dir == .a ? Tokens.CO.stepTextALineSpacing : Tokens.CO.stepTextBLineSpacing)
    }
}

// MARK: - Small caps label + warn ring + indeterminate bar (file-local mirrors)

private struct FaCapLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Tokens.F.cap)
            .foregroundColor(Tokens.C.textTertiary)
            .trackingCompat(Tokens.Track.cap)
    }
}

/// The 104×104 warn ring: dashed amber track + ⚠ (or a continuous spin while checking).
private struct FaWarnRing: View {
    var checking: Bool = false
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle().stroke(Tokens.C.barTrack, style: StrokeStyle(lineWidth: Tokens.M.ringStroke))
            if checking {
                Circle()
                    .trim(from: 0, to: 70 / Tokens.CO.ringCircumference)
                    .stroke(Tokens.CO.ringInstallGrad,
                            style: StrokeStyle(lineWidth: Tokens.M.ringStroke, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                faIcon("gearshape", size: Tokens.CO.ringIconGear, weight: .regular)
                    .foregroundColor(Tokens.C.accentOrange)
                    .rotationEffect(.degrees(spin ? 360 : 0))
            } else {
                Circle()
                    .stroke(Tokens.CO.ringWarnDash,
                            style: StrokeStyle(lineWidth: Tokens.M.ringStroke, lineCap: .round, dash: [4, 10]))
                faIcon("lock.shield", size: Tokens.CO.ringIconWarn, weight: .regular)
                    .foregroundColor(Tokens.C.accentOrange)
            }
        }
        .frame(width: Tokens.M.ringSize, height: Tokens.M.ringSize)
        .onAppear { syncSpin() }
        // A3: the ring is a PERSISTENT instance in the blocker (not conditionally
        // re-inserted), so a live denied→checking flip does NOT re-fire onAppear — the
        // gearshape would sit frozen. Restart/stop the spin on every `checking` flip.
        .onChange(of: checking) { _ in syncSpin() }
    }

    /// Drive the continuous spin from the current `checking` value: start the repeating
    /// rotation while checking, drop it (and reset the angle) otherwise so a later
    /// checking begins from 0. Called on appear AND on each `checking` transition (A3).
    private func syncSpin() {
        if checking {
            withAnimation(.linear(duration: Tokens.CO.spinDur).repeatForever(autoreverses: false)) {
                spin = true
            }
        } else {
            withAnimation(.linear(duration: 0)) { spin = false }
        }
    }
}

/// The 6px indeterminate progress bar (shown while checking), mirrors EngineSetupCard.
private struct FaProgressBar: View {
    @SwiftUI.State private var slide = false
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Tokens.CO.progRadius, style: .continuous)
                    .fill(Tokens.C.barTrack)
                RoundedRectangle(cornerRadius: Tokens.CO.progRadius, style: .continuous)
                    .fill(Tokens.G.barOrange)
                    .frame(width: Tokens.CO.progIndetWidth * w)
                    .offset(x: slide ? w * (1 - Tokens.CO.progIndetWidth) : 0)
            }
        }
        .frame(height: Tokens.CO.progHeight)
        .onAppear {
            withAnimation(.easeInOut(duration: Tokens.CO.progIndetDur).repeatForever(autoreverses: true)) {
                slide = true
            }
        }
    }
}

// MARK: - Presentation: BLOCKER (Direction B)

extension FolderAccessCard {

    var blocker: some View {
        VStack(spacing: 0) {
            FaWarnRing(checking: isChecking)

            Text(blockerTitleText)
                .font(Tokens.CO.blockerTitle)
                .foregroundColor(Tokens.C.textPrimary)
                .trackingCompat(Tokens.Track.welcomeH2)
                .multilineTextAlignment(.center)
                .padding(.top, Tokens.CO.blTitleTop)

            Text(bodyText)
                .font(Tokens.F.welcomeSub)
                .foregroundColor(Tokens.C.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(Tokens.CO.blBodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Tokens.CO.blBodyMaxW)
                .padding(.top, Tokens.CO.blBodyTop)

            // Steps hidden while actively checking (the spinner + status carry it).
            if !isChecking {
                VStack(alignment: .leading, spacing: Tokens.CO.stepsGapB) {
                    FaStep(dir: .b, n: 1, leading: Self.step1)
                    FaStep(dir: .b, n: 2, leading: Self.step2)
                    FaStep(dir: .b, n: 3, leading: Self.step3lead,
                           accent: Self.step3accent, accentMono: true, trailing: ".")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Tokens.CO.stepsTopB)
            } else {
                FaProgressBar().padding(.top, Tokens.CO.stepsTopB)
            }

            if let fb = feedbackText {
                Text(fb)
                    .font(Tokens.CO.bannerSub)
                    .foregroundColor(state == .stillDenied ? Tokens.C.accentOrange : Tokens.C.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Tokens.CO.blBodyMaxW)
                    .padding(.top, 12)
            }

            FaCtaBig(title: "Открыть настройки и скопировать путь",
                     icon: "arrow.up.right.square", disabled: isChecking, action: onOpenSettings)
            FaCtaGhost(title: "Проверить снова", icon: "arrow.clockwise",
                       disabled: isChecking, action: onRecheck)
        }
        .frame(maxWidth: .infinity, minHeight: Tokens.CO.blockerMinH, alignment: .top)
        .padding(.top, 20)
        .padding(.horizontal, Tokens.CO.blockerPadH)
        .padding(.bottom, Tokens.CO.blockerPadBottom)
    }
}

// MARK: - Presentation: BANNER (Direction A)

extension FolderAccessCard {

    var banner: some View {
        VStack(alignment: .leading, spacing: 0) {
            // b-top: 28px warn icon chip + title/sub column.
            HStack(alignment: .top, spacing: Tokens.CO.bTopGap) {
                RoundedRectangle(cornerRadius: Tokens.M.rowIconRadius, style: .continuous)
                    .fill(Tokens.C.stepCurBg)
                    .overlay(faIcon(isChecking ? "arrow.clockwise" : "lock.shield",
                                    size: Tokens.CO.bannerIcon, weight: .regular)
                        .foregroundColor(Tokens.C.accentOrange))
                    .frame(width: Tokens.M.rowIcon, height: Tokens.M.rowIcon)
                VStack(alignment: .leading, spacing: 0) {
                    Text(blockerTitleText)
                        .font(Tokens.CO.bannerTitle)
                        .foregroundColor(Tokens.C.textPrimary)
                    Text(bannerSub)
                        .font(Tokens.CO.bannerSub)
                        .foregroundColor(Tokens.C.textSecondary)
                        .lineSpacing(Tokens.CO.bSubLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Tokens.CO.bSubTop)
                }
                Spacer(minLength: 0)
            }

            if isChecking {
                FaProgressBar().padding(.top, Tokens.CO.bActionsTop)
            } else {
                VStack(alignment: .leading, spacing: Tokens.CO.stepsGapA) {
                    FaStep(dir: .a, n: 1, leading: Self.step1)
                    FaStep(dir: .a, n: 2, leading: Self.step2)
                    FaStep(dir: .a, n: 3, leading: Self.step3lead,
                           accent: Self.step3accent, accentMono: true, trailing: ".")
                }
                .padding(.top, Tokens.CO.stepsTopA)

                HStack(spacing: Tokens.CO.bActionsGap) {
                    FaCtaSmall(title: "Открыть настройки", icon: "arrow.up.right.square",
                               size: .big, fill: .orange, action: onOpenSettings)
                    FaLinkBtn(title: "Проверить снова", orange: true, action: onRecheck)
                }
                .padding(.top, Tokens.CO.bActionsTop)
            }
        }
        .padding(.vertical, Tokens.CO.bannerPadV)
        .padding(.horizontal, Tokens.M.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.M.groupRadius, style: .continuous).fill(Tokens.CO.warnBg))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.M.groupRadius, style: .continuous)
                .stroke(Tokens.CO.warnBorder28, lineWidth: 1))
        .padding(.top, Tokens.M.heroTopGap)
        .padding(.horizontal, Tokens.M.cardInset)
        .padding(.bottom, Tokens.M.cardSpacing)
    }

    private var bannerSub: String {
        switch state {
        case .checking:    return "Проверяю доступ…"
        case .stillDenied: return "Доступа пока нет — проверь шаги и попробуй ещё раз."
        case .timeout:     return "Агент не ответил. Проверь, что он активен, и попробуй ещё раз."
        case .denied:      return "Фоновому агенту закрыт доступ к папке — книги не конвертируются."
        }
    }
}

// MARK: - Presentation: SETUP STEP (amber «ДОСТУП К ПАПКЕ» body)

extension FolderAccessCard {

    /// The BODY of an amber access step on Setup (SetupView owns the amber number
    /// bubble + wizard chrome). Display-only: the button hands off to Status, where
    /// the live blocker/banner + recheck live (mirrors the engine setup-step handoff).
    var setupStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            FaCapLabel(text: "ДОСТУП К ПАПКЕ")
            Text("Нет доступа к папке")
                .font(Tokens.F.stepTitle)
                .foregroundColor(Tokens.C.textPrimary)
                .padding(.top, Tokens.M.stepTitleTop)
            Text("Нужен для конвертации")
                .font(Tokens.F.stepOkSub)
                .foregroundColor(Tokens.C.accentOrange)
                .padding(.top, Tokens.M.stepOkSubTop)
            FaCtaSmall(title: "Открыть настройки", icon: "arrow.up.right.square",
                       size: .big, fill: .orange, action: onFixFromSetup)
                .padding(.top, 11)
        }
    }
}

// MARK: - Presentation: SETTINGS ROW (compact warn row)

extension FolderAccessCard {

    /// The warn Настройки row shown ONLY while denied (SettingsView keeps its own
    /// passive "Full Disk Access" row for ok/absent — byte-identical to today).
    var settingsRow: some View {
        HStack(spacing: Tokens.M.rowGap) {
            RoundedRectangle(cornerRadius: Tokens.M.rowIconRadius, style: .continuous)
                .fill(Tokens.C.tintOrange)
                .overlay(faIcon("lock.shield", size: 15, weight: .semibold)
                    .foregroundColor(Tokens.C.accentOrange))
                .frame(width: Tokens.M.rowIcon, height: Tokens.M.rowIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text("Нет доступа к папке")
                    .font(Tokens.F.rowLabel)
                    .foregroundColor(Tokens.C.accentOrange)
                Text("фоновому агенту закрыт доступ — конвертация стоит")
                    .font(Tokens.F.rowSub)
                    .foregroundColor(Tokens.C.textTertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            FaCtaSmall(title: "Исправить", size: .compact, fill: .brand, action: onOpenSettings)
        }
        .padding(.horizontal, Tokens.M.rowPadH)
        .padding(.vertical, Tokens.M.rowPadV)
        .background(
            RoundedRectangle(cornerRadius: Tokens.M.groupRadius, style: .continuous)
                .fill(Tokens.C.cardBg)
                .overlay(RoundedRectangle(cornerRadius: Tokens.M.groupRadius, style: .continuous)
                    .stroke(Tokens.C.cardBorder, lineWidth: 1)))
        .padding(.horizontal, Tokens.M.cardInset)
        .padding(.bottom, Tokens.M.cardSpacing)
    }
}
