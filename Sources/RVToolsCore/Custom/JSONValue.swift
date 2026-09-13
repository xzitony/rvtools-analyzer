import Foundation

/// A JSON value from a manifest, price list or script result.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        if var a = try? decoder.unkeyedContainer() {
            var out: [JSONValue] = []
            while !a.isAtEnd { out.append(try a.decode(JSONValue.self)) }
            self = .array(out)
        } else if let o = try? decoder.container(keyedBy: AnyKey.self) {
            var out: [String: JSONValue] = [:]
            for k in o.allKeys { out[k.stringValue] = try o.decode(JSONValue.self, forKey: k) }
            self = .object(out)
        } else {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else { self = .null }
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let b): var c = encoder.singleValueContainer(); try c.encode(b)
        case .number(let n): var c = encoder.singleValueContainer(); try c.encode(n)
        case .string(let s): var c = encoder.singleValueContainer(); try c.encode(s)
        case .array(let a): var c = encoder.unkeyedContainer(); for v in a { try c.encode(v) }
        case .object(let o): var c = encoder.container(keyedBy: AnyKey.self); for (k, v) in o { try c.encode(v, forKey: AnyKey(stringValue: k)) }
        }
    }

    /// Parses JSON text (faster than `JSONDecoder` for large script results).
    public static func parse(_ data: Data) throws -> JSONValue {
        from(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    static func from(_ any: Any) -> JSONValue {
        switch any {
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(from))
        case let o as [String: Any]: return .object(o.mapValues(from))
        default: return .null
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var isNull: Bool { self == .null }

    /// A scalar as display text.
    public var text: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "Yes" : "No"
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .array(let a): return a.map(\.text).joined(separator: ", ")
        case .object: return "…"
        }
    }
}

/// A problem with a custom solution or price list, worded for the person who wrote it.
public struct ExtensionError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Ids of custom solutions and price lists: lowercase, file-name and URL safe.
public enum ExtensionID {
    public static func isValid(_ id: String) -> Bool {
        regexMatch(id, #"^[a-z0-9][a-z0-9._-]{0,63}$"#) != nil && id == id.lowercased()
    }
}

func describeDecodingError(_ error: Error) -> String {
    guard let e = error as? DecodingError else { return error.localizedDescription }
    func path(_ keys: [CodingKey]) -> String {
        let s = keys.map { k in k.intValue.map { "[\($0)]" } ?? ".\(k.stringValue)" }.joined()
        return s.hasPrefix(".") ? String(s.dropFirst()) : s
    }
    func typeName(_ t: Any.Type) -> String {
        if t == String.self { return "text" }
        if t == Double.self || t == Int.self { return "a number" }
        if t == Bool.self { return "true or false" }
        if String(describing: t).hasPrefix("Array") { return "a list" }
        if String(describing: t).hasPrefix("Dictionary") { return "an object" }
        return String(describing: t)
    }
    switch e {
    case .keyNotFound(let key, let c): return "missing “\(path(c.codingPath + [key]))”"
    case .typeMismatch(let t, let c): return "“\(path(c.codingPath))” should be \(typeName(t))"
    case .valueNotFound(let t, let c): return "“\(path(c.codingPath))” should be \(typeName(t)), not null"
    case .dataCorrupted(let c):
        if c.codingPath.isEmpty {
            let detail = (c.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? c.debugDescription
            return "not valid JSON — \(detail)"
        }
        return "“\(path(c.codingPath))”: \(c.debugDescription)"
    @unknown default: return e.localizedDescription
    }
}
