import Foundation
import Testing
@testable import OrbKit

@Suite struct VoiceTests {
    @Test func agentStatesUseTheWebPagesAliases() {
        #expect(AgentState(attribute: "speaking") == .speaking)
        #expect(AgentState(attribute: "disconnected") == .idle && AgentState(attribute: "") == .idle)
        #expect(AgentState(attribute: "pre-connect-buffering") == .listening)
        #expect(AgentState(attribute: "a-future-state") == .listening)
    }

    @Test func captionsFollowTheSegmentRules() {
        var c = Captions()
        c.yourWords(segment: "u1", text: "what does", final: false)
        c.yourWords(segment: "u1", text: "what does the plan say", final: true)
        c.orbWords(segment: "a1", chunk: "It sets ")
        c.orbWords(segment: "a1", chunk: "three dates.")
        #expect(c.you == "what does the plan say" && c.youFinal && c.orb == "It sets three dates.")
        c.polished(heard: "what does the plan say", text: "What does the plan say?")
        #expect(c.you == "What does the plan say?")
        c.yourWords(segment: "u2", text: "and", final: false)  // a new turn of yours: orb's last reply is old
        #expect(c.orb == "" && !c.youFinal)
        c.orbWords(segment: "a2", chunk: "Yes.")
        #expect(c.orb == "Yes.")
    }

    @Test func benchEventsDecodeTheWorkersPayloadsAndSummariseWithoutWords() throws {
        let e = try #require(BenchEvent(data: Data(#"{"type": "polished", "t": 1795488811.3, "heard": "hi there", "text": "Hi there.", "applied": true, "ms": 41.5}"#.utf8)))
        #expect(e.type == "polished" && e["applied"]?.bool == true && e["text"]?.string == "Hi there.")
        #expect(e.summary == "polished applied=true ms=41.500")
        #expect(BenchEvent(data: Data("not json".utf8)) == nil && BenchEvent(data: Data(#"{"no": "type"}"#.utf8)) == nil)
    }

    @Test func theLevelSmootherRisesFastAndFallsSlowly() {
        var s = LevelSmoother()
        #expect(s.step(1) == 0.5)
        let up = s.step(1)
        #expect(up == 0.75)
        #expect(s.step(0) > 0.6)
        #expect(s.step(5) <= 1)
    }
}
