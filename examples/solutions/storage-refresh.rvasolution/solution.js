// Storage Refresh — an example custom solution for RVTools Analyzer.
//
// Sizes replacement primary storage for the selected VMs: today's footprint, growth over a horizon, data
// reduction and free-space headroom, broken down by cluster and by the datastore type the data lives on now.
// It uses no prices. See docs/SOLUTIONS.md for the API.

function run(vms, inventory, params, context) {
  const inScope = vms.filter((vm) =>
    vm.isTemplate ? params.include.includes(2) : vm.isRunning ? params.include.includes(0) : params.include.includes(1));

  const growth = Math.pow(1 + params.growth / 100, params.years);
  const reduction = Math.max(params.reduction, 1);
  const headroom = params.freeSpace / 100;
  const toBuy = (mib) => mib / reduction / (1 - headroom);

  // Datastore type by vCenter + name: where each VM's data lives today.
  const dsKey = (vcenter, name) => vcenter + "|" + name;
  const dsType = new Map(inventory.datastores.map((ds) => [dsKey(ds.vcenter, ds.name), ds.type || "Unknown"]));

  const rows = inScope.map((vm) => {
    // RDMs and independent disks are out of scope: remove their share of the VM's disk capacity.
    const excluded = rva.sum(vm.disks.filter((d) => d.rdm || d.independent), "capacityMiB");
    const share = vm.diskCapacityMiB > 0 ? Math.max(0, 1 - excluded / vm.diskCapacityMiB) : 1;
    let basis, used;
    if (params.basis === 0 && vm.guestConsumedMiB > 0) {
      basis = "Guest used"; used = vm.guestConsumedMiB;
    } else if (params.basis <= 1) {
      basis = "In use"; used = vm.inUseExcludingSwapMiB;
    } else {
      basis = "Provisioned"; used = vm.provisionedMiB;
    }
    const data = used * share + (params.snapshots ? vm.snapshotSizeMiB : 0);
    const type = vm.datastores.length ? dsType.get(dsKey(vm.vcenter, vm.datastores[0])) || "Unknown" : "Unknown";
    return { vm, basis, data, excluded, future: data * growth, type };
  });

  const today = rva.sum(rows, "data");
  const future = today * growth;
  const physical = future / reduction;
  const usable = toBuy(future);
  const guestBased = rows.filter((r) => r.basis === "Guest used").length;

  // The datastores behind the selection, as they are today.
  const usedNames = new Set(inScope.flatMap((vm) => vm.datastores.map((name) => dsKey(vm.vcenter, name))));
  const datastores = inventory.datastores.filter((ds) => usedNames.has(dsKey(ds.vcenter, ds.name)));

  const sections = [];

  sections.push(rva.metrics("Summary", [
    rva.metric("VMs in scope", rva.int(inScope.length), `${inScope.filter((vm) => vm.isRunning).length} powered on`, "desktopcomputer"),
    rva.metric("Data today", rva.capacity(today),
      params.basis === 0 ? `guest used for ${guestBased} VMs, in-use for ${rows.length - guestBased}` : context.labels.basis, "internaldrive"),
    rva.metric(`Data in ${params.years} years`, rva.capacity(future), `${rva.num(params.growth)}% a year`, "chart.line.uptrend.xyaxis"),
    rva.metric("Physical data", rva.capacity(physical), `after ${rva.num(reduction)} : 1 data reduction`, "arrow.down.right.and.arrow.up.left"),
    rva.metric("Usable capacity to buy", rva.capacity(usable), `keeps ${params.freeSpace}% free at the horizon`, "externaldrive.badge.plus"),
    rva.metric("Current datastores", rva.capacity(rva.sum(datastores, "capacityMiB")),
      `${datastores.length} datastores · ${rva.capacity(rva.sum(datastores, "freeMiB"))} free`, "square.stack.3d.up"),
  ]));

  sections.push(rva.table({
    id: "capacity-plan",
    title: "Capacity plan",
    subtitle: `${params.years}-year horizon`,
    columns: ["Step", "Capacity"],
    numeric: [1],
    rows: [
      ["Data today", rva.capacity(today)],
      [`Growth (${rva.num(params.growth)}% a year for ${params.years} years)`, "+" + rva.capacity(future - today)],
      ["Data at the horizon", rva.capacity(future)],
      [`Data reduction (${rva.num(reduction)} : 1)`, "−" + rva.capacity(future - physical)],
      ["Physical data", rva.capacity(physical)],
      [`Free-space headroom (${params.freeSpace}%)`, "+" + rva.capacity(usable - physical)],
      ["Usable capacity to buy", rva.capacity(usable)],
    ],
    emphasized: [2, 6],
  }));

  const byCluster = Object.entries(rva.groupBy(rows, (r) => r.vm.clusterName));
  sections.push(rva.table({
    id: "by-cluster",
    title: "By cluster",
    columns: ["Cluster", "VMs", "Data today", "At the horizon", "Usable to buy"],
    numeric: [1, 2, 3, 4],
    rows: rva.sortBy(byCluster, (entry) => rva.sum(entry[1], "data"), true).map(([name, list]) => [
      name, rva.int(list.length), rva.capacity(rva.sum(list, "data")), rva.capacity(rva.sum(list, "future")), rva.capacity(toBuy(rva.sum(list, "future"))),
    ]),
  }));

  const byType = Object.entries(rva.groupBy(rows, "type"))
    .map(([type, list]) => ({ label: type, value: rva.sum(list, "data"), count: list.length }))
    .sort((a, b) => b.value - a.value);
  sections.push(rva.bars("Data today by current datastore type", byType, { format: "capacityMiB" }));

  const c = rva.checks();
  c.list("rdm", "Scope", "Raw device mappings", "warning", {
    noun: "VMs have RDMs (not included in the sizing)",
    affected: inScope.filter((vm) => vm.disks.some((d) => d.rdm))
      .map((vm) => rva.vmRef(vm, rva.capacity(rva.sum(vm.disks.filter((d) => d.rdm), "capacityMiB")))),
    ready: "No RDMs",
    remediation: "Size RDM LUNs separately, or plan to convert them to VMDKs or vVols during the move.",
  });
  c.list("independent", "Scope", "Independent disks", "info", {
    noun: "VMs have independent disks (not included in the sizing)",
    affected: inScope.filter((vm) => vm.disks.some((d) => d.independent && !d.rdm)).map((vm) => rva.vmRef(vm)),
    ready: "No independent disks",
    remediation: "Independent disks often hold scratch or separately replicated data — confirm whether they move.",
  });
  c.list("snapshots", "Hygiene", "Snapshots", params.snapshots ? "info" : "warning", {
    noun: params.snapshots ? "VMs have snapshots (included in the sizing)" : "VMs have snapshots (not included in the sizing)",
    affected: inScope.filter((vm) => vm.snapshots.length > 0)
      .map((vm) => rva.vmRef(vm, `${vm.snapshots.length} snapshot(s), ${rva.capacity(vm.snapshotSizeMiB)}`)),
    ready: "No snapshots",
    remediation: "Delete or consolidate old snapshots before migrating rather than buying capacity for them.",
  });
  if (params.basis === 0) {
    c.list("guest", "Accuracy", "No guest used space", "info", {
      noun: "powered-on VMs sized from VM in-use instead",
      affected: rows.filter((r) => r.basis !== "Guest used" && r.vm.isRunning).map((r) => rva.vmRef(r.vm, "VMware Tools: " + r.vm.tools.status)),
      ready: "Guest used space is known for every powered-on VM",
      remediation: "Guest partition data needs running VMware Tools. VM in-use includes deleted blocks that UNMAP could reclaim.",
    });
  }
  c.list("low-free", "Current state", "Datastores low on free space", "warning", {
    noun: "datastores behind the selection are below 15% free",
    total: datastores.length,
    affected: datastores.filter((ds) => ds.freePct < 15).map((ds) => rva.datastoreRef(ds, `${rva.pct(ds.freePct)} free of ${rva.capacity(ds.capacityMiB)}`)),
    ready: "Every datastore behind the selection has at least 15% free",
    remediation: "Free space is already tight — plan the refresh before growth uses up what's left.",
  });
  c.list("thick", "Efficiency", "Thick-provisioned disks", "info", {
    noun: "VMs have thick disks",
    affected: inScope.filter((vm) => vm.disks.some((d) => d.provisioning.startsWith("Thick")))
      .map((vm) => rva.vmRef(vm, `${rva.capacity(vm.provisionedMiB)} provisioned, ${rva.capacity(vm.inUseMiB)} in use`)),
    ready: "Every disk is thin-provisioned",
    remediation: "Migrating thick disks to thin on the new array reclaims the unused space (unless the application needs eager-zeroed disks).",
  });
  sections.push(c.section("Considerations"));

  const perVM = rva.sortBy(rows, "data", true);
  sections.push(rva.table({
    id: "per-vm",
    title: "Per-VM sizing",
    columns: ["VM", "Cluster", "Power", "Datastore type", "Basis", "Data today", "At the horizon", "Excluded"],
    numeric: [5, 6, 7],
    rows: perVM.map((r) => [
      r.vm.name, r.vm.clusterName, r.vm.isTemplate ? "Template" : r.vm.powerState, r.type, r.basis,
      rva.capacity(r.data), rva.capacity(r.future), r.excluded > 0 ? rva.capacity(r.excluded) : "",
    ]),
    rowRefs: perVM.map((r) => rva.vmRef(r.vm)),
  }));

  sections.push(rva.notes("Method", [
    "Data per VM = the chosen basis, less the share of RDM and independent disks" + (params.snapshots ? ", plus snapshot space." : "."),
    `Growth compounds at ${rva.num(params.growth)}% a year for ${params.years} years (× ${rva.num(growth, 2)}).`,
    `Usable capacity = data at the horizon ÷ ${rva.num(reduction)} data reduction ÷ (1 − ${params.freeSpace}% free space).`,
    "RAID / erasure-coding overhead and spares are the array vendor's to add: this is usable capacity.",
  ]));

  return {
    headline: `${rva.int(inScope.length)} VMs · ${rva.capacity(today)} today → buy ${rva.capacity(usable)} usable for a ${params.years}-year horizon`,
    sections,
  };
}
