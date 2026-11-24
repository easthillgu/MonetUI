/**
 * tools/audit-multireturn.js — 抓"把多返回值 API 当表用"这一类静默空转 / 直接抛错。
 *
 * 背景（2026-11-24 复查）：本客户端 `frame:GetChildren()` / `frame:GetRegions()` 返回的是
 * **变长返回值**，不是一张表 —— 暴雪自己就写成 `{ frame:GetChildren() }`
 * （framexml-source 里十几处，另有 `select("#", proxy:GetChildren())`）。
 * 写成下面任一种，都不会报错、只会**静默少做事**或在对 userdata 取长度时抛：
 *
 *   local kids = frame:GetChildren()          -- kids = 第一个子框（userdata）或 nil
 *   local ok, kids = pcall(frame.GetChildren, frame)   -- 同上，pcall 只接到第一个返回值
 *   for i = 1, #kids do                       -- 对 userdata 取长度 → 抛
 *   for _, c in ipairs(frame:GetChildren())   -- ipairs 拿到的是第一个子框，循环空转
 *
 * 已判实的事故：
 *   * `c2b6b2b`（2026-11-01）首领框压制从没生效 —— 子框递归空转；
 *   * `71085819`（2026-11-03）把 Nameplates 的 FadeBlizzardSiblings 改成
 *     `local kids = base:GetChildren()` + `#kids`，兄弟框压暗整段失效；
 *     **而 tools/test-skin-lua.js 那条断言当时是绿的** —— 它的正则匹配到的是描述旧写法的
 *     那句注释，不是代码。所以这道闸门只认代码、并把注释剥掉再判。
 *
 * 只认**代码**：先剥掉整行注释与行尾注释（引号里的 `--` 不算注释），再判形状。
 *
 * 用法：node tools/audit-multireturn.js     # 有问题退出码 1
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SKIP_DIRS = new Set(['Libs', 'node_modules', '.git', 'tools', 'docs', 'Assets',
  'Assets-src', 'framexml-source']);
const APIS = ['GetChildren', 'GetRegions'];

const files = [];
(function walk(dir) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP_DIRS.has(ent.name)) continue;
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p);
    else if (p.endsWith('.lua')) files.push(p);
  }
})(ROOT);

/**
 * 剥掉一行里的注释与字符串字面量：
 *   * 整行注释 / 行尾注释 → 去掉（引号里的 `--` 不算注释）；
 *   * `"..."` / `'...'` 的内容 → 换成空串（帮助文本里写 `base:GetChildren()` 不是代码）。
 * 长括号字符串 `[[...]]` 跨行，本闸门按行判，遇到就不判这一行（宁漏不误报）。
 */
function stripComment(line) {
  let out = '';
  let quote = null;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quote) {
      if (ch === '\\') { i++; continue; }
      if (ch === quote) { out += '""'; quote = null; }
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; continue; }
    if (ch === '[' && (line[i + 1] === '[' || line[i + 1] === '=')) return null;   // 长字符串：跳过本行
    if (ch === '-' && line[i + 1] === '-') return out;
    out += ch;
  }
  return out;
}

const findings = [];

for (const file of files) {
  const rel = path.relative(ROOT, file).replace(/\\/g, '/');
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);

  lines.forEach((raw, idx) => {
    const code = stripComment(raw);
    if (code === null || !code.trim()) return;
    // `select("#", x:GetRegions())` / `select(i, x:GetChildren())` 是**正确**的多返回值用法
    // （select 本来就吃变长返回值），不是把多返回值当表。
    if (/\bselect\s*\(/.test(code)) return;
    const at = `${rel}:${idx + 1}`;

    for (const api of APIS) {
      // ① pcall(obj.GetChildren, obj) —— 只接到第一个返回值
      if (new RegExp(`pcall\\(\\s*[A-Za-z_][\\w.]*\\.${api}\\s*,`).test(code)) {
        findings.push([at, `pcall(x.${api}, x) 只接到第一个返回值`, code.trim()]);
      }
      // ② 赋值/传参时没有包表：`= x:GetChildren()`、`(x:GetChildren())` 而左边不是 `{`
      const bare = new RegExp(`([^\\{\\s])\\s*[:.]\\s*${api}\\s*\\(\\s*\\)`, 'g');
      let m;
      while ((m = bare.exec(code)) !== null) {
        const before = code.slice(0, m.index + 1);
        // 前面紧邻的是 `{` 或 `{ ` → 已包表，合规
        if (/\{\s*$/.test(before)) continue;
        // 已经在表构造里（同一行更前面有未闭合的 `{`）也算包表
        const opens = (before.match(/\{/g) || []).length;
        const closes = (before.match(/\}/g) || []).length;
        if (opens > closes) continue;
        findings.push([at, `x:${api}() 的多返回值没有包成表`, code.trim()]);
      }
      // ③ 直接对调用结果取长度
      if (new RegExp(`#\\s*[A-Za-z_][\\w.]*[:.]${api}\\s*\\(`).test(code)) {
        findings.push([at, `#${api}() 对多返回值取长度`, code.trim()]);
      }
    }
  });
}

if (findings.length === 0) {
  console.log(`audit-multireturn: ${files.length} 个文件，全部通过`);
  process.exit(0);
}

console.log(`audit-multireturn: ${files.length} 个文件，${findings.length} 处把多返回值当表用\n`);
for (const [at, why, code] of findings) {
  console.log(`  ${at}\n    ${why}\n    > ${code.slice(0, 160)}`);
}
console.log('\n修法：包成表 —— `local ok, list = pcall(function() return { x:GetChildren() } end)`，');
console.log('      或把包表提成模块级函数（`local function KidsOf(f) return { f:GetChildren() } end`）');
console.log('      再 `pcall(KidsOf, x)`，省掉每次调用新建的闭包。');
process.exit(1);
