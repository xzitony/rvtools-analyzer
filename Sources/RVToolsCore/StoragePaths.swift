import Foundation

/// How each datastore is reached, and how redundant that is on every host that mounts it.
///
/// RVTools reports block storage paths per host in vMultiPath (one row per LUN, up to eight paths with their state),
/// the adapters in vHBA, and VMkernel adapters in vSC_VMK. NFS has no path rows at all: its redundancy comes from the
/// VMkernel adapters that reach the server and the uplinks of the switch behind them, so it is assessed differently.
/// vSAN and local disks are reported here but not assessed.
public enum StorageTransport: String, Sendable, CaseIterable {
    case fibreChannel = "Fibre Channel"
    case iscsi = "iSCSI"
    case nfs = "NFS"
    case vsan = "vSAN"
    case local = "Local"
    case unknown = "Unknown"

    /// Transports whose redundancy comes from multipathing rather than the network.
    public var isBlock: Bool { self == .fibreChannel || self == .iscsi }
}

/// One host's view of one datastore.
public struct HostStoragePaths: Identifiable, Sendable {
    public var id: String { hostKey }
    public var hostKey = ""
    public var host = ""
    /// Block storage: the LUNs behind the datastore, as this host sees them.
    public var devices: [MultiPathLUN] = []
    public var paths = 0
    public var activePaths = 0
    public var deadPaths = 0
    /// Storage adapters the paths run over, e.g. "vmhba1".
    public var adapters: [String] = []
    public var policies: [String] = []
    /// NFS: VMkernel adapters that can reach the server (same subnet, or named for storage).
    public var vmkernels: [VMKernel] = []
    /// NFS: uplinks with link on the switches behind those VMkernel adapters.
    public var uplinks = 0

    public var hasPathData: Bool { !devices.isEmpty }
    public var mtus: [Int] { Array(Set(vmkernels.map(\.mtu))).sorted() }
    public var adapterList: String { adapters.joined(separator: ", ") }
    public var policyList: String { policies.joined(separator: ", ") }
}

/// A datastore's transport and per-host redundancy.
public struct DatastorePaths: Sendable {
    public var datastoreID = ""
    public var name = ""
    public var transport: StorageTransport = .unknown
    public var hosts: [HostStoragePaths] = []
    /// Hosts that mount the datastore but have no multipathing rows in the export.
    public var hostsWithoutData: [String] = []
    /// NFS server as RVTools reports it: "nfs01.example.com:/vol/x" → server and export path.
    public var server = ""
    public var exportPath = ""

    var withData: [HostStoragePaths] { hosts.filter(\.hasPathData) }
    public var minPaths: Int { withData.map(\.paths).min() ?? 0 }
    public var maxPaths: Int { withData.map(\.paths).max() ?? 0 }
    public var totalPaths: Int { hosts.reduce(0) { $0 + $1.paths } }
    public var deadPaths: Int { hosts.reduce(0) { $0 + $1.deadPaths } }
    public var policies: [String] { Array(Set(hosts.flatMap(\.policies))).sorted() }

    public var deadPathHosts: [HostStoragePaths] { hosts.filter { $0.deadPaths > 0 } }
    public var singlePathHosts: [HostStoragePaths] { withData.filter { $0.paths == 1 } }
    /// Hosts whose paths all run over one adapter: that adapter is a single point of failure.
    public var singleAdapterHosts: [HostStoragePaths] { withData.filter { $0.paths > 1 && $0.adapters.count == 1 } }
    /// NFS hosts with fewer than two VMkernel adapters able to reach the server.
    public var singleVMKHosts: [HostStoragePaths] { transport == .nfs ? hosts.filter { $0.vmkernels.count == 1 } : [] }
    public var noVMKHosts: [HostStoragePaths] { transport == .nfs ? hosts.filter { $0.vmkernels.isEmpty } : [] }
    /// NFS hosts whose storage VMkernel sits on a switch with a single uplink.
    public var singleUplinkHosts: [HostStoragePaths] { transport == .nfs ? hosts.filter { !$0.vmkernels.isEmpty && $0.uplinks == 1 } : [] }
    public var mtus: [Int] { Array(Set(hosts.flatMap { $0.vmkernels.map(\.mtu) }).filter { $0 > 0 }).sorted() }

