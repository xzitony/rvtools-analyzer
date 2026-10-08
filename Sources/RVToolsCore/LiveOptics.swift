import Foundation

/// Dell Live Optics (Optical Prime) VMware workbooks carry a slimmer vSphere inventory than RVTools — one row per host,
/// VM, guest partition and host storage device — plus per-VM and per-host performance. This turns one into RVTools-shaped
/// tables, like `NutanixCollector`, so everything downstream reads it unchanged. Column meanings follow Dell's
/// "Optical Prime VMware Excel Definitions".
///
/// What Live Optics doesn't gather (vCenter name, VM networks and NICs, virtual disks, snapshots, HA/DRS, EVC, NTP/DNS,
/// VM folders, port groups…) is simply absent, and the usual fallbacks and data-confidence notes apply.
enum LiveOptics {
    static let tool = "Live Optics"
    typealias Sheet = NutanixCollector.Sheet

    static func isLiveOptics(_ raws: [RawTable]) -> Bool {
        guard let details = raws.first(where: { $0.name.caseInsensitiveCompare("Details") == .orderedSame }),
              raws.contains(where: { $0.name.caseInsensitiveCompare("VMs") == .orderedSame }) else { return false }
        return Table.normalize(details.headers.first ?? "") == "projectid" || !detail(details, "Collector Build Version").isEmpty
    }

    /// Details is a two-column key/value sheet whose first pair lands in the header row.
    static func detail(_ t: RawTable, _ key: String) -> String {
        let k = Table.normalize(key)
        for r in [t.headers] + t.rows where r.count > 1 && Table.normalize(r[0]) == k { return r[1].trimmingCharacters(in: .whitespaces) }
        return ""
    }

    struct Result {
        var tables: [RawTable]
        var version: String
        var collected: Date?
        var warnings: [String]
    }

    static func translate(_ raws: [RawTable], file: String) -> Result {
        var warnings: [String] = []
        func sheet(_ name: String) -> Sheet { Sheet(raws.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }) }
        let hosts = sheet("ESX Hosts"), hostPerf = sheet("ESX Performance"), devices = sheet("Host Devices")
        let vms = sheet("VMs"), vmPerf = sheet("VM Performance"), parts = sheet("VM Disks"), lic = sheet("ESX Licenses")
        let pnics = sheet("Host Network Adapters"), attrs = sheet("Custom Attributes")

        // Live Optics' "vCenter" column is the vCenter *version*, never its name. Stand in with the datacenter name(s),
        // as for Nutanix Collector: stable across collections of the same vCenter and distinct between vCenters.
        let dcNames = Set((hosts.rows.map { hosts.value($0, "Datacenter") } + vms.rows.map { vms.value($0, "Datacenter") }).filter { !$0.isEmpty })
        let server = dcNames.isEmpty ? tool : dcNames.sorted().joined(separator: " + ")
        let vcVersions = Set((hosts.rows.map { hosts.value($0, "vCenter") } + vms.rows.map { vms.value($0, "vCenter") }).filter { !$0.isEmpty })

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
        func scaled(_ s: Sheet, _ name: String, _ factor: Double) -> ([String]) -> String {
            { r in s.number(r, name).map { NutanixCollector.plain($0 * factor) } ?? "" }
        }
        let plain = NutanixCollector.plain

        // MARK: vCenter

        if !vcVersions.isEmpty {
            // "VMware vCenter Server 8.0.3 build-25197330"
            let full = vcVersions.sorted().last!
            let version = full.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression).map { String(full[$0]) } ?? ""
            let build = full.range(of: #"build-(\d+)"#, options: .regularExpression).map { String(full[$0].dropFirst(6)) } ?? ""
            out.append(RawTable(name: "vSource", headers: ["VI SDK Server", "Fullname", "Version", "Build"], rows: [[server, full, version, build]]))
            if vcVersions.count > 1 {
                warnings.append("\(file) covers more than one vCenter (\(vcVersions.sorted().joined(separator: ", "))). Live Optics doesn't name them, so they're shown as one.")
            }
        }

        // MARK: Hosts

