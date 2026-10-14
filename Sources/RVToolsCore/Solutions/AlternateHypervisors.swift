import Foundation

/// Sizes the selected VMs on vSphere 8, VVF 9 and VCF 9 and on alternate hypervisors (Hyper-V, Nutanix AHV, KVM such as
/// Proxmox VE, OpenShift Virtualization) with the same host model and failure rules, then breaks down where each platform's
/// extra hosts come from: management components, memory overcommit and tiering, per-host overhead, per-VM overhead and
/// control plane, and cluster size limits. VVF and VCF management components come from `VCFAppliances`.
/// Every platform figure is an assumption whose help text names its source; confirm them against current vendor docs.
public struct AlternateHypervisors: Solution {
    public init() {}
    public var id: String { "althv" }
    public var title: String { "Alternate Hypervisors" }
    public var symbol: String { "arrow.left.arrow.right.square" }
    public var summary: String { "Hosts needed on Hyper-V, Nutanix AHV, KVM (Proxmox VE, etc.) and OpenShift Virtualization compared with vSphere, and why." }

    enum Platform: Int, CaseIterable {
        case vsphere8, vvf, vcf, hyperv, ahv, kvm, openshift
        /// Assumption prefix; the VMware editions share the vSphere host assumptions.
        var key: String { ["vs", "vs", "vs", "hv", "ahv", "px", "ocp"][rawValue] }
        var id: String { ["vs8", "vvf", "vcf", "hv", "ahv", "px", "ocp"][rawValue] }
        var name: String {
            ["vSphere 8", "VMware vSphere Foundation 9", "VMware Cloud Foundation 9", "Microsoft Hyper-V", "Nutanix AHV", "KVM (Proxmox VE, etc.)",
             "OpenShift Virtualization"][rawValue]
        }
        var short: String { ["vSphere 8", "VVF 9", "VCF 9", "Hyper-V", "AHV", "KVM", "OpenShift"][rawValue] }
        var isVMware: Bool { rawValue <= Platform.vcf.rawValue }
        /// In the order of the "baseline" choice.
        static let editions: [Platform] = [.vcf, .vvf, .vsphere8]
        static let alternates: [Platform] = [.hyperv, .ahv, .kvm, .openshift]
    }

