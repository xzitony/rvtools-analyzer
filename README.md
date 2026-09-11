# RVTools Analyzer

A native macOS app (SwiftUI + Swift Charts) that ingests an **RVTools** export and correlates every tab into one object model of the vSphere estate. It then rolls the data up into dashboards for counts, capacity, utilization, configuration, lifecycle and health.

Everything runs locally and nothing leaves the Mac. There are no third-party dependencies: the `.xlsx` reader (ZIP + XML) is built in.

## Build & run

Requirements: macOS 14 or later and the Swift toolchain (Xcode or the Command Line Tools: `xcode-select --install`).

```bash
scripts/build-app.sh            # → build/RVTools Analyzer.app
open "build/RVTools Analyzer.app"
```

Drag the app to `/Applications` if you like. It is ad-hoc signed, so the first launch may need right-click › **Open**.

## Opening data

- **An RVTools `.xlsx` export** (`RVTools_export_all_*.xlsx`)
- **A folder of CSVs** from RVTools' *Export all to csv* (`RVTools_tabvInfo.csv`, …)
- **Several exports at once.** Drop multiple files or folders to merge vCenters into one view. Rows are keyed by `VI SDK Server`, so objects from different vCenters don't collide.

To open an export you can:
- drop it on the window,
- use **File › Open** (⌘O),
- use the Finder's **Open With**, or
- run `RVToolsAnalyzer <path>` from a shell.

**Try Sample Data** on the welcome screen loads a synthetic environment.

Ages are measured from the export timestamp in `vMetaData` or the file name, not from today. That applies to snapshot age, host uptime, certificate expiry and end-of-support status, so an old export shows what was true when it was taken.

## Dashboards

| Page | What it rolls up |
|---|---|
| **Overview** | Headline figures: VMs, hosts, cores, vCPU:core, vRAM:RAM, CPU/memory use, storage, snapshots, findings. Also VM power state, workload footprint, VMs per cluster, OS family, a cluster capacity + N+1 table, the most-used datastores and the top issues. |
| **Issues** | 70+ rule checks grouped by check, with severity, category and object-type filters, search, a recommendation per check, and a jump to each affected object. |
| **Compute** | Cluster cards (HA/DRS/admission control, capacity, consolidation ratios, CPU/memory used, memory if the largest host fails, ESXi/CPU mix) and host utilization. The hosts table has an inspector covering the host's VMs, datastores, pNICs, VMkernel adapters, HBAs, LUN paths and findings. |
| **Virtual Machines** | A searchable, sortable inventory (search by name, IP, host, OS, network, datastore or notes). The inspector shows everything joined to the VM: placement, compute, disks, guest partitions, NICs with VLANs, snapshots, Tools/HW/firmware, findings and vHealth messages. |
| **Storage** | Capacity, used, provisioned (overcommit), thin vs thick, reclaim opportunities (powered-off VMs, snapshots, templates, guest free space, empty datastores, zombie files) and snapshot age. The datastores table has an inspector listing each datastore's VMs and hosts. |
| **Network** | Port groups with VLANs, the switch they're on, host and VM counts, and security policy. Also distributed and standard switches, VMkernel adapters, physical NICs, and adapter types. |
| **Configuration** | Distributions: guest OS, vCPU and memory sizes, firmware/Secure Boot, disk controllers, NIC types, resource controls, CPU models, hardware, link speeds. |
| **Lifecycle** | Guest OS end-of-support status, ESXi and vCenter support dates, virtual hardware versions, VMware Tools status, VM creation by year, host uptime, licenses. |
| **Correlations** | The entity graph, what each cross-tab relationship reveals, join coverage per tab, and consistency checks (RVTools' own counts vs the counts derived from other tabs). |
| **Raw Tabs** | Every tab exactly as loaded, including custom-attribute columns, in a fast sortable and filterable grid. |

The **Scope** picker in the toolbar limits every page to one vCenter, datacenter or cluster. Datastores and networks follow the hosts and VMs in scope.

**Export** writes CSVs of the findings, the correlated VM inventory, hosts, clusters and datastores. **Settings** (⌘,) holds the thresholds; findings recalculate immediately when you change them.

## How tabs are correlated

```
vCenter (vSource, vLicense) → Datacenter → Cluster (vCluster) → Host (vHost) → VM (vInfo)
VM   ⨝ vCPU · vMemory · vTools · vDisk · vPartition · vNetwork · vSnapshot · vCD · vUSB · vHealth
VM   ⨝ Datastore      via the [datastore] prefix of VMDK / .vmx paths
VM   ⨝ Port group     via vNetwork.Network ⨝ vPort / dvPort (→ VLAN, switch, security policy)
Host ⨝ vNIC · vHBA · vSC_VMK · vSwitch · vMultiPath (→ Datastore)
Host ⨝ Datastore      via vDatastore.Hosts
```

VM rows are matched by `VM ID`, then `VM UUID`, then name (all scoped to the vCenter). Columns are looked up by name, never by position, and older headers such as `… MB` vs `… MiB` are handled. That makes RVTools 3.x and 4.x exports, and environment-specific custom-attribute columns, work the same way.

## Command line

```bash
swift build -c release --product rvtools-cli
.build/release/rvtools-cli <export.xlsx | csv-folder> [--export <dir>]
```

This prints the inventory, cluster headroom, join coverage, consistency checks, findings and distributions. With `--export` it also writes the CSVs.

## Sample data

`python3 scripts/generate_sample.py` (requires `openpyxl`) regenerates a fictional environment in `samples/`, as both an `.xlsx` and a CSV folder. It contains deliberate issues for every dashboard to show. The build script bundles the `.xlsx` into the app as the **Try Sample Data** file.

## Screenshots for review

The app can render every page to PNG itself, which needs no Screen Recording permission:

```bash
open -W -n --env RVTA_SNAPSHOT_DIR=/tmp/shots --env RVTA_SNAPSHOT_QUIT=1 \
  -a "build/RVTools Analyzer.app" samples/RVTools_export_all_*.xlsx
```

Add `--env RVTA_APPEARANCE=dark` to capture in dark mode.

## Project layout

```
Sources/RVToolsCore/      parsing (Zip, XLSX, CSV, Dataset), Correlate, Rules, Analysis, Lifecycle, Export
Sources/RVToolsAnalyzer/  SwiftUI app (one file per page + shared components/theme)
Sources/rvtools-cli/      headless runner
scripts/                  build-app.sh, make_icon.swift, generate_sample.py
```

End-of-support dates for Windows, RHEL/CentOS, Ubuntu, Debian, SLES, ESXi and vCenter are built into `Sources/RVToolsCore/Lifecycle.swift`. Thresholds for the rules live in `Thresholds` (`Rules.swift`) and are editable in Settings.
