import Foundation
import Network
import ControlKit

/// Loopback-only HTTP API for scripting MirrorUE from the CLI.
///
/// Default: `http://127.0.0.1:8090`
///
/// Namespaces (v3):
/// ```
/// GET  /v1                      → endpoint map
/// GET  /v1/status
/// GET  /v1/vision/frame         ?maxW=720&format=jpg&encoding=path|b64
/// POST /v1/control/{tap,swipe,type,home,open,do,…}
/// POST /v1/workflows/record|play|save   GET /v1/workflows/list
/// ```
///
/// Legacy aliases without namespace prefix remain supported (`/v1/tap`, `/v1/frame`, …).
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
    /// Writes the latest phone frame; returns path or nil. maxWidth 0 = full size.
    var frameProvider: ((_ maxWidth: Int, _ format: String) -> String?)?

    private static var frameSeq: UInt = 0

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
        let fullPath = String(parts[1])
        let pathParts = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(pathParts[0])
        var query: [String: String] = [:]
        if pathParts.count > 1 {
            for pair in pathParts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0]).lowercased()] = String(kv[1])
                        .removingPercentEncoding ?? String(kv[1])
                }
            }
        }

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
            let result = await self.route(method: method, path: path, query: query, body: body)
            self.respond(connection, status: result.status, json: result.json)
        }
    }

    @MainActor
    private func route(
        method: String,
        path: String,
        query: [String: String],
        body: Data
    ) async -> (status: Int, json: [String: Any]) {
        let norm = Self.remapLegacy(Self.normalize(path))

        if method == "GET" && (norm == "/v1" || norm == "/v1/help" || norm == "/help") {
            return (200, Self.helpPayload())
        }

        if method == "GET" && (norm == "/v1/status" || norm == "/status") {
            var payload = statusProvider?() ?? [:]
            payload["api"] = "mirrorue-local"
            payload["version"] = 3
            payload["ok"] = true
            return (200, payload)
        }

        if method == "GET" && (norm == "/v1/docs" || norm == "/docs") {
            return (200, Self.docsPayload())
        }

        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

        if let wfResult = await handleWorkflows(method: method, norm: norm, json: json, body: body) {
            return wfResult
        }

        if method == "GET" && Self.isFramePath(norm) {
            return handleFrame(query: query)
        }

        guard let control = controlProvider?() else {
            return (503, ["ok": false, "error": "not connected"])
        }
        let mode = touchModeProvider?() ?? .portrait

        switch (method, norm) {
        case ("POST", "/v1/home"), ("POST", "/home"):
            await LocalAPIMacros.goHome(control: control, mode: mode)
            return (200, ["ok": true, "action": "home"])

        case ("POST", "/v1/wait"), ("POST", "/wait"):
            let ms = Self.waitMs(from: json)
            await LocalAPIMacros.sleepMs(ms)
            return (200, ["ok": true, "action": "wait", "ms": ms])

        case ("POST", "/v1/spotlight"), ("POST", "/spotlight"):
            let goHome = (json["home"] as? Bool) ?? true
            await LocalAPIMacros.openSpotlight(control: control, mode: mode, goHome: goHome)
            return (200, ["ok": true, "action": "spotlight", "home": goHome])

        case ("POST", "/v1/clear"), ("POST", "/clear"),
             ("POST", "/v1/clear_field"), ("POST", "/clear_field"):
            let backspaces = max(0, min(60, json["backspaces"] as? Int ?? 28))
            await LocalAPIMacros.clearField(control: control, mode: mode, backspaces: backspaces)
            return (200, ["ok": true, "action": "clear", "backspaces": backspaces])

        case ("POST", "/v1/open"), ("POST", "/open"),
             ("POST", "/v1/open_app"), ("POST", "/open_app"):
            let app = (json["app"] as? String ?? json["name"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.isEmpty else {
                return (400, ["ok": false, "error": "app required"])
            }
            await LocalAPIMacros.openApp(app, control: control, mode: mode)
            return (200, ["ok": true, "action": "open", "app": app])

        case ("POST", "/v1/do"), ("POST", "/do"):
            return await runDo(json: json, body: body, control: control, mode: mode)

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
            let resetBefore = (json["resetBefore"] as? Bool) ?? (json["reset_before"] as? Bool) ?? true
            await WorkflowPlayer.shared.runType(text, control: control, resetBefore: resetBefore)
            return (200, ["ok": true, "action": "type", "chars": text.count])

        case ("POST", "/v1/key"), ("POST", "/key"):
            let usage = UInt16(json["usage"] as? Int ?? 0)
            let mods = UInt8(json["mods"] as? Int ?? 0)
            await WorkflowPlayer.shared.runOne(.key(usage: usage, mods: mods), control: control, mode: mode)
            return (200, ["ok": true, "action": "key"])

        case ("POST", "/v1/keyboard/reset"), ("POST", "/keyboard/reset"):
            control.keyboardReset()
            return (200, ["ok": true, "action": "keyboard_reset"])

        case ("POST", "/v1/button"), ("POST", "/button"):
            let name = json["name"] as? String ?? "home"
            await WorkflowPlayer.shared.runOne(.button(name), control: control, mode: mode)
            return (200, ["ok": true, "action": "button", "name": name])

        case ("POST", "/v1/workflows/run"), ("POST", "/workflows/run"):
            guard let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return (400, ["ok": false, "error": "name required — inline workflow JSON import is disabled"])
            }
            do {
                let wf = try WorkflowStore.load(named: name)
                for step in wf.steps {
                    await WorkflowPlayer.shared.runOne(step, control: control, mode: mode)
                }
                return (200, ["ok": true, "steps": wf.steps.count, "name": wf.name])
            } catch {
                return (404, ["ok": false, "error": "path not found: \(name)"])
            }

        default:
            return (404, ["ok": false, "error": "not found", "path": path, "hint": "GET /v1"])
        }
    }

    @MainActor
    private func handleWorkflows(
        method: String,
        norm: String,
        json: [String: Any],
        body: Data
    ) async -> (status: Int, json: [String: Any])? {
        switch (method, norm) {
        case ("GET", "/v1/workflows"), ("GET", "/v1/workflows/list"), ("GET", "/workflows/list"):
            return (200, [
                "ok": true,
                "directory": WorkflowStore.directory.path,
                "workflows": WorkflowStore.listSummaries(),
                "recording": WorkflowRecorder.shared.isRecording,
                "playing": WorkflowPlayer.shared.isPlaying,
                "liveSteps": WorkflowRecorder.shared.steps.count,
            ])
        case ("GET", "/v1/workflows/status"), ("GET", "/workflows/status"):
            return (200, [
                "ok": true,
                "recording": WorkflowRecorder.shared.isRecording,
                "playing": WorkflowPlayer.shared.isPlaying,
                "liveSteps": WorkflowRecorder.shared.steps.count,
            ])
        case ("POST", "/v1/workflows/record/start"), ("POST", "/workflows/record/start"):
            WorkflowRecorder.shared.start()
            return (200, ["ok": true, "action": "record-start"])
        case ("POST", "/v1/workflows/record/stop"), ("POST", "/workflows/record/stop"):
            let wf = WorkflowRecorder.shared.stop()
            var payload: [String: Any] = [
                "ok": true,
                "action": "record-stop",
                "steps": wf.steps.count,
            ]
            if let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                var named = wf
                named.name = name
                do {
                    let url = try WorkflowStore.save(named)
                    payload["saved"] = url.path
                    payload["name"] = name
                } catch {
                    return (400, ["ok": false, "error": "\(error)"])
                }
            }
            if let data = try? JSONEncoder().encode(wf),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                payload["workflow"] = obj
            }
            return (200, payload)
        case ("POST", "/v1/workflows/save"), ("POST", "/workflows/save"):
            let name = (json["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return (400, ["ok": false, "error": "name required"])
            }
            guard !WorkflowRecorder.shared.steps.isEmpty else {
                return (400, ["ok": false, "error": "no steps — record first"])
            }
            var wf = Workflow(name: name, steps: WorkflowRecorder.shared.steps)
            wf.name = name
            do {
                let url = try WorkflowStore.save(wf)
                return (200, ["ok": true, "path": url.path, "name": name, "steps": wf.steps.count])
            } catch {
                return (400, ["ok": false, "error": "\(error)"])
            }
        case ("POST", "/v1/workflows/stop"), ("POST", "/workflows/stop"):
            WorkflowPlayer.shared.cancel()
            return (200, ["ok": true, "action": "play-stop"])
        case ("POST", "/v1/workflows/play"), ("POST", "/workflows/play"):
            guard let control = controlProvider?() else {
                return (503, ["ok": false, "error": "not connected"])
            }
            let mode = touchModeProvider?() ?? .portrait
            guard let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return (400, ["ok": false, "error": "name required — import from disk is disabled"])
            }
            let wf: Workflow
            do {
                wf = try WorkflowStore.load(named: name)
            } catch {
                return (404, ["ok": false, "error": "path not found: \(name)"])
            }
            for step in wf.steps {
                await WorkflowPlayer.shared.runOne(step, control: control, mode: mode)
            }
            return (200, ["ok": true, "name": wf.name, "steps": wf.steps.count])
        case ("POST", "/v1/workflows/export"), ("POST", "/workflows/export"):
            guard let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return (400, ["ok": false, "error": "name required"])
            }
            guard let dest = (json["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !dest.isEmpty else {
                return (400, ["ok": false, "error": "path required (destination file)"])
            }
            do {
                let url = try WorkflowStore.export(named: name, to: URL(fileURLWithPath: dest))
                return (200, ["ok": true, "exported": url.path, "name": name])
            } catch {
                return (400, ["ok": false, "error": "\(error)"])
            }
        default:
            return nil
        }
    }

    @MainActor
    private func handleFrame(query: [String: String]) -> (status: Int, json: [String: Any]) {
        let maxW = Int(query["maxw"] ?? query["maxwidth"] ?? "720") ?? 720
        let format = query["format"] ?? "jpg"
        let encoding = (query["encoding"] ?? "path").lowercased()
        guard let framePath = frameProvider?(maxW, format) else {
            return (503, ["ok": false, "error": "no live frame"])
        }
        var size = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: framePath),
           let n = attrs[.size] as? NSNumber {
            size = n.intValue
        }
        Self.frameSeq = Self.frameSeq &+ 1
        let frameId = "f\(Self.frameSeq)"
        var payload: [String: Any] = [
            "ok": true,
            "frameId": frameId,
            "path": framePath,
            "bytes": size,
            "maxW": maxW,
            "format": format,
            "encoding": encoding,
        ]
        if encoding == "b64" || encoding == "base64" {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: framePath)) {
                payload["b64"] = data.base64EncodedString()
                payload["encoding"] = "b64"
            } else {
                return (500, ["ok": false, "error": "frame read failed"])
            }
        }
        return (200, payload)
    }

    private static func isFramePath(_ norm: String) -> Bool {
        norm == "/v1/frame" || norm == "/frame"
            || norm == "/v1/screenshot"
            || norm == "/v1/vision/frame" || norm == "/vision/frame"
    }

    /// Map `/v1/control/tap` → `/v1/tap`, etc.
    private static func remapLegacy(_ norm: String) -> String {
        if norm.hasPrefix("/v1/control/") {
            return "/v1/" + norm.dropFirst("/v1/control/".count)
        }
        if norm == "/v1/control/do" { return "/v1/do" }
        if norm.hasPrefix("/control/") {
            return "/v1/" + norm.dropFirst("/control/".count)
        }
        return norm
    }

    @MainActor
    private func runDo(
        json: [String: Any],
        body: Data,
        control: ControlClient,
        mode: TouchMap.Mode
    ) async -> (status: Int, json: [String: Any]) {
        let rawSteps: [[String: Any]]
        if let arr = json["steps"] as? [[String: Any]] {
            rawSteps = arr
        } else if let arr = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] {
            rawSteps = arr
        } else {
            return (400, ["ok": false, "error": "steps array required"])
        }

        var done: [String] = []
        for (i, step) in rawSteps.enumerated() {
            let op = ((step["op"] as? String) ?? (step["kind"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch op {
            case "home":
                await LocalAPIMacros.goHome(control: control, mode: mode)
                done.append("home")
            case "wait":
                let ms = Self.waitMs(from: step)
                await LocalAPIMacros.sleepMs(ms)
                done.append("wait:\(ms)")
            case "spotlight":
                let goHome = (step["home"] as? Bool) ?? false
                await LocalAPIMacros.openSpotlight(control: control, mode: mode, goHome: goHome)
                done.append("spotlight")
            case "clear", "clear_field":
                let n = max(0, min(40, step["backspaces"] as? Int ?? 12))
                await LocalAPIMacros.clearField(control: control, mode: mode, backspaces: n)
                done.append("clear")
            case "open", "open_app":
                let app = (step["app"] as? String ?? step["name"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !app.isEmpty else {
                    return (400, ["ok": false, "error": "open requires app", "at": i, "done": done])
                }
                await LocalAPIMacros.openApp(app, control: control, mode: mode)
                done.append("open:\(app)")
            case "tap":
                let x = step["x"] as? Double ?? 0.5
                let y = step["y"] as? Double ?? 0.5
                await WorkflowPlayer.shared.runOne(.tap(x: x, y: y), control: control, mode: mode)
                done.append("tap")
            case "swipe":
                let x = step["x"] as? Double ?? 0.5
                let y = step["y"] as? Double ?? 0.8
                let x1 = step["x1"] as? Double ?? x
                let y1 = step["y1"] as? Double ?? 0.2
                let ms = step["ms"] as? Int ?? 300
                await WorkflowPlayer.shared.runOne(
                    .swipe(x0: x, y0: y, x1: x1, y1: y1, ms: ms),
                    control: control, mode: mode
                )
                done.append("swipe")
            case "type":
                let text = step["text"] as? String ?? ""
                let reset = (step["reset_before"] as? Bool) ?? (step["resetBefore"] as? Bool) ?? true
                await WorkflowPlayer.shared.runType(text, control: control, resetBefore: reset)
                done.append("type")
            case "enter", "return", "ret":
                await WorkflowPlayer.shared.runOne(.key(usage: 40, mods: 0), control: control, mode: mode)
                done.append("enter")
            case "key":
                let usage = UInt16(step["usage"] as? Int ?? 0)
                let mods = UInt8(step["mods"] as? Int ?? 0)
                await WorkflowPlayer.shared.runOne(.key(usage: usage, mods: mods), control: control, mode: mode)
                done.append("key")
            case "button":
                let name = step["name"] as? String ?? "home"
                await WorkflowPlayer.shared.runOne(.button(name), control: control, mode: mode)
                done.append("button:\(name)")
            case "":
                return (400, ["ok": false, "error": "missing op", "at": i, "done": done])
            default:
                return (400, ["ok": false, "error": "unknown op \(op)", "at": i, "done": done])
            }
        }
        return (200, ["ok": true, "action": "do", "count": done.count, "done": done])
    }

    private static func waitMs(from json: [String: Any]) -> Int {
        if let ms = json["ms"] as? Int { return max(0, ms) }
        if let ms = json["ms"] as? Double { return max(0, Int(ms)) }
        if let s = json["seconds"] as? Double { return max(0, Int(s * 1000)) }
        if let s = json["seconds"] as? Int { return max(0, s * 1000) }
        return 500
    }

    private static func normalize(_ path: String) -> String {
        if path.count > 1, path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }

    private static func helpPayload() -> [String: Any] {
        [
            "ok": true,
            "api": "mirrorue-local",
            "version": 3,
            "engine": "MirrorUE HID + recorded paths",
            "cli": "./tools/mirrorue <cmd>",
            "docs": "GET /v1/docs · docs/API.md",
            "namespaces": [
                "workflows": "GET /v1/workflows · POST record/start|stop · save · play",
                "control": "POST /v1/control/{tap,swipe,type,key,button,home,wait,spotlight,clear,open,do}",
                "vision": "GET /v1/vision/frame",
            ],
            "endpoints": [
                "GET  /v1/workflows",
                "POST /v1/workflows/record/start",
                "POST /v1/workflows/record/stop {name?}",
                "POST /v1/workflows/save {name}",
                "POST /v1/workflows/play {name}",
                "POST /v1/workflows/stop",
                "GET  /v1/vision/frame",
                "POST /v1/control/*",
            ],
            "pathsDirectory": WorkflowStore.directory.path,
            "legacy": [
                "/v1/frame", "/v1/tap", "/v1/home", "/v1/open", "/v1/do", "/v1/workflows/run",
            ],
        ]
    }

    private static func docsPayload() -> [String: Any] {
        var candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("docs/API.md"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/MirrorUE/docs/API.md"),
        ]
        var walk = Bundle.main.bundleURL
        for _ in 0..<8 {
            candidates.append(walk.appendingPathComponent("docs/API.md"))
            let parent = walk.deletingLastPathComponent()
            if parent.path == walk.path { break }
            walk = parent
        }
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return ["ok": true, "path": url.path, "markdown": text]
            }
        }
        return [
            "ok": true,
            "hint": "See docs/API.md in the MirrorUE repo",
            "url": "https://github.com/KamilBourouiba/MirrorUE/blob/main/docs/API.md",
        ]
    }

    private func respond(_ connection: NWConnection, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let reason: String = {
            switch status {
            case 200: return "OK"
            case 202: return "Accepted"
            case 400: return "Bad Request"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 409: return "Conflict"
            case 429: return "Too Many Requests"
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
    @MainActor
    func runOne(_ step: WorkflowStep, control: ControlClient, mode: TouchMap.Mode) async {
        await execute(step, control: control, mode: mode)
    }
}
