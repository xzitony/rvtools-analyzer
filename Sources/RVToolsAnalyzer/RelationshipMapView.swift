import AppKit
import RVToolsCore
import SwiftUI
import UniformTypeIdentifiers

extension RelKind {
    var symbol: String {
        switch self {
        case .datacenter: return "building.2"
        case .cluster: return "square.stack.3d.up"
        case .host: return "server.rack"
        case .vm: return "desktopcomputer"
        case .folder: return "folder"
        case .resourcePool: return "chart.pie"
        case .vApp: return "shippingbox"
        case .datastore: return "externaldrive"
        case .storageDevice: return "internaldrive"
        case .portGroup: return "network"
        case .standardSwitch, .distributedSwitch: return "switch.2"
        case .physicalNIC: return "cable.connector"
        case .vmkernel: return "bolt.horizontal"
        case .vlan: return "tag"
        }
    }

    /// One colour per layer: placement, workloads, storage, network, physical.
    var tint: Color {
        switch self {
        case .datacenter, .cluster, .host: return Palette.series[0]
        case .vm, .folder, .resourcePool, .vApp: return Palette.series[6]
        case .datastore, .storageDevice: return Palette.series[2]
        case .portGroup, .standardSwitch, .distributedSwitch, .vlan: return Palette.series[1]
        case .physicalNIC, .vmkernel: return Palette.series[3]
        }
    }
}

/// Opens the relationship map of an object in its own window.
struct RelationshipMapButton: View {
    @Environment(\.openWindow) private var openWindow
    let focus: RelFocus
    var compact = false

