import Foundation

/// Appliance sizes from Broadcom's VCF 9.1.1 Planning and Preparation Workbook ("Management Domain Sizing" and its
/// reference tables), in GB as the workbook states them. Update these tables when a new workbook changes the numbers.
enum VCFAppliances {
    static let source = "VCF 9.1.1 Planning and Preparation Workbook"

    struct Spec {
        let cpu: Double, ram: Double, disk: Double
        init(_ cpu: Double, _ ram: Double, _ disk: Double) { self.cpu = cpu; self.ram = ram; self.disk = disk }
    }

    enum Deployment: Int, CaseIterable {
        case simple = 0, haSmall, haMedium, haLarge
        var isHA: Bool { self != .simple }
        var size: String { [.simple: "Small", .haSmall: "Small", .haMedium: "Medium", .haLarge: "Large"][self]! }
        var label: String { isHA ? "High availability · \(size)" : "Simple · Small" }
    }

    static let vcenter: [String: (cpu: Double, ram: Double)] = [
        "Tiny": (2, 14), "Small": (4, 21), "Medium": (8, 30), "Large": (16, 39), "XLarge": (24, 58),
    ]
    /// vCenter disk by appliance size and storage size.
    static let vcenterDisk: [String: [String: Double]] = [
        "Tiny": ["Default": 619, "Large": 2059, "XLarge": 4319],
        "Small": ["Default": 734, "Large": 2084, "XLarge": 4344],
        "Medium": ["Default": 933, "Large": 2233, "XLarge": 4493],
        "Large": ["Default": 1383, "Large": 2283, "XLarge": 4543],
        "XLarge": ["Default": 2308, "Large": 2408, "XLarge": 4668],
    ]
    static let vcenterLimits: [(size: String, hosts: Int, vms: Int)] = [
        ("Tiny", 10, 100), ("Small", 100, 1000), ("Medium", 400, 4000), ("Large", 1000, 10_000), ("XLarge", 2000, 35_000),
    ]
    static let nsxManager: [String: Spec] = ["Medium": Spec(6, 24, 300), "Large": Spec(12, 48, 300), "XLarge": Spec(24, 96, 400)]
    static let nsxLimits: [(size: String, hosts: Int, clusters: Int)] = [("Medium", 128, 5), ("Large", 1024, 256), ("XLarge", 2048, 512)]
    static let nsxEdge: [String: Spec] = ["Small": Spec(2, 4, 200), "Medium": Spec(4, 8, 200), "Large": Spec(8, 32, 200), "XLarge": Spec(16, 64, 200)]
    static let sddcManager = Spec(4, 16, 914)
    static let runtimeControl: [String: Spec] = ["Small": Spec(4, 10, 100), "Medium": Spec(4, 10, 100), "Large": Spec(8, 14, 100)]
    /// VCF services runtime worker nodes: vCPU and RAM per node, disk for the set.
    static let runtimeWorker: [Deployment: Spec] = [
        .simple: Spec(12, 24, 2900), .haSmall: Spec(10, 16, 2800), .haMedium: Spec(12, 24, 3300), .haLarge: Spec(16, 32, 4002),
    ]
    /// Day-0 services on the workers: Identity Broker, Software Depot, SDDC LCM, Salt, Salt RaaS, Telemetry and Fleet.
    static let runtimeServices: [Deployment: (cpu: Double, ram: Double)] = [
        .simple: (9.85, 16.1), .haSmall: (12.35, 20.1), .haMedium: (20, 26.5), .haLarge: (29.5, 52.5),
    ]
    /// Log management, per replica (disk from the VCF Operations for logs appliance).
    static let logs: [String: Spec] = ["Small": Spec(8, 16, 575), "Medium": Spec(16, 32, 575), "Large": Spec(32, 64, 575)]
    /// Real-time metrics (VODAP) on the workers.
    static let realTimeMetrics: [Deployment: Spec] = [
        .simple: Spec(16, 20, 205), .haSmall: Spec(16, 20, 205), .haMedium: Spec(31, 41, 205), .haLarge: Spec(47, 62, 205),
    ]
    static let operations: [String: Spec] = ["Small": Spec(4, 16, 274), "Medium": Spec(8, 32, 274), "Large": Spec(16, 48, 274)]
    static let licenseServer = Spec(2, 4, 12)
    static let cloudProxy: [String: Spec] = ["Small": Spec(4, 16, 264), "Standard": Spec(8, 48, 264)]
    static let automation: [String: Spec] = ["Small": Spec(24, 96, 600), "Medium": Spec(24, 96, 900), "Large": Spec(32, 128, 1200)]

    /// Smallest vCenter for a domain (VCF deploys Small or larger).
    static func vcenterSize(hosts: Int, vms: Int) -> String {
        vcenterLimits.dropFirst().first { hosts <= $0.hosts && vms <= $0.vms }?.size ?? "XLarge"
    }

    static func nsxSize(hosts: Int, clusters: Int) -> String {
        nsxLimits.first { hosts <= $0.hosts && clusters <= $0.clusters }?.size ?? "XLarge"
    }

    static func larger(_ a: String, _ b: String) -> String {
        let order = ["Tiny", "Small", "Medium", "Large", "XLarge"]
        return (order.firstIndex(of: a) ?? 0) >= (order.firstIndex(of: b) ?? 0) ? a : b
    }
}

/// Sizes a VCF 9 fleet on the hardware RVTools shows: which hosts can become the management domain (peeled off an
/// existing cluster, or shared with workloads in a consolidated cluster), what the management appliances need, and what
/// converging the other clusters into workload domains adds. Management appliance sizing follows the VCF 9.1.1 Planning
/// and Preparation Workbook; host fit uses the real hosts' cores and memory with host failures held in reserve.
public struct VCF9Sizing: Solution {
    public init() {}
    public var id: String { "vcfsizing" }
    public var title: String { "VCF 9 Sizing" }
    public var symbol: String { "square.stack.3d.up" }
    public var summary: String { "Management domain and workload domain sizing on the existing hosts: greenfield peel-off, consolidated, and convergence of the other clusters." }

