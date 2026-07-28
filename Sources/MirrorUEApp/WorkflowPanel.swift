import AppKit
import UniformTypeIdentifiers

/// Panel to record, play, save, and load automation workflows.
final class WorkflowPanel: NSView {
    var onClose: (() -> Void)?
    var onStartRecord: (() -> Void)?
    var onStopRecord: (() -> Workflow?)?
    var onPlay: ((Workflow) -> Void)?
    var onStopPlay: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let list = NSTextField(wrappingLabelWithString: "No steps yet.")
    private let status = NSTextField(labelWithString: "")
    private var current: Workflow?
    private var refreshTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let title = NSTextField(labelWithString: "Workflows")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        list.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        list.textColor = .secondaryLabelColor
        list.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false

        let record = NSButton(title: "Record", target: self, action: #selector(toggleRecord))
        record.bezelStyle = .rounded
        record.identifier = NSUserInterfaceItemIdentifier("recordBtn")
        let play = NSButton(title: "Play", target: self, action: #selector(play))
        play.bezelStyle = .rounded
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        let load = NSButton(title: "Load…", target: self, action: #selector(load))
        load.bezelStyle = .rounded
        let close = NSButton(title: "Close", target: self, action: #selector(close))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"

        let row1 = NSStackView(views: [record, play, save, load])
        row1.orientation = .horizontal
        row1.spacing = 8
        row1.translatesAutoresizingMaskIntoConstraints = false

        let row2 = NSStackView(views: [close])
        row2.orientation = .horizontal
        row2.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(title)
        effect.addSubview(list)
        effect.addSubview(status)
        effect.addSubview(row1)
        effect.addSubview(row2)

        NSLayoutConstraint.activate([
            effect.centerXAnchor.constraint(equalTo: centerXAnchor),
            effect.centerYAnchor.constraint(equalTo: centerYAnchor),
            effect.widthAnchor.constraint(equalToConstant: 440),
            effect.heightAnchor.constraint(lessThanOrEqualToConstant: 420),

            title.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),

            list.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            list.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            list.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),

            status.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            status.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),

            row1.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 14),
            row1.centerXAnchor.constraint(equalTo: effect.centerXAnchor),

            row2.topAnchor.constraint(equalTo: row1.bottomAnchor, constant: 10),
            row2.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            row2.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14),
        ])

        WorkflowRecorder.shared.onChanged = { [weak self] in self?.refreshList() }
        refreshList()

        let click = NSClickGestureRecognizer(target: self, action: #selector(backdrop(_:)))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setStatus(_ text: String) { status.stringValue = text }

    func setWorkflow(_ wf: Workflow) {
        current = wf
        refreshList()
    }

    private func refreshList() {
        let steps = WorkflowRecorder.shared.isRecording
            ? WorkflowRecorder.shared.steps
            : (current?.steps ?? [])
        if steps.isEmpty {
            list.stringValue = WorkflowRecorder.shared.isRecording
                ? "Recording… interact with the phone."
                : "No steps yet. Hit Record, use the mirror, then Stop."
        } else {
            let lines = steps.enumerated().map { "\($0.offset + 1). \($0.element.summary)" }
            list.stringValue = lines.suffix(18).joined(separator: "\n")
        }
        if let btn = effect.subviews.compactMap({ $0 as? NSStackView }).first?
            .arrangedSubviews.compactMap({ $0 as? NSButton })
            .first(where: { $0.identifier?.rawValue == "recordBtn" }) {
            btn.title = WorkflowRecorder.shared.isRecording ? "Stop" : "Record"
        }
    }

    @objc private func toggleRecord() {
        if WorkflowRecorder.shared.isRecording {
            if let wf = onStopRecord?() {
                current = wf
                status.stringValue = "Recorded \(wf.steps.count) steps"
            }
        } else {
            onStartRecord?()
            status.stringValue = "Recording…"
        }
        refreshList()
    }

    @objc private func play() {
        if WorkflowPlayer.shared.isPlaying {
            onStopPlay?()
            status.stringValue = "Stopped"
            return
        }
        let wf = current ?? Workflow(name: "live", steps: WorkflowRecorder.shared.steps)
        guard !wf.steps.isEmpty else {
            status.stringValue = "Nothing to play"
            return
        }
        current = wf
        onPlay?(wf)
    }

    @objc private func save() {
        guard let wf = current ?? optionalLive(), !wf.steps.isEmpty else {
            status.stringValue = "Nothing to save"
            return
        }
        do {
            let url = try WorkflowStore.save(wf)
            status.stringValue = "Saved \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status.stringValue = "Save failed: \(error)"
        }
    }

    private func optionalLive() -> Workflow? {
        let steps = WorkflowRecorder.shared.steps
        guard !steps.isEmpty else { return nil }
        return Workflow(name: "Untitled", steps: steps)
    }

    @objc private func load() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = WorkflowStore.directory
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            current = try WorkflowStore.load(from: url)
            status.stringValue = "Loaded \(url.lastPathComponent)"
            refreshList()
        } catch {
            status.stringValue = "Load failed: \(error)"
        }
    }

    @objc private func close() { onClose?() }

    @objc private func backdrop(_ gr: NSClickGestureRecognizer) {
        if !effect.frame.contains(gr.location(in: self)) { close() }
    }
}
