// tools/api-fetch.js
// Snapshot the wuxianwow.com API manual (「无限」1.60 client Lua API) into docs/api/.
//
// Source: https://wuxianwow.com/api/ . The page is a single HTML file that embeds
// the whole dump as <script id="data" type="application/json">:
//   [ { ns, name, o?, file, f:[functions], e:[events], t:[enums/structures] }, ... ]
// Function flags (from the page's own renderer, so the labels match the site):
//   p  受保护        protected global (IsProtectedFunction)
//   pg              protected global listed by the manual
//   pm 受保护的方法  protected object method (own frames always OK)
//   re 受限事件      registering it is refused by the client
//   s  机密          SecretReturns / SecretWhen*, array of aspect names
//   na 禁机密参数    SecretArguments = NotAllowed
//   at              SecretArguments = Allowed (tainted code may pass secrets)
//   r  受限          HasRestrictions
//   h  可安全钩      SecureHooksAllowed
//   m  可能无返回    MayReturnNothing
//   sp 机密载荷      event payload is secret
//   u  去重事件      event is deduplicated
//
// Usage:
//   node tools/api-fetch.js                  fetch + regenerate docs/api/*
//   node tools/api-fetch.js --force          regenerate even if the build is unchanged
//   node tools/api-fetch.js --html saved.html   parse a saved copy instead of the network
//   node tools/api-fetch.js --out <dir>      write somewhere else than docs/api
//
// Output (docs/ is gitignored -- these are local development references):
//   docs/api/data/wuxian-api.json   raw dump, byte-identical to the site
//   docs/api/data/meta.json         build facts, counts, fetch time
//   docs/api/MANUAL.md              prose part of the page (runtime, TOC rules, 无限专属 API...)
//   docs/api/FUNCTIONS.md           one line per function, grouped by namespace
//   docs/api/EVENTS.md              one line per event, with payload
//   docs/api/TYPES.md               enums and structures

const fs = require("fs");
const path = require("path");
const https = require("https");

const SOURCE = "https://wuxianwow.com/api/";
const ROOT = path.resolve(__dirname, "..");

const argv = process.argv.slice(2);
const FORCE = argv.includes("--force");
function opt(name, fallback) {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
}
const OUT = path.resolve(opt("--out", path.join(ROOT, "docs", "api")));
const HTML_FILE = opt("--html", null);

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

// ---------------------------------------------------------------- fetch
function fetchPage(url) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers: { "user-agent": "MonetUI-api-fetch/1.0" } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        return resolve(fetchPage(new URL(res.headers.location, url).href));
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error("HTTP " + res.statusCode + " for " + url));
      }
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    });
    req.on("error", reject);
    req.setTimeout(60000, () => req.destroy(new Error("timeout after 60s")));
  });
}

// ---------------------------------------------------------------- html -> data / prose
function extractData(html) {
  const m = html.match(/<script id="data" type="application\/json">([\s\S]*?)<\/script>/);
  if (!m) throw new Error("no <script id=\"data\"> block -- page layout changed?");
  return JSON.parse(m[1]);
}

function decodeEntities(s) {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&");
}

function factsFromHtml(html) {
  const facts = {};
  for (const m of html.matchAll(/<div class="fact"><div class="k">([\s\S]*?)<\/div><div class="v">([\s\S]*?)<\/div><\/div>/g)) {
    facts[decodeEntities(m[1].trim())] = decodeEntities(m[2].trim());
  }
  return facts;
}

function changeNotesFromHtml(html) {
  const notes = [];
  for (const m of html.matchAll(/<summary[^>]*>([\s\S]*?)<\/summary>/g)) {
    const text = decodeEntities(m[1].replace(/<[^>]+>/g, "")).replace(/\s+/g, " ").trim();
    if (text) notes.push(text);
  }
  return notes;
}

// The page lists the client's classic protected globals as a chip row under
// <h2>受保护的全局函数</h2>.  They are NOT in the API dump itself (UseAction,
// CastSpellByID, ... have no documentation entry), so the audit needs this list.
function protectedGlobalsFromHtml(html) {
  const at = html.indexOf("受保护的全局函数");
  if (at < 0) return [];
  const chips = html.indexOf('<div class="chips">', at);
  if (chips < 0) return [];
  const end = html.indexOf("</div>", chips);
  const block = html.slice(chips, end < 0 ? chips + 4000 : end);
  const names = [];
  for (const m of block.matchAll(/<code[^>]*>([\s\S]*?)<\/code>/g)) names.push(decodeEntities(m[1]).trim());
  return [...new Set(names.filter(Boolean))];
}