    /// One line for the inspector and the map: "6 hosts · 4 paths each · Round Robin".
    public var summary: String {
        switch transport {
        case .nfs:
            let vmk = hosts.map { $0.vmkernels.count }.min() ?? 0
            let mtuText = mtus.count == 1 ? " · MTU \(mtus[0])" : (mtus.count > 1 ? " · MTU " + mtus.map(String.init).joined(separator: "/") : "")
            return "\(hosts.count) host\(hosts.count == 1 ? "" : "s") · \(vmk) VMkernel adapter\(vmk == 1 ? "" : "s") to the server" + mtuText
        case .vsan, .local:
            return "\(transport.rawValue) · no storage paths to check"
        default:
            guard !withData.isEmpty else { return "No multipathing data in the export" }
            let paths = minPaths == maxPaths ? "\(minPaths) paths each" : "\(minPaths)–\(maxPaths) paths"
            let policy = policies.count == 1 ? " · " + StoragePaths.policyName(policies[0]) : ""
            return "\(withData.count) host\(withData.count == 1 ? "" : "s") · \(paths)" + policy
        }
    }
}

public enum StoragePaths {
    /// Path redundancy for every datastore in the inventory, keyed by datastore id.
    public static func map(_ inv: Inventory) -> [String: DatastorePaths] {
        let b = Builder(inv)
        return Dictionary(inv.datastores.map { ($0.id, b.paths(for: $0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// Path redundancy for one datastore.
    public static func paths(for ds: Datastore, in inv: Inventory) -> DatastorePaths {
        Builder(inv).paths(for: ds)
    }

    /// "VMW_PSP_RR" → "Round Robin".
    public static func policyName(_ policy: String) -> String {
        switch policy.uppercased() {
        case "VMW_PSP_RR": return "Round Robin"
        case "VMW_PSP_FIXED": return "Fixed"
        case "VMW_PSP_MRU": return "Most Recently Used"
        default: return policy
        }
    }

    /// The adapter a path runs over: "vmhba1:C0:T0:L1" → "vmhba1".
    static func adapter(ofPath path: String) -> String {
        String(path.split(separator: ":").first ?? "")
    }

    private struct Builder {
        let inv: Inventory
        let lunsByHost: [String: [MultiPathLUN]]
        let vmksByHost: [String: [VMKernel]]
        let hbasByHost: [String: [HBA]]
        let pnicsByHost: [String: [PhysicalNIC]]
        let hostsByKey: [String: Host]
        let portGroups: [String: PortGroup]

        init(_ inv: Inventory) {
            self.inv = inv
            lunsByHost = Dictionary(grouping: inv.luns, by: \.hostKey)
            vmksByHost = Dictionary(grouping: inv.vmkernels, by: \.hostKey)
            hbasByHost = Dictionary(grouping: inv.hbas, by: \.hostKey)
            pnicsByHost = Dictionary(grouping: inv.pnics, by: \.hostKey)
            hostsByKey = Dictionary(inv.hosts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            portGroups = Dictionary(inv.portGroups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }

        func paths(for ds: Datastore) -> DatastorePaths {
            var out = DatastorePaths(datastoreID: ds.id, name: ds.name)
            let (server, export) = Self.splitAddress(ds.address)
            out.server = server
            out.exportPath = export

            var luns: [String: [MultiPathLUN]] = [:]   // hostKey → LUNs of this datastore
            for hk in ds.hostKeys {
                let mine = (lunsByHost[hk] ?? []).filter { $0.datastore.lowercased() == ds.name.lowercased() }
                if !mine.isEmpty { luns[hk] = mine }
            }
            out.transport = transport(ds, luns: luns.values.flatMap { $0 })

            for hk in ds.hostKeys {
                guard let host = hostsByKey[hk] else { continue }
                var h = HostStoragePaths(hostKey: hk, host: host.name)
                h.devices = luns[hk] ?? []
                h.paths = h.devices.reduce(0) { $0 + $1.paths }
                h.activePaths = h.devices.reduce(0) { $0 + $1.activePaths }
                h.deadPaths = h.devices.reduce(0) { $0 + $1.deadPaths }
                h.adapters = Array(Set(h.devices.flatMap { $0.pathNames.map(StoragePaths.adapter(ofPath:)) }).filter { !$0.isEmpty }).sorted()
                h.policies = Array(Set(h.devices.map(\.policy).filter { !$0.isEmpty })).sorted()
                if out.transport == .nfs {
                    h.vmkernels = storageVMKs(hostKey: hk, host: host, server: server)
                    h.uplinks = uplinks(for: h.vmkernels, host: host)
                }
                out.hosts.append(h)
            }
            out.hosts.sort { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
            if out.transport.isBlock || out.transport == .unknown {
                out.hostsWithoutData = out.hosts.filter { !$0.hasPathData }.map(\.host)
            }
            return out
        }

        /// vSAN and NFS come from the datastore type; block storage from the LUN names, then the host's adapters.
        private func transport(_ ds: Datastore, luns: [MultiPathLUN]) -> StorageTransport {
            let type = ds.type.lowercased()
            if type.contains("vsan") { return .vsan }
            if type.contains("nfs") { return .nfs }
            if type.contains("vvol") { return .unknown }
            if ds.isLocal && luns.isEmpty { return .local }
            let names = luns.map { ($0.displayName + " " + $0.model + " " + $0.vendor).lowercased() }
            if names.contains(where: { $0.contains("iscsi") }) { return .iscsi }
            if names.contains(where: { $0.contains("fibre") || $0.contains("fcoe") }) { return .fibreChannel }
            if names.contains(where: { $0.contains("local") || $0.contains("sas") || $0.contains("sata") || $0.contains("nvme") }) { return .local }
            let types = Set(ds.hostKeys.flatMap { hbasByHost[$0] ?? [] }.map { $0.type.lowercased() })
            if types.contains(where: { $0.contains("fibre") || $0.contains("fcoe") }) { return .fibreChannel }
            if types.contains(where: { $0.contains("iscsi") }) { return .iscsi }
            return .unknown
        }

        /// The VMkernel adapters that can reach an NFS server: same subnet when the server is an IP address,
        /// otherwise the ones whose port group is named for storage. Management-only hosts get none.
        private func storageVMKs(hostKey: String, host: Host, server: String) -> [VMKernel] {
            let all = vmksByHost[hostKey] ?? []
            if let serverIP = IPv4(server) {
                let sameSubnet = all.filter { k in
                    guard let ip = IPv4(k.ip), let mask = IPv4(k.subnet) else { return false }
                    return ip.value & mask.value == serverIP.value & mask.value
                }
                if !sameSubnet.isEmpty { return sameSubnet }
            }
            let named = all.filter { k in
                let text = (k.portGroup + " " + k.device).lowercased()
                return text.contains("nfs") || text.contains("storage") || text.contains("stor-") || text.contains("iscsi")
            }
            if !named.isEmpty { return named }
            // No storage-specific adapter: NFS traffic runs over whatever carries that subnet, usually management.
            return []
        }

        /// Uplinks with link on the switches behind these VMkernel adapters.
        private func uplinks(for vmks: [VMKernel], host: Host) -> Int {
            let switches = Set(vmks.compactMap { k -> String? in
                portGroups[key(host.vcenter, k.portGroup)]?.switchName.lowercased()
            })
            guard !switches.isEmpty else { return 0 }
            return (pnicsByHost[host.id] ?? []).filter { switches.contains($0.switchName.lowercased()) && $0.speedMbps > 0 }.count
        }

        /// "nfs01.example.com:/vol/data" → ("nfs01.example.com", "/vol/data").
        static func splitAddress(_ address: String) -> (String, String) {
            guard let colon = address.firstIndex(of: ":") else { return (address, "") }
            return (String(address[..<colon]), String(address[address.index(after: colon)...]))
        }
    }
}
