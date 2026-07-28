import Foundation
import Network
import ControlKit

/// Loopback-only HTTP API for scripting MirrorUE (Phase 5 / automation).
///
/// Default: `http://127.0.0.1:8090`
///
/// ```
/// GET  /v1/status
/// POST /v1/tap          {"x":0.5,"y":0.8}
/// POST /v1/swipe        {"x":0.5,"y":0.8,"x1":0.5,"y1":0.2,"ms":300}
/// POST /v1/type         {"text":"hello"}
/// POST /v1/key          {"usage":40,"mods":0}
/// POST /v1/button       {"name":"home"}
/// POST /v1/workflows/run  <workflow JSON body>
/// ```
final class LocalAPIServer {
    static let shared = LocalAPIServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mirrorue.local-api")
    private(set) var port: UInt16 = 8090
    private(set) var isRunning = false

    /// Injected by the app once connected.
    var controlProvider: (() -> ControlClient?)?
    var touchModeProvider: (() -> TouchMap.Mode)?
    var statusProvider: (() -> [String: Any])?

    private init() {}

    func start(port: UInt16 = 8090) {
        stop()
        self.port = port
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.isRunning = true
                    fputs("LocalAPI: listening on 127.0.0.1:\(port)\n", stderr)
                }
                if case .failed(let err) = state {
                    fputs("LocalAPI: failed \(err)\n", stderr)
                    self?.isRunning = false
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            fputs("LocalAPI: cannot bind :\(port) — \(error)\n", stderr)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: buf.startIndex..<range.lowerBound)
                let header = String(data: headerData, encoding: .utf8) ?? ""
                let contentLength = Self.contentLength(from: header)
                let bodyStart = range.upperBound
                let have = buf.count - bodyStart
                if have >= contentLength {
                    let body = buf.subdata(in: bodyStart..<(bodyStart + contentLength))
                    self.dispatch(header: header, body: body, connection: connection)
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buf)
        }
    }

    private static func contentLength(from header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func dispatch(header: String, body: Data, connection: NWConnection) {
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            respond(connection, status: 400, json: ["error": "bad request"])
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(connection, status: 400, json: ["error": "bad request"])
            return
        }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? String(parts[1])

        // Loopback-only: reject if remote isn't localhost (best-effort).
        if let endpoint = connection.currentPath?.remoteEndpoint, case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let v4) where v4 == .loopback: break
            case .ipv6(let v6) where v6 == .loopback: break
            case .name(let name, _) where name == "localhost": break
            default:
                respond(connection, status: 403, json: ["error": "loopback only"])
                return
            }
        }

        Task { @MainActor in
            let result = await self.route(method: method, path: path, body: body)
            self.respond(connection, status: result.status, json: result.json)
        }
    }

    @MainActor
    private func route(method: String, path: String, body: Data) async -> (status: Int, json: [String: Any]) {
        if method == "GET" && (path == "/v1/status" || path == "/status") {
            var payload = statusProvider?() ?? [:]
            payload["api"] = "mirrorue-local"
            payload["version"] = 1
            payload["ok"] = true
            return (200, payload)
        }

        guard let control = controlProvider?() else {
            return (503, ["error": "not connected"])
        }
        let mode = touchModeProvider?() ?? .portrait
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

        switch (method, path) {
        case ("POST", "/v1/tap"), ("POST", "/tap"):
            let x = json["x"] as? Double ?? 0.5
            let y = json["y"] as? Double ?? 0.5
            await WorkflowPlayer.shared.runOne(.tap(x: x, y: y), control: control, mode: mode)
            return (200, ["ok": true, "action": "tap", "x": x, "y": y])

        case ("POST", "/v1/swipe"), ("POST", "/swipe"):
            let x = json["x"] as? Double ?? 0.5
            let y = json["y"] as? Double ?? 0.8
            let x1 = json["x1"] as? Double ?? x
            let y1 = json["y1"] as? Double ?? 0.2
            let ms = json["ms"] as? Int ?? 300
            await WorkflowPlayer.shared.runOne(
                .swipe(x0: x, y0: y, x1: x1, y1: y1, ms: ms),
                control: control, mode: mode
            )
            return (200, ["ok": true, "action": "swipe"])

        case ("POST", "/v1/type"), ("POST", "/type"):
            let text = json["text"] as? String ?? ""
            await WorkflowPlayer.shared.runOne(.type(text), control: control, mode: mode)
            return (200, ["ok": true, "action": "type", "chars": text.count])

        case ("POST", "/v1/key"), ("POST", "/key"):
            let usage = UInt16(json["usage"] as? Int ?? 0)
            let mods = UInt8(json["mods"] as? Int ?? 0)
            await WorkflowPlayer.shared.runOne(.key(usage: usage, mods: mods), control: control, mode: mode)
            return (200, ["ok": true, "action": "key"])

        case ("POST", "/v1/button"), ("POST", "/button"):
            let name = json["name"] as? String ?? "home"
            await WorkflowPlayer.shared.runOne(.button(name), control: control, mode: mode)
            return (200, ["ok": true, "action": "button", "name": name])

        case ("POST", "/v1/workflows/run"), ("POST", "/workflows/run"):
            do {
                let wf = try JSONDecoder().decode(Workflow.self, from: body)
                // Synchronous run for API simplicity.
                for step in wf.steps {
                    await WorkflowPlayer.shared.runOne(step, control: control, mode: mode)
                }
                return (200, ["ok": true, "steps": wf.steps.count, "name": wf.name])
            } catch {
                return (400, ["error": "invalid workflow JSON", "detail": "\(error)"])
            }

        default:
            return (404, ["error": "not found", "path": path])
        }
    }

    private func respond(_ connection: NWConnection, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let reason: String = {
            switch status {
            case 200: return "OK"
            case 400: return "Bad Request"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 503: return "Service Unavailable"
            default: return "Error"
            }
        }()
        var msg = "HTTP/1.1 \(status) \(reason)\r\n"
        msg += "Content-Type: application/json\r\n"
        msg += "Content-Length: \(body.count)\r\n"
        msg += "Connection: close\r\n\r\n"
        var data = Data(msg.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

extension WorkflowPlayer {
    /// Run a single step (used by LocalAPI).
    @MainActor
    func runOne(_ step: WorkflowStep, control: ControlClient, mode: TouchMap.Mode) async {
        await execute(step, control: control, mode: mode)
    }
}
