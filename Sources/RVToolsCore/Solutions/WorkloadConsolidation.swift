import Foundation

/// Validates today's vSphere workload clusters and plans a tighter layout on the hosts the customer already has: which
/// clusters to merge, where memory needs adding, which hosts to move so each cluster runs one CPU family, and which hosts
/// a cluster doesn't need. Workload clusters only: the VCF management domain is assumed to run elsewhere already.
///
/// Recommendations are made automatically (each kind can be turned off) and overrides always win: merge groups, clusters
/// kept standalone, memory per host and host moves. Results offer one-click changes that write those overrides.
public struct WorkloadConsolidation: Solution {
    public init() {}
    public var id: String { "consolidation" }
    public var title: String { "Workload Consolidation" }
    public var symbol: String { "rectangle.compress.vertical" }
    public var summary: String { "Validate today's vSphere clusters and plan a tighter layout on the existing hosts: merges, memory upgrades, CPU family alignment and hosts to release. Workload clusters only; management runs elsewhere." }

    /// Memory sizes a host can be upgraded to, in GiB.
    static let ramSizes: [Double] = [256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192]
    static func ramLabel(_ gib: Double) -> String {
        let g = gib.rounded()
        if g < 1024 || g.truncatingRemainder(dividingBy: 512) != 0 { return Fmt.int(Int(g)) + " GiB" }
        return String(format: "%g", g / 1024) + " TiB"
    }

    public var parameters: [SolutionParameter] {
        let sizes = WorkloadConsolidation.ramSizes
        return [
            .choice("mode", "Plan", "Plan", [
                "Recommended changes, plus my overrides",
                "Only my overrides (validate today's layout)",
            ], help: "Recommended changes merge clusters, add memory, align CPU families and release hosts, as the options below allow. Your overrides always apply."),
            .toggle("autoMerge", "Plan", "Merge clusters when that saves hosts", true,
                    help: "Only clusters in the same datacenter and vCenter, with the same CPU vendor and family and the same environment (production, test or development). Clusters named for a role stay separate unless you merge them below: SQL, Oracle or DB (database licensing), NoMS, Linux or RHEL (OS licensing), CTX, Citrix, VDI or Horizon (desktops), Recovery, DR or SRM, and management."),
            .choice("autoRAM", "Plan", "Memory upgrades", [
                "Where a cluster is short of memory",
                "Also where more memory releases hosts",
                "Never",
            ], help: "A cluster short of memory whose CPU has room gets the smallest upgrade that fits, rather than more hosts. Every host below the new size is upgraded to it."),
            .toggle("autoAlign", "Plan", "Move hosts to a cluster of their CPU family", true,
                    help: "When a cluster mixes CPU families (Xeon Scalable 2nd and 4th gen, say), its minority hosts move to a cluster of their family in the same datacenter, if the cluster still fits without them. Database, licensing and recovery clusters don't receive hosts this way. Otherwise the results suggest an EVC mode."),
            .toggle("autoRelease", "Plan", "Release hosts a cluster doesn't need", true,
                    help: "Hosts beyond what a cluster needs at the load limit, with failures held in reserve, go to a spare pool: hosts in maintenance mode first, then hosts outside the cluster's main CPU family, then the oldest and smallest."),
            .toggle("rebalance", "Plan", "Use spare hosts before adding new ones", true,
                    help: "A cluster that's short takes released hosts from the same datacenter and CPU vendor first, its own CPU family first."),
            .clusterGroups("merge", "Overrides", "Merge these clusters",
                           help: "Each group becomes one cluster, whatever the recommendations say."),
            .clusters("solo", "Overrides", "Keep standalone", multi: true, none: "None",
                      help: "Never merged, and CPU alignment neither moves its hosts out nor moves hosts in. For example, a database cluster licensed by its hosts. Memory upgrades and releasing hosts still apply."),
            .clusterValues("ram", "Overrides", "Memory per host", values: [0] + sizes, labels: ["No upgrade"] + sizes.map(WorkloadConsolidation.ramLabel),
                           help: "Hosts with less memory are upgraded to this size. No upgrade stops a recommended one. In a merged cluster, the largest size set for any of its clusters applies."),
            .hostMoves("moves", "Overrides", "Move hosts",
                       help: "Move a cluster's hosts of one CPU family, or all of them, to another cluster, or release them to the spare pool. Keep in place stops recommendations from moving or releasing them."),
            .toggle("includeMgmt", "Capacity", "Include management clusters", false,
                    help: "Off by default: VCF management is assumed to run on its own clusters already. Clusters named mgmt or management are left out unless this is on."),
            .choice("basis", "Capacity", "Size workloads from", [
                "Measured host usage (vHost CPU and memory %)",
                "Configured vCPU and memory of the selected powered-on VMs",
            ], help: "Measured usage is each host's CPU and memory use, scaled to the selected VMs' share of it. It stays with the cluster when hosts move."),
            .number("ratio", "Capacity", "vCPU per core", 4, min: 0.5, max: 20, step: 0.5, unit: ": 1",
                    help: "Sizes CPU when sizing from configured vCPU. Either way, planned clusters above it are flagged."),
            .number("memRatio", "Capacity", "Configured memory per physical memory", 100, min: 50, max: 300, step: 5, unit: "%",
                    help: "Only for configured sizes: 100% means no memory overcommit."),
            .number("spare", "Capacity", "Host failures to tolerate", 1, min: 0, max: 3,
                    help: "Hosts held back in every cluster for failures and maintenance; the largest hosts are assumed down."),
            .number("maxLoad", "Capacity", "Max CPU / memory load with those hosts down", 80, min: 50, max: 100, unit: "%"),
            .number("growth", "Capacity", "Growth to plan for", 0, min: 0, max: 200, unit: "%"),
            .number("minHosts", "Capacity", "Minimum hosts per cluster", 2, min: 1, max: 16, help: "vSAN clusters keep at least 3."),
            .number("maxHosts", "Capacity", "Most hosts per cluster", 64, min: 2, max: 96,
                    help: "vSphere 8 allows 96 hosts per cluster and vSAN 64. Merges that would pass this aren't recommended."),
            .choice("maxRAM", "Hardware", "Most memory a host takes", sizes.map(WorkloadConsolidation.ramLabel), selected: sizes.firstIndex(of: 3072) ?? 0,
                    help: "Upgrades stop at this size. It depends on the server: a Cisco UCS B200 M5 takes 3 TiB with 128 GiB DIMMs, an X210c M7 8 TiB. Check the vendor's memory guide, and that every host has free slots or that its DIMMs can be swapped."),
            .number("coreMin", "Licensing", "Licensed cores minimum per CPU", 16, min: 1, max: 64,
                    help: "VMware licenses cores with a per-CPU minimum, so releasing hosts saves licensed cores. Verify current terms."),
        ]
    }

    public func defaultSelection(_ inventory: Inventory) -> Set<String> {
        Set(inventory.workloadVMs.map(\.id))
    }

    // MARK: - Roles

    enum Role: String {
        case general, database, licensing, vdi, recovery, management
        var label: String {
            switch self {
            case .general: return ""
            case .database: return "Database"
            case .licensing: return "OS licensing"
            case .vdi: return "Desktops"
            case .recovery: return "Recovery"
            case .management: return "Management"
            }
        }
        var phrase: String {
            switch self {
            case .general: return "a general cluster"
            case .database: return "a database cluster"
            case .licensing: return "an OS licensing cluster"
            case .vdi: return "a desktop cluster"
            case .recovery: return "a recovery cluster"
            case .management: return "a management cluster"
            }
        }
        /// Roles that don't take hosts from CPU alignment.
        var receivesHosts: Bool { ![.database, .licensing, .recovery, .management].contains(self) }
    }

