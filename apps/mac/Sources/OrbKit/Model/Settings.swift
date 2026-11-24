import Foundation

/// What the person chose in Settings. Saved in UserDefaults as one JSON value.
public struct Settings: Codable, Equatable, Sendable {
    public var serviceURL = "http://127.0.0.1:8100"
    public var geminiModel: String?
    public var geminiVoice: String?
    public var personas = false
    public var search = false
    public var companion = true
    public var bubble = true
    public var idleMinutes = 3.0

    public init() {}

    static let key = "orb.settings"

    public static func load(_ defaults: UserDefaults = .standard) -> Settings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    public var config: SessionConfig {
        SessionConfig(geminiModel: geminiModel, geminiVoice: geminiVoice, geminiPersonas: personas, geminiSearch: search)
    }
}
