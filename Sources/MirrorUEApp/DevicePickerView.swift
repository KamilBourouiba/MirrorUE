import AppKit
import DeviceKit

/// Startup panel: list USB iPhones and let the user pick one.
final class DevicePickerView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((DeviceInfo) -> Void)?

    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Select iPhone")
    private let hintLabel = NSTextField(labelWithString: "Connect a trusted USB cable, unlock the phone, then choose a device.")
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No USB iPhone found — plug in, unlock, and Trust this Mac")

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

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 12, weight: .regular)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.maximumNumberOfLines = 2
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        table.style = .plain
        table.headerView = nil
        table.rowHeight = 52
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.doubleAction = #selector(connectClicked)
        table.target = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device"))
        col.width = 360
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(reload)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connectClicked)
        connectButton.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [refreshButton, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(titleLabel)
        effect.addSubview(hintLabel)
        effect.addSubview(scroll)
        effect.addSubview(emptyLabel)
        effect.addSubview(buttons)

        NSLayoutConstraint.activate([
            effect.centerXAnchor.constraint(equalTo: centerXAnchor),
            effect.centerYAnchor.constraint(equalTo: centerYAnchor),
            effect.widthAnchor.constraint(equalToConstant: 420),
            effect.heightAnchor.constraint(equalToConstant: 360),

            rim.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            rim.topAnchor.constraint(equalTo: effect.topAnchor),
            rim.bottomAnchor.constraint(equalTo: effect.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),

            hintLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            hintLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -24),

            scroll.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            buttons.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -18),
            buttons.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
        ])

        reload()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { pollTimer?.invalidate() }

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
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.drawsBackground = false
        text.isBordered = false
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        let name = device.name ?? "iPhone"
        let model = device.productType ?? "unknown"
        let version = device.productVersion.map { "iOS \($0)" } ?? "iOS —"
        let short = String(device.udid.prefix(8))
        text.stringValue = "\(name)\n\(model)  ·  \(version)  ·  \(short)…"
        text.font = .systemFont(ofSize: 13, weight: .medium)
        text.maximumNumberOfLines = 2
        return cell
    }
}
