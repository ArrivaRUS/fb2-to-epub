// Tokens — the single source of truth for the native UI's colors, type and
// metrics. Every value here is lifted verbatim from the design spec
// (design/spec-ui.md, derived from design/mockups/ui-native.html). Views must
// pull from Tokens, never hardcode hex/sizes inline — that keeps pixel-perfect
// (G3 / M7) a one-file diff.
//
// The app is unconditionally dark (utility app, D10): colors are fixed and do
// NOT follow the system appearance.

import SwiftUI

// MARK: - Color(hex:) helper

extension Color {
    /// Build a Color from "#RRGGBB" / "RRGGBB" / "#RRGGBBAA". Falls back to
    /// opaque magenta on a malformed string so a typo is loud, not silent.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&v) else {
            self = Color(.sRGB, red: 1, green: 0, blue: 1, opacity: 1)
            return
        }
        let r, g, b, a: Double
        switch s.count {
        case 6:
            r = Double((v & 0xFF0000) >> 16) / 255
            g = Double((v & 0x00FF00) >> 8) / 255
            b = Double(v & 0x0000FF) / 255
            a = 1
        case 8:
            r = Double((v & 0xFF000000) >> 24) / 255
            g = Double((v & 0x00FF0000) >> 16) / 255
            b = Double((v & 0x0000FF00) >> 8) / 255
            a = Double(v & 0x000000FF) / 255
        default:
            r = 1; g = 0; b = 1; a = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// White at a given opacity — the spec expresses most hairlines/surfaces as
    /// rgba(255,255,255,a).
    static func white(_ opacity: Double) -> Color { Color(.sRGB, white: 1, opacity: opacity) }
}

// MARK: - macOS-11 compatibility shims for Text modifiers

// The app targets macOS 11.0 (a hard invariant). `.tracking` (13+) and
// `.monospacedDigit` (12+) are newer; these shims apply them when available and
// no-op otherwise, so the design values are honored on modern macOS (where the
// screenshots are taken) without breaking the 11.0 build.
extension Text {
    @ViewBuilder
    func trackingCompat(_ value: CGFloat) -> some View {
        if #available(macOS 13.0, *) { self.tracking(value) } else { self }
    }

    @ViewBuilder
    func monoDigitsCompat() -> some View {
        if #available(macOS 12.0, *) { self.monospacedDigit() } else { self }
    }

    /// Both tracking (13+) and tabular digits (12+) in one shot — used by the
    /// hero metric where both are needed on the same Text.
    @ViewBuilder
    func trackingMonoCompat(_ value: CGFloat) -> some View {
        if #available(macOS 13.0, *) {
            self.tracking(value).monospacedDigit()
        } else if #available(macOS 12.0, *) {
            self.monospacedDigit()
        } else {
            self
        }
    }
}

enum Tokens {

    // MARK: - Colors (roles -> hex/rgba), from spec "Цвета"

    enum C {
        // Text
        static let textPrimary   = Color(hex: "#F4F1FA")
        static let textSecondary = Color(hex: "#9A8FB5")
        static let textTertiary  = Color(hex: "#7E748F") // muted / caps label
        static let textSoft      = Color(hex: "#C9BFE0")
        static let textVeryMute  = Color(hex: "#5C546B")

        // Surfaces
        static let cardBg        = Color(hex: "#16131F")
        static let inputBg       = Color(hex: "#0E0B16") // setup field
        static let cardBorder    = Color.white(0.06)
        static let hairline      = Color.white(0.05)
        static let windowBorder  = Color.white(0.07)

        // Brand accent (single orange — links / arrows / hover)
        static let accentOrange  = Color(hex: "#FF8A3D")
        static let magenta       = Color(hex: "#E63CC8")

        // Success / active (emerald)
        static let emerald       = Color(hex: "#34D399")
        static let emeraldDark   = Color(hex: "#1D9E75")
        static let emeraldBg     = Color(.sRGB, red: 52/255, green: 211/255, blue: 153/255, opacity: 0.12)
        static let emeraldBorder = Color(.sRGB, red: 52/255, green: 211/255, blue: 153/255, opacity: 0.25)

        // Stat-bar track
        static let barTrack      = Color.white(0.07)

