import SwiftUI

/// Every colour, font and size of the app. The design tokens replace this one file (mac-app.md section 3).
public enum Theme {
    public static let canvas = Color(hex: 0x0B0B10)
    public static let surface = Color(hex: 0x15151C)
    public static let line = Color(hex: 0x25252F)
    public static let ink = Color(hex: 0xF5F4F0)
    public static let ink2 = Color(hex: 0xA9A8B3)
    public static let listen = Color(hex: 0x2DD4BF)
    public static let think = Color(hex: 0x8B7CF6)
    public static let speak = Color(hex: 0xFF7A59)
    public static let speak2 = Color(hex: 0xFFB547)
    public static let idle = Color(hex: 0x5B5B6B)
    public static let alert = Color(hex: 0xFF4D5E)
    /// The hues of context chips, chosen by a hash of the item's name.
    public static let hues: [Color] = [listen, think, speak, speak2, Color(hex: 0x38BDF8), Color(hex: 0xA3E635)]

    public static let body = Font.system(size: 13)
    public static let caption = Font.system(size: 15)
    public static let label = Font.system(size: 10, weight: .semibold, design: .monospaced)
    public static let meta = Font.system(size: 11, design: .monospaced)
    public static let wordmark = Font.system(size: 15, weight: .semibold, design: .rounded)
    public static let state = Font.system(size: 13, weight: .medium, design: .rounded)

    public static let panelRadius: CGFloat = 14
    public static let rowRadius: CGFloat = 10
    public static let panelWidth: CGFloat = 380

    public static func hue(for name: String) -> Color {
        hues[Int(name.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value } % UInt32(hues.count))]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
