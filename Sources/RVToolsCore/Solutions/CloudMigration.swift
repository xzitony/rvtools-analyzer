import Foundation

/// A solution whose results depend on downloaded cloud list prices (see `PriceStore`).
public protocol PricedSolution: Solution {
    var provider: CloudProvider { get }
    func regions(_ params: Params) -> [String]
}

/// Right-sizes VMs onto Azure or AWS instance families and estimates monthly cost per region from public
/// list prices: best-fit instance per VM, managed disks / EBS, pricing-model and licensing options.
public struct CloudMigration: PricedSolution {
    public let provider: CloudProvider
    public init(_ provider: CloudProvider) { self.provider = provider }

    public var id: String { provider.rawValue }
    public var title: String { "\(provider.name) Migration" }
    public var symbol: String { provider == .azure ? "cloud" : "cloud.fill" }
    public var summary: String { "Right-size the selected VMs onto \(provider.name) instances and compare monthly list-price estimates across regions." }

    static let azureFamilies = ["Dsv5", "Dasv5", "Esv5", "Easv5", "Fsv2", "Dsv6", "Dasv6", "Esv6", "Easv6"]
    static let awsFamilies = ["m6i", "m7i", "m6a", "m7a", "r6i", "r7i", "r6a", "r7a", "c6i", "c7i", "c6a", "c7a", "m5", "r5", "c5", "t3"]

    var families: [String] { provider == .azure ? Self.azureFamilies : Self.awsFamilies }
    var familyLabels: [String] {
        provider == .azure
            ? ["Dsv5 · general, Intel", "Dasv5 · general, AMD", "Esv5 · memory, Intel", "Easv5 · memory, AMD", "Fsv2 · compute, Intel",
               "Dsv6 · general, Intel", "Dasv6 · general, AMD", "Esv6 · memory, Intel (≤ 64 vCPU)", "Easv6 · memory, AMD (≤ 64 vCPU)"]
            : ["m6i · general, Intel", "m7i · general, Intel", "m6a · general, AMD", "m7a · general, AMD", "r6i · memory, Intel", "r7i · memory, Intel",
               "r6a · memory, AMD", "r7a · memory, AMD", "c6i · compute, Intel", "c7i · compute, Intel", "c6a · compute, AMD", "c7a · compute, AMD",
               "m5 · general, previous gen", "r5 · memory, previous gen", "c5 · compute, previous gen", "t3 · burstable"]
    }
    var regionList: [CloudRegion] { CloudRegions.list(provider) }

