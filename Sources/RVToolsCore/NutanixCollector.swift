import Foundation

/// Nutanix Collector, run against a vCenter, exports much the same vSphere inventory RVTools does under different tab
/// and column names. This turns a Collector workbook into RVTools-shaped tables, so everything downstream reads it
/// unchanged. What Collector doesn't gather (vCenter identity, HA/DRS, EVC, VM folders, NTP/DNS, certificates…) is
/// simply absent, and the usual fallbacks and data-confidence notes apply.
///
/// An anonymized export replaces names, IPs, MACs and paths with tokens such as `NTNX-VM-12-1a2b3c4d`; the mapping
/// workbook Collector writes alongside it (one "Mapping" sheet: Anonymized Value → Original Value) restores them when
/// both are opened together.
enum NutanixCollector {
    static let tool = "Nutanix Collector"

    static func isCollector(_ raws: [RawTable]) -> Bool {
        guard let meta = raws.first(where: { $0.name.caseInsensitiveCompare("Metadata") == .orderedSame }) else { return false }
        return meta.headers.contains { Table.normalize($0) == "collectorversion" }
    }

    static func isMapping(_ raws: [RawTable]) -> Bool {
        guard raws.count == 1, let t = raws.first else { return false }
        let h = Set(t.headers.map(Table.normalize))
        return h.contains("anonymizedvalue") && h.contains("originalvalue")
    }

    static func mapping(_ raws: [RawTable]) -> [String: String] {
        guard let t = raws.first else { return [:] }
        let names = t.headers.map(Table.normalize)
        guard let a = names.firstIndex(of: "anonymizedvalue"), let o = names.firstIndex(of: "originalvalue") else { return [:] }
        var out: [String: String] = [:]
        for r in t.rows where !r.s(a).isEmpty { out[r.s(a)] = r.s(o) }
        return out
    }

    /// Files Collector wrote alongside the given ones that weren't opened with them: the export for a mapping file,
    /// and the mapping file for an anonymized export. Paired by the timestamp in their names
    /// ("ntnxcollector_anon_2026_9_18_9_35_59.xlsx" ↔ "ntnxcollector_mapping_2026_9_18_9_35_59.xlsx").
    static func companions(of files: [URL]) -> [URL] {
        let mappingPrefix = "ntnxcollector_mapping_", anonPrefix = "ntnxcollector_anon_"
        let opened = Set(files.map { $0.standardizedFileURL.path })
        var out: [URL] = []
        func add(_ dir: URL, _ name: String) {
            let url = dir.appendingPathComponent(name).standardizedFileURL
            if !opened.contains(url.path), !out.contains(url), FileManager.default.fileExists(atPath: url.path) { out.append(url) }
        }
        for file in files where file.pathExtension.lowercased() == "xlsx" {
            let name = file.lastPathComponent, dir = file.deletingLastPathComponent()
            if name.lowercased().hasPrefix(mappingPrefix) {
                let stamp = name.dropFirst(mappingPrefix.count)
                let exportOpened = files.contains { $0.lastPathComponent.lowercased().hasPrefix("ntnxcollector_") && !$0.lastPathComponent.lowercased().hasPrefix(mappingPrefix) && $0.lastPathComponent.hasSuffix(stamp) }
                if !exportOpened { add(dir, anonPrefix + stamp) }
            } else if name.lowercased().hasPrefix(anonPrefix) {
                add(dir, mappingPrefix + name.dropFirst(anonPrefix.count))
            }
        }
        return out
    }

    struct Result {
        var tables: [RawTable]
        var version: String
        var collected: Date?
        var warnings: [String]
    }

