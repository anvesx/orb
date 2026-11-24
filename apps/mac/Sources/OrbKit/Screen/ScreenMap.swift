import CoreGraphics

/// From the shapes that Vision and Gemini use to global AppKit points (origin at the bottom left of the main display,
/// y up). `display` is the shared display's frame when the screenshot was taken.
public enum ScreenMap {
    /// A Vision box: normalized to the image, origin at the bottom left.
    public static func rect(vision box: CGRect, display: CGRect) -> CGRect {
        CGRect(x: display.minX + box.minX * display.width, y: display.minY + box.minY * display.height,
               width: box.width * display.width, height: box.height * display.height)
    }

    /// A vision model's `box_2d`: [ymin, xmin, ymax, xmax], 0 to 1000 over the image, origin at the top left.
    public static func rect(box2d b: [Int], display: CGRect) -> CGRect? {
        guard b.count == 4 else { return nil }
        let (y0, x0, y1, x1) = (CGFloat(b[0]) / 1000, CGFloat(b[1]) / 1000, CGFloat(b[2]) / 1000, CGFloat(b[3]) / 1000)
        return CGRect(x: display.minX + x0 * display.width, y: display.maxY - y1 * display.height,
                      width: (x1 - x0) * display.width, height: (y1 - y0) * display.height)
    }

    /// An Accessibility frame: top-left origin on the main display, y down.
    public static func rect(accessibility r: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    /// A Gemini point: 0 to 1000 over the image, origin at the top left.
    public static func point(x: Int, y: Int, display: CGRect) -> CGPoint {
        let fx = Double(min(max(x, 0), 1000)) / 1000, fy = Double(min(max(y, 0), 1000)) / 1000
        return CGPoint(x: display.minX + fx * display.width, y: display.maxY - fy * display.height)
    }

    /// The rects of one passage only: from the first, each next line must sit just below the one before it and share
    /// part of its width. OCR's reading order puts a line of the right column after the same line of the left one, so a
    /// quote that runs on can reach the other column; that part is dropped. Rects are in AppKit points (y up).
    public static func passage(_ rects: [CGRect]) -> [CGRect] {
        guard var last = rects.first else { return [] }
        var out = [last]
        for r in rects.dropFirst() {
            let below = r.maxY <= last.midY && last.minY - r.maxY <= 1.5 * max(last.height, r.height)
            let overlaps = r.minX < last.maxX && r.maxX > last.minX
            guard below && overlaps else { break }
            out.append(r)
            last = r
        }
        return out
    }
}

/// Which display to share: the one under the pointer, else the nearest (a pointer can sit in a gap between displays).
public enum ScreenChoice {
    public static func display(pointer: CGPoint, displays: [CGRect]) -> Int? {
        if let i = displays.firstIndex(where: { $0.contains(pointer) }) { return i }
        return displays.indices.min { distance(pointer, displays[$0]) < distance(pointer, displays[$1]) }
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