    public var parameters: [SolutionParameter] {
        var p: [SolutionParameter] = [
            .multi("regions", "Regions", "Regions to compare", regionList.map { "\($0.name) · \($0.code)" },
                   selected: provider == .azure ? [0, 1, 2, 6] : [0, 1, 3],
                   help: "Prices are downloaded per region; the cheapest region gets the detailed breakdown."),
        ]
        if provider == .azure {
            p += [
                .choice("pricing", "Pricing", "Pricing model", ["Pay-as-you-go", "1-year reserved instances", "3-year reserved instances"]),
                .choice("windows", "Pricing", "Windows Server licensing", ["License included", "Azure Hybrid Benefit (bring your own)"]),
            ]
        } else {
            p += [
                .number("discount", "Pricing", "Commitment discount on compute", 0, min: 0, max: 80, unit: "%",
                        help: "Savings Plans / Reserved Instances. AWS doesn't publish commitment prices in a lightweight public file — enter your expected discount (0 = on-demand)."),
                .choice("windows", "Pricing", "Windows Server licensing", ["License included", "Bring your own license (priced as Linux)"]),
            ]
        }
        p += [
            .number("hours", "Pricing", "Running hours per month", 730, min: 1, max: 744, unit: "hours"),
            .choice("off", "Scope", "Powered-off VMs", ["Storage only (deallocated)", "Price as running", "Exclude"]),
            .multi("families", "Instances", "Instance families", familyLabels, selected: provider == .azure ? [0, 1, 2, 3, 4] : [0, 1, 2, 4, 5, 6, 8, 9, 10]),
            .choice("cpu", "Right-sizing", "vCPU sizing", ["As configured", "From CPU usage in the export (+ buffer)"],
                    help: "RVTools is a point-in-time snapshot — validate right-sizing with performance history before committing."),
            .choice("mem", "Right-sizing", "Memory sizing", ["As configured", "From consumed memory in the export (+ buffer)"]),
            .number("buffer", "Right-sizing", "Right-sizing buffer", 25, min: 0, max: 200, unit: "%"),
            .number("minCPU", "Right-sizing", "Minimum vCPU", 2, min: 1, max: 16),
            .number("minMem", "Right-sizing", "Minimum memory", 4, min: 1, max: 64, unit: "GiB"),
            provider == .azure
                ? .choice("disk", "Storage", "Managed disk type", ["Premium SSD", "Standard SSD", "Standard HDD"])
                : .choice("disk", "Storage", "EBS volume type", ["gp3", "gp2", "st1 (throughput HDD)"]),
            .choice("diskBasis", "Storage", "Size disks from", ["Provisioned disk size", "Guest used space + headroom"]),
            .number("diskHead", "Storage", "Disk headroom (guest used basis)", 20, min: 0, max: 200, unit: "%"),
        ]
        return p
    }

    public func defaultSelection(_ inventory: Inventory) -> Set<String> {
        Set(inventory.vms.filter(\.isVM).map(\.id))
    }

    public func regions(_ params: Params) -> [String] {
        params.multi("regions").compactMap { regionList.indices.contains($0) ? regionList[$0].code : nil }
    }

    // MARK: Model

    struct Demand {
        let vm: VM
        let vcpu: Int
        let memGiB: Double
        let windows: Bool
        let diskGiB: [Double]
        let rightsized: Bool
    }

    typealias Disk = CloudSizing.Disk

    struct Line {
        let d: Demand
        let offer: InstanceOffer?
        let hourly: Double
        let compute: Double
        let disks: [Disk]
        var storage: Double { disks.reduce(0) { $0 + $1.monthly } }
        var total: Double { compute + storage }
    }

    struct Eval {
        let code: String
        let prices: RegionPrices?
        let lines: [Line]
        var compute: Double { lines.reduce(0) { $0 + $1.compute } }
        var storage: Double { lines.reduce(0) { $0 + $1.storage } }
        var total: Double { compute + storage }
        var unmatched: [Line] { lines.filter { $0.offer == nil && ($0.d.vm.isRunning || $0.compute > 0 || $0.hourly < 0) } }
    }

    func demand(_ vm: VM, _ p: Params, _ hostSpeed: [String: Double], rightsize: Bool) -> Demand {
        var o = CloudSizing.DemandOptions()
        o.rightsizeCPU = rightsize && p.choice("cpu") == 1
        o.rightsizeMemory = rightsize && p.choice("mem") == 1
        o.bufferPct = p.num("buffer")
        o.minVCPU = Int(p.num("minCPU"))
        o.minMemoryGiB = p.num("minMem")
        o.diskFromGuestUsage = p.choice("diskBasis") == 1
        o.diskHeadroomPct = p.num("diskHead")
        let s = CloudSizing.demand(vm, o, hostSpeedMHz: hostSpeed[vm.hostKey])
        return Demand(vm: vm, vcpu: s.vcpu, memGiB: s.memoryGiB, windows: s.windows, diskGiB: s.diskGiB, rightsized: s.rightsized)
    }

