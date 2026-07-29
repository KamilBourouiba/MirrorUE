import Foundation
import AppKit
import ControlKit

/// Serializable automation workflow (record → JSON → replay).
struct Workflow: Codable, Equatable {
    var name: String
    var version: Int
    var createdAt: String
    /// Mirror round-trip latency (p95 ms) captured when the path was recorded.
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
    /// Normalized 0…1 coordinates in the phone content rect (top-left origin for docs;
    /// stored as view UV with y increasing downward — same as framebuffer UV).
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
        case .tap: return String(format: "Tap %.0f%%, %.0f%%", (x ?? 0) * 100, (y ?? 0) * 100)
        case .swipe: return String(format: "Swipe %.0f%%,%.0f%% → %.0f%%,%.0f%%",
                                   (x ?? 0) * 100, (y ?? 0) * 100, (x1 ?? 0) * 100, (y1 ?? 0) * 100)
        case .type: return "Type \"\(text ?? "")\""
        case .key: return "Key usage \(usage ?? 0)"
        case .button: return "Button \(name ?? "?")"
        case .wait: return "Pause \(Self.formatMs(ms ?? 0))"
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
            return String(format: "%.0f%%,%.0f%% → %.0f%%,%.0f%%",
                          (x ?? 0) * 100, (y ?? 0) * 100, (x1 ?? 0) * 100, (y1 ?? 0) * 100)
        case .type:
            let t = text ?? ""
            return t.count > 24 ? String(t.prefix(22)) + "…" : t
        case .key:
            return "usage \(usage ?? 0)"
        case .button:
            return name ?? "?"
        case .wait:
            return Self.formatMs(ms ?? 0)
        }
    }

    var symbolName: String {
        switch kind {
        case .tap: return "hand.tap.fill"
        case .swipe: return "hand.draw.fill"
        case .type: return "keyboard.fill"
        case .key: return "key.fill"
        case .button: return Self.buttonSymbol(name)
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

    private static func formatMs(_ ms: Int) -> String {
        if ms >= 1000 { return String(format: "%.1fs", Double(ms) / 1000) }
        return "\(ms) ms"
    }

    private static func buttonSymbol(_ name: String?) -> String {
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
    }
}

/// Latency-aware timing for record / playback (uses live p95 or path metadata).
enum WorkflowTiming {
    static var latencyProvider: (() -> (p50: Double, p95: Double))?

    static func roundTripMs(fallback: Int? = nil) -> Int {
        if let lat = latencyProvider?() {
            let live = Int(max(lat.p95, lat.p50, 0))
            if live > 0 { return live }
        }
        return max(0, fallback ?? 0)
    }

    static func oneWayMs(fallback: Int? = nil) -> Int {
        max(0, roundTripMs(fallback: fallback) / 2)
    }

    static func normalizeRecordedGap(_ gapMs: Int, fallbackLatency: Int? = nil) -> Int {
        max(0, gapMs - oneWayMs(fallback: fallbackLatency))
    }

    static func playbackWait(_ recordedMs: Int, fallbackLatency: Int? = nil) -> Int {
        max(40, recordedMs - oneWayMs(fallback: fallbackLatency))
    }

    static func postTapSettleMs(fallbackLatency: Int? = nil) -> Int {
        max(120, roundTripMs(fallback: fallbackLatency) + 80)
    }

    static func postButtonSettleMs(fallbackLatency: Int? = nil) -> Int {
        max(100, roundTripMs(fallback: fallbackLatency) + 60)
    }
}

/// Records user interactions into a ``Workflow``.
final class WorkflowRecorder {
    static let shared = WorkflowRecorder()

    private(set) var isRecording = false
    private(set) var steps: [WorkflowStep] = []
    private var lastEventAt = Date()
    private var downUV: (Double, Double)?
    private var downAt: Date?
    private var typeBuffer = ""
    private var typeFlushWork: DispatchWorkItem?
    private var recordLatencyP95Ms = 0

    var onChanged: (() -> Void)?
    var onStepAdded: ((WorkflowStep, Int) -> Void)?

    private init() {}

    private func append(_ step: WorkflowStep) {
        steps.append(step)
        let index = steps.count - 1
        onChanged?()
        onStepAdded?(step, index)
    }

    func start() {
        flushType()
        steps.removeAll()
        isRecording = true
        lastEventAt = Date()
        recordLatencyP95Ms = WorkflowTiming.roundTripMs()
        downUV = nil
        onChanged?()
    }

    func stop() -> Workflow {
        flushType()
        isRecording = false
        let wf = Workflow(
            name: "Recording \(Self.stamp())",
            steps: steps,
            latencyP95Ms: recordLatencyP95Ms > 0 ? recordLatencyP95Ms : nil
        )
        onChanged?()
        return wf
    }

    func noteWaitGap(minMs: Int = 80) {
        guard isRecording else { return }
        let gap = Int(Date().timeIntervalSince(lastEventAt) * 1000)
        let net = WorkflowTiming.normalizeRecordedGap(gap, fallbackLatency: recordLatencyP95Ms)
        if net >= minMs {
            append(.wait(min(net, 5000)))
        }
        lastEventAt = Date()
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
        let dx = abs(nx - start.0)
        let dy = abs(ny - start.1)
        let held = Date().timeIntervalSince(downAt ?? Date())
        if dx + dy < 0.03 && held < 0.45 {
            append(.tap(x: start.0, y: start.1))
        } else {
            let ms = Int(max(0.15, held) * 1000)
            append(.swipe(x0: start.0, y0: start.1, x1: nx, y1: ny, ms: ms))
        }
        downUV = nil
        downAt = nil
        lastEventAt = Date()
    }

    func typed(_ text: String) {
        guard isRecording, !text.isEmpty else { return }
        noteWaitGap(minMs: 120)
        typeBuffer += text
        scheduleTypeFlush()
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
        let skip: Set<String> = ["workflow", "agent", "settings", "perf", "screenshot", "record", "pasteclip"]
        guard !skip.contains(name) else { return }
        flushType()
        noteWaitGap()
        append(.button(name))
        lastEventAt = Date()
    }

    private func scheduleTypeFlush() {
        typeFlushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushType() }
        typeFlushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func flushType() {
        typeFlushWork?.cancel()
        typeFlushWork = nil
        guard !typeBuffer.isEmpty else { return }
        append(.type(typeBuffer))
        typeBuffer = ""
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f.string(from: Date())
    }
}

/// Plays a ``Workflow`` through ``ControlClient``.
final class WorkflowPlayer {
    static let shared = WorkflowPlayer()

    private(set) var isPlaying = false
    private var cancelFlag = false
    private var playbackLatencyP95Ms = 0

    var onProgress: ((Int, Int, String) -> Void)?
    var onFinished: ((Bool) -> Void)?
    var onStepHighlight: ((WorkflowStep, Int) -> Void)?

    private init() {}

    func cancel() {
        cancelFlag = true
    }

    func play(_ workflow: Workflow, control: ControlClient, touchMode: TouchMap.Mode = .portrait) {
        guard !isPlaying else { return }
        isPlaying = true
        cancelFlag = false
        playbackLatencyP95Ms = workflow.latencyP95Ms ?? 0
        let steps = workflow.steps
        let mode = touchMode
        let latFallback = playbackLatencyP95Ms > 0 ? playbackLatencyP95Ms : nil
        Task { @MainActor in
            for (i, step) in steps.enumerated() {
                if cancelFlag { break }
                onStepHighlight?(step, i)
                onProgress?(i + 1, steps.count, step.summary)
                await execute(step, control: control, mode: mode, latencyFallback: latFallback)
            }
            let ok = !cancelFlag
            isPlaying = false
            onFinished?(ok)
        }
    }

    @MainActor
    func execute(
        _ step: WorkflowStep,
        control: ControlClient,
        mode: TouchMap.Mode,
        latencyFallback: Int? = nil
    ) async {
        let lat = latencyFallback ?? (playbackLatencyP95Ms > 0 ? playbackLatencyP95Ms : nil)
        await run(step, control: control, mode: mode, latencyFallback: lat)
    }

    @MainActor
    func runType(_ text: String, control: ControlClient, resetBefore: Bool = true) async {
        let body = text
        if resetBefore {
            control.keyboardReset()
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        for ch in body {
            if cancelFlag { break }
            let glyph = String(ch)
            if let chord = KeyboardTranslator.resolve(glyph, hostMods: 0) {
                control.key(down: true, usage: chord.usage, character: glyph, mods: chord.mods)
                try? await Task.sleep(nanoseconds: 45_000_000)
                control.key(down: false, usage: chord.usage, character: glyph, mods: chord.mods)
            } else if KeyboardTranslator.pasteUnmapped {
                for chord in KeyboardTranslator.pasteChords(glyph) {
                    control.key(down: true, usage: chord.usage, character: glyph, mods: chord.mods)
                    try? await Task.sleep(nanoseconds: 45_000_000)
                    control.key(down: false, usage: chord.usage, character: glyph, mods: chord.mods)
                }
                control.keyboardReset()
            }
            try? await Task.sleep(nanoseconds: 55_000_000)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    @MainActor
    private func run(
        _ step: WorkflowStep,
        control: ControlClient,
        mode: TouchMap.Mode,
        latencyFallback: Int? = nil
    ) async {
        switch step.kind {
        case .wait:
            let ms = UInt64(WorkflowTiming.playbackWait(step.ms ?? 0, fallbackLatency: latencyFallback))
            if ms > 0 { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        case .tap:
            let (x, y) = hid(step.x ?? 0.5, step.y ?? 0.5, mode: mode)
            control.keyboardReset()
            try? await Task.sleep(nanoseconds: 40_000_000)
            control.tap(x: x, y: y)
            let settle = WorkflowTiming.postTapSettleMs(fallbackLatency: latencyFallback)
            try? await Task.sleep(nanoseconds: UInt64(settle) * 1_000_000)
        case .swipe:
            let (x0, y0) = hid(step.x ?? 0.5, step.y ?? 0.5, mode: mode)
            let (x1, y1) = hid(step.x1 ?? 0.5, step.y1 ?? 0.5, mode: mode)
            let ms = max(120, step.ms ?? 280)
            let frames = max(6, ms / 16)
            control.touch(type: "contact", x: x0, y: y0)
            for i in 1...frames {
                if cancelFlag { break }
                let t = Double(i) / Double(frames)
                let x = Int(Double(x0) + (Double(x1 - x0) * t))
                let y = Int(Double(y0) + (Double(y1 - y0) * t))
                control.touch(type: "contact", x: x, y: y)
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000 / UInt64(frames))
            }
            control.touch(type: "release", x: x1, y: y1)
            let settle = WorkflowTiming.postTapSettleMs(fallbackLatency: latencyFallback)
            try? await Task.sleep(nanoseconds: UInt64(settle) * 1_000_000)
        case .type:
            await runType(step.text ?? "", control: control, resetBefore: true)
        case .key:
            let usage = UInt16(step.usage ?? 0)
            let mods = UInt8(step.mods ?? 0)
            if mods == 0 {
                control.keyboardReset()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            control.key(down: true, usage: usage, character: "", mods: mods)
            try? await Task.sleep(nanoseconds: 50_000_000)
            control.key(down: false, usage: usage, character: "", mods: mods)
            control.keyboardReset()
            try? await Task.sleep(nanoseconds: 40_000_000)
        case .button:
            switch step.name {
            case "apps": control.appsSwitcher()
            case "cc": control.controlCenter()
            case let name?: control.button(name)
            default: break
            }
            let settle = WorkflowTiming.postButtonSettleMs(fallbackLatency: latencyFallback)
            try? await Task.sleep(nanoseconds: UInt64(settle) * 1_000_000)
        }
    }

    private func hid(_ nx: Double, _ ny: Double, mode: TouchMap.Mode) -> (Int, Int) {
        let (hx, hy) = TouchMap.digitizerUV(nx: CGFloat(nx), ny: CGFloat(ny), mode: mode)
        return (TouchMap.quantize(hx), TouchMap.quantize(hy))
    }
}

enum WorkflowStore {
    static var directory: URL {
        if let dir = bundledDirectory(), ensureDirectory(dir) { return dir }
        if let dir = devDirectory(), ensureDirectory(dir) { return dir }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorUE/Workflows", isDirectory: true)
        ensureDirectory(fallback)
        return fallback
    }

    private static func bundledDirectory() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Workflows", isDirectory: true)
    }

    private static func devDirectory() -> URL? {
        guard let exe = Bundle.main.executableURL else { return nil }
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<12 {
            if dir.appendingPathComponent("Package.swift").existsFile {
                return dir.appendingPathComponent("Workflows", isDirectory: true)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    @discardableResult
    private static func ensureDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    static func isManaged(_ url: URL) -> Bool {
        let base = directory.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(base + "/") || url.standardizedFileURL.path == base
    }

    static func safeName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    static func url(forName name: String) -> URL {
        directory.appendingPathComponent("\(safeName(name)).json")
    }

    static func load(named name: String) throws -> Workflow {
        try load(from: url(forName: name))
    }

    static func save(_ workflow: Workflow) throws -> URL {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(workflow)
        let safe = safeName(workflow.name)
        let url = directory.appendingPathComponent("\(safe).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func listSummaries() -> [[String: Any]] {
        list().compactMap { url in
            guard let wf = try? load(from: url) else { return nil }
            return [
                "name": wf.name,
                "file": url.lastPathComponent,
                "path": url.path,
                "steps": wf.steps.count,
                "createdAt": wf.createdAt,
            ] as [String: Any]
        }
    }

    static func load(from url: URL) throws -> Workflow {
        guard isManaged(url) else {
            throw WorkflowStoreError.importBlocked
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Workflow.self, from: data)
    }

    static func export(named name: String, to destination: URL) throws -> URL {
        let wf = try load(named: name)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(wf)
        let out = destination.pathExtension.lowercased() == "json"
            ? destination
            : destination.appendingPathComponent("\(safeName(name)).json")
        try data.write(to: out, options: .atomic)
        return out
    }

    static func list() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        } ?? []
    }
}

enum WorkflowStoreError: LocalizedError {
    case importBlocked

    var errorDescription: String? {
        switch self {
        case .importBlocked:
            return "Paths can only be loaded from the app Workflows folder. Export copies out; import from disk is disabled."
        }
    }
}

private extension URL {
    var existsFile: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
