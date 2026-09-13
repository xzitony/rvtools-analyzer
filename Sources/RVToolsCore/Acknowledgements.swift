import Foundation

/// A finding, or a whole check, that someone reviewed and accepted on the Issues page. Acknowledged findings are
/// left out of the report — counts, badges, inspectors and exports — and listed separately. Saved with projects.
///
/// A finding is matched by its check and object (not its detail, which changes between exports), so an
/// acknowledgement still applies to a newer export of the same environment.
public struct Acknowledgement: Codable, Hashable, Sendable, Identifiable {
    public let rule: String
    /// nil when the whole check is acknowledged, including findings that appear later.
    public let objectID: String?
    public let objectName: String?
    public var note: String
    public var date: Date

    /// Acknowledges a whole check.
    public init(rule: String, note: String = "", date: Date = Date()) {
        self.rule = rule
        objectID = nil
        objectName = nil
        self.note = note
        self.date = date
    }

    /// Acknowledges one finding.
    public init(finding: Finding, note: String = "", date: Date = Date()) {
        rule = finding.rule
        objectID = finding.objectID
        objectName = finding.objectName
        self.note = note
        self.date = date
    }

    public var id: String { key }
    public var isWholeCheck: Bool { objectID == nil }
    public var key: String { Acknowledgement.key(rule: rule, objectID: objectID, objectName: objectName) }

    static func key(rule: String, objectID: String?, objectName: String?) -> String {
        guard let objectID else { return rule + "|*" }
        return rule + "|" + objectID + "|" + (objectName ?? "")
    }
}

public extension Finding {
    /// What an acknowledgement of this finding covers: its check and object.
    var acknowledgementKey: String { Acknowledgement.key(rule: rule, objectID: objectID, objectName: objectName) }
}

public extension Array where Element == Acknowledgement {
    /// Splits findings into those still open and those an acknowledgement covers.
    func partition(_ findings: [Finding]) -> (open: [Finding], acknowledged: [Finding]) {
        guard !isEmpty else { return (findings, []) }
        let keys = Set(map(\.key))
        var open: [Finding] = [], acknowledged: [Finding] = []
        for f in findings {
            if keys.contains(f.rule + "|*") || keys.contains(f.acknowledgementKey) { acknowledged.append(f) } else { open.append(f) }
        }
        return (open, acknowledged)
    }

    /// The acknowledgement covering a finding: its own, or its check's.
    func covering(_ finding: Finding) -> Acknowledgement? {
        first { $0.key == finding.acknowledgementKey } ?? first { $0.rule == finding.rule && $0.isWholeCheck }
    }
}
