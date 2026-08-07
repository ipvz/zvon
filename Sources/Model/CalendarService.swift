import Foundation
import EventKit

struct CalendarEvent {
    let title: String
    let start: Date
    let end: Date
    let attendees: [String]     // names / emails
    let joinLink: URL?          // Telemost / Zoom / Meet / Teams link, if found

    /// Stable-enough identity for "don't nag me about the same meeting twice".
    var key: String { "\(title)|\(Int(start.timeIntervalSince1970))" }
    var isCall: Bool { joinLink != nil }
}

/// Reads the system Calendar via EventKit. A Yandex calendar added to macOS as a CalDAV account
/// (Системные настройки → Учётные записи, caldav.yandex.ru + app-password) shows up here too — so we
/// get the meeting title / attendees / join-link with ZERO network code and stay local-first.
@MainActor
final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()

    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async -> Bool {
        if authorized { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The meeting in progress now (best-scored), else the nearest one starting within `lookahead`.
    /// On a crowded calendar full of recurring blockers, scoring picks the REAL meeting (a call link
    /// or invitees, short, not a «Занят»/«Focus» block) instead of just "the first overlapping event".
    func currentOrNext(lookahead: TimeInterval = 900) async -> CalendarEvent? {
        guard authorized else { return nil }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600),
                                            end: now.addingTimeInterval(lookahead + 3600), calendars: nil)
        let evs = store.events(matching: pred).filter { !$0.isAllDay && ($0.title?.isEmpty == false) }
        let ongoing = evs.filter { $0.startDate <= now && $0.endDate > now }
        let upcoming = evs.filter { $0.startDate > now && $0.startDate <= now.addingTimeInterval(lookahead) }
        let pool = ongoing.isEmpty ? upcoming : ongoing
        let best = pool.sorted { lhs, rhs in
            let sl = Self.score(lhs), sr = Self.score(rhs)
            if sl != sr { return sl > sr }                                    // higher meeting-likeness first
            return abs(lhs.startDate.timeIntervalSince(now)) < abs(rhs.startDate.timeIntervalSince(now))  // then nearest
        }.first
        guard let e = best else { return nil }
        let people = (e.attendees ?? []).compactMap { p -> String? in
            p.name ?? p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        return CalendarEvent(title: e.title ?? "", start: e.startDate, end: e.endDate,
                             attendees: people, joinLink: Self.joinLink(from: e))
    }

    /// How "real-meeting-like" an event is — so a call with invitees beats a recurring «Занят» blocker.
    private static let blockerWords = ["занят", "busy", "свободн", "free", "обед", "lunch", "отпуск",
                                       "dnd", "не беспок", "фокус", "focus", "недоступ", "болею", "sick"]
    private static func score(_ e: EKEvent) -> Int {
        var s = 0
        if joinLink(from: e) != nil { s += 5 }                      // has a call link → almost certainly the meeting
        if !(e.attendees ?? []).isEmpty { s += 3 }                  // has invitees → a real meeting, not a personal block
        let t = (e.title ?? "").lowercased()
        if blockerWords.contains(where: { t.contains($0) }) { s -= 5 }
        let hours = e.endDate.timeIntervalSince(e.startDate) / 3600
        if hours <= 1.0 { s += 2 } else if hours >= 4 { s -= 3 }    // a 30-min sync over an all-day-ish block
        return s
    }

    /// Conferencing hosts we recognise. Kept deliberately host-specific — a bare "https://…" in the
    /// notes is far more often a doc or a ticket than a call, and a false positive here nags the
    /// user about a meeting that isn't one.
    private static let linkPatterns = [
        "telemost\\.yandex\\.ru/[\\w-]+",
        "[a-z0-9.]*zoom\\.us/j/\\d+[^\\s]*",
        "meet\\.google\\.com/[a-z-]+",
        "teams\\.microsoft\\.com/[^\\s]+",
        "talk\\.kontur\\.ru/[^\\s]+",              // Контур.Толк
        "jazz\\.sber\\.ru/[^\\s]+",                // SberJazz
        "[a-z0-9.-]*mts-link\\.ru/[^\\s]+",        // МТС Линк (ex-Webinar.ru)
        "[a-z0-9.-]*dion\\.vc/[^\\s]+",            // Dion
        "meet\\.jit\\.si/[^\\s]+",
        "[a-z0-9.-]*whereby\\.com/[^\\s]+",
        "[a-z0-9.-]*webex\\.com/[^\\s]+",
        "[a-z0-9.-]*pruffme\\.com/[^\\s]+",
        "videomost\\.com/[^\\s]+",
        "calls\\.vk\\.com/[^\\s]+",
        "[a-z0-9.-]*ktalk\\.ru/[^\\s]+",           // Контур.Толк (короткий домен)
    ]
    private static func joinLink(from e: EKEvent) -> URL? {
        if let u = e.url, linkPatterns.contains(where: { u.absoluteString.range(of: $0, options: .regularExpression) != nil }) { return u }
        let hay = [e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: "\n")
        for p in linkPatterns {
            if let r = hay.range(of: p, options: .regularExpression) {
                let s = String(hay[r])
                return URL(string: s.hasPrefix("http") ? s : "https://" + s)
            }
        }
        return nil
    }
}
