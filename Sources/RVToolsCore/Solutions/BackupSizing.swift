import Foundation

/// Vendor-neutral image-level backup sizing: repository capacity (restore points + GFS), offsite copy,
/// throughput for the backup window, licensing counts and coverage gaps.
public struct BackupSizing: Solution {
    public init() {}
    public var id: String { "backup" }
    public var title: String { "Backup Sizing" }
    public var symbol: String { "externaldrive.badge.timemachine" }
    public var summary: String { "Repository and offsite-copy capacity, throughput and licensing for the selected VMs." }

    public var parameters: [SolutionParameter] { [
        .choice("basis", "Source data", "Size backups from", ["Guest used space (fallback: VM in-use)", "VM in-use (excluding swap)", "Provisioned disk size"],
                help: "Guest used space comes from vPartition and needs VMware Tools; image backups skip unallocated and (with file-system awareness) deleted blocks."),
        .number("change", "Source data", "Daily change rate", 3, min: 0.1, max: 50, step: 0.5, unit: "%"),
        .number("growth", "Source data", "Annual data growth", 10, min: 0, max: 100, unit: "%"),
        .number("years", "Source data", "Sizing horizon", 3, min: 0, max: 10, unit: "years"),
        .number("reduction", "Repository", "Data reduction (compression + dedupe)", 2, min: 1, max: 20, step: 0.1, unit: ": 1"),
        .toggle("fastclone", "Repository", "Space-efficient synthetic fulls", true,
                help: "Block cloning (ReFS / XFS) or a deduplicating target: each GFS full only stores the unique data changed since the previous one."),
        .number("weeklyUnique", "Repository", "Unique change per weekly point", 10, min: 0, max: 100, unit: "% of a full",
                help: "Used with space-efficient fulls. Daily changes largely rewrite the same blocks, so unique change grows much slower than days × daily rate."),
        .number("monthlyUnique", "Repository", "Unique change per monthly point", 20, min: 0, max: 100, unit: "% of a full"),
        .number("yearlyUnique", "Repository", "Unique change per yearly point", 40, min: 0, max: 100, unit: "% of a full"),
        .number("headroom", "Repository", "Free-space headroom", 20, min: 0, max: 100, unit: "%"),
        .number("daily", "Retention", "Daily restore points", 14, min: 1, max: 365),
        .number("weekly", "Retention", "Weekly GFS fulls", 4, min: 0, max: 520),
        .number("monthly", "Retention", "Monthly GFS fulls", 12, min: 0, max: 120),
        .number("yearly", "Retention", "Yearly GFS fulls", 0, min: 0, max: 30),
        .toggle("copy", "Offsite copy", "Keep an offsite / immutable copy", true,
                help: "3-2-1: a second copy with the same restore points (object storage, cloud or a second repository)."),
        .number("window", "Throughput", "Backup window", 8, min: 1, max: 24, unit: "hours"),
    ] }

    public func defaultSelection(_ inventory: Inventory) -> Set<String> {
        Set(inventory.workloadVMs.map(\.id))
    }

    struct Source {
        let mib: Double
        let excludedMiB: Double
        let basis: String
    }

    /// Protected data for one VM; independent, RDM and shared disks are excluded from image-level backup.
    static func source(_ vm: VM, basis: Int) -> Source {
        let diskCap = vm.diskCapacityMiB
        let excludedCap = vm.disks.filter { $0.isIndependent || $0.raw || $0.isSharedWriter }.reduce(0) { $0 + $1.capacityMiB }
        let fraction = diskCap > 0 ? max(0, 1 - excludedCap / diskCap) : 1
        let raw: Double
        let label: String
        switch basis {
        case 0:
            if vm.guestConsumedMiB > 0 { raw = vm.guestConsumedMiB; label = "Guest used" } else { raw = vm.inUseExcludingSwapMiB; label = "In use" }
        case 1:
            raw = vm.inUseExcludingSwapMiB; label = "In use"
        default:
            raw = diskCap > 0 ? diskCap : vm.provisionedMiB; label = "Provisioned"
        }
        return Source(mib: raw * fraction, excludedMiB: raw * (1 - fraction), basis: label)
    }

