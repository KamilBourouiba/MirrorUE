import AppKit
import Foundation

/// A self-contained provider editor. Use `.overlay` over the mirror view or
/// `.embedded` inside another settings surface.
final class AIProviderSettingsPanel: NSView, NSTextFieldDelegate {
    enum PresentationStyle {
        case embedded
        case overlay
    }

    typealias ConnectionTest = (
        _ profile: AIProviderProfile,
        _ token: String?
    ) async -> AIProviderConnectionTestResult

    var onSave: ((AIProviderProfile) -> Void)?
    var onCancel: (() -> Void)?

    private let store: AIProviderStore
    private let presentationStyle: PresentationStyle
    private let connectionTest: ConnectionTest
    private var profile: AIProviderProfile
    private var lastPreset: AIProviderPreset
    private var tokenWasEdited = false
    private var hasStoredToken = false
    private var testTask: Task<Void, Never>?

    private let effect = NSVisualEffectView()
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField()
    private let baseURLField = NSTextField()
    private let modelCombo = NSComboBox()
    private let reasoningPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let reasoningHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let tokenField = NSSecureTextField()
    private let removeTokenButton = NSButton()
    private let screenshotsCheck = NSButton(
        checkboxWithTitle: "Allow sending phone screenshots to this provider",
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let testButton = NSButton()
    private let saveButton = NSButton()

    init(
        frame frameRect: NSRect,
        profile: AIProviderProfile? = nil,
        store: AIProviderStore = .shared,
        presentationStyle: PresentationStyle = .overlay,
        connectionTest: ConnectionTest? = nil
    ) {
        let initialProfile = profile ?? store.selectedProfile ?? AIProviderProfile.lmStudio()
        self.store = store
        self.profile = initialProfile
        self.lastPreset = initialProfile.preset
        self.presentationStyle = presentationStyle
        self.connectionTest = connectionTest ?? { profile, token in
            await AIProviderConnectionTester.test(profile: profile, token: token)
        }
        super.init(frame: frameRect)

        buildView()
        populateFields()
        loadCredentialState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        testTask?.cancel()
    }

    private func buildView() {
        wantsLayer = true
        if presentationStyle == .overlay {
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        }

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = presentationStyle == .overlay ? 18 : 10
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let title = NSTextField(labelWithString: "AI Provider")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(
            wrappingLabelWithString: "Connect a local model or another compatible API. Tokens are stored in macOS Keychain."
        )
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        for preset in AIProviderPreset.allCases {
            presetPopup.addItem(withTitle: preset.title)
            presetPopup.lastItem?.representedObject = preset.rawValue
        }
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)

        nameField.placeholderString = "My provider"
        baseURLField.placeholderString = "https://provider.example/v1"
        baseURLField.toolTip = "API base URL. Do not paste a /chat/completions endpoint."
        baseURLField.delegate = self

        modelCombo.isEditable = true
        modelCombo.completes = true
        modelCombo.numberOfVisibleItems = 10
        modelCombo.placeholderString = "Select or enter a chat/tool-capable model"

        for effort in AIReasoningEffort.allCases {
            reasoningPopup.addItem(withTitle: effort.title)
            reasoningPopup.lastItem?.representedObject = effort.rawValue
        }
        reasoningPopup.controlSize = .small
        reasoningPopup.target = self
        reasoningPopup.action = #selector(reasoningChanged)
        reasoningHelpLabel.font = .systemFont(ofSize: 10.5)
        reasoningHelpLabel.textColor = .secondaryLabelColor
        reasoningHelpLabel.maximumNumberOfLines = 3

        tokenField.placeholderString = "Optional API token"
        tokenField.delegate = self
        tokenField.toolTip = "Stored in macOS Keychain, never in provider settings."
        tokenField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        removeTokenButton.title = "Remove"
        removeTokenButton.bezelStyle = .rounded
        removeTokenButton.controlSize = .small
        removeTokenButton.target = self
        removeTokenButton.action = #selector(removeTokenClicked)
        removeTokenButton.toolTip = "Remove the saved token when this profile is saved."
        let tokenRow = NSStackView(views: [tokenField, removeTokenButton])
        tokenRow.orientation = .horizontal
        tokenRow.alignment = .centerY
        tokenRow.spacing = 8

        screenshotsCheck.toolTip = "When off, this provider must never receive captured iPhone frames."

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 11
        form.translatesAutoresizingMaskIntoConstraints = false

        let reasoningRow = labeled("Chat reasoning", control: reasoningPopup)
        let reasoningSection = NSStackView(views: [reasoningRow, reasoningHelpLabel])
        reasoningSection.orientation = .vertical
        reasoningSection.alignment = .leading
        reasoningSection.spacing = 3
        reasoningSection.translatesAutoresizingMaskIntoConstraints = false
        reasoningRow.widthAnchor.constraint(equalTo: reasoningSection.widthAnchor).isActive = true
        reasoningHelpLabel.widthAnchor.constraint(equalTo: reasoningSection.widthAnchor).isActive = true

        [
            labeled("Provider type", control: presetPopup),
            labeled("Display name", control: nameField),
            labeled("API base URL", control: baseURLField),
            labeled("Model", control: modelCombo),
            reasoningSection,
            labeled("API token", control: tokenRow),
        ].forEach { row in
            form.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        form.addArrangedSubview(screenshotsCheck)

        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false

        testButton.title = "Test Connection"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testConnectionClicked)
        testButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)

