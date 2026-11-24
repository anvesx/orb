// Draws the orb mark into an .iconset: swift scripts/make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func icon(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let tile = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)  // the macOS icon grid
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil))
    ctx.setFillColor(color(0x0B0B10))
    ctx.fillPath()
    let ring = tile.insetBy(dx: s * 0.17, dy: s * 0.17)
    ctx.setStrokeColor(color(0xF5F4F0))
    ctx.setLineWidth(s * 0.065)
    ctx.strokeEllipse(in: ring)
    let d = ring.width * 0.4
    let dot = CGRect(x: ring.midX - d * 0.15, y: ring.midY - d * 0.15, width: d, height: d)
    ctx.saveGState()
    ctx.addEllipse(in: dot)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [color(0xFF7A59), color(0x8B7CF6)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: dot.minX, y: dot.maxY), end: CGPoint(x: dot.maxX, y: dot.minY), options: [])
    ctx.restoreGState()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try icon(size).write(to: out.appending(path: "icon_\(size)x\(size).png"))
    try icon(size * 2).write(to: out.appending(path: "icon_\(size)x\(size)@2x.png"))
}
