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
    @State private var showAcknowledged = false
    @State private var pending: PendingAcknowledgement?

    private struct Filtered: Identifiable {
        let group: FindingGroup
        let findings: [Finding]
        var id: String { group.rule }
    }

    /// Findings waiting for a note before they're acknowledged.
    struct PendingAcknowledgement: Identifiable {
        let id = UUID()
        let title: String
        let rule: String
        let findings: [Finding]
        let wholeCheck: Bool
    }

    private var sourceFindings: [Finding] { showAcknowledged ? report.acknowledgedFindings : report.findings }
    private var sourceGroups: [FindingGroup] { showAcknowledged ? report.acknowledgedGroups : report.groups }

    private var filtered: [Filtered] {
        let q = search.lowercased()
        return sourceGroups.compactMap { g in
            guard severities.contains(g.severity), category == nil || g.category == category else { return nil }
            var fs = g.findings
            if let kind { fs = fs.filter { $0.kind == kind } }
            if !q.isEmpty, !g.title.lowercased().contains(q) {
                fs = fs.filter { $0.objectName.lowercased().contains(q) || $0.detail.lowercased().contains(q) || $0.location.lowercased().contains(q) }
            }
            return fs.isEmpty ? nil : Filtered(group: g, findings: fs)
        }
    }

    /// Whole-check acknowledgements with no current findings (only listed in the Acknowledged view).
    private var idleCheckAcknowledgements: [Acknowledgement] {
        let rules = Set(report.acknowledgedGroups.map(\.rule))
        return report.acknowledgements.filter { $0.isWholeCheck && !rules.contains($0.rule) }
    }

    var body: some View {
        let groups = filtered
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("View", selection: $showAcknowledged) {
                    Text("Open").tag(false)
                    Text("Acknowledged (\(Fmt.int(report.acknowledgedFindings.count)))").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Divider().frame(height: 18)
                ForEach(Severity.allCases) { s in
                    Toggle(isOn: Binding(get: { severities.contains(s) }, set: { on in if on { severities.insert(s) } else { severities.remove(s) } })) {
                        HStack(spacing: 4) {
                            SeverityBadge(severity: s)
                            Text(Fmt.int(sourceFindings.filter { $0.severity == s }.count)).foregroundStyle(.secondary).tabular()
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
            if groups.isEmpty && (!showAcknowledged || idleCheckAcknowledgements.isEmpty) {
                if showAcknowledged {
                    ContentUnavailableView("Nothing acknowledged", systemImage: "checkmark.seal",
                                           description: Text("Acknowledge findings you've reviewed and accepted. They're left out of counts, badges and exports, and listed here."))
                } else {
                    ContentUnavailableView("No matching findings", systemImage: "checkmark.seal", description: Text("Adjust the filters above."))
                }
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(groups) { fg in
                            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(fg.id) }, set: { if $0 { expanded.insert(fg.id) } else { expanded.remove(fg.id) } })) {
                                Label(fg.group.recommendation, systemImage: "lightbulb")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                                if showAcknowledged, let check = report.acknowledgements.first(where: { $0.rule == fg.group.rule && $0.isWholeCheck }) {
                                    AcknowledgementNote(acknowledgement: check, prefix: "Whole check acknowledged")
                                }
                                ForEach(fg.findings) { f in
                                    if showAcknowledged {
                                        FindingRow(finding: f, acknowledgement: report.acknowledgements.covering(f),
                                                   onRestore: { model.restore([f]) })
                                    } else {
                                        FindingRow(finding: f, onAcknowledge: {
                                            pending = PendingAcknowledgement(title: "\(fg.group.title) — \(f.objectName)", rule: f.rule, findings: [f], wholeCheck: false)
                                        })
                                    }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    SeverityBadge(severity: fg.group.severity, showLabel: false)
                                    Text(fg.group.title).font(.body.weight(.medium))
                                    Tag(text: fg.group.category.rawValue)
                                    Spacer()
                                    Text(Fmt.int(fg.findings.count)).font(.body.weight(.semibold)).tabular()
                                    groupMenu(fg)
                                }
                                .padding(.vertical, 3)
                            }
                            .id(fg.id)
                        }
                        if showAcknowledged && !idleCheckAcknowledgements.isEmpty {
                            Section("Acknowledged checks with no current findings") {
                                ForEach(idleCheckAcknowledgements) { a in
                                    HStack {
                                        AcknowledgementNote(acknowledgement: a, prefix: a.rule)
                                        Spacer()
                                        Button("Restore") { model.restore(a) }.buttonStyle(.link).font(.caption)
                                    }
                                }
                            }
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
        .sheet(item: $pending) { p in
            AcknowledgeSheet(pending: p) { note in
                if p.wholeCheck { model.acknowledgeCheck(p.rule, note: note) } else { model.acknowledge(p.findings, note: note) }
            }
        }
    }

    @ViewBuilder
    private func groupMenu(_ fg: Filtered) -> some View {
        Menu {
            if showAcknowledged {
                Button("Restore \(fg.findings.count == 1 ? "Finding" : "All \(Fmt.int(fg.findings.count)) Findings")") {
                    model.restore(fg.findings, wholeCheck: fg.group.rule)
                }
            } else {
                Button("Acknowledge \(fg.findings.count == 1 ? "This Finding" : "These \(Fmt.int(fg.findings.count)) Findings")…") {
                    pending = PendingAcknowledgement(title: fg.group.title, rule: fg.group.rule, findings: fg.findings, wholeCheck: false)
                }
                Button("Acknowledge Whole Check…") {
                    pending = PendingAcknowledgement(title: fg.group.title, rule: fg.group.rule, findings: fg.findings, wholeCheck: true)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(showAcknowledged ? "Restore" : "Acknowledge")
    }
}

/// Asks for an optional note before acknowledging.
private struct AcknowledgeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pending: IssuesView.PendingAcknowledgement
    let onConfirm: (String) -> Void
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.wholeCheck ? "Acknowledge the whole check?" : "Acknowledge \(pending.findings.count == 1 ? "this finding" : "\(Fmt.int(pending.findings.count)) findings")?")
                .font(.title3.weight(.semibold))
            Text(pending.title).font(.callout.weight(.medium))
            Text(pending.wholeCheck
                 ? "Every finding of this check, now and in future exports, is left out of counts, badges, inspectors and exports."
                 : "\(pending.findings.count == 1 ? "It's" : "They're") left out of counts, badges, inspectors and exports. The same check on the same object stays acknowledged in newer exports.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Note (optional): reason, owner or ticket", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            Text("Restore it any time from the Acknowledged view. Projects save acknowledgements.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Acknowledge") { onConfirm(note.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct AcknowledgementNote: View {
    let acknowledgement: Acknowledgement
    let prefix: String

    var body: some View {
        Label(prefix + " " + Fmt.date(acknowledgement.date) + (acknowledgement.note.isEmpty ? "" : " — " + acknowledgement.note), systemImage: "checkmark.seal")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let finding: Finding
    var showTitle = false
    var acknowledgement: Acknowledgement? = nil
    var onAcknowledge: (() -> Void)? = nil
    var onRestore: (() -> Void)? = nil

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
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if let a = acknowledgement {
                    AcknowledgementNote(acknowledgement: a, prefix: a.isWholeCheck ? "Whole check acknowledged" : "Acknowledged")
                }
            }
            Spacer(minLength: 8)
            if !showTitle && canReveal {
                Button("Show") { model.reveal(finding) }.buttonStyle(.link).font(.caption)
            }
            if let onAcknowledge {
                Button("Acknowledge") { onAcknowledge() }.buttonStyle(.link).font(.caption)
            }
            if let onRestore, acknowledgement?.isWholeCheck != true {
                Button("Restore") { onRestore() }.buttonStyle(.link).font(.caption)
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