        let trailingButtons = NSStackView(views: [cancelButton, saveButton])
        trailingButtons.orientation = .horizontal
        trailingButtons.spacing = 8

        let buttonSpacer = NSView()
        let buttons = NSStackView(views: [testButton, progress, buttonSpacer, trailingButtons])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 9
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(title)
        document.addSubview(subtitle)
        document.addSubview(form)
        document.addSubview(statusLabel)
        document.addSubview(buttons)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = document
        effect.addSubview(scroll)

        var containerConstraints: [NSLayoutConstraint]
        switch presentationStyle {
        case .overlay:
            let preferredWidth = effect.widthAnchor.constraint(equalToConstant: 520)
            preferredWidth.priority = .defaultHigh
            let preferredHeight = effect.heightAnchor.constraint(equalToConstant: 480)
            preferredHeight.priority = .defaultHigh
            containerConstraints = [
                effect.centerXAnchor.constraint(equalTo: centerXAnchor),
                effect.centerYAnchor.constraint(equalTo: centerYAnchor),
                preferredWidth,
                preferredHeight,
                effect.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
                effect.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -24),
                effect.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
                effect.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                effect.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
                effect.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            ]
        case .embedded:
            containerConstraints = [
                effect.leadingAnchor.constraint(equalTo: leadingAnchor),
                effect.trailingAnchor.constraint(equalTo: trailingAnchor),
                effect.topAnchor.constraint(equalTo: topAnchor),
                effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        }

