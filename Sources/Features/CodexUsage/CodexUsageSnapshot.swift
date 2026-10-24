import Foundation

struct CodexUsageWindow: Decodable, Equatable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?
    var remainingPercent: Int { Int(floor(max(0, min(100, 100 - usedPercent)))) }
    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
    var period: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return L("Текущий период", "Current period") }
        if minutes == 10080 { return L("Неделя", "Weekly") }
        if minutes % 1440 == 0 { return L("\(minutes / 1440) дн.", "\(minutes / 1440) days") }
        if minutes % 60 == 0 { return L("\(minutes / 60) ч", "\(minutes / 60) hours") }
        return L("\(minutes) мин", "\(minutes) minutes")
    }
}

struct CodexUsageBucket: Decodable, Equatable, Sendable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: CodexUsageWindow?
    let secondary: CodexUsageWindow?
    var windows: [CodexUsageWindow] { [primary, secondary].compactMap { $0 } }
    var remainingPercent: Int? { windows.map(\.remainingPercent).min() }
}

struct CodexUsageResponse: Decodable, Sendable {
    let rateLimits: CodexUsageBucket?
    let rateLimitsByLimitId: [String: CodexUsageBucket]?
    // Never silently substitute another model's bucket for the general Codex allowance.
    var codex: CodexUsageBucket? {
        if let bucket = rateLimitsByLimitId?["codex"] { return bucket }
        if let rateLimits, rateLimits.limitId == nil || rateLimits.limitId == "codex" { return rateLimits }
        return nil
    }
}

struct CodexUsageSnapshot: Equatable, Sendable {
    let bucket: CodexUsageBucket
    let fetchedAt: Date
    func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(fetchedAt) >= 600 || bucket.windows.contains {
            guard let reset = $0.resetDate else { return false }
            return reset <= date
        }
    }
}

enum CodexUsageError: Error, Equatable {
    case notInstalled, signedOut, unsupportedAccount, unavailable, timeout, invalidResponse
    var message: String {
        switch self {
        case .notInstalled: return L("Установи Codex или ChatGPT, чтобы видеть лимиты.", "Install Codex or ChatGPT to see usage limits.")
        case .signedOut: return L("Войди в Codex через аккаунт ChatGPT.", "Sign in to Codex with your ChatGPT account.")
        case .unsupportedAccount: return L("Этот способ входа не предоставляет лимиты подписки ChatGPT.", "This sign-in method does not provide ChatGPT plan limits.")
        case .timeout: return L("Codex не ответил вовремя. Попробуем ещё раз.", "Codex did not respond in time. We’ll try again.")
        case .invalidResponse, .unavailable: return L("Не удалось обновить лимиты. Попробуй чуть позже.", "Could not refresh usage limits. Try again shortly.")
        }
    }
}
