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
guard !args.isEmpty else {
    print("usage: rvtools-cli <RVTools export .xlsx | folder of RVTools_tab*.csv> [...] [--export <dir>]")
    exit(1)
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
func ms(_ a: Date, _ b: Date) -> String { String(format: "%.0f ms", b.timeIntervalSince(a) * 1000) }

do {
    let t0 = Date()
    let ds = try Dataset.load(args.map { URL(fileURLWithPath: $0) })
    let t1 = Date()
    let inv = InventoryBuilder.build(ds)
    let t2 = Date()
    let r = Analyzer.run(inv)
    let t3 = Date()

    if let sid = solutionID {
        guard let s = SolutionCatalog.solution(id: sid) else {
            print("unknown solution '\(sid)'; available: " + SolutionCatalog.all.map(\.id).joined(separator: ", "))
            exit(1)
        }
        let selected = s.defaultSelection(r.inventory)
        let result = s.run(vms: r.inventory.vms.filter { selected.contains($0.id) }, inventory: r.inventory, values: ParamValues())
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
