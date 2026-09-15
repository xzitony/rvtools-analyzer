import Charts
import RVToolsCore
import SwiftUI

struct ComputeView: View {
    @Environment(AppModel.self) private var model
    let report: Report

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("View", selection: $model.computeTab) {
                Text("Clusters").tag(0)
                Text("Hosts").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240).padding(.vertical, 10)
            Divider()
            if model.computeTab == 0 { ClustersPane(report: report) } else { HostsPane(report: report) }
        }
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).tabular().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ClustersPane: View {
    @Environment(AppModel.self) private var model
    let report: Report

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 440), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(report.inventory.clusters) { c in ClusterCard(cluster: c, thresholds: report.thresholds) }
                }
                HostUtilizationCard(hosts: report.inventory.hosts)
            }
            .padding(20)
        }
    }
}

struct ClusterCard: View {
    @Environment(AppModel.self) private var model
    let cluster: Cluster
    let thresholds: Thresholds

    var body: some View {
        let c = cluster
        Card(c.name, subtitle: [c.vcenter, c.datacenter].filter { !$0.isEmpty }.joined(separator: " › ")) {
            HStack(spacing: 6) {
                if c.isStandalone {
                    Tag(text: "Not in a cluster")
                } else {
                    StateChip(label: "HA", state: c.haEnabled)
                    StateChip(label: "Admission control", state: c.admissionControl)
                    StateChip(label: "DRS", state: c.drsEnabled)
                }
                Spacer()
                RelationshipMapButton(focus: .cluster(c.id), compact: true)
                if c.issueCount > 0 { Button("\(c.issueCount) cluster finding\(c.issueCount == 1 ? "" : "s")") { model.showIssues() }.buttonStyle(.link).font(.caption) }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Stat(label: "Hosts", value: "\(c.hostCount)" + (c.hostsInMaintenance > 0 ? " (\(c.hostsInMaintenance) maint.)" : ""))
                    Stat(label: "Cores / threads", value: "\(Fmt.int(c.cores)) / \(Fmt.int(c.threads))")
                    Stat(label: "Memory", value: Fmt.memory(mib: c.memoryMiB))
                    Stat(label: "Datastores", value: "\(c.datastoreCount)")
                }
                GridRow {
                    Stat(label: "VMs on / total", value: "\(Fmt.int(c.vmsOn)) / \(Fmt.int(c.vmCount))")
                    Stat(label: "vCPU : core", value: Fmt.ratio(c.vcpuPerCore))
                    Stat(label: "vRAM : RAM", value: Fmt.pct(c.vramPerPhysical * 100))
                    Stat(label: "Templates", value: "\(c.templates)")
                }
                GridRow {
                    Stat(label: "vCPU (on)", value: Fmt.int(c.vcpuOn))
                    Stat(label: "vRAM (on)", value: Fmt.memory(mib: c.vramOnMiB))
                    Stat(label: "Provisioned", value: Fmt.capacity(mib: c.provisionedMiB))
                    Stat(label: "In use", value: Fmt.capacity(mib: c.inUseMiB))
                }
            }
            LabeledMeter(label: "CPU used", pct: c.cpuUsagePct, detail: "\(Fmt.ghz(c.cpuUsedMHz)) of \(Fmt.ghz(c.cpuMHz))", warn: thresholds.hostCPUWarnPct, crit: 95)
            LabeledMeter(label: "Memory used", pct: c.memUsagePct, detail: "\(Fmt.memory(mib: c.memUsedMiB)) of \(Fmt.memory(mib: c.memoryMiB))", warn: thresholds.hostMemWarnPct, crit: 95)
            if c.hostCount > 1 {
                LabeledMeter(label: "Memory if the largest host fails (N+1)", pct: c.memPctAfterHostLoss,
                             detail: "\(Fmt.memory(mib: c.memUsedMiB)) needed vs \(Fmt.memory(mib: c.memoryMiB - c.largestHostMemMiB)) remaining", warn: 90, crit: 100)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("ESXi: " + (c.esxVersions.isEmpty ? "—" : c.esxVersions.joined(separator: " · ")))
                Text("CPU: " + (c.cpuModels.isEmpty ? "—" : c.cpuModels.joined(separator: " · ")))
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

struct HostUtilizationCard: View {
    let hosts: [RVToolsCore.Host]

    var body: some View {
        let top = Array(hosts.sorted { max($0.cpuUsagePct, $0.memUsagePct) > max($1.cpuUsagePct, $1.memUsagePct) }.prefix(30))
        let names = top.map { $0.name.split(separator: ".").first.map(String.init) ?? $0.name }
        let lw = barLabelWidth(names)
        Card("Host utilization", subtitle: hosts.count > top.count ? "Top \(top.count) of \(hosts.count) hosts by peak utilization" : "CPU and memory usage per host") {
            LegendRow(items: [("CPU", Palette.series[0]), ("Memory", Palette.series[1])]).padding(.leading, lw + 8)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(top.enumerated()), id: \.offset) { i, h in
                    HStack(spacing: 8) {
                        Text(names[i]).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: lw, alignment: .trailing)
                        VStack(spacing: 3) {
                            usageBar(h.cpuUsagePct, Palette.series[0])
                            usageBar(h.memUsagePct, Palette.series[1])
                        }
                    }
                    .help("\(h.name): CPU \(Fmt.pct(h.cpuUsagePct)) · memory \(Fmt.pct(h.memUsagePct))")
                }
            }
        }
    }