    public func run(vms: [VM], inventory inv: Inventory, params p: Params) -> SolutionResult {
        let basis = p.choice("basis")
        let c = p.num("change") / 100
        let reduction = max(p.num("reduction"), 1)
        let daily = max(p.num("daily"), 1), weekly = p.num("weekly"), monthly = p.num("monthly"), yearly = p.num("yearly")
        let years = p.num("years")
        let growth = pow(1 + p.num("growth") / 100, years)
        let headroom = p.num("headroom") / 100
        let fastClone = p.flag("fastclone"), offsite = p.flag("copy")
        let windowSec = max(p.num("window"), 1) * 3600

        let sources = vms.map { (vm: $0, s: BackupSizing.source($0, basis: basis)) }
        let protected = sources.reduce(0) { $0 + $1.s.mib }
        let excluded = sources.reduce(0) { $0 + $1.s.excludedMiB }

        /// Repository footprint for `s` MiB of protected data (before growth and headroom).
        let unique = (weekly: p.num("weeklyUnique") / 100, monthly: p.num("monthlyUnique") / 100, yearly: p.num("yearlyUnique") / 100)
        func footprint(_ s: Double) -> (full: Double, incr: Double, weekly: Double, monthly: Double, yearly: Double) {
            let f = s / reduction, i = s * c / reduction
            let point = { (fraction: Double) -> Double in fastClone ? f * min(1, fraction) : f }
            return (f, (daily - 1) * i, weekly * point(unique.weekly), monthly * point(unique.monthly), yearly * point(unique.yearly))
        }
        func total(_ fp: (full: Double, incr: Double, weekly: Double, monthly: Double, yearly: Double)) -> Double {
            fp.full + fp.incr + fp.weekly + fp.monthly + fp.yearly
        }
        let fp = footprint(protected)
        let subtotal = total(fp)
        let head = subtotal * growth * headroom
        let primary = subtotal * growth + head
        let copy = offsite ? primary : 0

        // Throughput
        let fullMiBps = protected / windowSec
        let incrMiBps = protected * c / windowSec

        // Licensing footprint
        let hostIDs = Set(vms.map(\.hostKey))
        let hosts = inv.hosts.filter { hostIDs.contains($0.id) }
        let clusterIDs = Set(vms.map(\.clusterKey))
        let clusterHosts = inv.hosts.filter { clusterIDs.contains($0.clusterKey) && !$0.isVirtual }

        let running = vms.filter(\.isRunning).count
        let guestBased = sources.filter { $0.s.basis == "Guest used" }.count
        let yrs = SFmt.num(years)

        var sections: [SolutionSection] = [
            .metrics("Summary", [
                SolutionMetric("VMs protected", Fmt.int(vms.count), "\(running) powered on · \(vms.count - running) off", symbol: "desktopcomputer"),
                SolutionMetric("Protected data", Fmt.capacity(mib: protected),
                               basis == 0 ? "guest used for \(guestBased) VMs, in-use for \(vms.count - guestBased)" : "from \(sources.first?.s.basis.lowercased() ?? "in-use")",
                               symbol: "internaldrive"),
                SolutionMetric("Daily change", Fmt.capacity(mib: protected * c), "\(SFmt.num(c * 100))% per day", symbol: "arrow.triangle.2.circlepath"),
                SolutionMetric("Primary repository", Fmt.capacity(mib: primary), "\(yrs)-yr horizon incl. growth and \(SFmt.num(headroom * 100))% headroom", symbol: "externaldrive"),
                SolutionMetric("Offsite copy", offsite ? Fmt.capacity(mib: copy) : "Not included", offsite ? "same restore points" : "", symbol: "icloud"),
                SolutionMetric("Throughput (active full)", Fmt.rate(mbps: fullMiBps * mibToMegabits), "incremental: \(Fmt.rate(mbps: incrMiBps * mibToMegabits))", symbol: "speedometer"),
            ]),
        ]

        let rows: [[String]] = [
            ["Full backup", "1", Fmt.capacity(mib: fp.full), Fmt.capacity(mib: fp.full * growth)],
            ["Incrementals", SFmt.num(daily - 1), Fmt.capacity(mib: fp.incr), Fmt.capacity(mib: fp.incr * growth)],
            ["Weekly GFS", SFmt.num(weekly), Fmt.capacity(mib: fp.weekly), Fmt.capacity(mib: fp.weekly * growth)],
            ["Monthly GFS", SFmt.num(monthly), Fmt.capacity(mib: fp.monthly), Fmt.capacity(mib: fp.monthly * growth)],
            ["Yearly GFS", SFmt.num(yearly), Fmt.capacity(mib: fp.yearly), Fmt.capacity(mib: fp.yearly * growth)],
            ["Subtotal", SFmt.num(daily + weekly + monthly + yearly), Fmt.capacity(mib: subtotal), Fmt.capacity(mib: subtotal * growth)],
            ["Headroom (\(SFmt.num(headroom * 100))%)", "", Fmt.capacity(mib: subtotal * headroom), Fmt.capacity(mib: head)],
            ["Primary repository", "", Fmt.capacity(mib: subtotal * (1 + headroom)), Fmt.capacity(mib: primary)],
            ["Offsite copy", offsite ? "same" : "—", offsite ? Fmt.capacity(mib: subtotal * (1 + headroom)) : "—", offsite ? Fmt.capacity(mib: copy) : "—"],
            ["Total backup storage", "", Fmt.capacity(mib: subtotal * (1 + headroom) * (offsite ? 2 : 1)), Fmt.capacity(mib: primary + copy)],
        ]
        sections.append(.table(SolutionTable(id: "repository", title: "Repository capacity", subtitle: "Today vs. \(yrs)-year horizon at \(SFmt.num(p.num("growth")))% annual growth",
                                             columns: ["Component", "Restore points", "Today", "In \(yrs) years"], numeric: [1, 2, 3], rows: rows, emphasized: [5, 7, 9])))

        sections.append(.table(SolutionTable(id: "throughput", title: "Throughput for the \(SFmt.num(windowSec / 3600))-hour backup window",
                                             columns: ["Job", "Data per run", "Storage rate", "Network rate"], numeric: [1, 2, 3], rows: [
                                                 ["Active full", Fmt.capacity(mib: protected), Fmt.dataRate(mibPerSec: fullMiBps), Fmt.rate(mbps: fullMiBps * mibToMegabits)],
                                                 ["Daily incremental", Fmt.capacity(mib: protected * c), Fmt.dataRate(mibPerSec: incrMiBps), Fmt.rate(mbps: incrMiBps * mibToMegabits)],
                                             ])))

        sections.append(.table(SolutionTable(id: "licensing", title: "Licensing footprint", subtitle: "For per-workload, per-socket or per-host licensing models",
                                             columns: ["Metric", "Value"], numeric: [1], rows: [
                                                 ["VMs (per-workload licensing)", Fmt.int(vms.count)],
                                                 ["Hosts running the selected VMs", Fmt.int(hosts.count)],
                                                 ["CPU sockets on those hosts", Fmt.int(hosts.reduce(0) { $0 + $1.sockets })],
                                                 ["Cores on those hosts", Fmt.int(hosts.reduce(0) { $0 + $1.cores })],
                                                 ["Clusters involved", Fmt.int(clusterIDs.count)],
                                                 ["All hosts / sockets in those clusters", "\(clusterHosts.count) / \(clusterHosts.reduce(0) { $0 + $1.sockets })"],
                                             ])))

        var byCluster: [String: (Int, Double)] = [:], byOS: [String: (Int, Double)] = [:]
        for (vm, s) in sources {
            let cn = clusterName(inv, vm)
            byCluster[cn, default: (0, 0)].0 += 1; byCluster[cn]!.1 += s.mib
            byOS[vm.os.family.rawValue, default: (0, 0)].0 += 1; byOS[vm.os.family.rawValue]!.1 += s.mib
        }
        let toItems = { (d: [String: (Int, Double)]) in d.map { CountItem(label: $0.key, count: $0.value.0, value: $0.value.1) }.sorted { $0.value > $1.value } }
        sections.append(.bars("Protected data by cluster", "", toItems(byCluster), .capacityMiB))
        sections.append(.bars("Protected data by OS family", "", toItems(byOS), .capacityMiB))

        // Coverage & consistency considerations
        var b = CheckBuilder()
        let indep = vms.filter { $0.disks.contains(where: \.isIndependent) }.map { vm in
            vm.ref(vm.disks.filter(\.isIndependent).map { "\($0.label) \(Fmt.capacity(mib: $0.capacityMiB)) (\($0.mode))" }.joined(separator: ", "))
        }
        b.list("indep", "Coverage", "Independent disks are skipped", .warning, noun: "VMs have independent disks", affected: indep,
               ready: "No independent disks", remediation: "Snapshot-based backups skip independent disks. Change the disk mode or protect the data with an in-guest agent.")
        let rdm = vms.filter { $0.disks.contains(where: \.raw) }.map { vm in
            vm.ref(vm.disks.filter(\.raw).map { "\($0.label) \(Fmt.capacity(mib: $0.capacityMiB))" }.joined(separator: ", "))
        }
        b.list("rdm", "Coverage", "Raw device mappings", .warning, noun: "VMs have RDMs", affected: rdm,
               ready: "No RDM disks", remediation: "Physical-mode RDMs can't be snapshotted — use an in-guest agent or storage snapshots. Virtual-mode RDMs back up like VMDKs.")
        let shared = vms.filter { $0.disks.contains(where: \.isSharedWriter) }.map { $0.ref("shared / multi-writer disk") }
        b.list("shared", "Coverage", "Shared / multi-writer disks", .warning, noun: "VMs use shared disks", affected: shared,
               ready: "No shared disks", remediation: "Clustered VMs (WSFC, Oracle RAC) can't be snapshotted; protect them with application-level backups.")
        let consolidate = vms.filter(\.consolidationNeeded).map { $0.ref("consolidation needed") }
        b.list("consolidate", "Consistency", "Disk consolidation needed", .blocker, noun: "VMs need consolidation", affected: consolidate,
               ready: "No VMs need consolidation", remediation: "Consolidate snapshots before the first backup; backup jobs fail on broken chains.")
        let noTools = vms.filter { $0.isRunning && ["Not installed", "Not running"].contains($0.toolsDisplay) }.map { $0.ref("VMware Tools: \($0.toolsDisplay.lowercased())") }
        b.list("tools", "Consistency", "No application-consistent quiescing", .warning, noun: "powered-on VMs without running VMware Tools", affected: noTools,
               ready: "VMware Tools runs on every powered-on VM", remediation: "Install / start VMware Tools so backups can quiesce applications (VSS / pre-freeze scripts).")
        let snaps = vms.filter { !$0.snapshots.isEmpty }.map { $0.ref("\($0.snapshots.count) snapshot(s), \(Fmt.capacity(mib: $0.snapshotSizeMiB))") }
        b.list("snaps", "Consistency", "Existing snapshots", .info, noun: "VMs already have snapshots", affected: snaps,
               ready: "No existing snapshots", remediation: "Remove stale snapshots before onboarding; they add I/O during backup and can hide consolidation problems.")
        if vms.contains(where: { $0.cbt != nil }) {
            let noCBT = vms.filter { $0.isRunning && $0.cbt == false }.map { $0.ref("CBT disabled") }
            b.list("cbt", "Performance", "Changed Block Tracking", .info, noun: "powered-on VMs have CBT disabled", affected: noCBT,
                   ready: "CBT enabled on all powered-on VMs", remediation: "Most backup products enable CBT on first run (it needs a snapshot cycle); confirm that is allowed.")
        }
        let large = sources.filter { $0.s.mib > 10 * 1024 * 1024 }.map { $0.vm.ref(Fmt.capacity(mib: $0.s.mib)) }
        b.list("large", "Performance", "Very large VMs (> 10 TB)", .info, noun: "VMs exceed 10 TB of protected data", affected: large,
               ready: "No VMs over 10 TB", remediation: "Enable per-disk parallel processing and consider seeding the first full.")
        let apps = vms.filter { regexMatch($0.name, #"sql|ora|db|mongo|postgres|mysql|exch|sap|hana"#) != nil }.map { $0.ref($0.os.name) }
        if !apps.isEmpty {
            b.add("apps", "Application awareness", "Likely database / application servers", .info, "\(apps.count) VMs by name (SQL, ORA, DB, EXCH, SAP, …)",
                  remediation: "Enable application-aware processing and transaction-log backups for these.", affected: apps)
        }
        let off = vms.filter { !$0.isRunning && !$0.isTemplate }
        if !off.isEmpty {
            b.add("off", "Scope", "Powered-off VMs included", .info, "\(off.count) VMs — one full, then almost no change",
                  remediation: "Confirm they still need protection; archive-and-delete may be cheaper.", affected: off.map { $0.ref(Fmt.capacity(mib: $0.inUseMiB)) })
        }
        let templates = vms.filter(\.isTemplate)
        if !templates.isEmpty {
            b.add("templates", "Scope", "Templates included", .info, "\(templates.count) templates", affected: templates.map(\.vmRef))
        }
        sections.append(.checks("Backup considerations", b.checks))

        let perVM = sources.sorted { $0.s.mib > $1.s.mib }
        sections.append(.table(SolutionTable(
            id: "per-vm", title: "Per-VM sizing", subtitle: "Footprint today, before growth and headroom",
            columns: ["VM", "Cluster", "Power", "Guest OS", "Basis", "Protected", "Excluded", "Change / day", "Repository footprint"],
            numeric: [5, 6, 7, 8],
            rows: perVM.map { vm, s in
                [vm.name, clusterName(inv, vm), vm.powerLabel, vm.os.name, s.basis, Fmt.capacity(mib: s.mib),
                 s.excludedMiB > 0 ? Fmt.capacity(mib: s.excludedMiB) : "", Fmt.capacity(mib: s.mib * c), Fmt.capacity(mib: total(footprint(s.mib)))]
            },
            rowRefs: perVM.map { $0.vm.vmRef })))

        sections.append(.notes("Method", [
            "Protected data per VM = the chosen basis, minus independent, RDM and shared disks (their share of disk capacity). VM in-use excludes the swap file of running VMs.",
            "Full = protected ÷ data reduction; each incremental = protected × daily change ÷ data reduction.",
            fastClone
                ? "GFS fulls are space-efficient: each stores only the unique data changed since the previous point — \(SFmt.num(unique.weekly * 100))% (weekly), \(SFmt.num(unique.monthly * 100))% (monthly) and \(SFmt.num(unique.yearly * 100))% (yearly) of a full."
                : "GFS fulls are stored as independent full backups.",
            "Capacity grows by \(SFmt.num(p.num("growth")))% a year for \(yrs) years; \(SFmt.num(headroom * 100))% headroom is added on top. The offsite copy mirrors the primary retention.",
            "Excluded from protection today: \(Fmt.capacity(mib: excluded)).",
        ]))

        let headline = "\(Fmt.int(vms.count)) VMs · \(Fmt.capacity(mib: protected)) protected → \(Fmt.capacity(mib: primary)) primary repository"
            + (offsite ? " + \(Fmt.capacity(mib: copy)) offsite" : "") + " at a \(yrs)-year horizon"
        return SolutionResult(headline: headline, sections: sections)
    }
}