    /// Hourly price for an offer under the chosen pricing model and licensing (nil if not purchasable).
    func hourly(_ o: InstanceOffer, windows: Bool, _ p: Params, model: Int?, windowsChoice: Int?, discount: Double?) -> Double? {
        let licenseIncluded = (windowsChoice ?? p.choice("windows")) == 0
        if provider == .azure {
            let m: CloudSizing.PriceModel = [.payg, .reserved1y, .reserved3y][min(max(model ?? p.choice("pricing"), 0), 2)]
            return CloudSizing.hourly(o, windows: windows, licenseIncluded: licenseIncluded, model: m, discountPct: 0)
        }
        return CloudSizing.hourly(o, windows: windows, licenseIncluded: licenseIncluded, model: .payg, discountPct: discount ?? p.num("discount"))
    }

    func disk(_ gib: Double, _ prices: RegionPrices, _ p: Params) -> Disk {
        if provider == .azure {
            return CloudSizing.azureManagedDisk(gib: gib, prefix: ["P", "E", "S"][min(max(p.choice("disk"), 0), 2)], storage: prices.storage)
        }
        return CloudSizing.awsVolume(gib: gib, type: ["gp3", "gp2", "st1"][min(max(p.choice("disk"), 0), 2)], storage: prices.storage)
    }

    func evaluate(_ code: String, _ demands: [Demand], _ allowed: Set<String>, _ p: Params,
                  model: Int? = nil, windowsChoice: Int? = nil, discount: Double? = nil) -> Eval {
        guard let prices = PriceStore.shared.prices(provider, code) else { return Eval(code: code, prices: nil, lines: []) }
        let offers = prices.instances.filter { allowed.contains($0.family) }
        let hours = p.num("hours")
        let off = p.choice("off")
        let lines = demands.map { d -> Line in
            let runs = d.vm.isRunning || off == 1
            let fits = offers.filter { $0.vcpu >= d.vcpu && $0.memoryGiB >= d.memGiB - 0.01 }
                .compactMap { o in hourly(o, windows: d.windows, p, model: model, windowsChoice: windowsChoice, discount: discount).map { (o, $0) } }
            let best = fits.min { ($0.1, $0.0.vcpu, $0.0.memoryGiB) < ($1.1, $1.0.vcpu, $1.0.memoryGiB) }
            let disks = d.diskGiB.map { disk($0, prices, p) }
            return Line(d: d, offer: best?.0, hourly: best?.1 ?? (runs ? -1 : 0), compute: runs ? (best?.1 ?? 0) * hours : 0, disks: disks)
        }
        return Eval(code: code, prices: prices, lines: lines)
    }

    // MARK: Run

