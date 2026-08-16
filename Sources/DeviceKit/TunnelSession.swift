import Foundation

/// Spawns MirrorUEEngine (CoreDevice tunnel + DisplayService + HID) and waits
/// until the local control HTTP endpoint is ready.
public final class TunnelSession: @unchecked Sendable {
    public let device: DeviceInfo
    public let httpPort: Int
    public let controlBaseURL: URL
    public private(set) var rsdSession: RsdSession?
    private var process: Process?
    private var logPipe: Pipe?

    public init(device: DeviceInfo, httpPort: Int = 8080) {
        self.device = device
        self.httpPort = httpPort
        self.controlBaseURL = URL(string: "http://127.0.0.1:\(httpPort)")!
    }

    public static func resolveEngine() -> URL? {
        if let p = ProcessInfo.processInfo.environment["MIRRORUE_ENGINE"],
           FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        var candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MirrorUEEngine"),
        ]
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("MirrorUEEngine"))
            var dir = exeDir
            for _ in 0..<10 {
                candidates.append(dir.appendingPathComponent("bin/MirrorUEEngine"))
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("bin/MirrorUEEngine"))
        candidates.append(cwd.deletingLastPathComponent().appendingPathComponent("bin/MirrorUEEngine"))
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c.path) { return c }
        }
        return nil
    }

    public func start() throws {
        guard let engine = Self.resolveEngine() else {
            throw TunnelError.missingEngine
        }
        // Only kill orphan engine daemons on httpPort+1, never kill current app PID on httpPort
        _ = shell("lsof -tiTCP:\(httpPort + 1) -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null")

        let transport = device.connectionType == "USB" ? "usb" : "wifi"
        let p = Process()
        let isScript = engine.pathExtension == "py" || engine.pathExtension == "sh" || isShebang(engine)
        if isScript {
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [engine.path,
                           "--udid", device.udid,
                           "--transport", transport,
                           "--http-port", "\(httpPort + 1)"]
        } else {
            p.executableURL = engine
            p.arguments = [
                "--udid", device.udid,
                "--transport", transport,
                "--http-port", "\(httpPort + 1)",
            ]
        }
        var env = ProcessInfo.processInfo.environment
        env["MIRRORUE_NATIVE"] = "1"
        env["MIRRORUE_VIDEO_TRANSPORT"] = "unix"
        env["MIRRORUE_PUSH"] = env["MIRRORUE_PUSH"] ?? "rgba"
        env["MIRRORUE_RCTL"] = env["MIRRORUE_RCTL"] ?? "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        logPipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) {
                fputs(s, stderr)
            }
        }
        try p.run()
        process = p
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                self?.onProcessExit?(code)
            }
        }
        fputs("TunnelSession engine=\(engine.lastPathComponent) pid=\(p.processIdentifier) udid=\(device.udid)\n", stderr)
    }

    public func waitUntilReady(timeout: TimeInterval = 60) async throws {
        let url = controlBaseURL.appendingPathComponent("status")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let process, !process.isRunning {
                throw TunnelError.exited(process.terminationStatus)
            }
            do {
                let (_, resp) = try await URLSession.shared.data(from: url)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    rsdSession = await CoreDeviceBridge.waitForSession(timeout: 5)
                    return
                }
            } catch {}
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw TunnelError.timeout
    }

    public func stop() {
        onProcessExit = nil
        logPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
    }

    public var isAlive: Bool {
        guard let process else { return false }
        return process.isRunning
    }

    /// Optional callback when the engine process exits unexpectedly.
    public var onProcessExit: ((Int32) -> Void)?

    deinit { stop() }

    private func isShebang(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: 2)
        return data == Data([0x23, 0x21])
    }

    @discardableResult
    private func shell(_ cmd: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

public enum TunnelError: Error, CustomStringConvertible {
    case missingEngine
    case timeout
    case exited(Int32)

    public var description: String {
        switch self {
        case .missingEngine:
            return "MirrorUEEngine is missing from this app. Reinstall MirrorUE or rebuild with ./tools/build_engine.sh"
        case .timeout:
            return "tunnel status timeout"
        case .exited(let c):
            return "engine exited (\(c))"
        }
    }
}