    public var parameters: [SolutionParameter] { [
        .multi("platforms", "Compare", "Platforms to compare with vSphere", Platform.alternates.map(\.name), selected: [0, 1, 2, 3]),
        .choice("baseline", "Compare", "Compare them with", Platform.editions.map(\.name),
                help: "vSphere 8, VVF 9 and VCF 9 are all sized; the comparison and the breakdown use this one."),
        .host("hostModel", "Target hosts", "Size new hosts like", none: "Typical host (median of the hosts behind the selected VMs)",
                help: "The same host model is used for every platform. Pick one of the export's hosts, or set cores and memory below."),
        .number("hostCores", "Target hosts", "Cores per host", 0, min: 0, max: 512,
                help: "Physical cores in each new host. 0 uses the host chosen above."),
        .number("hostRAM", "Target hosts", "Memory per host", 0, min: 0, max: 16_384, step: 64, unit: "GiB",
                help: "DRAM in each new host. 0 uses the host chosen above."),
        .choice("basis", "Capacity", "Size workloads from", ["Configured vCPU and memory", "Measured CPU and consumed memory"],
                help: "The same basis is used for every platform. Measured uses each VM's CPU (MHz) over the host clock and its consumed memory, falling back to configured sizes when the export doesn't have them."),
        .number("cpuRatio", "Capacity", "vCPU per core (configured sizes)", 4, min: 0.5, max: 20, step: 0.5, unit: ": 1",
                help: "The same on every platform: no vendor publishes a hard limit, so change it per run if you have evidence. VMware: no common ratio; start at 1:1 if you can't react to contention quickly (VCF blog, \"vCPU to pCPU ratio guidelines\", June 2025). Nutanix: 1:1 to 2:1 for business-critical or latency-sensitive VMs, up to 4:1 for the rest (Nutanix, \"Understanding CPU resource management in Nutanix AHV\"). Hyper-V: no ratio imposed (Microsoft, Hyper-V maximum scale limits); Windows Server 2008 R2 supported 8:1 per logical processor, 12:1 for VDI. KVM: older Red Hat guidance says no more than 10 vCPUs per physical core (RHEL 6 Virtualization Administration Guide). OpenShift Virtualization schedules vCPUs through a CPU allocation ratio, 10:1 in the docs (\"Assigning compute resources\"). No independent test compares the CPU schedulers; Principled Technologies' Broadcom-commissioned vSphere 8 vs OpenShift density study tested memory overcommit."),
        .number("spare", "Capacity", "Host failures to tolerate per cluster", 1, min: 0, max: 3),
        .number("maxLoad", "Capacity", "Max CPU / memory load with those hosts down", 80, min: 50, max: 100, unit: "%"),
        .number("growth", "Storage", "Estimated growth", 10, min: 0, max: 200, unit: "%"),
        .number("reserve", "Storage", "Free-space reserve (rebuild and operations)", 30, min: 0, max: 80, unit: "%",
                help: "Kept free on every platform's storage for rebuilds after a host failure."),
        .number("mgmtRatio", "Capacity", "Management VMs — vCPU per core", 2, min: 0.5, max: 8, step: 0.5, unit: ": 1",
                help: "For every platform's management VMs (VCF and VVF appliances, Prism Central and so on). The VCF 9.1.1 Planning and Preparation Workbook recommends 2:1 for a performant management domain."),

        // VCF 9
        .choice("vcfArch", "VMware Cloud Foundation 9", "Management domain", [
            "Dedicated — its own cluster",
            "Consolidated — management runs in the workload cluster",
        ], help: "Dedicated is the VCF design ideal: the management domain gets its own cluster, with its own spare, and also runs the workload domain's vCenter and NSX Managers. It needs at least 4 hosts for a high-availability deployment, 3 for simple. Consolidated puts the management appliances in the workload cluster."),
        .choice("vcfDeploy", "VMware Cloud Foundation 9", "Deployment model", VCFAppliances.Deployment.allCases.map { d in
            d.isHA ? "High availability — \(d.size)" : "Simple — single-node appliances (Small)"
        }, selected: 1, help: "Sets appliance sizes and node counts as the VCF Installer does. Sizes come from the \(VCFAppliances.source), as in VCF 9 Sizing."),
        .toggle("vcfOps", "VMware Cloud Foundation 9", "VCF Operations (with cloud proxy and license server)", true,
                help: "VCF 9 uses VCF Operations for licensing and fleet management. The SDDC Manager, management vCenter, NSX Managers and VCF services runtime are always counted."),

        // VVF 9
        .choice("vvfArch", "VMware vSphere Foundation 9", "Management components", [
            "Consolidated — in the workload cluster",
            "Dedicated management cluster",
        ], help: "VVF's smaller footprint usually runs in the workload cluster; a dedicated cluster is still worth it when hosts can be spared."),
        .toggle("vvfServices", "VMware vSphere Foundation 9", "VCF management services", true,
                help: "Fleet and SDDC lifecycle, software depot and telemetry on the VCF services runtime, as the VCF Installer deploys VVF (simple mode). Without them VVF is installed by hand: vCenter, VCF Operations and license server."),
        .choice("vvfVC", "VMware vSphere Foundation 9", "vCenter", ["Existing vCenter (converge)", "New vCenter (Medium)"],
                help: "Converging keeps the vCenter that runs the clusters today, so it isn't counted; a new deployment adds a Medium vCenter, the VCF Installer's VVF default. VCF Operations (Medium, one node) and the license server are always counted."),

        // vSphere 8
        .toggle("vs8VC", "vSphere 8", "Count a new vCenter (Medium)", false,
                help: "Off assumes the existing vCenter keeps running where it is. vSphere 8 needs nothing else for management."),

        // Memory tiering (VVF 9 and VCF 9)
        .toggle("vsTier", "Memory tiering (VVF 9 and VCF 9)", "NVMe memory tiering", false,
                help: "Uses NVMe devices as a second memory tier. GA in VCF 9.0 and VVF 9.0; vSphere 8.0 U3 had it only as a tech preview, so it never applies to vSphere 8. Off by default: every host needs an NVMe device for it (two to mirror it in 9.1), and it suits workloads whose active memory fits in DRAM. Sources: Broadcom VCF blog, \"Advanced Memory Tiering now available\" and \"Smarter infrastructure starts here\" (June 2025)."),
        .number("vsTierRatio", "Memory tiering (VVF 9 and VCF 9)", "NVMe tier size, as a share of DRAM", 100, min: 0, max: 400, step: 25, unit: "%",
                help: "VCF 9.0 defaults to a 1:1 DRAM:NVMe ratio, doubling memory. Broadcom quotes up to 4x with other ratios, depending on how active the workloads are. Active memory must still fit in DRAM, which this sizing checks when the export has active memory. Source: Broadcom VCF blog (June 2025)."),
        .number("vsMem", "vSphere (all editions)", "Memory overcommit (VM memory per host memory)", 100, min: 100, max: 300, step: 5, unit: "%",
                help: "Beyond tiering: ballooning, compression and page sharing. 100% sizes VM memory 1:1, the usual design rule."),
        .number("vsCores", "vSphere (all editions)", "Per-host overhead — cores", 0, min: 0, max: 64,
                help: "ESXi and vSAN ESA CPU use is not reserved; 0 by default."),
        .number("vsRAM", "vSphere (all editions)", "Per-host overhead — memory", 16, min: 0, max: 512, unit: "GiB",
                help: "ESXi plus vSAN ESA memory. An estimate: vSAN memory grows with the number of disks; see Broadcom's \"vSAN memory consumption\" KB for your host."),
        .number("vsMax", "vSphere (all editions)", "Hosts per cluster, at most", 64, min: 2, max: 96,
                help: "vSAN clusters go to 64 hosts (Broadcom KB 327030, \"Creating vSAN clusters up to 64 nodes\"). Plain vSphere clusters go higher; see configmax.broadcom.com."),
        .number("vsMin", "vSphere (all editions)", "Hosts per cluster, at least", 3, min: 1, max: 8, help: "vSAN needs 3 hosts (2 with a witness)."),
        .choice("vsStorage", "vSphere (all editions)", "vSAN ESA storage policy", ["RAID-5 adaptive (2+1 under 6 hosts, 4+1 at 6+)", "RAID-6 (4+2)", "RAID-1 mirror", "External storage"],
                help: "RAID-5 2+1 stores 150% of the data, 4+1 stores 125%; RAID-6 4+2 stores 150%; RAID-1 stores 200%. Source: Duncan Epping, \"vSAN 8.0 ESA – Introducing Adaptive RAID-5\" (Yellow Bricks), and Broadcom KB 405876."),

        // Hyper-V
        .number("hvMem", "Microsoft Hyper-V", "Memory overcommit (VM memory per host memory)", 100, min: 100, max: 300, step: 5, unit: "%",
                help: "Dynamic Memory hot-adds and balloons memory per VM. It works best with Windows guests; Linux support depends on the distribution and kernel. 100% sizes VM memory 1:1. Source: Microsoft Learn, \"Hyper-V Dynamic Memory Overview\"."),
        .number("hvCores", "Microsoft Hyper-V", "Per-host overhead — cores", 2, min: 0, max: 64,
                help: "Management OS (parent partition), failover clustering and Storage Spaces Direct. An estimate; Microsoft doesn't publish a fixed figure."),
        .number("hvRAM", "Microsoft Hyper-V", "Per-host overhead — memory", 8, min: 0, max: 512, unit: "GiB",
                help: "Hyper-V calculates and keeps a host reserve for the management OS and cluster services (Microsoft Learn, \"Hyper-V Dynamic Memory Overview\"); 8 GiB is an estimate."),
        .number("hvCacheTB", "Microsoft Hyper-V", "Storage Spaces Direct cache drives per host", 0, min: 0, max: 100, step: 0.5, unit: "TB",
                help: "S2D needs 4 GB of memory per TB of cache drive on each server, on top of the host and VMs. All-NVMe hosts with one drive type have no cache tier. Source: Microsoft Learn, \"Storage Spaces Direct hardware requirements\"."),
        .number("hvMax", "Microsoft Hyper-V", "Hosts per cluster, at most", 16, min: 2, max: 64,
                help: "Storage Spaces Direct supports 2 to 16 servers (Microsoft Learn, \"Storage Spaces Direct hardware requirements\"). With SAN storage instead, failover clusters go to 64 nodes and 8,000 VMs (Microsoft, Windows Server 2025 scale limits)."),
        .number("hvMin", "Microsoft Hyper-V", "Hosts per cluster, at least", 2, min: 1, max: 8, help: "S2D needs 2 servers."),
        .number("hvStorage", "Microsoft Hyper-V", "Raw storage per usable (0 = external array)", 3, min: 0, max: 4, step: 0.05, unit: "×",
                help: "Three-way mirror, needed to survive two failures, keeps 33% of raw capacity: 3×. Two-way mirror is 2×; mirror-accelerated parity falls in between. Source: Microsoft Learn, \"Fault tolerance and storage efficiency\"."),
        .number("hvMgmtCPU", "Microsoft Hyper-V", "Management VMs — vCPU", 0, min: 0, max: 500,
                help: "System Center VMM, Windows Admin Center or other management VMs, if used; they run in the workload cluster. 0 by default."),
        .number("hvMgmtRAM", "Microsoft Hyper-V", "Management VMs — memory", 0, min: 0, max: 4000, step: 4, unit: "GiB"),

        // Nutanix AHV
        .number("ahvMem", "Nutanix AHV", "Memory overcommit (VM memory per host memory)", 100, min: 100, max: 300, step: 5, unit: "%",
                help: "AHV memory overcommit (AOS 6.1 and later) is enabled per VM, uses ballooning and host swap, and Nutanix suggests starting with non-production VMs. 100% sizes VM memory 1:1. Source: Nutanix, \"AHV Internals: Memory Overcommit\"."),
        .number("ahvCores", "Nutanix AHV", "Per-host overhead — cores (Controller VM)", 8, min: 0, max: 64,
                help: "Every node runs a Controller VM (CVM) for storage. It defaults to 8 vCPU on most platforms and more on large ones; Foundation sizes it by platform. Sources: Nutanix Prism \"CVM Memory Configuration\" and the CVM Field Specifications for your AOS version."),
        .number("ahvRAM", "Nutanix AHV", "Per-host overhead — memory (Controller VM and AHV)", 36, min: 0, max: 512, unit: "GiB",
                help: "A 32 GB CVM (the common minimum, more with deduplication, RF3 or Nutanix Files) plus about 4 GiB for AHV itself. Sources: Nutanix Prism \"CVM Memory Configuration\"; Nutanix Oracle best practices (32 GB default, 64 GB for heavy I/O)."),
        .number("ahvMax", "Nutanix AHV", "Hosts per cluster, at most", 32, min: 3, max: 64,
                help: "32 nodes for AHV per Nutanix's Configuration Maximums as quoted on the Nutanix community (2023); check the portal for your AOS version."),
        .number("ahvMin", "Nutanix AHV", "Hosts per cluster, at least", 3, min: 1, max: 8, help: "RF2 clusters need 3 nodes."),
        .number("ahvStorage", "Nutanix AHV", "Raw storage per usable (0 = external array)", 2, min: 0, max: 4, step: 0.05, unit: "×",
                help: "RF2 keeps two copies: 2×. RF3 is 3×. Erasure coding (EC-X) lowers this for cold data only."),
        .number("ahvMgmtCPU", "Nutanix AHV", "Management VMs — vCPU (Prism Central)", 6, min: 0, max: 500,
                help: "Prism Central, needed for multi-cluster management, DR and most add-ons; it runs in the workload cluster. A single Small instance is 6 vCPU and 26 GB; scale-out is three of them. Source: Prism Central sizes as documented by OVHcloud's Nutanix service; confirm in Nutanix KB-16847."),
        .number("ahvMgmtRAM", "Nutanix AHV", "Management VMs — memory (Prism Central)", 26, min: 0, max: 4000, step: 2, unit: "GiB"),

        // KVM (Proxmox VE and similar)
        .number("pxMem", "KVM (Proxmox VE, etc.)", "Memory overcommit (VM memory per host memory)", 100, min: 100, max: 300, step: 5, unit: "%",
                help: "KVM ballooning and KSM page merging. Proxmox warns that aggressive ballooning can trigger the guest's OOM killer, and KSM costs CPU. 100% sizes VM memory 1:1. Source: Proxmox VE wiki, \"Dynamic Memory Management\"."),
        .number("pxCores", "KVM (Proxmox VE, etc.)", "Per-host overhead — cores (host)", 1, min: 0, max: 64, help: "The KVM host (Proxmox VE or similar), before Ceph. An estimate."),
        .number("pxRAM", "KVM (Proxmox VE, etc.)", "Per-host overhead — memory (host)", 4, min: 0, max: 512, unit: "GiB", help: "The KVM host (Proxmox VE or similar), before Ceph. An estimate."),
        .number("pxOSDs", "KVM (Proxmox VE, etc.)", "Ceph OSDs (NVMe drives) per host", 4, min: 0, max: 32,
                help: "0 for external storage. Each OSD adds the cores and memory below."),
        .number("pxOSDCores", "KVM (Proxmox VE, etc.)", "Cores per Ceph OSD", 2, min: 0, max: 8, step: 0.5,
                help: "Proxmox suggests 4 to 6 CPU threads per NVMe OSD for high-performance disks, about 2 to 3 cores with hyperthreading. Source: Proxmox VE docs, \"Deploy Hyper-Converged Ceph Cluster\"."),
        .number("pxOSDRAM", "KVM (Proxmox VE, etc.)", "Memory per Ceph OSD", 8, min: 1, max: 32, unit: "GiB",
                help: "Proxmox recommends at least 8 GiB per OSD daemon (the default target is 4 GiB; the rest covers recovery and backfill). Source: Proxmox VE docs, pveceph OSD memory considerations (2025)."),
        .number("pxMax", "KVM (Proxmox VE, etc.)", "Hosts per cluster, at most", 32, min: 3, max: 64,
                help: "Proxmox VE's corosync clusters are commonly kept to about 32 nodes on a dedicated cluster network; Proxmox staff say they haven't tested beyond 36. Source: Proxmox forum and pve-devel list."),
        .number("pxMin", "KVM (Proxmox VE, etc.)", "Hosts per cluster, at least", 3, min: 1, max: 8, help: "Ceph with 3 replicas needs 3 nodes."),
        .number("pxStorage", "KVM (Proxmox VE, etc.)", "Raw storage per usable (0 = external array)", 3, min: 0, max: 4, step: 0.05, unit: "×",
                help: "Ceph pools default to 3 replicas: 3×. Erasure-coded pools (e.g. 4+2 at 1.5×) are rarely used for VM disks."),
        .number("pxMgmtCPU", "KVM (Proxmox VE, etc.)", "Management VMs — vCPU", 0, min: 0, max: 500,
                help: "Proxmox VE's management runs on every node. Add Proxmox Datacenter Manager, backup servers or other management VMs here if used."),
        .number("pxMgmtRAM", "KVM (Proxmox VE, etc.)", "Management VMs — memory", 0, min: 0, max: 4000, step: 4, unit: "GiB"),

        // OpenShift Virtualization
        .number("ocpMem", "OpenShift Virtualization", "Memory overcommit (VM memory per host memory)", 100, min: 100, max: 400, step: 25, unit: "%",
                help: "VMs reserve their full memory by default. Higher workload density (memoryOvercommitPercentage, with wasp-agent and node swap) raises this; Red Hat recommends a fast dedicated swap device and testing the ratio. Source: Red Hat, \"Configuring higher VM workload density\" (OpenShift 4.19–4.21)."),
        .number("ocpCores", "OpenShift Virtualization", "Per-host overhead — cores (node)", 1, min: 0, max: 64,
                help: "Kubelet, CRI-O and system reserved, before ODF. An estimate."),
        .number("ocpRAM", "OpenShift Virtualization", "Per-host overhead — memory (node)", 4, min: 0, max: 512, unit: "GiB",
                help: "Kubelet, CRI-O, system reserved and the OpenShift Virtualization node agents (about 360 MiB per worker). An estimate."),
        .number("ocpDrives", "OpenShift Virtualization", "OpenShift Data Foundation drives per host", 4, min: 0, max: 24,
                help: "0 for external storage. ODF internal mode needs 30 CPU and 72 GiB across 3 nodes for the first 3 drives, plus 6 CPU and 15 GiB per further 3 drives; per node that is 10 logical CPUs and 24 GiB plus 2 logical CPUs and 5 GiB per drive after the first, counted here as half as many cores (hyperthreading). Source: Red Hat ODF 4.18, \"Planning your deployment — Resource requirements\"."),
        .number("ocpControl", "OpenShift Virtualization", "Control-plane nodes per cluster", 3, min: 0, max: 5,
                help: "Dedicated control-plane nodes don't run VMs. 0 for a compact cluster where they do."),
        .number("ocpMax", "OpenShift Virtualization", "Worker nodes per cluster, at most", 100, min: 3, max: 500,
                help: "OpenShift Virtualization was tested to 500 nodes; Red Hat recommends 100 or fewer and more clusters beyond that. Source: Red Hat, OpenShift Virtualization \"Supported limits\"."),
        .number("ocpMin", "OpenShift Virtualization", "Worker nodes per cluster, at least", 3, min: 1, max: 8, help: "ODF needs 3 nodes."),
        .number("ocpStorage", "OpenShift Virtualization", "Raw storage per usable (0 = external array)", 3, min: 0, max: 4, step: 0.05, unit: "×",
                help: "ODF (Ceph) keeps 3 replicas: 3×."),
    ] }

