import Foundation

/// Lays blocks out on slides of a package, splitting tables, lists and tiles over as many slides as they need.
struct DeckRenderer {
    let pkg: DeckPackage
    init(_ pkg: DeckPackage) { self.pkg = pkg }

    private var c: Rect { pkg.content }
    private let gap = inch(0.2)

    func render(_ blocks: [DeckBlock]) -> [(xml: String, layout: String)] {
        blocks.flatMap { block -> [SlideXML] in
            switch block {
            case .title(let t, let sub, let date): return [cover(t, [sub, date].filter { !$0.isEmpty })]
            case .headline(let h): return [headline(h)]
            case .metrics(let t, let h, let items): return metrics(t, h, items)
            case .table(let t): return table(t)
            case .bars(let t, let sub, let rows, let more): return [bars(t, sub, rows, more)]
            case .bullets(let t, let lines): return bullets(t, lines)
            case .issue(let check): return [issue(check)]
            }
        }.enumerated().map { i, s in (s.xml(), i == 0 ? pkg.titleLayout.path : pkg.contentLayout.path) }
    }

    // MARK: Slide kinds

    private func slide(_ title: String) -> SlideXML {
        var s = SlideXML()
        // Largest scale, in 10% steps down to half size, at which the title fits its box (less the default 0.1" insets).
        let r = pkg.titleRect
        let scale = stride(from: 1.0, through: 0.5, by: -0.1).first { TextFit.height(title, width: r.w - inch(0.2), size: pkg.titleSize * $0) <= r.h - inch(0.1) } ?? 0.5
        s.placeholder(pkg.contentLayout.title, fallback: pkg.titleRect, lines: [title], size: 28, bold: true, color: .scheme("tx2"), fontScale: scale)
        return s
    }

    private func cover(_ title: String, _ lines: [String]) -> SlideXML {
        var s = SlideXML()
        s.placeholder(pkg.titleLayout.title, fallback: pkg.coverTitle, lines: [title], size: 40, bold: true, color: .scheme("tx2"))
        if !lines.isEmpty { s.placeholder(pkg.titleLayout.subtitle, fallback: pkg.coverSubtitle, lines: lines, size: 20, color: .muted) }
        return s
    }

    private func headline(_ text: String) -> SlideXML {
        var s = slide("Summary")
        s.shape(Rect(x: c.x, y: c.y, w: c.w, h: c.h / 2), paras: [para([Run(text: text, size: 24, color: .scheme("tx2"))])], autofit: true)
        return s
    }

    /// Up to eight tiles a slide; the result's headline goes above the first slide's tiles.
    private func metrics(_ title: String, _ headline: String?, _ items: [SolutionMetric]) -> [SlideXML] {
        let pages = stride(from: 0, to: max(items.count, 1), by: 8).map { Array(items[$0..<min($0 + 8, items.count)]) }
        return pages.enumerated().map { page, tiles in
            var s = slide(page == 0 ? title : title + " (cont.)")
            var top = c.y
            if page == 0, let headline {
                let h = TextFit.height(headline, width: c.w - inch(0.1), size: 20) + inch(0.2)
                s.shape(Rect(x: c.x, y: top, w: c.w, h: h), paras: [para([Run(text: headline, size: 20, color: .scheme("tx2"))])])
                top += h + inch(0.1)
            }
            guard !tiles.isEmpty else { return s }
            let cols = tiles.count <= 4 ? tiles.count : (tiles.count <= 6 ? 3 : 4)
            let rows = (tiles.count + cols - 1) / cols
            let w = (c.w - gap * (cols - 1)) / cols
            let h = min(inch(1.7), (c.y + c.h - top - gap * (rows - 1)) / rows)
            for (i, m) in tiles.enumerated() {
                let r = Rect(x: c.x + (i % cols) * (w + gap), y: top + (i / cols) * (h + gap), w: w, h: h)
                let valueSize: Double = m.value.count > 24 ? 16 : (m.value.count > 14 ? 20 : 28)
                let flagged = m.status == .blocker || m.status == .warning
                var paras = [para([Run(text: m.label, size: 12, color: .muted)]),
                             para([Run(text: m.value, size: valueSize, bold: true, color: flagged ? .status(m.status!) : .scheme("tx2"))], spaceBefore: 2)]
                if !m.detail.isEmpty { paras.append(para([Run(text: m.detail, size: 11, color: .muted)], spaceBefore: 2)) }
                s.shape(r, paras: paras, geom: "roundRect", fill: .tile, line: flagged ? .status(m.status!) : nil, inset: inch(0.14), autofit: true)
            }
            return s
        }
    }

