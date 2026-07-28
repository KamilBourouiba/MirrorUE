import AppKit
import ControlKit

/// In-app settings (replaces most MIRRORUE_* env vars for end users).
final class SettingsPanel: NSView {
    var onClose: (() -> Void)?
    var onApply: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let kbPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let landPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var touchesCheck: NSButton!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 14
        form.translatesAutoresizingMaskIntoConstraints = false

        form.addArrangedSubview(labeled("Frame rate", control: fpsPopup))
        form.addArrangedSubview(labeled("iPhone keyboard", control: kbPopup))
        form.addArrangedSubview(labeled("Landscape touch", control: landPopup))

        let touches = NSButton(checkboxWithTitle: "Show touches", target: nil, action: nil)
        touches.state = MirrorUESettings.showTouches ? .on : .off
        touches.translatesAutoresizingMaskIntoConstraints = false
        self.touchesCheck = touches
        form.addArrangedSubview(touches)

        for mode in MirrorUESettings.FrameRate.allCases {
            fpsPopup.addItem(withTitle: mode.title)
            fpsPopup.lastItem?.representedObject = mode.rawValue
        }
        for mode in MirrorUESettings.KeyboardMode.allCases {
            kbPopup.addItem(withTitle: mode.title)
            kbPopup.lastItem?.representedObject = mode.rawValue
        }
        for mode in MirrorUESettings.LandscapeHome.allCases {
            landPopup.addItem(withTitle: mode.title)
            landPopup.lastItem?.representedObject = mode.rawValue
        }

        select(fpsPopup, value: MirrorUESettings.frameRate.rawValue)
        select(kbPopup, value: MirrorUESettings.keyboardMode.rawValue)
        select(landPopup, value: MirrorUESettings.landscapeHome.rawValue)

        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [cancel, done])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(title)
        effect.addSubview(form)
        effect.addSubview(buttons)

        NSLayoutConstraint.activate([
            effect.centerXAnchor.constraint(equalTo: centerXAnchor),
            effect.centerYAnchor.constraint(equalTo: centerYAnchor),
            effect.widthAnchor.constraint(equalToConstant: 380),

            title.topAnchor.constraint(equalTo: effect.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),

            form.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            form.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -24),

            buttons.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 20),
            buttons.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -18),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(backdropClicked(_:)))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func labeled(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let col = NSStackView(views: [label, control])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        return col
    }

    private func select(_ popup: NSPopUpButton, value: Any) {
        for (i, item) in (popup.itemArray).enumerated() {
            if let rep = item.representedObject as? Int, let v = value as? Int, rep == v {
                popup.selectItem(at: i)
                return
            }
            if let rep = item.representedObject as? String, let v = value as? String, rep == v {
                popup.selectItem(at: i)
                return
            }
        }
    }

    @objc private func doneClicked() {
        if let raw = fpsPopup.selectedItem?.representedObject as? Int,
           let mode = MirrorUESettings.FrameRate(rawValue: raw) {
            MirrorUESettings.frameRate = mode
        }
        if let raw = kbPopup.selectedItem?.representedObject as? String,
           let mode = MirrorUESettings.KeyboardMode(rawValue: raw) {
            MirrorUESettings.keyboardMode = mode
        }
        if let raw = landPopup.selectedItem?.representedObject as? String,
           let mode = MirrorUESettings.LandscapeHome(rawValue: raw) {
            MirrorUESettings.landscapeHome = mode
        }
        MirrorUESettings.showTouches = touchesCheck.state == .on
        MirrorUESettings.applyToEnvironment()
        onApply?()
        onClose?()
    }

    @objc private func cancelClicked() { onClose?() }

    @objc private func backdropClicked(_ gr: NSClickGestureRecognizer) {
        let p = gr.location(in: self)
        if !effect.frame.contains(p) { onClose?() }
    }
}
