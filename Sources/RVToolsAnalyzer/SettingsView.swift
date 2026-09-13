import RVToolsCore
import SwiftUI

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "findings"

    var body: some View {
        TabView(selection: $tab) {
            FindingsSettingsView()
                .tabItem { Label("Findings", systemImage: "exclamationmark.triangle") }
                .tag("findings")
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

private struct FindingsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Snapshots") {
                field("Flag snapshots older than", $model.thresholds.snapshotAgeDays, "days")
                field("Flag snapshots larger than", $model.thresholds.snapshotSizeGiB, "GB")
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
            }
            Section("Guests") {
                field("Guest partition free below", $model.thresholds.guestFreeWarnPct, "%")
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
