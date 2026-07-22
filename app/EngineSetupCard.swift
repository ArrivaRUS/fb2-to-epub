// EngineSetupCard — the ONE onboarding component, rendered in four presentations
// (CAL-2 skeleton, read-only).
//
// Built strictly from design/calibre-onboarding/{design-spec.md,tokens.md,flow.md}
// and the accepted mockups (direction-A-banner.html / direction-B-blocker.html,
// gate G3 / decision D43). Every colour/size/inset comes from Tokens (C/M/F/G/CO)
// — nothing is eyeballed.
//
// One install state (flow.md §3/§6), four "подачи" (design-spec §1):
//   • .blocker     — Direction B: full-screen ring + title + CTA, replaces the
//                    Status content when there is NO conversion history.
//   • .banner      — Direction A: a warn/err/ok card under the header, Status
//                    content stays visible (there IS history).
//   • .setupStep   — the amber "ДВИЖОК" step body on the first-run Setup screen.
//   • .settingsRow — the compact stateful Calibre row in Настройки.
//
// CAL-2 is READ-ONLY: every button is drawn but its callback defaults to a no-op;
// the real pipeline (start/cancel/retry/site/recheck) is wired in CAL-4. The
// Phase enum here is DISPLAY-ONLY — the real InstallStore stitches in at CAL-4
// (this component never owns install logic, never spawns anything).

import SwiftUI
import AppKit

// MARK: - Local glyph helper (file-private; mirrors StatusView/SetupView)

private func sfIcon(_ name: String, size: CGFloat, weight: Font.Weight = .regular) -> some View {
    Image(systemName: name)
        .font(.system(size: size, weight: weight))
}

// MARK: - EngineSetupCard

struct EngineSetupCard: View {

    /// Display-only install phase (flow.md §6). The real InstallStore.phase maps
    /// onto this at CAL-4; here it is driven by FB2_FORCE_INSTALL_STATE for
    /// screenshots (see AppDelegate.parseForcedInstallState).
    enum Phase: Equatable {
        case notInstalled                          // empty / not-installed
        case downloading(done: Int, total: Int)    // Скачиваю Calibre… X из Y МБ · NN%
        case installing                            // Устанавливаю…
        case verifying                             // Проверяю движок…
        case success                               // Готово! Движок на месте
        case errorNetwork                          // Не удалось скачать (нет сети)
        case errorSpace                            // Мало места на диске (D41: «~1 ГБ»)
        case errorInstall                          // Не получилось установить
        case manual(osUnsupported: Bool)           // Установить вручную (osUnsupported → macOS<14, D42)
        case activationFailed                      // движок ЕСТЬ, агент не поднялся (≠ провал установки)
    }

    /// Which of the four surfaces to render this phase into.
    enum Presentation { case blocker, banner, setupStep, settingsRow }

    let phase: Phase
    let presentation: Presentation

    // Actions — DRAWN but inert in CAL-2 (defaults are no-ops). Wired at CAL-4.
    var onInstall: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}
    var onManual: () -> Void = {}
    var onOpenSite: () -> Void = {}
    var onRecheck: () -> Void = {}
    var onRetryAgent: () -> Void = {}

    var body: some View {
        switch presentation {
        case .blocker:     blocker
        case .banner:      banner
        case .setupStep:   setupStep
        case .settingsRow: settingsRow
        }
    }

    // MARK: - Shared content helpers

    /// "{done} из {total} МБ" — the mono progress label (content, not a token).
    private func mbLine(_ done: Int, _ total: Int) -> String { "\(done) из \(total) МБ" }
    /// Integer percent, rounded. total==0 → 0 (indeterminate handled separately).
    private func pct(_ done: Int, _ total: Int) -> Int {
        total > 0 ? Int((Double(done) / Double(total) * 100).rounded()) : 0
    }
}

// MARK: - InstallPhase → display Phase (CAL-4 bridge)

