import AppKit

/// In-app privacy & security explanation (Product review §12).
final class PrivacyPanel: NSView {
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let title = NSTextField(labelWithString: "Privacy & Security")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let body = NSTextField(wrappingLabelWithString: """
        MirrorUE talks only to an iPhone that you have physically connected, unlocked, trusted, and authorized for development.

        • Screen frames and keystrokes stay on this Mac (and the phone). Nothing is uploaded to MirrorUE servers — there are none.
        • The local automation API binds to 127.0.0.1 only.
        • Developer Mode is required because touch/keyboard use Apple’s CoreDevice / UniversalHID developer services.
        • Pairing records and credentials must never be redistributed.
        • DRM apps may show a black screen while mirrored — that is enforced by the OS, not MirrorUE.
        • Optional diagnostics you copy stay on your clipboard until you paste them elsewhere.

        Permissions: camera / screen capture (CoreMediaIO), local network (CoreDevice tunnel).
        """)
        body.font = .systemFont(ofSize: 12.5, weight: .regular)
        body.textColor = .secondaryLabelColor
        body.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "Close", target: self, action: #selector(close))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        close.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(title)
        effect.addSubview(body)
        effect.addSubview(close)

        NSLayoutConstraint.activate([
            effect.centerXAnchor.constraint(equalTo: centerXAnchor),
            effect.centerYAnchor.constraint(equalTo: centerYAnchor),
            effect.widthAnchor.constraint(equalToConstant: 460),

            title.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 22),
            body.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -22),

            close.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 16),
            close.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            close.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -16),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(backdrop(_:)))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func close() { onClose?() }
    @objc private func backdrop(_ gr: NSClickGestureRecognizer) {
        // Ignore — require Close button for intentional dismiss of legal text.
    }
}
