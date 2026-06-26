// CoverSelectView — the "Выбор обложки" screen (M5).
//
// Renders the real cover-selection queue the watcher produced:
//   ~/Library/Application Support/fb2-to-epub/covers/queue/<book_id>.json
//   ~/Library/Application Support/fb2-to-epub/covers/previews/<book_id>/<rank>.jpg
//
// The screen is pixel-mapped from design/mockups/cover-select.html via the design
// spec (design/spec-ui.md, "Cover-select"). Every metric/color comes from Tokens;
// the few cover-select-only values (counter chip, book card, candidate grid,
// select ring, action links) are added to Tokens.swift under the CS namespace.
//
// Read-only w.r.t. the engine: this view ONLY reads the queue + previews. The
// user's choice is written as an apply-job by EngineClient (covers/jobs/), and
// the EPUB is rewritten exclusively by the agent under its Full Disk Access
// (synthesis-ui.md D13). The app never touches the EPUB.
//
// Helpers (StrokeIcon / CSIcons / csCard) are file-private duplicates of the
// StatusView/SetupView pattern: those are `private` and not shared across files,
// so each screen carries its own small icon+card kit (keeps pixel-perfect a
// one-file diff).

import SwiftUI

// MARK: - Wire model (matches covers/queue/<book_id>.json exactly)

/// One cover candidate the finder produced, with a local preview on disk.
/// Schema (arch/plans-ui.md, cover-finder --json):
///   { id, rank, source, url, preview_path, score }
struct CoverCandidate: Codable, Identifiable, Equatable {
    let id: String          // e.g. "<book_id>-1"
    let rank: Int
    let source: String      // e.g. "Open Library", "labirint.ru"
    let url: String
    let previewPath: String // absolute path to the local .jpg preview
    let score: Double

    enum CodingKeys: String, CodingKey {
        case id, rank, source, url
        case previewPath = "preview_path"
        case score
    }

    /// Tolerant decode: a partial entry (missing score / rank) degrades rather
    /// than dropping the whole queue. id + preview_path are the load-bearing keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        rank        = (try? c.decode(Int.self, forKey: .rank)) ?? 0
        source      = (try? c.decode(String.self, forKey: .source)) ?? ""
        url         = (try? c.decode(String.self, forKey: .url)) ?? ""
        previewPath = (try? c.decode(String.self, forKey: .previewPath)) ?? ""
        score       = (try? c.decode(Double.self, forKey: .score)) ?? 0
    }

    init(id: String, rank: Int, source: String, url: String, previewPath: String, score: Double) {
        self.id = id; self.rank = rank; self.source = source
        self.url = url; self.previewPath = previewPath; self.score = score
    }

    /// "Open Library" / "labirint.ru" — the host label shown under the cover.
    /// Already a clean label from the finder; trimmed for safety.
    var hostLabel: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// One queued book awaiting a cover decision.
/// Schema (arch/plans-ui.md):
///   { book_id, epub_path, title, author, src_file, status, candidates[],
///     best_candidate_id, ts }
struct CoverQueueEntry: Codable, Identifiable, Equatable {
    let bookId: String
    let epubPath: String
    let title: String?
    let author: String?
    let srcFile: String?
    let status: String          // pending | apply_requested | resolved | skipped | failed
    let candidates: [CoverCandidate]
    let bestCandidateId: String?
    let ts: String?

    var id: String { bookId }

    enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case epubPath = "epub_path"
        case title, author
        case srcFile = "src_file"
        case status, candidates
        case bestCandidateId = "best_candidate_id"
        case ts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookId          = (try? c.decode(String.self, forKey: .bookId)) ?? ""
        epubPath        = (try? c.decode(String.self, forKey: .epubPath)) ?? ""
        title           = try? c.decodeIfPresent(String.self, forKey: .title)
        author          = try? c.decodeIfPresent(String.self, forKey: .author)
        srcFile         = try? c.decodeIfPresent(String.self, forKey: .srcFile)
        status          = (try? c.decode(String.self, forKey: .status)) ?? "pending"
        candidates      = (try? c.decode([CoverCandidate].self, forKey: .candidates)) ?? []
        bestCandidateId = try? c.decodeIfPresent(String.self, forKey: .bestCandidateId)
        ts              = try? c.decodeIfPresent(String.self, forKey: .ts)
    }

    init(bookId: String, epubPath: String, title: String?, author: String?,
         srcFile: String?, status: String, candidates: [CoverCandidate],
         bestCandidateId: String?, ts: String?) {
        self.bookId = bookId; self.epubPath = epubPath; self.title = title
        self.author = author; self.srcFile = srcFile; self.status = status
        self.candidates = candidates; self.bestCandidateId = bestCandidateId; self.ts = ts
    }

    var isPending: Bool { status == "pending" }

    /// Basename of the source file ("война-и-мир.fb2") for the book card.
    var srcBasename: String? {
        guard let s = srcFile, !s.isEmpty else { return nil }
        return (s as NSString).lastPathComponent
    }
}

