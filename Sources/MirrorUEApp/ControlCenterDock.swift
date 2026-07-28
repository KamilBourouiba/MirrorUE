import AppKit

/// Floating frosted control bar — scales down when the window is narrow.
final class ControlCenterDock: NSView {
    var onAction: ((String) -> Void)?

    private let effect = NSVisualEffectView()
    private let border = NSView()
    private let row = NSStackView()
    private var buttons: [String: NSButton] = [:]
    private var tileSizeConstraints: [NSLayoutConstraint] = []
    private var dividerWidthConstraints: [NSLayoutConstraint] = []
    private var musicOn = false
    private var compact = false

    private static let tile: CGFloat = 34
    private static let tileCompact: CGFloat = 28
    private static let radius: CGFloat = 10
    private static let barRadius: CGFloat = 18

    /// Intrinsic width of the glass capsule at full size (for compact threshold).
    static let preferredWidth: CGFloat = 428

    /// Never drive the NSWindow size — a required intrinsic width caused
    /// `_changeWindowFrameFromConstraintsIfNecessary` layout-pass crashes.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 56)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.barRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        border.wantsLayer = true
        border.layer?.cornerRadius = Self.barRadius
        border.layer?.cornerCurve = .continuous
        border.layer?.borderWidth = 0.5
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        border.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(border)

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(row)

        NSLayoutConstraint.activate([
            effect.centerXAnchor.constraint(equalTo: centerXAnchor),
            effect.centerYAnchor.constraint(equalTo: centerYAnchor),
            effect.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            effect.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            effect.heightAnchor.constraint(equalToConstant: 50),

            border.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            border.topAnchor.constraint(equalTo: effect.topAnchor),
            border.bottomAnchor.constraint(equalTo: effect.bottomAnchor),

            row.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            row.topAnchor.constraint(equalTo: effect.topAnchor),
            row.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        appendGroup([
            ("house.fill", "home", "Home"),
            ("lock.fill", "lock", "Lock"),
            ("square.stack.3d.up.fill", "apps", "App Switcher"),
            ("switch.2", "cc", "Control Center"),
        ])
        appendDivider()
        appendGroup([
            ("waveform", "siri", "Siri"),
            ("bell.slash.fill", "mute", "Mute"),
        ])
        appendDivider()
        appendGroup([
            ("speaker.minus.fill", "volume-down", "Volume Down"),
            ("speaker.plus.fill", "volume-up", "Volume Up"),
        ])
        appendDivider()
        appendGroup([
            ("music.note", "music", "Music Safe"),
            ("bolt.fill", "instant", "Refresh"),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let needCompact = bounds.width > 0 && bounds.width < Self.preferredWidth + 8
        if needCompact != compact { setCompact(needCompact) }
    }

    func setCompact(_ on: Bool) {
        compact = on
        let size = on ? Self.tileCompact : Self.tile
        row.spacing = on ? 4 : 6
        for c in tileSizeConstraints { c.constant = size }
        for c in dividerWidthConstraints { c.constant = on ? 6 : 8 }
        for b in buttons.values {
            b.layer?.cornerRadius = on ? 8 : Self.radius
        }
        needsLayout = true
    }

    func setMusicSafe(_ on: Bool) {
        musicOn = on
        refreshTint(for: "music")
    }

    private func appendGroup(_ specs: [(String, String, String)]) {
        for (symbol, action, tip) in specs {
            row.addArrangedSubview(tileButton(symbol: symbol, action: action, tip: tip))
        }
    }

    private func appendDivider() {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let w = spacer.widthAnchor.constraint(equalToConstant: 8)
        w.isActive = true
        dividerWidthConstraints.append(w)

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        line.layer?.cornerRadius = 0.5
        line.translatesAutoresizingMaskIntoConstraints = false
        spacer.addSubview(line)
        NSLayoutConstraint.activate([
            line.centerXAnchor.constraint(equalTo: spacer.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: spacer.centerYAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 18),
        ])
        row.addArrangedSubview(spacer)
    }

    private func tileButton(symbol: String, action: String, tip: String) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .white))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config)
        let b = NSButton(image: image ?? NSImage(), target: self, action: #selector(tap(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(action)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyDown
        b.toolTip = tip
        b.focusRingType = .none
        b.setButtonType(.momentaryChange)
        b.wantsLayer = true
        b.layer?.cornerRadius = Self.radius
        b.layer?.cornerCurve = .continuous
        b.layer?.backgroundColor = Self.idleFill
        b.contentTintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        let w = b.widthAnchor.constraint(equalToConstant: Self.tile)
        let h = b.heightAnchor.constraint(equalToConstant: Self.tile)
        w.isActive = true
        h.isActive = true
        tileSizeConstraints.append(contentsOf: [w, h])
        buttons[action] = b
        return b
    }

    private static var idleFill: CGColor {
        NSColor.white.withAlphaComponent(0.10).cgColor
    }

    private static var pressFill: CGColor {
        NSColor.systemBlue.withAlphaComponent(0.85).cgColor
    }

    private static var activeFill: CGColor {
        NSColor.systemBlue.cgColor
    }

    private func refreshTint(for action: String) {
        guard let b = buttons[action] else { return }
        let on = action == "music" && musicOn
        b.layer?.backgroundColor = on ? Self.activeFill : Self.idleFill
        b.contentTintColor = .white
        b.alphaValue = 1
    }

    @objc private func tap(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        sender.layer?.backgroundColor = Self.pressFill
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            sender.animator().alphaValue = 0.85
        }, completionHandler: { [weak self] in
            sender.alphaValue = 1
            self?.refreshTint(for: id)
        })
        onAction?(id)
    }
}

/// Compact glass status chip overlaid on the mirror.
final class StatusChip: NSView {
    private let effect = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")

    var stringValue: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let rim = NSView()
        rim.wantsLayer = true
        rim.layer?.cornerRadius = 8
        rim.layer?.cornerCurve = .continuous
        rim.layer?.borderWidth = 0.5
        rim.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        rim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        rim.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(rim)

        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.88)
        label.drawsBackground = false
        label.isBordered = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),

            rim.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            rim.topAnchor.constraint(equalTo: effect.topAnchor),
            rim.bottomAnchor.constraint(equalTo: effect.bottomAnchor),

            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
