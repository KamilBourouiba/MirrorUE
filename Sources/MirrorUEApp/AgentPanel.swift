import AppKit

/// Provider-neutral UI snapshot. `AppDelegate` maps the agent actor's state
/// into this small presentation type, keeping the view independent of the
/// inference implementation.
struct AgentPanelSnapshot {
    var state: String
    var detail: String
    var logs: [String]
    var actions: [String] = []
    var running: Bool
    var provider: String
    var mode: String = "Checkpoint plans · up to 3 safe actions"
    var vision: String = "Trusted app state + local OCR · lowest latency"
}

/// Compact in-app goal runner for the phone agent.
final class AgentPanel: NSView {
    var onClose: (() -> Void)?
    var onRun: ((_ goal: String, _ maxSteps: Int) -> Void)?
    var onStop: (() -> Void)?
    var onConfigure: (() -> Void)?
    var snapshotProvider: (() async -> AgentPanelSnapshot)?

    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "iPhone Agent")
    private let subtitleLabel = NSTextField(
        wrappingLabelWithString: "Describe one goal. MirrorUE observes, validates, and executes bounded actions locally."
    )
    private let contentStack = NSStackView()
    private let goalField = NSTextField()
    private let stepsField = NSTextField()
    private let providerLabel = NSTextField(labelWithString: "Provider: —")
    private let modeLabel = NSTextField(
        labelWithString: "Checkpoint plans · up to 3 safe actions"
    )
    private let visionLabel = NSTextField(
        labelWithString: "Trusted app state + local OCR · lowest latency"
    )
    private let statusLabel = NSTextField(labelWithString: "Idle")
    private let progress = NSProgressIndicator()
    private let logView = NSTextView()
    private let runButton = NSButton()
    private let stopButton = NSButton()
    private let closeButton = NSButton()
    private var overlayConstraints: [NSLayoutConstraint] = []
    private var embeddedConstraints: [NSLayoutConstraint] = []
    private var backdropRecognizer: NSClickGestureRecognizer?
    private var embedded = false
    private var presentationActive = true
    private var pollTimer: Timer?
    private var pollInFlight = false
    private var isRunActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.48).cgColor

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.alignment = .center

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        goalField.placeholderString = "For example: Open Settings"
        goalField.font = .systemFont(ofSize: 13)
        goalField.target = self
        goalField.action = #selector(runClicked)

        stepsField.stringValue = "12"
        stepsField.alignment = .right
        stepsField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        stepsField.toolTip = "Maximum observe/act iterations (1–32)"

        let goalRow = NSStackView(views: [goalField, stepsField])
        goalRow.orientation = .horizontal
        goalRow.spacing = 8
        goalField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stepsField.translatesAutoresizingMaskIntoConstraints = false
        stepsField.widthAnchor.constraint(equalToConstant: 42).isActive = true

        providerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        providerLabel.textColor = .secondaryLabelColor
        providerLabel.lineBreakMode = .byTruncatingMiddle

        let configure = NSButton(title: "Provider…", target: self, action: #selector(configureClicked))
        configure.bezelStyle = .rounded
        configure.controlSize = .small
        let providerRow = NSStackView(views: [providerLabel, configure])
        providerRow.orientation = .horizontal
        providerRow.spacing = 8
        providerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        let stateRow = NSStackView(views: [progress, statusLabel])
        stateRow.orientation = .horizontal
        stateRow.spacing = 7

        logView.isEditable = false
        logView.isSelectable = true
        logView.drawsBackground = false
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        logView.textContainerInset = NSSize(width: 7, height: 6)
        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let preferredLogHeight = scroll.heightAnchor.constraint(equalToConstant: 150)
        preferredLogHeight.priority = .defaultHigh
        preferredLogHeight.isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true

        runButton.title = "Run"
        runButton.target = self
        runButton.action = #selector(runClicked)
        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"

        stopButton.title = "Stop"
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.bezelStyle = .rounded
        stopButton.isEnabled = false

        closeButton.title = "Close"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [closeButton, stopButton, runButton])
        buttons.orientation = .horizontal
        buttons.spacing = 9
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let buttonHost = NSView()
        buttonHost.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.centerXAnchor.constraint(equalTo: buttonHost.centerXAnchor),
            buttons.topAnchor.constraint(equalTo: buttonHost.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: buttonHost.bottomAnchor),
        ])

        modeLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        modeLabel.textColor = .systemBlue
        modeLabel.lineBreakMode = .byTruncatingTail
        visionLabel.font = .systemFont(ofSize: 10.5)
        visionLabel.textColor = .secondaryLabelColor
        visionLabel.lineBreakMode = .byTruncatingTail

        let runtimeDetails = NSStackView(views: [modeLabel, visionLabel])
        runtimeDetails.orientation = .vertical
        runtimeDetails.alignment = .leading
        runtimeDetails.spacing = 2

        for view in [
            titleLabel, subtitleLabel, goalRow, providerRow, runtimeDetails,
            stateRow, scroll, buttonHost,
        ] {
            contentStack.addArrangedSubview(view)
        }
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        for view in [
            titleLabel, subtitleLabel, goalRow, providerRow, runtimeDetails,
            stateRow, scroll, buttonHost,
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        effect.addSubview(contentStack)
        let preferredWidth = effect.widthAnchor.constraint(equalToConstant: 390)
        preferredWidth.priority = .defaultHigh
        overlayConstraints = [
            effect.centerXAnchor.constraint(equalTo: centerXAnchor),
            effect.centerYAnchor.constraint(equalTo: centerYAnchor),
            preferredWidth,
            effect.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
            effect.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            effect.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            effect.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            effect.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ]
        embeddedConstraints = [
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(overlayConstraints + [
            contentStack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),
            contentStack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -18),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(backdropClicked(_:)))
        addGestureRecognizer(click)
        backdropRecognizer = click
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    convenience init(frame frameRect: NSRect, embedded: Bool) {
        self.init(frame: frameRect)
        if embedded { useEmbeddedPresentation() }
    }

    private func useEmbeddedPresentation() {
        embedded = true
        layer?.backgroundColor = .clear
        effect.material = .sidebar
        effect.layer?.cornerRadius = 10
        titleLabel.isHidden = true
        subtitleLabel.isHidden = true
        contentStack.spacing = 8
        closeButton.isHidden = true
        if let backdropRecognizer {
            removeGestureRecognizer(backdropRecognizer)
            self.backdropRecognizer = nil
        }
        NSLayoutConstraint.deactivate(overlayConstraints)
        NSLayoutConstraint.activate(embeddedConstraints)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, presentationActive {
            startPolling()
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self?.goalField) }
        } else {
            stopPolling()
        }
    }

    override func removeFromSuperview() {
        stopPolling()
        super.removeFromSuperview()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func setPresentationActive(_ active: Bool) {
        presentationActive = active
        if active, window != nil {
            startPolling()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self.goalField)
            }
        } else {
            stopPolling()
        }
    }

    private func refresh() {
        guard !pollInFlight, let snapshotProvider else { return }
        pollInFlight = true
        Task { [weak self] in
            let snapshot = await snapshotProvider()
            await MainActor.run {
                guard let self else { return }
                self.pollInFlight = false
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: AgentPanelSnapshot) {
        isRunActive = snapshot.running
        providerLabel.stringValue = "Provider: \(snapshot.provider)"
        modeLabel.stringValue = snapshot.mode
        visionLabel.stringValue = snapshot.vision
        statusLabel.stringValue = snapshot.detail.isEmpty
            ? snapshot.state
            : "\(snapshot.state) · \(snapshot.detail)"
        statusLabel.textColor = snapshot.state == AgentRunStatus.failed.rawValue
            ? .systemRed
            : .labelColor
        if snapshot.running {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
        runButton.isEnabled = !snapshot.running
        stopButton.isEnabled = snapshot.running
        goalField.isEnabled = !snapshot.running
        stepsField.isEnabled = !snapshot.running

        let lines = snapshot.actions.isEmpty
            ? snapshot.logs.suffix(20)
            : snapshot.actions.suffix(80)
        let rendered = lines.joined(separator: "\n")
        if logView.string != rendered {
            logView.string = rendered
            logView.scrollToEndOfDocument(nil)
        }
    }

    func showMessage(_ message: String, isError: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    @objc private func runClicked() {
        let goal = goalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            NSSound.beep()
            statusLabel.stringValue = "Enter a goal first"
            return
        }
        let maxSteps = min(32, max(1, Int(stepsField.stringValue) ?? 12))
        stepsField.stringValue = "\(maxSteps)"
        isRunActive = true
        runButton.isEnabled = false
        stopButton.isEnabled = true
        onRun?(goal, maxSteps)
        refresh()
    }

    @objc private func stopClicked() {
        onStop?()
        refresh()
    }

    @objc private func configureClicked() { onConfigure?() }
    @objc private func closeClicked() {
        guard !isRunActive else {
            NSSound.beep()
            showMessage("Stop the active run before closing.", isError: true)
            return
        }
        onClose?()
    }

    @objc private func backdropClicked(_ gesture: NSClickGestureRecognizer) {
        guard !embedded else { return }
        let point = gesture.location(in: self)
        if !effect.frame.contains(point) { closeClicked() }
    }
}
