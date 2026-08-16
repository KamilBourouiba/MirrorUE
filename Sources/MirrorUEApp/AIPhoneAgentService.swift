import Foundation

struct ResolvedAIProvider: Sendable {
    let profile: AIProviderProfile
    let model: String
    let provider: OpenAICompatibleChatProvider
}

struct AIPhoneAgentRequestPolicy: Sendable, Equatable {
    let reasoningEffortOverride: AIReasoningEffort?
    let logMessage: String?

    static func forProfile(_ profile: AIProviderProfile) -> AIPhoneAgentRequestPolicy {
        guard profile.preset == .lmStudio else {
            return AIPhoneAgentRequestPolicy(
                reasoningEffortOverride: nil,
                logMessage: nil
            )
        }
        return AIPhoneAgentRequestPolicy(
            reasoningEffortOverride: AIReasoningEffort.none,
            logMessage: "LM Studio agent reasoning is forced off for lower latency "
                + "and to preserve the tool-call token budget; chat settings are unchanged."
        )
    }
}

enum AIProviderRuntimeError: LocalizedError {
    case noProfile
    case unsupportedAdapter(String)
    case noModel(String)

    var errorDescription: String? {
        switch self {
        case .noProfile:
            return "Configure an AI provider first."
        case .unsupportedAdapter(let adapter):
            return "No runtime adapter is installed for “\(adapter)”."
        case .noModel(let detail):
            return detail
        }
    }
}

/// Converts Keychain-backed UI profiles into runtime-only provider instances.
/// The token exists only in the returned configuration and is never exposed by
/// status or agent APIs.
actor AIProviderRuntimeService {
    static let shared = AIProviderRuntimeService()

    private let store: AIProviderStore
    private var cachedResolution: ResolvedAIProvider?
    private var cachedProfile: AIProviderProfile?
    private var cachedRevision: UInt64?

    init(store: AIProviderStore = .shared) {
        self.store = store
    }

    func invalidate() {
        cachedResolution = nil
        cachedProfile = nil
        cachedRevision = nil
    }

    func resolveSelected(force: Bool = false) async throws -> ResolvedAIProvider {
        guard let selection = try store.selectedRuntimeSelection() else {
            throw AIProviderRuntimeError.noProfile
        }
        let profile = selection.profile.sanitized()
        try profile.validate()

        if !force,
           let cachedResolution,
           cachedProfile == profile,
           cachedRevision == selection.revision {
            return cachedResolution
        }
        guard profile.adapterIdentifier == AIProviderProfile.openAICompatibleAdapter else {
            throw AIProviderRuntimeError.unsupportedAdapter(profile.adapterIdentifier)
        }

        let token = selection.token
        guard !profile.model.isEmpty else {
            // `/v1/models` may include embedding models and every downloaded
            // JIT-loadable model. Never execute a phone goal against an
            // arbitrary first entry; the user must choose the chat/tool model.
            throw AIProviderRuntimeError.noModel(
                "Select a chat/tool-capable model in AI Provider settings first."
            )
        }
        let model = profile.model

        var bearer: String?
        var headers: [String: String] = [:]
        switch profile.authentication {
        case .none:
            break
        case .bearer:
            bearer = token
        case .apiKey(let header):
            if let token, !token.isEmpty {
                headers[header] = token
            }
        }
        guard let baseURL = URL(string: profile.baseURL) else {
            throw AIProviderProfileError.invalidBaseURL
        }
        let configuration = AgentProviderConfiguration(
            name: profile.name,
            baseURL: baseURL,
            apiKey: bearer,
            model: model,
            additionalHeaders: headers,
            reasoningEffort: profile.reasoningEffort,
            timeout: profile.requestTimeoutSeconds
        )
        let resolved = ResolvedAIProvider(
            profile: profile,
            model: model,
            provider: OpenAICompatibleChatProvider(configuration: configuration)
        )
        cachedProfile = profile
        cachedRevision = selection.revision
        cachedResolution = resolved
        return resolved
    }

    func connectionStatus() async -> AIProviderConnectionTestResult {
        let selection: AIProviderStoredSelection
        do {
            guard let selected = try store.selectedRuntimeSelection() else {
                return .failure("No AI provider is configured.")
            }
            selection = selected
        } catch {
            return .failure(error.localizedDescription)
        }
        let profile = selection.profile.sanitized()
        guard !profile.name.isEmpty else {
            return .failure("No AI provider is configured.")
        }
        return await AIProviderConnectionTester.test(profile: profile, token: selection.token)
    }
}

