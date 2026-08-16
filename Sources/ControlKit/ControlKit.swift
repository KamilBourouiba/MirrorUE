import Foundation

public struct ControlForegroundAppStatus: Sendable, Equatable {
    public let available: Bool
    public let fresh: Bool
    public let monitor: String
    public let bundleIdentifier: String?
    public let name: String?
    public let state: String?
    public let timestamp: Double?
    public let ageMilliseconds: Double?
}

public struct ControlAppLaunchReceipt: Sendable, Equatable {
    public let requested: String
    public let name: String
    public let bundleIdentifier: String
    public let processIdentifier: Int?
    public let launchAccepted: Bool
    public let foregroundConfirmed: Bool
    public let foreground: ControlForegroundAppStatus?
}

public enum ControlClientRequestError: LocalizedError, Sendable, Equatable {
    case invalidResponse
    case endpointUnavailable(String)
    case rejected(status: Int, code: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The phone control engine returned an invalid response."
        case .endpointUnavailable(let message):
            return message
        case .rejected(_, _, let message):
            return message
        }
    }

    /// Older engines and temporarily unavailable CoreDevice app services can
    /// safely fall back to the HID Spotlight macro. Validation errors and
    /// ambiguous app names must remain fail-closed.
    public var allowsAppMacroFallback: Bool {
        switch self {
        case .endpointUnavailable:
            return true
        case .rejected(let status, _, _):
            return status == 503
        case .invalidResponse:
            return false
        }
    }
}

