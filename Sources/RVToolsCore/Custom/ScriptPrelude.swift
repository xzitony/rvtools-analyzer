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
  function capacity(mib) {
    if (!finite(mib)) return "—";
    const a = Math.abs(mib);
    if (a < 1024) return mib.toFixed(0) + " MB";
    if (a < 1048576) return (mib / 1024).toFixed(a < 10240 ? 1 : 0) + " GB";
    if (a < 1073741824) return (mib / 1048576).toFixed(1) + " TB";
    return (mib / 1073741824).toFixed(2) + " PB";
  }
  const currencySymbols = { USD: "$", EUR: "€", GBP: "£", JPY: "¥", AUD: "A$", CAD: "C$", NZD: "NZ$", INR: "₹", BRL: "R$" };
  function money(v, currency) {
    if (!finite(v)) return "—";
    const code = String(currency || "USD").toUpperCase();
    const a = Math.abs(v);
    const body = a >= 1e7 ? (a / 1e6).toFixed(2) + "M" : int(a);
    const symbol = currencySymbols[code];
    return (v < 0 ? "−" : "") + (symbol !== undefined ? symbol + body : body + " " + code);
  }
  function mbps(v) {
    if (!finite(v)) return "—";
    if (v >= 1000) return (v / 1000).toFixed(2) + " Gb/s";
    if (v >= 10) return v.toFixed(0) + " Mb/s";
    return v.toFixed(1) + " Mb/s";
  }
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

  // Result sections
  const metric = (label, value, detail, symbol) => ({ label, value: String(value), detail: detail === undefined ? "" : String(detail), symbol });
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
      section(title) { return { type: "checks", title, checks: list }; },
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

  return {
    apiVersion: 1,
    int, num, pct, capacity, gib: (mib) => mib / 1024, money, mbps, duration, date, daysBetween,
    sum, groupBy, countBy, sortBy, uniq, index,
    ref, vmRef, hostRef, clusterRef, datastoreRef, isWindows,
    metric, metrics, table, bars, notes, checks,
    cloud,
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

function __main(idsJSON, inventoryJSON, paramsJSON, labelsJSON, contextJSON) {
  const inventory = JSON.parse(inventoryJSON);
  const ids = new Set(JSON.parse(idsJSON));
  const vms = inventory.vms.filter((vm) => ids.has(vm.id));
  const params = JSON.parse(paramsJSON);
  const context = JSON.parse(contextJSON);
  context.labels = JSON.parse(labelsJSON);
  if (typeof run !== "function") throw new Error("the script must define function run(vms, inventory, params, context)");
  const result = run(vms, inventory, params, context);
  if (result === null || typeof result !== "object") throw new Error("run() must return an object like { headline, sections: [...] }");
  return JSON.stringify(result);
}
"""#
}
