import Foundation

// MARK: - Model

/// The object a relationship map is centred on (ids as in `Inventory`).
public enum RelFocus: Hashable, Codable, Sendable {
    case vm(String), host(String), cluster(String), datastore(String), portGroup(String)
}

public enum RelKind: String, Sendable {
    case datacenter = "Datacenter", cluster = "Cluster", host = "Host", vm = "VM"
    case folder = "Folder", resourcePool = "Resource pool", vApp = "vApp"
    case datastore = "Datastore", storageDevice = "Storage device"
    case portGroup = "Port group", standardSwitch = "Standard switch", distributedSwitch = "Distributed switch"
    case physicalNIC = "Physical NIC", vmkernel = "VMkernel adapter", vlan = "VLAN"
}

/// One object on a relationship map.
public struct RelNode: Identifiable, Hashable, Sendable {
    /// Unique within the map, e.g. "host:<host id>".
    public let id: String
    public let kind: RelKind
    public let name: String
    public var detail = ""
    /// Set when the map can be re-centred on this object.
    public var focus: RelFocus?
    public var issues = 0
    /// Something worth a warning icon (maintenance mode, link down, nearly full, dead paths…).
    public var alert: String?
    /// Drawn subdued (powered-off VMs).
    public var muted = false

    /// The inventory object to reveal in the app, when there is one.
    public var object: (kind: ObjectKind, id: String)? {
        switch focus {
        case .vm(let id)?: return (.vm, id)
        case .host(let id)?: return (.host, id)
        case .cluster(let id)?: return (.cluster, id)
        case .datastore(let id)?: return (.datastore, id)
        case .portGroup(let id)?: return (.network, id)
        case nil: return nil
        }
    }
}

/// A relationship between two nodes, drawn from the left one to the right one.
public struct RelLink: Hashable, Sendable {
    public let from: String
    public let to: String
    public var label = ""
}

public struct RelGroup: Sendable {
    public let title: String
    public var nodes: [RelNode]
}

public struct RelColumn: Sendable {
    public var groups: [RelGroup]
}

/// Everything an object is connected to, laid out in columns around it.
public struct RelationshipMap: Sendable {
    public let focus: RelNode
    public let columns: [RelColumn]
    public let focusColumn: Int
    public let links: [RelLink]

    public var nodes: [RelNode] { columns.flatMap { $0.groups.flatMap(\.nodes) } }

    /// Every relationship on the map, one row per link.
    public func csv() -> String {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = links.compactMap { l -> [String]? in
            guard let a = byID[l.from], let b = byID[l.to] else { return nil }
            return [a.kind.rawValue, a.name, b.kind.rawValue, b.name, l.label, a.detail, b.detail]
        }
        return CSVExport.build(["From type", "From", "To type", "To", "Relationship", "From details", "To details"], rows)
    }

