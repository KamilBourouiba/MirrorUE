import Foundation
import Network
import ControlKit
import CoreImage
import CoreGraphics
import CryptoKit

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
    /// Returns raw in-memory encoded JPEG data directly (~2ms GPU hardware encoding).
    var rawFrameProvider: ((_ maxWidth: Int) -> Data?)?
    /// Allow connections from LAN / public tunnels
    var allowRemote: Bool = true
    var beginControlAction: (() -> Bool)?
    var endControlAction: (() -> Void)?
    var beginWorkflowPlayback: (() -> Bool)?
    var endWorkflowPlayback: (() -> Void)?
    typealias JSONResult = (status: Int, json: [String: Any])
    typealias AsyncJSONHandler = (_ payload: [String: Any]) async -> JSONResult
    var llmStatusHandler: (() async -> JSONResult)?
    var llmChatHandler: AsyncJSONHandler?
    var agentRunHandler: AsyncJSONHandler?
    var agentStatusHandler: (() async -> JSONResult)?
    var agentLogsHandler: (() async -> JSONResult)?
    var agentStopHandler: AsyncJSONHandler?
    var aiRunActiveProvider: (() async -> Bool)?

    private static var frameSeq: UInt = 0

    /// Reactive stream continuations
    private var h264Continuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var frameContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    private let frameLock = NSLock()

    /// True when at least one WebSocket or MJPEG client is actively subscribed.
    var hasStreamingClients: Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        return !h264Continuations.isEmpty || !frameContinuations.isEmpty
    }

    var hasH264StreamingClients: Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        return !h264Continuations.isEmpty
    }

    var hasJPEGStreamingClients: Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        return !frameContinuations.isEmpty
    }

    /// Call this from H264StreamEncoder whenever a new H.264 Annex B packet is ready.
    func pushH264Frame(_ packet: Data) {
        frameLock.lock()
        let conts = h264Continuations
        frameLock.unlock()
        for cont in conts.values {
            cont.yield(packet)
        }
    }

    /// Call this whenever a new GPU-encoded JPEG is ready.
    func pushFrame(_ jpeg: Data) {
        frameLock.lock()
        let conts = frameContinuations
        frameLock.unlock()
        for cont in conts.values {
            cont.yield(jpeg)
        }
    }

    private func subscribeH264Frames() -> (id: UUID, stream: AsyncStream<Data>) {
        let id = UUID()
        var cont: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(4)) { cont = $0 }
        frameLock.lock()
        h264Continuations[id] = cont
        frameLock.unlock()
        return (id, stream)
    }

    private func unsubscribeH264Frames(id: UUID) {
        frameLock.lock()
        h264Continuations.removeValue(forKey: id)
        frameLock.unlock()
    }

    private func subscribeFrames() -> (id: UUID, stream: AsyncStream<Data>) {
        let id = UUID()
        var cont: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(2)) { cont = $0 }
        frameLock.lock()
        frameContinuations[id] = cont
        frameLock.unlock()
        return (id, stream)
    }

    private func unsubscribeFrames(id: UUID) {
        frameLock.lock()
        frameContinuations.removeValue(forKey: id)
        frameLock.unlock()
    }

    private init() {}

    func start(port: UInt16 = 8090) {
        if isRunning, listener != nil, self.port == port { return }
        stop()
        self.port = port
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
            let listener: NWListener
            if allowRemote {
                listener = try NWListener(using: params, on: endpointPort)
            } else {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
                listener = try NWListener(using: params)
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.isRunning = true
                    fputs("LocalAPI: listening on http://0.0.0.0:\(port) (Local + LAN ready)\n", stderr)
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
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
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
                    let leftover = buf.subdata(in: (bodyStart + contentLength)..<buf.count)
                    self.dispatch(header: header, body: body, connection: connection)
                    self.receive(on: connection, buffer: leftover)
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

        if !allowRemote, let endpoint = connection.currentPath?.remoteEndpoint, case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let v4) where v4 == .loopback: break
            case .ipv6(let v6) where v6 == .loopback: break
            case .name(let name, _) where name == "localhost": break
            default:
                respond(connection, status: 403, json: ["error": "loopback only"])
                return
            }
        }

        if header.lowercased().contains("upgrade: websocket") || header.lowercased().contains("sec-websocket-key") || path == "/v1/ws" || path == "/ws" {
            handleWebSocketUpgrade(header: header, connection: connection)
            return
        }

        if method == "OPTIONS" {
            respondRaw(connection, status: 204, contentType: "text/plain", body: Data())
            return
        }

        if (method == "GET" || method == "HEAD") && (path == "/" || path == "/web" || path == "/web/" || path == "/index.html") {
            let body = method == "HEAD" ? Data() : Data(Self.webHTMLPage().utf8)
            respondRaw(connection, status: 200, contentType: "text/html; charset=utf-8", body: body)
            return
        }

        if method == "GET" && (path == "/v1/stream" || path == "/v1/screen.mjpeg" || path == "/stream" || path == "/mjpeg") {
            let maxW = (query["maxwidth"] ?? query["max_width"] ?? query["w"]).flatMap(Int.init) ?? 720
            respondMJPEGStream(connection, maxWidth: maxW)
            return
        }

        if method == "GET" && (path == "/v1/screen.jpg" || path == "/v1/screen.jpeg" || path == "/screen.jpg" || path == "/v1/screen.raw") {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let maxW = (query["maxwidth"] ?? query["max_width"] ?? query["w"]).flatMap(Int.init) ?? 720
                if let data = self.rawFrameProvider?(maxW) {
                    self.respondRaw(connection, status: 200, contentType: "image/jpeg", body: data)
                } else if let framePath = self.frameProvider?(maxW, "jpg"),
                          let data = try? Data(contentsOf: URL(fileURLWithPath: framePath)) {
                    self.respondRaw(connection, status: 200, contentType: "image/jpeg", body: data)
                } else {
                    self.respondRaw(connection, status: 200, contentType: "image/jpeg", body: Self.standbyJPEGData)
                }
            }
            return
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

        default:
            return (404, ["ok": false, "error": "not found", "path": path, "hint": "GET /v1"])
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
            "engine": "MirrorUE HID control",
            "cli": "./tools/mirrorue <cmd>",
            "docs": "GET /v1/docs · docs/API.md",
            "namespaces": [
                "control": "POST /v1/control/{tap,swipe,type,key,button,home,wait,spotlight,clear,open,do}",
                "vision": "GET /v1/vision/frame",
            ],
            "endpoints": [
                "GET  /v1/vision/frame",
                "POST /v1/control/*",
            ],
            "legacy": [
                "/v1/frame", "/v1/tap", "/v1/home", "/v1/open", "/v1/do",
            ],
            "pro": "Path automation: https://github.com/KamilBourouiba/MirrorUE-Pro",
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

    private static let standbyJPEGData: Data = {
        let ci = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.08))
            .cropped(to: CGRect(x: 0, y: 0, width: 720, height: 1280))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.jpegRepresentation(of: ci, colorSpace: colorSpace, options: [:]) ?? Data()
    }()

    private func respondMJPEGStream(_ connection: NWConnection, maxWidth: Int) {
        let boundary = "frame_boundary_mirrorue"
        var msg = "HTTP/1.1 200 OK\r\n"
        msg += "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n"
        msg += "Cache-Control: no-cache, no-store, must-revalidate\r\n"
        msg += "Access-Control-Allow-Origin: *\r\n"
        msg += "Connection: keep-alive\r\n\r\n"
        
        connection.send(content: Data(msg.utf8), completion: .contentProcessed { err in
            if err != nil { connection.cancel() }
        })
        
        Task { [weak self] in
            guard let self else { return }
            let (subId, frameStream) = self.subscribeFrames()
            defer { self.unsubscribeFrames(id: subId) }

            for await jpeg in frameStream {
                guard connection.state == .ready else { break }
                var part = "--\(boundary)\r\n"
                part += "Content-Type: image/jpeg\r\n"
                part += "Content-Length: \(jpeg.count)\r\n\r\n"
                var chunk = Data(part.utf8)
                chunk.append(jpeg)
                chunk.append(Data("\r\n".utf8))
                let sendOk = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                    connection.send(content: chunk, completion: .contentProcessed { c.resume(returning: $0 == nil) })
                }
                if !sendOk { break }
            }
            connection.cancel()
        }
    }

    private func handleWebSocketUpgrade(header: String, connection: NWConnection) {
        var clientKey = ""
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "sec-websocket-key" {
                clientKey = parts[1].trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard !clientKey.isEmpty else {
            respond(connection, status: 400, json: ["error": "missing sec-websocket-key"])
            return
        }

        let acceptKey = Self.computeWSAcceptKey(clientKey)
        var msg = "HTTP/1.1 101 Switching Protocols\r\n"
        msg += "Upgrade: websocket\r\n"
        msg += "Connection: Upgrade\r\n"
        msg += "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"

        connection.send(content: Data(msg.utf8), completion: .contentProcessed { err in
            if err != nil { connection.cancel() }
        })

        let isJPEG = header.contains("codec=jpeg")
        let isH264 = !isJPEG

        Task { [weak self] in
            guard let self else { return }
            if isH264 {
                let (subId, frameStream) = self.subscribeH264Frames()
                defer { self.unsubscribeH264Frames(id: subId) }

                H264StreamEncoder.shared.requestKeyframe()
                if let keyframe = H264StreamEncoder.shared.latestKeyframePacket {
                    connection.send(content: Self.makeWSBinaryFrame(keyframe), completion: .contentProcessed { err in
                        if err != nil { connection.cancel() }
                    })
                }

                for await packet in frameStream {
                    guard connection.state == .ready else { break }
                    connection.send(
                        content: Self.makeWSBinaryFrame(packet),
                        completion: .contentProcessed { err in if err != nil { connection.cancel() } }
                    )
                }
            } else {
                let (subId, frameStream) = self.subscribeFrames()
                defer { self.unsubscribeFrames(id: subId) }

                let standby = await MainActor.run { self.rawFrameProvider?(540) ?? Self.standbyJPEGData }
                connection.send(content: Self.makeWSBinaryFrame(standby), completion: .contentProcessed { err in
                    if err != nil { connection.cancel() }
                })

                for await jpeg in frameStream {
                    guard connection.state == .ready else { break }
                    connection.send(
                        content: Self.makeWSBinaryFrame(jpeg),
                        completion: .contentProcessed { err in if err != nil { connection.cancel() } }
                    )
                }
            }
            connection.cancel()
        }

        receiveWSIncomingFrames(connection)
    }

    private func receiveWSIncomingFrames(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                if isComplete || error != nil { connection.cancel() }
                return
            }
            if let parsed = Self.parseWSFrame(data) {
                if parsed.opcode == 0x8 {
                    connection.cancel()
                    return
                }
                if parsed.opcode == 0x1 || parsed.opcode == 0x2 {
                    if let text = String(data: parsed.payload, encoding: .utf8),
                       let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            let action = json["action"] as? String ?? ""
                            if action == "keyframe" {
                                H264StreamEncoder.shared.requestKeyframe()
                                return
                            }
                            if let control = self.controlProvider?() {
                                let mode = self.touchModeProvider?() ?? .portrait
                                switch action {
                                case "touch":
                                    let type = json["type"] as? String ?? "contact"
                                    let x = json["x"] as? Double ?? 0.5
                                    let y = json["y"] as? Double ?? 0.5
                                    let (hx, hy) = TouchMap.toDigitizer(nx: x, ny: y, mode: mode)
                                    control.touch(type: type, x: hx, y: hy)
                                case "release_touch":
                                    let x = json["x"] as? Double ?? 0.5
                                    let y = json["y"] as? Double ?? 0.5
                                    let pressedAt = (json["pressedAt"] as? UInt64) ?? DispatchTime.now().uptimeNanoseconds
                                    let (hx, hy) = TouchMap.toDigitizer(nx: x, ny: y, mode: mode)
                                    control.releaseTouch(x: hx, y: hy, minHoldUs: 140_000, pressedAt: pressedAt)
                                case "key":
                                    let down = json["down"] as? Bool ?? true
                                    let usage = UInt16(json["usage"] as? Int ?? 0)
                                    let char = json["char"] as? String ?? ""
                                    let mods = UInt8(json["mods"] as? Int ?? 0)
                                    control.key(down: down, usage: usage, character: char, mods: mods)
                                case "key_reset":
                                    control.keyboardReset()
                                case "tap":
                                    let x = json["x"] as? Double ?? 0.5
                                    let y = json["y"] as? Double ?? 0.5
                                    let (hx, hy) = TouchMap.toDigitizer(nx: x, ny: y, mode: mode)
                                    control.tap(x: hx, y: hy)
                                case "swipe":
                                    let x0 = json["x0"] as? Double ?? json["x"] as? Double ?? 0.5
                                    let y0 = json["y0"] as? Double ?? json["y"] as? Double ?? 0.8
                                    let x1 = json["x1"] as? Double ?? x0
                                    let y1 = json["y1"] as? Double ?? 0.2
                                    let ms = json["ms"] as? Int ?? 200
                                    let (hx0, hy0) = TouchMap.toDigitizer(nx: x0, ny: y0, mode: mode)
                                    let (hx1, hy1) = TouchMap.toDigitizer(nx: x1, ny: y1, mode: mode)
                                    let frames = max(6, ms / 16)
                                    control.touch(type: "contact", x: hx0, y: hy0)
                                    for i in 1...frames {
                                        let t = Double(i) / Double(frames)
                                        let curX = Int(Double(hx0) + (Double(hx1 - hx0) * t))
                                        let curY = Int(Double(hy0) + (Double(hy1 - hy0) * t))
                                        control.touch(type: "contact", x: curX, y: curY)
                                        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000 / UInt64(frames))
                                    }
                                    control.touch(type: "release", x: hx1, y: hy1)
                                case "home":
                                    await LocalAPIMacros.goHome(control: control, mode: mode)
                                case "button":
                                    let name = json["name"] as? String ?? "home"
                                    await WorkflowPlayer.shared.runOne(.button(name), control: control, mode: mode)
                                case "type":
                                    let t = json["text"] as? String ?? ""
                                    await WorkflowPlayer.shared.runType(t, control: control)
                                default: break
                                }
                            }
                        }
                    }
                }
            }
            if connection.state == .ready {
                self.receiveWSIncomingFrames(connection)
            }
        }
    }

    static func computeWSAcceptKey(_ clientKey: String) -> String {
        let magic = clientKey.trimmingCharacters(in: .whitespacesAndNewlines) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }

    static func makeWSBinaryFrame(_ payload: Data) -> Data {
        var frame = Data()
        frame.append(0x82)
        let len = payload.count
        if len <= 125 {
            frame.append(UInt8(len))
        } else if len <= 65535 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((len >> (i * 8)) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    static func parseWSFrame(_ data: Data) -> (opcode: UInt8, payload: Data)? {
        guard data.count >= 2 else { return nil }
        let firstByte = data[0]
        let secondByte = data[1]
        let opcode = firstByte & 0x0F
        let isMasked = (secondByte & 0x80) != 0
        var payloadLen = Int(secondByte & 0x7F)
        var headerOffset = 2

        if payloadLen == 126 {
            guard data.count >= 4 else { return nil }
            payloadLen = Int(data[2]) << 8 | Int(data[3])
            headerOffset = 4
        } else if payloadLen == 127 {
            guard data.count >= 10 else { return nil }
            payloadLen = 0
            for i in 0..<8 {
                payloadLen = (payloadLen << 8) | Int(data[2 + i])
            }
            headerOffset = 10
        }

        var maskKey: [UInt8] = [0, 0, 0, 0]
        if isMasked {
            guard data.count >= headerOffset + 4 else { return nil }
            maskKey = Array(data[headerOffset..<(headerOffset + 4)])
            headerOffset += 4
        }

        guard data.count >= headerOffset + payloadLen else { return nil }
        var payload = Data(data[headerOffset..<(headerOffset + payloadLen)])
        if isMasked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }
        return (opcode, payload)
    }

    private func respondRaw(_ connection: NWConnection, status: Int, contentType: String, body: Data, keepAlive: Bool = true) {
        let reason: String = status == 200 ? "OK" : (status == 204 ? "No Content" : "Error")
        var msg = "HTTP/1.1 \(status) \(reason)\r\n"
        msg += "Content-Type: \(contentType)\r\n"
        msg += "Content-Length: \(body.count)\r\n"
        msg += "Cache-Control: no-cache, no-store, must-revalidate\r\n"
        msg += "Access-Control-Allow-Origin: *\r\n"
        msg += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        msg += "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        if keepAlive {
            msg += "Connection: keep-alive\r\n\r\n"
            var data = Data(msg.utf8)
            data.append(body)
            connection.send(content: data, completion: .contentProcessed { _ in })
        } else {
            msg += "Connection: close\r\n\r\n"
            var data = Data(msg.utf8)
            data.append(body)
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    static func webHTMLPage() -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
        <title>MirrorUE — Mobile Web Mirror Studio</title>
        <style>
          :root {
            --bg-color: #090a0f;
            --card-bg: rgba(255, 255, 255, 0.05);
            --border-color: rgba(255, 255, 255, 0.12);
            --accent-blue: #007aff;
            --accent-green: #34c759;
            --accent-purple: #af52de;
            --text-main: #f0f0f5;
            --text-sub: #a0a0b0;
            --focus-ring: #007aff;
          }
          * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
          body {
            background: var(--bg-color);
            color: var(--text-main);
            display: flex;
            flex-direction: column;
            align-items: center;
            min-height: 100vh;
            padding: clamp(10px, 3vw, 20px);
            touch-action: manipulation;
            -webkit-tap-highlight-color: transparent;
          }
          
          button:focus-visible, input:focus-visible {
            outline: 2px solid var(--focus-ring);
            outline-offset: 2px;
          }
          
          .header {
            width: 100%;
            max-width: 960px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            background: var(--card-bg);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            border: 1px solid var(--border-color);
            border-radius: 16px;
            padding: 12px 18px;
            margin-bottom: 16px;
          }
          .header .title { font-weight: 700; font-size: 16px; display: flex; align-items: center; gap: 8px; }
          .status-pill {
            font-size: 11px;
            font-weight: 700;
            letter-spacing: 0.5px;
            background: rgba(52, 199, 89, 0.15);
            color: var(--accent-green);
            border: 1px solid rgba(52, 199, 89, 0.3);
            padding: 6px 12px;
            border-radius: 20px;
            display: flex;
            align-items: center;
            gap: 6px;
          }
          .status-dot { width: 8px; height: 8px; background: var(--accent-green); border-radius: 50%; box-shadow: 0 0 8px var(--accent-green); }
          
          .main-stage {
            display: flex;
            flex-direction: row;
            gap: 20px;
            max-width: 960px;
            width: 100%;
            justify-content: center;
            align-items: flex-start;
          }
          
          @media (max-width: 768px) {
            .main-stage {
              flex-direction: column;
              align-items: center;
            }
            .side-panel {
              width: 100% !important;
              max-width: 420px;
            }
            .dock-btn {
              width: 46px !important;
              height: 42px !important;
              font-size: 18px !important;
            }
          }

          .device-container {
            position: relative;
            background: #000;
            border-radius: clamp(24px, 5vw, 40px);
            padding: clamp(8px, 2vw, 14px);
            border: 2px solid rgba(255,255,255,0.15);
            box-shadow: 0 20px 50px rgba(0,0,0,0.7);
            display: flex;
            flex-direction: column;
            align-items: center;
            max-width: 100%;
          }
          .screen-wrapper {
            position: relative;
            border-radius: clamp(18px, 4vw, 30px);
            overflow: hidden;
            display: flex;
            background: #000;
            touch-action: none;
            max-width: 100%;
          }
          #mirror-canvas {
            max-height: clamp(400px, 70vh, 750px);
            width: auto;
            max-width: 100%;
            object-fit: contain;
            display: block;
            border-radius: clamp(18px, 4vw, 30px);
            touch-action: none;
            cursor: crosshair;
            user-select: none;
            -webkit-user-select: none;
            -webkit-touch-callout: none;
          }
          .touch-ripple {
            position: absolute;
            width: 36px;
            height: 36px;
            margin-left: -18px;
            margin-top: -18px;
            border-radius: 50%;
            background: rgba(0, 122, 255, 0.4);
            border: 2px solid #007aff;
            pointer-events: none;
            animation: ripple 0.4s ease-out forwards;
          }
          @keyframes ripple {
            0% { transform: scale(0.4); opacity: 1; }
            100% { transform: scale(1.6); opacity: 0; }
          }

          .dock-bar {
            display: flex;
            gap: 8px;
            margin-top: 12px;
            background: rgba(255, 255, 255, 0.08);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            padding: 8px 14px;
            border-radius: 24px;
            border: 1px solid var(--border-color);
            flex-wrap: wrap;
            justify-content: center;
          }
          .dock-btn {
            background: rgba(255, 255, 255, 0.08);
            border: 1px solid rgba(255, 255, 255, 0.12);
            color: var(--text-main);
            border-radius: 12px;
            width: 42px;
            height: 38px;
            display: flex;
            align-items: center;
            justify-content: center;
            cursor: pointer;
            font-size: 16px;
            transition: all 0.15s ease;
          }
          .dock-btn:hover { background: rgba(255, 255, 255, 0.2); transform: translateY(-1px); }
          .dock-btn:active { transform: translateY(1px); scale: 0.95; }

          .side-panel {
            width: 320px;
            display: flex;
            flex-direction: column;
            gap: 14px;
          }
          .panel-card {
            background: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 16px;
            padding: 16px;
            display: flex;
            flex-direction: column;
            gap: 12px;
          }
          .panel-title { font-size: 12px; font-weight: 700; color: var(--text-sub); text-transform: uppercase; letter-spacing: 0.6px; }
          .input-row { display: flex; gap: 8px; }
          input[type="text"] {
            flex: 1;
            background: rgba(0, 0, 0, 0.35);
            border: 1px solid var(--border-color);
            border-radius: 10px;
            padding: 10px 14px;
            color: #fff;
            font-size: 14px;
            outline: none;
          }
          input[type="text"]:focus { border-color: var(--accent-blue); }
          .action-btn {
            background: var(--accent-blue);
            border: none;
            color: #fff;
            font-size: 14px;
            font-weight: 600;
            padding: 10px 16px;
            border-radius: 10px;
            cursor: pointer;
            transition: background 0.15s ease;
            min-height: 42px;
          }
          .action-btn:hover { background: #0062cc; }

          .stats-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
          .stat-item {
            background: rgba(0, 0, 0, 0.3);
            border-radius: 10px;
            padding: 10px;
          }
          .stat-val { font-size: 14px; font-weight: 700; color: #fff; }
          .stat-lbl { font-size: 10px; color: var(--text-sub); margin-top: 2px; text-transform: uppercase; letter-spacing: 0.5px; }
          .codec-btn {
            background: rgba(255, 255, 255, 0.08);
            border: 1px solid rgba(255, 255, 255, 0.15);
            border-radius: 8px;
            color: #fff;
            padding: 4px 10px;
            font-size: 11px;
            cursor: pointer;
            transition: all 0.2s;
          }
          .codec-btn.active {
            background: #007aff;
            border-color: #007aff;
          }
        </style>
        </head>
        <body>
          <header class="header" role="banner">
            <h1 class="title"><span>📱</span> MirrorUE Web Studio</h1>
            <div style="display:flex;gap:6px;align-items:center;">
              <button class="codec-btn" id="btn-h264" onclick="setCodec('h264')" title="H.264 Hardware Streaming">⚡ H.264 HW</button>
              <button class="codec-btn" id="btn-jpeg" onclick="setCodec('jpeg')" title="Direct JPEG Streaming">🎨 JPEG</button>
              <div class="status-pill" role="status" aria-live="polite"><div class="status-dot"></div><span id="fps-label">LIVE STREAM</span></div>
            </div>
          </header>

          <main class="main-stage" role="main">
            <section class="device-container" aria-label="iPhone Screen Mirror">
              <div class="screen-wrapper" id="screen-wrapper" role="region" aria-label="Interactive Touch Area">
                <canvas id="mirror-canvas" aria-label="Live Interactive iPhone Screen"></canvas>
              </div>
              <nav class="dock-bar" role="toolbar" aria-label="Device Controls">
                <button class="dock-btn" onclick="sendAction('/v1/button', {name:'home'})" title="Home Button" aria-label="Home">🏠</button>
                <button class="dock-btn" onclick="sendAction('/v1/button', {name:'lock'})" title="Lock Screen" aria-label="Lock">🔒</button>
                <button class="dock-btn" onclick="sendAction('/v1/button', {name:'app_switcher'})" title="App Switcher" aria-label="App Switcher">🔲</button>
                <button class="dock-btn" onclick="sendAction('/v1/button', {name:'vol_down'})" title="Volume Down" aria-label="Volume Down">🔉</button>
                <button class="dock-btn" onclick="sendAction('/v1/button', {name:'vol_up'})" title="Volume Up" aria-label="Volume Up">🔊</button>
                <button class="dock-btn" onclick="takeScreenshot()" title="Take Screenshot" aria-label="Screenshot">📷</button>
              </nav>
            </section>

            <aside class="side-panel" aria-label="Controls Panel">
              <div class="panel-card">
                <h2 class="panel-title">⌨️ Type to iPhone</h2>
                <div class="input-row">
                  <input type="text" id="typeInput" placeholder="Enter text to type..." aria-label="Text to type" onkeydown="if(event.key==='Enter')typeText()">
                  <button class="action-btn" onclick="typeText()" aria-label="Send Text">Send</button>
                </div>
              </div>

              <div class="panel-card">
                <h2 class="panel-title">⚡ AI Phone Agent</h2>
                <div class="input-row">
                  <input type="text" id="agentInput" placeholder="Goal e.g. Open Settings..." aria-label="Agent Goal" onkeydown="if(event.key==='Enter')runAgent()">
                  <button class="action-btn" style="background:var(--accent-purple)" onclick="runAgent()" aria-label="Run Agent Goal">Run</button>
                </div>
              </div>

              <div class="panel-card">
                <h2 class="panel-title">📊 Web Telemetry</h2>
                <div class="stats-grid">
                  <div class="stat-item"><div class="stat-val" id="stat-link">Direct Tunnel</div><div class="stat-lbl">Transport</div></div>
                  <div class="stat-item"><div class="stat-val" id="stat-latency">&lt;1 ms (HW)</div><div class="stat-lbl">Decode Latency</div></div>
                  <div class="stat-item"><div class="stat-val" id="stat-port">8090</div><div class="stat-lbl">HTTP Port</div></div>
                  <div class="stat-item"><div class="stat-val" id="stat-proto">WebCodecs/H264</div><div class="stat-lbl">Protocol</div></div>
                </div>
              </div>
            </aside>
          </main>

          <script>
            const canvas = document.getElementById('mirror-canvas');
            const wrapper = document.getElementById('screen-wrapper');
            const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });

            const wsProtocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
            let ws = null;

            let fpsCount = 0;
            let lastFpsTime = performance.now();
            let canvasReady = false;

            const hasWebCodecs = typeof VideoDecoder !== 'undefined';
            let decoder = null;
            let activeCodec = new URLSearchParams(location.search).get('codec') || (hasWebCodecs ? 'h264' : 'jpeg');
            let framesReceived = 0;

            function updateCodecButtons() {
              const bH264 = document.getElementById('btn-h264');
              const bJpeg = document.getElementById('btn-jpeg');
              if (bH264) bH264.classList.toggle('active', activeCodec === 'h264');
              if (bJpeg) bJpeg.classList.toggle('active', activeCodec === 'jpeg');
            }

            function setCodec(c) {
              if (activeCodec === c) return;
              activeCodec = c;
              updateCodecButtons();
              if (ws) {
                try { ws.close(); } catch(e){}
              }
              connectWebSocket();
            }

            function updateFPS(customCodec) {
              fpsCount++;
              const now = performance.now();
              if (now - lastFpsTime >= 1000) {
                const label = document.getElementById('fps-label');
                const codecName = customCodec || (activeCodec === 'h264' ? 'H.264 HW' : 'JPEG');
                if (label) label.innerText = `LIVE · ${fpsCount} FPS (${codecName})`;
                const lat = document.getElementById('stat-latency');
                if (lat) lat.innerText = activeCodec === 'h264' ? '<1 ms (HW)' : '2 ms';
                const proto = document.getElementById('stat-proto');
                if (proto) proto.innerText = activeCodec === 'h264' ? 'WebCodecs/H264' : 'Canvas/JPEG';
                fpsCount = 0;
                lastFpsTime = now;
              }
            }

            function setupWebCodecsDecoder() {
              if (!hasWebCodecs) return;
              try {
                if (decoder && decoder.state !== 'closed') decoder.close();
              } catch(e){}

              decoder = new VideoDecoder({
                output: (frame) => {
                  if (!canvasReady || canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
                    canvas.width = frame.displayWidth;
                    canvas.height = frame.displayHeight;
                    canvasReady = true;
                  }
                  ctx.drawImage(frame, 0, 0);
                  frame.close(); // Immediate GPU release
                  updateFPS("H.264 HW");
                },
                error: (err) => {
                  console.error('WebCodecs decoder error:', err);
                  sendControl({ action: 'keyframe' });
                }
              });

              decoder.configure({
                codec: 'avc1.42E01F', // Baseline Profile Level 3.1
                optimizeForLatency: true,
                hardwareAcceleration: 'prefer-hardware'
              });
            }

            let decodingJPEG = false;
            let pendingJPEGBuffer = null;
            function decodeJPEG(ab) {
              decodingJPEG = true;
              createImageBitmap(new Blob([ab], { type: 'image/jpeg' }))
                .then(bmp => {
                  if (!canvasReady || canvas.width !== bmp.width || canvas.height !== bmp.height) {
                    canvas.width = bmp.width;
                    canvas.height = bmp.height;
                    canvasReady = true;
                  }
                  ctx.drawImage(bmp, 0, 0);
                  bmp.close();
                  updateFPS("JPEG");
                  decodingJPEG = false;
                  if (pendingJPEGBuffer) {
                    const next = pendingJPEGBuffer;
                    pendingJPEGBuffer = null;
                    decodeJPEG(next);
                  }
                })
                .catch(() => { decodingJPEG = false; });
            }

            function connectWebSocket() {
              updateCodecButtons();
              if (hasWebCodecs && activeCodec === 'h264') {
                setupWebCodecsDecoder();
              }

              const targetUrl = wsProtocol + '//' + location.host + '/v1/ws?codec=' + activeCodec;
              ws = new WebSocket(targetUrl);
              ws.binaryType = 'arraybuffer';
              framesReceived = 0;

              // Automatic fallback if H.264 is unparseable on this browser
              if (activeCodec === 'h264') {
                setTimeout(() => {
                  if (framesReceived === 0 && ws && ws.readyState === WebSocket.OPEN) {
                    console.warn('H.264 inactive on this browser, auto-switching to JPEG…');
                    setCodec('jpeg');
                  }
                }, 2000);
              }

              ws.onopen = () => {
                const label = document.getElementById('fps-label');
                if (label) label.innerText = 'CONNECTED';
                sendControl({ action: 'keyframe' });
              };

              ws.onmessage = (e) => {
                if (!(e.data instanceof ArrayBuffer)) return;
                const buffer = e.data;
                framesReceived++;

                // 1. Try WebCodecs H.264 Decoder
                if (activeCodec === 'h264' && hasWebCodecs && decoder && decoder.state === 'configured') {
                  const view = new Uint8Array(buffer);
                  if (view.length >= 2) {
                    const isKey = view[0] === 0x01;
                    const nalData = buffer.slice(1);
                    try {
                      decoder.decode(new EncodedVideoChunk({
                        type: isKey ? 'key' : 'delta',
                        timestamp: performance.now() * 1000,
                        data: nalData
                      }));
                      return;
                    } catch (err) {
                      console.warn('Decode chunk error, requesting keyframe:', err);
                      sendControl({ action: 'keyframe' });
                    }
                  }
                }

                // 2. Fallback JPEG
                if (!decodingJPEG) {
                  decodeJPEG(buffer);
                } else {
                  pendingJPEGBuffer = buffer;
                }
              };

              ws.onclose = () => {
                const label = document.getElementById('fps-label');
                if (label) label.innerText = 'RECONNECTING…';
                setTimeout(connectWebSocket, 800);
              };

              ws.onerror = (err) => console.error('WS Error:', err);
            }
            connectWebSocket();

            // ─── Single-Touch Precision Tracker (Zero Ghosting / Multi-Touch) ──────
            let canvasPointCache = { x: 0.5, y: 0.5, localX: 0, localY: 0 };
            function getCanvasPoint(e) {
              const rect = canvas.getBoundingClientRect();
              canvasPointCache.x = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
              canvasPointCache.y = Math.max(0, Math.min(1, (e.clientY - rect.top) / rect.height));
              canvasPointCache.localX = e.clientX - rect.left;
              canvasPointCache.localY = e.clientY - rect.top;
              return canvasPointCache;
            }

            let activePointerId = null;
            let lastTouchX = 0.5, lastTouchY = 0.5;
            let scrollActive = false;
            let scrollReleaseTimer = null;
            let scrollX = 0.5, scrollY = 0.5;

            function finishScroll() {
              if (scrollActive) {
                clearTimeout(scrollReleaseTimer);
                scrollActive = false;
                sendControl({ action: 'touch', type: 'release', x: scrollX, y: scrollY });
              }
            }

            function finishTouch() {
              if (activePointerId !== null) {
                try { canvas.releasePointerCapture(activePointerId); } catch(e){}
                activePointerId = null;
                sendControl({ action: 'touch', type: 'release', x: lastTouchX, y: lastTouchY });
              }
            }

            canvas.addEventListener('contextmenu', (e) => e.preventDefault());

            canvas.addEventListener('pointerdown', (e) => {
              e.preventDefault();
              finishScroll();
              if (activePointerId !== null) {
                finishTouch();
              }
              activePointerId = e.pointerId;
              try { canvas.setPointerCapture(e.pointerId); } catch(err){}
              const pt = getCanvasPoint(e);
              lastTouchX = pt.x;
              lastTouchY = pt.y;
              showRipple(pt.localX, pt.localY);
              sendControl({ action: 'touch', type: 'contact', x: pt.x, y: pt.y });
            });

            let lastMoveSent = 0;
            canvas.addEventListener('pointermove', (e) => {
              if (activePointerId !== e.pointerId) return;
              e.preventDefault();
              const now = performance.now();
              if (now - lastMoveSent < 8) return; // 120Hz rate limit
              lastMoveSent = now;
              const pt = getCanvasPoint(e);
              lastTouchX = pt.x;
              lastTouchY = pt.y;
              sendControl({ action: 'touch', type: 'contact', x: pt.x, y: pt.y });
            });

            canvas.addEventListener('pointerup', (e) => {
              if (activePointerId !== e.pointerId) return;
              e.preventDefault();
              const pt = getCanvasPoint(e);
              lastTouchX = pt.x;
              lastTouchY = pt.y;
              finishTouch();
            });

            canvas.addEventListener('pointercancel', (e) => {
              if (activePointerId === e.pointerId) {
                finishTouch();
              }
            });

            window.addEventListener('blur', () => { finishTouch(); finishScroll(); });
            document.addEventListener('visibilitychange', () => {
              if (document.hidden) { finishTouch(); finishScroll(); }
            });

            // ─── Trackpad & Mouse Wheel Scrolling (macOS-identical) ────────────────
            canvas.addEventListener('wheel', (e) => {
              e.preventDefault();
              finishTouch();
              const pt = getCanvasPoint(e);
              if (!scrollActive) {
                scrollActive = true;
                scrollX = pt.x;
                scrollY = pt.y;
                sendControl({ action: 'touch', type: 'contact', x: scrollX, y: scrollY });
              }
              const dx = e.deltaX * 0.0012;
              const dy = e.deltaY * 0.0012;
              scrollX = Math.max(0, Math.min(1, scrollX - dx));
              scrollY = Math.max(0, Math.min(1, scrollY - dy));
              sendControl({ action: 'touch', type: 'contact', x: scrollX, y: scrollY });

              clearTimeout(scrollReleaseTimer);
              scrollReleaseTimer = setTimeout(() => {
                finishScroll();
              }, 120);
            }, { passive: false });

            // ─── Physical Keyboard Direct Typing (macOS-identical) ────────────────
            const specialKeyMap = {
              'Enter': 40,
              'Escape': 41,
              'Backspace': 42,
              'Tab': 43,
              ' ': 44,
              'ArrowRight': 79,
              'ArrowLeft': 80,
              'ArrowDown': 81,
              'ArrowUp': 82
            };

            window.addEventListener('keydown', (e) => {
              if (['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName)) return;
              if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'h') {
                e.preventDefault();
                sendAction('/v1/button', { name: 'home' });
                return;
              }
              if (e.key === 'Escape') {
                e.preventDefault();
                sendAction('/v1/button', { name: 'home' });
                return;
              }

              let mods = 0;
              if (e.shiftKey) mods |= 0x01;
              if (e.ctrlKey) mods |= 0x02;
              if (e.altKey) mods |= 0x04;
              if (e.metaKey) mods |= 0x08;

              if (specialKeyMap[e.key]) {
                e.preventDefault();
                const usage = specialKeyMap[e.key];
                sendControl({ action: 'key', down: true, usage, mods });
                setTimeout(() => sendControl({ action: 'key', down: false, usage, mods }), 25);
              } else if (e.key.length === 1) {
                e.preventDefault();
                sendControl({ action: 'key', down: true, char: e.key, mods });
                setTimeout(() => sendControl({ action: 'key', down: false, char: e.key, mods }), 25);
              }
            });

            function showRipple(x, y) {
              const rip = document.createElement('div');
              rip.className = 'touch-ripple';
              rip.style.left = x + 'px';
              rip.style.top = y + 'px';
              wrapper.appendChild(rip);
              setTimeout(() => rip.remove(), 400);
            }

            function sendControl(payload) {
              if (ws && ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify(payload));
              } else {
                postJSON('/v1/' + (payload.action || 'control'), payload);
              }
            }

            function postJSON(url, payload) {
              fetch(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
              }).catch(err => console.error(err));
            }

            function sendAction(url, body) {
              if (body && body.name) {
                sendControl({ action: 'button', name: body.name });
              } else {
                postJSON(url, body || {});
              }
            }

            function typeText() {
              const input = document.getElementById('typeInput');
              if (!input.value) return;
              sendControl({ action: 'type', text: input.value });
              input.value = '';
            }

            function runAgent() {
              const input = document.getElementById('agentInput');
              if (!input.value) return;
              postJSON('/v1/agent/run', { goal: input.value });
              input.value = '';
            }

            function takeScreenshot() {
              window.open('/v1/screen.jpg', '_blank');
            }
          </script>
        </body>
        </html>
        """
    }

    private func respond(_ connection: NWConnection, status: Int, json: [String: Any], keepAlive: Bool = true) {
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
        msg += "Access-Control-Allow-Origin: *\r\n"
        msg += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        msg += "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        if keepAlive {
            msg += "Connection: keep-alive\r\n\r\n"
            var data = Data(msg.utf8)
            data.append(body)
            connection.send(content: data, completion: .contentProcessed { _ in })
        } else {
            msg += "Connection: close\r\n\r\n"
            var data = Data(msg.utf8)
            data.append(body)
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

extension WorkflowPlayer {
    @MainActor
    func runOne(_ step: WorkflowStep, control: ControlClient, mode: TouchMap.Mode) async {
        await execute(step, control: control, mode: mode)
    }
}
