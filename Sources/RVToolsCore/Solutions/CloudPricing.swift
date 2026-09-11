import Foundation

// Public list prices for Azure and AWS, downloaded on request and cached on disk. Only public price
// lists are fetched — no inventory data is ever sent.
//   Azure: Retail Prices API (prices.azure.com) — pay-as-you-go, reservations and managed disks.
//   AWS:   the public price files behind aws.amazon.com pricing pages (b0.p.awsstatic.com) — on-demand
//          EC2 (Linux / Windows) and EBS. Commitment prices aren't published there.

public enum CloudProvider: String, Codable, Sendable {
    case azure, aws
    public var name: String { self == .azure ? "Azure" : "AWS" }
}

public struct CloudRegion: Hashable, Sendable {
    public let code: String
    public let name: String
}

public enum CloudRegions {
    public static let azure: [CloudRegion] = [
        ("eastus", "East US"), ("eastus2", "East US 2"), ("centralus", "Central US"), ("northcentralus", "North Central US"),
        ("southcentralus", "South Central US"), ("westus", "West US"), ("westus2", "West US 2"), ("westus3", "West US 3"),
        ("canadacentral", "Canada Central"), ("uksouth", "UK South"), ("westeurope", "West Europe"), ("northeurope", "North Europe"),
        ("germanywestcentral", "Germany West Central"), ("francecentral", "France Central"), ("swedencentral", "Sweden Central"),
        ("australiaeast", "Australia East"), ("southeastasia", "Southeast Asia"), ("japaneast", "Japan East"),
        ("centralindia", "Central India"), ("brazilsouth", "Brazil South"),
    ].map { CloudRegion(code: $0.0, name: $0.1) }

    /// Names must match the AWS price-list "Location" strings.
    public static let aws: [CloudRegion] = [
        ("us-east-1", "US East (N. Virginia)"), ("us-east-2", "US East (Ohio)"), ("us-west-1", "US West (N. California)"),
        ("us-west-2", "US West (Oregon)"), ("ca-central-1", "Canada (Central)"), ("eu-west-1", "EU (Ireland)"),
        ("eu-west-2", "EU (London)"), ("eu-central-1", "EU (Frankfurt)"), ("eu-west-3", "EU (Paris)"), ("eu-north-1", "EU (Stockholm)"),
        ("ap-southeast-2", "Asia Pacific (Sydney)"), ("ap-southeast-1", "Asia Pacific (Singapore)"), ("ap-northeast-1", "Asia Pacific (Tokyo)"),
        ("ap-south-1", "Asia Pacific (Mumbai)"), ("sa-east-1", "South America (Sao Paulo)"),
    ].map { CloudRegion(code: $0.0, name: $0.1) }

    public static func list(_ p: CloudProvider) -> [CloudRegion] { p == .azure ? azure : aws }
    public static func name(_ p: CloudProvider, _ code: String) -> String { list(p).first { $0.code == code }?.name ?? code }
}

public struct InstanceOffer: Codable, Hashable, Sendable {
    public let name: String
    public let family: String
    public let category: String
    public let vcpu: Int
    public let memoryGiB: Double
    public var linuxHourly: Double?
    public var windowsHourly: Double?
    public var reserved1yHourly: Double?
    public var reserved3yHourly: Double?

    public var displayName: String { name.replacingOccurrences(of: "Standard_", with: "") }
}

public struct RegionPrices: Codable, Sendable {
    public let provider: CloudProvider
    public let region: String
    public let fetched: Date
    public var instances: [InstanceOffer]
    /// Azure: monthly price per disk tier ("P10", "E10", "S10"). AWS: $ per GB-month per volume type ("gp3", "gp2", "st1").
    public var storage: [String: Double]
}

public enum PricingError: LocalizedError {
    case http(Int, String)
    case empty(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let host): return "HTTP \(code) from \(host)"
        case .empty(let s): return s
        }
    }
}

/// In-memory + on-disk cache of downloaded region prices (thread-safe).
public final class PriceStore: @unchecked Sendable {
    public static let shared = PriceStore()
    public static let maxAge: TimeInterval = 7 * 86_400

    private let lock = NSLock()
    private var regions: [String: RegionPrices] = [:]
    private var _version = 0

    public var version: Int { lock.lock(); defer { lock.unlock() }; return _version }

