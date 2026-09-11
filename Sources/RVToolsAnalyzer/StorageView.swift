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
            if model.storageTab == 0 { StorageOverview(report: report) } else { DatastoresPane(report: report) }
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
                    KPITile(title: "Capacity", value: Fmt.capacity(mib: t.dsCapacityMiB), detail: "\(t.datastores) datastores", symbol: "externaldrive")
                    KPITile(title: "Used", value: Fmt.pct(t.dsUsedPct), detail: "\(Fmt.capacity(mib: t.dsUsedMiB)) used · \(Fmt.capacity(mib: t.dsFreeMiB)) free", symbol: "chart.bar.fill")
                    KPITile(title: "Provisioned", value: Fmt.pct(t.dsCapacityMiB > 0 ? t.dsProvisionedMiB / t.dsCapacityMiB * 100 : 0),
                            detail: "\(Fmt.capacity(mib: t.dsProvisionedMiB)) promised to VMs (thin overcommit)", symbol: "arrow.up.right.square")
                    KPITile(title: "VM in use", value: Fmt.capacity(mib: t.vmInUseMiB), detail: "of \(Fmt.capacity(mib: t.vmProvisionedMiB)) VM provisioned", symbol: "internaldrive")
                    KPITile(title: "Guest used", value: Fmt.capacity(mib: t.guestConsumedMiB), detail: "of \(Fmt.capacity(mib: t.guestCapacityMiB)) guest file systems", symbol: "folder")
                    KPITile(title: "Thin provisioned", value: Fmt.pct(s.thinMiB / diskTotal * 100), detail: "\(Fmt.capacity(mib: s.thinMiB)) thin · \(Fmt.capacity(mib: s.thickMiB)) thick", symbol: "square.dashed")
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("Datastore utilization", subtitle: "Most-used datastores") {
                        DatastoreUsageChart(datastores: report.inventory.datastores, thresholds: report.thresholds, limit: 15)
                    }
                    Card("Reclaim opportunities", subtitle: "Correlated from vInfo, vSnapshot, vPartition, vDatastore and vHealth") {
                        VStack(spacing: 0) {
                            reclaimRow("Powered-off VMs", Fmt.capacity(mib: s.poweredOffProvisionedMiB), "\(t.vmsOff) VMs · \(Fmt.capacity(mib: s.poweredOffInUseMiB)) actually in use", rule: "vm.poweredoff")
                            reclaimRow("Snapshots", Fmt.capacity(mib: s.snapshotMiB), "\(t.snapshots) snapshots in delta files", rule: "vm.snapshot.old")
                            reclaimRow("Templates", Fmt.capacity(mib: s.templateProvisionedMiB), "\(t.templates) templates provisioned", rule: nil)
                            reclaimRow("Free space inside guests", Fmt.capacity(mib: s.guestFreeMiB), "Right-sizing headroom in guest file systems", rule: nil)
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
