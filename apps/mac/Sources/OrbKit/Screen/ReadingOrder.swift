import CoreGraphics

/// The order a person reads the lines of a screen in: column by column, left to right, each top to bottom. A line
/// continues the block whose last line sits right above it and shares at least half of the narrower width; blocks
/// side by side are read left to right, a block below them after both. Rects are AppKit-like: y up.
public enum ReadingOrder {
    public static func indices(of lines: [CGRect]) -> [Int] {
        var blocks: [[Int]] = []
        for i in lines.indices.sorted(by: { lines[$0].midY > lines[$1].midY }) {
            let r = lines[i]
            let next = blocks.indices.filter { b in continues(lines[blocks[b].last!], r) }
                .min { gap(lines[blocks[$0].last!], r) < gap(lines[blocks[$1].last!], r) }
            if let b = next { blocks[b].append(i) } else { blocks.append([i]) }
        }
        return ordered(blocks, lines).flatMap { $0 }
    }

    static func continues(_ above: CGRect, _ r: CGRect) -> Bool {
        let shared = min(above.maxX, r.maxX) - max(above.minX, r.minX)
        return shared >= 0.5 * min(above.width, r.width) && gap(above, r) <= 2.5 * max(above.height, r.height)
    }

    static func gap(_ above: CGRect, _ r: CGRect) -> CGFloat { above.minY - r.maxY }

    static func ordered(_ blocks: [[Int]], _ lines: [CGRect]) -> [[Int]] {
        let box = blocks.map { b in b.map { lines[$0] }.reduce(CGRect.null) { $0.union($1) } }
        return blocks.indices.sorted { a, b in
            let side = box[a].maxY > box[b].minY && box[b].maxY > box[a].minY
            return side ? box[a].minX < box[b].minX : box[a].maxY > box[b].maxY
        }.map { blocks[$0] }
    }
}
