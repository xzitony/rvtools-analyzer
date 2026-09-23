import Foundation

/// JavaScript loaded before every custom solution: `console`, `rva` (formatting, collections, result builders,
/// cloud sizing) and `pricing`. Documented in docs/SOLUTIONS.md — keep the two in step.
enum ScriptPrelude {
    static let source = #"""
"use strict";

globalThis.console = (() => {
  const text = (args) => Array.from(args).map((a) => {
    if (typeof a === "string") return a;
    if (a instanceof Error) return a.message;
    try { return JSON.stringify(a); } catch (e) { return String(a); }
  }).join(" ");
  return {
    log: function () { __log("log", text(arguments)); },
    info: function () { __log("log", text(arguments)); },
    debug: function () { __log("log", text(arguments)); },
    warn: function () { __log("warn", text(arguments)); },
    error: function () { __log("error", text(arguments)); },
  };
})();

globalThis.rva = (() => {
  const finite = (v) => typeof v === "number" && isFinite(v);
  const group3 = (digits) => digits.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const accessor = (fn) => (typeof fn === "function" ? fn : (x) => x[fn]);

  // Formatting (matches the built-in solutions)
  function int(v) {
    if (!finite(v)) return "—";
    const r = Math.round(v);
    return (r < 0 ? "-" : "") + group3(String(Math.abs(r)));
  }
  function num(v, digits) {
    if (!finite(v)) return "—";
    if (digits === undefined) {
      if (Math.round(v) === v && Math.abs(v) < 1e12) return int(v);
      digits = Math.abs(v) < 10 ? 2 : 1;
    }
    const parts = Math.abs(v).toFixed(digits).split(".");
    return (v < 0 ? "-" : "") + group3(parts[0]) + (parts[1] ? "." + parts[1] : "");
  }
  function pct(v, digits) {
    if (!finite(v)) return "—";
    if (digits !== undefined) return v.toFixed(digits) + "%";
    return (v < 10 && v !== 0 && Math.round(v) !== v ? v.toFixed(1) : v.toFixed(0)) + "%";
  }
  // Display units chosen in the app (or rvtools-cli --units / --rate). Memory is always binary.
  const units = Object.freeze(typeof __rvaUnits === "object" && __rvaUnits ? __rvaUnits : { storage: "binary", rate: "bits" });
  function scaled(v, base, names) {
    const a = Math.abs(v);
    if (a < base) return v.toFixed(0) + " " + names[0];
    if (a < base * base) return (v / base).toFixed(a < 10 * base ? 1 : 0) + " " + names[1];
    if (a < base * base * base) return (v / base / base).toFixed(1) + " " + names[2];
    return (v / base / base / base).toFixed(2) + " " + names[3];
  }
  function capacity(mib) {
    if (!finite(mib)) return "—";
    return units.storage === "decimal" ? scaled(mib * 1.048576, 1000, ["MB", "GB", "TB", "PB"]) : scaled(mib, 1024, ["MiB", "GiB", "TiB", "PiB"]);
  }
  function memory(mib) {
    if (!finite(mib)) return "—";
    return scaled(mib, 1024, ["MiB", "GiB", "TiB", "PiB"]);
  }
  function trimmed(v) { return String(Number(v.toFixed(2))); }
  const currencySymbols = { USD: "$", EUR: "€", GBP: "£", JPY: "¥", AUD: "A$", CAD: "C$", NZD: "NZ$", INR: "₹", BRL: "R$" };
  function money(v, currency) {
    if (!finite(v)) return "—";
    const code = String(currency || "USD").toUpperCase();
    const a = Math.abs(v);
    const body = a >= 1e7 ? (a / 1e6).toFixed(2) + "M" : int(a);
    const symbol = currencySymbols[code];
    return (v < 0 ? "−" : "") + (symbol !== undefined ? symbol + body : body + " " + code);
  }
  function rate(mbps) {
    if (!finite(mbps)) return "—";
    const bits = units.rate !== "bytes", v = bits ? mbps : mbps / 8;
    if (Math.abs(v) >= 1000) return trimmed(v / 1000) + (bits ? " Gbps" : " GB/s");
    return (Math.abs(v) >= 10 ? v.toFixed(0) : trimmed(v)) + (bits ? " Mbps" : " MB/s");
  }
  const mbps = rate;
  function duration(hours) {
    if (!finite(hours)) return "—";
    if (hours < 1) return (hours * 60).toFixed(0) + " minutes";
    if (hours < 48) return hours.toFixed(1) + " hours";
    return (hours / 24).toFixed(1) + " days";
  }
  function date(value) {
    if (!value) return "—";
    const d = new Date(value);
    return isNaN(d.getTime()) ? "—" : d.toISOString().slice(0, 10);
  }
  function daysBetween(a, b) {
    const x = new Date(a).getTime(), y = new Date(b === undefined ? Date.now() : b).getTime();
    return (y - x) / 86400000;
  }

  // Collections
  function sum(list, fn) {
    const f = fn === undefined ? (x) => x : accessor(fn);
    let total = 0;
    for (const x of list) { const v = f(x); if (finite(v)) total += v; }
    return total;
  }
  function groupBy(list, fn) {
    const f = accessor(fn), out = {};
    for (const x of list) { const k = String(f(x)); (out[k] || (out[k] = [])).push(x); }
    return out;
  }
  function countBy(list, fn) {
    const f = accessor(fn), out = {};
    for (const x of list) { const k = String(f(x)); out[k] = (out[k] || 0) + 1; }
    return out;
  }
  function sortBy(list, fn, descending) {
    const f = accessor(fn);
    return list.slice().sort((a, b) => {
      const x = f(a), y = f(b);
      const c = x < y ? -1 : x > y ? 1 : 0;
      return descending ? -c : c;
    });
  }
  const uniq = (list) => Array.from(new Set(list));
  function index(list) {
    const m = new Map();
    for (const x of list) m.set(x.id, x);
    return m;
  }

  // Objects a result can link to (click-through in the app)
  const ref = (kind, obj, detail) => ({ kind, id: obj.id, name: obj.name, detail: detail === undefined ? "" : String(detail) });
  const vmRef = (vm, detail) => ref("vm", vm, detail);
  const hostRef = (host, detail) => ref("host", host, detail);
  const clusterRef = (cluster, detail) => ref("cluster", cluster, detail);
  const datastoreRef = (ds, detail) => ref("datastore", ds, detail);
  const isWindows = (vm) => vm.os.family === "windowsServer" || vm.os.family === "windowsDesktop";

  // vCenter custom attributes and vSphere tags (vm.customFields)
  const customFields = (vm) => (vm && Array.isArray(vm.customFields) ? vm.customFields : []);
  function fields(vm) {
    const out = {};
    for (const f of customFields(vm)) if (!(f.name in out)) out[f.name] = f.value;
    return out;
  }
  // The first value whose name matches: a RegExp, or a string compared with the whole name, ignoring case.
  function field(vm, pattern) {
    const matches = pattern instanceof RegExp ? (n) => pattern.test(n) : (n) => n.toLowerCase() === String(pattern).toLowerCase();
    const f = customFields(vm).find((x) => matches(x.name));
    return f ? f.value : null;
  }
  // Name, notes and custom field values as one text, for keyword matching. Field names are left out: they're the
  // same on every VM (e.g. a backup product's attribute), so they'd match everything.
  const hints = (vm) => [vm.name, vm.annotation].concat(customFields(vm).map((f) => f.value)).filter(Boolean).join("\n");

  // Result sections
  const metric = (label, value, detail, symbol, status) =>
    Object.assign({ label, value: String(value), detail: detail === undefined ? "" : String(detail), symbol }, status ? { status } : {});
  const metrics = (title, items) => ({ type: "metrics", title, items });
  const table = (spec) => Object.assign({ type: "table" }, spec);
  const bars = (title, items, options) => Object.assign({ type: "bars", title, items }, options || {});
  const notes = (title, lines) => ({ type: "notes", title, lines });

  function checks() {
    const list = [];
    const api = {
      add(id, area, title, status, summary, options) {
        const o = options || {};
        list.push({ id, area, title, status, summary: summary || "", remediation: o.remediation || "", affected: o.affected || [] });
        return api;
      },
      // "ready" when nothing is affected, otherwise `status` with "<n> [of <total>] <noun>".
      list(id, area, title, status, options) {
        const o = options || {}, affected = o.affected || [];
        if (affected.length === 0) return api.add(id, area, title, "ready", o.ready || "None found");
        const of = o.total !== undefined ? " of " + o.total : "";
        return api.add(id, area, title, status, affected.length + of + " " + (o.noun || "objects"), { remediation: o.remediation, affected });
      },
      // One check over many objects: items are [status, ref]; the worst non-ready status wins.
      aggregate(id, area, title, options) {
        const o = options || {}, items = o.items || [];
        const rank = { blocker: 0, warning: 1, info: 2, ready: 3 };
        if (items.length === 0) return o.empty ? api.add(id, area, title, "info", o.empty, { remediation: o.remediation }) : api;
        const bad = items.filter((i) => i[0] !== "ready").sort((a, b) => rank[a[0]] - rank[b[0]]);
        if (bad.length === 0) return api.add(id, area, title, "ready", o.ready || "All ready");
        const blockers = bad.filter((i) => i[0] === "blocker").length;
        let summary = bad.length + " of " + items.length + " " + (o.noun || "objects");
        if (blockers > 0 && blockers < bad.length) summary += " (" + blockers + " blocking)";
        return api.add(id, area, title, bad[0][0], summary, { remediation: o.remediation, affected: bad.map((i) => i[1]) });
      },
      get checks() { return list; },
      section(title, subtitle) { return subtitle ? { type: "checks", title, subtitle, checks: list } : { type: "checks", title, checks: list }; },
    };
    return api;
  }

  // Cloud sizing — the same code the built-in Azure / AWS solutions use.
  const cloud = {
    monthlyHours: 730,
    demand(vm, options) {
      return JSON.parse(__cloud_demand(String(typeof vm === "object" ? vm.id : vm), JSON.stringify(options || {})));
    },
    bestFit(sheet, demand, options) {
      if (!sheet) throw new Error("rva.cloud.bestFit needs a price sheet from pricing.get()");
      const o = Object.assign({ vcpu: demand.vcpu, memoryGiB: demand.memoryGiB, windows: !!demand.windows }, options || {});
      return JSON.parse(__cloud_bestFit(sheet.provider, sheet.region, JSON.stringify(o)));
    },
    disk(sheet, gib, type) {
      if (!sheet) throw new Error("rva.cloud.disk needs a price sheet from pricing.get()");
      return JSON.parse(__cloud_disk(sheet.provider, sheet.region, JSON.stringify({ gib, type: type || "" })));
    },
  };

  // The app's findings (context.findings): filter, rank and turn them into checks.
  const findings = (() => {
    const rank = { critical: 0, warning: 1, info: 2 };
    const nouns = { vm: ["VM", "VMs"], host: ["host", "hosts"], cluster: ["cluster", "clusters"], datastore: ["datastore", "datastores"],
                    network: ["port group", "port groups"], vcenter: ["vCenter", "vCenters"] };
    const lower = (list) => (list ? new Set([].concat(list).map((x) => String(x).toLowerCase())) : null);
    function counted(objects) {
      const kinds = uniq(objects.map((o) => o.kind));
      const n = objects.length, noun = kinds.length === 1 && nouns[kinds[0]] ? nouns[kinds[0]][n === 1 ? 0 : 1] : (n === 1 ? "object" : "objects");
      return int(n) + " " + noun;
    }
    const api = {
      // Object kinds for the usual review areas.
      areas: Object.freeze({ compute: ["vm", "host", "cluster"], storage: ["datastore"], network: ["network"], management: ["vcenter"] }),
      // Groups matching every option given, worst first, then by objects affected. Filtering by kinds keeps only those objects.
      top(groups, options) {
        const o = options || {};
        const kinds = lower(o.kinds), categories = lower(o.categories), severities = lower(o.severities);
        const rules = o.rules ? [].concat(o.rules).map(String) : null;
        const exclude = o.exclude ? [].concat(o.exclude).map(String) : [];
        const matches = (rule, list) => list.some((p) => rule === p || (p.endsWith(".") ? rule.startsWith(p) : rule.startsWith(p + ".")));
        const out = [];
        for (const g of groups || []) {
          if (severities && !severities.has(g.severity) && !severities.has(g.status)) continue;
          if (categories && !categories.has(g.category.toLowerCase())) continue;
          if (rules && !matches(g.rule, rules)) continue;
          if (matches(g.rule, exclude)) continue;
          const objects = kinds ? g.objects.filter((x) => kinds.has(x.kind)) : g.objects;
          if (objects.length === 0) continue;
          out.push(objects.length === g.objects.length ? g : Object.assign({}, g, { objects, count: objects.length, kinds: uniq(objects.map((x) => x.kind)) }));
        }
        out.sort((a, b) => rank[a.severity] - rank[b.severity] || b.count - a.count || a.title.localeCompare(b.title));
        return o.limit ? out.slice(0, o.limit) : out;
      },
      // One finding group as a check: status, "12 VMs", the recommendation and the affected objects.
      check(g, options) {
        const o = options || {};
        const objects = o.maxObjects ? g.objects.slice(0, o.maxObjects) : g.objects;
        return { id: g.rule, area: o.area || g.category, title: g.title, status: g.status, summary: counted(g.objects),
                 remediation: g.recommendation, affected: objects.map((x) => ({ kind: x.kind, id: x.id, name: x.name, detail: x.detail || x.location })) };
      },
      checks(groups, options) { return (groups || []).map((g) => api.check(g, options)); },
      section(title, groups, options) {
        const s = { type: "checks", title, checks: api.checks(groups, options) };
        if (options && options.subtitle) s.subtitle = options.subtitle;
        return s;
      },
      // Totals by severity, e.g. { critical: 3, warning: 12, info: 40, groups: 20 }; counts objects unless { by: "groups" }.
      counts(groups, options) {
        const byGroups = options && options.by === "groups";
        const c = { critical: 0, warning: 0, info: 0, groups: (groups || []).length };
        for (const g of groups || []) c[g.severity] += byGroups ? 1 : g.count;
        return c;
      },
    };
    return api;
  })();

  return {
    apiVersion: 1,
    int, num, pct, capacity, memory, gib: (mib) => mib / 1024, money, mbps, rate, units, duration, date, daysBetween,
    sum, groupBy, countBy, sortBy, uniq, index,
    ref, vmRef, hostRef, clusterRef, datastoreRef, isWindows, fields, field, hints,
    metric, metrics, table, bars, notes, checks,
    cloud, findings,
  };
})();

globalThis.pricing = (() => {
  const cache = new Map();
  function load(provider, region) {
    const key = provider + "|" + region;
    if (!cache.has(key)) cache.set(key, JSON.parse(__pricing_get(String(provider), String(region))));
    return cache.get(key);
  }
  return {
    providers: () => JSON.parse(__pricing_providers()),
    regions: (provider) => JSON.parse(__pricing_regions(String(provider))),
    get: (provider, region) => load(provider, region).sheet || null,
    error: (provider, region) => load(provider, region).error || null,
    require(provider, region) {
      const r = load(provider, region);
      if (r.error) throw new Error(r.error);
      return r.sheet;
    },
  };
})();

function __main(idsJSON, inventoryJSON, paramsJSON, labelsJSON, contextJSON, selectionsJSON) {
  const inventory = JSON.parse(inventoryJSON);
  const byID = new Map(inventory.vms.map((vm) => [vm.id, vm]));
  const pick = (ids) => ids.map((id) => byID.get(id)).filter(Boolean);
  const vms = pick(JSON.parse(idsJSON));
  const params = JSON.parse(paramsJSON);
  const context = JSON.parse(contextJSON);
  context.labels = JSON.parse(labelsJSON);
  context.selections = {};
  const selections = JSON.parse(selectionsJSON || "{}");
  for (const id of Object.keys(selections)) context.selections[id] = pick(selections[id]);
  if (typeof run !== "function") throw new Error("the script must define function run(vms, inventory, params, context)");
  const result = run(vms, inventory, params, context);
  if (result === null || typeof result !== "object") throw new Error("run() must return an object like { headline, sections: [...] }");
  return JSON.stringify(result);
}
"""#
}
