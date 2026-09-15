import RVToolsCore
import SwiftUI

struct NetworkView: View {
    @Environment(AppModel.self) private var model
    let report: Report

    var body: some View {
        @Bindable var model = model
        let inv = report.inventory
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                KPITile(title: "Port groups", value: Fmt.int(report.totals.portGroups), detail: "\(inv.portGroups.filter { $0.vmCount == 0 && !$0.isUplink }.count) without VMs")
                KPITile(title: "VLANs", value: Fmt.int(report.totals.vlans), detail: "excluding VLAN 0 / trunks")
                KPITile(title: "Switches", value: "\(inv.dvSwitches.count) + \(Set(inv.vSwitches.map(\.name)).count)", detail: "distributed + standard")
                KPITile(title: "VM NICs", value: Fmt.int(report.totals.nics), detail: "\(Fmt.int(inv.vms.flatMap(\.nics).filter(\.connected).count)) connected")
                KPITile(title: "Physical NICs", value: Fmt.int(inv.pnics.count), detail: "\(inv.pnics.filter { $0.speedMbps == 0 }.count) link down")
                KPITile(title: "VMkernel", value: Fmt.int(inv.vmkernels.count), detail: "\(Set(inv.vmkernels.map(\.mtu)).sorted().map(String.init).joined(separator: " / ")) MTU")
            }
            .padding(.horizontal, 16).padding(.top, 12)
            Picker("View", selection: $model.networkTab) {
                Text("Port groups").tag(0)
                Text("Switches").tag(1)
                Text("VMkernel").tag(2)
                Text("Physical NICs").tag(3)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 440).padding(.vertical, 10)
            Divider()
            switch model.networkTab {
            case 0: PortGroupsPane(report: report)
            case 1: SwitchesPane(report: report)
            case 2: VMKernelPane(report: report)
            default: PhysicalNICPane(report: report)
            }
        }
    }
}

struct PortGroupsPane: View {
    @Environment(AppModel.self) private var model
    let report: Report
    @State private var sortOrder = [KeyPathComparator(\PortGroup.vmCount, order: .reverse)]

