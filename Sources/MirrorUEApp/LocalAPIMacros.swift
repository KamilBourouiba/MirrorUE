import Foundation
import ControlKit

/// Deterministic high-level phone macros for the local HTTP API / CLI.
/// Coordinates are normalized 0…1 (top-left origin, y downward).
enum LocalAPIMacros {
    /// Home Search pill (more reliable over HID than mid-screen swipe).
    static let searchPill = WorkflowStep.tap(x: 0.5, y: 0.82)
    /// Mid-screen pull-down fallback.
    static let spotlightSwipe = WorkflowStep.swipe(x0: 0.5, y0: 0.35, x1: 0.5, y1: 0.78, ms: 380)
    /// Search field — keyboard down (bottom bar).
    static let fieldBottom = WorkflowStep.tap(x: 0.5, y: 0.90)
    /// Search field — keyboard up (mid screen).
    static let fieldKeyboard = WorkflowStep.tap(x: 0.5, y: 0.55)
    /// Clear (×) on the bottom search bar.
    static let clearX = WorkflowStep.tap(x: 0.93, y: 0.90)
    /// First result / Top Hit.
    static let topHit = WorkflowStep.tap(x: 0.18, y: 0.18)
    /// Open button when shown.
    static let openButton = WorkflowStep.tap(x: 0.78, y: 0.90)
    /// Done checkmark if SpringBoard is in jiggle / edit mode.
    static let jiggleDone = WorkflowStep.tap(x: 0.92, y: 0.07)

    @MainActor
    static func sleepMs(_ ms: Int) async {
        let n = max(0, ms)
        if n > 0 { try? await Task.sleep(nanoseconds: UInt64(n) * 1_000_000) }
    }

    @MainActor
    static func run(
        _ steps: [WorkflowStep],
        control: ControlClient,
        mode: TouchMap.Mode
    ) async {
        for step in steps {
            await WorkflowPlayer.shared.runOne(step, control: control, mode: mode)
        }
    }

    /// Leave apps / jiggle and land on SpringBoard.
    /// Prefer the home **gesture** — the HID Home button is unreliable on some builds.
    @MainActor
    static func goHome(control: ControlClient, mode: TouchMap.Mode) async {
        await WorkflowPlayer.shared.runOne(jiggleDone, control: control, mode: mode)
        await sleepMs(150)
        // Edge swipe up ≈ Home gesture on modern iPhones.
        await WorkflowPlayer.shared.runOne(
            .swipe(x0: 0.5, y0: 0.98, x1: 0.5, y1: 0.35, ms: 420),
            control: control, mode: mode
        )
        await sleepMs(550)
        await WorkflowPlayer.shared.runOne(.button("home"), control: control, mode: mode)
        await sleepMs(450)
        await WorkflowPlayer.shared.runOne(
            .swipe(x0: 0.5, y0: 0.98, x1: 0.5, y1: 0.40, ms: 380),
            control: control, mode: mode
        )
        await sleepMs(800)
    }

    /// Open iOS Search (Spotlight) from Home.
    @MainActor
    static func openSpotlight(
        control: ControlClient,
        mode: TouchMap.Mode,
        goHome: Bool = true
    ) async {
        if goHome {
            await self.goHome(control: control, mode: mode)
        }
        // Search pill opens Spotlight with the field + keyboard already focused.
        await WorkflowPlayer.shared.runOne(searchPill, control: control, mode: mode)
        await sleepMs(1200)
    }

    /// Clear Spotlight text without re-tapping the field (keeps keyboard up).
    @MainActor
    static func clearField(control: ControlClient, mode: TouchMap.Mode, backspaces: Int = 12) async {
        control.keyboardReset()
        await sleepMs(50)
        control.key(down: true, usage: 0x9C, character: "", mods: 0)
        await sleepMs(45)
        control.key(down: false, usage: 0x9C, character: "", mods: 0)
        await sleepMs(120)
        let n = max(0, min(20, backspaces))
        for _ in 0..<n {
            control.key(down: true, usage: 42, character: "", mods: 0)
            await sleepMs(40)
            control.key(down: false, usage: 42, character: "", mods: 0)
            await sleepMs(40)
        }
        await sleepMs(180)
    }

    /// Search → clear → type app name → Top Hit / Open / Enter.
    @MainActor
    static func openApp(
        _ appName: String,
        control: ControlClient,
        mode: TouchMap.Mode
    ) async {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else { return }

        await openSpotlight(control: control, mode: mode, goHome: true)
        await clearField(control: control, mode: mode)
        // Field already focused — type without extra field taps or pre-reset.
        await WorkflowPlayer.shared.runType(app, control: control, resetBefore: false)
        await sleepMs(1500)
        await WorkflowPlayer.shared.runOne(topHit, control: control, mode: mode)
        await sleepMs(900)
        await WorkflowPlayer.shared.runOne(openButton, control: control, mode: mode)
        await sleepMs(350)
        await WorkflowPlayer.shared.runOne(.key(usage: 40, mods: 0), control: control, mode: mode)
        await sleepMs(900)
    }
}
