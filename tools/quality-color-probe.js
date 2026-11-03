/**
 * 品质色（Skin:QualityColor）闸门入口 —— 跑 tools/harness/quality-color-probe.lua 那套断言。
 *
 * 为什么要 node 入口而不是"直接叫大家跑 lua"：
 *   其它闸门都是 `node tools/xxx.js`，验收时一条命令跑一套；本机 lua 的调用名在各人机器上
 *   不一样（lua / lua5.4 / lua5.1 / luajit，或只有绝对路径），所以这里负责把解释器找出来，
 *   找不到就**明确失败退出 1**，绝不静默跳过（静默跳过等于这条判据没跑过 yet 显示绿）。
 *
 * 跑两件事：
 *   1) 源码级：六档兜底的字面量（含旧的位置表写法）在全仓只允许出现在 Utils/Skin.lua 一处，
 *      Modules/Bags/Bags.lua 里不能再有 QUALITY_COLOR —— 这条不需要解释器，先跑。
 *   2) 行为级：把 Lua 探针跑起来（品质色场景断言 + 源码接线断言，条数由探针自己打印），
 *      退出码原样透传。
 *
 * 用法：node tools/quality-color-probe.js
 *      （或设环境变量 LUA_BIN 指定解释器：LUA_BIN=C:\path\to\lua.exe node tools/quality-color-probe.js）
 * 解释器只需要能跑 Lua 5.1 语法子集：探针里没用 loadstring / // / goto / table.unpack。
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const PROBE = path.join(__dirname, 'harness', 'quality-color-probe.lua');
const SKIP_DIRS = new Set(['.git', 'node_modules', 'Libs', 'docs', 'Assets', 'Assets-src', 'tools']);

let pass = 0;
let fail = 0;
function ok(cond, label) {
  if (cond) { pass++; console.log('  [OK]   ' + label); }
  else { fail++; console.log('  [FAIL] ' + label); }
}

/** 六档手调数的两种写法都算"自己算品质色"：命名字段（现在）与位置表（改动前 / Bags 旧表）。 */
const LITERALS = [
  '0.65, g = 0.30, b = 0.95', '0.65, 0.30, 0.95',   // Epic 紫
  '1.00, g = 0.55, b = 0.00', '1.00, 0.55, 0.00',   // Legendary 橙
  '0.90, g = 0.80, b = 0.40', '0.90, 0.80, 0.40',   // Artifact / Heirloom
];

function walk(dir, out) {
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    const st = fs.statSync(p);
    if (st.isDirectory()) {
      if (SKIP_DIRS.has(name)) continue;
      walk(p, out);
    } else if (name.endsWith('.lua')) {
      out.push(p);
    }
  }
  return out;
}

console.log('=== 品质色单一来源（源码级）===');
if (!fs.existsSync(PROBE)) {
  console.log('[FAIL] 找不到探针本体 ' + PROBE);
  process.exit(1);
}

const files = walk(ROOT, []);
const holders = [];
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  if (LITERALS.some((lit) => src.includes(lit))) holders.push(path.relative(ROOT, f));
}
const skinRel = path.join('Utils', 'Skin.lua');
ok(holders.length === 1 && holders[0] === skinRel,
  '六档手调数只存在于 Utils/Skin.lua（实测命中：' + (holders.join(', ') || '无') + '）');

const bags = fs.readFileSync(path.join(ROOT, 'Modules', 'Bags', 'Bags.lua'), 'utf8');
ok(!/local\s+QUALITY_COLOR\s*=\s*\{/.test(bags), 'Modules/Bags/Bags.lua 没有自己的品质色表');
ok(bags.includes('Skin:QualityColor(rec.quality or 0)'), 'Modules/Bags/Bags.lua 走 Skin:QualityColor');

console.log('');
console.log('=== 行为断言（Lua 探针）===');

function findLua() {
  const candidates = [];
  if (process.env.LUA_BIN) candidates.push({ cmd: process.env.LUA_BIN, args: [] });
  for (const name of ['lua', 'lua5.1', 'lua51', 'lua5.4', 'lua54', 'luajit']) {
    candidates.push({ cmd: name, args: [] });
  }
  const localAppData = process.env.LOCALAPPDATA || '';
  if (localAppData) {
    candidates.push({ cmd: path.join(localAppData, 'Programs', 'Lua', 'bin', 'lua.exe'), args: [] });
  }
  for (const c of candidates) {
    const r = spawnSync(c.cmd, ['-v'], { encoding: 'utf8', windowsHide: true });
    if (!r.error && r.status === 0) {
      return { cmd: c.cmd, version: (r.stdout || r.stderr || '').trim().split('\n')[0] };
    }
  }
  return null;
}

const lua = findLua();
if (!lua) {
  console.log('  [FAIL] 机器上找不到 Lua 解释器（试过 LUA_BIN / lua / lua5.1 / lua5.4 / luajit /');
  console.log('         %LOCALAPPDATA%\\Programs\\Lua\\bin\\lua.exe）。行为断言**没有跑过**，');
  console.log('         这条闸门判失败 —— 设 LUA_BIN 指到一个解释器再重跑。');
  fail++;
} else {
  console.log('  解释器：' + lua.cmd + '（' + lua.version + '）');
  const r = spawnSync(lua.cmd, [PROBE], { cwd: ROOT, encoding: 'utf8', windowsHide: true });
  const out = (r.stdout || '') + (r.stderr || '');
  process.stdout.write(out.endsWith('\n') ? out : out + '\n');
  ok(r.status === 0, '探针退出码 0（实际 ' + r.status + '）');
}

console.log('');
console.log('quality-color-probe: ' + pass + ' 通过 / ' + fail + ' 失败');
process.exit(fail === 0 ? 0 : 1);
