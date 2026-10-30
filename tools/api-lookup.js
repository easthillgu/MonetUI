// tools/api-lookup.js
// Query the local snapshot of the wuxianwow.com API manual (docs/api/, filled by
// tools/api-fetch.js). This is the authoritative API reference for this client --
// prefer it over any external MCP for "does this function / event / enum exist,
// what are its arguments, is it protected / secret?" questions.
//
// Usage:
//   node tools/api-lookup.js <word> [word...]      all words must match (name, doc, payload)
//   node tools/api-lookup.js SetPoint
//   node tools/api-lookup.js --ns C_GameRules
//   node tools/api-lookup.js aura --kind event
//   node tools/api-lookup.js --protected
//   node tools/api-lookup.js FrameStrata --kind enum
//
// Options:
//   --kind fn|event|enum|struct|type   restrict the kind ("type" = enum + struct)
//   --ns <name>          restrict to one namespace / object / global group
//                        (accepts "C_GameRules", "GameRules", "Frame")
//   --protected          only protected entries (functions)
//   --secret             only entries with secret returns / secret payload
//   --restricted         only entries flagged HasRestrictions / 受限事件
//   --limit <n>          max rows (default 25, 0 = no limit)
//   --json               machine readable output
//   --exact              name must match exactly (ignores doc text)
//   --exists             quiet check: prints nothing, exit 0 if found, 1 if not
//   --stats              counts per category and per namespace (no query needed)
//   --file <path>        use another dump (default docs/api/data/wuxian-api.json)

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const argv = process.argv.slice(2);

const FLAG_ORDER = ["p", "pm", "re", "sp", "s", "na", "at", "r", "h", "m", "u"];
const FLAG_LABEL = {
  p: "受保护",
  pm: "受保护的方法",
  re: "受限事件",
  s: "机密",
  na: "禁机密参数",
  at: "允许污染代码传机密",
  r: "受限",
  h: "可安全钩",
  m: "可能无返回",
  sp: "机密载荷",
  u: "去重事件",
};

function opt(name) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}
const has = (name) => argv.includes(name);

const words = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a.startsWith("--")) {
    if (["--kind", "--ns", "--limit", "--file"].includes(a)) i++;
    continue;
  }
  words.push(a.toLowerCase());
}

const FILE = path.resolve(opt("--file") || path.join(ROOT, "docs", "api", "data", "wuxian-api.json"));
if (!fs.existsSync(FILE)) {
  console.error("no snapshot at " + FILE + "\nrun: node tools/api-fetch.js");
  process.exit(2);
}

let meta = {};
try {
  meta = JSON.parse(fs.readFileSync(path.join(path.dirname(FILE), "meta.json"), "utf8"));
} catch (e) {
  meta = {};
}

const DATA = JSON.parse(fs.readFileSync(FILE, "utf8"));

// ---------------------------------------------------------------- flatten
function paramList(ps) {
  return ps
    .map(([name, type, optional, def]) => {
      let s = name + (optional ? "?" : "") + ": " + type;
      if (def !== null && def !== undefined) s += " = " + String(def);
      return s;
    })
    .join(", ");
}

function flagsOf(fl) {
  const parts = [];
  for (const key of FLAG_ORDER) {
    if (!fl || !(key in fl)) continue;
    if (key === "s" && Array.isArray(fl.s) && fl.s.length) parts.push("机密[" + fl.s.join(", ") + "]");
    else parts.push(FLAG_LABEL[key] || key);
  }
  return parts;
}

function groupLabel(entry) {
  if (entry.ns) return entry.ns;
  if (entry.o) return "(object) " + entry.o;
  return entry.name ? "(global) " + entry.name : "(global)";
}

const ITEMS = [];
for (const entry of DATA) {
  const group = groupLabel(entry);
  for (const fn of entry.f || []) {
    const full = entry.ns ? entry.ns + "." + fn.n : entry.o ? entry.o + ":" + fn.n : fn.n;
    const ret = fn.r && fn.r.length ? " → " + paramList(fn.r) : "";
    ITEMS.push({
      kind: "fn",
      name: fn.n,
      full,
      group,
      file: entry.file,
      sig: full + "(" + paramList(fn.a) + ")" + ret,
      doc: fn.d || "",
      flags: flagsOf(fn.fl),
      raw: fn.fl || {},
      hay: [full, fn.n, group, fn.d || "", paramList(fn.a), paramList(fn.r || [])].join(" ").toLowerCase(),
    });
  }
  for (const ev of entry.e || []) {
    ITEMS.push({
      kind: "event",
      name: ev.n,
      full: ev.n,
      group,
      file: entry.file,
      sig: ev.n + "  载荷: " + (ev.p && ev.p.length ? paramList(ev.p) : "无"),
      doc: ev.d || "",
      flags: flagsOf(ev.fl),
      raw: ev.fl || {},
      hay: [ev.n, group, ev.d || "", paramList(ev.p || [])].join(" ").toLowerCase(),
    });
  }
  for (const t of entry.t || []) {
    const isEnum = t.ty === "Enumeration";
    const full = isEnum ? "Enum." + t.n : t.n;
    const fields = (t.f || [])
      .map(([fname, ftype, fvalue]) => (isEnum ? fname + " = " + fvalue : fname + ": " + ftype))
      .join(", ");
    ITEMS.push({
      kind: isEnum ? "enum" : "struct",
      name: t.n,
      full,
      group,
      file: entry.file,
      sig: full + "  (" + t.ty + "): " + (fields || "（无成员）"),
      doc: "",
      flags: [],
      raw: {},
      hay: [full, t.n, group, fields].join(" ").toLowerCase(),
    });
  }
}

