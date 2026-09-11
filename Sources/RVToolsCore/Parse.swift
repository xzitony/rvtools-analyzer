import Foundation

public enum Parse {
    public static func number(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.hasSuffix("%") { s.removeLast() }
        if let v = Double(s) { return v }
        s = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
        if s.contains(","), !s.contains(".") { s = s.replacingOccurrences(of: ",", with: ".") }
        return Double(s)
    }

    public static func bool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "1", "on", "enabled", "connected": return true
        case "false", "no", "0", "off", "disabled", "disconnected": return false
        default: return nil
        }
    }

    private static let utc = TimeZone(identifier: "UTC")!
    private static let formatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ",
        "M/d/yyyy h:mm:ss a", "M/d/yyyy H:mm:ss", "M/d/yyyy h:mm a", "d-M-yyyy H:mm:ss", "d.M.yyyy H:mm:ss",
        "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd", "M/d/yyyy", "d.M.yyyy",
    ].map { f in
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = utc
        df.dateFormat = f
        return df
    }

    public static func date(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 6 else { return nil }
        // Plain Excel serial number (a date column that lost its date style).
        if let serial = Double(s), serial > 20_000, serial < 80_000 {
            return Date(timeIntervalSince1970: (serial - 25_569) * 86_400)
        }
        for f in formatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    /// "RVTools_export_all_2026-03-18_16.05.15.xlsx" -> 2026-03-18 16:05:15
    public static func dateFromExportName(_ name: String) -> Date? {
        guard let r = name.range(of: #"\d{4}-\d{2}-\d{2}_\d{2}\.\d{2}\.\d{2}"#, options: .regularExpression) else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = utc
        df.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        return df.date(from: String(name[r]))
    }

    /// "[datastore1] folder/vm.vmdk" -> "datastore1"
    public static func datastore(fromPath path: String) -> String? {
        guard path.hasPrefix("["), let end = path.firstIndex(of: "]") else { return nil }
        let name = path[path.index(after: path.startIndex)..<end].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    public static func list(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// First integer found in a string: "vmx-11" -> 11, "20" -> 20.
    public static func firstInt(_ raw: String) -> Int? {
        guard let r = raw.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(raw[r])
    }
}