    private func usageBar(_ pct: Double, _ color: Color) -> some View {
        GeometryReader { g in
            let w = max(g.size.width - 46, 20)
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(color).frame(width: max(2, w * min(pct, 100) / 100))
                }
                .frame(width: w)
                Text(Fmt.pct(pct)).font(.caption2).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
        }
        .frame(height: 8)
    }
}

struct HostsPane: View {
    @Environment(AppModel.self) private var model
    let report: Report
    @State private var sortOrder = [KeyPathComparator(\RVToolsCore.Host.name)]
    @State private var search = ""

    private var rows: [RVToolsCore.Host] {
        let q = search.lowercased()
        let all = report.inventory.hosts
        guard !q.isEmpty else { return all.sorted(using: sortOrder) }
        let matches = all.filter { (h: RVToolsCore.Host) -> Bool in
            let text: String = [h.name, h.cluster, h.vendor, h.model, h.cpuModel, h.esxVersion].joined(separator: "\n").lowercased()
            return text.contains(q)
        }
        return matches.sorted(using: sortOrder)
    }

    static func esxLabel(_ h: ESXiHost) -> String {
        h.esxBuild.isEmpty ? h.esxVersion : "\(h.esxVersion) (\(h.esxBuild))"
    }

    static func modelLabel(_ h: ESXiHost) -> String {
        [h.vendor, h.model].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        @Bindable var model = model
        let th = report.thresholds
        let cpuWarn = th.hostCPUWarnPct, memWarn = th.hostMemWarnPct
        Table(rows, selection: $model.selectedHostID, sortOrder: $sortOrder) {
            Group {
                TableColumn("Host", sortUsing: KeyPathComparator(\ESXiHost.name)) { (h: ESXiHost) in
                    Text(h.isVirtual ? "\(h.name)  · virtual" : h.name).help(h.isVirtual ? "Virtual host (witness / placeholder) — excluded from capacity totals" : h.name)
                }
                .width(min: 150, ideal: 200)
                TableColumn("Cluster", sortUsing: KeyPathComparator(\ESXiHost.cluster)) { (h: ESXiHost) in Text(h.cluster) }
                    .width(min: 90, ideal: 120)
                TableColumn("CPU", sortUsing: KeyPathComparator(\ESXiHost.cpuUsagePct)) { (h: ESXiHost) in UsageMeter(pct: h.cpuUsagePct, warn: cpuWarn, crit: 95, width: 44) }
                    .width(min: 100, ideal: 110)
                TableColumn("Memory", sortUsing: KeyPathComparator(\ESXiHost.memUsagePct)) { (h: ESXiHost) in UsageMeter(pct: h.memUsagePct, warn: memWarn, crit: 95, width: 44) }
                    .width(min: 100, ideal: 110)
                TableColumn("Cores", sortUsing: KeyPathComparator(\ESXiHost.cores)) { (h: ESXiHost) in Text("\(h.cores)").tabular() }.width(50)
                TableColumn("RAM", sortUsing: KeyPathComparator(\ESXiHost.memoryMiB)) { (h: ESXiHost) in Text(Fmt.memory(mib: h.memoryMiB)).tabular() }.width(70)
            }
            Group {
                TableColumn("VMs on / total", sortUsing: KeyPathComparator(\ESXiHost.vmCount)) { (h: ESXiHost) in Text("\(h.vmsOn) / \(h.vmCount)").tabular() }.width(90)
                TableColumn("vCPU : core", sortUsing: KeyPathComparator(\ESXiHost.vcpuPerCore)) { (h: ESXiHost) in Text(Fmt.ratio(h.vcpuPerCore)).tabular() }.width(80)
                TableColumn("ESXi", sortUsing: KeyPathComparator(\ESXiHost.esxVersion)) { (h: ESXiHost) in Text(HostsPane.esxLabel(h)) }
                    .width(min: 110, ideal: 150)
                TableColumn("Model", sortUsing: KeyPathComparator(\ESXiHost.model)) { (h: ESXiHost) in Text(HostsPane.modelLabel(h)) }
                    .width(min: 100, ideal: 160)
                TableColumn("Issues", sortUsing: KeyPathComparator(\ESXiHost.issueCount)) { (h: ESXiHost) in Text(h.issueCount > 0 ? "\(h.issueCount)" : "").tabular() }.width(50)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Host, cluster, model, ESXi")
        .inspector(isPresented: Binding(get: { model.selectedHostID != nil }, set: { if !$0 { model.selectedHostID = nil } })) {
            if let id = model.selectedHostID, let h = model.lookup.hosts[id] {
                HostDetail(host: h, report: report)
            } else {
                ContentUnavailableView("Select a host", systemImage: "server.rack")
            }
        }
        .inspectorColumnWidth(min: 340, ideal: 420, max: 640)
    }
}

struct HostDetail: View {
    @Environment(AppModel.self) private var model
    let host: RVToolsCore.Host
    let report: Report

    var body: some View {
        let inv = report.inventory
        let th = report.thresholds
        let vms = inv.vms.filter { $0.hostKey == host.id }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let datastores = inv.datastores.filter { $0.hostKeys.contains(host.id) }.sorted { $0.name < $1.name }
        let pnics = inv.pnics.filter { $0.hostKey == host.id }
        let vmks = inv.vmkernels.filter { $0.hostKey == host.id }
        let hbas = inv.hbas.filter { $0.hostKey == host.id }
        let luns = inv.luns.filter { $0.hostKey == host.id }
        let eos = Lifecycle.vsphereEndOfSupport(host.esxVersion)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(host.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text([host.vendor, host.model].filter { !$0.isEmpty }.joined(separator: " ")).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        StateChip(label: host.maintenance ? "Maintenance mode" : "In service", state: !host.maintenance)
                        if !host.configStatus.isEmpty { Tag(text: "Status: \(host.configStatus)") }
                    }
                    RelationshipMapButton(focus: .host(host.id)).padding(.top, 2)
                }
                LabeledMeter(label: "CPU", pct: host.cpuUsagePct, detail: "\(Fmt.ghz(host.cpuUsedMHz)) of \(Fmt.ghz(host.cpuCapacityMHz)) · \(host.vcpuOn) vCPU on \(host.cores) cores (\(Fmt.ratio(host.vcpuPerCore)))",
                             warn: th.hostCPUWarnPct, crit: 95)
                LabeledMeter(label: "Memory", pct: host.memUsagePct, detail: "\(Fmt.memory(mib: host.memUsedMiB)) of \(Fmt.memory(mib: host.memoryMiB)) · \(Fmt.memory(mib: host.vramOnMiB)) vRAM on running VMs",
                             warn: th.hostMemWarnPct, crit: 95)
                Divider()
                DetailSection("Findings", count: report.findingsByObject[host.id]?.count ?? 0) { ObjectFindings(findings: report.findingsByObject[host.id] ?? []) }
                DetailSection("Placement") {
                    KeyValueGrid(rows: [("vCenter", host.vcenter), ("Datacenter", host.datacenter), ("Cluster", host.cluster.isEmpty ? "Standalone" : host.cluster)])
                }
                DetailSection("Hardware") {
                    KeyValueGrid(rows: [
                        ("CPU", host.cpuModel),
                        ("Topology", "\(host.sockets) × \(host.coresPerSocket) = \(host.cores) cores · HT \(host.htActive ? "active" : (host.htAvailable ? "available, off" : "n/a"))"),
                        ("Speed", "\(Fmt.int(Int(host.speedMHz))) MHz"),
                        ("Memory", Fmt.memory(mib: host.memoryMiB)),
                        ("Serial", host.serial), ("BIOS", host.biosVersion), ("Power policy", host.powerPolicy),
                    ])
                }
                DetailSection("Software") {
                    KeyValueGrid(rows: [
                        ("ESXi", host.esxVersion + (host.esxBuild.isEmpty ? "" : " build \(host.esxBuild)")),
                        ("Support ends", eos.map { Fmt.date($0) + ($0 <= inv.reportDate ? " (ended)" : "") } ?? "—"),
                        ("Boot time", Fmt.dateTime(host.bootTime) + (host.uptimeDays.map { " · up \(Fmt.num($0, 0)) days" } ?? "")),
                        ("EVC", host.evcCurrent.isEmpty ? "Disabled (max \(host.evcMax))" : host.evcCurrent),
                        ("NTP", host.ntpServers.isEmpty ? "Not configured" : host.ntpServers + (host.ntpdRunning == false ? " (not running)" : "")),
                        ("DNS", host.dnsServers), ("Time zone", host.timeZone),
                        ("Certificate expiry", Fmt.date(host.certExpiry)), ("Licenses", host.licenses),
                    ])
                }
                DetailSection("Virtual machines", count: vms.count) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(vms.prefix(400)) { vm in
                            Button { model.reveal(vm: vm.id) } label: {
                                HStack(spacing: 6) {
                                    PowerIcon(vm: vm)
                                    Text(vm.name).lineLimit(1)
                                    Spacer()
                                    Text("\(vm.cpus) vCPU · \(Fmt.memory(mib: vm.memoryMiB))").font(.caption).foregroundStyle(.secondary).tabular()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                DetailSection("Datastores", count: datastores.count) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(datastores) { d in
                            Button { model.reveal(datastore: d.id) } label: {
                                HStack(spacing: 8) {
                                    Text(d.name).lineLimit(1)
                                    Spacer()
                                    Text(d.type).font(.caption).foregroundStyle(.secondary)
                                    UsageMeter(pct: d.usedPct, warn: 100 - th.datastoreFreeWarnPct, crit: 100 - th.datastoreFreeCritPct, width: 50)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !pnics.isEmpty {
                    DetailSection("Physical NICs", count: pnics.count) {
                        KeyValueGrid(rows: pnics.map { ($0.device, "\($0.speedMbps == 0 ? "link down" : Fmt.rate(mbps: $0.speedMbps)) · \($0.driver) · \($0.switchName.isEmpty ? "unassigned" : $0.switchName)") })
                    }
                }
                if !vmks.isEmpty {
                    DetailSection("VMkernel adapters", count: vmks.count) {
                        KeyValueGrid(rows: vmks.map { ($0.device, "\($0.portGroup) · \($0.ip) · MTU \($0.mtu)") })
                    }
                }
                if !hbas.isEmpty {
                    DetailSection("Storage adapters", count: hbas.count) {
                        KeyValueGrid(rows: hbas.map { ($0.device, "\($0.type) · \($0.model) · \($0.status)") })
                    }
                }
                if !luns.isEmpty {
                    DetailSection("Storage paths", count: luns.count) {
                        KeyValueGrid(rows: luns.map {
                            ($0.datastore.isEmpty ? $0.disk : $0.datastore, "\($0.paths) paths · \($0.activePaths) active" + ($0.deadPaths > 0 ? " · \($0.deadPaths) dead" : "") + " · \($0.policy)")
                        })
                    }
                }
            }
            .padding(16)
        }
    }
}

struct PowerIcon: View {
    let vm: VM
    var body: some View {
        if vm.isTemplate {
            Image(systemName: "doc.on.doc").foregroundStyle(.secondary).help("Template")
        } else {
            switch vm.powerState {
            case .on: Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Palette.good).help("Powered on")
            case .off: Image(systemName: "circle").font(.system(size: 7)).foregroundStyle(.secondary).help("Powered off")
            case .suspended: Image(systemName: "pause.circle.fill").font(.system(size: 9)).foregroundStyle(Palette.warning).help("Suspended")
            }
        }
    }
}
