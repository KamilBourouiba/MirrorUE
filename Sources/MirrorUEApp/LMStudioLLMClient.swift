import Foundation

/// HTTP client for LM Studio OpenAI-compatible API (`http://127.0.0.1:1234` by default).
enum LMStudioLLMClient {
    static var host: String {
        let raw = ProcessInfo.processInfo.environment["LMSTUDIO_HOST"]
            ?? ProcessInfo.processInfo.environment["MIRRORUE_LLM_HOST"]
            ?? "http://127.0.0.1:1234"
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") {
            base = String(base.dropLast(3))
            while base.hasSuffix("/") { base.removeLast() }
        }
        return base
    }

    static var apiBase: String { "\(host)/v1" }

    static var model: String {
        ProcessInfo.processInfo.environment["MIRRORUE_LLM_MODEL"]
            ?? ProcessInfo.processInfo.environment["LMSTUDIO_MODEL"]
            ?? ""
    }

    private static func listModels(timeout: TimeInterval = 3) -> [String] {
        guard let url = URL(string: "\(apiBase)/models") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var ids: [String] = []
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json["data"] as? [[String: Any]] else { return }
            ids = rows.compactMap { ($0["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return ids
    }

    private static func assistantText(from message: [String: Any]) -> String {
        let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !content.isEmpty { return content }
        let reasoning = (message["reasoning_content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if reasoning.isEmpty { return "" }
        let patterns = [
            #"\{[^{}]*"acts"\s*:\s*\[[^\]]*\][^{}]*\}"#,
            #"\{[^{}]*"see"\s*:[^{}]*\}"#,
            #"`(\{.*?\})`"#,
            #"(\{[^{}]*\})"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            let range = NSRange(reasoning.startIndex..<reasoning.endIndex, in: reasoning)
            let matches = regex.matches(in: reasoning, options: [], range: range)
            if let last = matches.last, last.numberOfRanges > 1,
               let r = Range(last.range(at: 1), in: reasoning) ?? Range(last.range, in: reasoning) {
                return String(reasoning[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let last = matches.last, let r = Range(last.range, in: reasoning) {
                return String(reasoning[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let lines = reasoning.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let last = lines.last { return String(last) }
        return reasoning
    }

    private static var defaultMaxTokens: Int {
        if let raw = ProcessInfo.processInfo.environment["MIRRORUE_LLM_MAX_TOKENS"],
           let n = Int(raw), n > 0 { return n }
        return 384
    }

    private static func resolveModel() -> String? {
        let configured = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        return listModels().first
    }

    static func status() -> [String: Any] {
        let models = listModels()
        let resolved = resolveModel()
        var out: [String: Any] = [
            "ok": false,
            "provider": "lmstudio",
            "host": host,
            "model": resolved ?? model,
            "enabled": true,
        ]
        if models.isEmpty {
            out["error"] = "lmstudio unreachable or no models loaded"
            out["detail"] = "start LM Studio and load a model"
            return out
        }
        out["ok"] = true
        out["models"] = models
        out["detail"] = resolved.map { "ok (\($0))" } ?? "ok"
        return out
    }

    static func chat(payload: [String: Any]) -> (status: Int, json: [String: Any]) {
        let messages = payload["messages"] as? [[String: Any]]
            ?? [["role": "user", "content": payload["prompt"] as? String ?? payload["question"] as? String ?? ""]]
        let maxTokens = payload["max_tokens"] as? Int ?? payload["maxTokens"] as? Int ?? defaultMaxTokens
        let temperature = payload["temperature"] as? Double ?? 0.0
        let reqModel = (payload["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model = (reqModel?.isEmpty == false ? reqModel : resolveModel()) else {
            return (503, [
                "ok": false,
                "provider": "lmstudio",
                "error": "no model loaded in LM Studio",
                "detail": "load Qwen (or any model) in LM Studio",
            ])
        }

        guard let url = URL(string: "\(apiBase)/chat/completions") else {
            return (400, ["ok": false, "error": "invalid LMSTUDIO_HOST"])
        }

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return (400, ["ok": false, "error": "invalid body"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 120

        let sem = DispatchSemaphore(value: 0)
        var status = 503
        var json: [String: Any] = ["ok": false, "error": "timeout"]

        URLSession.shared.dataTask(with: req) { respData, resp, err in
            defer { sem.signal() }
            if let err {
                json = ["ok": false, "error": err.localizedDescription, "provider": "lmstudio"]
                status = 503
                return
            }
            guard let http = resp as? HTTPURLResponse else {
                json = ["ok": false, "error": "no response"]
                return
            }
            status = http.statusCode
            guard let respData,
                  var obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
                json = ["ok": false, "error": "decode failed"]
                return
            }
            let choices = obj["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any] ?? [:]
            let text = assistantText(from: message)
            let usage = obj["usage"] as? [String: Any]
            obj["ok"] = (200..<300).contains(http.statusCode)
            obj["text"] = text
            obj["provider"] = "lmstudio"
            obj["model"] = model
            if let usage {
                obj["usage"] = [
                    "completion": usage["completion_tokens"] as? Int ?? 0,
                    "prompt_est": usage["prompt_tokens"] as? Int ?? 0,
                    "latency_ms": 0,
                ]
            }
            json = obj
        }.resume()

        _ = sem.wait(timeout: .now() + 125)
        if !json.keys.contains("ok") { json["ok"] = false }
        return (status == 200 ? 200 : (status >= 400 ? status : 503), json)
    }
}
