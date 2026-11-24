import CoreGraphics
import Foundation

/// How orb marks what it shows: a pen's underline, box, marker stroke or loop.
public enum Mark: String, Codable, Sendable { case underline, box, marker, circle }

/// Hand-drawn strokes, after the technique that Rough.js and rough-notation publish: a line is a cubic curve between
/// jittered ends, bowed sideways and drawn twice; a circle is one loop of a little more than a turn through jittered
/// points, so the pen passes its start. A seed makes a mark the same each time it is drawn.
public enum Rough {
    /// The strokes of a mark, in the order a pen draws them, around `rects` (one per line of text, or one picture).
    public static func strokes(_ mark: Mark, around rects: [CGRect], seed: UInt64) -> [CGPath] {
        var rng = Seeded(seed)
        switch mark {
        case .box:
            let r = union(rects).insetBy(dx: -6, dy: -4)
            let corners = [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
                           CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.minY)]
            return (0..<2).flatMap { _ in
                (0..<4).map { i in line(corners[i], corners[(i + 1) % 4], overshoot: 4, &rng) }
            }
        case .underline:
            return rects.map { r in
                line(CGPoint(x: r.minX - 2, y: r.minY - 1), CGPoint(x: r.maxX + 2, y: r.minY - 1), overshoot: 2, &rng)
            }
        case .marker:
            return rects.map { r in
                line(CGPoint(x: r.minX - 3, y: r.midY), CGPoint(x: r.maxX + 3, y: r.midY), overshoot: 0, &rng,
                     bow: 0.6)
            }
        case .circle:
            return [smooth(circlePoints(union(rects), seed: seed))]
        }
    }

    public static func lineWidth(_ mark: Mark, around rects: [CGRect]) -> CGFloat {
        mark == .marker ? max(10, (rects.map(\.height).max() ?? 14) * 0.95) : 2.5
    }

    public static func union(_ rects: [CGRect]) -> CGRect { rects.reduce(CGRect.null) { $0.union($1) } }

    /// A line as a pen draws it: ends off by a little, the middle bowed to one side, sometimes past the corner.
    static func line(_ a: CGPoint, _ b: CGPoint, overshoot: CGFloat, _ rng: inout Seeded, bow: CGFloat = 1)
        -> CGPath {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0 else { return CGMutablePath() }
        let (ux, uy) = ((b.x - a.x) / length, (b.y - a.y) / length)
        let (nx, ny) = (-uy, ux)
        let jitter = min(2.5, length * 0.08)
        func off(_ p: CGPoint, along t: CGFloat) -> CGPoint {
            CGPoint(x: p.x + ux * t + nx * rng.next(jitter), y: p.y + uy * t + ny * rng.next(jitter))
        }
        let start = off(a, along: -rng.unit() * overshoot), end = off(b, along: rng.unit() * overshoot)
        let side = rng.next(min(8, length * 0.015 + 1.5) * bow)
        func at(_ t: CGFloat) -> CGPoint {
            CGPoint(x: start.x + (end.x - start.x) * t + nx * side, y: start.y + (end.y - start.y) * t + ny * side)
        }
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: end, control1: at(0.3 + rng.next(0.05)), control2: at(0.7 + rng.next(0.05)))
        return path
    }

    /// Points around `rect`, padded, a little more than one turn from a random angle, each radius off by a little.
    static func circlePoints(_ rect: CGRect, seed: UInt64) -> [CGPoint] {
        var rng = Seeded(seed &+ 0x9E37)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let (rx, ry) = (rect.width / 2 * 1.18 + 8, rect.height / 2 * 1.22 + 8)
        let steps = 14, sweep = 2 * Double.pi * (1.08 + Double(rng.unit()) * 0.06)
        let start = Double(rng.unit()) * 2 * .pi
        return (0...steps).map { k in
            let t = Double(k) / Double(steps)
            let angle = start + sweep * t
            let scale = 1 + rng.next(0.05) + CGFloat(t) * 0.04  // the end drifts out, so the loop does not close
            return CGPoint(x: c.x + rx * scale * CGFloat(cos(angle)), y: c.y + ry * scale * CGFloat(sin(angle)))
        }
    }

    /// How many turns the points make around their centre.
    static func turns(of points: [CGPoint]) -> Double {
        let cx = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let cy = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        var total = 0.0
        for (p, q) in zip(points, points.dropFirst()) {
            var d = atan2(Double(q.y - cy), Double(q.x - cx)) - atan2(Double(p.y - cy), Double(p.x - cx))
            if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
            total += d
        }
        return abs(total) / (2 * .pi)
    }

    /// A Catmull-Rom curve through the points, as cubic Béziers.
    static func smooth(_ p: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard p.count > 1 else { return path }
        path.move(to: p[0])
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }
}

/// SplitMix64: small, fast, and the same numbers for the same seed.
struct Seeded {
    var state: UInt64

    init(_ seed: UInt64) { state = seed }

    mutating func unit() -> CGFloat {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return CGFloat(Double((z ^ (z >> 31)) >> 11) / Double(1 << 53))
    }

    /// A number in −amount…amount.
    mutating func next(_ amount: CGFloat) -> CGFloat { (unit() * 2 - 1) * amount }
}
