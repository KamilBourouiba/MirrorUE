import Cocoa
import Metal
import MetalKit
import Darwin
import UniformTypeIdentifiers
import DeviceKit
import MediaKit
import ControlKit

@main
enum MirrorUEMain {
    static func main() {
        let args = AppArgs.parse(CommandLine.arguments)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(args: args)
        app.delegate = delegate
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

struct AppArgs {
    var udid: String?
    var width: CGFloat = 340
    var height: CGFloat = 720
    var httpPort: Int = 8080

    static func parse(_ argv: [String]) -> AppArgs {
        var a = AppArgs()
        var i = 1
        while i < argv.count {
            let k = argv[i]
            let v = i + 1 < argv.count ? argv[i + 1] : nil
            switch k {
            case "--udid":
                if let v { a.udid = v }; i += 2
            case "--width":
                if let v, let n = Double(v) { a.width = CGFloat(n) }; i += 2
            case "--height":
                if let v, let n = Double(v) { a.height = CGFloat(n) }; i += 2
            case "--http-port":
                if let v, let n = Int(v) { a.httpPort = n }; i += 2
            case "-h", "--help":
                fputs("""
                MirrorUE — Swift/Metal iPhone mirror

                  MirrorUE [--udid UDID] [--width 340] [--height 720]

                Video uses the system CoreMediaIO screen device (same source as
                QuickTime / iPhone presentation). Control uses a CoreDevice
                tunnel — Network when available so USB stays free for capture.

                Without --udid, a device picker lists USB iPhones at launch.
                Requires bin/MirrorUEEngine (./tools/build_engine.sh).

                """, stderr)
                exit(0)
            default:
                i += 1
            }
        }
        return a
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let args: AppArgs
    var window: NSWindow!
    var metalView: FrameView!
    var status: StatusChip!
    var deviceBadge: InfoBadge!
    var linkBadge: InfoBadge!
    var dock: ControlCenterDock!
    var picker: DevicePickerView?
    var connecting: ConnectingOverlay?
    var setupChecklist: SetupChecklistView?
    var permissionsGate: PermissionsGateView?
    var settingsPanel: SettingsPanel?
    var performancePanel: PerformancePanel?
    var workflowStrip: WorkflowLiveStrip!
    var privacyPanel: PrivacyPanel?
    var pathBar: PathBar!
    var lastRecorded: Workflow?
    var connectionState: ConnectionState = .idle
    var lastBootDevice: DeviceInfo?
    var recoveryAttempt = 0
    var engineRecoveryAttempt = 0
    private var sleepObservers: [NSObjectProtocol] = []
    var control = ControlClient()
    var muvsReader: VideoSocketReader?
    var capture: DeviceScreenCapture?
    private let captureClock = NSLock()
    private var lastCaptureNs: UInt64 = 0
    var session: TunnelSession?
    var codecLabel = "muvs3"
    var musicSafe = false
    private var lastStatusTick = CACurrentMediaTime()
    private var didRevealMirror = false
    /// Top inset above the phone stage (titlebar / traffic lights).
    private let chromeTop: CGFloat = 28
    /// Gap + agent bar + dock + bottom margin under the stage.
    private let chromeBottom: CGFloat = 108
    private let sidePad: CGFloat = 8
    private let bezelPad: CGFloat = 2.5
    private var chromeY: CGFloat { chromeTop + chromeBottom }
    /// Video width ÷ height — updates when the phone rotates.
    private var mirrorAspect: CGFloat = 0
    private var isLandscape = false
    private var lastVideoSize: (Int, Int) = (0, 0)
    private var cachedDeviceName = "MirrorUE"
    private var bezel: NSView!
    private var stage: MirrorStageView!
    private var rim: NSView!
    private var resizing = false
    /// True while the user is dragging a window resize grip.
    private var liveUserResize = false
    private var pendingOrientationResize = false
    /// Native fullscreen session (aspect lock must not fight the space size).
    private var fullScreenSession = false
    private var stripWidthConstraint: NSLayoutConstraint!
    private var stageTrailingToStrip: NSLayoutConstraint!
    private var stageTrailingToRoot: NSLayoutConstraint!
    private static let stripWidth: CGFloat = 196

    private var inFullScreen: Bool {
        fullScreenSession || window?.styleMask.contains(.fullScreen) == true
    }

    init(args: AppArgs) {
        self.args = args
        self.mirrorAspect = args.width / max(args.height, 1)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MirrorUESettings.applyToEnvironment()
        installMainMenu()
        _ = DeviceScreenCapture.isAvailable

        let contentW = args.width + sidePad * 2
        let contentH = args.height + chromeY
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = "MirrorUE"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior.insert([.fullScreenPrimary, .managed])
        // Keep aspect via windowWillResize — never let Auto Layout resize the window.
        window.minSize = window.frameRect(forContentRect: NSRect(
            x: 0, y: 0, width: 200, height: 360
        )).size
        window.center()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fputs("Metal unavailable\n", stderr)
            exit(1)
        }

        let root = NSView(frame: window.contentView!.bounds)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        root.autoresizingMask = [.width, .height]
        // Content must not push the window frame through constraints.
        root.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        window.contentView = root

        control.baseURL = URL(string: "http://127.0.0.1:\(args.httpPort)")!

        stage = MirrorStageView(frame: .zero)
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.aspect = mirrorAspect
        stage.bezelPad = bezelPad
        root.addSubview(stage)

        // Thin continuous phone bezel — positioned by MirrorStageView.layout().
        bezel = NSView(frame: .zero)
        bezel.wantsLayer = true
        bezel.layer?.cornerRadius = 26
        bezel.layer?.cornerCurve = .continuous
        bezel.layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1).cgColor
        bezel.layer?.borderWidth = 1.25
        bezel.layer?.borderColor = NSColor.white.withAlphaComponent(0.32).cgColor
        bezel.layer?.masksToBounds = false
        bezel.shadow = NSShadow()
        bezel.layer?.shadowColor = NSColor.black.cgColor
        bezel.layer?.shadowOpacity = 0.40
        bezel.layer?.shadowRadius = 18
        bezel.layer?.shadowOffset = CGSize(width: 0, height: -4)
        stage.bezel = bezel
        stage.addSubview(bezel)

        rim = NSView(frame: .zero)
        rim.wantsLayer = true
        rim.layer?.cornerRadius = 24
        rim.layer?.cornerCurve = .continuous
        rim.layer?.borderWidth = 0.5
        rim.layer?.borderColor = NSColor.black.withAlphaComponent(0.55).cgColor
        rim.layer?.backgroundColor = .clear
        bezel.addSubview(rim)

        metalView = FrameView(frame: .zero, device: device, control: control)
        metalView.wantsLayer = true
        metalView.layer?.cornerRadius = 23
        metalView.layer?.cornerCurve = .continuous
        metalView.layer?.masksToBounds = true
        bezel.addSubview(metalView)
        stage.metalView = metalView
        stage.rim = rim

        dock = ControlCenterDock(frame: .zero)
        dock.translatesAutoresizingMaskIntoConstraints = false
        dock.onAction = { [weak self] id in self?.handleDockAction(id) }
        root.addSubview(dock)

        pathBar = PathBar(frame: .zero)
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        wirePathBar()
        root.addSubview(pathBar)

        WorkflowTiming.latencyProvider = { [weak self] in
            let snap = self?.metalView.presentLatency.snapshot()
                ?? LatencyWindow.Snapshot(p50Ms: 0, p95Ms: 0, count: 0)
            return (snap.p50Ms, snap.p95Ms)
        }

        status = StatusChip(frame: .zero)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.stringValue = "waiting for device…"
        metalView.addSubview(status)

        workflowStrip = WorkflowLiveStrip(frame: .zero)
        workflowStrip.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(workflowStrip)

        deviceBadge = InfoBadge(frame: .zero)
        deviceBadge.translatesAutoresizingMaskIntoConstraints = false
        deviceBadge.set(symbol: "iphone", text: "MirrorUE", tip: "Application MirrorUE — miroir iPhone")
        metalView.addSubview(deviceBadge)

        linkBadge = InfoBadge(frame: .zero)
        linkBadge.translatesAutoresizingMaskIntoConstraints = false
        linkBadge.set(symbol: "cable.connector", text: "USB · pick a phone", tip: "Connexion USB — choisir un iPhone")
        metalView.addSubview(linkBadge)

        stripWidthConstraint = workflowStrip.widthAnchor.constraint(equalToConstant: 0)
        stageTrailingToStrip = stage.trailingAnchor.constraint(equalTo: workflowStrip.leadingAnchor, constant: -8)
        stageTrailingToRoot = stage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -sidePad)
        stageTrailingToRoot.isActive = true

        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: root.topAnchor, constant: chromeTop),
            stage.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: sidePad),
            stage.bottomAnchor.constraint(equalTo: pathBar.topAnchor, constant: -8),

            workflowStrip.topAnchor.constraint(equalTo: stage.topAnchor),
            workflowStrip.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            workflowStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -sidePad),
            stripWidthConstraint,

            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBar.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -6),
            pathBar.heightAnchor.constraint(equalToConstant: 40),

            dock.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            dock.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            dock.heightAnchor.constraint(equalToConstant: 56),
            dock.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -12),

            status.leadingAnchor.constraint(equalTo: metalView.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: metalView.trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: metalView.bottomAnchor, constant: -10),
            status.heightAnchor.constraint(equalToConstant: 22),

            deviceBadge.leadingAnchor.constraint(equalTo: metalView.leadingAnchor, constant: 10),
            deviceBadge.topAnchor.constraint(equalTo: metalView.topAnchor, constant: 10),
            deviceBadge.heightAnchor.constraint(equalToConstant: 24),
            deviceBadge.trailingAnchor.constraint(lessThanOrEqualTo: linkBadge.leadingAnchor, constant: -8),

            linkBadge.trailingAnchor.constraint(equalTo: metalView.trailingAnchor, constant: -10),
            linkBadge.topAnchor.constraint(equalTo: metalView.topAnchor, constant: 10),
            linkBadge.heightAnchor.constraint(equalToConstant: 24),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        resizeWindowToVideo(animated: false)
        installSessionHealthObservers()
        startLocalAPI()
        // Do NOT auto-request permissions or warm FastVLM here — that spammed prompts.
        // PermissionsGateView asks one-by-one; warmup starts after the gate.

        if let udid = args.udid {
            Task { await self.boot(udid: udid) }
        } else {
            beginOnboardingFlow()
        }
    }

    private func beginOnboardingFlow() {
        if MirrorUEPermissions.needsPermissionGate {
            showPermissionsGate()
        } else if !MirrorUESettings.setupChecklistSeen {
            showSetupChecklist()
        } else {
            afterPermissionsReady()
            showDevicePicker()
        }
    }

    private func afterPermissionsReady() {
        pathBar?.setStatus("")
    }

    private func showPermissionsGate() {
        permissionsGate?.removeFromSuperview()
        let view = PermissionsGateView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        view.onFinished = { [weak self] in
            guard let self else { return }
            self.permissionsGate?.removeFromSuperview()
            self.permissionsGate = nil
            self.afterPermissionsReady()
            if !MirrorUESettings.setupChecklistSeen {
                self.showSetupChecklist()
            } else {
                self.showDevicePicker()
            }
        }
        window.contentView?.addSubview(view)
        permissionsGate = view
        applyConnectionState(.pickingDevice)
        pathBar?.setStatus("Grant permissions to continue")
    }

    private func startLocalAPI() {
        let api = LocalAPIServer.shared
        api.controlProvider = { [weak self] in
            guard let self, self.didRevealMirror else { return nil }
            return self.control
        }
        api.touchModeProvider = { [weak self] in
            self?.metalView.touchMode ?? .portrait
        }
        api.statusProvider = { [weak self] in
            guard let self else { return [:] }
            return [
                "connected": self.didRevealMirror,
                "device": self.cachedDeviceName,
                "codec": self.codecLabel,
                "state": self.connectionState.title,
                "engineAlive": self.session?.isAlive ?? false,
                "displayFps": self.metalView?.fps ?? 0,
                "captureFps": self.capture?.inboundFps ?? 0,
                "apiPort": Int(LocalAPIServer.shared.port),
            ]
        }
        api.frameProvider = { [weak self] maxW, format in
            guard let self else { return nil }
            let ext = format.lowercased() == "png" ? "png" : "jpg"
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mirrorue-live-frame.\(ext)")
            let ok = CaptureStudio.shared.writeFrame(
                self.metalView?.lastPixelBuffer,
                to: url,
                maxWidth: maxW,
                format: format
            )
            return ok ? url.path : nil
        }
        let port = UInt16(ProcessInfo.processInfo.environment["MIRRORUE_API_PORT"].flatMap(Int.init) ?? 8090)
        api.start(port: port)
    }

    private func installSessionHealthObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        sleepObservers.append(ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            fputs("MirrorUE: Mac will sleep\n", stderr)
            self?.status.stringValue = "Mac sleeping…"
        })
        sleepObservers.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            fputs("MirrorUE: Mac woke — recovering capture\n", stderr)
            self.applyConnectionState(.recovering(message: "Mac woke — restoring…", attempt: 1))
            self.capture?.stop()
            self.capture?.start()
            if let session = self.session, !session.isAlive, let device = self.lastBootDevice {
                Task { await self.boot(device: device) }
            } else if self.didRevealMirror {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.applyConnectionState(.connected(codec: self?.codecLabel ?? "coremediaio"))
                }
            }
        })
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        appMenu.addItem(withTitle: "About MirrorUE", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "Privacy & Security…", action: #selector(showPrivacy), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Performance…", action: #selector(showPerformance), keyEquivalent: "p")
        appMenu.addItem(NSMenuItem.separator())
        let shot = NSMenuItem(title: "Screenshot", action: #selector(takeScreenshot), keyEquivalent: "s")
        shot.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(shot)
        let rec = NSMenuItem(title: "Start/Stop Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        rec.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(rec)
        let paste = NSMenuItem(title: "Paste Mac Clipboard", action: #selector(pasteMacClipboard), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(paste)
        let touches = NSMenuItem(title: "Toggle Show Touches", action: #selector(toggleShowTouches), keyEquivalent: "t")
        touches.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(touches)
        let steps = NSMenuItem(title: "Toggle Path Timeline", action: #selector(toggleWorkflowStrip), keyEquivalent: "p")
        steps.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(steps)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit MirrorUE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let windowMenu = NSMenu(title: "Window")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        windowMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        windowMenu.addItem(withTitle: "Performance…", action: #selector(showPerformance), keyEquivalent: "p")

        NSApp.mainMenu = main
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MirrorUE"
        alert.informativeText = "Control a development iPhone from your Mac.\nCoreMediaIO + CoreDevice · MIT License\nLocal API: http://127.0.0.1:\(LocalAPIServer.shared.port)/v1/status"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Privacy…")
        if alert.runModal() == .alertSecondButtonReturn {
            showPrivacy()
        }
    }

    @objc func showPrivacy() {
        guard privacyPanel == nil, let root = window.contentView else { return }
        let panel = PrivacyPanel(frame: root.bounds)
        panel.autoresizingMask = [.width, .height]
        panel.onClose = { [weak self] in
            self?.privacyPanel?.removeFromSuperview()
            self?.privacyPanel = nil
        }
        root.addSubview(panel)
        privacyPanel = panel
    }

    @objc func showSettings() {
        guard settingsPanel == nil, let root = window.contentView else { return }
        let panel = SettingsPanel(frame: root.bounds)
        panel.autoresizingMask = [.width, .height]
        panel.onClose = { [weak self] in
            self?.settingsPanel?.removeFromSuperview()
            self?.settingsPanel = nil
        }
        panel.onApply = { [weak self] in
            self?.status.stringValue = "settings saved · \(MirrorUESettings.captureFPS) fps · \(MirrorUESettings.keyboardMode.rawValue)"
            // Restart capture rate on next session; FPS is read when attach runs.
            if let capture = self?.capture, capture.isRunning {
                capture.stop()
                capture.start()
            }
        }
        root.addSubview(panel)
        settingsPanel = panel
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        liveUserResize = true
        metalView?.cancelActiveTouch()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        liveUserResize = false
        guard dock != nil else { return }
        dock.setCompact(window.frame.width < ControlCenterDock.preferredWidth)
        applyMinSize()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreenSession = true
        metalView?.cancelActiveTouch()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenSession = true
        if let window, let cv = window.contentView {
            cv.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
            cv.needsLayout = true
        }
        relayoutWorkflowStrip()
        dock?.setCompact(window.frame.width < ControlCenterDock.preferredWidth)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        metalView?.cancelActiveTouch()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenSession = false
        relayoutWorkflowStrip()
        DispatchQueue.main.async { [weak self] in
            self?.resizeWindowToVideo(animated: true)
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !resizing else { return frameSize }
        // Fullscreen must receive the real space size — aspect-locking here left
        // a tiny phone window stranded in the top-left of a black fullscreen.
        if inFullScreen || fullScreenSession { return frameSize }

        let padX = sidePad * 2
        let strip = stripChromeWidth
        let aspect = max(mirrorAspect, 0.01)
        let current = sender.contentRect(forFrameRect: sender.frame).size
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let dW = abs(proposed.width - current.width)
        let dH = abs(proposed.height - current.height)

        let phoneW: CGFloat
        let phoneH: CGFloat
        if dW >= dH {
            phoneW = max(160, proposed.width - padX - strip)
            phoneH = phoneW / aspect
        } else {
            phoneH = max(160, proposed.height - chromeY)
            phoneW = phoneH * aspect
        }
        let sized = NSSize(width: phoneW + padX + strip, height: phoneH + chromeY)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: sized)).size
    }

    func windowDidResize(_ notification: Notification) {
        guard dock != nil, !resizing, !liveUserResize else { return }
        dock.setCompact(window.frame.width < ControlCenterDock.preferredWidth)
        if inFullScreen {
            relayoutWorkflowStrip()
        }
    }

    private func applyMinSize() {
        guard window != nil else { return }
        let minPhone: CGFloat = 180
        let minContent = NSSize(
            width: minPhone + sidePad * 2 + stripChromeWidth,
            height: minPhone / max(mirrorAspect, 0.01) + chromeY
        )
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minContent)).size
    }

    private var stripChromeWidth: CGFloat {
        (workflowStrip?.isHidden == false) ? Self.stripWidth + 8 : 0
    }

    /// Hug the phone bezel: window chrome matches stage + dock, no letterboxing.
    private func fittedContent(for proposed: NSSize) -> NSSize {
        let padX = sidePad * 2
        let strip = stripChromeWidth
        let availW = max(160, proposed.width - padX - strip)
        let availH = max(160, proposed.height - chromeY)
        let aspect = max(mirrorAspect, 0.01)

        let phoneW: CGFloat
        let phoneH: CGFloat
        if availW / availH > aspect {
            phoneH = availH
            phoneW = phoneH * aspect
        } else {
            phoneW = availW
            phoneH = phoneW / aspect
        }
        return NSSize(width: phoneW + padX + strip, height: phoneH + chromeY)
    }

    private func resizeWindowToVideo(animated: Bool) {
        guard window != nil else { return }
        // Never fight the user mid-resize, mid-drag, or while fullscreen.
        if liveUserResize || inFullScreen || metalView?.hasActiveTouch == true { return }

        resizing = true
        defer { resizing = false }

        let ideal: NSSize
        if isLandscape {
            let w = max(args.height, 640)
            ideal = NSSize(
                width: w + sidePad * 2,
                height: w / max(mirrorAspect, 0.01) + chromeY
            )
        } else {
            ideal = NSSize(
                width: args.width + sidePad * 2,
                height: args.height + chromeY
            )
        }
        let target = fittedContent(for: ideal)
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(
            origin: .zero, size: target
        ))
        if stripChromeWidth > 0 {
            frame.origin.x = old.maxX - frame.width
        } else {
            frame.origin.x = old.origin.x
        }
        frame.origin.y = old.origin.y + old.height - frame.height
        applyMinSize()

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
        dock?.setCompact(target.width < ControlCenterDock.preferredWidth)
    }

    private func noteVideoSize(width: Int, height: Int) {
        guard width > 1, height > 1 else { return }
        if lastVideoSize == (width, height) { return }

        let aspect = CGFloat(width) / CGFloat(height)
        let landscape = width > height
        let touchMode = TouchMap.mode(frameWidth: width, frameHeight: height)
        // Capture often jitters height (2624 vs 2656) — ignore unless orientation flips.
        let aspectDelta = abs(aspect - (mirrorAspect == 0 ? aspect : mirrorAspect))
        let orientFlip = landscape != isLandscape
        let sizeOnly = lastVideoSize != (0, 0) && !orientFlip && aspectDelta < 0.04
        lastVideoSize = (width, height)
        let aspectChanged = !sizeOnly && (orientFlip || aspectDelta > 0.03)
        if aspectChanged {
            mirrorAspect = aspect
            isLandscape = landscape
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.stage != nil else { return }
            self.metalView.videoSize = CGSize(width: width, height: height)
            self.metalView.touchMode = touchMode
            guard aspectChanged else { return }
            self.stage.aspect = self.mirrorAspect
            self.stage.needsLayout = true
            self.deviceBadge.set(
                symbol: landscape ? "iphone.landscape" : "iphone",
                text: "\(self.cachedDeviceName) · \(TouchMap.badge(for: touchMode))",
                tip: "Appareil connecté · orientation \(TouchMap.badge(for: touchMode))"
            )
            // Defer frame change so we never setFrame inside a layout pass.
            guard !self.pendingOrientationResize else { return }
            self.pendingOrientationResize = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingOrientationResize = false
                self.resizeWindowToVideo(animated: true)
                self.window.makeFirstResponder(self.metalView)
            }
        }
    }

    private func applyConnectionState(_ state: ConnectionState) {
        connectionState = state
        status.stringValue = state.title
        let badge = state.linkBadge
        linkBadge.set(symbol: badge.symbol, text: badge.text, tip: "État de la connexion — \(badge.text)")
        connecting?.setStep(state.title)
        connecting?.setSteps(state.steps)
        if case .failed(let message, let detail) = state {
            connecting?.showFailed(title: message, detail: detail, steps: state.steps)
        }
    }

    private func showSetupChecklist() {
        let view = SetupChecklistView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        view.onContinue = { [weak self] in
            self?.setupChecklist?.removeFromSuperview()
            self?.setupChecklist = nil
            self?.showDevicePicker()
        }
        window.contentView?.addSubview(view)
        setupChecklist = view
        applyConnectionState(.pickingDevice)
    }

    private func showDevicePicker() {
        // Hard gate: never show the picker until permissions onboarding finished.
        guard !MirrorUEPermissions.needsPermissionGate else {
            showPermissionsGate()
            return
        }
        picker?.removeFromSuperview()
        let view = DevicePickerView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        view.onSelect = { [weak self] device in
            guard let self else { return }
            self.picker?.removeFromSuperview()
            self.picker = nil
            self.window.makeFirstResponder(self.metalView)
            Task { await self.boot(device: device) }
        }
        window.contentView?.addSubview(view)
        picker = view
        applyConnectionState(.pickingDevice)
        deviceBadge.set(symbol: "iphone", text: "MirrorUE")
    }

    private func showConnecting(device: DeviceInfo) {
        connecting?.removeFromSuperview()
        let overlay = ConnectingOverlay(frame: window.contentView!.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.show(device: device, step: ConnectionState.openingTunnel(link: "linking…").title)
        overlay.setSteps(ConnectionState.openingTunnel(link: "linking…").steps)
        overlay.onRetry = { [weak self] in
            guard let self, let device = self.lastBootDevice else { return }
            self.recoveryAttempt = 0
            Task { await self.boot(device: device) }
        }
        overlay.onBack = { [weak self] in
            self?.connecting?.removeFromSuperview()
            self?.connecting = nil
            self?.session?.stop()
            self?.session = nil
            self?.showDevicePicker()
        }
        window.contentView?.addSubview(overlay)
        connecting = overlay
        deviceBadge.set(symbol: "iphone", text: device.name ?? "iPhone", tip: "Connexion en cours…")
        cachedDeviceName = device.name ?? "iPhone"
        applyConnectionState(.openingTunnel(link: "linking…"))
    }

    private func updateConnecting(step: String, steps: [String], link: String, symbol: String = "cable.connector") {
        // Kept for call sites that still pass explicit steps; prefer applyConnectionState.
        connecting?.setStep(step)
        connecting?.setSteps(steps)
        linkBadge.set(symbol: symbol, text: link, tip: "Liaison USB ou Wi‑Fi avec l'iPhone")
        status.stringValue = step
    }

    private func hideConnecting() {
        connecting?.hideAnimated()
        connecting = nil
        didRevealMirror = true
        applyConnectionState(.connected(codec: codecLabel))
        maybeShowFirstHints()
    }

    private func maybeShowFirstHints() {
        guard !MirrorUESettings.didShowFirstHints, let root = window.contentView else { return }
        MirrorUESettings.didShowFirstHints = true
        let hints = FirstUseHintsOverlay(frame: root.bounds)
        hints.present(in: root)
    }

    private func boot(udid: String) async {
        do {
            let info = try Usbmux.pick(udid: udid)
            await boot(device: info)
        } catch {
            presentBootFailure(error)
            fputs("boot failed: \(error)\n", stderr)
        }
    }

    private func presentBootFailure(_ error: Error) {
        let message = "Couldn’t connect"
        let detail = friendlyError(error)
        DispatchQueue.main.async {
            if self.connecting == nil, let device = self.lastBootDevice {
                self.showConnecting(device: device)
            }
            if self.connecting != nil {
                self.applyConnectionState(.failed(message: message, detail: detail))
            } else {
                self.status.stringValue = "error: \(detail)"
                self.showDevicePicker()
            }
        }
    }

    private func friendlyError(_ error: Error) -> String {
        let raw = String(describing: error)
        if raw.contains("missingEngine") || raw.lowercased().contains("engine") {
            return "The control engine is missing. Reinstall the app, or run ./tools/build_engine.sh when developing."
        }
        if raw.lowercased().contains("timeout") {
            return "The phone didn’t answer in time. Unlock it, keep USB plugged in, and enable Developer Mode."
        }
        if raw.lowercased().contains("exited") {
            return "The control engine stopped. Unlock the iPhone, quit other mirrors (QuickTime), and try again."
        }
        return raw
    }

    private func boot(device info: DeviceInfo) async {
        didRevealMirror = false
        lastBootDevice = info
        session?.stop()
        session = nil
        DispatchQueue.main.async {
            self.showConnecting(device: info)
            self.window.title = info.name ?? "MirrorUE"
        }
        do {
            let peer = (try? Usbmux.controlPeer(for: info.udid)) ?? info
            let link = peer.connectionType == "USB" ? "USB tunnel" : "Wi‑Fi tunnel"
            DispatchQueue.main.async {
                self.applyConnectionState(.openingTunnel(link: link))
            }
            let session = TunnelSession(device: peer, httpPort: args.httpPort)
            try session.start()
            session.onProcessExit = { [weak self] code in
                guard let self, self.didRevealMirror else { return }
                fputs("MirrorUE: engine exited (\(code)) — recovering\n", stderr)
                self.handleEngineDeath(code: code)
            }
            self.session = session
            self.control.baseURL = session.controlBaseURL
            try await session.waitUntilReady()
            let hidLink = peer.connectionType == "USB" ? "USB · HID" : "Wi‑Fi · HID"
            DispatchQueue.main.async {
                self.applyConnectionState(.attachingHID(link: hidLink))
            }
            if let rsd = session.rsdSession {
                control.hidSocketPath = rsd.hidSocketPath
                startVideo(rsd)
            } else {
                startVideo(nil)
            }
            DispatchQueue.main.async {
                self.applyConnectionState(.startingCapture)
                self.window.makeFirstResponder(self.metalView)
            }
            recoveryAttempt = 0
        } catch {
            // One automatic retry for flaky tunnel bring-up.
            if recoveryAttempt < 2 {
                recoveryAttempt += 1
                DispatchQueue.main.async {
                    self.applyConnectionState(.recovering(message: "Reopening connection…", attempt: self.recoveryAttempt))
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await boot(device: info)
                return
            }
            presentBootFailure(error)
            fputs("boot failed: \(error)\n", stderr)
        }
    }

    private func startVideo(_ rsd: RsdSession?) {
        muvsReader?.stop()
        muvsReader = nil
        capture?.stop()
        capture = nil

        // Primary picture: system screen capture (QuickTime / AirPlay-style DAL).
        let source = DeviceScreenCapture()
        source.onFrame = { [weak self] pixels in self?.handleCapturedFrame(pixels) }
        source.onActive = { [weak self] name in
            DispatchQueue.main.async {
                guard let self else { return }
                self.codecLabel = "coremediaio"
                self.applyConnectionState(.connected(codec: "screen · \(name)"))
                fputs("MediaKit: presenting via \(name)\n", stderr)
            }
        }
        source.onStalled = { [weak self] in
            DispatchQueue.main.async {
                self?.applyConnectionState(.recovering(message: "Video interrupted — reopening…", attempt: 1))
                self?.status.stringValue = "recovering capture…"
            }
        }
        source.onRecovered = { [weak self] name in
            DispatchQueue.main.async {
                guard let self else { return }
                self.codecLabel = "coremediaio"
                self.applyConnectionState(.connected(codec: "screen · \(name)"))
            }
        }
        source.start()
        capture = source

        // Engine stream as fallback until the screen device appears (locked phone).
        let path = rsd?.videoSocketPath ?? "/tmp/mirrorue_video.sock"
        let reader = VideoSocketReader(path: path)
        reader.onBind = { [weak self] ring in
            self?.noteVideoSize(width: ring.width, height: ring.height)
            self?.metalView.bind(ring)
        }
        reader.onFrame = { [weak self] frame in self?.handleSlotFrame(frame) }
        metalView.onDisplayed = { [weak reader] seq, producedNs in
            reader?.acknowledge(seq: seq, displayedNs: producedNs)
        }
        reader.start()
        muvsReader = reader
        if codecLabel == "muvs3" { codecLabel = reader.codecName }
    }

    private func handleSlotFrame(_ frame: SlotFrame) {
        // Capture wins while fresh; still ACK engine frames so credits don't stall.
        if captureIsFresh {
            muvsReader?.acknowledge(seq: frame.seq, displayedNs: frame.producedNs)
            return
        }
        metalView.present(slot: frame.slot, seq: frame.seq, producedNs: frame.producedNs)
        revealMirrorIfNeeded()
        updateStatus(
            latency: muvsReader?.endToEndLatency,
            detail: metalView.zeroCopySlots ? "zero-copy" : "upload"
        )
    }

    private func handleCapturedFrame(_ pixels: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pixels)
        let h = CVPixelBufferGetHeight(pixels)
        noteVideoSize(width: w, height: h)
        captureClock.lock()
        lastCaptureNs = monotonicNow()
        captureClock.unlock()
        metalView.present(pixels)
        revealMirrorIfNeeded()
        let inbound = capture?.inboundFps ?? 0
        updateStatus(
            latency: capture?.deliveryLag,
            detail: String(format: "in %.0f", inbound)
        )
    }

    private func revealMirrorIfNeeded() {
        guard !didRevealMirror else { return }
        DispatchQueue.main.async { [weak self] in
            self?.hideConnecting()
        }
    }

    private var captureIsFresh: Bool {
        captureClock.lock()
        let last = lastCaptureNs
        captureClock.unlock()
        return last != 0 && monotonicNow() &- last < 2_000_000_000
    }

    private func updateStatus(latency: LatencyWindow?, detail: String) {
        let now = CACurrentMediaTime()
        guard now - lastStatusTick >= 0.25 else { return }
        lastStatusTick = now
        let fps = metalView.fps
        let lat = latency?.snapshot() ?? LatencyWindow.Snapshot(p50Ms: 0, p95Ms: 0, count: 0)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.status.stringValue = String(
                format: "%.0f fps · %@ · p95 %.0fms · %@",
                fps, self.codecLabel, lat.p95Ms, detail
            )
        }
    }

    private func handleDockAction(_ id: String) {
        switch id {
        case "apps":
            WorkflowRecorder.shared.button("apps")
            control.appsSwitcher()
        case "cc":
            WorkflowRecorder.shared.button("cc")
            control.controlCenter()
        case "music":
            musicSafe.toggle()
            control.musicSafe(musicSafe)
            dock.setMusicSafe(musicSafe)
            status.stringValue = musicSafe ? "music safe · HID only" : "video on"
        case "instant":
            let hard = NSEvent.modifierFlags.contains(.shift)
            control.instant(hard: hard)
            if musicSafe {
                musicSafe = false
                control.musicSafe(false)
                dock.setMusicSafe(false)
            }
        case "settings":
            showSettings()
        case "perf":
            showPerformance()
        case "screenshot":
            takeScreenshot()
        case "record":
            toggleRecording()
        case "pasteclip":
            pasteMacClipboard()
        default:
            WorkflowRecorder.shared.button(id)
            control.button(id)
        }
    }

    private func wirePathBar() {
        pathBar.reloadPaths()

        pathBar.onRecordToggle = { [weak self] in
            guard let self else { return }
            if WorkflowRecorder.shared.isRecording {
                let wf = WorkflowRecorder.shared.stop()
                self.lastRecorded = wf
                self.pathBar.setRecording(false, steps: wf.steps.count)
                self.workflowStrip.setMode(recording: false, playing: false)
                self.workflowStrip.reload(steps: wf.steps)
                self.relayoutWorkflowStrip()
                let name = self.pathBar.pathName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !wf.steps.isEmpty {
                    var named = wf
                    named.name = name
                    if (try? WorkflowStore.save(named)) != nil {
                        self.lastRecorded = named
                        self.pathBar.reloadPaths(select: name)
                        self.pathBar.setStatus("Saved · \(wf.steps.count) steps")
                        self.status.stringValue = "path saved · \(name)"
                    }
                } else if wf.steps.isEmpty {
                    self.pathBar.setStatus("No steps recorded")
                    self.workflowStrip.setVisible(false)
                    self.relayoutWorkflowStrip()
                } else {
                    self.pathBar.setStatus("Name the path to save")
                }
            } else {
                WorkflowRecorder.shared.start()
                self.pathBar.setRecording(true)
                self.workflowStrip.setMode(recording: true, playing: false)
                self.workflowStrip.setVisible(true)
                self.workflowStrip.reload(steps: [])
                self.relayoutWorkflowStrip()
                self.status.stringValue = "recording…"
            }
        }

        pathBar.onPlay = { [weak self] name in
            guard let self, self.didRevealMirror else {
                self?.pathBar.setStatus("Connect phone first")
                return
            }
            do {
                let wf = try WorkflowStore.load(named: name)
                self.pathBar.setPlaying(true)
                self.workflowStrip.setMode(recording: false, playing: true)
                self.workflowStrip.setVisible(true)
                self.workflowStrip.reload(steps: wf.steps)
                self.relayoutWorkflowStrip()
                self.status.stringValue = "playing · \(name)"
                WorkflowPlayer.shared.onStepHighlight = { [weak self] step, index in
                    self?.flashWorkflowStep(step, index: index, steps: wf.steps)
                }
                WorkflowPlayer.shared.onProgress = { [weak self] i, n, _ in
                    self?.pathBar.setStatus("Play \(i)/\(n)")
                }
                WorkflowPlayer.shared.onFinished = { [weak self] ok in
                    self?.pathBar.setPlaying(false)
                    self?.workflowStrip.setMode(recording: false, playing: false)
                    self?.pathBar.setStatus(ok ? "Done" : "Stopped")
                    self?.status.stringValue = ok ? "path done" : "stopped"
                }
                WorkflowPlayer.shared.play(wf, control: self.control, touchMode: self.metalView.touchMode)
            } catch {
                self.pathBar.setStatus("Not found: \(name)")
            }
        }

        pathBar.onStopPlay = { [weak self] in
            WorkflowPlayer.shared.cancel()
            self?.pathBar.setPlaying(false)
            self?.workflowStrip.setMode(recording: false, playing: false)
        }

        pathBar.onExport = { [weak self] name in
            self?.exportPath(named: name)
        }

        WorkflowRecorder.shared.onChanged = { [weak self] in
            guard let self, WorkflowRecorder.shared.isRecording else { return }
            let steps = WorkflowRecorder.shared.steps
            self.pathBar.setRecording(true, steps: steps.count)
            self.workflowStrip.reload(steps: steps, highlight: max(0, steps.count - 1))
        }

        WorkflowRecorder.shared.onStepAdded = { [weak self] step, index in
            guard let self else { return }
            self.flashWorkflowStep(step, index: index, steps: WorkflowRecorder.shared.steps)
        }
    }

    private func flashWorkflowStep(_ step: WorkflowStep, index: Int, steps: [WorkflowStep]) {
        workflowStrip.highlight(index: index, steps: steps)
    }

    private func relayoutWorkflowStrip() {
        let show = !workflowStrip.isHidden
        if show && !inFullScreen {
            widenWindowForStrip()
        }
        stripWidthConstraint.constant = show ? Self.stripWidth : 0
        stageTrailingToRoot.isActive = !show
        stageTrailingToStrip.isActive = show
        stage.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Keep the phone size — grow the window leftward so the right edge stays anchored.
    private func widenWindowForStrip() {
        guard window != nil, !inFullScreen, stripWidthConstraint.constant == 0 else { return }
        let extra = Self.stripWidth + 8
        var frame = window.frame
        frame.origin.x -= extra
        frame.size.width += extra
        window.setFrame(frame, display: true, animate: true)
    }

    @objc func toggleWorkflowStrip() {
        workflowStrip.setVisible(workflowStrip.isHidden)
        relayoutWorkflowStrip()
    }

    private func exportPath(named name: String) {
        do {
            _ = try WorkflowStore.load(named: name)
        } catch {
            pathBar.setStatus("Not found: \(name)")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Path"
        panel.nameFieldStringValue = "\(WorkflowStore.safeName(name)).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let out = try WorkflowStore.export(named: name, to: url)
            pathBar.setStatus("Exported")
            status.stringValue = "exported · \(out.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } catch {
            pathBar.setStatus("Export failed")
        }
    }

    @objc func takeScreenshot() {
        let url = CaptureStudio.shared.saveScreenshot(metalView?.lastPixelBuffer)
        if let url {
            status.stringValue = "screenshot · \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            status.stringValue = "screenshot failed — wait for a live frame"
        }
    }

    @objc func toggleRecording() {
        if CaptureStudio.shared.isRecording {
            CaptureStudio.shared.stopRecording { [weak self] url in
                if let url {
                    self?.status.stringValue = "saved · \(url.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    self?.status.stringValue = "recording failed"
                }
                self?.dock.setRecordOn(false)
            }
            return
        }
        let size = metalView?.videoSize ?? .zero
        let w = size.width > 1 ? size.width : 1170
        let h = size.height > 1 ? size.height : 2532
        do {
            try CaptureStudio.shared.startRecording(size: CGSize(width: w, height: h))
            dock.setRecordOn(true)
            status.stringValue = "recording…"
        } catch {
            status.stringValue = "record failed: \(error)"
        }
    }

    @objc func pasteMacClipboard() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty else {
            status.stringValue = "clipboard empty"
            return
        }
        // Put text on pasteboard (already there) and send Cmd+V to the phone.
        for chord in KeyboardTranslator.pasteChords(text) {
            control.key(down: true, usage: chord.usage, character: "", mods: chord.mods)
            control.key(down: false, usage: chord.usage, character: "", mods: chord.mods)
        }
        control.keyboardReset()
        status.stringValue = "pasted \(min(text.count, 40)) chars"
    }

    @objc func toggleShowTouches() {
        MirrorUESettings.showTouches.toggle()
        status.stringValue = MirrorUESettings.showTouches ? "show touches on" : "show touches off"
        if !MirrorUESettings.showTouches { metalView?.cancelActiveTouch() }
    }

    private func handleEngineDeath(code: Int32) {
        guard let device = lastBootDevice else {
            applyConnectionState(.failed(
                message: "Control engine stopped",
                detail: "Exit code \(code). Unlock the iPhone and try again."
            ))
            return
        }
        if engineRecoveryAttempt >= 2 {
            engineRecoveryAttempt = 0
            if connecting == nil { showConnecting(device: device) }
            applyConnectionState(.failed(
                message: "Control engine stopped",
                detail: "Couldn’t recover automatically. Unlock the phone, quit other mirrors, then Try again."
            ))
            return
        }
        engineRecoveryAttempt += 1
        applyConnectionState(.recovering(message: "Control engine restarted…", attempt: engineRecoveryAttempt))
        Task { await boot(device: device) }
    }

    @objc func showPerformance() {
        guard performancePanel == nil, let root = window.contentView else { return }
        let panel = PerformancePanel(frame: root.bounds)
        panel.autoresizingMask = [.width, .height]
        panel.metricsProvider = { [weak self] in
            self?.makeDiagnostics() ?? DiagnosticsReport(
                captureFps: 0, displayFps: 0, latencyP50Ms: 0, latencyP95Ms: 0,
                videoTransport: "—", inputTransport: "—", deviceName: "—", udid: "—",
                connectionState: "—", engineAlive: false, captureStalled: false,
                keyboardMode: "—", targetFps: 120,
                macOS: DiagnosticsReport.macVersion(), appVersion: "dev"
            )
        }
        panel.onClose = { [weak self] in
            self?.performancePanel?.removeFromSuperview()
            self?.performancePanel = nil
        }
        root.addSubview(panel)
        performancePanel = panel
    }

    private func makeDiagnostics() -> DiagnosticsReport {
        let lag = (captureIsFresh ? capture?.deliveryLag : muvsReader?.endToEndLatency)?.snapshot()
            ?? LatencyWindow.Snapshot(p50Ms: 0, p95Ms: 0, count: 0)
        let peer = lastBootDevice
        let input: String = {
            if control.hidSocketPath != nil { return "CoreDevice Network/USB HID" }
            return "HTTP fallback"
        }()
        return DiagnosticsReport(
            captureFps: capture?.inboundFps ?? 0,
            displayFps: metalView?.fps ?? 0,
            latencyP50Ms: lag.p50Ms,
            latencyP95Ms: lag.p95Ms,
            videoTransport: captureIsFresh ? "USB CoreMediaIO" : "Engine HEVC/MUVS",
            inputTransport: input,
            deviceName: cachedDeviceName,
            udid: peer?.udid ?? "—",
            connectionState: connectionState.title,
            engineAlive: session?.isAlive ?? false,
            captureStalled: capture?.isStalled ?? false,
            keyboardMode: MirrorUESettings.keyboardMode.rawValue,
            targetFps: MirrorUESettings.captureFPS,
            macOS: DiagnosticsReport.macVersion(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        LocalAPIServer.shared.stop()
        for o in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        sleepObservers.removeAll()
        picker?.stopPolling()
        session?.stop()
        muvsReader?.stop()
        capture?.stop()
    }
}

// MARK: - Phone stage (frame-based aspect-fit — never drives NSWindow size)

/// Lays out the bezel with aspect-fit inside its bounds using frames only.
/// Auto Layout aspect constraints on a window-filling view caused
/// `NSGenericException` layout-pass loops with `windowWillResize`.
final class MirrorStageView: NSView {
    var bezel: NSView?
    var rim: NSView?
    var metalView: NSView?
    var aspect: CGFloat = 9 / 19.5 {
        didSet { needsLayout = true }
    }
    var bezelPad: CGFloat = 2.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        guard let bezel else { return }
        let b = bounds
        guard b.width > 1, b.height > 1 else { return }
        let a = max(aspect, 0.01)

        let phoneW: CGFloat
        let phoneH: CGFloat
        if b.width / b.height > a {
            phoneH = b.height
            phoneW = phoneH * a
        } else {
            phoneW = b.width
            phoneH = phoneW / a
        }
        let x = (b.width - phoneW) * 0.5
        let y = (b.height - phoneH) * 0.5
        bezel.frame = NSRect(x: x, y: y, width: phoneW, height: phoneH)

        let pad = bezelPad
        let inner = NSRect(
            x: pad, y: pad,
            width: max(0, phoneW - pad * 2),
            height: max(0, phoneH - pad * 2)
        )
        rim?.frame = inner
        metalView?.frame = inner
    }
}

// MARK: - Touch pretranslation (view → UniversalHID)

/// Maps a click on the mirrored frame into UniversalHID absolute coordinates.
///
/// UniversalHID’s digitizer is fixed to the device’s **natural portrait** axes
/// (origin top-left, +X right, +Y down), independent of UI orientation. CMIO
/// frames follow the UI (landscape buffers when the phone is landscape), so
/// every touch must be pretranslated:
///
/// ```text
///   AppKit point (bottom-left)
///     → view UV top-left in the video content rect (aspect-fit)
///     → portrait digitizer UV (orientation matrix)
///     → uint16 0…65535 (VNC-compatible quantisation)
/// ```
enum TouchMap {
    /// Home-indicator side while the frame is landscape.
    enum LandscapeHome: Equatable {
        /// Home on the right — `UIInterfaceOrientationLandscapeLeft`.
        case right
        /// Home on the left — `UIInterfaceOrientationLandscapeRight`.
        case left
    }

    enum Mode: Equatable {
        case portrait
        case landscape(LandscapeHome)
        /// Skip digitizer remap (HID space == framebuffer). Debug / HEVC only.
        case buffer
    }

    static func mode(frameWidth: Int, frameHeight: Int) -> Mode {
        if frameWidth <= frameHeight { return .portrait }
        switch MirrorUESettings.landscapeHome {
        case .buffer:
            return .buffer
        case .left:
            return .landscape(.left)
        case .automatic:
            return .landscape(.right)
        }
    }

    static func badge(for mode: Mode) -> String {
        switch mode {
        case .portrait: return "portrait"
        case .buffer: return "landscape · buffer"
        case .landscape(.right): return "landscape"
        case .landscape(.left): return "landscape · flip"
        }
    }

    /// Aspect-fit rectangle of a `video` frame inside `view` (AppKit bottom-left).
    static func contentRect(view: CGSize, video: CGSize) -> CGRect {
        let vw = max(view.width, 1)
        let vh = max(view.height, 1)
        let tw = max(video.width, 1)
        let th = max(video.height, 1)
        let viewAspect = vw / vh
        let videoAspect = tw / th
        if viewAspect > videoAspect {
            let w = vh * videoAspect
            return CGRect(x: (vw - w) * 0.5, y: 0, width: w, height: vh)
        }
        let h = vw / videoAspect
        return CGRect(x: 0, y: (vh - h) * 0.5, width: vw, height: h)
    }

    /// View point (AppKit, bottom-left origin) → HID absolute pair.
    static func toHID(
        pointInView: CGPoint,
        viewSize: CGSize,
        videoSize: CGSize,
        mode: Mode
    ) -> (Int, Int)? {
        let content = contentRect(view: viewSize, video: videoSize)
        guard content.width > 1, content.height > 1 else { return nil }

        // Outside the letterbox → clamp onto the nearest edge of the image so a
        // drag that slips into the black bars does not jump off-screen on device.
        let px = min(max(pointInView.x, content.minX), content.maxX - .leastNonzeroMagnitude)
        let py = min(max(pointInView.y, content.minY), content.maxY - .leastNonzeroMagnitude)

        // Content-local, top-left UV (framebuffer space).
        var nx = (px - content.minX) / content.width
        var ny = 1.0 - (py - content.minY) / content.height
        nx = min(1, max(0, nx))
        ny = min(1, max(0, ny))

        let (hx, hy) = digitizerUV(nx: nx, ny: ny, mode: mode)
        return (quantize(hx), quantize(hy))
    }

    /// Framebuffer UV (top-left) → portrait-fixed digitizer UV.
    static func digitizerUV(nx: CGFloat, ny: CGFloat, mode: Mode) -> (CGFloat, CGFloat) {
        switch mode {
        case .portrait, .buffer:
            return (nx, ny)
        case .landscape(.right):
            // 90° CCW: landscape top-left → portrait top-right.
            // (nx, ny) → (1 - ny, nx)
            return (1 - ny, nx)
        case .landscape(.left):
            // 90° CW: landscape top-left → portrait bottom-left.
            // (nx, ny) → (ny, 1 - nx)
            return (ny, 1 - nx)
        }
    }

    /// Same inclusive edge mapping as pymobiledevice3’s VNC pointer path.
    static func quantize(_ t: CGFloat) -> Int {
        let c = min(1, max(0, t))
        return Int((c * 65535.0).rounded(.down))
    }
}

// MARK: - Metal view

final class FrameView: MTKView, MTKViewDelegate {
    private let control: ControlClient
    private var texture: MTLTexture?
    private var pipeline: MTLRenderPipelineState!
    private var commandQueue: MTLCommandQueue!
    private var lastUploadedSeq: UInt32 = 0
    private var uploadLock = NSLock()
    private var frames = 0
    private var t0 = CACurrentMediaTime()
    private(set) var fps: Double = 0
    let presentLatency = LatencyWindow()
    private var activeTouch = false
    private var lastDragSent = CACurrentMediaTime()
    private var lastDragX = -1
    private var lastDragY = -1
    /// Uptime ns when the current finger went down — used to enforce a firm min hold.
    private var touchPressedAt: UInt64 = 0
    private var touchGeneration: UInt64 = 0
    /// iOS often ignores sub-~100ms digitizer contacts; keep clicks firmer than that.
    private static let minTouchHoldUs: UInt32 = 140_000
    var hasActiveTouch: Bool { activeTouch }
    /// Touch pretranslation mode (portrait digitizer vs buffer).
    var touchMode: TouchMap.Mode = .portrait
    /// Last video frame size — drives aspect-fit content rect for taps + draw.
    var videoSize: CGSize = .zero
    /// keyCode → last HID payload (AppKit often clears `characters` on keyUp).
    private var keysDown: [UInt16: (usage: UInt16, character: String, mods: UInt8)] = [:]

    /// Fired when the GPU has finished reading a shared-memory slot.
    var onDisplayed: ((UInt32, UInt64) -> Void)?
    private var slotTextures: [MTLTexture] = []
    private var slotBuffers: [MTLBuffer] = []
    private(set) var zeroCopySlots = false
    private var pending: (slot: Int, seq: UInt32, producedNs: UInt64)?
    private var liveCapture: CaptureFrameRing.Slot?
    private var captureRing: CaptureFrameRing?
    private var continuousCapture = false
    private var drawScheduled = false
    private let touchIndicator = TouchIndicatorOverlay(frame: .zero)
    /// Latest CoreMediaIO frame for screenshot / recording.
    private(set) var lastPixelBuffer: CVPixelBuffer?

    private static var captureSlotCount: Int {
        let raw = ProcessInfo.processInfo.environment["MIRRORUE_CAPTURE_SLOTS"] ?? "32"
        return max(4, Int(raw) ?? 32)
    }

    init(frame: CGRect, device: MTLDevice, control: ControlClient) {
        self.control = control
        super.init(frame: frame, device: device)
        self.delegate = self
        self.framebufferOnly = true
        self.colorPixelFormat = .bgra8Unorm
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        self.preferredFramesPerSecond = DeviceScreenCapture.captureFPS
        if let metal = self.layer as? CAMetalLayer {
            metal.maximumDrawableCount = 3
            // Stay vsync'd to the Mac display — on ProMotion that is 120 Hz.
            metal.displaySyncEnabled = true
        }
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        commandQueue = device.makeCommandQueue()!
        buildPipeline(device)
        allowedTouchTypes = []

        touchIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(touchIndicator)
        NSLayoutConstraint.activate([
            touchIndicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            touchIndicator.trailingAnchor.constraint(equalTo: trailingAnchor),
            touchIndicator.topAnchor.constraint(equalTo: topAnchor),
            touchIndicator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resignFirstResponder() -> Bool {
        flushKeyboard()
        return super.resignFirstResponder()
    }

    /// Drop local key tracking and force an empty HID keyboard report on the phone.
    private func flushKeyboard() {
        keysDown.removeAll()
        control.keyboardReset()
    }

    override func mouseDown(with event: NSEvent) {
        if window?.inLiveResize == true { return }
        window?.makeFirstResponder(self)
        // Only clear when we still track local keys — a blanket reset on every
        // click dismisses text-field selection / IME on the phone.
        if !keysDown.isEmpty {
            flushKeyboard()
        }
        activeTouch = true
        touchGeneration &+= 1
        touchPressedAt = DispatchTime.now().uptimeNanoseconds
        guard let (x, y) = norm(event) else {
            activeTouch = false
            return
        }
        lastDragX = x
        lastDragY = y
        lastDragSent = CACurrentMediaTime()
        control.touch(type: "contact", x: x, y: y)
        updateTouchIndicator(event, pressing: true)
        if let uv = contentUV(event) {
            WorkflowRecorder.shared.touchDown(nx: uv.0, ny: uv.1)
        }
    }

    private func updateTouchIndicator(_ event: NSEvent, pressing: Bool) {
        guard MirrorUESettings.showTouches else {
            touchIndicator.clear()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if pressing {
            touchIndicator.show(at: p, pressing: true)
        } else {
            touchIndicator.release(at: p)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    private func buildPipeline(_ device: MTLDevice) {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut v_main(uint vid [[vertex_id]]) {
            float2 pos[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
            float2 uv[4]  = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
            VOut o; o.pos = float4(pos[vid], 0, 1); o.uv = uv[vid]; return o;
        }
        fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            float4 c = tex.sample(s, in.uv);
            c.a = 1.0;
            return c;
        }
        """
        let lib = try! device.makeLibrary(source: src, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "v_main")
        desc.fragmentFunction = lib.makeFunction(name: "f_main")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)
    }

    /// Bind MUVS shared-memory slots as Metal textures (zero-copy when aligned).
    func bind(_ ring: RingBinding) {
        guard let device = device else { return }
        let alignment = device.minimumLinearTextureAlignment(for: .bgra8Unorm)

        uploadLock.lock()
        defer { uploadLock.unlock() }

        slotTextures.removeAll()
        slotBuffers.removeAll()
        pending = nil
        zeroCopySlots = false

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: ring.width, height: ring.height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        if ring.bytesPerRow % alignment == 0 {
            var built: [MTLTexture] = []
            var buffers: [MTLBuffer] = []
            for index in 0..<ring.slots {
                guard let buffer = device.makeBuffer(
                    bytesNoCopy: ring.slotAddress(index),
                    length: ring.slotBytes,
                    options: .storageModeShared,
                    deallocator: nil
                ), let tex = buffer.makeTexture(
                    descriptor: descriptor, offset: 0, bytesPerRow: ring.bytesPerRow
                ) else {
                    built.removeAll()
                    buffers.removeAll()
                    break
                }
                buffers.append(buffer)
                built.append(tex)
            }
            if built.count == ring.slots {
                slotTextures = built
                slotBuffers = buffers
                zeroCopySlots = true
            }
        }

        if !zeroCopySlots {
            fputs("MediaKit: linear textures unavailable; falling back to uploads\n", stderr)
        }

        let displayDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: ring.width, height: ring.height, mipmapped: true
        )
        displayDescriptor.mipmapLevelCount = 4
        displayDescriptor.usage = [.shaderRead, .renderTarget]
        displayDescriptor.storageMode = .private
        texture = device.makeTexture(descriptor: displayDescriptor)
    }

    func present(slot: Int, seq: UInt32, producedNs: UInt64) {
        uploadLock.lock()
        // Engine frames must not fight continuous CoreMediaIO refresh.
        if continuousCapture {
            uploadLock.unlock()
            return
        }
        pending = (slot, seq, producedNs)
        uploadLock.unlock()
        tickFrame()
    }

    /// Zero-copy CoreMediaIO path: GPU samples the IOSurface macOS filled.
    func present(_ pixelBuffer: CVPixelBuffer) {
        guard let device = device else { return }
        if captureRing == nil {
            captureRing = CaptureFrameRing(device: device, slots: Self.captureSlotCount)
        }
        guard let slot = captureRing?.push(pixelBuffer) else { return }
        lastPixelBuffer = pixelBuffer
        if CaptureStudio.shared.isRecording {
            CaptureStudio.shared.appendFrame(pixelBuffer)
        }

        uploadLock.lock()
        liveCapture = slot
        zeroCopySlots = true
        let needContinuous = !continuousCapture
        if needContinuous { continuousCapture = true }
        uploadLock.unlock()

        if needContinuous {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPaused = false
                self.enableSetNeedsDisplay = false
                self.preferredFramesPerSecond = DeviceScreenCapture.captureFPS
            }
        }
    }

    private func tickFrame() {
        frames += 1
        let now = CACurrentMediaTime()
        if now - t0 >= 1 {
            fps = Double(frames) / (now - t0)
            frames = 0
            t0 = now
        }

        uploadLock.lock()
        let schedule = !drawScheduled
        if schedule { drawScheduled = true }
        uploadLock.unlock()
        guard schedule else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.uploadLock.lock()
            self.drawScheduled = false
            self.uploadLock.unlock()
            self.draw(in: self)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        uploadLock.lock()
        let tex = texture
        let claimed = pending
        pending = nil
        let capture = liveCapture
        let slotSource = claimed.flatMap { $0.slot < slotTextures.count ? slotTextures[$0.slot] : nil }
        uploadLock.unlock()

        func release() {
            if let claimed { onDisplayed?(claimed.seq, claimed.producedNs) }
        }

        guard let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer() else {
            release()
            return
        }

        let sample: MTLTexture?
        let captureHold: CaptureFrameRing.Slot?
        if let capture {
            sample = capture.texture
            captureHold = capture
        } else if let slotSource, let tex, let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: slotSource, to: tex)
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            sample = tex
            captureHold = nil
        } else {
            sample = tex
            captureHold = nil
        }

        guard let sample else {
            release()
            return
        }

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            release()
            return
        }
        // Aspect-fit viewport so the drawn pixels match the touch content rect.
        let dw = CGFloat(drawable.texture.width)
        let dh = CGFloat(drawable.texture.height)
        let vw = videoSize.width > 1 ? videoSize.width : CGFloat(sample.width)
        let vh = videoSize.height > 1 ? videoSize.height : CGFloat(sample.height)
        let fit = TouchMap.contentRect(view: CGSize(width: dw, height: dh), video: CGSize(width: vw, height: vh))
        enc.setViewport(MTLViewport(
            originX: Double(fit.minX),
            originY: Double(fit.minY),
            width: Double(fit.width),
            height: Double(fit.height),
            znear: 0,
            zfar: 1
        ))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(sample, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        if continuousCapture {
            frames += 1
            let now = CACurrentMediaTime()
            if now - t0 >= 1 {
                fps = Double(frames) / (now - t0)
                frames = 0
                t0 = now
            }
        }

        if let claimed {
            lastUploadedSeq = claimed.seq
            if claimed.producedNs > 0 {
                let now = monotonicNow()
                if now > claimed.producedNs {
                    presentLatency.add(Double(now - claimed.producedNs) / 1_000_000.0)
                }
            }
            cmd.addCompletedHandler { [weak self] _ in
                self?.onDisplayed?(claimed.seq, claimed.producedNs)
            }
        }
        if let captureHold {
            cmd.addCompletedHandler { _ in _ = captureHold }
        }
        cmd.present(drawable)
        cmd.commit()
    }

    private func norm(_ event: NSEvent) -> (Int, Int)? {
        let p = convert(event.locationInWindow, from: nil)
        let view = bounds.size
        let video = videoSize.width > 1 ? videoSize : view
        return TouchMap.toHID(
            pointInView: p,
            viewSize: view,
            videoSize: video,
            mode: touchMode
        )
    }

    /// Content-rect UV (0…1, y downward) for workflow recording.
    func contentUV(_ event: NSEvent) -> (Double, Double)? {
        let p = convert(event.locationInWindow, from: nil)
        let view = bounds.size
        let video = videoSize.width > 1 ? videoSize : view
        let content = TouchMap.contentRect(view: view, video: video)
        guard content.width > 1, content.height > 1 else { return nil }
        var nx = (p.x - content.minX) / content.width
        var ny = 1.0 - (p.y - content.minY) / content.height
        nx = min(1, max(0, nx))
        ny = min(1, max(0, ny))
        return (Double(nx), Double(ny))
    }

    /// Drop an in-progress finger without waiting for mouseUp (resize / layout).
    func cancelActiveTouch() {
        guard activeTouch else { return }
        activeTouch = false
        touchGeneration &+= 1
        control.touch(type: "release", x: max(lastDragX, 0), y: max(lastDragY, 0))
        lastDragX = -1
        lastDragY = -1
        touchIndicator.clear()
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeTouch else { return }
        if window?.inLiveResize == true {
            cancelActiveTouch()
            return
        }
        guard let (x, y) = norm(event) else { return }
        let now = CACurrentMediaTime()
        let dx = abs(x - lastDragX)
        let dy = abs(y - lastDragY)
        // Match capture rate so touch stays smooth at 120 Hz.
        let dragHz = Double(max(60, DeviceScreenCapture.captureFPS))
        guard now - lastDragSent >= 1.0 / dragHz || dx + dy >= 64 else { return }
        lastDragSent = now
        lastDragX = x
        lastDragY = y
        control.touch(type: "contact", x: x, y: y)
        updateTouchIndicator(event, pressing: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard activeTouch else { return }
        activeTouch = false
        updateTouchIndicator(event, pressing: false)
        let pressedAt = touchPressedAt
        guard let (x, y) = norm(event) else {
            control.releaseTouch(
                x: max(lastDragX, 0), y: max(lastDragY, 0),
                minHoldUs: Self.minTouchHoldUs, pressedAt: pressedAt
            )
            return
        }
        lastDragX = x
        lastDragY = y
        // Enforce a firm min hold on the HID queue so light trackpad clicks register.
        control.releaseTouch(x: x, y: y, minHoldUs: Self.minTouchHoldUs, pressedAt: pressedAt)
        if let uv = contentUV(event) {
            WorkflowRecorder.shared.touchUp(nx: uv.0, ny: uv.1)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard var coords = norm(event) else { return }
        let dy = Int(event.scrollingDeltaY * 40)
        let dx = Int(event.scrollingDeltaX * 40)
        if !activeTouch {
            activeTouch = true
            control.touch(type: "contact", x: coords.0, y: coords.1)
        }
        // Nudge in digitizer space (already orientation-correct).
        coords.0 = max(0, min(65535, coords.0 - dx))
        coords.1 = max(0, min(65535, coords.1 - dy))
        lastDragX = coords.0
        lastDragY = coords.1
        control.touch(type: "contact", x: coords.0, y: coords.1)
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
            activeTouch = false
            control.touch(type: "release", x: coords.0, y: coords.1)
        }
    }

    override func keyDown(with event: NSEvent) { inject(event, down: true) }
    override func keyUp(with event: NSEvent) { inject(event, down: false) }

    override func flagsChanged(with event: NSEvent) {
        // Swallow lone modifiers so AppKit does not beep; chords still ride
        // on the next keyDown's modifierFlags bitmask.
    }

    /// Inject a key. Default ``auto`` detects the Mac input source (French →
    /// AZERTY HID, U.S. → US HID, else physical positions). Assumes the iPhone
    /// hardware keyboard uses the same layout language as the Mac.
    private func inject(_ event: NSEvent, down: Bool) {
        if event.isARepeat { return }
        let code = event.keyCode

        if !down {
            if let prev = keysDown.removeValue(forKey: code) {
                control.key(down: false, usage: prev.usage, character: prev.character, mods: prev.mods)
            }
            return
        }

        var mods: UInt8 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) { mods |= 0x01 }
        if flags.contains(.control) { mods |= 0x02 }
        if flags.contains(.option) { mods |= 0x04 }
        if flags.contains(.command) { mods |= 0x08 }

        let layout = KeyboardTranslator.phoneLayout

        // Physical / host: mirror the key position (Mac layout == iPhone layout).
        if layout == .physical {
                if let usage = MacHID.usage(forKeyCode: code) {
                keysDown[code] = (usage, "", mods)
                control.key(down: true, usage: usage, character: "", mods: mods)
                let glyph = event.charactersIgnoringModifiers ?? ""
                if let ch = glyph.first, ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    WorkflowRecorder.shared.typed(String(ch))
                } else {
                    WorkflowRecorder.shared.specialKey(usage: usage, mods: mods)
                }
            }
            return
        }

        let typed = event.characters ?? ""
        let bare = event.charactersIgnoringModifiers ?? ""
        let glyphSource = typed.isEmpty ? bare : typed

        if let ch = glyphSource.first {
            let controlOnly = ch.unicodeScalars.allSatisfy {
                CharacterSet.controlCharacters.contains($0)
            }
            let structural = ch == "\t" || ch == "\r" || ch == "\n"
            if structural || !controlOnly {
                let hostMods = mods & 0x0A
                let glyph = String(ch)
                if let chord = KeyboardTranslator.resolve(glyph, hostMods: hostMods) {
                    keysDown[code] = (chord.usage, "", chord.mods)
                    control.key(down: true, usage: chord.usage, character: "", mods: chord.mods)
                    if structural {
                        WorkflowRecorder.shared.specialKey(usage: chord.usage, mods: chord.mods)
                    } else {
                        WorkflowRecorder.shared.typed(glyph)
                    }
                    return
                }
                if KeyboardTranslator.pasteUnmapped, !structural {
                    for chord in KeyboardTranslator.pasteChords(glyph) {
                        control.key(down: true, usage: chord.usage, character: "", mods: chord.mods)
                        control.key(down: false, usage: chord.usage, character: "", mods: chord.mods)
                    }
                    control.keyboardReset()
                    WorkflowRecorder.shared.typed(glyph)
                    return
                }
                return
            }
        }

        if let usage = MacHID.specialUsage(forKeyCode: code) {
            keysDown[code] = (usage, "", mods)
            control.key(down: true, usage: usage, character: "", mods: mods)
            WorkflowRecorder.shared.specialKey(usage: usage, mods: mods)
        }
    }
}

/// Carbon key codes → USB HID usages (ANSI positions).
enum MacHID {
    /// Letters, digits, punctuation, and specials — for ``physical`` mode.
    static func usage(forKeyCode code: UInt16) -> UInt16? {
        if let u = letterDigitPunctuation(code) { return u }
        return specialUsage(forKeyCode: code)
    }

    static func specialUsage(forKeyCode code: UInt16) -> UInt16? {
        switch code {
        case 0x24, 0x4C: return 0x28 // Return / keypad Enter
        case 0x30: return 0x2B       // Tab
        case 0x31: return 0x2C       // Space
        case 0x33: return 0x2A       // Delete (Backspace)
        case 0x35: return 0x29       // Escape
        case 0x7B: return 0x50       // Left
        case 0x7C: return 0x4F       // Right
        case 0x7D: return 0x51       // Down
        case 0x7E: return 0x52       // Up
        case 0x72: return 0x49       // Help / Insert
        case 0x73: return 0x4A       // Home
        case 0x77: return 0x4D       // End
        case 0x74: return 0x4B       // Page Up
        case 0x79: return 0x4E       // Page Down
        case 0x75: return 0x4C       // Forward Delete
        case 0x39: return 0x39       // Caps Lock
        case 0x7A: return 0x3A       // F1
        case 0x78: return 0x3B       // F2
        case 0x63: return 0x3C       // F3
        case 0x76: return 0x3D       // F4
        case 0x60: return 0x3E       // F5
        case 0x61: return 0x3F       // F6
        case 0x62: return 0x40       // F7
        case 0x64: return 0x41       // F8
        case 0x65: return 0x42       // F9
        case 0x6D: return 0x43       // F10
        case 0x67: return 0x44       // F11
        case 0x6F: return 0x45       // F12
        default: return nil
        }
    }

    /// ANSI / ISO keyCode → HID usage (physical position, layout-agnostic).
    private static func letterDigitPunctuation(_ code: UInt16) -> UInt16? {
        switch code {
        case 0x00: return 0x04 // a
        case 0x01: return 0x16 // s
        case 0x02: return 0x07 // d
        case 0x03: return 0x09 // f
        case 0x04: return 0x0B // h
        case 0x05: return 0x0A // g
        case 0x06: return 0x1D // z
        case 0x07: return 0x1B // x
        case 0x08: return 0x06 // c
        case 0x09: return 0x19 // v
        case 0x0B: return 0x05 // b
        case 0x0C: return 0x14 // q
        case 0x0D: return 0x1A // w
        case 0x0E: return 0x08 // e
        case 0x0F: return 0x15 // r
        case 0x10: return 0x1C // y
        case 0x11: return 0x17 // t
        case 0x12: return 0x1E // 1
        case 0x13: return 0x1F // 2
        case 0x14: return 0x20 // 3
        case 0x15: return 0x21 // 4
        case 0x16: return 0x22 // 5
        case 0x17: return 0x23 // 6
        case 0x18: return 0x24 // 7
        case 0x19: return 0x25 // 8
        case 0x1A: return 0x26 // 9
        case 0x1B: return 0x27 // 0
        case 0x1C: return 0x2D // -
        case 0x1D: return 0x2E // =
        case 0x1E: return 0x2F // [
        case 0x1F: return 0x30 // ]
        case 0x20: return 0x18 // u
        case 0x21: return 0x13 // p
        case 0x22: return 0x0C // i
        case 0x23: return 0x12 // o
        case 0x25: return 0x0F // l
        case 0x26: return 0x0D // j
        case 0x27: return 0x34 // '
        case 0x28: return 0x0E // k
        case 0x29: return 0x33 // ;
        case 0x2A: return 0x31 // \
        case 0x2B: return 0x36 // ,
        case 0x2C: return 0x35 // `
        case 0x2D: return 0x11 // n
        case 0x2E: return 0x10 // m
        case 0x2F: return 0x37 // .
        case 0x30: return 0x2B // tab (also in specials)
        case 0x31: return 0x2C // space
        case 0x32: return 0x32 // ISO § / non-US #~ (Keyboard Non-US # and ~)
        case 0x0A: return 0x64 // ISO key (Keyboard Non-US \ and |)
        default: return nil
        }
    }
}