    public var parameters: [SolutionParameter] { [
        .choice("arch", "Architecture", "Management domain", [
            "Dedicated — peel hosts off an existing cluster",
            "Consolidated — management and workloads share one cluster",
        ], help: "Dedicated is the ideal: a new management cluster built from existing hosts, with the rest of that cluster carrying its VMs. Consolidated suits small environments that can't spare the hosts."),
        .clusters("mgmtCluster", "Architecture", "Management cluster", multi: false, none: "Best fit (automatic)",
                  help: "The cluster that gives up hosts (dedicated) or hosts the management appliances (consolidated). Best fit needs the fewest new hosts, then leaves the most headroom."),
        .choice("deploy", "Architecture", "VCF deployment model", VCFAppliances.Deployment.allCases.map { d in
            d.isHA ? "High availability — \(d.size)" : "Simple — single-node appliances (Small)"
        }, selected: 1, help: "Sets appliance sizes and node counts as the VCF Installer does. High availability needs at least 4 hosts."),
        .choice("storage", "Architecture", "Management domain principal storage", [
            "Auto — vSAN ESA if the cluster has vSAN, otherwise external",
            "vSAN ESA", "vSAN OSA", "External — FC / NFS",
        ]),
        .toggle("vcfOps", "Management components", "VCF Operations (with cloud proxy and license server)", true,
                help: "The workbook leaves this out by default; VCF 9 uses VCF Operations for licensing and fleet management, so it's on here."),
        .toggle("vcfAuto", "Management components", "VCF Automation", false),
        .choice("logs", "Management components", "Log management", ["None", "Small", "Medium", "Large"]),
        .number("logReplicas", "Management components", "Log management replicas", 3, min: 1, max: 5),
        .toggle("rtm", "Management components", "Real-time metrics", false),
        .choice("edges", "Management components", "NSX Edges in the management domain (2 nodes)", ["None", "Small", "Medium", "Large", "XLarge"]),
        .number("extraCPU", "Management components", "Other management VMs — vCPU", 0, min: 0, max: 2000,
                help: "Anything else that will run in the management domain: directory, DNS, backup proxies, jump hosts."),
        .number("extraRAM", "Management components", "Other management VMs — memory", 0, min: 0, max: 20_000, step: 8, unit: "GB"),
        .number("extraDisk", "Management components", "Other management VMs — disk", 0, min: 0, max: 500_000, step: 100, unit: "GB"),
        .choice("wldGroup", "Workload domains", "Workload domains", ["One per vCenter", "One per cluster", "One for all clusters"],
                help: "Each workload domain adds its vCenter and NSX Managers to the management domain."),
        .choice("wldVC", "Workload domains", "Workload domain vCenters", [
            "New vCenter per workload domain, in the management domain",
            "Keep the existing vCenter (converge in place)",
        ]),
        .choice("wldNSX", "Workload domains", "Workload domain NSX", [
            "Dedicated NSX Managers (3 nodes) per workload domain",
            "Single NSX Manager per workload domain",
            "Share the management domain's NSX",
        ]),
        .clusters("merge", "Workload domains", "Merge these clusters into one workload cluster", multi: true, none: "None",
                  help: "Shows what consolidating smaller clusters saves: one set of failover hosts instead of one per cluster, and one workload domain."),
        .choice("basis", "Capacity", "Size existing workloads from", [
            "Measured host usage (vHost CPU and memory %)",
            "Configured vCPU and memory of the selected powered-on VMs",
        ], help: "Measured usage covers every VM on the hosts; configured sizes follow the VM selection."),
        .number("mgmtRatio", "Capacity", "Management appliances — vCPU per core", 2, min: 0.5, max: 8, step: 0.5, unit: ": 1",
                help: "The workbook recommends 2:1 for a performant management domain."),
        .number("wlRatio", "Capacity", "Workloads — vCPU per core (configured sizes)", 4, min: 0.5, max: 20, step: 0.5, unit: ": 1"),
        .number("spare", "Capacity", "Host failures to tolerate", 1, min: 0, max: 3,
                help: "Hosts held back in every cluster for failures and rolling upgrades."),
        .number("maxLoad", "Capacity", "Max CPU / memory load with those hosts down", 80, min: 50, max: 100, unit: "%"),
        .number("reserve", "Capacity", "Storage — host rebuild and operations reserve (vSAN)", 30, min: 0, max: 100, unit: "%"),
        .number("growth", "Capacity", "Storage — estimated growth", 10, min: 0, max: 200, unit: "%"),
    ] }

    public func defaultSelection(_ inventory: Inventory) -> Set<String> {
        Set(inventory.workloadVMs.map(\.id))
    }

    // MARK: - Model

    struct Component {
        let name: String, nodes: Int, cpu: Double, ram: Double, disk: Double
        var note = ""
    }

    struct Demand {
        var cores = 0.0, ramGiB = 0.0
        static func + (a: Demand, b: Demand) -> Demand { Demand(cores: a.cores + b.cores, ramGiB: a.ramGiB + b.ramGiB) }
        var isEmpty: Bool { cores <= 0 && ramGiB <= 0 }
    }

    struct HostCap {
        let id: String, name: String, cores: Double, ramGiB: Double
        var isNew = false
        var vendor: String
        var cluster = ""
    }

    struct Fit {
        var hosts: [HostCap]
        var newHosts: Int
        var load: Double
    }

    struct PeelPlan {
        let cluster: Cluster
        let mgmt: [HostCap]
        let remaining: [HostCap]
        let newHosts: Int
        let mgmtLoad: Double
        let remainingLoad: Double
    }

    struct WorkloadDomain {
        let name: String
        var clusters: [Cluster]
        var hosts: Int
        var vms: Int
        var vcSize = ""
        var nsxSize = ""
    }

    /// Worst CPU or memory load once the `spare` largest hosts are out; infinity if too few hosts remain.
    static func load(_ hosts: [HostCap], _ d: Demand, spare: Int) -> Double {
        if d.isEmpty { return 0 }
        guard hosts.count > spare else { return .infinity }
        let cores = hosts.map(\.cores).sorted(by: >).dropFirst(spare).reduce(0, +)
        let ram = hosts.map(\.ramGiB).sorted(by: >).dropFirst(spare).reduce(0, +)
        guard cores > 0, ram > 0 else { return .infinity }
        return max(d.cores / cores, d.ramGiB / ram)
    }

    /// Adds hosts like `typical` until the demand fits at `maxLoad` with at least `minHosts`.
    static func fit(_ hosts: [HostCap], _ d: Demand, typical: HostCap, minHosts: Int, spare: Int, maxLoad: Double) -> Fit {
        for k in 0...256 {
            let pool = hosts + (0..<k).map { _ in newHost(typical) }
            let l = load(pool, d, spare: spare)
            if pool.count >= minHosts && l <= maxLoad { return Fit(hosts: pool, newHosts: k, load: l) }
        }
        return Fit(hosts: hosts, newHosts: -1, load: load(hosts, d, spare: spare))
    }

    static func newHost(_ typical: HostCap) -> HostCap {
        HostCap(id: "", name: "New host (like \(typical.name))", cores: typical.cores, ramGiB: typical.ramGiB, isNew: true, vendor: typical.vendor)
    }

    /// Peels the smallest hosts off a cluster for the management domain, adding hosts like its typical one only when the
    /// management domain and the cluster's remaining workloads can't both fit.
    static func peel(_ cluster: Cluster, hosts: [HostCap], workload: Demand, hasVMs: Bool, mgmt: Demand, minMgmt: Int, minWorkload: Int,
                     spare: Int, maxLoad: Double) -> PeelPlan? {
        guard let typical = VCF9Sizing.typical(hosts) else { return nil }
        let wlMin = hasVMs || !workload.isEmpty ? minWorkload : 0
        for k in 0...256 {
            let pool = (hosts + (0..<k).map { _ in newHost(typical) }).sorted { ($0.ramGiB, $0.cores, $0.name) < ($1.ramGiB, $1.cores, $1.name) }
            guard pool.count - wlMin >= minMgmt else { continue }
            for n in minMgmt...(pool.count - wlMin) {
                let m = Array(pool[..<n])
                let mLoad = load(m, mgmt, spare: spare)
                guard mLoad <= maxLoad else { continue }
                let rest = Array(pool[n...])
                let rLoad = load(rest, workload, spare: spare)
                if rLoad <= maxLoad {
                    return PeelPlan(cluster: cluster, mgmt: m, remaining: rest, newHosts: k, mgmtLoad: mLoad, remainingLoad: rLoad)
                }
                break  // giving the management domain more hosts only leaves less for the workloads
            }
        }
        return nil
    }

    /// The median host by memory, used as the model for any new hosts.
    static func typical(_ hosts: [HostCap]) -> HostCap? {
        let sorted = hosts.filter { !$0.isNew }.sorted { ($0.ramGiB, $0.cores) < ($1.ramGiB, $1.cores) }
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }

    static func vendor(_ cpuModel: String) -> String {
        let m = cpuModel.lowercased()
        return m.contains("amd") || m.contains("epyc") ? "AMD" : (m.contains("intel") || m.contains("xeon") ? "Intel" : "")
    }

