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
// Helpers (sfIcon / csCard) are file-private duplicates of the StatusView/SetupView
// pattern: those are `private` and not shared across files, so each screen carries
// its own small icon (SF Symbols via Image(systemName:)) + card kit (keeps
// pixel-perfect a one-file diff).

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
    /// Set by the agent after a "research" re-search that found NOTHING new: the
    /// old `candidates` are kept and this flag flips true. The "Искать ещё" polling
    /// reads it to show "больше вариантов не нашлось". Absent/false by default.
    let noMore: Bool
    /// Title-match confidence from the cover finder: `true` when a web cover was
    /// matched to this book's TITLE with confidence (and `best_candidate_id` is the
    /// pick). `false` means NO confident web match — `best_candidate_id` is null and
    /// the default selection must NOT sit on a (possibly wrong) web candidate; the
    /// screen defaults to a GENERATED cover instead. Absent → `true` (legacy entries
    /// predate the flag, so they keep the original "best/first web pick" behaviour).
    let confident: Bool

    var id: String { bookId }

    enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case epubPath = "epub_path"
        case title, author
        case srcFile = "src_file"
        case status, candidates
        case bestCandidateId = "best_candidate_id"
        case ts
        case noMore = "no_more"
        case confident
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
        noMore          = (try? c.decodeIfPresent(Bool.self, forKey: .noMore)) ?? false
        // Absent → true: legacy entries keep the original "best/first web pick"
        // default; only an explicit `false` switches the default to a generated cover.
        confident       = (try? c.decodeIfPresent(Bool.self, forKey: .confident)) ?? true
    }

    init(bookId: String, epubPath: String, title: String?, author: String?,
         srcFile: String?, status: String, candidates: [CoverCandidate],
         bestCandidateId: String?, ts: String?, noMore: Bool = false,
         confident: Bool = true) {
        self.bookId = bookId; self.epubPath = epubPath; self.title = title
        self.author = author; self.srcFile = srcFile; self.status = status
        self.candidates = candidates; self.bestCandidateId = bestCandidateId; self.ts = ts
        self.noMore = noMore
        self.confident = confident
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
    ///
    /// EPUB-existence gate: a "pending" entry only counts when its `epub_path`
    /// still exists on disk. The user can delete the watched folder (sources +
    /// converted EPUBs) while stale queue files linger; without this gate the
    /// "Выбрать обложку" row + screen would offer covers for books that no longer
    /// exist (nothing to apply to). When the EPUB is GONE we also self-clean the
    /// stale `covers/queue/<id>.json` (App Support is app-writable; the watcher
    /// only ADDS new entries, so there's no write race). We delete ONLY when the
    /// EPUB is provably absent — a transient read error never drops an entry.
    func loadPending() -> [CoverQueueEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: queueDir) else { return [] }
        var entries: [CoverQueueEntry] = []
        for name in names where name.hasSuffix(".json") && !name.hasSuffix(".tmp") {
            let path = "\(queueDir)/\(name)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let entry = try? JSONDecoder().decode(CoverQueueEntry.self, from: data),
                  entry.isPending else { continue }
            // Only surface books whose EPUB still exists. If it's gone, drop the
            // entry from the result AND remove the now-orphaned queue file.
            guard !entry.epubPath.isEmpty,
                  fm.fileExists(atPath: entry.epubPath) else {
                if !entry.epubPath.isEmpty { try? fm.removeItem(atPath: path) }
                continue
            }
            entries.append(entry)
        }
        // Newest first; entries without ts sort last but keep a stable order.
        entries.sort { ($0.ts ?? "") > ($1.ts ?? "") }
        return entries
    }

    /// Read ONE book's queue file directly (`covers/queue/<book_id>.json`), tolerant
    /// of a half-written/malformed file (returns nil rather than throwing). Used by
    /// the "Искать ещё" polling loop to watch a single book's entry get rewritten by
    /// the agent with fresh candidates (or a `no_more` flag). Unlike `loadPending()`
    /// this applies NO pending/epub filtering: the caller already showed this book,
    /// and a re-search keeps status "pending" — we just need the latest snapshot,
    /// including the `no_more` case.
    func loadEntry(bookId: String) -> CoverQueueEntry? {
        let path = "\(queueDir)/\(bookId).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let entry = try? JSONDecoder().decode(CoverQueueEntry.self, from: data) else {
            return nil
        }
        return entry
    }
}

// MARK: - Generated (fallback) cover candidates (Step 2)

/// One natively-rendered fallback cover (CoverGenerator template 1…4), shown in
/// the grid AFTER the web candidates with the source label "Сгенерировано". It is
/// selectable exactly like a web `CoverCandidate`, but applying it takes a
/// different path (save PNG + `requestApplyGenerated`), so it carries its own
/// synthetic id + the raw PNG `Data` instead of an on-disk preview path.
private struct GeneratedCover: Identifiable, Equatable {
    /// Synthetic id, namespaced so it can never collide with a web candidate id
    /// (which is "<book_id>-<rank>"): "<book_id>-gen-<template>".
    let id: String
    let template: Int       // 1…4
    let png: Data           // the rendered 1200×1800 PNG bytes
}

/// Per-book generated-cover state, cached for the screen's lifetime so flipping
/// the pager back and forth never re-renders. `covers` is filled once all 4
/// templates finish; while empty AND `loading`, the grid shows 4 placeholders.
///
/// `renderedSeq` stamps WHICH edit-generation these covers belong to (the value of
/// `regenSeq[bookId]` when this render was kicked). It's the freshness key that
/// closes the M3 race: after the user edits a field we bump `regenSeq` and mark the
/// state loading with the NEW seq SYNCHRONOUSLY, so any covers still on screen are
/// provably stale (`renderedSeq != regenSeq[bookId]`) and "Утвердить" refuses to
/// commit them until the fresh render lands with a matching seq.
private struct GeneratedState: Equatable {
    var loading: Bool
    var covers: [GeneratedCover]
    var renderedSeq: Int
}

/// The user's edited metadata for one book (Фича 2 плумбинг, M3). Holds the
/// TRIMMED title/author the user typed on screen. In M3 the edit fields don't
/// exist yet, so `edits` stays empty and the effective values equal the queue
/// entry's originals; the struct + wiring are here so M4 only adds the TextFields.
private struct MetaEdit: Equatable {
    var title: String   // trimmed; "" = no override for this field
    var author: String  // trimmed; "" = no override for this field
}

/// Which metadata field currently has keyboard focus (for the orange focus ring).
private enum FocusedField { case title, author }

// MARK: - Borderless metadata text field (Фича 2, M4)

/// A single-line, borderless NSTextField wrapped for SwiftUI. We use AppKit (not a
/// bare SwiftUI TextField) for three reasons the spec/floor demand: (1) exact focus
/// tracking on macOS 11 — SwiftUI's @FocusState is 12+; the delegate reports
/// begin/end editing so the card can paint the orange focus ring; (2) a placeholder
/// visible when empty; (3) live per-keystroke text via controlTextDidChange. The
/// field draws NOTHING itself (clear background, no bezel) — the SwiftUI container
/// owns the fill/border/ring from Tokens, so the visual stays token-exact.
private struct MetaTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let textColor: NSColor
    let placeholderColor: NSColor
    /// Called on every keystroke with the current (untrimmed) string.
    var onChange: (String) -> Void = { _ in }
    /// Called when the field gains (true) / loses (false) first-responder focus.
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTextField {
        let tf = FocusReportingTextField()
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.backgroundColor = .clear
        tf.focusRingType = .none           // the SwiftUI container draws our own ring
        tf.usesSingleLineMode = true
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.delegate = context.coordinator
        tf.font = font
        tf.textColor = textColor
        tf.onFocusChange = { context.coordinator.parent.onFocusChange($0) }
        applyString(tf)
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self
        tf.font = font
        tf.textColor = textColor
        // Only overwrite the field's value when it diverges from the binding AND the
        // field isn't the active editor — otherwise we'd fight the user's cursor.
        if tf.stringValue != text && tf.currentEditor() == nil {
            tf.stringValue = text
        }
        applyPlaceholder(tf)
    }

    private func applyString(_ tf: NSTextField) {
        tf.stringValue = text
        applyPlaceholder(tf)
    }

    private func applyPlaceholder(_ tf: NSTextField) {
        tf.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: placeholderColor, .font: font])
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MetaTextField
        init(_ parent: MetaTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
            parent.onChange(tf.stringValue)
        }
    }
}

