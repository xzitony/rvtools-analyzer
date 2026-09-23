import Foundation

struct Placeholder {
    var type: String?
    var idx: String?
    var rect: Rect?
}

struct DeckLayout {
    var path: String
    var title: Placeholder?
    var subtitle: Placeholder?
}

private let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main"
private let nsR = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
private let nsP = "http://schemas.openxmlformats.org/presentationml/2006/main"
private let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
private let xmlDecl = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
private let presentationML = "application/vnd.openxmlformats-officedocument.presentationml."

/// The package parts of a deck: a template's (minus its slides) or the built-in look, plus where content goes.
struct DeckPackage {
    var parts: [String: Data] = [:]
    var order: [String] = []
    var width = 12_192_000
    var height = 6_858_000
    var titleLayout = DeckLayout(path: "")
    var contentLayout = DeckLayout(path: "")
    /// Where a content slide's title and body go.
    var titleRect = Rect(x: 0, y: 0, w: 0, h: 0)
    var content = Rect(x: 0, y: 0, w: 0, h: 0)
    /// Where a title slide's title and subtitle go when its layout has no placeholders for them.
    var coverTitle = Rect(x: 0, y: 0, w: 0, h: 0)
    var coverSubtitle = Rect(x: 0, y: 0, w: 0, h: 0)
    /// The slide master the deck's layouts belong to.
    var masterPath = ""
    /// The master's title font size in points, to shrink titles that won't fit.
    var titleSize = 44.0

    // MARK: Loading

    init() {}