    public func defaultSelection(_ inventory: Inventory) -> Set<String> {
        Set(inventory.workloadVMs.map(\.id))
    }


    // MARK: - Model

    typealias Component = VCF9Sizing.Component

    struct HostSpec { var cores: Double, ramGiB: Double, mhz: Double, name: String }

    struct Demand {
        var cores = 0.0, ramGiB = 0.0
        /// Active memory, which must stay in DRAM with tiering; nil when the export has none.
        var activeGiB: Double?
        var isEmpty: Bool { cores <= 0 && ramGiB <= 0 }
    }

    /// One platform's rules, from the assumptions.
    struct Profile {
        let platform: Platform
        var density = 1.0           // VM memory per host memory
        var tier = 0.0              // NVMe tier as a share of DRAM
        var hostCores = 0.0, hostRAM = 0.0
        var perVMOverhead = false   // OpenShift virt-launcher overhead
        var control = 0             // hosts per cluster that run no VMs
        var maxHosts = 64, minHosts = 3
        var storage: (Int) -> Double? = { _ in nil }   // raw per usable, given hosts per cluster; nil = external
        /// Management components, given the workload hosts and clusters they manage.
        var management: (Int, Int) -> [Component] = { _, _ in [] }
        /// Management in its own cluster (at least `mgmtMinHosts`), rather than in the workload cluster.
        var mgmtDedicated = false
        var mgmtMinHosts = 3
    }

