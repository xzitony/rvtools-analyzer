import Foundation

/// `manifest.json` of a custom solution pack (`Name.rvasolution/`).
public struct SolutionManifest: Codable, Sendable {
    public var apiVersion: Int
    public var id: String
    public var title: String
    public var symbol: String?
    public var summary: String?
    public var version: String?
    public var author: String?
    /// Script file inside the pack; "solution.js" when omitted.
    public var script: String?
    /// "vms" (default), "poweredOn", "all" (includes templates) or "none".
    public var defaultSelection: String?
    public var timeoutSeconds: Double?
    /// Show everything the script logs under the results.
    public var debug: Bool?
    public var pricing: Pricing?
    public var parameters: [Parameter]?

    public struct Pricing: Codable, Sendable {
        /// "azure", "aws" and/or custom price list ids the script reads.
        public var providers: [String]
        /// Show Download Prices for built-in providers (default true).
        public var allowDownload: Bool?
    }

    public struct Parameter: Codable, Sendable {
        public var id: String
        /// number, choice, toggle, multi or regions
        public var type: String
        public var label: String
        public var group: String?
        public var help: String?
        public var `default`: JSONValue?
        public var min: Double?
        public var max: Double?
        public var step: Double?
        public var unit: String?
        public var options: [String]?
        /// regions: the price provider whose regions are offered.
        public var provider: String?
    }

    public static let selectionModes = ["vms", "poweredOn", "all", "none"]
    public static let parameterTypes = ["number", "choice", "toggle", "multi", "regions"]

    /// Problems that stop the pack from loading (empty when valid).
    public var problems: [String] {
        var p: [String] = []
        if apiVersion > SolutionAPI.version {
            p.append("needs apiVersion \(apiVersion), but this version of RVTools Analyzer supports \(SolutionAPI.version) — update the app")
        } else if apiVersion < 1 {
            p.append("apiVersion must be \(SolutionAPI.version)")
        }
        if !ExtensionID.isValid(id) { p.append("id “\(id)” must be up to 64 lowercase letters, digits, dots, dashes or underscores") }
        if title.trimmingCharacters(in: .whitespaces).isEmpty { p.append("title is empty") }
        if let s = defaultSelection, !Self.selectionModes.contains(s) { p.append("defaultSelection must be one of \(Self.selectionModes.joined(separator: ", "))") }
        if let t = timeoutSeconds, !(1...300).contains(t) { p.append("timeoutSeconds must be between 1 and 300") }
        let providers = pricing?.providers ?? []
        for provider in providers where !ExtensionID.isValid(provider) { p.append("pricing provider “\(provider)” isn't a valid id") }
        var ids = Set<String>()
        for (i, prm) in (parameters ?? []).enumerated() {
            let name = prm.id.isEmpty ? "parameters[\(i)]" : "parameter “\(prm.id)”"
            if prm.id.isEmpty || !ids.insert(prm.id).inserted { p.append("\(name) has a missing or duplicate id") }
            if prm.label.isEmpty { p.append("\(name) needs a label") }
            let options = prm.options ?? []
            switch prm.type {
            case "number":
                if let lo = prm.min, let hi = prm.max, lo > hi { p.append("\(name): min is larger than max") }
                if let d = prm.default, d.number == nil { p.append("\(name): default must be a number") }
            case "choice":
                if options.isEmpty { p.append("\(name) needs options") }
                if let d = prm.default, ScriptedSolution.index(d, options) == nil { p.append("\(name): default must be an option or its index") }
            case "toggle":
                if let d = prm.default, d.bool == nil { p.append("\(name): default must be true or false") }
            case "multi":
                if options.isEmpty { p.append("\(name) needs options") }
                if let d = prm.default, d.array == nil { p.append("\(name): default must be a list") }
            case "regions":
                if let pv = prm.provider {
                    if !providers.contains(pv) { p.append("\(name): add “\(pv)” to pricing.providers") }
                } else {
                    p.append("\(name) needs a provider")
                }
                if let d = prm.default, d.array == nil { p.append("\(name): default must be a list of region codes") }
            default:
                p.append("\(name): type must be one of \(Self.parameterTypes.joined(separator: ", "))")
            }
        }
        return p
    }
}

/// Finds, validates, installs and removes custom solution packs.
///
/// A pack is a folder containing `manifest.json` and a script. Packs are loaded from `extraDirectories` (command
/// line), the colon-separated `RVTOOLS_SOLUTIONS_PATH` and `~/Library/Application Support/RVTools Analyzer/Solutions/`,
/// in that order. A search directory may itself be a pack (handy while developing one).
public final class SolutionLibrary: @unchecked Sendable {
    public static let shared = SolutionLibrary()
    public static let packExtension = "rvasolution"