// MARK: - Loader

/// Reads the cover queue from the engine's Application Support dir. All paths
/// derive from `home`, so tests can point this at a throwaway HOME and never
/// touch the real queue. The watcher OWNS these files; the app only reads them.
struct CoverQueueStore {
    let home: String

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    /// `~/Library/Application Support/fb2-to-epub/covers`
    var coversDir: String {
        if let override = ProcessInfo.processInfo.environment["FB2_COVERS_DIR"], !override.isEmpty {
            return override
        }
        return "\(home)/Library/Application Support/fb2-to-epub/covers"
    }

    var queueDir: String { "\(coversDir)/queue" }

    /// Count of pending queue entries — the number shown on the Status row badge.
    /// Counts files whose decoded status == "pending"; malformed files are skipped.
    func pendingCount() -> Int {
        loadPending().count
    }

    /// Load all pending queue entries, newest-first by ts (stable on missing ts).
    /// Any unreadable / malformed file is skipped so one bad entry never blanks
    /// the whole screen.
    func loadPending() -> [CoverQueueEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: queueDir) else { return [] }
        var entries: [CoverQueueEntry] = []
        for name in names where name.hasSuffix(".json") && !name.hasSuffix(".tmp") {
            let path = "\(queueDir)/\(name)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let entry = try? JSONDecoder().decode(CoverQueueEntry.self, from: data),
                  entry.isPending else { continue }
            entries.append(entry)
        }
        // Newest first; entries without ts sort last but keep a stable order.
        entries.sort { ($0.ts ?? "") > ($1.ts ?? "") }
        return entries
    }
}

// MARK: - File-private icon + card kit (mirrors StatusView/SetupView)

/// Stroke icon drawn in a 0...24 design box (same contract as StatusView).
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

/// Path builders — coordinates lifted from cover-select.html's SVG `d` attrs.
private enum CSIcons {
    // back chevron-left (.cs-icon-btn): M15 6l-6 6 6 6
    static func back(_ p: inout Path) {
        p.move(to: .init(x: 15, y: 6))
        p.addLine(to: .init(x: 9, y: 12))
        p.addLine(to: .init(x: 15, y: 18))
    }
    // document (.cs-book-file): M13 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V9z + M13 2v7h7
    static func doc(_ p: inout Path) {
        p.move(to: .init(x: 13, y: 2))
        p.addLine(to: .init(x: 4, y: 2))
        p.addLine(to: .init(x: 4, y: 22))
        p.addLine(to: .init(x: 20, y: 22))
        p.addLine(to: .init(x: 20, y: 9))
        p.closeSubpath()
        p.move(to: .init(x: 13, y: 2))
        p.addLine(to: .init(x: 13, y: 9))
        p.addLine(to: .init(x: 20, y: 9))
    }
    // info circle (.cs-book-note): circle r9 + dot + stem (M12 8v.01M12 11v5)
    static func info(_ p: inout Path) {
        p.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
        // dot
        p.move(to: .init(x: 12, y: 8))
        p.addLine(to: .init(x: 12, y: 8.01))
        // stem
        p.move(to: .init(x: 12, y: 11))
        p.addLine(to: .init(x: 12, y: 16))
    }
    // checkmark (.cs-check / .cs-cta): M5 13l4 4L19 7
    static func check(_ p: inout Path) {
        p.move(to: .init(x: 5, y: 13))
        p.addLine(to: .init(x: 9, y: 17))
        p.addLine(to: .init(x: 19, y: 7))
    }
    // lightning bolt (.cs-link "Оставить авто-выбор"): M13 2L3 14h7l-1 8 10-12h-7z
    static func bolt(_ p: inout Path) {
        p.move(to: .init(x: 13, y: 2))
        p.addLine(to: .init(x: 3, y: 14))
        p.addLine(to: .init(x: 10, y: 14))
        p.addLine(to: .init(x: 9, y: 22))
        p.addLine(to: .init(x: 19, y: 10))
        p.addLine(to: .init(x: 12, y: 10))
        p.closeSubpath()
    }
    // arrow right (.cs-skip): M5 12h14M13 6l6 6-6 6
    static func arrowRight(_ p: inout Path) {
        p.move(to: .init(x: 5, y: 12)); p.addLine(to: .init(x: 19, y: 12))
        p.move(to: .init(x: 13, y: 6)); p.addLine(to: .init(x: 19, y: 12)); p.addLine(to: .init(x: 13, y: 18))
    }
}