    public func run(vms: [VM], inventory inv: Inventory, params p: Params) -> SolutionResult {
        let codes = regions(p)
        let off = p.choice("off")
        let allowed = Set(p.multi("families").compactMap { families.indices.contains($0) ? families[$0] : nil })
        let speed = Dictionary(inv.hosts.map { ($0.id, $0.speedMHz) }, uniquingKeysWith: { a, _ in a })
        let inScope = vms.filter { !$0.isTemplate && (off != 2 || $0.isRunning) }
        let demands = inScope.map { demand($0, p, speed, rightsize: true) }
        let evals = codes.map { evaluate($0, demands, allowed, p) }
        let missing = evals.filter { $0.prices == nil }.map(\.code)
        let name = { (code: String) in CloudRegions.name(provider, code) }

        guard let best = evals.filter({ $0.prices != nil }).min(by: { $0.total < $1.total }) else {
            var b = CheckBuilder()
            b.add("prices", "Pricing", "\(provider.name) prices not downloaded", .blocker,
                  codes.isEmpty ? "Choose at least one region under Assumptions." : "Use Download Prices to fetch list prices for \(codes.count) region(s).",
                  remediation: "Only public price lists are downloaded; no inventory data leaves this Mac.")
            return SolutionResult(headline: "\(inScope.count) VMs selected — download \(provider.name) prices to see estimates",
                                  sections: [.checks("Pricing", b.checks)])
        }

        let configured = inScope.map { demand($0, p, speed, rightsize: false) }
        let asConfigured = evaluate(best.code, configured, allowed, p)
        let rightsizedCount = demands.filter(\.rightsized).count
        let savings = asConfigured.total - best.total
        let cheapestName = name(best.code)
        let fetched = best.prices!.fetched

        let modelName: String = provider == .azure
            ? ["pay-as-you-go", "1-year reserved", "3-year reserved"][min(p.choice("pricing"), 2)]
            : (p.num("discount") > 0 ? "on-demand less \(SFmt.num(p.num("discount")))%" : "on-demand")
        let cfgCPU = configured.reduce(0) { $0 + $1.vcpu }, tgtCPU = demands.reduce(0) { $0 + $1.vcpu }
        let cfgMem = configured.reduce(0) { $0 + $1.memGiB }, tgtMem = demands.reduce(0) { $0 + $1.memGiB }

        var sections: [SolutionSection] = [
            .metrics("Summary", [
                SolutionMetric("VMs priced", Fmt.int(inScope.count - best.unmatched.count),
                               best.unmatched.isEmpty ? "all selected VMs matched" : "\(best.unmatched.count) without a fitting instance", symbol: "desktopcomputer"),
                SolutionMetric("Monthly estimate", SFmt.usd(best.total), "\(cheapestName) · \(modelName)", symbol: "dollarsign.circle"),
                SolutionMetric("Annual estimate", SFmt.usd(best.total * 12), "compute + storage list prices", symbol: "calendar"),
                SolutionMetric("Compute / storage", "\(SFmt.usd(best.compute)) / \(SFmt.usd(best.storage))", "per month", symbol: "cpu"),
                SolutionMetric("Target size", "\(Fmt.int(tgtCPU)) vCPU", "\(Fmt.int(Int(tgtMem))) GiB (configured: \(Fmt.int(cfgCPU)) vCPU, \(Fmt.int(Int(cfgMem))) GiB)", symbol: "arrow.down.right.and.arrow.up.left"),
                SolutionMetric("Right-sizing savings", SFmt.usd(max(savings, 0)), rightsizedCount > 0 ? "\(rightsizedCount) VMs downsized, per month" : "right-sizing is off (Assumptions)", symbol: "scissors"),
            ]),
        ]

        // Region comparison
        let regionRows = evals.sorted { ($0.prices == nil ? 1 : 0, $0.total) < ($1.prices == nil ? 1 : 0, $1.total) }
        sections.append(.table(SolutionTable(
            id: "regions", title: "Region comparison", subtitle: "\(modelName.prefix(1).uppercased() + modelName.dropFirst()) list prices, USD",
            columns: ["Region", "Compute / month", "Storage / month", "Total / month", "Total / year", "vs cheapest", "Prices from"], numeric: [1, 2, 3, 4, 5],
            rows: regionRows.map { e in
                guard let pr = e.prices else { return ["\(name(e.code)) (\(e.code))", "—", "—", "—", "—", "—", "not downloaded"] }
                let delta = e.total - best.total
                return ["\(name(e.code)) (\(e.code))", SFmt.usd(e.compute), SFmt.usd(e.storage), SFmt.usd(e.total), SFmt.usd(e.total * 12),
                        delta < 0.5 ? "cheapest" : "+\(SFmt.usd(delta)) (\(Fmt.pct(delta / max(best.total, 1) * 100)))", Fmt.date(pr.fetched)]
            },
            emphasized: [0])))
        sections.append(.bars("Monthly cost by region", "", evals.filter { $0.prices != nil }.sorted { $0.total < $1.total }
            .map { CountItem(label: name($0.code), count: $0.lines.count, value: $0.total) }, .currency))

        // Pricing & licensing options in the cheapest region
        var optionRows: [[String]] = []
        func optionRow(_ label: String, _ e: Eval) { optionRows.append([label, SFmt.usd(e.compute), SFmt.usd(e.total), SFmt.usd(e.total * 12), SFmt.usd(e.total - best.total)]) }
        if provider == .azure {
            for (i, label) in ["Pay-as-you-go", "1-year reserved instances", "3-year reserved instances"].enumerated() {
                optionRow(label, evaluate(best.code, demands, allowed, p, model: i))
            }
        } else {
            optionRow("On-demand", evaluate(best.code, demands, allowed, p, discount: 0))
            if p.num("discount") > 0 { optionRow("With \(SFmt.num(p.num("discount")))% commitment discount", best) }
        }
        let windowsVMs = demands.filter(\.windows).count
        if windowsVMs > 0 {
            let alt = p.choice("windows") == 0 ? 1 : 0
            let altLabel = provider == .azure ? (alt == 1 ? "With Azure Hybrid Benefit" : "With Windows license included")
                                              : (alt == 1 ? "With Windows BYOL" : "With Windows license included")
            optionRow("\(altLabel) (\(windowsVMs) Windows VMs)", evaluate(best.code, demands, allowed, p, windowsChoice: alt))
        }
        sections.append(.table(SolutionTable(id: "options", title: "Pricing and licensing options", subtitle: "\(cheapestName); difference vs the current assumptions",
                                             columns: ["Option", "Compute / month", "Total / month", "Total / year", "Difference / month"], numeric: [1, 2, 3, 4], rows: optionRows)))

        // Right-sizing
        sections.append(.table(SolutionTable(id: "rightsizing", title: "Right-sizing", subtitle: "Configured vs target size in \(cheapestName)",
                                             columns: ["Metric", "As configured", "Target", "Change"], numeric: [1, 2, 3], rows: [
                                                 ["vCPU", Fmt.int(cfgCPU), Fmt.int(tgtCPU), Fmt.int(tgtCPU - cfgCPU)],
                                                 ["Memory (GiB)", Fmt.int(Int(cfgMem)), Fmt.int(Int(tgtMem)), Fmt.int(Int(tgtMem - cfgMem))],
                                                 ["Monthly cost", SFmt.usd(asConfigured.total), SFmt.usd(best.total), SFmt.usd(best.total - asConfigured.total)],
                                                 ["VMs downsized", "", Fmt.int(rightsizedCount), ""],
                                             ])))

        // Instance mix
        var mix: [String: (offer: InstanceOffer, count: Int, hourly: Double, monthly: Double)] = [:]
        for l in best.lines {
            guard let o = l.offer, l.compute > 0 else { continue }
            var e = mix[o.name] ?? (o, 0, l.hourly, 0)
            e.count += 1; e.monthly += l.compute
            mix[o.name] = e
        }
        let mixRows = mix.values.sorted { $0.monthly > $1.monthly }
        sections.append(.table(SolutionTable(id: "instances", title: "Instance mix", subtitle: "\(cheapestName) · running VMs",
                                             columns: ["Instance", "Category", "vCPU", "Memory", "VMs", "Compute / month"], numeric: [2, 3, 4, 5],
                                             rows: mixRows.map { [$0.offer.displayName, $0.offer.category, "\($0.offer.vcpu)", "\(SFmt.num($0.offer.memoryGiB)) GiB",
                                                                  Fmt.int($0.count), SFmt.usd($0.monthly)] })))

        // Storage mix
        var tiers: [String: (count: Int, gib: Double, cost: Double)] = [:]
        for l in best.lines { for d in l.disks { let k = provider == .azure ? d.label : d.label; var e = tiers[k] ?? (0, 0, 0); e.count += 1; e.gib += d.gib; e.cost += d.monthly; tiers[k] = e } }
        sections.append(.table(SolutionTable(id: "storage", title: provider == .azure ? "Managed disks" : "EBS volumes", subtitle: cheapestName,
                                             columns: ["Type / tier", "Disks", "Capacity", "Storage / month"], numeric: [1, 2, 3],
                                             rows: tiers.sorted { $0.value.cost > $1.value.cost }.map { [$0.key, Fmt.int($0.value.count), Fmt.capacity(mib: $0.value.gib * 1024), SFmt.usd($0.value.cost)] })))

        var byCluster: [String: (Int, Double)] = [:], byOS: [String: (Int, Double)] = [:]
        for l in best.lines {
            let c = clusterName(inv, l.d.vm), o = l.d.vm.os.family.rawValue
            byCluster[c, default: (0, 0)].0 += 1; byCluster[c]!.1 += l.total
            byOS[o, default: (0, 0)].0 += 1; byOS[o]!.1 += l.total
        }
        let items = { (d: [String: (Int, Double)]) in d.map { CountItem(label: $0.key, count: $0.value.0, value: $0.value.1) }.sorted { $0.value > $1.value } }
        sections.append(.bars("Monthly cost by source cluster", cheapestName, items(byCluster), .currency))
        sections.append(.bars("Monthly cost by OS family", cheapestName, items(byOS), .currency))

        // Considerations
        var b = CheckBuilder()
        if !missing.isEmpty {
            b.add("prices", "Pricing", "Prices not downloaded", .warning, missing.map(name).joined(separator: ", "),
                  remediation: "Use Download Prices to include these regions in the comparison.")
        }
        let age = Date().timeIntervalSince(fetched)
        b.add("age", "Pricing", "Price list age", age > PriceStore.maxAge ? .warning : .ready,
              "\(provider.name) list prices downloaded \(Fmt.dateTime(fetched))", remediation: age > PriceStore.maxAge ? "Refresh prices for current rates." : "")
        b.list("nofit", "Sizing", "No fitting instance", .blocker, noun: "VMs exceed every instance in the selected families",
               affected: best.unmatched.map { $0.d.vm.ref("needs \($0.d.vcpu) vCPU / \(SFmt.num($0.d.memGiB)) GiB") },
               ready: "Every VM fits an instance in the selected families", remediation: "Add larger or memory-optimized families, or right-size these VMs.")
        let oversize = best.lines.filter { $0.disks.contains(where: \.oversize) }.map { $0.d.vm.ref("disk over the \(provider == .azure ? "32 TiB" : "16 TiB") per-disk limit") }
        b.list("bigdisk", "Storage", "Disks above the per-disk limit", .warning, noun: "VMs", affected: oversize,
               ready: "All disks fit within per-disk limits", remediation: "Split data across multiple disks (priced here as several disks) or use file / object storage.")
        let rdm = inScope.filter { $0.disks.contains { $0.raw || $0.isSharedWriter } }.map { $0.ref("RDM or shared disk") }
        b.list("rdm", "Migration", "RDM / shared disks", .warning, noun: "VMs need storage re-design", affected: rdm,
               ready: "No RDM or shared disks", remediation: provider == .azure ? "Plan Azure shared disks or re-architect clustered workloads." : "Plan EBS Multi-Attach / FSx or re-architect clustered workloads.")
        let desktops = inScope.filter { $0.os.family == .windowsDesktop }.map { $0.ref($0.os.name) }
        b.list("desktop", "Licensing", "Windows client OS VMs", .info, noun: "VMs", affected: desktops, ready: "No Windows client VMs",
               remediation: provider == .azure ? "Windows 10/11 on Azure is licensed through Azure Virtual Desktop." : "Windows client OS on AWS requires WorkSpaces or dedicated hosts with your own licenses.")
        let subscriptions = inScope.filter { [.rhel, .suse].contains($0.os.family) && !$0.os.name.lowercased().contains("centos") && !$0.os.name.lowercased().contains("rocky") && !$0.os.name.lowercased().contains("alma") }
        b.list("linuxsub", "Licensing", "RHEL / SUSE subscriptions not included", .info, noun: "VMs priced as plain Linux", affected: subscriptions.map { $0.ref($0.os.name) },
               ready: "No RHEL / SUSE guests", remediation: "Add pay-as-you-go RHEL/SLES image pricing or bring your own subscriptions.")
        let eol = inScope.compactMap { vm in vm.os.endOfSupport.flatMap { $0 <= inv.reportDate ? vm.ref("\(vm.os.name) — ended \(Fmt.date($0))") : nil } }
        b.list("eol", "Migration", "Guest OS past end of support", .info, noun: "VMs", affected: eol, ready: "No end-of-support guests",
               remediation: "Check \(provider.name)'s support policy (and any extended security updates) or upgrade during migration.")
        let offVMs = inScope.filter { !$0.isRunning }
        if !offVMs.isEmpty {
            b.add("off", "Scope", "Powered-off VMs", .info,
                  off == 1 ? "\(offVMs.count) VMs priced as running" : "\(offVMs.count) VMs priced for storage only (deallocated)", affected: offVMs.map(\.vmRef))
        }
        if provider == .aws && p.num("discount") == 0 {
            b.add("commit", "Pricing", "On-demand pricing", .info, "Estimates use on-demand rates",
                  remediation: "Enter an expected Savings Plan / Reserved Instance discount under Assumptions to model commitments.")
        }
        sections.append(.checks("Migration considerations", b.checks))

        let perVM = best.lines.sorted { $0.total > $1.total }
        sections.append(.table(SolutionTable(
            id: "per-vm", title: "Per-VM estimate", subtitle: cheapestName,
            columns: ["VM", "Cluster", "OS", "Power", "Configured", "Target", "Instance", "Compute / month", "Disks", "Storage / month", "Total / month"],
            numeric: [7, 9, 10],
            rows: perVM.map { l in
                let vm = l.d.vm
                return [vm.name, clusterName(inv, vm), vm.os.name, vm.powerLabel, "\(vm.cpus) vCPU / \(SFmt.num(vm.memoryMiB / 1024)) GiB",
                        "\(l.d.vcpu) vCPU / \(SFmt.num(l.d.memGiB)) GiB", l.offer?.displayName ?? "no fit", SFmt.usd(l.compute),
                        l.disks.map { provider == .azure ? $0.label : "\($0.label) \(Int($0.gib.rounded(.up))) GiB" }.joined(separator: ", "),
                        SFmt.usd(l.storage), SFmt.usd(l.total)]
            },
            rowRefs: perVM.map { $0.d.vm.vmRef })))

        sections.append(.notes("Pricing sources and exclusions", [
            provider == .azure
                ? "Azure Retail Prices API list prices (USD) downloaded \(Fmt.dateTime(fetched)); reserved prices are the published 1- and 3-year reservation rates. Windows licence cost = Windows PAYG − Linux PAYG rate."
                : "AWS public on-demand list prices (USD) from the aws.amazon.com pricing data, downloaded \(Fmt.dateTime(fetched)). Commitment discounts are your input; Windows licence cost = Windows − Linux on-demand rate and is not discounted.",
            "Each VM gets the cheapest instance in the selected families with at least the target vCPU and memory. Target = configured size, or observed usage × (1 + buffer) when right-sizing is on, never below the minimums.",
            "Storage: every VM disk priced as \(provider == .azure ? "a managed disk rounded up to the next tier" : "an EBS volume of the same size (gp3 baseline performance)"). Powered-off VMs: \(["storage only", "priced as running", "excluded"][min(off, 2)]). Templates are excluded.",
            "Not included: network egress and connectivity, backup, monitoring, OS subscriptions (RHEL / SLES), SQL Server and other application licences, support plans, taxes and negotiated discounts.",
        ]))

        let headline = "\(Fmt.int(inScope.count)) VMs → \(SFmt.usd(best.total))/month (\(SFmt.usd(best.total * 12))/year) in \(cheapestName)"
            + (codes.count > 1 ? " — cheapest of \(codes.count - missing.count) regions" : "") + " · \(modelName)"
        return SolutionResult(headline: headline, sections: sections)
    }
}
