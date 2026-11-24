import Foundation

/// What the person chose in Settings. Saved in UserDefaults as one JSON value.
public struct Settings: Codable, Equatable, Sendable {
    public var serviceURL = "http://127.0.0.1:8100"
    public var geminiModel: String?
    public var geminiVoice: String?
    public var personas = false
    /// Google Search. A new key: the old "search" was off by default and saved as off.
    public var webSearch = true
    public var screen = true
    public var companion = true
    public var bubble = true
    public var idleMinutes = 3.0
    public var doubleTapOption = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        serviceURL = try c.decodeIfPresent(String.self, forKey: .serviceURL) ?? d.serviceURL
        geminiModel = try c.decodeIfPresent(String.self, forKey: .geminiModel)
        geminiVoice = try c.decodeIfPresent(String.self, forKey: .geminiVoice)
        personas = try c.decodeIfPresent(Bool.self, forKey: .personas) ?? d.personas
        webSearch = try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? d.webSearch
        screen = try c.decodeIfPresent(Bool.self, forKey: .screen) ?? d.screen
        companion = try c.decodeIfPresent(Bool.self, forKey: .companion) ?? d.companion
        bubble = try c.decodeIfPresent(Bool.self, forKey: .bubble) ?? d.bubble
        idleMinutes = try c.decodeIfPresent(Double.self, forKey: .idleMinutes) ?? d.idleMinutes
        doubleTapOption = try c.decodeIfPresent(Bool.self, forKey: .doubleTapOption) ?? d.doubleTapOption
    }

    static let key = "orb.settings"

    public static func load(_ defaults: UserDefaults = .standard) -> Settings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    public var serviceBase: URL { URL(string: serviceURL) ?? URL(string: Settings().serviceURL)! }

    public var config: SessionConfig {
        SessionConfig(geminiModel: geminiModel, geminiVoice: geminiVoice, geminiPersonas: personas, geminiSearch: webSearch,
                      geminiScreen: screen)
    }
}
