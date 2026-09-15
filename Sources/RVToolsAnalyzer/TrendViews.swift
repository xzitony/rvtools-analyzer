import Charts
import RVToolsCore
import SwiftUI

// Trend mode pages: several exports of one environment compared over time.

func trendValue(_ v: Double, _ f: TrendFormat) -> String {
    switch f {
    case .count: return Fmt.int(Int(v.rounded()))
    case .capacityMiB: return Fmt.capacity(mib: v)
    case .percent: return Fmt.pct(v)
    }
}

func trendDelta(_ v: Double, _ f: TrendFormat) -> String {
    let zero = f == .capacityMiB ? abs(v) < 1 : abs(v) < 0.05
    if zero { return "no change" }
    return (v > 0 ? "+" : "−") + trendValue(abs(v), f)
}

func signedInt(_ v: Int) -> String { v == 0 ? "0" : (v > 0 ? "+" : "−") + Fmt.int(abs(v)) }
func signedPct(_ v: Double) -> String { (v >= 0 ? "+" : "−") + Fmt.num(abs(v), 1) + "%" }
func firstLast(_ a: String, _ b: String) -> String { a == b ? b : "\(a) → \(b)" }

// MARK: - Line chart

struct TrendLine: Identifiable {
    let id: String
    let color: Color
    let points: [TrendPoint]
}

/// Values over time (one line per series, legend for ≥ 2) with a hover crosshair and tooltip.
struct TrendLineChart: View {
    let lines: [TrendLine]
    let format: TrendFormat
    var height: CGFloat = 150
    @State private var selected: Date?

    private var dates: [Date] { lines.first?.points.map(\.date) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if lines.count > 1 { LegendRow(items: lines.map { ($0.id, $0.color) }) }
            plot
        }
    }

    private func nearest(_ d: Date?) -> Int? {
        guard let d else { return nil }
        let ds = dates
        return ds.indices.min { abs(ds[$0].timeIntervalSince(d)) < abs(ds[$1].timeIntervalSince(d)) }
    }

    private var plot: some View {
        let ds = dates
        let sel = nearest(selected)
        let selDate = sel.map { ds[$0] }
        return Chart {
            ForEach(lines) { line in
                ForEach(line.points) { p in
                    LineMark(x: .value("Date", p.date), y: .value("Value", p.value), series: .value("Series", line.id))
                        .foregroundStyle(line.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    PointMark(x: .value("Date", p.date), y: .value("Value", p.value))
                        .foregroundStyle(line.color)
                        .symbolSize(selDate == p.date ? 80 : 40)
                }
            }
            if let i = sel {
                RuleMark(x: .value("Date", ds[i]))
                    .foregroundStyle(Palette.neutral.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(i)
                    }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Palette.grid)
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(trendValue(d, format)).font(.caption2) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: ds) { _ in
                AxisTick().foregroundStyle(Palette.grid)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.caption2)
            }
        }
        .chartXSelection(value: $selected)
        .frame(height: height)
        .padding(.top, 4)
    }

    private func tooltip(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Fmt.date(dates[i])).font(.caption.weight(.semibold))
            ForEach(lines) { line in
                if line.points.indices.contains(i) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(line.color).frame(width: 8, height: 8)
                        Text("\(line.id): \(trendValue(line.points[i].value, format))").font(.caption).monospacedDigit()
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
    }
}

// MARK: - Summary

struct TrendSummaryView: View {
    @Environment(AppModel.self) private var model
    let trend: TrendReport