    struct Plan {
        var hosts = 0, clusters = 0, control = 0
        /// Hosts and clusters of a dedicated management cluster, included in `hosts` and `clusters`.
        var mgmtHosts = 0, mgmtClusters = 0
        var mgmt: [Component] = []
        var cpuLoad = 0.0, memLoad = 0.0, activeLoad = 0.0
        var feasible = true
        var total: Int { hosts + control }
        var load: Double { max(cpuLoad, memLoad, activeLoad) }
        var driver: String {
            if !feasible { return "Doesn't fit" }
            if activeLoad >= memLoad && activeLoad >= cpuLoad && activeLoad > 0 { return "Active memory (DRAM)" }
            return memLoad >= cpuLoad ? "Memory" : "CPU"
        }
    }

    /// OpenShift Virtualization's per-VM memory overhead: 0.2% of guest memory, 218 MiB for virt-launcher, 8 MiB per
    /// vCPU and 16 MiB for the graphics device (Red Hat, OpenShift Virtualization "Preparing your cluster", 4.13+).
    static func openShiftOverheadGiB(_ vm: VM) -> Double {
        (vm.memoryMiB * 0.002 + 218 + 8 * Double(vm.cpus) + 16) / 1024
    }

    /// The fewest hosts that carry the demand at `maxLoad` with `spare` hosts down in every cluster, clusters split at
    /// the platform's maximum and each at least its minimum.
    static func size(_ d: Demand, vmOverheadGiB: Double, _ pr: Profile, host: HostSpec, spare: Int, maxLoad: Double) -> Plan {
        let cores = host.cores - pr.hostCores, dram = host.ramGiB - pr.hostRAM
        guard cores > 0, dram > 0 else { return Plan(feasible: false) }
        let ram = d.ramGiB / max(pr.density, 1) + vmOverheadGiB
        let perCluster = max(pr.maxHosts, pr.minHosts, spare + 1)
        for h in 1...20_000 {
            let clusters = Int((Double(h) / Double(perCluster)).rounded(.up))
            guard h >= clusters * max(pr.minHosts, spare + 1) else { continue }
            let live = Double(h - clusters * spare)
            var p = Plan(hosts: h, clusters: clusters, control: clusters * pr.control)
            p.cpuLoad = d.cores / (live * cores)
            p.memLoad = ram / (live * dram * (1 + pr.tier))
            if pr.tier > 0, let active = d.activeGiB { p.activeLoad = (active + vmOverheadGiB) / (live * dram) }
            if p.load <= maxLoad { return p }
        }
        return Plan(feasible: false)
    }