    /// `~/Library/Application Support/<folder>`: "RVTools Analyzer", the build's `RVTASupportFolder` (Dev builds use
    /// their own folder, so work in progress never sees your real solutions), or `RVTA_SUPPORT_FOLDER` from the environment.
    /// The Solutions and Price Lists folders inside may be symlinks to a synced folder.
    public static var supportDirectory: URL {
        let folder = ProcessInfo.processInfo.environment["RVTA_SUPPORT_FOLDER"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "RVTASupportFolder") as? String) ?? "RVTools Analyzer"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(folder, isDirectory: true)
    }
    public static var directory: URL { supportDirectory.appendingPathComponent("Solutions", isDirectory: true) }

    public struct Issue: Sendable, Hashable, Identifiable {
        public var id: String { path + "|" + message }
        public let path: String
        public let message: String
    }

    private let lock = NSLock()
    private var _solutions: [ScriptedSolution] = []
    private var _issues: [Issue] = []
    private var _disabled: Set<String> = []
    private var _extraDirectories: [URL] = []
    private var _version = 0

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Every valid pack, enabled or not.
    public var solutions: [ScriptedSolution] { locked { _solutions } }
    public var enabled: [ScriptedSolution] { locked { _solutions.filter { !_disabled.contains($0.id) } } }
    public var issues: [Issue] { locked { _issues } }
    public var version: Int { locked { _version } }

    public var disabled: Set<String> {
        get { locked { _disabled } }
        set { locked { _disabled = newValue; _version += 1 } }
    }

    public var extraDirectories: [URL] {
        get { locked { _extraDirectories } }
        set { locked { _extraDirectories = newValue } }
    }

    /// Command-line and environment directories come first, so a pack under development wins over an installed copy.
    public var searchDirectories: [URL] {
        let env = (ProcessInfo.processInfo.environment["RVTOOLS_SOLUTIONS_PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        return extraDirectories + env + [Self.directory]
    }

    /// Rescans every search directory (and the price lists bundled with packs).
    public func reload() {
        var found: [ScriptedSolution] = []
        var issues: [Issue] = []
        var priceFiles: [(url: URL, solutionID: String)] = []
        let reserved = Set(SolutionCatalog.builtIn.map(\.id))
        for pack in Self.packs(in: searchDirectories) {
            do {
                let s = try Self.loadPack(pack)
                if reserved.contains(s.id) {
                    issues.append(Issue(path: pack.path, message: "id “\(s.id)” belongs to a built-in solution — choose another id"))
                } else if let other = found.first(where: { $0.id == s.id }) {
                    issues.append(Issue(path: pack.path, message: "id “\(s.id)” is already used by \(other.packURL.path) — ignored"))
                } else {
                    found.append(s)
                    priceFiles += PriceLibrary.files(in: pack.appendingPathComponent("prices")).map { ($0, s.id) }
                }
            } catch {
                issues.append(Issue(path: pack.path, message: error.localizedDescription))
            }
        }
        found.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        PriceLibrary.shared.reload(solutionFiles: priceFiles)
        locked {
            _solutions = found
            _issues = issues
            _version += 1
        }
    }

    static func isPack(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
    }

    /// Whether a pack lives in the Solutions folder (which may be a symlink, e.g. to a synced folder).
    public static func isInstalled(_ pack: URL) -> Bool {
        pack.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/")
    }

    static func packs(in dirs: [URL]) -> [URL] {
        var out: [URL] = []
        for dir in dirs {
            if isPack(dir) { out.append(dir); continue }
            // The URL-based listing fails with ENOTDIR on a symlinked folder, so list where it really is.
            let children = (try? FileManager.default.contentsOfDirectory(at: dir.resolvingSymlinksInPath(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            out += children.filter(isPack).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return out
    }

    /// Reads and validates one pack without registering it.
    public static func loadPack(_ url: URL) throws -> ScriptedSolution {
        let data: Data
        do { data = try Data(contentsOf: url.appendingPathComponent("manifest.json")) } catch {
            throw ExtensionError("\(url.lastPathComponent) has no readable manifest.json")
        }
        let manifest: SolutionManifest
        do { manifest = try JSONDecoder().decode(SolutionManifest.self, from: data) } catch {
            throw ExtensionError("manifest.json: \(describeDecodingError(error))")
        }
        let problems = manifest.problems
        guard problems.isEmpty else { throw ExtensionError("manifest.json: " + problems.joined(separator: "; ")) }
        let scriptURL = url.appendingPathComponent(manifest.script ?? "solution.js")
        guard let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            throw ExtensionError("can't read \(scriptURL.lastPathComponent) in \(url.lastPathComponent)")
        }
        return ScriptedSolution(manifest: manifest, packURL: url, scriptURL: scriptURL, script: script)
    }

    /// Copies a pack into the Solutions folder as `<id>.rvasolution`, replacing an installed pack with the same id. Call `reload` afterwards.
    @discardableResult
    public func install(_ url: URL) throws -> ScriptedSolution {
        let s = try Self.loadPack(url)
        if SolutionCatalog.builtIn.contains(where: { $0.id == s.id }) { throw ExtensionError("id “\(s.id)” belongs to a built-in solution — choose another id") }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let dest = Self.directory.appendingPathComponent("\(s.id).\(Self.packExtension)", isDirectory: true)
        guard dest.resolvingSymlinksInPath() != url.resolvingSymlinksInPath() else { return s }
        for existing in Self.packs(in: [Self.directory]) where existing.resolvingSymlinksInPath() == dest.resolvingSymlinksInPath() || (try? Self.loadPack(existing))?.id == s.id {
            try fm.trashItem(at: existing, resultingItemURL: nil)
        }
        try fm.copyItem(at: url, to: dest)
        return try Self.loadPack(dest)
    }

    /// Moves an installed pack to the Trash. Call `reload` afterwards.
    public func remove(_ id: String) throws {
        guard let s = solutions.first(where: { $0.id == id }) else { return }
        guard Self.isInstalled(s.packURL) else {
            throw ExtensionError("\(s.title) is loaded from \(s.packURL.path); remove it there.")
        }
        try FileManager.default.trashItem(at: s.packURL, resultingItemURL: nil)
    }
}
