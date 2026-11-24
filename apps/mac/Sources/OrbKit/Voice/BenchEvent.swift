import Foundation

/// An event of the voice worker on the room's data channel (topic "orb.bench"): `{"type", "t", ...}`.
public struct BenchEvent: Sendable, Equatable {
    public static let topic = "orb.bench"
    public var type: String
    public var fields: [String: JSONValue]

    public init?(data: Data) {
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              let type = object["type"]?.string else { return nil }
        self.type = type
        self.fields = object
    }

    public subscript(key: String) -> JSONValue? { fields[key] }

    /// One line for the inspector's event log, without words.
    public var summary: String {
        let keep = fields.filter { !["type", "t", "text", "heard"].contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.short($0.value))" }
        return ([type] + keep).joined(separator: " ")
    }

    static func short(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): s
        case .number(let n): n == n.rounded() ? String(Int(n)) : String(format: "%.3f", n)
        case .bool(let b): String(b)
        case .null: "null"
        default: "…"
        }
    }
}
