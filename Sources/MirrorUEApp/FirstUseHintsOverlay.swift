import AppKit

/// Brief first-connection tips overlay (shown once).
final class FirstUseHintsOverlay: NSView {
    var onDismiss: (() -> Void)?

    private let effect = NSVisualEffectView()
    private var dismissTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        alphaValue = 0

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let title = NSTextField(labelWithString: "You're connected")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let body = NSTextField(wrappingLabelWithString: """
        Click to tap · Drag to swipe · Scroll with the trackpad
        Type with your Mac keyboard · Dock for Home / Lock / volume
        """)
        body.font = .systemFont(ofSize: 12.5, weight: .regular)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.translatesAutoresizingMaskIntoConstraints = false

        let dismiss = NSButton(title: "Got it", target: self, action: #selector(close))
        dismiss.bezelStyle = .rounded
        dismiss.keyEquivalent = "\r"
        dismiss.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(title)
        effect.addSubview(body)
        effect.addSubview(dismiss)

        NSLayoutConstraint.activate([
            effect.centerXAnchor.constraint(equalTo: centerXAnchor),
            effect.centerYAnchor.constraint(equalTo: centerYAnchor),
            effect.widthAnchor.constraint(equalToConstant: 360),

            title.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            body.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 22),
            body.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -22),

            dismiss.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 16),
            dismiss.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            dismiss.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -16),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(close))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSView) {
        frame = parent.bounds
        autoresizingMask = [.width, .height]
        parent.addSubview(self)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            animator().alphaValue = 1
        }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.close()
        }
    }

    @objc private func close() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
            self?.onDismiss?()
        })
    }
}
