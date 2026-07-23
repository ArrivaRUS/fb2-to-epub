// StateModel — the UI's read-only view of the engine's state.json snapshot.
//
// Contract (arch/plans-ui.md, "Контракты данных"):
//   ~/Library/Application Support/fb2-to-epub/state/state.json
//   { schema, agent:{watch_dir},
//     totals:{converted_total, today, failed_today},
//     recent:[ ≤50 {src,dst,ts,status} ],   // newest-first
//     last_conversion }
//
// The watcher OWNS this file and rewrites it atomically (tmp -> rename); the app
// only ever reads it. Decoding is defensive: a missing file / partial write /
// unknown extra keys must degrade to an empty-but-valid model, never crash.

import Foundation

// MARK: - Wire model (matches state.json exactly)

struct ConversionEntry: Codable, Identifiable, Equatable {
    let src: String      // basename, e.g. "роман.fb2"
    let dst: String      // basename, e.g. "роман.epub"
    let ts: String       // ISO-8601 UTC, e.g. "2026-06-25T12:04:00Z"
    let status: String   // "ok" | "failed"

    var isOK: Bool { status == "ok" }

    /// Stable id for SwiftUI lists. ts+dst is unique enough for a ≤50 list; if a
    /// rare collision happens the list just reuses a row identity (harmless).
    var id: String { "\(ts)|\(dst)" }
}

struct EngineTotals: Codable, Equatable {
    var convertedTotal: Int
    var today: Int
    var failedToday: Int

    enum CodingKeys: String, CodingKey {
        case convertedTotal = "converted_total"
        case today
        case failedToday = "failed_today"
    }

    static let empty = EngineTotals(convertedTotal: 0, today: 0, failedToday: 0)

    // Tolerate a missing totals block / missing individual keys.
    init(convertedTotal: Int, today: Int, failedToday: Int) {
        self.convertedTotal = convertedTotal
        self.today = today
        self.failedToday = failedToday
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        convertedTotal = (try? c.decode(Int.self, forKey: .convertedTotal)) ?? 0
        today          = (try? c.decode(Int.self, forKey: .today)) ?? 0
        failedToday    = (try? c.decode(Int.self, forKey: .failedToday)) ?? 0
    }
}

/// The agent's self-reported access to the watch folder (v1.0.1, D46). The agent
/// listdir()s WATCH_DIR every run and publishes this tristate; the app only reads it.
///   • `.ok`      — folder readable (conversion can proceed)
///   • `.denied`  — TCC/permissions block the background agent (needs Full Disk Access)
///   • `.missing` — folder deleted / path broken (NOT an FDA case; no UI in v1.0.1)
/// A plain enum decoded via rawValue string so an ABSENT field or an UNKNOWN future
/// value both degrade to `nil` (⇒ no FDA surface), never a decode failure.
enum FolderAccess: String, Codable, Equatable {
    case ok
    case denied
    case missing
}

struct EngineAgentInfo: Codable, Equatable {
    var watchDir: String?
    /// NEW (v1.0.1): absent on an old agent / unknown value → nil → no FDA surface.
    var folderAccess: FolderAccess?
    /// NEW (v1.0.1): ISO-8601 UTC ("…Z") timestamp of the last probe. The recheck
    /// flow keys off a CHANGE in this value (proof of a fresh check).
    var folderAccessTs: String?

    enum CodingKeys: String, CodingKey {
        case watchDir = "watch_dir"
        case folderAccess = "folder_access"
        case folderAccessTs = "folder_access_ts"
    }

    init(watchDir: String?, folderAccess: FolderAccess? = nil, folderAccessTs: String? = nil) {
        self.watchDir = watchDir
        self.folderAccess = folderAccess
        self.folderAccessTs = folderAccessTs
    }

    // Tolerant decode: a garbage / non-string / unknown folder_access degrades to
    // nil WITHOUT dropping watch_dir (a synthesized decoder would throw on a bad
    // value and lose the whole agent block). Forward-compatible with a future agent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        watchDir = try? c.decodeIfPresent(String.self, forKey: .watchDir)
        if let raw = try? c.decodeIfPresent(String.self, forKey: .folderAccess) {
            folderAccess = FolderAccess(rawValue: raw)   // unknown string → nil
        } else {
            folderAccess = nil                            // absent / non-string → nil
        }
        folderAccessTs = try? c.decodeIfPresent(String.self, forKey: .folderAccessTs)
    }
}

