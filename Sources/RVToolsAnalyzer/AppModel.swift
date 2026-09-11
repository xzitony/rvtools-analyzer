import AppKit
import Observation
import RVToolsCore
import SwiftUI
import UniformTypeIdentifiers

/// A sidebar destination: one of the fixed pages, or a solution from `SolutionCatalog` (added dynamically).
struct SidebarItem: Hashable, Identifiable {
    let id: String
    let title: String
    let symbol: String

    var rawValue: String { title }
    var solutionID: String? { id.hasPrefix("solution:") ? String(id.dropFirst("solution:".count)) : nil }

    static let overview = SidebarItem(id: "overview", title: "Overview", symbol: "gauge.with.dots.needle.67percent")
    static let issues = SidebarItem(id: "issues", title: "Issues", symbol: "exclamationmark.triangle")
    static let compute = SidebarItem(id: "compute", title: "Compute", symbol: "cpu")
    static let vms = SidebarItem(id: "vms", title: "Virtual Machines", symbol: "desktopcomputer")
    static let storage = SidebarItem(id: "storage", title: "Storage", symbol: "externaldrive")
    static let network = SidebarItem(id: "network", title: "Network", symbol: "network")
    static let configuration = SidebarItem(id: "configuration", title: "Configuration", symbol: "slider.horizontal.3")
    static let lifecycle = SidebarItem(id: "lifecycle", title: "Lifecycle", symbol: "calendar.badge.clock")
    static let correlations = SidebarItem(id: "correlations", title: "Correlations", symbol: "point.3.connected.trianglepath.dotted")
    static let rawData = SidebarItem(id: "rawData", title: "Raw Tabs", symbol: "tablecells")

    /// Fixed pages, in sidebar order (used by the Go menu).
    static let allCases: [SidebarItem] = [overview, issues, compute, vms, storage, network, configuration, lifecycle, correlations, rawData]

    static func solution(_ s: any Solution) -> SidebarItem {
        SidebarItem(id: "solution:" + s.id, title: s.title, symbol: s.symbol)
    }
}

struct ScopeOption: Identifiable, Hashable {
    let id: String
    let label: String
    /// nil = entire environment
    let clusterIDs: Set<String>?
    var isGroupStart = false
}

/// Fast id → entity lookups for the current report (used for cross-navigation in detail panes).
struct Lookup {
    var vms: [String: VM] = [:]
    var hosts: [String: RVToolsCore.Host] = [:]
    var clusters: [String: Cluster] = [:]
    var datastores: [String: Datastore] = [:]
    var portGroups: [String: PortGroup] = [:]

    init() {}

