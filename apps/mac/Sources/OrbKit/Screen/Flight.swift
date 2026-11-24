import CoreGraphics
import Foundation

/// The companion's path (mac-screen.md section 5): it follows the pointer, flies to what orb shows along a curve, and
/// flies back. `position` is a pure function of the time, so each screen's display link can ask it every frame.
public struct Flight: Equatable, Sendable {
    /// A fixed point, or the pointer (nil).
    public var to: CGPoint?
    public var from: CGPoint
    public var start: TimeInterval
    public var duration: TimeInterval

    public static let follow = Flight(to: nil, from: .zero, start: 0, duration: 0)

    public init(to: CGPoint?, from: CGPoint, start: TimeInterval, duration: TimeInterval = 0.5) {
        self.to = to
        self.from = from
        self.start = start
        self.duration = duration
    }

    public func landed(at now: TimeInterval) -> Bool { now - start >= duration }

    public func position(at now: TimeInterval, pointer: CGPoint) -> CGPoint {
        let end = to ?? pointer
        guard duration > 0, !landed(at: now) else { return end }
        let t = max(0, (now - start) / duration)
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2  // ease in and out
        // the control point is above the middle of the line, by a third of its length: an arc, not a slide
        let length = hypot(end.x - from.x, end.y - from.y)
        let control = CGPoint(x: (from.x + end.x) / 2, y: (from.y + end.y) / 2 + length / 3)
        let u = 1 - e
        return CGPoint(x: u * u * from.x + 2 * u * e * control.x + e * e * end.x,
                       y: u * u * from.y + 2 * u * e * control.y + e * e * end.y)
    }
}
