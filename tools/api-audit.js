// tools/api-audit.js
// Static API audit of this addon against a Blizzard API documentation dump.
//
// Two sources, same parser:
//   default   docs/api/data/wuxian-api.json   -- 「无限」1.60 client docs, filled by
//             tools/api-fetch.js from https://wuxianwow.com/api/ . This is the
//             authoritative source for THIS client (see AGENTS.md).
//   --gethe   FUNCTIONS_INDEX.md / EVENTS_INDEX.md / Blizzard_APIDocumentationGenerated/
//             (Gethe/wow-ui-source "forever", formal-server export; the old baseline).
//
// Why this exists: the in-game linter cannot tell a missing name from an
// undocumented one on this client ("Unknown-function checks are off"), so the
// only way to catch a wrong C_* name, a wrong argument count, a misspelled
// event or a bad Enum.* value is to diff the source against the docs.
//
// Usage:
//   node tools/api-audit.js                 audit against docs/api (wuxian snapshot)
//   node tools/api-audit.js --gethe [apiDir]  audit against the Gethe dump
//   node tools/api-audit.js --libs          include Libs/ in the source pass
//   node tools/api-audit.js [apiDir] [addonDir]   explicit paths (implies --gethe
//                                                 unless docs/api exists)
//
// Exit code 1 when a hard finding exists (unknown C_* call / unknown event /
// unknown enum value / protected-global call / restricted event), 0 when the
// source is clean or only soft findings were reported.
//
// Scope notes (what this baseline CANNOT check, by design):
//   * FrameXML globals (GameTooltip_SetDefaultAnchor, SharedTooltip_SetBackdropStyle,
//     UIDropDownMenu_*, PanelTemplates_*, StaticPopup_*, ...) -- those live in
//     Blizzard's shipped Lua, verify them with the Ellesmere reference or in game;
//   * asset paths, .toc keys, XML template names;
//   * which widget type a `receiver:Method()` call really is. The wuxian source
//     documents object methods, so an unknown method name is reported as SOFT.


const fs = require("fs");
const path = require("path");

const ARGV = process.argv.slice(2);
const VALUED = ["--addon"];
const POS = [];
for (let i = 0; i < ARGV.length; i++) {
  if (ARGV[i].startsWith("--")) { if (VALUED.includes(ARGV[i])) i++; continue; }
  POS.push(ARGV[i]);
}
const API = POS[0] || "C:/Users/EastHillGu/Documents/wowaddonsdev/wow-forever-api";
const ADDON = path.resolve((() => { const i = ARGV.indexOf("--addon"); return i >= 0 ? ARGV[i + 1] : (POS[1] || path.join(__dirname, "..")); })());
const DOCS = path.join(API, "Blizzard_APIDocumentationGenerated");
const WITH_LIBS = process.argv.includes("--libs");
const WUXIAN_FILE = path.resolve(__dirname, "..", "docs", "api", "data", "wuxian-api.json");
const USE_WUXIAN = !process.argv.includes("--gethe") && !POS[0] && fs.existsSync(WUXIAN_FILE);

function readIndex(file, re) {
  const set = new Map();
  for (const line of fs.readFileSync(path.join(API, file), "utf8").split(/\r?\n/)) {
    const m = line.match(re);
    if (m) set.set(m[1], m[2] || "");
  }
  return set;
}

// ---------------------------------------------------------------- reference
const documented = new Map();     // full name -> doc text
const events = new Map();         // event name -> doc text
const enumNames = new Set();
const enumValues = new Set();     // "EnumName.Member"
const sig = new Map();            // full name -> { args:[], req, total }
const secureOnly = new Set();     // protected global: an addon call is refused (FORBIDDEN)
const restrictedEvents = new Set(); // registering it is refused by the client
const methodNames = new Set();    // every documented widget/object method name
const secretApis = new Map();     // full name -> SecretReturns aspects
const manualProtected = new Set(); // protected globals listed in the page prose only
let docFiles = [];
let SOURCE_LABEL = "";