    public var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RVToolsAnalyzer/pricing", isDirectory: true)
    }

    private static func key(_ p: CloudProvider, _ r: String) -> String { p.rawValue + "|" + r }

    private func file(_ p: CloudProvider, _ r: String) -> URL {
        cacheDirectory.appendingPathComponent("\(p.rawValue)-\(r).json")
    }

    public func prices(_ p: CloudProvider, _ region: String) -> RegionPrices? {
        lock.lock(); defer { lock.unlock() }
        return regions[PriceStore.key(p, region)]
    }

    /// Loads cached price files (no network). Stale files (older than `maxAge`) are still loaded but reported.
    @discardableResult
    public func loadFromDisk(_ p: CloudProvider, regions list: [String]) -> [String] {
        var missing: [String] = []
        for r in list where prices(p, r) == nil {
            if let data = try? Data(contentsOf: file(p, r)), let rp = try? JSONDecoder().decode(RegionPrices.self, from: data) {
                store(rp)
            } else {
                missing.append(r)
            }
        }
        return missing
    }

    /// Downloads current public list prices and caches them. Returns an error message per failed region.
    public func download(_ p: CloudProvider, regions list: [String]) async -> [String: String] {
        var errors: [String: String] = [:]
        for r in list {
            do {
                let rp = p == .azure ? try await AzurePrices.fetch(region: r) : try await AWSPrices.fetch(region: r)
                store(rp)
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(rp) { try? data.write(to: file(p, r)) }
            } catch {
                errors[r] = error.localizedDescription
            }
        }
        return errors
    }

    private func store(_ rp: RegionPrices) {
        lock.lock()
        regions[PriceStore.key(rp.provider, rp.region)] = rp
        _version += 1
        lock.unlock()
    }
}

// MARK: - Azure

/// Azure VM sizes whose memory follows a fixed GiB-per-vCPU ratio (the Retail Prices API has no specs).
enum AzureSizes {
    static func spec(_ sku: String) -> (family: String, category: String, vcpu: Int, memoryGiB: Double)? {
        guard let m = regexMatch(sku, #"^Standard_([DEF])(\d+)(a?)s_v([256])$"#), let n = Int(m[2]) else { return nil }
        let letter = m[1].uppercased(), amd = m[3].lowercased() == "a", gen = m[4]
        switch (letter, gen) {
        case ("D", "5"), ("D", "6"):
            return ("D\(amd ? "a" : "")sv\(gen)", "General purpose", n, Double(n) * 4)
        case ("E", "5"), ("E", "6"):
            if gen == "6" && n > 64 { return nil }
            return ("E\(amd ? "a" : "")sv\(gen)", "Memory optimized", n, n >= 96 ? 672 : Double(n) * 8)
        case ("F", "2") where !amd:
            return ("Fsv2", "Compute optimized", n, Double(n) * 2)
        default:
            return nil
        }
    }
}

enum AzurePrices {
    struct Page: Decodable {
        let Items: [Item]
        let NextPageLink: String?
    }

    struct Item: Decodable {
        let armSkuName: String
        let retailPrice: Double
        let type: String
        let reservationTerm: String?
        let productName: String
        let skuName: String
        let meterName: String
    }

    static func query(_ filter: String) async throws -> [Item] {
        var comps = URLComponents(string: "https://prices.azure.com/api/retail/prices")!
        comps.queryItems = [URLQueryItem(name: "$filter", value: filter)]
        var next = comps.url
        var items: [Item] = []
        var pages = 0
        while let url = next, pages < 80 {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw PricingError.http(http.statusCode, url.host ?? "") }
            let page = try JSONDecoder().decode(Page.self, from: data)
            items += page.Items
            next = page.NextPageLink.flatMap { URL(string: $0) }
            pages += 1
        }
        return items
    }

