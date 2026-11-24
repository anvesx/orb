import AppKit
import OrbKit
@preconcurrency import ScreenCaptureKit
import os

private let log = Logger(subsystem: "ai.anvesx.orb", category: "screen")

/// The screen for a call (mac-screen.md sections 3 to 5): one stream of the display under the pointer, Vision on its
/// latest frame, and Accessibility's view of the front app.
actor MacScreen: ScreenService {
    let stream = ScreenStream()
    let api: @Sendable () -> AgentAPI
    let excluded: @MainActor @Sendable () -> [CGRect]
    var feeding: Task<Void, Never>?
    var seen: Seen?
    var document: (url: URL, date: Date?, reading: ScreenReading.Document)?

    init(api: @escaping @Sendable () -> AgentAPI, excluded: @escaping @MainActor @Sendable () -> [CGRect]) {
        self.api = api
        self.excluded = excluded
    }

    func allowed(ask: Bool) async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        guard ask else { return false }
        _ = CGRequestScreenCaptureAccess()
        return (try? await SCShareableContent.current) != nil
    }

    func feed(_ sink: ScreenSink?) async {
        feeding?.cancel()
        feeding = nil
        guard let sink else { return await stream.stop() }
        Task.detached { ScreenVision.warmUp() }
        feeding = Task {
            while !Task.isCancelled {
                do {
                    try await stream.show(try await ScreenStream.pointerDisplay())
                    if let frame = stream.latest { sink(frame.pixels) }
                } catch {
                    log.error("screen stream: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func read() async -> ScreenReading {
        let t0 = Date.now
        async let text = try? ocr(current())
        var (r, url) = await MainActor.run { FrontApp.read() }
        if let url { r.document = documentText(url) }
        if let seen = await text {
            r.screenText = seen.lines.map(\.string).joined(separator: "\n")
        } else {
            r.note = [r.note, "The screen's text is missing: no Screen Recording permission, or no frame yet."]
                .compactMap { $0 }.joined(separator: " ")
        }
        log.debug("read in \(Int(Date.now.timeIntervalSince(t0) * 1000)) ms")
        return r
    }

    func ground(_ target: Target) async -> Grounded {
        guard let frame = try? await current() else { return .notFound("orb can't see the screen yet.") }
        let (excluded, pointer) = await MainActor.run { (self.excluded(), NSEvent.mouseLocation) }
        let t0 = Date.now
        let grounding = Grounding([
            TextGrounder { try await self.ocr(frame) },
            ElementGrounder(),
            SightGrounder(api: api(), frame: frame),
        ])
        let result = await grounding.ground(target, in: Frame(id: frame.id, displayID: frame.display.id,
                                                              bounds: frame.display.frame, excluded: excluded),
                                            pointer: pointer)
        log.debug("grounded \(target.kind.rawValue, privacy: .public) in \(Int(Date.now.timeIntervalSince(t0) * 1000)) ms")
        return result
    }

    /// The stream's latest frame; before its first one, a single screenshot.
    func current() async throws -> ScreenFrame {
        if let frame = stream.latest { return frame }
        let display = try await ScreenStream.pointerDisplay()
        let (filter, config) = try await ScreenStream.capture(display)
        let buffer = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
        guard let pixels = buffer.imageBuffer else { throw CocoaError(.featureUnsupported) }
        return ScreenFrame(pixels: pixels, display: display)
    }

    /// Vision's text of a frame, once per frame.
    func ocr(_ frame: ScreenFrame) throws -> Seen {
        if let seen, seen.frame.id == frame.id { return seen }
        let t0 = Date.now
        let fresh = try ScreenVision.read(frame)
        log.debug("OCR: \(fresh.lines.count) lines in \(Int(Date.now.timeIntervalSince(t0) * 1000)) ms")
        seen = fresh
        return fresh
    }

    func documentText(_ url: URL) -> ScreenReading.Document? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let d = document, d.url == url, d.date == date { return d.reading }
        guard let source = Extractor.source(of: url) else { return nil }
        let reading = ScreenReading.Document(name: source.name, kind: source.kind.rawValue, text: source.text)
        document = (url, date, reading)
        return reading
    }
}
