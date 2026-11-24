import Foundation

/// Text from a context provider, as the agent service takes it (decision 0020): a name, never a path.
public struct Source: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case markdown, text, pdf, document, code }
    public var name: String
    public var kind: Kind
    public var text: String

    public init(name: String, kind: Kind, text: String) {
        self.name = name
        self.kind = kind
        self.text = text
    }
}

/// How much of a source went into the prompt.
public struct SourceUse: Codable, Equatable, Sendable {
    public var name: String
    public var kind: String
    public var chars: Int
    public var used: Int
    public var whole: Bool
}

/// The voice settings of a session. v1 calls are Gemini Live (decision 0019).
public struct SessionConfig: Codable, Equatable, Sendable {
    public var voiceMode = "gemini-live"
    public var geminiModel: String?
    public var geminiVoice: String?
    public var geminiPersonas: Bool?
    public var geminiSearch: Bool?
    public var geminiScreen: Bool?

    public init(geminiModel: String? = nil, geminiVoice: String? = nil, geminiPersonas: Bool? = nil,
                geminiSearch: Bool? = nil, geminiScreen: Bool? = nil) {
        self.geminiModel = geminiModel
        self.geminiVoice = geminiVoice
        self.geminiPersonas = geminiPersonas
        self.geminiSearch = geminiSearch
        self.geminiScreen = geminiScreen
    }

    enum CodingKeys: String, CodingKey {
        case voiceMode = "voice_mode", geminiModel = "gemini_model", geminiVoice = "gemini_voice"
        case geminiPersonas = "gemini_personas", geminiSearch = "gemini_search", geminiScreen = "gemini_screen"
    }
}

public struct SessionInfo: Decodable, Equatable, Sendable {
    public var id: String
    public var topic: String
    public var sources: [SourceUse]
}

public struct VoiceStatus: Decodable, Equatable, Sendable {
    public var url: String
    public var dev: Bool
    public var local: Bool
    public var livekit: Bool?
    public var worker: Bool?
}

public struct VoiceToken: Decodable, Equatable, Sendable {
    public var url: String
    public var room: String
    public var identity: String
    public var token: String
}

public struct GeminiOptions: Decodable, Equatable, Sendable {
    public var available: Bool
    public var models: [String]
    public var defaultModel: String
    public var voices: [String]
    public var defaultVoice: String

    enum CodingKeys: String, CodingKey {
        case available, models, voices, defaultModel = "default_model", defaultVoice = "default_voice"
    }
}

/// A box the vision model found (`POST /v1/ground`): `box` is [ymin, xmin, ymax, xmax], 0 to 1000 over the image.
public struct GroundBox: Codable, Equatable, Sendable {
    public var box: [Int]
    public var label: String
    public var confidence: Double?

    public init(box: [Int], label: String = "", confidence: Double? = nil) {
        self.box = box
        self.label = label
        self.confidence = confidence
    }
}

public struct AgentError: Error, Equatable, LocalizedError {
    public var status: Int  // 0: no answer
    public var message: String
    public var errorDescription: String? { message }

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }

    public var isMissingSession: Bool { status == 404 }
}

/// The agent service's HTTP API, as the app uses it.
public protocol AgentAPI: Sendable {
    func health() async throws -> Bool
    func voiceStatus() async throws -> VoiceStatus?
    func gemini() async throws -> GeminiOptions
    func createSession(topic: String, config: SessionConfig, sources: [Source]) async throws -> SessionInfo
    func saveConfig(session: String, config: SessionConfig) async throws
    func token(session: String) async throws -> VoiceToken
    /// The session's state for the inspector, or nil when it has not changed since `version`.
    func state(session: String, since version: Int?) async throws -> [String: JSONValue]?
    /// Where a described thing is on a JPEG of the screen. `strict` checks every answer on its crop.
    func ground(image: Data, query: String, strict: Bool) async throws -> [GroundBox]
}