    /// Management domain appliances, following the workbook's Management Domain Sizing tab (first instance).
    static func managementComponents(_ d: VCFAppliances.Deployment, vcfOps: Bool, vcfAuto: Bool, logs: String?, logReplicas: Int, rtm: Bool,
                                     edges: String?, mgmtNSXSize: String, extra: VCFAppliances.Spec,
                                     domains: [WorkloadDomain], newVCenters: Bool, wldNSXNodes: Int) -> [Component] {
        typealias A = VCFAppliances
        var c: [Component] = []
        c.append(Component(name: "SDDC Manager", nodes: 1, cpu: A.sddcManager.cpu, ram: A.sddcManager.ram, disk: A.sddcManager.disk))
        let vcSize = d.size
        let vc = A.vcenter[vcSize]!
        c.append(Component(name: "Management vCenter", nodes: 1, cpu: vc.cpu, ram: vc.ram, disk: A.vcenterDisk[vcSize]![d == .haLarge ? "XLarge" : "Large"]!,
                           note: "\(vcSize), \(d == .haLarge ? "XLarge" : "Large") storage"))
        let nsx = A.nsxManager[mgmtNSXSize]!
        let nsxNodes = d.isHA ? 3 : 1
        c.append(Component(name: "Management NSX Managers", nodes: nsxNodes, cpu: nsx.cpu * Double(nsxNodes), ram: nsx.ram * Double(nsxNodes),
                           disk: nsx.disk * Double(nsxNodes), note: mgmtNSXSize))
        if let edges, let e = A.nsxEdge[edges] {
            c.append(Component(name: "Management NSX Edges", nodes: 2, cpu: e.cpu * 2, ram: e.ram * 2, disk: e.disk * 2, note: edges))
        }
        let ctl = A.runtimeControl[d.size]!
        let ctlNodes = d.isHA ? 3 : 1
        c.append(Component(name: "VCF services runtime — control nodes", nodes: ctlNodes, cpu: ctl.cpu * Double(ctlNodes), ram: ctl.ram * Double(ctlNodes),
                           disk: ctl.disk * Double(ctlNodes)))

        // Workers: enough nodes for the Day-0 services plus any Day-N services (with the workbook's 9% CPU and 20% RAM
        // allowances), plus one — except where the workbook's HA Medium profile already has the headroom.
        let w = A.runtimeWorker[d]!
        let day0 = A.runtimeServices[d]!
        var dayN = (cpu: 0.0, ram: 0.0, disk: 0.0)
        if let logs, let l = A.logs[logs] {
            dayN.cpu += l.cpu * Double(logReplicas); dayN.ram += l.ram * Double(logReplicas); dayN.disk += l.disk * Double(logReplicas)
        }
        if rtm, let r = A.realTimeMetrics[d] { dayN.cpu += r.cpu; dayN.ram += r.ram; dayN.disk += r.disk }
        let ramNeed = ((dayN.ram + day0.ram) * 1.2).rounded(.up)
        let cpuNeed = ((dayN.cpu + day0.cpu) * 1.09).rounded(.up)
        let nodesRAM = Int((ramNeed / w.ram).rounded(.up)) + (d == .haMedium ? 0 : 1)
        let nodesCPU = Int((cpuNeed / w.cpu).rounded(.up)) + ((logs != nil || rtm) && d == .haMedium ? 0 : 1)
        let workers = max(nodesRAM, nodesCPU)
        var services = ["fleet management", "identity broker", "software depot"]
        if logs != nil { services.append("log management") }
        if rtm { services.append("real-time metrics") }
        c.append(Component(name: "VCF services runtime — worker nodes", nodes: workers, cpu: w.cpu * Double(workers), ram: w.ram * Double(workers),
                           disk: w.disk + dayN.disk, note: services.joined(separator: ", ")))

        if vcfOps {
            let nodes = d == .haSmall ? 2 : (d.isHA ? 3 : 1)
            let o = A.operations[d.size]!
            c.append(Component(name: "VCF Operations", nodes: nodes, cpu: o.cpu * Double(nodes), ram: o.ram * Double(nodes), disk: o.disk * Double(nodes), note: d.size))
            let p = A.cloudProxy[d.isHA && d != .haSmall ? "Standard" : "Small"]!
            c.append(Component(name: "Cloud proxy", nodes: 1, cpu: p.cpu, ram: p.ram, disk: p.disk))
            c.append(Component(name: "License server", nodes: 1, cpu: A.licenseServer.cpu, ram: A.licenseServer.ram, disk: A.licenseServer.disk))
        }
        if vcfAuto {
            let nodes = d.isHA && d != .haSmall ? 3 : 1
            let a = A.automation[d.size]!
            c.append(Component(name: "VCF Automation", nodes: nodes, cpu: a.cpu * Double(nodes), ram: a.ram * Double(nodes), disk: a.disk * Double(nodes), note: d.size))
        }

        for wd in domains {
            if newVCenters, let v = A.vcenter[wd.vcSize] {
                c.append(Component(name: "\(wd.name) vCenter", nodes: 1, cpu: v.cpu, ram: v.ram, disk: A.vcenterDisk[wd.vcSize]!["Default"]!, note: wd.vcSize))
            }
            if wldNSXNodes > 0, let n = A.nsxManager[wd.nsxSize] {
                let k = Double(wldNSXNodes)
                c.append(Component(name: "\(wd.name) NSX Managers", nodes: wldNSXNodes, cpu: n.cpu * k, ram: n.ram * k, disk: n.disk * k, note: wd.nsxSize))
            }
        }
        if extra.cpu > 0 || extra.ram > 0 || extra.disk > 0 {
            c.append(Component(name: "Other management VMs", nodes: 0, cpu: extra.cpu, ram: extra.ram, disk: extra.disk))
        }
        return c
    }

    // MARK: - Run

