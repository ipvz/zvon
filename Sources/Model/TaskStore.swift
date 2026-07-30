import Foundation
import EventKit

/// A checklist sub-item of a task.
struct SubTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done: Bool = false
}

/// A task extracted from a meeting (by the LLM or a voice command) or added manually.
struct TaskItem: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case llm, voice, manual }
    var id = UUID()
    var text: String
    var owner: String?
    var due: String?
    var done: Bool = false
    var notes: String = ""
    var subtasks: [SubTask] = []
    var sessionId: UUID?
    var source: Source = .llm
    var createdAt: Date = Date()

    var subtitle: String {
        [owner, due].compactMap { $0 }.filter { !$0.isEmpty && $0.lowercased() != "null" }.joined(separator: " · ")
    }
    var subtaskProgress: (done: Int, total: Int) { (subtasks.filter(\.done).count, subtasks.count) }
}

@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()
    @Published private(set) var tasks: [TaskItem] = []

    // Interval reminder about OPEN tasks (a floating nudge + sound every N minutes).
    @Published var reminderEnabled: Bool { didSet { UserDefaults.standard.set(reminderEnabled, forKey: "taskReminderEnabled") } }
    @Published var reminderIntervalMin: Int { didSet { UserDefaults.standard.set(reminderIntervalMin, forKey: "taskReminderInterval") } }
    @Published var reminderSound: Bool { didSet { UserDefaults.standard.set(reminderSound, forKey: "taskReminderSound") } }

    private static let key = "tasks"
    private static let limit = 500

    init() {
        let d = UserDefaults.standard
        reminderEnabled = d.bool(forKey: "taskReminderEnabled")               // off by default; user opts in
        reminderIntervalMin = d.object(forKey: "taskReminderInterval") == nil ? 60 : max(5, d.integer(forKey: "taskReminderInterval"))
        reminderSound = d.object(forKey: "taskReminderSound") == nil ? true : d.bool(forKey: "taskReminderSound")
        load()
    }

    // MARK: Query

    var open: [TaskItem] { tasks.filter { !$0.done } }
    func forSession(_ id: UUID) -> [TaskItem] { tasks.filter { $0.sessionId == id } }

    // MARK: Mutate

    /// Merge the LLM's extracted action items for a session (dedup by normalized text so repeated
    /// debounced refreshes don't duplicate; keeps the freshest owner/due).
    func upsertFromActions(_ actions: [ActionItem], sessionId: UUID?) {
        for a in actions {
            let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let i = tasks.firstIndex(where: { $0.sessionId == sessionId && Self.norm($0.text) == Self.norm(text) }) {
                tasks[i].owner = a.ownerClean ?? tasks[i].owner
                tasks[i].due = a.dueClean ?? tasks[i].due
            } else {
                insert(TaskItem(text: text, owner: a.ownerClean, due: a.dueClean, sessionId: sessionId, source: .llm))
            }
        }
    }

    @discardableResult
    func addVoice(_ text: String, sessionId: UUID?) -> TaskItem? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        guard !tasks.contains(where: { $0.sessionId == sessionId && Self.norm($0.text) == Self.norm(t) }) else { return nil }
        let item = TaskItem(text: t, sessionId: sessionId, source: .voice)
        insert(item)
        return item
    }

    func addManual(text: String, owner: String? = nil, due: String? = nil, sessionId: UUID? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        insert(TaskItem(text: t, owner: owner, due: due, sessionId: sessionId, source: .manual))
    }

    func toggle(_ id: UUID) {
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].done.toggle(); save() }
    }
    func update(_ item: TaskItem) {
        if let i = tasks.firstIndex(where: { $0.id == item.id }) { tasks[i] = item; save() }
    }
    /// In-place edit — the view mutates fields (title/owner/due/notes/subtasks) through this.
    func edit(_ id: UUID, _ mutate: (inout TaskItem) -> Void) {
        if let i = tasks.firstIndex(where: { $0.id == id }) { mutate(&tasks[i]); save() }
    }
    func remove(_ id: UUID) { tasks.removeAll { $0.id == id }; save() }
    func clearDone() { tasks.removeAll { $0.done }; save() }

    private func insert(_ item: TaskItem) {
        tasks.insert(item, at: 0)
        if tasks.count > Self.limit { tasks.removeLast(tasks.count - Self.limit) }
        save()
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Export

    func exportMarkdown(_ items: [TaskItem]) -> String {
        items.map { t in
            var line = "- [\(t.done ? "x" : " ")] \(t.text)"
            let meta = [t.owner, t.due].compactMap { $0 }.filter { !$0.isEmpty }
            if !meta.isEmpty { line += " (" + meta.joined(separator: ", ") + ")" }
            return line
        }.joined(separator: "\n")
    }

    /// Push tasks to Apple Reminders (requires the Reminders permission). Returns nil on success,
    /// otherwise a human-readable error. Needs NSRemindersUsageDescription in Info.plist.
    func exportToReminders(_ items: [TaskItem]) async -> String? {
        let store = EKEventStore()
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToReminders()
            } else {
                granted = try await store.requestAccess(to: .reminder)
            }
            guard granted else { return "Нет доступа к Напоминаниям. Разрешите в системных настройках." }
            guard let list = store.defaultCalendarForNewReminders() else { return "Не найден список напоминаний." }
            for t in items where !t.done {
                let r = EKReminder(eventStore: store)
                r.title = t.text
                r.calendar = list
                if let owner = t.owner, !owner.isEmpty { r.notes = "Ответственный: \(owner)" }
                try store.save(r, commit: false)
            }
            try store.commit()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let items = try? JSONDecoder().decode([TaskItem].self, from: data) {
            tasks = items
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(tasks) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
