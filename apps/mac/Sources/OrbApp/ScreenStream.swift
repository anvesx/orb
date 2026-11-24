import AppKit
import OrbKit
@preconcurrency import ScreenCaptureKit
import os

struct ScreenDisplay: Equatable, Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
}

struct ScreenFrame: @unchecked Sendable {
    private static let ids = OSAllocatedUnfairLock(initialState: UInt64(0))

    let id: UInt64
    let pixels: CVPixelBuffer
    let display: ScreenDisplay
    let at: Date

    init(pixels: CVPixelBuffer, display: ScreenDisplay) {
        id = Self.ids.withLock { $0 += 1; return $0 }
        self.pixels = pixels
        self.display = display
        at = .now
    }
}

/// One ScreenCaptureKit stream for the whole call, keeping the latest frame. A stream, unlike a screenshot per frame,
/// keeps macOS's capture indicator steady (no blink) and has a frame ready when a question comes.
final class ScreenStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.anvesx.orb.screen")
    private let state = OSAllocatedUnfairLock<ScreenFrame?>(initialState: nil)
    private var stream: SCStream?
    private(set) var display: ScreenDisplay?

    var latest: ScreenFrame? { state.withLock { $0 } }

    func show(_ display: ScreenDisplay) async throws {
        let (filter, config) = try await Self.capture(display)
        if let stream {
            guard display != self.display else { return }
            try await stream.updateContentFilter(filter)
            try await stream.updateConfiguration(config)
        } else {
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
        }
        self.display = display
        state.withLock { $0 = nil }
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        display = nil
        state.withLock { $0 = nil }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = buffer.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              (info[.status] as? Int).flatMap(SCFrameStatus.init) == .complete, let display else { return }
        let frame = ScreenFrame(pixels: pixels, display: display)
        state.withLock { $0 = frame }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger(subsystem: "ai.anvesx.orb", category: "screen").error("stream stopped: \(error.localizedDescription, privacy: .public)")
        self.stream = nil
    }

    /// The display at its full pixel size, orb's own windows left out, the pointer drawn, two frames a second at most.
    static func capture(_ display: ScreenDisplay) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let sc = content.displays.first(where: { $0.displayID == display.id }) else {
            throw CocoaError(.featureUnsupported)
        }
        let me = content.applications.filter { $0.processID == getpid() }
        let scale = await MainActor.run { NSScreen.screens.first { $0.displayID == display.id }?.backingScaleFactor ?? 2 }
        let config = SCStreamConfiguration()
        config.width = Int(display.frame.width * scale) & ~1
        config.height = Int(display.frame.height * scale) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return (SCContentFilter(display: sc, excludingApplications: me, exceptingWindows: []), config)
    }

    static func pointerDisplay() async throws -> ScreenDisplay {
        let (screens, mouse) = await MainActor.run {
            (NSScreen.screens.compactMap { s in s.displayID.map { ScreenDisplay(id: $0, frame: s.frame) } }, NSEvent.mouseLocation)
        }
        guard let i = ScreenChoice.display(pointer: mouse, displays: screens.map(\.frame)) else {
            throw CocoaError(.featureUnsupported)
        }
        return screens[i]
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
