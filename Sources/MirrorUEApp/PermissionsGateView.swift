import AVFoundation
import AppKit

/// One-by-one permission onboarding. Skips any permission already granted — never re-asks.
final class PermissionsGateView: NSView {
    var onFinished: (() -> Void)?

    private enum Step: Int, CaseIterable {
        case camera
        case done
    }

    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let stepLabel = NSTextField(labelWithString: "")
    private let allowButton = NSButton(title: "Allow…", target: nil, action: nil)
    private let nextButton = NSButton(title: "Continue", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    private var step: Step = .camera
    private var pollTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 20
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        for label in [titleLabel, bodyLabel, statusLabel, stepLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.alignment = .center
        }
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .labelColor
        bodyLabel.font = .systemFont(ofSize: 13, weight: .regular)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 6
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        stepLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        stepLabel.textColor = .tertiaryLabelColor

        allowButton.bezelStyle = .rounded
        allowButton.target = self
        allowButton.action = #selector(allowTapped)
        allowButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.target = self
        nextButton.action = #selector(nextTapped)
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        skipButton.bezelStyle = .rounded
        skipButton.target = self
        skipButton.action = #selector(skipTapped)
        skipButton.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [skipButton, allowButton, nextButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(stepLabel)
        effect.addSubview(titleLabel)
        effect.addSubview(bodyLabel)
        effect.addSubview(statusLabel)
        effect.addSubview(buttons)

        NSLayoutConstraint.activate([
            effect.centerXAnchor.constraint(equalTo: centerXAnchor),
            effect.centerYAnchor.constraint(equalTo: centerYAnchor),
            effect.widthAnchor.constraint(equalToConstant: 480),
            effect.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            effect.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            stepLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 20),
            stepLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 24),
            stepLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -24),

            titleLabel.topAnchor.constraint(equalTo: stepLabel.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -24),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            bodyLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 28),
            bodyLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -28),

            statusLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 28),
            statusLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -28),

            buttons.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            buttons.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -20),
        ])

        // If everything is already OK, close immediately — never re-ask.
        if MirrorUEPermissions.allRequiredGranted {
            DispatchQueue.main.async { [weak self] in self?.finish() }
            return
        }

        step = firstMissingStep()
        if step == .done {
            DispatchQueue.main.async { [weak self] in self?.finish() }
            return
        }
        render()
        startPolling()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { pollTimer?.invalidate() }

    private func firstMissingStep() -> Step {
        if !MirrorUEPermissions.cameraGranted { return .camera }
        return .done
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Auto-skip a step the moment the OS grants it — no second prompt.
            if self.step == .camera, MirrorUEPermissions.cameraGranted {
                self.finish()
                return
            }
            if MirrorUEPermissions.allRequiredGranted {
                self.finish()
                return
            }
            self.render()
        }
    }

    private func render() {
        switch step {
        case .camera:
            if MirrorUEPermissions.cameraGranted {
                finish()
                return
            }
            stepLabel.stringValue = "PERMISSION"
            titleLabel.stringValue = "Camera / Continuity"
            bodyLabel.stringValue =
                "MirrorUE needs camera access so macOS can show your iPhone display (CoreMediaIO).\n\nTap Allow once — we won’t ask again if it’s already granted.\n\nScreen Recording for MirrorUE is optional; the agent uses the live phone frame API, not Mac screencapture."
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            statusLabel.stringValue = status == .denied || status == .restricted
                ? "Denied — open System Settings → Privacy → Camera"
                : "Not granted yet"
            statusLabel.textColor = .secondaryLabelColor
            allowButton.isHidden = status == .denied || status == .restricted
            allowButton.title = "Allow Camera…"
            nextButton.title = "Continue anyway"
            skipButton.isHidden = false

        case .done:
            finish()
        }
    }

    @objc private func allowTapped() {
        switch step {
        case .camera:
            // No-op if already granted.
            guard !MirrorUEPermissions.cameraGranted else {
                finish()
                return
            }
            MirrorUEPermissions.requestCameraExplicitly { [weak self] in
                DispatchQueue.main.async {
                    if MirrorUEPermissions.cameraGranted {
                        self?.finish()
                    } else {
                        self?.render()
                    }
                }
            }
        case .done:
            break
        }
    }

    @objc private func nextTapped() { advance() }
    @objc private func skipTapped() { advance() }

    private func advance() {
        finish()
    }

    private func finish() {
        pollTimer?.invalidate()
        pollTimer = nil
        MirrorUEPermissions.markGateCompleted()
        onFinished?()
    }
}
