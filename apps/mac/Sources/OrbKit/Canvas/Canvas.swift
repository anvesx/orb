import CoreGraphics
import Foundation

/// Where an annotation is attached (screen-canvas.md section 4). Window and element anchors, which follow a window or
/// a scroll, come later as more cases.
public enum Anchor: Equatable, Sendable {
    case screen(displayID: UInt32, rects: [CGRect], frameID: UInt64)

    public var displayID: UInt32 {
        switch self { case .screen(let id, _, _): id }
    }

    public var rects: [CGRect] {
        switch self { case .screen(_, let rects, _): rects }
    }

    public var bounds: CGRect { rects.reduce(CGRect.null) { $0.union($1) } }
}

public struct Annotation: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case mark(Mark) }

    public var id: String
    public var kind: Kind
    public var anchor: Anchor
    public var note: String

    public init(id: String, kind: Kind, anchor: Anchor, note: String = "") {
        self.id = id
        self.kind = kind
        self.anchor = anchor
        self.note = note
    }
}

public struct CanvasState: Equatable, Sendable {
    public var annotations: [Annotation] = []
    public var expires: Date?
    var applied: Set<String> = []

    public init() {}

    /// The newest annotation: the companion stands there.
    public var focus: Annotation? { annotations.last }
}

public enum CanvasEvent: Equatable, Sendable {
    case add(Annotation, opID: String, at: Date)
    case remove(String)
    case clear
    case youSpoke
    case orbSpeaking
    case orbStopped(at: Date)
    case tick(Date)
}

/// The canvas as a pure function of (state, event), like `CallMachine`. A mark stays while orb talks about it, and
/// goes when you next talk or `linger` after orb stops; one that orb never talks about goes after `unspoken`.
public enum Canvas {
    public static let linger: TimeInterval = 6
    public static let unspoken: TimeInterval = 12

    public static func reduce(_ state: CanvasState, _ event: CanvasEvent) -> CanvasState {
        var s = state
        switch event {
        case .add(let a, let opID, let at):
            guard !s.applied.contains(opID) else { return s }
            s.applied.insert(opID)
            s.annotations.removeAll { $0.id == a.id }
            s.annotations.append(a)
            s.expires = s.expires.map { max($0, at + unspoken) } ?? at + unspoken
        case .remove(let id):
            s.annotations.removeAll { $0.id == id }
        case .clear, .youSpoke:
            s.annotations = []
            s.expires = nil
        case .orbSpeaking:
            if !s.annotations.isEmpty { s.expires = .distantFuture }
        case .orbStopped(let at):
            if s.expires == .distantFuture { s.expires = at + linger }
        case .tick(let now):
            if let e = s.expires, now >= e {
                s.annotations = []
                s.expires = nil
            }
        }
        return s
    }
}
