import AppKit

/// Visual touch feedback for demos / QA ("show touches").
final class TouchIndicatorOverlay: NSView {
    private let dot = NSView()
    private let vectorLayer = CAShapeLayer()
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

        vectorLayer.fillColor = NSColor.clear.cgColor
        vectorLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
        vectorLayer.lineWidth = 4
        vectorLayer.lineCap = .round
        vectorLayer.lineJoin = .round
        layer?.addSublayer(vectorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(at pointInView: CGPoint, pressing: Bool) {
        isHidden = false
        fadeWork?.cancel()
        vectorLayer.path = nil
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
        scheduleFade(after: 0.15)
    }

    func showVector(from start: CGPoint, to end: CGPoint, durationMilliseconds: Int) {
        isHidden = false
        fadeWork?.cancel()
        alphaValue = 1
        show(at: start, pressing: true)
        dot.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor

        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 16
        let arrowAngle = CGFloat.pi / 7
        let left = CGPoint(
            x: end.x - arrowLength * cos(angle - arrowAngle),
            y: end.y - arrowLength * sin(angle - arrowAngle)
        )
        let right = CGPoint(
            x: end.x - arrowLength * cos(angle + arrowAngle),
            y: end.y - arrowLength * sin(angle + arrowAngle)
        )
        path.move(to: left)
        path.addLine(to: end)
        path.addLine(to: right)
        vectorLayer.path = path

        scheduleFade(after: max(0.25, Double(durationMilliseconds) / 1_000 + 0.15))
    }

    func clear() {
        fadeWork?.cancel()
        vectorLayer.path = nil
        isHidden = true
    }

    private func scheduleFade(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self?.animator().alphaValue = 0
            }, completionHandler: {
                self?.vectorLayer.path = nil
                self?.isHidden = true
                self?.alphaValue = 1
            })
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
