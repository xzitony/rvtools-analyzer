import Foundation

/// The deck's look when no template is chosen: 16:9, a neutral blue theme, a title slide and a title-only layout.
enum BuiltInTheme {
    private static let decl = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    private static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    private static let pml = "application/vnd.openxmlformats-officedocument.presentationml."
    private static let relsOpen = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
    private static let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"

    static let contentTypes = decl + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        + "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"\(pml)presentation.main+xml\"/>"
        + "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"\(pml)slideMaster+xml\"/>"
        + "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"\(pml)slideLayout+xml\"/>"
        + "<Override PartName=\"/ppt/slideLayouts/slideLayout2.xml\" ContentType=\"\(pml)slideLayout+xml\"/>"
        + "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        + "<Override PartName=\"/ppt/presProps.xml\" ContentType=\"\(pml)presProps+xml\"/>"
        + "<Override PartName=\"/ppt/viewProps.xml\" ContentType=\"\(pml)viewProps+xml\"/>"
        + "<Override PartName=\"/ppt/tableStyles.xml\" ContentType=\"\(pml)tableStyles+xml\"/>"
        + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        + "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        + "</Types>"

    static let rootRels = decl + relsOpen
        + "<Relationship Id=\"rId1\" Type=\"\(rel)officeDocument\" Target=\"ppt/presentation.xml\"/>"
        + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        + "<Relationship Id=\"rId3\" Type=\"\(rel)extended-properties\" Target=\"docProps/app.xml\"/>"
        + "</Relationships>"

    static let presentation = decl + "<p:presentation \(ns) saveSubsetFonts=\"1\">"
        + "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>"
        + "<p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"

    static let presentationRels = decl + relsOpen
        + "<Relationship Id=\"rId1\" Type=\"\(rel)slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
        + "<Relationship Id=\"rId2\" Type=\"\(rel)theme\" Target=\"theme/theme1.xml\"/>"
        + "<Relationship Id=\"rId3\" Type=\"\(rel)presProps\" Target=\"presProps.xml\"/>"
        + "<Relationship Id=\"rId4\" Type=\"\(rel)viewProps\" Target=\"viewProps.xml\"/>"
        + "<Relationship Id=\"rId5\" Type=\"\(rel)tableStyles\" Target=\"tableStyles.xml\"/>"
        + "</Relationships>"

    static let masterRels = decl + relsOpen
        + "<Relationship Id=\"rId1\" Type=\"\(rel)slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
        + "<Relationship Id=\"rId2\" Type=\"\(rel)slideLayout\" Target=\"../slideLayouts/slideLayout2.xml\"/>"
        + "<Relationship Id=\"rId3\" Type=\"\(rel)theme\" Target=\"../theme/theme1.xml\"/>"
        + "</Relationships>"

    static let layoutRels = decl + relsOpen
        + "<Relationship Id=\"rId1\" Type=\"\(rel)slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/>"
        + "</Relationships>"

