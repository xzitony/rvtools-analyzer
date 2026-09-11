# RVTools Analyzer

A native macOS app (SwiftUI + Swift Charts) that ingests an **RVTools** export and correlates every tab into one object model of the vSphere estate. It then rolls the data up into dashboards for counts, capacity, utilization, configuration, lifecycle and health.

Everything runs locally and your RVTools data never leaves the Mac. The only network access is the optional download of public cloud price lists (see Solutions). There are no third-party dependencies: the `.xlsx` reader (ZIP + XML) is built in.

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

### Projects

**Save Project** (⌘S) turns the current session into a `Name.rvaproj` project. Finder shows it as one file, but it's a folder that contains:
- a copy of the export(s)
- your settings: thresholds, scope, each solution's VM selection and assumptions, and the open page
- project notes
- the cloud price lists behind any estimates, so they can be reproduced later

After the first save, changes save automatically. If you've customized an unsaved session, the app offers to save it before you quit or open something else. Open projects like exports (⌘O, drag and drop, or double-click in Finder). Recent projects are on the start screen and under File › Open Recent Project.

Projects are ordinary files, so they can sit next to the customer's exports in OneDrive or SharePoint, or in iCloud Drive to sync across your Macs. The app doesn't use iCloud directly: that would need an Apple Developer membership and a provisioned, signed build, and it would move customer data out of company storage. `rvtools-cli Customer.rvaproj --solution azure` runs a solution with the project's saved selection and assumptions, and `--save-project <path>` creates a project from the CLI.

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

## Solutions

The **Solutions** section of the sidebar turns a chosen set of VMs and editable assumptions into a report. Each solution has three steps:

1. **Select VMs** — filter by name, cluster, power state or OS family, then add or remove the shown or highlighted VMs, or tick them one by one. Each solution keeps its own selection.
2. **Assumptions** — change rates, retention, host specs and so on. They are saved and reused for every export you open.
3. **Results** — headline figures, sizing tables, a checklist with the affected objects, and a per-VM breakdown. **Export Report…** writes a Markdown report plus CSV tables and the list of selected VMs.

| Solution | What it produces |
|---|---|
| **Backup Sizing** | Protected data (guest used, in-use or provisioned), primary repository capacity for daily points and GFS fulls with growth and headroom, offsite copy, throughput for the backup window, licensing counts (VMs, hosts, sockets), and coverage gaps (independent, RDM or shared disks, no Tools, consolidation). |
| **DR Sizing** | DR hosts, sized by whichever of CPU, memory or storage needs the most, plus spares; replica storage with point-in-time history; average and peak replication bandwidth against the link and RPO; initial seed time; a DR network map of port groups, VLANs and subnets; and replication blockers. |
| **Azure Migration** / **AWS Migration** | Right-sizes each VM, either as configured or from the CPU and consumed memory in the export plus a buffer. It then picks the cheapest instance that fits in your chosen families, prices each disk as a managed disk tier or EBS volume, and compares monthly and annual cost across the selected regions. Also shows pricing-model options (Azure pay-as-you-go vs 1- or 3-year reservations; AWS on-demand vs your commitment discount), Windows licensing (Hybrid Benefit / BYOL), right-sizing savings, instance and storage mix, and a per-VM estimate. |
| **VCF 9 Readiness** | Checks on the clusters, hosts and vCenters behind the selected VMs: upgrade path, CPU generation, NTP, DNS, certificates, uplinks, cluster size, DRS/HA and host-evacuation headroom. Also vDS vs standard switches, datastore types, VM live-migration blockers, and VCF core licensing. |

**Cloud prices.** The Azure and AWS solutions use public list prices (USD), downloaded only when you click **Download Prices**. They're cached for 7 days in `~/Library/Caches/RVToolsAnalyzer/pricing`. Only the price lists are fetched; no inventory data is sent. Azure prices come from the [Azure Retail Prices API](https://prices.azure.com/api/retail/prices) (pay-as-you-go, reservations, managed disks). AWS prices come from the public price files behind the aws.amazon.com pricing pages (on-demand EC2 Linux/Windows and EBS). AWS doesn't publish Savings Plan or Reserved Instance prices in a lightweight file, so enter your expected commitment discount. `rvtools-cli --prices azure|aws` downloads every region and reports what it found. Not included: egress, backup, monitoring, OS subscriptions (RHEL/SLES), SQL and other application licences, support and negotiated discounts.

The rules and defaults are built in; confirm them against current vendor documentation. VCF 9 upgrade paths and CPU support are the ones most likely to need checking. To add a solution, create a type conforming to `Solution` in `Sources/RVToolsCore/Solutions/` and add it to `SolutionCatalog.all`. The app renders its parameters, selection and results automatically. `rvtools-cli <export> --solution backup|dr|vcf9` prints a report from the terminal.

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
