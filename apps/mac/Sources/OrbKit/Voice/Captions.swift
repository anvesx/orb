/// What you said and what orb says, as the web page shows them.
public struct Captions: Equatable, Sendable {
    public var you = ""
    public var youFinal = true
    public var orb = ""
    var youSegment = ""
    public internal(set) var orbSegment = ""

    public init() {}

    /// The first words of a new segment of yours make orb's last reply old, so it clears.
    public mutating func yourWords(segment: String, text: String, final: Bool) {
        if segment != youSegment {
            youSegment = segment
            orbSegment = ""
            orb = ""
        }
        you = text
        youFinal = final
    }

    public mutating func orbWords(segment: String, chunk: String) {
        if segment != orbSegment {
            orbSegment = segment
            orb = ""
        }
        orb += chunk
    }

    /// The polish of a transcript replaces it while the caption still shows the heard text.
    public mutating func polished(heard: String, text: String) {
        if you == heard { you = text }
    }
}