/// Live batch progress for the hero ring. Written by the engine at the top level
/// of state.json as `"batch": {"active", "total", "done"}` while it processes a
/// drop of new files. ABSENT in older / idle state.json — the decoder below maps
/// that to `nil` ("no active batch"), so the ring shows a calm full circle.
/// `done`/`total` count files in the current run; `progress` is done/total.
struct EngineBatch: Codable, Equatable {
    var active: Bool
    var total: Int
    var done: Int

    enum CodingKeys: String, CodingKey {
        case active
        case total
        case done
    }

    init(active: Bool, total: Int, done: Int) {
        self.active = active
        self.total = total
        self.done = done
    }

    // Tolerate missing individual keys inside an otherwise-present batch object.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = (try? c.decode(Bool.self, forKey: .active)) ?? false
        total  = (try? c.decode(Int.self,  forKey: .total)) ?? 0
        done   = (try? c.decode(Int.self,  forKey: .done)) ?? 0
    }

    /// Fraction filled, clamped to 0...1. No batch / total==0 → 1.0 (full ring):
    /// nothing is in flight, so the ring rests complete rather than empty.
    var progress: Double {
        guard total > 0 else { return 1.0 }
        return min(1.0, max(0.0, Double(done) / Double(total)))
    }
}

/// The full snapshot. Extra keys present in the JSON are ignored by Codable —
/// EXCEPT the watcher's private "_today_date" day stamp, which we DO decode (as
/// `todayDate`) so the app can make the "за сегодня" reset day-aware: a baseline
/// captured today must expire once the watcher rolls the day over (see
/// EngineClient+Status.resetStats / loadState). We never WRITE this field (D13).
struct EngineState: Codable, Equatable {
    var schema: Int
    var agent: EngineAgentInfo
    var totals: EngineTotals
    var recent: [ConversionEntry]
    var lastConversion: ConversionEntry?

    /// Current batch progress for the hero ring (top-level `batch` in state.json).
    /// nil when the engine has not written it (older state / no active drop) — the
    /// ring treats nil as "all done" and shows a calm full circle. Read-only.
    var batch: EngineBatch?

    /// The watcher's local-day stamp ("yyyy-MM-dd", via Python `datetime.now()`),
    /// i.e. the day `totals.today` is currently counting. nil when the watcher has
    /// not written it yet (e.g. a fresh / pre-day-stamp state.json). Read-only.
    var todayDate: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case agent
        case totals
        case recent
        case lastConversion = "last_conversion"
        case batch
        case todayDate = "_today_date"
    }

    static let empty = EngineState(
        schema: 1,
        agent: EngineAgentInfo(watchDir: nil),
        totals: .empty,
        recent: [],
        lastConversion: nil
    )

    init(schema: Int, agent: EngineAgentInfo, totals: EngineTotals,
         recent: [ConversionEntry], lastConversion: ConversionEntry?,
         batch: EngineBatch? = nil,
         todayDate: String? = nil) {
        self.schema = schema
        self.agent = agent
        self.totals = totals
        self.recent = recent
        self.lastConversion = lastConversion
        self.batch = batch
        self.todayDate = todayDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema         = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        agent          = (try? c.decode(EngineAgentInfo.self, forKey: .agent)) ?? EngineAgentInfo(watchDir: nil)
        totals         = (try? c.decode(EngineTotals.self, forKey: .totals)) ?? .empty
        recent         = (try? c.decode([ConversionEntry].self, forKey: .recent)) ?? []
        lastConversion = try? c.decodeIfPresent(ConversionEntry.self, forKey: .lastConversion)
        batch          = try? c.decodeIfPresent(EngineBatch.self, forKey: .batch)
        todayDate      = try? c.decodeIfPresent(String.self, forKey: .todayDate)
    }
}

// MARK: - FDA recheck decision (pure; shared by the host + its unit test)

/// The outcome of a «Проверить снова» round-trip, decided purely from timestamps +
/// the fresh access value. Extracted so the shipping host (AppDelegate) and the unit
/// test drive the SAME logic (mirrors how the sticky-batch test extracts batch_state):
/// the recheck accepts a result ONLY when a FRESH `folder_access_ts` (≠ the one at
/// press time) has landed — proof the agent actually re-probed, not a stale read.
enum FolderRecheckOutcome: Equatable {
    case pending       // not in flight, or no fresh probe yet → keep waiting
    case stillDenied   // fresh probe, still denied
    case cleared       // fresh probe, access no longer denied → drop the card
}

/// The Status content router's CJM priority (arch/plan-fda-synthesis «Развилка»,
/// resolved: engine → access → normal). Extracted as a pure function so StatusView
/// and its unit test share ONE ordering — a drift (e.g. FDA before engine) breaks
/// the test. `engineOnboardingActive` = an EngineSetupCard phase should show (active
/// install / no engine); `folderAccessActive` = the agent reported denied.
enum StatusSurface: Equatable { case engineOnboarding, folderAccess, normal }

