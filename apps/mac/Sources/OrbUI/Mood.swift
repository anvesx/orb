import OrbKit
import SwiftUI

/// What the orb shows: the call's phase and the agent's state, folded into five looks.
public enum Mood: Equatable, Sendable {
    case idle, connecting, listening, thinking, speaking

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
            default: self = .listening
            }
        }
    }

    public var words: String {
        switch self {
        case .idle: "orb"
        case .connecting: "Connecting…"
        case .listening: "Listening"
        case .thinking: "Thinking…"
        case .speaking: "Speaking"
        }
    }

    public var tint: Color {
        switch self {
        case .idle: Theme.idle
        case .connecting, .thinking: Theme.think
        case .listening: Theme.listen
        case .speaking: Theme.speak
        }
    }
}
