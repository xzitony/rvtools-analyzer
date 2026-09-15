import Foundation

/// How storage capacities are shown. RVTools reports capacity in MiB and the app keeps it that way; this only changes display.
public enum StorageUnits: String, CaseIterable, Codable, Sendable {
    /// MiB, GiB, TiB (powers of 1024), as vSphere calculates capacity.
    case binary
    /// MB, GB, TB (powers of 1000), as drive and array vendors often quote capacity.
    case decimal

    public var label: String { self == .binary ? "Binary (MiB, GiB, TiB)" : "Decimal (MB, GB, TB)" }
}

/// How network rates are shown. Rates are kept in megabits per second; this only changes display.
public enum RateUnits: String, CaseIterable, Codable, Sendable {
    /// Mbps, Gbps.
    case bits
    /// MB/s, GB/s (decimal bytes).
    case bytes

    public var label: String { self == .bits ? "Bits per second (Mbps, Gbps)" : "Bytes per second (MB/s, GB/s)" }
}

/// The display units in effect (app settings, or `rvtools-cli --units / --rate`). Memory is always binary.
public enum Units {
    public nonisolated(unsafe) static var storage: StorageUnits = .binary
    public nonisolated(unsafe) static var rate: RateUnits = .bits
}

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

    /// MiB → bytes ÷ 10⁶.
    static let mibToMB = 1.048576

    /// Storage capacity in the chosen units: MiB, GiB, TiB, PiB (binary) or MB, GB, TB, PB (decimal).
    public static func capacity(mib: Double) -> String {
        guard mib.isFinite else { return "—" }
        switch Units.storage {
        case .binary: return scaled(mib, base: 1024, units: ["MiB", "GiB", "TiB", "PiB"])
        case .decimal: return scaled(mib * mibToMB, base: 1000, units: ["MB", "GB", "TB", "PB"])
        }
    }

    /// Memory, always in binary units (RAM comes in powers of two): MiB, GiB, TiB.
    public static func memory(mib: Double) -> String {
        guard mib.isFinite else { return "—" }
        return scaled(mib, base: 1024, units: ["MiB", "GiB", "TiB", "PiB"])
    }

    private static func scaled(_ v: Double, base: Double, units: [String]) -> String {
        let a = abs(v)
        if a < base { return String(format: "%.0f", v) + " " + units[0] }
        if a < base * base { return String(format: a < 10 * base ? "%.1f" : "%.0f", v / base) + " " + units[1] }
        if a < base * base * base { return String(format: "%.1f", v / base / base) + " " + units[2] }
        return String(format: "%.2f", v / base / base / base) + " " + units[3]
    }

    /// A network rate given in megabits per second, in the chosen units: Mbps / Gbps, or MB/s / GB/s.
    public static func rate(mbps: Double) -> String {
        guard mbps.isFinite else { return "—" }
        let bits = Units.rate == .bits
        let v = bits ? mbps : mbps / 8
        if abs(v) >= 1000 { return trimmed(v / 1000) + (bits ? " Gbps" : " GB/s") }
        return (abs(v) >= 10 ? String(format: "%.0f", v) : trimmed(v)) + (bits ? " Mbps" : " MB/s")
    }

    public static func rate(mbps: Int) -> String { rate(mbps: Double(mbps)) }

    /// Storage throughput given in MiB per second, in the chosen storage units: MiB/s or MB/s.
    public static func dataRate(mibPerSec: Double) -> String {
        guard mibPerSec.isFinite else { return "—" }
        let v = Units.storage == .binary ? mibPerSec : mibPerSec * mibToMB
        let unit = Units.storage == .binary ? (abs(v) >= 1024 ? "GiB/s" : "MiB/s") : (abs(v) >= 1000 ? "GB/s" : "MB/s")
        let scaled = abs(v) >= (Units.storage == .binary ? 1024 : 1000) ? v / (Units.storage == .binary ? 1024 : 1000) : v
        return (abs(scaled) >= 10 ? String(format: "%.0f", scaled) : trimmed(scaled)) + " " + unit
    }

    /// Up to two decimals, without trailing zeros.
    private static func trimmed(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// The gigabyte-scale unit for storage columns: "GiB" or "GB".
    public static var storageGBLabel: String { Units.storage == .binary ? "GiB" : "GB" }
    /// A storage figure for a CSV column headed with `storageGBLabel`.
    public static func storageGB(mib: Double) -> String { String(format: "%.1f", Units.storage == .binary ? mib / 1024 : mib * mibToMB / 1000) }
    /// A memory figure for a CSV column in GiB.
    public static func memoryGiB(mib: Double) -> String { String(format: "%.1f", mib / 1024) }

    public static func ghz(_ mhz: Double) -> String { String(format: mhz >= 100_000 ? "%.0f GHz" : "%.1f GHz", mhz / 1000) }

    public static func date(_ d: Date?) -> String { d.map { dateFormatter.string(from: $0) } ?? "—" }
    public static func dateTime(_ d: Date?) -> String { d.map { dateTimeFormatter.string(from: $0) } ?? "—" }
}
