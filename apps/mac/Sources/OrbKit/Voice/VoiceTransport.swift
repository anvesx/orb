import Foundation

/// The state that the voice agent publishes (LiveKit participant attribute `lk.agent.state`).
public enum AgentState: String, Sendable {
    case initializing, listening, thinking, speaking, idle

    /// The web page's aliases: a gone agent is idle, a buffering one listens.
    public init(attribute raw: String) {
        switch raw {
        case "disconnected", "failed", "": self = .idle
        case "pre-connect-buffering": self = .listening
        default: self = AgentState(rawValue: raw) ?? .listening  // a state of a later agent version
        }
    }
}

public enum VoiceEvent: Sendable {
    case agentJoined
    case agentState(AgentState)
    case youSpeaking(Bool)
    /// Your words: each update holds the whole text of the segment so far.
    case yourWords(segment: String, text: String, final: Bool)
    /// orb's words: chunks of one reply, in step with its audio.
    case orbWords(segment: String, chunk: String)
    case bench(BenchEvent)
    case reconnecting, reconnected
    case disconnected(String?)
}

/// One voice call. The LiveKit implementation is in OrbVoice; tests use a fake.
public protocol VoiceTransport: AnyObject, Sendable {
    var levels: AudioLevels { get }
    /// Joins the room with the microphone published and muted. The stream ends when the call ends.
    func connect(url: String, token: String) async throws -> AsyncStream<VoiceEvent>
    func setMicrophone(_ on: Bool) async throws
    /// Answers the agent's RPC `method` with `handler` (payload in, answer out) for the rest of the call.
    func serve(_ method: String, _ handler: @escaping @Sendable (String) async -> String) async
    /// Publishes the call's screen track; nil when it could not.
    func startScreen() async -> ScreenSink?
    func disconnect() async
}
