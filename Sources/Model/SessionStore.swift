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

    private static let key = "sessions"
    private static let limit = 300

    static let time: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "HH:mm"; return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM"; return f
    }()

    init() { load() }

    // MARK: Add

    func addMeeting(id: UUID = UUID(), title: String, date: Date, durationSec: Double, hasSummary: Bool,
                    transcript: String, noteSummary: [String]?,
                    noteDecisions: [String]? = nil, noteTopics: [String]? = nil) {
        insert(SessionRecord(id: id, kind: .meeting, title: title, date: date, durationSec: durationSec,
                             hasSummary: hasSummary, transcript: transcript, noteSummary: noteSummary,
                             noteDecisions: noteDecisions, noteTopics: noteTopics))
    }

    func addDictation(text: String, date: Date) {
        insert(SessionRecord(kind: .dictation, title: text, date: date))
    }

    func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    private func insert(_ record: SessionRecord) {
        sessions.insert(record, at: 0)
        if sessions.count > Self.limit { sessions.removeLast(sessions.count - Self.limit) }
        save()
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

    // MARK: Persistence (JSON in UserDefaults — fine for this volume)

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let items = try? JSONDecoder().decode([SessionRecord].self, from: data) else { return }
        sessions = items
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