/// Control plane: dock buttons, touch, and keyboard via Unix HID socket
/// (preferred) or HTTP fallback to the local engine.
public final class ControlClient: @unchecked Sendable {
    public var baseURL: URL
    public var hidSocketPath: String? {
        didSet {
            if let p = hidSocketPath {
                hid = HidSocketClient(path: p)
            }
        }
    }
    private var hid: HidSocketClient?
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8080")!) {
        self.baseURL = baseURL
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: cfg)
    }

    public func button(_ name: String, state: String = "press") {
        if let hid, hid.isAvailable {
            hid.button(name, state: state)
            // Press alone leaves Indigo buttons stuck; click = press + release.
            if state == "press" {
                hid.button(name, state: "release")
            }
            return
        }
        post("/button", ["name": name, "state": state])
        if state == "press" {
            post("/button", ["name": name, "state": "release"])
        }
    }

    public func key(down: Bool, usage: UInt16, character: String = "", mods: UInt8 = 0) {
        if let hid, hid.isAvailable {
            hid.key(down: down, usage: usage, character: character, mods: mods)
            return
        }
        post("/key", [
            "down": down,
            "usage": Int(usage),
            "char": character,
            "mods": Int(mods),
        ])
    }

    public func touch(type: String, x: Int, y: Int) {
        if let hid, hid.isAvailable {
            hid.touch(type: type, x: x, y: y)
            return
        }
        post("/touch", ["type": type, "x": x, "y": y])
    }

    /// Finger tap (press + release) — preferred over separate contact/release posts.
    public func tap(x: Int, y: Int) {
        if let hid, hid.isAvailable {
            hid.tap(x: x, y: y)
            return
        }
        post("/touch", ["type": "contact", "x": x, "y": y])
        Thread.sleep(forTimeInterval: 0.045)
        post("/touch", ["type": "contact", "x": x, "y": y])
        Thread.sleep(forTimeInterval: 0.16)
        post("/touch", ["type": "release", "x": x, "y": y])
    }

    /// Release with a minimum press duration (mouse / trackpad clicks).
    public func releaseTouch(x: Int, y: Int, minHoldUs: UInt32 = 140_000, pressedAt: UInt64) {
        if let hid, hid.isAvailable {
            hid.release(x: x, y: y, minHoldUs: minHoldUs, pressedAt: pressedAt)
            return
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- pressedAt
        let need = UInt64(minHoldUs) * 1_000
        if elapsed < need {
            Thread.sleep(forTimeInterval: Double(need - elapsed) / 1_000_000_000)
        }
        post("/touch", ["type": "release", "x": x, "y": y])
    }

    public func instant(hard: Bool = false) {
        if let hid, hid.isAvailable {
            hid.instant(hard: hard)
            return
        }
        post("/instant", ["hard": hard])
    }

    public func musicSafe(_ on: Bool) {
        if let hid, hid.isAvailable {
            hid.musicSafe(on)
            return
        }
        post("/music-safe", ["on": on])
    }

    /// Release every virtual key on the phone (clear stuck WASD / Shift).
    public func keyboardReset() {
        if let hid, hid.isAvailable {
            hid.keyboardReset()
            return
        }
        post("/keyboard-reset", [:])
    }

    /// Returns host-produced foreground application state from the persistent
    /// CoreDevice notification monitor. This is separate from OCR/screenshot
    /// content and can therefore disambiguate a Home Screen icon label.
    public func foregroundAppStatus() async throws -> ControlForegroundAppStatus {
        let json = try await requestJSON(method: "GET", path: "/status", body: nil)
        guard let foreground = json["foreground"] as? [String: Any] else {
            throw ControlClientRequestError.endpointUnavailable(
                "This phone engine does not expose foreground-app state."
            )
        }
        return try Self.decodeForegroundStatus(foreground)
    }

    /// Launches an installed application through CoreDevice AppService. The
    /// engine resolves names against a bounded cached app catalog and returns
    /// the exact bundle identifier it launched.
    public func openAppDirect(_ name: String) async throws -> ControlAppLaunchReceipt {
        let requested = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            throw ControlClientRequestError.rejected(
                status: 400,
                code: "invalid_selector",
                message: "App name must not be empty."
            )
        }
        let json = try await requestJSON(
            method: "POST",
            path: "/open-app",
            body: ["name": requested],
            timeout: 8
        )
        guard json["ok"] as? Bool == true,
              json["launchAccepted"] as? Bool == true,
              let resolvedName = json["name"] as? String,
              let bundleIdentifier = json["bundleId"] as? String,
              !resolvedName.isEmpty,
              !bundleIdentifier.isEmpty else {
            throw ControlClientRequestError.invalidResponse
        }
        let foreground: ControlForegroundAppStatus?
        if let object = json["foreground"] as? [String: Any] {
            foreground = try? Self.decodeForegroundStatus(object)
        } else {
            foreground = nil
        }
        return ControlAppLaunchReceipt(
            requested: (json["requested"] as? String) ?? requested,
            name: resolvedName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: Self.integer(json["pid"]),
            launchAccepted: true,
            foregroundConfirmed: (json["foregroundConfirmed"] as? Bool) ?? false,
            foreground: foreground
        )
    }

    public func appsSwitcher() { swipeUp() }
    public func controlCenter() { swipeDown() }

    public func swipeUp() {
        fireTouchPath([
            ("contact", 32768, 64000),
            ("contact", 32768, 52000),
            ("contact", 32768, 40000),
            ("contact", 32768, 28000),
            ("contact", 32768, 16000),
            ("release", 32768, 8000),
        ])
    }

    public func swipeDown() {
        fireTouchPath([
            ("contact", 50000, 1200),
            ("contact", 50000, 8000),
            ("contact", 50000, 18000),
            ("contact", 50000, 30000),
            ("contact", 50000, 42000),
            ("release", 50000, 48000),
        ])
    }

    private func fireTouchPath(_ path: [(String, Int, Int)]) {
        for (i, step) in path.enumerated() {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Double(i) * 0.02) {
                self.touch(type: step.0, x: step.1, y: step.2)
            }
        }
    }

    private func post(_ path: String, _ body: [String: Any]) {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: req).resume()
    }

    private func requestJSON(
        method: String,
        path: String,
        body: [String: Any]?,
        timeout: TimeInterval = 2
    ) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw ControlClientRequestError.endpointUnavailable(
                "The phone control engine URL is invalid."
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw ControlClientRequestError.endpointUnavailable(
                "CoreDevice app control is unavailable: \(error.localizedDescription)"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw ControlClientRequestError.invalidResponse
        }
        let object = (try? JSONSerialization.jsonObject(with: data))
            as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            let errorObject = object["error"] as? [String: Any]
            let code = (errorObject?["code"] as? String)
                ?? (object["code"] as? String)
            let message = (errorObject?["message"] as? String)
                ?? (object["error"] as? String)
                ?? (object["message"] as? String)
                ?? "Phone control request failed with HTTP \(http.statusCode)."
            if http.statusCode == 404,
               code == nil,
               message.lowercased() == "not found" {
                throw ControlClientRequestError.endpointUnavailable(
                    "The running phone engine predates direct app launch."
                )
            }
            throw ControlClientRequestError.rejected(
                status: http.statusCode,
                code: code,
                message: message
            )
        }
        guard !object.isEmpty else {
            throw ControlClientRequestError.invalidResponse
        }
        return object
    }

    private static func decodeForegroundStatus(
        _ object: [String: Any]
    ) throws -> ControlForegroundAppStatus {
        guard let available = object["available"] as? Bool,
              let fresh = object["fresh"] as? Bool else {
            throw ControlClientRequestError.invalidResponse
        }
        let monitor: String
        if let value = object["monitor"] as? String {
            monitor = value
        } else if let value = object["monitor"] as? Bool {
            monitor = value ? "connected" : "disconnected"
        } else {
            monitor = "unknown"
        }
        return ControlForegroundAppStatus(
            available: available,
            fresh: fresh,
            monitor: monitor,
            bundleIdentifier: object["bundleId"] as? String,
            name: object["name"] as? String,
            state: object["state"] as? String,
            timestamp: number(object["timestamp"]),
            ageMilliseconds: number(object["ageMs"])
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
