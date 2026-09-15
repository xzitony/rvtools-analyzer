import Foundation

/// Host-based replication DR sizing: target compute (hosts), storage (replicas + point-in-time history),
/// replication bandwidth vs RPO, initial seeding, DR network mapping and replication blockers.
public struct DisasterRecoverySizing: Solution {
    public init() {}
    public var id: String { "dr" }
    public var title: String { "DR Sizing" }
    public var symbol: String { "arrow.triangle.2.circlepath.circle" }
    public var summary: String { "DR site compute, storage and replication bandwidth for the selected VMs." }

    public var parameters: [SolutionParameter] { [
        .choice("basis", "Replicated data", "Size replicas from", ["VM in-use (thin at target)", "Provisioned (thick at target)"]),
        .number("change", "Replicated data", "Daily change rate", 3, min: 0.1, max: 50, step: 0.5, unit: "%"),
        .number("growth", "Replicated data", "Annual growth", 10, min: 0, max: 100, unit: "%"),
        .number("years", "Replicated data", "Sizing horizon", 3, min: 0, max: 10, unit: "years"),
        .number("journal", "DR storage", "Point-in-time history", 24, min: 0, max: 720, unit: "hours",
                help: "Journal / multiple point-in-time copies kept at the DR site."),
        .number("storHeadroom", "DR storage", "Storage headroom", 20, min: 0, max: 100, unit: "%"),
        .number("rpo", "Replication network", "Target RPO", 15, min: 1, max: 1440, unit: "minutes"),
        .number("peak", "Replication network", "Peak-to-average change", 2.5, min: 1, max: 10, step: 0.1, unit: "×",
                help: "Change is bursty; the link must absorb peak change to hold the RPO."),
        .number("wan", "Replication network", "WAN compression", 1.6, min: 1, max: 10, step: 0.1, unit: ": 1"),
        .number("link", "Replication network", "WAN link", 1000, min: 10, max: 100_000, step: 100, unit: "Mbps"),
        .number("linkUse", "Replication network", "Usable share of the link", 70, min: 10, max: 100, unit: "%"),
        .number("ratio", "DR compute", "vCPU : pCore at DR", 4, min: 0.5, max: 20, step: 0.5, unit: ": 1"),
        .number("memOver", "DR compute", "vRAM : physical RAM", 1, min: 0.5, max: 4, step: 0.1, unit: ": 1"),
        .number("memUtil", "DR compute", "Max host memory utilization", 85, min: 30, max: 100, unit: "%"),
        .toggle("offCompute", "DR compute", "Reserve compute for powered-off VMs", false,
                help: "Powered-off VMs are always replicated; turn this on if they must also be recoverable at DR."),
        .number("hostCores", "DR host specification", "Cores per host", 64, min: 4, max: 512),
        .number("hostMem", "DR host specification", "Memory per host", 1024, min: 64, max: 12_288, step: 64, unit: "GiB"),
        .number("hostStor", "DR host specification", "Usable storage per host", 0, min: 0, max: 500, unit: "TiB",
                help: "0 = external array; otherwise hosts are also sized for storage (e.g. vSAN)."),
        .number("spare", "DR host specification", "Spare hosts (N+x)", 1, min: 0, max: 10),
    ] }

    public func defaultSelection(_ inventory: Inventory) -> Set<String> {
        Set(inventory.vms.filter { $0.isVM && $0.isRunning }.map(\.id))
    }

    func replicated(_ vm: VM, basis: Int) -> Double {
        basis == 0 ? vm.inUseExcludingSwapMiB : (vm.diskCapacityMiB > 0 ? vm.diskCapacityMiB : vm.provisionedMiB)
    }

