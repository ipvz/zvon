import Foundation

/// A saved prompt-template ("lens") run over a meeting's notes+transcript to produce an artifact
/// (follow-up email, minutes, PRD, coaching…). Built-ins ship with the app; users add their own.
struct Recipe: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var icon: String            // SF Symbol
    var prompt: String          // the instruction fed to the LLM over the meeting materials
    var builtin: Bool = false
}

@MainActor
final class RecipeStore: ObservableObject {
    static let shared = RecipeStore()
    @Published private(set) var custom: [Recipe] = []
    private static let key = "recipes"

    /// Curated defaults — each is just an instruction; the runner supplies the meeting content.
    static let builtins: [Recipe] = [
        Recipe(name: "Письмо-follow-up", icon: "envelope",
               prompt: "Составь вежливое деловое письмо по итогам встречи: короткое резюме договорённостей, ключевые решения, следующие шаги с ответственными и сроками. Деловой тон, готово к отправке. Без выдуманных фактов.",
               builtin: true),
        Recipe(name: "Протокол", icon: "doc.text",
               prompt: "Составь официальный протокол встречи: участники, обсуждённые темы по пунктам, принятые решения, поручения (кто · что · срок). Чётко и структурно.",
               builtin: true),
        Recipe(name: "Тезисы в Telegram", icon: "paperplane",
               prompt: "Составь компактную сводку для мессенджера: 3–6 буллетов главного + решения + задачи. Коротко, живо, без воды.",
               builtin: true),
        Recipe(name: "Черновик ТЗ / PRD", icon: "list.bullet.rectangle",
               prompt: "На основе обсуждения составь черновик ТЗ/PRD: цель, контекст и проблема, требования, объём, открытые вопросы, следующие шаги. Отметь, чего не хватает для полноты.",
               builtin: true),
        Recipe(name: "Разбор звонка", icon: "chart.bar.doc.horizontal",
               prompt: "Оцени встречу как коуч по продажам/переговорам по рубрике: выявлены ли потребности, заданы ли уточняющие вопросы, обработаны ли возражения, согласованы ли следующие шаги. По каждому пункту — короткая оценка, цитата-довод из встречи и совет на будущее.",
               builtin: true),
    ]

    var all: [Recipe] { Self.builtins + custom }

    init() { load() }

    func add(name: String, prompt: String, icon: String = "wand.and.stars") {
        let n = name.trimmingCharacters(in: .whitespaces), p = prompt.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !p.isEmpty else { return }
        custom.insert(Recipe(name: n, icon: icon, prompt: p), at: 0); save()
    }
    func update(_ r: Recipe) {
        if let i = custom.firstIndex(where: { $0.id == r.id }) { custom[i] = r; save() }
    }
    func remove(_ id: UUID) { custom.removeAll { $0.id == id }; save() }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let items = try? JSONDecoder().decode([Recipe].self, from: data) { custom = items }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(custom) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
