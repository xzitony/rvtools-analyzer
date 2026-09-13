// Cloud Cost Compare — an example custom solution for RVTools Analyzer.
//
// Prices the selected VMs on Azure and AWS, and optionally against price lists (a negotiated discount on the
// Azure list prices, a private cloud rate card), with the same right-sizing and best-fit logic as the built-in
// Azure / AWS Migration solutions. It never downloads anything: it reads prices the app already has.
// See docs/SOLUTIONS.md for the API.

const MODELS = ["payg", "reserved1y", "reserved3y"];
const AZURE_FAMILIES = ["Dsv5", "Dasv5", "Esv5", "Easv5", "Fsv2"];
const AWS_FAMILIES = ["m6i", "m7i", "m6a", "m7a", "r6i", "r7i", "r6a", "r7a", "c6i", "c7i", "c6a", "c7a"];

function run(vms, inventory, params, context) {
  const providers = {};
  for (const p of pricing.providers()) providers[p.id] = p;

  const targets = [
    { provider: "azure", label: "Azure", kind: "azure", regions: params.azureRegions, model: MODELS[params.azureModel], families: AZURE_FAMILIES },
    { provider: "aws", label: "AWS", kind: "aws", regions: params.awsRegions, model: "payg", discountPct: params.awsDiscount, families: AWS_FAMILIES },
  ];
  if (params.compare.includes(0)) {
    targets.push({ provider: "example-azure-ea", label: "Azure (negotiated)", kind: "azure", regions: params.azureRegions, model: MODELS[params.azureModel], families: AZURE_FAMILIES });
  }
  if (params.compare.includes(1)) {
    targets.push({ provider: "example-private-cloud", label: "Private cloud", kind: null, regions: pricing.regions("example-private-cloud"), model: "payg" });
  }

  const inScope = vms.filter((vm) => !vm.isTemplate);
  const demandOptions = { rightsizeCPU: params.rightsize, rightsizeMemory: params.rightsize, bufferPct: params.buffer, minVCPU: 2, minMemoryGiB: 4 };
  const demands = inScope.map((vm) => ({ vm, d: rva.cloud.demand(vm, demandOptions) }));
  const hdd = params.disk === 1;

  const checks = rva.checks();
  const evaluations = [];
  for (const t of targets) {
    const info = providers[t.provider];
    if (!info || !info.installed) {
      checks.add("missing-" + t.provider, "Pricing", `${t.label}: price list not installed`, "warning",
        `No price list with id “${t.provider}” is installed.`,
        { remediation: "Import it in Settings › Price Lists, or untick it under Assumptions." });
      continue;
    }
    if (t.regions.length === 0) {
      checks.add("regions-" + t.provider, "Pricing", `${t.label}: no regions`, "info", "Choose at least one region under Assumptions.");
      continue;
    }
    for (const region of t.regions) {
      const sheet = pricing.get(t.provider, region);
      if (!sheet) {
        checks.add(`prices-${t.provider}-${region}`, "Pricing", `${t.label} · ${region}: no prices`, "warning", pricing.error(t.provider, region));
        continue;
      }
      evaluations.push(evaluate(t, sheet, demands, params, hdd));
    }
  }

  if (evaluations.length === 0) {
    return { headline: `${rva.int(inScope.length)} VMs selected — no prices available yet`, sections: [checks.section("Pricing")] };
  }

  // The cheapest region of each option
  const best = [];
  for (const t of targets) {
    const mine = evaluations.filter((e) => e.target === t);
    if (mine.length) best.push(mine.reduce((a, b) => (b.total < a.total ? b : a)));
  }
  const currencies = rva.uniq(best.map((e) => e.sheet.currency));
  const cheapest = currencies.length === 1 ? best.reduce((a, b) => (b.total < a.total ? b : a)) : null;
  const money = (e, value) => rva.money(value, e.sheet.currency);

  const sections = [];

  sections.push(rva.metrics("Summary", best.map((e) => rva.metric(
    e.target.label,
    money(e, e.total) + " / month",
    `${e.sheet.regionName} · ${money(e, e.total * 12)} a year` + (e === cheapest ? " · cheapest" : ""),
    e === cheapest ? "star.fill" : "cloud"))));

  const byTotal = rva.sortBy(evaluations, "total");
  sections.push(rva.table({
    id: "regions",
    title: "Every region priced",
    subtitle: "Monthly estimate for the selected VMs",
    columns: ["Option", "Region", "Compute / month", "Storage / month", "Total / month", "Total / year", "No fit", "Prices"],
    numeric: [2, 3, 4, 5, 6],
    rows: byTotal.map((e) => [
      e.target.label, `${e.sheet.regionName} (${e.sheet.region})`, money(e, e.compute), money(e, e.storage),
      money(e, e.total), money(e, e.total * 12), rva.int(e.unmatched.length), priceDate(e.sheet),
    ]),
    emphasized: cheapest ? [byTotal.indexOf(cheapest)] : [],
  }));

  if (cheapest) {
    sections.push(rva.bars("Cheapest region of each option",
      rva.sortBy(best, "total").map((e) => ({ label: `${e.target.label} · ${e.sheet.regionName}`, value: e.total, count: e.lines.length })),
      { format: "currency", currency: currencies[0], subtitle: "per month" }));
  }

  for (const e of best) {
    checks.list("nofit-" + e.target.provider, "Sizing", `${e.target.label}: no fitting instance`, "warning", {
      noun: "powered-on VMs are larger than every instance",
      affected: e.unmatched.map((l) => rva.vmRef(l.vm, `needs ${l.d.vcpu} vCPU / ${rva.num(l.d.memoryGiB, 0)} GiB`)),
      ready: "Every powered-on VM fits an instance",
      remediation: "These VMs are left out of the compute total.",
    });
    if (e.sheet.stale) {
      checks.add("stale-" + e.target.provider, "Pricing", `${e.target.label}: prices are over a week old`, "info", priceDate(e.sheet),
        { remediation: "Use Download Prices to refresh them." });
    }
  }
  if (!cheapest) {
    checks.add("currency", "Pricing", "Different currencies", "warning", `Options are priced in ${currencies.join(", ")}, so totals aren't directly comparable.`);
  }
  const off = inScope.filter((vm) => !vm.isRunning);
  if (off.length) {
    checks.add("off", "Scope", "Powered-off VMs", "info", `${off.length} VMs priced for storage only`, { affected: off.map((vm) => rva.vmRef(vm)) });
  }
  sections.push(checks.section("Considerations"));

  const columns = ["VM", "Cluster", "OS", "Target size"];
  const numeric = [];
  for (const e of best) {
    columns.push(`${e.target.label} instance`, `${e.target.label} / month`);
    numeric.push(columns.length - 1);
  }
  sections.push(rva.table({
    id: "per-vm",
    title: "Per-VM estimate",
    subtitle: "In the cheapest region of each option",
    columns,
    numeric,
    rows: demands.map(({ vm, d }, i) => {
      const row = [vm.name, vm.clusterName, vm.os.name, `${d.vcpu} vCPU / ${rva.num(d.memoryGiB, 0)} GiB`];
      for (const e of best) {
        const line = e.lines[i];
        row.push(!vm.isRunning ? "storage only" : line.fit ? line.fit.instance.name.replace("Standard_", "") : "no fit", money(e, line.total));
      }
      return row;
    }),
    rowRefs: demands.map(({ vm }) => rva.vmRef(vm)),
  }));

  sections.push(rva.notes("Method and sources", [
    "Each VM gets the cheapest instance with at least its target vCPU and memory (at least 2 vCPU / 4 GiB) — the same best fit as the built-in migration solutions"
      + (params.rightsize ? `, right-sized from observed usage plus ${params.buffer}%.` : "."),
    `Compute is priced at ${rva.cloud.monthlyHours} hours a month for powered-on VMs. Every disk is priced as ${hdd ? "HDD" : "SSD"} storage of its provisioned size.`,
    ...best.map((e) => `${e.target.label}: ${e.sheet.source}${e.sheet.effective ? ` (effective ${e.sheet.effective})` : ""}.`),
    "Not included: egress, backup, monitoring, OS subscriptions other than Windows Server, support and taxes.",
  ]));

  const headline = cheapest
    ? `${rva.int(inScope.length)} VMs: ${cheapest.target.label} in ${cheapest.sheet.regionName} is cheapest at ${money(cheapest, cheapest.total)}/month`
    : `${rva.int(inScope.length)} VMs priced across ${best.length} options`;
  return { headline, sections };
}

