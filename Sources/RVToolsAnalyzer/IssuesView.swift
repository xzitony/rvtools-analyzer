import RVToolsCore
import SwiftUI

extension ObjectKind {
    var symbol: String {
        switch self {
        case .vm: return "desktopcomputer"
        case .host: return "server.rack"
        case .cluster: return "square.grid.3x3"
        case .datastore: return "externaldrive"
        case .network: return "network"
        case .vcenter: return "building.2"
        case .other: return "questionmark.square.dashed"
        }
    }
}

struct IssuesView: View {
    @Environment(AppModel.self) private var model
    let report: Report
    @State private var severities: Set<Severity> = Set(Severity.allCases)
    @State private var category: FindingCategory?
    @State private var kind: ObjectKind?
    @State private var search = ""
    @State private var expanded: Set<String> = []

    private struct Filtered: Identifiable {
        let group: FindingGroup
        let findings: [Finding]
        var id: String { group.rule }
    }

    private var filtered: [Filtered] {
        let q = search.lowercased()
        return report.groups.compactMap { g in
            guard severities.contains(g.severity), category == nil || g.category == category else { return nil }
            var fs = g.findings
            if let kind { fs = fs.filter { $0.kind == kind } }
            if !q.isEmpty, !g.title.lowercased().contains(q) {
                fs = fs.filter { $0.objectName.lowercased().contains(q) || $0.detail.lowercased().contains(q) || $0.location.lowercased().contains(q) }
            }
            return fs.isEmpty ? nil : Filtered(group: g, findings: fs)
        }
    }

    var body: some View {
        let groups = filtered
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(Severity.allCases) { s in
                    Toggle(isOn: Binding(get: { severities.contains(s) }, set: { on in if on { severities.insert(s) } else { severities.remove(s) } })) {
                        HStack(spacing: 4) {
                            SeverityBadge(severity: s)
                            Text(Fmt.int(report.findings.filter { $0.severity == s }.count)).foregroundStyle(.secondary).tabular()
                        }
                        .fixedSize()
                    }
                    .toggleStyle(.button)
                }
                Divider().frame(height: 18)
                Picker("Category", selection: $category) {
                    Text("All categories").tag(FindingCategory?.none)
                    ForEach(FindingCategory.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                .frame(width: 210)
                Picker("Object", selection: $kind) {
                    Text("All objects").tag(ObjectKind?.none)
                    ForEach(ObjectKind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                .frame(width: 170)
                Spacer()
                Text("\(groups.count) checks · \(Fmt.int(groups.reduce(0) { $0 + $1.findings.count })) findings").font(.callout).foregroundStyle(.secondary)
                Button(expanded.isEmpty ? "Expand All" : "Collapse All") {
                    expanded = expanded.isEmpty ? Set(groups.map(\.id)) : []
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if groups.isEmpty {
                ContentUnavailableView("No matching findings", systemImage: "checkmark.seal", description: Text("Adjust the filters above."))
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(groups) { fg in
                            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(fg.id) }, set: { if $0 { expanded.insert(fg.id) } else { expanded.remove(fg.id) } })) {
                                Label(fg.group.recommendation, systemImage: "lightbulb")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                                ForEach(fg.findings) { f in FindingRow(finding: f) }
                            } label: {
                                HStack(spacing: 10) {
                                    SeverityBadge(severity: fg.group.severity, showLabel: false)
                                    Text(fg.group.title).font(.body.weight(.medium))
                                    Tag(text: fg.group.category.rawValue)
                                    Spacer()
                                    Text(Fmt.int(fg.findings.count)).font(.body.weight(.semibold)).tabular()
                                }
                                .padding(.vertical, 3)
                            }
                            .id(fg.id)
                        }
                    }
                    .onAppear {
                        if let rule = model.focusRule {
                            expanded.insert(rule)
                            model.focusRule = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(rule, anchor: .top) }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter checks, objects, details")
    }
}

struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let finding: Finding
    var showTitle = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: finding.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                if showTitle {
                    HStack(spacing: 4) {
                        SeverityBadge(severity: finding.severity, showLabel: false)
                        Text(finding.title).fontWeight(.medium)
                    }
                } else {
                    Text(finding.objectName).fontWeight(.medium).textSelection(.enabled)
                    if !finding.location.isEmpty { Text(finding.location).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .frame(minWidth: showTitle ? 0 : 240, alignment: .leading)
            Text(finding.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer(minLength: 8)
            if !showTitle && canReveal {
                Button("Show") { model.reveal(finding) }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var canReveal: Bool {
        switch finding.kind {
        case .vm: return model.lookup.vms[finding.objectID] != nil
        case .host: return model.lookup.hosts[finding.objectID] != nil
        case .datastore: return model.lookup.datastores[finding.objectID] != nil
        case .network: return model.lookup.portGroups[finding.objectID] != nil
        case .cluster: return true
        default: return false
        }
    }
}

/// Findings for one object, shown in detail inspectors.
struct ObjectFindings: View {
    let findings: [Finding]

    var body: some View {
        if findings.isEmpty {
            Label("No findings", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.good).font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(findings.sorted { $0.severity < $1.severity }) { f in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            SeverityBadge(severity: f.severity, showLabel: false)
                            Text(f.title).font(.callout.weight(.medium))
                        }
                        Text(f.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.leading, 21)
                    }
                }
            }
        }
    }
}