extension EngineSetupCard.Phase {
    /// Map the pipeline's `InstallPhase` (Foundation-only, owned by `InstallStore`)
    /// onto this display phase. `nil` means "not in flight" — the caller then falls
    /// back to engine presence (present → normal screen, missing → notInstalled /
    /// manual). Kept HERE (SwiftUI side) so CalibreInstaller.swift stays SwiftUI-free
    /// and the headless install tests don't drag AppKit in.
    ///
    /// Notes:
    ///   • `.precheck` shows as `.downloading(0,0)` — a sub-second "Скачиваю Calibre…"
    ///     while disk/OS are checked and the connection opens (real bytes fill in on
    ///     the first `didWriteData`).
    ///   • `.verifying` AND `.activating` (the atomic swap) BOTH read "Проверяю
    ///     движок…" — and the store also holds `.verifying` while installer.sh revives
    ///     the agent, so the label stays continuous through swap + activation.
    ///   • bytes → MB uses 1_000_000 (decimal), matching the mockup's "330 МБ".
    static func from(_ p: InstallPhase, autoInstallSupported: Bool) -> EngineSetupCard.Phase? {
        switch p {
        case .idle:
            return nil
        case .precheck:
            return .downloading(done: 0, total: 0)
        case .downloading(let got, let total):
            let mb: (Int64) -> Int = { Int(max(0, $0) / 1_000_000) }
            return .downloading(done: mb(got), total: mb(total))
        case .installing:
            return .installing
        case .verifying, .activating:
            return .verifying
        case .success:
            return .success
        case .error(let reason):
            switch reason {
            case .network: return .errorNetwork
            case .space:   return .errorSpace
            case .install: return .errorInstall
            }
        case .agentActivationFailed:
            return .activationFailed
        case .manual:
            return .manual(osUnsupported: !autoInstallSupported)
        }
    }
}

// MARK: - Reusable buttons (tokens-exact)

/// `.cta-sm` — the small brand button. Two sizes (design-spec §0 decision #3):
/// `.big` (9×15 / 12.5) in banner A + Setup; `.compact` (8×13 / 12) in Настройки
/// and Direction B. Two fills: brand `G.brand135` or `orange` `CO.retryOrangeGrad`.
private struct CtaSmall: View {
    enum Size { case big, compact }
    enum Fill { case brand, orange }
    let title: String
    var icon: String? = nil
    var size: Size = .big
    var fill: Fill = .brand
    let action: () -> Void

    var body: some View {
        HStack(spacing: Tokens.CO.ctaSmGap) {
            if let icon = icon {
                sfIcon(icon, size: size == .big ? 13 : 12, weight: .bold)
                    .foregroundColor(.white)
            }
            Text(title)
                .font(size == .big ? Tokens.CO.ctaSmFont : Tokens.CO.ctaSmFontSm)
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, size == .big ? Tokens.CO.ctaSmPadV : Tokens.CO.ctaSmPadVsm)
        .padding(.horizontal, size == .big ? Tokens.CO.ctaSmPadH : Tokens.CO.ctaSmPadHsm)
        .background(fillShape)
        .shadow(color: Tokens.CO.ctaSmShadowColor,
                radius: Tokens.CO.ctaSmShadowRadius, x: 0, y: Tokens.CO.ctaSmShadowY)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    @ViewBuilder private var fillShape: some View {
        switch fill {
        case .brand:
            RoundedRectangle(cornerRadius: Tokens.CO.ctaRadius, style: .continuous).fill(Tokens.G.brand135)
        case .orange:
            RoundedRectangle(cornerRadius: Tokens.CO.ctaRadius, style: .continuous).fill(Tokens.CO.retryOrangeGrad)
        }
    }
}

/// `.cta` — the big blocker button (Direction B). Brand or orange fill.
private struct CtaBig: View {
    enum Fill { case brand, orange }
    let title: String
    var icon: String? = nil
    var fill: Fill = .brand
    let action: () -> Void

