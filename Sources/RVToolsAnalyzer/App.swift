import AppKit
import RVToolsCore
import SwiftUI

@main
struct RVToolsAnalyzerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("RVTools Analyzer", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(BuildInfo.name)") { BuildInfo.showAboutPanel() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }.keyboardShortcut("o")
                Button("Compare Snapshots…") { model.presentTrendPanel() }.keyboardShortcut("o", modifiers: [.command, .option])
                Menu("Open Recent Project") {
                    ForEach(model.recentProjects, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { model.open([url]) }
                    }
                    if !model.recentProjects.isEmpty {
                        Divider()
                        Button("Clear Menu") { model.clearRecentProjects() }
                    }
                }
                .disabled(model.recentProjects.isEmpty)
                Divider()
                Button("Close") { model.close() }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(model.report == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { model.saveProject() }.keyboardShortcut("s").disabled(model.report == nil)
                Button("Save Project As…") { model.saveProjectAs() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.report == nil)
                Divider()
                Button("Project Notes…") { model.showProjectInfo = true }.disabled(model.report == nil)
            }
            CommandMenu("Export") {
                ForEach(ExportKind.allCases) { kind in
                    Button("\(kind.rawValue) as CSV…") { model.export(kind) }.disabled(model.report == nil)
                }
                Divider()
                Button("All CSV Files to Folder…") { model.exportAll() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.report == nil)
                Divider()
                Button("Trend Report to Folder…") { model.exportTrend() }.disabled(model.trend == nil)
            }
            CommandMenu("Solutions") {
                Button("Install Solution or Price List…") { model.presentInstallPanel() }
                Button("Reload Custom Solutions") { model.reloadExtensions() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Open Solutions Folder") { model.openFolder(SolutionLibrary.directory) }
                Button("Open Price Lists Folder") { model.openFolder(PriceLibrary.directory) }
                Divider()
                Button("Install Examples") { model.installExamples() }.disabled(model.bundledExamplesURL == nil)
                Button("Authoring Guide") { model.openAuthoringGuide() }.disabled(model.authoringGuideURL == nil)
            }
            CommandMenu("Go") {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { i, item in
                    Button(item.rawValue) { model.sidebar = item }
                        .keyboardShortcut(KeyEquivalent(Character("\((i + 1) % 10)")), modifiers: .command)
                        .disabled(model.report == nil)
                }
                Divider()
                ForEach(SidebarItem.trendPages) { item in
                    Button(item.rawValue) { model.sidebar = item }.disabled(model.trend == nil)
                }
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// Which build is running, from keys `scripts/build-app.sh` writes into Info.plist.
enum BuildInfo {
    private static func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

    static let name = info("CFBundleName") ?? "RVTools Analyzer"
    /// A Dev build (`scripts/build-app.sh dev`): separate settings and custom solutions.
    static let isDev = info("RVTABuildVariant") == "dev"
    /// `git describe` of the source, e.g. "v1.0-3-g1a2b3c4"; "-dirty" means built with uncommitted changes.
    static let build = info("RVTABuild")

    static func showAboutPanel() {
        var lines: [String] = []
        if isDev { lines.append("Dev build — its own settings and custom solutions (~/Library/Application Support/\(info("RVTASupportFolder") ?? name)).") }
        if let date = info("RVTABuildDate").flatMap({ ISO8601DateFormatter().date(from: $0) }) { lines.append("Built \(Fmt.dateTime(date)) UTC") }
        lines.append("Local RVTools analysis — data never leaves this Mac.")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: isDev ? NSColor.systemOrange : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits]
        if let build { options[.version] = build }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Marks the Dev build in the window, so it's never mistaken for the installed app.
struct DevBuildBadge: View {
    var body: some View {
        if BuildInfo.isDev {
            Label("Dev build" + (BuildInfo.build.map { " · \($0)" } ?? ""), systemImage: "hammer.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help("Separate settings and custom solutions from the installed RVTools Analyzer")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Allow `RVToolsAnalyzer [--trend] <file-or-folder>...` from the command line.
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        if !paths.isEmpty {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            let trend = CommandLine.arguments.contains("--trend")
            Task { @MainActor in trend ? AppModel.shared.openTrend(urls) : AppModel.shared.open(urls) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.open(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Offers to save a customized, unsaved session (saved projects are written silently).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.confirmDiscardChanges() } ? .terminateNow : .terminateCancel
    }
}
