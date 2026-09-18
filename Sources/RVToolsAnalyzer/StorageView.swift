import Charts
import RVToolsCore
import SwiftUI

struct StorageView: View {
    @Environment(AppModel.self) private var model
    let report: Report

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("View", selection: $model.storageTab) {
                Text("Overview").tag(0)
                Text("Datastores").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240).padding(.vertical, 10)
            Divider()
            VMCDatastoreNotice(report: report).padding(.horizontal, 16).padding(.top, 10)
            UnusedLocalDatastoresNotice(report: report).padding(.horizontal, 16).padding(.top, 10)
            if model.storageTab == 0 { StorageOverview(report: report) } else { DatastoresPane(report: report) }
        }
    }
}

/// Says when host-local datastores with no VM files are left out (or could be), with a one-click switch.
/// VMC on AWS lists the cluster's vSAN capacity as both vsanDatastore and WorkloadDatastore.
struct VMCDatastoreNotice: View {
    @Environment(AppModel.self) private var model
    let report: Report

    var body: some View {
        let dupes = report.vmcManagementDatastores
        if !dupes.isEmpty {
            let left = report.thresholds.ignoreVMCManagementDatastore
            let names = dupes.map(\.name).sorted().joined(separator: ", ")
            HStack(spacing: 10) {
                Image(systemName: left ? "eye.slash" : "eye").foregroundStyle(Palette.primary)
                Text("\(names) reports the same vSAN capacity as WorkloadDatastore (VMware Cloud on AWS) and "
                     + (left ? "is left out of totals, findings and charts." : "is counted again in totals, findings and charts."))
                    .font(.callout)
                Spacer()
                Button(left ? "Include It" : "Leave It Out") { model.thresholds.ignoreVMCManagementDatastore.toggle() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.track.opacity(0.5)))
        }
    }
}

struct UnusedLocalDatastoresNotice: View {
    @Environment(AppModel.self) private var model
    let report: Report

    var body: some View {
        let unused = report.unusedLocalDatastores
        if !unused.isEmpty {
            let left = report.thresholds.ignoreUnusedLocalDatastores
            let n = unused.count
            let what = "\(n) local datastore\(n == 1 ? "" : "s") with no VM files (\(Fmt.capacity(mib: unused.reduce(0) { $0 + $1.capacityMiB })))"
            HStack(spacing: 10) {
                Image(systemName: left ? "eye.slash" : "eye").foregroundStyle(Palette.primary)
                Text(left ? "\(what) \(n == 1 ? "is" : "are") left out of totals, findings and charts." : "\(what) \(n == 1 ? "is" : "are") included in totals, findings and charts.")
                    .font(.callout)
                    .help(unused.map(\.name).sorted().joined(separator: ", "))
                Spacer()
                Button(left ? "Include Them" : "Leave Them Out") { model.thresholds.ignoreUnusedLocalDatastores.toggle() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.track.opacity(0.5)))
        }
    }
}

struct StorageOverview: View {
    @Environment(AppModel.self) private var model
    let report: Report

