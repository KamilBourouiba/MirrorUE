import AppKit
import ControlKit

/// First-run / empty-state checklist shown above the device picker.
final class SetupChecklistView: NSView {
    var onContinue: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Set up MirrorUE")
    private let subtitle = NSTextField(wrappingLabelWithString:
        "MirrorUE controls a development iPhone you own and trust. Complete these steps once, then connect."
    )
    private let stack = NSStackView()
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)

    private let items: [(String, String)] = [
        ("cable.connector", "Connect your iPhone with a trusted USB cable"),
        ("lock.open", "Unlock the iPhone and tap Trust This Computer"),
        ("hammer.fill", "Enable Developer Mode (Settings → Privacy & Security)"),
        ("wifi", "Pair Network / Wi‑Fi debugging once via Xcode (for touch & keyboard)"),
        ("camera.fill", "Allow camera / screen capture when macOS asks"),
    ]

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

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitle.font = .systemFont(ofSize: 12.5, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (symbol, text) in items {
            stack.addArrangedSubview(row(symbol: symbol, text: text))
        }

        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.target = self
        continueButton.action = #selector(continueClicked)
        continueButton.translatesAutoresizingMaskIntoConstraints = false

        skipButton.bezelStyle = .rounded
        skipButton.target = self
        skipButton.action = #selector(continueClicked)
        skipButton.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [skipButton, continueButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(titleLabel)
        effect.addSubview(subtitle)
        effect.addSubview(stack)
        effect.addSubview(buttons)

        NSLayoutConstraint.activate([
            effect.centerXAnchor.constraint(equalTo: centerXAnchor),
            effect.centerYAnchor.constraint(equalTo: centerYAnchor),
            effect.widthAnchor.constraint(equalToConstant: 460),
            effect.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            effect.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            titleLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -24),

            subtitle.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 28),
            subtitle.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -28),

            stack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -28),

            buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 22),
            buttons.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func row(symbol: String, text: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        icon.contentTintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        return row
    }

    @objc private func continueClicked() {
        MirrorUESettings.setupChecklistSeen = true
        onContinue?()
    }
}
