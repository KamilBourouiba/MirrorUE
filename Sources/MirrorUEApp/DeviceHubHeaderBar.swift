import AppKit

enum DeviceHubMode: Int {
    case stage = 0
    case workflows = 1
    case aiAgent = 2
    case telemetry = 3
}

/// Translucent top toolbar for Device Hub navigation and live device status.
final class DeviceHubHeaderBar: NSView {
    var onModeSelected: ((DeviceHubMode) -> Void)?
    var onQuickAction: ((String) -> Void)?

    private let effect = NSVisualEffectView()
    private let borderLine = NSView()

    // Left Device Info Pill
    private let devicePillView = NSView()
    private let deviceIcon = NSImageView()
    private let statusDotView = NSView()
    private let deviceNameLabel = NSTextField(labelWithString: "iPhone")
    private let linkBadgeLabel = NSTextField(labelWithString: "USB · 120 FPS")
    private let latencyChipLabel = NSTextField(labelWithString: "18ms")

    // Center Workspace Mode Selector
    private let modeSegmentControl = NSSegmentedControl(
        labels: ["Stage", "Workflows", "AI Agent", "Monitor & API"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    // Right Quick Action Bar
    private let quickActionStack = NSStackView()
    private var quickButtons: [String: NSButton] = [:]

    private(set) var currentMode: DeviceHubMode = .stage

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        wantsLayer = true

        effect.material = .titlebar
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        borderLine.wantsLayer = true
        borderLine.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        borderLine.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(borderLine)

        // Device Pill
        devicePillView.wantsLayer = true
        devicePillView.layer?.cornerRadius = 13
        devicePillView.layer?.cornerCurve = .continuous
        devicePillView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        devicePillView.layer?.borderWidth = 0.5
        devicePillView.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        devicePillView.translatesAutoresizingMaskIntoConstraints = false

        deviceIcon.image = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        deviceIcon.contentTintColor = .labelColor
        deviceIcon.translatesAutoresizingMaskIntoConstraints = false

        statusDotView.wantsLayer = true
        statusDotView.layer?.cornerRadius = 4
        statusDotView.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDotView.translatesAutoresizingMaskIntoConstraints = false

        deviceNameLabel.font = .systemFont(ofSize: 12, weight: .bold)
        deviceNameLabel.textColor = .labelColor

        linkBadgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        linkBadgeLabel.textColor = .secondaryLabelColor

        latencyChipLabel.font = .systemFont(ofSize: 10, weight: .bold)
        latencyChipLabel.textColor = .systemBlue

        let deviceMetaStack = NSStackView(views: [deviceNameLabel, linkBadgeLabel, latencyChipLabel])
        deviceMetaStack.orientation = .horizontal
        deviceMetaStack.spacing = 6
        deviceMetaStack.alignment = .centerY

        let pillStack = NSStackView(views: [statusDotView, deviceIcon, deviceMetaStack])
        pillStack.orientation = .horizontal
        pillStack.spacing = 7
        pillStack.alignment = .centerY
        pillStack.translatesAutoresizingMaskIntoConstraints = false

        devicePillView.addSubview(pillStack)

        NSLayoutConstraint.activate([
            statusDotView.widthAnchor.constraint(equalToConstant: 8),
            statusDotView.heightAnchor.constraint(equalToConstant: 8),
            pillStack.leadingAnchor.constraint(equalTo: devicePillView.leadingAnchor, constant: 10),
            pillStack.trailingAnchor.constraint(equalTo: devicePillView.trailingAnchor, constant: -10),
            pillStack.topAnchor.constraint(equalTo: devicePillView.topAnchor, constant: 4),
            pillStack.bottomAnchor.constraint(equalTo: devicePillView.bottomAnchor, constant: -4),
            devicePillView.heightAnchor.constraint(equalToConstant: 26)
        ])

        // Workspace Mode Selector
        modeSegmentControl.selectedSegment = DeviceHubMode.stage.rawValue
        modeSegmentControl.segmentStyle = .texturedRounded
        modeSegmentControl.target = self
        modeSegmentControl.action = #selector(modeChanged)
        modeSegmentControl.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 11.0, *) {
            modeSegmentControl.setImage(NSImage(systemSymbolName: "iphone", accessibilityDescription: nil), forSegment: 0)
            modeSegmentControl.setImage(NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil), forSegment: 1)
            modeSegmentControl.setImage(NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil), forSegment: 2)
            modeSegmentControl.setImage(NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil), forSegment: 3)
        }

        // Quick Action Bar
        quickActionStack.orientation = .horizontal
        quickActionStack.spacing = 6
        quickActionStack.alignment = .centerY
        quickActionStack.translatesAutoresizingMaskIntoConstraints = false

        addQuickButton(symbol: "safari", action: "open_web", tip: "Open Local Web Studio")
        addQuickButton(symbol: "camera.fill", action: "screenshot", tip: "Take Screenshot (⌘⇧S)")
        addQuickButton(symbol: "record.circle", action: "record", tip: "Screen Record (⌘⇧R)")
        addQuickButton(symbol: "gearshape.fill", action: "settings", tip: "Settings (⌘,)")

        effect.addSubview(devicePillView)
        effect.addSubview(quickActionStack)

        deviceNameLabel.lineBreakMode = .byTruncatingTail
        linkBadgeLabel.lineBreakMode = .byTruncatingTail

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),

            borderLine.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            borderLine.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            borderLine.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            borderLine.heightAnchor.constraint(equalToConstant: 1),

            devicePillView.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 76), // Space for traffic lights
            devicePillView.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            devicePillView.trailingAnchor.constraint(lessThanOrEqualTo: quickActionStack.leadingAnchor, constant: -12),

            quickActionStack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            quickActionStack.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])
    }

    private func addQuickButton(symbol: String, action: String, tip: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config)

        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(quickActionTapped(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = tip
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true

        quickButtons[action] = button
        quickActionStack.addArrangedSubview(button)
    }

    @objc private func modeChanged() {
        guard let mode = DeviceHubMode(rawValue: modeSegmentControl.selectedSegment) else { return }
        currentMode = mode
        onModeSelected?(mode)
    }

    @objc private func quickActionTapped(_ sender: NSButton) {
        guard let action = sender.identifier?.rawValue else { return }
        onQuickAction?(action)
    }

    func setMode(_ mode: DeviceHubMode) {
        currentMode = mode
        modeSegmentControl.selectedSegment = mode.rawValue
    }

    func updateDeviceStatus(name: String, link: String, fps: Int, latencyMs: Int, connected: Bool) {
        deviceNameLabel.stringValue = name
        linkBadgeLabel.stringValue = "\(link) · \(fps) FPS"
        latencyChipLabel.stringValue = "\(latencyMs)ms"

        statusDotView.layer?.backgroundColor = connected
            ? NSColor.systemGreen.cgColor
            : NSColor.systemOrange.cgColor
    }

    func setRecordingOn(_ on: Bool) {
        if let btn = quickButtons["record"] {
            btn.layer?.backgroundColor = on
                ? NSColor.systemRed.withAlphaComponent(0.85).cgColor
                : NSColor.white.withAlphaComponent(0.06).cgColor
        }
    }
}