/// Card surface (fill + 1px border) — same as StatusView's `card`.
private func csCard(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(Tokens.C.cardBg)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Tokens.C.cardBorder, lineWidth: 1)
        )
}

// MARK: - Cover art (real preview, or a branded placeholder)

/// One candidate's 2:3 cover. Loads the local preview from `previewPath`; when
/// the file is missing/unreadable it falls back to a gradient placeholder that
/// echoes the mockup (title + author over a deterministic gradient + spine
/// highlight), so the grid never shows an empty box.
private struct CoverArt: View {
    let candidate: CoverCandidate
    let title: String?
    let author: String?

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if let img = loadImage() {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // Spine highlight on the left edge (mockup .cs-cover::before).
            .overlay(spine, alignment: .leading)
        }
        .aspectRatio(Tokens.CS.coverAspectW / Tokens.CS.coverAspectH, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.CS.coverRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.CS.coverRadius, style: .continuous)
                .stroke(Tokens.CS.coverBorder, lineWidth: 1)
        )
    }

    private func loadImage() -> NSImage? {
        guard !candidate.previewPath.isEmpty,
              FileManager.default.fileExists(atPath: candidate.previewPath) else { return nil }
        return NSImage(contentsOfFile: candidate.previewPath)
    }

    /// Deterministic gradient placeholder keyed off the candidate id, with the
    /// book title/author overlaid (matches the mockup's placeholder covers).
    private var placeholder: some View {
        ZStack(alignment: .bottomLeading) {
            placeholderGradient
            VStack(alignment: .leading, spacing: Tokens.CS.coverAuthorTop) {
                Text(title ?? "")
                    .font(Tokens.CS.coverTitleF)
                    .foregroundColor(Tokens.CS.coverTitle)
                    .lineLimit(3)
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                if let a = author, !a.isEmpty {
                    Text(a)
                        .font(Tokens.CS.coverAuthorF)
                        .foregroundColor(Tokens.CS.coverAuthor)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                }
            }
            .padding(.horizontal, Tokens.CS.coverPadH)
            .padding(.vertical, Tokens.CS.coverPadV)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var placeholderGradient: LinearGradient {
        // Pick one of three deep covers by a stable hash of the id (mockup used
        // indigo / wine / teal). Deterministic so re-renders don't flicker.
        let palettes: [[String]] = [
            ["#3A2E6E", "#241C44", "#15102A"],
            ["#6E2A3A", "#8A2F2F", "#3A1620"],
            ["#1D6E5A", "#15584C", "#0C2E2A"],
        ]
        let idx = abs(candidate.id.hashValue) % palettes.count
        let p = palettes[idx]
        return LinearGradient(
            colors: p.map { Color(hex: $0) },
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var spine: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.32), Color.white(0.08), Color.black.opacity(0)],
            startPoint: .leading, endPoint: .trailing)
            .frame(width: Tokens.CS.coverSpineW)
    }
}

// MARK: - Candidate cell

