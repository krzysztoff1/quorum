import Foundation
import Security
import QuorumCore

/// Minimal macOS Keychain wrapper for BYOK secrets (PRD 02 R4): provider + search keys live here, never
/// in UserDefaults, argv, logs, or run transcripts. One generic-password item per env-var name.
enum Keychain {
    private static let service = "com.quorum.keys"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    /// Upsert; an empty value deletes the item (so clearing a field removes the secret).
    static func set(_ account: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(account); return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(trimmed.utf8)
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            SecItemAdd(base.merging([kSecValueData as String: data]) { _, new in new } as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

/// The BYOK secrets the engine reads from its environment (PRD 01 R6). One entry per provider/search
/// key: the env-var name the engine expects + a UI label. The app injects present keys into the engine
/// subprocess environment; the search key also reaches the CLI's MCP child via inheritance (R7).
enum EngineKey: String, CaseIterable, Identifiable {
    case anthropic = "QUORUM_ANTHROPIC_KEY"
    case openRouter = "QUORUM_OPENROUTER_KEY"
    case deepSeek = "QUORUM_DEEPSEEK_KEY"
    case tavily = "QUORUM_TAVILY_KEY"
    case brave = "QUORUM_BRAVE_KEY"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic:  return "Anthropic (BYOK)"
        case .openRouter: return "OpenRouter"
        case .deepSeek:   return "DeepSeek"
        case .tavily:     return "Tavily (search)"
        case .brave:      return "Brave (search)"
        }
    }

    var isSearch: Bool { self == .tavily || self == .brave }
    var isModelProvider: Bool { !isSearch }
}

/// Reads the stored BYOK secrets and reports what the engine can do with them.
enum EngineKeys {
    /// Present keys as an env-var → value map, for injecting into the engine (and the CLI's MCP child).
    static func environment() -> [String: String] {
        var env: [String: String] = [:]
        for key in EngineKey.allCases { if let v = Keychain.get(key.rawValue) { env[key.rawValue] = v } }
        return env
    }

    static func hasModelKey() -> Bool {
        EngineKey.allCases.contains { $0.isModelProvider && Keychain.get($0.rawValue) != nil }
    }

    static func hasSearchKey() -> Bool {
        EngineKey.allCases.contains { $0.isSearch && Keychain.get($0.rawValue) != nil }
    }

    /// The key a specific model actually needs — availability must gate on THIS, not on "any provider
    /// key" (a run configured for `deepseek/…` isn't served by an OpenRouter key). `claude-code` is the
    /// subscription and needs no BYOK key.
    static func hasKeyForModel(_ model: String) -> Bool {
        switch ModelID.provider(model) {
        case "claude-code", "": return true
        case "anthropic":  return Keychain.get(EngineKey.anthropic.rawValue) != nil
        case "openrouter": return Keychain.get(EngineKey.openRouter.rawValue) != nil
        case "deepseek":   return Keychain.get(EngineKey.deepSeek.rawValue) != nil
        default:           return hasModelKey()   // openai-compatible long tail — any provider key
        }
    }

    /// Engine model ids (compose/settings → UserDefaults), with sensible defaults. Synthesis falls back
    /// to the angle model (Full BYOK); Budget synthesizes on the subscription, so it's unused there.
    static func configuredAngleModel() -> String {
        let v = UserDefaults.standard.string(forKey: "engineAngleModel") ?? ""
        return v.isEmpty ? "deepseek/deepseek-chat" : v
    }
    static func configuredSynthesisModel() -> String {
        let v = UserDefaults.standard.string(forKey: "engineSynthesisModel") ?? ""
        return v.isEmpty ? configuredAngleModel() : v
    }
}
