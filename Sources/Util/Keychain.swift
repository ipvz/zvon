import Foundation
import Security

/// Minimal Keychain wrapper — API keys must never live in UserDefaults / plists / the DB
/// (per the Parley engineering notes). One generic-password item per account.
enum Keychain {
    private static let service = "com.parley.app"

    /// Reads are cached for the life of the process. A Keychain lookup is a synchronous XPC round
    /// trip to securityd, and views ask for the same secret on every render — a record list that
    /// checked each space's Telegram token per row stalled the main thread (seen in a crash report
    /// as the main thread parked in `SecItemCopyMatching`). Only this app writes these items, and
    /// `set`/`delete` below keep the cache honest. A missing item is cached too.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: String?] = [:]

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        lock.lock(); defer { lock.unlock() }
        if status == errSecSuccess { cache[account] = .some(value) } else { cache[account] = nil }
    }

    static func get(account: String) -> String? {
        lock.lock()
        if let hit = cache[account] { lock.unlock(); return hit }
        lock.unlock()
        let value = read(account: account)
        lock.lock(); cache[account] = .some(value); lock.unlock()
        return value
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        lock.lock(); cache[account] = .some(nil); lock.unlock()
    }
}
