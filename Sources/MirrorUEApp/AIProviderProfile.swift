import Foundation

/// A UI preset is intentionally separate from the adapter identifier. New API
/// adapters can be added without changing how profiles and credentials are stored.
enum AIProviderPreset: String, Codable, CaseIterable, Sendable {
    case lmStudio = "lm-studio"
    case openAICompatible = "openai-compatible"

    var title: String {
        switch self {
        case .lmStudio:
            return "LM Studio"
        case .openAICompatible:
            return "OpenAI-compatible"
        }
    }

    var defaultName: String { title }

    var defaultBaseURL: String {
        switch self {
        case .lmStudio:
            return "http://127.0.0.1:1234/v1"
        case .openAICompatible:
            return ""
        }
    }

    var defaultReasoningEffort: AIReasoningEffort {
        switch self {
        case .lmStudio:
            // Qwen through LM Studio honors this OpenAI-compatible field and
            // avoids costly hidden reasoning in the latency-sensitive agent loop.
            return .none
        case .openAICompatible:
            // Do not assume an arbitrary compatible API accepts the extension.
            return .providerDefault
        }
    }

    var adapterIdentifier: String {
        switch self {
        case .lmStudio, .openAICompatible:
            return AIProviderProfile.openAICompatibleAdapter
        }
    }
}

/// Describes how an adapter should apply the profile's optional Keychain token.
/// The token itself is never part of this value or any Codable profile.
enum AIProviderAuthentication: Codable, Equatable, Sendable {
    case none
    case bearer
    case apiKey(header: String)
}

struct AIProviderProfile: Codable, Equatable, Identifiable, Sendable {
    static let openAICompatibleAdapter = "openai.chat-completions"

    var id: UUID
    var name: String
    var preset: AIProviderPreset

    /// Stable routing key used to select a provider-specific request adapter.
    var adapterIdentifier: String

    /// API base, not a chat endpoint. For OpenAI-compatible providers this
    /// normally ends in `/v1`.
    var baseURL: String
    var model: String
    var authentication: AIProviderAuthentication
    var allowsScreenshots: Bool
    var reasoningEffort: AIReasoningEffort
    var requestTimeoutSeconds: Double

