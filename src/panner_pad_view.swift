//
//  panner_pad_view.swift
//  foo_out_avfoundation
//
//  A 2D positioning pad: listener at the centre, one draggable puck. Reports its position as
//  normalized (-1...1, -1...1) via `onChange`. Used twice in the preferences page — a top-down pad
//  (X = left/right, Y = front/back) and an elevation pad (X = left/right, Y = up/down) — which is
//  the DAW-panner answer to "mouse has 2 DOF, space has 3": split into two unambiguous 2D drags.
//

import AppKit

final class PannerPadView: NSView {

    /// Normalized puck position, -1...1 on each axis. Setting these redraws but does NOT fire onChange.
    var valueX: CGFloat = 0 { didSet { needsDisplay = true } }
    var valueY: CGFloat = 0 { didSet { needsDisplay = true } }

    /// Fired on user drags with the new normalized (x, y).
    var onChange: ((CGFloat, CGFloat) -> Void)?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        NSColor.gridColor.setStroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: bounds.midX, y: 0))
        cross.line(to: CGPoint(x: bounds.midX, y: bounds.maxY))
        cross.move(to: CGPoint(x: 0, y: bounds.midY))
        cross.line(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        cross.stroke()

        // listener at centre
        NSColor.secondaryLabelColor.setFill()
        let lr: CGFloat = 4
        NSBezierPath(ovalIn: CGRect(x: bounds.midX - lr, y: bounds.midY - lr, width: lr * 2, height: lr * 2)).fill()

        // source puck
        let p = pointForValue()
        NSColor.controlAccentColor.setFill()
        let pr: CGFloat = 9
        NSBezierPath(ovalIn: CGRect(x: p.x - pr, y: p.y - pr, width: pr * 2, height: pr * 2)).fill()
    }

    private func pointForValue() -> CGPoint {
        CGPoint(x: bounds.midX + valueX * bounds.width / 2,
                y: bounds.midY + valueY * bounds.height / 2)
    }

    private func updateFromEvent(_ e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        valueX = max(-1, min(1, (pt.x - bounds.midX) / (bounds.width / 2)))
        valueY = max(-1, min(1, (pt.y - bounds.midY) / (bounds.height / 2)))
        onChange?(valueX, valueY)
    }

    override func mouseDown(with event: NSEvent) { updateFromEvent(event) }
    override func mouseDragged(with event: NSEvent) { updateFromEvent(event) }
}
