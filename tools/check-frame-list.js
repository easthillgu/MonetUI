// Every name in a M:Panel `frames` list must be reachable from code, otherwise the list is decoration.
// The list exists so `/mui skins diagnose` probes Blizzard globals and reports which ones the skin
// actually reaches; a name listed but never looked up in Lua means diagnose claims coverage the skin
// does not have, which is worse than not listing it.
//
// `frames` blocks may hold three shapes (M:Panel flattens all of them):
//   "PlayerSpellsFrame"            -- a literal global name
//   "DressUpFrame.LinkButton"      -- a dotted path, resolved by Skin:Need at diagnose time
//   PLAYERSPELLS_TABS              -- a const table shared with the skin function
// A const table only proves reachability when the skin code itself walks it; if its only reference is
// the frames list, listing it says nothing about what the skin touches.
//
// Names built at runtime (`_G["StaticPopup" .. index .. "Button1"]`, `_G[name .. "CloseButton"]`)
// are legitimately unreachable by static scan, so they are declared in ALLOW_DYNAMIC with the reason.
//
// Run: node tools/check-frame-list.js
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const luaFiles = [];
(function walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    if (['.git', 'tools', 'docs', 'Assets', 'Libs'].includes(e.name)) continue;
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p);
    else if (/\.lua$/.test(e.name)) luaFiles.push(p);
  }
})(root);

const skinsFiles = luaFiles.filter(f => f.includes(path.join('Modules', 'Skins')));

// Prose is not a code path: a name that only appears in a comment has never been looked up, and the
// apostrophes inside those comments would also break any later string-stripping pass.
const stripComment = line => line.replace(/--.*$/, '');
const sources = new Map(luaFiles.map(f => [f, fs.readFileSync(f, 'utf8').split(/\r?\n/).map(stripComment)]));

// Reached only through string concatenation at runtime. Keep this list short and justified --
// a name added here is one static analysis can never check again. Three shapes are already covered
// by isReached() and must NOT be parked here: `N`-suffixed families built from a quoted prefix
// ("StaticPopup"..index), `<Window>CloseButton` derived by M:SkinWindow, and dotted member paths
// whose segments each appear in code.
const ALLOW_DYNAMIC = new Map(Object.entries({
  // System.lua builds the four static popups and their buttons as "StaticPopup"..index and
  // "StaticPopup"..index.."Button1" etc.
  StaticPopup1Button1: 'System.lua 拼接 "StaticPopup"..index.."Button1"',
  StaticPopup1Button2: 'System.lua 拼接 "StaticPopup"..index.."Button2"',
  StaticPopup2Button1: 'System.lua 拼接 "StaticPopup"..index.."Button1"',
  StaticPopup3Button1: 'System.lua 拼接 "StaticPopup"..index.."Button1"',
  StaticPopup4Button1: 'System.lua 拼接 "StaticPopup"..index.."Button1"',
  // Forever.lua: LFG 子视图的成员，既不是全局名，也不在皮肤写出的点路径里。
  LFGBrowseFrameCategoryDropdown: 'Forever.lua 的成员访问',
  LFGBrowseFrameActivityDropdown: 'Forever.lua 的成员访问',
}));

const NAME = '[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*';
const esc = s => s.replace(/\./g, '\\.');

/** Line ranges `[from, to]` (inclusive) of every `frames = { ... }` block, outermost only. */
function blocks(lines, opener) {
  const found = [];
  for (let i = 0; i < lines.length; i++) {
    if (!opener.test(lines[i])) continue;
    let depth = 0, started = false, j = i;
    for (; j < lines.length; j++) {
      for (const ch of lines[j]) {
        if (ch === '{') { depth++; started = true; }
        else if (ch === '}') depth--;
      }
      // `<=` not `===`: the trailing `} })` of a M:Panel call pushes past zero on the same line.
      if (started && depth <= 0) break;
    }
    found.push([i, j]);
    i = j;
  }
  return found;
}