    var body: some View {
        HStack(spacing: Tokens.CO.ctaGap) {
            if let icon = icon {
                sfIcon(icon, size: 16, weight: .bold).foregroundColor(.white)
            }
            Text(title).font(Tokens.CS.cta_).foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(Tokens.CO.ctaPad)
        .background(fillShape)
        .shadow(color: fill == .brand ? Tokens.CO.ctaShadowColor : Tokens.CO.ctaShadowOrangeColor,
                radius: Tokens.CO.ctaShadowRadius, x: 0, y: Tokens.CO.ctaShadowY)
        .padding(.top, Tokens.CO.ctaTop)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    @ViewBuilder private var fillShape: some View {
        switch fill {
        case .brand:
            RoundedRectangle(cornerRadius: Tokens.CO.ctaBigRadius, style: .continuous).fill(Tokens.G.brand135)
        case .orange:
            RoundedRectangle(cornerRadius: Tokens.CO.ctaBigRadius, style: .continuous).fill(Tokens.CO.retryOrangeGrad)
        }
    }
}

/// `.cta-ghost` — secondary "Проверить снова" (Direction B).
private struct CtaGhost: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    var body: some View {
        HStack(spacing: Tokens.CO.ctaGap) {
            if let icon = icon {
                sfIcon(icon, size: 15, weight: .regular).foregroundColor(Tokens.C.textSoft)
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
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// `.mini-btn` — the small "Отмена" pill in banner A.
private struct MiniBtn: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Text(title)
            .font(Tokens.CO.miniBtnFont)
            .foregroundColor(Tokens.C.textPrimary)
            .padding(.vertical, Tokens.CO.miniBtnPadV)
            .padding(.horizontal, Tokens.CO.miniBtnPadH)
            .background(
                RoundedRectangle(cornerRadius: Tokens.CO.miniBtnRadius, style: .continuous)
                    .fill(Tokens.C.btnBg))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.CO.miniBtnRadius, style: .continuous)
                    .stroke(Tokens.C.fieldBtnBorder, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// `.link-btn` — text-only secondary. 12px everywhere (design-spec §0 decision #5).
private struct LinkBtn: View {
    let title: String
    var orange: Bool = false
    let action: () -> Void
    var body: some View {
        Text(title)
            .font(Tokens.F.link)
            .foregroundColor(orange ? Tokens.C.accentOrange : Tokens.C.textSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

// MARK: - Download progress bar (.prog, shared A/B)

/// The 6px/r3 progress bar (≠ the 3px stat bars). Determinate (fraction) or
/// indeterminate (a 38%-wide chip sliding left↔right at 1.15s).
private struct ProgressBar: View {
    /// nil → indeterminate.
    var fraction: Double? = nil
    @State private var slide = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Tokens.CO.progRadius, style: .continuous)
                    .fill(Tokens.C.barTrack)
                RoundedRectangle(cornerRadius: Tokens.CO.progRadius, style: .continuous)
                    .fill(Tokens.G.barOrange)
                    .frame(width: fillWidth(w))
                    .offset(x: offsetX(w))
            }
        }
        .frame(height: Tokens.CO.progHeight)
        .onAppear {
            guard fraction == nil else { return }
            withAnimation(.easeInOut(duration: Tokens.CO.progIndetDur).repeatForever(autoreverses: true)) {
                slide = true
            }
        }
    }

    private func fillWidth(_ w: CGFloat) -> CGFloat {
        if let f = fraction { return max(0, min(1, CGFloat(f))) * w }
        return Tokens.CO.progIndetWidth * w
    }
    private func offsetX(_ w: CGFloat) -> CGFloat {
        guard fraction == nil else { return 0 }
        let travel = w * (1 - Tokens.CO.progIndetWidth)
        return slide ? travel : 0
    }
}

// MARK: - Blocker ring (Direction B)

/// The 104×104 status ring, in its five install states (tokens.md §3). Reuses the
/// Status ring geometry (r44 / stroke 8 / track white .07).
private struct BlockerRing: View {
    enum Style { case warn, progress(Double), installing, success, error(Double) }
    let style: Style
    @State private var spin = false

    var body: some View {
        ZStack {
            // Track — always present.
            Circle()
                .stroke(Tokens.C.barTrack, style: StrokeStyle(lineWidth: Tokens.M.ringStroke))

            arc
            center
        }
        .frame(width: Tokens.M.ringSize, height: Tokens.M.ringSize)
        .onAppear {
            if case .installing = style {
                withAnimation(.linear(duration: Tokens.CO.spinDur).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
        }
    }

    @ViewBuilder private var arc: some View {
        switch style {
        case .warn:
            // Dashed amber ring (dash "4 10", round cap).
            Circle()
                .stroke(Tokens.CO.ringWarnDash,
                        style: StrokeStyle(lineWidth: Tokens.M.ringStroke, lineCap: .round, dash: [4, 10]))
        case .progress(let f):
            // Линейный бренд-градиент вдоль дуги (ref B-2, rgB2) — НЕ угловой G.ring:
            // угловой давал шов magenta под round-cap'ом старта (урок 014) и «почти
            // всю дугу оранжевой». Линейный без шва → startCap не нужен.
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, f))))
                .stroke(Tokens.CO.ringProgressGrad, style: StrokeStyle(lineWidth: Tokens.M.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        case .installing:
            // A single 70/276 arc sweeping continuously (spinner).
            Circle()
                .trim(from: 0, to: 70 / Tokens.CO.ringCircumference)
                .stroke(Tokens.CO.ringInstallGrad,
                        style: StrokeStyle(lineWidth: Tokens.M.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
        case .success:
            Circle()
                .stroke(Tokens.C.emerald, style: StrokeStyle(lineWidth: Tokens.M.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Tokens.CO.ringSuccessGlowColor, radius: Tokens.CO.ringSuccessGlowRadius)
        case .error(let f):
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, f))))
                .stroke(Tokens.C.danger, style: StrokeStyle(lineWidth: Tokens.M.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    @ViewBuilder private var center: some View {
        switch style {
        case .warn:
            sfIcon("exclamationmark.triangle", size: Tokens.CO.ringIconWarn, weight: .regular)
                .foregroundColor(Tokens.C.accentOrange)
        case .progress(let f):
            Text("\(Int((f * 100).rounded()))%")
                .font(Tokens.CO.ringPct)
                .foregroundColor(Tokens.C.accentOrange)
                .monoDigitsCompat()
        case .installing:
            sfIcon("gearshape", size: Tokens.CO.ringIconGear, weight: .regular)
                .foregroundColor(Tokens.C.accentOrange)
                .rotationEffect(.degrees(spin ? 360 : 0))
        case .success:
            sfIcon("checkmark", size: Tokens.CO.ringIconCheck, weight: .bold)
                .foregroundColor(Tokens.C.emerald)
        case .error:
            sfIcon("xmark", size: Tokens.CO.ringIconError, weight: .bold)
                .foregroundColor(Tokens.C.danger)
        }
    }
}

// MARK: - Manual steps (numbered list)

/// A single numbered step. Style differs A vs B (design-spec §0 decision #4):
/// A → 18px grey badge; B → 20px amber badge. `text`/`mono` build the line.
private struct ManualStep: View {
    enum Direction { case a, b }
    let dir: Direction
    let n: Int
    let leading: String          // plain text before the accent (may be "")
    /// Bold accent word — «calibre-ebook.com» (mono) or «Calibre» (plain). The mockup
    /// bolds both (`<b>`); Юрка's decision: semibold. `accentMono` picks the treatment.
    var accent: String? = nil
    var accentMono: Bool = false // true → monospaced host (textPrimary); false → plain word (body colour)
    var trailing: String = ""    // plain text after the accent

    var body: some View {
        HStack(alignment: .top, spacing: dir == .a ? Tokens.CO.stepsGapA : Tokens.CO.stepsGapB) {
            badge
            line
                .fixedSize(horizontal: false, vertical: true)
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
            .overlay(dir == .b
                     ? Circle().stroke(Tokens.CO.warnBorder30, lineWidth: 1)
                     : nil)
            .padding(.top, 1)
    }

    private var line: some View {
        // Compose leading + (semibold accent) + trailing. The accent reads as in the
        // mockup: «calibre-ebook.com» → mono + textPrimary; «Calibre» → body font +
        // textSoft. Both semibold (heavier than the regular body run).
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

// MARK: - Small caps label (file-local; mirrors the shared .cap style)

private struct CapLabelCO: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Tokens.F.cap)
            .foregroundColor(Tokens.C.textTertiary)
            .trackingCompat(Tokens.Track.cap)
    }
}

// MARK: - Presentation: BANNER (Direction A)

extension EngineSetupCard {

    private enum BannerVariant { case warn, err, ok }

    private var bannerVariant: BannerVariant {
        switch phase {
        case .success:                                     return .ok
        case .errorNetwork, .errorSpace, .errorInstall:    return .err
        default:                                           return .warn
        }
    }

    private var bannerBg: Color {
        switch bannerVariant {
        case .warn: return Tokens.CO.warnBg
        case .err:  return Tokens.CO.dangerBg
        case .ok:   return Tokens.C.emeraldBg
        }
    }
    private var bannerBorder: Color {
        switch bannerVariant {
        case .warn: return Tokens.CO.warnBorder28
        case .err:  return Tokens.CO.dangerBorder
        case .ok:   return Tokens.C.emeraldBorder
        }
    }

    var banner: some View {
        VStack(alignment: .leading, spacing: 0) {
            bannerTop
            bannerBelow
        }
        .padding(.vertical, Tokens.CO.bannerPadV)
        .padding(.horizontal, Tokens.M.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.M.groupRadius, style: .continuous).fill(bannerBg))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.M.groupRadius, style: .continuous)
                .stroke(bannerBorder, lineWidth: 1))
        .padding(.top, Tokens.M.heroTopGap)          // margin-top 4
        .padding(.horizontal, Tokens.M.cardInset)    // margin 0 14
        .padding(.bottom, Tokens.M.cardSpacing)      // margin-bottom 12
    }

    // b-top: 28px icon chip + title/sub column.
    private var bannerTop: some View {
        HStack(alignment: .top, spacing: Tokens.CO.bTopGap) {
            RoundedRectangle(cornerRadius: Tokens.M.rowIconRadius, style: .continuous)
                .fill(bannerIconTint)
                .overlay(sfIcon(bannerIcon, size: bannerIconSize, weight: .regular)
                    .foregroundColor(bannerIconColor))
                .frame(width: Tokens.M.rowIcon, height: Tokens.M.rowIcon)
            VStack(alignment: .leading, spacing: 0) {
                Text(bannerTitle)
                    .font(Tokens.CO.bannerTitle)
                    .foregroundColor(bannerTitleColor)
                if let sub = bannerSub {
                    Text(sub)
                        .font(Tokens.CO.bannerSub)
                        .foregroundColor(Tokens.C.textSecondary)
                        .lineSpacing(Tokens.CO.bSubLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Tokens.CO.bSubTop)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // Below b-top: progress / steps / actions per phase.
    @ViewBuilder private var bannerBelow: some View {
        switch phase {
        case .notInstalled:
            bannerActions {
                CtaSmall(title: "Установить Calibre", icon: "arrow.down.to.line",
                         size: .big, fill: .brand, action: onInstall)
                LinkBtn(title: "Установить вручную", action: onManual)
            }
        case .downloading(let done, let total):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(mbLine(done, total))
                        .font(Tokens.F.conv).foregroundColor(Tokens.C.textSoft)
                    Spacer(minLength: 0)
                    Text("\(pct(done, total))%")
                        .font(Tokens.CO.progPct).foregroundColor(Tokens.C.textPrimary)
                        .monoDigitsCompat()
                }
                .padding(.bottom, Tokens.CO.progRowBottom)
                ProgressBar(fraction: total > 0 ? Double(done) / Double(total) : 0)
            }
            .padding(.top, Tokens.CO.bActionsTop)
            bannerActions { MiniBtn(title: "Отмена", action: onCancel) }
        case .installing, .verifying:
            ProgressBar(fraction: nil)
                .padding(.top, Tokens.CO.bActionsTop)
        case .success:
            EmptyView()
        case .errorNetwork, .errorSpace, .errorInstall:
            bannerActions {
                CtaSmall(title: "Повторить", icon: "arrow.clockwise",
                         size: .big, fill: .orange, action: onRetry)
                LinkBtn(title: "Установить вручную", action: onManual)
            }
        case .manual(let osUnsupported):
            if !osUnsupported {
                VStack(alignment: .leading, spacing: Tokens.CO.stepsGapA) {
                    ManualStep(dir: .a, n: 1, leading: "Открой сайт ", accent: "calibre-ebook.com",
                               accentMono: true, trailing: " и скачай Calibre для Mac.")
                    ManualStep(dir: .a, n: 2, leading: "Перетащи ", accent: "Calibre",
                               trailing: " в папку «Программы».")
                    ManualStep(dir: .a, n: 3, leading: "Вернись сюда — я сам подхвачу движок.")
                }
                .padding(.top, Tokens.CO.stepsTopA)
            }
            bannerActions {
                CtaSmall(title: "Открыть сайт Calibre", icon: "arrow.up.right.square",
                         size: .big, fill: .orange, action: onOpenSite)
                LinkBtn(title: "Проверить снова", orange: true, action: onRecheck)
            }
        case .activationFailed:
            bannerActions {
                CtaSmall(title: "Повторить запуск агента", icon: "arrow.clockwise",
                         size: .big, fill: .orange, action: onRetryAgent)
            }
        }
    }

    private func bannerActions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Tokens.CO.bActionsGap, content: content)
            .padding(.top, Tokens.CO.bActionsTop)
    }

    // Per-phase banner glyph + tint.
    private var bannerIcon: String {
        switch phase {
        case .notInstalled, .manual, .activationFailed: return "exclamationmark.triangle"
        case .downloading:                               return "arrow.down.to.line"
        case .installing, .verifying:                    return "arrow.clockwise"
        case .success:                                   return "checkmark"
        case .errorNetwork:                              return "wifi.slash"
        case .errorSpace, .errorInstall:                 return "xmark"
        }
    }
    private var bannerIconSize: CGFloat {
        bannerVariant == .ok ? Tokens.CO.bannerIconOk : Tokens.CO.bannerIcon
    }
    private var bannerIconTint: Color {
        switch bannerVariant {
        case .warn: return Tokens.C.stepCurBg
        case .err:  return Tokens.CO.dangerTint
        case .ok:   return Tokens.C.stepOkBg
        }
    }
    private var bannerIconColor: Color {
        switch bannerVariant {
        case .warn: return Tokens.C.accentOrange
        case .err:  return Tokens.C.danger
        case .ok:   return Tokens.C.emerald
        }
    }
    private var bannerTitleColor: Color {
        switch bannerVariant {
        case .warn: return Tokens.C.textPrimary
        case .err:  return Tokens.C.danger
        case .ok:   return Tokens.C.emerald
        }
    }

    private var bannerTitle: String {
        switch phase {
        case .notInstalled:    return "Нет движка конвертации"
        case .downloading:     return "Скачиваю Calibre…"
        case .installing:      return "Устанавливаю…"
        case .verifying:       return "Проверяю движок…"
        case .success:         return "Готово! Движок на месте"
        case .errorNetwork:    return "Не удалось скачать"
        case .errorSpace:      return "Мало места на диске"
        case .errorInstall:    return "Не получилось установить"
        case .manual:          return "Установить вручную"
        case .activationFailed: return "Движок есть, агент не запустился"
        }
    }

    private var bannerSub: String? {
        switch phase {
        case .notInstalled:
            return "Без него книги не превращаются в EPUB. Скачаю и поставлю сам — пара минут, ≈330 МБ."
        case .downloading:
            // D44: макет писался до D40; теперь закрытие окна безопасно (установка
            // живёт в Dock), поэтому текст честно об этом говорит.
            return "Окно можно закрыть — загрузка продолжится."
        case .installing:
            return "Распаковываю движок в приложение. Почти готово — пароль и подтверждения не нужны."
        case .verifying:
            return nil
        case .success:
            return "Агент заработал — уже берусь за книги в папке."
        case .errorNetwork:
            return "Похоже, нет интернета. Проверь соединение и попробуй снова."
        case .errorSpace:
            return "Нужно ~1 ГБ свободно — освободи место и попробуй снова."
        case .errorInstall:
            return "Попробуй ещё раз или поставь движок вручную."
        case .manual(let osUnsupported):
            return osUnsupported
                ? "Ваша версия macOS не поддерживает автоустановку — поставь совместимую версию с сайта."
                : "Если авто-установка не идёт — три коротких шага:"
        case .activationFailed:
            return "Движок на месте, но фоновый агент не поднялся. Попробуй запустить его снова."
        }
    }
}

// MARK: - Presentation: BLOCKER (Direction B)

extension EngineSetupCard {

    var blocker: some View {
        VStack(spacing: 0) {
            blockerContent
        }
        .frame(maxWidth: .infinity, minHeight: Tokens.CO.blockerMinH,
               alignment: blockerTopAligned ? .top : .center)
        .padding(.top, blockerTopAligned ? 20 : Tokens.CO.blockerPadTop)
        .padding(.horizontal, Tokens.CO.blockerPadH)
        .padding(.bottom, Tokens.CO.blockerPadBottom)
    }

    /// Manual is top-aligned (mockup: justify-content flex-start, padding-top 20).
    private var blockerTopAligned: Bool {
        if case .manual = phase { return true }
        return false
    }

    @ViewBuilder private var blockerContent: some View {
        switch phase {
        case .notInstalled:
            BlockerRing(style: .warn)
            blockerTitleView("Не хватает движка", color: Tokens.C.textPrimary)
            blockerBody {
                Text("Чтобы делать EPUB, нужен бесплатный движок ")
                    + Text("Calibre").foregroundColor(Tokens.C.textSoft)
                    + Text(". Скачаю и установлю сам — это займёт пару минут.")
            }
            blockerMb("≈330 МБ · бесплатно")
            CtaBig(title: "Установить Calibre", icon: "arrow.down.to.line",
                   fill: .brand, action: onInstall)
            LinkBtn(title: "Установить вручную", action: onManual)
                .padding(.top, Tokens.CO.linkBtnTopB)

        case .downloading(let done, let total):
            BlockerRing(style: .progress(total > 0 ? Double(done) / Double(total) : 0))
            blockerTitleView("Скачиваю Calibre…", color: Tokens.C.textPrimary)
            // D44: закрытие окна безопасно (D40) — текст обновлён под это.
            blockerBody { Text("Окно можно закрыть — загрузка продолжится. Осталось совсем немного.") }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(mbLine(done, total)).font(Tokens.F.conv).foregroundColor(Tokens.C.textSoft)
                    Spacer(minLength: 0)
                    Text("\(pct(done, total))%").font(Tokens.CO.progPct)
                        .foregroundColor(Tokens.C.textPrimary).monoDigitsCompat()
                }
                .padding(.bottom, Tokens.CO.progRowBottom)
                ProgressBar(fraction: total > 0 ? Double(done) / Double(total) : 0)
            }
            .padding(.top, Tokens.CO.stepsTopB)
            LinkBtn(title: "Отмена", orange: true, action: onCancel)
                .padding(.top, Tokens.CO.linkBtnTopB)

        case .installing:
            BlockerRing(style: .installing)
            blockerTitleView("Устанавливаю…", color: Tokens.C.textPrimary)
            blockerBody { Text("Распаковываю движок в приложение. Почти готово — пароль и подтверждения не нужны.") }

        case .verifying:
            BlockerRing(style: .installing)
            blockerTitleView("Проверяю движок…", color: Tokens.C.textPrimary)

        case .success:
            BlockerRing(style: .success)
            blockerTitleView("Готово! Движок на месте", color: Tokens.C.emerald)
            blockerBody { Text("Агент заработал — уже берусь за книги в папке. Сейчас открою обычный экран.") }

        case .errorNetwork, .errorSpace, .errorInstall:
            BlockerRing(style: .error(0.47))
            blockerTitleView(bannerTitle, color: Tokens.C.danger)
            blockerBody { Text(bannerSub ?? "") }
            CtaBig(title: "Повторить", icon: "arrow.clockwise", fill: .orange, action: onRetry)
            LinkBtn(title: "Установить вручную", action: onManual)
                .padding(.top, Tokens.CO.linkBtnTopB)

        case .manual(let osUnsupported):
            blockerTitleView("Установить вручную", color: Tokens.C.textPrimary, topGap: 0)
            blockerBody {
                Text(osUnsupported
                     ? "Ваша версия macOS не поддерживает автоустановку — поставь совместимую версию с сайта."
                     : "Если авто-установка не идёт — три коротких шага.")
            }
            VStack(alignment: .leading, spacing: Tokens.CO.stepsGapB) {
                ManualStep(dir: .b, n: 1, leading: "Открой сайт ", accent: "calibre-ebook.com",
                           accentMono: true, trailing: " и скачай Calibre для Mac.")
                ManualStep(dir: .b, n: 2, leading: "Перетащи ", accent: "Calibre",
                           trailing: " в папку «Программы».")
                ManualStep(dir: .b, n: 3, leading: "Вернись сюда — я сам подхвачу движок.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Tokens.CO.stepsTopB)
            CtaBig(title: "Открыть сайт Calibre", icon: "arrow.up.right.square",
                   fill: .orange, action: onOpenSite)
            CtaGhost(title: "Проверить снова", icon: "arrow.clockwise", action: onRecheck)

        case .activationFailed:
            BlockerRing(style: .warn)
            blockerTitleView("Движок есть, агент не запустился", color: Tokens.C.textPrimary)
            blockerBody { Text("Движок на месте, но фоновый агент не поднялся. Попробуй запустить его снова.") }
            CtaBig(title: "Повторить запуск агента", icon: "arrow.clockwise",
                   fill: .orange, action: onRetryAgent)
        }
    }

    private func blockerTitleView(_ text: String, color: Color, topGap: CGFloat = Tokens.CO.blTitleTop) -> some View {
        Text(text)
            .font(Tokens.CO.blockerTitle)
            .foregroundColor(color)
            .trackingCompat(Tokens.Track.welcomeH2)
            .multilineTextAlignment(.center)
            .padding(.top, topGap)
    }

    private func blockerBody<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(Tokens.F.welcomeSub)
            .foregroundColor(Tokens.C.textSecondary)
            .multilineTextAlignment(.center)
            .lineSpacing(Tokens.CO.blBodyLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Tokens.CO.blBodyMaxW)
            .padding(.top, Tokens.CO.blBodyTop)
    }

    private func blockerMb(_ text: String) -> some View {
        Text(text)
            .font(Tokens.CO.blMb)
            .foregroundColor(Tokens.C.textTertiary)
            .monoDigitsCompat()
            .padding(.top, Tokens.CO.blMbTop)
    }
}

// MARK: - Presentation: SETUP STEP (amber «ДВИЖОК» body)

extension EngineSetupCard {

    /// The BODY of the amber engine step on Setup (SetupView owns the amber
    /// number-bubble + wizard row chrome; this fills the right column). Only the
    /// not-installed state is depicted (Setup screen 8) — install progress lives
    /// on Status/Настройки, so other phases fall through to the same amber body.
    var setupStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            CapLabelCO(text: "ДВИЖОК")
            Text("Calibre не найден")
                .font(Tokens.F.stepTitle)
                .foregroundColor(Tokens.C.textPrimary)
                .padding(.top, Tokens.M.stepTitleTop)
            Text("Нужен для конвертации")
                .font(Tokens.F.stepOkSub)
                .foregroundColor(Tokens.C.accentOrange)
                .padding(.top, Tokens.M.stepOkSubTop)
            HStack(spacing: Tokens.CO.bActionsGap) {
                CtaSmall(title: "Установить Calibre", icon: "arrow.down.to.line",
                         size: .big, fill: .brand, action: onInstall)
                LinkBtn(title: "Вручную", action: onManual)
            }
            .padding(.top, 11)
        }
    }
}

// MARK: - Presentation: SETTINGS ROW (compact stateful Calibre row)

extension EngineSetupCard {

