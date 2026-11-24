import Foundation

/// The canvas wire format (screen-canvas.md section 6, `contracts/canvas-ops.json`): the worker's ops and the app's
/// answers on the RPC method `orb.canvas`.
public struct CanvasOp: Codable, Equatable, Sendable {
    public enum Name: String, Codable, Sendable { case mark, clear }

    public var v: Int
    public var op: Name
    public var opId: String
    public var target: String?
    public var kind: Target.Kind?
    public var style: Mark?
    public var note: String?

    public static let method = "orb.canvas"
    public static let version = 1

    public static func decode(_ payload: String) -> CanvasOp? {
        guard let op = try? JSONDecoder().decode(CanvasOp.self, from: Data(payload.utf8)), op.v == version else {
            return nil
        }
        return op
    }
}

public struct CanvasAnswer: Codable, Equatable, Sendable {
    public var found: Bool?
    public var id: String?
    public var by: GroundSource?
    public var matches: Int?
    public var confidence: Double?
    public var why: String?
    public var cleared: Int?
    public var error: String?

    public static func found(id: String, by: GroundSource, matches: Int, confidence: Double?) -> Self {
        Self(found: true, id: id, by: by, matches: matches, confidence: confidence)
    }

    public static func notFound(_ why: String) -> Self { Self(found: false, why: why) }
    public static func cleared(_ n: Int) -> Self { Self(cleared: n) }
    public static func failed(_ why: String) -> Self { Self(error: why) }

    public var json: String {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