        NSLayoutConstraint.activate(containerConstraints + [
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),

            title.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 32),
            subtitle.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -32),

            form.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 30),
            form.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -30),

            statusLabel.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 11),
            statusLabel.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 17),

            buttons.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 13),
            buttons.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
        ])

        if presentationStyle == .overlay {
            let click = NSClickGestureRecognizer(target: self, action: #selector(backdropClicked(_:)))
            addGestureRecognizer(click)
        }
    }

    private func labeled(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .secondaryLabelColor

        control.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func populateFields() {
        if let index = presetPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == profile.preset.rawValue
        }) {
            presetPopup.selectItem(at: index)
        }
        nameField.stringValue = profile.name
        baseURLField.stringValue = profile.baseURL
        modelCombo.stringValue = profile.model
        selectReasoningEffort(profile.reasoningEffort)
        updateReasoningHelp()
        screenshotsCheck.state = profile.allowsScreenshots ? .on : .off
    }

    private func selectedReasoningEffort() -> AIReasoningEffort? {
        guard let raw = reasoningPopup.selectedItem?.representedObject as? String else {
            return nil
        }
        return AIReasoningEffort(rawValue: raw)
    }

    private func selectReasoningEffort(_ effort: AIReasoningEffort) {
        guard let index = reasoningPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == effort.rawValue
        }) else { return }
        reasoningPopup.selectItem(at: index)
    }

    private func updateReasoningHelp() {
        let effort = selectedReasoningEffort() ?? .providerDefault
        let selectedPreset = presetPopup.selectedItem?.representedObject as? String
        let agentNote = selectedPreset == AIProviderPreset.lmStudio.rawValue
            ? " Phone Agent always uses None for reliable, low-latency tool calls."
            : ""
        let help = effort.helpText + agentNote
        reasoningHelpLabel.stringValue = help
        reasoningPopup.toolTip = help
    }

    private func loadCredentialState() {
        do {
            hasStoredToken = try store.token(for: profile.id)?.isEmpty == false
            updateTokenPlaceholder()
        } catch {
            hasStoredToken = false
            showStatus("Could not read the saved token: \(error.localizedDescription)", success: false)
        }
    }

    private func updateTokenPlaceholder() {
        let originChanged = Self.origin(of: profile.baseURL)
            != Self.origin(of: baseURLField.stringValue)
        if hasStoredToken && !tokenWasEdited && originChanged {
            tokenField.placeholderString = "Saved token blocked for new host — enter its token"
        } else {
            tokenField.placeholderString = hasStoredToken && !tokenWasEdited
                ? "Saved in Keychain — type to replace"
                : "Optional API token"
        }
        removeTokenButton.isHidden = !hasStoredToken
    }

    private func draftProfile() throws -> AIProviderProfile {
        guard let rawPreset = presetPopup.selectedItem?.representedObject as? String,
              let preset = AIProviderPreset(rawValue: rawPreset) else {
            throw AIProviderProfileError.missingAdapter
        }

        var draft = profile
        draft.name = nameField.stringValue
        draft.preset = preset
        draft.adapterIdentifier = preset.adapterIdentifier
        draft.baseURL = baseURLField.stringValue
        draft.model = modelCombo.stringValue
        draft.reasoningEffort = selectedReasoningEffort()
            ?? preset.defaultReasoningEffort
        draft.allowsScreenshots = screenshotsCheck.state == .on
        draft = draft.sanitized()
        try draft.validate()
        return draft
    }

    private func tokenForConnectionTest(_ draft: AIProviderProfile) throws -> String? {
        if tokenWasEdited {
            let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }
        // A Keychain item belongs to the origin at which the user entered it.
        // Never silently forward it after host/scheme/port edits.
        guard Self.origin(of: draft.baseURL) == Self.origin(of: profile.baseURL) else {
            return nil
        }
        return try store.token(for: profile.id)
    }

    @objc private func presetChanged() {
        guard let raw = presetPopup.selectedItem?.representedObject as? String,
              let selected = AIProviderPreset(rawValue: raw),
              selected != lastPreset else { return }

        let base = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == lastPreset.defaultBaseURL {
            baseURLField.stringValue = selected.defaultBaseURL
        }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == lastPreset.defaultName {
            nameField.stringValue = selected.defaultName
        }
        if selectedReasoningEffort() == lastPreset.defaultReasoningEffort {
            selectReasoningEffort(selected.defaultReasoningEffort)
        }
        updateReasoningHelp()
        modelCombo.removeAllItems()
        modelCombo.stringValue = ""
        // A provider change is a new disclosure decision. Do not carry a
        // screenshot opt-in to a potentially remote custom endpoint.
        screenshotsCheck.state = .off
        lastPreset = selected
        updateTokenPlaceholder()
        if hasStoredToken,
           !tokenWasEdited,
           Self.origin(of: profile.baseURL) != Self.origin(of: baseURLField.stringValue) {
            showStatus(
                "The saved token is blocked for this new host. Enter its token if required.",
                success: nil
            )
        } else {
            showStatus("", success: nil)
        }
    }

    @objc private func reasoningChanged() {
        updateReasoningHelp()
    }

    @objc private func testConnectionClicked() {
        testTask?.cancel()

        let draft: AIProviderProfile
        let token: String?
        do {
            draft = try draftProfile()
            token = try tokenForConnectionTest(draft)
        } catch {
            showStatus(error.localizedDescription, success: false)
            return
        }

        setTesting(true)
        showStatus("Connecting…", success: nil)
        let connectionTest = self.connectionTest
        testTask = Task { [weak self] in
            let result = await connectionTest(draft, token)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.finishConnectionTest(result)
            }
        }
    }

    private func finishConnectionTest(_ result: AIProviderConnectionTestResult) {
        setTesting(false)
        showStatus(result.message, success: result.succeeded)
        guard result.succeeded, !result.models.isEmpty else { return }

        let existing = modelCombo.stringValue
        modelCombo.removeAllItems()
        modelCombo.addItems(withObjectValues: result.models)
        modelCombo.stringValue = existing
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showStatus(
                "\(result.message). Choose a chat/tool-capable model before saving.",
                success: nil
            )
        }
    }

    private func setTesting(_ testing: Bool) {
        testButton.isEnabled = !testing
        saveButton.isEnabled = !testing
        presetPopup.isEnabled = !testing
        nameField.isEnabled = !testing
        baseURLField.isEnabled = !testing
        modelCombo.isEnabled = !testing
        reasoningPopup.isEnabled = !testing
        tokenField.isEnabled = !testing
        removeTokenButton.isEnabled = !testing
        screenshotsCheck.isEnabled = !testing
        if testing {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }

    private func showStatus(_ message: String, success: Bool?) {
        statusLabel.stringValue = message
        switch success {
        case true:
            statusLabel.textColor = .systemGreen
        case false:
            statusLabel.textColor = .systemRed
        case nil:
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func saveClicked() {
        do {
            let draft = try draftProfile()
            guard !draft.model.isEmpty else {
                throw AIProviderRuntimeError.noModel(
                    "Choose a chat/tool-capable model before saving."
                )
            }
            if draft.allowsScreenshots,
               !Self.isLoopbackURL(draft.baseURL),
               (!profile.allowsScreenshots || profile.baseURL != draft.baseURL) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Send iPhone screenshots to a remote provider?"
                alert.informativeText = "Screen contents may include private notifications, messages, or account information. Only continue if you trust \(draft.name)."
                alert.addButton(withTitle: "Allow & Save")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            let tokenUpdate: AIProviderTokenUpdate
            if tokenWasEdited {
                let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                tokenUpdate = token.isEmpty ? .remove : .replace(token)
            } else if hasStoredToken,
                      Self.origin(of: draft.baseURL) != Self.origin(of: profile.baseURL) {
                // Editing a profile to another origin must not rebind its old
                // secret. Remove it unless the user explicitly entered a new one.
                tokenUpdate = .remove
            } else {
                tokenUpdate = .unchanged
            }

            profile = try store.upsert(draft, tokenUpdate: tokenUpdate, select: true)
            tokenField.stringValue = ""
            tokenWasEdited = false
            hasStoredToken = try store.token(for: profile.id)?.isEmpty == false
            updateTokenPlaceholder()
            showStatus("Provider saved.", success: true)
            onSave?(profile)
        } catch {
            showStatus(error.localizedDescription, success: false)
        }
    }

    @objc private func removeTokenClicked() {
        tokenField.stringValue = ""
        tokenWasEdited = true
        hasStoredToken = false
        updateTokenPlaceholder()
        showStatus("The saved token will be removed when you save.", success: nil)
    }

    @objc private func cancelClicked() {
        testTask?.cancel()
        setTesting(false)
        onCancel?()
    }

    @objc private func backdropClicked(_ recognizer: NSClickGestureRecognizer) {
        if !effect.frame.contains(recognizer.location(in: self)) {
            cancelClicked()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSecureTextField === tokenField {
            tokenWasEdited = true
            updateTokenPlaceholder()
        } else if notification.object as? NSTextField === baseURLField {
            updateTokenPlaceholder()
            if hasStoredToken,
               !tokenWasEdited,
               Self.origin(of: profile.baseURL)
                    != Self.origin(of: baseURLField.stringValue) {
                showStatus(
                    "The saved token will not be sent to this new host. Enter its token if required.",
                    success: nil
                )
            }
        }
    }

    private static func isLoopbackURL(_ rawURL: String) -> Bool {
        guard let host = URLComponents(string: rawURL)?.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func origin(of rawURL: String) -> String? {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }
        let port = components.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(port)"
    }
}
