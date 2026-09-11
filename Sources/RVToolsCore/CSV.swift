import Foundation

/// Reads RVTools "Export all to csv" output (RVTools_tabvInfo.csv, RVTools_tabvHost.csv, ...).
enum CSVReader {
    static func readTable(url: URL) throws -> RawTable {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw RVToolsError.unreadable("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let rows = parse(data)
        let name = sheetName(forFile: url)
        guard let header = rows.first else { return RawTable(name: name, headers: [], rows: []) }
        var headers = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        while let last = headers.last, last.isEmpty { headers.removeLast() }
        for i in headers.indices where headers[i].isEmpty { headers[i] = "Column \(i + 1)" }
        let n = headers.count
        var body: [[String]] = []
        body.reserveCapacity(rows.count)
        for r in rows.dropFirst() {
            guard r.contains(where: { !$0.isEmpty }) else { continue }
            if r.count == n { body.append(r) }
            else if r.count < n { body.append(r + Array(repeating: "", count: n - r.count)) }
            else { body.append(Array(r[0..<n])) }
        }
        return RawTable(name: name, headers: headers, rows: body)
    }

    /// "RVTools_tabvInfo.csv" -> "vInfo". Falls back to the known sheet list, then to the bare file name.
    static func sheetName(forFile url: URL) -> String {
        var base = url.deletingPathExtension().lastPathComponent
        if let r = base.range(of: "_tab", options: [.caseInsensitive, .backwards]) {
            base = String(base[r.upperBound...])
        } else if base.lowercased().hasPrefix("tab") {
            base = String(base.dropFirst(3))
        }
        if let known = Dataset.knownSheets.first(where: { $0.caseInsensitiveCompare(base) == .orderedSame }) { return known }
        return base
    }

    static func parse(_ raw: Data) -> [[String]] {
        var bytes = [UInt8](raw)
        if bytes.count >= 2, (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            let enc: String.Encoding = bytes[0] == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            let s = String(data: Data(bytes.dropFirst(2)), encoding: enc) ?? ""
            bytes = Array(s.utf8)
        } else if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        } else if String(bytes: bytes, encoding: .utf8) == nil, let s = String(bytes: bytes, encoding: .windowsCP1252) {
            bytes = Array(s.utf8)
        }

        let delimiter = detectDelimiter(bytes)
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var i = 0
        let n = bytes.count
        @inline(__always) func finishField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        while i < n {
            let c = bytes[i]
            if inQuotes {
                if c == 0x22 {
                    if i + 1 < n, bytes[i + 1] == 0x22 { field.append(0x22); i += 2; continue }
                    inQuotes = false
                } else {
                    field.append(c)
                }
            } else if c == 0x22 && field.isEmpty {
                inQuotes = true
            } else if c == delimiter {
                finishField()
            } else if c == 0x0A {
                finishField(); rows.append(row); row = []
            } else if c != 0x0D {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { finishField(); rows.append(row) }
        return rows
    }

    private static func detectDelimiter(_ bytes: [UInt8]) -> UInt8 {
        var counts: [UInt8: Int] = [0x2C: 0, 0x3B: 0, 0x09: 0]
        var inQuotes = false
        for c in bytes.prefix(8192) {
            if c == 0x22 { inQuotes.toggle() }
            if inQuotes { continue }
            if c == 0x0A { break }
            if counts[c] != nil { counts[c]! += 1 }
        }
        return counts.max { $0.value < $1.value }.flatMap { $0.value > 0 ? $0.key : nil } ?? 0x2C
    }
}
