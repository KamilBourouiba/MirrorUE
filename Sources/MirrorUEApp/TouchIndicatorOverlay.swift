import AppKit

/// Visual touch feedback for demos / QA ("show touches").
final class TouchIndicatorOverlay: NSView {
    private let dot = NSView()
    private var fadeWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        isHidden = true

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.45).cgColor
        dot.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        dot.layer?.borderWidth = 2
        dot.layer?.cornerRadius = 22
        dot.frame = NSRect(x: 0, y: 0, width: 44, height: 44)
        addSubview(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(at pointInView: CGPoint, pressing: Bool) {
        isHidden = false
        fadeWork?.cancel()
        let r: CGFloat = pressing ? 48 : 40
        dot.frame = NSRect(x: pointInView.x - r / 2, y: pointInView.y - r / 2, width: r, height: r)
        dot.layer?.cornerRadius = r / 2
        dot.layer?.backgroundColor = (pressing
            ? NSColor.systemBlue.withAlphaComponent(0.55)
            : NSColor.systemBlue.withAlphaComponent(0.35)).cgColor
        alphaValue = 1
    }

    func release(at pointInView: CGPoint) {
        show(at: pointInView, pressing: false)
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self?.animator().alphaValue = 0
            }, completionHandler: {
                self?.isHidden = true
                self?.alphaValue = 1
            })
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func clear() {
        fadeWork?.cancel()
        isHidden = true
    }
}
