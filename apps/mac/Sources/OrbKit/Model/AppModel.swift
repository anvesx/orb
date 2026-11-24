import AVFoundation
import Foundation
import Observation
import os

let trace = Logger(subsystem: "ai.anvesx.orb", category: "call")

/// The one model that the UI reads. It runs the call machine's effects and talks to the service, the voice
/// transport and the context providers. The UI calls its intents only.
@MainActor @Observable
public final class AppModel {
    public struct Timing: Sendable {
        public var tail: Duration = .milliseconds(300)
        public var agentJoin: Duration = .seconds(15)
        public init() {}
    }

    public private(set) var call = CallState()
    public private(set) var captions = Captions()
    /// What orb has drawn on the screen (screen-canvas.md section 4); the companion goes to its focus.
    public private(set) var canvas = CanvasState()
    /// "Preview · pricing.pdf": what orb last read on the screen in this call.
    public private(set) var seeing: String?
    /// Whether orb may capture the screen (nil: not asked yet).
    public private(set) var screenAllowed: Bool?
    /// Whether the call's screen track is on.
    public private(set) var sharing = false
    public private(set) var sessionID: String?
    public private(set) var serviceUp: Bool?
    public private(set) var gemini: GeminiOptions?
    public private(set) var youSpeaking = false
    /// A problem that does not end the call (a worker error, a reply with no words).
    public private(set) var notice: String?
    public private(set) var events: [String] = []
    /// The inspector's view of the session (polled while the inspector is open) and the call's latency table.
    public private(set) var engine: EngineView?
    public private(set) var turnLog = TurnLog()
    @ObservationIgnored var engineSession: String?
    public var settings: Settings { didSet { settings.save() } }
    /// How the talk shortcut reads, for the hints (the app sets it).
    public var talkShortcut = "⌥ Space"
    /// Why the double tap of ⌥ cannot work, or nil (the app sets it: it needs the Accessibility permission).
    public var doubleTapBlocked: String?

    public let screen: ScreenService?
    public var levels: AudioLevels { transport.levels }
    public var warning: String? { call.warning ?? notice }

    let transport: VoiceTransport
    let makeAPI: @Sendable (URL) -> AgentAPI
    let timing: Timing
    let microphone: @Sendable () async -> Bool
    @ObservationIgnored var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var micChain: Task<Void, Never>?

    public init(transport: VoiceTransport, screen: ScreenService? = nil, settings: Settings = .load(),
                timing: Timing = Timing(), microphone: @escaping @Sendable () async -> Bool = AppModel.askMicrophone,
                makeAPI: @escaping @Sendable (URL) -> AgentAPI = { AgentClient(base: $0) }) {
        self.transport = transport
        self.screen = screen
        self.settings = settings
        self.timing = timing
        self.makeAPI = makeAPI
        self.microphone = microphone
    }

    var api: AgentAPI { makeAPI(settings.serviceBase) }

    // MARK: - Intents

    public func talkDown() { send(.talkDown) }
    public func talkUp() { send(.talkUp) }
    public func hangUp() { send(.hangUp) }
    public func toggleHandsFree() { send(.toggleHandsFree) }
    public func newSession() { send(.newSession) }

    /// Is the service up, which Gemini options does it have, and may orb see the screen.
    public func refresh() {
        tasks["refresh"]?.cancel()
        tasks["refresh"] = Task {
            let api = self.api
            serviceUp = (try? await api.health()) ?? false
            gemini = try? await api.gemini()
            if let screen { screenAllowed = await screen.allowed(ask: false) }
        }
    }

