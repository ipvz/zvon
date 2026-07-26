import SwiftUI

/// Interface language (separate from the recognition/notes language `store.language`).
enum AppLang: String, CaseIterable, Identifiable {
    case ru, en
    var id: String { rawValue }
    var title: String { self == .ru ? "Русский" : "English" }
}

/// Plain global mirror of the current UI language so `L(...)` can be called from ANY context —
/// including non-@MainActor enum computed properties — without actor hops. Written only from the
/// main actor (via `L11n`), read everywhere; a single enum value never tears in practice.
nonisolated(unsafe) var _uiLang: AppLang = AppLang(rawValue: UserDefaults.standard.string(forKey: "uiLanguage") ?? "ru") ?? .ru

/// Inline two-language UI string: `L("Записи", "Records")` returns the current-language variant.
func L(_ ru: String, _ en: String) -> String { _uiLang == .en ? en : ru }

/// Observable holder so SwiftUI roots re-render on a language change (their whole subtree
/// re-localizes because `L(...)` re-reads `_uiLang` during the re-render).
@MainActor
final class L11n: ObservableObject {
    static let shared = L11n()
    @Published var lang: AppLang {
        didSet {
            _uiLang = lang
            UserDefaults.standard.set(lang.rawValue, forKey: "uiLanguage")
        }
    }
    private init() {
        lang = _uiLang
    }
}
