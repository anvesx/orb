import Foundation

/// The agent service over HTTP (apps/agent, default http://127.0.0.1:8100). Errors carry the service's own text.
public struct AgentClient: AgentAPI {
    public let base: URL
    let session: URLSession

    public init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    public func health() async throws -> Bool {
        struct Health: Decodable { var ok: Bool }
        return try await get("health", as: Health.self).ok
    }

    public func voiceStatus() async throws -> VoiceStatus? {
        try await get("v1/voice/status", as: VoiceStatus?.self)
    }

    public func gemini() async throws -> GeminiOptions {
        struct Models: Decodable { var gemini: GeminiOptions }
        return try await get("v1/models", as: Models.self).gemini
    }

    public func createSession(topic: String, config: SessionConfig, sources: [Source]) async throws -> SessionInfo {
        struct Body: Encodable { var topic: String; var config: SessionConfig; var sources: [Source]? }
        return try await send("POST", "v1/sessions", Body(topic: topic, config: config, sources: sources.isEmpty ? nil : sources),
                              as: SessionInfo.self)
    }

    public func saveConfig(session id: String, config: SessionConfig) async throws {
        _ = try await send("PUT", "v1/sessions/\(id)/config", config, as: JSONValue.self)
    }

    public func token(session id: String) async throws -> VoiceToken {
        struct Body: Encodable { var session_id: String }
        return try await send("POST", "v1/voice/token", Body(session_id: id), as: VoiceToken.self)
    }

    public func state(session id: String, since version: Int?) async throws -> [String: JSONValue]? {
        let path = "v1/sessions/\(id)" + (version.map { "?since=\($0)" } ?? "")
        let state = try await get(path, as: [String: JSONValue].self)
        return state["unchanged"]?.bool == true ? nil : state
    }

    public func ground(image: Data, query: String, strict: Bool) async throws -> [GroundBox] {
        struct Body: Encodable { var image: String; var query: String; var strict: Bool }
        struct Answer: Decodable { var boxes: [GroundBox] }
        let body = Body(image: image.base64EncodedString(), query: query, strict: strict)
        return try await send("POST", "v1/ground", body, as: Answer.self).boxes
    }

    // MARK: - HTTP

    func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        try await run(request(path, method: "GET"), as: T.self)
    }

    func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, _ body: B, as: T.Type) async throws -> T {
        var r = request(path, method: method)
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try JSONEncoder().encode(body)
        return try await run(r, as: T.self)
    }

    func request(_ path: String, method: String) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!, timeoutInterval: 20)
        r.httpMethod = method
        return r
    }

    func run<T: Decodable>(_ r: URLRequest, as: T.Type) async throws -> T {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: r)
        } catch {
            throw AgentError(status: 0, message: "The orb service does not answer at \(base.absoluteString). Start it with make dev-gemini.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["error"]
            let text = error.map { $0.string ?? "\($0)" }
            throw AgentError(status: status, message: text ?? "The orb service answered HTTP \(status).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
