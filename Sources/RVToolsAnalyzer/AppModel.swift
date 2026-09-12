import AppKit
import Observation
import RVToolsCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Saved project package (`.rvaproj`); declared in the app's Info.plist.
    static let rvaProject = UTType(exportedAs: "local.rvtools-analyzer.project", conformingTo: .package)
}

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

    // Trend mode pages
    static let trendSummary = SidebarItem(id: "trend:summary", title: "Trend Summary", symbol: "chart.line.uptrend.xyaxis")
    static let trendChanges = SidebarItem(id: "trend:changes", title: "Changes", symbol: "arrow.triangle.2.circlepath")
    static let trendGrowth = SidebarItem(id: "trend:growth", title: "Growth", symbol: "chart.bar.xaxis")
    static let trendCapacity = SidebarItem(id: "trend:capacity", title: "Capacity Forecast", symbol: "calendar.badge.exclamationmark")
    static let trendPages: [SidebarItem] = [trendSummary, trendChanges, trendGrowth, trendCapacity]

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

/// A rate measured in the loaded trend that an assumption can be replaced with (`value`), or that is only
/// context for it (`value` nil).
struct ObservedRate {
    let text: String
    let value: Double?
    let unit: String
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
    var scopeID = "all" { didSet { if oldValue != scopeID { recompute(); noteChange() } } }
    var sidebar: SidebarItem? = .overview
    var isLoading = false
    var loadingMessage = ""
    var errorMessage: String?
    var sources: [URL] = []

    // Trend mode: several exports of one environment over time. The snapshot dashboards (report, lookup, …)
    // show the export picked with `trendSnapshot` (the latest by default).
    var trend: TrendReport?
    var trendSnapshot = 0 { didSet { if oldValue != trendSnapshot { showSnapshot(trendSnapshot) } } }
    var trendVMKey: String?
    var trendInterval: Int?
    var trendChangesTab = 0

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
    var solutionSelections: [String: Set<String>] = [:] { didSet { noteChange() } }
    var solutionParams: [String: ParamValues] = AppModel.loadSolutionParams() {
        didSet {
            if let data = try? JSONEncoder().encode(solutionParams) { UserDefaults.standard.set(data, forKey: "solutionParams") }
            noteChange()
        }
    }
    var solutionTab: [String: Int] = [:]
    private(set) var reportVersion = 0
    var priceVersion = 0
    var priceLoading = false
    var priceStatus = ""
    var priceError: String?
    @ObservationIgnored private var solutionCache: [String: SolutionResult] = [:]

    // Projects: saved sessions (.rvaproj). Once saved, changes autosave.
    var projectURL: URL?
    var projectName = "" { didSet { if oldValue != projectName { noteChange() } } }
    var projectNotes = "" { didSet { if oldValue != projectNotes { noteChange() } } }
    var isDirty = false
    var lastSaved: Date?
    var showProjectInfo = false
    var recentProjects: [URL] = AppModel.loadRecents()
    @ObservationIgnored private var currentProject: ProjectFile?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    var thresholds: Thresholds = AppModel.loadThresholds() {
        didSet {
            guard thresholds != oldValue else { return }
            if let data = try? JSONEncoder().encode(thresholds) { UserDefaults.standard.set(data, forKey: "thresholds") }
            recompute()
            noteChange()
        }
    }

    private var generation = 0

    private static func loadThresholds() -> Thresholds {
        guard let data = UserDefaults.standard.data(forKey: "thresholds"), let t = try? JSONDecoder().decode(Thresholds.self, from: data) else { return Thresholds() }
        return t
    }

    var scopeLabel: String { scopes.first { $0.id == scopeID }?.label ?? "Entire environment" }

    var sourceSummary: String {
        if let t = trend { return "\(t.snapshots.count) snapshots · \(Fmt.date(t.first.date)) → \(Fmt.date(t.last.date))" }
        guard let first = sources.first else { return "" }
        if sources.count == 1 { return first.lastPathComponent }
        let folders = Set(sources.map { $0.deletingLastPathComponent().lastPathComponent })
        return sources.allSatisfy({ $0.pathExtension.lowercased() == "csv" }) && folders.count == 1 ? "\(folders.first!) (CSV)" : "\(sources.count) files"
    }

