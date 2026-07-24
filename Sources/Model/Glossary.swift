import Foundation

/// One user vocabulary entry: the correct spelling + optional misheard variants the model tends to
/// produce. Used two ways — local fuzzy correction of the transcript, and a hint in the LLM prompt.
struct GlossaryTerm: Codable, Identifiable, Equatable {
    var id = UUID()
    var canonical: String                 // "Kubernetes", "PostgreSQL", "Максим Иванов"
    var variants: [String] = []           // ["кубернетис", "кубернетес"]
    var enabled: Bool = true
}

@MainActor
final class GlossaryStore: ObservableObject {
    static let shared = GlossaryStore()
    @Published private(set) var terms: [GlossaryTerm] = []
    @Published var correctionEnabled: Bool {           // layer 1: local fuzzy fix
        didSet { UserDefaults.standard.set(correctionEnabled, forKey: "glossaryCorrection") }
    }
    @Published var llmInjectEnabled: Bool {            // layer 2: inject into the LLM prompt
        didSet { UserDefaults.standard.set(llmInjectEnabled, forKey: "glossaryLLMInject") }
    }

    private static let key = "glossaryTerms"
    private static func boolDefault(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }

    init() {
        correctionEnabled = Self.boolDefault("glossaryCorrection")
        llmInjectEnabled = Self.boolDefault("glossaryLLMInject")
        load()
    }

    // MARK: CRUD

    func add(_ term: GlossaryTerm) { terms.append(term); rebuild(); save() }
    func update(_ term: GlossaryTerm) {
        if let i = terms.firstIndex(where: { $0.id == term.id }) { terms[i] = term; rebuild(); save() }
    }
    func remove(_ id: UUID) { terms.removeAll { $0.id == id }; rebuild(); save() }
    /// Quick add from a selected transcript word: canonical + the heard variant.
    func quickAdd(canonical: String, heard: String? = nil) {
        var variants: [String] = []
        if let heard, heard.caseInsensitiveCompare(canonical) != .orderedSame { variants = [heard] }
        add(GlossaryTerm(canonical: canonical, variants: variants))
    }

    private var enabledTerms: [GlossaryTerm] { terms.filter { $0.enabled && !$0.canonical.isEmpty } }

    // MARK: LLM prompt hint

    /// A short line for the notes/ask system prompt so the LLM uses correct spellings.
    var promptFragment: String? {
        guard llmInjectEnabled else { return nil }
        let names = enabledTerms.map(\.canonical)
        guard !names.isEmpty else { return nil }
        return "Используй эти правильные написания терминов и имён, исправляй их в тексте: "
            + names.joined(separator: ", ") + "."
    }

    // MARK: Local correction

    // Precomputed indexes (rebuilt on edit).
    private var exactMap: [String: String] = [:]                 // lowercased single-word variant → canonical
    private var fuzzyCandidates: [(key: String, canonical: String)] = []  // transliterated single-word → canonical
    private var phrasePairs: [(pattern: String, canonical: String)] = []  // \bphrase\b (escaped) → canonical

    private func rebuild() {
        exactMap.removeAll(); fuzzyCandidates.removeAll(); phrasePairs.removeAll()
        for t in enabledTerms {
            let forms = ([t.canonical] + t.variants).filter { !$0.isEmpty }
            for form in forms {
                if form.contains(" ") {
                    phrasePairs.append((#"\b"# + NSRegularExpression.escapedPattern(for: form) + #"\b"#, t.canonical))
                } else {
                    let low = form.lowercased()
                    exactMap[low] = t.canonical
                    if form.count >= 4 { fuzzyCandidates.append((Self.translit(low), t.canonical)) }
                }
            }
        }
    }

    /// Correct a finalized transcript/dictation string. Deterministic; conservative to avoid
    /// mangling correct words. No-op when disabled or empty.
    func correct(_ text: String) -> String {
        guard correctionEnabled, !text.isEmpty, !enabledTerms.isEmpty else { return text }
        var out = text
        // 1) whole-phrase variants (multi-word), case-insensitive.
        for (pattern, canonical) in phrasePairs {
            out = out.replacingOccurrences(of: pattern, with: canonical,
                                           options: [.regularExpression, .caseInsensitive])
        }
        // 2) single words: exact variant, else conservative fuzzy.
        return Self.replaceWords(in: out, exact: exactMap, fuzzy: fuzzyCandidates)
    }

    private static let wordRegex = try! NSRegularExpression(pattern: #"\p{L}[\p{L}\p{N}\-]*"#)

    private static func replaceWords(in text: String,
                                     exact: [String: String],
                                     fuzzy: [(key: String, canonical: String)]) -> String {
        let ns = text as NSString
        let matches = wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        // Replace from the end so earlier ranges stay valid.
        for m in matches.reversed() {
            let word = ns.substring(with: m.range)
            let low = word.lowercased()
            var replacement: String?
            if let canon = exact[low] {
                if canon != word { replacement = canon }
            } else if word.count >= 4 {
                let tl = translit(low)
                var best: (String, Double)?
                for cand in fuzzy {
                    let s = similarity(tl, cand.key)
                    if s >= 0.86, s > (best?.1 ?? 0) { best = (cand.canonical, s) }
                }
                if let (canon, _) = best, canon.lowercased() != low { replacement = canon }
            }
            if let replacement, let r = Range(m.range, in: result) {
                result.replaceSubrange(r, with: replacement)
            }
        }
        return result
    }

    // Cyrillic → Latin (rough phonetic) so "кубернетис" ≈ "kubernetes".
    private static let cyr: [Character: String] = [
        "а":"a","б":"b","в":"v","г":"g","д":"d","е":"e","ё":"e","ж":"zh","з":"z","и":"i","й":"y",
        "к":"k","л":"l","м":"m","н":"n","о":"o","п":"p","р":"r","с":"s","т":"t","у":"u","ф":"f",
        "х":"h","ц":"ts","ч":"ch","ш":"sh","щ":"sch","ъ":"","ы":"y","ь":"","э":"e","ю":"yu","я":"ya",
    ]
    static func translit(_ s: String) -> String {
        s.lowercased().map { cyr[$0] ?? String($0) }.joined()
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let dist = levenshtein(Array(a), Array(b))
        let maxLen = max(a.count, b.count)
        return maxLen == 0 ? 1 : 1 - Double(dist) / Double(maxLen)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let items = try? JSONDecoder().decode([GlossaryTerm].self, from: data) {
            terms = items
        }
        rebuild()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(terms) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