/// Rebuilds a bounded coordinator for each run. This permits changing provider
/// profiles and per-run step limits without retaining old keys or model state.
actor AIPhoneAgentService {
    typealias ObservationSource = @Sendable (
        _ includeScreenshot: Bool
    ) async throws -> AgentPhoneObservation
    typealias ActionExecutor = PhoneAgentCoordinator.ActionExecutor

    private let providerRuntime: AIProviderRuntimeService
    private let observationSource: ObservationSource
    private let actionExecutor: ActionExecutor

    private var coordinator: PhoneAgentCoordinator?
    private var providerLabel = "Not configured"
    private var startToken: UUID?

    init(
        providerRuntime: AIProviderRuntimeService = .shared,
        observationSource: @escaping ObservationSource,
        actionExecutor: @escaping ActionExecutor
    ) {
        self.providerRuntime = providerRuntime
        self.observationSource = observationSource
        self.actionExecutor = actionExecutor
    }

    func start(goal: String, maxSteps: Int = 12) async throws -> UUID {
        guard startToken == nil else { throw PhoneAgentCoordinatorError.alreadyRunning }
        if let coordinator,
           let current = await coordinator.currentSnapshot(),
           !current.status.isTerminal {
            throw PhoneAgentCoordinatorError.alreadyRunning
        }

        let token = UUID()
        startToken = token
        defer {
            if startToken == token { startToken = nil }
        }
        let resolved = try await providerRuntime.resolveSelected()
        guard startToken == token else { throw CancellationError() }
        let includeScreenshot = resolved.profile.allowsScreenshots
        let source = observationSource
        let executor = actionExecutor
        let limits = AgentRunLimits(maxSteps: min(32, max(1, maxSteps)))
        let requestPolicy = AIPhoneAgentRequestPolicy.forProfile(resolved.profile)
        let next = PhoneAgentCoordinator(
            provider: resolved.provider,
            limits: limits,
            reasoningEffortOverride: requestPolicy.reasoningEffortOverride,
            reasoningPolicyLogMessage: requestPolicy.logMessage,
            observationProvider: {
                try await source(includeScreenshot)
            },
            actionExecutor: executor
        )
        let id = try await next.start(goal: goal)
        guard startToken == token else {
            await next.cancel(runID: id)
            throw CancellationError()
        }
        coordinator = next
        providerLabel = "\(resolved.profile.name) · \(resolved.model)"
        return id
    }

    func snapshot() async -> AgentRunSnapshot? {
        await coordinator?.currentSnapshot()
    }

    func isStarting() -> Bool {
        startToken != nil
    }

    @discardableResult
    func cancel(runID: UUID? = nil) async throws -> AgentRunSnapshot? {
        if startToken != nil {
            guard runID == nil else { throw PhoneAgentCoordinatorError.runNotFound }
            startToken = nil
            return nil
        }
        guard let coordinator else {
            if runID != nil { throw PhoneAgentCoordinatorError.runNotFound }
            return nil
        }
        if let runID {
            guard let snapshot = await coordinator.currentSnapshot(),
                  snapshot.id == runID else {
                throw PhoneAgentCoordinatorError.runNotFound
            }
        }
        await coordinator.cancel(runID: runID)
        return await coordinator.currentSnapshot()
    }

    func currentProviderLabel() async -> String {
        if let coordinator, await coordinator.currentSnapshot() != nil {
            return providerLabel
        }
        if let selected = AIProviderStore.shared.selectedProfile {
            if selected.model.isEmpty {
                return selected.name
            }
            return "\(selected.name) · \(selected.model)"
        }
        return providerLabel
    }
}
