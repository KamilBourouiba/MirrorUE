import AppKit

/// Interactive loopback HTTP API & CLI Studio panel for Device Hub.
final class DeviceAPIPanel: NSView {
    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "API & CLI Studio")
    private let subtitleLabel = NSTextField(
        wrappingLabelWithString: "MirrorUE Pro exposes a zero-latency loopback HTTP API and CLI executable for QA and CI/CD automation."
    )

    private let statusBadge = NSTextField(labelWithString: "● 127.0.0.1:8090 Active")
    private let codeSnippetView = NSTextView()
    private let copyButton = NSButton()
    private let endpointPopup = NSPopUpButton()
    var port: UInt16 = 8090

    private struct EndpointSpec {
        let name: String
        let method: String
        let path: String
        let description: String
        let cliCommand: String
        let curlSnippet: String
    }

    private let endpoints: [EndpointSpec] = [
        EndpointSpec(
            name: "Workflows List",
            method: "GET",
            path: "/v1/workflows",
            description: "List all saved path recordings and status",
            cliCommand: "./tools/mirrorue path list",
            curlSnippet: "curl -s http://127.0.0.1:8090/v1/workflows"
        ),
        EndpointSpec(
            name: "Play Workflow",
            method: "POST",
            path: "/v1/workflows/play",
            description: "Replay a saved path recording with latency tuning",
            cliCommand: "./tools/mirrorue path play --name \"Login smoke\"",
            curlSnippet: "curl -X POST http://127.0.0.1:8090/v1/workflows/play -d '{\"name\":\"Login smoke\"}'"
        ),
        EndpointSpec(
            name: "Record Start",
            method: "POST",
            path: "/v1/workflows/record/start",
            description: "Begin recording live user touches and inputs",
            cliCommand: "./tools/mirrorue path record start",
            curlSnippet: "curl -X POST http://127.0.0.1:8090/v1/workflows/record/start"
        ),
        EndpointSpec(
            name: "Tap Screen",
            method: "POST",
            path: "/v1/control/tap",
            description: "Send normalized tap gesture (0...1 coordinates)",
            cliCommand: "./tools/mirrorue control tap --x 0.5 --y 0.5",
            curlSnippet: "curl -X POST http://127.0.0.1:8090/v1/control/tap -d '{\"x\":0.5,\"y\":0.5}'"
        ),
        EndpointSpec(
            name: "Press Home",
            method: "POST",
            path: "/v1/control/home",
            description: "Trigger physical hardware Home button",
            cliCommand: "./tools/mirrorue control home",
            curlSnippet: "curl -X POST http://127.0.0.1:8090/v1/control/home"
        ),
        EndpointSpec(
            name: "Frame Grab",
            method: "GET",
            path: "/v1/vision/frame",
            description: "Capture low-latency JPEG screen buffer",
            cliCommand: "./tools/mirrorue frame grab --out frame.jpg",
            curlSnippet: "curl -s http://127.0.0.1:8090/v1/vision/frame?maxW=720 > frame.jpg"
        )
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        wantsLayer = true

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .labelColor

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        statusBadge.font = .systemFont(ofSize: 10, weight: .bold)
        statusBadge.textColor = .systemGreen

        endpointPopup.bezelStyle = .rounded
        endpointPopup.font = .systemFont(ofSize: 11, weight: .medium)
        endpointPopup.target = self
        endpointPopup.action = #selector(endpointChanged)
        endpoints.forEach { endpointPopup.addItem(withTitle: "\($0.method) \($0.path)") }

        codeSnippetView.isEditable = false
        codeSnippetView.isSelectable = true
        codeSnippetView.drawsBackground = false
        codeSnippetView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        codeSnippetView.textColor = .labelColor
        codeSnippetView.textContainerInset = NSSize(width: 8, height: 8)

        let scroll = NSScrollView()
        scroll.documentView = codeSnippetView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        copyButton.title = "Copy CLI Command"
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyClicked)

        let topRow = NSStackView(views: [titleLabel, statusBadge])
        topRow.orientation = .horizontal
        topRow.alignment = .firstBaseline
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let containerStack = NSStackView(views: [
            topRow,
            subtitleLabel,
            endpointPopup,
            scroll,
            copyButton
        ])
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 10
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(containerStack)

        [topRow, subtitleLabel, endpointPopup, scroll, copyButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalTo: containerStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),

            containerStack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            containerStack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            containerStack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            containerStack.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor, constant: -12),
        ])

        updateSnippet()
    }

    @objc private func endpointChanged() {
        updateSnippet()
    }

    @objc private func copyClicked() {
        let index = max(0, min(endpoints.count - 1, endpointPopup.indexOfSelectedItem))
        let spec = endpoints[index]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(spec.cliCommand, forType: .string)

        copyButton.title = "Copied to Clipboard!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyButton.title = "Copy CLI Command"
        }
    }

    private func updateSnippet() {
        let index = max(0, min(endpoints.count - 1, endpointPopup.indexOfSelectedItem))
        let spec = endpoints[index]

        let text = """
        # \(spec.description)
        # CLI Command:
        \(spec.cliCommand)

        # cURL Request:
        \(spec.curlSnippet)
        """
        codeSnippetView.string = text
    }

    func setServerStatus(running: Bool, port: UInt16) {
        self.port = port
        statusBadge.stringValue = running ? "● 127.0.0.1:\(port) Active" : "○ Server Stopped"
        statusBadge.textColor = running ? .systemGreen : .systemRed
    }
}
