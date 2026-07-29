import Foundation

/// Routes `/v1/llm/*` to the configured text provider.
enum LLMClient {
    static var provider: String {
        (ProcessInfo.processInfo.environment["MIRRORUE_LLM_PROVIDER"] ?? "lmstudio")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func status() -> [String: Any] {
        switch provider {
        case "ollama":
            return OllamaLLMClient.status()
        case "none", "off", "disabled":
            return ["ok": true, "provider": "none", "enabled": false]
        case "lmstudio", "lm-studio", "lm_studio":
            return LMStudioLLMClient.status()
        default:
            var out = LMStudioLLMClient.status()
            out["error"] = (out["error"] as? String) ?? "unknown provider \(provider); using lmstudio"
            return out
        }
    }

    static func chat(payload: [String: Any]) -> (status: Int, json: [String: Any]) {
        switch provider {
        case "ollama":
            return OllamaLLMClient.chat(payload: payload)
        case "none", "off", "disabled":
            return (503, ["ok": false, "provider": "none", "error": "LLM disabled"])
        case "lmstudio", "lm-studio", "lm_studio":
            return LMStudioLLMClient.chat(payload: payload)
        default:
            return LMStudioLLMClient.chat(payload: payload)
        }
    }
}
