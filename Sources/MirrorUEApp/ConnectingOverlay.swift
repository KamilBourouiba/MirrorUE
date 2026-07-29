import AppKit
import DeviceKit

/// Frosted connecting overlay with spinner, steps, and device details.
/// Card size follows content and shrinks with the window (no clipped steps).
final class ConnectingOverlay: NSView {
    var onRetry: (() -> Void)?
    var onBack: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "Connecting")
    private let detailLabel = NSTextField(labelWithString: "")
    private let stepsLabel = NSTextField(labelWithString: "")
    private let pulse = NSView()
    private let retryButton = NSButton(title: "Try again", target: nil, action: nil)
    private let backButton = NSButton(title: "Choose device", target: nil, action: nil)
    private var actions: NSStackView?
    private var pulseAnim: CABasicAnimation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 20
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let rim = NSView()
        rim.wantsLayer = true
        rim.layer?.cornerRadius = 20
        rim.layer?.cornerCurve = .continuous
        rim.layer?.borderWidth = 0.5
        rim.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        rim.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        rim.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(rim)

        pulse.wantsLayer = true
        pulse.layer?.cornerRadius = 28
        pulse.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor
        pulse.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(pulse)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(spinner)

        let phoneIcon = NSImageView()
        phoneIcon.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "iPhone")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 28, weight: .medium))
        phoneIcon.contentTintColor = .white
        phoneIcon.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(phoneIcon)

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        stepsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        stepsLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        stepsLabel.alignment = .left
        stepsLabel.maximumNumberOfLines = 6
        stepsLabel.lineBreakMode = .byWordWrapping
        stepsLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        stepsLabel.translatesAutoresizingMaskIntoConstraints = false

        retryButton.bezelStyle = .rounded
        retryButton.title = "Try again"
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        backButton.bezelStyle = .rounded
        backButton.title = "Choose device"
        backButton.target = self
        backButton.action = #selector(backClicked)
        backButton.isHidden = true
        backButton.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [backButton, retryButton])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.translatesAutoresizingMaskIntoConstraints = false
        self.actions = actions

        effect.addSubview(titleLabel)
        effect.addSubview(detailLabel)
        effect.addSubview(stepsLabel)
        effect.addSubview(actions)

        let maxW = effect.widthAnchor.constraint(equalToConstant: 320)
        maxW.priority = .defaultHigh
        let minW = effect.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)

        NSLayoutConstraint.activate([
            effect.centerXAnchor.constraint(equalTo: centerXAnchor),
            effect.centerYAnchor.constraint(equalTo: centerYAnchor),
            effect.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            effect.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            effect.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
            effect.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            maxW,
            minW,

            rim.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            rim.topAnchor.constraint(equalTo: effect.topAnchor),
            rim.bottomAnchor.constraint(equalTo: effect.bottomAnchor),

            pulse.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            pulse.topAnchor.constraint(equalTo: effect.topAnchor, constant: 22),
            pulse.widthAnchor.constraint(equalToConstant: 56),
            pulse.heightAnchor.constraint(equalToConstant: 56),

            phoneIcon.centerXAnchor.constraint(equalTo: pulse.centerXAnchor),
            phoneIcon.centerYAnchor.constraint(equalTo: pulse.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: pulse.bottomAnchor, constant: 12),

            titleLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            detailLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),

            stepsLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 14),
            stepsLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 22),
            stepsLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),

            actions.topAnchor.constraint(equalTo: stepsLabel.bottomAnchor, constant: 16),
            actions.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            actions.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(device: DeviceInfo, step: String) {
        isHidden = false
        alphaValue = 1
        let name = device.name ?? "iPhone"
        let model = device.productType ?? "—"
        let ios = device.productVersion.map { "iOS \($0)" } ?? ""
        let short = String(device.udid.prefix(12))
        detailLabel.stringValue = "\(name)\n\(model)  ·  \(ios)\n\(short)…"
        setStep(step)
        setFailureActions(visible: false)
        spinner.startAnimation(nil)
        startPulse()
    }

    func setStep(_ step: String) {
        titleLabel.stringValue = step
    }

    func setSteps(_ lines: [String]) {
        stepsLabel.stringValue = lines.joined(separator: "\n")
    }

    func showFailed(title: String, detail: String, steps: [String]) {
        setStep(title)
        if !detail.isEmpty {
            detailLabel.stringValue = detailLabel.stringValue.split(separator: "\n").prefix(2).joined(separator: "\n")
                + "\n\n" + detail
        }
        setSteps(steps)
        setFailureActions(visible: true)
        spinner.stopAnimation(nil)
        stopPulse()
    }

    func hideAnimated() {
        spinner.stopAnimation(nil)
        stopPulse()
        setFailureActions(visible: false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
            self?.alphaValue = 1
        })
    }

    private func setFailureActions(visible: Bool) {
        retryButton.isHidden = !visible
        backButton.isHidden = !visible
        actions?.isHidden = !visible
    }

    @objc private func retryClicked() { onRetry?() }
    @objc private func backClicked() { onBack?() }

    private func startPulse() {
        pulse.layer?.removeAllAnimations()
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 1.0
        anim.toValue = 1.18
        anim.duration = 0.9
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.layer?.add(anim, forKey: "pulse")
        pulseAnim = anim
    }

    private func stopPulse() {
        pulse.layer?.removeAnimation(forKey: "pulse")
        pulseAnim = nil
    }
}

/// Small glass badge for persistent device / link info.
final class InfoBadge: NSView {
    private let effect = NSVisualEffectView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

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
        rim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        rim.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(rim)

        iconView.contentTintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(iconView)

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.drawsBackground = false
        label.isBordered = false
        label.lineBreakMode = .byTruncatingTail
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

            iconView.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(symbol: String, text: String, tip: String? = nil) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        label.stringValue = text
        toolTip = tip ?? text
        isHidden = text.isEmpty
    }
}
