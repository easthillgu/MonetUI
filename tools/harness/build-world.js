#!/usr/bin/env node
/**
 * tools/harness/build-world.js
 *
 * 从本地 FrameXML 转储（1.60 = Camelot 分支优先）提取**真实暴雪 UI 世界**，导出
 * tools/harness/world-data.lua 给无头替身 harness 实例化。
 *
 * 为什么需要它：harness 的断言五（`Skin:Need` 落空账本）要能回答"皮肤层点名的对象
 * 在真客户端里到底有没有"，这必须拿一份**与皮肤代码无关**的证据源来判 —— 拿代码里
 * 写的名字当世界，Need 永远命中，✗ 清单恒空，闸门就成了摆设。
 *
 * 用法：
 *   node tools/harness/build-world.js                       # 自动找 framexml-source
 *   node tools/harness/build-world.js --source <path>        # 指定 Interface/AddOns 目录
 *   node tools/harness/build-world.js --out <path>           # 指定输出
 *   node tools/harness/build-world.js --audit                # 只打印统计，不写文件
 *
 * 分支优先级（同一插件同一文件名只会有一份定义生效）：
 *   Camelot（1.60 目标）> 插件根目录（跨分支共享）> Shared > Mainline > Classic > Vanilla
 *
 * 这里**不执行**暴雪的 `<OnLoad>` 脚本体（那是 Lua，不是声明式 UI），所以运行期用
 * CreateFrame 拼出来的子件在本世界里不存在 —— 属于已知的离线近似，见 docs/CHECKS.md 的 harness 一节。
 */
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');

// ---------------------------------------------------------------- 源目录定位
function findSource(explicit) {
  const cand = [];
  if (explicit) cand.push(explicit);
  // lane（worktree）里通常没有 framexml-source（被 gitignore、也不在 junction 名单），
  // 依次找：本目录 → 主仓 → 主仓的父目录。
  cand.push(path.join(REPO, 'framexml-source', 'Interface', 'AddOns'));
  cand.push(path.join(REPO, '..', 'MonetUI', 'framexml-source', 'Interface', 'AddOns'));
  cand.push('C:\\Users\\EastHillGu\\Documents\\wowaddonsdev\\MonetUI\\framexml-source\\Interface\\AddOns');
  for (const p of cand) {
    if (p && fs.existsSync(p)) return path.resolve(p);
  }
  return null;
}

const args = process.argv.slice(2);
const argOf = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : null;
};
const AUDIT = args.includes('--audit');

const SRC = findSource(argOf('--source'));
if (!SRC) {
  console.error('[build-world] 找不到 FrameXML 转储（framexml-source/Interface/AddOns）。');
  console.error('  已试过：' + [path.join(REPO, 'framexml-source'), '主仓 MonetUI/framexml-source'].join(' | '));
  console.error('  用 --source <path> 指定，或直接复用已生成的 world-data.lua。');
  process.exit(2);
}

// ---------------------------------------------------------------- 采集文件
// 只有会被 1.60 真正加载的那一份算数：同插件目录里 Camelot/Mainline/Classic/Vanilla 是
// GameRule 分支，同名文件按优先级取一份。
const BRANCH_RANK = {
  Camelot: 0, Shared: 1, UI: 1, '': 2, Mainline: 3,
  Classic: 4, Cata: 4, ClassTalents: 4, WoWLabs: 5, Vanilla: 6,
};
const BINDINGS = /(^|[\\/])Bindings\.xml$/i;

function walkXml(dir, base, out) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) { walkXml(full, base, out); continue; }
    if (!ent.name.toLowerCase().endsWith('.xml')) continue;
    if (BINDINGS.test(full)) continue;              // 按键绑定与 UI 结构无关
    const rel = path.relative(base, full).split(path.sep);
    const addon = rel[0];
    const branch = rel.length > 2 ? rel[rel.length - 2] : '';
    const rank = branch in BRANCH_RANK ? BRANCH_RANK[branch] : 6;
    out.push({ full, addon, branch, rank, key: rel.slice(1).join('/').toLowerCase() });
  }
  return out;
}

// 随客户端启动就建帧的插件；其余算 LoD（要 LoadAddOn 才有帧），替身按加载状态决定存在与否。
const ALWAYS_LOADED = new Set([
  'Blizzard_FrameXML', 'Blizzard_FrameXMLBase', 'Blizzard_FrameXMLUtil',
  'Blizzard_SharedXML', 'Blizzard_SharedXMLBase', 'Blizzard_SharedXMLGame',
  'Blizzard_MoneyFrame', 'Blizzard_UIPanels_Game',
]);

const all = walkXml(SRC, SRC, []);
// 同名 key（Camelot/Foo.xml 与 Mainline/Foo.xml）只留 rank 最小的一份
const byKey = new Map();
for (const f of all) {
  const cur = byKey.get(f.key);
  if (!cur || f.rank < cur.rank) byKey.set(f.key, f);
}
const files = [...byKey.values()].sort((a, b) => a.key.localeCompare(b.key));

