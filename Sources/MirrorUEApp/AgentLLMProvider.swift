import Foundation

/// A small, provider-neutral JSON value used for tool schemas and arguments.
///
/// Keeping `Any` out of the agent boundary makes provider responses Sendable and
/// allows action validation to happen before any device code is called.
enum AgentJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AgentJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AgentJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var objectValue: [String: AgentJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [AgentJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }
}

/// Provider-neutral control for models that expose an OpenAI-style
/// `reasoning_effort` request field.
enum AIReasoningEffort: String, Codable, CaseIterable, Sendable {
    /// Preserve the provider's own behavior by omitting the request field.
    case providerDefault = "provider-default"
    case none
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .providerDefault: return "Provider default"
        case .none: return "None (fastest)"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var helpText: String {
        switch self {
        case .providerDefault:
            return "Let the provider choose; MirrorUE omits reasoning_effort."
        case .none:
            return "Disable reasoning when supported. Fastest for phone control; unsupported servers may reject explicit values."
        case .low:
            return "Use a small reasoning budget. Unsupported servers may reject explicit values."
        case .medium:
            return "Use a moderate reasoning budget. Unsupported servers may reject explicit values."
        case .high:
            return "Use the largest reasoning budget and most latency. Unsupported servers may reject explicit values."
        }
    }

    /// Value placed on the wire. A provider default is represented by absence,
    /// not a non-standard string.
    var requestValue: String? {
        self == .providerDefault ? nil : rawValue
    }
}

/// Runtime-only provider configuration. UI profiles can map into this value
/// without coupling the network layer to persistence or Keychain storage.
struct AgentProviderConfiguration: Sendable, Equatable {
    var name: String
    var baseURL: URL
    var apiKey: String?
    var model: String
    var chatCompletionsPath: String?
    var additionalHeaders: [String: String]
    var reasoningEffort: AIReasoningEffort
    var timeout: TimeInterval

    init(
        name: String = "OpenAI-compatible",
        baseURL: URL,
        apiKey: String? = nil,
        model: String,
        chatCompletionsPath: String? = nil,
        additionalHeaders: [String: String] = [:],
        reasoningEffort: AIReasoningEffort = .providerDefault,
        timeout: TimeInterval = 120
    ) {
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.chatCompletionsPath = chatCompletionsPath
        self.additionalHeaders = additionalHeaders
        self.reasoningEffort = reasoningEffort
        self.timeout = min(max(timeout, 1), 600)
    }

    static func lmStudio(
        baseURL: URL = URL(string: "http://127.0.0.1:1234")!,
        model: String,
        reasoningEffort: AIReasoningEffort = .none,
        timeout: TimeInterval = 120
    ) -> AgentProviderConfiguration {
        AgentProviderConfiguration(
            name: "LM Studio",
            baseURL: baseURL,
            model: model,
            reasoningEffort: reasoningEffort,
            timeout: timeout
        )
    }
}

enum AgentChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct AgentChatImage: Sendable, Equatable {
    enum Detail: String, Codable, Sendable {
        case auto
        case low
        case high
    }

    /// A `data:image/<format>;base64,...` URL.
    var dataURL: String
    var detail: Detail

    init(dataURL: String, detail: Detail = .low) {
        self.dataURL = dataURL
        self.detail = detail
    }
}

struct AgentChatMessage: Sendable, Equatable {
    var role: AgentChatRole
    var text: String
    var images: [AgentChatImage]

    init(role: AgentChatRole, text: String, images: [AgentChatImage] = []) {
        self.role = role
        self.text = text
        self.images = images
    }
}

struct AgentToolDefinition: Sendable, Equatable {
    var name: String
    var description: String
    var inputSchema: AgentJSONValue

    init(name: String, description: String, inputSchema: AgentJSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

enum AgentToolChoice: Sendable, Equatable {
    case auto
    case none
    case required
    case named(String)
}

struct AgentChatRequest: Sendable, Equatable {
    var messages: [AgentChatMessage]
    var tools: [AgentToolDefinition]
    var toolChoice: AgentToolChoice
    var model: String?
    var temperature: Double
    var maxTokens: Int
    /// Optional request-scoped override. `nil` preserves the provider
    /// configuration, while `.providerDefault` explicitly omits the field.
    var reasoningEffortOverride: AIReasoningEffort?

    init(
        messages: [AgentChatMessage],
        tools: [AgentToolDefinition] = [],
        toolChoice: AgentToolChoice = .auto,
        model: String? = nil,
        temperature: Double = 0,
        maxTokens: Int = 384,
        reasoningEffortOverride: AIReasoningEffort? = nil
    ) {
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.model = model
        self.temperature = min(max(temperature, 0), 2)
        self.maxTokens = min(max(maxTokens, 1), 16_384)
        self.reasoningEffortOverride = reasoningEffortOverride
    }
}

struct AgentToolCall: Sendable, Equatable {
    var id: String
    var name: String
    var arguments: AgentJSONValue
    var rawArguments: String
}

struct AgentTokenUsage: Codable, Sendable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int

    static let zero = AgentTokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
}

struct AgentChatResponse: Sendable, Equatable {
    var id: String?
    var model: String
    var text: String
    var toolCalls: [AgentToolCall]
    var finishReason: String?
    var usage: AgentTokenUsage
    var latencyMilliseconds: Double
}

/// Provider adapters must inherit cancellation from the calling task. In
/// particular, cancelling `complete` must cancel any in-flight network request.
protocol AgentLLMProvider: Sendable {
    func complete(_ request: AgentChatRequest) async throws -> AgentChatResponse
}

enum AgentProviderError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case http(status: Int, message: String)
    case invalidResponse(String)
    case invalidToolArguments(tool: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid provider configuration: \(message)"
        case .invalidRequest(let message):
            return "Invalid LLM request: \(message)"
        case .http(let status, let message):
            return "LLM HTTP \(status): \(message)"
        case .invalidResponse(let message):
            return "Invalid LLM response: \(message)"
        case .invalidToolArguments(let tool, let message):
            return "Invalid arguments for \(tool): \(message)"
        }
    }
}
