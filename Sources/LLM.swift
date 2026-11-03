import Foundation
import Security

enum Provider: String, CaseIterable, Identifiable {
    case claude, deepseek
    /// Development only: a Claude Code session answers through tools/claude_bridge.py on the Mac.
    case bridge
    var id: String { rawValue }

    /// The services offered in Settings; the dev bridge only in debug builds.
    static var choices: [Provider] {
        #if DEBUG
        allCases
        #else
        [.claude, .deepseek]
        #endif
    }

    var name: String {
        switch self {
        case .claude: "Claude (Anthropic)"
        case .deepseek: "DeepSeek"
        case .bridge: "Claude Code (dev bridge)"
        }
    }
    var defaultModel: String {
        switch self {
        case .claude: "claude-opus-5-5"
        case .deepseek: "deepseek-flash"
        case .bridge: "http://localhost:8793/llm"
        }
    }
    var needsKey: Bool { self != .bridge }
    var keyHint: String { self == .claude ? "sk-ant-…" : "sk-…" }
    /// For simulator testing: `SIMCTL_CHILD_DF_ANTHROPIC_KEY=… xcrun simctl launch …`
    var environmentKey: String { self == .claude ? "DF_ANTHROPIC_KEY" : "DF_DEEPSEEK_KEY" }
}

enum LLMSettings {
    static var provider: Provider {
        get {
            if let p = ProcessInfo.processInfo.environment["DF_PROVIDER"].flatMap(Provider.init(rawValue:)) { return p }
            return UserDefaults.standard.string(forKey: "provider").flatMap(Provider.init(rawValue:)) ?? .claude
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "provider") }
    }

    static func model(_ p: Provider) -> String {
        let m = UserDefaults.standard.string(forKey: "model.\(p.rawValue)") ?? ""
        return m.isEmpty ? p.defaultModel : m
    }
    static func setModel(_ m: String, for p: Provider) { UserDefaults.standard.set(m, forKey: "model.\(p.rawValue)") }

    static func apiKey(_ p: Provider) -> String? {
        if let k = ProcessInfo.processInfo.environment[p.environmentKey], !k.isEmpty { return k }
        return Keychain.get("apikey.\(p.rawValue)")
    }
    static func setAPIKey(_ k: String, for p: Provider) {
        let t = k.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { Keychain.delete("apikey.\(p.rawValue)") } else { Keychain.set(t, for: "apikey.\(p.rawValue)") }
    }
}

enum LLMError: LocalizedError {
    case noKey(Provider), http(Int, String), refused, badAnswer(String)
    var errorDescription: String? {
        switch self {
        case .noKey(let p): "Add your \(p.name) API key in Settings to translate books."
        case .http(let code, let body):
            switch code {
            case 401, 403: "The API key was refused (\(code)). Check it in Settings."
            case 429, 503, 529: "The translation service is busy (\(code)). Try again in a minute."
            default: "The translation service answered \(code): \(LLMError.message(in: body))"
            }
        case .refused: "The model declined to translate this passage."
        case .badAnswer(let why): "The translation came back unreadable (\(why))."
        }
    }

    /// The "message" inside an API error body, or its start.
    static func message(in body: String) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
           let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
        return String(body.prefix(160))
    }
}

/// Sends one prompt and returns the JSON object the model answered with.
enum LLM {
    static func json(system: String, user: String) async throws -> Data {
        let p = LLMSettings.provider
        if p == .bridge {
            return try extractJSON(try await bridge(system: system, user: user, url: LLMSettings.model(p)))
        }
        guard let key = LLMSettings.apiKey(p) else { throw LLMError.noKey(p) }
        // busy, rate-limited and overloaded answers are worth waiting out
        let waits: [UInt64] = [3, 8, 20, 45]
        var attempt = 0
        while true {
            do {
                let text = p == .claude
                    ? try await claude(system: system, user: user, key: key, model: LLMSettings.model(p))
                    : try await deepseek(system: system, user: user, key: key, model: LLMSettings.model(p))
                return try extractJSON(text)
            } catch LLMError.http(let code, let body) where [408, 429, 500, 502, 503, 504, 529].contains(code) {
                guard attempt < waits.count else { throw LLMError.http(code, body) }
                try await Task.sleep(nanoseconds: waits[attempt] * 1_000_000_000)
                attempt += 1
            } catch let e as URLError where e.code == .timedOut || e.code == .networkConnectionLost {
                guard attempt < waits.count else { throw e }
                try await Task.sleep(nanoseconds: waits[attempt] * 1_000_000_000)
                attempt += 1
            }
        }
    }

    static var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 900
        return URLSession(configuration: c)
    }()

    static func claude(system: String, user: String, key: String, model: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "output_config": ["effort": "medium"],
            "messages": [["role": "user", "content": user]],
        ]
        // on a safety decline the API retries on a fallback model in the same call
        if model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable-5") || model == "claude-sonnet-5-5" {
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.badAnswer("not JSON") }
        if obj["stop_reason"] as? String == "refusal" { throw LLMError.refused }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        if obj["stop_reason"] as? String == "max_tokens" { throw LLMError.badAnswer("answer too long") }
        return text
    }

    static func deepseek(system: String, user: String, key: String, model: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // at its default effort deepseek-flash can spend the whole budget reasoning and answer nothing
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 65536,
            "reasoning_effort": "low",
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user + "\n\nAnswer in JSON."]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let text = message["content"] as? String else { throw LLMError.badAnswer("no content") }
        if choice["finish_reason"] as? String == "length" { throw LLMError.badAnswer("answer too long") }
        return text
    }

    /// Waits (up to half an hour) for the Claude Code session to answer through the bridge.
    static func bridge(system: String, user: String, url: String) async throws -> String {
        guard let u = URL(string: url) else { throw LLMError.badAnswer("bad bridge address") }
        var req = URLRequest(url: u, timeoutInterval: 1_900)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["system": system, "user": user])
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 1_900
        c.timeoutIntervalForResource = 1_900
        let (data, resp) = try await URLSession(configuration: c).data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else { throw LLMError.badAnswer("no text from bridge") }
        return text
    }

    /// The outermost {...} in the answer, in case the model wrapped it in prose or a code fence.
    static func extractJSON(_ text: String) throws -> Data {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw LLMError.badAnswer("no JSON object")
        }
        return Data(text[start...end].utf8)
    }
}

enum Keychain {
    static let service = "com.decentespresso.decentlyfluent"

    /// On a Mac the app is signed with a Developer ID and no provisioning profile, which can't use the
    /// data-protection keychain: use the login keychain there.
    private static func query(_ q: [String: Any]) -> [String: Any] {
        var q = q
        #if targetEnvironment(macCatalyst)
        q[kSecUseDataProtectionKeychain as String] = false
        #endif
        return q
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query(q) as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(query(q) as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(query(q) as CFDictionary)
    }
}