    init(_ inv: Inventory) {
        vms = Dictionary(inv.vms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        hosts = Dictionary(inv.hosts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        clusters = Dictionary(inv.clusters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        datastores = Dictionary(inv.datastores.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        portGroups = Dictionary(inv.portGroups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func id(_ server: String, _ name: String) -> String { server.lowercased() + "|" + name.lowercased() }
}

enum ExportKind: String, CaseIterable, Identifiable {
    case findings = "Findings"
    case vms = "VM inventory"
    case hosts = "Hosts"
    case clusters = "Clusters"
    case datastores = "Datastores"
    var id: String { rawValue }
    var fileSuffix: String {
        switch self {
        case .findings: return "findings"
        case .vms: return "vms"
        case .hosts: return "hosts"
        case .clusters: return "clusters"
        case .datastores: return "datastores"
        }
    }

    func content(_ r: Report) -> String {
        switch self {
        case .findings: return CSVExport.findings(r)
        case .vms: return CSVExport.vms(r)
        case .hosts: return CSVExport.hosts(r)
        case .clusters: return CSVExport.clusters(r)
        case .datastores: return CSVExport.datastores(r)
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var dataset: Dataset?
    var fullInventory: Inventory?
    var report: Report?
    var lookup = Lookup()
    var scopes: [ScopeOption] = []
    var scopeID = "all" { didSet { if oldValue != scopeID { recompute() } } }
    var sidebar: SidebarItem? = .overview
    var isLoading = false
    var loadingMessage = ""
    var errorMessage: String?
    var sources: [URL] = []

    // Cross-page navigation state
    var selectedVMID: String?
    var selectedHostID: String?
    var selectedDatastoreID: String?
    var selectedPortGroupID: String?
    var computeTab = 0
    var storageTab = 0
    var networkTab = 0
    var focusRule: String?

    // Solutions: per-solution VM selection (reset per export), assumptions (persisted) and active tab.
    var solutionSelections: [String: Set<String>] = [:]
    var solutionParams: [String: ParamValues] = AppModel.loadSolutionParams() {
        didSet { if let data = try? JSONEncoder().encode(solutionParams) { UserDefaults.standard.set(data, forKey: "solutionParams") } }
    }
    var solutionTab: [String: Int] = [:]
    private(set) var reportVersion = 0
    @ObservationIgnored private var solutionCache: [String: SolutionResult] = [:]

    var thresholds: Thresholds = AppModel.loadThresholds() {
        didSet {
            guard thresholds != oldValue else { return }
            if let data = try? JSONEncoder().encode(thresholds) { UserDefaults.standard.set(data, forKey: "thresholds") }
            recompute()
        }
    }

    private var generation = 0

    private static func loadThresholds() -> Thresholds {
        guard let data = UserDefaults.standard.data(forKey: "thresholds"), let t = try? JSONDecoder().decode(Thresholds.self, from: data) else { return Thresholds() }
        return t
    }

    var scopeLabel: String { scopes.first { $0.id == scopeID }?.label ?? "Entire environment" }

    var sourceSummary: String {
        guard let first = sources.first else { return "" }
        if sources.count == 1 { return first.lastPathComponent }
        let folders = Set(sources.map { $0.deletingLastPathComponent().lastPathComponent })
        return sources.allSatisfy({ $0.pathExtension.lowercased() == "csv" }) && folders.count == 1 ? "\(folders.first!) (CSV)" : "\(sources.count) files"
    }

    // MARK: Loading

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open RVTools export"
        panel.message = "Choose an RVTools .xlsx export, a folder of RVTools_tab*.csv files, or several exports to merge."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx"), UTType(filenameExtension: "xlsm"), .commaSeparatedText, .folder].compactMap { $0 }
        if panel.runModal() == .OK { open(panel.urls) }
    }

    var sampleURL: URL? { Bundle.main.url(forResource: "RVTools_sample", withExtension: "xlsx") }

    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        isLoading = true
        errorMessage = nil
        loadingMessage = "Reading \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")…"
        let t = thresholds
        Task.detached(priority: .userInitiated) {
            do {
                let ds = try Dataset.load(urls)
                await MainActor.run { self.loadingMessage = "Correlating \(ds.tableNames.count) tabs…" }
                let inv = InventoryBuilder.build(ds)
                let report = Analyzer.run(inv, thresholds: t)
                await MainActor.run {
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    self.apply(ds, inv, report)
                }
            } catch {
                await MainActor.run {
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func apply(_ ds: Dataset, _ inv: Inventory, _ r: Report) {
        dataset = ds
        fullInventory = inv
        sources = ds.sources
        scopes = AppModel.buildScopes(inv)
        generation += 1
        scopeID = "all"
        report = r
        lookup = Lookup(r.inventory)
        reportVersion += 1
        solutionSelections = Dictionary(uniqueKeysWithValues: SolutionCatalog.all.map { ($0.id, $0.defaultSelection(inv)) })
        selectedVMID = nil
        selectedHostID = nil
        selectedDatastoreID = nil
        selectedPortGroupID = nil
        sidebar = .overview
        isLoading = false
        for url in ds.sources.prefix(1) { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        DebugSnapshot.runIfRequested(self)
    }

    func close() {
        dataset = nil
        fullInventory = nil
        report = nil
        lookup = Lookup()
        sources = []
        scopes = []
    }

    func recompute() {
        guard let full = fullInventory else { return }
        let scope = scopes.first { $0.id == scopeID }
        let inv = scope?.clusterIDs.map { full.scoped(to: $0) } ?? full
        let t = thresholds
        generation += 1
        let gen = generation
        Task.detached(priority: .userInitiated) {
            let r = Analyzer.run(inv, thresholds: t)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.report = r
                self.lookup = Lookup(r.inventory)
                self.reportVersion += 1
            }
        }
    }

    static func buildScopes(_ inv: Inventory) -> [ScopeOption] {
        var out = [ScopeOption(id: "all", label: "Entire environment", clusterIDs: nil)]
        let byVC = Dictionary(grouping: inv.clusters, by: { $0.vcenter })
        if byVC.count > 1 {
            for (i, (vc, cs)) in byVC.sorted(by: { $0.key < $1.key }).enumerated() {
                out.append(ScopeOption(id: "vc:" + vc, label: "vCenter \(vc)", clusterIDs: Set(cs.map(\.id)), isGroupStart: i == 0))
            }
        }
        let byDC = Dictionary(grouping: inv.clusters, by: { $0.vcenter + " / " + $0.datacenter })
        if byDC.count > 1 {
            for (i, (dc, cs)) in byDC.sorted(by: { $0.key < $1.key }).enumerated() {
                let label = byVC.count > 1 ? "Datacenter \(dc)" : "Datacenter \(cs.first?.datacenter ?? dc)"
                out.append(ScopeOption(id: "dc:" + dc, label: label, clusterIDs: Set(cs.map(\.id)), isGroupStart: i == 0))
            }
        }
        for (i, c) in inv.clusters.enumerated() {
            out.append(ScopeOption(id: c.id, label: byVC.count > 1 ? "\(c.name) — \(c.vcenter)" : c.name, clusterIDs: [c.id], isGroupStart: i == 0))
        }
        return out
    }

    // MARK: Navigation

    func reveal(vm id: String) {
        selectedVMID = id
        sidebar = .vms
    }

    func reveal(host id: String) {
        selectedHostID = id
        computeTab = 1
        sidebar = .compute
    }

    func reveal(datastore id: String) {
        selectedDatastoreID = id
        storageTab = 1
        sidebar = .storage
    }

    func reveal(portGroup id: String) {
        selectedPortGroupID = id
        networkTab = 0
        sidebar = .network
    }

    func reveal(_ f: Finding) {
        switch f.kind {
        case .vm where lookup.vms[f.objectID] != nil: reveal(vm: f.objectID)
        case .host where lookup.hosts[f.objectID] != nil: reveal(host: f.objectID)
        case .datastore where lookup.datastores[f.objectID] != nil: reveal(datastore: f.objectID)
        case .network where lookup.portGroups[f.objectID] != nil: reveal(portGroup: f.objectID)
        case .cluster: computeTab = 0; sidebar = .compute
        default: break
        }
    }

    func showIssues(rule: String? = nil) {
        focusRule = rule
        sidebar = .issues
    }

    // MARK: Solutions

    private static func loadSolutionParams() -> [String: ParamValues] {
        guard let data = UserDefaults.standard.data(forKey: "solutionParams"),
              let v = try? JSONDecoder().decode([String: ParamValues].self, from: data) else { return [:] }
        return v
    }

    /// Result for the current selection / assumptions / scope, cached until any of them change.
    func result(for s: any Solution) -> SolutionResult? {
        guard let r = report else { return nil }
        let selection = solutionSelections[s.id] ?? []
        let values = solutionParams[s.id] ?? ParamValues()
        let key = "\(s.id)|\(reportVersion)|\(selection.hashValue)|\(values.hashValue)"
        if let cached = solutionCache[key] { return cached }
        let result = s.run(vms: r.inventory.vms.filter { selection.contains($0.id) }, inventory: r.inventory, values: values)
        if solutionCache.count > 16 { solutionCache.removeAll() }
        solutionCache[key] = result
        return result
    }

    func exportSolution(_ s: any Solution) {
        guard let r = report, let result = result(for: s) else { return }
        let panel = NSOpenPanel()
        panel.title = "Export \(s.title)"
        panel.message = "Choose a folder for the report (Markdown) and its tables (CSV)."
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let base = "\(exportBaseName)_\(s.id)"
        let subtitle = "\(sourceSummary) · exported \(Fmt.dateTime(r.inventory.reportDate)) · scope: \(scopeLabel)"
        write(result.markdown(title: s.title, subtitle: subtitle), to: dir.appendingPathComponent(base + ".md"))
        for file in result.csvFiles() { write(file.content, to: dir.appendingPathComponent("\(base)_\(file.name).csv")) }
        let selected = r.inventory.vms.filter { (solutionSelections[s.id] ?? []).contains($0.id) }
        write(CSVExport.selection(selected), to: dir.appendingPathComponent("\(base)_selected-vms.csv"))
        NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent(base + ".md")])
    }

    func canReveal(_ kind: ObjectKind, _ id: String) -> Bool {
        switch kind {
        case .vm: return lookup.vms[id] != nil
        case .host: return lookup.hosts[id] != nil
        case .datastore: return lookup.datastores[id] != nil
        case .network: return lookup.portGroups[id] != nil
        case .cluster: return lookup.clusters[id] != nil
        default: return false
        }
    }

    func reveal(_ kind: ObjectKind, _ id: String) {
        switch kind {
        case .vm: reveal(vm: id)
        case .host: reveal(host: id)
        case .datastore: reveal(datastore: id)
        case .network: reveal(portGroup: id)
        case .cluster: computeTab = 0; sidebar = .compute
        default: break
        }
    }

    // MARK: Export

    private var exportBaseName: String {
        let base = sources.first?.deletingPathExtension().lastPathComponent ?? "RVTools"
        return scopeID == "all" ? base : base + "_" + scopeLabel.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
    }

    func export(_ kind: ExportKind) {
        guard let r = report else { return }
        let panel = NSSavePanel()
        panel.title = "Export \(kind.rawValue)"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(exportBaseName)_\(kind.fileSuffix).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(kind.content(r), to: url)
    }

    func exportAll() {
        guard let r = report else { return }
        let panel = NSOpenPanel()
        panel.title = "Export all CSV files"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for kind in ExportKind.allCases { write(kind.content(r), to: dir.appendingPathComponent("\(exportBaseName)_\(kind.fileSuffix).csv")) }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func write(_ content: String, to url: URL) {
        do { try content.write(to: url, atomically: true, encoding: .utf8) } catch {
            errorMessage = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
