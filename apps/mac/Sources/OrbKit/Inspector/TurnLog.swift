/// The voice call's latency table, from the worker's events (the web page's `onBench`): one row per turn.
public struct TurnLog: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var endOfTurn: Double?   // end of your speech to the turn commit
        public var read: Double?        // Jev reads your message
        public var firstToken: Double?  // the LLM's first token
        public var firstAudio: Double?  // the TTS's first audio
        public var total: Double?       // end of your speech to the first audio of orb
        public var persona: String?
    }

    public private(set) var rows: [Row] = []

    public init() {}

    public mutating func add(_ e: BenchEvent) {
        switch e.type {
        case "metrics":
            let m = e["metrics"]
            switch m?["type"]?.string {
            case "eou_metrics": rows.append(Row(endOfTurn: m?["end_of_utterance_delay"]?.number))
            case "llm_metrics": rows[open(\.firstToken)].firstToken = m?["ttft"]?.number
            case "tts_metrics": if let i = rows.indices.last, rows[i].firstAudio == nil { rows[i].firstAudio = m?["ttfb"]?.number }
            default: break
            }
        case "turn_latency": rows[rows.isEmpty ? open(\.total) : rows.count - 1].total = e["e2e"]?.number
        case "agent_read": if !rows.isEmpty { rows[rows.count - 1].read = e["seconds"]?.number }
        case "agent_decision": if !rows.isEmpty { rows[rows.count - 1].persona = e["persona"]?.string }
        default: break
        }
    }

    /// The last row when that field is still empty, else a new row.
    mutating func open(_ field: KeyPath<Row, Double?>) -> Int {
        if let last = rows.last, last[keyPath: field] == nil { return rows.count - 1 }
        rows.append(Row())
        return rows.count - 1
    }
}
