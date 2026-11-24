/// Finds a passage that Gemini quotes among the screen's OCR lines (mac-screen.md section 5). Case, punctuation and
/// spacing are ignored, and a passage may run over line breaks. When no exact match exists, the closest run of words
/// wins if it is at least `minSimilarity` alike (OCR misreads a letter, Gemini drops a word). It works on Unicode
/// scalars: grapheme clusters of Indic scripts merge differently once a line is rebuilt.
public enum TextMatch {
    /// A part of one line: the line's index and a range of Unicode scalar offsets in it.
    public struct Span: Equatable, Sendable {
        public var line: Int
        public var range: Range<Int>

        public init(line: Int, range: Range<Int>) {
            self.line = line
            self.range = range
        }
    }

    public static let minSimilarity = 0.8
    static let space: Unicode.Scalar = " "

    /// The spans of the first match in reading order, or nil.
    public static func find(_ quote: String, in lines: [String]) -> [Span]? {
        let q = normalize(quote).text
        guard !q.isEmpty else { return nil }
        let screen = Screen(lines)
        if let start = firstIndex(of: q, in: screen.text) { return screen.spans(start..<(start + q.count)) }
        return closest(q, screen)
    }

    static func firstIndex(of q: [Unicode.Scalar], in text: [Unicode.Scalar]) -> Int? {
        guard q.count <= text.count else { return nil }
        for i in 0...(text.count - q.count) where text[i] == q[0] && Array(text[i..<(i + q.count)]) == q { return i }
        return nil
    }

    /// The run of screen words, as many as the quote has (one more or less), most like the quote.
    static func closest(_ q: [Unicode.Scalar], _ screen: Screen) -> [Span]? {
        let qWords = q.split(separator: space).count
        let words = screen.words
        var best: (score: Double, range: Range<Int>)?
        for n in max(1, qWords - 1)...(qWords + 1) where n <= words.count {
            for i in 0...(words.count - n) {
                let range = words[i].lowerBound..<words[i + n - 1].upperBound
                let score = similarity(q, Array(screen.text[range]))
                if score > (best?.score ?? 0) { best = (score, range) }
            }
        }
        guard let best, best.score >= minSimilarity else { return nil }
        return screen.spans(best.range)
    }

    static func similarity(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let keep = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = keep
            }
        }
        return 1 - Double(row[b.count]) / Double(longest)
    }

    static func isWordPart(_ u: Unicode.Scalar) -> Bool {
        let p = u.properties
        switch p.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber: return true
        default: return p.isAlphabetic
        }
    }

    /// Lowercased letters, marks and digits, every other run as one space; `origin[i]` is the scalar offset in the
    /// source of scalar `i`.
    static func normalize(_ s: String) -> (text: [Unicode.Scalar], origin: [Int]) {
        var out: [Unicode.Scalar] = [], origin: [Int] = [], gap = false
        for (i, u) in s.unicodeScalars.enumerated() {
            if isWordPart(u) {
                if gap && !out.isEmpty { out.append(space); origin.append(i) }
                for l in u.properties.lowercaseMapping.unicodeScalars {
                    out.append(l)
                    origin.append(i)
                }
                gap = false
            } else {
                gap = true
            }
        }
        return (out, origin)
    }

    /// All lines as one normalized text, joined by spaces, with each scalar's line and offset.
    struct Screen {
        var text: [Unicode.Scalar] = []
        var place: [(line: Int, offset: Int)] = []

        init(_ lines: [String]) {
            for (l, line) in lines.enumerated() {
                let n = TextMatch.normalize(line)
                guard !n.text.isEmpty else { continue }
                if !text.isEmpty { text.append(TextMatch.space); place.append((l, -1)) }
                text += n.text
                place += n.origin.map { (l, $0) }
            }
        }

        var words: [Range<Int>] {
            var out: [Range<Int>] = [], start: Int?
            for (i, c) in text.enumerated() {
                if c == TextMatch.space {
                    if let s = start { out.append(s..<i); start = nil }
                } else if start == nil {
                    start = i
                }
            }
            if let s = start { out.append(s..<text.count) }
            return out
        }

        /// A range of the joined text as one span per line, in source offsets.
        func spans(_ r: Range<Int>) -> [Span] {
            var out: [Span] = []
            for i in r where place[i].offset >= 0 {
                let (line, offset) = place[i]
                if let last = out.last, last.line == line {
                    out[out.count - 1].range = last.range.lowerBound..<(offset + 1)
                } else {
                    out.append(Span(line: line, range: offset..<(offset + 1)))
                }
            }
            return out
        }
    }
}
