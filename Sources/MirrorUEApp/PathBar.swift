import AppKit

/// Path name · saved list · Play · Export · Record (Record on the far right).
final class PathBar: NSView {
    var onRecordToggle: (() -> Void)?
    var onPlay: ((String) -> Void)?
    var onStopPlay: (() -> Void)?
    var onExport: ((String) -> Void)?

    private let effect = NSVisualEffectView()
    private let pathsPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let playButton = NSButton()
    private let exportButton = NSButton()
    private let recordButton = NSButton()
    private var recording = false
    private var playing = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 40)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        pathsPopup.bezelStyle = .rounded
        pathsPopup.font = .systemFont(ofSize: 11, weight: .medium)
        pathsPopup.target = self
        pathsPopup.action = #selector(pathPicked)
        pathsPopup.toolTip = "Parcours enregistrés — choisir un path sauvegardé"
        pathsPopup.translatesAutoresizingMaskIntoConstraints = false
        pathsPopup.setContentHuggingPriority(.required, for: .horizontal)

        nameField.placeholderString = "Path name"
        nameField.font = .systemFont(ofSize: 13, weight: .medium)
        nameField.isBordered = false
        nameField.isBezeled = false
        nameField.drawsBackground = true
        nameField.backgroundColor = NSColor.white.withAlphaComponent(0.08)
        nameField.textColor = .white
        nameField.focusRingType = .none
        nameField.wantsLayer = true
        nameField.layer?.cornerRadius = 8
        nameField.toolTip = "Nom du parcours — sauvegardé automatiquement à l'arrêt de l'enregistrement"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        playButton.image = symbol("play.fill", size: 14)
        playButton.imagePosition = .imageOnly
        playButton.bezelStyle = .rounded
        playButton.toolTip = "Lire le parcours enregistré"
        playButton.target = self
        playButton.action = #selector(playTapped)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.setContentHuggingPriority(.required, for: .horizontal)

        exportButton.image = symbol("square.and.arrow.up", size: 13)
        exportButton.imagePosition = .imageOnly
        exportButton.bezelStyle = .rounded
        exportButton.toolTip = "Exporter le parcours en JSON (fichier externe)"
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.setContentHuggingPriority(.required, for: .horizontal)

        recordButton.image = symbol("record.circle", size: 16)
        recordButton.imagePosition = .imageOnly
        recordButton.bezelStyle = .rounded
        recordButton.toolTip = "Enregistrer un parcours (⌘R)"
        recordButton.target = self
        recordButton.action = #selector(recordTapped)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.setContentHuggingPriority(.required, for: .horizontal)
        recordButton.keyEquivalent = "r"
        recordButton.keyEquivalentModifierMask = [.command]

        let row = NSStackView(views: [pathsPopup, nameField, playButton, exportButton, recordButton])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(row)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),

            row.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            nameField.heightAnchor.constraint(equalToConstant: 26),
            pathsPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        reloadPaths()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var pathName: String {
        get { nameField.stringValue }
        set { nameField.stringValue = newValue }
    }

    func reloadPaths(select name: String? = nil) {
        pathsPopup.removeAllItems()
        pathsPopup.addItem(withTitle: "Saved paths…")
        pathsPopup.lastItem?.isEnabled = false
        for url in WorkflowStore.list() {
            if let wf = try? WorkflowStore.load(from: url) {
                pathsPopup.addItem(withTitle: wf.name)
            }
        }
        pathsPopup.selectItem(at: 0)
        if let name, !name.isEmpty {
            nameField.stringValue = name
            if let idx = pathsPopup.itemArray.firstIndex(where: { $0.title == name }) {
                pathsPopup.selectItem(at: idx)
            }
        }
    }

    func setRecording(_ on: Bool, steps: Int = 0) {
        recording = on
        if on {
            recordButton.image = symbol("stop.circle.fill", size: 16, color: .systemRed)
            recordButton.toolTip = steps > 0 ? "Arrêter · \(steps) étapes" : "Arrêter l'enregistrement"
            nameField.placeholderString = "Recording…"
        } else {
            recordButton.image = symbol("record.circle", size: 16)
            recordButton.toolTip = "Enregistrer un parcours (⌘R)"
            nameField.placeholderString = "Path name"
        }
    }

    func setPlaying(_ on: Bool) {
        playing = on
        playButton.image = symbol(on ? "stop.fill" : "play.fill", size: 14, color: on ? .systemOrange : nil)
        playButton.toolTip = on ? "Arrêter la lecture" : "Lire le parcours enregistré"
    }

    func setStatus(_ text: String) {
        nameField.placeholderString = text.isEmpty ? "Path name" : text
    }

    @objc private func pathPicked() {
        let title = pathsPopup.titleOfSelectedItem ?? ""
        guard title != "Saved paths…", !title.isEmpty else { return }
        nameField.stringValue = title
    }

    @objc private func recordTapped() {
        onRecordToggle?()
    }

    @objc private func playTapped() {
        if playing {
            onStopPlay?()
            return
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            nameField.placeholderString = "Enter a path name"
            window?.makeFirstResponder(nameField)
            return
        }
        onPlay?(name)
    }

    @objc private func exportTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            nameField.placeholderString = "Pick a saved path"
            return
        }
        onExport?(name)
    }

    private func symbol(_ name: String, size: CGFloat, color: NSColor? = nil) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        if let color {
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)?
                .withTintColor(color)
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }
}

private extension NSImage {
    func withTintColor(_ color: NSColor) -> NSImage {
        let img = copy() as! NSImage
        img.isTemplate = false
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }
}
