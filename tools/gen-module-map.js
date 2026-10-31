#!/usr/bin/env node
/**
 * tools/gen-module-map.js
 * 从 MonetUI.toc + 各组 xml + Lua 源码抽出"模块地图 / 加载分层"，输出 Graphviz DOT。
 *
 *   node tools/gen-module-map.js [docs/architecture/module-map.dot]
 *
 * 取数层在 tools/arch-load.js（与 gen-event-flow.js 共用）。
 * 边全部来自能对着行号核的语句，不靠目录结构猜：
 *   alias   —— 文件顶部 `local Widget = ns.Widget`（加载期注入，硬边）
 *   lookup  —— `ns:GetModule("Cooldown")`（运行期查表）
 *   sibling —— `local M = ns.Skins`（同组子文件挂回主模块表）
 *   core    —— `ns:Mark` / `ns:DB` / `ns:AfterCombat` 等 Core 服务
 *   lib     —— `LibStub("LibMonetColor-1.0")`
 * 节点顺序 = 加载顺序：toc 决定组间序，xml 内次序决定组内序。
 */
const fs = require('fs');
const path = require('path');
const A = require('./arch-load');

const OUT = process.argv[2] || path.join(A.ROOT, 'docs/architecture/module-map.dot');
const SEP = '::';
const EDGE_STYLE = {
  alias: ['load-time alias', 'style=solid'],
  lookup: ['runtime lookup', 'style=dashed color="#c0392b"'],
  sibling: ['sibling table', 'style=solid color="#8e44ad"'],
  core: ['core service', 'style=dotted'],
  lib: ['LibStub', 'style=solid color="#2c3e50"'],
  inline: ['inline ns.X', 'style=solid color="#16a085"'],
};

const kb = b => Math.round(b / 1024) + 'KB';
const lineOf = (src, index) => src.slice(0, index).split('\n').length;