    var body: some View {
        Button { openWindow(id: RelationshipMapWindow.windowID, value: focus) } label: {
            if compact {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
            } else {
                Label("Relationship Map", systemImage: "point.3.filled.connected.trianglepath.dotted")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Show everything this is connected to, and export it")
    }
}

// MARK: - Window

struct RelationshipMapWindow: View {
    static let windowID = "relationship-map"
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var history: [RelFocus]
    @State private var expanded: Set<String> = []
    @State private var hovered: String?

    init(focus: RelFocus) { _history = State(initialValue: [focus]) }

    var body: some View {
        let focus = history.last!
        let map = model.report.flatMap { RelationshipBuilder.map(focus, in: $0.inventory) }
        Group {
            if let map {
                ScrollView([.horizontal, .vertical]) {
                    RelationshipCanvas(map: map, expanded: $expanded, hovered: $hovered,
                                       onFocus: { f in
                                           history.append(f)
                                           expanded = []
                                           hovered = nil
                                       },
                                       onReveal: reveal)
                        .padding(32)
                }
                .background(Palette.track.opacity(0.35))
            } else {
                ContentUnavailableView("Not in the current view", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Open the export again, or set the scope to include this object."))
            }
        }
        .navigationTitle(map?.focus.name ?? "Relationship Map")
        .navigationSubtitle(map.map { "\($0.focus.kind.rawValue) relationships · \(model.scopeLabel)" } ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    history.removeLast()
                    expanded = []
                } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(history.count < 2)
                .help("Back to the previous map")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let map {
                    Button {
                        expanded = allGroupKeys(map).isSubset(of: expanded) ? [] : allGroupKeys(map)
                    } label: {
                        Label(allGroupKeys(map).isSubset(of: expanded) ? "Collapse Groups" : "Expand Groups", systemImage: "rectangle.expand.vertical")
                    }
                    .help("Show every object instead of the first few in each group")
                    Button { reveal(map.focus) } label: { Label("Show in Inventory", systemImage: "arrow.up.forward.app") }
                        .disabled(map.focus.object == nil)
                        .help("Select this object on its inventory page")
                    Menu {
                        Button("This Map’s Relationships (CSV)…") { exportCSV(map) }
                        Button("This Map as an Image (PNG)…") { exportPNG(map) }
                        Divider()
                        ForEach(ExportKind.relationships) { kind in
                            Button("All \(kind.rawValue) (CSV)…") { model.export(kind) }
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Export this map, or every relationship of one type for planning")
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private func allGroupKeys(_ map: RelationshipMap) -> Set<String> {
        Set(map.columns.enumerated().flatMap { ci, column in
            column.groups.indices.filter { column.groups[$0].nodes.count > RelationshipCanvas.visibleLimit + 1 }.map { "\(ci)-\($0)" }
        })
    }

    private func reveal(_ node: RelNode) {
        guard let object = node.object else { return }
        model.reveal(object.kind, object.id)
        openWindow(id: "main")
    }

    private func fileBase(_ map: RelationshipMap) -> String {
        let name = map.focus.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(model.exportBaseName)_\(name)_relationships"
    }

    private func exportCSV(_ map: RelationshipMap) {
        let panel = NSSavePanel()
        panel.title = "Export Relationships"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = fileBase(map) + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try map.csv().write(to: url, atomically: true, encoding: .utf8) } catch {
            model.errorMessage = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func exportPNG(_ map: RelationshipMap) {
        guard let png = RelationshipMapImage.png(map, expanded: expanded, subtitle: "\(model.projectTitle) · \(model.scopeLabel)") else {
            model.errorMessage = "The map couldn't be rendered as an image."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Relationship Map"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileBase(map) + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try png.write(to: url) } catch {
            model.errorMessage = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

enum RelationshipMapImage {
    /// The map as a PNG on a white background (2× scale), with a title.
    @MainActor
    static func png(_ map: RelationshipMap, expanded: Set<String> = [], subtitle: String) -> Data? {
        let content = VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(map.focus.kind.rawValue): \(map.focus.name)").font(.title2.weight(.semibold))
                Text("Relationship map · \(subtitle)").font(.callout).foregroundStyle(.secondary)
            }
            RelationshipCanvas(map: map, expanded: .constant(expanded), hovered: .constant(nil), interactive: false)
        }
        .padding(32)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Canvas

private struct NodeFramesKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Columns of object cards with curved connectors between related objects. Groups longer than `visibleLimit` collapse
/// to a "+N more" pill that the hidden objects' connectors lead to.
struct RelationshipCanvas: View {
    static let visibleLimit = 8
    let map: RelationshipMap
    @Binding var expanded: Set<String>
    @Binding var hovered: String?
    var interactive = true
    var onFocus: (RelFocus) -> Void = { _ in }
    var onReveal: (RelNode) -> Void = { _ in }

    private func isOpen(_ group: RelGroup, _ key: String) -> Bool {
        expanded.contains(key) || group.nodes.count <= Self.visibleLimit + 1
    }

    var body: some View {
        let related = relatedIDs
        let redirect = hiddenRedirects
        HStack(alignment: .center, spacing: 96) {
            ForEach(Array(map.columns.enumerated()), id: \.offset) { ci, column in
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(column.groups.enumerated()), id: \.offset) { gi, group in
                        groupView(group, key: "\(ci)-\(gi)", isFocus: ci == map.focusColumn && group.nodes.contains { $0.id == map.focus.id }, related: related)
                    }
                }
                .frame(width: ci == map.focusColumn ? 260 : 236)
            }
        }
        .backgroundPreferenceValue(NodeFramesKey.self) { anchors in
            GeometryReader { proxy in
                let frames = anchors.mapValues { proxy[$0] }
                Canvas { ctx, _ in
                    var drawn = Set<String>()
                    var labels: [(String, CGPoint)] = []
                    for link in map.links {
                        let from = redirect[link.from] ?? link.from, to = redirect[link.to] ?? link.to
                        guard from != to, let a = frames[from], let b = frames[to], drawn.insert(from + ">" + to).inserted || isLit(link) else { continue }
                        let forward = a.midX <= b.midX
                        let start = CGPoint(x: forward ? a.maxX : a.minX, y: a.midY)
                        let end = CGPoint(x: forward ? b.minX : b.maxX, y: b.midY)
                        let dx = abs(end.x - start.x) * 0.5 * (forward ? 1 : -1)
                        var path = Path()
                        path.move(to: start)
                        path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
                        let lit = isLit(link)
                        ctx.stroke(path, with: .color(lit ? Palette.primary : Color.secondary.opacity(hovered == nil ? 0.4 : 0.12)), lineWidth: lit ? 2 : 1.1)
                        if lit, !link.label.isEmpty { labels.append((link.label, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 8))) }
                    }
                    for (label, point) in labels {
                        ctx.draw(Text(label).font(.caption2.weight(.medium)).foregroundColor(Palette.primary), at: point)
                    }
                }
            }
        }
    }

    private func isLit(_ link: RelLink) -> Bool {
        guard let h = hovered else { return false }
        return link.from == h || link.to == h
    }

    /// The hovered node and everything linked to it.
    private var relatedIDs: Set<String> {
        guard let h = hovered else { return [] }
        var ids: Set<String> = [h]
        for l in map.links where l.from == h || l.to == h { ids.insert(l.from); ids.insert(l.to) }
        return ids
    }

    /// Nodes hidden in a collapsed group → that group's "+N more" pill.
    private var hiddenRedirects: [String: String] {
        var out: [String: String] = [:]
        for (ci, column) in map.columns.enumerated() {
            for (gi, group) in column.groups.enumerated() where !isOpen(group, "\(ci)-\(gi)") {
                for n in group.nodes.dropFirst(Self.visibleLimit) { out[n.id] = "more:\(ci)-\(gi)" }
            }
        }
        return out
    }

    @ViewBuilder
    private func groupView(_ group: RelGroup, key: String, isFocus: Bool, related: Set<String>) -> some View {
        let open = isOpen(group, key)
        let shown = open ? group.nodes : Array(group.nodes.prefix(Self.visibleLimit))
        VStack(alignment: .leading, spacing: 6) {
            if !isFocus {
                HStack(spacing: 5) {
                    Text(group.title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(group.nodes.count)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ForEach(shown) { node in
                RelationshipNodeCard(node: node, isFocus: isFocus, dimmed: hovered != nil && !related.contains(node.id), clickable: interactive && !isFocus && node.focus != nil)
                    .anchorPreference(key: NodeFramesKey.self, value: .bounds) { [node.id: $0] }
                    .onHover { inside in
                        guard interactive else { return }
                        if inside { hovered = node.id } else if hovered == node.id { hovered = nil }
                    }
                    .onTapGesture {
                        if interactive, !isFocus, let f = node.focus { onFocus(f) }
                    }
                    .contextMenu {
                        if let f = node.focus, !isFocus { Button("Centre the Map Here") { onFocus(f) } }
                        if node.object != nil { Button("Show in Inventory") { onReveal(node) } }
                        Button("Copy Name") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(node.name, forType: .string)
                        }
                    }
            }
            if group.nodes.count > shown.count {
                Button { expanded.insert(key) } label: {
                    Text("+\(group.nodes.count - shown.count) more").font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Palette.track))
                }
                .buttonStyle(.plain)
                // Anchored across the column, so connectors start at its edge instead of crossing the cards.
                .frame(maxWidth: .infinity, alignment: .leading)
                .anchorPreference(key: NodeFramesKey.self, value: .bounds) { ["more:" + key: $0] }
                .help("Show all \(group.nodes.count) \(group.title.lowercased())")
            } else if interactive, expanded.contains(key), group.nodes.count > Self.visibleLimit + 1 {
                Button("Show fewer") { expanded.remove(key) }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

struct RelationshipNodeCard: View {
    let node: RelNode
    let isFocus: Bool
    let dimmed: Bool
    var clickable = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: node.kind.symbol)
                .font(isFocus ? .title3 : .callout)
                .foregroundStyle(node.kind.tint)
                .frame(width: isFocus ? 24 : 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).font(isFocus ? .headline : .callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if !node.detail.isEmpty {
                    Text(node.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let alert = node.alert {
                Image(systemName: Severity.warning.symbol).foregroundStyle(Palette.warning).font(.caption).help(alert)
            }
            if node.issues > 0 {
                Text("\(node.issues)").font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Palette.track))
                    .help("\(node.issues) finding\(node.issues == 1 ? "" : "s")")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, isFocus ? 10 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(isFocus ? Palette.primary : Color.primary.opacity(0.12), lineWidth: isFocus ? 2 : 1))
        .opacity(dimmed ? 0.35 : (node.muted ? 0.72 : 1))
        .contentShape(Rectangle())
        .help([node.kind.rawValue + ": " + node.name, node.detail, node.alert ?? "", clickable ? "Click to centre the map here" : ""]
            .filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}
