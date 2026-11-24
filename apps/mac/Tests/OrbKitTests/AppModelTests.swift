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
    func ground(image: Data, query: String, strict: Bool) async throws -> [GroundBox] { [] }
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
    var served: [String: @Sendable (String) async -> String] = [:]
    var screens = 0

    func setMicrophone(_ on: Bool) async throws { mic.append(on) }
    func serve(_ method: String, _ handler: @escaping @Sendable (String) async -> String) async { served[method] = handler }
    func startScreen() async -> ScreenSink? {
        screens += 1
        return { _ in }
    }
    func disconnect() async { continuation?.finish() }
}

final class FakeScreen: ScreenService, @unchecked Sendable {
    var allow = true
    var fed: [Bool] = []
    var reading = ScreenReading(app: "Preview", window: "pricing.pdf", screenText: "Launch on the third of March")
    var grounded: Grounded = .found(anchor: .screen(displayID: 1, rects: [CGRect(x: 1, y: 2, width: 30, height: 10)], frameID: 3),
                                    by: .text, matches: 1, confidence: nil)
    var asked: [Target] = []

    func allowed(ask: Bool) async -> Bool { allow }
    func feed(_ sink: ScreenSink?) async { fed.append(sink != nil) }
    func read() async -> ScreenReading { reading }
    func ground(_ target: Target) async -> Grounded {
        asked.append(target)
        return grounded
    }
}

@MainActor
func waitFor(_ ok: () -> Bool) async {
    for _ in 0..<200 where !ok() { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor @Suite struct AppModelTests {
    let api = FakeAPI(), transport = FakeTransport(), screen = FakeScreen()

    func model(screenOn: Bool = true) -> AppModel {
        var settings = Settings()
        settings.idleMinutes = 10
        settings.screen = screenOn
        return AppModel(transport: transport, screen: screen, settings: settings, microphone: { true },
                        makeAPI: { [api] _ in api })
    }

    @Test func aPressMakesASessionJoinsAndOpensTheMic() async {
        let m = model()
        m.talkDown()
        await waitFor { m.call.phase == .live }
        #expect(api.created.map(\.topic) == ["Open discussion"] && api.created[0].sources.isEmpty)
        #expect(m.sessionID == "s1")
        await waitFor { transport.mic == [true] }
        transport.continuation?.yield(.orbWords(segment: "r1", chunk: "Hello."))
        await waitFor { m.captions.orb == "Hello." }
        #expect(m.captions.orb == "Hello.")
    }

    @Test func aForgottenSessionIsMadeAgain() async {
        let m = model()
        m.talkDown(); m.talkUp()
        await waitFor { m.call.phase == .live }
        m.hangUp()
        api.missing = ["s1"]  // the service restarted
        m.talkDown()
        await waitFor { m.sessionID == "s2" }
        #expect(api.created.count == 2)
    }

    @Test func aBlockedVoiceSaysWhy() async {
        api.status.worker = false
        let m = model()
        m.talkDown()
        await waitFor { m.call.warning != nil }
        #expect(m.call.phase == .idle && m.warning?.contains("voice worker is not running") == true)
    }

    @Test func aCallSharesTheScreenAndAnswersTheScreenTools() async throws {
        let m = model()
        m.talkDown()
        await waitFor { m.sharing }
        #expect(transport.screens == 1 && screen.fed == [true] && m.screenAllowed == true)
        let read = await transport.served[ScreenRPC.read]!("{}")
        #expect(read.contains("\"app\":\"Preview\"") && m.seeing == "Preview · pricing.pdf")
        let marked = await transport.served[CanvasOp.method]!(
            #"{"v":1,"op":"mark","opId":"a1","target":"third of March","kind":"text","style":"box","note":"date"}"#)
        #expect(marked == #"{"by":"text","found":true,"id":"a1","matches":1}"#)
        #expect(screen.asked == [Target("third of March", kind: .text)])
        #expect(m.canvas.focus?.kind == .mark(.box) && m.canvas.focus?.note == "date")
        screen.grounded = .notFound("\"refund policy\" is not on the screen.")
        let missed = await transport.served[CanvasOp.method]!(#"{"v":1,"op":"mark","opId":"a2","target":"refund policy","kind":"text"}"#)
        #expect(missed.contains("\"found\":false") && m.canvas.annotations.count == 1)
        #expect(await transport.served[CanvasOp.method]!(#"{"v":1,"op":"clear","opId":"a3"}"#) == #"{"cleared":1}"#)
        #expect(await transport.served[CanvasOp.method]!("nonsense").contains("did not understand"))
        m.hangUp()
        await waitFor { screen.fed == [true, false] }
        #expect(m.canvas.annotations.isEmpty && !m.sharing)
    }

    @Test func withTheScreenOffNothingIsSharedAndTheToolsSaySo() async {
        let m = model(screenOn: false)
        m.talkDown()
        await waitFor { transport.served.count == 2 }
        #expect(transport.screens == 0 && screen.fed.isEmpty)
        #expect(await transport.served[ScreenRPC.read]!("{}").contains("turned off screen sharing"))
        #expect(await transport.served[CanvasOp.method]!(#"{"v":1,"op":"clear","opId":"x"}"#).contains("turned off screen sharing"))
    }

    @Test func withoutThePermissionTheCallGoesOnWithVoiceOnly() async {
        screen.allow = false
        let m = model()
        m.talkDown()
        await waitFor { m.screenAllowed == false }
        #expect(m.call.phase == .live && transport.screens == 0 && !m.sharing)
    }

    @Test func marksGoWhenYouTalkButNotOnOrbsOwnEcho() async {
        let m = model()
        m.talkDown()
        await waitFor { transport.served.count == 2 }
        _ = await transport.served[CanvasOp.method]!(#"{"v":1,"op":"mark","opId":"a1","target":"robot","kind":"visual","style":"circle"}"#)
        #expect(m.canvas.annotations.count == 1)
        transport.continuation?.yield(.agentState(.speaking))
        transport.continuation?.yield(.youSpeaking(true))
        await waitFor { m.call.agent == .speaking && m.youSpeaking }
        #expect(m.canvas.annotations.count == 1 && m.canvas.expires == .distantFuture)
        transport.continuation?.yield(.agentState(.listening))
        transport.continuation?.yield(.youSpeaking(true))
        await waitFor { m.canvas.annotations.isEmpty }
        #expect(m.canvas.annotations.isEmpty)
    }
}
