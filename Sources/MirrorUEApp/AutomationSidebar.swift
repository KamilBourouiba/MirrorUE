import AppKit

enum AutomationSidebarTab: Int {
    case workflow = 0
    case aiRuns = 1
    case telemetry = 2
    case apiStudio = 3
}

/// Persistent right-side home for deterministic workflows, AI agent runs, telemetry and API studio.
final class AutomationSidebar: NSView {
    static let expandedWidth: CGFloat = 336
    static let collapsedWidth: CGFloat = 42

    var onCollapsedChanged: ((Bool) -> Void)?

    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Device Hub Studio")
    private let tabControl = NSSegmentedControl(
        labels: ["Workflow", "AI Runs", "Stats", "API"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let collapseButton = NSButton()
    private let contentHost = NSView()

    private let workflowView: NSView
    private let agentView: AgentPanel
    private let telemetryView: DeviceTelemetryPanel
    private let apiView: DeviceAPIPanel

    private(set) var isCollapsed = false
    private(set) var selectedTab: AutomationSidebarTab = .workflow

    init(
        frame frameRect: NSRect,
        workflowView: NSView,
        agentView: AgentPanel,
        telemetryView: DeviceTelemetryPanel,
        apiView: DeviceAPIPanel
    ) {
        self.workflowView = workflowView
        self.agentView = agentView
        self.telemetryView = telemetryView
        self.apiView = apiView
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.24
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: -3, height: 0)

        effect.material = .sidebar
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(titleLabel)

        collapseButton.image = sidebarSymbol(collapsed: false)
        collapseButton.imagePosition = .imageOnly
        collapseButton.isBordered = false
        collapseButton.toolTip = "Collapse studio sidebar"
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapsed)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(collapseButton)

        tabControl.selectedSegment = AutomationSidebarTab.workflow.rawValue
        tabControl.segmentStyle = .texturedRounded
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.isHidden = true // Top header bar is single source of truth for mode selection
        effect.addSubview(tabControl)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(contentHost)

        for child in [workflowView, agentView, telemetryView, apiView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                child.topAnchor.constraint(equalTo: contentHost.topAnchor),
                child.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),

            collapseButton.topAnchor.constraint(equalTo: effect.topAnchor, constant: 9),
            collapseButton.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            collapseButton.widthAnchor.constraint(equalToConstant: 26),
            collapseButton.heightAnchor.constraint(equalToConstant: 26),

            titleLabel.centerYAnchor.constraint(equalTo: collapseButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: collapseButton.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -10),

            contentHost.topAnchor.constraint(equalTo: collapseButton.bottomAnchor, constant: 8),
            contentHost.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 9),
            contentHost.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -9),
            contentHost.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -9),
        ])

        show(.workflow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: AutomationSidebarTab) {
        if isCollapsed { setCollapsed(false) }
        selectedTab = tab
        tabControl.selectedSegment = tab.rawValue
        switch tab {
        case .workflow:
            titleLabel.stringValue = "Device Hub · Workflows"
        case .aiRuns:
            titleLabel.stringValue = "Device Hub · AI Agent"
        case .telemetry:
            titleLabel.stringValue = "Device Hub · Telemetry"
        case .apiStudio:
            titleLabel.stringValue = "Device Hub · API Studio"
        }
        workflowView.isHidden = tab != .workflow
        agentView.isHidden = tab != .aiRuns
        telemetryView.isHidden = tab != .telemetry
        apiView.isHidden = tab != .apiStudio
        agentView.setPresentationActive(tab == .aiRuns)
    }

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        titleLabel.isHidden = collapsed
        tabControl.isHidden = true
        contentHost.isHidden = collapsed
        collapseButton.image = sidebarSymbol(collapsed: collapsed)
        collapseButton.toolTip = collapsed
            ? "Expand studio sidebar"
            : "Collapse studio sidebar"
        agentView.setPresentationActive(!collapsed && selectedTab == .aiRuns)
        onCollapsedChanged?(collapsed)
    }

    @objc private func toggleCollapsed() {
        setCollapsed(!isCollapsed)
    }

    var onTabSelected: ((AutomationSidebarTab) -> Void)?

    @objc private func tabChanged() {
        let tab = AutomationSidebarTab(rawValue: tabControl.selectedSegment) ?? .workflow
        show(tab)
        onTabSelected?(tab)
    }

    private func sidebarSymbol(collapsed: Bool) -> NSImage? {
        let name = collapsed ? "chevron.left" : "chevron.right"
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        return NSImage(
            systemSymbolName: name,
            accessibilityDescription: collapsed ? "Expand sidebar" : "Collapse sidebar"
        )?.withSymbolConfiguration(configuration)
    }
}

/// Vertical composition for the Workflow tab.
final class WorkflowSidebarView: NSView {
    let pathBar: PathBar
    let timeline: WorkflowLiveStrip

    init(frame frameRect: NSRect, pathBar: PathBar, timeline: WorkflowLiveStrip) {
        self.pathBar = pathBar
        self.timeline = timeline
        super.init(frame: frameRect)

        let helper = NSTextField(
            wrappingLabelWithString: "Record manual taps, swipes and typing, then replay them with latency compensation."
        )
        helper.font = .systemFont(ofSize: 10.5)
        helper.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [helper, pathBar, timeline])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        [helper, pathBar, timeline].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        pathBar.heightAnchor.constraint(equalToConstant: 96).isActive = true
        timeline.setContentHuggingPriority(.defaultLow, for: .vertical)
        timeline.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            timeline.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