        // Row-icon tints (accent .12), from mockup inline styles
        static let tintEmerald   = Color(.sRGB, red: 52/255,  green: 211/255, blue: 153/255, opacity: 0.12)
        static let tintOrange    = Color(.sRGB, red: 255/255, green: 138/255, blue: 61/255,  opacity: 0.12)
        static let tintMagenta   = Color(.sRGB, red: 230/255, green: 60/255,  blue: 200/255, opacity: 0.12)

        // Generic translucent button surface (footer .btn / icon-btn)
        static let btnBg         = Color.white(0.05)
        static let btnBorder     = Color.white(0.10)
        static let iconBtnBg     = Color.white(0.04)
        static let iconBtnBorder = Color.white(0.06)

        // Conversion-row separator (slightly lighter than hairline per mockup)
        static let convDivider   = Color.white(0.045)

        // Credit footer (spec "Кредит-подвал"): muted grey text + blue link.
        static let creditText    = Color(hex: "#6E647F")
        static let creditLink    = Color(hex: "#5B9DF9")

        // Setup screen (mockup ".step-num", ".field-input", ".field-btn").
        // step-num "ok": emerald tint .14 fill + .4 border (stronger than the
        // row tints, so the green checkmark reads on the wizard card).
        static let stepOkBg      = Color(.sRGB, red: 52/255, green: 211/255, blue: 153/255, opacity: 0.14)
        static let stepOkBorder  = Color(.sRGB, red: 52/255, green: 211/255, blue: 153/255, opacity: 0.40)
        // step-num "current": orange tint .14 fill + .4 border (unused in the
        // all-green Setup, kept for parity with the mockup's step states).
        static let stepCurBg     = Color(.sRGB, red: 255/255, green: 138/255, blue: 61/255, opacity: 0.14)
        static let stepCurBorder = Color(.sRGB, red: 255/255, green: 138/255, blue: 61/255, opacity: 0.40)
        // field-input: darker inputBg + a slightly stronger border than cards.
        static let fieldBorder   = Color.white(0.08)
        // field-btn: same translucent surface as the footer .btn.
        static let fieldBtnBg    = Color.white(0.05)
        static let fieldBtnBorder = Color.white(0.12)
    }

    // MARK: - Gradients (spec "Бренд-акцент" + stat bars)