    static func translate(_ raws: [RawTable], mapping: [String: String], file: String) -> Result {
        var warnings: [String] = []
        var src = raws
        let meta = Sheet(src.first { $0.name.caseInsensitiveCompare("Metadata") == .orderedSame })
        let anonymized = meta.rows.first.map { Parse.bool(meta.value($0, "Is Anonymized")) ?? false } ?? false
        if anonymized {
            var restored = 0, cells = 0
            for t in src.indices {
                for r in src[t].rows.indices {
                    for c in src[t].rows[r].indices {
                        let v = src[t].rows[r][c]
                        guard v.contains("NTNX-") else { continue }
                        cells += 1
                        if let o = deanonymize(v, mapping) { src[t].rows[r][c] = o; restored += 1 }
                    }
                }
            }
            if mapping.isEmpty {
                warnings.append("\(file) is anonymized: names, IPs and paths show as NTNX-… tokens. Open its ntnxcollector_mapping file with it to see the real names.")
            } else if restored < cells {
                warnings.append("\(file): \(Fmt.int(cells - restored)) anonymized value(s) weren't in the mapping file and still show as NTNX-… tokens")
            }
        }

        func sheet(_ name: String) -> Sheet { Sheet(src.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }) }
        let dcSheet = sheet("vDataCenter"), clusterSheet = sheet("vCluster"), hostSheet = sheet("vHosts")
        let info = sheet("vInfo"), list = sheet("vmList"), cpu = sheet("vCPU"), mem = sheet("vMemory")
        let disk = sheet("vDisk"), net = sheet("vNetwork")

        // Collector doesn't record which vCenter it read. Stand in with the datacenter name(s): stable across
        // collections of the same vCenter (so Compare Snapshots lines them up) and distinct between vCenters.
        var dcByMOID: [String: String] = [:]
        for r in dcSheet.rows { dcByMOID[dcSheet.value(r, "MOID")] = dcSheet.value(r, "Datacenter Name") }
        var dcNames = Set(dcByMOID.values.filter { !$0.isEmpty })
        if dcNames.isEmpty { dcNames = Set((info.rows.map { info.value($0, "Datacenter Name") } + list.rows.map { list.value($0, "Datacenter Name") }).filter { !$0.isEmpty }) }
        let server = dcNames.isEmpty ? tool : dcNames.sorted().joined(separator: " + ")

        var out: [RawTable] = []
        func emit(_ name: String, _ from: Sheet, _ columns: [(String, ([String]) -> String)]) {
            guard from.exists else { return }
            let cols = [("VI SDK Server", { (_: [String]) in server })] + columns
            out.append(RawTable(name: name, headers: cols.map(\.0), rows: from.rows.map { r in cols.map { $0.1(r) } }))
        }
        func f(_ s: Sheet, _ names: String...) -> ([String]) -> String {
            let c = names.lazy.compactMap { s.col($0) }.first
            return { $0.s(c) }
        }
        func date(_ s: Sheet, _ names: String...) -> ([String]) -> String {
            let c = names.lazy.compactMap { s.col($0) }.first
            return { cleanDate($0.s(c)) }
        }

        // MARK: Hosts and clusters

        var clusterDC: [String: String] = [:]
        for r in clusterSheet.rows { clusterDC[clusterSheet.value(r, "MOID")] = dcByMOID[clusterSheet.value(r, "Datacenter")] ?? "" }
        emit("vCluster", clusterSheet, [("Name", f(clusterSheet, "Cluster Name"))])
        emit("vHost", hostSheet, [
            ("Host", f(hostSheet, "Host Name")),
            ("Datacenter", { clusterDC[hostSheet.value($0, "Cluster")] ?? "" }),
            ("Cluster", f(hostSheet, "Cluster Name")),
            ("in Maintenance Mode", f(hostSheet, "Maintenance Mode")),
            ("CPU Model", f(hostSheet, "CPU Model")),
            ("Speed", f(hostSheet, "CPU Speed")),
            ("# CPU", f(hostSheet, "CPUs")),
            ("Cores per CPU", f(hostSheet, "Cores per CPU")),
            ("# Cores", f(hostSheet, "CPU Cores")),
            ("CPU usage %", f(hostSheet, "CPU Usage")),
            // Collector reports host memory in GiB; RVTools in MiB.
            ("# Memory", { r in hostSheet.number(r, "Memory Size").map { plain($0 * 1024) } ?? "" }),
            ("Memory usage %", f(hostSheet, "Memory Usage")),
            ("# NICs", f(hostSheet, "NICs")),
            ("# VMs total", f(hostSheet, "VMs")),
            ("ESX Version", f(hostSheet, "Hypervisor")),
            ("Vendor", f(hostSheet, "Vendor")),
            ("Model", f(hostSheet, "Model")),
            ("Serial number", f(hostSheet, "Service Tag")),
            ("BIOS Version", f(hostSheet, "BIOS")),
        ])

