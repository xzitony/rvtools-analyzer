import Foundation

public enum OSFamily: String, CaseIterable, Sendable {
    case windowsServer = "Windows Server"
    case windowsDesktop = "Windows Desktop"
    case rhel = "RHEL family"
    case ubuntuDebian = "Ubuntu / Debian"
    case suse = "SUSE"
    case otherLinux = "Other Linux"
    case appliance = "VMware Photon / appliance"
    case unix = "BSD / Unix"
    case other = "Other / unknown"
}

public struct OSInfo: Hashable, Sendable {
    public var family: OSFamily
    public var name: String
    public var endOfSupport: Date?

    public static let unknown = OSInfo(family: .other, name: "Unknown", endOfSupport: nil)
}

/// Built-in lifecycle knowledge. Dates are end of (extended) vendor support; edit here to adjust.
public enum Lifecycle {
    private static func d(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    static let windowsServer: [String: Date] = [
        "2000": d("2010-07-13"), "2003": d("2015-07-14"), "2008": d("2020-01-14"), "2012": d("2023-10-10"),
        "2016": d("2027-01-12"), "2019": d("2029-01-09"), "2022": d("2031-10-14"), "2025": d("2034-10-10"),
    ]
    static let windowsDesktop: [String: Date] = [
        "XP": d("2014-04-08"), "Vista": d("2017-04-11"), "7": d("2020-01-14"), "8": d("2016-01-12"),
        "8.1": d("2023-01-10"), "10": d("2025-10-14"),
    ]
    static let rhel: [Int: Date] = [4: d("2012-02-29"), 5: d("2017-03-31"), 6: d("2020-11-30"), 7: d("2024-06-30"), 8: d("2029-05-31"), 9: d("2032-05-31")]
    static let centos: [Int: Date] = [3: d("2010-10-31"), 4: d("2012-02-29"), 5: d("2017-03-31"), 6: d("2020-11-30"), 7: d("2024-06-30"), 8: d("2021-12-31")]
    static let oracle: [Int: Date] = [5: d("2017-06-30"), 6: d("2021-03-01"), 7: d("2024-12-31"), 8: d("2029-07-01"), 9: d("2032-06-30")]
    static let rockyAlma: [Int: Date] = [8: d("2029-05-31"), 9: d("2032-05-31")]
    static let ubuntu: [String: Date] = [
        "10.04": d("2015-04-30"), "12.04": d("2017-04-28"), "14.04": d("2019-04-30"), "16.04": d("2021-04-30"),
        "18.04": d("2023-05-31"), "20.04": d("2025-05-31"), "22.04": d("2027-06-01"), "24.04": d("2029-06-01"),
    ]
    static let debian: [Int: Date] = [6: d("2016-02-29"), 7: d("2018-05-31"), 8: d("2020-06-30"), 9: d("2022-06-30"), 10: d("2024-06-30"), 11: d("2026-08-31"), 12: d("2028-06-30")]
    static let sles: [Int: Date] = [10: d("2013-07-31"), 11: d("2019-03-31"), 12: d("2024-10-31"), 15: d("2031-07-31")]
    /// End of general support for ESXi / vCenter major.minor releases.
    static let vsphere: [String: Date] = [
        "4.0": d("2014-05-21"), "4.1": d("2014-05-21"), "5.0": d("2016-08-24"), "5.1": d("2016-08-24"), "5.5": d("2018-09-19"),
        "6.0": d("2020-03-12"), "6.5": d("2022-10-15"), "6.7": d("2022-10-15"), "7.0": d("2025-10-02"), "8.0": d("2027-10-11"),
    ]
    public static let hardwareVersions: [Int: String] = [
        4: "ESX 3.x", 7: "ESXi 4.x", 8: "ESXi 5.0", 9: "ESXi 5.1", 10: "ESXi 5.5", 11: "ESXi 6.0", 13: "ESXi 6.5",
        14: "ESXi 6.7", 15: "ESXi 6.7 U2", 17: "ESXi 7.0", 18: "ESXi 7.0 U1", 19: "ESXi 7.0 U2", 20: "ESXi 8.0",
        21: "ESXi 8.0 U2", 22: "ESXi 9.0",
    ]

    private static func match(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: s) else { return "" }
            return String(s[rr])
        }
    }

    /// Classifies a guest OS. The VMware Tools-reported OS is what is actually installed, so it wins; the configured
    /// guest OS is only used when Tools reports nothing useful, or reports a generic name ("2016 or later", "Ubuntu")
    /// where the configured value is more specific within the same family.
    public static func classify(config: String, tools: String) -> OSInfo {
        let c = config.trimmingCharacters(in: .whitespaces).isEmpty ? nil : classifyOne(config)
        guard !tools.trimmingCharacters(in: .whitespaces).isEmpty else { return c ?? .unknown }
        let t = classifyOne(tools)
        guard t.family != .other else { return c ?? t }
        guard let c else { return t }
        let generic = { (o: OSInfo) in o.name.rangeOfCharacter(from: .decimalDigits) == nil || o.name.hasSuffix("+") }
        if t.family == c.family, generic(t), !generic(c) { return c }
        return t
    }

    private static func classifyOne(_ s: String) -> OSInfo {
        if let m = match(s, #"Windows Server (2000|2003|2008|2012|2016|2019|2022|2025)( R2)?( or later)?"#) {
            let orLater = !m[3].isEmpty
            let name = "Windows Server \(m[1])\(m[2])\(orLater ? "+" : "")"
            return OSInfo(family: .windowsServer, name: name, endOfSupport: orLater ? nil : windowsServer[m[1]])
        }
        if let m = match(s, #"Windows (2000|2003|2008)"#) {
            return OSInfo(family: .windowsServer, name: "Windows Server \(m[1])", endOfSupport: windowsServer[m[1]])
        }
        if let m = match(s, #"Windows (XP|Vista|7|8\.1|8|10|11)\b"#) {
            return OSInfo(family: .windowsDesktop, name: "Windows \(m[1])", endOfSupport: windowsDesktop[m[1]])
        }
        if s.range(of: "windows", options: .caseInsensitive) != nil {
            return OSInfo(family: .windowsServer, name: "Windows (other)", endOfSupport: nil)
        }
        if let m = match(s, #"Red Hat Enterprise Linux\D*(\d+)"#), let v = Int(m[1]) {
            return OSInfo(family: .rhel, name: "RHEL \(v)", endOfSupport: rhel[v])
        }
        if s.range(of: "Red Hat", options: .caseInsensitive) != nil { return OSInfo(family: .rhel, name: "RHEL", endOfSupport: nil) }
        if s.range(of: "CentOS", options: .caseInsensitive) != nil {
            // "CentOS 4/5/6 (64-bit)" -> newest listed version; "CentOS 7" -> 7; bare "CentOS" -> CentOS Linux is fully EOL.
            let nums = (match(s, #"CentOS\D*([\d/]+)"#)?[1] ?? "").split(separator: "/").compactMap { Int($0) }
            if s.range(of: "Stream", options: .caseInsensitive) != nil {
                return OSInfo(family: .rhel, name: "CentOS Stream", endOfSupport: nil)
            }
            if let v = nums.max() { return OSInfo(family: .rhel, name: "CentOS \(v)", endOfSupport: centos[v] ?? centos[7]) }
            return OSInfo(family: .rhel, name: "CentOS", endOfSupport: centos[7])
        }
        if let m = match(s, #"Oracle Linux\D*(\d+)"#), let v = Int(m[1]) { return OSInfo(family: .rhel, name: "Oracle Linux \(v)", endOfSupport: oracle[v]) }
        if s.range(of: "Oracle Linux", options: .caseInsensitive) != nil { return OSInfo(family: .rhel, name: "Oracle Linux", endOfSupport: nil) }
        if let m = match(s, #"(Rocky|Alma)\s*Linux\D*(\d+)"#), let v = Int(m[2]) { return OSInfo(family: .rhel, name: "\(m[1]) Linux \(v)", endOfSupport: rockyAlma[v]) }
        if let m = match(s, #"Ubuntu\D*(\d{2}\.\d{2})"#) { return OSInfo(family: .ubuntuDebian, name: "Ubuntu \(m[1])", endOfSupport: ubuntu[m[1]]) }
        if s.range(of: "Ubuntu", options: .caseInsensitive) != nil { return OSInfo(family: .ubuntuDebian, name: "Ubuntu", endOfSupport: nil) }
        if let m = match(s, #"Debian\D*(\d+)"#), let v = Int(m[1]) { return OSInfo(family: .ubuntuDebian, name: "Debian \(v)", endOfSupport: debian[v]) }
        if s.range(of: "Debian", options: .caseInsensitive) != nil { return OSInfo(family: .ubuntuDebian, name: "Debian", endOfSupport: nil) }
        if let m = match(s, #"SUSE Linux Enterprise\D*(\d+)"#), let v = Int(m[1]) { return OSInfo(family: .suse, name: "SLES \(v)", endOfSupport: sles[v]) }
        if s.range(of: "SUSE", options: .caseInsensitive) != nil { return OSInfo(family: .suse, name: "SUSE", endOfSupport: nil) }
        if s.range(of: "Photon", options: .caseInsensitive) != nil { return OSInfo(family: .appliance, name: "VMware Photon OS", endOfSupport: nil) }
        if s.range(of: "Linux", options: .caseInsensitive) != nil {
            let name = s.replacingOccurrences(of: #"\s*\((32|64)-bit\)"#, with: "", options: .regularExpression)
            return OSInfo(family: .otherLinux, name: name, endOfSupport: nil)
        }
        if s.range(of: #"FreeBSD|Solaris|AIX|HP-UX|Unix"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return OSInfo(family: .unix, name: s.replacingOccurrences(of: #"\s*\((32|64)-bit\)"#, with: "", options: .regularExpression), endOfSupport: nil)
        }
        let name = s.replacingOccurrences(of: #"\s*\((32|64)-bit\)"#, with: "", options: .regularExpression)
        return OSInfo(family: .other, name: name.isEmpty ? "Unknown" : name, endOfSupport: nil)
    }

    /// Extracts "8.0.2" / build from "VMware ESXi 8.0.2 build-24790513" or a bare version string.
    public static func parseVMwareVersion(_ s: String) -> (version: String, build: String) {
        let version = match(s, #"(\d+\.\d+(\.\d+)?)"#)?[1] ?? ""
        let build = match(s, #"build[- ]?(\d+)"#)?[1] ?? ""
        return (version, build)
    }

    /// The date support status is judged on: today, or the export date if that's later. Whether a release is still
    /// supported matters as of now, so an export taken before a support end date still shows it as ended once it has passed.
    public static func supportReference(exportDate: Date) -> Date { max(exportDate, Date()) }

    public static func vsphereEndOfSupport(_ version: String) -> Date? {
        let parts = version.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return vsphere["\(parts[0]).\(parts[1])"]
    }

    public static func hardwareLabel(_ v: Int) -> String {
        guard v > 0 else { return "Unknown" }
        if let s = hardwareVersions[v] { return "vmx-\(v) (\(s))" }
        return "vmx-\(v)"
    }

    public static func toolsLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "toolsok", "guesttoolscurrent": return "OK"
        case "toolsold", "guesttoolsneedupgrade": return "Out of date"
        case "toolsnotrunning", "guesttoolsnotrunning": return "Not running"
        case "toolsnotinstalled", "guesttoolsnotinstalled": return "Not installed"
        case "guesttoolsunmanaged": return "Unmanaged (open-vm-tools)"
        case "": return "Unknown"
        default: return raw
        }
    }
}