    init(template url: URL) throws {
        let zip = try ZipArchive(url: url)
        guard zip.contains("ppt/presentation.xml") else {
            throw RVToolsError.notRVTools("\(url.lastPathComponent) is not a PowerPoint presentation or template")
        }
        for name in zip.names where !name.hasSuffix("/") {
            // The template's own slides (and what hangs off them) are dropped; the deck brings its own.
            if ["ppt/slides/", "ppt/notesSlides/", "ppt/comments/"].contains(where: { name.hasPrefix($0) }) { continue }
            set(name, try zip.read(name))
        }
        var pres = text("ppt/presentation.xml")
        pres = strip(pres, #"<p:sldIdLst\s*/>|<p:sldIdLst>.*?</p:sldIdLst>"#)
        pres = strip(pres, #"<p:custShowLst>.*?</p:custShowLst>"#)
        pres = strip(pres, #"<p:ext uri="\{521415D9-36F7-43E2-AB2F-B90AF26B5E84\}">.*?</p:ext>"#)  // slide sections
        set("ppt/presentation.xml", pres)
        if parts["ppt/viewProps.xml"] != nil { set("ppt/viewProps.xml", strip(text("ppt/viewProps.xml"), #"<p:sldLst>.*?</p:sldLst>"#)) }
        set("ppt/_rels/presentation.xml.rels", strip(text("ppt/_rels/presentation.xml.rels"), #"<Relationship\b[^>]*/relationships/slide"[^>]*/>"#))
        var types = strip(text("[Content_Types].xml"), #"<Override\b[^>]*PartName="/ppt/(slides|notesSlides|comments)/[^"]*"[^>]*/>"#)
        for kind in ["template.main+xml", "slideshow.main+xml", "macroEnabled.main+xml", "templateMacroEnabled.main+xml", "slideshowMacroEnabled.main+xml"] {
            types = types.replacingOccurrences(of: presentationML + kind, with: presentationML + "presentation.main+xml")
        }
        set("[Content_Types].xml", types)
        if let size = firstMatch(pres, #"<p:sldSz\b[^>]*>"#) {
            width = Int(attr(size, "cx") ?? "") ?? width
            height = Int(attr(size, "cy") ?? "") ?? height
        }
        try locateLayouts()
    }

    static func builtIn() -> DeckPackage {
        var p = DeckPackage()
        p.set("[Content_Types].xml", BuiltInTheme.contentTypes)
        p.set("_rels/.rels", BuiltInTheme.rootRels)
        p.set("docProps/app.xml", "")
        p.set("docProps/core.xml", "")
        p.set("ppt/presentation.xml", BuiltInTheme.presentation)
        p.set("ppt/_rels/presentation.xml.rels", BuiltInTheme.presentationRels)
        p.set("ppt/presProps.xml", xmlDecl + "<p:presentationPr xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\"/>")
        p.set("ppt/viewProps.xml", xmlDecl + "<p:viewPr xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\"/>")
        p.set("ppt/tableStyles.xml", xmlDecl + "<a:tblStyleLst xmlns:a=\"\(nsA)\" def=\"{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}\"/>")
        p.set("ppt/theme/theme1.xml", BuiltInTheme.theme)
        p.set("ppt/slideMasters/slideMaster1.xml", BuiltInTheme.master)
        p.set("ppt/slideMasters/_rels/slideMaster1.xml.rels", BuiltInTheme.masterRels)
        p.set("ppt/slideLayouts/slideLayout1.xml", BuiltInTheme.coverLayout)
        p.set("ppt/slideLayouts/_rels/slideLayout1.xml.rels", BuiltInTheme.layoutRels)
        p.set("ppt/slideLayouts/slideLayout2.xml", BuiltInTheme.contentLayout)
        p.set("ppt/slideLayouts/_rels/slideLayout2.xml.rels", BuiltInTheme.layoutRels)
        // The built-in parts are known-good; failing here would be a programming error.
        try! p.locateLayouts()
        return p
    }

    /// Picks the title-slide and title-only layouts of the first master and works out the content area.
    private mutating func locateLayouts() throws {
        let pres = text("ppt/presentation.xml")
        let presRels = rels("ppt/presentation.xml")
        let firstMasterID = firstMatch(pres, #"<p:sldMasterId\b[^>]*>"#).flatMap { attr($0, "r:id") }
        guard let master = presRels.first(where: { $0.id == firstMasterID })?.target ?? presRels.first(where: { $0.type == "slideMaster" })?.target,
              let masterXML = parts[master] else {
            throw RVToolsError.corrupt("The template has no slide master")
        }
        masterPath = master
        let masterRels = rels(master)
        let layoutIDs = matches(String(decoding: masterXML, as: UTF8.self), #"<p:sldLayoutId\b[^>]*>"#).compactMap { attr($0, "r:id") }
        let layoutPaths = layoutIDs.compactMap { id in masterRels.first { $0.id == id }?.target }.filter { parts[$0] != nil }
        guard !layoutPaths.isEmpty else { throw RVToolsError.corrupt("The template's slide master has no layouts") }

        let masterPHs = Self.placeholders(masterXML)
        let masterText = String(decoding: masterXML, as: UTF8.self)
        if let style = masterText.range(of: "<p:titleStyle>").map({ String(masterText[$0.upperBound...].prefix(2000)) }),
           let size = firstMatch(style, #"<a:defRPr\b[^>]*>"#).flatMap({ attr($0, "sz") }).flatMap(Double.init) {
            titleSize = size / 100
        }
        func inherit(_ ph: Placeholder?, _ types: [String]) -> Placeholder? {
            guard var ph else { return nil }
            if ph.rect == nil { ph.rect = masterPHs.first { types.contains($0.type ?? "body") }?.rect }
            return ph
        }
        let infos = layoutPaths.map { path -> (path: String, type: String, name: String, phs: [Placeholder]) in
            let xml = parts[path]!
            let s = String(decoding: xml, as: UTF8.self)
            return (path, firstMatch(s, #"<p:sldLayout\b[^>]*>"#).flatMap { attr($0, "type") } ?? "",
                    firstMatch(s, #"<p:cSld\b[^>]*>"#).flatMap { attr($0, "name") }?.lowercased() ?? "", Self.placeholders(xml))
        }
        let cover = infos.first { $0.type == "title" } ?? infos.first { $0.name.contains("title slide") } ?? infos[0]
        let body = infos.first { $0.type == "titleOnly" } ?? infos.first { $0.name.contains("title only") }
            ?? infos.first { $0.type == "obj" } ?? infos.first { $0.phs.contains { $0.type == "title" } } ?? infos[0]

        titleLayout = DeckLayout(path: cover.path,
                                 title: inherit(cover.phs.first { $0.type == "ctrTitle" } ?? cover.phs.first { $0.type == "title" }, ["title", "ctrTitle"]),
                                 subtitle: inherit(cover.phs.first { $0.type == "subTitle" } ?? cover.phs.first { $0.type == nil || $0.type == "body" }, ["body", "subTitle"]))
        contentLayout = DeckLayout(path: body.path, title: inherit(body.phs.first { $0.type == "title" }, ["title"]))

        let margin = width / 24
        titleRect = contentLayout.title?.rect ?? Rect(x: margin, y: inch(0.3), w: width - 2 * margin, h: inch(0.9))
        var bottom = height - inch(0.35)
        for ph in masterPHs + body.phs where ["dt", "ftr", "sldNum"].contains(ph.type ?? "") {
            if let r = ph.rect, r.y > height / 2 { bottom = min(bottom, r.y - inch(0.08)) }
        }
        // Logos and footer text drawn on the master or layout; full-width or tall artwork is background, not a footer.
        for r in Self.artwork(masterXML) + Self.artwork(parts[body.path]!)
        where r.y > height * 3 / 4 && r.h < height * 3 / 10 && r.w < width * 8 / 10 {
            bottom = min(bottom, r.y - inch(0.08))
        }
        let top = titleRect.y + titleRect.h + inch(0.15)
        content = Rect(x: titleRect.x, y: top, w: titleRect.w, h: bottom - top)
        if content.h < inch(2) || content.w < inch(4) {
            content = Rect(x: margin, y: inch(1.35), w: width - 2 * margin, h: height - inch(1.8))
        }
        coverTitle = Rect(x: margin * 2, y: height * 30 / 100, w: width - margin * 4, h: height * 22 / 100)
        coverSubtitle = Rect(x: margin * 2, y: height * 54 / 100, w: width - margin * 4, h: height * 20 / 100)
    }

    // MARK: Writing

    mutating func write(_ slides: [(xml: String, layout: String)], title: String) throws -> Data {
        var ids = "", presRels = "", overrides = ""
        for (i, slide) in slides.enumerated() {
            let n = i + 1
            let path = "ppt/slides/slide\(n).xml"
            set(path, slide.xml)
            set("ppt/slides/_rels/slide\(n).xml.rels", xmlDecl + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"\(relBase)slideLayout\" Target=\"../\(slide.layout.dropFirst(4))\"/></Relationships>")
            ids += "<p:sldId id=\"\(255 + n)\" r:id=\"rIdRva\(n)\"/>"
            presRels += "<Relationship Id=\"rIdRva\(n)\" Type=\"\(relBase)slide\" Target=\"slides/slide\(n).xml\"/>"
            overrides += "<Override PartName=\"/\(path)\" ContentType=\"\(presentationML)slide+xml\"/>"
        }
        var pres = text("ppt/presentation.xml")
        let anchors = ["</p:sldMasterIdLst>", "</p:notesMasterIdLst>", "</p:handoutMasterIdLst>"].compactMap { pres.range(of: $0)?.upperBound }
        guard let at = anchors.max() else { throw RVToolsError.corrupt("The template's presentation part has no slide master list") }
        pres.insert(contentsOf: "<p:sldIdLst>\(ids)</p:sldIdLst>", at: at)
        set("ppt/presentation.xml", pres)
        set("ppt/_rels/presentation.xml.rels", text("ppt/_rels/presentation.xml.rels").replacingOccurrences(of: "</Relationships>", with: presRels + "</Relationships>"))
        set("[Content_Types].xml", text("[Content_Types].xml").replacingOccurrences(of: "</Types>", with: overrides + "</Types>"))

        if parts["docProps/app.xml"] != nil {
            set("docProps/app.xml", xmlDecl + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\">"
                + "<Application>RVTools Analyzer</Application><Slides>\(slides.count)</Slides></Properties>")
        }
        if parts["docProps/core.xml"] != nil {
            let now = ISO8601DateFormatter().string(from: Date())
            set("docProps/core.xml", xmlDecl + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
                + "<dc:title>\(xmlEscape(title))</dc:title><dc:creator>RVTools Analyzer</dc:creator>"
                + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:modified></cp:coreProperties>")
        }

        prune()
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", parts["[Content_Types].xml"]!)
        for name in order where name != "[Content_Types].xml" { zip.add(name, parts[name]!) }
        return zip.finish()
    }

    /// Unlinks every other slide master and every layout the deck doesn't use; `prune()` then drops their parts.
    mutating func trimLayouts() {
        let keep: Set<String> = [titleLayout.path, contentLayout.path]
        func unlink(_ part: String, listTag: String, keepTarget: (String) -> Bool) {
            let dropIDs = Set(rels(part).filter { $0.type == (listTag == "p:sldMasterId" ? "slideMaster" : "slideLayout") && !keepTarget($0.target) }.map(\.id))
            guard !dropIDs.isEmpty else { return }
            var xml = text(part), relsXML = text(Self.relsPath(part))
            for tag in matches(xml, "<\(listTag)\\b[^>]*>") where attr(tag, "r:id").map(dropIDs.contains) == true {
                xml = xml.replacingOccurrences(of: tag, with: "")
            }
            for tag in matches(relsXML, #"<Relationship\b[^>]*>"#) where attr(tag, "Id").map(dropIDs.contains) == true {
                relsXML = relsXML.replacingOccurrences(of: tag, with: "")
            }
            set(part, xml)
            set(Self.relsPath(part), relsXML)
        }
        unlink("ppt/presentation.xml", listTag: "p:sldMasterId") { $0 == masterPath }
        unlink(masterPath, listTag: "p:sldLayoutId") { keep.contains($0) }
    }

    /// Drops parts nothing links to any more, such as the media, charts and notes of a template's slides, and their content types.
    private mutating func prune() {
        var reachable: Set<String> = ["[Content_Types].xml"]
        var queue = rels(nil).map(\.target)
        while let part = queue.popLast() {
            guard parts[part] != nil, reachable.insert(part).inserted else { continue }
            let relsPath = Self.relsPath(part)
            if parts[relsPath] != nil { reachable.insert(relsPath) }
            queue += rels(part).map(\.target)
        }
        reachable.insert("_rels/.rels")
        let dropped = order.filter { !reachable.contains($0) }
        guard !dropped.isEmpty else { return }
        for name in dropped { parts[name] = nil }
        order.removeAll { !reachable.contains($0) }
        var types = text("[Content_Types].xml")
        for name in dropped {
            types = strip(types, #"<Override\b[^>]*PartName="/"# + NSRegularExpression.escapedPattern(for: name) + #""[^>]*/>"#)
        }
        set("[Content_Types].xml", types)
    }

    private static func relsPath(_ part: String) -> String {
        let dir = (part as NSString).deletingLastPathComponent
        return (dir.isEmpty ? "" : dir + "/") + "_rels/" + (part as NSString).lastPathComponent + ".rels"
    }

    // MARK: Helpers

    private mutating func set(_ name: String, _ data: Data) {
        if parts[name] == nil { order.append(name) }
        parts[name] = data
    }
    private mutating func set(_ name: String, _ text: String) { set(name, Data(text.utf8)) }
    private func text(_ name: String) -> String { parts[name].map { String(decoding: $0, as: UTF8.self) } ?? "" }

    /// A part's relationships, with targets resolved to package paths and types reduced to their last component.
    /// `nil` = the package's own relationships (`_rels/.rels`).
    private func rels(_ part: String?) -> [(id: String, type: String, target: String)] {
        let dir = part.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        return matches(text(part.map(Self.relsPath) ?? "_rels/.rels"), #"<Relationship\b[^>]*>"#).compactMap { tag in
            guard let id = attr(tag, "Id"), let type = attr(tag, "Type"), let target = attr(tag, "Target"), attr(tag, "TargetMode") != "External" else { return nil }
            let resolved = target.hasPrefix("/") ? String(target.dropFirst()) : normalize(dir.isEmpty ? target : dir + "/" + target)
            return (id, String(type.split(separator: "/").last ?? ""), resolved)
        }
    }

    /// Positions of the top-level shapes, pictures and groups that aren't placeholders.
    static func artwork(_ xml: Data) -> [Rect] {
        guard let doc = try? XMLDocument(data: xml, options: []),
              let nodes = try? doc.nodes(forXPath: "//*[local-name()='cSld']/*[local-name()='spTree']/*[local-name()='sp' or local-name()='pic' or local-name()='grpSp' or local-name()='graphicFrame']")
        else { return [] }
        return nodes.compactMap { node -> Rect? in
            if let ph = try? node.nodes(forXPath: ".//*[local-name()='ph']"), !ph.isEmpty { return nil }
            guard let off = (try? node.nodes(forXPath: "./*/*[local-name()='xfrm']/*[local-name()='off'] | ./*[local-name()='xfrm']/*[local-name()='off']"))?.first as? XMLElement,
                  let ext = (try? node.nodes(forXPath: "./*/*[local-name()='xfrm']/*[local-name()='ext'] | ./*[local-name()='xfrm']/*[local-name()='ext']"))?.first as? XMLElement,
                  let x = off.attribute(forName: "x")?.stringValue.flatMap(Int.init), let y = off.attribute(forName: "y")?.stringValue.flatMap(Int.init),
                  let w = ext.attribute(forName: "cx")?.stringValue.flatMap(Int.init), let h = ext.attribute(forName: "cy")?.stringValue.flatMap(Int.init)
            else { return nil }
            return Rect(x: x, y: y, w: w, h: h)
        }
    }

    static func placeholders(_ xml: Data) -> [Placeholder] {
        guard let doc = try? XMLDocument(data: xml, options: []),
              let nodes = try? doc.nodes(forXPath: "//*[local-name()='sp']/*[local-name()='nvSpPr']/*[local-name()='nvPr']/*[local-name()='ph']") else { return [] }
        return nodes.compactMap { node -> Placeholder? in
            guard let ph = node as? XMLElement else { return nil }
            var p = Placeholder(type: ph.attribute(forName: "type")?.stringValue, idx: ph.attribute(forName: "idx")?.stringValue)
            if let sp = ph.parent?.parent?.parent,
               let off = (try? sp.nodes(forXPath: "./*[local-name()='spPr']/*[local-name()='xfrm']/*[local-name()='off']"))?.first as? XMLElement,
               let ext = (try? sp.nodes(forXPath: "./*[local-name()='spPr']/*[local-name()='xfrm']/*[local-name()='ext']"))?.first as? XMLElement,
               let x = off.attribute(forName: "x")?.stringValue.flatMap(Int.init), let y = off.attribute(forName: "y")?.stringValue.flatMap(Int.init),
               let w = ext.attribute(forName: "cx")?.stringValue.flatMap(Int.init), let h = ext.attribute(forName: "cy")?.stringValue.flatMap(Int.init) {
                p.rect = Rect(x: x, y: y, w: w, h: h)
            }
            return p
        }
    }
}

/// Resolves "." and ".." in a package path.
private func normalize(_ path: String) -> String {
    var out: [Substring] = []
    for c in path.split(separator: "/") {
        if c == "." { continue }
        if c == ".." { _ = out.popLast() } else { out.append(c) }
    }
    return out.joined(separator: "/")
}

private func strip(_ s: String, _ pattern: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return s }
    return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
}

private func matches(_ s: String, _ pattern: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
}

private func firstMatch(_ s: String, _ pattern: String) -> String? { matches(s, pattern).first }

/// An attribute's value within a single start tag.
private func attr(_ tag: String, _ name: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    guard let re = try? NSRegularExpression(pattern: "\\s\(escaped)=\"([^\"]*)\""),
          let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
          let r = Range(m.range(at: 1), in: tag) else { return nil }
    return String(tag[r]).replacingOccurrences(of: "&amp;", with: "&")
}
