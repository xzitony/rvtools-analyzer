import Foundation

public enum Fmt {
    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    public static func int(_ v: Int) -> String { intFormatter.string(from: NSNumber(value: v)) ?? "\(v)" }

    public static func num(_ v: Double, _ digits: Int = 1) -> String {
        guard v.isFinite else { return "—" }
        return String(format: "%.\(digits)f", v)
    }

    public static func pct(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        return v < 10 && v != 0 && v.rounded() != v ? String(format: "%.1f%%", v) : String(format: "%.0f%%", v)
    }

    public static func ratio(_ v: Double) -> String { v.isFinite ? String(format: "%.1f:1", v) : "—" }

    /// VMware-style binary units, labelled GB/TB as vSphere does.
    public static func capacity(mib: Double) -> String {
        guard mib.isFinite else { return "—" }
        let a = abs(mib)
        if a < 1024 { return String(format: "%.0f MB", mib) }
        if a < 1024 * 1024 { return String(format: a < 10 * 1024 ? "%.1f GB" : "%.0f GB", mib / 1024) }
        if a < 1024 * 1024 * 1024 { return String(format: "%.1f TB", mib / 1024 / 1024) }
        return String(format: "%.2f PB", mib / 1024 / 1024 / 1024)
    }

    public static func ghz(_ mhz: Double) -> String { String(format: mhz >= 100_000 ? "%.0f GHz" : "%.1f GHz", mhz / 1000) }

    public static func date(_ d: Date?) -> String { d.map { dateFormatter.string(from: $0) } ?? "—" }
    public static func dateTime(_ d: Date?) -> String { d.map { dateTimeFormatter.string(from: $0) } ?? "—" }
}
