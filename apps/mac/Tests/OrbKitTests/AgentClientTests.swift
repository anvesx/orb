import Foundation
import Testing
@testable import OrbKit

/// Answers requests from a table and records them. One URLSession per test: the stub is per session.
final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answers: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var seen: [(method: String, path: String, body: String)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let key = "\(request.httpMethod!) \(url.path)" + (url.query.map { "?" + $0 } ?? "")
        let body = request.httpBodyStream.map { s -> String in
            s.open(); defer { s.close() }
            var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            return String(decoding: data, as: UTF8.self)
        } ?? ""
        Self.seen.append((request.httpMethod!, key, body))
        let (status, json) = Self.answers[key] ?? (404, #"{"error": "There is no route \#(key)."}"#)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func client() -> AgentClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return AgentClient(base: URL(string: "http://127.0.0.1:8100")!, session: URLSession(configuration: config))
    }
}

@Suite(.serialized) struct AgentClientTests {
    init() { Stub.answers = [:]; Stub.seen = [] }

    @Test func createSendsTheTopicConfigAndSourcesAndReadsWhatFitInThePrompt() async throws {
        Stub.answers["POST /v1/sessions"] = (201, #"{"id": "s1", "topic": "Notes", "sources": [{"name": "a.md", "kind": "markdown", "chars": 5, "used": 5, "whole": true}], "messages": []}"#)
        let info = try await Stub.client().createSession(topic: "Notes", config: SessionConfig(geminiVoice: "Kore"),
                                                         sources: [Source(name: "a.md", kind: .markdown, text: "hello")])
        #expect(info == SessionInfo(id: "s1", topic: "Notes", sources: [SourceUse(name: "a.md", kind: "markdown", chars: 5, used: 5, whole: true)]))
        let body = try JSONSerialization.jsonObject(with: Data(Stub.seen[0].body.utf8)) as! [String: Any]
        #expect((body["config"] as! [String: Any])["voice_mode"] as? String == "gemini-live")
        #expect((body["config"] as! [String: Any])["gemini_voice"] as? String == "Kore")
        #expect(((body["sources"] as! [[String: Any]])[0]["kind"]) as? String == "markdown")
    }

    @Test func noSourcesSendsNoSourcesField() async throws {
        Stub.answers["POST /v1/sessions"] = (201, #"{"id": "s2", "topic": "Open discussion", "sources": []}"#)
        _ = try await Stub.client().createSession(topic: "Open discussion", config: SessionConfig(), sources: [])
        #expect(!Stub.seen[0].body.contains("sources"))
    }

    @Test func errorsCarryTheServicesTextAndA404SaysTheSessionIsGone() async throws {
        let e = await #expect(throws: AgentError.self) {
            try await Stub.client().saveConfig(session: "gone-1", config: SessionConfig())
        }
        #expect(e?.isMissingSession == true && e?.message == "There is no route PUT /v1/sessions/gone-1/config.")
    }

    @Test func voiceStatusTokenAndAnUnchangedState() async throws {
        Stub.answers["GET /v1/voice/status"] = (200, #"{"url": "wss://x", "dev": false, "local": false, "proxy": false, "livekit": true, "worker": false}"#)
        Stub.answers["POST /v1/voice/token"] = (200, #"{"url": "wss://x", "room": "orb-s1", "identity": "user-1", "token": "jwt"}"#)
        Stub.answers["GET /v1/sessions/s1?since=4"] = (200, #"{"version": 4, "unchanged": true}"#)
        let c = Stub.client()
        #expect(try await c.voiceStatus()?.worker == false)
        #expect(try await c.token(session: "s1").room == "orb-s1")
        #expect(Stub.seen[1].body == #"{"session_id":"s1"}"#)
        #expect(try await c.state(session: "s1", since: 4) == nil)
    }

    @Test func aServiceThatDoesNotAnswerSaysHowToStartIt() async {
        let c = AgentClient(base: URL(string: "http://127.0.0.1:1")!)
        let e = await #expect(throws: AgentError.self) { try await c.health() }
        #expect(e?.status == 0 && e?.message.contains("make dev-gemini") == true)
    }
}
