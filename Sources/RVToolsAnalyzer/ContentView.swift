import RVToolsCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if let report = model.report {
                MainView(report: report)
            } else {
                WelcomeView(dropTargeted: dropTargeted)
            }
        }
        .overlay {
            if model.isLoading {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(model.loadingMessage).font(.callout)
                    }
                    .padding(28)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .alert("Couldn't open export", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    let dropTargeted: Bool

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 56))
                .foregroundStyle(Palette.primary)
            VStack(spacing: 6) {
                Text("RVTools Analyzer").font(.largeTitle.weight(.semibold))
                Text("Correlates every RVTools tab into one model of your vSphere estate and rolls it up into\ncapacity, utilization, configuration, lifecycle and health dashboards.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("Drop an RVTools .xlsx export, a folder of RVTools_tab*.csv files, or a saved project here").font(.callout)
                Text("Drop several exports at once to merge multiple vCenters.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 520, height: 150)
            .background(RoundedRectangle(cornerRadius: 14).fill(dropTargeted ? Palette.primary.opacity(0.12) : Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5])).foregroundStyle(dropTargeted ? Palette.primary : Color.secondary.opacity(0.4)))
            HStack(spacing: 12) {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Open…", systemImage: "folder").padding(.horizontal, 6)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o")
                if let sample = model.sampleURL {
                    Button("Try Sample Data") { model.open([sample]) }.controlSize(.large)
                }
            }
            RecentProjectsList()
            Text("Your RVTools data stays on this Mac — cloud solutions only download public price lists.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Recently saved or opened projects on the start screen.
struct RecentProjectsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.recentProjects.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent projects").font(.headline)
                ForEach(model.recentProjects.prefix(6), id: \.self) { url in
                    Button { model.open([url]) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text").foregroundStyle(Palette.primary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.deletingPathExtension().lastPathComponent).font(.callout.weight(.medium))
                                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 5).padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.card))
                }
            }
            .frame(width: 520)
        }
    }
}

/// Name and free-form notes stored with the project.
struct ProjectInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Project").font(.title3.weight(.semibold))
            if model.projectURL == nil {
                Text("This session hasn't been saved yet — use Save Project (⌘S) to keep your selections, assumptions and these notes.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.projectURL!.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            TextField("Project name", text: $model.projectName).textFieldStyle(.roundedBorder)
            Text("Notes").font(.subheadline.weight(.semibold))
            TextEditor(text: $model.projectNotes)
                .font(.body)
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                if model.projectURL == nil {
                    Button("Save Project…") { dismiss(); model.saveProjectAs() }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    let report: Report

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.sidebar) {
                Section("Dashboard") {
                    row(.overview)
                    row(.issues, badge: report.totals.critical + report.totals.warning)
                }
                Section("Inventory") {
                    row(.compute, badge: report.totals.hosts)
                    row(.vms, badge: report.totals.vms + report.totals.templates)
                    row(.storage, badge: report.totals.datastores)
                    row(.network, badge: report.totals.portGroups)
                }
                Section("Analysis") {
                    row(.configuration)
                    row(.lifecycle)
                    row(.correlations)
                }
                Section("Solutions") {
                    ForEach(SolutionCatalog.all.map { SidebarItem.solution($0) }) { item in
                        row(item, badge: model.solutionSelections[item.solutionID ?? ""]?.count ?? 0)
                    }
                }
                Section("Source") {
                    row(.rawData, badge: model.dataset?.tableNames.count ?? 0)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Button { model.showProjectInfo = true } label: {
                        Label(model.projectTitle, systemImage: model.projectURL == nil ? "doc.badge.plus" : "doc.text")
                            .font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Project notes")
                    if let saved = model.lastSaved, model.projectURL != nil {
                        Text(model.isDirty ? "Saving…" : "Saved \(Fmt.dateTime(saved))").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(model.sourceSummary).font(.caption).lineLimit(2).truncationMode(.middle)
                    Text("Exported \(Fmt.dateTime(report.inventory.reportDate))" + ((model.dataset?.rvtoolsVersion ?? "").isEmpty ? "" : " · RVTools \(model.dataset!.rvtoolsVersion)"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } detail: {
            detail
                .navigationTitle(model.sidebar?.rawValue ?? "Overview")
                .navigationSubtitle(model.projectTitle + (model.projectURL != nil && model.isDirty ? " — Edited" : "") + " · " + model.scopeLabel)
        }
        .sheet(isPresented: $model.showProjectInfo) {
            ProjectInfoSheet().environment(model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Scope", selection: $model.scopeID) {
                    ForEach(model.scopes) { s in
                        if s.isGroupStart { Divider() }
                        Text(s.label).tag(s.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 200)
                .help("Limit every dashboard to a vCenter, datacenter or cluster")

                Button {
                    model.saveProject()
                } label: {
                    Label(model.projectURL == nil ? "Save Project" : "Save", systemImage: "square.and.arrow.down")
                }
                .help(model.projectURL == nil ? "Save this session as a project (⌘S)"
                                               : (model.isDirty ? "Saving changes to \(model.projectName)…" : "\(model.projectName) — all changes saved"))

                Menu {
                    ForEach(ExportKind.allCases) { kind in
                        Button("\(kind.rawValue) (CSV)…") { model.export(kind) }
                    }
                    Divider()
                    Button("All CSV files to folder…") { model.exportAll() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export correlated data and findings as CSV")

                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open another RVTools export")
            }
        }
    }

    /// The badge must be applied before `.tag` — a modifier added after the tag hides it from the
    /// List's selection, which made badged rows unclickable.
    private func row(_ item: SidebarItem, badge: Int = 0) -> some View {
        Label(item.rawValue, systemImage: item.symbol)
            .badge(badge)
            .tag(item)
    }

    @ViewBuilder private var detail: some View {
        switch model.sidebar ?? .overview {
        case .overview: OverviewView(report: report)
        case .issues: IssuesView(report: report)
        case .compute: ComputeView(report: report)
        case .vms: VMsView(report: report)
        case .storage: StorageView(report: report)
        case .network: NetworkView(report: report)
        case .configuration: ConfigurationView(report: report)
        case .lifecycle: LifecycleView(report: report)
        case .correlations: CorrelationsView(report: report)
        case .rawData: RawDataView()
        default:
            if let sid = model.sidebar?.solutionID, let solution = SolutionCatalog.solution(id: sid) {
                SolutionView(solution: solution, report: report).id(sid)
            } else {
                OverviewView(report: report)
            }
        }
    }
}
