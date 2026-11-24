import Foundation
import Testing
@testable import OrbKit

final class FakeAPI: AgentAPI, @unchecked Sendable {
    var created: [(topic: String, sources: [Source])] = []
    var missing: Set<String> = []
    var nextID = 0
    var status = VoiceStatus(url: "wss://x", dev: false, local: false, livekit: true, worker: true)

    func health() async throws -> Bool { true }
    func voiceStatus() async throws -> VoiceStatus? { status }
    func gemini() async throws -> GeminiOptions {
        GeminiOptions(available: true, models: ["m"], defaultModel: "m", voices: ["Kore"], defaultVoice: "Kore")
    }
    func createSession(topic: String, config: SessionConfig, sources: [Source]) async throws -> SessionInfo {
        created.append((topic, sources))
        nextID += 1
        return SessionInfo(id: "s\(nextID)", topic: topic, sources: sources.map {
            SourceUse(name: $0.name, kind: $0.kind.rawValue, chars: $0.text.count, used: $0.text.count, whole: true) })
    }
    func saveConfig(session: String, config: SessionConfig) async throws {
        if missing.contains(session) { throw AgentError(status: 404, message: "There is no session \(session).") }
    }
    func token(session: String) async throws -> VoiceToken { VoiceToken(url: "wss://x", room: "orb-\(session)", identity: "u", token: "t") }
    func state(session: String, since version: Int?) async throws -> [String: JSONValue]? { nil }
}

final class FakeTransport: VoiceTransport, @unchecked Sendable {
    let levels = AudioLevels()
    var mic: [Bool] = []
    var continuation: AsyncStream<VoiceEvent>.Continuation?

    func connect(url: String, token: String) async throws -> AsyncStream<VoiceEvent> {
        let (stream, c) = AsyncStream<VoiceEvent>.makeStream()
        continuation = c
        return stream
    }
    func setMicrophone(_ on: Bool) async throws { mic.append(on) }
    func disconnect() async { continuation?.finish() }
}

struct Notes: ContextProvider {
    let id = "notes", title = "Notes"
    func suggestions() async -> [ContextItem] { [] }
    func sources(for items: [ContextItem]) async -> [Source] { items.map { Source(name: $0.title, kind: .text, text: "text of \($0.title)") } }
}

@MainActor
func waitFor(_ ok: () -> Bool) async {
    for _ in 0..<200 where !ok() { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor @Suite struct AppModelTests {
    let api = FakeAPI(), transport = FakeTransport()

    func model() -> AppModel {
        var settings = Settings()
        settings.idleMinutes = 10
        return AppModel(transport: transport, providers: [Notes()], settings: settings, microphone: { true },
                        makeAPI: { [api] _ in api })
    }

    @Test func aPressMakesASessionWithTheContextJoinsAndOpensTheMic() async {
        let m = model()
        m.add(ContextItem(id: "notes:a", provider: "notes", title: "a.md"))
        m.talkDown()
        await waitFor { m.call.phase == .live }
        #expect(api.created.map(\.topic) == ["a.md"] && api.created[0].sources.map(\.text) == ["text of a.md"])
        #expect(m.sessionID == "s1" && m.sourceUses.map(\.name) == ["a.md"])
        await waitFor { transport.mic == [true] }
        transport.continuation?.yield(.orbWords(segment: "r1", chunk: "Hello."))
        await waitFor { m.captions.orb == "Hello." }
        #expect(m.captions.orb == "Hello.")
    }

    @Test func aForgottenSessionIsMadeAgainWithItsSources() async {
        let m = model()
        m.add(ContextItem(id: "notes:a", provider: "notes", title: "a.md"))
        m.talkDown(); m.talkUp()
        await waitFor { m.call.phase == .live }
        m.hangUp()
        api.missing = ["s1"]  // the service restarted
        m.talkDown()
        await waitFor { m.sessionID == "s2" }
        #expect(api.created.count == 2 && api.created[1].sources.count == 1)
    }

    @Test func aBlockedVoiceSaysWhy() async {
        api.status.worker = false
        let m = model()
        m.talkDown()
        await waitFor { m.call.warning != nil }
        #expect(m.call.phase == .idle && m.warning?.contains("voice worker is not running") == true)
    }

    @Test func changingTheContextEndsTheSession() async {
        let m = model()
        m.talkDown(); m.talkUp()
        await waitFor { m.call.phase == .live }
        m.add(ContextItem(id: "notes:b", provider: "notes", title: "b.md"))
        #expect(m.call.phase == .idle && m.sessionID == nil && m.context.count == 1)
    }
}
