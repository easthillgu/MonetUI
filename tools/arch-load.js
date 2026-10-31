#!/usr/bin/env node
/**
 * tools/arch-load.js —— 架构图脚本共用的取数层（被 gen-module-map.js / gen-event-flow.js require）。
 *
 * 只做三件事，都不带观点：
 *   loadOrder()          把 MonetUI.toc 展开成有序 .lua 清单（xml 按 <Script file> 次序展开）
 *   nodeId(file, regs)   一个 .lua 文件对应图里哪个节点（Utils/Core/Config/Libs 各自成节点，
 *                        模块组归到它 ns:Register 的主名）
 *   scanFiles(files)     逐文件读出注册名、体积、事件接线数
 * 目录结构本身不当证据用，只当分组用。
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const UTILS = ['Math', 'Secrets', 'Media', 'EventBus', 'Color', 'Widget', 'Layout', 'Mover', 'Skin', 'Compat'];

const readText = f => fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n');
const rel = p => path.relative(ROOT, p).replace(/\\/g, '/');

/** toc → 有序文件清单（xml 展开成它自己的 Script file 顺序）。 */
function loadOrder() {
  const files = [];
  for (const raw of readText(path.join(ROOT, 'MonetUI.toc')).split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    if (!/\.(lua|xml)$/i.test(line)) continue;
    const host = line.replace(/\\/g, '/');
    if (host.toLowerCase().endsWith('.xml')) {
      const dir = path.dirname(host);
      for (const m of readText(path.join(ROOT, host)).matchAll(/<Script\s+file\s*=\s*"([^"]+)"/g)) {
        files.push(dir + '/' + m[1].replace(/\\/g, '/'));
      }
    } else {
      files.push(host);
    }
  }
  return files;
}

/** 文件 → 图节点 id。 */
function nodeId(file, registers) {
  if (file.startsWith('Utils/')) return 'u:' + path.basename(file, '.lua');
  if (file === 'Core.lua') return 'core:ENGINE';
  if (file.startsWith('Config/')) return 'cfg';
  if (file.startsWith('Libs/')) return 'lib:' + path.basename(path.dirname(file));
  const self = registers.get(file);
  if (self && self.length) return 'mod:' + self[0];
  const dir = path.dirname(file);
  for (const entry of registers) {
    if (path.dirname(entry[0]) === dir && entry[1].length) return 'mod:' + entry[1][0];
  }
  return null;
}

/** 读全部加载项：注册名 + 源码文本 + 体积。 */
function scanFiles(files) {
  const registers = new Map();
  const sources = new Map();
  const sizes = new Map();
  for (const f of files) {
    const abs = path.join(ROOT, f);
    if (!fs.existsSync(abs)) continue;
    const src = readText(abs);
    registers.set(f, [...src.matchAll(/ns:Register\(\s*"([^"]+)"/g)].map(m => m[1]));
    sources.set(f, src);
    sizes.set(f, fs.statSync(abs).size);
  }
  return { registers, sources, sizes };
}

/**
 * 硬自查：边不许指向未声明节点（DOT 会造出脱离分层的幽灵节点）。
 * opts.isolated 为真时另查孤岛。任一失败置 exitCode 1。
 */
function selfCheck(lines, declaredList, opts) {
  const declared = new Set(declaredList);
  const used = new Set();
  for (const line of lines) {
    const m = line.match(/^\s*"([^"]+)" -> "([^"]+)"/);
    if (m) { used.add(m[1]); used.add(m[2]); }
  }
  const dangling = [...used].filter(id => !declared.has(id));
  if (dangling.length) {
    console.error('FAIL 边指向未声明节点: ' + dangling.join(', '));
    process.exitCode = 1;
  }
  if (opts && opts.isolated) {
    const isolated = [...declared].filter(id => !used.has(id));
    if (isolated.length) {
      console.error('FAIL 孤岛节点（抽取规则漏了用法，或该节点本不该进图）: ' + isolated.join(', '));
      process.exitCode = 1;
    }
  }
  if (!process.exitCode) console.error('check ok: 无悬空节点' + (opts && opts.isolated ? '、无孤岛' : ''));
}

/**
 * DOT 词法自查：每个双引号字符串必须在同一行闭合。
 * 标签里混进真实换行或未转义的引号时，Graphviz 报的是"行号对不上"的语法错，
 * 事后极难归因，所以在生成时就拦掉。
 */
function lintDot(lines, name) {
  const bad = [];
  lines.forEach((line, i) => {
    if (/^\s*\/\//.test(line)) return;             // DOT 注释行不参与引号配平
    let inStr = false;
    for (let k = 0; k < line.length; k++) {
      const c = line[k];
      if (c === '\\') { k++; continue; }
      if (c === '"') inStr = !inStr;
    }
    if (inStr) bad.push((i + 1) + ': ' + line.trim().slice(0, 90));
  });
  if (bad.length) {
    console.error('FAIL DOT 字符串未闭合（' + name + '）—— 标签里有真换行或未转义引号:');
    for (const b of bad.slice(0, 6)) console.error('  ' + b);
    process.exitCode = 1;
  }
  return !bad.length;
}

module.exports = { ROOT, UTILS, CORE_SERVICES: [
  'Mark', 'Marked', 'DB', 'Print', 'InCombat', 'AfterCombat', 'IsRestricted',
  'Restrictions', 'GetAnim', 'HasMonetColor', 'IsModuleEnabled', 'ResolveObject', 'ResolvePath',
  'GetModuleOrder', 'ClientIdentity', 'RefreshTheme', 'HookShow'],
readText, rel, loadOrder, nodeId, scanFiles, selfCheck, lintDot };