function collect(files) {
  const { registers, sources, sizes } = A.scanFiles(files);
  const nodes = new Map();
  const edges = new Map();

  files.forEach((f, i) => {
    const src = sources.get(f);
    if (src === undefined) return;
    const owner = A.nodeId(f, registers);
    if (!owner) return;
    if (!nodes.has(owner)) nodes.set(owner, { files: 0, bytes: 0, events: 0, order: i + 1, src: [] });
    const n = nodes.get(owner);
    n.files += 1;
    n.bytes += sizes.get(f);
    n.events += (src.match(/EventBus:(Register|RegisterUnit|Fire|Dispatch)\(/g) || []).length;
    n.src.push(f);

    const add = (to, type, where) => {
      if (to === owner) return;
      const key = owner + SEP + to;
      if (!edges.has(key)) edges.set(key, { type, count: 0, where: [] });
      const e = edges.get(key);
      e.count += 1;
      if (e.where.length < 4) e.where.push(where);
      edges.set(key, e);
    };

    for (const m of src.matchAll(/^local\s+\w+\s*=\s*ns\.(\w+)/gm)) {
      const target = m[1];
      if (A.UTILS.includes(target)) add('u:' + target, 'alias', f + ':' + lineOf(src, m.index));
      else if (A.CORE_SERVICES.includes(target)) add('core:ENGINE', 'core', f + ':' + lineOf(src, m.index));
      else add('mod:' + target, 'sibling', f + ':' + lineOf(src, m.index));
    }
    for (const m of src.matchAll(/ns:GetModule\(\s*"([^"]+)"/g)) add('mod:' + m[1], 'lookup', f);
    // 取库：LibStub("X") 与 pcall(stub, "X", true) 两种写法都算，注释里的名字不算（只认调用形）
    for (const m of src.matchAll(/\b(?:LibStub|stub)\s*(?:\(\s*|,\s*)"([^"]+)"/g)) {
      add('lib:' + m[1], 'lib', f + ':' + lineOf(src, m.index));
      add('lib:LibStub', 'lib', f);          // 能取库说明 LibStub 已先加载
    }
    // 调色引擎的状态色层：Core 用 LMC.Anim 拿它，模块只经 ns:GetAnim() 间接用
    if (/LMC\.Anim\b/.test(src)) add('lib:LibMonetColor-Anim-1.0', 'lib', f + ':' + lineOf(src, src.indexOf('LMC.Anim')));
    // 内联调用 ns.Layout.bottom 这类没起别名的用法
    for (const m of src.matchAll(/ns\.(\w+)\./g)) {
      if (A.UTILS.includes(m[1])) add('u:' + m[1], 'inline', f + ':' + lineOf(src, m.index));
    }
    for (const m of src.matchAll(/ns[:.](\w+)/g)) {
      if (A.CORE_SERVICES.includes(m[1])) add('core:ENGINE', 'core', f);
    }
  });
  return { nodes, edges };
}

function node(id, n, fill, label) {
  const text = label + (label.includes('\\n') ? '' : '\\n' + kb(n.bytes));
  return '"' + id + '" [fillcolor="' + fill + '", label="' + text +
    '", tooltip="' + n.src.join(' ') + ' | 加载序 ' + n.order + ' | 事件接线 ' + n.events + '"]';
}

function main() {
  const files = A.loadOrder();
  const { nodes, edges } = collect(files);
  const declared = new Set();
  for (const id of nodes.keys()) declared.add(id);
  const L = [];
  const push = s => L.push(s);
  const byTier = pre => [...nodes.entries()].filter(e => e[0].startsWith(pre)).sort((a, b) => a[1].order - b[1].order);
  const mods = byTier('mod:');
  const utils = byTier('u:');
  const libs = byTier('lib:');

  push('// MonetUI 模块地图 / 加载分层 —— 由 tools/gen-module-map.js 生成，勿手工编辑');
  push('// ' + files.length + ' 个加载项 / ' + nodes.size + ' 个节点 / ' + edges.size + ' 条边；每条边的 tooltip 带 file:line');
  push('digraph MonetUI {');
  push('  rankdir=TB; nodesep=0.30; ranksep=0.80;');
  push('  graph [fontname="Sans-Serif", fontsize=12, label="MonetUI L3 模块地图 + 加载分层\\l", labelloc=t];');
  push('  node  [shape=box, style="rounded,filled", fontname="Sans-Serif", fontsize=10];');
  push('  edge  [fontname="Sans-Serif", fontsize=8, color="#7a8ba3"];');

  push('  subgraph cluster_loadorder { label="加载序（toc 顺序 = 执行顺序）"; style="dashed"; color="#b0bccd"; fontsize=9;');
  push('    ord [shape=plaintext, fontsize=8, label="' + files.map((f, i) => (i + 1) + '. ' + f).join('\\n') + '"];');
  push('  }');

  const tier = (id, title, color, items) => {
    if (!items.length) return;
    push('  subgraph cluster_' + id + ' { label="' + title + '"; style=filled; color="' + color + '"; fontsize=11; margin=10;');
    for (const line of items) push('    ' + line);
    push('  }');
  };

  tier('libs', 'Libs（LibStub + 调色引擎，最先加载）', '#f4f8fc',
    libs.map(e => node(e[0], e[1], '#e8f0f8', e[0].slice(4))));
  tier('utils', 'Utils（ns.* 服务层，注意在 Core.lua 之前）', '#f1f7f1',
    utils.map(e => node(e[0], e[1], '#e0efe0', 'Utils/' + e[0].slice(2) + '.lua')));
  tier('engine', 'Core + Config', '#fdf3e8', [
    node('core:ENGINE', nodes.get('core:ENGINE'), '#f7e0c0', 'Core.lua（ns 引擎）'),
    node('cfg', nodes.get('cfg'), '#f7e0c0', 'Config/SimpleConfig.lua'),
  ]);
  tier('modules', 'Modules（' + mods.length + ' 个 ns:Register 模块）', '#f8f1fa',
    mods.map(e => node(e[0], e[1], '#f0e2f5',
      e[0].slice(4) + '\\n' + e[1].files + ' 文件 · ' + kb(e[1].bytes) + ' · ' + e[1].events + ' 处事件')));

  const dropped = new Set();
  for (const entry of edges) {
    const parts = entry[0].split(SEP);
    const e = entry[1];
    if (!declared.has(parts[0]) || !declared.has(parts[1])) {
      dropped.add(parts[0] + ' -> ' + parts[1]);   // 检出的依赖但目标不在本仓（如可选库），只报不画
      continue;
    }
    const st = EDGE_STYLE[e.type];
    push('  "' + parts[0] + '" -> "' + parts[1] + '" [' + st[1] + ' label="' + st[0] + ' x' + e.count +
      '" tooltip="' + e.where.join(' | ') + '"]');
  }

  push('  legend [shape=note, fillcolor="#fffde7", style=filled, fontsize=9, label="边例：实线 = 文件顶部 local X = ns.X（加载期，硬证据）\\l'
    + '红虚线 = ns:GetModule（运行期查表）\\l紫实线 = local M = ns.模块（同组子文件挂回主表）\\l'
    + '点线 = Core 服务（ns:Mark / ns:DB / AfterCombat 等）\\l深蓝线 = LibStub 取库\\l青线 = 内联 ns.<Util> 调用（没起别名）"];');
  push('  { rank=same; "core:ENGINE"; "cfg"; }');
  push('}');
  if (dropped.size) {
    console.error('NOTE 检出但未画的依赖（目标不在本仓加载清单里，多为可选库）:');
    for (const d of dropped) console.error('  - ' + d);
  }

  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  A.lintDot(L, 'module-map.dot');
  fs.writeFileSync(OUT, L.join('\n') + '\n', 'utf8');
  console.error('files=' + files.length + ' nodes=' + nodes.size + ' edges=' + edges.size + ' -> ' + OUT);
  A.selfCheck(L, nodes.keys(), { isolated: true });
}

main();