    /// Polls the session's state every 0.7 s while `on` (the web page's rate on this machine).
    public func inspect(_ on: Bool) {
        cancel("poll")
        guard on else { return }
        tasks["poll"] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func poll() async {
        guard let sid = sessionID else { return }
        if engineSession != sid { engine = nil; engineSession = sid }
        do {
            if let state = try await api.state(session: sid, since: engine?.version), sid == sessionID {
                engine = EngineView(state: state)
            }
        } catch let e as AgentError where e.isMissingSession && sid == sessionID {
            run(.forgetSession)  // the service restarted: the next call makes the session again
        } catch {}
    }

    // MARK: - The machine

    public func send(_ event: CallEvent) {
        let (next, effects) = CallMachine.reduce(call, event)
        trace.debug("event \(String(describing: event), privacy: .public) -> \(String(describing: next.phase), privacy: .public) mic \(next.micOn) hands-free \(next.handsFree) effects \(String(describing: effects), privacy: .public)")
        call = next
        effects.forEach(run)
    }

    func run(_ effect: CallEffect) {
        switch effect {
        case .prepare:
            notice = nil
            captions = Captions()
            turnLog = TurnLog()
            seeing = nil
            tasks["prepare"] = Task { await prepare() }
        case .cancelPrepare:
            cancel("prepare")
        case .connect(let token):
            tasks["call"] = Task { await connect(token) }
        case .disconnect:
            ["call", "tail", "join", "idle"].forEach(cancel)
            youSpeaking = false
            draw(.clear)
            sharing = false
            Task { [screen] in
                await screen?.feed(nil)
                await transport.disconnect()
            }
        case .setMic(let on):
            micChain = Task { [previous = micChain, transport] in
                await previous?.value
                try? await transport.setMicrophone(on)
            }
        case .startTail:
            after("tail", timing.tail) { $0.send(.tailElapsed) }
        case .startAgentJoinTimer:
            after("join", timing.agentJoin) { $0.send(.agentJoinTimeout) }
        case .cancelAgentJoinTimer:
            cancel("join")
        case .restartIdleTimer:
            after("idle", .seconds(settings.idleMinutes * 60)) { $0.send(.idleTimeout) }
        case .forgetSession:
            sessionID = nil
        }
    }

    func after(_ name: String, _ delay: Duration, _ then: @escaping @MainActor (AppModel) -> Void) {
        tasks[name]?.cancel()
        tasks[name] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            then(self)
        }
    }

    func cancel(_ name: String) {
        tasks[name]?.cancel()
        tasks[name] = nil
    }

    // MARK: - Effects

    func prepare() async {
        guard await microphone() else { return send(.micDenied) }
        do {
            let api = self.api
            if let block = try await voiceBlock(api) { return send(.prepareFailed(block)) }
            let sid = try await session(api)
            let token = try await api.token(session: sid)
            try Task.checkCancellation()
            send(.prepared(token))
        } catch is CancellationError {
        } catch {
            if (error as? AgentError)?.status == 0 { serviceUp = false }
            send(.prepareFailed(error.localizedDescription))
        }
    }

    /// Why a call cannot start, as the web page says it, or nil.
    func voiceBlock(_ api: AgentAPI) async throws -> String? {
        guard let status = try await api.voiceStatus() else {
            return "Voice is off: the orb service has no LiveKit settings (LIVEKIT_URL and its keys)."
        }
        serviceUp = true
        if status.livekit == false { return "The voice server (LiveKit) is not running. Start it with make dev-gemini." }
        if status.worker == false { return "The voice worker is not running. Start it with make dev-gemini." }
        if (try? await api.gemini())?.available == false {
            return "Gemini Live needs GOOGLE_API_KEY in the orb repo's .env. Set it and restart make dev-gemini."
        }
        return nil
    }

    /// The session of this context: the current one with the current config, or a new one with the sources.
    /// A 404 means the service restarted and forgot it, so a new one gets the sources again.
    func session(_ api: AgentAPI) async throws -> String {
        if let sid = sessionID {
            do {
                try await api.saveConfig(session: sid, config: settings.config)
                return sid
            } catch let e as AgentError where e.isMissingSession {
                sessionID = nil
            }
        }
        let info = try await api.createSession(topic: "Open discussion", config: settings.config, sources: [])
        sessionID = info.id
        return info.id
    }

    func connect(_ token: VoiceToken) async {
        let stream: AsyncStream<VoiceEvent>
        do {
            stream = try await transport.connect(url: token.url, token: token.token)
        } catch {
            return send(.connectFailed(Self.explain(error, url: token.url)))
        }
        guard !Task.isCancelled else { return }
        send(.joined)
        await shareScreen()
        for await event in stream { handle(event) }
        send(.disconnected(nil))
    }

    /// The screen tools are always answered (a call with the screen off says so); the track starts when the setting
    /// is on and macOS allows it.
    func shareScreen() async {
        guard let screen else { return }
        await transport.serve(ScreenRPC.read) { [weak self] _ in await self?.answerRead() ?? "{}" }
        await transport.serve(CanvasOp.method) { [weak self] payload in await self?.answerCanvas(payload) ?? "{}" }
        guard settings.screen else { return }
        screenAllowed = await screen.allowed(ask: true)
        guard screenAllowed == true, call.phase == .live, let sink = await transport.startScreen() else { return }
        guard call.phase == .live else { return }
        sharing = true
        await screen.feed(sink)
        trace.debug("screen shared")
    }

