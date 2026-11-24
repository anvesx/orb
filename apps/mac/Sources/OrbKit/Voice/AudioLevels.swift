import os

/// The latest audio levels (0...1), written on the audio thread and read by the display link. Nothing hops actors.
public final class AudioLevels: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (you: Float(0), orb: Float(0)))

    public init() {}

    public var you: Float { state.withLock { $0.you } }
    public var orb: Float { state.withLock { $0.orb } }

    public func set(you level: Float) { state.withLock { $0.you = level } }
    public func set(orb level: Float) { state.withLock { $0.orb = level } }
}

/// Smooths a level for drawing: fast up, slow down.
public struct LevelSmoother: Sendable {
    public var value: Float = 0
    let attack: Float, release: Float

    public init(attack: Float = 0.5, release: Float = 0.15) {
        self.attack = attack
        self.release = release
    }

    public mutating func step(_ target: Float) -> Float {
        let t = min(max(target, 0), 1)
        value += (t - value) * (t > value ? attack : release)
        return value
    }
}
