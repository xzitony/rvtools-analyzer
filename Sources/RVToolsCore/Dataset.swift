import Foundation

/// A worksheet with header lookup that tolerates RVTools version drift
/// (e.g. "Provisioned MB" in 3.x vs "Provisioned MiB" in 4.x, spacing/case changes).
public final class Table: @unchecked Sendable {
    public let name: String
    public private(set) var headers: [String]
    public private(set) var rows: [[String]]
    /// Columns RVTools writes between "Annotation" and "Datacenter" on VM tabs: vCenter custom attributes and, since
    /// RVTools 4.4.1, vSphere tags (one column per category). Tracked per export, so merged tables keep them.
    public private(set) var customColumns: Set<Int> = []
    private var lookup: [String: Int] = [:]

    init(raw: RawTable) {
        name = raw.name
        headers = raw.headers
        rows = raw.rows
        customColumns = Set(Table.customRange(raw.headers))
        rebuildLookup()
    }

    static func customRange(_ headers: [String]) -> Range<Int> {
        let names = headers.map(normalize)
        guard let a = names.firstIndex(of: "annotation"), let d = names.firstIndex(of: "datacenter"), d > a + 1 else { return 0..<0 }
        return (a + 1)..<d
    }

    static func normalize(_ s: String) -> String {
        // "#" must survive normalisation: "# Hosts" (a count) and "Hosts" (a list) are different columns.
        let lower = s.lowercased().replacingOccurrences(of: "mib", with: "mb").replacingOccurrences(of: "kib", with: "kb")
            .replacingOccurrences(of: "#", with: "num")
        return String(lower.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private func rebuildLookup() {
        lookup = [:]
        for (i, h) in headers.enumerated() {
            let k = Table.normalize(h)
            if lookup[k] == nil { lookup[k] = i }
        }
    }

    /// Index of the first header matching any of the given names.
    public func col(_ names: String...) -> Int? {
        for n in names { if let i = lookup[Table.normalize(n)] { return i } }
        return nil
    }

    /// Appends rows from another export of the same tab (multi-vCenter merges); headers are unioned.
    func merge(_ other: RawTable) {
        var mapping: [Int] = []
        for h in other.headers {
            if let i = lookup[Table.normalize(h)] { mapping.append(i) } else {
                headers.append(h)
                mapping.append(headers.count - 1)
                lookup[Table.normalize(h)] = headers.count - 1
                for r in rows.indices { rows[r].append("") }
            }
        }
        for j in Table.customRange(other.headers) where j < mapping.count { customColumns.insert(mapping[j]) }
        let width = headers.count
        for r in other.rows {
            var out = Array(repeating: "", count: width)
            for (j, v) in r.enumerated() where j < mapping.count { out[mapping[j]] = v }
            rows.append(out)
        }
    }
}

public extension Array where Element == String {
    @inline(__always) func s(_ c: Int?) -> String {
        guard let c, c < count else { return "" }
        return self[c]
    }
    func d(_ c: Int?) -> Double? { Parse.number(s(c)) }
    func d0(_ c: Int?) -> Double { Parse.number(s(c)) ?? 0 }
    func i0(_ c: Int?) -> Int { Int((Parse.number(s(c)) ?? 0).rounded()) }
    func b(_ c: Int?) -> Bool? { Parse.bool(s(c)) }
    func date(_ c: Int?) -> Date? { Parse.date(s(c)) }
}

/// Everything loaded from one or more RVTools exports.
public final class Dataset: @unchecked Sendable {
    public static let knownSheets = [
        "vInfo", "vCPU", "vMemory", "vDisk", "vPartition", "vNetwork", "vCD", "vUSB", "vSnapshot", "vTools",
        "vSource", "vRP", "vCluster", "vHost", "vHBA", "vNIC", "vSwitch", "vPort", "dvSwitch", "dvPort",
        "vSC_VMK", "vDatastore", "vMultiPath", "vLicense", "vFileInfo", "vHealth", "vMetaData",
    ]

    public private(set) var tables: [String: Table] = [:]
    public private(set) var tableNames: [String] = []
    public private(set) var sources: [URL] = []
    public private(set) var reportDate: Date = Date()
    public private(set) var rvtoolsVersion: String = ""
    public private(set) var warnings: [String] = []

    public func table(_ name: String) -> Table? { tables[name.lowercased()] }

    public static func load(_ urls: [URL]) throws -> Dataset {
        let ds = Dataset()
        var fileDates: [Date] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw RVToolsError.unreadable("\(url.lastPathComponent) does not exist")
            }
            var files: [URL] = []
            if isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                files = items.filter { ["csv", "xlsx", "xlsm"].contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                if files.isEmpty { throw RVToolsError.notRVTools("No RVTools .xlsx or .csv files found in \(url.lastPathComponent)") }
            } else {
                files = [url]
            }
            for file in files {
                let ext = file.pathExtension.lowercased()
                let raws: [RawTable]
                switch ext {
                case "xlsx", "xlsm": raws = try XLSXReader.read(url: file)
                case "csv", "txt": raws = [try CSVReader.readTable(url: file)]
                case "xls": throw RVToolsError.notRVTools("\(file.lastPathComponent) is a legacy .xls file — re-export from RVTools as .xlsx")
                default: continue
                }
                ds.sources.append(file)
                for raw in raws where !raw.headers.isEmpty { ds.add(raw) }
                if let d = Parse.dateFromExportName(file.lastPathComponent) ?? Parse.dateFromExportName(file.deletingLastPathComponent().lastPathComponent) {
                    fileDates.append(d)
                } else if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let m = attrs[.modificationDate] as? Date {
                    fileDates.append(m)
                }
            }
        }
        guard ds.table("vInfo") != nil else {
            throw RVToolsError.notRVTools("No vInfo tab found — this doesn't look like an RVTools export (tabs found: \(ds.tableNames.joined(separator: ", ")))")
        }
        ds.tableNames.sort { a, b in
            let ia = knownSheets.firstIndex { $0.caseInsensitiveCompare(a) == .orderedSame } ?? Int.max
            let ib = knownSheets.firstIndex { $0.caseInsensitiveCompare(b) == .orderedSame } ?? Int.max
            return ia == ib ? a < b : ia < ib
        }

        // Ages (snapshots, uptime, certificates, EOL) are measured from when the export was taken, not today.
        var metaDates: [Date] = []
        if let meta = ds.table("vMetaData") {
            let c = meta.col("xlsx creation datetime", "creation datetime")
            let v = meta.col("RVTools version")
            for r in meta.rows {
                if let d = r.date(c) { metaDates.append(d) }
                if ds.rvtoolsVersion.isEmpty { ds.rvtoolsVersion = r.s(v) }
            }
        }
        ds.reportDate = metaDates.max() ?? fileDates.max() ?? Date()
        return ds
    }

    private func add(_ raw: RawTable) {
        let key = raw.name.lowercased()
        if let existing = tables[key] {
            existing.merge(raw)
        } else {
            tables[key] = Table(raw: raw)
            tableNames.append(raw.name)
        }
    }
}
