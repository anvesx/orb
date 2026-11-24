import CoreGraphics
import Foundation

/// What `read_screen` gives Gemini (mac-screen.md section 4): the front app, the selection, the open document and the
/// screen's text. It goes back as one RPC answer, so it has a byte budget.
public struct ScreenReading: Codable, Equatable, Sendable {
    public struct Document: Codable, Equatable, Sendable {
        public var name: String
        public var kind: String
        public var text: String
        public var cut = false

        public init(name: String, kind: String, text: String) {
            self.name = name
            self.kind = kind
            self.text = text
        }
    }

    public var app: String?
    public var window: String?
    public var selection: String?
    public var document: Document?
    public var screenText: String?
    /// Why a part is missing (no Screen Recording, no Accessibility).
    public var note: String?

    public init(app: String? = nil, window: String? = nil, selection: String? = nil, document: Document? = nil,
                screenText: String? = nil, note: String? = nil) {
        self.app = app
        self.window = window
        self.selection = selection
        self.document = document
        self.screenText = screenText
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case app, window, selection, document, note, screenText = "screen_text"
    }

    /// A LiveKit RPC answer is at most 15 KB on the v1 wire (error 1504 past it).
    public static let maxBytes = 12_000
    static let selectionBytes = 1_500
    static let screenBytes = 5_000

    /// Each part cut to its share, in UTF-8 bytes: the selection and the screen first, the document gets the rest.
    public func budgeted(_ total: Int = maxBytes) -> ScreenReading {
        var r = self
        r.window = window.map { $0.prefix(bytes: 300) }
        r.app = app.map { $0.prefix(bytes: 100) }
        r.selection = selection.map { $0.prefix(bytes: Self.selectionBytes) }
        r.screenText = screenText.map { $0.prefix(bytes: Self.screenBytes) }
        if var doc = document {
            r.document = nil
            let used = (r.encoded()?.utf8.count ?? 0) + 200  // the document's own keys and quotes
            let room = max(0, total - used - doc.name.utf8.count)
            let text = doc.text.prefix(bytes: room)
            doc.cut = doc.cut || text.utf8.count < doc.text.utf8.count
            doc.text = text
            r.document = doc
            while (r.encoded()?.utf8.count ?? 0) > total, let d = r.document, !d.text.isEmpty {  // escapes grow the text
                r.document?.text = d.text.prefix(bytes: d.text.utf8.count * 9 / 10)
                r.document?.cut = true
            }
        }
        return r
    }

    public func encoded() -> String? {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// "Preview · pricing.pdf" for the panel.
    public var seeing: String? {
        guard let app else { return nil }
        guard let name = document?.name ?? window, !name.isEmpty, name != app else { return app }
        return "\(app) · \(name)"
    }
}

extension String {
    /// The longest prefix of whole characters that fits in `bytes` UTF-8 bytes.
    func prefix(bytes: Int) -> String {
        guard utf8.count > bytes else { return self }
        var n = 0, end = startIndex
        for i in indices {
            let size = self[i].utf8.count
            if n + size > bytes { break }
            n += size
            end = index(after: i)
        }
        return String(self[..<end])
    }
}
