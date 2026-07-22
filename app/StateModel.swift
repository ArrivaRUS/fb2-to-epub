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

struct EngineAgentInfo: Codable, Equatable {
    var watchDir: String?

    enum CodingKeys: String, CodingKey {
        case watchDir = "watch_dir"
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