    var body: some View {
        @Bindable var model = model
        let rows = report.inventory.portGroups.filter { !$0.isUplink }.sorted(using: sortOrder)
        VSplitView {
            HStack(alignment: .top, spacing: 16) {
                Card("Most-used networks", subtitle: "VMs per port group") { BarListChart(items: report.dist.topNetworks) }
                Card("VM network adapter types") { BarListChart(items: report.dist.nicAdapter) }
            }
            .padding(16)
            .frame(minHeight: 180, idealHeight: 330)
            Table(rows, selection: $model.selectedPortGroupID, sortOrder: $sortOrder) {
                TableColumn("Port group", value: \.name)
                TableColumn("Type", value: \.kind).width(110)
                TableColumn("Switch", value: \.switchName)
                TableColumn("VLAN", value: \.vlanList).width(90)
                TableColumn("Hosts", value: \.hostCount) { Text("\($0.hostCount)").tabular() }.width(50)
                TableColumn("VMs", value: \.vmCount) { Text("\($0.vmCount)").tabular() }.width(50)
                TableColumn("NICs connected", value: \.connectedNics) { Text("\($0.connectedNics) / \($0.nicCount)").tabular() }.width(100)
                TableColumn("Security") { p in
                    let flags = [p.promiscuous ? "promiscuous" : nil, p.macChanges ? "MAC changes" : nil, p.forgedTransmits ? "forged transmits" : nil].compactMap { $0 }
                    if !flags.isEmpty {
                        Label(flags.joined(separator: ", "), systemImage: Severity.warning.symbol).foregroundStyle(Palette.warning).help("Allows " + flags.joined(separator: ", "))
                    } else if p.isVMkernel {
                        Text("VMkernel").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 200)
        }
        .inspector(isPresented: Binding(get: { model.selectedPortGroupID != nil }, set: { if !$0 { model.selectedPortGroupID = nil } })) {
            if let id = model.selectedPortGroupID, let pg = model.lookup.portGroups[id] {
                PortGroupDetail(portGroup: pg, report: report)
            } else {
                ContentUnavailableView("Select a port group", systemImage: "network")
            }
        }
        .inspectorColumnWidth(min: 320, ideal: 380, max: 600)
    }
}

struct PortGroupDetail: View {
    @Environment(AppModel.self) private var model
    let portGroup: PortGroup
    let report: Report

    var body: some View {
        let p = portGroup
        let vms = p.vmIDs.compactMap { model.lookup.vms[$0] }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(p.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                RelationshipMapButton(focus: .portGroup(p.id))
                KeyValueGrid(rows: [
                    ("Type", p.kind), ("Switch", p.switchName), ("VLAN", p.vlanList), ("vCenter", p.vcenter),
                    ("NICs", "\(p.connectedNics) connected of \(p.nicCount)"),
                    ("Security", [p.promiscuous ? "Promiscuous" : nil, p.macChanges ? "MAC changes" : nil, p.forgedTransmits ? "Forged transmits" : nil].compactMap { $0 }.joined(separator: ", ")),
                ])
                DetailSection("Hosts", count: p.hostKeys.count) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(p.hostKeys, id: \.self) { hk in
                            if let h = model.lookup.hosts[hk] { Button(h.name) { model.reveal(host: hk) }.buttonStyle(.link) }
                        }
                    }
                }
                DetailSection("Virtual machines", count: vms.count) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(vms.prefix(400)) { vm in
                            Button { model.reveal(vm: vm.id) } label: {
                                HStack(spacing: 6) {
                                    PowerIcon(vm: vm)
                                    Text(vm.name)
                                    Spacer()
                                    Text(vm.nics.filter { $0.network == p.name }.flatMap(\.ipv4).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
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

struct SwitchesPane: View {
    let report: Report

    var body: some View {
        let inv = report.inventory
        VSplitView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Distributed switches").font(.headline).padding([.top, .horizontal], 12)
                Table(inv.dvSwitches) {
                    TableColumn("Switch") { Text($0.name) }
                    TableColumn("Datacenter") { Text($0.datacenter) }
                    TableColumn("Version") { Text($0.version) }.width(70)
                    TableColumn("Hosts") { Text("\($0.hostMembers)").tabular() }.width(50)
                    TableColumn("Port groups") { Text("\($0.portGroupCount)").tabular() }.width(80)
                    TableColumn("VMs") { Text("\($0.vmCount)").tabular() }.width(50)
                    TableColumn("Max MTU") { Text("\($0.maxMTU)").tabular() }.width(70)
                    TableColumn("LACP") { Text($0.lacp) }
                }
            }
            .frame(minHeight: 150)
            VStack(alignment: .leading, spacing: 6) {
                Text("Standard vSwitches").font(.headline).padding([.top, .horizontal], 12)
                Table(inv.vSwitches) {
                    TableColumn("Host") { Text($0.host) }
                    TableColumn("Switch") { Text($0.name) }.width(90)
                    TableColumn("Ports (free)") { Text("\($0.ports) (\($0.freePorts))").tabular() }.width(100)
                    TableColumn("MTU") { Text("\($0.mtu)").tabular() }.width(60)
                    TableColumn("Teaming") { Text($0.policy) }
                    TableColumn("Security") { s in
                        let flags = [s.promiscuous ? "promiscuous" : nil, s.macChanges ? "MAC changes" : nil, s.forgedTransmits ? "forged transmits" : nil].compactMap { $0 }
                        if !flags.isEmpty { Label(flags.joined(separator: ", "), systemImage: Severity.warning.symbol).foregroundStyle(Palette.warning) }
                    }
                }
            }
            .frame(minHeight: 150)
        }
    }
}

struct VMKernelPane: View {
    let report: Report
    var body: some View {
        Table(report.inventory.vmkernels) {
            TableColumn("Host") { Text($0.host) }
            TableColumn("Device") { Text($0.device) }.width(60)
            TableColumn("Port group") { Text($0.portGroup) }
            TableColumn("IP address") { Text($0.ip).tabular() }
            TableColumn("Subnet") { Text($0.subnet).tabular() }
            TableColumn("Gateway") { Text($0.gateway).tabular() }
            TableColumn("MTU") { Text("\($0.mtu)").tabular() }.width(60)
            TableColumn("DHCP") { Text($0.dhcp ? "Yes" : "No") }.width(50)
        }
    }
}

struct PhysicalNICPane: View {
    let report: Report
    var body: some View {
        Table(report.inventory.pnics) {
            TableColumn("Host") { Text($0.host) }
            TableColumn("Device") { Text($0.device) }.width(70)
            TableColumn("Speed") { n in
                if n.speedMbps == 0 {
                    Label("Link down", systemImage: Severity.warning.symbol).foregroundStyle(Palette.warning)
                } else {
                    Text("\(Fmt.int(n.speedMbps)) Mb/s").tabular()
                }
            }
            .width(110)
            TableColumn("Duplex") { Text($0.duplex) }.width(60)
            TableColumn("Driver") { Text($0.driver) }
            TableColumn("Switch") { Text($0.switchName) }
            TableColumn("MAC") { Text($0.mac).tabular() }
        }
    }
}