        func hostKey(_ s: String) -> String { s.lowercased() }
        var perfByHost: [String: [String]] = [:]
        for r in hostPerf.rows { perfByHost[hostKey(hostPerf.value(r, "Host", "Host Name"))] = r }
        var licByHost: [String: [String]] = [:]
        for r in lic.rows {
            let t = lic.value(r, "Software Title")
            if !t.isEmpty, !(licByHost[hostKey(lic.value(r, "ESX Host"))] ?? []).contains(t) { licByHost[hostKey(lic.value(r, "ESX Host")), default: []].append(t) }
        }
        emit("vHost", hosts, [
            ("Host", f(hosts, "Host Name", "Host-Name")),
            ("Datacenter", f(hosts, "Datacenter")),
            ("Cluster", f(hosts, "Cluster")),
            ("Config status", f(hosts, "Config Status")),
            ("CPU Model", f(hosts, "CPU Description")),
            ("Speed", scaled(hosts, "CPU Clock Speed (GHz)", 1000)),
            ("HT Active", { r in
                guard let t = hosts.number(r, "CPU Threads"), let c = hosts.number(r, "CPU Cores"), c > 0 else { return "" }
                return t > c ? "True" : "False"
            }),
            ("# CPU", f(hosts, "CPU Sockets")),
            ("Cores per CPU", { r in
                guard let c = hosts.number(r, "CPU Cores"), let s = hosts.number(r, "CPU Sockets"), s > 0 else { return "" }
                return plain(c / s)
            }),
            ("# Cores", f(hosts, "CPU Cores")),
            // Live Optics measures host CPU and memory use over the collection; RVTools has a point-in-time figure.
            ("CPU usage %", { r in perfByHost[hostKey(hosts.value(r, "Host Name", "Host-Name"))].map { hostPerf.value($0, "Average CPU %") } ?? "" }),
            ("# Memory", scaled(hosts, "Memory (KiB)", 1.0 / 1024)),
            ("Memory usage %", { r in perfByHost[hostKey(hosts.value(r, "Host Name", "Host-Name"))].map { hostPerf.value($0, "Average Memory %") } ?? "" }),
            ("# NICs", f(hosts, "Number of NICs")),
            ("# HBAs", f(hosts, "Number of HBAs")),
            ("Assigned License(s)", { r in (licByHost[hostKey(hosts.value(r, "Host Name", "Host-Name"))] ?? []).joined(separator: ", ") }),
            ("ESX Version", f(hosts, "OS")),
            ("Boot time", f(hosts, "Boot Time")),
            ("Vendor", f(hosts, "Manufacturer")),
            ("Model", f(hosts, "Model")),
            ("Serial number", f(hosts, "Serial No", "Serial No.")),
        ])
        let clusters = Array(Set(hosts.rows.map { hosts.value($0, "Cluster") }.filter { !$0.isEmpty })).sorted()
        if !clusters.isEmpty { out.append(RawTable(name: "vCluster", headers: ["VI SDK Server", "Name"], rows: clusters.map { [server, $0] })) }
        emit("vNIC", pnics, [("Host", f(pnics, "Host")), ("Network Device", f(pnics, "PNIC Name")),
                             ("Speed", f(pnics, "PNIC Speed (Mb/sec)", "PNIC Speed"))])

        // MARK: VMs

        // MOB IDs repeat between vCenters in one project, so a repeated one is dropped and the VM is keyed by its
        // instance UUID instead (the partitions tab carries both).
        var mobCount: [String: Int] = [:]
        for r in vms.rows { mobCount[vms.value(r, "MOB ID", "MOB_ID"), default: 0] += 1 }
        func vmID(_ s: Sheet) -> ([String]) -> String {
            { r in let id = s.value(r, "MOB ID", "MOB_ID"); return mobCount[id] == 1 ? id : "" }
        }
        func perfKey(_ s: Sheet, _ r: [String]) -> String { (s.value(r, "MOB ID", "MOB_ID") + "\u{1}" + s.value(r, "Host")).lowercased() }
        var perfByVM: [String: [String]] = [:]
        for r in vmPerf.rows { perfByVM[perfKey(vmPerf, r)] = r }

        // Custom attributes are keyed by VM name only; they become RVTools-style columns between Annotation and Datacenter.
        var attrNames: [String] = []
        var attrByVM: [String: [String: String]] = [:]
        for r in attrs.rows {
            let name = attrs.value(r, "Custom Attribute"), vm = attrs.value(r, "Guest VM Name").lowercased()
            guard !name.isEmpty, !vm.isEmpty else { continue }
            if !attrNames.contains(name) { attrNames.append(name) }
            attrByVM[vm, default: [:]][name] = attrs.value(r, "Custom Content")
        }
        let attrColumns: [(String, ([String]) -> String)] = attrNames.map { name in
            (name, { r in attrByVM[vms.value(r, "VM Name").lowercased()]?[name] ?? "" })
        }