// ---------------------------------------------------------------- XML 解析
// 元素白名单：只有这些标签是"对象"。包装标签（Layers/Anchors/Scripts/...）不进世界。
const WIDGET = new Set([
  'Frame', 'Button', 'CheckButton', 'StatusBar', 'EditBox', 'Slider', 'ScrollFrame', 'ScrollMessage',
  'Texture', 'FontString', 'DropDownList', 'Minimap', 'PlayerModel', 'TabardAtlas', 'TabardCharter',
  'TabardEmblem', 'TabardBackground', 'TabardBorder', 'Item', 'ItemButton', 'Icon', 'GameTip',
  'SpellBookPaginate', 'MaskedTexture', 'AnimatedTexture', 'ModelSceneFrame',
]);
// 按钮美术槽 → 记进 slots，替身用它实现 GetNormalTexture / GetHighlightTexture ...
const ART_SLOT = {
  NormalTexture: 'normal', HighlightTexture: 'highlight', PushedTexture: 'pushed',
  DisabledTexture: 'disabled', CheckedTexture: 'checked',
};

const TAG_RE = /<(\/?)([A-Za-z][A-Za-z0-9_.]*)([^>]*?)(\/?)>/g;
const ATTR_RE = /([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*"([^"]*)"/g;

function attrsOf(body) {
  const out = {};
  let m;
  ATTR_RE.lastIndex = 0;
  while ((m = ATTR_RE.exec(body))) out[m[1]] = m[2];
  return out;
}

// 字符串池（导出时去重，文件能小一半）
const strIds = new Map();
const strings = [];
function intern(s) {
  if (s == null) return 0;
  const hit = strIds.get(s);
  if (hit !== undefined) return hit;
  strings.push(s);
  const id = strings.length;
  strIds.set(s, id);
  return id;
}

const rows = [];        // 位置压缩行：[kind, name, key, parent, inh[], slots[]]
const byName = new Map();   // 非 virtual 的真实对象名 -> row index（1-based）
const templateByName = new Map(); // virtual 模板名 -> row index
const ownerOf = new Map();  // 全局对象行号 -> { addon, lod }
const stack = [];       // 打开的元素（{ tag, row }）

let currentAddon = '';

function addRow(kind, a, parentRow) {
  const row = {
    kind: intern(kind),
    name: 0,
    key: 0,
    parent: parentRow || 0,
    inh: [],
    slots: [],
  };
  // 名字：$parent 前缀 = 模板子件（后缀即字段名）；普通名字 = 全局对象
  const nm = a.name || '';
  if (nm) {
    if (nm.startsWith('$parent')) {
      row.name = intern(nm);
      row.key = intern(nm.slice('$parent'.length));
    } else {
      row.name = intern(nm);
      if (a.parentKey) row.key = intern(a.parentKey);
    }
  } else if (a.parentKey) {
    row.key = intern(a.parentKey);
  }
  const inh = [];
  if (a.inherits) inh.push(...a.inherits.split(',').map(s => s.trim()).filter(Boolean));
  if (a.template) inh.push(a.template);
  for (const s of inh) row.inh.push(intern(s));
  const virtual = !!(a.virtual && a.virtual !== 'false');
  rows.push(row);
  const idx = rows.length;              // 1-based
  if (nm && !nm.startsWith('$parent')) {
    if (virtual) templateByName.set(nm, idx);
    else {
      byName.set(nm, idx);
      ownerOf.set(idx, { addon: currentAddon, lod: !ALWAYS_LOADED.has(currentAddon) });
    }
  }
  return idx;
}

for (const f of files) {
  currentAddon = f.addon;
  let raw = fs.readFileSync(f.full, 'utf8');
  raw = raw.replace(/<!--[\s\S]*?-->/g, '')           // 注释里的示例帧不是真定义
    .replace(/<\?[\s\S]*?\?>/g, '')
    .replace(/<!DOCTYPE[\s\S]*?>/g, '');
  let m;
  TAG_RE.lastIndex = 0;
  while ((m = TAG_RE.exec(raw))) {
    const closing = m[1] === '/';
    const tag = m[2];
    const body = m[3] || '';
    const selfClose = m[4] === '/';
    if (tag === 'Ui') continue;
    if (closing) {
      // 出栈：只弹到同名开标签（畸形 XML 时不至于把整棵栈弄乱）
      for (let i = stack.length - 1; i >= 0; i--) {
        if (stack[i].tag === tag) { stack.length = i; break; }
      }
      continue;
    }
    const a = attrsOf(body);
    const isWidget = WIDGET.has(tag) || ART_SLOT[tag];
    let rowIdx = null;
    if (isWidget) {
      const parentRow = stack.length ? stack[stack.length - 1].row : 0;
      const kind = ART_SLOT[tag] ? 'Texture' : tag;
      rowIdx = addRow(kind, a, parentRow);
      if (ART_SLOT[tag] && parentRow) {
        // 美术槽直接记在宿主按钮上：[槽名下标, 贴图行号]，替身的 GetNormalTexture 等读它
        rows[parentRow - 1].slots.push([intern(ART_SLOT[tag]), rowIdx]);
      }
    }
    if (!selfClose) stack.push({ tag, row: rowIdx || (stack.length ? stack[stack.length - 1].row : 0) });
  }
  stack.length = 0;
}

