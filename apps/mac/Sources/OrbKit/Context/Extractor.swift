import AppKit
import PDFKit

/// The readable text of a file. It runs off the main actor; a file that gives no text returns "".
public enum Extractor {
    static let maxBytes = 2_000_000
    static let markdown: Set<String> = ["md", "markdown", "mdx"]
    static let text: Set<String> = ["txt", "text", "log"]
    static let document: Set<String> = ["rtf", "docx"]
    static let code: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "toml", "csv", "sh",
                                    "go", "rs", "java", "kt", "c", "h", "cpp", "m", "rb", "sql", "html", "css", "xml"]

    /// The kind of a file, or nil when orb can't read it yet.
    public static func kind(of url: URL) -> Source.Kind? {
        let ext = url.pathExtension.lowercased()
        if markdown.contains(ext) { return .markdown }
        if text.contains(ext) { return .text }
        if ext == "pdf" { return .pdf }
        if document.contains(ext) { return .document }
        if code.contains(ext) { return .code }
        return nil
    }

    public static func source(of url: URL) -> Source? {
        guard let kind = kind(of: url) else { return nil }
        let text = extract(url, kind).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Source(name: url.lastPathComponent, kind: kind, text: text)
    }

    static func extract(_ url: URL, _ kind: Source.Kind) -> String {
        switch kind {
        case .pdf:
            guard let doc = PDFDocument(url: url) else { return "" }
            let pages = (0..<doc.pageCount).compactMap { i -> String? in
                guard let t = doc.page(at: i)?.string, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return "--- page \(i + 1) ---\n" + t
            }
            return pages.joined(separator: "\n\n")
        case .document:
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string ?? ""
        case .markdown, .text, .code:
            guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
    }
}