    func answerRead() async -> String {
        guard let screen, settings.screen else { return CanvasAnswer.failed(Self.screenOff).json }
        let (answer, reading) = await ScreenRPC.answerRead(screen)
        seeing = reading.seeing
        trace.debug("screen read: \(answer.utf8.count) bytes")
        return answer
    }

    static let screenOff = "The person turned off screen sharing in orb."

    func answerCanvas(_ payload: String) async -> String {
        guard let screen, settings.screen else { return CanvasAnswer.failed(Self.screenOff).json }
        guard let op = CanvasOp.decode(payload) else { return CanvasAnswer.failed("orb did not understand the op.").json }
        switch op.op {
        case .clear:
            let n = canvas.annotations.count
            draw(.clear)
            return CanvasAnswer.cleared(n).json
        case .mark:
            guard let what = op.target, !what.isEmpty, let kind = op.kind else {
                return CanvasAnswer.failed("A mark needs a target and its kind.").json
            }
            switch await screen.ground(Target(what, kind: kind)) {
            case .notFound(let why):
                return CanvasAnswer.notFound(why).json
            case .found(let anchor, let by, let matches, let confidence):
                guard call.phase == .live else { return CanvasAnswer.notFound("The call ended.").json }
                let mark = Annotation(id: op.opId, kind: .mark(op.style ?? .underline), anchor: anchor, note: op.note ?? "")
                draw(.add(mark, opID: op.opId, at: .now))
                return CanvasAnswer.found(id: op.opId, by: by, matches: matches, confidence: confidence).json
            }
        }
    }

    func draw(_ event: CanvasEvent) {
        canvas = Canvas.reduce(canvas, event)
        guard let expires = canvas.expires, expires != .distantFuture else { return cancel("canvas") }
        after("canvas", .seconds(max(0, expires.timeIntervalSinceNow))) { $0.draw(.tick(.now)) }
    }

    func handle(_ event: VoiceEvent) {
        switch event {
        case .agentJoined: send(.agentJoined)
        case .agentState(let a):
            send(.agentState(a))
            draw(a == .speaking ? .orbSpeaking : .orbStopped(at: .now))
        case .youSpeaking(let on):
            youSpeaking = on
            if on {
                send(.youSpeaking)
                if call.agent != .speaking { draw(.youSpoke) }  // the speakers' echo is not you
            }
        case .yourWords(let segment, let text, let final):
            trace.debug("you said (\(final ? "final" : "interim", privacy: .public)): \(text, privacy: .private)")
            captions.yourWords(segment: segment, text: text, final: final)
        case .orbWords(let segment, let chunk):
            if segment != captions.orbSegment { trace.debug("orb starts a reply") }
            captions.orbWords(segment: segment, chunk: chunk)
        case .bench(let e):
            bench(e)
        case .reconnecting: send(.reconnecting)
        case .reconnected: send(.reconnected)
        case .disconnected(let why): send(.disconnected(why))
        }
    }

    func bench(_ e: BenchEvent) {
        log(e.summary)
        turnLog.add(e)
        switch e.type {
        case "polished":
            if e["applied"]?.bool == true, let heard = e["heard"]?.string, let text = e["text"]?.string {
                captions.polished(heard: heard, text: text)
            }
        case "error", "stt_error":
            notice = e["error"]?.string
        case "agent_reply":
            notice = e["chars"]?.number == 0 ? "orb wrote no words for this turn. Say it again." : nil
        default: break
        }
    }

    func log(_ line: String) {
        events.insert(Date.now.formatted(date: .omitted, time: .standard) + "  " + line, at: 0)
        if events.count > 200 { events.removeLast() }
    }

    public nonisolated static func askMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    static func explain(_ error: Error, url: String) -> String {
        let text = error.localizedDescription
        if text.lowercased().contains("pc connection") || text.lowercased().contains("peer connection") {
            return "The voice signal works, but the audio could not reach the computer that runs orb."
        }
        return "Voice did not start: \(text). The voice server is \(url); check that it and the voice worker run."
    }
}