    public func run(vms: [VM], inventory inv: Inventory, params p: Params) -> SolutionResult {
        typealias A = VCFAppliances
        let dedicated = p.choice("arch") == 0
        let deploy = A.Deployment(rawValue: p.choice("deploy")) ?? .haSmall
        let spare = Int(p.num("spare"))
        let maxLoad = max(p.num("maxLoad"), 1) / 100
        let mgmtRatio = max(p.num("mgmtRatio"), 0.1), wlRatio = max(p.num("wlRatio"), 0.1)
        let measured = p.choice("basis") == 0
        let reserve = p.num("reserve") / 100, growth = p.num("growth") / 100
        let wldNSX = p.choice("wldNSX")
        let newVCenters = p.choice("wldVC") == 0

        // Resolve a stored cluster (id, or a name from the CLI).
        func resolve(_ ref: String) -> Cluster? {
            inv.clusters.first { $0.id == ref } ?? inv.clusters.first { $0.name.lowercased() == ref.lowercased() && !$0.isStandalone }
        }

        let realHosts = inv.hosts.filter { !$0.isVirtual }
        var hostsByCluster = Dictionary(grouping: realHosts, by: \.clusterKey)
        var vmsByCluster = Dictionary(grouping: vms, by: \.clusterKey)
        var picked = p.names("mgmtCluster").first.flatMap(resolve)
        let scopeIDs = Set(vms.map(\.clusterKey)).union(picked.map { [$0.id] } ?? [])
        var clusters = inv.clusters.filter { scopeIDs.contains($0.id) && !$0.isStandalone && !(hostsByCluster[$0.id] ?? []).isEmpty }
            .sorted { ($0.vcenter.lowercased(), $0.name.lowercased()) < ($1.vcenter.lowercased(), $1.name.lowercased()) }

        // Clusters to merge become one cluster everywhere: a management candidate (peeled or consolidated) and a
        // workload cluster, with their hosts and workloads combined.
        let mergeIDs = Set(p.names("merge").compactMap(resolve).map(\.id))
        let mergeMembers = inv.clusters.filter { mergeIDs.contains($0.id) && !$0.isStandalone && !(hostsByCluster[$0.id] ?? []).isEmpty }
            .sorted { ($0.vcenter.lowercased(), $0.name.lowercased()) < ($1.vcenter.lowercased(), $1.name.lowercased()) }
        var memberIDs: [String: [String]] = [:]
        if mergeMembers.count > 1 {
            var m = Cluster(id: "merged|" + mergeMembers.map(\.id).joined(separator: ","))
            m.name = mergeMembers.map(\.name).joined(separator: " + ")
            var vcs: [String] = []
            for c in mergeMembers where !vcs.contains(c.vcenter) { vcs.append(c.vcenter) }
            m.vcenter = vcs.joined(separator: " + ")
            m.vmCount = mergeMembers.reduce(0) { $0 + $1.vmCount }
            m.hostCount = mergeMembers.reduce(0) { $0 + $1.hostCount }
            hostsByCluster[m.id] = mergeMembers.flatMap { hostsByCluster[$0.id] ?? [] }
            vmsByCluster[m.id] = mergeMembers.flatMap { vmsByCluster[$0.id] ?? [] }
            memberIDs[m.id] = mergeMembers.map(\.id)
            clusters = clusters.filter { !mergeIDs.contains($0.id) } + [m]
            if let pk = picked, mergeIDs.contains(pk.id) { picked = m }
        }
        let mergedCluster = clusters.first { memberIDs[$0.id] != nil }
        func members(_ c: Cluster) -> [String] { memberIDs[c.id] ?? [c.id] }
        /// A reference for navigation; a merged cluster has no single object to open.
        func cref(_ c: Cluster, _ detail: String = "") -> AffectedObject {
            AffectedObject(kind: memberIDs[c.id] == nil ? .cluster : .other, id: c.id, name: c.name, detail: detail)
        }
        func onCluster(_ d: Datastore, _ c: Cluster) -> Bool { d.clusterKeys.contains(where: members(c).contains) }

        func caps(_ c: Cluster) -> [HostCap] {
            (hostsByCluster[c.id] ?? []).filter { !$0.inferred && $0.cores > 0 && $0.memoryMiB > 0 }
                .map { HostCap(id: $0.id, name: $0.name, cores: Double($0.cores), ramGiB: $0.memoryMiB / 1024, vendor: VCF9Sizing.vendor($0.cpuModel), cluster: $0.cluster) }
        }
        var basisFallback: [String] = []
        func workload(_ c: Cluster) -> Demand {
            let configured: Demand = {
                let running = (vmsByCluster[c.id] ?? []).filter(\.isRunning)
                return Demand(cores: Double(running.reduce(0) { $0 + $1.cpus }) / wlRatio, ramGiB: running.reduce(0) { $0 + $1.memoryMiB } / 1024)
            }()
            guard measured else { return configured }
            let hs = (hostsByCluster[c.id] ?? []).filter { !$0.inferred }
            let d = Demand(cores: hs.reduce(0) { $0 + Double($1.cores) * $1.cpuUsagePct / 100 },
                           ramGiB: hs.reduce(0) { $0 + $1.memoryMiB / 1024 * $1.memUsagePct / 100 })
            if d.isEmpty && !configured.isEmpty { basisFallback.append(c.name); return configured }
            return d
        }

        // Storage type decides the minimum cluster sizes.
        func hasVSAN(_ c: Cluster) -> Bool { inv.datastores.contains { $0.type.lowercased() == "vsan" && onCluster($0, c) } }
        func storageKind(_ c: Cluster?) -> Int {   // 1 ESA, 2 OSA, 3 external
            let s = p.choice("storage")
            if s > 0 { return s }
            return c.map(hasVSAN) == true ? 1 : 3
        }
        func minMgmt(_ kind: Int) -> Int { deploy.isHA ? 4 : (kind == 3 ? 2 : 3) }
        func minWorkload(_ c: Cluster) -> Int { hasVSAN(c) ? 3 : 2 }

        // Workload domains and their appliances (independent of which hosts the management domain takes).
        func domains(excluding mgmtCluster: Cluster?) -> [WorkloadDomain] {
            let rest = clusters.filter { $0.id != mgmtCluster?.id }
            var groups: [(String, [Cluster])] = []
            switch p.choice("wldGroup") {
            case 1: groups += rest.map { ($0.name, [$0]) }
            case 2: if !rest.isEmpty { groups.append(("Workload domain", rest)) }
            default:
                var order: [String] = []
                let byVC = Dictionary(grouping: rest) { $0.vcenter.lowercased() }
                for c in rest where !order.contains(c.vcenter.lowercased()) { order.append(c.vcenter.lowercased()) }
                groups += order.map { vc in (byVC[vc]!.first!.vcenter, byVC[vc]!) }
            }
            return groups.enumerated().map { i, g in
                let hosts = g.1.reduce(0) { $0 + (hostsByCluster[$1.id]?.count ?? 0) }
                let count = g.1.reduce(0) { $0 + max($1.vmCount, vmsByCluster[$1.id]?.count ?? 0) }
                var d = WorkloadDomain(name: String(format: "w%02d", i + 1) + " · " + g.0, clusters: g.1, hosts: hosts, vms: count)
                d.vcSize = A.vcenterSize(hosts: hosts, vms: count)
                d.nsxSize = A.nsxSize(hosts: hosts, clusters: g.1.count)
                return d
            }
        }

        /// Appliances and workload domains; a consolidated management cluster isn't a workload domain.
        func components(consolidatedOn mgmtCluster: Cluster?, mgmtHosts: Int) -> ([Component], [WorkloadDomain]) {
            let wds = domains(excluding: mgmtCluster)
            var nsxSize = deploy == .haLarge ? "Large" : "Medium"
            if wldNSX == 2 {   // shared: the management NSX also carries every workload cluster
                nsxSize = A.larger(nsxSize, A.nsxSize(hosts: mgmtHosts + wds.reduce(0) { $0 + $1.hosts },
                                                      clusters: 1 + wds.reduce(0) { $0 + $1.clusters.count }))
            }
            let logs = ["", "Small", "Medium", "Large"][min(p.choice("logs"), 3)]
            let edges = ["", "Small", "Medium", "Large", "XLarge"][min(p.choice("edges"), 4)]
            let comps = VCF9Sizing.managementComponents(
                deploy, vcfOps: p.flag("vcfOps"), vcfAuto: p.flag("vcfAuto"), logs: logs.isEmpty ? nil : logs,
                logReplicas: max(Int(p.num("logReplicas")), 1), rtm: p.flag("rtm"), edges: edges.isEmpty ? nil : edges, mgmtNSXSize: nsxSize,
                extra: A.Spec(p.num("extraCPU"), p.num("extraRAM"), p.num("extraDisk")),
                domains: wds, newVCenters: newVCenters, wldNSXNodes: [3, 1, 0][min(wldNSX, 2)])
            return (comps, wds)
        }

        func mgmtDemand(_ comps: [Component]) -> Demand {
            Demand(cores: comps.reduce(0) { $0 + $1.cpu } / mgmtRatio, ramGiB: comps.reduce(0) { $0 + $1.ram })
        }

        // Evaluate every candidate cluster both ways. The appliances don't depend on the candidate in dedicated mode;
        // in consolidated mode the candidate stops being a workload domain.
        struct Candidate {
            let cluster: Cluster
            let hosts: [HostCap]
            let workload: Demand
            let currentLoad: Double
            let peel: PeelPlan?
            let consolidated: Fit
            let comps: [Component]
            let domains: [WorkloadDomain]
        }
        let candidates: [Candidate] = clusters.compactMap { c in
            let hs = caps(c)
            guard let typical = VCF9Sizing.typical(hs) else { return nil }
            let wl = workload(c)
            let kind = storageKind(c)
            let ded = components(consolidatedOn: nil, mgmtHosts: minMgmt(kind))
            let plan = VCF9Sizing.peel(c, hosts: hs, workload: wl, hasVMs: !(vmsByCluster[c.id] ?? []).isEmpty, mgmt: mgmtDemand(ded.0),
                                       minMgmt: minMgmt(kind), minWorkload: minWorkload(c), spare: spare, maxLoad: maxLoad)
            let con = components(consolidatedOn: c, mgmtHosts: hs.count)
            let fit = VCF9Sizing.fit(hs, wl + mgmtDemand(con.0), typical: typical, minHosts: minMgmt(kind), spare: spare, maxLoad: maxLoad)
            let (comps, wds) = dedicated ? ded : con
            return Candidate(cluster: c, hosts: hs, workload: wl, currentLoad: VCF9Sizing.load(hs, wl, spare: spare), peel: plan,
                             consolidated: fit, comps: comps, domains: wds)
        }

        let unknownHosts = clusters.flatMap { c in (hostsByCluster[c.id] ?? []).filter { $0.inferred || $0.cores == 0 || $0.memoryMiB == 0 } }
        guard !candidates.isEmpty else {
            return SolutionResult(headline: "No clusters with host capacity in scope", sections: [
                .notes("Nothing to size", [
                    clusters.isEmpty ? "Select VMs that run in a cluster on the Select VMs step." :
                        "The clusters behind the selected VMs have no host cores or memory in this export (vHost tab missing?).",
                ]),
            ])
        }

        func peelRank(_ c: Candidate) -> (Int, Double, Int) {
            guard let plan = c.peel else { return (Int.max, .infinity, 0) }
            return (plan.newHosts, plan.remainingLoad, -c.hosts.count)
        }
        func consRank(_ c: Candidate) -> (Int, Double, Int) {
            (c.consolidated.newHosts < 0 ? Int.max : c.consolidated.newHosts, c.consolidated.load, -c.hosts.count)
        }
        let bestPeel = candidates.min { peelRank($0) < peelRank($1) }!
        let bestCons = candidates.min { consRank($0) < consRank($1) }!
        let best = dedicated ? bestPeel : bestCons
        let chosen = picked.flatMap { pk in candidates.first { $0.cluster.id == pk.id } } ?? best
        let isAuto = picked == nil || chosen.cluster.id != picked?.id

        let comps = chosen.comps
        let wds = chosen.domains
        let mgmt = mgmtDemand(comps)
        let totCPU = comps.reduce(0) { $0 + $1.cpu }, totRAM = comps.reduce(0) { $0 + $1.ram }, totDisk = comps.reduce(0) { $0 + $1.disk }
        let kind = storageKind(chosen.cluster)
        let storageName = ["", "vSAN ESA", "vSAN OSA", "external (FC / NFS)"][kind]

        // Workbook storage: VM disk + swap, vSAN protection (FTT=1), rebuild / operations reserve, growth.
        let interim = totDisk + totRAM
        // Rounded up at each step, as the workbook does.
        let protected = (kind == 1 ? interim * 1.5 : (kind == 2 ? interim * 2 : interim)).rounded(.up)
        let reserved = kind == 3 ? protected : (protected * (1 + reserve)).rounded(.up)
        let storageGB = (reserved * (1 + growth)).rounded(.up)

        var b = CheckBuilder()
        var sections: [SolutionSection] = []
        var headline = ""
        var newHostsTotal = 0

        // One-click alternatives offered with the results.
        let dedicatedNew = chosen.peel?.newHosts ?? Int.max
        let toConsolidated: [SolutionAction] = bestCons.consolidated.newHosts >= 0 && bestCons.consolidated.newHosts < dedicatedNew ? [
            SolutionAction("Switch to consolidated on \(bestCons.cluster.name) — " + (bestCons.consolidated.newHosts == 0
                                ? "fits on its \(bestCons.consolidated.hosts.count) hosts" : "needs \(bestCons.consolidated.newHosts) new host(s)"),
                           help: "Sets Management domain to Consolidated and the management cluster to best fit.",
                           set: ["arch": .choice(1), "mgmtCluster": .names([])]),
        ] : []
        let toDedicated: [SolutionAction] = bestPeel.peel.map { plan in plan.newHosts == 0 ? [
            SolutionAction("Switch to dedicated — \(bestPeel.cluster.name) can spare \(plan.mgmt.count) hosts",
                           help: "Sets Management domain to Dedicated and the management cluster to best fit.",
                           set: ["arch": .choice(0), "mgmtCluster": .names([])]),
        ] : [] } ?? []

        // MARK: Management domain hosts
        let mgmtHostList: [HostCap]
        let mgmtLoad: Double
        let greenfieldOK = chosen.peel.map { $0.newHosts == 0 } ?? false
        if dedicated {
            if let plan = chosen.peel {
                mgmtHostList = plan.mgmt
                mgmtLoad = plan.mgmtLoad
                newHostsTotal += plan.newHosts
                let taken = plan.mgmt.filter { !$0.isNew }.count
                if plan.newHosts == 0 {
                    b.add("mgmt.greenfield", "Management domain", "Greenfield management domain capacity", .ready,
                          "\(taken) hosts from \(chosen.cluster.name) run the management domain at \(Fmt.pct(plan.mgmtLoad * 100)) with \(spare) down; the other \(plan.remaining.count) carry its workloads at \(Fmt.pct(plan.remainingLoad * 100))")
                    headline = "Greenfield management domain fits: \(taken) hosts from \(chosen.cluster.name), no new hosts"
                } else {
                    let forMgmt = plan.mgmt.filter(\.isNew).count
                    let split = [forMgmt > 0 ? "\(forMgmt) for the management domain" : "", plan.newHosts - forMgmt > 0 ? "\(plan.newHosts - forMgmt) for \(chosen.cluster.name)" : ""]
                        .filter { !$0.isEmpty }.joined(separator: ", ")
                    b.add("mgmt.greenfield", "Management domain", "Greenfield management domain capacity", .blocker,
                          "Not enough capacity for a greenfield management domain build: \(plan.newHosts) new host(s) needed (\(split)) — " + (taken == 0 ? "\(chosen.cluster.name) can't spare any of its \(chosen.hosts.count) hosts" : "\(chosen.cluster.name) can spare \(taken) of its \(chosen.hosts.count) hosts"),
                          remediation: "Free capacity on the other hosts (migrate or retire VMs), add hosts, or use a consolidated management domain.",
                          affected: [cref(chosen.cluster, "workloads need \(Fmt.pct(chosen.currentLoad * 100)) of today's hosts with \(spare) down")],
                          actions: toConsolidated)
                    headline = "Not enough capacity for a greenfield management domain build — \(plan.newHosts) new host(s) needed (\(split))"
                }
            } else {
                mgmtHostList = []
                mgmtLoad = .infinity
                b.add("mgmt.greenfield", "Management domain", "Greenfield management domain capacity", .blocker,
                      "Not enough capacity for a greenfield management domain build on \(chosen.cluster.name)", actions: toConsolidated)
                headline = "Not enough capacity for a greenfield management domain build"
            }
        } else {
            let f = chosen.consolidated
            mgmtHostList = f.hosts
            mgmtLoad = f.load
            newHostsTotal += max(f.newHosts, 0)
            b.add("mgmt.consolidated", "Management domain", "Consolidated management domain capacity", f.newHosts == 0 ? .ready : .warning,
                  f.newHosts == 0
                    ? "\(chosen.cluster.name) runs the management appliances and its workloads at \(Fmt.pct(f.load * 100)) with \(spare) host(s) down"
                    : "\(chosen.cluster.name) needs \(f.newHosts) more host(s) to run the management appliances alongside its workloads",
                  remediation: f.newHosts == 0 ? "" : "Add hosts, reduce the workloads, or choose a larger cluster.", actions: toDedicated)
            headline = f.newHosts == 0
                ? "Consolidated: management and workloads on \(chosen.cluster.name) (\(f.hosts.count) hosts, \(Fmt.pct(f.load * 100)) with \(spare) down)"
                : "Consolidated on \(chosen.cluster.name) needs \(f.newHosts) more host(s)"
        }

        // Management storage against what the chosen hosts bring.
        if kind == 3 {
            let shared = inv.datastores.filter { onCluster($0, chosen.cluster) && $0.type.lowercased() != "vsan" && Set($0.hostKeys).count > 1 }
            let largest = shared.map(\.freeMiB).max() ?? 0
            b.add("mgmt.storage", "Management domain", "Management domain storage", largest >= storageGB * 1024 ? .info : .warning,
                  "\(SFmt.num(storageGB)) GB needed on the principal datastore; largest shared datastore on \(chosen.cluster.name) has \(Fmt.capacity(mib: largest)) free",
                  remediation: "A new management domain on external storage needs its own principal datastore presented to the new hosts.")
        } else if case let vsan = inv.datastores.filter({ $0.type.lowercased() == "vsan" && onCluster($0, chosen.cluster) }), !vsan.isEmpty, chosen.hosts.count > 0 {
            let capacityMiB = vsan.reduce(0) { $0 + $1.capacityMiB }, freeMiB = vsan.reduce(0) { $0 + $1.freeMiB }
            let dsName = vsan.map(\.name).joined(separator: ", ")
            let perHost = capacityMiB / Double(chosen.hosts.count)
            let mgmtRaw = perHost * Double(mgmtHostList.count)
            b.add("mgmt.storage", "Management domain", "Management domain vSAN capacity", mgmtRaw >= storageGB * 1024 ? .ready : .warning,
                  "\(SFmt.num(storageGB)) GB needed; \(mgmtHostList.count) hosts bring about \(Fmt.capacity(mib: mgmtRaw)) of raw vSAN (from \(dsName))",
                  remediation: "Add capacity devices to the management hosts, or plan more hosts.")
            if dedicated, let plan = chosen.peel {
                let usedMiB = capacityMiB - freeMiB
                let left = perHost * Double(plan.remaining.count) * (1 - reserve)
                b.add("mgmt.donorvsan", "Management domain", "vSAN left for \(chosen.cluster.name)", usedMiB <= left ? .ready : .warning,
                      "\(Fmt.capacity(mib: usedMiB)) used today; \(plan.remaining.count) remaining hosts give about \(Fmt.capacity(mib: left)) after the \(SFmt.num(reserve * 100))% reserve",
                      remediation: "Taking hosts out of a vSAN cluster takes their disks too: free space first or add capacity.")
            }
        } else {
            b.add("mgmt.storage", "Management domain", "Management domain vSAN capacity", .info,
                  "\(SFmt.num(storageGB)) GB of \(storageName) needed; \(chosen.cluster.name) has no vSAN datastore to compare against",
                  remediation: "The management hosts need local capacity devices on the vSAN ESA / OSA compatibility list.")
        }
        if kind != 3 {
            b.add("mgmt.esa", "Management domain", "vSAN device eligibility", .info, "RVTools doesn't list host disks — confirm the management hosts' devices are certified for \(storageName)",
                  remediation: "vSAN ESA needs NVMe devices from the vSAN ESA ReadyNode / compatibility list.")
        }

        // MARK: Workload clusters
        // Merged clusters are sized as one cluster: one set of failover hosts instead of one per cluster.
        let candidateByID = Dictionary(candidates.map { ($0.cluster.id, $0) }, uniquingKeysWith: { a, _ in a })
        func liveHosts(_ c: Candidate) -> [HostCap] { dedicated && c.cluster.id == chosen.cluster.id ? (chosen.peel?.remaining ?? c.hosts) : c.hosts }
        /// Hosts the demand needs: drop the largest spare capacity while it still fits, or add hosts until it does.
        func hostsNeeded(_ hs: [HostCap], _ d: Demand, min: Int, typical: HostCap) -> (need: Int, fit: Fit) {
            let f = VCF9Sizing.fit(hs, d, typical: typical, minHosts: min, spare: spare, maxLoad: maxLoad)
            guard f.newHosts == 0 else { return (f.hosts.count, f) }
            var trimmed = hs.sorted { ($0.ramGiB, $0.cores) > ($1.ramGiB, $1.cores) }
            while trimmed.count > min, VCF9Sizing.load(Array(trimmed.dropLast()), d, spare: spare) <= maxLoad { trimmed.removeLast() }
            return (trimmed.count, f)
        }

        struct Unit { let name: String, domain: String, ref: AffectedObject, hosts: [HostCap], demand: Demand, min: Int, typical: HostCap, note: String }
        var units: [Unit] = []
        for wd in wds {
            for c in wd.clusters {
                guard let cand = candidateByID[c.id] else { continue }
                units.append(Unit(name: c.name, domain: wd.name, ref: cref(c), hosts: liveHosts(cand), demand: cand.workload, min: minWorkload(c),
                                  typical: VCF9Sizing.typical(cand.hosts)!, note: dedicated && c.id == chosen.cluster.id ? " (after peel)" : ""))
            }
        }
        var clusterRows: [[String]] = []
        var overloaded: [AffectedObject] = []
        var small: [AffectedObject] = []
        for u in units {
            let (need, f) = hostsNeeded(u.hosts, u.demand, min: u.min, typical: u.typical)
            let l = VCF9Sizing.load(u.hosts, u.demand, spare: spare)
            let obj = u.ref
            if f.newHosts > 0 {
                newHostsTotal += f.newHosts
                overloaded.append(AffectedObject(kind: obj.kind, id: obj.id, name: obj.name, detail: "\(l.isFinite ? Fmt.pct(l * 100) : "no failover host") with \(spare) down — add \(f.newHosts)"))
            }
            if u.hosts.count < u.min {
                small.append(AffectedObject(kind: obj.kind, id: obj.id, name: obj.name, detail: "\(u.hosts.count) hosts, \(u.min) minimum"))
            }
            let surplus = u.hosts.count - need
            let status = f.newHosts > 0 ? "Add \(f.newHosts) host(s)" : (surplus > 0 ? "\(surplus) host(s) spare" : "Fits")
            let added = u.hosts.filter(\.isNew).count
            clusterRows.append([u.name, u.domain, "\(u.hosts.count - added)" + (added > 0 ? " + \(added) new" : "") + u.note, SFmt.num(u.demand.cores.rounded()), SFmt.num(u.demand.ramGiB.rounded()),
                                l.isFinite ? Fmt.pct(l * 100) : "—", status])
        }
        let clusterRefs: [AffectedObject?] = units.map { $0.ref.kind == .cluster ? $0.ref : nil }
        b.list("wld.capacity", "Workload domains", "Workload cluster capacity", .warning, noun: "clusters are over \(SFmt.num(maxLoad * 100))% with \(spare) host(s) down",
               affected: overloaded, ready: "Every workload cluster fits with \(spare) host(s) down",
               remediation: "Add hosts, rebalance VMs between clusters, or merge clusters so they share failover capacity.")
        b.list("wld.size", "Workload domains", "Workload cluster minimum size", .warning, noun: "clusters below the VCF minimum", affected: small,
               ready: "Every workload cluster meets the minimum host count", remediation: "VCF needs 3 hosts per vSAN cluster and 2 with external storage.")

        var mergeRows: [[String]] = []
        if let merged = mergedCluster {
            let parts = mergeMembers.map { (c: $0, hosts: caps($0), demand: workload($0)) }.filter { !$0.hosts.isEmpty }
            let pool = parts.flatMap(\.hosts)
            let separate = parts.reduce(0) { $0 + hostsNeeded($1.hosts, $1.demand, min: minWorkload($1.c), typical: VCF9Sizing.typical($1.hosts)!).need }
            let together = hostsNeeded(pool, parts.reduce(Demand()) { $0 + $1.demand }, min: minWorkload(merged), typical: VCF9Sizing.typical(pool)!).need
            let role = merged.id == chosen.cluster.id ? (dedicated ? "gives up the management hosts" : "is the consolidated management cluster") : "is a workload cluster"
            mergeRows = [
                ["Clusters", parts.map(\.c.name).joined(separator: ", ")],
                ["Role in this plan", "The merged cluster " + role],
                ["Hosts today", "\(pool.count)"],
                ["Hosts their workloads need as separate clusters", "\(separate)"],
                ["Hosts their workloads need as one cluster", "\(together)"],
                [separate >= together ? "Hosts saved by merging" : "Extra hosts from merging", "\(abs(separate - together))"],
            ]
            let mergeCands = parts.map { (cluster: $0.c, hosts: $0.hosts) }
            let vendors = Set(pool.map(\.vendor).filter { !$0.isEmpty })
            if vendors.count > 1 {
                b.add("wld.merge.cpu", "Workload domains", "Merged cluster CPU vendors", .blocker, "The clusters to merge mix \(vendors.sorted().joined(separator: " and ")) CPUs",
                      remediation: "vMotion doesn't cross CPU vendors; keep Intel and AMD hosts in separate clusters.",
                      affected: mergeCands.map { AffectedObject(kind: .cluster, id: $0.cluster.id, name: $0.cluster.name, detail: Set($0.hosts.map(\.vendor)).sorted().joined(separator: ", ")) })
            } else {
                let evc = Set(mergeCands.flatMap { (hostsByCluster[$0.cluster.id] ?? []).map(\.evcCurrent) }.filter { !$0.isEmpty })
                if evc.count > 1 {
                    b.add("wld.merge.evc", "Workload domains", "Merged cluster EVC modes", .warning, "The clusters to merge run different EVC modes: \(evc.sorted().joined(separator: ", "))",
                          remediation: "Set the merged cluster's EVC mode to the lowest common generation, or move VMs cold.")
                }
            }
        }

        if !unknownHosts.isEmpty {
            b.list("hosts.unknown", "Data", "Hosts without capacity data", .info, noun: "hosts left out of the sizing",
                   affected: unknownHosts.map { $0.ref("no cores / memory in export") }, ready: "", remediation: "Ask for an export that includes the vHost tab.")
        }
        if !basisFallback.isEmpty {
            b.add("data.basis", "Data", "Measured usage missing", .info, "No host usage for \(basisFallback.joined(separator: ", ")); sized from configured VMs instead")
        }

        // MARK: Sections
        let checks = b.checks
        let wldAdds = comps.filter { c in wds.contains { c.name.hasPrefix($0.name + " ") } }
        sections.append(.metrics("Summary", [
            SolutionMetric("Management domain", "\(mgmtHostList.count) hosts",
                           dedicated ? [mgmtHostList.contains { !$0.isNew } ? "\(mgmtHostList.filter { !$0.isNew }.count) from \(chosen.cluster.name)" : "",
                                           mgmtHostList.contains(where: \.isNew) ? "\(mgmtHostList.filter(\.isNew).count) new" : ""].filter { !$0.isEmpty }.joined(separator: " + ")
                                     : "consolidated on \(chosen.cluster.name)",
                           symbol: "server.rack", status: dedicated ? (greenfieldOK ? .ready : .blocker) : (chosen.consolidated.newHosts == 0 ? .ready : .warning)),
            SolutionMetric("Management appliances", "\(SFmt.num(totCPU)) vCPU", "\(SFmt.num(totRAM)) GB RAM · \(SFmt.num(totDisk)) GB disk", symbol: "cpu"),
            SolutionMetric("Load with \(spare) host(s) down", mgmtLoad.isFinite ? Fmt.pct(mgmtLoad * 100) : "—", dedicated ? "management hosts" : "appliances + workloads", symbol: "gauge.with.dots.needle.50percent"),
            SolutionMetric("Management storage", "\(Fmt.num(storageGB / 1000, 1)) TB", storageName, symbol: "externaldrive"),
            SolutionMetric("Workload domains", Fmt.int(wds.count), "\(wds.reduce(0) { $0 + $1.clusters.count }) clusters · adds \(SFmt.num(wldAdds.reduce(0) { $0 + $1.cpu })) vCPU to management", symbol: "square.grid.2x2"),
            SolutionMetric("New hosts", Fmt.int(newHostsTotal), newHostsTotal == 0 ? "none needed" : "management and workload clusters", symbol: "plus.square.on.square",
                           status: newHostsTotal == 0 ? .ready : .warning),
        ]))
        sections.append(.checks("Assessment", checks))

        // Candidate clusters.
        let candRows = candidates.map { c -> [String] in
            let mark = c.cluster.id == chosen.cluster.id ? (isAuto ? "★ best fit" : "Selected") : (c.cluster.id == best.cluster.id ? "Best fit" : "")
            let green: String = {
                guard let plan = c.peel else { return "No" }
                return plan.newHosts == 0 ? "\(plan.mgmt.count) hosts, rest at \(Fmt.pct(plan.remainingLoad * 100))" : "Needs \(plan.newHosts) new"
            }()
            let cons = c.consolidated.newHosts < 0 ? "No" : (c.consolidated.newHosts == 0 ? "Fits at \(Fmt.pct(c.consolidated.load * 100))" : "Needs \(c.consolidated.newHosts) new")
            return [c.cluster.name, c.cluster.vcenter, "\(c.hosts.count)", SFmt.num(c.hosts.reduce(0) { $0 + $1.cores }),
                    SFmt.num(c.hosts.reduce(0) { $0 + $1.ramGiB }.rounded()), c.currentLoad.isFinite ? Fmt.pct(c.currentLoad * 100) : "—", green, cons, mark]
        }
        let merged = mergeMembers.map(\.id)
        let pending = memberIDs.isEmpty ? mergeMembers.first : nil   // one cluster ticked, waiting for a second
        let candActions: [[SolutionAction]] = candidates.map { c in
            var a: [SolutionAction] = []
            // Merge first so it lines up in one column; not every row offers "Use for management".
            if candidates.count + mergeMembers.count > 1 {
                if memberIDs[c.cluster.id] != nil {
                    a.append(SolutionAction("Split", symbol: "arrow.triangle.branch", help: "Sizes these clusters separately again.", set: ["merge": .names([])]))
                } else if pending?.id == c.cluster.id {
                    a.append(SolutionAction("Cancel merge", symbol: "xmark", set: ["merge": .names([])]))
                } else {
                    let with = memberIDs.isEmpty ? pending?.name : mergedCluster?.name
                    a.append(SolutionAction(with.map { "Merge with \($0)" } ?? "Merge…", symbol: "arrow.triangle.merge",
                                            help: with == nil ? "Then choose another cluster to merge it with." : "Sizes these clusters as one cluster.",
                                            set: ["merge": .names(merged + [c.cluster.id])]))
                }
            }
            if c.cluster.id != chosen.cluster.id {
                a.append(SolutionAction("Use for management", symbol: "star", help: "Makes this the management cluster.",
                                        set: ["mgmtCluster": .names([memberIDs[c.cluster.id]?.first ?? c.cluster.id])]))
            } else if !isAuto {
                a.append(SolutionAction("Use best fit", symbol: "star.slash", set: ["mgmtCluster": .names([])]))
            }
            return a
        }
        sections.append(.table(SolutionTable(
            id: "candidates", title: "Management domain candidates",
            subtitle: (pending.map { "\($0.name) is waiting to be merged — choose another cluster to merge it with. " } ?? "")
                + "Workload load is with \(spare) host(s) down; greenfield peels the smallest hosts off the cluster.",
            columns: ["Cluster", "vCenter", "Hosts", "Cores", "RAM (GB)", "Workload load", "Greenfield", "Consolidated", ""],
            numeric: [2, 3, 4, 5], rows: candRows, rowRefs: candidates.map { memberIDs[$0.cluster.id] == nil ? cref($0.cluster) : nil }, rowActions: candActions)))

        // Appliances.
        var compRows = comps.map { [$0.name, $0.nodes > 0 ? "\($0.nodes)" : "—", SFmt.num($0.cpu), SFmt.num($0.ram), SFmt.num($0.disk), $0.note] }
        compRows.append(["Total", "\(comps.reduce(0) { $0 + $1.nodes })", SFmt.num(totCPU), SFmt.num(totRAM), SFmt.num(totDisk), ""])
        sections.append(.table(SolutionTable(
            id: "appliances", title: "Management domain appliances", subtitle: "\(deploy.label) · sizes from the \(A.source)",
            columns: ["Component", "Nodes", "vCPU", "RAM (GB)", "Disk (GB)", "Notes"], numeric: [1, 2, 3, 4], rows: compRows, emphasized: [compRows.count - 1])))

        // Management hosts.
        if !mgmtHostList.isEmpty {
            let load = dedicated ? mgmt : mgmt + chosen.workload
            let perCPU = mgmtHostList.count > spare ? load.cores / Double(mgmtHostList.count - spare) : .infinity
            let perRAM = mgmtHostList.count > spare ? load.ramGiB / Double(mgmtHostList.count - spare) : .infinity
            var rows = mgmtHostList.map { h in [h.name, h.isNew ? "New" : (h.cluster.isEmpty ? chosen.cluster.name : h.cluster), SFmt.num(h.cores), SFmt.num(h.ramGiB.rounded())] }
            rows.append([dedicated ? "Management load per host" : "Load per host (appliances + workloads)", "\(spare) host(s) down", SFmt.num(perCPU.rounded(.up)), SFmt.num(perRAM.rounded(.up))])
            sections.append(.table(SolutionTable(
                id: "mgmt-hosts", title: dedicated ? "Management domain hosts" : "Consolidated cluster hosts",
                subtitle: dedicated ? "Appliances at \(SFmt.num(mgmtRatio)):1 vCPU per core" : "Appliances at \(SFmt.num(mgmtRatio)):1 plus the cluster's workloads",
                columns: ["Host", "Source", "Cores", "RAM (GB)"], numeric: [2, 3], rows: rows,
                rowRefs: mgmtHostList.map { $0.isNew ? nil : AffectedObject(kind: .host, id: $0.id, name: $0.name) } + [nil], emphasized: [rows.count - 1])))
        }

        // Storage.
        var storRows: [[String]] = [
            ["Appliance disk", SFmt.num(totDisk)],
            ["Swap (appliance memory)", SFmt.num(totRAM)],
        ]
        if kind != 3 {
            storRows.append(["vSAN protection (FTT=1, \(kind == 1 ? "×1.5 ESA" : "×2 OSA"))", SFmt.num(protected.rounded(.up))])
            storRows.append(["Rebuild and operations reserve (\(SFmt.num(reserve * 100))%)", SFmt.num(reserved.rounded(.up))])
        }
        storRows.append(["With \(SFmt.num(growth * 100))% growth", SFmt.num(storageGB)])
        sections.append(.table(SolutionTable(id: "mgmt-storage", title: "Management domain storage (GB)", subtitle: storageName,
                                             columns: ["Step", "GB"], numeric: [1], rows: storRows, emphasized: [storRows.count - 1])))

        // Workload domains.
        if !wds.isEmpty {
            let rows = wds.map { wd -> [String] in
                let adds = comps.filter { $0.name.hasPrefix(wd.name + " ") }
                return [wd.name, wd.clusters.map(\.name).joined(separator: ", "), "\(wd.hosts)", Fmt.int(wd.vms),
                        newVCenters ? wd.vcSize : "Existing", wldNSX == 2 ? "Shared" : "\(wd.nsxSize) × \(wldNSX == 0 ? 3 : 1)",
                        "\(SFmt.num(adds.reduce(0) { $0 + $1.cpu })) vCPU · \(SFmt.num(adds.reduce(0) { $0 + $1.ram })) GB"]
            }
            sections.append(.table(SolutionTable(
                id: "workload-domains", title: "Workload domains", subtitle: "What each converged domain adds to the management domain",
                columns: ["Domain", "Clusters", "Hosts", "VMs", "vCenter", "NSX Managers", "Adds to management"], numeric: [2, 3], rows: rows)))
            sections.append(.table(SolutionTable(
                id: "workload-clusters", title: "Workload clusters", subtitle: "Existing workloads with \(spare) host(s) down, at most \(SFmt.num(maxLoad * 100))%",
                columns: ["Cluster", "Domain", "Hosts", "Demand (cores)", "Demand (GB)", "Load", "Capacity"], numeric: [2, 3, 4, 5],
                rows: clusterRows, rowRefs: clusterRefs)))
        }
        if !mergeRows.isEmpty {
            sections.append(.table(SolutionTable(id: "merge", title: "Merged cluster", columns: ["", "Value"], numeric: [1], rows: mergeRows)))
        }

        // The alternative the user didn't pick, when it matters.
        if dedicated && !greenfieldOK {
            let f = bestCons.consolidated
            sections.append(.notes("Alternative: consolidated management domain", [
                f.newHosts == 0
                    ? "\(bestCons.cluster.name) could run the management appliances alongside its workloads on its \(f.hosts.count) hosts (\(Fmt.pct(f.load * 100)) with \(spare) down)."
                    : "The best consolidated option, \(bestCons.cluster.name), needs \(max(f.newHosts, 0)) more host(s).",
                "Switch Management domain to Consolidated under Assumptions to size it in full.",
            ]))
        } else if !dedicated, let plan = bestPeel.peel, plan.newHosts == 0 {
            sections.append(.notes("Alternative: dedicated management domain", [
                "\(bestPeel.cluster.name) can give up \(plan.mgmt.count) hosts for a greenfield management domain and still carry its workloads at \(Fmt.pct(plan.remainingLoad * 100)).",
            ]))
        }

        var notes = [
            "Management appliance sizes, node counts and the storage steps follow the \(A.source) (Management Domain Sizing tab, first instance). Unlike the workbook, CPU and memory both keep \(spare) host(s) in reserve.",
            "Host fit uses each host's cores and memory from vHost. " + (measured
                ? "Existing workloads are sized from measured host CPU and memory usage, so they include every VM on those hosts."
                : "Existing workloads are the selected powered-on VMs at \(SFmt.num(wlRatio)):1 vCPU per core and 1:1 memory."),
            "Greenfield assumes the other hosts in the cluster can take its VMs (vMotion / DRS) before hosts are removed for the management domain.",
            "Not in this sizing: Supervisor, Avi, Security Services Platform, VCF Operations for networks and Live Recovery — add them as Other management VMs.",
        ]
        if !isAuto { notes.insert("Management cluster chosen under Assumptions; best fit would be \(best.cluster.name).", at: 0) }
        sections.append(.notes("About this sizing", notes))

        if headline.isEmpty { headline = "\(clusters.count) clusters sized" }
        headline += " · \(wds.count) workload domain(s)" + (newHostsTotal > 0 ? " · \(newHostsTotal) new host(s) overall" : "")
        return SolutionResult(headline: headline, sections: sections)
    }
}