    /// The self-contained Настройки card for the "not installed / installing /
    /// error" states (installed keeps SettingsView's own info card). Chrome
    /// matches the sibling setting cards (cardBg + groupRadius + cardInset).
    var settingsRow: some View {
        HStack(spacing: Tokens.M.rowGap) {
            settingsIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(settingsLabel)
                    .font(Tokens.F.rowLabel)
                    .foregroundColor(settingsLabelColor)
                if let sub = settingsSub {
                    Text(sub)
                        .font(Tokens.F.rowSub)
                        .foregroundColor(Tokens.C.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if case .downloading(let done, let total) = phase {
                    ProgressBar(fraction: total > 0 ? Double(done) / Double(total) : 0)
                        .padding(.top, 5)
                } else if case .installing = phase {
                    ProgressBar(fraction: nil).padding(.top, 5)
                } else if case .verifying = phase {
                    ProgressBar(fraction: nil).padding(.top, 5)
                }
            }
            Spacer(minLength: 8)
            settingsAction
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

    @ViewBuilder private var settingsIcon: some View {
        switch phase {
        case .downloading, .installing, .verifying:
            EmptyView()   // no icon while working (mockup: label + thin progress)
        case .errorNetwork, .errorSpace, .errorInstall:
            settingsIconChip(tint: Tokens.CO.dangerTint, color: Tokens.C.danger, "xmark")
        case .activationFailed:
            settingsIconChip(tint: Tokens.C.tintOrange, color: Tokens.C.accentOrange, "exclamationmark.triangle")
        case .success:
            settingsIconChip(tint: Tokens.C.tintEmerald, color: Tokens.C.emerald, "checkmark")
        default:
            settingsIconChip(tint: Tokens.C.tintOrange, color: Tokens.C.accentOrange, "exclamationmark.triangle")
        }
    }

    private func settingsIconChip(tint: Color, color: Color, _ glyph: String) -> some View {
        RoundedRectangle(cornerRadius: Tokens.M.rowIconRadius, style: .continuous)
            .fill(tint)
            .overlay(sfIcon(glyph, size: 15, weight: .semibold).foregroundColor(color))
            .frame(width: Tokens.M.rowIcon, height: Tokens.M.rowIcon)
    }

    private var settingsLabel: String {
        switch phase {
        case .downloading(let done, let total): return "Скачиваю… \(pct(done, total))%"
        case .installing:                        return "Устанавливаю…"
        case .verifying:                         return "Проверяю движок…"
        case .errorNetwork, .errorSpace, .errorInstall: return "Не удалось установить"
        case .success:                           return "Готово! Движок на месте"
        case .activationFailed:                  return "Агент не запустился"
        default:                                 return "Calibre не найден"
        }
    }
    private var settingsLabelColor: Color {
        switch phase {
        case .errorNetwork, .errorSpace, .errorInstall: return Tokens.C.danger
        case .success:                                   return Tokens.C.emerald
        case .downloading, .installing, .verifying:      return Tokens.C.textPrimary
        default:                                         return Tokens.C.accentOrange
        }
    }
    private var settingsSub: String? {
        switch phase {
        case .downloading, .installing, .verifying: return nil
        // D44: короткая подача, как в релизе 0.9.8 — «движок конвертации» влезает
        // целиком, ничего не обрезается (хвост « · без него…» снят человеком).
        case .notInstalled, .manual:                return "движок конвертации"
        default:                                    return "движок конвертации"
        }
    }

    @ViewBuilder private var settingsAction: some View {
        switch phase {
        case .downloading:
            MiniBtn(title: "Отмена", action: onCancel)
        case .installing, .verifying:
            // S2 (flow.md §6): установка/проверка/активация — операция неделимая, отмены нет
            // (баннер/блокер уже так делают). Только скачивание отменяемо.
            EmptyView()
        case .errorNetwork, .errorSpace, .errorInstall:
            CtaSmall(title: "Повторить", size: .compact, fill: .orange, action: onRetry)
        case .activationFailed:
            CtaSmall(title: "Повторить", size: .compact, fill: .orange, action: onRetryAgent)
        case .success:
            EmptyView()
        default:
            CtaSmall(title: "Установить", size: .compact, fill: .brand, action: onInstall)
        }
    }
}