        // MARK: VMs

        // vInfo carries identity and configuration; size comes from vCPU, vMemory and vmList, NIC and disk counts from
        // their tabs. Older Collector versions may only have vmList, so it stands in for vInfo when that's missing.
        let base = info.exists ? info : list
        func byMOID(_ s: Sheet, _ key: String) -> [String: [String]] {
            var out: [String: [String]] = [:]
            for r in s.rows where out[s.value(r, key)] == nil { out[s.value(r, key)] = r }
            return out
        }
        let cpuByVM = byMOID(cpu, "MOID"), memByVM = byMOID(mem, "MOID")
        var listByName: [String: [String]] = [:]
        for r in list.rows { listByName[(list.value(r, "VM Name") + "\u{1}" + list.value(r, "Host")).lowercased()] = r }
        var nicCount: [String: Int] = [:], diskCount: [String: Int] = [:], firstIP: [String: String] = [:], note: [String: String] = [:]
        for r in net.rows {
            let id = net.value(r, "VM ID")
            nicCount[id, default: 0] += 1
            if firstIP[id] == nil, let ip = Parse.list(net.value(r, "IPV4 Address")).first(where: { $0.contains(".") }) { firstIP[id] = ip }
            let a = net.value(r, "Annotation").trimmingCharacters(in: .whitespacesAndNewlines)
            if note[id] == nil, !a.isEmpty { note[id] = a }
        }
        for r in disk.rows { diskCount[disk.value(r, "MOID"), default: 0] += 1 }
        func listRow(_ r: [String]) -> [String]? { listByName[(base.value(r, "VM Name") + "\u{1}" + base.value(r, "Host Name", "Host")).lowercased()] }

