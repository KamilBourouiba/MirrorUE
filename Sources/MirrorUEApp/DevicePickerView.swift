import AppKit
import DeviceKit

/// Startup panel: list USB iPhones and let the user pick one.
final class DevicePickerView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((DeviceInfo) -> Void)?

    private let effect = NSVisualEffectView()
    private let titleIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Select iPhone")
    private let hintLabel = NSTextField(wrappingLabelWithString:
        "Connect a trusted USB cable, unlock the phone, then choose a device.")
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let refreshButton = NSButton()
    private let connectButton = NSButton()
    private let emptyLabel = NSTextField(wrappingLabelWithString:
        "No USB iPhone found — plug in, unlock, and tap Trust This Mac on the phone.")

    private var devices: [DeviceInfo] = []
    private var pollTimer: Timer?

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

        let rim = NSView()
        rim.wantsLayer = true
        rim.layer?.cornerRadius = 20
        rim.layer?.cornerCurve = .continuous
        rim.layer?.borderWidth = 0.5
        rim.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        rim.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        rim.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(rim)

        titleIcon.image = sfSymbol("iphone.gen3", size: 22)
        titleIcon.contentTintColor = .labelColor
        titleIcon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView(views: [titleIcon, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .centerY
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 12, weight: .regular)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 0
        hintLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        table.style = .plain
        table.headerView = nil
        table.rowHeight = 56
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.doubleAction = #selector(connectClicked)
        table.target = self
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device"))
        col.resizingMask = .autoresizingMask
        col.minWidth = 200
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        styleButton(
            refreshButton, title: "Refresh", symbolName: "arrow.clockwise", primary: false,
            tip: "Rechercher à nouveau les iPhones branchés en USB")
        refreshButton.target = self
        refreshButton.action = #selector(reload)

        styleButton(
            connectButton, title: "Connect", symbolName: "cable.connector", primary: true,
            tip: "Miroir et contrôle de l'iPhone sélectionné")
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connectClicked)

        let buttons = NSStackView(views: [refreshButton, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(titleRow)
        effect.addSubview(hintLabel)
        effect.addSubview(scroll)
        effect.addSubview(emptyLabel)
        effect.addSubview(buttons)

        let panelW = effect.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.9)
        panelW.priority = .defaultHigh
        let panelH = effect.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.78)
        panelH.priority = .defaultHigh

        NSLayoutConstraint.activate([
            effect.centerXAnchor.constraint(equalTo: centerXAnchor),
            effect.centerYAnchor.constraint(equalTo: centerYAnchor),
            effect.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            effect.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            effect.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            effect.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            panelW,
            effect.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            effect.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            panelH,
            effect.heightAnchor.constraint(lessThanOrEqualToConstant: 440),
            effect.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),

            rim.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            rim.topAnchor.constraint(equalTo: effect.topAnchor),
            rim.bottomAnchor.constraint(equalTo: effect.bottomAnchor),

            titleRow.topAnchor.constraint(equalTo: effect.topAnchor, constant: 20),
            titleRow.centerXAnchor.constraint(equalTo: effect.centerXAnchor),

            hintLabel.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 10),
            hintLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),

            emptyLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -12),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            buttons.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -16),
            buttons.heightAnchor.constraint(equalToConstant: 36),
        ])

        reload()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { pollTimer?.invalidate() }

    override func layout() {
        super.layout()
        hintLabel.preferredMaxLayoutWidth = max(220, effect.bounds.width - 40)
        emptyLabel.preferredMaxLayoutWidth = max(200, effect.bounds.width - 56)
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc func reload() {
        let previous = selectedDevice()?.udid
        do {
            devices = try Usbmux.usbDevices()
        } catch {
            devices = []
        }
        table.reloadData()
        emptyLabel.isHidden = !devices.isEmpty
        connectButton.isEnabled = !devices.isEmpty
        connectButton.alphaValue = devices.isEmpty ? 0.45 : 1

        if devices.count == 1 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else if let previous, let idx = devices.firstIndex(where: { $0.udid == previous }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    @objc private func connectClicked() {
        guard let device = selectedDevice() else { return }
        stopPolling()
        onSelect?(device)
    }

    private func selectedDevice() -> DeviceInfo? {
        let row = table.selectedRow
        guard row >= 0, row < devices.count else { return nil }
        return devices[row]
    }

    func numberOfRows(in tableView: NSTableView) -> Int { devices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let device = devices[row]
        let cell = DeviceRowView()
        cell.configure(device: device)
        return cell
    }

    private func styleButton(_ button: NSButton, title: String, symbolName: String, primary: Bool, tip: String) {
        button.title = title
        button.image = sfSymbol(symbolName, size: primary ? 14 : 13)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = .systemFont(ofSize: 13, weight: primary ? .semibold : .medium)
        button.bezelStyle = .rounded
        button.isBordered = !primary
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        if primary {
            button.contentTintColor = .white
            button.wantsLayer = true
            button.layer?.cornerRadius = 10
            button.layer?.cornerCurve = .continuous
            button.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        } else {
            button.contentTintColor = .labelColor
        }
    }

    private func sfSymbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
    }
}

// MARK: - Device row

private final class DeviceRowView: NSView {
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor

        icon.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "iPhone")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(nameLabel)
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(device: DeviceInfo) {
        nameLabel.stringValue = device.name ?? "iPhone"
        let model = device.productType ?? "unknown"
        let version = device.productVersion.map { "iOS \($0)" } ?? "iOS —"
        let udid = device.udid
        detailLabel.stringValue = "\(model) · \(version) · \(udid)"
        toolTip = "\(device.name ?? "iPhone")\n\(model) · \(version)\nUDID \(udid)"
    }
}
