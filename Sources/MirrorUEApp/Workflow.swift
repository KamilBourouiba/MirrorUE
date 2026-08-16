import Foundation
import AppKit
import ControlKit

/// Serializable automation workflow (record → JSON → replay).
struct Workflow: Codable, Equatable {
    var name: String
    var version: Int
    var createdAt: String
    /// Mirror round-trip latency (p95 ms) captured when the workflow was recorded.
    var latencyP95Ms: Int?
    var steps: [WorkflowStep]

    init(name: String, steps: [WorkflowStep] = [], latencyP95Ms: Int? = nil) {
        self.name = name
        self.version = 1
        self.createdAt = ISO8601DateFormatter().string(from: Date())
        self.latencyP95Ms = latencyP95Ms
        self.steps = steps
    }
}

/// Single automation step for record/replay and the local control API.
struct WorkflowStep: Codable, Equatable {
    enum Kind: String, Codable {
        case tap
        case swipe
        case type
        case key
        case button
        case wait
    }

    var kind: Kind
    var x: Double?
    var y: Double?
    var x1: Double?
    var y1: Double?
    var text: String?
    var usage: Int?
    var mods: Int?
    var name: String?
    var ms: Int?

    static func tap(x: Double, y: Double) -> WorkflowStep {
        WorkflowStep(kind: .tap, x: x, y: y)
    }

    static func swipe(x0: Double, y0: Double, x1: Double, y1: Double, ms: Int = 280) -> WorkflowStep {
        WorkflowStep(kind: .swipe, x: x0, y: y0, x1: x1, y1: y1, ms: ms)
    }

    static func type(_ text: String) -> WorkflowStep {
        WorkflowStep(kind: .type, text: text)
    }

    static func key(usage: UInt16, mods: UInt8) -> WorkflowStep {
        WorkflowStep(kind: .key, usage: Int(usage), mods: Int(mods))
    }

    static func button(_ name: String) -> WorkflowStep {
        WorkflowStep(kind: .button, name: name)
    }

    static func wait(_ ms: Int) -> WorkflowStep {
        WorkflowStep(kind: .wait, ms: max(0, ms))
    }

    private init(
        kind: Kind,
        x: Double? = nil, y: Double? = nil,
        x1: Double? = nil, y1: Double? = nil,
        text: String? = nil,
        usage: Int? = nil, mods: Int? = nil,
        name: String? = nil, ms: Int? = nil
    ) {
        self.kind = kind
        self.x = x; self.y = y; self.x1 = x1; self.y1 = y1
        self.text = text; self.usage = usage; self.mods = mods
        self.name = name; self.ms = ms
    }

    var summary: String {
        switch kind {
        case .tap:
            return String(format: "Tap %.0f%%, %.0f%%", (x ?? 0) * 100, (y ?? 0) * 100)
        case .swipe:
            return String(
                format: "Swipe %.0f%%,%.0f%% → %.0f%%,%.0f%%",
                (x ?? 0) * 100, (y ?? 0) * 100,
                (x1 ?? 0) * 100, (y1 ?? 0) * 100
            )
        case .type:
            return "Type “\(text ?? "")”"
        case .key:
            return "Key usage \(usage ?? 0)"
        case .button:
            return "Button \(name ?? "?")"
        case .wait:
            return "Pause \(Self.formatMilliseconds(ms ?? 0))"
        }
    }

    var title: String {
        switch kind {
        case .tap: return "Tap"
        case .swipe: return "Swipe"
        case .type: return "Type"
        case .key: return "Key"
        case .button: return (name ?? "Button").capitalized
        case .wait: return "Pause"
        }
    }

    var detail: String {
        switch kind {
        case .tap:
            return String(format: "%.0f%%, %.0f%%", (x ?? 0) * 100, (y ?? 0) * 100)
        case .swipe:
            return String(
                format: "%.0f%%,%.0f%% → %.0f%%,%.0f%%",
                (x ?? 0) * 100, (y ?? 0) * 100,
                (x1 ?? 0) * 100, (y1 ?? 0) * 100
            )
        case .type:
            let value = text ?? ""
            return value.count > 28 ? String(value.prefix(26)) + "…" : value
        case .key:
            return "usage \(usage ?? 0)"
        case .button:
            return name ?? "?"
        case .wait:
            return Self.formatMilliseconds(ms ?? 0)
        }
    }

