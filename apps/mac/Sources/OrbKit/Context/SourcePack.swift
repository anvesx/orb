/// The request limits of the agent service for sources (orb_core.agent: MAX_SOURCES, MAX_SOURCE_CHARS,
/// MAX_SOURCES_CHARS). The service packs the prompt within its own, smaller budget.
public enum SourcePack {
    public static let maxSources = 100
    public static let maxSourceChars = 150_000
    public static let maxTotalChars = 500_000

    /// Sources in order, each cut to the per-file limit, stopping before the request limits.
    public static func fit(_ sources: [Source]) -> [Source] {
        var out: [Source] = [], total = 0
        for var s in sources where !s.text.isEmpty {
            guard out.count < maxSources, total < maxTotalChars else { break }
            let room = min(maxSourceChars, maxTotalChars - total)
            if s.text.count > room { s.text = String(s.text.prefix(room)) }
            total += s.text.count
            out.append(s)
        }
        return out
    }
}
