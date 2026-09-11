import Foundation

public enum CPUSupport: String, Sendable {
    case supported = "Supported"
    case atRisk = "Check compatibility guide"
    case unsupported = "Not supported"
    case virtual = "Virtual"
    case unknown = "Unknown"
}

public struct CPUGeneration: Sendable {
    public let name: String
    public let support: CPUSupport

    /// Built-in CPU generation table (edit here). Sandy/Ivy Bridge and older were dropped before ESXi 8;
    /// Haswell/Broadwell/Naples are treated as at risk for ESXi 9 — confirm on the Broadcom Compatibility Guide.
    public static func classify(_ model: String) -> CPUGeneration {
        let m = model.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "")
        if m.range(of: "virtual", options: .caseInsensitive) != nil { return .init(name: "Virtual CPU", support: .virtual) }
        if let g = regexMatch(m, #"(Platinum|Gold|Silver|Bronze)\s+\d(\d)\d\d"#), let d = Int(g[2]) {
            let names = [1: "Skylake-SP (1st gen Scalable)", 2: "Cascade Lake (2nd gen Scalable)", 3: "Ice Lake (3rd gen Scalable)",
                         4: "Sapphire Rapids (4th gen Scalable)", 5: "Emerald Rapids (5th gen Scalable)"]
            return .init(name: names[d] ?? "Xeon Scalable", support: .supported)
        }
        if regexMatch(m, #"Xeon\s+6\d{3}"#) != nil { return .init(name: "Xeon 6", support: .supported) }
        if let g = regexMatch(m, #"E[357]-\d{4}[A-Z]*\s*v(\d)"#), let v = Int(g[1]) {
            switch v {
            case 2: return .init(name: "Ivy Bridge", support: .unsupported)
            case 3: return .init(name: "Haswell", support: .atRisk)
            case 4: return .init(name: "Broadwell", support: .atRisk)
            default: return .init(name: "Xeon E5/E7 v\(v)", support: .unknown)
            }
        }
        if regexMatch(m, #"E[357]-\d{4}"#) != nil { return .init(name: "Sandy Bridge", support: .unsupported) }
        if let g = regexMatch(m, #"D-(\d)(\d)\d\d"#) {
            switch (g[1], g[2]) {
            case ("1", "5"): return .init(name: "Broadwell-DE", support: .atRisk)
            case ("2", "1"), ("1", "6"): return .init(name: "Skylake-D", support: .supported)
            default: return .init(name: "Xeon D (Ice Lake-D or later)", support: .supported)
            }
        }
        if regexMatch(m, #"\b[XELW][357]\d{3}\b"#) != nil { return .init(name: "Nehalem / Westmere", support: .unsupported) }
        if let g = regexMatch(m, #"EPYC\s+(\d)[0-9A-Z]{2}(\d)"#), let gen = Int(g[2]) {
            switch (g[1], gen) {
            case ("7", 1): return .init(name: "EPYC Naples (1st gen)", support: .atRisk)
            case ("7", 2): return .init(name: "EPYC Rome (2nd gen)", support: .supported)
            case ("7", 3): return .init(name: "EPYC Milan (3rd gen)", support: .supported)
            case ("9", 4), ("8", 4), ("4", 4): return .init(name: "EPYC Genoa / Siena (4th gen)", support: .supported)
            case (_, 5): return .init(name: "EPYC Turin (5th gen)", support: .supported)
            default: return .init(name: "AMD EPYC", support: .unknown)
            }
        }
        if m.range(of: "Opteron", options: .caseInsensitive) != nil { return .init(name: "AMD Opteron", support: .unsupported) }
        return .init(name: m.isEmpty ? "Unknown" : "Unrecognised model", support: .unknown)
    }
}

/// Readiness of the infrastructure running the selected VMs (their clusters, hosts and vCenters) for an
/// upgrade / convergence to VMware Cloud Foundation 9, plus VM-level items that affect rolling upgrades.
/// Rules are built-in defaults; verify against Broadcom's upgrade matrix and compatibility guide.
public struct VCF9Readiness: Solution {
    public init() {}
    public var id: String { "vcf9" }
    public var title: String { "VCF 9 Readiness" }
    public var symbol: String { "arrow.up.circle" }
    public var summary: String { "Upgrade-path, hardware, cluster, network, storage and VM checks for moving the selected workloads' infrastructure to VCF 9." }

    public var parameters: [SolutionParameter] { [
        .choice("minSource", "Upgrade path", "Minimum version for a direct upgrade to 9.0", ["8.0 GA", "8.0 U1", "8.0 U2", "8.0 U3"], selected: 1,
                help: "vCenter / ESXi below this need an intermediate update. Confirm against Broadcom's supported upgrade paths."),
        .choice("legacyCPU", "Hardware", "Treat Haswell / Broadwell / EPYC Naples hosts as", ["Warning — verify on the compatibility guide", "Blocker"]),
        .number("minHosts", "Clusters", "Minimum hosts per cluster", 3, min: 2, max: 8),
        .number("n1Warn", "Clusters", "Warn when memory after losing a host exceeds", 90, min: 50, max: 100, unit: "%",
                help: "Rolling upgrades put one host at a time into maintenance mode."),
        .toggle("requireVDS", "Networking", "Require vSphere Distributed Switch", true),
        .number("coreMin", "Licensing", "Licensed cores minimum per CPU", 16, min: 1, max: 64,
                help: "VCF is licensed per core with a per-CPU minimum; verify current terms."),
    ] }

    public func defaultSelection(_ inventory: Inventory) -> Set<String> {
        Set(inventory.vms.filter(\.isVM).map(\.id))
    }

    static func version(_ s: String) -> (Int, Int, Int)? {
        let parts = Lifecycle.parseVMwareVersion(s).version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1], parts.count > 2 ? parts[2] : 0)
    }

