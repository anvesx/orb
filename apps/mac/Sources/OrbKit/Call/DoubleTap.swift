import Foundation

/// Two quick taps of one modifier key alone (⌥ by default), with no other key between: the hands-free switch.
/// It is fed the modifier's down and up times and any other key; it is pure, so it is tested without a keyboard.
public struct DoubleTap: Sendable {
    public var maxTap: TimeInterval = 0.3   // a press longer than this is a hold, not a tap
    public var maxGap: TimeInterval = 0.4   // the second tap must start this soon after the first ends
    var downAt: TimeInterval?
    var lastTapEnd: TimeInterval?

    public init() {}

    public mutating func modifierDown(at t: TimeInterval) {
        downAt = t
    }

    /// True when this release completes a double tap.
    public mutating func modifierUp(at t: TimeInterval) -> Bool {
        guard let down = downAt else { return false }
        downAt = nil
        guard t - down <= maxTap else { lastTapEnd = nil; return false }
        if let end = lastTapEnd, down - end <= maxGap {
            lastTapEnd = nil
            return true
        }
        lastTapEnd = t
        return false
    }

    /// Another key or modifier: ⌥ Space and ⌥-shortcuts are not taps.
    public mutating func otherKey() {
        downAt = nil
        lastTapEnd = nil
    }
}