    var body: some View {
        let t = report.totals, s = report.storage, d = report.dist
        let diskTotal = max(s.thinMiB + s.thickMiB + s.rdmMiB, 1)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    let q = report.dataQuality, dsKnown = q.datastoreCapacityKnown
                    KPITile(title: "Capacity", value: dsKnown ? Fmt.capacity(mib: t.dsCapacityMiB) : "—", detail: "\(t.datastores) datastores" + (dsKnown ? "" : " · vDatastore tab not in export"), symbol: "externaldrive")
                    KPITile(title: "Used", value: dsKnown ? Fmt.pct(t.dsUsedPct) : "—", detail: dsKnown ? "\(Fmt.capacity(mib: t.dsUsedMiB)) used · \(Fmt.capacity(mib: t.dsFreeMiB)) free" : "Not in export", symbol: "chart.bar.fill")
                    KPITile(title: "Provisioned", value: dsKnown ? Fmt.pct(t.dsCapacityMiB > 0 ? t.dsProvisionedMiB / t.dsCapacityMiB * 100 : 0) : "—",
                            detail: dsKnown ? "\(Fmt.capacity(mib: t.dsProvisionedMiB)) promised to VMs (thin overcommit)" : "Not in export", symbol: "arrow.up.right.square")
                    KPITile(title: "VM in use", value: Fmt.capacity(mib: t.vmInUseMiB), detail: "of \(Fmt.capacity(mib: t.vmProvisionedMiB)) VM provisioned", symbol: "internaldrive")
                    KPITile(title: "Guest used", value: q.has("vPartition") ? Fmt.capacity(mib: t.guestConsumedMiB) : "—",
                            detail: q.has("vPartition") ? "of \(Fmt.capacity(mib: t.guestCapacityMiB)) guest file systems" : "vPartition tab not in export", symbol: "folder")
                    KPITile(title: "Thin provisioned", value: q.has("vDisk") ? Fmt.pct(s.thinMiB / diskTotal * 100) : "—",
                            detail: q.has("vDisk") ? "\(Fmt.capacity(mib: s.thinMiB)) thin · \(Fmt.capacity(mib: s.thickMiB)) thick" : "vDisk tab not in export", symbol: "square.dashed")
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("Datastore utilization", subtitle: "Most-used datastores") {
                        DatastoreUsageChart(datastores: report.inventory.datastores, thresholds: report.thresholds, limit: 15)
                    }
                    Card("Reclaim opportunities", subtitle: "Correlated from vInfo, vSnapshot, vPartition, vDatastore and vHealth") {
                        VStack(spacing: 0) {
                            reclaimRow("Powered-off VMs", Fmt.capacity(mib: s.poweredOffProvisionedMiB), "\(t.vmsOff) VMs · \(Fmt.capacity(mib: s.poweredOffInUseMiB)) actually in use", rule: "vm.poweredoff")
                            reclaimRow("Snapshots", report.dataQuality.has("vSnapshot") ? Fmt.capacity(mib: s.snapshotMiB) : "—",
                                       report.dataQuality.has("vSnapshot") ? "\(t.snapshots) snapshots in delta files" : "vSnapshot tab not in export", rule: "vm.snapshot.old")
                            reclaimRow("Templates", Fmt.capacity(mib: s.templateProvisionedMiB), "\(t.templates) templates provisioned", rule: nil)
                            reclaimRow("Free space inside guests", report.dataQuality.has("vPartition") ? Fmt.capacity(mib: s.guestFreeMiB) : "—",
                                       report.dataQuality.has("vPartition") ? "Right-sizing headroom in guest file systems" : "vPartition tab not in export", rule: nil)
                            reclaimRow("Empty datastores", Fmt.capacity(mib: report.inventory.datastores.filter { $0.vmCount == 0 }.reduce(0) { $0 + $1.capacityMiB }),
                                       "\(report.inventory.datastores.filter { $0.vmCount == 0 }.count) datastores with no VM files", rule: "ds.empty")
                            reclaimRow("Zombie files (RVTools)", "\(s.zombieFiles)", "VMDKs not attached to any registered VM", rule: "vhealth.zombie")
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("Capacity by datastore type") {
                        BarListChart(items: d.datastoreType, value: { $0.value }, label: { "\(Fmt.capacity(mib: $0.value)) · \($0.count)" })
                    }
                    Card("Virtual disk provisioning", subtitle: "By provisioned capacity") {
                        BarListChart(items: d.diskProvisioning, value: { $0.value }, label: { "\(Fmt.capacity(mib: $0.value)) · \(Fmt.int($0.count)) disks" })
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("Snapshot age", subtitle: "Measured from the export date") { ColumnChart(items: d.snapshotAge) }
                    Card("Guest partition free space", subtitle: "Number of guest file systems by % free") { ColumnChart(items: d.guestFree) }
                }
                Card("Largest VMs by provisioned storage") {
                    BarListChart(items: topVMs, value: { $0.value }, label: { Fmt.capacity(mib: $0.value) })
                }
            }
            .padding(20)
        }
    }

