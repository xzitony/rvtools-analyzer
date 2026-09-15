import RVToolsCore
import SwiftUI

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "findings"

    var body: some View {
        TabView(selection: $tab) {
            FindingsSettingsView()
                .tabItem { Label("Findings", systemImage: "exclamationmark.triangle") }
                .tag("findings")
            UnitsSettingsView()
                .tabItem { Label("Units", systemImage: "ruler") }
                .tag("units")
            SolutionsSettingsView()
                .tabItem { Label("Solutions", systemImage: "puzzlepiece.extension") }
                .tag("solutions")
            PriceListsSettingsView()
                .tabItem { Label("Price Lists", systemImage: "dollarsign.circle") }
                .tag("prices")
        }
        .frame(width: 640, height: 600)
    }
}

private struct UnitsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Storage") {
                Picker("Capacity", selection: $model.storageUnits) {
                    ForEach(StorageUnits.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Datastores, disks, VM and guest storage, snapshots, solution results and CSV exports. RVTools reports capacity in MiB, as vSphere calculates it; decimal units convert it (1 GiB = 1.074 GB, 1 TiB = 1.1 TB).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Network") {
                Picker("Rates", selection: $model.rateUnits) {
                    ForEach(RateUnits.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Physical NIC speeds, replication bandwidth and backup network rates (1 Gbps = 125 MB/s).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text("Memory is always shown in binary units (MiB, GiB), because RAM is sized in powers of two. Solution assumptions keep the unit shown beside them, and custom solutions that price per GB or TB keep the units their pricing uses.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FindingsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Snapshots") {
                field("Flag snapshots older than", $model.thresholds.snapshotAgeDays, "days")
                field("Flag snapshots larger than", $model.thresholds.snapshotSizeGiB, "GiB")
            }
            Section("Datastores") {
                field("Warning below free space", $model.thresholds.datastoreFreeWarnPct, "%")
                field("Critical below free space", $model.thresholds.datastoreFreeCritPct, "%")
                field("Overcommit above provisioned", $model.thresholds.datastoreOvercommitPct, "%")
            }
            Section("Hosts & clusters") {
                field("Host CPU usage above", $model.thresholds.hostCPUWarnPct, "%")
                field("Host memory usage above", $model.thresholds.hostMemWarnPct, "%")
                field("vCPU : core ratio above", $model.thresholds.vcpuPerCoreWarn, ": 1")
                field("Host uptime longer than", $model.thresholds.hostUptimeDays, "days")
                field("Certificate expires within", $model.thresholds.certExpiryDays, "days")
                field("License expires within", $model.thresholds.licenseExpiryDays, "days")
            }
            Section("Guests") {
                field("Guest partition free below", $model.thresholds.guestFreeWarnPct, "%")
            }
            Section("Local datastores") {
                Toggle("Ignore local datastores with no VM files", isOn: $model.thresholds.ignoreUnusedLocalDatastores)
                Text("Host-local datastores that hold no VMs, templates or VM disks — usually ESXi boot or scratch devices — are left out of capacity totals, findings, charts, exports and solutions. Local datastores that VMs use always count.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                HStack {
                    Text("Findings recalculate immediately.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { model.thresholds = Thresholds() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func field(_ label: String, _ value: Binding<Double>, _ unit: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", value: value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text(unit).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            }
        }
    }
}