    public func run(vms: [VM], inventory inv: Inventory, params p: Params) -> SolutionResult {
        let basis = p.choice("basis")
        let c = p.num("change") / 100
        let years = p.num("years")
        let growth = pow(1 + p.num("growth") / 100, years)
        let ratio = max(p.num("ratio"), 0.1), memOver = max(p.num("memOver"), 0.1), memUtil = max(p.num("memUtil"), 1) / 100
        let hostCores = max(p.num("hostCores"), 1), hostMemMiB = max(p.num("hostMem"), 1) * 1024
        let hostStorMiB = p.num("hostStor") * 1024 * 1024
        let spare = p.num("spare")
        let wan = max(p.num("wan"), 1), usable = max(p.num("link"), 1) * p.num("linkUse") / 100
        let rpoMin = p.num("rpo"), peak = max(p.num("peak"), 1)
        let journalHours = p.num("journal"), storHead = p.num("storHeadroom") / 100

        let computeVMs = p.flag("offCompute") ? vms.filter { !$0.isTemplate } : vms.filter(\.isRunning)
        let vcpu = Double(computeVMs.reduce(0) { $0 + $1.cpus }) * growth
        let vram = computeVMs.reduce(0) { $0 + $1.memoryMiB } * growth
        let pcores = vcpu / ratio
        let hostsCPU = (pcores / hostCores).rounded(.up)
        let ramNeeded = vram / memOver / memUtil
        let hostsMem = (ramNeeded / hostMemMiB).rounded(.up)

        let used = vms.reduce(0) { $0 + $1.inUseExcludingSwapMiB }
        let replica = vms.reduce(0) { $0 + replicated($1, basis: basis) }
        let journal = used * c * journalHours / 24
        let storageBase = replica * growth + journal
        let storage = storageBase * (1 + storHead)
        let hostsStor = hostStorMiB > 0 ? (storage / hostStorMiB).rounded(.up) : 0
        let required = max(hostsCPU, hostsMem, hostsStor, vms.isEmpty ? 0 : 1)
        let recommended = required + (vms.isEmpty ? 0 : spare)
        let binding = required == hostsCPU ? "CPU" : (required == hostsMem ? "memory" : "storage")

        let dailyChange = used * c
        let avgMbps = dailyChange * mibToMegabits / 86_400 / wan
        let peakMbps = avgMbps * peak
        let seedHours = replica * mibToMegabits / wan / usable / 3600
        let rpoHolds = peakMbps <= usable

        var sections: [SolutionSection] = [
            .metrics("Summary", [
                SolutionMetric("VMs protected", Fmt.int(vms.count), "\(computeVMs.count) counted for DR compute", symbol: "desktopcomputer"),
                SolutionMetric("Compute to recover", "\(Fmt.int(Int(vcpu))) vCPU", "\(Fmt.memory(mib: vram)) vRAM (incl. growth)", symbol: "cpu"),
                SolutionMetric("DR hosts", Fmt.int(Int(recommended)), "\(Int(required)) required (\(binding)-bound) + \(Int(spare)) spare", symbol: "server.rack"),
                SolutionMetric("DR storage", Fmt.capacity(mib: storage), "replicas, \(SFmt.num(journalHours))h history, headroom", symbol: "externaldrive"),
                SolutionMetric("Replication bandwidth", Fmt.rate(mbps: avgMbps), "peak \(Fmt.rate(mbps: peakMbps)) · usable link \(Fmt.rate(mbps: usable))",
                               symbol: rpoHolds ? "network" : Severity.warning.symbol),
                SolutionMetric("Initial seed", SFmt.duration(hours: seedHours), "\(Fmt.capacity(mib: replica)) over \(Fmt.rate(mbps: usable))", symbol: "clock"),
            ]),
        ]

        var computeRows: [[String]] = [
            ["CPU", "\(Fmt.int(Int(vcpu))) vCPU → \(Fmt.int(Int(pcores.rounded(.up)))) cores at \(SFmt.num(ratio)):1", "\(Fmt.int(Int(hostCores))) cores", Fmt.int(Int(hostsCPU))],
            ["Memory", "\(Fmt.memory(mib: vram)) vRAM → \(Fmt.memory(mib: ramNeeded)) RAM", "\(Fmt.memory(mib: hostMemMiB)) at \(SFmt.num(memUtil * 100))%", Fmt.int(Int(hostsMem))],
        ]
        if hostStorMiB > 0 { computeRows.append(["Storage", Fmt.capacity(mib: storage), Fmt.capacity(mib: hostStorMiB), Fmt.int(Int(hostsStor))]) }
        computeRows.append(["Required", "\(binding)-bound", "", Fmt.int(Int(required))])
        computeRows.append(["Recommended (N+\(Int(spare)))", "", "", Fmt.int(Int(recommended))])
        sections.append(.table(SolutionTable(id: "compute", title: "DR compute sizing", subtitle: "Demand includes \(SFmt.num(p.num("growth")))% annual growth over \(SFmt.num(years)) years",
                                             columns: ["Constraint", "Demand", "Per host", "Hosts"], numeric: [3], rows: computeRows,
                                             emphasized: [computeRows.count - 1])))

        sections.append(.table(SolutionTable(id: "storage", title: "DR storage", columns: ["Component", "Capacity"], numeric: [1], rows: [
            ["Replicas today (\(basis == 0 ? "in-use, thin" : "provisioned, thick"))", Fmt.capacity(mib: replica)],
            ["Replicas in \(SFmt.num(years)) years", Fmt.capacity(mib: replica * growth)],
            ["Point-in-time history (\(SFmt.num(journalHours)) h)", Fmt.capacity(mib: journal)],
            ["Headroom (\(SFmt.num(storHead * 100))%)", Fmt.capacity(mib: storageBase * storHead)],
            ["Total DR storage", Fmt.capacity(mib: storage)],
        ], emphasized: [4])))

        sections.append(.table(SolutionTable(id: "network", title: "Replication network", columns: ["Metric", "Value"], numeric: [1], rows: [
            ["Changed data per day", Fmt.capacity(mib: dailyChange)],
            ["Average after \(SFmt.num(wan)):1 compression", Fmt.rate(mbps: avgMbps)],
            ["Peak (\(SFmt.num(peak))× average)", Fmt.rate(mbps: peakMbps)],
            ["Usable link (\(SFmt.num(p.num("linkUse")))% of \(Fmt.rate(mbps: p.num("link"))))", Fmt.rate(mbps: usable)],
            ["Link needed to hold a \(SFmt.num(rpoMin))-min RPO at peak", Fmt.rate(mbps: peakMbps / max(p.num("linkUse") / 100, 0.01))],
            ["Initial seed over the WAN", SFmt.duration(hours: seedHours)],
        ])))

        // DR network mapping: every port group the selected VMs use, with VLANs and observed subnets.
        var nets: [String: (vcenter: String, vms: Set<String>, subnets: Set<String>)] = [:]
        for vm in vms {
            for n in vm.nics where !n.network.isEmpty {
                let k = vm.vcenter.lowercased() + "|" + n.network
                var e = nets[k] ?? (vm.vcenter, [], [])
                e.vms.insert(vm.id)
                for ip in n.ipv4 { let o = ip.split(separator: "."); if o.count == 4 { e.subnets.insert(o[0...2].joined(separator: ".") + ".0/24") } }
                nets[k] = e
            }
        }
        let pgByID = Dictionary(inv.portGroups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let netRows = nets.sorted { $0.value.vms.count > $1.value.vms.count }
        let subnetTotal = Set(nets.values.flatMap(\.subnets)).count
        sections.append(.table(SolutionTable(
            id: "network-mapping", title: "Network mapping at DR", subtitle: "Port groups to recreate or map at the DR site (\(netRows.count) networks, \(subnetTotal) /24 subnets in use)",
            columns: ["Port group", "Type", "VLAN", "VMs", "Subnets seen"], numeric: [3],
            rows: netRows.map { k, e in
                let name = String(k.split(separator: "|", maxSplits: 1).last ?? "")
                let pg = pgByID[k.lowercased()]
                return [name, pg?.kind ?? "—", pg?.vlanList ?? "—", Fmt.int(e.vms.count), e.subnets.sorted().prefix(6).joined(separator: ", ")]
            },
            rowRefs: netRows.map { k, _ in pgByID[k.lowercased()].map { AffectedObject(kind: .network, id: $0.id, name: $0.name) } })))

        // By source cluster
        var byCluster: [String: (vms: Int, vcpu: Int, vram: Double, stor: Double, change: Double)] = [:]
        for vm in vms {
            let cn = clusterName(inv, vm)
            var e = byCluster[cn] ?? (0, 0, 0, 0, 0)
            e.vms += 1; e.vcpu += vm.cpus; e.vram += vm.memoryMiB; e.stor += replicated(vm, basis: basis); e.change += vm.inUseExcludingSwapMiB * c
            byCluster[cn] = e
        }
        let clusterRows = byCluster.sorted { $0.value.stor > $1.value.stor }
        sections.append(.table(SolutionTable(id: "by-cluster", title: "By source cluster", columns: ["Cluster", "VMs", "vCPU", "vRAM", "Replicated", "Change / day", "Avg bandwidth"],
                                             numeric: [1, 2, 3, 4, 5, 6], rows: clusterRows.map { k, e in
                                                 [k, Fmt.int(e.vms), Fmt.int(e.vcpu), Fmt.memory(mib: e.vram), Fmt.capacity(mib: e.stor), Fmt.capacity(mib: e.change),
                                                  Fmt.rate(mbps: e.change * mibToMegabits / 86_400 / wan)]
                                             })))

        // Considerations
        var b = CheckBuilder()
        let shared = vms.filter { $0.disks.contains(where: \.isSharedWriter) }.map { $0.ref("shared / multi-writer disk") }
        b.list("shared", "Replication", "Shared / multi-writer disks", .blocker, noun: "VMs can't be host-replicated", affected: shared,
               ready: "No shared disks", remediation: "Clustered VMs need array-based or application-level replication.")
        let rdm = vms.filter { $0.disks.contains(where: \.raw) }.map { $0.ref("\($0.disks.filter(\.raw).count) RDM disk(s)") }
        b.list("rdm", "Replication", "Raw device mappings", .warning, noun: "VMs use RDMs", affected: rdm,
               ready: "No RDM disks", remediation: "Host-based replication doesn't cover physical-mode RDMs; use array replication or convert to VMDK.")
        let indep = vms.filter { $0.disks.contains(where: \.isIndependent) }.map { $0.ref("independent disk(s)") }
        b.list("indep", "Replication", "Independent disks", .warning, noun: "VMs have independent disks", affected: indep,
               ready: "No independent disks", remediation: "Check your replication product's support for independent disks.")
        let oversize = vms.filter { Double($0.cpus) > hostCores || $0.memoryMiB > hostMemMiB }.map { $0.ref("\($0.cpus) vCPU, \(Fmt.memory(mib: $0.memoryMiB))") }
        b.list("oversize", "DR compute", "VMs larger than a DR host", .blocker, noun: "VMs exceed the DR host specification", affected: oversize,
               ready: "Every VM fits on a DR host", remediation: "Increase the DR host specification or right-size these VMs.")
        let bigDisk = vms.filter { $0.disks.contains { $0.capacityMiB > 62 * 1024 * 1024 } }.map { $0.ref("disk > 62 TB") }
        b.list("bigdisk", "Replication", "Disks larger than 62 TB", .warning, noun: "VMs", affected: bigDisk,
               ready: "No disks over 62 TB", remediation: "Very large disks exceed common replication limits; verify with your product.")
        let ft = vms.filter { let s = $0.ftState.lowercased(); return !s.isEmpty && s != "notconfigured" && s != "not configured" }.map { $0.ref("FT: \($0.ftState)") }
        b.list("ft", "Replication", "Fault Tolerance", .warning, noun: "VMs use FT", affected: ft,
               ready: "No FT VMs", remediation: "FT-protected VMs usually can't be host-replicated; verify support.")
        b.add("rpo", "Network", "RPO at peak change", rpoHolds ? .ready : .warning,
              rpoHolds ? "Peak \(Fmt.rate(mbps: peakMbps)) fits in the usable \(Fmt.rate(mbps: usable))"
                       : "Peak \(Fmt.rate(mbps: peakMbps)) exceeds the usable \(Fmt.rate(mbps: usable)) — a \(SFmt.num(rpoMin))-min RPO will slip during bursts",
              remediation: rpoHolds ? "" : "Increase the link, relax the RPO for some VMs, or improve compression.")
        let devices = vms.filter { $0.usbConnected > 0 || $0.cdroms.contains(where: \.connected) }.map { $0.ref($0.usbConnected > 0 ? "USB device" : "CD/DVD connected") }
        b.list("devices", "Recovery", "Connected CD/DVD or USB", .info, noun: "VMs", affected: devices,
               ready: "No connected devices", remediation: "Disconnect media before failover; host devices don't exist at DR.")
        let noTools = vms.filter { $0.isRunning && $0.toolsDisplay != "OK" && $0.toolsDisplay != "Out of date" }.map { $0.ref("Tools \($0.toolsDisplay.lowercased())") }
        b.list("tools", "Recovery", "VMware Tools not running", .info, noun: "VMs", affected: noTools,
               ready: "Tools runs on all powered-on VMs", remediation: "Without Tools there is no quiescing and no guest IP customization at failover.")
        let eol = vms.compactMap { vm in vm.os.endOfSupport.flatMap { $0 <= inv.reportDate ? vm.ref("\(vm.os.name) — ended \(Fmt.date($0))") : nil } }
        b.list("eol", "Recovery", "Guest OS past end of support", .info, noun: "VMs", affected: eol,
               ready: "No end-of-support guests", remediation: "Unsupported guests may not be supported on the DR platform.")
        if subnetTotal > 0 {
            b.add("reip", "Recovery", "Networks to provide at DR", .info, "\(netRows.count) port groups and \(subnetTotal) subnets",
                  remediation: "Stretch these networks to DR or plan re-IP rules per subnet (see Network mapping).")
        }
        let off = vms.filter { !$0.isRunning && !$0.isTemplate }
        if !off.isEmpty && !p.flag("offCompute") {
            b.add("off", "Scope", "Powered-off VMs replicated only", .info, "\(off.count) VMs are replicated but not counted for DR compute", affected: off.map(\.vmRef))
        }
        sections.append(.checks("DR considerations", b.checks))

        let perVM = vms.sorted { replicated($0, basis: basis) > replicated($1, basis: basis) }
        sections.append(.table(SolutionTable(
            id: "per-vm", title: "Per-VM replication", columns: ["VM", "Cluster", "Power", "vCPU", "Memory", "Replicated", "Change / day", "Avg bandwidth", "Networks"],
            numeric: [3, 4, 5, 6, 7],
            rows: perVM.map { vm in
                let change = vm.inUseExcludingSwapMiB * c
                return [vm.name, clusterName(inv, vm), vm.powerLabel, "\(vm.cpus)", Fmt.memory(mib: vm.memoryMiB), Fmt.capacity(mib: replicated(vm, basis: basis)),
                        Fmt.capacity(mib: change), Fmt.rate(mbps: change * mibToMegabits / 86_400 / wan), vm.networkList]
            },
            rowRefs: perVM.map(\.vmRef))))

        sections.append(.notes("Method", [
            "Compute demand counts \(p.flag("offCompute") ? "all selected VMs" : "powered-on VMs") and grows with the data growth rate; hosts = max(CPU, memory\(hostStorMiB > 0 ? ", storage" : "")) + spares.",
            "Replicated data excludes VM swap files. History = in-use × daily change × retention hours ÷ 24.",
            "Bandwidth = in-use × daily change ÷ 86,400 s ÷ WAN compression; the peak multiplier models bursts that must fit the usable link to hold the RPO.",
            "Initial seed assumes the full replica set crosses the WAN; pre-seeding (backup restore / shipped media) shortens it.",
        ]))

        let headline = "\(Fmt.int(vms.count)) VMs · \(Fmt.int(Int(recommended))) DR hosts · \(Fmt.capacity(mib: storage)) DR storage · \(Fmt.rate(mbps: avgMbps)) avg (\(Fmt.rate(mbps: peakMbps)) peak) replication"
        return SolutionResult(headline: headline, sections: sections)
    }
}