function evaluate(target, sheet, demands, params, hdd) {
  const lines = demands.map(({ vm, d }) => {
    const fit = rva.cloud.bestFit(sheet, d, {
      model: target.model, discountPct: target.discountPct || 0, licenseIncluded: !params.byol, families: target.families,
    });
    const compute = vm.isRunning && fit ? fit.hourly * rva.cloud.monthlyHours : 0;
    const storage = rva.sum(d.diskGiB, (gib) => diskMonthly(target, sheet, gib, hdd));
    return { vm, d, fit, compute, storage, total: compute + storage };
  });
  return {
    target, sheet, lines,
    compute: rva.sum(lines, "compute"),
    storage: rva.sum(lines, "storage"),
    total: rva.sum(lines, "total"),
    unmatched: lines.filter((l) => !l.fit && l.vm.isRunning),
  };
}

function diskMonthly(target, sheet, gib, hdd) {
  if (target.kind === "azure") return rva.cloud.disk(sheet, gib, hdd ? "standard-hdd" : "premium-ssd").monthly;
  if (target.kind === "aws") return rva.cloud.disk(sheet, gib, hdd ? "st1" : "gp3").monthly;
  // Rate cards without an Azure / AWS base price storage per GiB-month in `storage`.
  return (sheet.storage[hdd ? "hddGiBMonth" : "ssdGiBMonth"] || 0) * gib;
}

function priceDate(sheet) {
  if (sheet.fetched) return "downloaded " + rva.date(sheet.fetched);
  if (sheet.effective) return "effective " + sheet.effective;
  return sheet.source;
}