/// NSTextField that reports focus gain/loss (begin/end editing) so the SwiftUI
/// wrapper can drive the orange focus-ring state — @FocusState is macOS 12+.
private final class FocusReportingTextField: NSTextField {
    var onFocusChange: (Bool) -> Void = { _ in }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange(true) }
        return ok
    }

    // Fires when the field editor resigns (click-away / Tab). textDidEndEditing is
    // the reliable end-of-focus hook for an NSTextField backed by a shared editor.
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange(false)
    }
}

// MARK: - UI glyphs (SF Symbols)

/// A UI glyph rendered as an SF Symbol — the same approach StatusView/SetupView
/// (and the sibling mp3-to-m4b app) use: `Image(systemName:)`. Replaces the old
/// hand-drawn stroke paths (an enum of SVG `d` builders) that rendered crooked at
/// small sizes. `size`/`weight` mirror the old glyph box + stroke weight so each
/// icon keeps its slot; color is applied by the caller via `.foregroundColor`.
/// Weight stays regular/light — no bold "толстая кисть".
private func sfIcon(_ name: String, size: CGFloat, weight: Font.Weight = .regular) -> some View {
    Image(systemName: name)
        .font(.system(size: size, weight: weight))
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
                sfIcon("checkmark", size: 11, weight: .bold)
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

// MARK: - Generated candidate cell (loading placeholder OR rendered cover)

/// One grid cell for a GENERATED cover. While the render is in flight it shows a
/// 2:3 placeholder (subtle fill + a small spinner) in the same footprint as a
/// real cover, so the grid never reflows when the covers land. Once rendered it
/// behaves exactly like `CandidateCell` (cover + selection ring + emerald check),
/// with the source label fixed to "Сгенерировано".
private struct GeneratedCell: View {
    /// The rendered cover (nil while still loading → placeholder).
    let cover: GeneratedCover?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                coverArt
                if cover != nil {
                    if isSelected {
                        selectionRing
                        checkBadge
                    } else {
                        RoundedRectangle(cornerRadius: Tokens.CS.ringRadius, style: .continuous)
                            .stroke(Tokens.CS.frame.opacity(0.0), lineWidth: Tokens.CS.frameWidth)
                            .padding(Tokens.CS.ringInset)
                    }
                }
            }
            source
                .padding(.top, Tokens.CS.srcTop)
        }
        .contentShape(Rectangle())
        .onTapGesture { if cover != nil { onTap() } }
    }

    /// The 2:3 cover image (from the rendered PNG bytes) or, while loading, a
    /// subtle placeholder with a centered spinner — same frame/aspect/border as
    /// the real `CoverArt` so swapping in the image never shifts the layout.
    @ViewBuilder
    private var coverArt: some View {
        if let cover, let img = NSImage(data: cover.png) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .aspectRatio(Tokens.CS.coverAspectW / Tokens.CS.coverAspectH, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.CS.coverRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.CS.coverRadius, style: .continuous)
                        .stroke(Tokens.CS.coverBorder, lineWidth: 1))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.CS.coverRadius, style: .continuous)
                    .fill(Tokens.CS.counterBg)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            }
            .aspectRatio(Tokens.CS.coverAspectW / Tokens.CS.coverAspectH, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.CS.coverRadius, style: .continuous)
                    .stroke(Tokens.CS.coverBorder, lineWidth: 1))
        }
    }

    // Selection ring + check badge — identical visuals to CandidateCell.
    private var selectionRing: some View {
        RoundedRectangle(cornerRadius: Tokens.CS.ringRadius, style: .continuous)
            .strokeBorder(Tokens.CS.selRing, lineWidth: Tokens.CS.ringWidth)
            .padding(Tokens.CS.ringInset)
            .shadow(color: Color(.sRGB, red: 1, green: 61/255, blue: 90/255, opacity: 0.5),
                    radius: 9, x: 0, y: 0)
    }

    private var checkBadge: some View {
        Circle()
            .fill(Tokens.CS.checkCircle)
            .overlay(
                sfIcon("checkmark", size: 11, weight: .bold)
                    .foregroundColor(.white))
            .overlay(Circle().stroke(Tokens.CS.checkStroke, lineWidth: Tokens.CS.checkBorder))
            .frame(width: Tokens.CS.checkSize, height: Tokens.CS.checkSize)
            .shadow(color: Tokens.C.emerald.opacity(0.6), radius: 4, x: 0, y: 2)
            .offset(x: Tokens.CS.checkOffset, y: -Tokens.CS.checkOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(Tokens.CS.ringInset)
    }

    /// Source label — always "Сгенерировано" (no host, no АВТО badge).
    private var source: some View {
        Text("Сгенерировано")
            .font(Tokens.CS.srcHost)
            .foregroundColor(Tokens.C.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - CoverSelectView

/// The "Выбор обложки" screen — a PAGER over every pending book in the queue.
///
/// Shows the books one at a time with an "X / N" counter; the bottom bar has
/// exactly three controls: ‹ Назад · Утвердить · Вперёд ›. The user can flip
/// between books without confirming (selections are remembered for the screen's
/// lifetime), and only "Утвердить" commits a decision — which resolves the book,
/// drops it from the pager, and advances to the next pending one.
///
/// State lives HERE (queue + index + per-book selection) so navigation never
/// round-trips through the host; the host only supplies the queue snapshot and two
/// callbacks (commit one book, and "we're done — go back to Status").
///
/// The host (main.swift) wires:
///   onApply(bookId, candidateId) -> EngineClient.requestCover(.apply(...))  (writes apply-job)
///   onDone()                     -> present(.status)   (queue drained / Back)
///   onHeightMayChange()          -> refit the fixed-width window (book ↔ book row
///                                   counts can differ, so the height must re-fit)
struct CoverSelectView: View {
    /// All pending books, newest-first (as the host loaded them). The pager walks
    /// this list; applying a book removes it locally.
    let queue: [CoverQueueEntry]

    /// Commit one book's chosen WEB candidate (host writes the apply-job via
    /// requestCover). `editedTitle`/`editedAuthor` carry the user's corrected
    /// metadata (nil until Фича 2 fields land / when unchanged) → the agent
    /// rewrites the EPUB metadata via ebook-meta before embedding the cover.
    var onApply: (_ bookId: String, _ candidateId: String,
                  _ editedTitle: String?, _ editedAuthor: String?) -> Void = { _, _, _, _ in }
    /// Confirm the AUTO cover as-is (Фича 1): the cover was embedded at conversion,
    /// so nothing to change — the host writes an "apply_confirm" job that just
    /// resolves the card (and rewrites metadata when edited-values are present).
    var onConfirmAuto: (_ bookId: String,
                        _ editedTitle: String?, _ editedAuthor: String?) -> Void = { _, _, _ in }
    /// No more pending books (or Back) → return to the Status screen.
    var onDone: () -> Void = {}
    /// Ask the host to re-fit the fixed-width window height (row count can change
    /// when navigating between books with different numbers of candidates).
    var onHeightMayChange: () -> Void = {}
    /// "Искать ещё с подсказкой": ask the agent to re-search this book's cover,
    /// excluding the URLs already shown and carrying the user's free-text `query`
    /// (author+title hint; "" = auto) (host → EngineClient.requestCoverResearch).
    /// Fire-and-forget; the fresh result arrives via `reloadEntry` polling.
    var onResearch: (_ bookId: String, _ excludeUrls: [String], _ query: String) -> Void = { _, _, _ in }
    /// Re-read ONE book's queue file (host → EngineClient.loadCoverQueueEntry). The
    /// polling loop calls this off the main thread to watch the agent rewrite the
    /// entry with fresh candidates (or set `no_more`). nil when absent/unreadable.
    var reloadEntry: (_ bookId: String) -> CoverQueueEntry? = { _ in nil }
    /// Apply a GENERATED (natively-rendered) cover for one book: the host saves the
    /// PNG to `<COVERS_DIR>/generated/<book_id>.png` and writes an "apply_generated"
    /// job (EngineClient.saveGeneratedCover + requestApplyGenerated). Distinct from
    /// `onApply`, which commits a WEB candidate by id. Fire-and-forget; the pager
    /// advances internally just like a web apply. `editedTitle`/`editedAuthor` carry
    /// the user's corrected metadata (nil when unchanged), same as onApply.
    var onApplyGenerated: (_ bookId: String, _ pngData: Data,
                           _ editedTitle: String?, _ editedAuthor: String?) -> Void = { _, _, _, _ in }

    /// Remaining pending books in the pager (a book is removed once applied).
    @State private var books: [CoverQueueEntry]
    /// 0-based index of the book currently shown within `books`.
    @State private var index: Int = 0
    /// Per-book selected candidate id, keyed by bookId. Seeded lazily from each
    /// book's auto/best pick; survives navigation so a re-picked cover sticks when
    /// the user flips away and back (in memory, for this screen session only).
    @State private var selections: [String: String]
    /// bookId currently being re-searched ("Искать ещё" tapped, awaiting the agent),
    /// else nil. Drives the per-book "Ищу новые варианты…" spinner and disables the
    /// research button + pager nav for that book while the poll runs.
    @State private var researchingBookId: String? = nil
    /// Per-book generated-cover cache, keyed by bookId. Filled lazily when a book is
    /// first shown (4 fallback covers rendered off the main path) and KEPT for the
    /// screen's lifetime, so flipping the pager never re-renders. While a book's
    /// entry is `loading` with empty `covers`, the grid shows 4 placeholders.
    @State private var generated: [String: GeneratedState] = [:]
    /// Per-book edited metadata (Фича 2 плумбинг, M3), keyed by bookId. Written by
    /// the M4 edit fields (R5: never cleared on finishResearch). Empty until the
    /// user types, so every untouched book's effective title/author equals its
    /// queue-entry originals and no edited-value is sent to the agent.
    @State private var edits: [String: MetaEdit] = [:]
    /// Debounce token for the edit → generated-cover regeneration. Each keystroke
    /// bumps `regenSeq`; a ~400ms-delayed closure only fires when its captured seq
    /// still matches (i.e. no newer keystroke landed), so rapid typing collapses to
    /// ONE re-render (macOS-11-safe: DispatchQueue timer, no Combine/.task(id:)).
    @State private var regenSeq: [String: Int] = [:]
    /// Which edit field (title/author) of the CURRENT book holds focus, else nil.
    /// Drives the orange focus ring + caps-label tint. Reset when the pager flips to
    /// another book so focus styling never sticks to the wrong card (@FocusState is
    /// macOS 12+; our floor is 11, so we track it manually via the field's delegate).
    @State private var focusedField: FocusedField? = nil

    init(queue: [CoverQueueEntry],
         onApply: @escaping (_ bookId: String, _ candidateId: String,
                             _ editedTitle: String?, _ editedAuthor: String?) -> Void = { _, _, _, _ in },
         onConfirmAuto: @escaping (_ bookId: String,
                                   _ editedTitle: String?, _ editedAuthor: String?) -> Void = { _, _, _ in },
         onDone: @escaping () -> Void = {},
         onHeightMayChange: @escaping () -> Void = {},
         onResearch: @escaping (_ bookId: String, _ excludeUrls: [String], _ query: String) -> Void = { _, _, _ in },
         reloadEntry: @escaping (_ bookId: String) -> CoverQueueEntry? = { _ in nil },
         onApplyGenerated: @escaping (_ bookId: String, _ pngData: Data,
                                      _ editedTitle: String?, _ editedAuthor: String?) -> Void = { _, _, _, _ in }) {
        self.queue = queue
        self.onApply = onApply
        self.onConfirmAuto = onConfirmAuto
        self.onDone = onDone
        self.onHeightMayChange = onHeightMayChange
        self.onResearch = onResearch
        self.reloadEntry = reloadEntry
        self.onApplyGenerated = onApplyGenerated
        _books = State(initialValue: queue)
        // Seed every CONFIDENT book's selection with its auto/best pick (else first
        // web candidate). For a non-confident book (no trustworthy web match) we do
        // NOT seed a key: leaving `selections[bookId] == nil` lets `selectedId` fall
        // through to the generated-cover default once it renders, instead of sitting
        // on a possibly-wrong web candidate. The user can still pick anything later.
        var seed: [String: String] = [:]
        for b in queue where b.confident {
            seed[b.bookId] = b.bestCandidateId ?? b.candidates.first?.id ?? ""
        }
        _selections = State(initialValue: seed)
    }

    // --- Derived state -------------------------------------------------------

    /// The book currently on screen (nil only if the pager is momentarily empty,
    /// which the body guards by calling onDone()).
    private var entry: CoverQueueEntry? {
        guard index >= 0, index < books.count else { return nil }
        return books[index]
    }

    /// Auto/best candidate id for the current book.
    private var autoId: String? { entry?.bestCandidateId }

    /// Currently selected candidate id for the current book.
    ///
    /// `selections[bookId]` is the user's EXPLICIT pick (absent until they tap a
    /// cell). When absent we fall back to the DEFAULT for this book:
    ///   • confident == true (or legacy/no flag) → the web auto/best pick (else the
    ///     first web candidate) — unchanged behaviour.
    ///   • confident == false (no trustworthy web match) → never auto-sit on a web
    ///     candidate. Until the generated covers render → "" (Утвердить inert). Once
    ///     `genState.covers` is non-empty → the FIRST generated cover's id.
    private var selectedId: String {
        guard let e = entry else { return "" }
        if let explicit = selections[e.bookId] { return explicit }
        return defaultSelection(for: e)
    }

    /// The default selection id for `e` when the user hasn't picked anything yet.
    /// Split out so `selectedId`, the auto badge, and the apply gate share ONE rule.
    private func defaultSelection(for e: CoverQueueEntry) -> String {
        if e.confident {
            return e.bestCandidateId ?? e.candidates.first?.id ?? ""
        }
        // No confident web match: prefer the first generated cover once it's ready;
        // until then stay empty so "Утвердить" can't veil a wrong web cover.
        return genState?.covers.first?.id ?? ""
    }

    /// Generated-cover state for the current book (nil until its render task runs).
    private var genState: GeneratedState? {
        guard let e = entry else { return nil }
        return generated[e.bookId]
    }

    /// The generated cover the current selection points at, if the user picked a
    /// generated cell (its id is namespaced "<book_id>-gen-<n>"). nil for a web pick.
    private var selectedGenerated: GeneratedCover? {
        genState?.covers.first { $0.id == selectedId }
    }

    // --- Editable metadata (Фича 2 плумбинг) ---------------------------------
    // effTitle/effAuthor are the EFFECTIVE values that drive both the job payload
    // and (in M4) the generated-cover render + research hint: the user's edit when
    // present, else the queue entry's original. In M3 `edits` is empty, so these
    // always resolve to the originals and nothing edited is sent.

    /// Effective TITLE for the current book: the trimmed edit if the user changed
    /// it, else the queue entry's original title.
    private var effTitle: String {
        guard let e = entry else { return "" }
        let edited = edits[e.bookId]?.title ?? ""
        return edited.isEmpty ? (e.title ?? "") : edited
    }

    /// Effective AUTHOR for the current book (same rule as effTitle).
    private var effAuthor: String {
        guard let e = entry else { return "" }
        let edited = edits[e.bookId]?.author ?? ""
        return edited.isEmpty ? (e.author ?? "") : edited
    }

    /// Effective TITLE for an ARBITRARY entry (not necessarily the one on screen).
    /// Used by the generated-cover render + research prefill, which take an `entry`
    /// by value and must honor the user's edit for THAT book, not the paged one.
    private func effTitle(for e: CoverQueueEntry) -> String {
        let edited = edits[e.bookId]?.title ?? ""
        return edited.isEmpty ? (e.title ?? "") : edited
    }

    /// Effective AUTHOR for an ARBITRARY entry (same rule as `effTitle(for:)`).
    private func effAuthor(for e: CoverQueueEntry) -> String {
        let edited = edits[e.bookId]?.author ?? ""
        return edited.isEmpty ? (e.author ?? "") : edited
    }

    /// True when the current book's effective metadata DIFFERS from its original —
    /// i.e. the user actually edited title and/or author. Drives whether an
    /// edited-value is attached to the outgoing job.
    private var metaEdited: Bool {
        guard let e = entry else { return false }
        return effTitle != (e.title ?? "") || effAuthor != (e.author ?? "")
    }

    /// The `editedTitle` to send in a job: the effective title when the user changed
    /// it (and it's non-empty), else nil (→ the job omits the field; agent keeps the
    /// original metadata). `metaEdited` gates it so an unchanged value never ships.
    private var jobEditedTitle: String? {
        guard let e = entry else { return nil }
        let t = effTitle
        return (metaEdited && !t.isEmpty && t != (e.title ?? "")) ? t : nil
    }

    /// The `editedAuthor` to send in a job (same rule as jobEditedTitle).
    private var jobEditedAuthor: String? {
        guard let e = entry else { return nil }
        let a = effAuthor
        return (metaEdited && !a.isEmpty && a != (e.author ?? "")) ? a : nil
    }

    /// True while the CURRENT book is being re-searched ("Искать ещё" in flight).
    /// Freezes nav + apply + the research button until the poll resolves.
    private var isResearching: Bool { researchingBookId != nil && researchingBookId == entry?.bookId }

    /// "Назад" is disabled on the first book (and while a re-search is in flight).
    private var canGoBack: Bool { index > 0 && !isResearching }
    /// "Вперёд" is disabled on the last book (and while a re-search is in flight).
    private var canGoForward: Bool { index < books.count - 1 && !isResearching }
    /// True when `selectedId` names a GENERATED cover (namespaced "<bookId>-gen-<n>"),
    /// independent of whether the covers are currently in the cache. Lets the confirm
    /// gate recognise a generated pick even right after an edit dropped the covers to a
    /// loading state (when `selectedGenerated` is momentarily nil).
    private var selectedIsGenerated: Bool {
        guard let e = entry else { return false }
        return selectedId.hasPrefix("\(e.bookId)-gen-")
    }

    /// True when the current book's generated covers are FRESH: rendered (not loading,
    /// non-empty) AND stamped with the current regen seq (M3). After an edit bumps the
    /// seq + marks the state loading, this reads false until the new render publishes.
    private var generatedFresh: Bool {
        guard let e = entry, let g = genState else { return false }
        return !g.loading && !g.covers.isEmpty && g.renderedSeq == (regenSeq[e.bookId] ?? 0)
    }

    /// "Утвердить" is active whenever there is a valid selection and no re-search is
    /// in flight. Confirming the AUTO pick as-is is a valid action now (Фича 1) — it
    /// resolves the card — so we NO LONGER require `selectedId != autoId` (that was
    /// the root of the "always-grey button" feel). Empty selection (a non-confident
    /// book before its generated covers render) still gates it off.
    ///
    /// M3 gate: when the selection is a GENERATED cover, it may only be confirmed once
    /// the generated covers are FRESH (re-rendered against the current edited text).
    /// Right after a keystroke we bump the seq + drop the covers to a loading state, so
    /// `generatedFresh` is false and this refuses to fire — preventing a stale PNG (old
    /// text) from shipping with the new metadata, and preventing a now-orphaned
    /// gen-id from leaking into `onApply` as if it were a web candidate.
    private var canConfirm: Bool {
        guard !isResearching, !selectedId.isEmpty else { return false }
        if selectedIsGenerated { return generatedFresh }
        return true
    }

    var body: some View {
        ZStack {
            Tokens.canvas.ignoresSafeArea()
            if let entry = entry {
                VStack(spacing: 0) {
                    // Header + book card stay PINNED at the top (always visible).
                    header(entry: entry)
                    bookCard(entry: entry)
                    // Only the candidate grid scrolls: when many candidates (web +
                    // generated) make the window hit the screen-height cap (see
                    // main.swift refitWindowHeight), this ScrollView absorbs the
                    // squeeze and scrolls, so the bottom bar below never leaves the
                    // screen. With few candidates the content fits and it doesn't
                    // scroll. Vertical-only; horizontal stays locked at 400px.
                    ScrollView(.vertical, showsIndicators: true) {
                        candidatesSection(entry: entry)
                    }
                    // "Искать ещё" + the ‹ Назад · Утвердить · Вперёд › bar stay
                    // PINNED at the bottom (always visible / tappable).
                    researchRow(entry: entry)
                    actions
                }
                // Render the 4 fallback covers for whichever book is on screen.
                // `.task(id:)` is macOS 12+, but our floor is 11 (MIN_MACOS), so we
                // kick an unstructured Task on appear AND whenever the shown book
                // changes (the VStack identity is stable across pager flips, so
                // onAppear alone wouldn't re-fire). The cache check inside makes a
                // re-show a no-op, so flipping back never re-renders.
                .onAppear { kickGenerated() }
                .onChange(of: entry.bookId) { _ in
                    focusedField = nil   // don't carry focus styling to the next card
                    kickGenerated()
                }
            } else {
                // Pager empty (last book applied) — bounce back to Status. Done on
                // the next runloop tick so we never mutate host state mid-render.
                Color.clear.onAppear { onDone() }
            }
        }
        .frame(width: Tokens.M.windowWidth)
    }

    // --- Navigation ----------------------------------------------------------

    private func goBack() {
        guard canGoBack else { return }
        index -= 1
        onHeightMayChange()
    }

    private func goForward() {
        guard canGoForward else { return }
        index += 1
        onHeightMayChange()
    }

    // --- Generated fallback covers (Step 2) ----------------------------------

    /// Kick the generated-cover render for the book currently on screen, as an
    /// unstructured Task (macOS-11-safe; `.task(id:)` is 12+). The cache check in
    /// `ensureGenerated` makes a re-call a no-op, so onAppear + onChange firing
    /// together (or a fast back-and-forth flip) never double-renders.
    private func kickGenerated() {
        guard let e = entry, generated[e.bookId] == nil else { return }
        Task { await ensureGenerated(for: e) }
    }

    /// Lazily render the 4 fallback covers for `entry` and cache them by bookId.
    /// No-ops if this book was already rendered (cache hit) or is mid-render, so a
    /// back-and-forth flip through the pager never re-renders. Flips `loading` on so
    /// the grid shows 4 placeholders, renders templates 1…4 (CoverGenerator is
    /// @MainActor), then publishes whatever succeeded as selectable candidates.
    @MainActor
    private func ensureGenerated(for entry: CoverQueueEntry) async {
        let bookId = entry.bookId
        // Cache hit OR already loading → nothing to do (idempotent re-show).
        if generated[bookId] != nil { return }
        // Snapshot the regen token: an edit-triggered re-render bumps `regenSeq` and
        // resets `generated[bookId]` to nil; if a NEWER kick started while we render,
        // its seq wins and this (stale-text) render must NOT publish over it.
        let mySeq = regenSeq[bookId] ?? 0

        // Mark loading so the grid paints 4 placeholders in the covers' footprint.
        // Stamp the loading state with THIS render's seq so the confirm gate sees a
        // fresh (matching-seq) loading state, not a stale one.
        generated[bookId] = GeneratedState(loading: true, covers: [], renderedSeq: mySeq)
        onHeightMayChange()      // generated row appears → window must re-fit

        // Render all 4 templates. Each render is async on the main actor; we await
        // them in order (the WebKit renderer serializes anyway) and keep only the
        // ones that succeeded, tagged with a namespaced id for selection. If the
        // book leaves the pager mid-render (applied/dropped), bail without churn.
        // Render from the EFFECTIVE (edited-or-original) metadata so a correction
        // typed in the card lands on the generated covers too (Фича 2, M4).
        let genTitle = effTitle(for: entry)
        let genAuthor = effAuthor(for: entry)
        let gen = CoverGenerator()
        var covers: [GeneratedCover] = []
        for template in 1...4 {
            guard books.contains(where: { $0.bookId == bookId }) else { return }
            if let png = await gen.render(author: genAuthor,
                                          title: genTitle,
                                          template: template) {
                covers.append(GeneratedCover(id: "\(bookId)-gen-\(template)",
                                             template: template, png: png))
            }
        }

        // The user may have navigated away (or applied this book) while rendering.
        // Only publish if this book is still in the pager AND no newer edit-render
        // superseded this one (regenSeq unchanged since we started).
        guard books.contains(where: { $0.bookId == bookId }),
              (regenSeq[bookId] ?? 0) == mySeq else { return }
        generated[bookId] = GeneratedState(loading: false, covers: covers, renderedSeq: mySeq)
        onHeightMayChange()      // placeholders → real covers (row count unchanged,
                                 // but the source label height differs slightly)
    }

    // --- Editable metadata → generated-cover regeneration (Фича 2, M4) --------

    /// Write one edited field (title/author) into `edits[bookId]` and schedule a
    /// debounced regeneration of that book's generated covers. Called on every
    /// keystroke by the card's edit fields. The value is TRIMMED and stored ""-empty
    /// when it equals the original, so an unchanged field never counts as edited
    /// (matches jobEditedTitle/Author's gate) and the "было:" line stays hidden.
    ///
    /// Two things happen SYNCHRONOUSLY here (both close review races):
    ///   • m1: when a field's changed-state flips (the "было:" line appears/disappears,
    ///     which grows/shrinks the PINNED book card), call `onHeightMayChange()` so the
    ///     window re-fits and the bottom "Утвердить" bar can't slip off screen.
    ///   • M3: the moment the effective text changes we mark the generated covers dirty
    ///     RIGHT NOW (bump `regenSeq`, drop the cached covers to a loading state stamped
    ///     with the new seq) — NOT 400ms later. That makes any covers still on screen
    ///     provably stale, so `canConfirm` gates "Утвердить" off until the fresh render
    ///     lands. The debounce below only delays the (expensive) RENDER, never the
    ///     staleness marking.
    private func commitEdit(bookId: String, original: (title: String, author: String),
                            title: String? = nil, author: String? = nil) {
        let before = edits[bookId] ?? MetaEdit(title: "", author: "")
        var m = before
        if let t = title {
            let tt = t.trimmingCharacters(in: .whitespacesAndNewlines)
            m.title = (tt == original.title) ? "" : tt
        }
        if let a = author {
            let aa = a.trimmingCharacters(in: .whitespacesAndNewlines)
            m.author = (aa == original.author) ? "" : aa
        }
        // Nothing effectively changed (e.g. typed then deleted a trailing space that
        // trims back to the original) → no regen, no reflow, no dirtying.
        guard m != before else { return }
        edits[bookId] = m

        // m1: the "было:" line toggles with a field's changed-state (""→non-"" or
        // back). When that boundary is crossed the pinned card's height changes, so
        // the window must re-fit synchronously.
        let titleChangedFlip = before.title.isEmpty != m.title.isEmpty
        let authorChangedFlip = before.author.isEmpty != m.author.isEmpty
        if titleChangedFlip || authorChangedFlip {
            onHeightMayChange()
        }

        // M3: mark the generated covers dirty NOW (synchronously) so a rapid
        // edit-then-Утвердить can't commit a stale PNG. Bump the seq and reset the
        // cache to a fresh-seq loading state; the debounced closure only fires the
        // render off the NEW effective metadata.
        markGeneratedDirty(bookId: bookId)
        scheduleRegen(bookId: bookId)
    }

    /// SYNCHRONOUSLY invalidate `bookId`'s generated covers after an edit (M3): bump
    /// the regen seq and replace the cached state with a loading placeholder stamped
    /// with the NEW seq. The old covers vanish immediately (no 400ms window where a
    /// stale PNG is still selectable/committable), and `canConfirm` sees a
    /// loading/newer-seq state → "Утвердить" is inert until the fresh render lands.
    private func markGeneratedDirty(bookId: String) {
        let next = (regenSeq[bookId] ?? 0) + 1
        regenSeq[bookId] = next
        generated[bookId] = GeneratedState(loading: true, covers: [], renderedSeq: next)
    }

    /// Debounce (~400ms) the generated-cover RE-RENDER for `bookId`. The seq was
    /// already bumped + the covers already dirtied synchronously by `markGeneratedDirty`
    /// (M3); this only delays the expensive render so rapid typing collapses to ONE
    /// pass. After the delay — if no newer keystroke bumped the seq again — re-kick the
    /// render off the effective (edited) metadata. macOS-11-safe (DispatchQueue timer;
    /// no Combine/.task(id:)).
    private func scheduleRegen(bookId: String) {
        let mySeq = regenSeq[bookId] ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // A newer keystroke landed → let that one own the re-render.
            guard regenSeq[bookId] == mySeq else { return }
            // Regenerate THIS book by id (not `entry`): the user may have paged away
            // during the debounce window, and its covers must still reflect the edit.
            guard let b = books.first(where: { $0.bookId == bookId }) else { return }
            // Invalidate the cache so ensureGenerated re-renders (it no-ops while
            // `generated[bookId] != nil`); nil = "no covers yet" → loading placeholders.
            generated[bookId] = nil
            Task { await ensureGenerated(for: b) }
        }
    }

    /// Commit the current book's choice ("Утвердить"), then remove it from the pager
    /// and land on the next pending book. If that was the last one, return to Status.
    ///
    /// Routes the current selection to one of THREE host callbacks (Фича 1):
    ///   1. a GENERATED cover is picked → onApplyGenerated (save PNG + polish).
    ///   2. the AUTO cover is picked AND the book is `confident` (it's already
    ///      embedded, nothing to change) → onConfirmAuto (meta-only, no polish).
    ///   3. otherwise (a WEB candidate) → onApply (embed that cover).
    /// Every branch forwards the edited metadata (nil when unchanged) so the agent
    /// rewrites the EPUB's title/author when the user corrected it.
    private func confirmCurrent() {
        guard canConfirm, let e = entry else { return }

        // Safety net: the EPUB may have been deleted while this screen was open
        // (the load-time gate only filters at entry). Re-check at confirm time — if
        // it's gone, do NOT write a job for a file that no longer exists.
        // Tell the user, drop the book from the pager, and move on.
        guard !e.epubPath.isEmpty,
              FileManager.default.fileExists(atPath: e.epubPath) else {
            dropCurrentBook(showingMissingAlert: true)
            return
        }

        let t = jobEditedTitle
        let a = jobEditedAuthor
        if selectedIsGenerated {
            // 1) Generated pick → save the PNG + write an "apply_generated" job.
            // M3 barrier: only ship a generated cover whose bytes are FRESH (matching
            // the current edited text). If the covers were just invalidated by an edit
            // (`selectedGenerated` momentarily nil, or seq stale), bail WITHOUT sending
            // — never fall through to `onApply` with a gen-id (that would embed a
            // non-existent web candidate) and never ship a stale PNG. `canConfirm`
            // already gates the button; this guards the race where state lags the tap.
            guard generatedFresh, let g = selectedGenerated else { return }
            onApplyGenerated(e.bookId, g.png, t, a)
        } else if selectedId == autoId && e.confident {
            // 2) Auto cover, already embedded → confirm-only (no cover change).
            onConfirmAuto(e.bookId, t, a)
        } else {
            // 3) Web candidate → embed that cover by id.
            onApply(e.bookId, selectedId, t, a)
        }
        dropCurrentBook(showingMissingAlert: false)
    }

    /// Remove the current book from the pager and land on the next pending one
    /// (return to Status when none remain). When `showingMissingAlert` is true,
    /// first surface a short "book no longer found" alert (the EPUB vanished).
    private func dropCurrentBook(showingMissingAlert: Bool) {
        if showingMissingAlert {
            let alert = NSAlert()
            alert.messageText = "Книга больше не найдена"
            alert.informativeText = "Файл EPUB был удалён, поэтому обложку применить нельзя."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        guard index >= 0, index < books.count else {
            onDone()
            return
        }
        var next = books
        next.remove(at: index)
        books = next
        // Clamp the index onto the new list (removing the last book shifts us back).
        if index >= next.count { index = max(0, next.count - 1) }

        if next.isEmpty {
            onDone()
        } else {
            onHeightMayChange()
        }
    }

    // --- Header (exit + title + N / M counter) -------------------------------
    // Top-left ‹ = EXIT the section (back to Status via onDone). This is distinct
    // from the bottom pager's ‹ Назад / Вперёд › which only flip between books.
    // Always enabled (incl. first/last book) so the user can never get stuck —
    // adding the pager removed the old header back-arrow and trapped the screen.
    private func header(entry: CoverQueueEntry) -> some View {
        HStack(spacing: Tokens.M.headerGap - 1) { // mockup gap 11
            exitButton
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

    /// Top-left ‹ — EXIT the cover-select section back to Status (onDone). Reuses
    /// the screen's nav-button language (1px border, linkText chevron) but, unlike
    /// the bottom pager buttons, is never disabled/faded: this is the always-on way
    /// out, independent of which book is shown.
    private var exitButton: some View {
        // Hit-testing (see .patches/010): a `.buttonStyle(.plain)` Button whose label
        // is a clear fill + stroked border + stroke-only chevron has NO hit-testable
        // surface, so the tap target collapsed and ‹ never fired `onDone`. Use the
        // same proven pattern as the rest of the UI — `.contentShape(Rectangle())` +
        // `.onTapGesture` — so the whole padded box exits to Status.
        sfIcon("chevron.left", size: 15, weight: .semibold)
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

    /// "X / N": current 1-based position over the total pending count.
    private var counter: some View {
        HStack(spacing: 1) {
            Text("\(index + 1)")
                .font(Tokens.CS.counterCur)
                .foregroundColor(Tokens.C.textPrimary)
                .monoDigitsCompat()
            Text("/")
                .font(Tokens.CS.counterSep)
                .foregroundColor(Tokens.C.textVeryMute)
                .padding(.horizontal, 1)
            Text("\(books.count)")
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

    // --- Book card (Вариант A: always-editable Название / Автор, Фича 2 M4) --
    // The heading IS the editor: two borderless fields on the darker input surface,
    // then a hint line (why edit → nudge to Cyrillic), then the source-file row.
    // Metrics/colors are token-exact (design/cover-edit-fields-SPEC.md + Tokens).
    private func bookCard(entry: CoverQueueEntry) -> some View {
        let bookId = entry.bookId
        let orig = (title: (entry.title ?? ""), author: (entry.author ?? ""))
        return VStack(alignment: .leading, spacing: 0) {
            // [Название] [Автор] — vertical gap 7 (fieldInputGap rhythm).
            VStack(alignment: .leading, spacing: Tokens.M.fieldInputGap) {
                metaField(
                    bookId: bookId,
                    caption: "НАЗВАНИЕ",
                    which: .title,
                    text: Binding(
                        get: { effTitle(for: entry) },
                        set: { commitEdit(bookId: bookId, original: orig, title: $0) }),
                    original: orig.title,
                    placeholder: "Название книги",
                    font: NSFont.systemFont(ofSize: 15, weight: .bold),   // CS.bookTitle
                    color: Tokens.C.nsTextPrimary,
                    changed: !(edits[bookId]?.title ?? "").isEmpty)
                metaField(
                    bookId: bookId,
                    caption: "АВТОР",
                    which: .author,
                    text: Binding(
                        get: { effAuthor(for: entry) },
                        set: { commitEdit(bookId: bookId, original: orig, author: $0) }),
                    original: orig.author,
                    placeholder: "Автор",
                    font: NSFont.systemFont(ofSize: 14, weight: .medium), // CS.bookAuthor (secondary)
                    color: Tokens.C.nsTextSecondary,
                    changed: !(edits[bookId]?.author ?? "").isEmpty)
            }

            // Hint line (replaces the old "Обложка не найдена" note): why edit.
            HStack(alignment: .top, spacing: Tokens.CS.bookNoteGap) {
                sfIcon("info.circle", size: 12)
                    .foregroundColor(Tokens.C.textTertiary)
                    .padding(.top, 1)
                editHintText
                    .font(Tokens.CS.bookNote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Tokens.CS.bookNoteTop)

            // Source-file row (kept, now last per spec layout order).
            if let file = entry.srcBasename {
                HStack(spacing: Tokens.CS.bookFileGap) {
                    sfIcon("doc", size: 12)
                        .foregroundColor(Tokens.C.textTertiary)
                    Text(file)
                        .font(Tokens.CS.bookFile)
                        .foregroundColor(Tokens.C.textSoft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.top, Tokens.CS.bookFileTop)
            }
        }
        .padding(.horizontal, Tokens.CS.bookPadH)
        .padding(.vertical, Tokens.CS.bookPadV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(csCard(radius: Tokens.CS.bookRadius))
        .padding(.horizontal, Tokens.CS.bookMarginH)
        .padding(.top, Tokens.CS.bookMarginTop)
        .padding(.bottom, Tokens.CS.bookMarginBottom)
    }

    /// Hint text with "Поправь на русский" emphasized (C.textSoft), rest tertiary.
    private var editHintText: Text {
        (Text("Данные из файла. ")
            .foregroundColor(Tokens.C.textTertiary)
         + Text("Поправь на русский")
            .foregroundColor(Tokens.C.textSoft)
         + Text(", если распозналось неверно — текст попадёт на обложку и в метаданные.")
            .foregroundColor(Tokens.C.textTertiary))
    }

    /// One editable metadata field: caps label (with emerald dot when changed),
    /// the borderless input on the input surface, and — when changed — a struck-
    /// through "было: <original>" line. States (rest / focus / changed) are painted
    /// per SPEC: focus → orange ring + orange caps; changed → emerald border + caps.
    ///
    /// `bookId` keys the input's `.id` (M4): the borderless NSTextField is backed by a
    /// reusable NSView, and `updateNSView` refuses to overwrite `stringValue` while the
    /// field is the active editor. If the pager flipped WHILE the field held focus
    /// (Tab/keyboard nav past the resign), that guard would leave the previous book's
    /// text in the field — and could commit it to the wrong book. Tagging the field
    /// `.id("<bookId>-<which>")` makes SwiftUI throw away the old NSView and build a
    /// FRESH one per book (makeNSView seeds the correct value from scratch), so no
    /// reuse — and thus no stale-text — can survive a book change.
    private func metaField(bookId: String, caption: String, which: FocusedField,
                           text: Binding<String>, original: String,
                           placeholder: String, font: NSFont, color: NSColor,
                           changed: Bool) -> some View {
        // Field metrics (SPEC Вариант A): radius 8, padding 6/10/7 (t/side/b),
        // caps margin-bottom 3, "было:" 9.5px mono.
        let radius: CGFloat = 8
        let padTop: CGFloat = 6, padSide: CGFloat = 10, padBottom: CGFloat = 7
        let capsBottom: CGFloat = 3
        let focused = (focusedField == which)
        return VStack(alignment: .leading, spacing: 0) {
            // Caps label + emerald dot (when changed).
            HStack(spacing: Tokens.CS.autoGap) {
                if changed {
                    Circle()
                        .fill(Tokens.C.emerald)
                        .frame(width: 5, height: 5)
                        .shadow(color: Tokens.C.emerald, radius: 2.5)
                }
                Text(caption)
                    .font(Tokens.F.cap)
                    .foregroundColor(capsColor(focused: focused, changed: changed))
                    .trackingCompat(Tokens.Track.cap)
            }
            .padding(.bottom, capsBottom)

            // The borderless input.
            MetaTextField(
                text: text,
                placeholder: placeholder,
                font: font,
                textColor: color,
                placeholderColor: Tokens.C.nsTextVeryMute,
                onChange: { _ in },
                onFocusChange: { gained in
                    if gained { focusedField = which }
                    else if focusedField == which { focusedField = nil }
                })
                // M4: fresh NSTextField per book+field — never reuse across a pager
                // flip, so the currentEditor()==nil guard in updateNSView can't strand
                // the previous book's text (or commit it to the wrong book).
                .id("\(bookId)-\(which)")
                .frame(height: font.pointSize + 4)   // room for ascenders/descenders

            // "было: <original>" — struck-through original, only when changed.
            if changed && !original.isEmpty {
                (Text("было: ")
                    .foregroundColor(Tokens.C.textVeryMute)
                 + Text(original)
                    .foregroundColor(Tokens.C.textVeryMute)
                    .strikethrough(true, color: Tokens.C.textVeryMute))
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 3)
            }
        }
        .padding(.init(top: padTop, leading: padSide, bottom: padBottom, trailing: padSide))
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Tokens.C.inputBg))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(fieldBorderColor(focused: focused, changed: changed),
                        lineWidth: focused ? 1.5 : 1))
        // Orange halo on focus (SPEC: subtle 2px accentOrange@~.14, no heavy glow).
        .shadow(color: focused ? Tokens.C.accentOrange.opacity(0.14) : .clear,
                radius: focused ? 2 : 0, x: 0, y: 0)
    }

    /// Caps-label color by state: focus → orange, changed → emerald, else tertiary.
    private func capsColor(focused: Bool, changed: Bool) -> Color {
        if focused { return Tokens.C.accentOrange }
        if changed { return Tokens.C.emerald }
        return Tokens.C.textTertiary
    }

    /// Field border by state: focus → orange@.55, changed → emerald@.28, else the
    /// standard field border (white@.08).
    private func fieldBorderColor(focused: Bool, changed: Bool) -> Color {
        if focused { return Tokens.C.accentOrange.opacity(0.55) }
        if changed { return Tokens.C.emerald.opacity(0.28) }
        return Tokens.C.fieldBorder
    }

    // --- Candidates ----------------------------------------------------------
    private func candidatesSection(entry: CoverQueueEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                // Count = web candidates + generated covers shown (the 4 placeholders
                // count while they render, so the number is stable across the swap).
                Text("КАНДИДАТЫ · \(entry.candidates.count + generatedCellCount)")
                    .font(Tokens.F.cap)
                    .foregroundColor(Tokens.C.textTertiary)
                    .trackingCompat(Tokens.Track.cap)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.CS.secCapPadH)
            .padding(.bottom, Tokens.CS.secCapBottom)

            grid(entry: entry)
        }
    }

    /// How many generated cells the grid shows for the current book: the rendered
    /// covers when ready, 4 placeholders while loading, else 0.
    private var generatedCellCount: Int {
        guard let g = genState else { return 0 }
        if !g.covers.isEmpty { return g.covers.count }
        return g.loading ? 4 : 0
    }

    private func grid(entry: CoverQueueEntry) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: Tokens.CS.gridGap),
                         count: 3)
        let sel = selectedId
        let auto = autoId
        return LazyVGrid(columns: cols, alignment: .center, spacing: Tokens.CS.gridGap) {
            // Web candidates FIRST (unchanged path).
            ForEach(entry.candidates) { cand in
                CandidateCell(
                    candidate: cand,
                    title: entry.title,
                    author: entry.author,
                    isSelected: cand.id == sel,
                    isAuto: cand.id == auto,
                    onTap: { selections[entry.bookId] = cand.id })
            }
            // Generated fallback covers AFTER the web ones, labelled "Сгенерировано".
            generatedCells(entry: entry, sel: sel)
        }
        .padding(.horizontal, Tokens.CS.gridPadH)
        .padding(.bottom, Tokens.CS.gridBottom)
    }

    /// The generated grid cells for the current book: the rendered covers when
    /// ready (selectable), or 4 loading placeholders while the render is in flight.
    @ViewBuilder
    private func generatedCells(entry: CoverQueueEntry, sel: String) -> some View {
        if let g = genState {
            if !g.covers.isEmpty {
                ForEach(g.covers) { cover in
                    GeneratedCell(
                        cover: cover,
                        isSelected: cover.id == sel,
                        onTap: { selections[entry.bookId] = cover.id })
                }
            } else if g.loading {
                // 4 stable-id placeholders so SwiftUI keeps cell identity through the
                // swap to real covers (no flicker / reflow).
                ForEach(0..<4, id: \.self) { i in
                    GeneratedCell(cover: nil, isSelected: false, onTap: {})
                        .id("\(entry.bookId)-gen-ph-\(i)")
                }
            }
        }
    }

    // --- "Искать ещё" — re-search this book's cover --------------------------
    // A full-width secondary button under the grid. Tapping it asks the agent to
    // re-search, excluding every URL already shown, then polls the queue file for
    // the rewritten entry (new candidates → swap them in; no_more/timeout → alert).
    // While in flight it swaps to a "Ищу новые варианты…" spinner and the whole
    // book (nav + apply) is frozen; the background search never blocks the UI.
    @ViewBuilder
    private func researchRow(entry: CoverQueueEntry) -> some View {
        Button(action: { startResearch(entry: entry, query: researchQuery(for: entry)) }) {
            HStack(spacing: Tokens.CS.researchGap) {
                if isResearching {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: Tokens.CS.researchSpinner, height: Tokens.CS.researchSpinner)
                    Text("Ищу новые варианты…")
                        .font(Tokens.CS.researchFont)
                        .foregroundColor(Tokens.CS.linkText)
                } else {
                    sfIcon("magnifyingglass", size: Tokens.CS.researchIcon, weight: .medium)
                        .foregroundColor(Tokens.CS.linkText)
                    Text("Искать ещё")
                        .font(Tokens.CS.researchFont)
                        .foregroundColor(Tokens.CS.linkText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.CS.researchPadV)
            .background(
                RoundedRectangle(cornerRadius: Tokens.CS.researchRadius, style: .continuous)
                    .fill(Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.CS.researchRadius, style: .continuous)
                    .stroke(Tokens.CS.linkBorder, lineWidth: 1))
            // Whole full-width box tappable, not just the label text (clear fill +
            // stroked icon aren't hit-testable — .patches/010). Stays a Button so
            // `.disabled(isResearching)` freezes it mid-search.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isResearching)
        .opacity(isResearching ? 0.7 : 1.0)
        .help("Переискать обложку по подсказке (автор и название), исключив уже показанные варианты")
        .padding(.horizontal, Tokens.CS.researchRowPadH)
        .padding(.bottom, Tokens.CS.researchRowBottom)
    }

    /// Build the search hint for a re-search straight from the on-screen EDITABLE
    /// fields — no dialog. Since v0.9.7 the card already exposes editable
    /// Название/Автор, so the user has corrected the metadata a step earlier; the
    /// old "Искать ещё" NSAlert (title+author prefill) became redundant and was
    /// removed. This reproduces EXACTLY the string that dialog used to prefill:
    /// "<title> <author>" from the EFFECTIVE (edited-or-original) values, each part
    /// trimmed, empties dropped, joined with a single space — so a missing
    /// title/author never leaves a stray gap. Both empty → "" (onResearch's "auto").
    private func researchQuery(for entry: CoverQueueEntry) -> String {
        [effTitle(for: entry), effAuthor(for: entry)]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Kick off a re-search for `entry` with the user's `query` hint (already
    /// trimmed; "" = auto): collect every shown candidate URL as the exclude set,
    /// flip the per-book "searching" flag, fire the host callback, and start polling
    /// the queue file for the rewritten entry.
    private func startResearch(entry: CoverQueueEntry, query: String) {
        guard !isResearching else { return }
        let bookId = entry.bookId
        // Exclude the URLs the user has already seen (non-empty only).
        let exclude = entry.candidates.map { $0.url }.filter { !$0.isEmpty }
        // Remember the candidate id-set so polling can tell "rewritten with new
        // covers" from "same file re-read" (the agent rewrites the WHOLE entry).
        let oldIds = Set(entry.candidates.map { $0.id })
        let oldUrls = Set(entry.candidates.map { $0.url })

        researchingBookId = bookId
        onHeightMayChange()          // spinner row height differs from the button
        onResearch(bookId, exclude, query)
        pollResearch(bookId: bookId, oldIds: oldIds, oldUrls: oldUrls, attempt: 0)
    }

    /// Poll the book's queue file ~every 0.7s (max ~30s) for the agent's rewrite.
    /// Resolves on: a changed candidate set (id OR url differs) → swap covers in;
    /// `no_more == true` OR timeout → keep the old covers and show an alert. Each
    /// tick re-reads off the main thread (file I/O), then hops back to mutate state.
    private func pollResearch(bookId: String, oldIds: Set<String>,
                              oldUrls: Set<String>, attempt: Int) {
        // ~30s budget at 0.7s/tick ≈ 43 attempts.
        let maxAttempts = 43
        let interval = 0.7

        // Bail if the user already left this book's search (defensive).
        guard researchingBookId == bookId else { return }

        if attempt >= maxAttempts {
            finishResearch(bookId: bookId, refreshed: nil, exhausted: true)
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval) {
            let fresh = reloadEntry(bookId)
            DispatchQueue.main.async {
                // User navigated/aborted while the read was in flight → stop quietly.
                guard researchingBookId == bookId else { return }

                if let fresh = fresh {
                    let newIds = Set(fresh.candidates.map { $0.id })
                    let newUrls = Set(fresh.candidates.map { $0.url })
                    let changed = !fresh.candidates.isEmpty &&
                        (newIds != oldIds || newUrls != oldUrls)
                    if changed {
                        finishResearch(bookId: bookId, refreshed: fresh, exhausted: false)
                        return
                    }
                    if fresh.noMore {
                        finishResearch(bookId: bookId, refreshed: nil, exhausted: true)
                        return
                    }
                }
                // Not resolved yet → next tick.
                pollResearch(bookId: bookId, oldIds: oldIds, oldUrls: oldUrls,
                             attempt: attempt + 1)
            }
        }
    }

    /// Land a finished re-search on the main thread. `refreshed` non-nil → swap the
    /// book's candidates in and re-point the selection at the new auto/best pick.
    /// `exhausted` → tell the user nothing new was found (old covers stay).
    private func finishResearch(bookId: String, refreshed: CoverQueueEntry?, exhausted: Bool) {
        researchingBookId = nil

        if let fresh = refreshed,
           let pos = books.firstIndex(where: { $0.bookId == bookId }) {
            var next = books
            next[pos] = fresh
            books = next
            // Re-point the default at the fresh result. A confident re-search → the
            // new auto/best pick (else first web candidate). A non-confident one →
            // clear the explicit pick so the default falls back to the generated
            // cover (don't auto-sit on a possibly-wrong fresh web candidate).
            if fresh.confident {
                selections[bookId] = fresh.bestCandidateId ?? fresh.candidates.first?.id ?? ""
            } else {
                selections[bookId] = nil
            }
            onHeightMayChange()      // candidate count likely changed → refit
            return
        }

        if exhausted {
            let alert = NSAlert()
            alert.messageText = "Больше подходящих вариантов не нашлось"
            alert.informativeText = "Оставлены уже найденные обложки — выбери из них."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        onHeightMayChange()          // spinner row → button row, height shrinks back
    }

    // --- Actions: ‹ Назад · Утвердить · Вперёд › -----------------------------
    // The bar must fit three controls inside the 400px window. The side nav
    // buttons hug their content (chevron + short label); the center CTA takes a
    // higher layout priority and the remaining flexible width. The CTA label is
    // the short "Утвердить" (the screen context — "Выбор обложки" — already says
    // *what* is confirmed), so nothing truncates at 400px.
    private var actions: some View {
        HStack(spacing: Tokens.CS.linksGap) {
            // ‹ Назад — disabled on the first book.
            navButton(label: "Назад", icon: "chevron.left", iconLeading: true,
                      enabled: canGoBack, action: goBack)

            // Утвердить — primary gradient CTA; active whenever a valid cover is
            // selected (incl. the auto pick as-is). Flexible width + higher priority.
            confirmCTA
                .layoutPriority(1)

            // Вперёд › — disabled on the last book.
            navButton(label: "Вперёд", icon: "chevron.right", iconLeading: false,
                      enabled: canGoForward, action: goForward)
        }
        .padding(.horizontal, Tokens.CS.actionsPadH)
        .padding(.top, Tokens.CS.actionsPadTop)
        .padding(.bottom, Tokens.CS.actionsPadBottom)
    }

    /// The center "Утвердить" gradient button. When disabled it drops to a muted
    /// fill (same surface as the secondary nav buttons) and shows no shadow,
    /// matching the screen's "grey / inert" language.
    private var confirmCTA: some View {
        let enabled = canConfirm
        return Button(action: confirmCurrent) {
            HStack(spacing: Tokens.CS.ctaGap) {
                sfIcon("checkmark", size: 14, weight: .semibold)
                    .foregroundColor(enabled ? .white : Tokens.CS.linkText)
                Text("Утвердить")
                    .font(Tokens.CS.cta_)
                    .foregroundColor(enabled ? .white : Tokens.CS.linkText)
                    .trackingCompat(0.1)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity)
            .padding(Tokens.CS.ctaPad)
            .background(confirmBackground(enabled: enabled))
            .shadow(color: enabled
                        ? Color(.sRGB, red: 1, green: 61/255, blue: 90/255, opacity: 0.6)
                        : .clear,
                    radius: enabled ? 12 : 0, x: 0, y: enabled ? 10 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func confirmBackground(enabled: Bool) -> some View {
        if enabled {
            RoundedRectangle(cornerRadius: Tokens.CS.ctaRadius, style: .continuous)
                .fill(Tokens.CS.cta)
        } else {
            RoundedRectangle(cornerRadius: Tokens.CS.ctaRadius, style: .continuous)
                .fill(Tokens.CS.counterBg)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.CS.ctaRadius, style: .continuous)
                        .stroke(Tokens.CS.linkBorder, lineWidth: 1))
        }
    }

    /// A secondary nav button (Назад / Вперёд). When disabled it fades to ~40%
    /// opacity and takes no action (`.disabled`), per the screen's grey language.
    private func navButton(label: String, icon: String,
                           iconLeading: Bool, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        let color = Tokens.CS.linkText
        return Button(action: action) {
            HStack(spacing: Tokens.CS.linkGap) {
                if iconLeading {
                    sfIcon(icon, size: 13, weight: .semibold).foregroundColor(color)
                    Text(label).font(Tokens.CS.link).foregroundColor(color)
                } else {
                    Text(label).font(Tokens.CS.link).foregroundColor(color)
                    sfIcon(icon, size: 13, weight: .semibold).foregroundColor(color)
                }
            }
            // Hug content so the flexible center CTA gets the remaining width;
            // a fixed size keeps the side button from competing for an equal third.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, Tokens.CS.linkPadV)
            .padding(.horizontal, Tokens.CS.linkPadH)
            .background(
                RoundedRectangle(cornerRadius: Tokens.CS.linkRadius, style: .continuous)
                    .fill(Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.CS.linkRadius, style: .continuous)
                    .stroke(Tokens.CS.linkBorder, lineWidth: 1))
            // Make the whole padded box tappable, not just the Text glyphs (the
            // clear fill + stroked chevron are not hit-testable — same .patches/010
            // gotcha). Kept as a Button (not onTapGesture) so `.disabled` still gates
            // first/last book.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.4)
    }
}