    private struct ChartSpec: Identifiable {
        var id: String { title }
        let title: String
        let subtitle: String
        let lines: [TrendLine]
        let format: TrendFormat
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !trend.warnings.isEmpty { warnings }
                SnapshotStrip(trend: trend)
                kpis
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(charts) { c in
                        Card(c.title, subtitle: c.subtitle) { TrendLineChart(lines: c.lines, format: c.format) }
                    }
                }
                IntervalTable(trend: trend)
            }
            .padding(20)
        }
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(trend.warnings, id: \.self) { w in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Severity.warning.symbol).foregroundStyle(Palette.warning)
                    Text(w).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.warning.opacity(0.12)))
    }

    private var kpis: some View {
        let vms = trend.series(.vms)
        let vcpu = trend.series(.vcpu)
        let hostMoves = trend.count(.hostMove)
        let soonest = trend.datastores.first { $0.daysToFull != nil }
        let soonDays = soonest?.daysToFull ?? .infinity
        let dataValue = trend.netData.map { trendDelta($0.perDay * 30.4, .capacityMiB) + " / mo" } ?? "—"
        let dataDetail = [trend.netData?.annualPct.map { signedPct($0) + " a year" }, trend.organicData?.annualPct.map { "existing VMs " + signedPct($0) }]
            .compactMap { $0 }.joined(separator: " · ")
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            KPITile(title: "Period", value: "\(Fmt.int(Int(trend.spanDays.rounded()))) days",
                    detail: "\(trend.snapshots.count) snapshots · \(Fmt.date(trend.first.date)) → \(Fmt.date(trend.last.date))", symbol: "calendar")
            KPITile(title: "VMs", value: Fmt.int(Int(vms?.last ?? 0)),
                    detail: "+\(trend.count(.added)) added · −\(trend.count(.removed)) removed (net \(signedInt(Int((vms?.last ?? 0) - (vms?.first ?? 0)))))",
                    symbol: "desktopcomputer")
            KPITile(title: "vCPU", value: Fmt.int(Int(vcpu?.last ?? 0)),
                    detail: "\(signedInt(Int((vcpu?.last ?? 0) - (vcpu?.first ?? 0)))) · \(Set(trend.changes.filter { $0.kind == .resized }.map(\.key)).count) VMs resized",
                    symbol: "cpu")
            KPITile(title: "VM data growth", value: dataValue, detail: dataDetail, symbol: "chart.line.uptrend.xyaxis")
            KPITile(title: "Changes", value: Fmt.int(trend.changes.count - hostMoves),
                    detail: "Plus \(Fmt.int(hostMoves)) host moves (DRS / vMotion) · \(trend.infra.count) infrastructure", symbol: "arrow.triangle.2.circlepath")
            KPITile(title: "First datastore full", value: soonest?.daysToFull.map { "\(Fmt.int(Int($0.rounded()))) days" } ?? "—",
                    detail: soonest.map { "\($0.name), around \(Fmt.date($0.fullDate ?? trend.last.date))" } ?? "No datastore is filling up",
                    symbol: soonDays < 180 ? Severity.warning.symbol : "externaldrive",
                    tint: soonDays < 90 ? Palette.critical : (soonDays < 180 ? Palette.warning : nil))
        }
    }

    private func line(_ m: TrendMetric, _ name: String, _ slot: Int) -> TrendLine {
        TrendLine(id: name, color: Palette.series[slot], points: trend.series(m)?.points ?? [])
    }

    private func change(_ m: TrendMetric) -> String {
        guard let s = trend.series(m) else { return "" }
        return "\(trendValue(s.first, m.format)) → \(trendValue(s.last, m.format)) (\(trendDelta(s.last - s.first, m.format)))"
    }

    private var charts: [ChartSpec] { [
        ChartSpec(title: "Virtual machines", subtitle: change(.vms), lines: [line(.vms, "All VMs", 0), line(.vmsOn, "Powered on", 1)], format: .count),
        ChartSpec(title: "vCPU allocated", subtitle: change(.vcpu), lines: [line(.vcpu, "vCPU", 0)], format: .count),
        ChartSpec(title: "vRAM allocated", subtitle: change(.vram), lines: [line(.vram, "vRAM", 0)], format: .capacityMiB),
        ChartSpec(title: "VM storage", subtitle: "Data in use " + change(.data), lines: [line(.provisioned, "Provisioned", 0), line(.data, "Data in use", 1)], format: .capacityMiB),
        ChartSpec(title: "Datastores", subtitle: "Used " + change(.dsUsed), lines: [line(.dsCapacity, "Capacity", 0), line(.dsUsed, "Used", 1)], format: .capacityMiB),
        ChartSpec(title: "Host utilization", subtitle: "CPU " + change(.hostCPU) + " · memory " + change(.hostMem),
                  lines: [line(.hostCPU, "CPU", 0), line(.hostMem, "Memory", 1)], format: .percent),
    ] }
}

/// The snapshots in the series; clicking one opens its dashboards.
struct SnapshotStrip: View {
    @Environment(AppModel.self) private var model
    let trend: TrendReport

