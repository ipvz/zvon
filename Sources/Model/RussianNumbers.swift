import Foundation

/// Local, deterministic Russian number-words → digits, so dictation writes «150» not «сто пятьдесят»
/// without needing the (optional, LLM-backed) AI cleanup. Runs of number-words are collapsed to a
/// number; a boundary between two numbers is detected when a base word's rank stops strictly
/// decreasing (e.g. «сто пятьдесят двести тридцать» → «150 230», not one big sum).
enum RussianNumbers {
    // value + rank (1 = unit, 2 = ten/teen, 3 = hundred). Numbers are spoken largest-tier first.
    private static let base: [String: (val: Int, rank: Int)] = [
        "ноль": (0, 1), "нуль": (0, 1),
        "один": (1, 1), "одна": (1, 1), "одно": (1, 1), "два": (2, 1), "две": (2, 1), "три": (3, 1),
        "четыре": (4, 1), "пять": (5, 1), "шесть": (6, 1), "семь": (7, 1), "восемь": (8, 1), "девять": (9, 1),
        "десять": (10, 2), "одиннадцать": (11, 2), "двенадцать": (12, 2), "тринадцать": (13, 2),
        "четырнадцать": (14, 2), "пятнадцать": (15, 2), "шестнадцать": (16, 2), "семнадцать": (17, 2),
        "восемнадцать": (18, 2), "девятнадцать": (19, 2),
        "двадцать": (20, 2), "тридцать": (30, 2), "сорок": (40, 2), "пятьдесят": (50, 2), "шестьдесят": (60, 2),
        "семьдесят": (70, 2), "восемьдесят": (80, 2), "девяносто": (90, 2),
        "сто": (100, 3), "двести": (200, 3), "триста": (300, 3), "четыреста": (400, 3), "пятьсот": (500, 3),
        "шестьсот": (600, 3), "семьсот": (700, 3), "восемьсот": (800, 3), "девятьсот": (900, 3),
    ]
    private static let scale: [String: Int] = [
        "тысяча": 1000, "тысячи": 1000, "тысяч": 1000, "тыща": 1000, "тыщи": 1000,
        "миллион": 1_000_000, "миллиона": 1_000_000, "миллионов": 1_000_000,
        "миллиард": 1_000_000_000, "миллиарда": 1_000_000_000, "миллиардов": 1_000_000_000,
    ]

    static func digitsify(_ text: String) -> String {
        let toks = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var run: [(word: String, key: String)] = []
        var lastRank = 99

        func value(of run: [(word: String, key: String)]) -> Int {
            var total = 0, cur = 0
            for t in run {
                if let b = base[t.key] { cur += b.val }
                else if let s = scale[t.key] { cur = (cur == 0 ? 1 : cur) * s; total += cur; cur = 0 }
            }
            return total + cur
        }
        func flush() {
            guard !run.isEmpty else { return }
            // keep punctuation glued to the run's edges (e.g. «(сто…» / «…тридцать.»)
            let first = run.first!.word, last = run.last!.word
            let lead = String(first.prefix(while: { "(«„\"".contains($0) }))
            let trail = String(String(last.reversed()).prefix(while: { ".,!?;:)».…".contains($0) }).reversed())
            out.append(lead + String(value(of: run)) + trail)
            run = []; lastRank = 99
        }

        for w in toks {
            let key = w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:()«»\"…"))
            if let b = base[key] {
                if !run.isEmpty, b.rank >= lastRank { flush() }   // magnitude didn't decrease → a new number
                run.append((w, key)); lastRank = b.rank
            } else if scale[key] != nil, !run.isEmpty {
                run.append((w, key)); lastRank = 99                // a scale extends the current number
            } else {
                flush(); out.append(w)                             // bare scale word («тысячи файлов») or plain word → literal
            }
        }
        flush()
        return out.joined(separator: " ")
    }
}
