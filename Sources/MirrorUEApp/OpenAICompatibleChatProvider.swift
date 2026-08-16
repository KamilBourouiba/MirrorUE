import Foundation

/// Async OpenAI Chat Completions adapter used by LM Studio and other compatible
/// endpoints. It owns one memory-only URLSession so connections are reused.
final class OpenAICompatibleChatProvider: AgentLLMProvider, @unchecked Sendable {
    private static let maximumResponseBytes = 2 * 1_024 * 1_024
    private let configuration: AgentProviderConfiguration
    private let loader: BoundedURLSessionDataLoader
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        configuration: AgentProviderConfiguration,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        if let session {
            self.loader = BoundedURLSessionDataLoader(copying: session)
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = configuration.timeout
            config.timeoutIntervalForResource = configuration.timeout
            config.httpMaximumConnectionsPerHost = 2
            config.waitsForConnectivity = false
            self.loader = BoundedURLSessionDataLoader(configuration: config)
        }
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func complete(_ request: AgentChatRequest) async throws -> AgentChatResponse {
        try Task.checkCancellation()
        let endpoint = try chatCompletionsURL()
        let model = request.model?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AgentProviderError.invalidConfiguration("model is required")
        }
        guard !request.messages.isEmpty else {
            throw AgentProviderError.invalidRequest("at least one message is required")
        }

        let body = try RequestBody(
            request: request,
            model: model,
            temperature: temperatureParameter(for: model, request: request),
            tokenLimitParameter: tokenLimitParameter(for: model),
            reasoningEffort: reasoningEffortParameter(for: model)
        )
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw AgentProviderError.invalidRequest(error.localizedDescription)
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in configuration.additionalHeaders {
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty,
                  !cleanName.contains("\r"), !cleanName.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else { continue }
            urlRequest.setValue(value, forHTTPHeaderField: cleanName)
        }
        if let apiKey = configuration.apiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            guard !apiKey.contains("\r"), !apiKey.contains("\n") else {
                throw AgentProviderError.invalidConfiguration(
                    "API key contains an invalid newline"
                )
            }
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let data: Data
        let response: URLResponse
        do {
            // URLSession's async API binds the data task lifetime to this Task;
            // cancelling the agent therefore cancels the socket request as well.
            (data, response) = try await loader.data(
                for: urlRequest,
                maximumBytes: Self.maximumResponseBytes
            )
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let bounded = error as? BoundedURLSessionDataError {
                throw AgentProviderError.invalidResponse(
                    bounded.localizedDescription
                )
            }
            throw error
        }
        try Task.checkCancellation()
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        let latencyMilliseconds = Double(elapsed) / 1_000_000
        guard let http = response as? HTTPURLResponse else {
            throw AgentProviderError.invalidResponse("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(4_096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentProviderError.http(
                status: http.statusCode,
                message: body.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode) : body
            )
        }

        let decoded: ResponseBody
        do {
            decoded = try decoder.decode(ResponseBody.self, from: data)
        } catch {
            throw AgentProviderError.invalidResponse(error.localizedDescription)
        }
        guard let choice = decoded.choices.first else {
            throw AgentProviderError.invalidResponse("response contains no choices")
        }

        let toolCalls = try choice.message.normalizedToolCalls(using: decoder, encoder: encoder)
        let usage = AgentTokenUsage(
            promptTokens: max(0, decoded.usage?.promptTokens ?? 0),
            completionTokens: max(0, decoded.usage?.completionTokens ?? 0),
            totalTokens: max(
                0,
                decoded.usage?.totalTokens
                    ?? ((decoded.usage?.promptTokens ?? 0) + (decoded.usage?.completionTokens ?? 0))
            )
        )
        return AgentChatResponse(
            id: decoded.id,
            model: decoded.model ?? model,
            text: choice.message.normalizedText,
            toolCalls: toolCalls,
            finishReason: choice.finishReason,
            usage: usage,
            latencyMilliseconds: latencyMilliseconds
        )
    }

    private func chatCompletionsURL() throws -> URL {
        guard var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        ), let scheme = components.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           components.host != nil else {
            throw AgentProviderError.invalidConfiguration("base URL must be HTTP(S)")
        }

        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }

        if let configuredPath = configuration.chatCompletionsPath?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            if configuredPath.hasPrefix("/") {
                path = configuredPath
            } else {
                if path.isEmpty || path == "/" {
                    path = ""
                }
                path += "/\(configuredPath)"
            }
        } else if !path.hasSuffix("/chat/completions") {
            if path.hasSuffix("/v1") {
                path += "/chat/completions"
            } else {
                path += "/v1/chat/completions"
            }
        }
        components.path = path

        guard let url = components.url else {
            throw AgentProviderError.invalidConfiguration("cannot form chat completions URL")
        }
        return url
    }

    private func tokenLimitParameter(for model: String) -> RequestBody.TokenLimitParameter {
        if isOfficialOpenAIHost || isOpenAIReasoningModel(model) {
            return .maxCompletionTokens
        }
        return .maxTokens
    }

    private func temperatureParameter(for model: String, request: AgentChatRequest) -> Double? {
        isOpenAIReasoningModel(model) ? nil : request.temperature
    }

    private func reasoningEffortParameter(for model: String) -> AIReasoningEffort {
        guard isOfficialOpenAIHost, configuration.reasoningEffort == .none else {
            return configuration.reasoningEffort
        }
        // OpenAI reasoning models do not accept "none"; omit the field instead.
        return .providerDefault
    }

    private var isOfficialOpenAIHost: Bool {
        guard let host = configuration.baseURL.host?.lowercased() else { return false }
        return host == "api.openai.com" || host.hasSuffix(".openai.com")
    }

    private func isOpenAIReasoningModel(_ model: String) -> Bool {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleanModel.hasPrefix("gpt-5")
            || cleanModel.hasPrefix("o1")
            || cleanModel.hasPrefix("o3")
            || cleanModel.hasPrefix("o4")
    }
}