    var symbolName: String {
        switch kind {
        case .tap: return "hand.tap.fill"
        case .swipe: return "hand.draw.fill"
        case .type: return "keyboard.fill"
        case .key: return "key.fill"
        case .button:
            switch name {
            case "home": return "house.fill"
            case "lock": return "lock.fill"
            case "apps": return "square.stack.3d.up.fill"
            case "volume-up": return "speaker.plus.fill"
            case "volume-down": return "speaker.minus.fill"
            case "screenshot": return "camera.fill"
            case "cc": return "switch.2"
            default: return "button.programmable"
            }
        case .wait: return "pause.circle.fill"
        }
    }

    var accent: NSColor {
        switch kind {
        case .tap: return .systemBlue
        case .swipe: return .systemOrange
        case .type: return .systemPurple
        case .key: return .systemTeal
        case .button: return .systemIndigo
        case .wait: return .systemGray
        }
    }

    private static func formatMilliseconds(_ milliseconds: Int) -> String {
        if milliseconds >= 1_000 {
            return String(format: "%.1fs", Double(milliseconds) / 1_000)
        }
        return "\(milliseconds) ms"
    }
}

/// Latency compensation shared by workflow recording and playback.
enum WorkflowTiming {
    static var latencyProvider: (() -> (p50: Double, p95: Double))?

    static func roundTripMilliseconds(fallback: Int? = nil) -> Int {
        if let latency = latencyProvider?() {
            let live = Int(max(latency.p95, latency.p50, 0))
            if live > 0 { return live }
        }
        return max(0, fallback ?? 0)
    }

    static func oneWayMilliseconds(fallback: Int? = nil) -> Int {
        max(0, roundTripMilliseconds(fallback: fallback) / 2)
    }

    static func normalizeRecordedGap(_ gap: Int, fallback: Int? = nil) -> Int {
        max(0, gap - oneWayMilliseconds(fallback: fallback))
    }

    static func playbackWait(_ recorded: Int, fallback: Int? = nil) -> Int {
        max(40, recorded - oneWayMilliseconds(fallback: fallback))
    }

    static func postTapSettle(fallback: Int? = nil) -> Int {
        max(120, roundTripMilliseconds(fallback: fallback) + 80)
    }

    static func postButtonSettle(fallback: Int? = nil) -> Int {
        max(100, roundTripMilliseconds(fallback: fallback) + 60)
    }
}

/// Records manual phone input into a bounded, serializable workflow.
final class WorkflowRecorder {
    static let shared = WorkflowRecorder()
    private static let maxTypeBufferCharacters = 8_192

    private(set) var isRecording = false
    private(set) var steps: [WorkflowStep] = []
    private var lastEventAt = Date()
    private var downUV: (Double, Double)?
    private var downAt: Date?
    private var typeBuffer = ""
    private var typeFlushWork: DispatchWorkItem?
    private var recordedLatencyP95 = 0

    var onChanged: (() -> Void)?
    var onStepAdded: ((WorkflowStep, Int) -> Void)?

    private init() {}

    func start() {
        flushType()
        steps.removeAll(keepingCapacity: true)
        isRecording = true
        lastEventAt = Date()
        recordedLatencyP95 = WorkflowTiming.roundTripMilliseconds()
        downUV = nil
        downAt = nil
        onChanged?()
    }

    func stop() -> Workflow {
        flushType()
        isRecording = false
        let workflow = Workflow(
            name: "Recording \(Self.timestamp())",
            steps: steps,
            latencyP95Ms: recordedLatencyP95 > 0 ? recordedLatencyP95 : nil
        )
        onChanged?()
        return workflow
    }

    func touchDown(nx: Double, ny: Double) {
        guard isRecording else { return }
        flushType()
        noteWaitGap()
        downUV = (nx, ny)
        downAt = Date()
    }

