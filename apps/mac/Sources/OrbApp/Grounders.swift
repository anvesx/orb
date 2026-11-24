import AppKit
@preconcurrency import ApplicationServices
import CoreImage
import OrbKit

/// Words on the screen: OCR of the frame (cached by frame) and every occurrence of the quote.
struct TextGrounder: Grounder {
    let source = GroundSource.text
    let budget = Duration.seconds(2)
    let ocr: @Sendable () async throws -> Seen

    func candidates(_ target: Target, in frame: Frame) async throws -> [Candidate] {
        let seen = try await ocr()
        return TextMatch.all(target.what, in: seen.lines.map(\.string)).compactMap { match in
            let rects = ScreenMap.passage(ScreenVision.rects(of: match.spans, in: seen))
            return rects.isEmpty ? nil : Candidate(rects: rects, score: match.score)
        }
    }
}

/// Controls of the front app, by name: its focused window's Accessibility tree, visible elements only.
struct ElementGrounder: Grounder {
    static let roles: Set<String> = [kAXButtonRole, kAXMenuItemRole, kAXMenuBarItemRole, kAXRadioButtonRole,
                                     kAXCheckBoxRole, kAXPopUpButtonRole, kAXTextFieldRole, kAXComboBoxRole,
                                     kAXSliderRole, kAXTabGroupRole, "AXLink", kAXMenuButtonRole, kAXDisclosureTriangleRole]
    static let maxDepth = 12, maxNodes = 4_000

    let source = GroundSource.element
    let budget = Duration.milliseconds(200)

    func candidates(_ target: Target, in frame: Frame) async throws -> [Candidate] {
        guard AXIsProcessTrusted(), let pid = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier })
        else { return [] }
        let mainHeight = await MainActor.run { NSScreen.screens.first?.frame.height ?? 0 }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let window: AXUIElement = app.value(kAXFocusedWindowAttribute) else { return [] }
        let query = ElementMatch.query(target.what)
        var found: [Candidate] = [], queue: [(AXUIElement, Int)] = [(window, 0)], seen = 0
        while !queue.isEmpty, seen < Self.maxNodes, !Task.isCancelled {
            let (element, depth) = queue.removeFirst()
            seen += 1
            if let role: String = element.value(kAXRoleAttribute), Self.roles.contains(role),
               let rect = element.frame.map({ ScreenMap.rect(accessibility: $0, mainHeight: mainHeight) }),
               rect.width > 1, rect.height > 1, frame.bounds.intersects(rect),
               let score = element.names.compactMap({ ElementMatch.score(query, name: $0) }).max() {
                found.append(Candidate(rects: [rect], score: score))
            }
            if depth < Self.maxDepth, let children: [AXUIElement] = element.value(kAXChildrenAttribute) {
                queue += children.map { ($0, depth + 1) }
            }
        }
        return found
    }
}

/// Anything seen: the frame as a JPEG to the agent service's vision model, which answers boxes.
struct SightGrounder: Grounder {
    static let longest: CGFloat = 1280

    let source = GroundSource.sight
    let budget = Duration.milliseconds(3500)
    let api: AgentAPI
    let frame: ScreenFrame

    func candidates(_ target: Target, in frame: Frame) async throws -> [Candidate] {
        guard let jpeg = Self.jpeg(self.frame.pixels) else { return [] }
        let boxes = try await api.ground(image: jpeg, query: target.what)
        return boxes.enumerated().compactMap { i, b in
            ScreenMap.rect(box2d: b.box, display: frame.bounds).map {
                Candidate(rects: [$0], score: 1 - 0.2 * Double(i), confidence: b.confidence)
            }
        }
    }

    static func jpeg(_ pixels: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixels)
        let scale = min(1, longest / max(image.extent.width, image.extent.height))
        return CIContext().jpegRepresentation(
            of: image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7])
    }
}

extension AXUIElement {
    var frame: CGRect? {
        guard let p: AXValue = value(kAXPositionAttribute), let s: AXValue = value(kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var names: [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { value($0) as String? }
            .filter { !$0.isEmpty }
    }
}
