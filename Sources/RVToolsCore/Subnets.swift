import Foundation

/// An IPv4 address.
public struct IPv4: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard (1...3).contains(p.count), let octet = UInt32(p), octet <= 255 else { return nil }
            v = v << 8 | octet
        }
        value = v
    }

    public var description: String { "\(value >> 24).\(value >> 16 & 255).\(value >> 8 & 255).\(value & 255)" }

    public static func < (a: IPv4, b: IPv4) -> Bool { a.value < b.value }

    /// Worth counting for a guest network: not unspecified, loopback, link-local (APIPA), multicast or reserved.
    public var isGuestNetworkAddress: Bool {
        let first = value >> 24
        return first != 0 && first != 127 && first < 224 && !(first == 169 && value >> 16 & 255 == 254)
    }
}

/// An IPv4 network in CIDR notation.
public struct CIDR: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let network: UInt32
    public let prefix: Int

    /// The network of `prefix` bits that contains `ip`.
    public init(_ ip: IPv4, prefix: Int) {
        self.prefix = prefix
        network = ip.value & (UInt32.max << UInt32(32 - prefix))
    }

    /// From an address and a dotted mask ("255.255.254.0") or prefix length ("23" or "/23"); nil for anything else.
    public init?(address: String, mask: String) {
        guard let ip = IPv4(address) else { return nil }
        let m = mask.trimmingCharacters(in: .whitespaces)
        if let p = Int(m.hasPrefix("/") ? String(m.dropFirst()) : m), (0...32).contains(p) {
            self.init(ip, prefix: p)
            return
        }
        guard let bits = IPv4(m)?.value else { return nil }
        let p = bits.nonzeroBitCount
        guard bits == UInt32.max << UInt32(32 - p) else { return nil }
        self.init(ip, prefix: p)
    }

    public var size: UInt64 { UInt64(1) << UInt64(32 - prefix) }
    public func contains(_ ip: IPv4) -> Bool { CIDR(ip, prefix: prefix).network == network }
    public func overlaps(_ other: CIDR) -> Bool { contains(IPv4(other.network)) || other.contains(IPv4(network)) }
    public var description: String { "\(IPv4(network))/\(prefix)" }

    public static func < (a: CIDR, b: CIDR) -> Bool { (a.network, a.prefix) < (b.network, b.prefix) }
}

/// A network seen in use: guest addresses grouped into /24 blocks, merged where neighbouring blocks are all in use.
public struct ObservedSubnet: Hashable, Sendable {
    public let cidr: CIDR
    /// Distinct addresses seen in it.
    public let addresses: Int
    /// VMs with an address in it.
    public let vms: Int
    public let first: IPv4
    public let last: IPv4

    public var range: String { first == last ? first.description : "\(first) – \(last)" }
}

public enum Subnets {
    /// Guest addresses are grouped into blocks of this size. RVTools doesn't record VM netmasks, so it's a convention.
    public static let basePrefix = 24
    /// Neighbouring blocks are merged no further than this.
    public static let widestPrefix = 16

    /// The networks these addresses fall in. `owner` identifies whose address it is (a VM id) for the VM counts.
    public static func observed(_ addresses: [(ip: IPv4, owner: String)]) -> [ObservedSubnet] {
        let usable = addresses.filter { $0.ip.isGuestNetworkAddress }
        guard !usable.isEmpty else { return [] }
        var blocks = Set(usable.map { CIDR($0.ip, prefix: basePrefix) })
        var merged = true
        while merged {
            merged = false
            for block in blocks.sorted() where block.prefix > widestPrefix && blocks.contains(block) {
                let parent = CIDR(IPv4(block.network), prefix: block.prefix - 1)
                guard parent.network == block.network else { continue }
                let upper = CIDR(IPv4(block.network &+ UInt32(block.size)), prefix: block.prefix)
                guard upper.network != block.network, blocks.contains(upper) else { continue }
                blocks.remove(block)
                blocks.remove(upper)
                blocks.insert(parent)
                merged = true
            }
        }
        return blocks.sorted().map { cidr in
            let inside = usable.filter { cidr.contains($0.ip) }
            let ips = Set(inside.map(\.ip))
            return ObservedSubnet(cidr: cidr, addresses: ips.count, vms: Set(inside.map(\.owner)).count, first: ips.min()!, last: ips.max()!)
        }
    }

    public static func list(_ subnets: [ObservedSubnet]) -> String { subnets.map(\.cidr.description).joined(separator: ", ") }
}

public extension VMKernel {
    /// The adapter's network, from its address and subnet mask (exact, unlike VM subnets).
    var cidr: String { CIDR(address: ip, mask: subnet)?.description ?? "" }
}