// ---------------------------------------------------------------- stats
if (has("--stats")) {
  const byKind = {};
  for (const it of ITEMS) byKind[it.kind] = (byKind[it.kind] || 0) + 1;
  const byGroup = new Map();
  for (const it of ITEMS) {
    if (!byGroup.has(it.group)) byGroup.set(it.group, { fn: 0, event: 0, type: 0 });
    const slot = byGroup.get(it.group);
    if (it.kind === "fn") slot.fn++;
    else if (it.kind === "event") slot.event++;
    else slot.type++;
  }
  console.log("客户端 " + (meta.clientVersion || "?") + "（编译 " + (meta.buildDate || "?") + "），抓取于 " + (meta.fetchedAt || "?"));
  console.log("来源 " + (meta.source || "?") + "  →  " + path.relative(ROOT, FILE));
  console.log(JSON.stringify(byKind));
  console.log("flags: " + ITEMS.filter((i) => i.flags.length).length + " 条带标记（" +
    ITEMS.filter((i) => i.raw.p).length + " 受保护 / " +
    ITEMS.filter((i) => i.raw.s).length + " 机密 / " +
    ITEMS.filter((i) => i.raw.re).length + " 受限事件）");
  const groups = [...byGroup.entries()].sort((a, b) => (b[1].fn + b[1].event + b[1].type) - (a[1].fn + a[1].event + a[1].type));
  console.log("分组 " + groups.length + " 个" + (has("--groups") ? "：" : "，最大的 15 个：" +
    groups.slice(0, 15).map(([g, c]) => g + "(" + (c.fn + c.event + c.type) + ")").join("  ") + "   [--stats --groups 列出全部]"));
  if (has("--groups")) console.log(groups.map(([g, c]) => g + "(" + (c.fn + c.event + c.type) + ")").join("  "));
  process.exit(0);
}

// ---------------------------------------------------------------- filter
const kindOpt = opt("--kind");
const nsOpt = opt("--ns");
const limit = Number(opt("--limit") || 25);
const wantProtected = has("--protected");
const wantSecret = has("--secret");
const wantRestricted = has("--restricted");
const exact = has("--exact");
const quiet = has("--exists");

function pickKind(it) {
  if (!kindOpt || kindOpt === "all") return true;
  if (kindOpt === "type") return it.kind === "enum" || it.kind === "struct";
  if (kindOpt === "fn" || kindOpt === "func" || kindOpt === "function") return it.kind === "fn";
  if (kindOpt === "event" || kindOpt === "events") return it.kind === "event";
  return it.kind === kindOpt;
}

function pickNs(it) {
  if (!nsOpt) return true;
  const want = nsOpt.toLowerCase();
  const group = it.group.toLowerCase();
  return group === want || group.replace(/^\(object\)\s+/, "") === want ||
    group.replace(/^\(global\)\s+/, "") === want || group === "(global) " + want;
}

const matched = ITEMS.filter((it) => {
  if (!pickKind(it) || !pickNs(it)) return false;
  if (wantProtected && !(it.raw.p || it.raw.pm)) return false;
  if (wantSecret && !(it.raw.s || it.raw.sp)) return false;
  if (wantRestricted && !(it.raw.r || it.raw.re)) return false;
  if (!words.length) return true;
  if (exact) {
    const q = words.join(" ").toLowerCase();
    return it.name.toLowerCase() === q || it.full.toLowerCase() === q;
  }
  return words.every((w) => it.hay.includes(w));
});

// rank: exact name > exact full > prefix > substring, functions before events before types
function score(it) {
  const q = words.join(" ").toLowerCase();
  let s = 0;
  if (!words.length) s = 0;
  else if (it.name.toLowerCase() === q || it.full.toLowerCase() === q) s = 100;
  else if (it.name.toLowerCase().startsWith(q) || it.full.toLowerCase().startsWith(q)) s = 60;
  else if (it.name.toLowerCase().includes(q) || it.full.toLowerCase().includes(q)) s = 40;
  else s = 10;
  s += it.kind === "fn" ? 3 : it.kind === "event" ? 2 : 1;
  s += it.flags.length ? 1 : 0;
  return s;
}
matched.sort((a, b) => score(b) - score(a) || a.full.localeCompare(b.full));

if (quiet) process.exit(matched.length ? 0 : 1);

if (!matched.length) {
  console.log("no match for: " + (words.join(" ") || "(empty query)"));
  if (meta.clientVersion) console.log("snapshot: client " + meta.clientVersion + ", " + ITEMS.length + " entries");
  process.exit(1);
}

const shown = limit > 0 ? matched.slice(0, limit) : matched;

if (has("--json")) {
  console.log(JSON.stringify(shown.map((it) => ({
    kind: it.kind,
    name: it.full,
    signature: it.sig,
    flags: it.flags,
    doc: it.doc,
    namespace: it.group,
    file: it.file,
  })), null, 2));
  process.exit(0);
}

for (const it of shown) {
  console.log(it.sig + (it.flags.length ? "   [" + it.flags.join("、") + "]" : ""));
  if (it.doc) console.log("    " + it.doc.replace(/\s+/g, " "));
  console.log("    · " + it.group + " · " + it.file);
}
console.log("");
console.log(shown.length + " / " + matched.length + " 条" + (limit > 0 && matched.length > limit ? "（--limit 0 看全部）" : "") +
  (meta.clientVersion ? "  ·  客户端 " + meta.clientVersion : ""));
