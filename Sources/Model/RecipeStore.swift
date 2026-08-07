import Foundation

/// A saved prompt-template ("lens") run over a meeting's notes+transcript to produce an artifact
/// (follow-up email, minutes, PRD, coaching…). The curated set is seeded on first run; from then on
/// every recipe — seeded or user-made — is fully editable and deletable.
struct Recipe: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var icon: String            // SF Symbol
    var prompt: String          // the instruction fed to the LLM over the meeting materials
    var builtin: Bool = false   // seeded default (kept for the icon default / "restore defaults"); still editable
}

@MainActor
final class RecipeStore: ObservableObject {
    static let shared = RecipeStore()
    @Published private(set) var recipes: [Recipe] = []
    private static let key = "recipes"
    private static let seededKey = "recipesSeeded"

    /// Curated defaults — each is just an instruction; the runner supplies the meeting content.
    static let builtins: [Recipe] = [
        Recipe(name: "Письмо-follow-up", icon: "envelope",
               prompt: "Составь вежливое деловое письмо по итогам встречи: короткое резюме договорённостей, ключевые решения, следующие шаги с ответственными и сроками. Деловой тон, готово к отправке. Без выдуманных фактов.",
               builtin: true),
        Recipe(name: "Протокол", icon: "doc.text",
               prompt: """
               Составь официальный протокол встречи.

               Шапка: название, дата и время проведения, длительность, участники, время формирования \
               протокола. Все эти данные возьми из блока материалов дословно — не вычисляй и не выдумывай.

               Далее разделы:
               1. Хронология — ключевые моменты в порядке, в каком они прозвучали, каждый со временем \
               в формате [ЧЧ:ММ]. Только то, где что-то решили, о чём-то договорились, подняли новую \
               тему или зафиксировали возражение. Это не пересказ расшифровки целиком.
               2. Обсуждённые темы по пунктам.
               3. Принятые решения.
               4. Поручения: кто · что · срок.

               Время бери ТОЛЬКО из квадратных скобок в расшифровке. Если у реплики времени нет — \
               не указывай его и ничего не додумывай. Чётко, структурно, без выдуманных фактов.
               """,
               builtin: true),
        Recipe(name: "Тезисы в Telegram", icon: "paperplane",
               prompt: """
               Составь компактную сводку для мессенджера. Первой строкой — название встречи, дата и \
               время из материалов. Затем 3–6 буллетов главного, решения и задачи. Ключевые моменты \
               помечай временем [ЧЧ:ММ] из расшифровки, если оно там есть. Коротко, живо, без воды \
               и без выдуманных фактов.
               """,
               builtin: true),
        Recipe(name: "Черновик ТЗ / PRD", icon: "list.bullet.rectangle",
               prompt: "На основе обсуждения составь черновик ТЗ/PRD: цель, контекст и проблема, требования, объём, открытые вопросы, следующие шаги. Отметь, чего не хватает для полноты.",
               builtin: true),
        Recipe(name: "Разбор звонка", icon: "chart.bar.doc.horizontal",
               prompt: "Оцени встречу как коуч по продажам/переговорам по рубрике: выявлены ли потребности, заданы ли уточняющие вопросы, обработаны ли возражения, согласованы ли следующие шаги. По каждому пункту — короткая оценка, цитата-довод из встречи и совет на будущее.",
               builtin: true),
    ]

    /// Kept for source compatibility; the list is now one flat editable collection.
    var all: [Recipe] { recipes }
    var custom: [Recipe] { recipes }

    init() { load() }

    func add(name: String, prompt: String, icon: String = "wand.and.stars") {
        let n = name.trimmingCharacters(in: .whitespaces), p = prompt.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !p.isEmpty else { return }
        recipes.insert(Recipe(name: n, icon: icon, prompt: p), at: 0); save()
    }

    /// Insert or update — the editor doesn't need to know which.
    func upsert(_ r: Recipe) {
        let n = r.name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        var r = r; r.name = n; r.prompt = r.prompt.trimmingCharacters(in: .whitespaces)
        if let i = recipes.firstIndex(where: { $0.id == r.id }) { recipes[i] = r } else { recipes.append(r) }
        save()
    }

    func update(_ r: Recipe) { upsert(r) }
    func remove(_ id: UUID) { recipes.removeAll { $0.id == id }; save() }

    /// Add back any curated default whose name is missing (never duplicates or overwrites edits).
    func restoreDefaults() {
        let present = Set(recipes.map { $0.name.lowercased() })
        let missing = Self.builtins.filter { !present.contains($0.name.lowercased()) }
        guard !missing.isEmpty else { return }
        recipes.append(contentsOf: missing); save()
    }

    /// Prompts shipped by earlier versions. A seeded recipe still carrying one of these verbatim was
    /// never touched by the user, so upgrading it in place is safe; anything else is their own
    /// wording and is left exactly as it is.
    private static let supersededPrompts: [String: Set<String>] = [
        "протокол": [
            "Составь официальный протокол встречи: участники, обсуждённые темы по пунктам, принятые решения, поручения (кто · что · срок). Чётко и структурно.",
        ],
        "тезисы в telegram": [
            "Составь компактную сводку для мессенджера: 3–6 буллетов главного + решения + задачи. Коротко, живо, без воды.",
        ],
    ]

    /// Seeded recipes live in UserDefaults from first run, so editing `builtins` alone would never
    /// reach an existing install. Rewrite only the ones the user never edited.
    private func upgradeUneditedBuiltins() {
        var changed = false
        for i in recipes.indices {
            let key = recipes[i].name.lowercased()
            guard let old = Self.supersededPrompts[key],
                  old.contains(recipes[i].prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let fresh = Self.builtins.first(where: { $0.name.lowercased() == key })
            else { continue }
            recipes[i].prompt = fresh.prompt
            changed = true
        }
        if changed { save() }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let items = try? JSONDecoder().decode([Recipe].self, from: data) {
            recipes = items
        }
        // First run (or upgrading from the old builtins-were-separate scheme): seed the curated set into
        // the editable list, once, so they can be edited/deleted like any other recipe.
        if !UserDefaults.standard.bool(forKey: Self.seededKey) {
            let present = Set(recipes.map { $0.name.lowercased() })
            recipes.append(contentsOf: Self.builtins.filter { !present.contains($0.name.lowercased()) })
            UserDefaults.standard.set(true, forKey: Self.seededKey)
            save()
        }
        upgradeUneditedBuiltins()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(recipes) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