    private func table(_ t: DeckTable) -> [SlideXML] {
        let cols = t.columns.count
        guard cols > 0 else { return [] }
        let size: Double = cols <= 3 ? 14 : cols == 4 ? 12 : cols <= 6 ? 11 : cols <= 8 ? 10 : 9
        let widths = columnWidths(t, total: c.w)
        // Cell text insets are 0.08" left/right and 0.04" top/bottom (see SlideXML.table), plus a little slack.
        func height(_ row: [DeckCell], _ size: Double) -> Int {
            let lines = row.enumerated().map { i, cell in TextFit.lines(cell.text, width: widths[min(i, cols - 1)] - 2 * inch(0.08), size: size) }.max() ?? 1
            return lines * TextFit.lineHeight(size) + 2 * inch(0.04) + inch(0.02)
        }
        let header = t.columns.map { DeckCell(text: $0) }
        let headerH = height(header, size)
        let subH = t.subtitle.isEmpty ? 0 : TextFit.height(t.subtitle, width: c.w, size: 14) + inch(0.12)
        let footH = t.footnote.isEmpty ? 0 : TextFit.lineHeight(10) + inch(0.12)
        let rows = t.rows.map { row in (0..<cols).map { i in i < row.count ? clip(row[i]) : DeckCell(text: "") } }

        // Pack rows onto pages.
        var pages: [[Int]] = [[]]
        var used = headerH
        for (i, row) in rows.enumerated() {
            let avail = c.h - (pages.count == 1 ? subH : 0) - footH
            let h = height(row, size)
            if !pages[pages.count - 1].isEmpty && used + h > avail { pages.append([]); used = headerH }
            pages[pages.count - 1].append(i); used += h
        }
        return pages.enumerated().map { p, indices in
            var s = slide(p == 0 ? t.title : t.title + " (cont.)")
            var top = c.y
            if p == 0 && subH > 0 {
                s.shape(Rect(x: c.x, y: top, w: c.w, h: subH), paras: [para([Run(text: t.subtitle, size: 14, color: .muted)])], inset: 0)
                top += subH
            }
            let pageRows = [header] + indices.map { rows[$0] }
            s.table(Rect(x: c.x, y: top, w: c.w, h: 0), widths: widths, heights: pageRows.map { height($0, size) },
                    rows: pageRows, header: 1, numeric: t.numeric, size: size)
            if p == pages.count - 1 && footH > 0 {
                s.shape(Rect(x: c.x, y: c.y + c.h - footH + inch(0.06), w: c.w, h: footH), paras: [para([Run(text: t.footnote, size: 10, color: .muted)])], inset: 0)
            }
            return s
        }
    }

    /// Widths from how much text each column holds, within bounds, plus any fixed widths.
    private func columnWidths(_ t: DeckTable, total: Int) -> [Int] {
        let cols = t.columns.count
        let fixedTotal = t.fixed.filter { $0.key < cols }.values.reduce(0) { $0 + inch($1) }
        let weights = (0..<cols).map { i -> Double in
            if t.fixed[i] != nil { return 0 }
            let lengths = t.rows.map { i < $0.count ? $0[i].text.count : 0 }.sorted()
            let p90 = lengths.isEmpty ? 0 : lengths[min(lengths.count - 1, lengths.count * 9 / 10)]
            // Room for the longest unbreakable word (host names, paths) so it doesn't split mid-word.
            let words = ([t.columns[i]] + t.rows.prefix(50).map { i < $0.count ? $0[i].text : "" }).flatMap { $0.split(separator: " ") }
            let longestWord = Double(words.map(\.count).max() ?? 4) * 1.4
            let cap: Double = t.numeric.contains(i) ? 16 : 48
            return min(cap, max(Double(p90), min(longestWord, 34), 5))
        }
        let sum = weights.reduce(0, +)
        return (0..<cols).map { i in
            if let f = t.fixed[i] { return inch(f) }
            return sum > 0 ? Int(Double(total - fixedTotal) * weights[i] / sum) : (total - fixedTotal) / cols
        }
    }

