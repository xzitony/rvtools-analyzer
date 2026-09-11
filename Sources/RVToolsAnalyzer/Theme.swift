import AppKit
import RVToolsCore
import SwiftUI

/// Foundation also defines `Host`; this alias keeps the app code unambiguous.
typealias ESXiHost = RVToolsCore.Host

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Validated categorical palette (fixed slot order, light/dark steps) plus a reserved status palette.
/// Status colours are only used for state (severity, thresholds) and always ship with an icon or label.
enum Palette {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }

    static let series: [Color] = [
        dynamic(0x2A78D6, 0x3987E5), // blue
        dynamic(0xEB6834, 0xD95926), // orange
        dynamic(0x1BAF7A, 0x199E70), // aqua
        dynamic(0xEDA100, 0xC98500), // yellow
        dynamic(0xE87BA4, 0xD55181), // magenta
        dynamic(0x008300, 0x008300), // green
        dynamic(0x4A3AA7, 0x9085E9), // violet
        dynamic(0xE34948, 0xE66767), // red
    ]
    static let primary = series[0]

    static let good = Color(nsColor: NSColor(hex: 0x0CA30C))
    static let warning = Color(nsColor: NSColor(hex: 0xFAB219))
    static let serious = Color(nsColor: NSColor(hex: 0xEC835A))
    static let critical = Color(nsColor: NSColor(hex: 0xD03B3B))
    static let neutral = dynamic(0x898781, 0x898781)
    static let grid = dynamic(0xE1E0D9, 0x2C2C2A)
    static let track = dynamic(0xECEBE6, 0x2C2C2A)
    static let card = Color(nsColor: .controlBackgroundColor)

    static func severity(_ s: Severity) -> Color {
        switch s {
        case .critical: return critical
        case .warning: return warning
        case .info: return dynamic(0x52514E, 0xC3C2B7)
        }
    }

    /// Meter colour for a utilisation percentage.
    static func usage(_ pct: Double, warn: Double, crit: Double) -> Color {
        pct >= crit ? critical : (pct >= warn ? warning : primary)
    }
}
