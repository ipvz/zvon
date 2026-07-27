import Foundation
import AppKit

/// A user-defined voice command: a spoken phrase (+ aliases) → an action. The LLM is NOT in the
/// hot path — matching is deterministic and local (Raycast-Quicklinks / Talon style), so it's
/// instant, offline, and can never escalate to something outside this registry.
struct CommandItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case openURL, openApp, runShortcut
        var id: String { rawValue }
        var title: String {
            switch self {
            case .openURL:     return "Открыть сайт"
            case .openApp:     return "Открыть приложение"
            case .runShortcut: return "Запустить Shortcut"
            }
        }
        var valueLabel: String {
            switch self {
            case .openURL:     return "Адрес сайта"
            case .openApp:     return "Название приложения"
            case .runShortcut: return "Название Shortcut"
            }
        }
        var icon: String {
            switch self {
            case .openURL:     return "safari"
            case .openApp:     return "app"
            case .runShortcut: return "bolt"
            }
        }
    }

    var id = UUID()
    var phrase: String                 // primary spoken phrase, e.g. "почта"
    var aliases: [String] = []         // extra ways to say it: "gmail", "мейл"
    var kind: Kind = .openURL
    var value: String = ""             // URL / app name / shortcut name
    var needsConfirm: Bool = false     // ask before running (for anything with a side effect)

    /// All the ways this command can be spoken, normalized lowercase.
    var spokenForms: [String] {
        ([phrase] + aliases).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
}

@MainActor
final class CommandStore: ObservableObject {
    static let shared = CommandStore()
    private static let key = "voiceCommands"

    @Published private(set) var commands: [CommandItem] = []

    private init() {
        load()
        if commands.isEmpty { seed() }
    }

    // MARK: CRUD

    func add(_ c: CommandItem) { commands.append(c); save() }
    func remove(_ id: UUID) { commands.removeAll { $0.id == id }; save() }
    func update(_ id: UUID, _ mutate: (inout CommandItem) -> Void) {
        guard let i = commands.firstIndex(where: { $0.id == id }) else { return }
        mutate(&commands[i]); save()
    }
    func addBlank() { commands.append(CommandItem(phrase: "", kind: .openURL)); save() }

    // MARK: Matching — the spoken remainder after a command verb ("открой …") → the best command.

    /// Best command whose phrase/alias matches the spoken target. Word-level, stem-tolerant: every
    /// word of a form must match some word of the target, where a "match" allows Russian declension
    /// («почту»≈«почта», «календарь»≈«календаре») via a shared prefix. Longest form wins so
    /// "рабочая почта" beats "почта".
    func match(_ target: String) -> CommandItem? {
        let tWords = Self.words(target)
        guard !tWords.isEmpty else { return nil }
        var best: (CommandItem, Int)?
        for c in commands where !c.value.trimmingCharacters(in: .whitespaces).isEmpty {
            for form in c.spokenForms where !form.isEmpty {
                let fWords = Self.words(form)
                guard !fWords.isEmpty else { continue }
                let hit = fWords.allSatisfy { fw in tWords.contains { Self.wordMatch($0, fw) } }
                if hit {
                    let score = form.count
                    if best == nil || score > best!.1 { best = (c, score) }
                }
            }
        }
        return best?.0
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Two words match if equal, or one is a prefix of the other, or they share a long-enough prefix
    /// (tolerates a differing case ending: «почт-у» / «почт-а», «календар-ь» / «календар-е»).
    private static func wordMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let aa = Array(a), bb = Array(b)
        let m = min(aa.count, bb.count)
        if m < 3 { return a == b }
        var p = 0
        while p < m, aa[p] == bb[p] { p += 1 }
        if p == m { return true }                      // one is a prefix of the other
        return p >= max(3, m - 2)                       // shared stem, differ only in the ending
    }

    // MARK: Execution — deterministic, allowlisted actions only. No free-form shell.

    /// Perform the command. Returns a short label for the confirmation toast.
    @discardableResult
    func run(_ c: CommandItem) -> String {
        let value = c.value.trimmingCharacters(in: .whitespaces)
        switch c.kind {
        case .openURL:
            var s = value
            if !s.contains("://") { s = "https://" + s }
            if let u = URL(string: s) { NSWorkspace.shared.open(u) }
        case .openApp:
            if let app = Self.appURL(named: value) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                    if let err { DebugLog.log("command openApp error: \(err.localizedDescription)") }
                }
            } else {
                DebugLog.log("command openApp: «\(value)» not found in /Applications → open -a")
                Self.shell("/usr/bin/open", ["-a", value])   // fallback: Launch Services may find it elsewhere
            }
        case .runShortcut:
            Self.shell("/usr/bin/shortcuts", ["run", value])
        }
        DebugLog.log("command run: \(c.kind.rawValue) «\(value)»")
        return c.phrase.isEmpty ? value : c.phrase
    }

    /// Installed apps (basename without ".app"), sorted — for the app picker in the command editor,
    /// so a command targets a real app, not a typo.
    static func installedApps() -> [String] {
        let dirs = ["/Applications", "\(NSHomeDirectory())/Applications", "/System/Applications", "/System/Applications/Utilities"]
        let fm = FileManager.default
        var names = Set<String>()
        for d in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for it in items where it.hasSuffix(".app") { names.insert(String(it.dropLast(4))) }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Resolve an app by (typed) name in the standard app folders — exact "<name>.app" first, then a
    /// case-insensitive contains, so "Notion" / "notion" / "safari" all find the bundle.
    private static func appURL(named name: String) -> URL? {
        let n = name.lowercased()
        guard !n.isEmpty else { return nil }
        let dirs = ["/Applications", "\(NSHomeDirectory())/Applications", "/System/Applications", "/System/Applications/Utilities"]
        let fm = FileManager.default
        for d in dirs {
            let u = URL(fileURLWithPath: d).appendingPathComponent("\(name).app")
            if fm.fileExists(atPath: u.path) { return u }
        }
        for d in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: d) else { continue }
            if let hit = items.first(where: { $0.hasSuffix(".app") && $0.dropLast(4).lowercased().contains(n) }) {
                return URL(fileURLWithPath: d).appendingPathComponent(hit)
            }
        }
        return nil
    }

    private static func shell(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() } catch { DebugLog.log("command shell error: \(error)") }
    }

    // MARK: Persistence

    private func seed() {
        commands = [
            CommandItem(phrase: "почта", aliases: ["gmail", "мейл"], kind: .openURL, value: "https://mail.google.com"),
            CommandItem(phrase: "календарь", aliases: [], kind: .openURL, value: "https://calendar.google.com"),
            CommandItem(phrase: "заметки", aliases: ["notion"], kind: .openApp, value: "Notion"),
        ]
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let items = try? JSONDecoder().decode([CommandItem].self, from: data) else { return }
        commands = items
    }
    private func save() {
        if let data = try? JSONEncoder().encode(commands) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
