import Foundation
import Testing
@testable import OrbKit

func fixture(_ name: String) throws -> [String: JSONValue] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
}

func bench(_ json: String) -> BenchEvent { BenchEvent(data: Data(json.utf8))! }

@Suite struct InspectorTests {
    /// A real state of the agent service after one note and one reply (captured 2026-11-24).
    @Test func theEngineViewReadsARealSessionState() throws {
        let e = try #require(EngineView(state: try fixture("session-state")))
        #expect(e.messages?.map(\.speaker) == ["human", "ai"] && e.messages?[0].channel == "voice")
        let turn = try #require(e.turn(replying: 1))
        #expect(turn.decision?.persona != nil && turn.decision?.move != nil)
        #expect(e.scores?["Reflection"] == EngineView.Score(owed: 1, paid: 1, due: false))
        #expect(e.board?.first?.id == "D1" && e.board?.first?.status == "paid" && e.board?.first?.paid == 1)
        #expect(e.lastCall?.tokens == 905 && e.lastCall?.questions?.isEmpty == false)
        #expect(e.stage == "Open" && e.version == 4 && (e.costUSD ?? 0) > 0)
    }

    @Test func aStateWithoutTheEngineFieldsStillDecodes() {
        #expect(EngineView(state: ["version": .number(1)])?.messages == nil)
    }

    @Test func theTurnLogBuildsOneRowPerTurnFromTheWorkersEvents() {
        var log = TurnLog()
        for e in [
            #"{"type": "metrics", "metrics": {"type": "eou_metrics", "end_of_utterance_delay": 0.42}}"#,
            #"{"type": "agent_read", "seconds": 0.8}"#,
            #"{"type": "agent_decision", "persona": "Examiner"}"#,
            #"{"type": "metrics", "metrics": {"type": "tts_metrics", "ttfb": 0.3}}"#,
            #"{"type": "metrics", "metrics": {"type": "tts_metrics", "ttfb": 0.9}}"#,
            #"{"type": "turn_latency", "e2e": 1.6}"#,
            #"{"type": "metrics", "metrics": {"type": "llm_metrics", "ttft": 0.5}}"#,
            #"{"type": "session", "voice": "Kore"}"#,
        ] { log.add(bench(e)) }
        #expect(log.rows == [TurnLog.Row(endOfTurn: 0.42, read: 0.8, firstToken: 0.5, firstAudio: 0.3, total: 1.6, persona: "Examiner")])
        log.add(bench(#"{"type": "metrics", "metrics": {"type": "llm_metrics", "ttft": 0.7}}"#))  // the field is full: a new row
        #expect(log.rows.count == 2 && log.rows[1].firstToken == 0.7)
    }
}
