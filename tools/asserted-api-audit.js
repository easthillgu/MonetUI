#!/usr/bin/env node
/**
 * asserted-api-audit.js —— 查"代码/注释里声称某 API 不存在"的断言与**本机 API 快照**是否矛盾。
 *
 * 为什么需要它：`GetInventoryItemDurability` 那一轮（2026-11-26）证明了这类错误断言的代价 ——
 * 一句旧笔记写着"全族不存在"，整条槽位耐久路径就没写，功能空缺了几个月，而且**离线闸门全绿**
 * （闸门只审"写了的代码"，不审"没写的那一半"）。
 *
 * 判据：名字出现在 docs/api/FUNCTIONS.md / TYPES.md（= 本客户端自己导出的
 * Blizzard_APIDocumentationGenerated 快照），而注释/提示文案里写着"本客户端没有 / 不存在" ⇒ 矛盾，报红。
 *
 * 只做**词法层**的交叉核对（不判断"这句断言有没有真的关掉功能"），所以 wording 尽量收敛：
 * 一律 `--xxx` 打印、退出码 0；加 `--strict` 时矛盾项 >=1 就退出 1，可挂进闸门流水线。
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const API_DIR = path.join(ROOT, 'docs', 'api');
const SCAN_DIRS = ['Modules', 'Utils', 'Core.lua', 'Config'];

// "声称不存在"的措辞（同义收敛，别扩得太宽：`不存在` 在别的语境里大量指"框体/字段"）
const ABSENCE = /(本客户端没有|本客户端不存在|本客户端无|客户端没有|客户端不存在|全族不存在|1\.60 上没有|1\.60 没有)/;

// 候选名字：`C_Xxx.Yyy` 形式或裸全局（大写开头、>=4 字符，含 CamelCase）
const C_API = /C_[A-Za-z0-9_]+\.\w+/g;
const C_GLOBAL = /\b(Get|Set|Is|Has|Can|Unit|Send|Pickup|Toggle|Show|Hide|Clear|Update)[A-Za-z0-9_]{4,}\b/g;

function collectFiles(dir, out = []) {
  const abs = path.isAbsolute(dir) ? dir : path.join(ROOT, dir);
  if (!fs.existsSync(abs)) return out;
  const st = fs.statSync(abs);
  if (st.isFile()) {
    if (abs.endsWith('.lua')) out.push(abs);
    return out;
  }
  for (const entry of fs.readdirSync(abs)) {
    collectFiles(path.join(abs, entry), out);
  }
  return out;
}

/** 快照里登记过的名字集合（函数名 + 枚举名 + 一律去掉参数部分） */
function documentedNames() {
  const names = new Set();
  for (const file of ['FUNCTIONS.md', 'TYPES.md', 'MANUAL.md']) {
    const abs = path.join(API_DIR, file);
    if (!fs.existsSync(abs)) continue;
    const text = fs.readFileSync(abs, 'utf8');
    const re = /\*\*`([^`]+)`\*\*/g;
    let m;
    while ((m = re.exec(text)) !== null) {
      const raw = m[1].replace(/\(.*$/, '').trim();      // 去掉 (参数)
      if (!raw) continue;
      names.add(raw);
      // `C_Foo.Bar` 只登记全名；`GetFoo` 这类裸名单独登记
      const tail = raw.split('.').pop();
      names.add(tail);
    }
  }
  return names;
}

function main() {
  const documented = documentedNames();
  const files = [];
  for (const dir of SCAN_DIRS) collectFiles(dir, files);

  const hits = [];
  for (const file of files) {
    const rel = path.relative(ROOT, file);
    const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (!ABSENCE.test(line)) continue;
      // 白名单：这句是**运行时兜底文案**（`if type(fn) ~= "function"` 才打印，API 真缺才出现，无害）。
      // 写法和其它审计工具一致：上一行或本行留 `api-audit:ok <理由>`。
      if (/api-audit:ok/.test(line) || (i > 0 && /api-audit:ok/.test(lines[i - 1]))) continue;
      const absence = ABSENCE.exec(line);
      if (!absence) continue;
      // 只取**紧跟在断言后面**的那一小段（60 字符内）——否则整行里的"顺带提到的真名"
      // 也会被当成被断言的对象（11-26 首跑就误报 `GetCursorPosition` = `GetScaledCursorPosition` 的前缀）。
      const tail = line.slice(absence.index, absence.index + 80);
      const candidates = new Set();
      for (const m of tail.matchAll(C_API)) candidates.add(m[0]);
      for (const m of tail.matchAll(C_GLOBAL)) candidates.add(m[0]);
      for (const name of candidates) {
        if (!documented.has(name)) continue;
        // `GetInventoryItem*` 这种**通配写法**不是单个 API 名，跳过（要它自己带具体名字才算）
        if (tail.includes(name + '*')) continue;
        // 名字是更长标识符的前缀（`GetMouseFocus` ⊂ `GetMouseFoci`）也跳过：那是另一条 API
        const after = tail.slice(tail.indexOf(name) + name.length, tail.indexOf(name) + name.length + 1);
        if (/[A-Za-z0-9_]/.test(after)) continue;
        hits.push({ rel, line: i + 1, name, text: line.trim() });
      }
    }
  }

  if (hits.length === 0) {
    console.log('[asserted-api-audit] 0 条矛盾：声称"不存在"的 API 里没有快照登记过的名字。');
    return 0;
  }

  console.log(`[asserted-api-audit] ${hits.length} 条矛盾（快照里**有**这个 API，代码却写着"不存在"）：`);
  for (const h of hits) {
    console.log(`  ✗ ${h.rel}:${h.line}  ${h.name}`);
    console.log(`      ${h.text}`);
  }
  console.log('\n每条都要判一下：这句是"运行时兜底文案"（API 真缺才打印，无害）还是"整条功能没写"（要去实机验一次再补实现）。');
  return process.argv.includes('--strict') ? 1 : 0;
}

process.exitCode = main();
