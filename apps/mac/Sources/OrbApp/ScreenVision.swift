import CoreImage
import OrbKit
@preconcurrency import Vision

/// The text of one frame, kept so that a mark lands where Gemini read the words.
struct Seen: @unchecked Sendable {
    let frame: ScreenFrame
    let lines: [VNRecognizedText]
    let image: CIImage
    var display: ScreenDisplay { frame.display }
    var at: Date { frame.at }
}

/// Vision on a frame: its lines of text in reading order, and the objects next to a caption.
enum ScreenVision {
    static func read(_ frame: ScreenFrame) throws -> Seen {
        let image = CIImage(cvPixelBuffer: frame.pixels)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(ciImage: image).perform([request])
        let found = request.results ?? []
        let lines = ReadingOrder.indices(of: found.map(\.boundingBox)).compactMap { found[$0].topCandidates(1).first }
        return Seen(frame: frame, lines: lines, image: image)
    }

    static func rects(of spans: [TextMatch.Span], in seen: Seen) -> [CGRect] {
        spans.compactMap { span in
            let u = seen.lines[span.line].string.unicodeScalars
            guard span.range.upperBound <= u.count else { return nil }
            let range = u.index(u.startIndex, offsetBy: span.range.lowerBound)..<u.index(u.startIndex, offsetBy: span.range.upperBound)
            guard let box = try? seen.lines[span.line].boundingBox(for: range)?.boundingBox else { return nil }
            return ScreenMap.rect(vision: box, display: seen.display.frame)
        }
    }

    /// The first recognition of a session loads Vision's model, about a second.
    static func warmUp() {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try? VNImageRequestHandler(ciImage: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16)))
            .perform([request])
    }
}