    static func fetch(region: String) async throws -> RegionPrices {
        let vmFilter = "serviceName eq 'Virtual Machines' and armRegionName eq '\(region)' and (priceType eq 'Consumption' or priceType eq 'Reservation') "
            + "and (contains(armSkuName, 's_v5') or contains(armSkuName, 's_v6') or contains(armSkuName, 's_v2'))"
        var offers: [String: InstanceOffer] = [:]
        for i in try await query(vmFilter) {
            // The service also returns Cloud Services products ("Dasv5 Series Cloud Services") for the same SKUs,
            // priced like Windows but without "Windows" in the name — only real VM products count.
            guard i.productName.hasPrefix("Virtual Machines") else { continue }
            let label = (i.skuName + " " + i.meterName).lowercased()
            if label.contains("spot") || label.contains("low priority") { continue }
            guard let spec = AzureSizes.spec(i.armSkuName) else { continue }
            var o = offers[i.armSkuName] ?? InstanceOffer(name: i.armSkuName, family: spec.family, category: spec.category, vcpu: spec.vcpu, memoryGiB: spec.memoryGiB)
            switch i.type {
            case "Consumption":
                if i.productName.contains("Windows") { o.windowsHourly = i.retailPrice } else { o.linuxHourly = i.retailPrice }
            case "Reservation":
                // Reservation prices are the total for the term.
                if i.reservationTerm == "1 Year" { o.reserved1yHourly = i.retailPrice / 8_760 }
                if i.reservationTerm == "3 Years" { o.reserved3yHourly = i.retailPrice / 26_280 }
            default:
                break
            }
            offers[i.armSkuName] = o
        }
        guard !offers.isEmpty else { throw PricingError.empty("No Azure VM prices returned for \(region)") }

        let diskFilter = "serviceName eq 'Storage' and armRegionName eq '\(region)' and priceType eq 'Consumption' and "
            + "(productName eq 'Premium SSD Managed Disks' or productName eq 'Standard SSD Managed Disks' or productName eq 'Standard HDD Managed Disks')"
        var storage: [String: Double] = [:]
        for i in try await query(diskFilter) {
            let parts = i.meterName.split(separator: " ")   // "P10 LRS Disk" (skip ZRS, "Disk Mount", transactions)
            guard parts.count == 3, parts[1] == "LRS", parts[2] == "Disk" else { continue }
            storage[String(parts[0])] = i.retailPrice
        }
        return RegionPrices(provider: .azure, region: region, fetched: Date(), instances: Array(offers.values), storage: storage)
    }
}

// MARK: - AWS

enum AWSPrices {
    static let base = "https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps"
    static let families: Set<String> = ["m5", "m6i", "m6a", "m7i", "m7a", "r5", "r6i", "r6a", "r7i", "r7a", "c5", "c6i", "c6a", "c7i", "c7a", "t3"]

    static func json(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: base + "/" + path) else { throw PricingError.empty("Bad URL \(path)") }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw PricingError.http(http.statusCode, url.host ?? "") }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func regionEntries(_ doc: [String: Any], _ name: String) -> [String: [String: Any]] {
        let regions = doc["regions"] as? [String: Any] ?? [:]
        return (regions[name] ?? regions.values.first) as? [String: [String: Any]] ?? [:]
    }

    static func fetch(region code: String) async throws -> RegionPrices {
        let name = CloudRegions.name(.aws, code)
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { throw PricingError.empty("Bad region \(name)") }
        var offers: [String: InstanceOffer] = [:]
        for os in ["Linux", "Windows"] {
            let doc = try await json("ec2/USD/current/ec2-ondemand-without-sec-sel/\(encoded)/\(os)/index.json")
            for (_, e) in regionEntries(doc, name) {
                guard let type = e["Instance Type"] as? String, let price = Double(e["price"] as? String ?? ""), price > 0,
                      let vcpu = Int(e["vCPU"] as? String ?? ""), let memory = e["Memory"] as? String else { continue }
                let family = String(type.split(separator: ".").first ?? "")
                guard families.contains(family), !type.contains("metal") else { continue }
                let gib = Double(memory.split(separator: " ").first.map { $0.replacingOccurrences(of: ",", with: "") } ?? "") ?? 0
                var o = offers[type] ?? InstanceOffer(name: type, family: family, category: e["Instance Family"] as? String ?? "", vcpu: vcpu, memoryGiB: gib)
                if os == "Linux" { o.linuxHourly = price } else { o.windowsHourly = price }
                offers[type] = o
            }
        }
        guard !offers.isEmpty else { throw PricingError.empty("No AWS EC2 prices returned for \(name)") }

        var storage: [String: Double] = [:]
        let ebs = regionEntries(try await json("ec2/USD/current/ebs.json"), name)
        let keys = ["gp3": "Storage General Purpose gp3 GB Mo", "gp2": "Storage General Purpose gp2 GB Mo", "st1": "Storage Throughput Optimized HDD st1 GB Mo"]
        for (type, k) in keys { if let p = Double(ebs[k]?["price"] as? String ?? "") { storage[type] = p } }
        return RegionPrices(provider: .aws, region: code, fetched: Date(), instances: Array(offers.values), storage: storage)
    }
}
