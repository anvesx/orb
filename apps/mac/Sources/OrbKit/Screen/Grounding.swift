import CoreGraphics
import Foundation

/// What a tool asked to find (screen-canvas.md section 3): words, a control, or a thing seen.
public struct Target: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, ui, visual }

    public var what: String
    public var kind: Kind

    public init(_ what: String, kind: Kind) {
        self.what = what
        self.kind = kind
    }
}

/// One captured moment of one display, in global AppKit points. The pixels stay in the app, under the same id.
public struct Frame: Equatable, Sendable {
    public var id: UInt64
    public var displayID: UInt32
    public var bounds: CGRect
    /// orb's own windows: excluded from the capture, so nothing found there is real.
    public var excluded: [CGRect]

    public init(id: UInt64, displayID: UInt32, bounds: CGRect, excluded: [CGRect] = []) {
        self.id = id
        self.displayID = displayID
        self.bounds = bounds
        self.excluded = excluded
    }
}

public enum GroundSource: String, Codable, Sendable { case text, element, sight }

/// A place a grounder found, best first by `score` (0 to 1).
public struct Candidate: Equatable, Sendable {
    public var rects: [CGRect]
    public var score: Double
    public var confidence: Double?

    public init(rects: [CGRect], score: Double = 1, confidence: Double? = nil) {
        self.rects = rects
        self.score = score
        self.confidence = confidence
    }
}

public protocol Grounder: Sendable {
    var source: GroundSource { get }
    var budget: Duration { get }
    func candidates(_ target: Target, in frame: Frame) async throws -> [Candidate]
}

public enum Grounded: Equatable, Sendable {
    case found(anchor: Anchor, by: GroundSource, matches: Int, confidence: Double?)
    case notFound(String)
}

/// Routes a target to the grounders for its kind, in order, and turns the first useful answer into an anchor.
public struct Grounding: Sendable {
    public static let tie = 0.05
    public static let maxShare: CGFloat = 0.6

    let grounders: [GroundSource: any Grounder]

    public init(_ grounders: [any Grounder]) {
        self.grounders = Dictionary(grounders.map { ($0.source, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public static func route(_ kind: Target.Kind) -> [GroundSource] {
        switch kind {
        case .text: [.text, .sight]
        case .ui: [.element, .text, .sight]
        case .visual: [.sight]
        }
    }

    public func ground(_ target: Target, in frame: Frame, pointer: CGPoint) async -> Grounded {
        var late = false
        for source in Self.route(target.kind) {
            guard let grounder = grounders[source] else { continue }
            guard let found = await Self.within(grounder.budget, { try await grounder.candidates(target, in: frame) }) else {
                late = true
                continue
            }
            let usable = found.filter { Self.plausible($0, in: frame) }
            guard let best = Self.ranked(usable, pointer: pointer).first else { continue }
            let matches = usable.filter { $0.score >= best.score - Self.tie }.count
            return .found(anchor: .screen(displayID: frame.displayID, rects: best.rects, frameID: frame.id),
                          by: source, matches: matches, confidence: best.confidence)
        }
        return .notFound(late ? "orb could not find \"\(target.what)\" in time." : "\"\(target.what)\" is not on the screen.")
    }

    /// Inside the frame, not most of it, and not over orb's own windows.
    static func plausible(_ c: Candidate, in frame: Frame) -> Bool {
        let box = c.rects.reduce(CGRect.null) { $0.union($1) }
        guard !box.isNull, frame.bounds.insetBy(dx: -2, dy: -2).contains(box) else { return false }
        guard box.width * box.height <= maxShare * frame.bounds.width * frame.bounds.height else { return false }
        return !frame.excluded.contains { $0.intersects(box) }
    }

    /// Best score first; within a tie, the one nearer the pointer.
    static func ranked(_ cs: [Candidate], pointer: CGPoint) -> [Candidate] {
        cs.sorted { a, b in
            if abs(a.score - b.score) > tie { return a.score > b.score }
            return distance(pointer, a) < distance(pointer, b)
        }
    }

    static func distance(_ p: CGPoint, _ c: Candidate) -> CGFloat {
        let r = c.rects.reduce(CGRect.null) { $0.union($1) }
        return hypot(r.midX - p.x, r.midY - p.y)
    }

    /// The candidates, `[]` when the grounder failed, nil when it ran past its budget.
    static func within(_ budget: Duration, _ work: @escaping @Sendable () async throws -> [Candidate]) async -> [Candidate]? {
        await withTaskGroup(of: [Candidate]?.self) { group in
            group.addTask { (try? await work()) ?? [] }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
