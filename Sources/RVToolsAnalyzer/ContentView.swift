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
                Text("Drop an RVTools .xlsx export or a folder of RVTools_tab*.csv files here").font(.callout)
                Text("Drop several exports at once to merge multiple vCenters.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 520, height: 150)
            .background(RoundedRectangle(cornerRadius: 14).fill(dropTargeted ? Palette.primary.opacity(0.12) : Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5])).foregroundStyle(dropTargeted ? Palette.primary : Color.secondary.opacity(0.4)))
            HStack(spacing: 12) {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Open Export…", systemImage: "folder").padding(.horizontal, 6)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o")
                if let sample = model.sampleURL {
                    Button("Try Sample Data") { model.open([sample]) }.controlSize(.large)
                }
            }
            Text("Everything runs locally — nothing leaves this Mac.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    row(.issues).badge(report.totals.critical + report.totals.warning)
                }
                Section("Inventory") {
                    row(.compute).badge(report.totals.hosts)
                    row(.vms).badge(report.totals.vms + report.totals.templates)
                    row(.storage).badge(report.totals.datastores)
                    row(.network).badge(report.totals.portGroups)
                }
                Section("Analysis") {
                    row(.configuration)
                    row(.lifecycle)
                    row(.correlations)
                }
                Section("Source") {
                    row(.rawData).badge(model.dataset?.tableNames.count ?? 0)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
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
                .navigationSubtitle(model.scopeLabel)
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

    private func row(_ item: SidebarItem) -> some View {
        Label(item.rawValue, systemImage: item.symbol).tag(item)
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
        }
    }
}
