import AppKit
import RVToolsCore

/// Developer aid: renders every page to PNG after an export loads, without needing Screen Recording permission.
///   RVTA_SNAPSHOT_DIR=/tmp/shots [RVTA_APPEARANCE=dark] [RVTA_SNAPSHOT_QUIT=1] RVToolsAnalyzer <export>
@MainActor
enum DebugSnapshot {
    private static var started = false

    static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard !started, let dir = env["RVTA_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        started = true
        let base = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if env["RVTA_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }

        let logURL = base.appendingPathComponent("snapshot.log")
        func log(_ s: String) {
            let line = "\(Date()) \(s)\n"
            if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
            else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
        }

        Task { @MainActor in
            log("windows: " + NSApp.windows.map { "\($0.className) visible=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: "; "))
            if let w = mainWindow() {
                w.setContentSize(NSSize(width: 1500, height: 960))
                w.center()
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            if env["RVTA_CLICKTEST"] == "1" {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await clickSidebarRows(model, log: log)
                if env["RVTA_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
                return
            }
            let inv = model.report?.inventory
            let worstVM = inv?.vms.max { $0.issueCount < $1.issueCount }?.id
            let busiestHost = inv?.hosts.max { $0.issueCount < $1.issueCount }?.id
            let fullestDS = inv?.datastores.max { $0.usedPct < $1.usedPct }?.id
            let steps: [(String, () -> Void)] = [
                ("01-overview", { model.sidebar = .overview }),
                ("02-issues", { model.focusRule = model.report?.groups.first?.rule; model.sidebar = .issues }),
                ("03-compute-clusters", { model.computeTab = 0; model.sidebar = .compute }),
                ("04-compute-hosts", { model.selectedHostID = busiestHost; model.computeTab = 1; model.sidebar = .compute }),
                ("05-vms", { model.selectedVMID = worstVM; model.sidebar = .vms }),
                ("06-storage", { model.storageTab = 0; model.sidebar = .storage }),
                ("07-datastores", { model.selectedDatastoreID = fullestDS; model.storageTab = 1; model.sidebar = .storage }),
                ("08-network", { model.networkTab = 0; model.sidebar = .network }),
                ("09-configuration", { model.sidebar = .configuration }),
                ("10-lifecycle", { model.sidebar = .lifecycle }),
                ("11-correlations", { model.sidebar = .correlations }),
                ("12-raw", { model.sidebar = .rawData }),
                ("13-overview-again", { model.sidebar = .overview }),
            ] + SolutionCatalog.all.enumerated().flatMap { i, s -> [(String, () -> Void)] in
                [("\(20 + i * 3)-\(s.id)-select", { model.solutionTab[s.id] = 0; model.sidebar = .solution(s) }),
                 ("\(21 + i * 3)-\(s.id)-assumptions", { model.solutionTab[s.id] = 1; model.sidebar = .solution(s) }),
                 ("\(22 + i * 3)-\(s.id)-results", { model.solutionTab[s.id] = 2; model.sidebar = .solution(s) })]
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for (name, setup) in steps {
                setup()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                log("\(name): " + capture(to: base.appendingPathComponent(name + ".png")))
            }
            if env["RVTA_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
        }
    }

    /// Clicks every row of the sidebar with synthetic mouse events and logs which page the app selects.
    private static func clickSidebarRows(_ model: AppModel, log: (String) -> Void) async {
        guard let window = mainWindow(), let root = window.contentView?.superview ?? window.contentView else { log("no window"); return }
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
        }
        let all = tables(in: root)
        log("tables: " + all.map { "\($0.className) rows=\($0.numberOfRows) x=\(Int($0.convert($0.bounds, to: nil).minX)) w=\(Int($0.bounds.width))" }.joined(separator: "; "))
        guard let sidebar = all.filter({ $0.numberOfRows > 5 }).min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) else {
            log("no sidebar table"); return
        }
        for row in 0..<sidebar.numberOfRows {
            let rect = sidebar.rect(ofRow: row)
            let p = sidebar.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let before = model.sidebar?.rawValue ?? "nil"
            let t = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let hit = sidebar.hitTest(sidebar.convert(p, from: nil)).map { String(describing: type(of: $0)) } ?? "nil"
            log("row \(row) h=\(Int(rect.height)) winY=\(Int(p.y)) hit=\(hit) | \(before) -> \(model.sidebar?.rawValue ?? "nil") selectedRow=\(sidebar.selectedRow)")
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.filter { $0.contentView != nil && $0.frame.width > 600 }.max { $0.frame.width < $1.frame.width }
    }

    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// An app may image its own windows without Screen Recording permission. The API is unavailable in the
    /// current SDK headers, so it is looked up at runtime; returns nil if it is gone.
    private static func windowServerImage(_ window: NSWindow) -> CGImage? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: WindowImageFn.self)
        // CGRectNull, kCGWindowListOptionIncludingWindow, window id, kCGWindowImageBoundsIgnoreFraming
        return fn(CGRect.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
    }

    private static func capture(to url: URL) -> String {
        guard let window = mainWindow(), let content = window.contentView else { return "no window" }
        if let image = windowServerImage(window), image.width > 100 {
            let rep = NSBitmapImageRep(cgImage: image)
            if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil {
                return "ok (window server) \(image.width)x\(image.height)"
            }
        }
        let view = content.superview ?? content
        guard view.bounds.width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no bitmap for \(view.bounds)" }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "png encode failed" }
        do { try png.write(to: url); return "ok \(rep.pixelsWide)x\(rep.pixelsHigh)" } catch { return "write failed: \(error.localizedDescription)" }
    }
}
