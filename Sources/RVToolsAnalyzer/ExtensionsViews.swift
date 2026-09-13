import CoreServices
import RVToolsCore
import SwiftUI

/// Watches the solution and price list folders (recursively) so edits reload without restarting the app.
final class ExtensionWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(paths: [String], onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ExtensionWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

private func tildePath(_ url: URL) -> String {
    url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

// MARK: - Settings › Solutions

struct SolutionsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.extensionsVersion
        let library = SolutionLibrary.shared
        VStack(alignment: .leading, spacing: 12) {
            Text("Add solutions without changing the app: a folder with a manifest.json and a JavaScript file. Scripts run on this Mac with no file or network access, and can read the cloud prices and price lists the app already has.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                Section("Custom") {
                    if library.solutions.isEmpty {
                        Text("No custom solutions yet — install a pack, or the examples.").foregroundStyle(.secondary)
                    }
                    ForEach(library.solutions, id: \.id) { s in
                        CustomSolutionRow(solution: s)
                    }
                }
                if !library.issues.isEmpty {
                    Section("Couldn't load") {
                        ForEach(library.issues) { issue in
                            IssueRow(path: issue.path, message: issue.message)
                        }
                    }
                }
                Section("Built in") {
                    ForEach(SolutionCatalog.builtIn, id: \.id) { s in
                        HStack(spacing: 10) {
                            Image(systemName: s.symbol).frame(width: 22).foregroundStyle(Palette.primary)
                            Text(s.title)
                            Spacer()
                            Label("Included with the app", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Button("Install…") { model.presentInstallPanel() }
                Button("Reload") { model.reloadExtensions() }
                Button("Open Solutions Folder") { model.openFolder(SolutionLibrary.directory) }
                Spacer()
                if model.bundledExamplesURL != nil { Button("Install Examples") { model.installExamples() } }
                if model.authoringGuideURL != nil { Button("Authoring Guide") { model.openAuthoringGuide() } }
            }
            Text("Packs in \(tildePath(SolutionLibrary.directory)) reload automatically when they change. Turned-off solutions keep their settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct CustomSolutionRow: View {
    @Environment(AppModel.self) private var model
    let solution: ScriptedSolution

    private var isInstalled: Bool { SolutionLibrary.isInstalled(solution.packURL) }

    var body: some View {
        let _ = model.extensionsVersion
        HStack(alignment: .top, spacing: 10) {
            Toggle("Enabled", isOn: Binding(get: { model.isSolutionEnabled(solution.id) }, set: { model.setSolutionEnabled(solution.id, $0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Show this solution in the sidebar")
            Image(systemName: solution.symbol).frame(width: 22).foregroundStyle(Palette.primary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(solution.title).fontWeight(.medium)
                    Text([solution.version, solution.author].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
                }
                if !solution.summary.isEmpty {
                    Text(solution.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(solution.id + " · " + tildePath(solution.packURL) + (solution.providers.isEmpty ? "" : " · prices: " + solution.providers.joined(separator: ", ")))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Menu {
                Button("Show in Finder") { model.showInFinder(solution.packURL) }
                Button("Open \(solution.scriptURL.lastPathComponent)") { model.openFile(solution.scriptURL) }
                Divider()
                Button("Move to Trash…", role: .destructive) { model.removeSolution(solution) }.disabled(!isInstalled)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 3)
    }
}

private struct IssueRow: View {
    @Environment(AppModel.self) private var model
    let path: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: path).lastPathComponent).fontWeight(.medium)
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer()
            Button("Show in Finder") { model.showInFinder(URL(fileURLWithPath: path)) }.controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Settings › Price Lists

struct PriceListsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.extensionsVersion
        let _ = model.priceVersion
        let library = PriceLibrary.shared
        VStack(alignment: .leading, spacing: 12) {
            Text("Price lists give custom solutions negotiated or private rates: a discount on the downloaded Azure / AWS list prices, or a complete rate card. A solution reads a price list only if its manifest names it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                Section("Price lists") {
                    if library.all.isEmpty {
                        Text("No price lists yet — import a .rvaprices file.").foregroundStyle(.secondary)
                    }
                    ForEach(library.all) { entry in
                        PriceListRow(entry: entry)
                    }
                }
                if !library.issues.isEmpty {
                    Section("Couldn't load") {
                        ForEach(library.issues) { issue in
                            IssueRow(path: issue.path, message: issue.message)
                        }
                    }
                }
                Section("Built in") {
                    ForEach(CloudProvider.allCases, id: \.self) { p in
                        let regions = PriceStore.shared.availableRegions(p)
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "cloud").frame(width: 22).foregroundStyle(Palette.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(p.name) list prices").fontWeight(.medium)
                                Text("id “\(p.rawValue)” · " + (regions.isEmpty ? "nothing downloaded yet" : "\(regions.count) region\(regions.count == 1 ? "" : "s") downloaded"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label("Public list prices, USD", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Button("Import…") { model.presentInstallPanel() }
                Button("Reload") { model.reloadExtensions() }
                Button("Open Price Lists Folder") { model.openFolder(PriceLibrary.directory) }
                Spacer()
                if model.authoringGuideURL != nil { Button("File Format") { model.openAuthoringGuide() } }
            }
            Text("Projects save a copy of the price lists their custom solutions use, so they open with the same rates on another Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct PriceListRow: View {
    @Environment(AppModel.self) private var model
    let entry: PriceLibrary.Entry

    private var detail: String {
        let list = entry.list
        var parts: [String] = []
        if let base = list.baseProvider {
            var text = "Based on \(base.name) list prices"
            if let d = list.discountPct, d > 0 { text += ", \(Fmt.num(d, d.rounded() == d ? 0 : 1))% off" }
            if let d = list.storageDiscountPct, d > 0 { text += " (storage \(Fmt.num(d, d.rounded() == d ? 0 : 1))% off)" }
            parts.append(text)
            parts.append(list.regionCodes.isEmpty ? "every region" : "\(list.regionCodes.count) region\(list.regionCodes.count == 1 ? "" : "s")")
        } else {
            let instances = (list.regions ?? []).reduce(0) { $0 + ($1.instances?.count ?? 0) }
            parts.append("\(list.regionCodes.count) region\(list.regionCodes.count == 1 ? "" : "s") · \(instances) instance prices")
        }
        parts.append(list.currencyCode)
        if let effective = list.effective { parts.append("effective \(effective)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "list.bullet.rectangle").frame(width: 22).foregroundStyle(Palette.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.list.name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let source = entry.list.source, !source.isEmpty {
                    Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("id “\(entry.list.id)” · \(entry.origin.label)" + (entry.url.map { " · " + tildePath($0) } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Menu {
                Button("Show in Finder") { if let url = entry.url { model.showInFinder(url) } }.disabled(entry.url == nil)
                Divider()
                Button("Move to Trash…", role: .destructive) { model.removePriceList(entry) }.disabled(entry.origin != .installed)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Missing solution

/// Shown for a custom solution a project uses that isn't installed (or is turned off) on this Mac.
struct MissingSolutionView: View {
    @Environment(\.openSettings) private var openSettings
    let id: String

    var body: some View {
        ContentUnavailableView {
            Label("“\(id)” isn't available", systemImage: "puzzlepiece.extension")
        } description: {
            Text("This project has a VM selection and assumptions for the custom solution “\(id)”, which isn't installed or is turned off on this Mac. They stay in the project: install the solution's .rvasolution pack to see its results.")
        } actions: {
            Button("Manage Solutions…") {
                UserDefaults.standard.set("solutions", forKey: "settingsTab")
                openSettings()
            }
        }
    }
}