    static func tokens(_ name: String) -> [String] {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// A role guessed from the cluster name.
    static func role(_ name: String) -> Role {
        let t = tokens(name)
        func any(_ words: [String]) -> Bool { t.contains { words.contains($0) } }
        if t.contains(where: { $0.hasPrefix("sql") || $0.hasPrefix("mssql") || $0.contains("oracle") || $0 == "ora" || $0 == "db" || $0 == "database" || $0 == "databases" }) {
            return .database
        }
        if any(["noms", "nonms", "linux", "rhel", "lic", "licensing", "licensed"]) { return .licensing }
        if any(["ctx", "citrix", "vdi", "horizon", "xenapp", "xendesktop", "avd", "euc", "rds", "wvd"]) { return .vdi }
        if any(["recovery", "dr", "srm", "failover", "standby", "bcp"]) { return .recovery }
        if any(["mgmt", "management", "mgt"]) { return .management }
        return .general
    }

    /// "prod" unless the name says test or development.
    static func environment(_ name: String) -> String {
        let t = tokens(name)
        if t.contains(where: { ["test", "tst", "qa", "uat", "stage", "staging", "nonprod", "preprod", "np"].contains($0) }) { return "test" }
        if t.contains(where: { ["dev", "development", "sandbox", "lab"].contains($0) }) { return "dev" }
        return "prod"
    }

    // MARK: - Model

    struct Demand {
        var cores = 0.0, ramGiB = 0.0
        var isEmpty: Bool { cores <= 0 && ramGiB <= 0 }
        static func + (a: Demand, b: Demand) -> Demand { Demand(cores: a.cores + b.cores, ramGiB: a.ramGiB + b.ramGiB) }
        static func * (a: Demand, f: Double) -> Demand { Demand(cores: a.cores * f, ramGiB: a.ramGiB * f) }
    }

    struct WHost {
        var id: String
        var name: String
        /// The cluster the host is in today; "" for a new host.
        var origin: String
        var originName: String
        /// The planned cluster.
        var cluster: String
        var cores: Double
        var threads: Int
        var sockets: Int
        var coresPerSocket: Int
        var reportedGiB: Double
        var ramGiB: Double
        var gen: CPUBaseline
        var evcCurrent: String
        var esx: String
        var maintenance = false
        var isNew = false
        /// Recommendations don't move or release it.
        var pinned = false
        var released = false
        var releasedBy = ""
        var movedBy = ""
        var fromPool = false
        /// Memory before an upgrade, nominal GiB; 0 when not upgraded.
        var upgradedFrom = 0.0
        /// Installed memory as sold (768 GiB rather than the 766.7 the host reports).
        var nominalGiB: Double { max(32, (reportedGiB / 32).rounded(.up) * 32) }

        func licensed(_ coreMin: Double) -> Double {
            sockets > 0 ? Double(sockets) * max(coreMin, Double(coresPerSocket)) : max(coreMin, cores)
        }
    }

    struct PCluster {
        var id: String
        var name: String
        var members: [Cluster]
        var site: String
        var siteName: String
        var demand: Demand
        var vms: [VM]
        var role: Role
        var env: String
        var solo: Bool
        var vsan: Bool
        var forced = false
        var auto = false
        var ramFloor = 0.0
        var ramSetByYou = false
        var ramReason = ""
        var isMerged: Bool { members.count > 1 }
    }

    struct Load {
        var cpu = 0.0, mem = 0.0
        var worst: Double { max(cpu, mem) }
    }

    /// CPU and memory load once the `spare` largest hosts are out; infinity if too few hosts remain for the demand.
    static func load(_ hosts: [WHost], _ d: Demand, spare: Int) -> Load {
        if d.isEmpty { return Load() }
        guard hosts.count > spare else { return Load(cpu: .infinity, mem: .infinity) }
        let cores = hosts.map(\.cores).sorted(by: >).dropFirst(spare).reduce(0, +)
        let ram = hosts.map(\.ramGiB).sorted(by: >).dropFirst(spare).reduce(0, +)
        let cpu = cores > 0 ? d.cores / cores : (d.cores > 0 ? Double.infinity : 0)
        let mem = ram > 0 ? d.ramGiB / ram : (d.ramGiB > 0 ? Double.infinity : 0)
        return Load(cpu: cpu, mem: mem)
    }

    /// The family most hosts have (the newest on a tie).
    static func majority(_ hosts: [WHost]) -> String {
        let counts = Dictionary(grouping: hosts.filter { !$0.isNew }, by: \.gen.family).mapValues(\.count)
        let ranks = Dictionary(hosts.map { ($0.gen.family, $0.gen.rank) }, uniquingKeysWith: max)
        return counts.max { ($0.value, ranks[$0.key] ?? 0) < ($1.value, ranks[$1.key] ?? 0) }?.key ?? CPUFamily.unknown
    }

    static func majorityVendor(_ hosts: [WHost]) -> String {
        let counts = Dictionary(grouping: hosts, by: \.gen.vendor).mapValues(\.count)
        return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? ""
    }

    /// The median host by memory, the model for new hosts.
    static func typical(_ hosts: [WHost]) -> WHost? {
        let sorted = hosts.filter { !$0.isNew }.sorted { ($0.ramGiB, $0.cores, $0.name) < ($1.ramGiB, $1.cores, $1.name) }
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }

    static func withMemory(_ hosts: [WHost], floor: Double) -> [WHost] {
        guard floor > 0 else { return hosts }
        return hosts.map { h in
            var h = h
            if h.nominalGiB < floor {
                h.upgradedFrom = h.upgradedFrom > 0 ? h.upgradedFrom : h.nominalGiB
                h.ramGiB = floor * h.reportedGiB / h.nominalGiB
            }
            return h
        }
    }

    /// "768 GiB ×7, 1 TiB ×2"
    static func memoryMix(_ hosts: [WHost]) -> String {
        let counts = Dictionary(grouping: hosts) { ($0.upgradedFrom > 0 ? ($0.ramGiB * $0.nominalGiB / $0.reportedGiB) : $0.nominalGiB).rounded() }.mapValues(\.count)
        return counts.sorted { $0.key < $1.key }.map { "\(ramLabel($0.key)) ×\($0.value)" }.joined(separator: ", ")
    }

    static func familyMix(_ hosts: [WHost]) -> String {
        let counts = Dictionary(grouping: hosts, by: \.gen.family).mapValues(\.count)
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\(CPUFamily.short($0.key)) ×\($0.value)" }.joined(separator: ", ")
    }

    static func pct(_ x: Double) -> String { x.isFinite ? "\(Int((x * 100).rounded()))%" : "—" }

    // MARK: - Run

    public func run(vms: [VM], inventory inv: Inventory, params p: Params) -> SolutionResult {
        typealias W = WorkloadConsolidation
        let recommend = p.choice("mode") == 0
        let spare = max(Int(p.num("spare")), 0)
        let maxLoad = max(p.num("maxLoad"), 1) / 100
        let measured = p.choice("basis") == 0
        let ratio = max(p.num("ratio"), 0.1)
        let memRatio = max(p.num("memRatio"), 1) / 100
        let growth = 1 + max(p.num("growth"), 0) / 100
        let minHostsParam = max(Int(p.num("minHosts")), 1)
        let maxHosts = max(Int(p.num("maxHosts")), 2)
        let maxRAM = W.ramSizes[min(max(p.choice("maxRAM"), 0), W.ramSizes.count - 1)]
        let coreMin = max(p.num("coreMin"), 1)
        let autoRAM = recommend ? p.choice("autoRAM") : 2
        let autoRelease = recommend && p.flag("autoRelease")
        let downText = spare == 0 ? "with no hosts down" : "with \(spare) host\(spare == 1 ? "" : "s") down"

        func resolve(_ ref: String) -> Cluster? {
            inv.clusters.first { $0.id == ref } ?? inv.clusters.first { $0.name.lowercased() == ref.lowercased() && !$0.isStandalone }
        }

        // Scope: the clusters behind the selected VMs, plus idle clusters in the same datacenters.
        let realHosts = inv.hosts.filter { !$0.isVirtual }
        let hostsByCluster = Dictionary(grouping: realHosts, by: \.clusterKey)
        let vmsByCluster = Dictionary(grouping: vms, by: \.clusterKey)
        let allVMsByCluster = Dictionary(grouping: inv.vms.filter(\.isVM), by: \.clusterKey)
        func siteKey(_ c: Cluster) -> String { c.vcenter.lowercased() + "|" + c.datacenter.lowercased() }
        func siteName(_ c: Cluster) -> String {
            [c.datacenter, c.vcenter].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let selectedSites = Set(inv.clusters.filter { vmsByCluster[$0.id] != nil }.map(siteKey))
        let includeMgmt = p.flag("includeMgmt")
        let mgmtLeftOut = inv.clusters.filter { !$0.isStandalone && vmsByCluster[$0.id] != nil && W.role($0.name) == .management && !includeMgmt }
        let scope = inv.clusters.filter { c in
            !c.isStandalone && !(hostsByCluster[c.id] ?? []).isEmpty && (includeMgmt || W.role(c.name) != .management)
                && (vmsByCluster[c.id] != nil || ((allVMsByCluster[c.id] ?? []).isEmpty && selectedSites.contains(siteKey(c))))
        }.sorted { (siteKey($0), $0.name.lowercased()) < (siteKey($1), $1.name.lowercased()) }
        let scopeIDs = Set(scope.map(\.id))
        let mgmtIDs = Set(mgmtLeftOut.map(\.id))
        let outsideVMs = vms.filter { !scopeIDs.contains($0.clusterKey) && !mgmtIDs.contains($0.clusterKey) }

        guard !scope.isEmpty else {
            return SolutionResult(headline: "No clusters with hosts in scope", sections: [
                .notes("Nothing to plan", ["Select VMs that run in a cluster on the Select VMs step. Standalone hosts aren't planned."]),
            ])
        }

        // Demand of each cluster today, which stays with the cluster wherever its hosts go.
        var basisFallback: [String] = []
        var demandByCluster: [String: Demand] = [:]
        for c in scope {
            let selected = (vmsByCluster[c.id] ?? []).filter(\.isRunning)
            if selected.isEmpty { demandByCluster[c.id] = Demand(); continue }
            let configured = Demand(cores: Double(selected.reduce(0) { $0 + $1.cpus }) / ratio,
                                    ramGiB: selected.reduce(0) { $0 + $1.memoryMiB } / 1024 / memRatio)
            guard measured else { demandByCluster[c.id] = configured * growth; continue }
            let hs = (hostsByCluster[c.id] ?? []).filter { !$0.inferred }
            let d = Demand(cores: hs.reduce(0) { $0 + Double($1.cores) * $1.cpuUsagePct / 100 },
                           ramGiB: hs.reduce(0) { $0 + $1.memoryMiB / 1024 * $1.memUsagePct / 100 })
            if d.isEmpty && !configured.isEmpty {
                basisFallback.append(c.name)
                demandByCluster[c.id] = configured * growth
                continue
            }
            // Host usage covers every VM on the hosts; keep the selected VMs' share of it.
            let all = (allVMsByCluster[c.id] ?? []).filter(\.isRunning)
            func share(_ value: (VM) -> Double) -> Double? {
                let total = all.reduce(0) { $0 + value($1) }
                return total > 0 ? min(1, selected.reduce(0) { $0 + value($1) } / total) : nil
            }
            let cpuShare = share(\.cpuUsageMHz) ?? share { Double($0.cpus) } ?? 1
            let memShare = share(\.memConsumedMiB) ?? share(\.memoryMiB) ?? 1
            demandByCluster[c.id] = Demand(cores: d.cores * cpuShare, ramGiB: d.ramGiB * memShare) * growth
        }

        // Hosts.
        var hosts: [WHost] = []
        var unknownHosts: [Host] = []
        for c in scope {
            for h in (hostsByCluster[c.id] ?? []).sorted(by: { $0.name < $1.name }) {
                guard !h.inferred, h.cores > 0, h.memoryMiB > 0 else { unknownHosts.append(h); continue }
                hosts.append(WHost(id: h.id, name: h.name, origin: c.id, originName: c.name, cluster: c.id, cores: Double(h.cores),
                                   threads: h.threads, sockets: h.sockets, coresPerSocket: h.coresPerSocket,
                                   reportedGiB: h.memoryMiB / 1024, ramGiB: h.memoryMiB / 1024, gen: CPUBaseline.of(h),
                                   evcCurrent: h.evcCurrent, esx: h.esxShort, maintenance: h.maintenance))
            }
        }
        let todayHosts = hosts
        func vsan(_ ids: [String]) -> Bool {
            inv.datastores.contains { $0.type.lowercased() == "vsan" && $0.clusterKeys.contains(where: ids.contains) }
        }
        func minHosts(_ isVSAN: Bool) -> Int { max(minHostsParam, isVSAN ? 3 : 1) }
        func fits(_ hs: [WHost], _ d: Demand, _ minimum: Int) -> Bool {
            hs.count >= minimum && W.load(hs, d, spare: spare).worst <= maxLoad
        }
        /// Releases hosts one at a time while the rest still fit: maintenance mode first, then hosts outside the main
        /// family, then the oldest and smallest. Pinned and new hosts stay.
        func trim(_ hs: [WHost], _ d: Demand, _ minimum: Int) -> (kept: [WHost], released: [WHost]) {
            guard fits(hs, d, minimum) else { return (hs, []) }
            let major = W.majority(hs)
            func rank(_ h: WHost) -> (Int, Int, Int, Double, Double, String) {
                (h.maintenance ? 0 : 1, h.gen.family == major ? 1 : 0, h.gen.rank, h.ramGiB, h.cores, h.name)
            }
            let order = hs.filter { !$0.pinned && !$0.isNew }.sorted { rank($0) < rank($1) }
            var kept = hs
            var released: [WHost] = []
            for h in order {
                let trial = kept.filter { $0.id != h.id }
                if fits(trial, d, minimum) { kept = trial; released.append(h) }
            }
            return (kept, released)
        }
        /// New hosts like the typical one needed until the demand fits; nil if no number does.
        func additions(_ hs: [WHost], _ d: Demand, _ minimum: Int, floor: Double = 0) -> Int? {
            guard let t = W.typical(hs) else { return nil }
            var pool = hs
            var model = t
            model.isNew = true
            model = W.withMemory([model], floor: floor)[0]
            for k in 0...256 {
                if fits(pool, d, minimum) { return k }
                pool.append(model)
            }
            return nil
        }
        /// Hosts the demand needs: after releasing what it doesn't, or with new hosts added.
        func needed(_ hs: [WHost], _ d: Demand, _ minimum: Int) -> Int {
            if fits(hs, d, minimum) { return trim(hs, d, minimum).kept.count }
            return hs.count + (additions(hs, d, minimum) ?? 999)
        }

        // Overrides already set, for building one-click changes.
        let soloNames = p.names("solo"), mergeNames = p.names("merge"), ramNames = p.names("ram"), moveNames = p.names("moves")
        let soloIDs = Set(soloNames.compactMap(resolve).map(\.id))
        var notes: [String] = []

        // 1. Your host moves, on today's clusters.
        var invalidMoves = 0
        for e in moveNames {
            let parts = PlanEntry.parts(e)
            guard parts.count == 3, let src = resolve(parts[0]), scopeIDs.contains(src.id) else { invalidMoves += 1; continue }
            let fam = parts[1], dst = parts[2]
            var target: Cluster?
            if dst != HostMove.release && dst != HostMove.keep {
                guard let t = resolve(dst), scopeIDs.contains(t.id), t.id != src.id else { invalidMoves += 1; continue }
                target = t
            }
            for i in hosts.indices where hosts[i].origin == src.id && (fam == HostMove.all || hosts[i].gen.family == fam) {
                hosts[i].pinned = true
                if dst == HostMove.release {
                    hosts[i].released = true
                    hosts[i].releasedBy = "you"
                } else if let target {
                    hosts[i].cluster = target.id
                    hosts[i].movedBy = "you"
                }
            }
        }
        if invalidMoves > 0 { notes.append("\(invalidMoves) host move(s) name a cluster that isn't in scope, and were skipped.") }

        // Today's clusters after your moves: merges are judged on these.
        let baseHosts = hosts
        func hostsOf(_ clusterIDs: [String]) -> [WHost] { baseHosts.filter { !$0.released && clusterIDs.contains($0.cluster) } }

        // 2. Merges: yours, then recommended.
        var groups: [(members: [Cluster], forced: Bool)] = []
        var grouped = Set<String>()
        var soloInMerge: [String] = []
        for e in mergeNames {
            var members: [Cluster] = []
            for ref in PlanEntry.parts(e) {
                guard let c = resolve(ref), scopeIDs.contains(c.id), !grouped.contains(c.id), !members.contains(where: { $0.id == c.id }) else { continue }
                if soloIDs.contains(c.id) { soloInMerge.append(c.name); continue }
                members.append(c)
            }
            if members.count > 1 { groups.append((members, true)); grouped.formUnion(members.map(\.id)) }
        }
        func roleOf(_ c: Cluster) -> Role { W.role(c.name) }
        func clusterFamily(_ c: Cluster) -> String { W.majority(hostsOf([c.id])) }
        func clusterVendor(_ c: Cluster) -> String { W.majorityVendor(hostsOf([c.id])) }
        func demandOf(_ cs: [Cluster]) -> Demand { cs.reduce(Demand()) { $0 + (demandByCluster[$1.id] ?? Demand()) } }
        func mergeSaving(_ cs: [Cluster]) -> Int {
            let apart = cs.reduce(0) { $0 + needed(hostsOf([$1.id]), demandOf([$1]), minHosts(vsan([$1.id]))) }
            let together = needed(hostsOf(cs.map(\.id)), demandOf(cs), minHosts(vsan(cs.map(\.id))))
            return apart - together
        }
        if recommend && p.flag("autoMerge") {
            let eligible = scope.filter {
                !grouped.contains($0.id) && !soloIDs.contains($0.id) && roleOf($0) == .general && vmsByCluster[$0.id] != nil && !hostsOf([$0.id]).isEmpty
            }
            let buckets = Dictionary(grouping: eligible) { c in [siteKey(c), W.environment(c.name), clusterVendor(c), clusterFamily(c)].joined(separator: "#") }
            for key in buckets.keys.sorted() {
                guard !key.contains("#" + CPUFamily.unknown) else { continue }
                var members: [Cluster] = []
                var count = 0
                for c in buckets[key]!.sorted(by: { (hostsOf([$0.id]).count, $0.name) < (hostsOf([$1.id]).count, $1.name) }) {
                    let n = hostsOf([c.id]).count
                    if count + n <= maxHosts { members.append(c); count += n }
                }
                guard members.count > 1, mergeSaving(members) > 0 else { continue }
                groups.append((members, false))
                grouped.formUnion(members.map(\.id))
            }
        }

        // The planned clusters.
        var plan: [PCluster] = []
        var planIDOf: [String: String] = [:]
        func makeCluster(_ members: [Cluster], forced: Bool, auto: Bool) -> PCluster {
            let id = members.count == 1 ? members[0].id : "merged|" + members.map(\.id).joined(separator: ",")
            let sites = Set(members.map(siteKey))
            let roles = Set(members.map(roleOf))
            return PCluster(id: id, name: members.map(\.name).joined(separator: " + "), members: members,
                            site: sites.count == 1 ? sites.first! : "mixed",
                            siteName: Array(Set(members.map(siteName))).sorted().joined(separator: ", "),
                            demand: demandOf(members), vms: members.flatMap { vmsByCluster[$0.id] ?? [] },
                            role: roles.count == 1 ? roles.first! : .general, env: W.environment(members[0].name),
                            solo: members.count == 1 && soloIDs.contains(members[0].id), vsan: vsan(members.map(\.id)), forced: forced, auto: auto)
        }
        for g in groups {
            let c = makeCluster(g.members, forced: g.forced, auto: !g.forced)
            plan.append(c)
            for m in g.members { planIDOf[m.id] = c.id }
        }
        for c in scope where planIDOf[c.id] == nil {
            plan.append(makeCluster([c], forced: false, auto: false))
            planIDOf[c.id] = c.id
        }
        plan.sort { ($0.site, $0.name.lowercased()) < ($1.site, $1.name.lowercased()) }
        for i in hosts.indices { hosts[i].cluster = planIDOf[hosts[i].cluster] ?? hosts[i].cluster }
        func members(_ ci: Int) -> [WHost] { hosts.filter { !$0.released && $0.cluster == plan[ci].id } }
        func minHosts(_ ci: Int) -> Int { minHosts(plan[ci].vsan) }

        // 3. CPU alignment.
        struct AlignMove { let from: Int, to: Int, family: String, ids: [String] }
        struct AlignBlock { let cluster: Int, family: String, reason: String, target: Int? }
        var alignMoves: [AlignMove] = []
        var alignBlocks: [AlignBlock] = []
        for ci in plan.indices {
            let hs = members(ci)
            let families = Set(hs.map(\.gen.family)).subtracting([CPUFamily.unknown])
            guard families.count > 1 else { continue }
            let major = W.majority(hs)
            for fam in families.sorted() where fam != major {
                let movers = hs.filter { $0.gen.family == fam && !$0.pinned }
                guard !movers.isEmpty else { continue }
                let sameFamily = plan.indices.filter { $0 != ci && plan[$0].site == plan[ci].site && W.majority(members($0)) == fam }
                let targets = sameFamily.filter { !plan[$0].solo && plan[$0].role.receivesHosts }
                guard recommend && p.flag("autoAlign") else {
                    alignBlocks.append(AlignBlock(cluster: ci, family: fam, reason: "", target: sameFamily.first))
                    continue
                }
                if plan[ci].solo {
                    alignBlocks.append(AlignBlock(cluster: ci, family: fam, reason: "it's kept standalone", target: sameFamily.first))
                    continue
                }
                guard let t = targets.max(by: { W.load(members($0), plan[$0].demand, spare: spare).worst < W.load(members($1), plan[$1].demand, spare: spare).worst }) else {
                    let why = sameFamily.isEmpty ? "no other cluster in its datacenter runs that family"
                        : "the only cluster of that family, \(plan[sameFamily[0]].name), is \(plan[sameFamily[0]].solo ? "kept standalone" : plan[sameFamily[0]].role.phrase)"
                    alignBlocks.append(AlignBlock(cluster: ci, family: fam, reason: why, target: sameFamily.first))
                    continue
                }
                let ids = Set(movers.map(\.id))
                let rest = hs.filter { !ids.contains($0.id) }
                guard fits(rest, plan[ci].demand, minHosts(ci)) else {
                    alignBlocks.append(AlignBlock(cluster: ci, family: fam, reason: "\(plan[ci].name) needs those hosts", target: t))
                    continue
                }
                for i in hosts.indices where ids.contains(hosts[i].id) {
                    hosts[i].cluster = plan[t].id
                    hosts[i].movedBy = "CPU alignment"
                }
                alignMoves.append(AlignMove(from: ci, to: t, family: fam, ids: movers.map(\.id)))
            }
        }

        // 4. Memory.
        var ramByCluster: [String: Double] = [:]
        for e in ramNames {
            let parts = PlanEntry.parts(e)
            if parts.count == 2, let c = resolve(parts[0]), let v = Double(parts[1]) { ramByCluster[c.id] = v }
        }
        /// The smallest upgrade that makes the hosts fit, if CPU isn't what's short.
        func memoryFix(_ hs: [WHost], _ d: Demand, _ minimum: Int) -> Double? {
            let l = W.load(hs, d, spare: spare)
            guard l.mem > maxLoad, l.cpu <= maxLoad, hs.count >= minimum, let low = hs.map(\.nominalGiB).min() else { return nil }
            return W.ramSizes.first { $0 > low && $0 <= maxRAM && fits(W.withMemory(hs, floor: $0), d, minimum) }
        }
        for ci in plan.indices {
            let set = plan[ci].members.compactMap { ramByCluster[$0.id] }
            if let v = set.max() {
                plan[ci].ramFloor = v
                plan[ci].ramSetByYou = true
            } else if autoRAM < 2 {
                let hs = members(ci), d = plan[ci].demand, minimum = minHosts(ci)
                if let s = memoryFix(hs, d, minimum) {
                    plan[ci].ramFloor = s
                    plan[ci].ramReason = "short of memory"
                }
                if autoRAM == 1 && autoRelease, let low = hs.map(\.nominalGiB).min() {
                    let base = W.withMemory(hs, floor: plan[ci].ramFloor)
                    let baseCount = fits(base, d, minimum) ? trim(base, d, minimum).kept.count : Int.max
                    var best: (size: Double, count: Int)?
                    for s in W.ramSizes where s > max(low, plan[ci].ramFloor) && s <= maxRAM {
                        let up = W.withMemory(hs, floor: s)
                        guard fits(up, d, minimum) else { continue }
                        let n = trim(up, d, minimum).kept.count
                        if n < (best?.count ?? baseCount) { best = (s, n) }
                    }
                    if let best {
                        let n = baseCount == Int.max ? hs.count - best.count : baseCount - best.count
                        plan[ci].ramReason = "releases \(n) host\(n == 1 ? "" : "s")"
                        plan[ci].ramFloor = best.size
                    }
                }
            }
            guard plan[ci].ramFloor > 0 else { continue }
            let floor = plan[ci].ramFloor
            for i in hosts.indices where !hosts[i].released && hosts[i].cluster == plan[ci].id {
                hosts[i] = W.withMemory([hosts[i]], floor: floor)[0]
            }
        }

        // 5. Release what each cluster doesn't need; upgrades on released hosts are undone.
        if autoRelease {
            for ci in plan.indices {
                let out = trim(members(ci), plan[ci].demand, minHosts(ci)).released
                let ids = Set(out.map(\.id))
                for i in hosts.indices where ids.contains(hosts[i].id) {
                    hosts[i].released = true
                    hosts[i].releasedBy = "not needed"
                    hosts[i].ramGiB = hosts[i].reportedGiB
                    hosts[i].upgradedFrom = 0
                }
            }
        }

        // 6. Shortfalls: spare hosts first, then new hosts.
        var newHosts: [Int: Int] = [:]
        var shortfalls: [Int] = []
        var siteOfCluster: [String: String] = [:]
        for c in scope { siteOfCluster[c.id] = siteKey(c) }
        for ci in plan.indices {
            let d = plan[ci].demand, minimum = minHosts(ci)
            guard !fits(members(ci), d, minimum) else { continue }
            guard recommend else { shortfalls.append(ci); continue }
            let major = W.majority(members(ci)), vendor = W.majorityVendor(members(ci))
            if p.flag("rebalance") {
                while !fits(members(ci), d, minimum) {
                    let site = plan[ci].site
                    let pool = hosts.indices.filter { i in
                        hosts[i].released && !hosts[i].isNew && hosts[i].gen.vendor == vendor && siteOfCluster[hosts[i].origin] == site
                    }
                    func rank(_ i: Int) -> (Int, Double, Double, String) {
                        let h = hosts[i]
                        return (h.gen.family == major ? 0 : 1, -h.ramGiB, -h.cores, h.name)
                    }
                    guard let i = pool.min(by: { rank($0) < rank($1) }) else { break }
                    hosts[i].released = false
                    hosts[i].releasedBy = ""
                    hosts[i].fromPool = true
                    hosts[i].cluster = plan[ci].id
                    hosts[i] = W.withMemory([hosts[i]], floor: plan[ci].ramFloor)[0]
                }
            }
            guard !fits(members(ci), d, minimum) else { continue }
            if let k = additions(members(ci), d, minimum, floor: plan[ci].ramFloor), k > 0, var model = W.typical(members(ci)) {
                model = W.withMemory([model], floor: plan[ci].ramFloor)[0]
                for n in 1...k {
                    var h = model
                    h.id = "new|\(plan[ci].id)|\(n)"
                    h.name = "New host \(n) (like \(model.name))"
                    h.origin = ""
                    h.originName = ""
                    h.cluster = plan[ci].id
                    h.isNew = true
                    h.pinned = false
                    h.maintenance = false
                    h.fromPool = false
                    h.movedBy = ""
                    hosts.append(h)
                }
                newHosts[ci] = k
            } else {
                shortfalls.append(ci)
            }
        }

        // MARK: Results

        let planned = hosts.filter { !$0.released }
        let spareHosts = hosts.filter { $0.released }
        let upgraded = planned.filter { $0.upgradedFrom > 0 }
        let addedGiB = upgraded.reduce(0.0) { $0 + ($1.ramGiB * $1.nominalGiB / $1.reportedGiB - $1.upgradedFrom) }
        let newCount = planned.filter(\.isNew).count
        let licToday = todayHosts.reduce(0.0) { $0 + $1.licensed(coreMin) }
        let licPlan = planned.reduce(0.0) { $0 + $1.licensed(coreMin) }
        let nonEmptyPlan = plan.indices.filter { !members($0).isEmpty }

        func cref(_ c: PCluster, _ detail: String = "") -> AffectedObject {
            AffectedObject(kind: c.isMerged ? .other : .cluster, id: c.isMerged ? c.id : c.members[0].id, name: c.name, detail: detail)
        }
        func hostRef(_ h: WHost, _ detail: String) -> AffectedObject {
            AffectedObject(kind: h.isNew ? .other : .host, id: h.id, name: h.name, detail: detail)
        }

        // Override builders for one-click changes.
        func keepSeparate(_ c: Cluster) -> SolutionAction {
            SolutionAction("Keep \(c.name) separate", symbol: "square.split.2x1", help: "Adds it to Keep standalone, so it isn't merged.",
                           set: ["solo": .names(soloNames + [c.id])])
        }
        func unmerge(_ c: PCluster) -> SolutionAction {
            let ids = Set(c.members.map(\.id))
            let rest = mergeNames.filter { e in !PlanEntry.parts(e).contains { resolve($0).map { ids.contains($0.id) } ?? false } }
            return SolutionAction("Unmerge", symbol: "square.split.2x1", help: "Removes this group from Merge these clusters.", set: ["merge": .names(rest)])
        }
        func mergeAction(_ cs: [Cluster], label: String) -> SolutionAction {
            SolutionAction(label, symbol: "square.stack.3d.down.forward", help: "Adds the group to Merge these clusters.",
                           set: ["merge": .names(mergeNames + [PlanEntry.join(cs.map(\.id))])])
        }
        func ramAction(_ c: PCluster, _ size: Double, label: String? = nil) -> SolutionAction {
            let ids = Set(c.members.map(\.id))
            let rest = ramNames.filter { e in resolve(PlanEntry.parts(e)[0]).map { !ids.contains($0.id) } ?? true }
            let text = label ?? (size == 0 ? "Don't upgrade memory" : "Use \(W.ramLabel(size)) per host")
            return SolutionAction(text, symbol: "memorychip", help: "Sets Memory per host for this cluster.",
                                  set: ["ram": .names(size < 0 ? rest : rest + c.members.map { PlanEntry.join([$0.id, String(format: "%g", size)]) })])
        }
        func moveAction(_ entries: [(origin: String, family: String, to: String)], label: String, symbol: String = "arrow.right.square") -> SolutionAction {
            let keys = Set(entries.map { $0.origin + "\n" + $0.family })
            let rest = moveNames.filter { e in
                let parts = PlanEntry.parts(e)
                return parts.count != 3 || !keys.contains((resolve(parts[0])?.id ?? parts[0]) + "\n" + parts[1])
            }
            return SolutionAction(label, symbol: symbol, help: "Sets Move hosts.",
                                  set: ["moves": .names(rest + entries.map { PlanEntry.join([$0.origin, $0.family, $0.to]) })])
        }
        func keepAction(_ hs: [WHost], label: String) -> SolutionAction {
            let pairs = Set(hs.filter { !$0.origin.isEmpty }.map { $0.origin + "\n" + $0.gen.family }).sorted()
            return moveAction(pairs.map { k in
                let parts = PlanEntry.parts(k)
                return (parts[0], parts[1], HostMove.keep)
            }, label: label, symbol: "pin")
        }

        // Today, cluster by cluster.
        var todayRows: [[String]] = []
        var todayRefs: [AffectedObject?] = []
        var shortToday: [String] = []
        var surplusToday = 0
        for c in scope {
            let hs = todayHosts.filter { $0.origin == c.id }
            let d = demandByCluster[c.id] ?? Demand()
            let minimum = minHosts(vsan([c.id]))
            let l = W.load(hs, d, spare: spare)
            let vcpu = (vmsByCluster[c.id] ?? []).filter(\.isRunning).reduce(0) { $0 + $1.cpus }
            let cores = hs.reduce(0.0) { $0 + $1.cores }
            var verdict: String
            if hs.isEmpty {
                verdict = "No host capacity in export"
            } else if !fits(hs, d, minimum) {
                shortToday.append(c.name)
                if hs.count < minimum && l.worst <= maxLoad { verdict = "Below \(minimum) hosts" }
                else if l.mem > maxLoad && l.cpu <= maxLoad { verdict = "Short of memory" + (memoryFix(hs, d, minimum).map { " — \(W.ramLabel($0)) per host fits" } ?? "") }
                else if l.cpu > maxLoad && l.mem <= maxLoad { verdict = "Short of CPU" }
                else { verdict = "Short of CPU and memory" }
            } else {
                let spareN = hs.count - trim(hs.map { var h = $0; h.pinned = false; return h }, d, minimum).kept.count
                surplusToday += spareN
                verdict = d.isEmpty ? "Idle — no running VMs selected" : (spareN > 0 ? "Fits; \(spareN) host\(spareN == 1 ? "" : "s") more than needed" : (l.worst > maxLoad - 0.1 ? "Fits, tight" : "Fits"))
            }
            let role = roleOf(c)
            todayRows.append([c.name, siteName(c), role.label, Fmt.int(hs.count), W.familyMix(hs), W.memoryMix(hs),
                              Fmt.int((vmsByCluster[c.id] ?? []).count), cores > 0 ? Fmt.ratio(Double(vcpu) / cores) : "—",
                              W.pct(l.cpu), W.pct(l.mem), verdict])
            todayRefs.append(AffectedObject(kind: .cluster, id: c.id, name: c.name))
        }

        // Plan changes.
        var changes = CheckBuilder()
        for (ci, c) in plan.enumerated() where c.isMerged {
            let before = c.members.reduce(0) { n, m in n + todayHosts.filter { $0.origin == m.id }.count }
            let saving = mergeSaving(c.members)
            let summary = (c.forced ? "Merged by you. " : "Same datacenter, CPU family and environment. ")
                + (saving > 0 ? "Needs \(saving) host\(saving == 1 ? "" : "s") fewer than apart (one set of failover hosts instead of \(c.members.count))." : "Saves no hosts at these settings.")
                + " \(before) hosts today."
            let actions = c.forced ? [unmerge(c)] : c.members.prefix(3).map(keepSeparate)
            changes.add("merge-\(ci)", "Merges", "Merge \(c.name)", .info, summary, affected: c.members.map { AffectedObject(kind: .cluster, id: $0.id, name: $0.name) },
                        actions: actions)
        }
        for m in alignMoves {
            let hs = hosts.filter { m.ids.contains($0.id) }
            changes.add("align-\(m.from)-\(m.family)", "CPU alignment",
                        "Move \(hs.count) \(CPUFamily.short(m.family)) host\(hs.count == 1 ? "" : "s") from \(plan[m.from].name) to \(plan[m.to].name)",
                        .info, "\(plan[m.from].name) runs mostly \(CPUFamily.label(W.majority(members(m.from)))) and still fits without them; \(plan[m.to].name) runs \(CPUFamily.label(m.family)).",
                        affected: hs.map { hostRef($0, $0.gen.name) }, actions: [keepAction(hs, label: "Keep them in \(plan[m.from].name)")])
        }
        for (ci, c) in plan.enumerated() where c.ramFloor > 0 {
            let up = planned.filter { $0.cluster == c.id && $0.upgradedFrom > 0 }
            guard !up.isEmpty else { continue }
            let gib = up.reduce(0.0) { $0 + ($1.ramGiB * $1.nominalGiB / $1.reportedGiB - $1.upgradedFrom) }
            var actions: [SolutionAction] = []
            if c.ramSetByYou {
                actions.append(ramAction(c, -1, label: "Remove my memory setting"))
            } else {
                actions.append(ramAction(c, 0))
                let next = W.ramSizes.filter { $0 > c.ramFloor && $0 <= maxRAM }.prefix(1)
                actions += next.map { ramAction(c, $0) }
            }
            changes.add("ram-\(ci)", "Memory", "Upgrade \(up.count) host\(up.count == 1 ? "" : "s") in \(c.name) to \(W.ramLabel(c.ramFloor))",
                        .warning, "+\(Fmt.memory(mib: gib * 1024)) in all; " + (c.ramSetByYou ? "set by you." : "\(c.ramReason), and the CPU has room."),
                        affected: up.map { hostRef($0, "\(W.ramLabel($0.upgradedFrom)) → \(W.ramLabel(c.ramFloor))") }, actions: actions)
        }
        let releasedAuto = spareHosts.filter { $0.releasedBy == "not needed" }
        for (origin, hs) in Dictionary(grouping: releasedAuto, by: \.origin).sorted(by: { $0.key < $1.key }) {
            let name = hs[0].originName
            changes.add("release-\(origin)", "Hosts", "Release \(hs.count) host\(hs.count == 1 ? "" : "s") from \(name)", .info,
                        "Not needed at \(SFmt.num(maxLoad * 100))% load \(downText). They go to the spare pool.",
                        affected: hs.map { hostRef($0, "\($0.gen.name), \(W.ramLabel($0.nominalGiB))" + ($0.maintenance ? ", in maintenance mode" : "")) },
                        actions: [keepAction(hs, label: "Keep them in \(name)")])
        }
        let releasedByYou = spareHosts.filter { $0.releasedBy == "you" }
        if !releasedByYou.isEmpty {
            changes.add("release-you", "Hosts", "Release \(releasedByYou.count) host\(releasedByYou.count == 1 ? "" : "s") (set by you)", .info,
                        "They go to the spare pool.", affected: releasedByYou.map { hostRef($0, $0.originName) })
        }
        let movedByYou = planned.filter { $0.movedBy == "you" }
        if !movedByYou.isEmpty {
            changes.add("move-you", "Hosts", "Move \(movedByYou.count) host\(movedByYou.count == 1 ? "" : "s") (set by you)", .info,
                        "As set under Move hosts.", affected: movedByYou.map { h in hostRef(h, "\(h.originName) → \(plan.first { $0.id == h.cluster }?.name ?? "")") })
        }
        let pooled = planned.filter(\.fromPool)
        for (cid, hs) in Dictionary(grouping: pooled, by: \.cluster).sorted(by: { $0.key < $1.key }) {
            guard let c = plan.first(where: { $0.id == cid }) else { continue }
            changes.add("pool-\(cid)", "Hosts", "Reuse \(hs.count) spare host\(hs.count == 1 ? "" : "s") in \(c.name)", .info,
                        "\(c.name) is short without them; they were released elsewhere in the same datacenter.",
                        affected: hs.map { hostRef($0, "from \($0.originName), \($0.gen.name)") }, actions: [keepAction(hs, label: "Keep them where they are")])
        }
        for (ci, k) in newHosts.sorted(by: { $0.key < $1.key }) {
            let c = plan[ci]
            let model = planned.first { $0.cluster == c.id && $0.isNew }
            var actions: [SolutionAction] = []
            let existing = members(ci).filter { !$0.isNew }
            if let s = memoryFix(existing, c.demand, minHosts(ci)) { actions.append(ramAction(c, s, label: "Upgrade memory to \(W.ramLabel(s)) instead")) }
            changes.add("new-\(ci)", "Hosts", "Add \(k) new host\(k == 1 ? "" : "s") to \(c.name)", .warning,
                        "Short at \(SFmt.num(maxLoad * 100))% load \(downText), with no spare host of its CPU vendor in the datacenter. Sized like \(model.map { "\(Int($0.cores)) cores, \(W.ramLabel($0.ramGiB.rounded()))" } ?? "its typical host").",
                        affected: [cref(c)], actions: actions)
        }
        if changes.checks.isEmpty {
            changes.add("none", "Plan", recommend ? "No changes recommended" : "No overrides set", .ready,
                        recommend ? "Every cluster fits and none can give up hosts or merge at these settings." : "Validating today's layout as it is.")
        }

        // Merges that weren't made, for what-ifs.
        var candidates: [(a: Cluster, b: Cluster, saving: Int, why: String)] = []
        let singles = plan.filter { !$0.isMerged && !$0.vms.isEmpty && ![.recovery, .management].contains($0.role) }.map { $0.members[0] }
        if singles.count <= 60 {
            for i in singles.indices {
                for j in singles.indices where j > i {
                    let a = singles[i], b = singles[j]
                    guard siteKey(a) == siteKey(b), clusterVendor(a) == clusterVendor(b), !clusterVendor(a).isEmpty else { continue }
                    let s = mergeSaving([a, b])
                    guard s > 0 else { continue }
                    var why: [String] = []
                    if soloIDs.contains(a.id) || soloIDs.contains(b.id) { why.append("kept standalone") }
                    for c in [a, b] where roleOf(c) != .general { why.append("\(c.name) looks like \(roleOf(c).phrase)") }
                    if W.environment(a.name) != W.environment(b.name) { why.append("different environments") }
                    if clusterFamily(a) != clusterFamily(b) { why.append("different CPU families, so EVC would apply") }
                    if !recommend || !p.flag("autoMerge") { why.append("recommended merges are off") }
                    candidates.append((a, b, s, why.isEmpty ? "too large together" : why.joined(separator: "; ")))
                }
            }
        }
        candidates.sort { ($1.saving, $0.a.name) < ($0.saving, $1.a.name) }
        var opportunities = CheckBuilder()
        for (k, c) in candidates.prefix(8).enumerated() {
            opportunities.add("candidate-\(k)", "Other merges", "\(c.a.name) + \(c.b.name)", .info,
                              "Would need \(c.saving) host\(c.saving == 1 ? "" : "s") fewer. Not recommended: \(c.why).",
                              affected: [AffectedObject(kind: .cluster, id: c.a.id, name: c.a.name), AffectedObject(kind: .cluster, id: c.b.id, name: c.b.name)],
                              actions: [mergeAction([c.a, c.b], label: "Merge")])
        }

        // Validation of the planned clusters.
        var v = CheckBuilder()
        var evcRows: [String: String] = [:]
        for ci in nonEmptyPlan {
            let c = plan[ci]
            let hs = members(ci)
            let real = hs.filter { !$0.isNew }
            let l = W.load(hs, c.demand, spare: spare)
            let vendors = Set(hs.map(\.gen.vendor)).subtracting([""])
            if vendors.count > 1 {
                v.add("vendor-\(ci)", "CPU", "\(c.name) mixes Intel and AMD", .blocker, "vMotion can't move a running VM between CPU vendors, and EVC can't bridge them.",
                      remediation: "Keep Intel and AMD hosts in separate clusters.", affected: [cref(c)])
            }
            let gens = Set(real.map(\.gen.evc)).subtracting([""])
            if vendors.count == 1, gens.count > 1, let base = real.filter({ !$0.gen.evc.isEmpty }).min(by: { $0.gen.rank < $1.gen.rank })?.gen {
                let current = Set(real.map { $0.evcCurrent.lowercased() })
                let currentRanks = current.compactMap { CPUBaseline.fromEVC($0)?.rank }
                let covered = !current.contains("") && !current.contains("disabled") && currentRanks.count == current.count && (currentRanks.max() ?? 99) <= base.rank
                evcRows[c.id] = covered ? base.evc : "set " + base.evc
                let families = Set(real.map(\.gen.family))
                let block = alignBlocks.first { $0.cluster == ci }
                var actions: [SolutionAction] = []
                if let block, let t = block.target {
                    let movers = real.filter { $0.gen.family == block.family }
                    let origins = Set(movers.map(\.origin)).sorted()
                    let dest = plan[t].members[0].id
                    actions.append(moveAction(origins.map { ($0, block.family, dest) },
                                              label: "Move the \(CPUFamily.short(block.family)) hosts to \(plan[t].name)"))
                }
                let mix = W.familyMix(real)
                if covered {
                    if families.count > 1 { v.add("evc-\(ci)", "CPU", "\(c.name) runs EVC \(base.evc)", families.count > 1 ? .info : .ready,
                          "Mixed CPU families (\(mix)) under an EVC mode that covers them.", affected: [cref(c)], actions: actions) }
                } else {
                    let why = block.map { $0.reason.isEmpty ? "" : " The \(CPUFamily.short($0.family)) hosts weren't moved: \($0.reason)." } ?? ""
                    v.add("evc-\(ci)", "CPU", "Set EVC to \(base.evc) on \(c.name)", families.count > 1 ? .warning : .info,
                          "Its hosts span \(Set(real.map(\.gen.name)).sorted().joined(separator: ", ")) (\(mix)), and EVC "
                            + (current.contains("") || current.contains("disabled") ? "is off on some or all of them" : "is set above the oldest host") + ", so vMotion can fail between them.\(why)",
                          remediation: "EVC at \(base.name) hides newer CPU features from VMs; a VM picks up the lower mode at its next power cycle. Or keep each CPU family in its own cluster.",
                          affected: [cref(c)], actions: actions)
                }
            }
            if l.worst > maxLoad || hs.count < minHosts(ci) {
                let fix = memoryFix(hs, c.demand, minHosts(ci))
                v.add("short-\(ci)", "Capacity", "\(c.name) is short", recommend ? .blocker : .warning,
                      "\(SFmt.num((l.cpu * 100).rounded()))% CPU and \(SFmt.num((l.mem * 100).rounded()))% memory \(downText), above \(SFmt.num(maxLoad * 100))%"
                        + (hs.count < minHosts(ci) ? ", and fewer than \(minHosts(ci)) hosts" : "") + ".",
                      remediation: fix.map { "Upgrading to \(W.ramLabel($0)) per host fits." } ?? (recommend ? "Allow more memory per host, or add hosts." : "Switch Plan to Recommended to see the hosts or memory it needs."),
                      affected: [cref(c)], actions: fix.map { [ramAction(c, $0, label: "Upgrade to \(W.ramLabel($0))")] } ?? [])
            }
            if hs.count > maxHosts {
                v.add("max-\(ci)", "Capacity", "\(c.name) has \(hs.count) hosts", .blocker, "More than \(maxHosts) hosts per cluster.",
                      remediation: "Split the merge.", affected: [cref(c)], actions: c.forced ? [unmerge(c)] : [])
            }
            let cores = hs.reduce(0.0) { $0 + $1.cores }
            let vcpu = c.vms.filter(\.isRunning).reduce(0) { $0 + $1.cpus }
            if cores > 0 && Double(vcpu) / cores > ratio {
                v.add("ratio-\(ci)", "Capacity", "\(c.name) at \(Fmt.ratio(Double(vcpu) / cores)) vCPU per core", .warning,
                      "Above the \(Fmt.ratio(ratio)) set under Capacity. Watch CPU ready time.", affected: [cref(c)])
            }
            if let smallest = hs.min(by: { ($0.threads, $0.ramGiB) < ($1.threads, $1.ramGiB) }) {
                let minRAM = hs.map(\.ramGiB).min() ?? 0, minThreads = hs.map(\.threads).min() ?? 0
                let big = c.vms.filter { $0.cpus > minThreads || $0.memoryMiB / 1024 > minRAM }
                if !big.isEmpty {
                    v.list("bigvm-\(ci)", "Capacity", "VMs larger than \(c.name)'s smallest host", .warning, noun: "VMs",
                           affected: big.map { $0.ref("\($0.cpus) vCPU, \(Fmt.memory(mib: $0.memoryMiB))") }, ready: "",
                           remediation: "\(smallest.name) has \(minThreads) threads and \(W.ramLabel(minRAM.rounded())). DRS can't place these VMs on it; size the hosts for them or keep them on larger hosts with a rule.")
                }
            }
            if c.isMerged {
                let sites = Set(c.members.map(siteKey))
                if sites.count > 1 {
                    v.add("site-\(ci)", "Merge", "\(c.name) spans datacenters or vCenters", .warning, c.siteName,
                          remediation: "A cluster lives in one datacenter of one vCenter: hosts must be moved and VMs migrated across. Confirm the sites are really one location.",
                          affected: [cref(c)], actions: c.forced ? [unmerge(c)] : [])
                }
                let memberIDs = c.members.map(\.id)
                let mapped = memberIDs.allSatisfy { id in inv.datastores.contains { $0.clusterKeys.contains(id) } }
                let shared = inv.datastores.contains { d in !d.isLocal && memberIDs.allSatisfy { d.clusterKeys.contains($0) } }
                if !mapped {
                    v.add("storage-\(ci)", "Merge", "Check storage for \(c.name)", .info,
                          "The export doesn't show which hosts mount which datastores (vDatastore without its Hosts column).",
                          remediation: "Confirm every merged host can reach the datastores, or plan Storage vMotion.", affected: [cref(c)])
                } else if !shared {
                    v.add("storage-\(ci)", "Merge", "No datastore shared by every cluster in \(c.name)", .warning,
                          "Each cluster sees its own storage today.",
                          remediation: "Present the datastores to all the merged hosts (zoning, masking, NFS exports), or Storage vMotion the VMs first.", affected: [cref(c)])
                }
                if c.vsan {
                    v.add("vsan-\(ci)", "Merge", "\(c.name) includes vSAN", .warning, "vSAN datastores belong to their cluster.",
                          remediation: "Plan how the vSAN data moves: evacuate to shared storage, or rebuild the merged cluster's vSAN as hosts join.", affected: [cref(c)])
                }
            }
            let esx = Set(real.map(\.esx))
            if esx.count > 1 {
                v.add("esx-\(ci)", "Lifecycle", "\(c.name) runs \(esx.count) ESXi versions", .info, esx.sorted().joined(separator: ", "),
                      remediation: "Bring the hosts to one version and image before or as they join.", affected: [cref(c)])
            }
            if !c.isMerged && c.vms.isEmpty && (allVMsByCluster[c.members[0].id] ?? []).isEmpty && !real.isEmpty {
                v.add("idle-\(ci)", "Hosts", "\(c.name) runs no VMs", .info,
                      "\(real.count) host\(real.count == 1 ? "" : "s") with nothing on them" + (c.role == .recovery ? ", likely held for recovery." : "."),
                      remediation: "If it isn't reserved for failover or recovery, release its hosts to the spare pool.", affected: [cref(c)],
                      actions: [moveAction([(c.members[0].id, HostMove.all, HostMove.release)], label: "Release all its hosts", symbol: "tray.and.arrow.up")])
            }
            let maint = real.filter(\.maintenance)
            if !maint.isEmpty {
                v.list("maint-\(ci)", "Hosts", "Hosts in maintenance mode in \(c.name)", .info, noun: "hosts",
                       affected: maint.map { hostRef($0, "") }, ready: "", remediation: "They count as capacity. Check whether they're failing or being retired.")
            }
        }
        if !unknownHosts.isEmpty {
            v.list("unknown-hosts", "Hosts", "Hosts without cores or memory in the export", .warning, noun: "hosts",
                   affected: unknownHosts.map { $0.ref($0.cluster) }, ready: "", remediation: "They aren't counted. Include the vHost tab.")
        }
        let unknownCPU = planned.filter { $0.gen.family == CPUFamily.unknown && !$0.isNew }
        if !unknownCPU.isEmpty {
            v.list("unknown-cpu", "CPU", "Hosts whose CPU family isn't recognised", .info, noun: "hosts",
                   affected: unknownCPU.map { hostRef($0, "") }, ready: "", remediation: "They're left out of CPU alignment and EVC suggestions.")
        }
        for name in soloInMerge {
            v.add("solo-merge-\(name)", "Merge", "\(name) is kept standalone", .info, "It's also in a merge group, and was left out of it.",
                  remediation: "Remove it from Keep standalone to merge it.")
        }

        func currentEVC(_ hs: [WHost]) -> String {
            let modes = Set(hs.filter { !$0.isNew }.map { $0.evcCurrent.lowercased() })
            if modes.isEmpty { return "—" }
            if modes.contains("") || modes.contains("disabled") { return modes.count == 1 ? "off" : "mixed" }
            return modes.count == 1 ? modes.first! : "mixed"
        }

        // Planned clusters.
        var planRows: [[String]] = []
        var planRefs: [AffectedObject?] = []
        var planActions: [[SolutionAction]] = []
        var worst: (load: Double, what: String) = (0, "")
        for ci in nonEmptyPlan {
            let c = plan[ci]
            let hs = members(ci)
            let before = c.members.reduce(0) { n, m in n + todayHosts.filter { $0.origin == m.id }.count }
            let l = W.load(hs, c.demand, spare: spare)
            if l.worst > worst.load { worst = (l.worst, "\(l.mem >= l.cpu ? "memory" : "CPU") · \(c.name)") }
            let cores = hs.reduce(0.0) { $0 + $1.cores }
            let vcpu = c.vms.filter(\.isRunning).reduce(0) { $0 + $1.cpus }
            var what: [String] = []
            if c.isMerged { what.append(c.forced ? "merged by you" : "merged") }
            let movedIn = hs.filter { h in !h.isNew && !c.members.contains { $0.id == h.origin } }.count
            let movedOut = hosts.filter { h in c.members.contains { $0.id == h.origin } && !h.released && h.cluster != c.id }.count
            let releasedN = spareHosts.filter { h in c.members.contains { $0.id == h.origin } }.count
            if movedIn > 0 { what.append("+\(movedIn) moved in") }
            if movedOut > 0 { what.append("−\(movedOut) moved out") }
            if releasedN > 0 { what.append("−\(releasedN) released") }
            if let k = newHosts[ci] { what.append("+\(k) new") }
            let up = hs.filter { $0.upgradedFrom > 0 }.count
            if up > 0 { what.append("\(up) memory upgrade\(up == 1 ? "" : "s")") }
            if c.solo { what.append("kept standalone") }
            planRows.append([c.name, c.role.label, "\(before) → \(hs.count)", W.familyMix(hs), W.memoryMix(hs),
                             W.pct(l.cpu), W.pct(l.mem), cores > 0 ? Fmt.ratio(Double(vcpu) / cores) : "—",
                             evcRows[c.id] ?? currentEVC(hs), what.isEmpty ? "No change" : what.joined(separator: ", ")])
            planRefs.append(cref(c))
            planActions.append(c.isMerged ? (c.forced ? [unmerge(c)] : []) : [])
        }

        // Host changes.
        var hostRows: [[String]] = []
        var hostRefs: [AffectedObject?] = []
        let planName = Dictionary(plan.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for h in hosts.sorted(by: { ($0.originName, $0.name) < ($1.originName, $1.name) }) {
            var change: [String] = []
            let inPlan = h.released ? "Spare pool" : (planName[h.cluster] ?? "")
            if h.isNew { change.append("new") }
            if h.released { change.append(h.releasedBy == "you" ? "released by you" : "released, not needed") }
            if h.fromPool { change.append("reused spare") }
            if !h.movedBy.isEmpty && !h.fromPool { change.append(h.movedBy == "you" ? "moved by you" : "moved for CPU alignment") }
            if h.upgradedFrom > 0 { change.append("memory upgrade") }
            if !h.released && !h.isNew && planIDOf[h.origin] != h.cluster && h.movedBy.isEmpty && !h.fromPool { change.append("moved") }
            guard !change.isEmpty else { continue }
            let mem = h.upgradedFrom > 0 ? "\(W.ramLabel(h.upgradedFrom)) → \(W.ramLabel((h.ramGiB * h.nominalGiB / h.reportedGiB).rounded()))" : W.ramLabel(h.nominalGiB)
            hostRows.append([h.name, h.isNew ? "—" : h.originName, inPlan, change.joined(separator: ", "), "\(h.gen.name), \(Int(h.cores)) cores", mem])
            hostRefs.append(hostRef(h, ""))
        }

        // Summary.
        let clustersToday = scope.count, clustersPlan = nonEmptyPlan.count
        var metrics: [SolutionMetric] = [
            SolutionMetric("Clusters", clustersToday == clustersPlan ? Fmt.int(clustersToday) : "\(clustersToday) → \(clustersPlan)",
                           plan.filter(\.isMerged).isEmpty ? "no merges" : "\(plan.filter(\.isMerged).count) merge\(plan.filter(\.isMerged).count == 1 ? "" : "s")",
                           symbol: "square.stack.3d.up"),
            SolutionMetric("Hosts", "\(todayHosts.count) → \(planned.count)",
                           [spareHosts.isEmpty ? nil : "\(spareHosts.count) to the spare pool", newCount > 0 ? "\(newCount) new" : nil].compactMap { $0 }.joined(separator: ", ").ifEmpty("no change"),
                           symbol: "server.rack", status: newCount > 0 ? .warning : nil),
            SolutionMetric("Memory upgrades", upgraded.isEmpty ? "None" : "\(upgraded.count) host\(upgraded.count == 1 ? "" : "s")",
                           upgraded.isEmpty ? "no cluster needs more memory" : "+\(Fmt.memory(mib: addedGiB * 1024)) in all", symbol: "memorychip",
                           status: upgraded.isEmpty ? nil : .warning),
            SolutionMetric("Licensed cores", licToday == licPlan ? Fmt.int(Int(licToday)) : "\(Fmt.int(Int(licToday))) → \(Fmt.int(Int(licPlan)))",
                           "at \(SFmt.num(coreMin)) cores minimum per CPU", symbol: "checkmark.seal"),
            SolutionMetric("Short today", shortToday.isEmpty ? "None" : "\(shortToday.count) cluster\(shortToday.count == 1 ? "" : "s")",
                           shortToday.isEmpty ? "every cluster fits \(downText)" : shortToday.prefix(3).joined(separator: ", ") + (shortToday.count > 3 ? "…" : ""),
                           symbol: "exclamationmark.triangle", status: shortToday.isEmpty ? nil : .warning),
            SolutionMetric("Busiest planned cluster", W.pct(worst.load), worst.what.isEmpty ? downText : "\(worst.what), \(downText)", symbol: "gauge.with.dots.needle.67percent",
                           status: worst.load > maxLoad ? .blocker : nil),
        ]

        let headline: String
        if recommend {
            var parts: [String] = []
            if clustersPlan != clustersToday { parts.append("\(clustersToday) clusters → \(clustersPlan)") }
            if !spareHosts.isEmpty { parts.append("\(spareHosts.count) host\(spareHosts.count == 1 ? "" : "s") released") }
            if newCount > 0 { parts.append("\(newCount) new host\(newCount == 1 ? "" : "s") needed") }
            if !upgraded.isEmpty { parts.append("memory added to \(upgraded.count) host\(upgraded.count == 1 ? "" : "s") (+\(Fmt.memory(mib: addedGiB * 1024)))") }
            headline = "\(todayHosts.count) hosts in \(clustersToday) clusters: " + (parts.isEmpty ? "no changes needed" : parts.joined(separator: ", "))
                + (shortfalls.isEmpty ? "" : "; \(shortfalls.count) cluster\(shortfalls.count == 1 ? "" : "s") still short")
        } else {
            headline = shortToday.isEmpty
                ? "All \(clustersToday) clusters fit \(downText)" + (surplusToday > 0 ? "; \(surplusToday) hosts more than needed" : "")
                : "\(shortToday.count) of \(clustersToday) clusters are short \(downText): \(shortToday.prefix(4).joined(separator: ", "))"
        }

        var method = [
            "Workload clusters only. The VCF management domain is assumed to run on other clusters already, so no management appliances are sized here.",
            measured ? "Demand is measured host CPU and memory use (vHost), scaled to the selected VMs' share, plus \(SFmt.num((growth - 1) * 100))% growth. It stays with its cluster when hosts move or merge."
                : "Demand is the selected powered-on VMs' vCPU at \(Fmt.ratio(ratio)) and their memory at \(SFmt.num(memRatio * 100))% of physical, plus \(SFmt.num((growth - 1) * 100))% growth.",
            "A cluster fits when CPU and memory stay at or below \(SFmt.num(maxLoad * 100))% \(downText) (the largest hosts out), with at least \(minHostsParam) hosts (3 on vSAN).",
            "CPU families come from each host's highest EVC mode, or its CPU model. Skylake and Cascade Lake are one family (Xeon Scalable 1st–2nd gen), as are Sapphire and Emerald Rapids.",
            "Roles and environments are guessed from cluster names; use the overrides when a guess is wrong.",
            "Memory sizes are nominal (a host reporting 766.7 GiB has 768 GiB installed). Upgrades assume every host can reach the new size; check DIMM slots and the vendor's population rules.",
        ]
        if !basisFallback.isEmpty { method.append("No host usage for \(basisFallback.joined(separator: ", ")): sized from configured vCPU and memory.") }
        if !mgmtLeftOut.isEmpty {
            method.append("Left out as management clusters: \(mgmtLeftOut.map(\.name).joined(separator: ", ")). Turn on Include management clusters to plan them too.")
        }
        if !outsideVMs.isEmpty { method.append("\(outsideVMs.count) selected VMs run outside a cluster in scope (standalone hosts) and aren't planned.") }
        method += notes

        var sections: [SolutionSection] = [.metrics("Summary", metrics)]
        sections.append(.table(SolutionTable(id: "today", title: "Today", subtitle: "Load is CPU and memory \(downText), against \(SFmt.num(maxLoad * 100))%.",
                                             columns: ["Cluster", "Datacenter", "Role", "Hosts", "CPU", "Memory per host", "VMs", "vCPU:core", "CPU", "Memory", "Verdict"],
                                             numeric: [3, 6, 7, 8, 9], rows: todayRows, rowRefs: todayRefs)))
        sections.append(.checks(recommend ? "Plan changes" : "Your overrides", changes.checks,
                                subtitle: "Each change can be undone here; it's then kept as an override under Assumptions."))
        sections.append(.table(SolutionTable(id: "plan", title: "Planned clusters", subtitle: "Load \(downText), against \(SFmt.num(maxLoad * 100))%.",
                                             columns: ["Cluster", "Role", "Hosts", "CPU", "Memory per host", "CPU", "Memory", "vCPU:core", "EVC", "Changes"],
                                             numeric: [5, 6, 7], rows: planRows, rowRefs: planRefs, rowActions: planActions)))
        sections.append(.checks("Validation", v.checks.isEmpty ? [SolutionCheck(id: "ok", area: "Plan", title: "No issues found", status: .ready, summary: "The planned clusters pass every check.", remediation: "", affected: [])] : v.checks))
        if !opportunities.checks.isEmpty {
            sections.append(.checks("Other merges to try", opportunities.checks, subtitle: "Pairs in the same datacenter that would need fewer hosts together, but weren't recommended."))
        }
        if !hostRows.isEmpty {
            sections.append(.table(SolutionTable(id: "hosts", title: "Host changes", columns: ["Host", "Today in", "Planned", "Change", "CPU", "Memory"],
                                                 rows: hostRows, rowRefs: hostRefs)))
        }
        sections.append(.notes("Method", method))
        return SolutionResult(headline: headline, sections: sections)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
