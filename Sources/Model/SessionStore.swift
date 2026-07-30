import Foundation

/// One entry in the History/Library: a finished meeting or a dictation snippet. Both aggregate
/// here automatically so nothing is lost (spec §8).
struct SessionRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case meeting, dictation }
    var id = UUID()
    var kind: Kind
    var title: String
    var date: Date
    var durationSec: Double?
    var hasSummary: Bool = false
    var transcript: String?
    var noteSummary: [String]?    // cached ✦ Итог bullets, if any
    var noteDecisions: [String]?  // «Решения» section, persisted so it survives after the meeting
    var noteTopics: [String]?     // «Темы» tags
    var userNotes: String? = nil  // «Мои заметки» — the user's own notes (optionally AI-enriched)

    /// Sidebar sub-line: "11:20 · 41 мин" for meetings, "Диктовка · 13:05" for snippets.
    var subtitle: String {
        switch kind {
        case .meeting:
            let t = SessionStore.time.string(from: date)
            if let d = durationSec { return "\(t) · \(Int((d / 60).rounded())) мин" }
            return t
        case .dictation:
            return "Диктовка · \(SessionStore.time.string(from: date))"
        }
    }
}

enum SessionFilter: String, CaseIterable, Identifiable { case all, meetings, dictation
    var id: String { rawValue }
    var title: String { self == .all ? "Все" : self == .meetings ? "Встречи" : "Диктовка" }
}

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()
    @Published private(set) var sessions: [SessionRecord] = []

    private static let key = "sessions"   // legacy UserDefaults blob — read once for migration, then left as backup
    private let db: SessionDB?

    static let time: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "HH:mm"; return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM"; return f
    }()

    init() {
        db = SessionDB(path: Self.dbURL().path)
        migrateFromUserDefaultsIfNeeded()
        sessions = db?.all() ?? Self.legacyLoad()   // SQLite is source of truth; fall back to the old blob only if the DB failed to open
    }

    // MARK: Add

    func addMeeting(id: UUID = UUID(), title: String, date: Date, durationSec: Double, hasSummary: Bool,
                    transcript: String, noteSummary: [String]?,
                    noteDecisions: [String]? = nil, noteTopics: [String]? = nil, userNotes: String? = nil) {
        insert(SessionRecord(id: id, kind: .meeting, title: title, date: date, durationSec: durationSec,
                             hasSummary: hasSummary, transcript: transcript, noteSummary: noteSummary,
                             noteDecisions: noteDecisions, noteTopics: noteTopics, userNotes: userNotes))
    }

    /// Edit a past record's own notes (write-back for the «Мои заметки» editor). Reassigns the array
    /// element so @Published fires, and upserts the row (db.insert is INSERT OR REPLACE).
    func updateUserNotes(_ id: UUID, _ text: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].userNotes = text.isEmpty ? nil : text
        db?.insert(sessions[i])
    }

    func addDictation(text: String, date: Date) {
        insert(SessionRecord(kind: .dictation, title: text, date: date))
    }

    func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        db?.delete(id)
        SpaceStore.shared.purge(meeting: id)   // drop it from any space it was tagged into
    }

    /// No cap: SQLite scales to tens of thousands of rows, and a single-row INSERT is cheap (unlike
    /// re-serialising the whole array). A flood of dictations can never again evict meetings.
    private func insert(_ record: SessionRecord) {
        sessions.insert(record, at: 0)
        db?.insert(record)
    }

    // MARK: Query

    /// Day-grouped, filtered, searched — reverse-chronological. Returns [(day label, rows)].
    func grouped(filter: SessionFilter, search: String) -> [(String, [SessionRecord])] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = sessions.filter { r in
            switch filter {
            case .all: break
            case .meetings: if r.kind != .meeting { return false }
            case .dictation: if r.kind != .dictation { return false }
            }
            if q.isEmpty { return true }
            return r.title.lowercased().contains(q) || (r.transcript?.lowercased().contains(q) ?? false)
        }
        var order: [String] = []
        var map: [String: [SessionRecord]] = [:]
        for r in rows {
            let key = Self.dayLabel(r.date)
            if map[key] == nil { map[key] = []; order.append(key) }
            map[key]?.append(r)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Сегодня" }
        if cal.isDateInYesterday(date) { return "Вчера" }
        return day.string(from: date)
    }

    // MARK: Persistence (SQLite — see SessionDB)

    private static func dbURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ZVON", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.sqlite")
    }

    private static func legacyLoad() -> [SessionRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([SessionRecord].self, from: data) else { return [] }
        return items
    }

    /// One-time lift of the old UserDefaults blob into SQLite. The blob is left in place as a backup —
    /// harmless, and the only copy of pre-migration data.
    private func migrateFromUserDefaultsIfNeeded() {
        guard let db, db.isEmpty else { return }
        let legacy = Self.legacyLoad()
        guard !legacy.isEmpty else { return }
        for r in legacy { db.insert(r) }
        DebugLog.log("SessionStore: migrated \(legacy.count) records from UserDefaults → SQLite")
    }
}