    enum G {
        /// Brand accent 135°: #FFB23D 0% -> #FF6B2C 35% -> #FF3D5A 68% -> #E63CC8 100%.
        static let brand135 = LinearGradient(
            stops: [
                .init(color: Color(hex: "#FFB23D"), location: 0.00),
                .init(color: Color(hex: "#FF6B2C"), location: 0.35),
                .init(color: Color(hex: "#FF3D5A"), location: 0.68),
                .init(color: Color(hex: "#E63CC8"), location: 1.00),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )

        /// App icon: same stops, 145° (mockup uses 38/70 splits).
        static let appIcon = LinearGradient(
            stops: [
                .init(color: Color(hex: "#FFB23D"), location: 0.00),
                .init(color: Color(hex: "#FF6B2C"), location: 0.38),
                .init(color: Color(hex: "#FF3D5A"), location: 0.70),
                .init(color: Color(hex: "#E63CC8"), location: 1.00),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )

        /// Status ring, angular sweep of the brand stops (full circle).
        static let ring = AngularGradient(
            gradient: Gradient(stops: [
                .init(color: Color(hex: "#FFB23D"), location: 0.00),
                .init(color: Color(hex: "#FF6B2C"), location: 0.40),
                .init(color: Color(hex: "#FF3D5A"), location: 0.72),
                .init(color: Color(hex: "#E63CC8"), location: 1.00),
            ]),
            center: .center
        )

        // Stat bars
        static let barOrange = LinearGradient(
            colors: [Color(hex: "#FFB23D"), Color(hex: "#FF6B2C")],
            startPoint: .leading, endPoint: .trailing)
        static let barMagenta = LinearGradient(
            colors: [Color(hex: "#FF3D5A"), Color(hex: "#E63CC8")],
            startPoint: .leading, endPoint: .trailing)
        static let barEmerald = LinearGradient(
            colors: [Color(hex: "#1D9E75"), Color(hex: "#34D399")],
            startPoint: .leading, endPoint: .trailing)

        /// Count-badge: linear 135° #FF6B2C -> #E63CC8 (mockup .count-badge).
        static let countBadge = LinearGradient(
            colors: [Color(hex: "#FF6B2C"), Color(hex: "#E63CC8")],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Window canvas (spec "Окно")

    /// radial-gradient(120% 90% at 50% -10%, #42257E 0% -> #1A1422 38% -> #100C18 64% -> #08080C 100%).
    /// Approximated with a SwiftUI RadialGradient anchored above-center.
    static let canvas = RadialGradient(
        gradient: Gradient(stops: [
            .init(color: Color(hex: "#42257E"), location: 0.00),
            .init(color: Color(hex: "#1A1422"), location: 0.38),
            .init(color: Color(hex: "#100C18"), location: 0.64),
            .init(color: Color(hex: "#08080C"), location: 1.00),
        ]),
        center: UnitPoint(x: 0.5, y: -0.10),
        startRadius: 0,
        endRadius: 460 // ~120% of the 400px window across the diagonal
    )

    // MARK: - Typography (spec "Типографика"; SF Pro = system)

    enum F {
        static let h1        = Font.system(size: 17,   weight: .bold)      // header title
        static let headerSub = Font.system(size: 12,   weight: .regular)   // header subtitle
        static let cap       = Font.system(size: 9,    weight: .bold)      // caps label
        static let statVal   = Font.system(size: 21,   weight: .bold)      // stat value
        static let statSub   = Font.system(size: 9.5,  weight: .regular)
        static let heroMetric = Font.system(size: 24,  weight: .bold)      // hero number
        static let heroUnit  = Font.system(size: 13,   weight: .medium)    // hero unit
        static let rowLabel  = Font.system(size: 13,   weight: .regular)
        static let rowSub    = Font.system(size: 11,   weight: .regular)
        static let rowVal    = Font.system(size: 11,   weight: .regular)
        static let link      = Font.system(size: 12,   weight: .semibold)
        static let pill      = Font.system(size: 11,   weight: .bold)
        static let badge     = Font.system(size: 11,   weight: .semibold)
        static let countBadge = Font.system(size: 11,  weight: .bold)
        // design: .monospaced is available on macOS 11 (Font.monospaced() is 12+).
        static let conv      = Font.system(size: 11.5, weight: .regular, design: .monospaced)
        static let button    = Font.system(size: 12,   weight: .semibold)
        static let clearBtn  = Font.system(size: 9,    weight: .semibold)
        static let heroPath  = Font.system(size: 12,   weight: .regular, design: .monospaced)
        // Credit footer (spec "Кредит-подвал"): 11px; link is slightly heavier.
        static let credit     = Font.system(size: 11,  weight: .regular)
        static let creditLink = Font.system(size: 11,  weight: .semibold)

        // Setup screen (mockup ".welcome", ".step", ".field", ".footnote").
        static let welcomeH2  = Font.system(size: 19,   weight: .bold)      // .welcome h2
        static let welcomeSub = Font.system(size: 12.5, weight: .regular)   // .welcome p
        static let stepNum    = Font.system(size: 12,   weight: .bold)      // .step-num
        static let stepTitle  = Font.system(size: 14,   weight: .semibold)  // .step-title
        static let stepOkSub  = Font.system(size: 11.5, weight: .regular)   // .step-ok-sub
        static let fieldMono  = Font.system(size: 11.5, weight: .regular, design: .monospaced) // .field-input .mono
        static let fieldBtn   = Font.system(size: 12,   weight: .semibold)  // .field-btn
        static let footnote   = Font.system(size: 11,   weight: .regular)   // .footnote div
    }

    // MARK: - Letter spacing (tracking), spec table

    enum Track {
        static let h1: CGFloat  = -0.2
        static let cap: CGFloat = 1.2
        static let heroMetric: CGFloat = -0.4
        static let welcomeH2: CGFloat = -0.3 // .welcome h2 letter-spacing
    }

    // MARK: - Metrics: sizes / paddings / radii (spec "Размеры")

    enum M {
        static let windowWidth: CGFloat = 400
        static let windowRadius: CGFloat = 16

        // Header
        static let headerPadTop: CGFloat = 18
        static let headerPadH: CGFloat = 18
        static let headerPadBottom: CGFloat = 14
        static let headerGap: CGFloat = 12
        static let appIconSize: CGFloat = 40
        static let appIconRadius: CGFloat = 11
        static let iconBtnSize: CGFloat = 28
        static let iconBtnRadius: CGFloat = 8
        static let headerActionsGap: CGFloat = 6

        // Cards: shared horizontal inset
        static let cardInset: CGFloat = 14
        static let heroRadius: CGFloat = 16
        static let statRadius: CGFloat = 13
        static let groupRadius: CGFloat = 14
        static let detailsRadius: CGFloat = 14

        // Hero
        static let heroPad: CGFloat = 18
        static let heroRowGap: CGFloat = 18
        static let ringSize: CGFloat = 104
        static let ringStroke: CGFloat = 8
        static let ringPlay: CGFloat = 30

        // Stats
        static let statGap: CGFloat = 8
        static let statPadH: CGFloat = 11
        static let statPadTop: CGFloat = 11
        static let statPadBottom: CGFloat = 12
        static let barHeight: CGFloat = 3
        static let barRadius: CGFloat = 2

        // Group rows
        static let rowPadV: CGFloat = 12
        static let rowPadH: CGFloat = 14
        static let rowGap: CGFloat = 11
        static let rowIcon: CGFloat = 28
        static let rowIconRadius: CGFloat = 8
        static let countBadgeMin: CGFloat = 20
        static let countBadgeRadius: CGFloat = 10

        // Details list
        static let detailsPadTop: CGFloat = 13
        static let detailsPadH: CGFloat = 14
        static let detailsPadBottom: CGFloat = 6
        /// CSS grid columns: 118 / 14 / 1fr / auto, col-gap 8.
        static let convColSrc: CGFloat = 118
        static let convColArrow: CGFloat = 14
        static let convColGap: CGFloat = 8
        static let convRowPadV: CGFloat = 7

        // Footer
        static let footerPadV: CGFloat = 13
        static let footerPadH: CGFloat = 16
        static let footerGap: CGFloat = 10
        static let footDot: CGFloat = 7
        static let btnPadV: CGFloat = 7
        static let btnPadH: CGFloat = 13
        static let btnRadius: CGFloat = 9
        static let btnIconSize: CGFloat = 32

        // Vertical rhythm between stacked cards (mockup margin-bottom: 12)
        static let cardSpacing: CGFloat = 12
        static let heroTopGap: CGFloat = 4 // .hero margin-top: 4

        // Credit footer (mockup .credit: padding 9 16 13)
        static let creditPadTop: CGFloat = 9
        static let creditPadH: CGFloat = 16
        static let creditPadBottom: CGFloat = 13

        // --- Setup screen (mockup .welcome / .wizard / .step / .field / .footnote) ---
        // .welcome { padding: 14 28 4 }  +  p { margin-top: 6, line-height: 1.45 }
        static let welcomePadTop: CGFloat = 14
        static let welcomePadH: CGFloat = 28
        static let welcomePadBottom: CGFloat = 4
        static let welcomeSubGap: CGFloat = 6
        static let welcomeLineSpacing: CGFloat = 12.5 * 0.45 // 12.5px * (1.45 - 1)
        // .wizard { margin: 18 14 12; border-radius: 16; padding: 6 0 }
        static let wizardMarginTop: CGFloat = 18
        static let wizardMarginH: CGFloat = 14
        static let wizardMarginBottom: CGFloat = 12
        static let wizardRadius: CGFloat = 16
        static let wizardPadV: CGFloat = 6
        // .step { gap: 12; padding: 15 16 }  +  .step-num { 26x26 }
        static let stepGap: CGFloat = 12
        static let stepPadV: CGFloat = 15
        static let stepPadH: CGFloat = 16
        static let stepNumSize: CGFloat = 26
        static let stepTitleTop: CGFloat = 3   // .step-title { margin-top: 3 }
        static let stepOkSubTop: CGFloat = 2   // .step-ok-sub { margin-top: 2 }
        static let stepHairlineH: CGFloat = 16 // .hairline { margin: 0 16 }
        // .field { gap: 8; margin-top: 9 }
        static let fieldGap: CGFloat = 8
        static let fieldTop: CGFloat = 9
        // .field-input { padding: 9 11; radius: 10; gap: 7 }
        static let fieldInputPadV: CGFloat = 9
        static let fieldInputPadH: CGFloat = 11
        static let fieldInputRadius: CGFloat = 10
        static let fieldInputGap: CGFloat = 7
        // .field-btn { padding: 9 13; radius: 10 }
        static let fieldBtnPadV: CGFloat = 9
        static let fieldBtnPadH: CGFloat = 13
        static let fieldBtnRadius: CGFloat = 10
        // .footnote { gap: 8; padding: 10 20 20 }  +  line-height 1.45
        static let footnoteGap: CGFloat = 8
        static let footnotePadTop: CGFloat = 10
        static let footnotePadH: CGFloat = 20
        static let footnotePadBottom: CGFloat = 20
        static let footnoteLineSpacing: CGFloat = 11 * 0.45 // 11px * (1.45 - 1)
    }

    // MARK: - Cover-select screen (mockup cover-select.html; spec "Cover-select")

    /// All values lifted verbatim from design/mockups/cover-select.html. Kept in
    /// one namespace so the "Выбор обложки" screen is a one-file pixel diff.
    enum CS {

        // --- Colors / gradients ---
        // Brand select-ring: 135° #FFB23D -> #FF6B2C -> #FF3D5A -> #E63CC8 (mockup .cs-sel-ring).
        static let selRing = LinearGradient(
            colors: [Color(hex: "#FFB23D"), Color(hex: "#FF6B2C"),
                     Color(hex: "#FF3D5A"), Color(hex: "#E63CC8")],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        // CTA: 135° #FFB23D 0% -> #FF6B2C 35% -> #FF3D5A 68% -> #E63CC8 100% (mockup .cs-cta).
        static let cta = LinearGradient(
            stops: [
                .init(color: Color(hex: "#FFB23D"), location: 0.00),
                .init(color: Color(hex: "#FF6B2C"), location: 0.35),
                .init(color: Color(hex: "#FF3D5A"), location: 0.68),
                .init(color: Color(hex: "#E63CC8"), location: 1.00),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        // Emerald check-circle: 135° #34D399 -> #1D9E75 (mockup .cs-check).
        static let checkCircle = LinearGradient(
            colors: [Color(hex: "#34D399"), Color(hex: "#1D9E75")],
            startPoint: .topLeading, endPoint: .bottomTrailing)

        // Counter chip (.cs-counter): cur #F4F1FA, sep #5C546B, tot #9A8FB5.
        static let counterBg     = Color.white(0.04)
        static let counterBorder = Color.white(0.07)
        // Candidate cover border (.cs-cover) + placeholder text.
        static let coverBorder   = Color.white(0.06)
        static let coverTitle    = Color.white(1.0)
        static let coverAuthor   = Color.white(0.82)
        // Non-selected hover frame (.cs-frame) — rendered subtly at rest.
        static let frame         = Color.white(0.22)
        // Check-circle stroke ring matches the card surface (.cs-check border #16131F).
        static let checkStroke   = Color(hex: "#16131F")
        // Action links (.cs-link): muted text + faint border.
        static let linkText      = Color(hex: "#9A8FB5")
        static let linkBorder    = Color.white(0.07)

        // --- Fonts (mockup px -> system) ---
        static let counterCur   = Font.system(size: 13,   weight: .bold)      // .cs-cur
        static let counterSep   = Font.system(size: 12,   weight: .semibold)  // .cs-sep
        static let counterTot   = Font.system(size: 12,   weight: .semibold)  // .cs-tot
        static let bookTitle    = Font.system(size: 15,   weight: .bold)      // .cs-book-title
        static let bookAuthor   = Font.system(size: 15,   weight: .medium)    // .cs-author
        static let bookFile     = Font.system(size: 11.5, weight: .regular, design: .monospaced) // .cs-book-file .mono
        static let bookNote     = Font.system(size: 11,   weight: .regular)   // .cs-book-note
        static let coverTitleF  = Font.system(size: 10,   weight: .bold)      // .cs-cover-title
        static let coverAuthorF = Font.system(size: 7.5,  weight: .semibold)  // .cs-cover-author
        static let srcHost      = Font.system(size: 10,   weight: .regular)   // .cs-host
        static let autoBadge    = Font.system(size: 8.5,  weight: .bold)      // .cs-auto b
        static let cta_         = Font.system(size: 15,   weight: .bold)      // .cs-cta
        static let link         = Font.system(size: 12,   weight: .semibold)  // .cs-link

        // --- Metrics ---
        // Counter chip (.cs-counter { padding: 5 10; radius: 9 }).
        static let counterPadV: CGFloat = 5
        static let counterPadH: CGFloat = 10
        static let counterRadius: CGFloat = 9
        // Book card (.cs-book { margin: 2 14 12; padding: 14 15; radius: 14 }).
        static let bookMarginTop: CGFloat = 2
        static let bookMarginH: CGFloat = 14
        static let bookMarginBottom: CGFloat = 12
        static let bookPadV: CGFloat = 14
        static let bookPadH: CGFloat = 15
        static let bookRadius: CGFloat = 14
        static let bookFileTop: CGFloat = 8     // .cs-book-file margin-top
        static let bookNoteTop: CGFloat = 9     // .cs-book-note margin-top
        static let bookFileGap: CGFloat = 6
        static let bookNoteGap: CGFloat = 6
        // Section caption (.cs-sec-cap { padding: 0 18; margin-bottom: 9 }).
        static let secCapPadH: CGFloat = 18
        static let secCapBottom: CGFloat = 9
        // Candidate grid (.cs-grid { 3 cols; gap 13; padding: 0 16; margin-bottom 14 }).
        static let gridPadH: CGFloat = 16
        static let gridGap: CGFloat = 13
        static let gridBottom: CGFloat = 14
        // Cover (.cs-cover { aspect 2/3; radius 9; padding 9 8 }).
        static let coverRadius: CGFloat = 9
        static let coverAspectW: CGFloat = 2
        static let coverAspectH: CGFloat = 3
        static let coverPadV: CGFloat = 9
        static let coverPadH: CGFloat = 8
        static let coverSpineW: CGFloat = 6     // .cs-cover::before width (spine highlight)
        static let coverAuthorTop: CGFloat = 3
        // Select ring / hover frame (inset -3, radius 12, 2px ring) (.cs-sel-ring/.cs-frame).
        static let ringInset: CGFloat = -3
        static let ringRadius: CGFloat = 12
        static let ringWidth: CGFloat = 2       // .cs-sel-ring padding
        static let frameWidth: CGFloat = 1.5    // .cs-frame border
        // Check circle (.cs-check { 22x22; top/right -7; border 2 }).
        static let checkSize: CGFloat = 22
        static let checkOffset: CGFloat = 7
        static let checkBorder: CGFloat = 2
        // Source block (.cs-src { margin-top 9 } + .cs-auto { margin-top 4; padding 2 7; radius 6 }).
        static let srcTop: CGFloat = 9
        static let autoTop: CGFloat = 4
        static let autoPadV: CGFloat = 2
        static let autoPadH: CGFloat = 7
        static let autoRadius: CGFloat = 6
        static let autoDot: CGFloat = 4
        static let autoGap: CGFloat = 4
        // Actions (.cs-actions { padding 4 14 16 }; .cs-cta { padding 14; radius 13 }).
        static let actionsPadTop: CGFloat = 4
        static let actionsPadH: CGFloat = 14
        static let actionsPadBottom: CGFloat = 16
        static let ctaPad: CGFloat = 14
        static let ctaRadius: CGFloat = 13
        static let ctaGap: CGFloat = 8
        // Link row (.cs-links { gap 8; margin-top 12 }; .cs-link { padding 9 8; radius 10 }).
        static let linksGap: CGFloat = 8
        static let linksTop: CGFloat = 12
        static let linkPadV: CGFloat = 9
        static let linkPadH: CGFloat = 8
        static let linkRadius: CGFloat = 10
        static let linkGap: CGFloat = 6
    }

    // MARK: - Project constants (credit footer)

    enum Project {
        static let githubURL = "https://github.com/ArrivaRUS/fb2-to-epub"
        /// Fallback when CFBundleShortVersionString is unreadable (matches the mockup).
        static let fallbackVersion = "0.2.0"
        /// Marketing version straight from the bundle (spec: from CFBundleShortVersionString).
        static var version: String {
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? fallbackVersion
        }
    }
}