enum StatusRouter {
    static func surface(engineOnboardingActive: Bool, folderAccessActive: Bool) -> StatusSurface {
        if engineOnboardingActive { return .engineOnboarding }  // 1. engine wins
        if folderAccessActive     { return .folderAccess }      // 2. then access
        return .normal                                          // 3. else normal Status
    }
}

enum FolderRecheck {
    /// - pressedTs: the `folder_access_ts` captured when «Проверить снова» was pressed
    ///   (nil ⇒ no recheck in flight).
    /// - currentTs: the `folder_access_ts` in the freshly-read state (nil ⇒ none yet).
    /// - currentAccess: the freshly-read `folder_access`.
    static func evaluate(pressedTs: String?, currentTs: String?,
                         currentAccess: FolderAccess?) -> FolderRecheckOutcome {
        guard let pressed = pressedTs else { return .pending }        // not in flight
        guard let cur = currentTs, cur != pressed else { return .pending } // no fresh probe
        return currentAccess == .denied ? .stillDenied : .cleared
    }

    /// Refresh-cycle rule for a STICKY terminal recheck card (stillDenied/timeout). Once
    /// the recheck coordinator tears down it PINS that terminal state into the store, so
    /// a later live flip of the agent flag back to ok/missing would stay hidden behind
    /// the pinned card — the surface never dissolves on its own (review A1). This decides
    /// whether to dissolve it now: dissolve the moment the card is terminal AND the live
    /// flag is no longer `.denied`. When still `.denied`, keep the richer terminal
    /// feedback; a non-terminal card (`.checking`/none) is driven by `evaluate()`, not here.
    static func terminalRecheckDissolves(isTerminal: Bool, liveAccess: FolderAccess?) -> Bool {
        isTerminal && liveAccess != .denied
    }
}

// MARK: - Loader

/// Reads state.json from the engine's Application Support dir. All paths derive
/// from `home`, so tests can point this at a throwaway HOME and never touch the
/// real file.
struct StateStore {
    let home: String

    init(home: String = EngineHome.resolve()) {
        self.home = home
    }

    /// `~/Library/Application Support/fb2-to-epub/state/state.json`
    var stateFilePath: String {
        "\(home)/Library/Application Support/fb2-to-epub/state/state.json"
    }

    /// Load + decode. Returns `.empty` for any failure (absent / unreadable /
    /// malformed) so the Status screen always has a valid model to render.
    func load() -> EngineState {
        let url = URL(fileURLWithPath: stateFilePath)
        guard let data = try? Data(contentsOf: url) else { return .empty }
        guard let state = try? JSONDecoder().decode(EngineState.self, from: data) else {
            return .empty
        }
        return state
    }
}

// MARK: - Relative time ("… назад")

enum RelativeTime {
    /// Parse an ISO-8601 UTC timestamp ("...Z"). Returns nil on malformed input.
    static func parse(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return d }
        // Fallback: allow fractional seconds if a future writer adds them.
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)
    }

    /// Russian short "ago" phrase: "только что" / "N мин назад" / "N ч назад" /
    /// "N дн назад". `now` is injectable for deterministic tests.
    static func ago(_ iso: String, now: Date = Date()) -> String? {
        guard let date = parse(iso) else { return nil }
        let secs = max(0, now.timeIntervalSince(date))
        switch secs {
        case ..<60:
            return "только что"
        case ..<3600:
            let m = Int(secs / 60)
            return "\(m) \(pluralMinutes(m)) назад"
        case ..<86_400:
            let h = Int(secs / 3600)
            return "\(h) \(pluralHours(h)) назад"
        default:
            let d = Int(secs / 86_400)
            return "\(d) \(pluralDays(d)) назад"
        }
    }

    /// Local wall-clock "HH:mm" for the conversion list's right column.
    static func clock(_ iso: String) -> String {
        guard let date = parse(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // Russian plural rules (1 минута / 2 минуты / 5 минут).
    private static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod100 = n % 100
        let mod10 = n % 10
        if mod100 >= 11 && mod100 <= 14 { return many }
        switch mod10 {
        case 1: return one
        case 2, 3, 4: return few
        default: return many
        }
    }
    private static func pluralMinutes(_ n: Int) -> String { plural(n, "мин", "мин", "мин") }
    private static func pluralHours(_ n: Int) -> String { plural(n, "ч", "ч", "ч") }
    private static func pluralDays(_ n: Int) -> String { plural(n, "дн", "дн", "дн") }
}