    /// A plain-text summary (command line).
    public func outline(limit: Int = 6) -> String {
        var lines = ["\(focus.kind.rawValue): \(focus.name)" + (focus.detail.isEmpty ? "" : " — \(focus.detail)")]
        for (i, column) in columns.enumerated() {
            lines.append("Column \(i + 1)" + (i == focusColumn ? " (focus)" : ""))
            for g in column.groups {
                lines.append("  \(g.title) (\(g.nodes.count))")
                for n in g.nodes.prefix(limit) {
                    lines.append("    • \(n.name)" + (n.detail.isEmpty ? "" : " — \(n.detail)") + (n.alert.map { " ⚠ \($0)" } ?? ""))
                }
                if g.nodes.count > limit { lines.append("    … \(g.nodes.count - limit) more") }
            }
        }
        lines.append("\(links.count) links")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Builder

public enum RelationshipBuilder {
    /// The map for an object in this inventory, or nil when it isn't in it (e.g. outside the current scope).
    public static func map(_ focus: RelFocus, in inv: Inventory) -> RelationshipMap? {
        let b = MapBuilder(inv)
        switch focus {
        case .vm(let id): return b.vms[id].map(b.vmMap)
        case .host(let id): return b.hosts[id].map(b.hostMap)
        case .cluster(let id): return b.clusters[id].map(b.clusterMap)
        case .datastore(let id): return b.datastores[id].map(b.datastoreMap)
        case .portGroup(let id): return b.portGroups[id].map(b.portGroupMap)
        }
    }

    /// Finds an object by "vm:NAME", "host:NAME", "cluster:NAME", "datastore:NAME" or "portgroup:NAME" (case-insensitive).
    public static func focus(_ spec: String, in inv: Inventory) -> RelFocus? {
        guard let colon = spec.firstIndex(of: ":") else { return nil }
        let kind = spec[..<colon].lowercased(), name = spec[spec.index(after: colon)...].lowercased()
        func matches(_ s: String) -> Bool { s.lowercased() == name }
        switch kind {
        case "vm": return inv.vms.first { matches($0.name) }.map { .vm($0.id) }
        case "host": return inv.hosts.first { matches($0.name) || matches(MapBuilder.short($0.name)) }.map { .host($0.id) }
        case "cluster": return inv.clusters.first { matches($0.name) }.map { .cluster($0.id) }
        case "datastore", "ds": return inv.datastores.first { matches($0.name) }.map { .datastore($0.id) }
        case "portgroup", "network", "pg": return inv.portGroups.first { matches($0.name) }.map { .portGroup($0.id) }
        default: return nil
        }
    }
}

/// Collects nodes into columns and groups, dropping duplicates and empty columns.
private final class Draft {
    var columns: [[RelGroup]]
    var links: [RelLink] = []
    private var seen = Set<String>()
    private var linkIndex: [String: Int] = [:]

    init(columns: Int) { self.columns = Array(repeating: [], count: columns) }

    func contains(_ id: String) -> Bool { seen.contains(id) }

    func add(_ node: RelNode, _ column: Int, _ group: String) {
        guard seen.insert(node.id).inserted else { return }
        if let gi = columns[column].firstIndex(where: { $0.title == group }) {
            columns[column][gi].nodes.append(node)
        } else {
            columns[column].append(RelGroup(title: group, nodes: [node]))
        }
    }

    func link(_ from: String, _ to: String, _ label: String = "") {
        let k = from + ">" + to
        if let i = linkIndex[k] {
            if !label.isEmpty, !links[i].label.contains(label) { links[i].label += links[i].label.isEmpty ? label : "; " + label }
            return
        }
        linkIndex[k] = links.count
        links.append(RelLink(from: from, to: to, label: label))
    }

    func finish(_ focus: RelNode) -> RelationshipMap {
        let cols = columns.map { $0.filter { !$0.nodes.isEmpty } }.filter { !$0.isEmpty }.map(RelColumn.init)
        let fi = cols.firstIndex { $0.groups.contains { $0.nodes.contains { $0.id == focus.id } } } ?? 0
        return RelationshipMap(focus: focus, columns: cols, focusColumn: fi, links: links)
    }
}

private struct MapBuilder {
    let inv: Inventory
    let vms: [String: VM]
    let hosts: [String: Host]
    let clusters: [String: Cluster]
    let datastores: [String: Datastore]
    let portGroups: [String: PortGroup]
    let pnicsByHost: [String: [PhysicalNIC]]
    let vmksByHost: [String: [VMKernel]]
    let lunsByHost: [String: [MultiPathLUN]]
    let vSwitchesByHost: [String: [VSwitchInfo]]
    let dvSwitches: [String: DVSwitchInfo]

    init(_ inv: Inventory) {
        self.inv = inv
        func index<T: Identifiable>(_ list: [T]) -> [String: T] where T.ID == String {
            Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        vms = index(inv.vms)
        hosts = index(inv.hosts)
        clusters = index(inv.clusters)
        datastores = index(inv.datastores)
        portGroups = index(inv.portGroups)
        pnicsByHost = Dictionary(grouping: inv.pnics, by: \.hostKey)
        vmksByHost = Dictionary(grouping: inv.vmkernels, by: \.hostKey)
        lunsByHost = Dictionary(grouping: inv.luns, by: \.hostKey)
        vSwitchesByHost = Dictionary(grouping: inv.vSwitches, by: \.hostKey)
        dvSwitches = Dictionary(inv.dvSwitches.map { (key($0.vcenter, $0.name), $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Nodes

    /// A host name without its domain (IP addresses stay whole).
    static func short(_ name: String) -> String {
        let first = name.split(separator: ".").first.map(String.init) ?? name
        return Int(first) == nil ? first : name
    }

    static func byName(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }

    func node(_ vm: VM) -> RelNode {
        RelNode(id: "vm:" + vm.id, kind: .vm, name: vm.name,
                detail: "\(vm.powerLabel) · \(vm.cpus) vCPU · \(Fmt.capacity(mib: vm.memoryMiB))",
                focus: .vm(vm.id), issues: vm.issueCount, muted: !vm.isRunning)
    }

    func node(_ h: Host) -> RelNode {
        RelNode(id: "host:" + h.id, kind: .host, name: h.name,
                detail: "ESXi \(h.esxShort) · \(h.vmCount) VMs · CPU \(Fmt.pct(h.cpuUsagePct)) · memory \(Fmt.pct(h.memUsagePct))",
                focus: .host(h.id), issues: h.issueCount, alert: h.maintenance ? "Maintenance mode" : nil)
    }

    func node(_ c: Cluster) -> RelNode {
        RelNode(id: "cluster:" + c.id, kind: .cluster, name: c.name,
                detail: "\(c.hostCount) host\(c.hostCount == 1 ? "" : "s") · \(c.vmCount) VMs" + (c.isStandalone ? " · not in a cluster" : ""),
                focus: .cluster(c.id), issues: c.issueCount)
    }

    func datacenterNode(_ vcenter: String, _ datacenter: String) -> RelNode {
        RelNode(id: "dc:" + key(vcenter, datacenter), kind: .datacenter, name: datacenter.isEmpty ? vcenter : datacenter,
                detail: datacenter.isEmpty ? "vCenter" : vcenter)
    }

    func node(_ d: Datastore) -> RelNode {
        RelNode(id: "ds:" + d.id, kind: .datastore, name: d.name,
                detail: "\(d.type) · \(Fmt.capacity(mib: d.capacityMiB)) · \(Fmt.pct(d.usedPct)) used",
                focus: .datastore(d.id), issues: d.issueCount,
                alert: !d.accessible ? "Not accessible" : (d.usedPct >= 90 ? "\(Fmt.pct(d.usedPct)) used" : nil))
    }

    func node(_ p: PortGroup) -> RelNode {
        let flags = [p.promiscuous ? "promiscuous mode" : nil, p.macChanges ? "MAC changes" : nil, p.forgedTransmits ? "forged transmits" : nil].compactMap { $0 }
        return RelNode(id: "pg:" + p.id, kind: .portGroup, name: p.name,
                       detail: "VLAN \(p.vlanList)" + (p.switchName.isEmpty ? "" : " · \(p.switchName)"),
                       focus: .portGroup(p.id), alert: flags.isEmpty ? nil : "Allows " + flags.joined(separator: ", "))
    }

    /// The switch a port group is on: one distributed switch, or the standard switch on one host (or on all its hosts).
    func switchNode(_ p: PortGroup, hostKey: String?) -> RelNode? {
        guard !p.switchName.isEmpty else { return nil }
        if p.kind == "Distributed" {
            let dvs = dvSwitches[key(p.vcenter, p.switchName)]
            let detail = dvs.map { s in
                ["Distributed", s.version.isEmpty ? "" : "v\(s.version)", "\(s.hostMembers) hosts", s.maxMTU > 0 ? "MTU \(s.maxMTU)" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            } ?? "Distributed switch"
            return RelNode(id: "dvs:" + key(p.vcenter, p.switchName), kind: .distributedSwitch, name: p.switchName, detail: detail)
        }
        if let hk = hostKey {
            let vs = vSwitchesByHost[hk]?.first { $0.name.lowercased() == p.switchName.lowercased() }
            return RelNode(id: standardSwitchID(hk, p.switchName), kind: .standardSwitch, name: p.switchName,
                           detail: "\(p.kind) on \(Self.short(hosts[hk]?.name ?? ""))" + ((vs?.mtu ?? 0) > 0 ? " · MTU \(vs!.mtu)" : ""))
        }
        return RelNode(id: "vss:" + key(p.vcenter, p.switchName), kind: .standardSwitch, name: p.switchName,
                       detail: "\(p.kind) · on \(p.hostKeys.count) host\(p.hostKeys.count == 1 ? "" : "s")")
    }

    func standardSwitchID(_ hostKey: String, _ name: String) -> String { "vss:" + hostKey + "|" + name.lowercased() }

    func node(_ n: PhysicalNIC) -> RelNode {
        RelNode(id: "pnic:" + n.id, kind: .physicalNIC, name: "\(Self.short(n.host)) · \(n.device)",
                detail: (n.speedMbps == 0 ? "Link down" : "\(Fmt.int(n.speedMbps)) Mb/s") + (n.driver.isEmpty ? "" : " · \(n.driver)"),
                alert: n.speedMbps == 0 ? "Link down" : nil)
    }

    func node(_ k: VMKernel) -> RelNode {
        RelNode(id: "vmk:" + k.id, kind: .vmkernel, name: "\(Self.short(k.host)) · \(k.device)",
                detail: [k.ip, k.mtu > 0 ? "MTU \(k.mtu)" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    func node(_ l: MultiPathLUN) -> RelNode {
        RelNode(id: "lun:" + l.hostKey + "|" + l.disk.lowercased(), kind: .storageDevice, name: l.displayName.isEmpty ? l.disk : l.displayName,
                detail: "\(l.paths) paths · \(l.activePaths) active" + (l.policy.isEmpty ? "" : " · \(l.policy)"),
                alert: l.deadPaths > 0 ? "\(l.deadPaths) dead paths" : nil)
    }

    func vlanNode(_ vlan: String, _ vcenter: String) -> RelNode {
        RelNode(id: "vlan:" + key(vcenter, vlan), kind: .vlan, name: "VLAN \(vlan)", detail: vcenter)
    }

    // MARK: Maps

    /// Placement (datacenter → cluster → host, folder / resource pool / vApp) ← VM → datastores → devices, networks → switches → uplinks.
    func vmMap(_ vm: VM) -> RelationshipMap {
        let d = Draft(columns: 7)
        let f = node(vm)
        d.add(f, 3, vm.isTemplate ? "Template" : "VM")
        let dc = datacenterNode(vm.vcenter, vm.datacenter)
        d.add(dc, 0, "Datacenter")
        var parent = dc.id
        if let c = clusters[vm.clusterKey], !c.isStandalone {
            let cn = node(c)
            d.add(cn, 1, "Cluster")
            d.link(parent, cn.id)
            parent = cn.id
        }
        if let h = hosts[vm.hostKey] {
            let hn = node(h)
            d.add(hn, 2, "Host")
            d.link(parent, hn.id)
            d.link(hn.id, f.id, "runs on")
        } else {
            d.link(parent, f.id)
        }
        for (kind, value) in [(RelKind.resourcePool, vm.resourcePool), (.folder, vm.folder), (.vApp, vm.vApp)] where !value.isEmpty {
            let name = value.split(separator: "/").last.map(String.init) ?? value
            let n = RelNode(id: "\(kind.rawValue):" + key(vm.vcenter, value), kind: kind, name: name, detail: value == name ? kind.rawValue : value)
            d.add(n, 2, "Organization")
            d.link(n.id, f.id)
        }

        var dsNames: [String] = []
        for name in vm.datastores + vm.disks.map(\.datastore) where !name.isEmpty && !dsNames.contains(where: { $0.lowercased() == name.lowercased() }) {
            dsNames.append(name)
        }
        for name in dsNames {
            let disks = vm.disks.filter { $0.datastore.lowercased() == name.lowercased() }
            let label = disks.isEmpty ? "configuration files" : "\(disks.count) disk\(disks.count == 1 ? "" : "s") · \(Fmt.capacity(mib: disks.reduce(0) { $0 + $1.capacityMiB }))"
            let dn = datastores[key(vm.vcenter, name)].map(node) ?? RelNode(id: "ds:" + key(vm.vcenter, name), kind: .datastore, name: name, detail: "Not in the vDatastore tab")
            d.add(dn, 4, "Datastores")
            d.link(f.id, dn.id, label)
            for l in lunsByHost[vm.hostKey] ?? [] where l.datastore.lowercased() == name.lowercased() {
                let ln = node(l)
                d.add(ln, 5, "Storage devices")
                d.link(dn.id, ln.id)
            }
        }

        let nics = vm.nics.isEmpty ? vm.networks.map { VNic(network: $0, connected: true) } : vm.nics
        for n in nics where !n.network.isEmpty {
            let pg = portGroups[key(vm.vcenter, n.network)]
            let pn = pg.map(node) ?? RelNode(id: "pg:" + key(vm.vcenter, n.network), kind: .portGroup, name: n.network,
                                             detail: n.switchName.isEmpty ? "Not in the vPort or dvPort tab" : n.switchName)
            d.add(pn, 4, "Networks")
            d.link(f.id, pn.id, [n.label, n.ipv4.joined(separator: ", "), n.connected ? "" : "disconnected"].filter { !$0.isEmpty }.joined(separator: " · "))
            guard let pg else { continue }
            if let sw = switchNode(pg, hostKey: pg.kind == "Distributed" ? nil : vm.hostKey) {
                d.add(sw, 5, "Switches")
                d.link(pn.id, sw.id)
                for p in pnicsByHost[vm.hostKey] ?? [] where p.switchName.lowercased() == pg.switchName.lowercased() {
                    let nn = node(p)
                    d.add(nn, 6, "Physical NICs")
                    d.link(sw.id, nn.id)
                }
            }
            for v in pg.vlans {
                let vn = vlanNode(v, pg.vcenter)
                d.add(vn, 5, "VLANs")
                d.link(pn.id, vn.id)
            }
        }
        return d.finish(f)
    }

    /// Datacenter → cluster → host → VMs, datastores → devices, switches → port groups / uplinks → VMkernel adapters.
    func hostMap(_ h: Host) -> RelationshipMap {
        let d = Draft(columns: 6)
        let f = node(h)
        d.add(f, 2, "Host")
        let dc = datacenterNode(h.vcenter, h.datacenter)
        d.add(dc, 0, "Datacenter")
        if let c = clusters[h.clusterKey], !c.isStandalone {
            let cn = node(c)
            d.add(cn, 1, "Cluster")
            d.link(dc.id, cn.id)
            d.link(cn.id, f.id)
        } else {
            d.link(dc.id, f.id)
        }
        let dsList = inv.datastores.filter { $0.hostKeys.contains(h.id) }.sorted { Self.byName($0.name, $1.name) }
        for ds in dsList {
            let n = node(ds)
            d.add(n, 3, "Datastores")
            d.link(f.id, n.id)
        }
        for l in lunsByHost[h.id] ?? [] {
            guard let ds = dsList.first(where: { $0.name.lowercased() == l.datastore.lowercased() }) else { continue }
            let ln = node(l)
            d.add(ln, 4, "Storage devices")
            d.link("ds:" + ds.id, ln.id)
        }
        for pg in inv.portGroups.filter({ $0.hostKeys.contains(h.id) }).sorted(by: { Self.byName($0.name, $1.name) }) {
            let pn = node(pg)
            d.add(pn, 4, "Port groups")
            if let sw = switchNode(pg, hostKey: pg.kind == "Distributed" ? nil : h.id) {
                d.add(sw, 3, "Switches")
                d.link(f.id, sw.id)
                d.link(sw.id, pn.id)
            } else {
                d.link(f.id, pn.id)
            }
        }
        for p in pnicsByHost[h.id] ?? [] {
            let pn = node(p)
            d.add(pn, 4, "Physical NICs")
            let standard = standardSwitchID(h.id, p.switchName), distributed = "dvs:" + key(h.vcenter, p.switchName)
            if p.switchName.isEmpty {
                d.link(f.id, pn.id, "unassigned")
            } else if d.contains(standard) {
                d.link(standard, pn.id)
            } else if d.contains(distributed) {
                d.link(distributed, pn.id)
            } else {
                d.add(RelNode(id: standard, kind: .standardSwitch, name: p.switchName, detail: "Switch on \(Self.short(h.name))"), 3, "Switches")
                d.link(f.id, standard)
                d.link(standard, pn.id)
            }
        }
        for k in vmksByHost[h.id] ?? [] {
            let kn = node(k)
            d.add(kn, 5, "VMkernel adapters")
            let pgID = "pg:" + key(h.vcenter, k.portGroup)
            d.link(d.contains(pgID) ? pgID : f.id, kn.id)
        }
        for vm in inv.vms.filter({ $0.hostKey == h.id }).sorted(by: { Self.byName($0.name, $1.name) }) {
            let n = node(vm)
            d.add(n, 3, "Virtual machines")
            d.link(f.id, n.id)
        }
        return d.finish(f)
    }

    /// Datacenter → cluster → hosts, datastores, port groups (→ switches, VLANs) and VMs.
    func clusterMap(_ c: Cluster) -> RelationshipMap {
        let d = Draft(columns: 4)
        let f = node(c)
        d.add(f, 1, "Cluster")
        let dc = datacenterNode(c.vcenter, c.datacenter)
        d.add(dc, 0, "Datacenter")
        d.link(dc.id, f.id)
        let hostList = inv.hosts.filter { $0.clusterKey == c.id }.sorted { Self.byName($0.name, $1.name) }
        let hostIDs = Set(hostList.map(\.id))
        for h in hostList {
            let n = node(h)
            d.add(n, 2, "Hosts")
            d.link(f.id, n.id)
        }
        for ds in inv.datastores.filter({ $0.clusterKeys.contains(c.id) }).sorted(by: { Self.byName($0.name, $1.name) }) {
            let n = node(ds)
            d.add(n, 2, "Datastores")
            d.link(f.id, n.id)
        }
        for pg in inv.portGroups.filter({ $0.hostKeys.contains(where: hostIDs.contains) }).sorted(by: { Self.byName($0.name, $1.name) }) {
            let pn = node(pg)
            d.add(pn, 2, "Port groups")
            d.link(f.id, pn.id)
            if let sw = switchNode(pg, hostKey: nil) {
                d.add(sw, 3, "Switches")
                d.link(pn.id, sw.id)
            }
            for v in pg.vlans {
                let vn = vlanNode(v, pg.vcenter)
                d.add(vn, 3, "VLANs")
                d.link(pn.id, vn.id)
            }
        }
        for vm in inv.vms.filter({ $0.clusterKey == c.id }).sorted(by: { Self.byName($0.name, $1.name) }) {
            let n = node(vm)
            d.add(n, 2, "Virtual machines")
            d.link(f.id, n.id)
        }
        return d.finish(f)
    }

    /// Clusters → hosts → datastore → storage devices and VMs.
    func datastoreMap(_ ds: Datastore) -> RelationshipMap {
        let d = Draft(columns: 4)
        let f = node(ds)
        d.add(f, 2, "Datastore")
        for h in ds.hostKeys.compactMap({ hosts[$0] }).sorted(by: { Self.byName($0.name, $1.name) }) {
            let hn = node(h)
            d.add(hn, 1, "Hosts")
            d.link(hn.id, f.id)
            if let c = clusters[h.clusterKey], !c.isStandalone {
                let cn = node(c)
                d.add(cn, 0, "Clusters")
                d.link(cn.id, hn.id)
            }
        }
        var devices: [(lun: MultiPathLUN, hosts: Int, paths: Int, dead: Int)] = []
        for l in inv.luns where ds.hostKeys.contains(l.hostKey) && l.datastore.lowercased() == ds.name.lowercased() {
            if let i = devices.firstIndex(where: { $0.lun.disk.lowercased() == l.disk.lowercased() }) {
                devices[i].hosts += 1; devices[i].paths += l.paths; devices[i].dead += l.deadPaths
            } else {
                devices.append((l, 1, l.paths, l.deadPaths))
            }
        }
        for dev in devices {
            let l = dev.lun
            let n = RelNode(id: "dev:" + ds.id + "|" + l.disk.lowercased(), kind: .storageDevice, name: l.displayName.isEmpty ? l.disk : l.displayName,
                            detail: "\(dev.hosts) host\(dev.hosts == 1 ? "" : "s") · \(dev.paths) paths" + (l.policy.isEmpty ? "" : " · \(l.policy)"),
                            alert: dev.dead > 0 ? "\(dev.dead) dead paths" : nil)
            d.add(n, 3, "Storage devices")
            d.link(f.id, n.id)
        }
        for vm in ds.vmIDs.compactMap({ vms[$0] }).sorted(by: { Self.byName($0.name, $1.name) }) {
            let disks = vm.disks.filter { $0.datastore.lowercased() == ds.name.lowercased() }
            let n = node(vm)
            d.add(n, 3, "Virtual machines")
            d.link(f.id, n.id, disks.isEmpty ? "configuration files" : "\(disks.count) disk\(disks.count == 1 ? "" : "s") · \(Fmt.capacity(mib: disks.reduce(0) { $0 + $1.capacityMiB }))")
        }
        return d.finish(f)
    }

    /// Hosts and their uplinks → switch → port group → VLANs, VMkernel adapters and VMs.
    func portGroupMap(_ pg: PortGroup) -> RelationshipMap {
        let d = Draft(columns: 4)
        let f = node(pg)
        d.add(f, 2, "Port group")
        let sw = switchNode(pg, hostKey: nil)
        if let sw {
            d.add(sw, 1, "Switch")
            d.link(sw.id, f.id)
        }
        let hostList = pg.hostKeys.compactMap { hosts[$0] }.sorted { Self.byName($0.name, $1.name) }
        for h in hostList {
            let hn = node(h)
            d.add(hn, 0, "Hosts")
            d.link(hn.id, sw?.id ?? f.id)
        }
        if let sw {
            for h in hostList {
                for p in pnicsByHost[h.id] ?? [] where p.switchName.lowercased() == pg.switchName.lowercased() {
                    let pn = node(p)
                    d.add(pn, 0, "Physical NICs")
                    d.link(pn.id, sw.id)
                }
            }
        }
        for v in pg.vlans {
            let vn = vlanNode(v, pg.vcenter)
            d.add(vn, 3, "VLANs")
            d.link(f.id, vn.id)
        }
        let hostIDs = Set(pg.hostKeys)
        for k in inv.vmkernels where k.portGroup.lowercased() == pg.name.lowercased() && (hostIDs.isEmpty || hostIDs.contains(k.hostKey)) {
            let kn = node(k)
            d.add(kn, 3, "VMkernel adapters")
            d.link(f.id, kn.id)
        }
        for vm in pg.vmIDs.compactMap({ vms[$0] }).sorted(by: { Self.byName($0.name, $1.name) }) {
            let n = node(vm)
            d.add(n, 3, "Virtual machines")
            let ips = vm.nics.filter { $0.network.lowercased() == pg.name.lowercased() }.flatMap(\.ipv4)
            d.link(f.id, n.id, ips.joined(separator: ", "))
        }
        return d.finish(f)
    }
}

// MARK: - Relationship exports

/// One row per relationship, so a spreadsheet filter answers both directions: "which VMs use these networks" and
/// "which networks do these VMs use".
extension CSVExport {
    private static func byName<T>(_ list: [T], _ name: (T) -> String) -> [T] {
        list.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    /// Every VM network adapter and the port group, switch and VLAN it connects to.
    public static func vmNetworks(_ r: Report) -> String {
        let inv = r.inventory
        let pgs = Dictionary(inv.portGroups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [[String]] = []
        for v in byName(inv.vms, \.name) {
            let nics = v.nics.isEmpty ? v.networks.map { VNic(network: $0, connected: true) } : v.nics
            for n in nics where !n.network.isEmpty {
                let pg = pgs[key(v.vcenter, n.network)]
                rows.append([n.network, pg?.vlanList ?? "", pg?.switchName ?? n.switchName, pg?.kind ?? "",
                             v.name, v.powerLabel, v.vcenter, v.datacenter, v.cluster, v.host,
                             n.label, n.adapter, n.connected ? "Yes" : "No", n.mac, n.ipv4.joined(separator: " ")])
            }
        }
        return build(["Network", "VLAN", "Switch", "Network type", "VM", "Power", "vCenter", "Datacenter", "Cluster", "Host",
                      "NIC", "Adapter", "Connected", "MAC", "IPv4"], rows)
    }

    /// Every VM and datastore it has files on, with the disks there.
    public static func vmDatastores(_ r: Report) -> String {
        let inv = r.inventory
        let dss = Dictionary(inv.datastores.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [[String]] = []
        for v in byName(inv.vms, \.name) {
            var names: [String] = []
            for name in v.datastores + v.disks.map(\.datastore) where !name.isEmpty && !names.contains(where: { $0.lowercased() == name.lowercased() }) {
                names.append(name)
            }
            for name in names {
                let disks = v.disks.filter { $0.datastore.lowercased() == name.lowercased() }
                let ds = dss[key(v.vcenter, name)]
                rows.append([name, ds?.type ?? "", ds.map { gb($0.capacityMiB) } ?? "", ds.map { Fmt.num($0.freePct, 0) } ?? "", ds?.clusterList ?? "",
                             v.name, v.powerLabel, v.vcenter, v.cluster, v.host,
                             "\(disks.count)", gb(disks.reduce(0) { $0 + $1.capacityMiB }), disks.map(\.provisioning).joined(separator: " ")])
            }
        }
        return build(["Datastore", "Datastore type", "Datastore capacity GB", "Datastore free %", "Datastore clusters",
                      "VM", "Power", "vCenter", "Cluster", "Host", "Disks", "Disk capacity GB", "Disk provisioning"], rows)
    }

    /// Every host and datastore it mounts, with its storage paths and the VMs it runs there.
    public static func hostDatastores(_ r: Report) -> String {
        let inv = r.inventory
        let hosts = Dictionary(inv.hosts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let vmHost = Dictionary(inv.vms.map { ($0.id, $0.hostKey) }, uniquingKeysWith: { a, _ in a })
        let luns = Dictionary(grouping: inv.luns) { $0.hostKey + "|" + $0.datastore.lowercased() }
        var rows: [[String]] = []
        for d in byName(inv.datastores, \.name) {
            for hk in Array(Set(d.hostKeys)).sorted() {
                let h = hosts[hk]
                let paths = luns[hk + "|" + d.name.lowercased()] ?? []
                rows.append([d.name, d.type, gb(d.capacityMiB), Fmt.num(d.freePct, 0), h?.name ?? hk, h?.cluster ?? "", d.vcenter,
                             "\(d.vmIDs.filter { vmHost[$0] == hk }.count)", "\(d.vmCount)",
                             "\(paths.reduce(0) { $0 + $1.paths })", "\(paths.reduce(0) { $0 + $1.deadPaths })",
                             paths.map { $0.displayName.isEmpty ? $0.disk : $0.displayName }.joined(separator: "; ")])
            }
        }
        return build(["Datastore", "Type", "Capacity GB", "Free %", "Host", "Cluster", "vCenter", "VMs on this host", "VMs on datastore",
                      "Paths", "Dead paths", "Storage devices"], rows)
    }

    /// Every host and port group available on it, with its switch uplinks, VMkernel adapters and VMs.
    public static func hostNetworks(_ r: Report) -> String {
        let inv = r.inventory
        let vmHost = Dictionary(inv.vms.map { ($0.id, $0.hostKey) }, uniquingKeysWith: { a, _ in a })
        let pnics = Dictionary(grouping: inv.pnics, by: \.hostKey)
        let vmks = Dictionary(grouping: inv.vmkernels, by: \.hostKey)
        var rows: [[String]] = []
        for h in byName(inv.hosts, \.name) {
            for pg in byName(inv.portGroups.filter { $0.hostKeys.contains(h.id) }, \.name) {
                let uplinks = (pnics[h.id] ?? []).filter { !pg.switchName.isEmpty && $0.switchName.lowercased() == pg.switchName.lowercased() }
                let adapters = (vmks[h.id] ?? []).filter { $0.portGroup.lowercased() == pg.name.lowercased() }
                rows.append([pg.name, pg.vlanList, pg.switchName, pg.kind, h.name, h.cluster, h.vcenter,
                             uplinks.map { "\($0.device) (\($0.speedMbps == 0 ? "link down" : "\($0.speedMbps) Mb/s"))" }.joined(separator: " "),
                             adapters.map { [$0.device, $0.ip].filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: "; "),
                             "\(pg.vmIDs.filter { vmHost[$0] == h.id }.count)"])
            }
        }
        return build(["Network", "VLAN", "Switch", "Network type", "Host", "Cluster", "vCenter", "Uplinks", "VMkernel adapters", "VMs on this host"], rows)
    }
}