    func cpuStatus(_ g: CPUGeneration, _ legacy: CheckStatus) -> CheckStatus {
        switch g.support {
        case .supported, .virtual: return .ready
        case .atRisk: return legacy
        case .unsupported: return .blocker
        case .unknown: return .info
        }
    }

    static func upgradePath(_ v: (Int, Int, Int)?, minUpdate: Int) -> (CheckStatus, String) {
        guard let v else { return (.info, "version unknown") }
        let label = "\(v.0).\(v.1)" + (v.0 == 8 ? (v.2 == 0 ? " GA" : " U\(v.2)") : ".\(v.2)")
        if v.0 >= 9 { return (.ready, "\(label) — already on 9") }
        if v.0 == 8 {
            return v.2 >= minUpdate ? (.ready, "\(label) — direct upgrade") : (.warning, "\(label) — update to 8.0 U\(minUpdate)+ first")
        }
        return (.blocker, "\(label) — upgrade to 8.0 first (no direct path to 9.0)")
    }

    public func run(vms: [VM], inventory inv: Inventory, params p: Params) -> SolutionResult {
        let minU = p.choice("minSource")
        let legacyStatus: CheckStatus = p.choice("legacyCPU") == 1 ? .blocker : .warning
        let minHosts = Int(p.num("minHosts"))
        let n1Warn = p.num("n1Warn")
        let requireVDS = p.flag("requireVDS")

        let clusterIDs = Set(vms.map(\.clusterKey))
        let clusters = inv.clusters.filter { clusterIDs.contains($0.id) }
        let scopeHosts = inv.hosts.filter { clusterIDs.contains($0.clusterKey) }
        let hosts = scopeHosts.filter { !$0.isVirtual }
        let hostIDs = Set(scopeHosts.map(\.id))
        let servers = Set(vms.map { $0.vcenter.lowercased() })
        let vcenters = inv.vcenters.filter { servers.contains($0.server.lowercased()) }
        let vmDatastores = Set(vms.flatMap { vm in vm.datastores.map { vm.vcenter.lowercased() + "|" + $0.lowercased() } })
        let datastores = inv.datastores.filter { $0.hostKeys.contains(where: hostIDs.contains) || vmDatastores.contains($0.id) }
        let pgByID = Dictionary(inv.portGroups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let clusterByID = Dictionary(inv.clusters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let reportDate = inv.reportDate

        var b = CheckBuilder()

        // MARK: vCenter
        let vcArea = "vCenter"
        b.aggregate("vc.version", vcArea, "vCenter upgrade path to 9.0", noun: "vCenters need work first",
                    items: vcenters.map { vc in
                        let (s, msg) = VCF9Readiness.upgradePath(VCF9Readiness.version(vc.version.isEmpty ? vc.fullName : vc.version), minUpdate: minU)
                        return (s, AffectedObject(kind: .vcenter, id: vc.id, name: vc.server, detail: msg))
                    },
                    ready: "All \(vcenters.count) vCenter(s) have a direct upgrade path",
                    remediation: "vCenter is upgraded first and must reach 9.0 before its hosts. From 7.x this is a two-step upgrade via 8.0.",
                    empty: "vCenter version unknown (no vSource tab)")

        // MARK: Hosts & hardware
        let hwArea = "ESXi hosts & hardware"
        let hostPath = hosts.map { h -> (CheckStatus, AffectedObject) in
            let (s, msg) = VCF9Readiness.upgradePath(VCF9Readiness.version(h.esxVersion), minUpdate: minU)
            return (s, h.ref("ESXi " + msg + (h.esxBuild.isEmpty ? "" : " (build \(h.esxBuild))")))
        }
        b.aggregate("host.version", hwArea, "ESXi upgrade path to 9.0", noun: "hosts need work first", items: hostPath,
                    ready: "All \(hosts.count) hosts have a direct upgrade path",
                    remediation: "Update hosts below the minimum to a supported 8.0 update first; hosts on 7.x need a two-step upgrade (7 → 8 → 9) and may need new hardware.")
        let cpuGen = Dictionary(hosts.map { ($0.id, CPUGeneration.classify($0.cpuModel)) }, uniquingKeysWith: { a, _ in a })
        b.aggregate("host.cpu", hwArea, "CPU generation supported by ESXi 9", noun: "hosts have older or unrecognised CPUs",
                    items: hosts.map { h in
                        let g = cpuGen[h.id]!
                        return (cpuStatus(g, legacyStatus), h.ref("\(g.name) — \(h.cpuModel)"))
                    },
                    ready: "All host CPUs are on supported generations",
                    remediation: "Check each CPU on the Broadcom Compatibility Guide for ESXi 9.0; unsupported CPUs mean new hardware before the upgrade.")
        let models = Dictionary(grouping: hosts, by: { [$0.vendor, $0.model].filter { !$0.isEmpty }.joined(separator: " ") })
            .map { "\($0.key.isEmpty ? "Unknown" : $0.key) (\($0.value.count))" }.sorted()
        if !hosts.isEmpty {
            b.add("host.hcl", hwArea, "Server models to verify on the compatibility guide", .info, models.joined(separator: " · "),
                  remediation: "Verify each server model, NIC, storage controller and firmware level on the Broadcom Compatibility Guide for ESXi 9.0 and your vendor's vLCM support.")
        }
        b.aggregate("host.ntp", hwArea, "NTP configured and running", noun: "hosts lack working NTP",
                    items: hosts.map { h in
                        let ok = !h.ntpServers.trimmingCharacters(in: .whitespaces).isEmpty && h.ntpdRunning != false
                        return (ok ? .ready : .blocker, h.ref(h.ntpServers.isEmpty ? "no NTP servers" : "ntpd not running"))
                    },
                    ready: "NTP is configured and running on every host",
                    remediation: "VCF requires consistent time on every component. Configure NTP servers and start the NTP service.")
        b.aggregate("host.dns", hwArea, "DNS configured", noun: "hosts have no DNS servers",
                    items: hosts.map { h in (h.dnsServers.trimmingCharacters(in: .whitespaces).isEmpty ? .warning : .ready, h.ref("no DNS servers")) },
                    ready: "DNS servers are set on every host",
                    remediation: "VCF needs forward and reverse DNS records for every host and appliance.")
        b.aggregate("host.cert", hwArea, "Host certificates valid", noun: "hosts have certificates expiring soon",
                    items: hosts.compactMap { h in
                        guard let exp = h.certExpiry else { return nil }
                        let s: CheckStatus = exp <= reportDate ? .blocker : (exp <= reportDate.addingTimeInterval(90 * 86_400) ? .warning : .ready)
                        return (s, h.ref("expires \(Fmt.date(exp))"))
                    },
                    ready: "No host certificates expire within 90 days",
                    remediation: "Renew host certificates before the upgrade.")
        b.aggregate("host.uplinks", hwArea, "At least two physical uplinks", noun: "hosts have fewer than two NICs",
                    items: hosts.map { h in (h.pnicCount > 0 && h.pnicCount < 2 ? .warning : .ready, h.ref("\(h.pnicCount) physical NIC")) },
                    ready: "Every host has two or more physical NICs",
                    remediation: "VCF host network profiles expect redundant uplinks.")
        let maint = hosts.filter(\.maintenance).map { $0.ref("in maintenance mode") }
        if !maint.isEmpty { b.add("host.maint", hwArea, "Hosts in maintenance mode", .info, "\(maint.count) hosts", affected: maint) }
        let virtualHosts = scopeHosts.filter(\.isVirtual).map { $0.ref($0.cpuModel) }
        if !virtualHosts.isEmpty {
            b.add("host.virtual", hwArea, "Virtual hosts excluded", .info, "\(virtualHosts.count) witness / placeholder hosts not assessed", affected: virtualHosts)
        }

        // MARK: Clusters
        let clArea = "Clusters"
        func cref(_ c: Cluster, _ d: String) -> AffectedObject { AffectedObject(kind: .cluster, id: c.id, name: c.name, detail: d) }
        let standalone = clusters.filter(\.isStandalone)
        b.list("cl.standalone", clArea, "Hosts outside a cluster", .warning, noun: "groups of standalone hosts",
               affected: standalone.map { cref($0, "\($0.hostCount) host(s)") },
               ready: "Every in-scope host is in a cluster", remediation: "VCF manages clusters; place standalone hosts into a cluster (or retire them) first.")
        let real = clusters.filter { !$0.isStandalone }
        b.aggregate("cl.size", clArea, "Cluster size", noun: "clusters are below \(minHosts) hosts",
                    items: real.map { c in (c.hostCount < minHosts ? .warning : .ready, cref(c, "\(c.hostCount) host(s)")) },
                    ready: "All clusters have \(minHosts)+ hosts",
                    remediation: "VCF domains need a minimum number of hosts per cluster (more for vSAN); check the minimum for your domain type.")
        b.aggregate("cl.drs", clArea, "DRS enabled", noun: "clusters without DRS",
                    items: real.map { c in (c.drsEnabled == false ? .warning : .ready, cref(c, "DRS disabled")) },
                    ready: "DRS is enabled on all clusters",
                    remediation: "Rolling host remediation relies on DRS to evacuate hosts automatically.")
        b.aggregate("cl.ha", clArea, "vSphere HA enabled", noun: "clusters without HA",
                    items: real.map { c in (c.haEnabled == false ? .warning : .ready, cref(c, "HA disabled")) },
                    ready: "HA is enabled on all clusters", remediation: "Enable HA to protect workloads while hosts are being upgraded.")
        b.aggregate("cl.n1", clArea, "Capacity to evacuate a host", noun: "clusters are short of rolling-upgrade headroom",
                    items: real.map { c in
                        let pct = c.memPctAfterHostLoss
                        let s: CheckStatus = c.hostCount < 2 || pct > 100 ? .blocker : (pct > n1Warn ? .warning : .ready)
                        return (s, cref(c, c.hostCount < 2 ? "single host — VMs must be powered off" : "memory at \(Fmt.pct(pct)) with one host in maintenance"))
                    },
                    ready: "Every cluster can run with one host in maintenance mode",
                    remediation: "Free or add capacity so each cluster can lose one host during the upgrade without powering VMs off.")
        b.aggregate("cl.image", clArea, "Consistent hardware per cluster", noun: "clusters mix server vendors or models",
                    items: real.map { c in
                        let members = hosts.filter { $0.clusterKey == c.id }
                        let vendors = Set(members.map(\.vendor)), modelSet = Set(members.map { $0.vendor + " " + $0.model })
                        let s: CheckStatus = vendors.count > 1 ? .warning : (modelSet.count > 1 ? .info : .ready)
                        return (s, cref(c, modelSet.sorted().joined(separator: " · ")))
                    },
                    ready: "Each cluster uses a single server model",
                    remediation: "vLCM applies one image (with one vendor add-on) per cluster; mixed vendors complicate firmware and driver management.")

        // MARK: Networking
        let netArea = "Networking"
        var pgVMs: [String: Int] = [:]
        for vm in vms { for n in Set(vm.networks) { pgVMs[vm.vcenter.lowercased() + "|" + n.lowercased(), default: 0] += 1 } }
        let usedPGs = pgVMs.keys.compactMap { pgByID[$0] }
        let vssPGs = usedPGs.filter { $0.kind == "Standard" }
        b.list("net.vss", netArea, "VM networks on standard vSwitches", requireVDS ? .warning : .info, noun: "port groups used by the selected VMs",
               affected: vssPGs.map { AffectedObject(kind: .network, id: $0.id, name: $0.name, detail: "\(pgVMs[$0.id] ?? 0) VMs · VLAN \($0.vlanList) · \($0.switchName)") },
               ready: "Selected VMs use distributed port groups", remediation: "VCF-managed clusters use vSphere Distributed Switches; migrate these port groups to a vDS.")
        let vmkVSS = inv.vmkernels.filter { k in
            guard hostIDs.contains(k.hostKey) else { return false }
            let server = k.hostKey.split(separator: "|").first.map(String.init) ?? ""
            return pgByID[server + "|" + k.portGroup.lowercased()]?.kind == "Standard"
        }
        let vmkHosts = Dictionary(grouping: vmkVSS, by: \.hostKey)
        b.list("net.vmk", netArea, "VMkernel adapters on standard vSwitches", requireVDS ? .warning : .info, noun: "hosts",
               affected: vmkHosts.map { hk, ks in AffectedObject(kind: .host, id: hk, name: ks.first?.host ?? hk, detail: ks.map { "\($0.device) (\($0.portGroup))" }.joined(separator: ", ")) }
                .sorted { $0.name < $1.name },
               ready: "No VMkernel adapters on standard switches", remediation: "Migrate management, vMotion and storage VMkernel adapters to the vDS.")
        let dvsInScope = inv.dvSwitches.filter { d in servers.contains(d.vcenter.lowercased()) }
        b.aggregate("net.vds", netArea, "Distributed switch version", noun: "distributed switches are below 8.0",
                    items: dvsInScope.map { d in
                        let major = Int(d.version.split(separator: ".").first ?? "") ?? 0
                        return (major >= 8 ? .ready : (major >= 7 ? .warning : .blocker),
                                AffectedObject(kind: .network, id: d.id, name: d.name, detail: "version \(d.version.isEmpty ? "unknown" : d.version)"))
                    },
                    ready: "All distributed switches are 8.0 or later", remediation: "Upgrade distributed switches to the latest version supported by the target release.")
        let nsx = usedPGs.filter { $0.kind == "NSX / opaque" } + pgVMs.keys.filter { pgByID[$0] == nil }.map { k in
            PortGroup(id: k, name: String(k.split(separator: "|", maxSplits: 1).last ?? ""), kind: "NSX / opaque")
        }
        if !nsx.isEmpty {
            b.add("net.nsx", netArea, "NSX / opaque networks in use", .info, "\(nsx.count) segments",
                  remediation: "Plan the NSX upgrade or import path alongside VCF 9.",
                  affected: nsx.map { AffectedObject(kind: .network, id: $0.id, name: $0.name, detail: "\(pgVMs[$0.id] ?? 0) VMs") })
        }

        // MARK: Storage
        let stArea = "Storage"
        let types = Dictionary(grouping: datastores, by: { $0.type.isEmpty ? "Unknown" : $0.type }).mapValues(\.count)
        let supported = ["vsan", "vmfs", "nfs", "nfs41"]
        let other = datastores.filter { !supported.contains($0.type.lowercased()) }
        b.add("st.types", stArea, "Datastore types", other.isEmpty ? .ready : .info,
              types.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "),
              remediation: other.isEmpty ? "" : "Check whether these datastore types are supported as principal or supplemental storage for your VCF domain.",
              affected: other.map { AffectedObject(kind: .datastore, id: $0.id, name: $0.name, detail: $0.type) })
        b.list("st.vmfs5", stArea, "VMFS 5 datastores", .warning, noun: "datastores",
               affected: datastores.filter { $0.type.lowercased() == "vmfs" && $0.majorVersion > 0 && $0.majorVersion < 6 }
                .map { AffectedObject(kind: .datastore, id: $0.id, name: $0.name, detail: "VMFS \($0.majorVersion)") },
               ready: "No VMFS 5 datastores", remediation: "Migrate VMs to VMFS 6 datastores; VMFS 5 is deprecated.")
        let iscsiOnly = hosts.filter { h in
            let types = inv.hbas.filter { $0.hostKey == h.id }.map { $0.type.lowercased() }
            return !types.isEmpty && types.contains { $0.contains("iscsi") } && !types.contains { $0.contains("fibre") || $0.contains("fc") }
        }
        if !iscsiOnly.isEmpty {
            b.add("st.iscsi", stArea, "Hosts using iSCSI storage", .info, "\(iscsiOnly.count) hosts",
                  remediation: "Check whether iSCSI is supported as principal storage for your target domain type.",
                  affected: iscsiOnly.map { $0.ref("iSCSI adapters only") })
        }
        let full = datastores.filter { $0.capacityMiB > 0 && $0.freePct < 10 }
        b.list("st.free", stArea, "Datastores below 10% free", .warning, noun: "datastores",
               affected: full.map { AffectedObject(kind: .datastore, id: $0.id, name: $0.name, detail: "\(Fmt.num($0.freePct, 1))% free") },
               ready: "All datastores have 10%+ free", remediation: "Upgrades and VM migrations need snapshot and staging space.")
        let dsByID = Dictionary(inv.datastores.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let localVMs = vms.filter { vm in vm.datastores.contains { dsByID[vm.vcenter.lowercased() + "|" + $0.lowercased()]?.isLocal == true } }
        b.list("st.local", stArea, "VMs on local datastores", .warning, noun: "VMs can't be live-migrated off their host",
               affected: localVMs.map { $0.ref($0.datastoreList) },
               ready: "No selected VMs on local storage", remediation: "Move them to shared storage or plan downtime while their host is upgraded.")

        // MARK: Virtual machines
        let vmArea = "Virtual machines"
        let runningVMs = vms.filter { $0.isRunning && !$0.isTemplate }
        b.list("vm.tools", vmArea, "VMware Tools installed and running", .warning, noun: "powered-on VMs",
               affected: runningVMs.filter { ["Not installed", "Not running"].contains($0.toolsDisplay) }.map { $0.ref("Tools \($0.toolsDisplay.lowercased())") },
               ready: "Tools runs on every powered-on VM", remediation: "Needed for graceful shutdown, heartbeats and guest operations during the upgrade.", total: runningVMs.count)
        b.list("vm.toolsold", vmArea, "VMware Tools up to date", .info, noun: "VMs",
               affected: vms.filter { $0.toolsDisplay == "Out of date" }.map { $0.ref("Tools \($0.toolsVersion)") },
               ready: "No out-of-date Tools", remediation: "Upgrade Tools after the hosts are on 9.0 (or set upgrade at power cycle).")
        b.list("vm.hw", vmArea, "Virtual hardware vmx-10 or newer", .warning, noun: "VMs",
               affected: vms.filter { $0.hwVersion > 0 && $0.hwVersion < 10 }.map { $0.ref(Lifecycle.hardwareLabel($0.hwVersion)) },
               ready: "All VMs are on vmx-10 or newer", remediation: "Upgrade VM compatibility (after Tools) and confirm the oldest version supported by ESXi 9.")
        b.list("vm.guest", vmArea, "Guest OS supported", .warning, noun: "VMs run an end-of-support guest OS",
               affected: vms.compactMap { vm in vm.os.endOfSupport.flatMap { $0 <= reportDate ? vm.ref("\(vm.os.name) — ended \(Fmt.date($0))") : nil } },
               ready: "No end-of-support guests", remediation: "Check the vSphere 9 guest OS compatibility guide; unsupported guests may run but aren't supported.")
        let legacyDev = vms.compactMap { vm -> AffectedObject? in
            var d: [String] = []
            let nics = vm.nics.map(\.adapter).filter { let a = $0.lowercased(); return a.contains("vmxnet2") || a == "vmxnet" || a.contains("flexible") || a.contains("vlance") || a.contains("pcnet") }
            if !nics.isEmpty { d.append(nics.joined(separator: ", ")) }
            if vm.disks.contains(where: { $0.controller.lowercased().contains("buslogic") }) { d.append("BusLogic controller") }
            return d.isEmpty ? nil : vm.ref(d.joined(separator: " · "))
        }
        b.list("vm.devices", vmArea, "Deprecated virtual devices", .warning, noun: "VMs", affected: legacyDev,
               ready: "No deprecated virtual devices", remediation: "Replace legacy NICs with VMXNET3 and BusLogic with LSI Logic SAS or PVSCSI.")
        let blockers = vms.compactMap { vm -> AffectedObject? in
            var r: [String] = []
            if vm.cdroms.contains(where: \.connected) { r.append("CD/DVD connected") }
            if vm.usbConnected > 0 { r.append("USB passthrough") }
            if vm.disks.contains(where: \.raw) { r.append("RDM") }
            if vm.disks.contains(where: \.isSharedWriter) { r.append("shared disk") }
            let ft = vm.ftState.lowercased()
            if !ft.isEmpty && ft != "notconfigured" && ft != "not configured" { r.append("Fault Tolerance") }
            if vm.latencySensitivity.lowercased() == "high" { r.append("latency sensitivity high") }
            return r.isEmpty || !vm.isRunning ? nil : vm.ref(r.joined(separator: ", "))
        }
        b.list("vm.mobility", vmArea, "Live-migration blockers", .warning, noun: "powered-on VMs may not vMotion during host remediation", affected: blockers,
               ready: "No vMotion blockers found", remediation: "Disconnect media / devices, or schedule downtime for these VMs while their host is upgraded.")
        b.list("vm.consolidate", vmArea, "Disk consolidation needed", .blocker, noun: "VMs",
               affected: vms.filter(\.consolidationNeeded).map { $0.ref("consolidation needed") },
               ready: "No VMs need consolidation", remediation: "Consolidate before upgrading.")
        b.list("vm.snapshots", vmArea, "Existing snapshots", .info, noun: "VMs have snapshots",
               affected: vms.filter { !$0.snapshots.isEmpty }.map { $0.ref("\($0.snapshots.count) snapshot(s), oldest \(Fmt.num($0.oldestSnapshotDays, 0)) days") },
               ready: "No snapshots", remediation: "Clean up snapshots before the upgrade window.")

        // MARK: Licensing
        let coreMin = max(Int(p.num("coreMin")), 1)
        let licensedCores = hosts.reduce(0) { $0 + $1.sockets * max(coreMin, $1.coresPerSocket) }
        let sockets = hosts.reduce(0) { $0 + $1.sockets }
        b.add("lic.cores", "Licensing", "VCF subscription cores", .info,
              "\(Fmt.int(licensedCores)) cores for \(sockets) CPUs on \(hosts.count) hosts (\(coreMin)-core minimum per CPU)",
              remediation: "Confirm current Broadcom licensing terms, including any per-order minimums.")

        let checks = b.checks
        let counts = Dictionary(grouping: checks, by: \.status).mapValues(\.count)
        let scored = checks.filter { $0.status != .info }
        let score = scored.isEmpty ? 100 : Double(scored.filter { $0.status == .ready }.count) / Double(scored.count) * 100

        var sections: [SolutionSection] = [
            .metrics("Summary", [
                SolutionMetric("In scope", "\(hosts.count) hosts", "\(real.count) clusters · \(vcenters.count) vCenter(s) · \(vms.count) VMs", symbol: "square.stack.3d.up"),
                SolutionMetric("Blockers", Fmt.int(counts[.blocker] ?? 0), "checks that must be fixed first", symbol: CheckStatus.blocker.symbol),
                SolutionMetric("Warnings", Fmt.int(counts[.warning] ?? 0), "checks to plan for", symbol: CheckStatus.warning.symbol),
                SolutionMetric("Ready", Fmt.int(counts[.ready] ?? 0), "checks passed", symbol: CheckStatus.ready.symbol),
                SolutionMetric("Readiness", Fmt.pct(score), "of scored checks pass", symbol: "gauge.with.dots.needle.67percent"),
                SolutionMetric("VCF cores", Fmt.int(licensedCores), "\(coreMin)-core minimum per CPU", symbol: "key"),
            ]),
            .checks("Readiness checks", checks),
        ]

        // Host readiness table
        let hostRows = hosts.sorted { ($0.cluster, $0.name) < ($1.cluster, $1.name) }.map { h -> [String] in
            let path = VCF9Readiness.upgradePath(VCF9Readiness.version(h.esxVersion), minUpdate: minU)
            let g = cpuGen[h.id]!
            let ntpOK = !h.ntpServers.isEmpty && h.ntpdRunning != false
            let worst = [path.0, cpuStatus(g, legacyStatus), ntpOK ? .ready : .blocker].min()!
            return [h.name, clusterByID[h.clusterKey]?.name ?? h.cluster, [h.vendor, h.model].filter { !$0.isEmpty }.joined(separator: " "),
                    g.name, "ESXi \(h.esxVersion)", ntpOK ? "OK" : "Missing", worst.label]
        }
        sections.append(.table(SolutionTable(
            id: "hosts", title: "Host readiness", columns: ["Host", "Cluster", "Hardware", "CPU generation", "ESXi", "NTP", "Status"], rows: hostRows,
            rowRefs: hosts.sorted { ($0.cluster, $0.name) < ($1.cluster, $1.name) }.map { AffectedObject(kind: .host, id: $0.id, name: $0.name) })))

        var genCounts: [String: Int] = [:]
        for h in hosts { genCounts[cpuGen[h.id]!.name, default: 0] += 1 }
        sections.append(.bars("Hosts by CPU generation", "", genCounts.map { CountItem(label: $0.key, count: $0.value, value: Double($0.value)) }.sorted { $0.count > $1.count }, .count))

        sections.append(.notes("About these checks", [
            "Scope: every host in the clusters that run the selected VMs, their vCenter(s) and datastores, plus VM-level checks on the selected VMs.",
            "Upgrade paths, CPU generations and minimums are built-in defaults (editable under Assumptions and in VCF9Readiness.swift) — confirm them against Broadcom's upgrade matrix, VCF 9 release notes and the Broadcom Compatibility Guide.",
            "RVTools can't see firmware, NIC/HBA driver versions, boot mode, NSX version or licensing assignments; review those separately.",
        ]))

        let headline = "\(hosts.count) hosts in \(real.count) clusters · \(counts[.blocker] ?? 0) blockers · \(counts[.warning] ?? 0) warnings · \(Fmt.pct(score)) of checks ready"
        return SolutionResult(headline: headline, sections: sections)
    }
}