        // Annotation goes last: RVTools puts custom attributes between Annotation and Datacenter, and nothing here is one.
        emit("vInfo", base, [
            ("VM", f(base, "VM Name")),
            ("Powerstate", f(base, "Power State")),
            ("Template", f(base, "Template")),
            ("Connection state", f(base, "Connection state")),
            ("CPUs", { r in cpu.opt(cpuByVM[base.value(r, "MOID")], "vCPUs") ?? listRow(r).flatMap { list.opt($0, "vCPUs") } ?? "" }),
            ("Memory", { r in mem.opt(memByVM[base.value(r, "MOID")], "Size (MiB)") ?? listRow(r).flatMap { list.opt($0, "Memory (MiB)") } ?? "" }),
            ("NICs", { r in nicCount[base.value(r, "MOID")].map(String.init) ?? "" }),
            ("Disks", { r in diskCount[base.value(r, "MOID")].map(String.init) ?? "" }),
            ("Primary IP Address", { r in firstIP[base.value(r, "MOID")] ?? "" }),
            ("Resource pool", f(base, "Resource pool")),
            ("FT State", f(base, "FT State")),
            ("Firmware", f(base, "Firmware")),
            ("HW version", f(base, "HW version")),
            ("EFI Secure boot", f(base, "EFI Secure boot")),
            ("CBT", f(base, "CBT")),
            ("Overall Cpu Readiness", { r in cpu.opt(cpuByVM[base.value(r, "MOID")], "CPU Readiness 95th Percentile %") ?? "" }),
            ("OS according to the configuration file", f(base, "Guest OS")),
            ("Datacenter", f(base, "Datacenter Name")),
            ("Cluster", f(base, "Cluster Name")),
            ("Host", f(base, "Host Name", "Host")),
            ("VM ID", f(base, "MOID")),
            ("VM UUID", f(base, "UUID")),
            ("Annotation", { r in note[base.value(r, "MOID")] ?? "" }),
        ])
        if info.col("Tool Status") != nil {
            emit("vTools", info, [("VM", f(info, "VM Name")), ("VM ID", f(info, "MOID")), ("VM UUID", f(info, "UUID")), ("Tools", f(info, "Tool Status"))])
        }
        emit("vCPU", cpu, [
            ("VM", f(cpu, "VM Name")), ("VM ID", f(cpu, "MOID")), ("VM UUID", f(cpu, "UUID")),
            ("CPUs", f(cpu, "vCPUs")), ("Overall", f(cpu, "Overall CPU (MHz)")),
            ("Reservation", f(cpu, "Reservation")), ("Limit", f(cpu, "Limit")),
        ])
        emit("vMemory", mem, [
            ("VM", f(mem, "VM Name")), ("VM ID", f(mem, "MOID")), ("VM UUID", f(mem, "UUID")),
            ("Size MiB", f(mem, "Size (MiB)")), ("Reservation", f(mem, "Reservation")), ("Limit", f(mem, "Limit")),
            // vCenter's memory usage counter is active memory; Collector reports its 95th percentile as a % of size.
            ("Active", { r in
                guard let size = mem.number(r, "Size (MiB)"), let pct = mem.number(r, "95th Percentile % (recommended)") else { return "" }
                return plain(size * pct / 100)
            }),
        ])
        emit("vDisk", disk, [
            ("VM", f(disk, "VM Name")), ("VM ID", f(disk, "MOID")), ("VM UUID", f(disk, "UUID")),
            ("Disk", f(disk, "Disk Name")), ("Capacity MiB", f(disk, "Capacity (MiB)")), ("Raw", f(disk, "Raw")),
            ("Disk Mode", f(disk, "Disk Mode")), ("Sharing mode", f(disk, "Sharing mode")), ("Thin", f(disk, "Thin Provisioned")),
            ("Controller", f(disk, "Controller")), ("Shared Bus", f(disk, "Shared Bus")),
            // Keep the datastore even when the path is still an anonymized token.
            ("Path", { r in
                let p = disk.value(r, "Path"), ds = disk.value(r, "Datastore Name")
                return p.hasPrefix("[") || ds.isEmpty ? p : "[\(ds)] \(p)"
            }),
        ])
        let part = sheet("vPartition")
        emit("vPartition", part, [
            ("VM", f(part, "VM Name")), ("VM ID", f(part, "MOID")), ("VM UUID", f(part, "UUID")),
            ("Disk", f(part, "Path")), ("Capacity MiB", f(part, "Capacity (MiB)")), ("Consumed MiB", f(part, "Consumed (MiB)")),
            ("Free MiB", { r in
                guard let cap = part.number(r, "Capacity (MiB)") else { return "" }
                return plain(max(0, cap - (part.number(r, "Consumed (MiB)") ?? 0)))
            }),
        ])
        emit("vNetwork", net, [
            ("VM", f(net, "VM Name")), ("VM ID", f(net, "VM ID")), ("VM UUID", f(net, "VM UUID")),
            ("NIC label", f(net, "NIC Label")), ("Adapter", f(net, "Adapter")), ("Network", f(net, "Network")),
            ("Switch", f(net, "vSwitch")), ("Connected", f(net, "Connection Status")), ("Starts Connected", f(net, "Starts Connected")),
            ("Mac Address", f(net, "MAC Address")), ("IPv4 Address", f(net, "IPV4 Address")), ("IPv6 Address", f(net, "IPV6 Address")),
        ])
        let snap = sheet("vSnapshot")
        emit("vSnapshot", snap, [
            ("VM", f(snap, "VM Name")), ("VM ID", f(snap, "MOID")), ("VM UUID", f(snap, "UUID")),
            ("Name", f(snap, "Snapshot Name")), ("Description", f(snap, "Description")), ("Date / time", date(snap, "Creation Time")),
            ("Size MiB (total)", f(snap, "Size MiB (total)")), ("Size MiB (vmsn)", f(snap, "Size MiB (vmsn)")),
        ])