/// One grid cell: the cover, the selection ring (when selected) + emerald check,
/// the "АВТО" badge (when this is the best/auto candidate), and the source host.
private struct CandidateCell: View {
    let candidate: CoverCandidate
    let title: String?
    let author: String?
    let isSelected: Bool
    let isAuto: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CoverArt(candidate: candidate, title: title, author: author)
                // Selected -> brand gradient ring (mask cut-out via padded fill).
                if isSelected {
                    selectionRing
                    checkBadge
                } else {
                    // Resting subtle frame for non-selected (mockup hover; shown
                    // faintly at rest so the grid reads as pickable).
                    RoundedRectangle(cornerRadius: Tokens.CS.ringRadius, style: .continuous)
                        .stroke(Tokens.CS.frame.opacity(0.0), lineWidth: Tokens.CS.frameWidth)
                        .padding(Tokens.CS.ringInset)
                }
            }
            source
                .padding(.top, Tokens.CS.srcTop)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    /// Brand-gradient ring around the cover (mockup .cs-sel-ring): a rounded rect
    /// stroked with the brand gradient, inset by -3 so it hugs the cover.
    private var selectionRing: some View {
        RoundedRectangle(cornerRadius: Tokens.CS.ringRadius, style: .continuous)
            .strokeBorder(Tokens.CS.selRing, lineWidth: Tokens.CS.ringWidth)
            .padding(Tokens.CS.ringInset)
            .shadow(color: Color(.sRGB, red: 1, green: 61/255, blue: 90/255, opacity: 0.5),
                    radius: 9, x: 0, y: 0)
    }

    /// Emerald check circle in the top-right corner of the selected cover.
    private var checkBadge: some View {
        Circle()
            .fill(Tokens.CS.checkCircle)
            .overlay(
                StrokeIcon(size: 11, lineWidth: 3.4, build: CSIcons.check)
                    .foregroundColor(.white))
            .overlay(Circle().stroke(Tokens.CS.checkStroke, lineWidth: Tokens.CS.checkBorder))
            .frame(width: Tokens.CS.checkSize, height: Tokens.CS.checkSize)
            .shadow(color: Tokens.C.emerald.opacity(0.6), radius: 4, x: 0, y: 2)
            .offset(x: Tokens.CS.checkOffset, y: -Tokens.CS.checkOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(Tokens.CS.ringInset)
    }

    private var source: some View {
        VStack(spacing: 0) {
            Text(candidate.hostLabel)
                .font(Tokens.CS.srcHost)
                .foregroundColor(Tokens.C.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
            if isAuto {
                HStack(spacing: Tokens.CS.autoGap) {
                    Circle()
                        .fill(Tokens.C.emerald)
                        .frame(width: Tokens.CS.autoDot, height: Tokens.CS.autoDot)
                        .shadow(color: Tokens.C.emerald, radius: 2.5)
                    Text("АВТО")
                        .font(Tokens.CS.autoBadge)
                        .foregroundColor(Tokens.C.emerald)
                        .trackingCompat(0.8)
                }
                .padding(.horizontal, Tokens.CS.autoPadH)
                .padding(.vertical, Tokens.CS.autoPadV)
                .background(Capsule().fill(Tokens.C.emeraldBg))
                .overlay(Capsule().stroke(Tokens.C.emeraldBorder, lineWidth: 1))
                .padding(.top, Tokens.CS.autoTop)
            }
        }
    }
}

// MARK: - CoverSelectView

/// The "Выбор обложки" screen. Renders ONE pending queue entry (the first), lets
/// the user re-pick among candidates, and reports the decision via callbacks.
/// The host (main.swift) wires:
///   onApply(candidateId) -> EngineClient.requestCover(...)  (writes apply-job)
///   onSkip()             -> EngineClient.requestCover(..., skip)
///   onBack()             -> pop back to the Status screen
struct CoverSelectView: View {
    /// The book currently being decided.
    let entry: CoverQueueEntry
    /// How many books are in the pending queue (for the "N / M" counter).
    let queueTotal: Int
    /// 1-based position of `entry` within the queue (for the "N / M" counter).
    let queueIndex: Int

    var onApply: (String) -> Void = { _ in }
    var onKeepAuto: (String) -> Void = { _ in }
    var onSkip: () -> Void = {}
    var onBack: () -> Void = {}

    /// Currently selected candidate id. Seeds from the auto/best pick, then the
    /// user can change it by tapping another cover.
    @State private var selectedId: String

    init(entry: CoverQueueEntry, queueTotal: Int, queueIndex: Int,
         onApply: @escaping (String) -> Void = { _ in },
         onKeepAuto: @escaping (String) -> Void = { _ in },
         onSkip: @escaping () -> Void = {},
         onBack: @escaping () -> Void = {}) {
        self.entry = entry
        self.queueTotal = queueTotal
        self.queueIndex = queueIndex
        self.onApply = onApply
        self.onKeepAuto = onKeepAuto
        self.onSkip = onSkip
        self.onBack = onBack
        // Seed selection: best candidate, else the first one, else empty.
        let seed = entry.bestCandidateId
            ?? entry.candidates.first?.id
            ?? ""
        _selectedId = State(initialValue: seed)
    }

    private var autoId: String? { entry.bestCandidateId }

    var body: some View {
        ZStack {
            Tokens.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                bookCard
                candidatesSection
                actions
                Spacer(minLength: 0)
            }
        }
        .frame(width: Tokens.M.windowWidth)
    }

    // --- Header (back + title + N / M counter) -------------------------------
    private var header: some View {
        HStack(spacing: Tokens.M.headerGap - 1) { // mockup gap 11
            // Back button
            RoundedRectangle(cornerRadius: Tokens.M.iconBtnRadius, style: .continuous)
                .fill(Tokens.C.iconBtnBg)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.M.iconBtnRadius, style: .continuous)
                        .stroke(Tokens.C.iconBtnBorder, lineWidth: 1))
                .overlay(
                    StrokeIcon(size: 13, lineWidth: 2.2, build: CSIcons.back)
                        .foregroundColor(Tokens.C.textSoft))
                .frame(width: Tokens.M.iconBtnSize, height: Tokens.M.iconBtnSize)
                .contentShape(Rectangle())
                .onTapGesture(perform: onBack)

            VStack(alignment: .leading, spacing: 4) {
                Text("Выбор обложки")
                    .font(Tokens.F.h1)
                    .foregroundColor(Tokens.C.textPrimary)
                    .trackingCompat(Tokens.Track.h1)
                Text("НАЙДЕНО НЕСКОЛЬКО ВАРИАНТОВ")
                    .font(Tokens.F.cap)
                    .foregroundColor(Tokens.C.textTertiary)
                    .trackingCompat(Tokens.Track.cap)
            }
            Spacer(minLength: 0)
            counter
        }
        .padding(.horizontal, Tokens.M.headerPadH)
        .padding(.top, Tokens.M.headerPadTop)
        .padding(.bottom, Tokens.M.headerPadBottom)
    }

    private var counter: some View {
        HStack(spacing: 1) {
            Text("\(max(1, queueIndex))")
                .font(Tokens.CS.counterCur)
                .foregroundColor(Tokens.C.textPrimary)
                .monoDigitsCompat()
            Text("/")
                .font(Tokens.CS.counterSep)
                .foregroundColor(Tokens.C.textVeryMute)
                .padding(.horizontal, 1)
            Text("\(max(1, queueTotal))")
                .font(Tokens.CS.counterTot)
                .foregroundColor(Tokens.C.textSecondary)
                .monoDigitsCompat()
        }
        .padding(.horizontal, Tokens.CS.counterPadH)
        .padding(.vertical, Tokens.CS.counterPadV)
        .background(
            RoundedRectangle(cornerRadius: Tokens.CS.counterRadius, style: .continuous)
                .fill(Tokens.CS.counterBg))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.CS.counterRadius, style: .continuous)
                .stroke(Tokens.CS.counterBorder, lineWidth: 1))
    }

    // --- Book card -----------------------------------------------------------
    private var bookCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title · author
            (Text(entry.title ?? "Без названия")
                .font(Tokens.CS.bookTitle)
                .foregroundColor(Tokens.C.textPrimary)
             + authorSuffix)
                .trackingCompat(Tokens.Track.h1)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // File row
            if let file = entry.srcBasename {
                HStack(spacing: Tokens.CS.bookFileGap) {
                    StrokeIcon(size: 13, build: CSIcons.doc)
                        .foregroundColor(Tokens.C.textTertiary)
                    Text(file)
                        .font(Tokens.CS.bookFile)
                        .foregroundColor(Tokens.C.textSoft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.top, Tokens.CS.bookFileTop)
            }

            // "Обложка в файле не найдена" note
            HStack(alignment: .top, spacing: Tokens.CS.bookNoteGap) {
                StrokeIcon(size: 12, build: CSIcons.info)
                    .foregroundColor(Tokens.C.textTertiary)
                    .padding(.top, 1)
                Text("Обложка в файле не найдена — выбери из найденных")
                    .font(Tokens.CS.bookNote)
                    .foregroundColor(Tokens.C.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Tokens.CS.bookNoteTop)
        }
        .padding(.horizontal, Tokens.CS.bookPadH)
        .padding(.vertical, Tokens.CS.bookPadV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(csCard(radius: Tokens.CS.bookRadius))
        .padding(.horizontal, Tokens.CS.bookMarginH)
        .padding(.top, Tokens.CS.bookMarginTop)
        .padding(.bottom, Tokens.CS.bookMarginBottom)
    }

    private var authorSuffix: Text {
        guard let a = entry.author, !a.isEmpty else { return Text("") }
        return Text("  ·  \(a)")
            .font(Tokens.CS.bookAuthor)
            .foregroundColor(Tokens.C.textSecondary)
    }

    // --- Candidates ----------------------------------------------------------
    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("КАНДИДАТЫ · \(entry.candidates.count)")
                    .font(Tokens.F.cap)
                    .foregroundColor(Tokens.C.textTertiary)
                    .trackingCompat(Tokens.Track.cap)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.CS.secCapPadH)
            .padding(.bottom, Tokens.CS.secCapBottom)

            grid
        }
    }

    private var grid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: Tokens.CS.gridGap),
                         count: 3)
        return LazyVGrid(columns: cols, alignment: .center, spacing: Tokens.CS.gridGap) {
            ForEach(entry.candidates) { cand in
                CandidateCell(
                    candidate: cand,
                    title: entry.title,
                    author: entry.author,
                    isSelected: cand.id == selectedId,
                    isAuto: cand.id == autoId,
                    onTap: { selectedId = cand.id })
            }
        }
        .padding(.horizontal, Tokens.CS.gridPadH)
        .padding(.bottom, Tokens.CS.gridBottom)
    }

    // --- Actions -------------------------------------------------------------
    private var actions: some View {
        VStack(spacing: 0) {
            // Apply CTA
            Button(action: { onApply(selectedId) }) {
                HStack(spacing: Tokens.CS.ctaGap) {
                    StrokeIcon(size: 16, lineWidth: 2.2, build: CSIcons.check)
                        .foregroundColor(.white)
                    Text("Применить обложку")
                        .font(Tokens.CS.cta_)
                        .foregroundColor(.white)
                        .trackingCompat(0.1)
                }
                .frame(maxWidth: .infinity)
                .padding(Tokens.CS.ctaPad)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.CS.ctaRadius, style: .continuous)
                        .fill(Tokens.CS.cta))
                .shadow(color: Color(.sRGB, red: 1, green: 61/255, blue: 90/255, opacity: 0.6),
                        radius: 12, x: 0, y: 10)
            }
            .buttonStyle(.plain)

            // Secondary links: keep-auto / skip
            HStack(spacing: Tokens.CS.linksGap) {
                linkButton(
                    label: "Оставить авто-выбор",
                    iconLeading: true,
                    color: Tokens.CS.linkText,
                    border: Tokens.CS.linkBorder,
                    build: CSIcons.bolt,
                    action: { onKeepAuto(autoId ?? selectedId) })
                linkButton(
                    label: "Пропустить",
                    iconLeading: false,
                    color: Tokens.CS.linkText,
                    border: Tokens.CS.linkBorder,
                    build: CSIcons.arrowRight,
                    action: onSkip)
            }
            .padding(.top, Tokens.CS.linksTop)
        }
        .padding(.horizontal, Tokens.CS.actionsPadH)
        .padding(.top, Tokens.CS.actionsPadTop)
        .padding(.bottom, Tokens.CS.actionsPadBottom)
    }

    private func linkButton(label: String, iconLeading: Bool, color: Color,
                            border: Color, build: @escaping (inout Path) -> Void,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Tokens.CS.linkGap) {
                if iconLeading {
                    StrokeIcon(size: 13, build: build).foregroundColor(color)
                    Text(label).font(Tokens.CS.link).foregroundColor(color)
                } else {
                    Text(label).font(Tokens.CS.link).foregroundColor(color)
                    StrokeIcon(size: 14, build: build).foregroundColor(color)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.CS.linkPadV)
            .padding(.horizontal, Tokens.CS.linkPadH)
            .background(
                RoundedRectangle(cornerRadius: Tokens.CS.linkRadius, style: .continuous)
                    .fill(Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.CS.linkRadius, style: .continuous)
                    .stroke(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