    func touchUp(nx: Double, ny: Double) {
        guard isRecording, let start = downUV else { return }
        let held = Date().timeIntervalSince(downAt ?? Date())
        if abs(nx - start.0) + abs(ny - start.1) < 0.03, held < 0.45 {
            append(.tap(x: start.0, y: start.1))
        } else {
            append(.swipe(
                x0: start.0,
                y0: start.1,
                x1: nx,
                y1: ny,
                ms: Int(max(0.15, held) * 1_000)
            ))
        }
        downUV = nil
        downAt = nil
        lastEventAt = Date()
    }

    func typed(_ text: String) {
        guard isRecording, !text.isEmpty else { return }
        noteWaitGap(minimum: 120)
        if typeBuffer.count + text.count > Self.maxTypeBufferCharacters {
            flushType()
        }
        typeBuffer += String(text.prefix(Self.maxTypeBufferCharacters))
        if typeBuffer.count > Self.maxTypeBufferCharacters {
            typeBuffer = String(typeBuffer.prefix(Self.maxTypeBufferCharacters))
        }
        typeFlushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushType() }
        typeFlushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        lastEventAt = Date()
    }

    func specialKey(usage: UInt16, mods: UInt8) {
        guard isRecording else { return }
        flushType()
        noteWaitGap()
        append(.key(usage: usage, mods: mods))
        lastEventAt = Date()
    }

    func button(_ name: String) {
        guard isRecording else { return }
        let excluded: Set<String> = [
            "workflow", "agent", "settings", "perf",
            "screenshot", "record", "pasteclip", "music", "instant",
        ]
        guard !excluded.contains(name) else { return }
        flushType()
        noteWaitGap()
        append(.button(name))
        lastEventAt = Date()
    }

    private func noteWaitGap(minimum: Int = 80) {
        let elapsed = Int(Date().timeIntervalSince(lastEventAt) * 1_000)
        let normalized = WorkflowTiming.normalizeRecordedGap(
            elapsed,
            fallback: recordedLatencyP95
        )
        if normalized >= minimum {
            append(.wait(min(normalized, 5_000)))
        }
        lastEventAt = Date()
    }

    private func append(_ step: WorkflowStep) {
        // A corrupted input stream must not make an unbounded in-memory recording.
        guard steps.count < 2_048 else { return }
        steps.append(step)
        onChanged?()
        onStepAdded?(step, steps.count - 1)
    }

    private func flushType() {
        typeFlushWork?.cancel()
        typeFlushWork = nil
        guard !typeBuffer.isEmpty else { return }
        append(.type(typeBuffer))
        typeBuffer = ""
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: Date())
    }
}

/// Executes control steps for workflows, the loopback API, and the AI agent.
final class WorkflowPlayer {
    static let shared = WorkflowPlayer()

    private(set) var isPlaying = false
    private(set) var currentWorkflow: Workflow?
    private var playbackTask: Task<Void, Never>?
    private var playbackLatencyP95 = 0
    private var playbackWaiters: [CheckedContinuation<Bool, Never>] = []
    private var lastPlaybackResult: Bool?

    var onStarted: ((Workflow) -> Void)?
    var onProgress: ((Int, Int, String) -> Void)?
    var onFinished: ((Bool) -> Void)?
    var onStepHighlight: ((WorkflowStep, Int) -> Void)?

    private init() {}