    // MARK: Loading

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open"
        panel.message = "Choose a saved project, an RVTools .xlsx export, a folder of RVTools_tab*.csv files, or several exports to merge."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.rvaProject, UTType(filenameExtension: "xlsx"), UTType(filenameExtension: "xlsm"), .commaSeparatedText, .folder].compactMap { $0 }
        if panel.runModal() == .OK { open(panel.urls) }
    }

    var sampleURL: URL? { Bundle.main.url(forResource: "RVTools_sample", withExtension: "xlsx") }

    /// Opens exports or a saved project (.rvaproj), offering to save a customized session first.
    func open(_ urls: [URL]) {
        guard !urls.isEmpty, confirmDiscardChanges() else { return }
        if let url = urls.first(where: ProjectFile.isProject) {
            do {
                let opened = try ProjectFile.read(url)
                if opened.project.isTrend {
                    loadTrend(groups: opened.project.sourceGroups(in: url), urls: nil, project: (opened.project, url, opened.prices))
                } else {
                    load(opened.sources, project: (opened.project, url, opened.prices))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        load(urls, project: nil)
    }

    private func load(_ urls: [URL], project: (file: ProjectFile, url: URL, prices: [RegionPrices])?) {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        isLoading = true
        errorMessage = nil
        loadingMessage = project.map { "Opening \($0.file.name)…" } ?? "Reading \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")…"
        let t = project?.file.thresholds ?? thresholds
        Task.detached(priority: .userInitiated) {
            do {
                let ds = try Dataset.load(urls)
                await MainActor.run { self.loadingMessage = "Correlating \(ds.tableNames.count) tabs…" }
                let inv = InventoryBuilder.build(ds)
                let report = Analyzer.run(inv, thresholds: t)
                await MainActor.run {
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    self.apply(ds, inv, report)
                    if let project { self.restore(project.file, url: project.url, prices: project.prices) }
                    DebugSnapshot.runIfRequested(self)
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

    // MARK: Trend mode

    var sampleSeriesURL: URL? { Bundle.main.url(forResource: "RVTools_sample_series", withExtension: nil) }

    func presentTrendPanel() {
        let panel = NSOpenPanel()
        panel.title = "Compare Snapshots"
        panel.message = "Choose two or more RVTools exports of the same environment taken at different times, or a folder that contains them."
        panel.prompt = "Compare"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx"), UTType(filenameExtension: "xlsm"), .commaSeparatedText, .folder].compactMap { $0 }
        if panel.runModal() == .OK { openTrend(panel.urls) }
    }

    /// Opens exports as a time series of one environment (trend mode).
    func openTrend(_ urls: [URL]) {
        guard !urls.isEmpty, confirmDiscardChanges() else { return }
        if let url = urls.first(where: ProjectFile.isProject) { open([url]); return }
        loadTrend(groups: nil, urls: urls, project: nil)
    }

    private func loadTrend(groups: [[URL]]?, urls: [URL]?, project: (file: ProjectFile, url: URL, prices: [RegionPrices])?) {
        let all = urls ?? groups?.flatMap { $0 } ?? []
        let scoped = all.filter { $0.startAccessingSecurityScopedResource() }
        isLoading = true
        errorMessage = nil
        loadingMessage = project.map { "Opening \($0.file.name)…" } ?? "Reading \(all.count == 1 ? all[0].lastPathComponent : "\(all.count) exports")…"
        let t = project?.file.thresholds ?? thresholds
        Task.detached(priority: .userInitiated) {
            do {
                let snapshots = try groups.map { try TrendLoader.load(groups: $0) } ?? TrendLoader.load(all)
                guard snapshots.count >= 2 else {
                    throw RVToolsError.unreadable("Compare Snapshots needs exports of the same environment taken at different times, but these files form a single snapshot. To combine several vCenters into one view, use Open… instead.")
                }
                await MainActor.run { self.loadingMessage = "Comparing \(snapshots.count) snapshots…" }
                let trend = TrendAnalyzer.run(snapshots)
                let latest = snapshots[snapshots.count - 1]
                let report = Analyzer.run(latest.inventory, thresholds: t)
                await MainActor.run {
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    self.apply(latest.dataset, latest.inventory, report, trend: trend)
                    if let project { self.restore(project.file, url: project.url, prices: project.prices) }
                    DebugSnapshot.runIfRequested(self)
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

    /// Points the snapshot dashboards at another export of the series.
    private func showSnapshot(_ index: Int) {
        guard let t = trend, t.snapshots.indices.contains(index) else { return }
        let snap = t.snapshots[index]
        let previous = fullInventory
        restoring = true
        dataset = snap.dataset
        fullInventory = snap.inventory
        scopes = AppModel.buildScopes(snap.inventory)
        if !scopes.contains(where: { $0.id == scopeID }) { scopeID = "all" }
        // VM ids (vCenter + moref) are stable across exports: keep customized selections, re-default untouched ones.
        let valid = Set(snap.inventory.vms.map(\.id))
        for s in SolutionCatalog.all {
            let current = solutionSelections[s.id] ?? []
            let untouched = previous.map { current == s.defaultSelection($0) } ?? true
            solutionSelections[s.id] = untouched ? s.defaultSelection(snap.inventory) : current.intersection(valid)
        }
        selectedHostID = nil
        selectedDatastoreID = nil
        selectedPortGroupID = nil
        restoring = false
        recompute()
    }

    /// Opens a VM from the trend pages in the dashboards of the latest snapshot it appears in.
    func revealTrendVM(_ key: String) {
        guard let t = trend else { return }
        let history = t.history(key)
        guard let i = history.lastIndex(where: { $0.vm != nil }), let vm = history[i].vm else { return }
        trendSnapshot = i
        selectedVMID = vm.id
        sidebar = .vms
    }

    /// What the loaded trend measured for an assumption, shown beside it on the Assumptions step.
    func observedRate(_ solutionID: String, _ paramID: String) -> ObservedRate? {
        guard let t = trend, solutionID == "backup" || solutionID == "dr" else { return nil }
        let period = "\(t.snapshots.count) snapshots over \(Fmt.int(Int(t.spanDays.rounded()))) days"
        switch paramID {
        case "growth":
            guard let pct = t.suggestedGrowthPct else { return nil }
            let organic = t.organicGrowthPct.map { ", existing VMs only \(Fmt.num($0, 1))%" } ?? ""
            return ObservedRate(text: "Measured across \(period): \(Fmt.num(pct, 1))% a year\(organic).",
                                value: min(100, max(0, (pct * 2).rounded() / 2)), unit: "%")
        case "change":
            guard let daily = t.netDailyGrowthPct else { return nil }
            return ObservedRate(text: "Across \(period), existing VMs grew by a net \(Fmt.num(daily, 3))% a day. That's a floor for the change rate, not a measurement of it — rewritten blocks change without adding capacity.",
                                value: nil, unit: "%")
        default:
            return nil
        }
    }

    /// Sets the annual growth assumption of the Backup and DR solutions to an observed rate.
    func applyObservedGrowth(_ pct: Double) {
        for id in ["backup", "dr"] {
            var v = solutionParams[id] ?? ParamValues()
            v.values["growth"] = .number(pct)
            solutionParams[id] = v
        }
    }

    func paramNumber(_ solution: String, _ id: String) -> Double? {
        let value = solutionParams[solution]?.values[id] ?? SolutionCatalog.solution(id: solution)?.parameters.first { $0.id == id }?.defaultValue
        if case .number(let v) = value { return v }
        return nil
    }

    func exportTrend() {
        guard let t = trend else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Trend Report"
        panel.message = "Choose a folder for the trend CSV files (metrics, changes, growth, datastores)."
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let base = (t.last.sources.first?.deletingPathExtension().lastPathComponent ?? "RVTools") + "_trend"
        let files: [(String, String)] = [
            ("summary", TrendExport.summary(t)),
            ("vm-changes", TrendExport.changes(t)),
            ("infrastructure-changes", TrendExport.infrastructure(t)),
            ("vm-growth", TrendExport.vmGrowth(t)),
            ("datastores", TrendExport.datastores(t)),
        ]
        for (name, content) in files { write(content, to: dir.appendingPathComponent("\(base)_\(name).csv")) }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func apply(_ ds: Dataset, _ inv: Inventory, _ r: Report, trend: TrendReport? = nil) {
        restoring = true
        self.trend = nil
        trendSnapshot = (trend?.snapshots.count ?? 1) - 1
        self.trend = trend
        trendVMKey = nil
        trendInterval = nil
        trendChangesTab = 0
        dataset = ds
        fullInventory = inv
        sources = trend.map { $0.snapshots.flatMap(\.sources) } ?? ds.sources
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
        sidebar = trend == nil ? .overview : .trendSummary
        isLoading = false
        // A freshly opened export is a new, unsaved session.
        projectURL = nil
        currentProject = nil
        projectName = ""
        projectNotes = ""
        lastSaved = nil
        isDirty = false
        restoring = false
    }

    /// Re-applies a saved project's settings on top of its freshly analysed export.
    private func restore(_ p: ProjectFile, url: URL, prices: [RegionPrices]) {
        restoring = true
        defer {
            restoring = false
            isDirty = false
        }
        currentProject = p
        projectURL = url
        projectName = p.name
        projectNotes = p.notes
        lastSaved = p.modified
        if !prices.isEmpty {
            PriceStore.shared.importSnapshots(prices)
            priceVersion += 1
        }
        thresholds = p.thresholds
        let valid = Set(fullInventory?.vms.map(\.id) ?? [])
        for (id, ids) in p.solutionSelections { solutionSelections[id] = Set(ids).intersection(valid) }
        for (id, values) in p.solutionParams { solutionParams[id] = values }
        solutionTab = p.solutionTabs
        if scopes.contains(where: { $0.id == p.scopeID }) { scopeID = p.scopeID }
        let pages = SidebarItem.allCases + SidebarItem.trendPages + SolutionCatalog.all.map { SidebarItem.solution($0) }
        if let page = p.page, let item = pages.first(where: { $0.id == page }) { sidebar = item }
        addRecent(url)
    }

    func close() {
        guard confirmDiscardChanges() else { return }
        dataset = nil
        fullInventory = nil
        report = nil
        lookup = Lookup()
        trend = nil
        trendVMKey = nil
        sources = []
        scopes = []
        restoring = true
        projectURL = nil
        currentProject = nil
        projectName = ""
        projectNotes = ""
        isDirty = false
        restoring = false
    }

    // MARK: Projects

    var projectTitle: String { projectURL == nil ? "Unsaved session" : projectName }

    private var defaultProjectName: String {
        guard let first = trend?.last.sources.first ?? sources.first else { return "RVTools Project" }
        let base = first.pathExtension.lowercased() == "csv" ? first.deletingLastPathComponent().lastPathComponent : first.deletingPathExtension().lastPathComponent
        return trend == nil ? base : base + " trend"
    }

    /// Records a user customization; saved projects autosave shortly afterwards.
    private func noteChange() {
        guard !restoring, report != nil else { return }
        isDirty = true
        if projectURL != nil { scheduleAutosave() }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.isDirty, self.projectURL != nil else { return }
            self.writeProject()
        }
    }

    private func snapshot() -> ProjectFile {
        var p = currentProject ?? ProjectFile(name: projectName.isEmpty ? defaultProjectName : projectName)
        if !projectName.isEmpty { p.name = projectName }
        p.notes = projectNotes
        p.scopeID = scopeID
        p.thresholds = thresholds
        p.solutionSelections = solutionSelections.mapValues { $0.sorted() }
        p.solutionParams = solutionParams
        p.solutionTabs = solutionTab
        p.page = sidebar?.id
        p.mode = trend == nil ? nil : ProjectFile.trendMode
        return p
    }

    /// Price snapshots behind the cloud estimates, stored with the project so they can be reproduced.
    private func projectPrices() -> [RegionPrices] {
        SolutionCatalog.all.compactMap { $0 as? any PricedSolution }.flatMap { s in
            s.regions(Params(s.parameters, solutionParams[s.id] ?? ParamValues())).compactMap { PriceStore.shared.prices(s.provider, $0) }
        }
    }

    func saveProject() {
        if projectURL == nil { saveProjectAs() } else { writeProject() }
    }

    func saveProjectAs() {
        guard let ds = dataset, report != nil else { return }
        let panel = NSSavePanel()
        panel.title = "Save Project"
        panel.message = "Saves a copy of the export with all your settings. Save to iCloud Drive or a OneDrive folder to use it on other Macs."
        panel.allowedContentTypes = [.rvaProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (projectName.isEmpty ? defaultProjectName : projectName) + "." + ProjectFile.fileExtension
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if !ProjectFile.isProject(url) { url.appendPathExtension(ProjectFile.fileExtension) }
        var p = snapshot()
        p.name = url.deletingPathExtension().lastPathComponent
        do {
            let saved: ProjectFile
            if let t = trend {
                saved = try ProjectFile.write(p, to: url, copyGroups: t.snapshots.map(\.sources), prices: projectPrices())
            } else {
                saved = try ProjectFile.write(p, to: url, copySources: ds.sources, prices: projectPrices())
            }
            finishSave(saved, url)
            addRecent(url)
        } catch {
            errorMessage = "Couldn't save the project: \(error.localizedDescription)"
        }
    }

    /// Rewrites the settings of the open project (its sources are already inside the package).
    func writeProject() {
        guard let url = projectURL else { return }
        do {
            finishSave(try ProjectFile.write(snapshot(), to: url, copySources: nil, prices: projectPrices()), url)
        } catch {
            errorMessage = "Couldn't save the project: \(error.localizedDescription)"
        }
    }

    private func finishSave(_ saved: ProjectFile, _ url: URL) {
        restoring = true
        currentProject = saved
        projectURL = url
        projectName = saved.name
        restoring = false
        lastSaved = saved.modified
        isDirty = false
    }

    /// Before a customized session is replaced or the app quits: saved projects are written silently, unsaved
    /// sessions offer to save. Returns false if the user cancels.
    func confirmDiscardChanges() -> Bool {
        guard isDirty, report != nil else { return true }
        if projectURL != nil {
            writeProject()
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Save this session as a project?"
        alert.informativeText = "You've changed VM selections, assumptions or settings. Save them as a project to come back to them later."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveProjectAs()
            return !isDirty
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private static func loadRecents() -> [URL] {
        let bookmarks = UserDefaults.standard.array(forKey: "recentProjects") as? [Data] ?? []
        return bookmarks.compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addRecent(_ url: URL) {
        var list = recentProjects.filter { $0.standardizedFileURL.path != url.standardizedFileURL.path }
        list.insert(url, at: 0)
        recentProjects = Array(list.prefix(10))
        UserDefaults.standard.set(recentProjects.compactMap { try? $0.bookmarkData() }, forKey: "recentProjects")
    }

    func clearRecentProjects() {
        recentProjects = []
        UserDefaults.standard.removeObject(forKey: "recentProjects")
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
        let key = "\(s.id)|\(reportVersion)|\(PriceStore.shared.version)|\(selection.hashValue)|\(values.hashValue)"
        if let cached = solutionCache[key] { return cached }
        let result = s.run(vms: r.inventory.vms.filter { selection.contains($0.id) }, inventory: r.inventory, values: values)
        if solutionCache.count > 16 { solutionCache.removeAll() }
        solutionCache[key] = result
        return result
    }

    /// Loads cached price files for the solution's regions (no network).
    func loadCachedPrices(_ s: any PricedSolution) {
        let regions = s.regions(Params(s.parameters, solutionParams[s.id] ?? ParamValues()))
        let before = PriceStore.shared.version
        PriceStore.shared.loadFromDisk(s.provider, regions: regions)
        if PriceStore.shared.version != before { priceVersion += 1 }
    }

    /// Downloads public list prices for the solution's regions (only when the user asks).
    func downloadPrices(_ s: any PricedSolution, force: Bool) {
        let provider = s.provider
        let regions = s.regions(Params(s.parameters, solutionParams[s.id] ?? ParamValues()))
        let needed = force ? regions : regions.filter { PriceStore.shared.prices(provider, $0) == nil }
        guard !needed.isEmpty else { return }
        priceLoading = true
        priceError = nil
        priceStatus = "Downloading \(provider.name) prices for \(needed.count) region\(needed.count == 1 ? "" : "s")…"
        Task.detached {
            let errors = await PriceStore.shared.download(provider, regions: needed)
            await MainActor.run {
                self.priceLoading = false
                self.priceVersion += 1
                self.noteChange()   // new price snapshots belong in the project
                self.priceError = errors.isEmpty ? nil
                    : "Failed: " + errors.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
            }
        }
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
