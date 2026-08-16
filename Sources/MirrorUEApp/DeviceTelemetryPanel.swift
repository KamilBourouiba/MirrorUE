import AppKit

/// Real-time performance, stream, and connection telemetry panel for Device Hub.
final class DeviceTelemetryPanel: NSView {
    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Device Telemetry")
    private let subtitleLabel = NSTextField(
        wrappingLabelWithString: "Live stream stats, Metal rendering, and CoreDevice HID tunnel metrics."
    )

    private let fpsChip = TelemetryMetricCard(title: "FPS", value: "--", unit: "fps", badgeColor: .systemGreen)
    private let latencyChip = TelemetryMetricCard(title: "LATENCY P95", value: "--", unit: "ms", badgeColor: .systemBlue)
    private let resolutionChip = TelemetryMetricCard(title: "SURFACE", value: "390×844", unit: "px", badgeColor: .systemPurple)
    private let linkChip = TelemetryMetricCard(title: "TUNNEL LINK", value: "USB", unit: "usbmux", badgeColor: .systemOrange)

    private let detailTableStack = NSStackView()
    private let pollTimerLock = NSLock()
    private var pollTimer: Timer?
    var telemetryProvider: (() -> TelemetrySnapshot)?

    struct TelemetrySnapshot {
        var fps: Double
        var latencyMs: Double
        var width: Int
        var height: Int
        var connectionLink: String
        var keyboardLayout: String
        var apiPort: Int
        var apiRunning: Bool
        var codec: String
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pollTimer?.invalidate()
    }

    private func setupUI() {
        wantsLayer = true

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .labelColor

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        let metricsGrid = NSStackView(views: [
            NSStackView(views: [fpsChip, latencyChip]),
            NSStackView(views: [resolutionChip, linkChip])
        ])
        metricsGrid.orientation = .vertical
        metricsGrid.spacing = 8
        metricsGrid.alignment = .leading

        for row in metricsGrid.arrangedSubviews as! [NSStackView] {
            row.orientation = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
        }

        detailTableStack.orientation = .vertical
        detailTableStack.spacing = 6
        detailTableStack.alignment = .leading

        let containerStack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            metricsGrid,
            createDivider(),
            detailTableStack
        ])
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 10
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(containerStack)

        [titleLabel, subtitleLabel, metricsGrid, detailTableStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalTo: containerStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),

            containerStack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            containerStack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            containerStack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            containerStack.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor, constant: -12),
        ])

        updateTelemetry(snapshot: TelemetrySnapshot(
            fps: 120.0,
            latencyMs: 18.0,
            width: 390,
            height: 844,
            connectionLink: "USB usbmux",
            keyboardLayout: "Auto (fr)",
            apiPort: 8090,
            apiRunning: true,
            codec: "CoreMediaIO DAL"
        ))

        startPolling()
    }

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self, let provider = self.telemetryProvider else { return }
            let snap = provider()
            DispatchQueue.main.async {
                self.updateTelemetry(snapshot: snap)
            }
        }
    }

    func updateTelemetry(snapshot: TelemetrySnapshot) {
        fpsChip.setValue(String(format: "%.0f", snapshot.fps))
        latencyChip.setValue(String(format: "%.0f", snapshot.latencyMs))
        resolutionChip.setValue("\(snapshot.width)×\(snapshot.height)")
        linkChip.setValue(snapshot.connectionLink.contains("USB") ? "USB" : "Wi-Fi")

        detailTableStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let rows: [(String, String)] = [
            ("Video Pipeline", snapshot.codec),
            ("Rendering API", "Metal IOSurface (Zero-copy)"),
            ("HID Tunnel", snapshot.connectionLink),
            ("Keyboard Map", snapshot.keyboardLayout),
            ("HTTP API Server", snapshot.apiRunning ? "Active · 127.0.0.1:\(snapshot.apiPort)" : "Offline"),
            ("Pro License", "Commercial Automation Active")
        ]

        for (key, val) in rows {
            detailTableStack.addArrangedSubview(createDetailRow(label: key, value: val))
        }
    }

    private func createDetailRow(label: String, value: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY

        let keyLabel = NSTextField(labelWithString: label)
        keyLabel.font = .systemFont(ofSize: 11, weight: .medium)
        keyLabel.textColor = .secondaryLabelColor

        let valLabel = NSTextField(labelWithString: value)
        valLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        valLabel.textColor = .labelColor
        valLabel.alignment = .right
        valLabel.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(keyLabel)
        row.addArrangedSubview(valLabel)

        keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        valLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        return row
    }

    private func createDivider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

/// Compact metric card component for Device Hub Telemetry.
final class TelemetryMetricCard: NSView {
    private let titleLabel = NSTextField()
    private let valueLabel = NSTextField()
    private let unitLabel = NSTextField()
    private let accentBar = NSView()

    init(title: String, value: String, unit: String, badgeColor: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = badgeColor.cgColor
        accentBar.layer?.cornerRadius = 2
        accentBar.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 9, weight: .bold)
        titleLabel.textColor = .secondaryLabelColor

        valueLabel.stringValue = value
        valueLabel.font = .systemFont(ofSize: 18, weight: .bold)
        valueLabel.textColor = .labelColor

        unitLabel.stringValue = unit
        unitLabel.font = .systemFont(ofSize: 10, weight: .medium)
        unitLabel.textColor = .tertiaryLabelColor

        let valRow = NSStackView(views: [valueLabel, unitLabel])
        valRow.orientation = .horizontal
        valRow.alignment = .firstBaseline
        valRow.spacing = 3

        let stack = NSStackView(views: [titleLabel, valRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(accentBar)
        addSubview(stack)

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            accentBar.widthAnchor.constraint(equalToConstant: 3),

            stack.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setValue(_ value: String) {
        valueLabel.stringValue = value
    }
}
