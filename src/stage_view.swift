//
//  stage_view.swift
//  foo_out_avfoundation
//
//  Top-down "stage" for arranging the virtual speaker rig: the listener sits at the centre, and the
//  user drags markers around them. Each draggable marker reports its normalized position (-1...1 on
//  each axis; +x = right, +y = front) via `onChange(id, nx, ny)`. The view also draws non-draggable
//  feedback dots for the derived speaker positions. Mouse has 2 DOF and the top-down plane is 2 DOF,
//  so this is unambiguous; height/spacing/elevation that the plane can't express are sliders.
//

import AppKit

struct StageMarker {
    let id: String
    var nx: CGFloat // -1...1, +x = right
    var ny: CGFloat // -1...1, +y = front
    var color: NSColor
    var label: String
}

final class StageView: NSView {

    /// Draggable markers (pair centres + mono speakers).
    var markers: [StageMarker] = [] { didSet { needsDisplay = true } }
    /// Non-draggable feedback dots: derived speaker positions (nx, ny, colour).
    var dots: [(CGFloat, CGFloat, NSColor)] = [] { didSet { needsDisplay = true } }
    /// Fired while dragging a marker: (markerID, nx, ny).
    var onChange: ((String, CGFloat, CGFloat) -> Void)?

    private var draggingIndex: Int?
    private let grabRadius: CGFloat = 20

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let cx = bounds.midX, cy = bounds.midY
        let rx = bounds.width / 2, ry = bounds.height / 2

        // concentric range rings + axis cross
        NSColor.gridColor.setStroke()
        for f: CGFloat in [0.5, 1.0] {
            let path = NSBezierPath(ovalIn: CGRect(x: cx - rx * f, y: cy - ry * f,
                                                   width: rx * 2 * f, height: ry * 2 * f))
            path.stroke()
        }
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: cx, y: 0)); cross.line(to: CGPoint(x: cx, y: bounds.maxY))
        cross.move(to: CGPoint(x: 0, y: cy)); cross.line(to: CGPoint(x: bounds.maxX, y: cy))
        cross.stroke()

        drawLabel("FRONT", at: CGPoint(x: cx, y: bounds.maxY - 12))
        drawLabel("REAR", at: CGPoint(x: cx, y: 6))

        // listener at the centre
        NSColor.secondaryLabelColor.setFill()
        let lr: CGFloat = 5
        NSBezierPath(ovalIn: CGRect(x: cx - lr, y: cy - lr, width: lr * 2, height: lr * 2)).fill()

        // derived speaker dots (feedback)
        for (nx, ny, color) in dots {
            let p = point(nx, ny)
            color.withAlphaComponent(0.55).setFill()
            let r: CGFloat = 5
            NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
        }

        // draggable markers
        for m in markers {
            let p = point(m.nx, m.ny)
            m.color.setFill()
            let r: CGFloat = 9
            NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
            drawLabel(m.label, at: CGPoint(x: p.x, y: p.y - r - 9))
        }
    }

    private func drawLabel(_ s: String, at center: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                             withAttributes: attrs)
    }

    private func point(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
        CGPoint(x: bounds.midX + nx * bounds.width / 2, y: bounds.midY + ny * bounds.height / 2)
    }

    private func normalized(_ p: CGPoint) -> (CGFloat, CGFloat) {
        (max(-1, min(1, (p.x - bounds.midX) / (bounds.width / 2))),
         max(-1, min(1, (p.y - bounds.midY) / (bounds.height / 2))))
    }

    /// Update one marker's position without firing onChange (config -> UI sync).
    func setMarker(id: String, nx: CGFloat, ny: CGFloat) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        markers[i].nx = nx
        markers[i].ny = ny
        needsDisplay = true
    }

    // MARK: - mouse

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        // pick the nearest marker within grab radius
        var best: Int?
        var bestDist = grabRadius
        for (i, m) in markers.enumerated() {
            let mp = point(m.nx, m.ny)
            let d = CGFloat(hypot(Double(mp.x - pt.x), Double(mp.y - pt.y)))
            if d <= bestDist { bestDist = d; best = i }
        }
        draggingIndex = best
        if best != nil { dragTo(pt) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingIndex != nil else { return }
        dragTo(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { draggingIndex = nil }

    private func dragTo(_ pt: CGPoint) {
        guard let i = draggingIndex else { return }
        let (nx, ny) = normalized(pt)
        markers[i].nx = nx
        markers[i].ny = ny
        needsDisplay = true
        onChange?(markers[i].id, nx, ny)
    }
}