    func profile(_ pl: Platform, _ p: Params, vms: Int) -> Profile {
        typealias A = VCFAppliances
        let k = pl.key
        var pr = Profile(platform: pl)
        pr.density = p.num(k + "Mem") / 100
        pr.hostCores = p.num(k + "Cores")
        pr.hostRAM = p.num(k + "RAM")
        pr.maxHosts = Int(p.num(k + "Max"))
        pr.minHosts = Int(p.num(k + "Min"))
        let factor = p.num(k + "Storage")
        pr.storage = { _ in factor > 0 ? factor : nil }
        if pl.isVMware {
            let policy = p.choice("vsStorage")
            pr.storage = { n in [n >= 6 ? 1.25 : 1.5, 1.5, 2.0, nil][min(policy, 3)] }
            if pl != .vsphere8, p.flag("vsTier") { pr.tier = p.num("vsTierRatio") / 100 }
        } else {
            let cpu = p.num(k + "MgmtCPU"), ram = p.num(k + "MgmtRAM")
            let name = pl == .ahv ? "Prism Central" : "Management VMs"
            if cpu > 0 || ram > 0 { pr.management = { _, _ in [Component(name: name, nodes: 1, cpu: cpu, ram: ram, disk: 0)] } }
        }
        switch pl {
        case .vsphere8:
            if p.flag("vs8VC"), let vc = A.vcenter["Medium"] {
                pr.management = { _, _ in [Component(name: "vCenter", nodes: 1, cpu: vc.cpu, ram: vc.ram, disk: A.vcenterDisk["Medium"]!["Default"]!, note: "Medium")] }
            }
        case .vvf:
            let newVC = p.choice("vvfVC") == 1, services = p.flag("vvfServices")
            pr.management = { _, _ in
                VCF9Sizing.vvfComponents(newVCenter: newVC, services: services, proxy: false, logs: nil, logReplicas: 3, extra: A.Spec(0, 0, 0))
            }
            pr.mgmtDedicated = p.choice("vvfArch") == 1
            pr.mgmtMinHosts = max(pr.minHosts, 3)
        case .vcf:
            let deploy = A.Deployment(rawValue: p.choice("vcfDeploy")) ?? .haSmall
            let dedicated = p.choice("vcfArch") == 0, ops = p.flag("vcfOps")
            pr.management = { hosts, clusters in
                // Dedicated: the workload domain's vCenter and NSX Managers run in the management domain. Consolidated:
                // the management domain is the workload cluster and has no workload domain.
                let wld = dedicated ? [VCF9Sizing.WorkloadDomain(name: "Workload domain", clusters: [], hosts: hosts, vms: vms,
                                                                 vcSize: A.vcenterSize(hosts: hosts, vms: vms),
                                                                 nsxSize: A.nsxSize(hosts: hosts, clusters: clusters))] : []
                return VCF9Sizing.managementComponents(deploy, vcfOps: ops, vcfAuto: false, logs: nil, logReplicas: 3, rtm: false, edges: nil,
                                                       mgmtNSXSize: deploy == .haLarge ? "Large" : "Medium", extra: A.Spec(0, 0, 0),
                                                       domains: wld, newVCenters: true, wldNSXNodes: 3)
            }
            pr.mgmtDedicated = dedicated
            pr.mgmtMinHosts = max(pr.minHosts, deploy.isHA ? 4 : 3)
        case .hyperv:
            pr.hostRAM += 4 * p.num("hvCacheTB")
        case .kvm:
            pr.hostCores += p.num("pxOSDs") * p.num("pxOSDCores")
            pr.hostRAM += p.num("pxOSDs") * p.num("pxOSDRAM")
        case .openshift:
            let drives = p.num("ocpDrives")
            if drives > 0 {
                // ODF's figures are logical CPUs; halved to cores, as hyperthreaded hosts give two per core.
                pr.hostCores += (10 + 2 * (drives - 1)) / 2
                pr.hostRAM += 24 + 5 * (drives - 1)
            }
            pr.perVMOverhead = true
            pr.control = Int(p.num("ocpControl"))
        case .ahv: break
        }
        return pr
    }

    /// The median host by memory behind the VMs, as the model for new hosts.
    static func typicalHost(_ hosts: [Host]) -> Host? {
        let sorted = hosts.filter { !$0.inferred && !$0.isVirtual && $0.cores > 0 && $0.memoryMiB > 0 }
            .sorted { ($0.memoryMiB, $0.cores) < ($1.memoryMiB, $1.cores) }
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }

    // MARK: - Run