// Turn the page's prose (env / rules tabs + the api house rules) into markdown.
// Everything interactive is dropped: the browser widget, tab buttons, inputs.
function proseFromHtml(html) {
  let body = html.slice(html.indexOf("<body"), html.lastIndexOf("</body>"));
  body = body.replace(/<script[\s\S]*?<\/script>/g, "").replace(/<style[\s\S]*?<\/style>/g, "");
  // events / enums tabs are pure widget -- no prose in them
  body = body.replace(/<section id="tab-events"[\s\S]*?<\/section>/g, "");
  body = body.replace(/<section id="tab-enums"[\s\S]*?<\/section>/g, "");
  // keep the api tab's intro + flag legend, cut the browser widget and everything after
  const browserAt = body.indexOf('<div class="browser">');
  if (browserAt > 0) body = body.slice(0, browserAt);
  body = body.replace(/<nav[\s\S]*?<\/nav>/g, "");
  body = body.replace(/<footer[\s\S]*?<\/footer>/g, "");
  body = body.replace(/<div class="toolbar"[\s\S]*?<\/div>/g, "");
  body = body.replace(/<div class="count"[^>]*>\s*<\/div>/g, "");
  body = body.replace(/<button[\s\S]*?<\/button>/g, "");
  body = body.replace(/<input[^>]*>/g, "");

  // facts table
  body = body.replace(/<div class="facts">([\s\S]*?)<\/div>\s*(?=<details|<h2|<section)/, (all, inner) => {
    const rows = [];
    for (const m of inner.matchAll(/<div class="fact"><div class="k">([\s\S]*?)<\/div><div class="v">([\s\S]*?)<\/div><\/div>/g)) {
      rows.push("| " + decodeEntities(m[1].trim()) + " | " + decodeEntities(m[2].trim()) + " |");
    }
    return rows.length ? "\n| 项目 | 值 |\n|---|---|\n" + rows.join("\n") + "\n" : all;
  });

  // flag legend -> a definition list (one bullet per badge)
  body = body.replace(/<div class="legend">([\s\S]*?)<\/div>/, (all, inner) => {
    const lines = inner
      .split(/(?=<span><span class="badge)/)
      .map((chunk) => {
        const m = chunk.match(/<span class="badge[^"]*">([\s\S]*?)<\/span>([\s\S]*)$/);
        if (!m) return null;
        return "- `" + decodeEntities(m[1]).trim() + "` — " + decodeEntities(m[2].replace(/<[^>]+>/g, "")).trim();
      })
      .filter(Boolean);
    return lines.length ? "\n\n#### 标记\n\n" + lines.join("\n") + "\n" : all;
  });

  // chips (<code class="chip">a</code><code class="chip">b</code>) -> one inline list
  body = body.replace(/<div class="chips">([\s\S]*?)<\/div>/g, (all, inner) => {
    const items = [];
    for (const m of inner.matchAll(/<code[^>]*>([\s\S]*?)<\/code>/g)) items.push("`" + decodeEntities(m[1].trim()) + "`");
    return "\n" + items.join("、") + "\n";
  });

  // notes -> blockquote
  body = body.replace(/<div class="note">([\s\S]*?)<\/div>/g, (all, inner) => {
    const parts = decodeEntities(inner.replace(/<\/p>/g, "\n\n").replace(/<[^>]+>/g, ""))
      .split(/\n\s*\n/)
      .map((s) => s.replace(/\s+/g, " ").trim())
      .filter(Boolean);
    return "\n\n" + parts.map((s) => "> " + s).join("\n>\n") + "\n";
  });

  body = body.replace(/<h([1-6])[^>]*>/g, (all, n) => "\n\n" + "#".repeat(Number(n)) + " ");
  body = body.replace(/<\/h[1-6]>/g, "\n");
  body = body.replace(/<summary[^>]*>/g, "\n\n#### ");
  body = body.replace(/<\/summary>/g, "\n");
  body = body.replace(/<\/details>/g, "\n");
  body = body.replace(/<li[^>]*>/g, "\n- ");
  body = body.replace(/<\/li>/g, "");
  body = body.replace(/<p[^>]*>/g, "\n\n");
  body = body.replace(/<\/p>/g, "\n");
  body = body.replace(/<br\s*\/?>/g, "\n");
  body = body.replace(/<code[^>]*>/g, "`").replace(/<\/code>/g, "`");
  body = body.replace(/<(b|strong)>/g, "**").replace(/<\/(b|strong)>/g, "**");
  body = body.replace(/<span class="k">([\s\S]*?)<\/span>/g, "**$1**");
  body = body.replace(/<\/?span[^>]*>/g, "");
  body = body.replace(/<\/div>/g, "\n");
  body = body.replace(/<[^>]+>/g, "");
  body = decodeEntities(body);

  const lines = body.split(/\r?\n/).map((l) => l.replace(/[ \t]+$/g, ""));
  const out = [];
  for (const line of lines) {
    const blank = line.trim() === "";
    if (blank && out.length && out[out.length - 1].trim() === "") continue;
    if (blank && out.length === 0) continue;
    out.push(line);
  }
  return out.join("\n").replace(/\n{3,}/g, "\n\n").trim() + "\n";
}

// ---------------------------------------------------------------- render
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
  return parts.length ? " · " + parts.join("、") : "";
}

function fnFullName(entry, fn) {
  if (entry.ns) return entry.ns + "." + fn.n;
  if (entry.o) return entry.o + ":" + fn.n;
  return fn.n;
}

function groupLabel(entry) {
  if (entry.ns) return entry.ns;
  if (entry.o) return "(object) " + entry.o;
  return entry.name ? "(global) " + entry.name : "(global)";
}

function mdHeader(title, meta) {
  return [
    "# " + title,
    "",
    "> 自动生成，请勿手改。来源 " + SOURCE + "（客户端 " + meta.clientVersion + "，编译 " + meta.buildDate + "）。",
    "> 重新生成：`node tools/api-fetch.js`；查询：`node tools/api-lookup.js <关键词>`。",
    "",
  ].join("\n");
}

function renderFunctions(data, meta) {
  const groups = [];
  for (const entry of data) {
    if (!entry.f || !entry.f.length) continue;
    const lines = [];
    for (const fn of entry.f) {
      let line = "- **`" + fnFullName(entry, fn) + "`**(" + paramList(fn.a) + ")";
      if (fn.r && fn.r.length) line += " → `" + paramList(fn.r) + "`";
      line += flagsOf(fn.fl);
      if (fn.d) line += " — " + fn.d.replace(/\s+/g, " ");
      lines.push(line);
    }
    groups.push({ label: groupLabel(entry), file: entry.file, lines });
  }
  const rank = (l) => (l.startsWith("(global)") ? 1 : l.startsWith("(object)") ? 2 : 0);
  groups.sort((a, b) => rank(a.label) - rank(b.label) || a.label.localeCompare(b.label));

  const out = [mdHeader("无限 1.60 函数索引（" + meta.counts.functions + " 个）", meta)];
  out.push("格式：`名字(参数) → 返回值 · 标记 — 说明`。参数名后带 `?` 是可选参数，`= x` 是默认值。");
  out.push("标记含义见 `MANUAL.md` 末尾的「标记」一节；`机密[...]` 方括号里是 SecretReturns 的 aspect。");
  out.push("");
  for (const g of groups) {
    out.push("## " + g.label + "  ");
    out.push("*" + g.file + "*");
    out.push("");
    out.push(...g.lines);
    out.push("");
  }
  return out.join("\n");
}

function renderEvents(data, meta) {
  const rows = [];
  for (const entry of data) {
    for (const ev of entry.e || []) {
      let line = "- **`" + ev.n + "`**";
      if (ev.p && ev.p.length) line += " 载荷: `" + paramList(ev.p) + "`";
      else line += " 载荷: 无";
      line += flagsOf(ev.fl);
      if (ev.d) line += " — " + ev.d.replace(/\s+/g, " ");
      line += "  <sub>" + groupLabel(entry) + "</sub>";
      rows.push(line);
    }
  }
  rows.sort((a, b) => a.localeCompare(b));
  const out = [mdHeader("无限 1.60 事件索引（" + meta.counts.events + " 个）", meta)];
  out.push("格式：`事件名 载荷: 字段 · 标记 — 说明`。末尾 <sub> 是该事件所在命名空间/源文件分组。");
  out.push("注册前先确认没有 `受限事件` 标记。");
  out.push("");
  out.push(...rows);
  out.push("");
  return out.join("\n");
}

function renderTypes(data, meta) {
  const enums = [];
  const structs = [];
  for (const entry of data) {
    for (const t of entry.t || []) {
      const isEnum = t.ty === "Enumeration";
      const name = isEnum ? "Enum." + t.n : t.n;
      const fields = (t.f || [])
        .map(([fname, ftype, fvalue]) => (isEnum ? "`" + fname + "` = " + fvalue : "`" + fname + ": " + ftype + "`"))
        .join("、");
      const line = "- **`" + name + "`** (" + t.ty + "): " + (fields || "（无成员）") + "  <sub>" + groupLabel(entry) + "</sub>";
      (isEnum ? enums : structs).push(line);
    }
  }
  enums.sort((a, b) => a.localeCompare(b));
  structs.sort((a, b) => a.localeCompare(b));
  const out = [mdHeader("无限 1.60 枚举与结构（" + meta.counts.types + " 个）", meta)];
  out.push("枚举写作 `Enum.名字`（游戏里就是 `Enum.ForeverExperiencePreset` 这种全名）；结构是普通表类型名。");
  out.push("");
  out.push("## 枚举（" + enums.length + "）");
  out.push("");
  out.push(...enums);
  out.push("");
  out.push("## 结构（" + structs.length + "）");
  out.push("");
  out.push(...structs);
  out.push("");
  return out.join("\n");
}

// ---------------------------------------------------------------- main
(async () => {
  const html = HTML_FILE ? fs.readFileSync(path.resolve(HTML_FILE), "utf8") : await fetchPage(SOURCE);
  const data = extractData(html);
  const facts = factsFromHtml(html);
  const changeNotes = changeNotesFromHtml(html);

  const counts = {
    namespaces: data.filter((e) => e.ns).length,
    functions: data.reduce((n, e) => n + (e.f ? e.f.length : 0), 0),
    events: data.reduce((n, e) => n + (e.e ? e.e.length : 0), 0),
    types: data.reduce((n, e) => n + (e.t ? e.t.length : 0), 0),
  };

  const meta = {
    source: SOURCE,
    fetchedAt: new Date().toISOString(),
    clientVersion: facts["客户端版本"] || "unknown",
    buildDate: facts["编译日期"] || "unknown",
    lua: facts["Lua"] || "",
    counts,
    facts,
    changeNotes,
    protectedGlobals: protectedGlobalsFromHtml(html),
  };

  const dataDir = path.join(OUT, "data");
  fs.mkdirSync(dataDir, { recursive: true });
  const metaFile = path.join(dataDir, "meta.json");

  let previous = null;
  try {
    previous = JSON.parse(fs.readFileSync(metaFile, "utf8"));
  } catch (e) {
    previous = null;
  }
  if (!FORCE && previous && previous.clientVersion === meta.clientVersion && previous.counts &&
      JSON.stringify(previous.counts) === JSON.stringify(counts) &&
      fs.existsSync(path.join(dataDir, "wuxian-api.json"))) {
    console.log("unchanged: still client " + meta.clientVersion + " (" + counts.functions + " functions, " +
      counts.events + " events, " + counts.types + " types) -- nothing regenerated (use --force to rewrite)");
    return;
  }

  const rawJson = html.match(/<script id="data" type="application\/json">([\s\S]*?)<\/script>/)[1];
  fs.writeFileSync(path.join(dataDir, "wuxian-api.json"), rawJson.trim());
  fs.writeFileSync(metaFile, JSON.stringify(meta, null, 2) + "\n");

  const manual = [
    mdHeader("无限 1.60 插件 API 手册 · 正文", meta),
    proseFromHtml(html).trim(),
    "",
  ].join("\n");
  fs.writeFileSync(path.join(OUT, "MANUAL.md"), manual);
  fs.writeFileSync(path.join(OUT, "FUNCTIONS.md"), renderFunctions(data, meta));
  fs.writeFileSync(path.join(OUT, "EVENTS.md"), renderEvents(data, meta));
  fs.writeFileSync(path.join(OUT, "TYPES.md"), renderTypes(data, meta));

  console.log("client " + meta.clientVersion + " (built " + meta.buildDate + "), fetched " + meta.fetchedAt);
  console.log("  " + counts.namespaces + " namespaces, " + counts.functions + " functions, " +
    counts.events + " events, " + counts.types + " enums/structures");
  for (const f of ["data/wuxian-api.json", "data/meta.json", "MANUAL.md", "FUNCTIONS.md", "EVENTS.md", "TYPES.md"]) {
    const p = path.join(OUT, f);
    console.log("  wrote " + f + "  (" + Math.round(fs.statSync(p).size / 1024) + " KB)");
  }
})().catch((err) => {
  console.error("api-fetch failed: " + err.message);
  process.exit(1);
});