        // MARK: Storage

        let dsSheet = sheet("Datastore")
        emit("vDatastore", dsSheet, [
            ("Name", f(dsSheet, "Datastore Name")), ("Accessible", f(dsSheet, "Accessible")), ("Type", f(dsSheet, "Datastore Type")),
            ("# VMs total", f(dsSheet, "VM Count")), ("Capacity MiB", f(dsSheet, "Capacity (MiB)")),
            ("In Use MiB", f(dsSheet, "Consumed (MiB)")), ("Free MiB", f(dsSheet, "Freespace (MiB)", "Free Space (MiB)")),
            ("Free %", { r in
                guard let cap = dsSheet.number(r, "Capacity (MiB)"), cap > 0, let free = dsSheet.number(r, "Freespace (MiB)", "Free Space (MiB)") else { return "" }
                return plain(free / cap * 100)
            }),
            ("Hosts", { r in Parse.list(dsSheet.value(r, "Host Names")).joined(separator: ", ") }),
            ("URL", f(dsSheet, "URL")),
        ])
        let mp = sheet("vMultipath")
        emit("vMultiPath", mp, [("Host", f(mp, "Host")), ("Disk", f(mp, "Disk")), ("Display name", f(mp, "Name")),
                                ("Vendor", { mp.value($0, "Vendor").trimmingCharacters(in: .whitespaces) }),
                                ("Model", { mp.value($0, "Model").trimmingCharacters(in: .whitespaces) })])
        let hba = sheet("vHBA")
        emit("vHBA", hba, [("Host", f(hba, "Host")), ("Device", f(hba, "Device")), ("Type", f(hba, "Type")), ("Status", f(hba, "Status")),
                           ("Model", f(hba, "Model")), ("Driver", f(hba, "Driver")), ("WWN", f(hba, "WWN"))])

        // MARK: Networking

        let nic = sheet("vNICs")
        emit("vNIC", nic, [("Host", f(nic, "Host")), ("Network Device", f(nic, "Network Device")), ("Driver", f(nic, "Drivers", "Driver")),
                           ("Speed", f(nic, "Speed (Mbps)")), ("Duplex", f(nic, "Duplex")), ("MAC", f(nic, "MAC Address")), ("Switch", f(nic, "Switch"))])
        let sw = sheet("vSwitch")
        emit("vSwitch", sw, [("Host", f(sw, "Host")), ("Switch", f(sw, "Switch Name")), ("# Ports", f(sw, "Ports Count")),
                             ("Free Ports", f(sw, "Available Ports Count")), ("Promiscuous Mode", f(sw, "Promiscuous Mode")),
                             ("Mac Changes", f(sw, "MAC Changes")), ("Forged Transmits", f(sw, "Forged Transmits")),
                             ("Policy", f(sw, "Policy")), ("MTU", f(sw, "MTU (Bytes)"))])
        let pg = sheet("vPort")
        emit("vPort", pg, [("Host", f(pg, "Host")), ("Port Group", f(pg, "Port Group")), ("Switch", f(pg, "vSwitch")), ("VLAN", f(pg, "VLAN ID")),
                           ("Promiscuous Mode", f(pg, "Promiscuous Mode")), ("Mac Changes", f(pg, "MAC Changes")),
                           ("Forged Transmits", f(pg, "Forged Transmits")), ("Policy", f(pg, "Policy"))])
        let dvs = sheet("dvSwitch")
        emit("dvSwitch", dvs, [("Switch", f(dvs, "dvSwitch")), ("Name", f(dvs, "dvSwitch")), ("Datacenter", f(dvs, "Datacenter Name")),
                               ("Version", f(dvs, "Version")), ("Host members", f(dvs, "Host Members")), ("# Ports", f(dvs, "# of Ports")),
                               ("# VMs", f(dvs, "# of VMs")), ("Max MTU", f(dvs, "Max MTU (Bytes)")), ("LACP Mode", f(dvs, "LACP Mode"))])
        let dvp = sheet("dvPort")
        emit("dvPort", dvp, [("Port", f(dvp, "Port")), ("Switch", f(dvp, "Switch")), ("VLAN", f(dvp, "VLAN ID(s)")),
                             ("Allow Promiscuous", f(dvp, "Allow Promiscuous")), ("Mac Changes", f(dvp, "Mac Changes")),
                             ("Forged Transmits", f(dvp, "Forged Transmits"))])

