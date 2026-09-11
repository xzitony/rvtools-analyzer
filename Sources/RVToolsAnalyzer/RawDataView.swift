import AppKit
import RVToolsCore
import SwiftUI

/// Browse any tab exactly as loaded (all columns, including custom attributes).
struct RawDataView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var filter = ""

    var body: some View {
        let ds = model.dataset
        let names = ds?.tableNames ?? []
        let current = selected ?? names.first
        HSplitView {
            List(names, id: \.self, selection: $selected) { name in
                HStack {
                    Text(name)
                    Spacer()
                    Text(Fmt.int(ds?.table(name)?.rows.count ?? 0)).foregroundStyle(.secondary).tabular()
                }
            }
            .frame(minWidth: 180, idealWidth: 210, maxWidth: 300)
            VStack(spacing: 0) {
                if let name = current, let t = ds?.table(name) {
                    let rows = filtered(t)
                    HStack {
                        Text(t.name).font(.headline)
                        Text("\(t.headers.count) columns · \(Fmt.int(rows.count))\(rows.count == t.rows.count ? "" : " of \(Fmt.int(t.rows.count))") rows")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("Filter rows", text: $filter).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                    .padding(10)
                    Divider()
                    DataGrid(headers: t.headers, rows: rows, identity: "\(name)|\(filter)")
                } else {
                    ContentUnavailableView("No tab selected", systemImage: "tablecells")
                }
            }
            .frame(minWidth: 400)
        }
        .onAppear { if selected == nil { selected = names.first } }
    }

    private func filtered(_ t: RVToolsCore.Table) -> [[String]] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return t.rows }
        return t.rows.filter { $0.contains { $0.lowercased().contains(q) } }
    }
}

/// NSTableView-backed grid: fast with tens of thousands of rows and ~100 dynamic columns; click headers to sort.
struct DataGrid: NSViewRepresentable {
    let headers: [String]
    let rows: [[String]]
    let identity: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.style = .plain
        table.rowHeight = 20
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(headers: headers, rows: rows, identity: identity)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        private var headers: [String] = []
        private var rows: [[String]] = []
        private var view: [[String]] = []
        private var identity = ""

        func update(headers: [String], rows: [[String]], identity: String) {
            guard let table, identity != self.identity || headers != self.headers else { return }
            let headersChanged = headers != self.headers
            self.headers = headers
            self.rows = rows
            self.identity = identity
            if headersChanged {
                for c in table.tableColumns { table.removeTableColumn(c) }
                let sample = rows.prefix(200)
                for (i, h) in headers.enumerated() {
                    let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)"))
                    col.title = h
                    let longest = max(h.count, sample.map { i < $0.count ? $0[i].count : 0 }.max() ?? 0)
                    col.width = max(60, min(320, CGFloat(longest) * 7 + 18))
                    col.sortDescriptorPrototype = NSSortDescriptor(key: "\(i)", ascending: true)
                    table.addTableColumn(col)
                }
                table.sortDescriptors = []
                view = rows
            } else {
                applySort()
            }
            table.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { view.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let i = Int(tableColumn.identifier.rawValue), row < view.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
                field = reused
            } else {
                field = NSTextField(labelWithString: "")
                field.identifier = id
                field.lineBreakMode = .byTruncatingTail
                field.font = .systemFont(ofSize: 12)
            }
            let r = view[row]
            field.stringValue = i < r.count ? r[i] : ""
            return field
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            applySort()
            tableView.reloadData()
        }

        private func applySort() {
            guard let d = table?.sortDescriptors.first, let key = d.key, let i = Int(key) else { view = rows; return }
            let asc = d.ascending
            view = rows.sorted { a, b in
                let x = i < a.count ? a[i] : "", y = i < b.count ? b[i] : ""
                if let dx = Double(x), let dy = Double(y) { return asc ? dx < dy : dx > dy }
                let c = x.localizedStandardCompare(y)
                return asc ? c == .orderedAscending : c == .orderedDescending
            }
        }
    }
}
