/**
 * tools/audit-locals.js — 抓"子文件用了主文件的局部函数/局部别名"这一类运行时炸弹。
 *
 * 背景（2026-10-30 实机）：`Modules/ActionBars/PetBar.lua` 从主文件搬出来后**没有继承**
 * `local Mark`，而新代码里写了 `Mark(btn, ...)` → 整个 ActionBars 模块初始化失败，
 * 实机表现是"动作条损坏、暴雪默认动作条冒出来"（`PetBar.lua:83: attempt to call a nil value`）。
 * `wuxian check` 只查名字是否存在于 API / 本文件（未解析的 global 只给 note），
 * 这种"裸调用一个没定义的 local"它和 api-audit 都判不死，所以单列一道闸门。
 *
 * 只认**调用**（`Name(`）且**跳过注释行**，否则注释里提到 Widget/Media 会误报一片。
 *
 * 用法：node tools/audit-locals.js      # 有问题退出码 1
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SKIP_DIRS = new Set(['Libs', 'node_modules', '.git', 'tools', 'docs', 'Assets', 'Assets-src']);
const NAMES = ['Mark', 'Marked', 'Media', 'Widget', 'Color', 'Secrets', 'EventBus', 'Mover', 'Skin', 'Math'];

const files = [];
(function walk(dir) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP_DIRS.has(ent.name)) continue;
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p);
    else if (p.endsWith('.lua')) files.push(p);
  }
})(ROOT);

function stripComments(src) {
  // 去掉 --[[ ]] / --[==[ ]==] 长注释，再逐行去掉 -- 之后的内容
  let out = src.replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, '');
  return out.split(/\r?\n/).map((line) => {
    const i = line.indexOf('--');
    return i >= 0 ? line.slice(0, i) : line;
  });
}

let bad = 0;
for (const file of files) {
  const rel = path.relative(ROOT, file);
  const lines = stripComments(fs.readFileSync(file, 'utf8'));
  const src = lines.join('\n');

  // 本文件声明过的名字：local a / local a, b / local function f / function ns:X / ns.X =
  const declared = new Set();
  for (const line of lines) {
    const multi = line.match(/^\s*local\s+([\w\s,]+)/);
    if (multi) {
      for (const part of multi[1].split(',')) {
        const name = part.trim().split(/[\s=]/)[0];
        if (name) declared.add(name);
      }
    }
    const lf = line.match(/^\s*local\s+function\s+(\w+)/);
    if (lf) declared.add(lf[1]);
    const nsf = line.match(/^\s*function\s+ns[:.](\w+)/);
    if (nsf) declared.add(nsf[1]);
    const nsa = line.match(/^\s*ns\.(\w+)\s*=/);
    if (nsa) declared.add(nsa[1]);
  }

  for (const name of NAMES) {
    const call = new RegExp(`(^|[^\\w.:])${name}\\s*\\(`, 'm');
    if (!call.test(src)) continue;
    if (declared.has(name)) continue;
    const idx = lines.findIndex((l) => new RegExp(`(^|[^\\w.:])${name}\\s*\\(`).test(l));
    console.log(`[MISSING] ${rel}:${idx + 1}: 调用了 ${name}( ) 但本文件没有 local ${name}`);
    bad++;
  }
}

console.log(bad === 0
  ? `audit-locals: ${files.length} 个文件，全部通过`
  : `audit-locals: ${bad} 处"裸调用未定义的 local"`);
process.exit(bad === 0 ? 0 : 1);
