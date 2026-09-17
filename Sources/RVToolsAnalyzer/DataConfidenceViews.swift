import RVToolsCore
import SwiftUI

extension DataQuality.Level {
    var color: Color {
        switch self {
        case .complete: return Palette.good
        case .derived: return Palette.primary
        case .incomplete: return Palette.warning
        }
    }
    var symbol: String {
        switch self {
        case .complete: return "checkmark.seal.fill"
        case .derived: return "arrow.triangle.branch"
        case .incomplete: return Severity.warning.symbol
        }
    }
    var headline: String {
        switch self {
        case .complete: return "Every key figure is reported by RVTools"
        case .derived: return "Some figures were derived from other tabs"
        case .incomplete: return "Some figures are missing from this export"
        }
    }
}

extension DataGap.Kind {
    var color: Color {
        switch self {
        case .missing: return Palette.warning
        case .derived: return Palette.primary
        case .note: return Palette.neutral
        }
    }
    var symbol: String {
        switch self {
        case .missing: return Severity.warning.symbol
        case .derived: return "arrow.triangle.branch"
        case .note: return "info.circle"
        }
    }
    var label: String {
        switch self {
        case .missing: return "Missing"
        case .derived: return "Derived"
        case .note: return "Note"
        }
    }
}

extension DataGap {
    /// One-line form for the banner, e.g. "Provisioned from Σ vDisk capacity (354 of 354 VMs)".
    var summary: String {
        guard total > 0 else { return title }
        let noun = ["Hosts": "hosts", "Datastores": "datastores"][area] ?? "VMs"
        let figure = noun == "VMs" ? title : "\(area.dropLast()) \(title.lowercased())"
        return figure + (kind == .missing ? " missing" : " from \(fallback)") + " (\(Fmt.int(affected)) of \(Fmt.int(total)) \(noun))"
    }
}

/// Slim banner above the dashboards when headline figures were derived or are missing.
struct DataConfidenceBanner: View {
    @Environment(AppModel.self) private var model
    let quality: DataQuality

    var body: some View {
        let level = quality.level
        let items = quality.headline
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: level.symbol).foregroundStyle(level.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(level.headline).font(.callout.weight(.semibold))
                Text(items.prefix(3).map(\.summary).joined(separator: " · ") + (items.count > 3 ? " · +\(items.count - 3) more" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("Review") { model.sidebar = .correlations }
            Button { model.dataBannerDismissed = true } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide until another export is opened")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(level.color.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(level.color.opacity(0.35)).frame(height: 1) }
    }
}

/// The full breakdown, shown at the top of Correlations.
struct DataConfidenceCard: View {
    let quality: DataQuality

    var body: some View {
        let level = quality.level
        Card("Data confidence", subtitle: "Where key figures came from: VM vCPU, memory, provisioned and in-use storage · host cores and memory · datastore capacity") {
            HStack(alignment: .center, spacing: 18) {
                HStack(spacing: 8) {
                    Image(systemName: level.symbol).font(.title2).foregroundStyle(level.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(level.headline).font(.callout.weight(.semibold))
                        Text("\(Fmt.pct(quality.score)) of \(Fmt.int(quality.total)) figures have a value").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 300, alignment: .leading)
                PartBar(parts: [
                    PartBar.Part(label: "Reported", value: Double(quality.reported), color: Palette.good),
                    PartBar.Part(label: "Derived", value: Double(quality.derived), color: Palette.primary),
                    PartBar.Part(label: "Missing", value: Double(quality.missing), color: Palette.warning),
                ])
            }
            if !quality.gaps.isEmpty {
                Divider()
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
                    GridRow { Text(""); Text("Figure"); Text("Affected"); Text("Taken from"); Text("What it means") }.font(.caption).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(quality.gaps) { g in
                        GridRow {
                            Image(systemName: g.kind.symbol).foregroundStyle(g.kind.color).help(g.kind.label)
                            Text("\(g.area) · \(g.title)").font(.callout.weight(.medium))
                            Text(g.total > 0 ? "\(Fmt.int(g.affected)) / \(Fmt.int(g.total))" : "—").tabular()
                            Text(g.fallback.isEmpty ? "—" : g.fallback).font(.callout)
                            Text(g.impact).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