        emit("vInfo", vms, [
            ("VM", f(vms, "VM Name")),
            ("Powerstate", f(vms, "Power State", "PowerState")),
            ("Template", f(vms, "Template")),
            ("Connection state", f(vms, "Connection State")),
            ("DNS Name", f(vms, "Guest Hostname")),
            ("PowerOn", f(vms, "Boot Time")),
            ("Creation date", f(vms, "Date Provisioned")),
            ("CPUs", f(vms, "Virtual CPU")),
            ("Memory", f(vms, "Provisioned Memory (MiB)")),
            ("NICs", f(vms, "NICs")),
            ("Disks", f(vms, "Disks")),
            ("Primary IP Address", f(vms, "Guest IP1")),
            ("Provisioned MiB", f(vms, "Virtual Disk Size (MiB)")),
            ("In Use MiB", f(vms, "Virtual Disk Used (MiB)")),
            ("Unshared MiB", f(vms, "Unshared (MiB)")),
            // Live Optics lists a VM's datastores but not its .vmx path; the first datastore stands in so the VM is
            // placed on it.
            ("Path", { r in Parse.list(vms.value(r, "Datastore")).first.map { "[\($0)]" } ?? "" }),
            // Reported by VMware Tools when it's running, otherwise vCenter's configured guest OS.
            ("OS according to the configuration file", f(vms, "VM OS")),
            ("Annotation", { _ in "" }),
        ] + attrColumns + [
            ("Datacenter", f(vms, "Datacenter")),
            ("Cluster", f(vms, "Cluster")),
            ("Host", f(vms, "Host")),
            ("VM ID", vmID(vms)),
            ("VM UUID", f(vms, "InstanceUUID", "Instance UUID")),
        ])
        emit("vTools", vms, [
            ("VM", f(vms, "VM Name")), ("VM ID", vmID(vms)), ("VM UUID", f(vms, "InstanceUUID", "Instance UUID")),
            ("Tools Version", f(vms, "VMware Tools Version")),
            // Blank when Tools isn't installed (per Dell's definitions); otherwise the status isn't reported.
            ("Tools", { r in vms.value(r, "VMware Tools Version").isEmpty && !(Parse.bool(vms.value(r, "Template")) ?? false) ? "toolsNotInstalled" : "" }),
        ])
        emit("vCPU", vms, [
            ("VM", f(vms, "VM Name")), ("VM ID", vmID(vms)), ("VM UUID", f(vms, "InstanceUUID", "Instance UUID")),
            ("CPUs", f(vms, "Virtual CPU")),
            ("Overall", { r in perfByVM[perfKey(vms, r)].flatMap { vmPerf.number($0, "Average vCPU (GHz)") }.map { plain($0 * 1000) } ?? "" }),
        ])
        emit("vMemory", vms, [
            ("VM", f(vms, "VM Name")), ("VM ID", vmID(vms)), ("VM UUID", f(vms, "InstanceUUID", "Instance UUID")),
            ("Size MiB", f(vms, "Provisioned Memory (MiB)")),
            ("Consumed", f(vms, "Consumed Memory (MiB)")),
            // Average active memory over the collection when VM performance was gathered, else the discovery-time figure.
            ("Active", { r in perfByVM[perfKey(vms, r)].map { vmPerf.value($0, "Avg Memory (MiB)") } ?? vms.value(r, "Used Memory (active) (MiB)") }),
        ])
        emit("vPartition", parts, [
            ("VM", f(parts, "VM Name")), ("VM ID", vmID(parts)), ("VM UUID", f(parts, "InstanceUUID", "Instance UUID")),
            ("Disk", f(parts, "Disk")), ("Capacity MiB", f(parts, "Capacity (MiB)")), ("Consumed MiB", f(parts, "Used (MiB)")),
            ("Free MiB", f(parts, "Free (MiB)")),
        ])

        // MARK: Datastores

        // Host Devices has one row per host and device; RVTools has one per datastore with its hosts listed.
        if devices.exists {
            var order: [String] = []
            var rows: [String: [String]] = [:], hostsOf: [String: [String]] = [:]
            for r in devices.rows {
                let name = devices.value(r, "Device Name"), lun = devices.value(r, "Lun Type").lowercased()
                guard !name.isEmpty, lun.isEmpty || lun == "disk" else { continue }
                if rows[name] == nil { order.append(name); rows[name] = r }
                let h = devices.value(r, "Server Name")
                if !h.isEmpty, !(hostsOf[name] ?? []).contains(h) { hostsOf[name, default: []].append(h) }
            }
            let gib = 1024.0
            out.append(RawTable(name: "vDatastore",
                                headers: ["VI SDK Server", "Name", "Type", "Capacity MiB", "In Use MiB", "Free MiB", "Free %", "Hosts"],
                                rows: order.map { name in
                let r = rows[name]!
                let cap = devices.number(r, "Capacity (GiB)") ?? 0, free = devices.number(r, "Free Capacity (GiB)") ?? 0
                let used = devices.number(r, "Used Capacity (GiB)") ?? max(0, cap - free)
                // Live Optics only says shared ("Cluster") or local; vSAN is recognisable by name.
                let type = name.lowercased().contains("vsan") ? "vsan" : (devices.value(r, "Device Type").lowercased() == "local" ? "Local" : "Shared")
                return [server, name, type, plain(cap * gib), plain(used * gib), plain(free * gib),
                        cap > 0 ? plain(free / cap * 100) : "", (hostsOf[name] ?? []).joined(separator: ", ")]
            }))
        }

        let version = raws.first { $0.name.caseInsensitiveCompare("Details") == .orderedSame }.map { detail($0, "Collector Build Version") } ?? ""
        let collected = raws.first { $0.name.caseInsensitiveCompare("Details") == .orderedSame }.flatMap { Parse.date(detail($0, "Date")) }
        if !vmPerf.exists {
            warnings.append("\(file) has no VM Performance tab, so VM CPU use and active memory are a single reading from the start of the collection")
        }
        return Result(tables: out, version: version, collected: collected, warnings: warnings)
    }
}
