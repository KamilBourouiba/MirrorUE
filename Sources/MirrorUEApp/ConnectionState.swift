import Foundation

/// Explicit connection lifecycle for the UI (and future recovery).
enum ConnectionState: Equatable {
    case idle
    case pickingDevice
    case openingTunnel(link: String)
    case attachingHID(link: String)
    case startingCapture
    case connected(codec: String)
    case recovering(message: String, attempt: Int)
    case failed(message: String, detail: String)

    var title: String {
        switch self {
        case .idle: return "Waiting for device…"
        case .pickingDevice: return "Select an iPhone"
        case .openingTunnel: return "Opening tunnel…"
        case .attachingHID: return "Attaching controls…"
        case .startingCapture: return "Waiting for screen…"
        case .connected: return "Connected"
        case .recovering(let message, let attempt): return "\(message) (\(attempt)/3)"
        case .failed(let message, _): return message
        }
    }

    var steps: [String] {
        switch self {
        case .idle, .pickingDevice:
            return [
                "○  Connect iPhone by USB",
                "○  Unlock & Trust this Mac",
                "○  Enable Developer Mode",
            ]
        case .openingTunnel:
            return [
                "●  Open CoreDevice tunnel",
                "○  Attach HID control",
                "○  Start screen capture",
            ]
        case .attachingHID:
            return [
                "✓  Open CoreDevice tunnel",
                "●  Attach HID control",
                "○  Start screen capture",
            ]
        case .startingCapture:
            return [
                "✓  Open CoreDevice tunnel",
                "✓  Attach HID control",
                "●  Start screen capture",
            ]
        case .connected:
            return [
                "✓  Open CoreDevice tunnel",
                "✓  Attach HID control",
                "✓  Start screen capture",
            ]
        case .recovering:
            return [
                "●  Recovering connection",
                "○  Reopen tunnel if needed",
                "○  Resume screen capture",
            ]
        case .failed:
            return [
                "✗  Connection failed",
                "○  Check cable / unlock / Trust",
                "○  Enable Developer Mode",
            ]
        }
    }

    var linkBadge: (symbol: String, text: String) {
        switch self {
        case .idle:
            return ("cable.connector", "USB · waiting")
        case .pickingDevice:
            return ("cable.connector", "USB · pick a phone")
        case .openingTunnel(let link), .attachingHID(let link):
            let wifi = link.lowercased().contains("wi")
            return (wifi ? "wifi" : "cable.connector", link)
        case .startingCapture:
            return ("sparkles.tv", "capture…")
        case .connected(let codec):
            return ("sparkles.tv", codec)
        case .recovering:
            return ("arrow.clockwise", "recovering…")
        case .failed:
            return ("exclamationmark.triangle", "failed")
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
