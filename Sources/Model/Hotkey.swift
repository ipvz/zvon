import KeyboardShortcuts
import AppKit

/// How dictation is triggered. `KeyboardShortcuts` can't record a modifier-only shortcut (it
/// requires a real key), so a single hold-key (Wispr Flow style) is handled separately via a
/// `flagsChanged` monitor. `.combo` uses the `.dictation` KeyboardShortcuts binding instead.
enum DictationTrigger: String, CaseIterable, Identifiable {
    case combo, fn, leftCommand, rightCommand, leftOption, rightOption, rightControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .combo:         return "Сочетание клавиш"
        case .fn:            return "Fn (🌐) — зажать"
        case .leftCommand:   return "Левый ⌘ — зажать"
        case .rightCommand:  return "Правый ⌘ — зажать"
        case .leftOption:    return "Левый ⌥ — зажать"
        case .rightOption:   return "Правый ⌥ — зажать"
        case .rightControl:  return "Правый ⌃ — зажать"
        }
    }

    /// keyCode carried by the modifier's `flagsChanged` event (nil = use the KeyboardShortcuts combo).
    /// Compact key hint shown in the dictation capsule (mockup: «правый ⌘»).
    var shortHint: String {
        switch self {
        case .combo:        return "⌥Space"
        case .fn:           return "fn"
        case .leftCommand:  return "левый ⌘"
        case .rightCommand: return "правый ⌘"
        case .leftOption:   return "левый ⌥"
        case .rightOption:  return "правый ⌥"
        case .rightControl: return "правый ⌃"
        }
    }

    var keyCode: UInt16? {
        switch self {
        case .combo:        return nil
        case .fn:           return 63
        case .leftCommand:  return 55
        case .rightCommand: return 54
        case .leftOption:   return 58
        case .rightOption:  return 61
        case .rightControl: return 62
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .combo:               return []
        case .fn:                  return .function
        case .leftCommand, .rightCommand: return .command
        case .leftOption, .rightOption:   return .option
        case .rightControl:        return .control
        }
    }
}

extension KeyboardShortcuts.Name {
    /// Global start/stop meeting recording. Default: ⌘⇧R (per handoff spec). Rebindable.
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.command, .shift]))

    /// Push-to-talk dictation (Wispr Flow style): hold → speak → release → text is inserted
    /// at the cursor (or copied). Default: ⌥Space (per handoff spec). Rebindable in Settings.
    static let dictation = Self("dictation", default: .init(.space, modifiers: [.option]))

    /// Summarize the current meeting (✦ Итог). Default: ⌘⇧S. Rebindable.
    static let summarize = Self("summarize", default: .init(.s, modifiers: [.command, .shift]))
}

/// Dictation activation: hold-to-talk (release inserts) vs toggle (press on/off). Spec §Горячие клавиши.
enum DictationMode: String, CaseIterable, Identifiable {
    case hold, toggle
    var id: String { rawValue }
    var title: String { self == .hold ? "Удерживать" : "Переключать" }
}

/// AI cleanup style for push-to-talk dictation (Settings → Горячие клавиши → Обработка диктовки).
enum DictationStyle: String, CaseIterable, Identifiable {
    case plain, email, message
    var id: String { rawValue }
    var title: String { self == .plain ? "Обычный" : self == .email ? "Письмо" : "Сообщение" }
    /// Extra instruction appended to the polish prompt.
    var hint: String {
        switch self {
        case .plain: return ""
        case .email: return "Стиль — деловое письмо: вежливо, полные предложения."
        case .message: return "Стиль — короткое сообщение в мессенджер: живо и компактно."
        }
    }
}

/// App appearance preference (Settings → Общие → Тема).
enum ThemePref: String, CaseIterable, Identifiable {
    case light, dark, auto
    var id: String { rawValue }
    var title: String { self == .light ? "Светлая" : self == .dark ? "Тёмная" : "Авто" }
}
