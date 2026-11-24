import Testing
@testable import OrbKit

let token = VoiceToken(url: "wss://lk.test", room: "orb-s1", identity: "user-1", token: "t")

/// Runs events from idle; returns the final state and every effect in order.
func run(_ events: [CallEvent], from start: CallState = CallState()) -> (CallState, [CallEffect]) {
    events.reduce((start, [CallEffect]())) { acc, e in
        let (s, fx) = CallMachine.reduce(acc.0, e)
        return (s, acc.1 + fx)
    }
}

@Suite struct CallMachineTests {
    @Test func aPressHeldThroughTheJoinOpensTheMicAtTheJoin() {
        let (s, fx) = run([.talkDown, .prepared(token), .joined])
        #expect(s.phase == .live && s.micOn)
        #expect(fx == [.prepare, .connect(token), .setMic(true), .startAgentJoinTimer, .restartIdleTimer])
    }

    @Test func aPressReleasedBeforeTheJoinSendsNothingAndTheCallStaysWarm() {
        let (s, fx) = run([.talkDown, .talkUp, .prepared(token), .joined])
        #expect(s.phase == .live && !s.micOn)
        #expect(!fx.contains(.setMic(true)))
    }

    @Test func releaseClosesTheMicAfterTheTailUnlessTheKeyIsPressedAgain() {
        let live = run([.talkDown, .prepared(token), .joined]).0
        let (closed, fx) = run([.talkUp, .tailElapsed], from: live)
        #expect(!closed.micOn && fx == [.startTail, .setMic(false), .restartIdleTimer])
        let (open, fx2) = run([.talkUp, .talkDown, .tailElapsed], from: live)
        #expect(open.micOn && fx2 == [.startTail])
    }

    @Test func theIdleTimeoutEndsAQuietCallButWaitsWhileOrbSpeaks() {
        let live = run([.talkDown, .talkUp, .prepared(token), .joined]).0
        let (speaking, fx) = run([.agentState(.speaking), .idleTimeout], from: live)
        #expect(speaking.phase == .live && fx == [.restartIdleTimer, .restartIdleTimer])
        let (ended, fx2) = run([.agentState(.listening), .idleTimeout], from: live)
        #expect(ended.phase == .idle && ended.warning == nil && fx2 == [.disconnect])
    }

    @Test func aWorkerThatNeverJoinsGivesAWarningThatGoesWhenItJoins() {
        let live = run([.talkDown, .prepared(token), .joined, .agentJoinTimeout]).0
        #expect(live.warning == CallMachine.agentJoinWarning)
        #expect(run([.agentJoined], from: live).0.warning == nil)
    }

    @Test func failuresAndDisconnectsEndTheCallWithTheReason() {
        #expect(run([.talkDown, .prepareFailed("no LiveKit")]).0 == { var s = CallState(); s.warning = "no LiveKit"; return s }())
        #expect(run([.talkDown, .prepared(token), .connectFailed("pc")]).0.warning == "pc")
        let (s, _) = run([.talkDown, .prepared(token), .joined, .disconnected("server left")])
        #expect(s.phase == .idle && s.warning == "server left")
    }

    @Test func newSessionCancelsWhatRunsAndForgetsTheSession() {
        #expect(run([.talkDown, .newSession]).1 == [.prepare, .cancelPrepare, .forgetSession])
        #expect(run([.talkDown, .prepared(token), .joined, .newSession]).1.suffix(2) == [.disconnect, .forgetSession])
        #expect(run([.newSession]).1 == [.forgetSession])
    }

    @Test func aDeniedMicrophoneEndsTheCallWithHelp() {
        let (s, fx) = run([.talkDown, .micDenied])
        #expect(s.phase == .idle && s.warning == CallMachine.micWarning && fx == [.prepare, .cancelPrepare])
    }

    @Test func lateEventsOfAnEndedCallChangeNothing() {
        let (s, fx) = run([.joined, .agentState(.speaking), .tailElapsed, .disconnected(nil), .hangUp])
        #expect(s == CallState() && fx.isEmpty)
    }

    @Test func reconnectingIsShownAndCleared() {
        let live = run([.talkDown, .prepared(token), .joined]).0
        #expect(run([.reconnecting], from: live).0.reconnecting)
        #expect(!run([.reconnecting, .reconnected], from: live).0.reconnecting)
    }
}