// ---------------------------------------------------------------- 导出
const luaEscape = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
const out = [];
out.push('-- tools/harness/world-data.lua');
out.push('-- GENERATED by tools/harness/build-world.js —— DO NOT EDIT BY HAND');
out.push('-- Source: ' + SRC.replace(/\\/g, '/'));
out.push('-- Files: ' + files.length + '  Elements: ' + rows.length + '  Globals: ' + byName.size + '  Templates: ' + templateByName.size);
out.push('--');
out.push('-- 真实暴雪 UI 世界的声明式快照（1.60 = Camelot 分支优先；LoD 插件的单列在 lod 表里）。');
out.push('-- rows[i] = { kind, name, key, parent, inh, slots }，标量都是 strings 池下标（0 = 无）：');
out.push('--   name 以 "$parent" 开头 = 模板/宿主子件，key 是它在宿主对象上的字段名；');
out.push('--   parent = 宿主元素行号（1-based，0 = XML 顶层）；inh = inherits/template 链；');
out.push('--   slots = { {槽名, 贴图行号} ... }（normal / highlight / pushed / disabled / checked）；');
out.push('-- globals / templates = 名字 -> 行号；lod = 插件名 -> 该插件提供的全局行号清单。');
out.push('-- 由 tools/harness/frames.lua 按名惰性实例化成替身对象；这里不执行任何暴雪脚本。');
out.push('-- luacheck: ignore');
out.push('local W = {');
out.push('  branch = "Camelot",');
out.push('  strings = {');
for (let i = 0; i < strings.length; i += 10) {
  out.push('    ' + strings.slice(i, i + 10).map(s => JSON.stringify(s)).join(', ') + ',');
}
out.push('  },');
out.push('  rows = {');
for (const r of rows) {
  const inh = r.inh.length ? '{' + r.inh.join(',') + '}' : '{}';
  const slots = r.slots.length ? '{' + r.slots.map(s => `{${s[0]},${s[1]}}`).join(',') + '}' : '{}';
  out.push(`    {${r.kind},${r.name},${r.key},${r.parent},${inh},${slots}},`);
}
out.push('  },');

// 全局注册表：先按名字排序，输出成 name -> row 的赋值段（keys 走 strings 池）
out.push('  globals = {');
for (const [name, idx] of [...byName.entries()].sort((a, b) => a[0].localeCompare(b[0]))) out.push(`    ["${luaEscape(name)}"] = ${idx},`);
out.push('  },');
out.push('  templates = {');
for (const [name, idx] of [...templateByName.entries()].sort((a, b) => a[0].localeCompare(b[0]))) out.push(`    ["${luaEscape(name)}"] = ${idx},`);
out.push('  },');
const lodByAddon = new Map();
for (const [rowIdx, o] of ownerOf) {
  if (!o.lod) continue;
  if (!lodByAddon.has(o.addon)) lodByAddon.set(o.addon, []);
  lodByAddon.get(o.addon).push(rowIdx);
}
out.push('  lod = {');
for (const [addon, idxs] of [...lodByAddon.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
  out.push(`    ["${luaEscape(addon)}"] = { ${idxs.join(', ')} },`);
}
out.push('  },');
out.push('}');
out.push('return W');

const OUT_PATH = argOf('--out') || path.join(__dirname, 'world-data.lua');
const body = out.join('\r\n') + '\r\n';

console.log(`[build-world] 源目录      ${SRC}`);
console.log(`[build-world] XML 文件    ${files.length}（分支去重后；Camelot 优先）`);
console.log(`[build-world] 元素        ${rows.length}`);
console.log(`[build-world] 全局对象    ${byName.size}`);
console.log(`[build-world] 虚拟模板    ${templateByName.size}`);
console.log(`[build-world] 字符串池    ${strings.length}`);
console.log(`[build-world] 体积        ${(body.length / 1048576).toFixed(2)} MB`);
if (AUDIT) { console.log('[build-world] --audit：不写文件'); process.exit(0); }
fs.writeFileSync(OUT_PATH, body, 'utf8');
console.log(`[build-world] 写出        ${OUT_PATH}`);
