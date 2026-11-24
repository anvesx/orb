import OrbKit
import SwiftUI

/// What the orb shows: the call's phase, the microphone and the agent's state, folded into six looks. "Listening"
/// means orb hears you (the microphone is open); a call with a closed microphone is "ready".
public enum Mood: Equatable, Sendable {
    case idle, ready, connecting, listening, thinking, speaking

    public init(_ call: CallState, youSpeaking: Bool = false) {
        switch call.phase {
        case .idle: self = .idle
        case .preparing, .connecting: self = .connecting
        case .live:
            if call.micOn || youSpeaking { self = .listening; return }
            switch call.agent {
            case .thinking: self = .thinking
            case .speaking: self = .speaking
            case .initializing, nil: self = .connecting
            default: self = .ready
            }
        }
    }

    public var words: String {
        switch self {
        case .idle: "orb"
        case .ready: "Ready"
        case .connecting: "Connecting…"
        case .listening: "Listening"
        case .thinking: "Thinking…"
        case .speaking: "Speaking"
        }
    }

    public var tint: Color {
        switch self {
        case .idle: Theme.idle
        case .ready: Theme.ink2
        case .connecting, .thinking: Theme.think
        case .listening: Theme.listen
        case .speaking: Theme.speak
        }
    }
}
