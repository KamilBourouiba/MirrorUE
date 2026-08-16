import AppKit

/// Scrollable live timeline used by the Workflow sidebar tab.
final class WorkflowLiveStrip: NSView {
    private let titleLabel = NSTextField(labelWithString: "Timeline")
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(
        wrappingLabelWithString: "Choose a saved workflow, or press Record and control the phone."
    )
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var rowViews: [WorkflowStepRow] = []
    private var highlightIndex = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(scroll)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            countLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor,
                constant: 6
            ),

            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),

            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setMode(recording: Bool, playing: Bool) {
        if recording {
            titleLabel.stringValue = "Recording"
        } else if playing {
            titleLabel.stringValue = "Playing"
        } else {
            titleLabel.stringValue = "Timeline"
        }
    }

    func setVisible(_ on: Bool) {
        isHidden = !on
    }

    func reload(steps: [WorkflowStep], highlight index: Int? = nil) {
        if let index { highlightIndex = index }
        if steps.isEmpty { highlightIndex = -1 }
        countLabel.stringValue = steps.isEmpty ? "" : "\(steps.count) steps"
        emptyLabel.isHidden = !steps.isEmpty
        scroll.isHidden = steps.isEmpty

        while rowViews.count < steps.count {
            let row = WorkflowStepRow()
            stack.addArrangedSubview(row)
            rowViews.append(row)
        }
        while rowViews.count > steps.count {
            let row = rowViews.removeLast()
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for (offset, step) in steps.enumerated() {
            rowViews[offset].configure(
                index: offset + 1,
                step: step,
                active: offset == highlightIndex
            )
        }

        layoutSubtreeIfNeeded()
        if rowViews.indices.contains(highlightIndex), let document = scroll.documentView {
            let row = rowViews[highlightIndex]
            document.scrollToVisible(row.convert(row.bounds, to: document))
        }
    }

    func highlight(index: Int, steps: [WorkflowStep]) {
        highlightIndex = index
        reload(steps: steps, highlight: index)
    }
}

private final class WorkflowStepRow: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let indexLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        indexLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        indexLabel.textColor = .tertiaryLabelColor
        indexLabel.alignment = .right
        indexLabel.translatesAutoresizingMaskIntoConstraints = false

        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false

        [indexLabel, icon, title, detail].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            indexLabel.widthAnchor.constraint(equalToConstant: 18),
            icon.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 5),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let superview else { return }
        widthAnchor.constraint(equalTo: superview.widthAnchor).isActive = true
    }

    func configure(index: Int, step: WorkflowStep, active: Bool) {
        indexLabel.stringValue = "\(index)"
        title.stringValue = step.title
        detail.stringValue = step.detail
        icon.image = NSImage(
            systemSymbolName: step.symbolName,
            accessibilityDescription: step.title
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        icon.contentTintColor = step.accent
        toolTip = "\(step.title) — \(step.detail)"

        if active {
            layer?.backgroundColor = step.accent.withAlphaComponent(0.28).cgColor
            title.textColor = .labelColor
            detail.textColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
            title.textColor = .labelColor
            detail.textColor = .secondaryLabelColor
        }
    }
}
