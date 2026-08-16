import AppKit

/// Workflow library controls sized for the right automation sidebar.
final class PathBar: NSView {
    var onRecordToggle: (() -> Void)?
    var onPlay: ((String) -> Void)?
    var onStopPlay: (() -> Void)?
    var onExport: ((String) -> Void)?
    var onSelect: ((String) -> Void)?

    var onDelete: ((String) -> Void)?

    private let pathsPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let playButton = NSButton()
    private let exportButton = NSButton()
    private let deleteButton = NSButton()
    private let recordButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private var playing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        pathsPopup.bezelStyle = .rounded
        pathsPopup.font = .systemFont(ofSize: 11, weight: .medium)
        pathsPopup.target = self
        pathsPopup.action = #selector(pathPicked)
        pathsPopup.toolTip = "Choose a saved workflow"

        nameField.placeholderString = "Workflow name"
        nameField.font = .systemFont(ofSize: 12, weight: .medium)
        nameField.toolTip = "The recording is saved under this name"
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configure(
            playButton,
            symbol: "play.fill",
            tip: "Play the selected workflow",
            action: #selector(playTapped)
        )
        configure(
            exportButton,
            symbol: "square.and.arrow.up",
            tip: "Export workflow JSON",
            action: #selector(exportTapped)
        )
        configure(
            deleteButton,
            symbol: "trash",
            tip: "Delete the selected workflow",
            action: #selector(deleteTapped)
        )
        configure(
            recordButton,
            symbol: "record.circle",
            tip: "Start recording manual phone input",
            action: #selector(recordTapped)
        )

        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let actions = NSStackView(views: [
            nameField, playButton, exportButton, deleteButton, recordButton,
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6

        let content = NSStackView(views: [pathsPopup, actions, statusLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        [pathsPopup, actions, statusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        [playButton, exportButton, deleteButton, recordButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            nameField.heightAnchor.constraint(equalToConstant: 26),
            statusLabel.heightAnchor.constraint(equalToConstant: 14),
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
        let wanted = name ?? selectedWorkflowName
        pathsPopup.removeAllItems()
        pathsPopup.addItem(withTitle: "Saved workflows")
        pathsPopup.lastItem?.isEnabled = false
        for url in WorkflowStore.list() {
            if let workflow = try? WorkflowStore.load(from: url) {
                pathsPopup.addItem(withTitle: workflow.name)
            }
        }
        if let wanted,
           let index = pathsPopup.itemArray.firstIndex(where: { $0.title == wanted }) {
            pathsPopup.selectItem(at: index)
            nameField.stringValue = wanted
        } else {
            pathsPopup.selectItem(at: 0)
        }
    }

    func setRecording(_ on: Bool, steps: Int = 0) {
        recordButton.image = symbol(
            on ? "stop.circle.fill" : "record.circle",
            color: on ? .systemRed : nil
        )
        recordButton.toolTip = on
            ? "Stop recording\(steps > 0 ? " · \(steps) steps" : "")"
            : "Start recording manual phone input"
        playButton.isEnabled = !on
        exportButton.isEnabled = !on
        pathsPopup.isEnabled = !on
        statusLabel.stringValue = on ? "Recording · \(steps) steps" : statusLabel.stringValue
        statusLabel.textColor = on ? .systemRed : .secondaryLabelColor
    }

    func setPlaying(_ on: Bool) {
        playing = on
        playButton.image = symbol(
            on ? "stop.fill" : "play.fill",
            color: on ? .systemOrange : nil
        )
        playButton.toolTip = on ? "Stop playback" : "Play the selected workflow"
        recordButton.isEnabled = !on
        exportButton.isEnabled = !on
        pathsPopup.isEnabled = !on
    }

    func setStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text.isEmpty ? "Ready" : text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private var selectedWorkflowName: String? {
        let selected = pathsPopup.titleOfSelectedItem ?? ""
        return selected == "Saved workflows" || selected.isEmpty ? nil : selected
    }

    private func currentName() -> String? {
        let value = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            setStatus("Enter or select a workflow name", isError: true)
            window?.makeFirstResponder(nameField)
            return nil
        }
        return value
    }

    @objc private func pathPicked() {
        guard let name = selectedWorkflowName else { return }
        nameField.stringValue = name
        setStatus("Loaded · \(name)")
        onSelect?(name)
    }

    @objc private func recordTapped() { onRecordToggle?() }

    @objc private func playTapped() {
        if playing {
            onStopPlay?()
        } else if let name = currentName() {
            onPlay?(name)
        }
    }

    @objc private func exportTapped() {
        if let name = currentName() { onExport?(name) }
    }

    @objc private func deleteTapped() {
        if let name = currentName() { onDelete?(name) }
    }

    private func configure(
        _ button: NSButton,
        symbol: String,
        tip: String,
        action: Selector
    ) {
        button.image = self.symbol(symbol)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    private func symbol(_ name: String, color: NSColor? = nil) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        guard let color, let image else { return image }
        let copy = image.copy() as! NSImage
        copy.isTemplate = false
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }
}
