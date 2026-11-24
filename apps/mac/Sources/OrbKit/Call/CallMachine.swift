/// The state machine of one call: a pure function of (state, event) to (state, effects). `AppModel` runs the effects.
///
///  idle ─talk─▶ preparing ─prepared─▶ connecting ─joined─▶ live ─hang up, idle timeout, disconnected─▶ idle
///
/// Hold to talk: key down opens the mic, key up starts a short tail, then the mic closes. A press while the call is
/// preparing or connecting is pending: when the key is still held at the join, the mic opens then; when it was
/// released before, nothing is sent and the call stays up for the next press. The call stays up (warm) until no one
/// has spoken for the idle timeout.
public enum CallPhase: Equatable, Sendable { case idle, preparing, connecting, live }

public struct CallState: Equatable, Sendable {
    public var phase: CallPhase = .idle
    public var keyDown = false
    public var micOn = false
    public var agent: AgentState?
    public var agentJoined = false
    public var reconnecting = false
    public var warning: String?

    public init() {}
}

public enum CallEvent: Equatable, Sendable {
    case talkDown, talkUp, tailElapsed
    case prepared(VoiceToken), prepareFailed(String)
    case joined, connectFailed(String)
    case agentJoined, agentState(AgentState), agentJoinTimeout
    case youSpeaking
    case reconnecting, reconnected
    case disconnected(String?)
    case idleTimeout, hangUp, newSession, micDenied
}

public enum CallEffect: Equatable, Sendable {
    case prepare, cancelPrepare
    case connect(VoiceToken), disconnect
    case setMic(Bool), startTail
    case startAgentJoinTimer, cancelAgentJoinTimer
    case restartIdleTimer
    case forgetSession
}

public enum CallMachine {
    public static let agentJoinWarning = "The voice agent did not join. Check that the voice worker runs (make dev-gemini)."
    public static let micWarning = "orb can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."

    public static func reduce(_ s: CallState, _ event: CallEvent) -> (CallState, [CallEffect]) {
        var s = s
        switch (s.phase, event) {
        case (.idle, .talkDown):
            s = CallState()
            s.phase = .preparing
            s.keyDown = true
            return (s, [.prepare])
        case (_, .talkDown):
            s.keyDown = true
            guard s.phase == .live, !s.micOn else { return (s, []) }  // pending, or the tail is still open
            s.micOn = true
            return (s, [.setMic(true), .restartIdleTimer])
        case (_, .talkUp):
            s.keyDown = false
            return (s, s.phase == .live && s.micOn ? [.startTail] : [])
        case (.live, .tailElapsed):
            guard !s.keyDown, s.micOn else { return (s, []) }
            s.micOn = false
            return (s, [.setMic(false), .restartIdleTimer])

        case (.preparing, .prepared(let token)):
            s.phase = .connecting
            return (s, [.connect(token)])
        case (.preparing, .prepareFailed(let why)), (.connecting, .connectFailed(let why)):
            return (ended(why), [])
        case (.connecting, .joined):
            s.phase = .live
            s.micOn = s.keyDown
            return (s, (s.micOn ? [.setMic(true)] : []) + [.startAgentJoinTimer, .restartIdleTimer])

        case (.live, .agentJoined):
            s.agentJoined = true
            if s.warning == agentJoinWarning { s.warning = nil }
            return (s, [.cancelAgentJoinTimer])
        case (.live, .agentState(let a)):
            s.agent = a
            return (s, a == .speaking || a == .thinking ? [.restartIdleTimer] : [])
        case (.live, .agentJoinTimeout):
            if !s.agentJoined { s.warning = agentJoinWarning }
            return (s, [])
        case (.live, .youSpeaking):
            return (s, [.restartIdleTimer])
        case (.live, .idleTimeout):
            if s.keyDown || s.micOn || s.agent == .speaking || s.agent == .thinking { return (s, [.restartIdleTimer]) }
            return (ended(nil), [.disconnect])
        case (.live, .reconnecting):
            s.reconnecting = true
            return (s, [])
        case (.live, .reconnected):
            s.reconnecting = false
            return (s, [])
        case (.connecting, .disconnected(let why)), (.live, .disconnected(let why)):
            return (ended(why), [])

        case (.preparing, .hangUp):
            return (ended(nil), [.cancelPrepare])
        case (.connecting, .hangUp), (.live, .hangUp):
            return (ended(nil), [.disconnect])
        case (let phase, .newSession):
            let stop: [CallEffect] = phase == .preparing ? [.cancelPrepare] : phase == .idle ? [] : [.disconnect]
            return (ended(nil), stop + [.forgetSession])
        case (let phase, .micDenied):
            return (ended(micWarning), phase == .idle ? [] : phase == .preparing ? [.cancelPrepare] : [.disconnect])

        default:  // a late event of a call that has ended, or one that does not apply in this phase
            return (s, [])
        }
    }

    static func ended(_ warning: String?) -> CallState {
        var s = CallState()
        s.warning = warning
        return s
    }
}