private extension OpenAICompatibleChatProvider {
    struct RequestBody: Encodable {
        enum TokenLimitParameter: String {
            case maxTokens = "max_tokens"
            case maxCompletionTokens = "max_completion_tokens"
        }

        var model: String
        var messages: [RequestMessage]
        var tools: [RequestTool]?
        var toolChoice: RequestToolChoice?
        var temperature: Double?
        var tokenLimit: Int
        var tokenLimitParameter: TokenLimitParameter
        var reasoningEffort: String?
        var stream = false

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case tools
            case toolChoice = "tool_choice"
            case temperature
            case reasoningEffort = "reasoning_effort"
            case stream
        }

        init(
            request: AgentChatRequest,
            model: String,
            temperature: Double?,
            tokenLimitParameter: TokenLimitParameter,
            reasoningEffort: AIReasoningEffort
        ) throws {
            self.model = model
            self.messages = try request.messages.map(RequestMessage.init)
            if request.tools.isEmpty {
                self.tools = nil
                self.toolChoice = nil
            } else {
                self.tools = request.tools.map(RequestTool.init)
                self.toolChoice = RequestToolChoice(request.toolChoice)
            }
            self.temperature = temperature
            self.tokenLimit = request.maxTokens
            self.tokenLimitParameter = tokenLimitParameter
            self.reasoningEffort = (
                request.reasoningEffortOverride ?? reasoningEffort
            ).requestValue
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(messages, forKey: .messages)
            try container.encodeIfPresent(tools, forKey: .tools)
            try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
            try container.encodeIfPresent(temperature, forKey: .temperature)
            try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
            try container.encode(stream, forKey: .stream)

            var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            try dynamicContainer.encode(
                tokenLimit,
                forKey: DynamicCodingKey(tokenLimitParameter.rawValue)
            )
        }
    }

    struct DynamicCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    struct RequestMessage: Encodable {
        var role: String
        var content: RequestContent

        init(_ message: AgentChatMessage) throws {
            role = message.role.rawValue
            if message.images.isEmpty {
                content = .text(message.text)
                return
            }

            var parts: [RequestContentPart] = []
            if !message.text.isEmpty {
                parts.append(.text(message.text))
            }
            for image in message.images {
                let dataURL = image.dataURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard dataURL.lowercased().hasPrefix("data:image/"),
                      dataURL.range(of: ";base64,", options: [.caseInsensitive]) != nil else {
                    throw AgentProviderError.invalidRequest(
                        "images must use a base64 data:image URL"
                    )
                }
                parts.append(.image(dataURL: dataURL, detail: image.detail.rawValue))
            }
            content = .parts(parts)
        }
    }

    enum RequestContent: Encodable {
        case text(String)
        case parts([RequestContentPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value):
                try container.encode(value)
            case .parts(let value):
                try container.encode(value)
            }
        }
    }

    struct RequestContentPart: Encodable {
        var type: String
        var text: String?
        var imageURL: ImageURL?

        struct ImageURL: Encodable {
            var url: String
            var detail: String
        }

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        static func text(_ text: String) -> RequestContentPart {
            RequestContentPart(type: "text", text: text, imageURL: nil)
        }

        static func image(dataURL: String, detail: String) -> RequestContentPart {
            RequestContentPart(
                type: "image_url",
                text: nil,
                imageURL: ImageURL(url: dataURL, detail: detail)
            )
        }
    }

    struct RequestTool: Encodable {
        var type = "function"
        var function: Function

        struct Function: Encodable {
            var name: String
            var description: String
            var parameters: AgentJSONValue
        }

        init(_ tool: AgentToolDefinition) {
            function = Function(
                name: tool.name,
                description: tool.description,
                parameters: tool.inputSchema
            )
        }
    }

    enum RequestToolChoice: Encodable {
        case value(String)
        case named(String)

        init(_ choice: AgentToolChoice) {
            switch choice {
            case .auto: self = .value("auto")
            case .none: self = .value("none")
            case .required: self = .value("required")
            case .named(let name): self = .named(name)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .value(let value):
                try container.encode(value)
            case .named(let name):
                try container.encode(
                    AgentJSONValue.object([
                        "type": .string("function"),
                        "function": .object(["name": .string(name)]),
                    ])
                )
            }
        }
    }

    struct ResponseBody: Decodable {
        var id: String?
        var model: String?
        var choices: [ResponseChoice]
        var usage: ResponseUsage?
    }

    struct ResponseChoice: Decodable {
        var message: ResponseMessage
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct ResponseMessage: Decodable {
        var content: AgentJSONValue?
        var reasoningContent: String?
        var toolCalls: [ResponseToolCall]?
        var legacyFunctionCall: ResponseFunction?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
            case legacyFunctionCall = "function_call"
        }

        var normalizedText: String {
            if let content {
                switch content {
                case .string(let text):
                    if !text.isEmpty { return text }
                case .array(let parts):
                    let text = parts.compactMap { part -> String? in
                        guard case .object(let object) = part else { return nil }
                        return object["text"]?.stringValue
                            ?? object["content"]?.stringValue
                    }.joined()
                    if !text.isEmpty { return text }
                default:
                    break
                }
            }
            return reasoningContent ?? ""
        }

        func normalizedToolCalls(
            using decoder: JSONDecoder,
            encoder: JSONEncoder
        ) throws -> [AgentToolCall] {
            var calls = toolCalls ?? []
            if calls.isEmpty, let legacyFunctionCall {
                calls = [
                    ResponseToolCall(
                        id: "legacy_function_call",
                        function: legacyFunctionCall
                    ),
                ]
            }

            return try calls.enumerated().map { index, call in
                let name = call.function.name
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    throw AgentProviderError.invalidResponse("tool call has no function name")
                }

                let arguments: AgentJSONValue
                let raw: String
                switch call.function.arguments {
                case .string(let json):
                    raw = json
                    do {
                        arguments = try decoder.decode(
                            AgentJSONValue.self,
                            from: Data(json.utf8)
                        )
                    } catch {
                        throw AgentProviderError.invalidToolArguments(
                            tool: name,
                            message: error.localizedDescription
                        )
                    }
                case let value:
                    arguments = value
                    let data = try encoder.encode(value)
                    raw = String(decoding: data, as: UTF8.self)
                }

                return AgentToolCall(
                    id: call.id ?? "call_\(index)",
                    name: name,
                    arguments: arguments,
                    rawArguments: raw
                )
            }
        }
    }

    struct ResponseToolCall: Decodable {
        var id: String?
        var function: ResponseFunction
    }

    struct ResponseFunction: Decodable {
        var name: String
        var arguments: AgentJSONValue
    }

    struct ResponseUsage: Decodable {
        var promptTokens: Int?
        var completionTokens: Int?
        var totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
