import Foundation
import ControlKit

/// Serializable automation workflow (record → JSON → replay).
struct Workflow: Codable, Equatable {
    var name: String
    var version: Int
    var createdAt: String
    var steps: [WorkflowStep]

    init(name: String, steps: [WorkflowStep] = []) {
        self.name = name
        self.version = 1
        self.createdAt = ISO8601DateFormatter().string(from: Date())
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
        case .wait: return "Wait \(ms ?? 0) ms"
        }
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

    var onChanged: (() -> Void)?

    private init() {}

    func start() {
        flushType()
        steps.removeAll()
        isRecording = true
        lastEventAt = Date()
        downUV = nil
        onChanged?()
    }

    func stop() -> Workflow {
        flushType()
        isRecording = false
        let wf = Workflow(name: "Recording \(Self.stamp())", steps: steps)
        onChanged?()
        return wf
    }

    func noteWaitGap(minMs: Int = 80) {
        guard isRecording else { return }
        let gap = Int(Date().timeIntervalSince(lastEventAt) * 1000)
        if gap >= minMs {
            steps.append(.wait(min(gap, 5000)))
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
            steps.append(.tap(x: start.0, y: start.1))
        } else {
            let ms = Int(max(0.15, held) * 1000)
            steps.append(.swipe(x0: start.0, y0: start.1, x1: nx, y1: ny, ms: ms))
        }
        downUV = nil
        downAt = nil
        lastEventAt = Date()
        onChanged?()
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
        steps.append(.key(usage: usage, mods: mods))
        lastEventAt = Date()
        onChanged?()
    }

    func button(_ name: String) {
        guard isRecording else { return }
        // Don't record workflow UI itself.
        let skip: Set<String> = ["workflow", "settings", "perf", "screenshot", "record", "pasteclip"]
        guard !skip.contains(name) else { return }
        flushType()
        noteWaitGap()
        steps.append(.button(name))
        lastEventAt = Date()
        onChanged?()
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
        steps.append(.type(typeBuffer))
        typeBuffer = ""
        onChanged?()
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
    var onProgress: ((Int, Int, String) -> Void)?
    var onFinished: ((Bool) -> Void)?

    private init() {}

    func cancel() {
        cancelFlag = true
    }

    func play(_ workflow: Workflow, control: ControlClient, touchMode: TouchMap.Mode = .portrait) {
        guard !isPlaying else { return }
        isPlaying = true
        cancelFlag = false
        let steps = workflow.steps
        let mode = touchMode
        Task { @MainActor in
            for (i, step) in steps.enumerated() {
                if cancelFlag { break }
                onProgress?(i + 1, steps.count, step.summary)
                await execute(step, control: control, mode: mode)
            }
            let ok = !cancelFlag
            isPlaying = false
            onFinished?(ok)
        }
    }

    /// Public single-step runner for the local HTTP API.
    @MainActor
    func execute(_ step: WorkflowStep, control: ControlClient, mode: TouchMap.Mode) async {
        await run(step, control: control, mode: mode)
    }

    @MainActor
    private func run(_ step: WorkflowStep, control: ControlClient, mode: TouchMap.Mode) async {
        switch step.kind {
        case .wait:
            let ms = UInt64(step.ms ?? 0)
            if ms > 0 { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        case .tap:
            let (x, y) = hid(step.x ?? 0.5, step.y ?? 0.5, mode: mode)
            control.touch(type: "contact", x: x, y: y)
            try? await Task.sleep(nanoseconds: 40_000_000)
            control.touch(type: "release", x: x, y: y)
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
        case .type:
            let text = step.text ?? ""
            for ch in text {
                if cancelFlag { break }
                if let chord = KeyboardTranslator.resolve(String(ch), hostMods: 0) {
                    control.key(down: true, usage: chord.usage, character: "", mods: chord.mods)
                    control.key(down: false, usage: chord.usage, character: "", mods: chord.mods)
                } else if KeyboardTranslator.pasteUnmapped {
                    for chord in KeyboardTranslator.pasteChords(String(ch)) {
                        control.key(down: true, usage: chord.usage, character: "", mods: chord.mods)
                        control.key(down: false, usage: chord.usage, character: "", mods: chord.mods)
                    }
                    control.keyboardReset()
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        case .key:
            let usage = UInt16(step.usage ?? 0)
            let mods = UInt8(step.mods ?? 0)
            control.key(down: true, usage: usage, character: "", mods: mods)
            try? await Task.sleep(nanoseconds: 40_000_000)
            control.key(down: false, usage: usage, character: "", mods: mods)
        case .button:
            switch step.name {
            case "apps": control.appsSwitcher()
            case "cc": control.controlCenter()
            case let name?: control.button(name)
            default: break
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func hid(_ nx: Double, _ ny: Double, mode: TouchMap.Mode) -> (Int, Int) {
        let (hx, hy) = TouchMap.digitizerUV(nx: CGFloat(nx), ny: CGFloat(ny), mode: mode)
        return (TouchMap.quantize(hx), TouchMap.quantize(hy))
    }
}

enum WorkflowStore {
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent("MirrorUE/Workflows", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ workflow: Workflow) throws -> URL {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(workflow)
        let safe = workflow.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(safe).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func load(from url: URL) throws -> Workflow {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Workflow.self, from: data)
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
