import AppKit
import Foundation
import Testing
@testable import OrbKit

func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "orb-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func write(_ text: String, _ name: String, in folder: URL, age: TimeInterval = 0) throws -> URL {
    let url = folder.appending(path: name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    return url
}

/// A one-page PDF with real text, drawn with Core Text.
func makePDF(_ text: String, at url: URL) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]).draw(at: CGPoint(x: 72, y: 700))
    NSGraphicsContext.current = nil
    ctx.endPDFPage()
    ctx.closePDF()
}

@Suite struct ExtractorTests {
    @Test func markdownTextAndCodeAreReadAsText() throws {
        let dir = try tempFolder()
        #expect(Extractor.source(of: try write("# Plan\nShip it.", "plan.md", in: dir)) == Source(name: "plan.md", kind: .markdown, text: "# Plan\nShip it."))
        #expect(Extractor.source(of: try write("print(1)", "a.py", in: dir))?.kind == .code)
        #expect(Extractor.source(of: try write("  \n", "empty.txt", in: dir)) == nil)
        #expect(Extractor.kind(of: dir.appending(path: "movie.mov")) == nil)
    }

    @Test func aPDFGivesItsTextPageByPage() throws {
        let url = try tempFolder().appending(path: "pricing.pdf")
        makePDF("The team plan costs twelve dollars.", at: url)
        let s = try #require(Extractor.source(of: url))
        #expect(s.kind == .pdf && s.text.hasPrefix("--- page 1 ---") && s.text.contains("twelve dollars"))
    }

    @Test func aPDFWithNoTextGivesNothing() throws {
        let url = try tempFolder().appending(path: "scan.pdf")
        makePDF("", at: url)
        #expect(Extractor.source(of: url) == nil)
    }

    @Test func wordAndRTFDocumentsAreRead() throws {
        let dir = try tempFolder()
        let doc = NSAttributedString(string: "Launch on the third of March.")
        let docx = dir.appending(path: "brief.docx"), rtf = dir.appending(path: "brief.rtf")
        try doc.data(from: NSRange(location: 0, length: doc.length),
                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx)
        try doc.data(from: NSRange(location: 0, length: doc.length),
                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf)
        #expect(Extractor.source(of: docx)?.text == "Launch on the third of March.")
        #expect(Extractor.source(of: rtf)?.kind == .document)
    }
}

@Suite struct FilesProviderTests {
    @Test func aFolderGivesItsReadableFilesNewestFirstWithoutSubfoldersOrHiddenFiles() async throws {
        let dir = try tempFolder()
        _ = try write("old", "old.md", in: dir, age: 100)
        _ = try write("new", "new.txt", in: dir)
        _ = try write("secret", ".hidden.md", in: dir)
        _ = try write("binary", "photo.heic", in: dir)
        try FileManager.default.createDirectory(at: dir.appending(path: "sub"), withIntermediateDirectories: true)
        _ = try write("deep", "deep.md", in: dir.appending(path: "sub"))
        let files = FilesProvider(desktop: dir)
        #expect(FilesProvider.files(in: dir).map(\.lastPathComponent) == ["new.txt", "old.md"])
        let sources = await files.sources(for: [files.item(for: dir)])
        #expect(sources.map(\.name) == ["new.txt", "old.md"])
    }

    @Test func theDesktopSuggestsItsFolders() async throws {
        let desktop = try tempFolder()
        try FileManager.default.createDirectory(at: desktop.appending(path: "Notes"), withIntermediateDirectories: true)
        _ = try write("x", "loose.md", in: desktop)
        let items = await FilesProvider(desktop: desktop).suggestions()
        #expect(items.map(\.title) == ["Notes"] && items[0].provider == "files" && items[0].id.hasPrefix("files:"))
    }

    @Test func sourcesStopAtTheRequestLimits() {
        let big = String(repeating: "x", count: 200_000)
        let packed = SourcePack.fit((0..<5).map { Source(name: "f\($0).md", kind: .markdown, text: big) } + [Source(name: "e.md", kind: .markdown, text: "")])
        #expect(packed.map(\.text.count) == [150_000, 150_000, 150_000, 50_000])
        #expect(SourcePack.fit((0..<120).map { Source(name: "\($0)", kind: .text, text: "a") }).count == 100)
    }
}
