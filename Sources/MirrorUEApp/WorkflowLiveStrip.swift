import AppKit

/// Live path timeline with SF Symbols — shown while recording or playing.
final class WorkflowLiveStrip: NSView {
    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Path")
    private let countLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var rowViews: [WorkflowStepRow] = []
    private var highlightIndex = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(titleLabel)
        effect.addSubview(countLabel)
        effect.addSubview(scroll)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),

            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),

            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
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
            titleLabel.stringValue = "Path"
        }
    }

    func setVisible(_ on: Bool) {
        isHidden = !on
    }

    func reload(steps: [WorkflowStep], highlight index: Int? = nil) {
        if let index { highlightIndex = index }
        countLabel.stringValue = steps.isEmpty ? "" : "\(steps.count)"

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

        for (i, step) in steps.enumerated() {
            rowViews[i].configure(index: i + 1, step: step, active: i == highlightIndex)
        }

        layoutSubtreeIfNeeded()
        if highlightIndex >= 0, highlightIndex < rowViews.count, let doc = scroll.documentView {
            let row = rowViews[highlightIndex]
            doc.scrollToVisible(row.convert(row.bounds, to: doc))
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
        indexLabel.translatesAutoresizingMaskIntoConstraints = false

        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false

        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        detail.font = .systemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false

        addSubview(indexLabel)
        addSubview(icon)
        addSubview(title)
        addSubview(detail)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            widthAnchor.constraint(equalToConstant: 168),

            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            indexLabel.widthAnchor.constraint(equalToConstant: 14),

            icon.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 0),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(index: Int, step: WorkflowStep, active: Bool) {
        indexLabel.stringValue = "\(index)"
        title.stringValue = step.title
        detail.stringValue = step.detail
        icon.image = NSImage(systemSymbolName: step.symbolName, accessibilityDescription: step.title)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        toolTip = "\(step.title) — \(step.detail)"

        if active {
            layer?.backgroundColor = step.accent.withAlphaComponent(0.35).cgColor
            icon.contentTintColor = step.accent
            title.textColor = .white
            detail.textColor = NSColor.white.withAlphaComponent(0.82)
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            icon.contentTintColor = step.accent.withAlphaComponent(0.85)
            title.textColor = .labelColor
            detail.textColor = .secondaryLabelColor
        }
    }
}