    public func run(vms: [VM], inventory inv: Inventory, params p: Params) -> SolutionResult {
        let running = vms.filter { $0.isVM && $0.isRunning }
        let hostIDs = Set(vms.map(\.hostKey))
        let hostsToday = inv.hosts.filter { hostIDs.contains($0.id) && !$0.isVirtual }
        let picked = p.names("hostModel").first.flatMap { HostSpecs.resolve($0, in: inv) }.flatMap { AlternateHypervisors.typicalHost([$0]) }
        let missingPick = !p.names("hostModel").isEmpty && picked == nil
        let model = picked ?? AlternateHypervisors.typicalHost(hostsToday) ?? AlternateHypervisors.typicalHost(inv.hosts)
        var host = HostSpec(cores: Double(model?.cores ?? 0), ramGiB: (model?.memoryMiB ?? 0) / 1024,
                            mhz: model?.speedMHz ?? 0, name: model.map { (picked != nil ? "like " : "typical, like ") + $0.name } ?? "")
        if p.num("hostCores") > 0 { host.cores = p.num("hostCores"); host.name = "custom" }
        if p.num("hostRAM") > 0 { host.ramGiB = p.num("hostRAM"); host.name = "custom" }
        let hostLabel = "\(SFmt.num(host.cores)) cores, \(Fmt.memory(mib: host.ramGiB * 1024))" + (host.name.isEmpty ? "" : " (\(host.name))")

        guard !running.isEmpty, host.cores > 0, host.ramGiB > 0 else {
            let why = running.isEmpty ? "No powered-on VMs selected." : "No host to model: set cores and memory per host under Target hosts."
            return SolutionResult(headline: why, sections: [.notes("Nothing to size", [why])])
        }

        // Demand, on the same basis for every platform.
        let measured = p.choice("basis") == 1
        let ratio = max(p.num("cpuRatio"), 0.1)
        let mgmtRatio = max(p.num("mgmtRatio"), 0.1)
        var d = Demand()
        var activeKnown = 0
        var activeSum = 0.0
        var measuredFallback = 0
        for vm in running {
            if measured, vm.cpuUsageMHz > 0, host.mhz > 0, vm.memConsumedMiB > 0 {
                d.cores += vm.cpuUsageMHz / host.mhz
                d.ramGiB += vm.memConsumedMiB / 1024
            } else {
                if measured { measuredFallback += 1 }
                d.cores += Double(vm.cpus) / ratio
                d.ramGiB += vm.memoryMiB / 1024
            }
            if vm.memActiveMiB > 0 { activeKnown += 1; activeSum += vm.memActiveMiB / 1024 }
        }
        // Active memory only counts when most VMs report it; VMs without it are taken at their sized memory.
        if activeKnown * 2 >= running.count {
            let missing = running.filter { $0.memActiveMiB <= 0 }.reduce(0) { $0 + $1.memoryMiB / 1024 }
            d.activeGiB = activeSum + missing
        }
        let ocpOverhead = running.reduce(0) { $0 + AlternateHypervisors.openShiftOverheadGiB($1) }

        let spare = Int(p.num("spare"))
        let maxLoad = p.num("maxLoad") / 100
        let chosen = p.multi("platforms").compactMap { i in Platform.alternates.indices.contains(i) ? Platform.alternates[i] : nil }
        let baseline = Platform.editions[min(p.choice("baseline"), Platform.editions.count - 1)]
        let editions: [Platform] = [.vsphere8, .vvf, .vcf]
        let platforms = editions + chosen
        let profiles = Dictionary(uniqueKeysWithValues: platforms.map { ($0, profile($0, p, vms: running.count)) })

        /// Management appliances count at the management vCPU ratio; their memory is all active.
        func demand(_ comps: [Component]) -> Demand {
            let ram = comps.reduce(0) { $0 + $1.ram }
            return Demand(cores: comps.reduce(0) { $0 + $1.cpu } / mgmtRatio, ramGiB: ram, activeGiB: ram)
        }
        func plan(_ pr: Profile) -> Plan {
            let overhead = pr.perVMOverhead ? ocpOverhead : 0
            func workloads(_ extra: Demand) -> Plan {
                var dd = d
                dd.cores += extra.cores; dd.ramGiB += extra.ramGiB
                dd.activeGiB = d.activeGiB.map { $0 + (extra.activeGiB ?? 0) }
                return AlternateHypervisors.size(dd, vmOverheadGiB: overhead, pr, host: host, spare: spare, maxLoad: maxLoad)
            }
            let first = workloads(Demand())
            guard first.feasible else { return first }
            let comps = pr.management(first.hosts, first.clusters)
            let md = demand(comps)
            guard !md.isEmpty else { return first }
            if pr.mgmtDedicated {
                var mp = pr
                mp.minHosts = max(pr.minHosts, pr.mgmtMinHosts); mp.perVMOverhead = false; mp.control = 0
                let m = AlternateHypervisors.size(md, vmOverheadGiB: 0, mp, host: host, spare: spare, maxLoad: maxLoad)
                guard m.feasible else { return m }
                var out = first
                out.hosts += m.hosts; out.clusters += m.clusters
                out.mgmtHosts = m.hosts; out.mgmtClusters = m.clusters
                out.mgmt = comps
                return out
            }
            // In the workload cluster: size with the appliances, then once more in case their size grew with the hosts.
            var out = workloads(md)
            guard out.feasible else { return out }
            let again = pr.management(out.hosts, out.clusters)
            if demand(again).ramGiB > md.ramGiB || demand(again).cores > md.cores { out = workloads(demand(again)) }
            out.mgmt = again
            return out
        }
        let plans = profiles.mapValues(plan)
        let base = plans[baseline]!

        // Storage
        let growth = 1 + p.num("growth") / 100
        let reserve = min(p.num("reserve") / 100, 0.95)
        let usableMiB = vms.filter(\.isVM).reduce(0) { $0 + $1.inUseExcludingSwapMiB } * growth
        func rawMiB(_ pl: Platform) -> Double? {
            guard let pr = profiles[pl], let pn = plans[pl], pn.feasible, pn.clusters > 0,
                  let f = pr.storage((pn.hosts - pn.mgmtHosts) / max(pn.clusters - pn.mgmtClusters, 1)) else { return nil }
            let mgmtMiB = pn.mgmt.reduce(0) { $0 + $1.disk } * 1024
            return (usableMiB + mgmtMiB) * f / (1 - reserve)
        }

        func delta(_ n: Int) -> String { n == 0 ? "same" : (n > 0 ? "+\(n)" : "−\(-n)") }
        func vsBase(_ pn: Plan) -> String {
            guard pn.feasible, base.feasible else { return "—" }
            let diff = pn.total - base.total
            return delta(diff) + (base.total > 0 && diff != 0 ? " (\(diff > 0 ? "+" : "−")\(Fmt.pct(Double(abs(diff)) / Double(base.total) * 100)))" : "")
        }
        func hosts(_ pn: Plan) -> String { pn.feasible ? Fmt.int(pn.total) : "—" }
        func clustersText(_ pn: Plan) -> String {
            "\(pn.clusters) cluster\(pn.clusters == 1 ? "" : "s")" + (pn.mgmtHosts > 0 ? " incl. \(pn.mgmtHosts)-host management" : "")
        }

        // Summary
        var metrics = [
            SolutionMetric("VMs sized", Fmt.int(running.count), "powered on, of \(Fmt.int(vms.count)) selected", symbol: "desktopcomputer"),
            SolutionMetric("Demand", "\(SFmt.num(d.cores.rounded(.up))) cores · \(Fmt.memory(mib: d.ramGiB * 1024))",
                           measured ? "measured CPU and consumed memory" : "\(Fmt.int(running.reduce(0) { $0 + $1.cpus })) vCPU at \(SFmt.num(ratio)):1",
                           symbol: "cpu"),
            SolutionMetric("Host model", "\(SFmt.num(host.cores)) cores · \(Fmt.memory(mib: host.ramGiB * 1024))",
                           (host.name.isEmpty ? "" : host.name + " · ") + "same on every platform · today \(Fmt.int(hostsToday.count)) hosts", symbol: "server.rack"),
        ]
        for pl in [baseline] + editions.filter({ $0 != baseline }) + chosen {
            let pn = plans[pl]!
            let detail = !pn.feasible ? "per-host overhead leaves nothing for VMs"
                : (pl == baseline ? clustersText(pn) + " · sized by \(pn.driver.lowercased())" : "\(vsBase(pn)) vs \(baseline.short)")
            metrics.append(SolutionMetric(pl.short, pn.feasible ? "\(Fmt.int(pn.total)) hosts" : "Doesn't fit", detail,
                                          symbol: pl.isVMware ? "checkmark.seal" : "server.rack", status: pn.feasible ? nil : .blocker))
        }

        // Hosts by platform
        var rows: [[String]] = []
        for pl in platforms {
            let pn = plans[pl]!, pr = profiles[pl]!
            let cores = host.cores - pr.hostCores, dram = host.ramGiB - pr.hostRAM
            let mem = Fmt.memory(mib: max(0, dram) * 1024) + (pr.tier > 0 ? " + \(Fmt.memory(mib: max(0, dram) * pr.tier * 1024)) NVMe" : "")
            rows.append([pl.name, hosts(pn), pl == baseline ? "baseline" : vsBase(pn), pn.feasible ? Fmt.int(pn.clusters) : "—",
                         pn.feasible ? Fmt.int(pn.clusters * spare) : "—", pn.mgmtHosts > 0 ? Fmt.int(pn.mgmtHosts) : "",
                         pn.control > 0 ? Fmt.int(pn.control) : "",
                         SFmt.num(max(0, cores)), mem, pr.density > 1 ? "\(Fmt.pct(pr.density * 100))" : "1:1",
                         pn.feasible ? Fmt.pct(pn.load * 100) : "—", pn.driver, pn.feasible ? rawMiB(pl).map { Fmt.capacity(mib: $0) } ?? "External" : "—"])
        }
        let hostsTable = SolutionTable(id: "hosts", title: "Hosts by platform",
                                       subtitle: "Same VMs, same host model, \(spare) host failure\(spare == 1 ? "" : "s") tolerated per cluster at up to \(Fmt.pct(maxLoad * 100)) load. Hosts include spares, management and control-plane nodes; load is the workload clusters'.",
                                       columns: ["Platform", "Hosts", "vs \(baseline.short)", "Clusters", "Spare hosts", "Management hosts", "Control-plane nodes",
                                                 "Cores per host for VMs", "Memory per host for VMs", "Memory overcommit", "Load", "Sized by", "Raw storage"],
                                       numeric: [1, 3, 4, 5, 6, 7, 10], rows: rows, emphasized: [platforms.firstIndex(of: baseline)!])

        // Where the extra hosts come from: swap one baseline assumption at a time for the platform's.
        var gapRows: [[String]] = []
        let vs = profiles[baseline]!
        for pl in chosen {
            let target = profiles[pl]!
            var step = vs
            var counts = [base]
            step.management = target.management; step.mgmtDedicated = target.mgmtDedicated; step.mgmtMinHosts = target.mgmtMinHosts
            counts.append(plan(step))
            step.density = target.density; step.tier = target.tier
            counts.append(plan(step))
            step.hostCores = target.hostCores; step.hostRAM = target.hostRAM
            counts.append(plan(step))
            step.perVMOverhead = target.perVMOverhead; step.control = target.control
            counts.append(plan(step))
            step.maxHosts = target.maxHosts; step.minHosts = target.minHosts
            counts.append(plan(step))
            guard counts.allSatisfy(\.feasible) else {
                gapRows.append([pl.name, Fmt.int(base.total), "—", "—", "—", "—", "—", "Doesn't fit"])
                continue
            }
            let steps = zip(counts.dropFirst(), counts).map { $0.total == $1.total ? "0" : delta($0.total - $1.total) }
            gapRows.append([pl.name, Fmt.int(base.total)] + steps + [Fmt.int(counts.last!.total)])
        }
        let gapTable = SolutionTable(id: "gap", title: "Where the difference in hosts comes from",
                                     subtitle: "Starting from \(baseline.short), each column swaps in one of the platform's assumptions, in this order. Another order can move hosts between columns; the total doesn't change.",
                                     columns: ["Platform", "\(baseline.short) hosts", "Management components", "Memory overcommit and tiering", "Per-host overhead",
                                               "Per-VM overhead and control plane", "Cluster size limits", "Platform hosts"],
                                     numeric: [1, 2, 3, 4, 5, 6, 7], rows: gapRows)

        // Management components
        var mgmtRows: [[String]] = []
        for pl in platforms {
            guard let pn = plans[pl], pn.feasible, !pn.mgmt.isEmpty else { continue }
            let pr = profiles[pl]!
            let place = pr.mgmtDedicated ? "Own cluster (\(pn.mgmtHosts) hosts)" : "Workload cluster"
            for c in pn.mgmt {
                mgmtRows.append([pl.short, c.name + (c.note.isEmpty ? "" : " (\(c.note))"), c.nodes > 0 ? Fmt.int(c.nodes) : "",
                                 SFmt.num(c.cpu), SFmt.num(c.ram), SFmt.num(c.disk), place])
            }
            let t = demand(pn.mgmt)
            mgmtRows.append([pl.short, "Total", "", SFmt.num(pn.mgmt.reduce(0) { $0 + $1.cpu }), SFmt.num(t.ramGiB), SFmt.num(pn.mgmt.reduce(0) { $0 + $1.disk }),
                             "\(SFmt.num((t.cores * 10).rounded() / 10)) cores at \(SFmt.num(mgmtRatio)):1"])
        }
        let mgmtTable = SolutionTable(id: "management", title: "Management components",
                                      subtitle: "VCF and VVF appliance sizes follow the \(VCFAppliances.source) and VCF 9.1 installer defaults, as in VCF 9 Sizing. OpenShift's control plane is counted as nodes instead.",
                                      columns: ["Platform", "Component", "Nodes", "vCPU", "Memory (GB)", "Disk (GB)", "Runs on"], numeric: [2, 3, 4, 5],
                                      rows: mgmtRows, emphasized: Set(mgmtRows.indices.filter { mgmtRows[$0][1] == "Total" }))

        // Per-host overhead
        let what: [Platform: String] = [
            .vsphere8: "ESXi and vSAN ESA", .vvf: "ESXi and vSAN ESA", .vcf: "ESXi and vSAN ESA",
            .hyperv: "Management OS, clustering and Storage Spaces Direct" + (p.num("hvCacheTB") > 0 ? " (incl. \(SFmt.num(4 * p.num("hvCacheTB"))) GiB for S2D cache)" : ""),
            .ahv: "Controller VM (storage) and AHV",
            .kvm: "KVM host plus \(SFmt.num(p.num("pxOSDs"))) Ceph OSDs",
            .openshift: "Node services" + (p.num("ocpDrives") > 0 ? " plus OpenShift Data Foundation for \(SFmt.num(p.num("ocpDrives"))) drives" : "")
                + "; per VM, virt-launcher adds \(Fmt.memory(mib: ocpOverhead * 1024)) in all",
        ]
        let overheadTable = SolutionTable(id: "overhead", title: "Per-host overhead",
                                          subtitle: "Taken from every host before VMs. Defaults and their sources are in the assumptions.",
                                          columns: ["Platform", "Cores", "Memory", "What it is"], numeric: [1, 2],
                                          rows: ([baseline] + chosen).map { pl in
                                              let pr = profiles[pl]!
                                              return [pl.isVMware ? "vSphere (all editions)" : pl.name, SFmt.num(pr.hostCores), Fmt.memory(mib: pr.hostRAM * 1024), what[pl] ?? ""]
                                          })

        // Migration considerations
        var cb = CheckBuilder()
        let all = vms.filter(\.isVM)
        cb.list("rdm", "Storage", "Raw device mappings", .warning, noun: "VMs with RDMs",
                affected: all.filter { $0.disks.contains(where: \.raw) }.map { vm in vm.ref("\(vm.disks.filter(\.raw).count) RDM disk(s)") },
                ready: "No RDMs", remediation: "Migration tools convert VMDKs, not RDMs. Plan to present the LUNs to the guest (iSCSI) or move the data.", total: all.count)
        cb.list("shared", "Storage", "Shared or multi-writer disks", .warning, noun: "VMs with shared disks",
                affected: all.filter { $0.disks.contains(where: \.isSharedWriter) }.map { $0.ref("guest cluster or shared disk") },
                ready: "No shared disks",
                remediation: "Guest clusters need each platform's own shared-disk feature (shared VHDX, Nutanix Volume Groups, shared RBD or RWX block volumes) and usually a rebuild.", total: all.count)
        let ft = all.filter { let s = $0.ftState.lowercased(); return !s.isEmpty && s != "notconfigured" && s != "not configured" }
        cb.list("ft", "Availability", "vSphere Fault Tolerance", .warning, noun: "VMs use FT", affected: ft.map { $0.ref("FT: \($0.ftState)") },
                ready: "No FT VMs", remediation: "None of the compared platforms has an equivalent of FT's lockstep secondary VM; these VMs fall back to HA restart or need application clustering.")
        let ref = Lifecycle.supportReference(exportDate: inv.reportDate)
        cb.list("eol", "Guest OS", "Guest OS past end of support", .warning, noun: "VMs",
                affected: all.compactMap { vm in vm.os.endOfSupport.flatMap { $0 <= ref ? vm.ref("\(vm.os.name) — ended \(Fmt.date($0))") : nil } },
                ready: "All guests in support",
                remediation: "Other hypervisors and their migration tools support fewer old guests (drivers such as VirtIO or Hyper-V integration services). Upgrade, or check each platform's guest support list.", total: all.count)
        cb.list("latency", "Performance", "Latency sensitivity set to high", .info, noun: "VMs",
                affected: all.filter { $0.latencySensitivity.lowercased() == "high" }.map { $0.ref("latency sensitivity high") },
                ready: "None", remediation: "Plan CPU pinning or dedicated cores on the target platform.")
        cb.list("usb", "Devices", "USB devices connected", .info, noun: "VMs",
                affected: all.filter { $0.usbConnected > 0 }.map { $0.ref("\($0.usbConnected) USB device(s)") },
                ready: "None", remediation: "USB passthrough works differently on each platform, and on some it blocks live migration; consider USB over IP.")
        for pl in [baseline] + chosen {
            let pr = profiles[pl]!
            let cores = host.cores - pr.hostCores, dram = (host.ramGiB - pr.hostRAM) * (1 + pr.tier)
            let big = running.filter { Double($0.cpus) > cores * (model?.htActive == true ? 2 : 1) || $0.memoryMiB / 1024 > dram }
            cb.list("big-" + pl.id, "Sizing", "VMs too large for one \(pl.short) host", .warning, noun: "VMs",
                    affected: big.map { $0.ref("\($0.cpus) vCPU, \(Fmt.memory(mib: $0.memoryMiB))") },
                    ready: "Every VM fits a host after overhead",
                    remediation: "After \(pl.short)'s per-host overhead, a host has \(SFmt.num(max(0, cores))) cores and \(Fmt.memory(mib: max(0, dram) * 1024)) for VMs. Use larger hosts for these VMs.")
        }

        var notes = [
            "Every platform is sized for the same powered-on VMs on the same host model (\(hostLabel)), with \(spare) host failure\(spare == 1 ? "" : "s") per cluster and up to \(Fmt.pct(maxLoad * 100)) CPU and memory load.",
            "Management components run at \(SFmt.num(mgmtRatio)) vCPU per core with all their memory active. In their own cluster they get their own spare hosts; in the workload cluster they add to its load.",
            "VCF's management domain also runs NSX networking and security, fleet lifecycle and VCF Operations, which the alternates' figures don't include. Their own add-ons (Nutanix Flow, SCVMM, an OpenShift observability stack and so on) can be added as management VMs.",
            "A dedicated management cluster is sized on the same host model as the workloads; smaller hosts are often enough for it.",
            "Clusters are split at each platform's maximum size, and every cluster keeps its own spare hosts, so lower cluster limits cost extra hosts.",
            "Storage is VM in-use space (excluding swap) plus \(Fmt.pct(p.num("growth"))) growth and the management components' disks, times each platform's raw-to-usable factor, with \(Fmt.pct(reserve * 100)) kept free. Data reduction is not counted on any platform. Storage doesn't add hosts here.",
            "Defaults come from vendor documentation where it exists, and are marked as estimates where it doesn't; each assumption's help names its source. Confirm them against the versions you would deploy.",
        ]
        if p.flag("vsTier") {
            notes.append(d.activeGiB != nil
                ? "Memory tiering (VVF 9 and VCF 9): active memory (\(Fmt.memory(mib: (d.activeGiB ?? 0) * 1024))) and the management appliances are kept within DRAM; inactive memory can sit on the NVMe tier."
                : "Memory tiering (VVF 9 and VCF 9): the export has no active memory for most VMs, so the sizing can't check that active memory fits in DRAM. Check it before relying on tiering.")
        }
        if missingPick {
            notes.append("The chosen host (\(p.names("hostModel").first.map { String($0.split(separator: "|").last ?? "") } ?? "")) isn't in this export, or has no cores or memory, so the typical host is used.")
        }
        if measuredFallback > 0 { notes.append("\(measuredFallback) VMs had no measured CPU or consumed memory and were sized from their configuration.") }

        let others = editions.filter { $0 != baseline }.compactMap { pl -> String? in
            guard let pn = plans[pl], pn.feasible else { return nil }
            return "\(pl.short) \(Fmt.int(pn.total))"
        }
        let alt = chosen.compactMap { pl -> String? in
            guard let pn = plans[pl], base.feasible else { return nil }
            return pn.feasible ? "\(pl.short) \(Fmt.int(pn.total)) (\(delta(pn.total - base.total)))" : "\(pl.short) doesn't fit"
        }
        let headline = base.feasible
            ? "\(baseline.short) needs \(Fmt.int(base.total)) hosts" + (others.isEmpty ? "" : " (\(others.joined(separator: ", ")))")
                + (alt.isEmpty ? "" : "; " + alt.joined(separator: ", "))
            : "These VMs don't fit the host model on \(baseline.short)"

        return SolutionResult(headline: headline, sections: [
            .metrics("Summary", metrics),
            .table(hostsTable),
            .table(gapTable),
            .table(mgmtTable),
            .table(overheadTable),
            .checks("Migration considerations", cb.checks, subtitle: "What needs work when these VMs leave vSphere, whichever platform they go to."),
            .notes("How it's sized", notes),
        ])
    }
}
