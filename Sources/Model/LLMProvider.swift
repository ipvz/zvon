import Foundation

/// Wire format of the endpoint — OpenAI-compatible `/chat/completions` or Anthropic `/messages`.
enum LLMAPIStyle { case openai, anthropic }

/// A selectable LLM backend. Cloud providers (OpenAI/Anthropic) have a fixed endpoint + need a
/// key; local/hf/custom let the user provide their own OpenAI-compatible endpoint.
enum LLMProvider: String, CaseIterable, Identifiable {
    case openai, anthropic, local, hf, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .openai:    return "OpenAI"
        case .anthropic: return "Anthropic"
        case .local:     return "Локальная модель"
        case .hf:        return "Hugging Face"
        case .custom:    return "Свой endpoint"
        }
    }
    var subtitle: String {
        switch self {
        case .openai:    return "GPT · облако · нужен API-ключ"
        case .anthropic: return "Claude · облако · нужен API-ключ"
        case .local:     return "Ollama · на устройстве"
        case .hf:        return "Открытые модели · свой endpoint"
        case .custom:    return "Любой OpenAI-совместимый API"
        }
    }

    var apiStyle: LLMAPIStyle { self == .anthropic ? .anthropic : .openai }

    /// Fixed base URL, or nil when the user supplies the endpoint (hf / custom).
    var fixedEndpoint: String? {
        switch self {
        case .openai:    return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .local:     return "http://localhost:11434/v1"
        case .hf, .custom: return nil
        }
    }
    var editableEndpoint: Bool { fixedEndpoint == nil }

    var defaultModel: String {
        switch self {
        case .openai:    return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-5"
        case .local:     return "llama3.1"
        case .hf:        return "Qwen/Qwen3.6-35B-A3B-FP8"
        case .custom:    return ""
        }
    }

    var needsKey: Bool {
        switch self {
        case .openai, .anthropic, .hf, .custom: return true
        case .local: return false
        }
    }

    /// Keychain account. hf/custom keep the legacy "llm" account (backward-compat); cloud providers
    /// get their own so switching keeps each key.
    var keyAccount: String {
        switch self {
        case .hf, .custom: return "llm"
        default:           return "llm.\(rawValue)"
        }
    }
    /// UserDefaults key for the per-provider model id.
    var modelKey: String { "llmModel.\(rawValue)" }
}