    private static func ph(_ id: Int, _ name: String, _ ph: String, x: Double, y: Double, w: Double, h: Double, anchor: String, body: String = "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>") -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr>\(ph)</p:nvPr></p:nvSpPr>"
            + "<p:spPr><a:xfrm><a:off x=\"\(inch(x))\" y=\"\(inch(y))\"/><a:ext cx=\"\(inch(w))\" cy=\"\(inch(h))\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>"
            + "<p:txBody><a:bodyPr anchor=\"\(anchor)\"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(body)</p:txBody></p:sp>"
    }

    private static func bar(_ id: Int, x: Double, y: Double, w: Double, h: Double, color: String) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Accent \(id)\"/><p:cNvSpPr/><p:nvPr userDrawn=\"1\"/></p:nvSpPr>"
            + "<p:spPr><a:xfrm><a:off x=\"\(inch(x))\" y=\"\(inch(y))\"/><a:ext cx=\"\(inch(w))\" cy=\"\(inch(h))\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
            + "<a:solidFill><a:schemeClr val=\"\(color)\"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>"
            + "<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang=\"en-US\"/></a:p></p:txBody></p:sp>"
    }

    static let master = decl + "<p:sldMaster \(ns)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg><p:spTree>\(group)"
        + ph(2, "Title Placeholder 1", "<p:ph type=\"title\"/>", x: 0.5, y: 0.3, w: 12.33, h: 0.85, anchor: "b")
        + ph(3, "Text Placeholder 2", "<p:ph type=\"body\" idx=\"1\"/>", x: 0.5, y: 1.4, w: 12.33, h: 5.6, anchor: "t")
        + "</p:spTree></p:cSld>"
        + "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        + "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/><p:sldLayoutId id=\"2147483650\" r:id=\"rId2\"/></p:sldLayoutIdLst>"
        + "<p:txStyles><p:titleStyle><a:lvl1pPr algn=\"l\" defTabSz=\"914400\"><a:lnSpc><a:spcPct val=\"90000\"/></a:lnSpc><a:spcBef><a:spcPct val=\"0\"/></a:spcBef><a:buNone/>"
        + "<a:defRPr sz=\"2800\" b=\"1\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx2\"/></a:solidFill><a:latin typeface=\"+mj-lt\"/><a:ea typeface=\"+mj-ea\"/><a:cs typeface=\"+mj-cs\"/></a:defRPr></a:lvl1pPr></p:titleStyle>"
        + "<p:bodyStyle><a:lvl1pPr marL=\"0\" indent=\"0\" algn=\"l\" defTabSz=\"914400\"><a:spcBef><a:spcPts val=\"600\"/></a:spcBef><a:buNone/>"
        + "<a:defRPr sz=\"1800\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/><a:ea typeface=\"+mn-ea\"/><a:cs typeface=\"+mn-cs\"/></a:defRPr></a:lvl1pPr></p:bodyStyle>"
        + "<p:otherStyle><a:lvl1pPr marL=\"0\" algn=\"l\" defTabSz=\"914400\"><a:defRPr sz=\"1800\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/><a:ea typeface=\"+mn-ea\"/><a:cs typeface=\"+mn-cs\"/></a:defRPr></a:lvl1pPr></p:otherStyle>"
        + "</p:txStyles></p:sldMaster>"

    static let coverLayout = decl + "<p:sldLayout \(ns) type=\"title\" preserve=\"1\"><p:cSld name=\"Title Slide\"><p:spTree>\(group)"
        + bar(4, x: 0, y: 0, w: 0.35, h: 7.5, color: "accent1")
        + ph(2, "Title 1", "<p:ph type=\"ctrTitle\"/>", x: 1.0, y: 2.0, w: 11.3, h: 1.7, anchor: "b",
             body: "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>")
            .replacingOccurrences(of: "<a:lstStyle/>", with: "<a:lstStyle><a:lvl1pPr><a:defRPr sz=\"4000\"/></a:lvl1pPr></a:lstStyle>")
        + ph(3, "Subtitle 2", "<p:ph type=\"subTitle\" idx=\"1\"/>", x: 1.0, y: 3.9, w: 11.3, h: 1.6, anchor: "t")
            .replacingOccurrences(of: "<a:lstStyle/>", with: "<a:lstStyle><a:lvl1pPr marL=\"0\" indent=\"0\"><a:buNone/><a:defRPr sz=\"2000\"><a:solidFill><a:schemeClr val=\"tx1\"><a:lumMod val=\"65000\"/><a:lumOff val=\"35000\"/></a:schemeClr></a:solidFill></a:defRPr></a:lvl1pPr></a:lstStyle>")
        + bar(5, x: 1.0, y: 3.78, w: 1.6, h: 0.05, color: "accent2")
        + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"

    static let contentLayout = decl + "<p:sldLayout \(ns) type=\"titleOnly\" preserve=\"1\"><p:cSld name=\"Title Only\"><p:spTree>\(group)"
        + ph(2, "Title 1", "<p:ph type=\"title\"/>", x: 0.5, y: 0.3, w: 12.33, h: 0.85, anchor: "b")
        + bar(3, x: 0.5, y: 1.2, w: 12.33, h: 0.03, color: "accent1")
        + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"

    static let theme = decl + "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"RVTools Analyzer\"><a:themeElements>"
        + "<a:clrScheme name=\"RVTools Analyzer\">"
        + "<a:dk1><a:srgbClr val=\"1F2328\"/></a:dk1><a:lt1><a:srgbClr val=\"FFFFFF\"/></a:lt1><a:dk2><a:srgbClr val=\"1F3A5F\"/></a:dk2><a:lt2><a:srgbClr val=\"EEF1F5\"/></a:lt2>"
        + "<a:accent1><a:srgbClr val=\"2F6DB5\"/></a:accent1><a:accent2><a:srgbClr val=\"E08E00\"/></a:accent2><a:accent3><a:srgbClr val=\"2E7D32\"/></a:accent3>"
        + "<a:accent4><a:srgbClr val=\"C62828\"/></a:accent4><a:accent5><a:srgbClr val=\"6A4C93\"/></a:accent5><a:accent6><a:srgbClr val=\"00897B\"/></a:accent6>"
        + "<a:hlink><a:srgbClr val=\"2F6DB5\"/></a:hlink><a:folHlink><a:srgbClr val=\"6A4C93\"/></a:folHlink></a:clrScheme>"
        + "<a:fontScheme name=\"RVTools Analyzer\"><a:majorFont><a:latin typeface=\"Aptos Display\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>"
        + "<a:minorFont><a:latin typeface=\"Aptos\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>"
        + "<a:fmtScheme name=\"RVTools Analyzer\"><a:fillStyleLst>" + String(repeating: "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>", count: 3) + "</a:fillStyleLst>"
        + "<a:lnStyleLst>" + [6350, 12700, 19050].map { "<a:ln w=\"\($0)\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>" }.joined() + "</a:lnStyleLst>"
        + "<a:effectStyleLst>" + String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3) + "</a:effectStyleLst>"
        + "<a:bgFillStyleLst>" + String(repeating: "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>", count: 3) + "</a:bgFillStyleLst>"
        + "</a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"
}