        let lic = sheet("vLicense")
        // "Expiry Date" is left out: Collector writes the same past date on every license, including ones still in use.
        emit("vLicense", lic, [("Name", f(lic, "Name")), ("Key", f(lic, "License Key")), ("Total", f(lic, "Total")), ("Used", f(lic, "Used")),
                               ("Cost Unit", f(lic, "Cost Unit"))])

        let version = meta.rows.first.map { meta.value($0, "Collector Version") } ?? ""
        let collected = meta.rows.first.flatMap { Parse.date(cleanDate(meta.value($0, "Collection Date & Time"))) }
        if let mode = meta.rows.first.map({ meta.value($0, "Hypervisor") }), !mode.isEmpty, mode.lowercased() != "vcenter" {
            warnings.append("\(file) was collected from \(mode), not vCenter; only tabs that match the vCenter layout were read")
        }
        return Result(tables: out, version: version, collected: collected, warnings: warnings)
    }

    /// Numbers written back as cells: no grouping, no trailing ".0".
    static func plain(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(format: "%.2f", v)
    }

    /// A whole-cell token, or a comma-separated list of them (datastore host lists).
    static func deanonymize(_ v: String, _ mapping: [String: String]) -> String? {
        if let o = mapping[v] { return o }
        guard v.contains(",") else { return nil }
        let parts = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let mapped = parts.compactMap { mapping[$0] }
        return mapped.count == parts.count ? mapped.joined(separator: ",") : nil
    }

    /// "2026-09-18 13:35:45 UTC" / "2026-08-04 11:52:34+00:00" → "2026-09-18 13:35:45"
    static func cleanDate(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(" UTC") { t.removeLast(4) }
        if let r = t.range(of: #"[+-]00:?00$"#, options: .regularExpression) { t.removeSubrange(r) }
        return t
    }

    /// Header lookup over a raw Collector sheet, tolerant of the same spelling drift as `Table`.
    struct Sheet {
        let exists: Bool
        let rows: [[String]]
        private let lookup: [String: Int]

        init(_ raw: RawTable?) {
            exists = raw != nil
            rows = raw?.rows ?? []
            var l: [String: Int] = [:]
            for (i, h) in (raw?.headers ?? []).enumerated() where l[Table.normalize(h)] == nil { l[Table.normalize(h)] = i }
            lookup = l
        }

        func col(_ name: String) -> Int? { lookup[Table.normalize(name)] }
        func value(_ r: [String], _ names: String...) -> String {
            for n in names { if let c = col(n) { return r.s(c) } }
            return ""
        }
        func opt(_ r: [String]?, _ name: String) -> String? {
            guard let r else { return nil }
            let v = value(r, name)
            return v.isEmpty ? nil : v
        }
        func number(_ r: [String], _ names: String...) -> Double? {
            for n in names { if let c = col(n) { return r.d(c) } }
            return nil
        }
    }
}
