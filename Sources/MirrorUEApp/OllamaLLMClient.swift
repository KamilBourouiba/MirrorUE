import Foundation

/// HTTP client for Ollama (`http://127.0.0.1:11434` by default).
enum OllamaLLMClient {
    static var host: String {
        ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "http://127.0.0.1:11434"
    }

    static var model: String {
        ProcessInfo.processInfo.environment["MIRRORUE_LLM_MODEL"]
            ?? ProcessInfo.processInfo.environment["OLLAMA_MODEL"]
            ?? "llama3.2"
    }

    static func status() -> [String: Any] {
        guard let url = URL(string: "\(host)/api/tags") else {
            return ["ok": false, "error": "invalid OLLAMA_HOST"]
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = ["ok": false, "provider": "ollama", "host": host, "model": model]
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err {
                out["error"] = err.localizedDescription
                out["detail"] = "ollama unreachable"
                return
            }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                out["error"] = "bad response"
                return
            }
            let models = (json["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            out["ok"] = true
            out["models"] = models
            out["detail"] = models.isEmpty ? "no models pulled" : "ok"
        }.resume()
        _ = sem.wait(timeout: .now() + 4)
        return out
    }

    static func chat(payload: [String: Any]) -> (status: Int, json: [String: Any]) {
        let messages = payload["messages"] as? [[String: Any]]
            ?? [["role": "user", "content": payload["prompt"] as? String ?? payload["question"] as? String ?? ""]]
        let maxTokens = payload["max_tokens"] as? Int ?? payload["maxTokens"] as? Int ?? 256
        let reqModel = payload["model"] as? String ?? Self.model
        let temperature = payload["temperature"] as? Double ?? 0.0

        guard let url = URL(string: "\(host)/api/chat") else {
            return (400, ["ok": false, "error": "invalid OLLAMA_HOST"])
        }

        let body: [String: Any] = [
            "model": reqModel,
            "messages": messages,
            "stream": false,
            "options": ["num_predict": maxTokens, "temperature": temperature],
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
                json = ["ok": false, "error": err.localizedDescription, "provider": "ollama"]
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
            let text = (obj["message"] as? [String: Any])?["content"] as? String ?? ""
            obj["ok"] = (200..<300).contains(http.statusCode)
            obj["text"] = text
            obj["provider"] = "ollama"
            obj["model"] = reqModel
            if let eval = obj["eval_count"] as? Int {
                obj["usage"] = [
                    "completion": eval,
                    "prompt_est": obj["prompt_eval_count"] as? Int ?? 0,
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
