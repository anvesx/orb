import AppKit
@preconcurrency import ApplicationServices
import OrbKit
@preconcurrency import ScreenCaptureKit
@preconcurrency import Vision
import os

private let log = Logger(subsystem: "ai.anvesx.orb", category: "screen")

/// The screen for a call (mac-screen.md sections 3 to 5): ScreenCaptureKit screenshots of the display under the
/// pointer, with orb's own windows left out; Vision's text on them; and Accessibility's view of the front app.
actor MacScreen: ScreenService {
    struct Display {
        let id: CGDirectDisplayID
        let frame: CGRect  // AppKit global points
    }

    /// The text of one screenshot, kept so that a highlight finds its words where Gemini read them.
    struct Seen {
        let display: Display
        let lines: [VNRecognizedText]
        let at: Date
    }

    var feeding: Task<Void, Never>?
    var content: (SCShareableContent, Date)?
    var shared: Display?
    var seen: Seen?
    /// The last document read, by its file and its modification date: a question after a question reads it once.
    var document: (url: URL, date: Date?, reading: ScreenReading.Document)?

    func allowed(ask: Bool) async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        guard ask else { return false }
        _ = CGRequestScreenCaptureAccess()  // the system's prompt, once; a grant may need a relaunch
        return (try? await shareable(fresh: true)) != nil
    }

    func feed(_ sink: ScreenSink?) {
        feeding?.cancel()
        feeding = nil
        guard let sink else { return }
        Task { await warmUp() }
        feeding = Task {
            while !Task.isCancelled {
                do {
                    let (display, frame) = try await frame()
                    shared = display
                    if let pixels = frame.imageBuffer { sink(pixels) }
                } catch {
                    log.error("screen frame failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func read() async -> ScreenReading {
        let t0 = Date.now
        async let text = try? look()  // OCR and the document at once: Gemini waits in silence for the answer
        var (r, url) = await MainActor.run { Self.frontApp() }
        if let url { r.document = documentText(url) }
        if let seen = await text {
            r.screenText = seen.lines.map(\.string).joined(separator: "\n")
        } else {
            r.note = "The screen's text is missing: orb has no Screen Recording permission, or the capture failed."
        }
        log.debug("read in \(Int(Date.now.timeIntervalSince(t0) * 1000)) ms")
        if r.app != nil && r.window == nil && !AXIsProcessTrusted() {
            r.note = (r.note.map { $0 + " " } ?? "") + "No window, selection or document: orb has no Accessibility permission."
        }
        return r
    }

    func documentText(_ url: URL) -> ScreenReading.Document? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let d = document, d.url == url, d.date == date { return d.reading }
        guard let source = Extractor.source(of: url) else { return nil }
        let reading = ScreenReading.Document(name: source.name, kind: source.kind.rawValue, text: source.text)
        document = (url, date, reading)
        return reading
    }

    /// Loads Vision's text model before the first question: the first recognition of a session is about a second slower.
    func warmUp() async {
        let image = CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data(count: 256) as CFData)!, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        if let image { try? VNImageRequestHandler(cgImage: image).perform([request]) }
    }

    func locate(_ text: String) async -> [CGRect]? {
        var seen = self.seen.flatMap { Date.now.timeIntervalSince($0.at) < 3 ? $0 : nil }
        if seen == nil { seen = try? await look() }
        guard let seen, let spans = TextMatch.find(text, in: seen.lines.map(\.string)) else { return nil }
        let rects = spans.compactMap { span -> CGRect? in
            let u = seen.lines[span.line].string.unicodeScalars
            guard span.range.upperBound <= u.count else { return nil }
            let range = u.index(u.startIndex, offsetBy: span.range.lowerBound)..<u.index(u.startIndex, offsetBy: span.range.upperBound)
            guard let box = try? seen.lines[span.line].boundingBox(for: range)?.boundingBox else { return nil }
            return ScreenMap.rect(vision: box, display: seen.display.frame)
        }
        let passage = ScreenMap.passage(rects)
        return passage.isEmpty ? nil : passage
    }

    func spot(x: Int, y: Int) async -> CGPoint? {
        var display = shared
        if display == nil { display = try? await pointerDisplay() }
        guard let display else { return nil }
        return ScreenMap.point(x: x, y: y, display: display.frame)
    }

    // MARK: - Capture

    func shareable(fresh: Bool = false) async throws -> SCShareableContent {
        if !fresh, let (c, at) = content, Date.now.timeIntervalSince(at) < 5 { return c }
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        content = (c, .now)
        return c
    }

    func pointerDisplay() async throws -> Display {
        let (screens, mouse) = await MainActor.run {
            (NSScreen.screens.compactMap { s in s.displayID.map { Display(id: $0, frame: s.frame) } }, NSEvent.mouseLocation)
        }
        guard let i = ScreenChoice.display(pointer: mouse, displays: screens.map(\.frame)) else {
            throw CocoaError(.featureUnsupported)
        }
        return screens[i]
    }

    /// The display under the pointer, without orb's windows, its longest side at most `longest` pixels.
    func capture(longest: CGFloat, cursor: Bool) async throws -> (Display, SCContentFilter, SCStreamConfiguration) {
        let display = try await pointerDisplay()
        let content = try await shareable()
        guard let sc = content.displays.first(where: { $0.displayID == display.id }) else {
            throw CocoaError(.featureUnsupported)
        }
        let me = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: sc, excludingApplications: me, exceptingWindows: [])
        let scale = await MainActor.run { NSScreen.screens.first { $0.displayID == display.id }?.backingScaleFactor ?? 2 }
        let pixels = CGSize(width: display.frame.width * scale, height: display.frame.height * scale)
        let fit = min(1, longest / max(pixels.width, pixels.height))
        let config = SCStreamConfiguration()
        config.width = Int(pixels.width * fit) & ~1
        config.height = Int(pixels.height * fit) & ~1
        config.showsCursor = cursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return (display, filter, config)
    }

    /// A frame for the call's video track: 1920 pixels at most, the pointer drawn.
    func frame() async throws -> (Display, CMSampleBuffer) {
        let (display, filter, config) = try await capture(longest: 1920, cursor: true)
        return (display, try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config))
    }

    /// The display's text, read at full resolution.
    func look() async throws -> Seen {
        let (display, filter, config) = try await capture(longest: 4096, cursor: false)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let t0 = Date.now
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = Self.readingOrder(request.results ?? []).compactMap { $0.topCandidates(1).first }
        log.debug("OCR: \(lines.count) lines in \(Int(Date.now.timeIntervalSince(t0) * 1000)) ms")
        let seen = Seen(display: display, lines: lines, at: .now)
        self.seen = seen
        return seen
    }

    /// Top to bottom, then left to right within a band of about half a line.
    static func readingOrder(_ o: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
        o.sorted { a, b in
            let band = min(a.boundingBox.height, b.boundingBox.height) / 2
            if abs(a.boundingBox.midY - b.boundingBox.midY) > band { return a.boundingBox.midY > b.boundingBox.midY }
            return a.boundingBox.minX < b.boundingBox.minX
        }
    }

    // MARK: - Accessibility

    /// The front app, its focused window, the selection (never from a password field) and the open document.
    @MainActor static func frontApp() -> (ScreenReading, document: URL?) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (ScreenReading(), nil) }
        var r = ScreenReading(app: app.localizedName), document: URL?
        guard AXIsProcessTrusted() else { return (r, nil) }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        if let window: AXUIElement = ax.value(kAXFocusedWindowAttribute) {
            r.window = window.value(kAXTitleAttribute)
            if let path: String = window.value(kAXDocumentAttribute), let url = URL(string: path), url.isFileURL {
                document = url
            }
        }
        if let focused: AXUIElement = ax.value(kAXFocusedUIElementAttribute),
           (focused.value(kAXSubroleAttribute) as String?) != (kAXSecureTextFieldSubrole as String),
           let selected: String = focused.value(kAXSelectedTextAttribute), !selected.isEmpty {
            r.selection = selected
        }
        return (r, document)
    }
}

extension AXUIElement {
    func value<T>(_ attribute: String) -> T? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &out) == .success else { return nil }
        return out as? T
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
