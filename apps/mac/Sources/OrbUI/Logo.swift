import SwiftUI

/// The orb mark: the letter o as a ring, with a smaller circle off-centre inside it.
public struct Logo: View {
    var template: Bool

    public init(template: Bool = false) {
        self.template = template
    }

    public var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let ring = CGRect(x: (size.width - s) / 2, y: (size.height - s) / 2, width: s, height: s).insetBy(dx: s * 0.09, dy: s * 0.09)
            ctx.stroke(Path(ellipseIn: ring), with: template ? .color(.black) : .color(Theme.ink), lineWidth: s * 0.14)
            let d = s * 0.36
            let dot = CGRect(x: ring.midX - d * 0.15, y: ring.midY - d * 0.85, width: d, height: d)
            if template {
                ctx.fill(Path(ellipseIn: dot), with: .color(.black))
            } else {
                ctx.fill(Path(ellipseIn: dot), with: .linearGradient(
                    Gradient(colors: [Theme.speak, Theme.think]), startPoint: CGPoint(x: dot.minX, y: dot.minY),
                    endPoint: CGPoint(x: dot.maxX, y: dot.maxY)))
            }
        }
        .accessibilityLabel("orb")
    }
}