if (USE_WUXIAN) {
  const DATA = JSON.parse(fs.readFileSync(WUXIAN_FILE, "utf8"));
  let meta = {};
  try { meta = JSON.parse(fs.readFileSync(path.join(path.dirname(WUXIAN_FILE), "meta.json"), "utf8")); } catch (e) { meta = {}; }
  // Protected globals that the client never documents (UseAction, CastSpellByID, ...):
  // the page lists them in prose, api-fetch copies the list into meta.json.
  for (const name of meta.protectedGlobals || []) { secureOnly.add(name); manualProtected.add(name); }
  for (const entry of DATA) {
    for (const fn of entry.f || []) {
      const full = entry.ns ? entry.ns + "." + fn.n : entry.o ? entry.o + ":" + fn.n : fn.n;
      documented.set(full, fn.d || "");
      const args = fn.a.map(a => a[0] + ":" + a[1] + (a[2] || a[3] !== null && a[3] !== undefined ? "?" : ""));
      // A default value implies the argument is optional even when the client docs do
      // not mark it nilable (UnitHealth's usePredicted = true is the classic case).
      sig.set(full, { args, req: fn.a.filter(a => !a[2] && (a[3] === null || a[3] === undefined)).length, total: fn.a.length });
      if (entry.o) methodNames.add(fn.n);
      if (fn.fl && fn.fl.p) secureOnly.add(full);
      if (fn.fl && fn.fl.s) secretApis.set(full, (fn.fl.s || []).join(", "));
      if (fn.fl && fn.fl.sp) secretApis.set(full, "secret payload");
    }
    for (const ev of entry.e || []) {
      events.set(ev.n, ev.d || "");
      if (ev.fl && ev.fl.re) restrictedEvents.add(ev.n);
    }
    for (const t of entry.t || []) {
      if (t.ty !== "Enumeration") continue;
      enumNames.add(t.n);
      for (const f of t.f || []) enumValues.add(t.n + "." + f[0]);
    }
  }
  SOURCE_LABEL = path.relative(ADDON, WUXIAN_FILE) + (meta.clientVersion ? "  (client " + meta.clientVersion + ", built " + meta.buildDate + ")" : "");
} else {
  function readIndex(file, re) {
    const set = new Map();
    for (const line of fs.readFileSync(path.join(API, file), "utf8").split(/\r?\n/)) {
      const m = line.match(re);
      if (m) set.set(m[1], m[2] || "");
    }
    return set;
  }
  for (const [k, v] of readIndex("FUNCTIONS_INDEX.md", /^\|\s*`([^`]+)`\s*\|\s*\[([^\]]+)\]/)) documented.set(k, v);
  for (const [k, v] of readIndex("EVENTS_INDEX.md", /^\|\s*`([A-Z0-9_]+)`\s*\|/)) events.set(k, v);

  docFiles = fs.readdirSync(DOCS).filter(f => f.endsWith(".lua"));

  function braceEnd(t, open) {
    let depth = 0;
    for (let i = open; i < t.length; i++) {
      const c = t[i];
      if (c === '"' || c === "'") {
        const q = c; i++;
        while (i < t.length && t[i] !== q) { if (t[i] === "\\") i++; i++; }
        continue;
      }
      if (c === "{") depth++;
      else if (c === "}") { depth--; if (depth === 0) return i; }
    }
    return -1;
  }
  function argsBlock(slice) {
    // Word-bounded search: a plain indexOf("Arguments") matches inside
    // "SecretArguments = \"AllowedWhenTainted\"", and the following brace then
    // belongs to the Documentation table -- which is why some functions used to
    // be reported as taking no arguments at all.
    const at = slice.search(/\bArguments\s*=/);
    if (at < 0) return { args: [], req: 0, total: 0 };
    const open = slice.indexOf("{", at);
    if (open < 0) return { args: [], req: 0, total: 0 };
    const end = braceEnd(slice, open);
    const block = slice.slice(open, end + 1);
    const entries = [...block.matchAll(/\{\s*Name = "([A-Za-z0-9_]+)",\s*Type = "([^"]+)"([^}]*)\}/g)];
    const args = [];
    let req = 0;
    for (const e of entries) {
      const meta = e[3] || "";
      const optional = /Nilable = true/.test(meta) || /Default =/.test(meta);
      args.push(e[1] + ":" + e[2] + (optional ? "?" : ""));
      if (!optional) req++;
    }
    return { args, req, total: entries.length };
  }

  for (const f of docFiles) {
    const t = fs.readFileSync(path.join(DOCS, f), "utf8");
    const nsm = t.match(/^\s*Namespace = "([A-Za-z0-9_]+)"/m);
    const ns = nsm ? nsm[1] : null;
    const isSecure = /^\s*Environment = "SecureOnly"/m.test(t);

    for (const m of t.matchAll(/Name = "([A-Za-z0-9_]+)",\s*\r?\n\s*Type = "Enumeration"/g)) enumNames.add(m[1]);
    for (const m of t.matchAll(/\{ Name = "([A-Za-z0-9_]+)", Type = "([A-Za-z0-9_]+)", EnumValue = -?\d+ \}/g)) enumValues.add(m[2] + "." + m[1]);

    // One entry per documented function: the window runs from this Name to the next
    // function Name.  A "walk out to the matching braces" slice is not reliable here,
    // because Documentation strings may contain unbalanced braces, which corrupted the
    // slice and made e.g. C_Spell.GetSpellCooldown look like it took no arguments.
    const fnMatches = [...t.matchAll(/Name = "([A-Za-z0-9_]+)",\s*\r?\n\s*Type = "Function"/g)];
    for (let i = 0; i < fnMatches.length; i++) {
      const m = fnMatches[i];
      const stop = i + 1 < fnMatches.length ? fnMatches[i + 1].index : Math.min(t.length, m.index + 4000);
      const full = ns ? ns + "." + m[1] : m[1];
      if (!sig.has(full)) sig.set(full, argsBlock(t.slice(m.index, stop)));
      if (isSecure) secureOnly.add(full);
    }
  }
  SOURCE_LABEL = API;
}

const docGlobals = new Set([...documented.keys()].filter(k => !k.includes(".") && !k.includes(":") && !k.endsWith(")")));
const cByFunc = new Map();
for (const key of documented.keys()) {
  const dot = key.indexOf(".");
  if (dot > 0 && !key.includes(":")) {
    const fn = key.slice(dot + 1);
    if (!cByFunc.has(fn)) cByFunc.set(fn, []);
    cByFunc.get(fn).push(key);
  }
}

// ---------------------------------------------------------------- source pass
const files = [];
(function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (e.name !== ".git" && e.name !== "tools" && (WITH_LIBS || e.name !== "Libs")) walk(p);
    } else if (e.name.endsWith(".lua")) files.push(p);
  }
})(ADDON);

// comments and string literals blanked out (newlines kept, so offsets stay valid)
function stripCode(src, keepStrings) {
  const blank = s => s.replace(/[^\n]/g, " ");
  let out = "", i = 0, n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === '"' || c === "'") {
      const q = c; let j = i + 1;
      while (j < n && src[j] !== q) { if (src[j] === "\\") j++; j++; }
      out += keepStrings ? src.slice(i, Math.min(j + 1, n)) : blank(src.slice(i, Math.min(j + 1, n)));
      i = j + 1; continue;
    }
    if (c === "-" && src[i + 1] === "-") {
      let eq = 0, j = i + 2;
      if (src[j] === "[") {
        j++;
        while (src[j] === "=") { eq++; j++; }
        if (src[j] === "[") {
          const close = "]" + "=".repeat(eq) + "]";
          const end = src.indexOf(close, j + 1);
          const stop = end < 0 ? n : end + close.length;
          out += blank(src.slice(i, stop)); i = stop; continue;
        }
      }
      let k = i; while (k < n && src[k] !== "\n") k++;
      out += blank(src.slice(i, k)); i = k; continue;
    }
    out += c; i++;
  }
  return out;
}
function countArgs(code, openIdx) {
  let depth = 0, args = 1, empty = true;
  // Commas inside a `function ... end` body are not argument separators, so block
  // keywords opened at depth 1 are tracked: C_Timer.After(0, function() for i=1,3 do end end)
  // used to count 3 arguments.  for/while are followed by `do`, which closes the
  // "expect a do" flag instead of opening a second block.
  let blocks = 0, expectDo = 0;
  for (let i = openIdx; i < code.length; i++) {
    const c = code[i];
    if (c === '"' || c === "'") {
      const q = c; i++;
      while (i < code.length && code[i] !== q) { if (code[i] === "\\") i++; i++; }
      empty = false; continue;
    }
    if (/[A-Za-z_]/.test(c)) {
      let j = i;
      while (j < code.length && /[A-Za-z0-9_]/.test(code[j])) j++;
      const word = code.slice(i, j);
      if (depth >= 1) {
        if (word === "function" || word === "if") blocks++;
        else if (word === "for" || word === "while") { blocks++; expectDo++; }
        else if (word === "do") { if (expectDo > 0) expectDo--; else if (blocks > 0) blocks++; }
        else if (word === "end") { if (blocks > 0) blocks--; }
      }
      i = j - 1;
      empty = false;
      continue;
    }
    if (c === "(" || c === "{" || c === "[") { depth++; if (depth > 1) empty = false; continue; }
    if (c === ")" || c === "}" || c === "]") { depth--; if (depth === 0) return empty ? 0 : args; continue; }
    if (depth === 1 && c === ",") { if (blocks === 0) args++; continue; }
    if (depth >= 1 && !/\s/.test(c)) empty = false;
  }
  return null;
}

const apiUses = [], enumUses = [], eventUses = [], sigIssues = [], legacy = [], protectedUses = [];
const calledNames = new Map();      // called name -> first few "file:line"
const undocumentedGlobals = new Map(); // bare global, not in the client docs and not ours
const methodUses = new Map();       // "obj:Method" name -> first few "file:line"
const nameRefs = new Map();         // documented name -> first few "file:line" (call or bare reference)
const sourceMethods = new Set();    // methods the addon defines itself
// Libs are excluded from the *call* pass but their method names still count as defined
// (LibMonetColor's LMC:GetActiveProfile and friends are called all over Utils/).
(function collectLibMethods(dir) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { collectLibMethods(p); continue; }
    if (!e.name.endsWith(".lua")) continue;
    const code = stripCode(fs.readFileSync(p, "utf8"), false);
    for (const m of code.matchAll(/(?:function[ \t]+[A-Za-z0-9_.]*[.:]([A-Za-z0-9_]+)[ \t]*\(|^[ \t]*[A-Za-z0-9_]+[.:]([A-Za-z0-9_]+)[ \t]*=[ \t]*function)/gm)) sourceMethods.add(m[1] || m[2]);
    // libs also expose helpers written as plain locals (CallbackHandler:New is `local function New`)
    for (const m of code.matchAll(/\blocal[ \t]+function[ \t]+([A-Za-z0-9_]+)/g)) sourceMethods.add(m[1]);
  }
})(path.join(ADDON, "Libs"));
const STD = new Set(("assert collectgarbage error getmetatable ipairs next pairs pcall print rawequal rawget rawset require select setmetatable tonumber tostring type unpack xpcall loadstring " +
  "string table math os io coroutine debug bit bit32 utf8").split(/\s+/));
// Client globals that ship as C functions / FrameXML natives and are therefore absent
// from the API docs.  Anything else starting with a capital letter is worth a look.
const KNOWN_CLIENT_GLOBALS = new Set([
  "CreateFrame", "CreateColor", "CreateFont", "CreateTexture", "CreateForbiddenFrame",
  "hooksecurefunc", "securecall", "secureexecuterange", "geterrorhandler", "seterrorhandler",
  "InCombatLockdown", "GetCVarBool", "GetCVarDefault", "IsInGroup", "IsInRaid", "IsInGuild",
  "IsModifiedClick", "IsShiftKeyDown", "IsControlKeyDown", "IsAltKeyDown", "GetLocale",
  "PixelUtil", "BackdropTemplateMixin", "FormatLargeNumber", "BreakUpLargeNumbers",
]);
// Widget/Blizzard-Lua methods the client provides but does not document as object API.
const WIDGET_EXTRA = new Map([
  ["SetBackdrop", "BackdropTemplate"], ["GetBackdrop", "BackdropTemplate"],
  ["SetBackdropColor", "BackdropTemplate"], ["GetBackdropColor", "BackdropTemplate"],
  ["SetBackdropBorderColor", "BackdropTemplate"], ["GetBackdropBorderColor", "BackdropTemplate"],
  ["SetOwner", "GameTooltip / EchoFrame"], ["AddLine", "GameTooltip"], ["AddDoubleLine", "GameTooltip"],
  ["ChildUpdate", "SecureHandler"], ["GetScrollBar", "Blizzard ScrollFrame"],
  ["Cancel", "C_Timer ticker object"], ["IsAttachedToButton", "SpellFlyout"],
  ["New", "CallbackHandler-1.0 (ships with the client, not in Libs/)"],
  ["GetRGBA", "ColorMixin"], ["SetRGBA", "ColorMixin"],
  ["SetBorderColor", "NineSlice"], ["SetCenterColor", "NineSlice"],
  ["GetBorderColor", "NineSlice"], ["GetCenterColor", "NineSlice"],
]);
const LUA_STR_METHODS = new Set(["format", "find", "gsub", "gmatch", "sub", "byte", "char", "rep", "upper", "lower", "len", "match", "gfind", "reverse"]);

for (const f of files) {
  const rel = path.relative(ADDON, f);
  const withStrings = stripCode(fs.readFileSync(f, "utf8"), true);
  const codeOnly = stripCode(fs.readFileSync(f, "utf8"), false);

  withStrings.split(/\r?\n/).forEach((line, idx) => {
    for (const m of line.matchAll(/\b(C_[A-Za-z0-9_]+)\.([A-Za-z0-9_]+)/g)) apiUses.push({ file: rel, line: idx + 1, name: m[1] + "." + m[2] });
    for (const m of line.matchAll(/(?:RegisterEvent|UnregisterEvent|RegisterUnitEvent|IsEventRegistered|EventBus:Register|EventBus:Unregister)\s*\(\s*"([A-Z][A-Z0-9_]+)"/g)) eventUses.push({ file: rel, line: idx + 1, name: m[1] });
  });
  withStrings.split(/\r?\n/).forEach((line, idx) => {
    for (const m of line.matchAll(/\bEnum\.([A-Za-z0-9_]+)(?:\.([A-Za-z0-9_]+))?/g)) enumUses.push({ file: rel, line: idx + 1, full: m[1], val: m[2] });
  });

  const locals = new Set();
  for (const m of codeOnly.matchAll(/\blocal\s+function\s+([A-Za-z0-9_]+)/g)) locals.add(m[1]);
  for (const m of codeOnly.matchAll(/\blocal\s+([A-Za-z0-9_]+)\s*(?:,|=)/g)) locals.add(m[1]);
  for (const m of codeOnly.matchAll(/\bfunction\s+([A-Za-z0-9_.:]+)\s*\(/g)) locals.add(m[1].split(/[.:]/).pop());
  for (const m of codeOnly.matchAll(/^\s*([A-Za-z0-9_]+)\s*=\s*function/gm)) locals.add(m[1]);
  // parameters of every function (named or anonymous) are locals too
  for (const m of codeOnly.matchAll(/\bfunction\s*[A-Za-z0-9_.:]*\s*\(([^)]*)\)/g)) {
    for (const p of m[1].split(",")) {
      const n = p.trim().replace(/^\.\.\.$/, "");
      if (n) locals.add(n);
    }
  }
  // methods this addon defines itself: `function M:Foo(`, `M.Foo = function`, `M:Foo = function`.
  // The `=` form is required for the non-`function` alternative -- without it a line that
  // merely starts with a call (`frame:Hide()`) counts as a definition.
  for (const m of codeOnly.matchAll(/(?:function[ \t]+[A-Za-z0-9_.]*[.:]([A-Za-z0-9_]+)[ \t]*\(|^[ \t]*[A-Za-z0-9_]+[.:]([A-Za-z0-9_]+)[ \t]*=[ \t]*function)/gm)) sourceMethods.add(m[1] || m[2]);
  // every `receiver:Method(` call
  for (const m of codeOnly.matchAll(/(?<![\w.:])([A-Za-z0-9_]+):([A-Za-z0-9_]+)\s*\(/g)) {
    const line = codeOnly.slice(0, m.index).split("\n").length;
    if (!methodUses.has(m[2])) methodUses.set(m[2], []);
    if (methodUses.get(m[2]).length < 3) methodUses.get(m[2]).push(rel + ":" + line);
  }

  // every reference to a documented name, with or without call syntax
  // (pcall(C_ActionBar.GetActionCooldown, slot), local f = C_X.Y, aliases ...)
  for (const m of codeOnly.matchAll(/[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*/g)) {
    const n = m[0];
    if (!secretApis.has(n) && !secureOnly.has(n)) continue;
    const line = codeOnly.slice(0, m.index).split("\n").length;
    if (!nameRefs.has(n)) nameRefs.set(n, []);
    if (nameRefs.get(n).length < 4) nameRefs.get(n).push(rel + ":" + line);
    if (secureOnly.has(n) && !locals.has(n)) protectedUses.push({ file: rel, line, name: n, manual: manualProtected.has(n) });
  }

  for (const m of codeOnly.matchAll(/(?<![\w.:])(C_[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)?|[A-Za-z_][A-Za-z0-9_]*)\s*\(/g)) {
    const name = m[1];
    const line = codeOnly.slice(0, m.index).split("\n").length;
    if (!calledNames.has(name)) calledNames.set(name, []);
    if (calledNames.get(name).length < 3) calledNames.get(name).push(rel + ":" + line);
    // Protected globals are checked before the signature lookup: the client leaves most
    // of them out of the documentation entirely (UseAction, CastSpellByID, ...).
    if (secureOnly.has(name) && !locals.has(name)) protectedUses.push({ file: rel, line, name, manual: manualProtected.has(name) });
    const info = sig.get(name);
    if (!info) {
      if (!name.startsWith("C_") && !secureOnly.has(name) && name === name[0].toUpperCase() + name.slice(1) && !locals.has(name) && !STD.has(name) && !docGlobals.has(name)) {
        if (!KNOWN_CLIENT_GLOBALS.has(name)) {
          if (!undocumentedGlobals.has(name)) undocumentedGlobals.set(name, []);
          if (undocumentedGlobals.get(name).length < 3) undocumentedGlobals.get(name).push(rel + ":" + line);
        }
        const alt = (cByFunc.get(name) || []).filter(k => !secureOnly.has(k));
        // CreateFrame only "collides" with C_PingSecure.CreateFrame by name; the legacy global is the correct call.
        if (alt.length && name !== "CreateFrame") legacy.push({ file: rel, line, name, alt });
      }
      continue;
    }
    if (name.startsWith("C_") && secureOnly.has(name)) protectedUses.push({ file: rel, line, name });
    if (name.startsWith("C_") && secureOnly.has(name)) protectedUses.push({ file: rel, line, name });
    if (!name.startsWith("C_") && (locals.has(name) || !docGlobals.has(name))) continue;
    // count on the string-preserving copy: the blanked one turns "x" into spaces, i.e. F("x") would count as F()
    const argc = countArgs(withStrings, m.index + m[0].length - 1);
    if (argc === null) continue;
    if (argc < info.req || argc > info.total) {
      sigIssues.push({ file: rel, line, name, used: argc, req: info.req, max: info.total, sig: info.args.join(", ") });
    }
  }
}

const byName = new Map();
for (const u of apiUses) { if (!byName.has(u.name)) byName.set(u.name, []); byName.get(u.name).push(u); }

const hard = { unknownApi: [], unknownEnum: [], unknownEvent: [], secureOnly: [], restrictedEvent: [], protectedUse: [] };
// Functions the client still installs from its deprecated shim layer, so the dump does
// not list them but calling them is safe.  Each entry must name the shipped file that
// provides it -- verify with wow_ui_grep before adding one.
const DEPRECATED_SHIMS = new Map([
  ["C_Spell.GetSpellLossOfControlCooldown", "Blizzard_DeprecatedSpellScript/Deprecated_SpellScript.lua:38"],
]);
hard.secureOnly = [...byName.keys()].filter(k => secureOnly.has(k));
hard.unknownApi = [...byName.keys()].filter(k => !documented.has(k) && !DEPRECATED_SHIMS.has(k)).sort();
// Enumerations the client installs but the dump never enumerates.  Same rule as
// DEPRECATED_SHIMS: every entry must name its evidence -- verify before adding one.
const CLIENT_ENUMS_NO_DUMP = new Map([
  ["GameRule", "本站手册「加载开关」：GameRule 枚举编号不在文档里，实际生效值要登录后用 C_GameRules.IsGameRuleActive 读（Utils/Compat.lua 探的就是它）"],
]);
const enumOutsideDump = enumUses.filter(u => CLIENT_ENUMS_NO_DUMP.has(u.full));
hard.unknownEnum = enumUses.filter(u => !CLIENT_ENUMS_NO_DUMP.has(u.full) &&
  (u.val ? !(enumNames.has(u.full) && enumValues.has(u.full + "." + u.val)) : !enumNames.has(u.full)));
hard.unknownEvent = eventUses.filter(u => !u.name.startsWith("MONETUI_") && !events.has(u.name));
hard.restrictedEvent = eventUses.filter(u => restrictedEvents.has(u.name));
// de-duplicate the protected call list per (file, line, name)
hard.protectedUse = [...new Map(protectedUses.map(u => [u.file + ":" + u.line + ":" + u.name, u])).values()];
const shimUses = [...byName.keys()].filter(k => DEPRECATED_SHIMS.has(k)).sort();
const secretHits = [...new Set([...nameRefs.keys()].filter(n => secretApis.has(n)).concat([...calledNames.keys()].filter(n => secretApis.has(n))))].sort();

// ---------------------------------------------------------------- output
const ok = !hard.unknownApi.length && !hard.unknownEnum.length && !hard.unknownEvent.length &&
  !hard.secureOnly.length && !hard.restrictedEvent.length;
const p = s => console.log(s);

p("docs:   " + SOURCE_LABEL);
p("        " + documented.size + " functions / " + events.size + " events / " + enumNames.size + " enums / " +
  methodNames.size + " object methods" + (docFiles.length ? " / " + docFiles.length + " source files" : ""));
p("addon:  " + ADDON);
p("source: " + files.length + " lua files, " + apiUses.length + " C_* calls (" + byName.size + " distinct), " + enumUses.length + " Enum.*, " + eventUses.length + " event registrations");
p("");

p("HARD  unknown C_* call:      " + hard.unknownApi.length);
for (const k of hard.unknownApi) for (const u of byName.get(k)) p("  - " + u.file + ":" + u.line + "  " + k);
p("HARD  SecureOnly call:       " + hard.secureOnly.length);
for (const k of hard.secureOnly) p("  - " + k);
p("HARD  unknown event:         " + hard.unknownEvent.length);
for (const u of hard.unknownEvent) p("  - " + u.file + ":" + u.line + "  " + u.name);
p("HARD  restricted event:      " + hard.restrictedEvent.length + "  (registering it is refused)");
for (const u of hard.restrictedEvent) p("  - " + u.file + ":" + u.line + "  " + u.name);
p("HARD  unknown enum value:    " + hard.unknownEnum.length);
for (const u of hard.unknownEnum) p("  - " + u.file + ":" + u.line + "  Enum." + u.full + (u.val ? "." + u.val : ""));
p("");
// Protected globals are legal out of combat (and from secure code); in combat the client
// raises ADDON_ACTION_BLOCKED.  Every hit must sit behind InCombatLockdown() or a snippet.
p("CHECK protected global:      " + hard.protectedUse.length + "  (legal out of combat / in secure code only -- verify the guard)");
for (const u of hard.protectedUse) p("  - " + u.file + ":" + u.line + "  " + u.name + (u.manual ? "  (listed in the manual, not in the dump)" : ""));
p("");
p("SOFT  argument count:        " + sigIssues.length);
for (const s of sigIssues) p("  - " + s.file + ":" + s.line + "  " + s.name + "  passed " + s.used + ", docs " + s.req + " required / " + s.max + " max  (" + s.sig + ")");
p("SOFT  deprecated shim used:  " + shimUses.length + "  (exists in the client, absent from the dump)");
for (const k of shimUses) p("  - " + k + "  <- " + DEPRECATED_SHIMS.get(k));
p("SOFT  legacy global used:    " + legacy.length);
for (const [name, uses] of [...legacy.reduce((m, l) => m.set(l.name, [...(m.get(l.name) || []), l]), new Map()).entries()].sort()) {
  p("  - " + name + "  x" + uses.length + "  -> documented as " + uses[0].alt.join(" / ") + "   first " + uses[0].file + ":" + uses[0].line);
}

// ---------------------------------------------------------------- info
p("");
p("INFO  secret-returning API:  " + secretHits.length + "  (returns may be secret under a restriction; guard before maths/compare)");
for (const n of secretHits) p("  - " + n + "  [" + secretApis.get(n) + "]  " + ((nameRefs.get(n) || calledNames.get(n) || []).join("  ")));
const unknownMethods = [...methodUses.keys()].filter(n => !methodNames.has(n) && !sourceMethods.has(n) && !WIDGET_EXTRA.has(n) && !LUA_STR_METHODS.has(n)).sort();
p("INFO  undocumented method:  " + unknownMethods.length + " of " + methodUses.size + "  (not in the docs and not defined here -- check by hand)");
for (const n of unknownMethods) p("  - " + n + "  " + methodUses.get(n).join("  "));
p("INFO  undocumented global:  " + undocumentedGlobals.size + "  (not in the docs, not defined here, not a known client global)");
for (const [n, locs] of [...undocumentedGlobals.entries()].sort()) p("  - " + n + "  " + locs.join("  "));
p("INFO  enum the client installs but the dump omits:  " + enumOutsideDump.length + "  (exempted with evidence -- not a free pass)");
for (const u of enumOutsideDump) p("  - " + u.file + ":" + u.line + "  Enum." + u.full + (u.val ? "." + u.val : "") + "  <- " + CLIENT_ENUMS_NO_DUMP.get(u.full));

// ---------------------------------------------------------------- toc
const tocFile = path.join(ADDON, "MonetUI.toc");
const TOC_DIRECTIVES = new Set(["Interface", "Title", "Author", "Version", "Notes", "Category", "Dependencies",
  "OptionalDeps", "SavedVariables", "SavedVariablesPerCharacter", "LoadOnDemand", "LoadWith", "LoadManagers",
  "DefaultState", "IconTexture", "IconAtlas", "AddonCompartmentFunc", "AddonCompartmentFuncOnEnter",
  "AddonCompartmentFuncOnLeave", "AllowLoad", "AllowLoadGameType", "LoadSavedVariablesFirst", "Secure"]);
const tocProblems = [];
if (fs.existsSync(tocFile)) {
  const tocLines = fs.readFileSync(tocFile, "utf8").split(/\r?\n/);
  tocLines.forEach((line, idx) => {
    const d = line.match(/^##\s*([A-Za-z][A-Za-z0-9_-]*)\s*:/);
    if (d && !TOC_DIRECTIVES.has(d[1]) && !d[1].startsWith("X-")) tocProblems.push(`MonetUI.toc:${idx + 1}  unknown directive ## ${d[1]}`);
    const f = line.match(/^([^#].*\.(lua|xml))\s*$/);
    if (f) {
      const rel = f[1].trim().replace(/\\/g, "/");
      if (!fs.existsSync(path.join(ADDON, rel))) tocProblems.push(`MonetUI.toc:${idx + 1}  missing file ${rel}`);
    }
  });
  const iface = tocLines.map(l => l.match(/^##\s*Interface\s*:\s*(\d+)/)).find(Boolean);
  p("INFO  toc:  " + (iface ? "Interface " + iface[1] : "no ## Interface") + ", " + tocProblems.length + " problem(s)");
} else {
  p("INFO  toc:  MonetUI.toc not found");
}
for (const t of tocProblems) p("  - " + t);
p("");
p(ok ? "result: no hard finding." : "result: HARD findings above must be fixed.");

process.exit(ok ? 0 : 1);
