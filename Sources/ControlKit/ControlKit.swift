import Foundation

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
}
