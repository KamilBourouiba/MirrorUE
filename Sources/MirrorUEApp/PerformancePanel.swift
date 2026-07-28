import AppKit
import Foundation
import DeviceKit
import MediaKit
import ControlKit

/// Live performance + diagnostics overlay.
final class PerformancePanel: NSView {
    var onClose: (() -> Void)?
    var metricsProvider: (() -> DiagnosticsReport)?

    private let effect = NSVisualEffectView()
    private let body = NSTextField(wrappingLabelWithString: "Collecting…")
    private var refreshTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let title = NSTextField(labelWithString: "Performance")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        body.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        body.textColor = .secondaryLabelColor
        body.translatesAutoresizingMaskIntoConstraints = false

        let copyBtn = NSButton(title: "Copy diagnostics", target: self, action: #selector(copyDiagnostics))
        copyBtn.bezelStyle = .rounded
        copyBtn.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = NSButton(title: "Close", target: self, action: #selector(close))
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [copyBtn, closeBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(title)
        effect.addSubview(body)
        effect.addSubview(buttons)

        NSLayoutConstraint.activate([
            effect.centerXAnchor.constraint(equalTo: centerXAnchor),
            effect.centerYAnchor.constraint(equalTo: centerYAnchor),
            effect.widthAnchor.constraint(equalToConstant: 420),

            title.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),

            buttons.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 16),
            buttons.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -16),
        ])

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()

        let click = NSClickGestureRecognizer(target: self, action: #selector(backdrop(_:)))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { refreshTimer?.invalidate() }

    private func refresh() {
        guard let report = metricsProvider?() else { return }
        body.stringValue = report.displayText
    }

    @objc private func copyDiagnostics() {
        guard let report = metricsProvider?() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report.exportText, forType: .string)
        body.stringValue = report.displayText + "\n\n(copied to clipboard)"
    }

    @objc private func close() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        onClose?()
    }

    @objc private func backdrop(_ gr: NSClickGestureRecognizer) {
        if !effect.frame.contains(gr.location(in: self)) { close() }
    }
}

struct DiagnosticsReport {
    var captureFps: Double
    var displayFps: Double
    var latencyP50Ms: Double
    var latencyP95Ms: Double
    var videoTransport: String
    var inputTransport: String
    var deviceName: String
    var udid: String
    var connectionState: String
    var engineAlive: Bool
    var captureStalled: Bool
    var keyboardMode: String
    var targetFps: Int
    var macOS: String
    var appVersion: String

    var displayText: String {
        """
        Capture rate          \(String(format: "%.1f", captureFps)) fps
        Displayed rate        \(String(format: "%.1f", displayFps)) fps
        Latency p50 / p95     \(String(format: "%.0f", latencyP50Ms)) / \(String(format: "%.0f", latencyP95Ms)) ms
        Video transport       \(videoTransport)
        Input transport       \(inputTransport)
        Device                \(deviceName)
        State                 \(connectionState)
        Engine                \(engineAlive ? "alive" : "stopped")
        Capture               \(captureStalled ? "stalled · recovering" : "live")
        Keyboard              \(keyboardMode)
        Target FPS            \(targetFps)
        """
    }

    var exportText: String {
        """
        MirrorUE diagnostics
        generated: \(ISO8601DateFormatter().string(from: Date()))
        app: \(appVersion)
        macOS: \(macOS)

        \(displayText)
        udid: \(udid)
        """
    }

    static func macVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
