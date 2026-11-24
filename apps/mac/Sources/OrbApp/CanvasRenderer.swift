import AppKit
import OrbKit
import OrbUI
import QuartzCore

/// Draws the canvas's annotations that are on one display (screen-canvas.md section 5). It diffs by id: a new
/// annotation animates in, a gone one fades out, an unchanged one is left alone.
@MainActor
final class CanvasRenderer {
    let root = CALayer()
    private let screen: NSScreen
    private var layers: [String: CALayer] = [:]

    init(screen: NSScreen) {
        self.screen = screen
    }

    func render(_ annotations: [Annotation], appearAfter delay: TimeInterval) {
        let here = annotations.filter { $0.anchor.displayID == screen.displayID }
        let ids = Set(here.map(\.id))
        for (id, layer) in layers where !ids.contains(id) {
            layers[id] = nil
            Self.disappear(layer)
        }
        for annotation in here where layers[annotation.id] == nil {
            let layer = RoughMarkLayer.make(annotation, origin: screen.frame.origin, delay: delay)
            root.addSublayer(layer)
            layers[annotation.id] = layer
        }
    }

    static func disappear(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        layer.opacity = 0
        CATransaction.commit()
    }
}

/// A mark drawn by hand: the `Rough` strokes, each a shape layer that a pen draws in, one after another.
enum RoughMarkLayer {
    static func make(_ annotation: Annotation, origin: CGPoint, delay: TimeInterval) -> CALayer {
        let container = CALayer()
        guard case .mark(let mark) = annotation.kind else { return container }
        let rects = annotation.anchor.rects.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
        let marker = mark == .marker
        let ink = NSColor(marker ? Theme.speak2 : Theme.speak).cgColor
        let each = mark == .circle ? 0.55 : marker ? 0.3 : 0.22
        let seed = UInt64(truncatingIfNeeded: annotation.id.hashValue)
        for (i, path) in Rough.strokes(mark, around: rects, seed: seed).enumerated() {
            let stroke = CAShapeLayer()
            stroke.path = path
            stroke.fillColor = nil
            stroke.strokeColor = marker ? ink.copy(alpha: 0.38) : ink
            stroke.lineWidth = Rough.lineWidth(mark, around: rects)
            stroke.lineCap = marker ? .butt : .round
            stroke.lineJoin = .round
            if !marker {
                stroke.shadowColor = ink
                stroke.shadowRadius = 4
                stroke.shadowOpacity = 0.35
                stroke.shadowOffset = .zero
            }
            container.addSublayer(stroke)
            let pen = CABasicAnimation(keyPath: "strokeEnd")
            pen.fromValue = 0
            pen.toValue = 1
            pen.duration = each
            pen.beginTime = CACurrentMediaTime() + delay + Double(i) * each * 0.85
            pen.fillMode = .backwards
            pen.timingFunction = CAMediaTimingFunction(name: .easeOut)
            stroke.add(pen, forKey: "pen")
        }
        return container
    }
}