    static func sourceLabel(_ s: TrendSnapshot) -> String {
        guard let first = s.sources.first else { return "" }
        let name = first.pathExtension.lowercased() == "csv" ? first.deletingLastPathComponent().lastPathComponent : first.lastPathComponent
        let files = Set(s.sources.map { $0.pathExtension.lowercased() == "csv" ? $0.deletingLastPathComponent().path : $0.path }).count
        return files > 1 ? "\(name) +\(files - 1)" : name
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(trend.snapshots) { s in
                    Button {
                        model.trendSnapshot = s.id
                        model.sidebar = .overview
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("\(s.id + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    .frame(width: 18, height: 18).background(Circle().fill(Palette.primary))
                                Text(Fmt.dateTime(s.date)).font(.callout.weight(.semibold))
                            }
                            Text("\(Fmt.int(s.inventory.vms.filter(\.isVM).count)) VMs · \(s.inventory.hosts.count) hosts · \(s.vcenters.count) vCenter\(s.vcenters.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(SnapshotStrip.sourceLabel(s)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(10)
                        .frame(width: 230, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(model.trendSnapshot == s.id ? Palette.primary : Color.primary.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open this snapshot's dashboards")
                }
            }
        }
    }
}

struct IntervalTable: View {
    @Environment(AppModel.self) private var model
    let trend: TrendReport
    private let kinds: [ChangeKind] = [.added, .removed, .resized, .storage, .clusterMove, .upgraded, .power]

    var body: some View {
        Card("Changes between snapshots", subtitle: "Click an interval to list its changes · host moves (DRS / vMotion) aren't counted here") {
            ScrollView(.horizontal) {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Interval").gridColumnAlignment(.leading)
                        ForEach(kinds) { Text($0.rawValue) }
                        Text("Net VMs")
                        Text("Net vCPU")
                        Text("Data growth")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider()
                    ForEach(trend.intervals) { iv in
                        GridRow {
                            Button {
                                model.trendInterval = iv.snapshot
                                model.trendChangesTab = 0
                                model.sidebar = .trendChanges
                            } label: {
                                Text("\(Fmt.date(iv.from)) → \(Fmt.date(iv.to))")
                            }
                            .buttonStyle(.link)
                            ForEach(kinds) { k in
                                Text(Fmt.int(iv.counts[k] ?? 0)).foregroundStyle((iv.counts[k] ?? 0) == 0 ? .tertiary : .primary)
                            }
                            Text(signedInt(iv.netVMs))
                            Text(signedInt(iv.netVCPU))
                            Text(trendDelta(iv.dataGrowthMiB, .capacityMiB))
                        }
                        .font(.callout).monospacedDigit()
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Changes

struct TrendChangesView: View {
    @Environment(AppModel.self) private var model
    let trend: TrendReport
    @State private var kind: ChangeKind?
    @State private var includeHostMoves = false
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\VMChange.date)]
    @State private var infraSort = [KeyPathComparator(\InfraChange.date)]
    @State private var selection: VMChange.ID?

    private var query: String { search.lowercased().trimmingCharacters(in: .whitespaces) }

    private var rows: [VMChange] {
        var r = trend.changes
        if let k = kind { r = r.filter { $0.kind == k } } else if !includeHostMoves { r = r.filter { $0.kind != .hostMove } }
        if let i = model.trendInterval { r = r.filter { $0.snapshot == i } }
        let q = query
        if !q.isEmpty { r = r.filter { ($0.name + " " + $0.cluster + " " + $0.detail).lowercased().contains(q) } }
        return r.sorted(using: sortOrder)
    }

    private var infraRows: [InfraChange] {
        var r = trend.infra
        if let i = model.trendInterval { r = r.filter { $0.snapshot == i } }
        let q = query
        if !q.isEmpty { r = r.filter { ($0.name + " " + $0.change + " " + $0.detail).lowercased().contains(q) } }
        return r.sorted(using: infraSort)
    }

    var body: some View {
        @Bindable var model = model
        let count = model.trendChangesTab == 0 ? rows.count : infraRows.count
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("View", selection: $model.trendChangesTab) {
                    Text("VMs").tag(0)
                    Text("Infrastructure").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Picker("Interval", selection: $model.trendInterval) {
                    Text("All intervals").tag(Int?.none)
                    ForEach(trend.intervals) { iv in
                        Text("\(Fmt.date(iv.from)) → \(Fmt.date(iv.to))").tag(Int?.some(iv.snapshot))
                    }
                }
                .frame(width: 260)
                if model.trendChangesTab == 0 {
                    Picker("Change", selection: $kind) {
                        Text("All changes").tag(ChangeKind?.none)
                        Divider()
                        ForEach(ChangeKind.allCases) { k in
                            Text("\(k.rawValue) (\(trend.count(k)))").tag(ChangeKind?.some(k))
                        }
                    }
                    .frame(width: 230)
                    Toggle("Include host moves", isOn: $includeHostMoves)
                        .toggleStyle(.checkbox)
                        .disabled(kind != nil)
                        .help("DRS and vMotion move VMs between hosts all the time, so these are hidden unless you ask for them")
                }
                Spacer()
                Text("\(Fmt.int(count)) changes").foregroundStyle(.secondary).font(.callout)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if model.trendChangesTab == 0 { vmTable } else { infraTable }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "VM, cluster or detail")
        .onChange(of: selection) { _, id in
            if let id, trend.changes.indices.contains(id) { model.trendVMKey = trend.changes[id].key }
        }
        .inspector(isPresented: Binding(get: { model.trendVMKey != nil && model.trendChangesTab == 0 },
                                        set: { if !$0 { model.trendVMKey = nil; selection = nil } })) {
            if let key = model.trendVMKey { VMHistoryView(trend: trend, key: key) }
        }
        .inspectorColumnWidth(min: 380, ideal: 460, max: 700)
    }

    private var vmTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Date", sortUsing: KeyPathComparator(\VMChange.date)) { (c: VMChange) in Text(Fmt.date(c.date)).tabular() }.width(90)
            TableColumn("VM", sortUsing: KeyPathComparator(\VMChange.name)) { (c: VMChange) in Text(c.name) }.width(min: 140, ideal: 190)
            TableColumn("Change", sortUsing: KeyPathComparator(\VMChange.kindLabel)) { (c: VMChange) in
                Label(c.kind.rawValue, systemImage: c.kind.symbol)
            }
            .width(min: 120, ideal: 145)
            TableColumn("Details", sortUsing: KeyPathComparator(\VMChange.magnitude)) { (c: VMChange) in Text(c.detail).help(c.detail) }.width(min: 240, ideal: 440)
            TableColumn("Cluster", sortUsing: KeyPathComparator(\VMChange.cluster)) { (c: VMChange) in Text(c.cluster) }.width(min: 90, ideal: 130)
        }
    }

    private var infraTable: some View {
        Table(infraRows, sortOrder: $infraSort) {
            TableColumn("Date", sortUsing: KeyPathComparator(\InfraChange.date)) { (c: InfraChange) in Text(Fmt.date(c.date)).tabular() }.width(90)
            TableColumn("Type", sortUsing: KeyPathComparator(\InfraChange.kindLabel)) { (c: InfraChange) in
                Label(c.kind.rawValue, systemImage: c.kind.symbol)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Name", sortUsing: KeyPathComparator(\InfraChange.name)) { (c: InfraChange) in Text(c.name) }.width(min: 160, ideal: 230)
            TableColumn("Change", sortUsing: KeyPathComparator(\InfraChange.change)) { (c: InfraChange) in Text(c.change) }.width(min: 110, ideal: 150)
            TableColumn("Details", sortUsing: KeyPathComparator(\InfraChange.detail)) { (c: InfraChange) in Text(c.detail).help(c.detail) }.width(min: 240, ideal: 440)
        }
    }
}

// MARK: - VM history

/// One VM across every snapshot, with the attributes that changed highlighted.
struct VMHistoryView: View {
    @Environment(AppModel.self) private var model
    let trend: TrendReport
    let key: String

    var body: some View {
        let hist = trend.history(key)
        let present = hist.compactMap { $0.vm }
        let changes = trend.changes.filter { $0.key == key }
        let points = hist.compactMap { h in
            h.vm.map { TrendPoint(snapshot: h.snapshot.id, date: h.snapshot.date, value: TrendAnalyzer.data($0)) }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(present.last?.name ?? "VM").font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text("In \(present.count) of \(hist.count) snapshots" + (hist.last?.vm == nil ? " · no longer present" : ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button { model.revealTrendVM(key) } label: {
                    Label("Show in Snapshot", systemImage: "arrow.right.circle")
                }
                .help("Open this VM in the dashboards of the latest snapshot it appears in")
                DetailSection("Across snapshots") { VMHistoryGrid(trend: trend, key: key) }
                if points.count >= 2 {
                    DetailSection("Data in use") {
                        TrendLineChart(lines: [TrendLine(id: "Data in use", color: Palette.primary, points: points)], format: .capacityMiB, height: 120)
                    }
                }
                DetailSection("Changes", count: changes.count) {
                    if changes.isEmpty { Text("No changes recorded").font(.callout).foregroundStyle(.secondary) }
                    ForEach(changes) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: c.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(c.kind.rawValue) · \(Fmt.date(c.date))").font(.callout.weight(.medium))
                                Text(c.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct VMHistoryGrid: View {
    let trend: TrendReport
    let key: String

    private struct Attribute {
        let label: String
        let highlight: Bool
        let value: (VM) -> String
    }

    private var attributes: [Attribute] { [
        Attribute(label: "Name", highlight: true) { $0.name },
        Attribute(label: "Power", highlight: true) { $0.powerLabel },
        Attribute(label: "Cluster", highlight: true) { $0.cluster.isEmpty ? "—" : $0.cluster },
        Attribute(label: "Host", highlight: false) { VMsView.shortHost($0) },
        Attribute(label: "vCPU", highlight: true) { "\($0.cpus)" },
        Attribute(label: "Memory", highlight: true) { Fmt.memory(mib: $0.memoryMiB) },
        Attribute(label: "Disks", highlight: true) { "\($0.disks.count) · \(Fmt.capacity(mib: $0.disks.isEmpty ? $0.provisionedMiB : $0.diskCapacityMiB))" },
        Attribute(label: "Data in use", highlight: false) { Fmt.capacity(mib: TrendAnalyzer.data($0)) },
        Attribute(label: "Datastores", highlight: true) { $0.datastoreList },
        Attribute(label: "Networks", highlight: true) { $0.networkList },
        Attribute(label: "HW version", highlight: true) { $0.hwVersion > 0 ? "vmx-\($0.hwVersion)" : "—" },
        Attribute(label: "Tools", highlight: true) { $0.toolsDisplay },
        Attribute(label: "Guest OS", highlight: true) { $0.os.name },
        Attribute(label: "Snapshots", highlight: true) { "\($0.snapshots.count)" },
    ] }

    var body: some View {
        let hist = trend.history(key)
        let attrs = attributes
        ScrollView(.horizontal) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("")
                    ForEach(hist.indices, id: \.self) { i in
                        Text(Fmt.date(hist[i].snapshot.date)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                ForEach(attrs.indices, id: \.self) { a in
                    GridRow {
                        Text(attrs[a].label).foregroundStyle(.secondary)
                        ForEach(hist.indices, id: \.self) { i in
                            cell(attrs[a], hist, i)
                        }
                    }
                }
            }
            .font(.callout)
            .padding(.bottom, 4)
        }
    }

    private func cell(_ attr: Attribute, _ hist: [(snapshot: TrendSnapshot, vm: VM?)], _ i: Int) -> some View {
        let value = hist[i].vm.map(attr.value)
        let previous = i > 0 ? hist[i - 1].vm.map(attr.value) : nil
        let changed = attr.highlight && value != nil && previous != nil && value != previous
        return HStack(spacing: 3) {
            if changed { Circle().fill(Palette.primary).frame(width: 5, height: 5) }
            Text(value ?? "—")
                .fontWeight(changed ? .semibold : .regular)
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
        .help(changed ? "Changed from \(previous ?? "")" : "")
    }
}

// MARK: - Growth

struct TrendGrowthView: View {
    @Environment(AppModel.self) private var model
    let trend: TrendReport
    @State private var sortOrder = [KeyPathComparator(\VMGrowth.deltaMiB, order: .reverse)]
    @State private var selection: VMGrowth.ID?
    @State private var filter = ""

    private var rows: [VMGrowth] {
        let q = filter.lowercased().trimmingCharacters(in: .whitespaces)
        let r = q.isEmpty ? trend.vmGrowth : trend.vmGrowth.filter { ($0.name + " " + $0.cluster).lowercased().contains(q) }
        return r.sorted(using: sortOrder)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    growthCard
                    SizingAssumptionsCard(trend: trend).frame(width: 440)
                }
                Card("VM growth", subtitle: "\(Fmt.int(trend.vmGrowth.count)) VMs present in the first and latest snapshot · data in use is guest data on VMDKs (excluding swap and snapshot deltas) · select a VM for its history") {
                    TextField("Filter by VM or cluster", text: $filter).textFieldStyle(.roundedBorder).frame(width: 280)
                    growthTable.frame(height: 460)
                }
            }
            .padding(20)
        }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let key = selection { VMHistoryView(trend: trend, key: key) }
        }
        .inspectorColumnWidth(min: 380, ideal: 460, max: 700)
    }

    private var growthCard: some View {
        Card("Observed growth", subtitle: "\(trend.snapshots.count) snapshots over \(Fmt.int(Int(trend.spanDays.rounded()))) days · per month from a linear fit across all snapshots, per year compounded from first to latest") {
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    Text("Metric").gridColumnAlignment(.leading)
                    Text("First")
                    Text("Latest")
                    Text("Change")
                    Text("Per month")
                    Text("Per year")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(trend.growth) { g in
                    GridRow {
                        Text(g.label)
                        Text(trendValue(g.first, g.format))
                        Text(trendValue(g.last, g.format))
                        Text(trendDelta(g.change, g.format))
                        Text(trendDelta(g.perDay * 30.4, g.format))
                        Text(g.annualPct.map { signedPct($0) } ?? "—")
                    }
                    .font(.callout).monospacedDigit()
                }
            }
        }
    }

    private var growthTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            Group {
                TableColumn("VM", sortUsing: KeyPathComparator(\VMGrowth.name)) { (g: VMGrowth) in Text(g.name) }.width(min: 140, ideal: 180)
                TableColumn("Cluster", sortUsing: KeyPathComparator(\VMGrowth.cluster)) { (g: VMGrowth) in Text(g.cluster) }.width(min: 90, ideal: 120)
                TableColumn("Data first", sortUsing: KeyPathComparator(\VMGrowth.firstDataMiB)) { (g: VMGrowth) in Text(Fmt.capacity(mib: g.firstDataMiB)).tabular() }.width(80)
                TableColumn("Data latest", sortUsing: KeyPathComparator(\VMGrowth.lastDataMiB)) { (g: VMGrowth) in Text(Fmt.capacity(mib: g.lastDataMiB)).tabular() }.width(80)
                TableColumn("Change", sortUsing: KeyPathComparator(\VMGrowth.deltaMiB)) { (g: VMGrowth) in Text(trendDelta(g.deltaMiB, .capacityMiB)).tabular() }.width(85)
            }
            Group {
                TableColumn("Per month", sortUsing: KeyPathComparator(\VMGrowth.perMonthMiB)) { (g: VMGrowth) in Text(trendDelta(g.perMonthMiB, .capacityMiB)).tabular() }.width(85)
                TableColumn("Per year", sortUsing: KeyPathComparator(\VMGrowth.annualSort)) { (g: VMGrowth) in Text(g.annualPct.map { signedPct($0) } ?? "—").tabular() }.width(70)
                TableColumn("vCPU", sortUsing: KeyPathComparator(\VMGrowth.lastCPU)) { (g: VMGrowth) in Text(firstLast("\(g.firstCPU)", "\(g.lastCPU)")).tabular() }.width(60)
                TableColumn("Memory", sortUsing: KeyPathComparator(\VMGrowth.lastMemMiB)) { (g: VMGrowth) in
                    Text(firstLast(Fmt.memory(mib: g.firstMemMiB), Fmt.memory(mib: g.lastMemMiB))).tabular()
                }
                .width(min: 70, ideal: 110)
                TableColumn("Changes", sortUsing: KeyPathComparator(\VMGrowth.changes)) { (g: VMGrowth) in Text(g.changes > 0 ? "\(g.changes)" : "").tabular() }.width(60)
            }
        }
    }
}

/// Observed rates offered as replacements for the Backup / DR sizing assumptions.
struct SizingAssumptionsCard: View {
    @Environment(AppModel.self) private var model
    let trend: TrendReport

    var body: some View {
        let resized = trend.changes.filter { $0.kind == .resized }
        let up = resized.filter { $0.magnitude > 0 }.count
        let resizedVMs = Set(resized.map(\.key)).count
        let vmCount = max(trend.last.inventory.vms.filter(\.isVM).count, 1)
        let days = Fmt.int(Int(trend.spanDays.rounded()))
        Card("Use in sizing", subtitle: "Replace assumptions with what this environment actually did — the same rates appear beside the assumption on the Assumptions step of Backup Sizing and DR Sizing") {
            VStack(alignment: .leading, spacing: 12) {
                if let all = trend.suggestedGrowthPct {
                    suggestion("Annual data growth — all VMs", all, "Includes VMs added and retired: how the protected footprint actually grew.")
                } else {
                    Text("Growth rates need at least two weeks between the first and latest snapshot.").font(.callout).foregroundStyle(.secondary)
                }
                if let organic = trend.organicGrowthPct {
                    suggestion("Annual data growth — existing VMs", organic, "Organic growth of the VMs present in every snapshot.")
                }
                Text("Currently: Backup Sizing \(pctText(model.paramNumber("backup", "growth"))) · DR Sizing \(pctText(model.paramNumber("dr", "growth")))")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Daily change rate").font(.callout.weight(.semibold))
                    Text(changeRateText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resizing").font(.callout.weight(.semibold))
                    Text("\(resizedVMs) VMs (\(Fmt.pct(Double(resizedVMs) / Double(vmCount) * 100)) of today's VMs) changed vCPU or memory in \(days) days — \(up) up, \(resized.count - up) down. Keep headroom for this when rightsizing into cloud instances.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var changeRateText: String {
        let lead = "RVTools only records point-in-time totals, so the share of blocks rewritten each day can't be measured."
        guard let d = trend.netDailyGrowthPct else { return lead + " Keep your assumption, or use backup-job or CBT statistics." }
        return lead + " Existing VMs grew by a net \(Fmt.num(d, 3))% a day; the real change rate is at least that and usually much higher, because rewritten and deleted blocks don't add capacity. Keep your assumption, or use backup-job or CBT statistics."
    }

    private func pctText(_ v: Double?) -> String { v.map { Fmt.num($0, 1) + "%" } ?? "—" }

    private func suggestion(_ title: String, _ pct: Double, _ help: String) -> some View {
        let value = min(100, max(0, (pct * 2).rounded() / 2))
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(Fmt.num(pct, 1) + "%").font(.title3.weight(.semibold)).monospacedDigit()
            Button("Apply") { model.applyObservedGrowth(value) }
                .help("Set the annual growth assumption of Backup Sizing, DR Sizing and custom solutions that offer the observed growth to \(Fmt.num(value, 1))%")
        }
    }
}

// MARK: - Capacity forecast

struct TrendCapacityView: View {
    @Environment(AppModel.self) private var model
    let trend: TrendReport
    @State private var sortOrder = [KeyPathComparator(\DatastoreTrend.sortDays)]
    @State private var selection: DatastoreTrend.ID?

    var body: some View {
        let capacity = trend.series(.dsCapacity)?.last ?? 0
        let used = trend.series(.dsUsed)?.last ?? 0
        let free = max(0, capacity - used)
        let perDay = trend.datastoreUsed?.perDay ?? 0
        let risk90 = trend.datastores.filter { ($0.daysToFull ?? .infinity) < 90 }.count
        let risk180 = trend.datastores.filter { ($0.daysToFull ?? .infinity) < 180 }.count
        let rows = trend.datastores.sorted(using: sortOrder)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    KPITile(title: "Datastore free", value: Fmt.capacity(mib: free),
                            detail: "of \(Fmt.capacity(mib: capacity)) across \(trend.last.inventory.datastores.count) datastores", symbol: "externaldrive")
                    KPITile(title: "Used growth", value: trendDelta(perDay * 30.4, .capacityMiB) + " / mo",
                            detail: trend.datastoreUsed?.annualPct.map { signedPct($0) + " a year" }, symbol: "chart.line.uptrend.xyaxis")
                    KPITile(title: "Aggregate runway", value: perDay > 0 ? "\(Fmt.int(Int((free / perDay).rounded()))) days" : "—",
                            detail: perDay > 0 ? "Until all free space is used at this rate (assumes perfect balancing)" : "Used space isn't growing", symbol: "hourglass")
                    KPITile(title: "Datastores at risk", value: "\(risk180)", detail: "Full within 180 days · \(risk90) within 90 days",
                            symbol: Severity.warning.symbol, tint: risk90 > 0 ? Palette.critical : (risk180 > 0 ? Palette.warning : nil))
                }
                Card("Datastores", subtitle: "Days until full at the growth rate observed across the snapshots (linear fit) · double-click to open in the latest snapshot") {
                    Table(rows, selection: $selection, sortOrder: $sortOrder) {
                        TableColumn("Datastore", sortUsing: KeyPathComparator(\DatastoreTrend.name)) { (d: DatastoreTrend) in Text(d.name) }.width(min: 140, ideal: 200)
                        TableColumn("Capacity", sortUsing: KeyPathComparator(\DatastoreTrend.capacityLast)) { (d: DatastoreTrend) in
                            Text(firstLast(Fmt.capacity(mib: d.capacityFirst), Fmt.capacity(mib: d.capacityLast))).tabular()
                        }
                        .width(min: 90, ideal: 140)
                        TableColumn("Used", sortUsing: KeyPathComparator(\DatastoreTrend.usedPctLast)) { (d: DatastoreTrend) in UsageMeter(pct: d.usedPctLast) }.width(120)
                        TableColumn("Growth / month", sortUsing: KeyPathComparator(\DatastoreTrend.perDayMiB)) { (d: DatastoreTrend) in
                            Text(trendDelta(d.perMonthMiB, .capacityMiB)).tabular()
                        }
                        .width(100)
                        TableColumn("Days to full", sortUsing: KeyPathComparator(\DatastoreTrend.sortDays)) { (d: DatastoreTrend) in DaysToFullCell(d: d) }.width(110)
                        TableColumn("Full around", sortUsing: KeyPathComparator(\DatastoreTrend.sortDays)) { (d: DatastoreTrend) in
                            Text(d.fullDate.map { ($0.timeIntervalSince(trend.last.date) > 3650 * 86_400) ? "—" : Fmt.date($0) } ?? "—").tabular()
                        }
                        .width(100)
                    }
                    .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { ids in
                        guard let id = ids.first else { return }
                        model.trendSnapshot = trend.snapshots.count - 1
                        model.reveal(datastore: id)
                    })
                    .frame(height: min(560, CGFloat(rows.count) * 24 + 34))
                }
                clusters
            }
            .padding(20)
        }
    }

    private var clusters: some View {
        Card("Clusters", subtitle: "First snapshot each cluster appears in → latest") {
            ScrollView(.horizontal) {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Cluster").gridColumnAlignment(.leading)
                        Text("Hosts")
                        Text("VMs")
                        Text("vCPU (on)")
                        Text("CPU usage")
                        Text("Memory usage")
                        Text("VM data in use")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider()
                    ForEach(trend.clusters) { c in
                        GridRow {
                            Text(c.name)
                            Text(firstLast("\(c.hostsFirst)", "\(c.hostsLast)"))
                            Text(firstLast("\(c.vmsFirst)", "\(c.vmsLast)"))
                            Text(firstLast(Fmt.int(c.vcpuFirst), Fmt.int(c.vcpuLast)))
                            Text(firstLast(Fmt.pct(c.cpuPctFirst), Fmt.pct(c.cpuPctLast)))
                            Text(firstLast(Fmt.pct(c.memPctFirst), Fmt.pct(c.memPctLast)))
                            Text(firstLast(Fmt.capacity(mib: c.dataFirst), Fmt.capacity(mib: c.dataLast)))
                        }
                        .font(.callout).monospacedDigit()
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

struct DaysToFullCell: View {
    let d: DatastoreTrend

    var body: some View {
        if let days = d.daysToFull {
            HStack(spacing: 4) {
                if days < 90 {
                    Image(systemName: Severity.critical.symbol).foregroundStyle(Palette.critical).help("Full within 90 days")
                } else if days < 180 {
                    Image(systemName: Severity.warning.symbol).foregroundStyle(Palette.warning).help("Full within 180 days")
                }
                Text(days > 3650 ? "> 10 years" : "\(Fmt.int(Int(days.rounded()))) days").tabular()
            }
        } else {
            Text("Not growing").foregroundStyle(.secondary)
        }
    }
}