    private func clip(_ cell: DeckCell) -> DeckCell { clip(cell, 280) }

    private func clip(_ cell: DeckCell, _ limit: Int) -> DeckCell {
        guard cell.text.count > limit else { return cell }
        var c = cell
        c.text = String(cell.text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        return c
    }

    private func bars(_ title: String, _ subtitle: String, _ rows: [(label: String, value: String, fraction: Double)], _ more: Int) -> SlideXML {
        var s = slide(title)
        var top = c.y
        if !subtitle.isEmpty {
            let h = TextFit.height(subtitle, width: c.w, size: 14) + inch(0.12)
            s.shape(Rect(x: c.x, y: top, w: c.w, h: h), paras: [para([Run(text: subtitle, size: 14, color: .muted)])], inset: 0)
            top += h
        }
        let footH = more > 0 ? TextFit.lineHeight(10) + inch(0.12) : 0
        guard !rows.isEmpty else { return s }
        let rowH = min(inch(0.5), (c.y + c.h - top - footH) / rows.count)
        let labelW = c.w * 30 / 100, valueW = c.w * 18 / 100
        let barX = c.x + labelW + inch(0.15), barMax = c.w - labelW - valueW - inch(0.3)
        let size: Double = rowH < inch(0.36) ? 11 : 13
        for (i, row) in rows.enumerated() {
            let y = top + i * rowH
            s.shape(Rect(x: c.x, y: y, w: labelW, h: rowH), paras: [para([Run(text: row.label, size: size)], align: "r")], anchor: "ctr", inset: inch(0.04))
            let w = max(inch(0.04), Int(Double(barMax) * row.fraction))
            s.shape(Rect(x: barX, y: y + rowH * 18 / 100, w: w, h: rowH * 64 / 100), fill: .scheme("accent1"))
            s.shape(Rect(x: barX + w + inch(0.08), y: y, w: valueW + barMax - w, h: rowH), paras: [para([Run(text: row.value, size: size, bold: true)])],
                    anchor: "ctr", inset: inch(0.04))
        }
        if more > 0 {
            s.shape(Rect(x: c.x, y: c.y + c.h - footH + inch(0.06), w: c.w, h: footH),
                    paras: [para([Run(text: "\(more) more not shown. The CSV export has them all.", size: 10, color: .muted)])], inset: 0)
        }
        return s
    }

    private func bullets(_ title: String, _ lines: [String]) -> [SlideXML] {
        let size: Double = 16
        let width = c.w - inch(0.3) - inch(0.1)
        var pages: [[String]] = [[]]
        var used = 0
        for line in lines {
            let h = TextFit.height(line, width: width, size: size) + Int(6 * Double(emuPerPoint))
            if !pages[pages.count - 1].isEmpty && used + h > c.h - inch(0.1) { pages.append([]); used = 0 }
            pages[pages.count - 1].append(line); used += h
        }
        return pages.enumerated().map { p, lines in
            var s = slide(p == 0 ? title : title + " (cont.)")
            s.shape(c, paras: lines.map { para([Run(text: $0, size: size)], bullet: true, spaceBefore: 6) })
            return s
        }
    }

    /// One check: status, what was found and what to do, with the objects it affects.
    private func issue(_ check: SolutionCheck) -> SlideXML {
        var s = slide(check.title)
        let pillW = inch(1.3), pillH = inch(0.36)
        s.shape(Rect(x: c.x, y: c.y, w: pillW, h: pillH), paras: [para([Run(text: check.status.label, size: 12, bold: true, color: .rgb("FFFFFF"))], align: "ctr")],
                geom: "roundRect", fill: .status(check.status), anchor: "ctr", inset: 0)
        if !check.area.isEmpty {
            s.shape(Rect(x: c.x + pillW + inch(0.15), y: c.y, w: c.w - pillW - inch(0.15), h: pillH),
                    paras: [para([Run(text: check.area, size: 14, color: .muted)])], anchor: "ctr", inset: 0)
        }
        let top = c.y + pillH + inch(0.25)
        let hasObjects = !check.affected.isEmpty
        let leftW = hasObjects ? c.w * 55 / 100 - gap / 2 : c.w
        let summary = clip(DeckCell(text: check.summary), 400).text, remediation = clip(DeckCell(text: check.remediation), 700).text
        // Shrink the text until it fits, since PowerPoint only autofits once a slide is edited.
        let boxH = c.y + c.h - top
        func height(_ k: Double) -> Int {
            TextFit.height(summary, width: leftW, size: 20 * k)
                + (remediation.isEmpty ? 0 : TextFit.lineHeight(14 * k) + TextFit.height(remediation, width: leftW, size: 15 * k) + Int(22 * k * Double(emuPerPoint)))
        }
        let k = stride(from: 1.0, through: 0.6, by: -0.05).first { height($0) <= boxH } ?? 0.6
        var paras = [para([Run(text: summary, size: (20 * k).rounded(), color: .scheme("tx2"))])]
        if !remediation.isEmpty {
            paras.append(para([Run(text: "Recommendation", size: (14 * k).rounded(), bold: true, color: .muted)], spaceBefore: 18 * k))
            paras.append(para([Run(text: remediation, size: (15 * k).rounded())], spaceBefore: 4 * k))
        }
        s.shape(Rect(x: c.x, y: top, w: leftW, h: boxH), paras: paras, inset: 0, autofit: true)

        guard hasObjects else { return s }
        let x = c.x + leftW + gap, w = c.w - leftW - gap
        let labelH = inch(0.4)
        s.shape(Rect(x: x, y: top, w: w, h: labelH), paras: [para([Run(text: "Affected (\(Fmt.int(check.affected.count)))", size: 14, bold: true, color: .muted)])], inset: 0)
        let kinds = Set(check.affected.map(\.kind))
        let hasDetail = check.affected.contains { !$0.detail.isEmpty }
        var columns = ["Name"]
        if kinds.count > 1 { columns.append("Type") }
        if hasDetail { columns.append("Detail") }
        let size: Double = 11
        func cells(_ a: AffectedObject) -> [DeckCell] {
            var row = [DeckCell(text: a.name)]
            if kinds.count > 1 { row.append(DeckCell(text: a.kind.rawValue)) }
            if hasDetail { row.append(DeckCell(text: a.detail)) }
            return row.map(clip)
        }
        let widths = columnWidths(DeckTable(title: "", columns: columns, rows: check.affected.prefix(20).map(cells)), total: w)
        func height(_ row: [DeckCell]) -> Int {
            (row.enumerated().map { i, cell in TextFit.lines(cell.text, width: widths[i] - 2 * inch(0.08), size: size) }.max() ?? 1) * TextFit.lineHeight(size) + 2 * inch(0.04) + inch(0.02)
        }
        let avail = c.y + c.h - top - labelH
        var rows = [columns.map { DeckCell(text: $0) }]
        var used = height(rows[0])
        let moreH = height([DeckCell(text: "…")])
        for (i, a) in check.affected.enumerated() {
            let row = cells(a), h = height(row)
            let remaining = check.affected.count - i
            if used + h + (remaining > 1 ? moreH : 0) > avail {
                rows.append([DeckCell(text: "… and \(Fmt.int(remaining)) more", bold: true, span: columns.count)] + Array(repeating: DeckCell(text: ""), count: columns.count - 1))
                break
            }
            rows.append(row); used += h
        }
        s.table(Rect(x: x, y: top + labelH, w: w, h: 0), widths: widths, heights: rows.map(height), rows: rows, header: 1, numeric: [], size: size)
        return s
    }
}