    init(
        id: UUID = UUID(),
        name: String,
        preset: AIProviderPreset,
        adapterIdentifier: String? = nil,
        baseURL: String,
        model: String = "",
        authentication: AIProviderAuthentication = .bearer,
        allowsScreenshots: Bool = false,
        reasoningEffort: AIReasoningEffort? = nil,
        requestTimeoutSeconds: Double = 120
    ) {
        self.id = id
        self.name = name
        self.preset = preset
        self.adapterIdentifier = adapterIdentifier ?? preset.adapterIdentifier
        self.baseURL = baseURL
        self.model = model
        self.authentication = authentication
        self.allowsScreenshots = allowsScreenshots
        self.reasoningEffort = reasoningEffort ?? preset.defaultReasoningEffort
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    static func lmStudio(id: UUID = UUID()) -> AIProviderProfile {
        AIProviderProfile(
            id: id,
            name: AIProviderPreset.lmStudio.defaultName,
            preset: .lmStudio,
            baseURL: AIProviderPreset.lmStudio.defaultBaseURL,
            model: "",
            authentication: .bearer,
            allowsScreenshots: false,
            reasoningEffort: AIReasoningEffort.none
        )
    }

    static func openAICompatible(id: UUID = UUID()) -> AIProviderProfile {
        AIProviderProfile(
            id: id,
            name: AIProviderPreset.openAICompatible.defaultName,
            preset: .openAICompatible,
            baseURL: AIProviderPreset.openAICompatible.defaultBaseURL,
            model: "",
            authentication: .bearer,
            allowsScreenshots: false,
            reasoningEffort: .providerDefault
        )
    }

    /// Returns a copy with whitespace removed from fields where it has no
    /// semantic meaning. Call this before validation and persistence.
    func sanitized() -> AIProviderProfile {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.adapterIdentifier = adapterIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while copy.baseURL.hasSuffix("/") {
            copy.baseURL.removeLast()
        }
        copy.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.requestTimeoutSeconds = min(max(requestTimeoutSeconds, 1), 600)
        return copy
    }

    func validate() throws {
        let candidate = sanitized()
        guard !candidate.name.isEmpty, candidate.name.count <= 80 else {
            throw AIProviderProfileError.invalidName
        }
        guard !candidate.adapterIdentifier.isEmpty else {
            throw AIProviderProfileError.missingAdapter
        }
        guard !candidate.baseURL.isEmpty,
              candidate.baseURL.count <= 2_048,
              let components = URLComponents(string: candidate.baseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw AIProviderProfileError.invalidBaseURL
        }
        if scheme == "http", let host = components.host,
           !Self.isLoopbackHost(host) {
            throw AIProviderProfileError.insecureRemoteURL
        }
        if case let .apiKey(header) = candidate.authentication {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
            let scalars = header.unicodeScalars
            guard !header.isEmpty,
                  header.count <= 128,
                  scalars.allSatisfy({ allowed.contains($0) }) else {
                throw AIProviderProfileError.invalidAuthenticationHeader
            }
        }
    }

    private static func isLoopbackHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: "[]")
        )
        if host == "localhost" || host == "localhost."
            || host == "::1" || host == "0:0:0:0:0:0:0:1" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ UInt8($0) != nil }) else {
            return false
        }
        return octets[0] == "127"
    }

    /// Builds an endpoint below the configured API base.
    func endpoint(appending path: String) throws -> URL {
        let candidate = sanitized()
        try candidate.validate()
        guard let base = URL(string: candidate.baseURL) else {
            throw AIProviderProfileError.invalidBaseURL
        }
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleanPath.isEmpty ? base : base.appendingPathComponent(cleanPath)
    }

    /// Applies the configured authentication mechanism without exposing the
    /// token to profile persistence or diagnostics.
    func applyAuthentication(token: String?, to request: inout URLRequest) {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              !token.contains("\r"),
              !token.contains("\n") else { return }

        switch authentication {
        case .none:
            return
        case .bearer:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case let .apiKey(header):
            let cleanHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanHeader.isEmpty else { return }
            request.setValue(token, forHTTPHeaderField: cleanHeader)
        }
    }

    // Defaults make persisted profiles tolerant of fields added in later builds.
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case preset
        case adapterIdentifier
        case baseURL
        case model
        case authentication
        case allowsScreenshots
        case reasoningEffort
        case requestTimeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        preset = try values.decodeIfPresent(AIProviderPreset.self, forKey: .preset) ?? .openAICompatible
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? preset.defaultName
        adapterIdentifier = try values.decodeIfPresent(String.self, forKey: .adapterIdentifier)
            ?? preset.adapterIdentifier
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? preset.defaultBaseURL
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        authentication = try values.decodeIfPresent(AIProviderAuthentication.self, forKey: .authentication)
            ?? .bearer
        allowsScreenshots = try values.decodeIfPresent(Bool.self, forKey: .allowsScreenshots) ?? false
        reasoningEffort = try values.decodeIfPresent(
            AIReasoningEffort.self,
            forKey: .reasoningEffort
        ) ?? preset.defaultReasoningEffort
        requestTimeoutSeconds = try values.decodeIfPresent(Double.self, forKey: .requestTimeoutSeconds) ?? 120
    }
}

enum AIProviderProfileError: LocalizedError, Equatable {
    case invalidName
    case missingAdapter
    case invalidBaseURL
    case insecureRemoteURL
    case invalidAuthenticationHeader

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a provider name of 80 characters or fewer."
        case .missingAdapter:
            return "This provider does not have an API adapter."
        case .invalidBaseURL:
            return "Enter a valid HTTP or HTTPS API base URL without credentials, a query, or a fragment."
        case .insecureRemoteURL:
            return "Remote AI providers must use HTTPS. Plain HTTP is allowed only on loopback."
        case .invalidAuthenticationHeader:
            return "The API-key header may contain only letters, numbers, and hyphens."
        }
    }
}
