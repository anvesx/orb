import OrbKit
import SwiftUI

/// The living orb: four soft colour fields drift inside a circle and blend. The mood sets the mix, the speed and the
/// pulse; the audio level of whoever speaks makes it swell. 15 frames a second while idle, the display rate otherwise.
public struct OrbView: View {
    var mood: Mood
    var level: () -> Float
    @State private var motion = OrbMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(mood: Mood, level: @escaping () -> Float) {
        self.mood = mood
        self.level = level
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: mood == .idle || mood == .ready ? 1.0 / 15 : nil)) { timeline in
            Canvas { ctx, size in
                let look = motion.step(to: mood, level: level(), at: timeline.date, slow: reduceMotion)
                draw(look, in: &ctx, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    func draw(_ look: OrbMotion.Look, in ctx: inout GraphicsContext, size: CGSize) {
        let s = min(size.width, size.height) * look.scale
        let disc = CGRect(x: (size.width - s) / 2, y: (size.height - s) / 2, width: s, height: s)
        let circle = Path(ellipseIn: disc)
        ctx.fill(circle, with: .color(Theme.canvas))
        ctx.drawLayer { layer in
            layer.clip(to: circle)
            layer.addFilter(.blur(radius: s * 0.12))
            layer.blendMode = .plusLighter
            for (i, field) in OrbMotion.fields.enumerated() {
                let w = look.weights[i]
                guard w > 0.01 else { continue }
                let p = look.positions[i]
                let r = s * (0.38 + 0.12 * w)
                let c = CGPoint(x: disc.midX + p.x * s * 0.28, y: disc.midY + p.y * s * 0.28)
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .radialGradient(Gradient(colors: [field.opacity(0.95 * w), field.opacity(0)]),
                                                 center: c, startRadius: 0, endRadius: r))
            }
        }
        ctx.stroke(circle, with: .linearGradient(Gradient(colors: [.white.opacity(0.28), .white.opacity(0.02)]),
                                                 startPoint: CGPoint(x: disc.minX, y: disc.minY),
                                                 endPoint: CGPoint(x: disc.maxX, y: disc.maxY)), lineWidth: 1)
    }
}

/// The orb's motion between frames: weights ease toward the mood's mix, the fields drift on Lissajous paths.
@MainActor
final class OrbMotion {
    struct Look { var weights: [CGFloat]; var positions: [CGPoint]; var scale: CGFloat }
    static let fields = [Theme.listen, Theme.think, Theme.speak, Theme.speak2, Theme.idle]

    var weights: [CGFloat] = [0.4, 0.55, 0.35, 0.2, 0.3]
    var phase: Double = 0
    var last: Date?
    var smoother = LevelSmoother()

    func step(to mood: Mood, level: Float, at now: Date, slow: Bool) -> Look {
        let dt = min(now.timeIntervalSince(last ?? now), 0.1)
        last = now
        let (target, speed, pulse) = Self.mix(mood)
        let k = CGFloat(1 - exp(-dt * 5))
        for i in weights.indices { weights[i] += (target[i] - weights[i]) * k }
        phase += dt * speed * (slow ? 0.25 : 1)
        let lv = CGFloat(smoother.step(mood == .listening || mood == .speaking ? level : 0))
        let breathe = pulse ? 0.03 * sin(phase * 2.2) : 0
        let positions = (0..<Self.fields.count).map { i -> CGPoint in
            let a = Double(i) * 1.7
            return CGPoint(x: sin(phase * (0.9 + 0.23 * Double(i)) + a), y: cos(phase * (0.7 + 0.31 * Double(i)) + a * 1.3))
        }
        return Look(weights: weights, positions: positions, scale: 0.86 + breathe + 0.14 * lv)
    }

    /// The weights of teal, violet, coral, amber and grey, the drift speed and whether it pulses.
    static func mix(_ mood: Mood) -> ([CGFloat], Double, Bool) {
        switch mood {
        case .idle: ([0.4, 0.55, 0.35, 0.2, 0.3], 0.3, false)
        case .ready: ([0.6, 0.6, 0.3, 0.2, 0.1], 0.6, false)
        case .connecting: ([0.45, 0.8, 0.1, 0.05, 0.2], 0.8, true)
        case .listening: ([1, 0.4, 0.12, 0.08, 0], 1.2, false)
        case .thinking: ([0.25, 1, 0.3, 0.1, 0], 1.8, true)
        case .speaking: ([0.1, 0.35, 1, 0.8, 0], 2.4, false)
        }
    }
}
