import Foundation

/// Flat CSV exports of the correlated data (open in Excel / feed to other tools).
public enum CSVExport {
    static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static func build(_ header: [String], _ rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func gb(_ mib: Double) -> String { String(format: "%.1f", mib / 1024) }

    public static func findings(_ r: Report) -> String {
        let recs = Dictionary(r.groups.map { ($0.rule, $0.recommendation) }, uniquingKeysWith: { a, _ in a })
        return build(["Severity", "Category", "Finding", "Object type", "Object", "Location", "Detail", "Recommendation"],
                     r.findings.sorted { ($0.severity.rawValue, $0.title, $0.objectName) < ($1.severity.rawValue, $1.title, $1.objectName) }.map {
                         [$0.severity.label, $0.category.rawValue, $0.title, $0.kind.rawValue, $0.objectName, $0.location, $0.detail, recs[$0.rule] ?? ""]
                     })
    }

    public static func vms(_ r: Report) -> String {
        build(["VM", "Power", "Template", "vCenter", "Datacenter", "Cluster", "Host", "Folder", "Guest OS", "OS family", "OS end of support",
               "vCPU", "Sockets", "Cores/socket", "Memory GB", "Provisioned GB", "In use GB", "Guest capacity GB", "Guest used GB",
               "Disks", "Datastores", "NICs", "Networks", "IPs", "HW version", "Firmware", "Tools", "Tools version",
               "Snapshots", "Snapshot GB", "Oldest snapshot days", "Created", "Issues", "Annotation"],
              r.inventory.vms.map { v in
                  [v.name, v.powerState.rawValue, v.isTemplate ? "Yes" : "No", v.vcenter, v.datacenter, v.cluster, v.host, v.folder,
                   v.os.name, v.os.family.rawValue, Fmt.date(v.os.endOfSupport), "\(v.cpus)", "\(v.sockets)", "\(v.coresPerSocket)",
                   gb(v.memoryMiB), gb(v.provisionedMiB), gb(v.inUseMiB), gb(v.guestCapacityMiB), gb(v.guestConsumedMiB),
                   "\(v.disks.count)", v.datastoreList, "\(v.nics.count)", v.networkList, v.ips.joined(separator: " "),
                   v.hwVersion > 0 ? "vmx-\(v.hwVersion)" : "", v.firmware, v.toolsDisplay, v.toolsVersion,
                   "\(v.snapshots.count)", gb(v.snapshotSizeMiB), Fmt.num(v.oldestSnapshotDays, 0), Fmt.date(v.creationDate), "\(v.issueCount)", v.annotation]
              })
    }

    public static func hosts(_ r: Report) -> String {
        build(["Host", "vCenter", "Datacenter", "Cluster", "Vendor", "Model", "CPU model", "Sockets", "Cores", "Threads", "Memory GB",
               "CPU usage %", "Memory usage %", "VMs", "VMs on", "vCPU (on)", "vCPU:core", "vRAM on GB", "ESXi", "Build", "Maintenance",
               "pNICs", "HBAs", "VMkernels", "LUN paths", "Datastores", "Uptime days", "Issues"],
              r.inventory.hosts.map { h in
                  [h.name, h.vcenter, h.datacenter, h.cluster, h.vendor, h.model, h.cpuModel, "\(h.sockets)", "\(h.cores)", "\(h.threads)",
                   gb(h.memoryMiB), Fmt.num(h.cpuUsagePct, 0), Fmt.num(h.memUsagePct, 0), "\(h.vmCount)", "\(h.vmsOn)", "\(h.vcpuOn)",
                   Fmt.num(h.vcpuPerCore, 2), gb(h.vramOnMiB), h.esxVersion, h.esxBuild, h.maintenance ? "Yes" : "No",
                   "\(h.pnicCount)", "\(h.hbaCount)", "\(h.vmkCount)", "\(h.lunCount)", "\(h.datastoreCount)", Fmt.num(h.uptimeDays ?? 0, 0), "\(h.issueCount)"]
              })
    }

    public static func clusters(_ r: Report) -> String {
        build(["Cluster", "vCenter", "Datacenter", "Hosts", "Cores", "Memory GB", "VMs", "VMs on", "vCPU on", "vCPU:core", "vRAM on GB",
               "CPU usage %", "Memory usage %", "Memory % after losing largest host", "HA", "DRS", "Admission control", "Provisioned GB", "Issues"],
              r.inventory.clusters.map { c in
                  [c.name, c.vcenter, c.datacenter, "\(c.hostCount)", "\(c.cores)", gb(c.memoryMiB), "\(c.vmCount)", "\(c.vmsOn)", "\(c.vcpuOn)",
                   Fmt.num(c.vcpuPerCore, 2), gb(c.vramOnMiB), Fmt.num(c.cpuUsagePct, 0), Fmt.num(c.memUsagePct, 0),
                   c.memPctAfterHostLoss.isFinite ? Fmt.num(c.memPctAfterHostLoss, 0) : "", c.haEnabled.map { $0 ? "On" : "Off" } ?? "",
                   c.drsEnabled.map { $0 ? "On" : "Off" } ?? "", c.admissionControl.map { $0 ? "On" : "Off" } ?? "", gb(c.provisionedMiB), "\(c.issueCount)"]
              })
    }

    public static func datastores(_ r: Report) -> String {
        build(["Datastore", "vCenter", "Type", "Capacity GB", "Used GB", "Free GB", "Free %", "Provisioned GB", "Provisioned %",
               "VMs", "Hosts", "Clusters", "Local", "Issues"],
              r.inventory.datastores.map { d in
                  [d.name, d.vcenter, d.type, gb(d.capacityMiB), gb(d.capacityMiB - d.freeMiB), gb(d.freeMiB), Fmt.num(d.freePct, 1),
                   gb(d.provisionedMiB), Fmt.num(d.provisionedPct, 0), "\(d.vmCount)", "\(d.hostNames.count)", d.clusterList,
                   d.isLocal ? "Yes" : "No", "\(d.issueCount)"]
              })
    }
}