    private var topVMs: [CountItem] {
        var seen: [String: Int] = [:]
        return report.inventory.vms.sorted { $0.provisionedMiB > $1.provisionedMiB }.prefix(12).map { vm in
            seen[vm.name, default: 0] += 1
            let label = seen[vm.name]! > 1 ? "\(vm.name) (\(seen[vm.name]!))" : vm.name
            return CountItem(label: label, count: 0, value: vm.provisionedMiB)
        }
    }

    private func reclaimRow(_ title: String, _ value: String, _ detail: String, rule: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).font(.title3.weight(.semibold)).tabular()
            if let rule, report.groups.contains(where: { $0.rule == rule }) {
                Button { model.showIssues(rule: rule) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).help("Show affected objects")
            } else {
                Image(systemName: "chevron.right").hidden()
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct DatastoresPane: View {
    @Environment(AppModel.self) private var model
    let report: Report
    @State private var sortOrder = [KeyPathComparator(\Datastore.usedPct, order: .reverse)]
    @State private var search = ""

    /// Path redundancy per datastore, for the Paths column: "4×6" is 4 paths from each of 6 hosts.
    private var pathSummaries: [String: (short: String, detail: String, alert: Bool)] {
        StoragePaths.map(report.inventory).mapValues { p in
            switch p.transport {
            case .nfs:
                let vmk = p.hosts.map { $0.vmkernels.count }.min() ?? 0
                return (vmk == 0 ? "NFS" : "\(vmk) vmk", p.summary, !p.noVMKHosts.isEmpty || !p.singleUplinkHosts.isEmpty)
            case .vsan, .local, .vvol:
                return ("—", p.summary, false)
            default:
                guard p.maxPaths > 0 else { return ("—", p.summary, false) }
                let paths = p.minPaths == p.maxPaths ? "\(p.minPaths)" : "\(p.minPaths)–\(p.maxPaths)"
                return ("\(paths)×\(p.hosts.filter(\.hasPathData).count)", p.summary, p.deadPaths > 0 || !p.singlePathHosts.isEmpty)
            }
        }
    }

    private var rows: [Datastore] {
        let q = search.lowercased()
        let r = q.isEmpty ? report.inventory.datastores : report.inventory.datastores.filter {
            $0.name.lowercased().contains(q) || $0.type.lowercased().contains(q) || $0.clusterList.lowercased().contains(q)
        }
        return r.sorted(using: sortOrder)
    }

    var body: some View {
        @Bindable var model = model
        let th = report.thresholds
        let warn = 100 - th.datastoreFreeWarnPct, crit = 100 - th.datastoreFreeCritPct
        Table(rows, selection: $model.selectedDatastoreID, sortOrder: $sortOrder) {
            Group {
                TableColumn("Datastore", value: \Datastore.name) { (d: Datastore) in
                    HStack(spacing: 4) {
                        Text(d.name)
                        if d.isLocal { Tag(text: "local") }
                    }
                }
                .width(min: 160, ideal: 220)
                TableColumn("Type", value: \Datastore.type).width(60)
                TableColumn("Capacity", value: \Datastore.capacityMiB) { (d: Datastore) in Text(Fmt.capacity(mib: d.capacityMiB)).tabular() }.width(80)
                TableColumn("Used", value: \Datastore.usedPct) { (d: Datastore) in UsageMeter(pct: d.usedPct, warn: warn, crit: crit, width: 48) }
                    .width(min: 105, ideal: 115)
                TableColumn("Free", value: \Datastore.freeMiB) { (d: Datastore) in Text(Fmt.capacity(mib: d.freeMiB)).tabular() }.width(80)
                TableColumn("Provisioned", value: \Datastore.provisionedPct) { (d: Datastore) in Text(Fmt.pct(d.provisionedPct)).tabular() }.width(80)
            }
            Group {
                TableColumn("VMs", value: \Datastore.vmCount) { (d: Datastore) in Text("\(d.vmCount)").tabular() }.width(45)
                TableColumn("Hosts", value: \Datastore.hostCount) { (d: Datastore) in Text("\(d.hostCount)").tabular() }.width(45)
                TableColumn("Paths") { (d: Datastore) in
                    let p = pathSummaries[d.id]
                    Text(p?.short ?? "—").foregroundStyle(p?.alert == true ? Palette.critical : Color.primary).tabular()
                        .help(p?.detail ?? "")
                }
                .width(70)
                TableColumn("Clusters", value: \Datastore.clusterList).width(min: 90, ideal: 120)
                TableColumn("Findings", value: \Datastore.issueCount) { (d: Datastore) in Text(d.issueCount > 0 ? "\(d.issueCount)" : "").tabular() }.width(60)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Datastore, type, cluster")
        .inspector(isPresented: Binding(get: { model.selectedDatastoreID != nil }, set: { if !$0 { model.selectedDatastoreID = nil } })) {
            if let id = model.selectedDatastoreID, let d = model.lookup.datastores[id] {
                DatastoreDetail(datastore: d, report: report)
            } else {
                ContentUnavailableView("Select a datastore", systemImage: "externaldrive")
            }
        }
        .inspectorColumnWidth(min: 340, ideal: 420, max: 640)
    }
}

/// How each host reaches the datastore: paths and adapters for block storage, VMkernel adapters and uplinks for NFS.
struct StoragePathsSection: View {
    @Environment(AppModel.self) private var model
    let paths: DatastorePaths

    var body: some View {
        if !paths.hosts.isEmpty, paths.transport == .vvol {
            DetailSection("Storage paths") {
                Text("\(paths.transport.rawValue) · \(paths.summary).").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !paths.hosts.isEmpty, paths.transport != .vsan, paths.transport != .local {
            DetailSection("Storage paths", count: paths.hosts.count) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(paths.transport.rawValue) · \(paths.summary)").font(.caption).foregroundStyle(.secondary)
                    if paths.transport == .nfs, !paths.server.isEmpty {
                        Text("Server \(paths.server)\(paths.exportPath.isEmpty ? "" : " · \(paths.exportPath)")").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(paths.hosts) { h in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Button(h.host.split(separator: ".").first.map(String.init) ?? h.host) { model.reveal(host: h.hostKey) }
                                .buttonStyle(.link).lineLimit(1)
                            Spacer()
                            Text(line(h)).font(.caption).foregroundStyle(alert(h) ? Palette.critical : .secondary)
                        }
                    }
                    if paths.transport == .nfs {
                        Text("NFS has no multipathing: redundancy comes from the VMkernel adapters and the uplinks behind them.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func line(_ h: HostStoragePaths) -> String {
        if paths.transport == .nfs {
            guard !h.vmkernels.isEmpty else { return "no storage VMkernel" }
            let mtu = h.mtus.map(String.init).joined(separator: "/")
            return "\(h.vmkernels.map(\.device).joined(separator: ", ")) · MTU \(mtu) · \(h.uplinks) uplink\(h.uplinks == 1 ? "" : "s")"
        }
        guard h.hasPathData else { return "no path data" }
        let dead = h.deadPaths > 0 ? " · \(h.deadPaths) dead" : ""
        let adapters = h.adapters.isEmpty ? "" : " · " + h.adapterList
        return "\(h.paths) path\(h.paths == 1 ? "" : "s")\(dead)\(adapters)"
    }

    private func alert(_ h: HostStoragePaths) -> Bool {
        if paths.transport == .nfs { return h.vmkernels.isEmpty || h.uplinks == 1 }
        return h.deadPaths > 0 || (h.hasPathData && h.paths == 1) || (h.paths > 1 && h.adapters.count == 1)
    }
}

struct DatastoreDetail: View {
    @Environment(AppModel.self) private var model
    let datastore: Datastore
    let report: Report

    var body: some View {
        let d = datastore
        let th = report.thresholds
        let vms: [(VM, Double)] = d.vmIDs.compactMap { id in
            guard let vm = model.lookup.vms[id] else { return nil }
            return (vm, vm.disks.filter { $0.datastore == d.name }.reduce(0) { $0 + $1.capacityMiB })
        }.sorted { $0.1 > $1.1 }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text("\(d.type) · \(Fmt.capacity(mib: d.capacityMiB))" + (d.isLocal ? " · local to one host" : "")).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        RelationshipMapButton(focus: .datastore(d.id))
                        // Only where there is pathing to show: vSAN and local disks have none.
                        if d.lunPaths > 0 || d.type.lowercased().contains("nfs") {
                            RelationshipMapButton(focus: .storagePaths(d.id), title: "Storage Paths", symbol: "point.topleft.down.to.point.bottomright.curvepath",
                                                  hint: "Hosts, adapters and the devices behind this datastore, without VMs")
                        }
                    }
                    .padding(.top, 2)
                }
                LabeledMeter(label: "Used", pct: d.usedPct, detail: "\(Fmt.capacity(mib: d.capacityMiB - d.freeMiB)) used · \(Fmt.capacity(mib: d.freeMiB)) free",
                             warn: 100 - th.datastoreFreeWarnPct, crit: 100 - th.datastoreFreeCritPct)
                LabeledMeter(label: "Provisioned vs capacity", pct: d.provisionedPct, detail: "\(Fmt.capacity(mib: d.provisionedMiB)) provisioned",
                             warn: 100, crit: th.datastoreOvercommitPct)
                Divider()
                DetailSection("Findings", count: report.findingsByObject[d.id]?.count ?? 0) { ObjectFindings(findings: report.findingsByObject[d.id] ?? []) }
                DetailSection("Details") {
                    KeyValueGrid(rows: [
                        ("vCenter", d.vcenter), ("Accessible", d.accessible ? "Yes" : "No"), ("Status", d.configStatus),
                        ("Version", d.majorVersion > 0 ? "VMFS \(d.majorVersion)" : "—"), ("SIOC", d.siocEnabled ? "Enabled" : "Disabled"),
                        ("Datastore cluster", d.datastoreCluster), ("Storage paths", d.lunPaths > 0 ? "\(d.lunPaths) (all hosts)" : "—"),
                        ("Address", d.address), ("URL", d.url),
                    ])
                }
                StoragePathsSection(paths: StoragePaths.paths(for: d, in: report.inventory))
                DetailSection("Hosts", count: d.hostNames.count) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(d.hostKeys, id: \.self) { hk in
                            if let h = model.lookup.hosts[hk] {
                                Button(h.name) { model.reveal(host: hk) }.buttonStyle(.link)
                            }
                        }
                        if d.hostKeys.count < d.hostNames.count {
                            Text(d.hostNames.filter { n in !d.hostKeys.contains { $0.hasSuffix("|" + n.lowercased()) } }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !d.clusters.isEmpty { Text("Clusters: " + d.clusterList).font(.caption).foregroundStyle(.secondary) }
                }
                DetailSection("Virtual machines", count: vms.count) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(vms.prefix(400), id: \.0.id) { vm, mib in
                            Button { model.reveal(vm: vm.id) } label: {
                                HStack(spacing: 6) {
                                    PowerIcon(vm: vm)
                                    Text(vm.name).lineLimit(1)
                                    Spacer()
                                    Text(mib > 0 ? Fmt.capacity(mib: mib) : "config only").font(.caption).foregroundStyle(.secondary).tabular()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}
