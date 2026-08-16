import Foundation

struct AIProviderConnectionTestResult: Equatable, Sendable {
    var succeeded: Bool
    var message: String
    var models: [String]
    var latencyMilliseconds: Int
    var statusCode: Int?

    static func failure(
        _ message: String,
        latencyMilliseconds: Int = 0,
        statusCode: Int? = nil
    ) -> AIProviderConnectionTestResult {
        AIProviderConnectionTestResult(
            succeeded: false,
            message: message,
            models: [],
            latencyMilliseconds: latencyMilliseconds,
            statusCode: statusCode
        )
    }
}

/// Lightweight, asynchronous health check for built-in provider adapters.
/// Adapter implementations can supply their own check to AIProviderSettingsPanel.
enum AIProviderConnectionTester {
    private struct ModelList: Decodable {
        struct Model: Decodable {
            var id: String
        }

        var data: [Model]
    }

    private static let maximumResponseBytes = 2 * 1_024 * 1_024

    private static let loader: BoundedURLSessionDataLoader = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return BoundedURLSessionDataLoader(configuration: configuration)
    }()

    static func test(
        profile: AIProviderProfile,
        token: String?
    ) async -> AIProviderConnectionTestResult {
        let profile = profile.sanitized()
        do {
            try profile.validate()
        } catch {
            return .failure(error.localizedDescription)
        }

        guard profile.adapterIdentifier == AIProviderProfile.openAICompatibleAdapter else {
            return .failure("No built-in connection test exists for adapter “\(profile.adapterIdentifier)”.")
        }

        let url: URL
        do {
            url = try profile.endpoint(appending: "models")
        } catch {
            return .failure(error.localizedDescription)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(max(profile.requestTimeoutSeconds, 2), 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        profile.applyAuthentication(token: token, to: &request)

        let started = Date()
        do {
            let (data, response) = try await loader.data(
                for: request,
                maximumBytes: maximumResponseBytes
            )
            let latency = Int(Date().timeIntervalSince(started) * 1_000)
            guard let http = response as? HTTPURLResponse else {
                return .failure("The provider returned no HTTP response.", latencyMilliseconds: latency)
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = errorMessage(from: data)
                let prefix: String
                switch http.statusCode {
                case 401, 403:
                    prefix = "Authentication was rejected"
                default:
                    prefix = "Provider returned HTTP \(http.statusCode)"
                }
                return .failure(
                    detail.map { "\(prefix): \($0)" } ?? prefix,
                    latencyMilliseconds: latency,
                    statusCode: http.statusCode
                )
            }

            let decoded = try? JSONDecoder().decode(ModelList.self, from: data)
            let models = decoded?.data
                .map(\.id)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            var seenModels = Set<String>()
            let uniqueModels = models.filter { seenModels.insert($0).inserted }
            let suffix = uniqueModels.isEmpty
                ? "connected; no models were reported"
                : "connected; \(uniqueModels.count) model\(uniqueModels.count == 1 ? "" : "s") available"

            return AIProviderConnectionTestResult(
                succeeded: true,
                message: "\(suffix) in \(latency) ms",
                models: uniqueModels,
                latencyMilliseconds: latency,
                statusCode: http.statusCode
            )
        } catch is CancellationError {
            return .failure("Connection test cancelled.")
        } catch {
            let latency = Int(Date().timeIntervalSince(started) * 1_000)
            return .failure(error.localizedDescription, latencyMilliseconds: latency)
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return bounded(message)
        }
        if let error = object["error"] as? String {
            return bounded(error)
        }
        if let message = object["message"] as? String {
            return bounded(message)
        }
        return nil
    }

    private static func bounded(_ message: String) -> String? {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(240))
    }
}
