import Testing
@testable import OrbKit

@Suite struct HandsFreeTests {
    @Test func aDoubleTapStartsACallWithTheMicOpenAndNoKeyHeld() {
        let (s, fx) = run([.toggleHandsFree, .prepared(token), .joined])
        #expect(s.phase == .live && s.handsFree && s.micOn && !s.keyDown)
        #expect(fx == [.prepare, .connect(token), .setMic(true), .startAgentJoinTimer, .restartIdleTimer])
    }

    @Test func anotherDoubleTapClosesTheMicAndKeepsTheCallWarm() {
        let live = run([.toggleHandsFree, .prepared(token), .joined]).0
        let (s, fx) = run([.toggleHandsFree], from: live)
        #expect(s.phase == .live && !s.handsFree && !s.micOn && fx == [.setMic(false), .restartIdleTimer])
    }

    @Test func holdingAndReleasingTheKeyDoesNotCloseAHandsFreeMic() {
        let live = run([.toggleHandsFree, .prepared(token), .joined]).0
        let (s, fx) = run([.talkDown, .talkUp, .tailElapsed], from: live)
        #expect(s.micOn && fx.isEmpty)
    }

    @Test func handsFreeFromAWarmCallOpensTheMic() {
        let warm = run([.talkDown, .talkUp, .prepared(token), .joined]).0
        let (s, fx) = run([.toggleHandsFree], from: warm)
        #expect(s.micOn && fx == [.setMic(true), .restartIdleTimer])
    }

    @Test func aSilentHandsFreeCallEndsAfterTheIdleTimeoutButNotWhileOrbSpeaks() {
        let live = run([.toggleHandsFree, .prepared(token), .joined]).0
        #expect(run([.agentState(.speaking), .idleTimeout], from: live).0.phase == .live)
        let (s, fx) = run([.agentState(.listening), .idleTimeout], from: live)
        #expect(s.phase == .idle && fx == [.disconnect])
    }

    @Test func aDoubleTapWhileConnectingIsDecidedAtTheJoin() {
        let (s, _) = run([.toggleHandsFree, .toggleHandsFree, .prepared(token), .joined])
        #expect(!s.handsFree && !s.micOn)
    }
}

@Suite struct DoubleTapTests {
    func taps(_ events: [(String, Double)]) -> [Bool] {
        var d = DoubleTap()
        return events.compactMap { kind, t -> Bool? in
            switch kind {
            case "down": d.modifierDown(at: t); return nil
            case "up": return d.modifierUp(at: t)
            default: d.otherKey(); return nil
            }
        }
    }

    @Test func twoQuickTapsCount() {
        #expect(taps([("down", 0), ("up", 0.08), ("down", 0.25), ("up", 0.33)]) == [false, true])
    }

    @Test func aSlowSecondTapAHoldOrAKeyBetweenDoNot() {
        #expect(taps([("down", 0), ("up", 0.08), ("down", 0.7), ("up", 0.78)]) == [false, false])
        #expect(taps([("down", 0), ("up", 0.5), ("down", 0.6), ("up", 0.68)]) == [false, false])
        #expect(taps([("down", 0), ("up", 0.08), ("key", 0.1), ("down", 0.2), ("up", 0.28)]) == [false, false])
    }

    @Test func threeTapsToggleOnceThenStartOver() {
        #expect(taps([("down", 0), ("up", 0.05), ("down", 0.15), ("up", 0.2), ("down", 0.3), ("up", 0.35)]) == [false, true, false])
    }
}
