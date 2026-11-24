import Foundation

/// The parts of a session's state that the inspector shows: the web page's engine view. Every field is optional, so
/// a later service that adds or drops a field does not break the app.
public struct EngineView: Decodable, Equatable, Sendable {
    public static let promises = ["Interaction", "Divergence", "Challenge", "Reflection", "Progression", "Resolution"]
    public static let promiseWords = [
        "Interaction": "Reply to the other side", "Divergence": "More than one option", "Challenge": "A reason for each claim",
        "Reflection": "Change only for a reason", "Progression": "No repeats, no stuck points", "Resolution": "Close the points",
    ]
    public static let stages = ["Open", "Test", "Close"]

    public struct Message: Decodable, Equatable, Sendable, Identifiable {
        public var seq: Int
        public var id: String
        public var speaker: String
        public var text: String
        public var channel: String?
        public var interrupted: Bool?
    }

    public struct Decision: Decodable, Equatable, Sendable {
        public var persona: String?
        public var name: String?
        public var move: String?
        public var why: String?
        public var debt: String?
        public var kind: String?
        public var promise: String?
    }

    public struct Check: Decodable, Equatable, Sendable {
        public var done: Bool?
        public var text: String?
    }

    public struct Timing: Decodable, Equatable, Sendable {
        public var readHuman: Double?
        public var readAI: Double?
        enum CodingKeys: String, CodingKey { case readHuman = "read_human", readAI = "read_ai" }
    }

    public struct Turn: Decodable, Equatable, Sendable {
        public var ai: Int?
        public var decision: Decision?
        public var check: Check?
        public var timing: Timing?
    }

    public struct Score: Decodable, Equatable, Sendable {
        public var owed: Int
        public var paid: Int
        public var due: Bool
    }

    public struct Debt: Decodable, Equatable, Sendable, Identifiable {
        public var id: String
        public var kind: String
        public var owner: String
        public var about: String
        public var status: String  // waiting, due or paid
        public var paid: Int?
    }

    public struct Question: Decodable, Equatable, Sendable {
        public var label: String?
        public var answer: Double?
        public var yes: Bool?
    }

    public struct Call: Decodable, Equatable, Sendable {
        public var id: String?
        public var speaker: String?
        public var questions: [Question]?
        public var seconds: Double?
        public var tokens: Int?
        public var error: String?
    }

    public var version: Int?
    public var messages: [Message]?
    public var turns: [Turn]?
    public var stage: String?
    public var stageWhy: String?
    public var scores: [String: Score]?
    public var board: [Debt]?
    public var need: String?
    public var lastCall: Call?
    public var tokens: Int?
    public var costUSD: Double?
    public var busy: Bool?

    enum CodingKeys: String, CodingKey {
        case version, messages, turns, stage, scores, board, need, tokens, busy
        case stageWhy = "stage_why", lastCall = "last_call", costUSD = "cost_usd"
    }

    public init?(state: [String: JSONValue]) {
        guard let data = try? JSONEncoder().encode(state),
              let view = try? JSONDecoder().decode(EngineView.self, from: data) else { return nil }
        self = view
    }

    /// The turn whose reply is the message at `seq`.
    public func turn(replying seq: Int) -> Turn? { turns?.first { $0.ai == seq } }
}
