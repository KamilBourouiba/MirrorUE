import AVFoundation
import CoreMediaIO
import Foundation

/// iPhone screen via CoreMediaIO (QuickTime's capture source).
///
/// Session control and the sample-buffer callback must not share a queue:
/// `startRunning()` can wait on the delegate queue and deadlocks if called from it.
public final class DeviceScreenCapture: NSObject, @unchecked Sendable {
    public var onFrame: ((CVPixelBuffer) -> Void)?
    public var onActive: ((String) -> Void)?
    public let deliveryLag = LatencyWindow()
    public private(set) var framesReceived: UInt64 = 0
    public private(set) var deviceName = "-"

    private let session = AVCaptureSession()
    private let frameQueue = DispatchQueue(label: "mirrorue-capture.frames", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "mirrorue-capture.control", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var stopped = false
    private var attaching = false
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    private let frameClock = NSLock()
    private var lastFrameNs: UInt64 = 0
    private var inboundWindowStart: UInt64 = 0
    private var inboundWindowCount: UInt64 = 0
    /// Rolling inbound rate from CoreMediaIO, updated about once a second.
    public private(set) var inboundFps: Double = 0

    public override init() {
        super.init()
        Self.allowScreenCaptureDevices()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        // Keep every frame the DAL produces. The UI copies into its own ring, so
        // holding them briefly here is fine and avoids gaps when the consumer
        // hiccups for a few milliseconds.
        output.alwaysDiscardsLateVideoFrames = false
        output.setSampleBufferDelegate(self, queue: frameQueue)
    }

    public var isRunning: Bool { session.isRunning }

    /// Target CoreMediaIO frame rate (default 120). Clamped to 1…240.
    public static var captureFPS: Int {
        let raw = ProcessInfo.processInfo.environment["MIRRORUE_CAPTURE_FPS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let n = Int(raw) ?? 120
        return min(240, max(1, n))
    }

    public static var isAvailable: Bool {
        allowScreenCaptureDevices()
        return findScreenDevice(attempts: 5) != nil
    }

    public func start() {
        stopped = false
        // Unsigned binaries sometimes see an empty device list until this returns.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            fputs("MediaKit: camera access \(granted ? "granted" : "denied")\n", stderr)
            Self.allowScreenCaptureDevices()
            self?.attach(force: true)
        }

        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification,
                     AVCaptureDevice.wasDisconnectedNotification,
                     AVCaptureSession.runtimeErrorNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) {
                [weak self] note in
                if name == AVCaptureDevice.wasConnectedNotification {
                    self?.attach(force: true)
                } else {
                    self?.attach(force: name == AVCaptureSession.runtimeErrorNotification)
                }
                _ = note
            })
        }

        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, !self.attaching else { return }
            if self.session.isRunning {
                self.frameClock.lock()
                let last = self.lastFrameNs
                self.frameClock.unlock()
                if last != 0 && monotonicNow() &- last > 3_000_000_000 {
                    fputs("MediaKit: screen capture stalled, reattaching\n", stderr)
                    self.attach(force: true)
                }
            } else {
                // Still waiting for the device — keep poking; the phone may have
                // unlocked without a connection notification we care about.
                self.attach(force: true)
            }
        }
        timer.resume()
        watchdog = timer
    }

    public func stop() {
        stopped = true
        watchdog?.cancel()
        watchdog = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        // Never sync-wait on controlQueue here: attach may be sleeping on it,
        // and a sync from the main thread would deadlock the UI.
        controlQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    deinit {
        stopped = true
        watchdog?.cancel()
    }

    private func attach(force: Bool) {
        controlQueue.async { [weak self] in
            guard let self, !self.stopped, !self.attaching else { return }
            if !force, self.session.isRunning,
               self.currentInput?.device.isConnected == true { return }
            self.attaching = true
            defer { self.attaching = false }

            if self.session.isRunning { self.session.stopRunning() }
            Self.allowScreenCaptureDevices()

            // One short poll only — the watchdog re-enters every 2s. Blocking
            // here for minutes made the control queue look wedged and delayed
            // every reconnect.
            guard let device = Self.findScreenDevice(attempts: 15) else {
                Self.debugDevices("waiting")
                return
            }

            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                fputs("MediaKit: screen device open failed: \(error)\n", stderr)
                return
            }

            self.session.beginConfiguration()
            // `.inputPriority` is iOS-only; on macOS keep `.high` and drive
            // rate via the connection frame-duration knobs below.
            self.session.sessionPreset = .high
            if let old = self.currentInput { self.session.removeInput(old) }
            guard self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                fputs("MediaKit: screen device input refused\n", stderr)
                return
            }
            self.session.addInput(input)
            self.currentInput = input
            if self.session.canAddOutput(self.output), !self.session.outputs.contains(self.output) {
                self.session.addOutput(self.output)
            }
            // Request ProMotion-class capture (default 120). Device-level
            // activeVideoMinFrameDuration throws on this CMIO plugin — set the
            // connection instead. Override with MIRRORUE_CAPTURE_FPS.
            let targetFps = Self.captureFPS
            if let connection = self.output.connection(with: .video) {
                let frame = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                if connection.isVideoMinFrameDurationSupported {
                    connection.videoMinFrameDuration = frame
                }
                if connection.isVideoMaxFrameDurationSupported {
                    connection.videoMaxFrameDuration = frame
                }
                fputs("MediaKit: capture request \(targetFps) fps\n", stderr)
            }
            self.session.commitConfiguration()
            self.session.startRunning()

            self.frameClock.lock()
            self.lastFrameNs = 0
            self.inboundWindowStart = monotonicNow()
            self.inboundWindowCount = 0
            self.frameClock.unlock()
            self.deviceName = device.localizedName
            fputs("MediaKit: screen capture via \(device.localizedName)\n", stderr)
            self.onActive?(device.localizedName)
        }
    }

    private static func debugDevices(_ tag: String) {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: nil, position: .unspecified
        )
        let names = discovery.devices.map {
            "\($0.localizedName)[v=\($0.hasMediaType(.video)) m=\($0.hasMediaType(.muxed))]"
        }.joined(separator: ", ")
        fputs("MediaKit: \(tag) external=[\(names)] auth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)\n", stderr)
    }

    /// Must run on the main thread. The CMIO DAL publishes screen devices onto
    /// the main run loop; setting this from a background queue is why a `swift`
    /// probe saw `iPhone [muxed]` while MirrorUE only ever saw Continuity Camera.
    private static func allowScreenCaptureDevices() {
        let apply = {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var allow: UInt32 = 1
            _ = CMIOObjectSetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &allow
            )
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.sync(execute: apply)
        }
    }

    private static func findScreenDevice(attempts: Int) -> AVCaptureDevice? {
        allowScreenCaptureDevices()
        for _ in 0..<attempts {
            // Give the main run loop a turn so the DAL can publish. Without this
            // the DiscoverySession keeps returning Continuity Camera only.
            // Never main.sync from the main thread — that deadlocks.
            let pump = {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if Thread.isMainThread {
                pump()
            } else {
                DispatchQueue.main.sync(execute: pump)
            }
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external], mediaType: nil, position: .unspecified
            )
            if let found = discovery.devices.first(where: { $0.hasMediaType(.muxed) }) {
                return found
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }
}

extension DeviceScreenCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        framesReceived &+= 1
        frameClock.lock()
        lastFrameNs = monotonicNow()
        if inboundWindowStart == 0 { inboundWindowStart = lastFrameNs }
        inboundWindowCount &+= 1
        let elapsed = lastFrameNs &- inboundWindowStart
        if elapsed >= 1_000_000_000 {
            inboundFps = Double(inboundWindowCount) * 1_000_000_000.0 / Double(elapsed)
            fputs(String(format: "MediaKit: capture inbound %.1f fps\n", inboundFps), stderr)
            inboundWindowStart = lastFrameNs
            inboundWindowCount = 0
        }
        frameClock.unlock()

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isValid {
            let delta = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), pts)
            let ms = CMTimeGetSeconds(delta) * 1000
            if ms > 0 && ms < 5000 { deliveryLag.add(ms) }
        }

        onFrame?(pixels)
    }
}
