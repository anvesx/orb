@preconcurrency import CoreVideo
import Foundation

/// Takes the shared display's frames for the call's video track.
public typealias ScreenSink = @Sendable (CVPixelBuffer) -> Void

/// The screen, as the call uses it: the frames, the reading and the places to show. The ScreenCaptureKit, Vision and
/// Accessibility implementation is in OrbApp; tests use a fake.
public protocol ScreenService: Sendable {
    /// Whether orb may capture the screen. With `ask`, macOS asks the person the first time.
    func allowed(ask: Bool) async -> Bool
    /// Sends a frame of the display under the pointer to `sink` every second; nil stops.
    func feed(_ sink: ScreenSink?) async
    func read() async -> ScreenReading
    /// The global rects of a passage on the shared display, or nil when it is not there.
    func locate(_ text: String) async -> [CGRect]?
    /// A Gemini point (0 to 1000, top left) on the shared display, in global points.
    func spot(x: Int, y: Int) async -> CGPoint?
}

/// The app's side of the worker's screen tools (mac-screen.md sections 4 and 5): payload in, JSON answer out.
public enum ScreenRPC {
    public static let read = "orb.screen.read"
    public static let show = "orb.screen.show"

    struct Show: Decodable {
        var text: String?
        var x: Int?
        var y: Int?
        var label: String?
        var point: Bool?
    }

    public static func answerRead(_ screen: ScreenService) async -> (answer: String, reading: ScreenReading) {
        let reading = await screen.read().budgeted()
        return (reading.encoded() ?? error("orb could not read the screen."), reading)
    }

    public static func answerShow(_ payload: String, _ screen: ScreenService) async -> (answer: String, target: PointTarget?) {
        guard let show = try? JSONDecoder().decode(Show.self, from: Data(payload.utf8)) else {
            return (error("The request was not understood."), nil)
        }
        let label = String((show.label ?? "").prefix(80))
        if let text = show.text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let rects = await screen.locate(text), let anchor = ScreenMap.anchor(of: rects) else {
                return (#"{"found":false,"why":"Those words are not on the screen. Quote them exactly as they appear."}"#, nil)
            }
            if show.point == true {  // a button or a caption: the companion goes there, nothing is highlighted
                return (#"{"found":true}"#, PointTarget(point: CGPoint(x: rects[0].midX, y: rects[0].minY), label: label))
            }
            return (#"{"found":true}"#, PointTarget(point: anchor, rects: rects, label: label))
        }
        if let x = show.x, let y = show.y {
            guard let point = await screen.spot(x: x, y: y) else {
                return (#"{"found":false,"why":"The screen is not shared."}"#, nil)
            }
            return (#"{"found":true}"#, PointTarget(point: point, label: label))
        }
        return (error("Give text, or x and y."), nil)
    }

    public static func error(_ why: String) -> String {
        (try? JSONEncoder().encode(["error": why])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
