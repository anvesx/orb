/// How well an on-screen control's name fits what Gemini asked for ("the Export button"): exact beats prefix beats
/// contains, on normalized words, so "Save" is not "Save As…".
public enum ElementMatch {
    static let generic: Set<String> = ["the", "a", "an", "button", "menu", "item", "icon", "tab", "field", "link",
                                       "checkbox", "box", "toggle", "switch", "option", "control"]

    public static func query(_ what: String) -> String {
        let words = String(String.UnicodeScalarView(TextMatch.normalize(what).text)).split(separator: " ")
        let kept = words.filter { !generic.contains(String($0)) }
        return (kept.isEmpty ? words : kept).joined(separator: " ")
    }

    public static func score(_ query: String, name: String) -> Double? {
        let n = String(String.UnicodeScalarView(TextMatch.normalize(name).text))
        guard !query.isEmpty, !n.isEmpty else { return nil }
        if n == query { return 1 }
        if n.hasPrefix(query + " ") || query.hasPrefix(n + " ") { return 0.8 }
        if (" " + n + " ").contains(" " + query + " ") { return 0.6 }
        return nil
    }
}
