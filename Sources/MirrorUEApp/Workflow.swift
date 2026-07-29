import Foundation
import ControlKit

/// Single automation step for the local control API (`/v1/do`, tap, type, …).
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
}

/// Executes control steps for the loopback HTTP API.
final class WorkflowPlayer {
    static let shared = WorkflowPlayer()

    private var cancelFlag = false

    private init() {}

    func cancel() {
        cancelFlag = true
    }

    @MainActor
    func execute(_ step: WorkflowStep, control: ControlClient, mode: TouchMap.Mode) async {
        await run(step, control: control, mode: mode)
    }

    @MainActor
    func runType(_ text: String, control: ControlClient, resetBefore: Bool = true) async {
        if resetBefore {
            control.keyboardReset()
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        for ch in text {
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
    private func run(_ step: WorkflowStep, control: ControlClient, mode: TouchMap.Mode) async {
        switch step.kind {
        case .wait:
            let ms = UInt64(max(40, step.ms ?? 0))
            if ms > 0 { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        case .tap:
            let (x, y) = hid(step.x ?? 0.5, step.y ?? 0.5, mode: mode)
            control.keyboardReset()
            try? await Task.sleep(nanoseconds: 40_000_000)
            control.tap(x: x, y: y)
            try? await Task.sleep(nanoseconds: 200_000_000)
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
            try? await Task.sleep(nanoseconds: 200_000_000)
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
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
    }

    private func hid(_ nx: Double, _ ny: Double, mode: TouchMap.Mode) -> (Int, Int) {
        let (hx, hy) = TouchMap.digitizerUV(nx: CGFloat(nx), ny: CGFloat(ny), mode: mode)
        return (TouchMap.quantize(hx), TouchMap.quantize(hy))
    }
}
