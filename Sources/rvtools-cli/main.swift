import Foundation
import RVToolsCore

// Headless runner: rvtools-cli <export.xlsx | csv-folder> [more exports...] [--export <dir>]

var args = Array(CommandLine.arguments.dropFirst())
var exportDir: String?
if let i = args.firstIndex(of: "--export"), i + 1 < args.count {
    exportDir = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
// --solution <id>: print that solution's report (Markdown) for its default VM selection.
var solutionID: String?
if let i = args.firstIndex(of: "--solution"), i + 1 < args.count {
    solutionID = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
// --save-project <path>: save the loaded export (plus any --solution/--set assumptions) as a .rvaproj project.
var saveProjectPath: String?
if let i = args.firstIndex(of: "--save-project"), i + 1 < args.count {
    saveProjectPath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
/// Set when the input is a .rvaproj project: its thresholds, selections and assumptions are used.
var project: ProjectFile?

// --trend: treat the inputs as snapshots of one environment over time and print the trend analysis.
var trendMode = false
if let i = args.firstIndex(of: "--trend") {
    trendMode = true
    args.remove(at: i)
}

func printTrend(_ t: TrendReport) {
    func cap(_ v: Double) -> String { Fmt.capacity(mib: v) }
    func fmt(_ v: Double, _ f: TrendFormat) -> String { f == .count ? Fmt.int(Int(v.rounded())) : (f == .percent ? Fmt.pct(v) : cap(v)) }
    func signed(_ v: Double, _ f: TrendFormat) -> String { (v >= 0 ? "+" : "−") + fmt(abs(v), f) }
    print("Snapshots (\(t.snapshots.count), \(Fmt.num(t.spanDays, 0)) days):")
    for s in t.snapshots {
        print("  \(s.id + 1). \(Fmt.dateTime(s.date))  VMs \(s.inventory.vms.filter(\.isVM).count) · hosts \(s.inventory.hosts.count) · \(s.vcenters.joined(separator: ", ")) · \(s.sources.map(\.lastPathComponent).first ?? "")\(s.sources.count > 1 ? " +\(s.sources.count - 1)" : "")")
    }
    print("\n== Metrics (first → last)")
    for s in t.series { print("  \(s.metric.rawValue.padding(toLength: 24, withPad: " ", startingAt: 0)) \(fmt(s.first, s.metric.format)) → \(fmt(s.last, s.metric.format))  (\(signed(s.last - s.first, s.metric.format)))") }
    print("\n== Observed growth")
    for g in t.growth {
        print("  \(g.label.padding(toLength: 40, withPad: " ", startingAt: 0)) \(signed(g.change, g.format)) · \(signed(g.perDay * 30.4, g.format))/month · \(g.annualPct.map { Fmt.num($0, 1) + "%/yr" } ?? "—")")
    }
    if let s = t.suggestedGrowthPct { print("  → suggested annual growth assumption: \(Fmt.num(s, 1))%") }
    if let d = t.netDailyGrowthPct { print("  → net daily growth \(Fmt.num(d, 3))% (lower bound for the daily change rate)") }
    print("\n== Changes per interval")
    for iv in t.intervals {
        let parts = ChangeKind.allCases.compactMap { k in iv.counts[k].map { "\(k.rawValue) \($0)" } }
        print("  \(Fmt.date(iv.from)) → \(Fmt.date(iv.to)) (\(Fmt.num(iv.days, 0))d): net VMs \(iv.netVMs >= 0 ? "+" : "")\(iv.netVMs), vCPU \(iv.netVCPU >= 0 ? "+" : "")\(iv.netVCPU), data \(signed(iv.dataGrowthMiB, .capacityMiB)) · " + parts.joined(separator: ", "))
    }
    print("\n== Top growing VMs")
    for g in t.vmGrowth.prefix(8) { print("  \(g.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(cap(g.firstDataMiB)) → \(cap(g.lastDataMiB)) (\(signed(g.perMonthMiB, .capacityMiB))/month)") }
    print("\n== Datastores by days to full")
    for d in t.datastores.prefix(6) { print("  \(d.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(Fmt.pct(d.usedPctLast)) used · \(signed(d.perMonthMiB, .capacityMiB))/month · full in \(d.daysToFull.map { Fmt.num($0, 0) + " days" } ?? "—")") }
    print("\n== Infrastructure changes")
    for c in t.infra { print("  \(Fmt.date(c.date)) \(c.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(c.name) — \(c.change) \(c.detail)") }
    print("\n== VM changes (\(t.changes.count); first 25 excluding host moves)")
    for c in t.changes.filter({ $0.kind != .hostMove }).prefix(25) { print("  \(Fmt.date(c.date)) \(c.kind.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(c.name) — \(c.detail)") }
    if !t.warnings.isEmpty { print("\n== Warnings"); t.warnings.forEach { print("  ! \($0)") } }
}

// --set name=value (repeatable): override a solution assumption. Choices take an index; multi-selects take "0,2,5".
var overrides: [String: String] = [:]
while let i = args.firstIndex(of: "--set"), i + 1 < args.count {
    let kv = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { overrides[kv[0]] = kv[1] }
    args.removeSubrange(i...(i + 1))
}

func paramValues(_ s: any Solution) -> ParamValues {
    var v = project?.solutionParams[s.id] ?? ParamValues()
    for (name, raw) in overrides {
        guard let spec = s.parameters.first(where: { $0.id == name }) else {
            FileHandle.standardError.write("unknown parameter '\(name)' — available: \(s.parameters.map(\.id).joined(separator: ", "))\n".data(using: .utf8)!)
            continue
        }
        switch spec.kind {
        case .number: if let x = Double(raw) { v.values[name] = .number(x) }
        case .choice: if let x = Int(raw) { v.values[name] = .choice(x) }
        case .toggle: v.values[name] = .flag(["1", "true", "yes", "on"].contains(raw.lowercased()))
        case .multi: v.values[name] = .selection(raw.split(separator: ",").compactMap { Int($0) })
        }
    }
    return v
}

// --prices azure|aws: download every region's public price list and report what was found.
if let i = args.firstIndex(of: "--prices"), i + 1 < args.count {
    guard let provider = CloudProvider(rawValue: args[i + 1]) else { print("usage: --prices azure|aws"); exit(1) }
    for region in CloudRegions.list(provider) {
        let errors = await PriceStore.shared.download(provider, regions: [region.code])
        if let e = errors[region.code] {
            print("  \(region.code.padding(toLength: 20, withPad: " ", startingAt: 0)) FAILED: \(e)")
        } else if let rp = PriceStore.shared.prices(provider, region.code) {
            let priced = rp.instances.filter { $0.linuxHourly != nil }
            print("  \(region.code.padding(toLength: 20, withPad: " ", startingAt: 0)) \(priced.count) instances · \(rp.instances.filter { $0.windowsHourly != nil }.count) Windows · "
                + "\(rp.instances.filter { $0.reserved1yHourly != nil }.count) reserved · storage \(rp.storage.keys.sorted().joined(separator: " "))")
        }
    }
    exit(0)
}

guard !args.isEmpty else {
    print("usage: rvtools-cli <RVTools export .xlsx | folder of RVTools_tab*.csv> [...] [--export <dir>]")
    exit(1)
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
func ms(_ a: Date, _ b: Date) -> String { String(format: "%.0f ms", b.timeIntervalSince(a) * 1000) }

do {
    let t0 = Date()
    var inputs = args.map { URL(fileURLWithPath: $0) }
    if inputs.count == 1, ProjectFile.isProject(inputs[0]), let opened = try? ProjectFile.read(inputs[0]), opened.project.isTrend {
        printTrend(TrendAnalyzer.run(try TrendLoader.load(groups: opened.project.sourceGroups(in: inputs[0]))))
        exit(0)
    }
    if trendMode {
        let snapshots = try TrendLoader.load(inputs)
        guard snapshots.count >= 2 else { print("Trend analysis needs at least two exports taken at different times (found \(snapshots.count))."); exit(1) }
        let t0 = Date()
        let trend = TrendAnalyzer.run(snapshots)
        printTrend(trend)
        print(String(format: "\n(analysed in %.0f ms)", Date().timeIntervalSince(t0) * 1000))
        if let out = saveProjectPath {
            let url = URL(fileURLWithPath: out)
            var p = ProjectFile(name: url.deletingPathExtension().lastPathComponent)
            p.mode = ProjectFile.trendMode
            _ = try ProjectFile.write(p, to: url, copyGroups: snapshots.map(\.sources), prices: [])
            print("Saved trend project \(url.path)")
        }
        exit(0)
    }
    if inputs.count == 1, ProjectFile.isProject(inputs[0]) {
        let opened = try ProjectFile.read(inputs[0])
        project = opened.project
        inputs = opened.sources
        PriceStore.shared.importSnapshots(opened.prices)
        print("Project:      \(opened.project.name) (saved \(Fmt.dateTime(opened.project.modified)))")
    }
    let ds = try Dataset.load(inputs)
    let t1 = Date()
    let inv = InventoryBuilder.build(ds)
    let t2 = Date()
    let r = Analyzer.run(inv, thresholds: project?.thresholds ?? Thresholds())
    let t3 = Date()

    if let out = saveProjectPath {
        var url = URL(fileURLWithPath: out)
        if !ProjectFile.isProject(url) { url.appendPathExtension(ProjectFile.fileExtension) }
        var p = project ?? ProjectFile(name: url.deletingPathExtension().lastPathComponent)
        p.name = url.deletingPathExtension().lastPathComponent
        for s in SolutionCatalog.all where p.solutionSelections[s.id] == nil { p.solutionSelections[s.id] = s.defaultSelection(r.inventory).sorted() }
        if let sid = solutionID, let s = SolutionCatalog.solution(id: sid) { p.solutionParams[sid] = paramValues(s) }
        _ = try ProjectFile.write(p, to: url, copySources: ds.sources, prices: [])
        print("Saved project \(url.path)")
    }

    if let sid = solutionID {
        guard let s = SolutionCatalog.solution(id: sid) else {
            print("unknown solution '\(sid)'; available: " + SolutionCatalog.all.map(\.id).joined(separator: ", "))
            exit(1)
        }
        if let priced = s as? any PricedSolution {
            let regions = priced.regions(Params(priced.parameters, paramValues(priced)))
            let missing = PriceStore.shared.loadFromDisk(priced.provider, regions: regions)
            if !missing.isEmpty {
                FileHandle.standardError.write("Downloading \(priced.provider.name) prices for \(missing.joined(separator: ", "))…\n".data(using: .utf8)!)
                for (region, error) in await PriceStore.shared.download(priced.provider, regions: missing) {
                    FileHandle.standardError.write("  \(region): \(error)\n".data(using: .utf8)!)
                }
            }
        }
        let selected = project?.solutionSelections[s.id].map { Set($0) } ?? s.defaultSelection(r.inventory)
        let result = s.run(vms: r.inventory.vms.filter { selected.contains($0.id) }, inventory: r.inventory, values: paramValues(s))
        print(result.markdown(title: s.title, subtitle: "\(ds.sources.map(\.lastPathComponent).joined(separator: ", ")) · exported \(Fmt.dateTime(ds.reportDate))"))
        exit(0)
    }

    print("Sources:      \(ds.sources.map(\.lastPathComponent).joined(separator: ", "))")
    print("Export date:  \(Fmt.dateTime(ds.reportDate))   RVTools \(ds.rvtoolsVersion)")
    print("Timing:       load \(ms(t0, t1)), correlate \(ms(t1, t2)), analyze \(ms(t2, t3))")
    print("Tabs:         " + ds.tableNames.map { "\($0)=\(ds.table($0)?.rows.count ?? 0)" }.joined(separator: " "))

    let t = r.totals
    print("\n== Inventory")
    print("vCenters \(t.vcenters) · datacenters \(t.datacenters) · clusters \(t.clusters) · hosts \(t.hosts) (\(t.hostsInMaintenance) in maintenance)")
    print("VMs \(t.vms): on \(t.vmsOn), off \(t.vmsOff), suspended \(t.vmsSuspended) · templates \(t.templates)")
    print("Compute: \(t.sockets) sockets, \(t.cores) cores, \(Fmt.capacity(mib: t.physMemMiB)) RAM · vCPU on \(t.vcpuOn) (\(Fmt.ratio(t.vcpuPerCore))) · vRAM on \(Fmt.capacity(mib: t.vramOnMiB))")
    print("Utilisation: CPU \(Fmt.pct(t.cpuUsagePct)) · memory \(Fmt.pct(t.memUsagePct))")
    print("Storage: \(t.datastores) datastores, \(Fmt.capacity(mib: t.dsCapacityMiB)) capacity, \(Fmt.pct(t.dsUsedPct)) used · VM provisioned \(Fmt.capacity(mib: t.vmProvisionedMiB)), in use \(Fmt.capacity(mib: t.vmInUseMiB))")
    print("Snapshots \(t.snapshots) (\(Fmt.capacity(mib: t.snapshotMiB))) · port groups \(t.portGroups) · VLANs \(t.vlans)")

    print("\n== Clusters")
    for c in r.inventory.clusters {
        print("  \(pad(c.name, 34)) hosts \(lpad("\(c.hostCount)", 3))  VMs \(lpad("\(c.vmCount)", 4))  vCPU:core \(lpad(Fmt.ratio(c.vcpuPerCore), 6))  CPU \(lpad(Fmt.pct(c.cpuUsagePct), 4))  mem \(lpad(Fmt.pct(c.memUsagePct), 4))  N+1 mem \(Fmt.pct(c.memPctAfterHostLoss))")
    }

    print("\n== Correlations (tab joins)")
    for j in r.inventory.joins {
        print("  \(pad(j.source, 22)) → \(pad(j.target, 28)) \(lpad("\(j.matched)/\(j.total)", 11))  \(lpad(Fmt.pct(j.coverage * 100), 5))  via \(j.keys)")
    }
    print("\n== Consistency checks")
    for c in r.inventory.checks {
        print("  [\(c.ok ? "ok" : "!!")] \(pad(c.title, 50)) reported \(c.reported) · derived \(c.derived)")
    }

    print("\n== Findings: \(t.critical) critical, \(t.warning) warning, \(t.info) info")
    for g in r.groups {
        print("  \(pad(g.severity.label, 8)) \(lpad("\(g.count)", 5))  \(pad(g.category.rawValue, 20)) \(g.title)")
    }

    print("\n== Distributions")
    func show(_ name: String, _ items: [CountItem]) {
        print("  \(name): " + items.prefix(8).map { "\($0.label) \($0.count)" }.joined(separator: " · "))
    }
    show("OS family", r.dist.osFamily)
    show("OS lifecycle", r.dist.osLifecycle)
    show("Tools (running)", r.dist.toolsStatus)
    show("HW version", r.dist.hwVersion)
    show("ESXi", r.dist.esxiVersion)
    show("Disk provisioning", r.dist.diskProvisioning)
    show("NIC adapters", r.dist.nicAdapter)
    show("Snapshot age", r.dist.snapshotAge)

    if let dir = exportDir {
        let base = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let files: [(String, String)] = [
            ("findings.csv", CSVExport.findings(r)), ("vms.csv", CSVExport.vms(r)), ("hosts.csv", CSVExport.hosts(r)),
            ("clusters.csv", CSVExport.clusters(r)), ("datastores.csv", CSVExport.datastores(r)),
        ]
        for (name, content) in files { try content.write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        print("\nExported \(files.count) CSV files to \(base.path)")
    }
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(2)
}