const framesRanges = new Map();
for (const f of luaFiles) framesRanges.set(f, blocks(sources.get(f), /frames\s*=\s*\{/));

const inFrames = (f, i) => framesRanges.get(f).some(([a, b]) => i >= a && i <= b);

/** `local NAME = { ... }` groups: members plus the line span of the definition. */
function constTables(lines) {
  const tables = new Map();
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^\s*local\s+([A-Z][A-Z0-9_]*)\s*=\s*\{/);
    if (!m) continue;
    let depth = 0, started = false, j = i;
    for (; j < lines.length; j++) {
      for (const ch of lines[j]) {
        if (ch === '{') { depth++; started = true; }
        else if (ch === '}') depth--;
      }
      if (started && depth <= 0) break;
    }
    const body = lines.slice(i, j + 1).join('\n');
    const members = [...body.matchAll(new RegExp(`["'](${NAME})["']`, 'g'))].map(x => x[1]);
    if (members.length) tables.set(m[1], { members, from: i, to: j });
    i = j;
  }
  return tables;
}

/* ---------------------------------------------------------------- declare ---- */

const declared = new Map(); // name -> { file, line }

for (const f of skinsFiles) {
  const lines = sources.get(f);
  const tables = constTables(lines);
  for (const [from, to] of blocks(lines, /frames\s*=\s*\{/)) {
    const body = lines.slice(from, to + 1).join('\n');
    for (const n of body.matchAll(new RegExp(`["'](${NAME})["']`, 'g'))) {
      if (!declared.has(n[1])) {
        declared.set(n[1], { file: path.relative(root, f), line: from + 1 });
      }
    }
    // Bare UPPERCASE identifiers are shared const tables; flatten them into the ledger.
    for (const n of body.matchAll(new RegExp(`^\\s*([A-Z][A-Z0-9_]*)\\s*,?\\s*$`, 'gm'))) {
      const table = tables.get(n[1]);
      if (!table) continue;
      for (const member of table.members) {
        if (!declared.has(member)) {
          declared.set(member, { file: path.relative(root, f), line: from + 1 });
        }
      }
    }
  }
}

/* --------------------------------------------------------------- evaluate ---- */

/**
 * Lines of const tables the code never walks. A group referenced only by a frames list is a second
 * copy of the list, not a code path, so its members cannot vouch for themselves.
 */
function deadConstLines(f) {
  const lines = sources.get(f);
  const dead = new Set();
  for (const [name, table] of constTables(lines)) {
    const walked = lines.some((line, k) =>
      (k < table.from || k > table.to) && !inFrames(f, k) && new RegExp(`\\b${name}\\b`).test(line));
    if (walked) continue;
    for (let k = table.from; k <= table.to; k++) dead.add(k);
  }
  return dead;
}

const deadCache = new Map(skinsFiles.map(f => [f, deadConstLines(f)]));

/** String literals blanked out, for "is this name an actual lookup in the code" tests. */
function identifiers(f) {
  return sources.get(f)
    .map(line => line.replace(/"[^"]*"/g, ' ').replace(/'[^']*'/g, ' '))
    .join('\n');
}
const identifiersCache = new Map(luaFiles.map(f => [f, identifiers(f)]));
const allIdentifiers = [...identifiersCache.values()].join('\n');

/** The name is looked up (or member-accessed) as code, not sitting inside a string. */
function isLookup(name) {
  return new RegExp(`\\.${esc(name)}\\b`).test(allIdentifiers);
}

/**
 * The name as a string literal in code -- outside a frames list, outside a const the code never
 * walks. A leading/trailing dot inside the quotes counts too: `Skin:Need(name .. ".CloseButton")`
 * builds the path from a prefix variable, so the literal only carries the tail.
 */
function codeUse(name) {
  const q = new RegExp(`["']\\.?${esc(name)}\\.?["']`);
  for (const f of skinsFiles) {
    const lines = sources.get(f);
    const dead = deadCache.get(f);
    for (let i = 0; i < lines.length; i++) {
      if (!q.test(lines[i])) continue;
      if (inFrames(f, i) || dead.has(i)) continue;
      return { file: f, line: i };
    }
  }
  return null;
}

/** The frame is dressed as a window -- M:SkinWindow then also resolves its close button (Skins.lua:194). */
function isWindowDressed(at) {
  const around = sources.get(at.file).slice(Math.max(0, at.line - 1), at.line + 7).join('\n');
  return /window\s*=\s*true/.test(around) || /SkinWindow\s*\(/.test(around);
}

const explain = process.argv.slice(2).find(a => !a.startsWith('--'));
const why = [];
function note(msg) { if (explain) why.push(msg); }

function isReached(name) {
  if (isLookup(name)) { note(`代码里有成员/全局查找 .${name}`); return true; }
  const direct = codeUse(name);
  if (direct) {
    note(`字符串常量出现在 ${path.relative(root, direct.file)}:${direct.line + 1}`);
    return true;
  }

  // `<Window>CloseButton` / `<Window>.CloseButton`: M:SkinWindow derives the name
  // (`_G[frame:GetName() .. "CloseButton"]`, Skins.lua:194) or walks `frame.CloseButton`, so the
  // lookup is invisible to a static scan. What has to hold is that the window itself is declared
  // and dressed.
  if (name.endsWith('CloseButton')) {
    for (const window of declared.keys()) {
      if (window + 'CloseButton' !== name && window + '.CloseButton' !== name) continue;
      const use = codeUse(window);
      if (use && isWindowDressed(use)) {
        note(`${window} 在 ${path.relative(root, use.file)}:${use.line + 1} 以 window 档美化，关闭按钮走引擎回退`);
        return true;
      }
    }
  }

  // `<object>.<member>` paths are assembled at runtime (`Skin:Need(parentPath .. "." .. tabName)` in
  // SideTabs, `Skin:Need(name .. ".GuildRosterScrollFrame")` in Social.lua): the head must be a real
  // object the skin dresses or walks, and every tail segment must appear in code.
  const segments = name.split('.');
  if (segments.length > 1) {
    const head = codeUse(segments[0]) || isLookup(segments[0]);
    if (!head) return false;
    const tails = segments.slice(1).every(seg => codeUse(seg) || isLookup(seg));
    if (tails) note(`${segments[0]} 在代码里，成员段逐一在代码里 —— 运行期拼出的点路径`);
    return tails;
  }

  // `Button1..N` families: `"GossipGreetingButton" .. index` -- the prefix is the literal, the
  // digits come from a loop.
  const numbered = name.match(/^(.*?)(\d+)$/);
  if (numbered && codeUse(numbered[1])) {
    note(`${numbered[1]} 以拼接出现，序号来自循环`);
    return true;
  }
  return false;
}



console.log(`M:Panel frames 名单：${declared.size} 个名字，取自 ${skinsFiles.length} 个皮肤文件\n`);

const orphan = [];
for (const [name, where] of declared) {
  why.length = 0;
  const reason = ALLOW_DYNAMIC.get(name);
  const reached = reason ? true : isReached(name);
  if (explain && name === explain) {
    console.log(`${name}: ${reached ? '可达' : '不可达'}`);
    if (reason) console.log(`  ALLOW_DYNAMIC：${reason}`);
    why.forEach(w => console.log('  ' + w));
    process.exit(0);
  }
  if (reached) continue;
  orphan.push(`${name}   (${where.file}:${where.line})`);
}

console.log(`其中 ${ALLOW_DYNAMIC.size} 个走运行期拼接，已在 ALLOW_DYNAMIC 登记理由。`);
if (orphan.length) {
  console.log('\n【只在 frames 名单里、代码从不取用】—— diagnose 会报告它们存在，皮肤其实没碰：');
  orphan.forEach(o => console.log('  ' + o));
  console.log('\n' + orphan.length + ' 个。要么接上皮肤，要么从名单里删掉。');
  process.exit(1);
} else {
  console.log('全部有实际取用路径 —— frames 名单与代码一致。');
}
