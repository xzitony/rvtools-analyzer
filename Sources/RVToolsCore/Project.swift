import Foundation

/// A saved analysis session, stored as a package directory (`Name.rvaproj`):
///
///     Name.rvaproj/
///       project.json      settings: scope, thresholds, per-solution VM selections, assumptions, notes
///       sources/…         copies of the RVTools exports (so the project survives the originals moving)
///       prices/…          cloud price snapshots used by the estimates (reproducible later)
///
/// Being plain files, projects can live anywhere — local disk, iCloud Drive or a OneDrive / SharePoint folder.
public struct ProjectFile: Codable, Sendable {
    public static let fileExtension = "rvaproj"
    public static let currentFormat = 1

    public var formatVersion = ProjectFile.currentFormat
    public var name: String
    public var notes = ""
    public var created: Date
    public var modified: Date
    /// Source files, relative to the package.
    public var sources: [String] = []
    /// Where the sources were originally loaded from (informational).
    public var originalSources: [String] = []
    public var scopeID = "all"
    public var thresholds = Thresholds()
    public var solutionSelections: [String: [String]] = [:]
    public var solutionParams: [String: ParamValues] = [:]
    public var solutionTabs: [String: Int] = [:]
    public var page: String?

    public init(name: String) {
        self.name = name
        created = Date()
        modified = created
    }

    public static func isProject(_ url: URL) -> Bool { url.pathExtension.lowercased() == fileExtension }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Reads a project; returns it with the absolute URLs of its embedded sources and its price snapshots.
    public static func read(_ url: URL) throws -> (project: ProjectFile, sources: [URL], prices: [RegionPrices]) {
        let data: Data
        do { data = try Data(contentsOf: url.appendingPathComponent("project.json")) } catch {
            throw RVToolsError.unreadable("\(url.lastPathComponent) is not a readable RVTools Analyzer project")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(ProjectFile.self, from: data)
        guard project.formatVersion <= currentFormat else {
            throw RVToolsError.unreadable("\(url.lastPathComponent) was saved by a newer version of RVTools Analyzer")
        }
        let sources = project.sources.map { url.appendingPathComponent($0) }
        if let missing = sources.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            throw RVToolsError.unreadable("The project is missing its source file \(missing.lastPathComponent)")
        }
        let priceFiles = (try? FileManager.default.contentsOfDirectory(at: url.appendingPathComponent("prices"), includingPropertiesForKeys: nil)) ?? []
        let prices = priceFiles.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(RegionPrices.self, from: Data(contentsOf: $0)) }
        return (project, sources, prices)
    }

    /// Writes the project. With `copySources` the whole package is (re)built with copies of those files and swapped
    /// into place atomically; without it only project.json and the price snapshots are rewritten (autosave).
    public static func write(_ project: ProjectFile, to url: URL, copySources: [URL]?, prices: [RegionPrices]) throws -> ProjectFile {
        let fm = FileManager.default
        var p = project
        p.modified = Date()
        guard let sources = copySources else {
            try writeContents(p, prices: prices, into: url)
            return p
        }
        let parent = url.deletingLastPathComponent()
        let staging = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true)) ?? fm.temporaryDirectory
        let tmp = staging.appendingPathComponent(UUID().uuidString + "." + fileExtension, isDirectory: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("sources"), withIntermediateDirectories: true)
        var relative: [String] = []
        for src in sources {
            // CSV exports keep their folder so each export stays grouped.
            let folder = src.pathExtension.lowercased() == "csv" ? src.deletingLastPathComponent().lastPathComponent + "/" : ""
            var rel = "sources/" + folder + src.lastPathComponent
            var n = 2
            while relative.contains(rel) { rel = "sources/" + folder + "\(n)-" + src.lastPathComponent; n += 1 }
            let dest = tmp.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dest)
            relative.append(rel)
        }
        p.sources = relative
        if p.originalSources.isEmpty { p.originalSources = sources.map(\.path) }
        try writeContents(p, prices: prices, into: tmp)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        try? fm.removeItem(at: staging)
        return p
    }

    private static func writeContents(_ p: ProjectFile, prices: [RegionPrices], into dir: URL) throws {
        try encoder.encode(p).write(to: dir.appendingPathComponent("project.json"), options: .atomic)
        let pricesDir = dir.appendingPathComponent("prices")
        try? FileManager.default.removeItem(at: pricesDir)
        guard !prices.isEmpty else { return }
        try FileManager.default.createDirectory(at: pricesDir, withIntermediateDirectories: true)
        for rp in prices {
            try JSONEncoder().encode(rp).write(to: pricesDir.appendingPathComponent("\(rp.provider.rawValue)-\(rp.region).json"))
        }
    }
}
