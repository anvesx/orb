@preconcurrency import CoreVideo
import Foundation

/// Takes the shared display's frames for the call's video track.
public typealias ScreenSink = @Sendable (CVPixelBuffer) -> Void

/// The screen, as the call uses it: the frames, the reading, and where a target is. The ScreenCaptureKit, Vision and
/// Accessibility implementation is in OrbApp; tests use a fake.
public protocol ScreenService: Sendable {
    /// Whether orb may capture the screen. With `ask`, macOS asks the person the first time.
    func allowed(ask: Bool) async -> Bool
    /// Sends a frame of the display under the pointer to `sink` every second; nil stops.
    func feed(_ sink: ScreenSink?) async
    func read() async -> ScreenReading
    func ground(_ target: Target) async -> Grounded
}

/// The app's side of `read_screen`.
public enum ScreenRPC {
    public static let read = "orb.screen.read"

    public static func answerRead(_ screen: ScreenService) async -> (answer: String, reading: ScreenReading) {
        let reading = await screen.read().budgeted()
        return (reading.encoded() ?? CanvasAnswer.failed("orb could not read the screen.").json, reading)
    }
}