    func play(
        _ workflow: Workflow,
        control: ControlClient,
        touchMode: TouchMap.Mode = .portrait
    ) {
        guard !isPlaying else { return }
        isPlaying = true
        currentWorkflow = workflow
        lastPlaybackResult = nil
        playbackLatencyP95 = workflow.latencyP95Ms ?? 0
        let steps = workflow.steps
        let fallback = playbackLatencyP95 > 0 ? playbackLatencyP95 : nil
        onStarted?(workflow)
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var completed = true
            do {
                for (index, step) in steps.enumerated() {
                    try Task.checkCancellation()
                    self.onStepHighlight?(step, index)
                    self.onProgress?(index + 1, steps.count, step.summary)
                    try await self.run(
                        step,
                        control: control,
                        mode: touchMode,
                        cancellable: true,
                        latencyFallback: fallback
                    )
                }
            } catch {
                completed = false
            }
            self.isPlaying = false
            self.playbackTask = nil
            self.lastPlaybackResult = completed
            self.onFinished?(completed)
            let waiters = self.playbackWaiters
            self.playbackWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters {
                waiter.resume(returning: completed)
            }
            self.currentWorkflow = nil
        }
    }

    func cancel() {
        playbackTask?.cancel()
    }

    func waitForCompletion() async -> Bool {
        if !isPlaying {
            return lastPlaybackResult ?? false
        }
        return await withCheckedContinuation { continuation in
            playbackWaiters.append(continuation)
        }
    }

    @MainActor
    func execute(_ step: WorkflowStep, control: ControlClient, mode: TouchMap.Mode) async {
        try? await run(
            step,
            control: control,
            mode: mode,
            cancellable: false,
            latencyFallback: nil
        )
    }

    /// Agent actions use this path so pressing Stop interrupts at the next HID
    /// boundary instead of allowing a macro or typing loop to continue.
    @MainActor
    func executeCancellable(
        _ step: WorkflowStep,
        control: ControlClient,
        mode: TouchMap.Mode
    ) async throws {
        try await run(
            step,
            control: control,
            mode: mode,
            cancellable: true,
            latencyFallback: nil
        )
    }

    @MainActor
    func runType(_ text: String, control: ControlClient, resetBefore: Bool = true) async {
        try? await runType(
            text,
            control: control,
            resetBefore: resetBefore,
            cancellable: false
        )
    }

    @MainActor
    func runTypeCancellable(
        _ text: String,
        control: ControlClient,
        resetBefore: Bool = true
    ) async throws {
        try await runType(
            text,
            control: control,
            resetBefore: resetBefore,
            cancellable: true
        )
    }

    /// Agent-generated text should preserve exact characters such as email
    /// punctuation. Send explicit characters to the HID engine instead of
    /// pretranslating them with a possibly-wrong app-side keyboard layout.
    @MainActor
    func runExactTextCancellable(
        _ text: String,
        control: ControlClient,
        resetBefore: Bool = true
    ) async throws {
        try await runExactText(
            text,
            control: control,
            resetBefore: resetBefore,
            cancellable: true
        )
    }

    @MainActor
    private func runType(
        _ text: String,
        control: ControlClient,
        resetBefore: Bool,
        cancellable: Bool
    ) async throws {
        try checkpoint(cancellable)
        if resetBefore {
            control.keyboardReset()
            try await pause(60_000_000, cancellable: cancellable)
        }
        for ch in text {
            try checkpoint(cancellable)
            let glyph = String(ch)
            if let chord = KeyboardTranslator.resolve(glyph, hostMods: 0) {
                try await sendKey(
                    usage: chord.usage,
                    character: glyph,
                    mods: chord.mods,
                    control: control,
                    cancellable: cancellable
                )
            } else if KeyboardTranslator.pasteUnmapped {
                for chord in KeyboardTranslator.pasteChords(glyph) {
                    try await sendKey(
                        usage: chord.usage,
                        character: glyph,
                        mods: chord.mods,
                        control: control,
                        cancellable: cancellable
                    )
                }
                control.keyboardReset()
            }
            try await pause(55_000_000, cancellable: cancellable)
        }
        try await pause(120_000_000, cancellable: cancellable)
    }

    @MainActor
    private func runExactText(
        _ text: String,
        control: ControlClient,
        resetBefore: Bool,
        cancellable: Bool
    ) async throws {
        try checkpoint(cancellable)
        if resetBefore {
            control.keyboardReset()
            try await pause(60_000_000, cancellable: cancellable)
        }
        for ch in text {
            try checkpoint(cancellable)
            try await sendKey(
                usage: 0,
                character: String(ch),
                mods: 0,
                control: control,
                cancellable: cancellable
            )
            try await pause(55_000_000, cancellable: cancellable)
        }
        try await pause(120_000_000, cancellable: cancellable)
    }

    @MainActor
    private func run(
        _ step: WorkflowStep,
        control: ControlClient,
        mode: TouchMap.Mode,
        cancellable: Bool,
        latencyFallback: Int?
    ) async throws {
        try checkpoint(cancellable)
        switch step.kind {
        case .wait:
            let wait = latencyFallback == nil
                ? max(40, step.ms ?? 0)
                : WorkflowTiming.playbackWait(step.ms ?? 0, fallback: latencyFallback)
            let ms = UInt64(wait)
            if ms > 0 {
                try await pause(ms * 1_000_000, cancellable: cancellable)
            }
        case .tap:
            let (x, y) = hid(step.x ?? 0.5, step.y ?? 0.5, mode: mode)
            control.keyboardReset()
            try await pause(40_000_000, cancellable: cancellable)
            control.tap(x: x, y: y)
            let settle = latencyFallback == nil
                ? 200
                : WorkflowTiming.postTapSettle(fallback: latencyFallback)
            try await pause(UInt64(settle) * 1_000_000, cancellable: cancellable)
        case .swipe:
            let (x0, y0) = hid(step.x ?? 0.5, step.y ?? 0.5, mode: mode)
            let (x1, y1) = hid(step.x1 ?? 0.5, step.y1 ?? 0.5, mode: mode)
            let ms = max(120, step.ms ?? 280)
            let frames = max(6, ms / 16)
            var releaseX = x0
            var releaseY = y0
            var gestureActive = true
            control.touch(type: "contact", x: x0, y: y0)
            defer {
                // Always end an in-flight gesture, including cancellation.
                if gestureActive {
                    control.touch(type: "release", x: releaseX, y: releaseY)
                }
            }
            for i in 1...frames {
                try checkpoint(cancellable)
                let t = Double(i) / Double(frames)
                let x = Int(Double(x0) + (Double(x1 - x0) * t))
                let y = Int(Double(y0) + (Double(y1 - y0) * t))
                releaseX = x
                releaseY = y
                control.touch(type: "contact", x: x, y: y)
                try await pause(
                    UInt64(ms) * 1_000_000 / UInt64(frames),
                    cancellable: cancellable
                )
            }
            releaseX = x1
            releaseY = y1
            control.touch(type: "release", x: x1, y: y1)
            gestureActive = false
            let settle = latencyFallback == nil
                ? 200
                : WorkflowTiming.postTapSettle(fallback: latencyFallback)
            try await pause(UInt64(settle) * 1_000_000, cancellable: cancellable)
        case .type:
            try await runType(
                step.text ?? "",
                control: control,
                resetBefore: true,
                cancellable: cancellable
            )
        case .key:
            let usage = UInt16(step.usage ?? 0)
            let mods = UInt8(step.mods ?? 0)
            if mods == 0 {
                control.keyboardReset()
                try await pause(20_000_000, cancellable: cancellable)
            }
            try await sendKey(
                usage: usage,
                character: "",
                mods: mods,
                control: control,
                cancellable: cancellable,
                holdNanoseconds: 50_000_000
            )
            control.keyboardReset()
            try await pause(40_000_000, cancellable: cancellable)
        case .button:
            try checkpoint(cancellable)
            switch step.name {
            case "apps": control.appsSwitcher()
            case "cc": control.controlCenter()
            case let name?: control.button(name)
            default: break
            }
            let settle = latencyFallback == nil
                ? 180
                : WorkflowTiming.postButtonSettle(fallback: latencyFallback)
            try await pause(UInt64(settle) * 1_000_000, cancellable: cancellable)
        }
    }

    @MainActor
    private func sendKey(
        usage: UInt16,
        character: String,
        mods: UInt8,
        control: ControlClient,
        cancellable: Bool,
        holdNanoseconds: UInt64 = 45_000_000
    ) async throws {
        try checkpoint(cancellable)
        control.key(down: true, usage: usage, character: character, mods: mods)
        defer {
            // A cancelled hold must never leave a key logically pressed.
            control.key(down: false, usage: usage, character: character, mods: mods)
        }
        try await pause(holdNanoseconds, cancellable: cancellable)
    }

    private func checkpoint(_ cancellable: Bool) throws {
        if cancellable {
            try Task.checkCancellation()
        }
    }

    private func pause(_ nanoseconds: UInt64, cancellable: Bool) async throws {
        if cancellable {
            try await Task.sleep(nanoseconds: nanoseconds)
        } else {
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    private func hid(_ nx: Double, _ ny: Double, mode: TouchMap.Mode) -> (Int, Int) {
        let (hx, hy) = TouchMap.digitizerUV(nx: CGFloat(nx), ny: CGFloat(ny), mode: mode)
        return (TouchMap.quantize(hx), TouchMap.quantize(hy))
    }
}

/// Durable workflow library. Development builds use the repository's
/// `Workflows` directory; packaged builds use the user's Documents folder.
enum WorkflowStore {
    private static let maxFileBytes = 2 * 1_024 * 1_024
    private static let maxSteps = 2_048
    private static let maxListedWorkflows = 512
    private static let allowedButtons: Set<String> = [
        "home", "lock", "apps", "cc", "volume-up", "volume-down", "mute",
    ]

    static var onLibraryChanged: (() -> Void)?

    static var directory: URL {
        if let overridden = ProcessInfo.processInfo.environment["MIRRORUE_WORKFLOWS_DIR"],
           !overridden.isEmpty {
            return ensured(URL(fileURLWithPath: overridden, isDirectory: true))
        }
        if let development = developmentDirectory() {
            return ensured(development)
        }
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return ensured(
            documents
                .appendingPathComponent("MirrorUE", isDirectory: true)
                .appendingPathComponent("Workflows", isDirectory: true)
        )
    }

    static func safeName(_ name: String) -> String {
        let clean = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return clean.isEmpty ? "Workflow" : String(clean.prefix(120))
    }

    static func url(forName name: String) -> URL {
        directory.appendingPathComponent("\(safeName(name)).json")
    }

    static func load(named name: String) throws -> Workflow {
        try load(from: url(forName: name))
    }

    static func load(from url: URL) throws -> Workflow {
        let source = try validatedManagedFileURL(url)
        let values = try source.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw WorkflowStoreError.invalidFile
        }
        guard let fileSize = values.fileSize, fileSize <= maxFileBytes else {
            throw WorkflowStoreError.fileTooLarge
        }

        // Read one byte beyond the limit so a file replaced after the metadata
        // check still cannot cause an unbounded allocation.
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
        guard data.count <= maxFileBytes else {
            throw WorkflowStoreError.fileTooLarge
        }
        let workflow = try JSONDecoder().decode(Workflow.self, from: data)
        try validate(workflow)
        return workflow
    }

    @discardableResult
    static func save(_ workflow: Workflow) throws -> URL {
        try validate(workflow)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workflow)
        guard data.count <= maxFileBytes else {
            throw WorkflowStoreError.fileTooLarge
        }
        let destination = url(forName: workflow.name)
        try data.write(to: destination, options: .atomic)
        onLibraryChanged?()
        return destination
    }

    static func export(named name: String, to destination: URL) throws -> URL {
        let workflow = try load(named: name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workflow)
        let output = destination.pathExtension.lowercased() == "json"
            ? destination
            : destination.appendingPathComponent("\(safeName(name)).json")
        try data.write(to: output, options: .atomic)
        return output
    }

    static func delete(named name: String) throws {
        let fileURL = url(forName: name)
        let validated = try validatedManagedFileURL(fileURL)
        if FileManager.default.fileExists(atPath: validated.path) {
            try FileManager.default.removeItem(at: validated)
            onLibraryChanged?()
        }
    }

    static func list() -> [URL] {
        let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return (urls ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted {
                let lhs = (try? $0.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
            .prefix(maxListedWorkflows)
            .map { $0 }
    }

    static func listSummaries() -> [[String: Any]] {
        list().compactMap { url in
            guard let workflow = try? load(from: url) else { return nil }
            return [
                "name": workflow.name,
                "file": url.lastPathComponent,
                "path": url.path,
                "steps": workflow.steps.count,
                "createdAt": workflow.createdAt,
            ]
        }
    }

    private static func validatedManagedFileURL(_ url: URL) throws -> URL {
        let lexicalRoot = directory.standardizedFileURL
        let lexicalCandidate = url.standardizedFileURL
        guard contains(lexicalCandidate, in: lexicalRoot) else {
            throw WorkflowStoreError.importBlocked
        }
        let lexicalValues = try lexicalCandidate.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        guard lexicalValues.isSymbolicLink != true else {
            throw WorkflowStoreError.invalidFile
        }

        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = lexicalCandidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard contains(resolvedCandidate, in: resolvedRoot) else {
            throw WorkflowStoreError.importBlocked
        }
        return resolvedCandidate
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.path
        let candidatePath = candidate.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func validate(_ workflow: Workflow) throws {
        let trimmedName = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let validNameScalars = trimmedName.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7f
        }
        guard workflow.version == 1,
              !trimmedName.isEmpty,
              validNameScalars,
              trimmedName.count <= 120,
              trimmedName.utf8.count <= 480,
              !workflow.createdAt.isEmpty,
              workflow.createdAt.utf8.count <= 64,
              ISO8601DateFormatter().date(from: workflow.createdAt) != nil,
              workflow.latencyP95Ms.map({ (0...60_000).contains($0) }) ?? true else {
            throw WorkflowStoreError.invalidWorkflow
        }
        guard workflow.steps.count <= maxSteps else {
            throw WorkflowStoreError.tooManySteps
        }
        var totalTypedCharacters = 0
        var totalTypedBytes = 0
        for (index, step) in workflow.steps.enumerated() {
            let valid: Bool
            switch step.kind {
            case .tap:
                valid = validCoordinate(step.x) && validCoordinate(step.y)
            case .swipe:
                valid = validCoordinate(step.x)
                    && validCoordinate(step.y)
                    && validCoordinate(step.x1)
                    && validCoordinate(step.y1)
                    && (120...10_000).contains(step.ms ?? -1)
            case .type:
                let count = step.text?.count ?? -1
                let byteCount = step.text?.utf8.count ?? -1
                let validScalars = step.text?.unicodeScalars.allSatisfy {
                    $0.value >= 0x20 || $0 == "\n" || $0 == "\t"
                } ?? false
                totalTypedCharacters += max(0, count)
                totalTypedBytes += max(0, byteCount)
                valid = validScalars
                    && (0...8_192).contains(count)
                    && (0...32_768).contains(byteCount)
                    && totalTypedCharacters <= 65_536
                    && totalTypedBytes <= 262_144
            case .key:
                valid = (1...Int(UInt16.max)).contains(step.usage ?? -1)
                    && (0...Int(UInt8.max)).contains(step.mods ?? -1)
            case .button:
                valid = allowedButtons.contains(step.name ?? "")
            case .wait:
                valid = (0...60_000).contains(step.ms ?? -1)
            }
            guard valid else {
                throw WorkflowStoreError.invalidStep(index + 1)
            }
        }
    }

    private static func validCoordinate(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value.isFinite && (0...1).contains(value)
    }

    private static func developmentDirectory() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        var cursor = executable.deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(
                atPath: cursor.appendingPathComponent("Package.swift").path
            ) {
                return cursor.appendingPathComponent("Workflows", isDirectory: true)
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return nil
    }

    private static func ensured(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

enum WorkflowStoreError: LocalizedError {
    case importBlocked
    case invalidFile
    case fileTooLarge
    case tooManySteps
    case invalidWorkflow
    case invalidStep(Int)

    var errorDescription: String? {
        switch self {
        case .importBlocked:
            return "Workflows can only be loaded from MirrorUE's workflow library."
        case .invalidFile:
            return "The workflow must be a regular JSON file, not a symbolic link."
        case .fileTooLarge:
            return "The workflow file exceeds the 2 MB limit."
        case .tooManySteps:
            return "A workflow can contain at most 2,048 steps."
        case .invalidWorkflow:
            return "The workflow metadata is invalid or exceeds its safety limit."
        case .invalidStep(let index):
            return "Workflow step \(index) is invalid or exceeds its safety limit."
        }
    }
}
