/**
 * Mult() / SnapUnit() 的离线自测
 *
 * 为什么是"镜像 + 源码断言"而不是直接跑 Media.lua：
 * 那两个函数是 Lua 5.1，Node 里跑它等于要写半个 transpiler（local/then/end/and/or/~= 全要转）。
 * 这里手写一份等价的 JS 负责算术验证，再用 SOURCE_PINS 里的断言把公式钉在真实源码上——
 * 改了 Media.lua 里的公式而不同步这里，测试会直接失败。
 *
 * 验证三件事：
 *   1) N * Mult() 折回物理像素后恒等于 N（边框宽度不随缩放漂）
 *   2) SnapUnit() 的结果一定落在网格上，且偏差不超过半个格子
 *   3) CVar 读不到 / 非法时退回 1 而不是崩
 *
 * 用法：node tools/test-mult.js
 */

const fs = require('fs');
const path = require('path');

const LUA = path.join(__dirname, '..', 'Utils', 'Media.lua');
const src = fs.readFileSync(LUA, 'utf8');

// ---- 公式镜像（与 Utils/Media.lua 保持一致）----
// 镜像 Utils/Media.lua：一个物理像素 = (768/physH)/uiScale 个 UI 单位。
// physH 缺省 1080（最常见的分辨率），测试里会显式覆盖。
function readMult(getCVar, physH) {
  let raw;
  if (getCVar) {
    try { raw = getCVar('uiScale'); } catch (_) { raw = undefined; }
  }
  const scale = parseFloat(raw);
  if (!(scale > 0) || !Number.isFinite(scale)) return 1;
  if (scale < 0.1 || scale > 6) return 1;
  const h = (typeof physH === 'number' && physH > 0) ? physH : 1080;
  return (768 / h) / scale;
}

// UI 单位 -> 物理像素：1 UI 单位 = (physH/768) 屏幕单位 = (physH/768)*es 物理像素。
function uiToPhysical(uiUnits, scale, physH) {
  const h = (typeof physH === 'number' && physH > 0) ? physH : 1080;
  return uiUnits * (h / 768) * scale;
}
function snapUnit(x, mult) {
  const n = Number(x);
  if (!n || n === 0) return x;
  return mult * Math.floor(n / mult + 0.5);
}

// ---- 源码断言：公式必须还长在 Media.lua 里 ----
// negate=true 的条目表示"这段源码**不应**出现"
const SOURCE_PINS = [
  [/pcall\(CVar,\s*"uiScale"\)/, 'Mult 必须经 pcall 读 uiScale CVar'],
  [/return\s+\(\s*768\s*\/\s*physH\s*\)\s*\/\s*scale/, 'Mult 必须返回 (768/physH)/scale —— 少了 768/physH 就不是物理像素'],
  [/GetPhysicalScreenSize/, 'Mult 必须从 GetPhysicalScreenSize 取屏幕高'],
  [/return\s+1\s*\/\s*scale\b/, 'Mult 只在拿不到分辨率时才退回 1/scale'],
  [/scale\s*<\s*0\.1\s+or\s+scale\s*>\s*6/, 'Mult 必须保留 0.1–6 的合理性区间'],
  [/math\.floor\(\s*n\s*\/\s*m\s*\+\s*0\.5\s*\)/, 'SnapUnit 必须四舍五入到网格'],
  [/function Media:SnapUnit[\s\S]{0,300}?m\s*==\s*1\s+then/, 'SnapUnit 不得保留 m==1 跳过分支（会把 19.37 原样放行）', true],
];

let bad = 0;
console.log('=== 源码断言（公式必须与 Utils/Media.lua 一致）===');
for (const [re, label, negate] of SOURCE_PINS) {
  const matched = re.test(src);
  const ok = negate ? !matched : matched;
  if (!ok) bad++;
  console.log(`  ${ok ? '[OK]  ' : '[FAIL]'} ${label}`);
}

// ---- 数值验证 ----
const SCALES = ['1.000000', '1.250000', '1.150000', '0.800000', '0.710000', '0.640000'];
const stub = (v) => (name) => (name === 'uiScale' ? v : undefined);

console.log('\n=== 边框宽度不随缩放漂移（1080p）===');
console.log('uiScale    Mult()     1物理px需     thickness=1   thickness=2');
console.log('-'.repeat(74));
const PHYS_1080 = 1080;
for (const s of SCALES) {
  const scale = parseFloat(s);
  const mult = readMult(stub(s), PHYS_1080);
  const b1 = uiToPhysical(1 * mult, scale, PHYS_1080);
  const b2 = uiToPhysical(2 * mult, scale, PHYS_1080);
  const ok = Math.abs(b1 - 1) < 1e-9 && Math.abs(b2 - 2) < 1e-9;
  if (!ok) bad++;
  console.log(s.padEnd(11) + mult.toFixed(4).padEnd(11) +
    ((768 / PHYS_1080) / scale).toFixed(4).padEnd(14) +
    b1.toFixed(6).padEnd(15) + b2.toFixed(6).padEnd(10) + (ok ? ' [OK]' : ' [FAIL]'));
}

console.log('\n=== 不同分辨率下「1px 边框」的真实像素数 ===');
console.log('（旧公式 1/uiScale 会随分辨率一路膨胀，新公式恒为 1.0）');
console.log('分辨率       physH    uiScale   新公式    旧公式    比值');
console.log('-'.repeat(70));
const RES = [['1280x720', 720, 0.9375], ['1920x1080', 1080, 0.7111],
             ['2560x1440', 1440, 0.5333], ['3840x2160', 2160, 0.3556]];
for (const [label, h, scale] of RES) {
  const now = uiToPhysical(1 * readMult(stub(String(scale)), h), scale, h);
  const old = uiToPhysical(1 * (1 / scale), scale, h);
  const ok = Math.abs(now - 1) < 1e-6;
  if (!ok) bad++;
  console.log(label.padEnd(12) + String(h).padEnd(9) + scale.toFixed(4).padEnd(10) +
    now.toFixed(3).padEnd(10) + old.toFixed(3).padEnd(10) + (old / now).toFixed(3).padEnd(8) + (ok ? '[OK]' : '[FAIL]'));
}

console.log('\n=== SnapUnit 落在网格上 ===');
for (const s of SCALES) {
  const mult = readMult(stub(s));
  let worst = 0, worstX = 0;
  for (let x = 1; x <= 200; x += 0.37) {
    const y = snapUnit(x, mult);
    const ratio = y / mult;
    const err = Math.abs(ratio - Math.round(ratio));
    if (err > worst) { worst = err; worstX = x; }
  }
  // 吸附误差不得超过浮点噪声；worstX 只在真有偏离时才有意义，不参与判定
  const ok = worst < 1e-9;
  if (!ok) bad++;
  console.log(`  uiScale ${s}  mult ${mult.toFixed(4)}  最大偏离 ${worst.toExponential(1)} (x=${worstX.toFixed(2)})  ${ok ? '[OK]' : '[FAIL]'}`);
}

console.log('\n=== 吸附的实际取值（thickness=1/2 的边框宽，1080p）===');
for (const s of ['1.000000', '0.710000', '0.640000']) {
  const mult = readMult(stub(s), PHYS_1080);
  const scale = parseFloat(s);
  const t1 = snapUnit(1 * mult, mult);
  const t2 = snapUnit(2 * mult, mult);
  console.log(`  uiScale ${s}: 1px 边框 = ${t1.toFixed(4)} UI 单位 = ${uiToPhysical(t1, scale, PHYS_1080).toFixed(4)} 物理px   ` +
              `2px 边框 = ${t2.toFixed(4)} UI 单位 = ${uiToPhysical(t2, scale, PHYS_1080).toFixed(4)} 物理px`);
}

console.log('\n=== 圆角边框选环（Utils/Widget.lua PickRoundEdge）===');
console.log('  贴图里环宽只能是整数纹素（=整数 UI 单位），想要的却是 thickness/uiScale，所以取最近的一个。');

// 镜像 Utils/Widget.lua 的 ROUND_EDGES（ring = 环宽纹素，slice = 外弧半径 = 9-slice 切片）
const ROUND_EDGES = [
  { key: 'monet_round_edge_thin', ring: 1, slice: 2 },
  { key: 'monet_round_edge', ring: 2, slice: 3 },
  { key: 'monet_round_edge_thick', ring: 3, slice: 4 },
];
function pickRoundEdge(thickness, mult) {
  const want = thickness * mult;
  let best = ROUND_EDGES[0], bestErr;
  for (const e of ROUND_EDGES) {
    const err = Math.abs(e.ring - want);
    if (bestErr === undefined || err < bestErr) { best = e; bestErr = err; }
  }
  return best;
}

// 源码断言：Widget.lua 的环参数必须与生成器一致，否则边框会漂或被切掉
const widgetLua = fs.readFileSync(path.join(__dirname, '..', 'Utils', 'Widget.lua'), 'utf8');
for (const [ring, slice, suffix] of [[1, 2, '_thin'], [2, 3, ''], [3, 4, '_thick']]) {
  const re = new RegExp('"monet_round_edge' + suffix + '"\\s*,\\s*ring\\s*=\\s*' + ring + '\\s*,\\s*slice\\s*=\\s*' + slice);
  const ok = re.test(widgetLua);
  if (!ok) bad++;
  console.log(`  ${ok ? '[OK]  ' : '[FAIL]'} Widget.lua: monet_round_edge${suffix || '(base)'} = ring ${ring} / slice ${slice}`);
}

console.log('\nuiScale    thickness  选中环                 物理宽   误差    平边框  差');
console.log('-'.repeat(78));
// 判据：选中的必须是**最近的**环 —— 误差不超过半个纹素（换回物理像素就是半纹素）。
// 注意这不是「和平边框等宽」：平边框的 edgeSize 是 thickness*Mult()，可以是小数 UI 单位，
// 能精确命中 N 物理像素；圆角环烘在贴图里，只能是整数纹素 = 整数 UI 单位。
// 两者只在 uiScale == 768/physH（客户端默认缩放）时相等，其余缩放下必然差最多半个纹素。
const SUPPORTED_MAX_THICKNESS = 2;
for (const s of SCALES) {
  const scale = parseFloat(s);
  const mult = readMult(stub(s), PHYS_1080);
  for (const thickness of [1, 2, 3]) {
    const e = pickRoundEdge(thickness, mult);
    const phys = uiToPhysical(e.ring, scale, PHYS_1080);
    const flat = uiToPhysical(thickness * mult, scale, PHYS_1080);   // 平边框：恒等于 thickness
    const err = phys - thickness;
    const halfTexel = uiToPhysical(0.5, scale, PHYS_1080);
    const supported = thickness <= SUPPORTED_MAX_THICKNESS;
    const ok = supported ? (Math.abs(err) <= halfTexel + 1e-9) : true;
    if (!ok) bad++;
    const note = supported ? (ok ? '[OK]' : '[FAIL]') : '(超出三张环覆盖，仅记录)';
    console.log(s.padEnd(11) + String(thickness).padEnd(11) + e.key.padEnd(24) +
      phys.toFixed(3).padEnd(9) + err.toFixed(3).padEnd(8) + flat.toFixed(3).padEnd(8) +
      (phys - flat).toFixed(3).padEnd(8) + note);
  }
}

console.log('\n  ↑「差」= 圆角边框比平边框宽/窄多少物理像素。只有 uiScale == 768/physH 时为 0：');
const defaultScale = 768 / PHYS_1080;
console.log(`     1080p 的默认缩放是 ${defaultScale.toFixed(4)}，此时 1 UI 单位 = 1 物理像素，环宽纹素数就是物理像素数。`);
console.log('     其它缩放下两者必然差最多半个纹素 —— 这是整数纹素贴图的固有上限，不是选择。');

console.log('\n=== 退化输入必须退回 1，而不是崩 ===');
for (const [v, note] of [[undefined, 'CVar 不存在'], ['', '空串'], ['garbage', '非数字'],
                         ['0', '零'], ['-1', '负数'], ['99', '超出合理性区间']]) {
  let m;
  try { m = readMult(v === undefined ? undefined : stub(v)); }
  catch (e) { bad++; console.log(`  ${note}: 抛异常 [FAIL] ${e.message}`); continue; }
  const ok = m === 1;
  if (!ok) bad++;
  console.log(`  ${note.padEnd(18)} => Mult() = ${m}  ${ok ? '[OK]' : '[FAIL]'}`);
}


// ---- 固定表（Utils/Media.lua scalePresets）：1 单位必须落在整数物理像素上 ----
// 解析源码里的表（表达式只有数字四则），逐档验算：1 UI 单位 = (physH/768) * scale 物理像素。
console.log('\n=== 按分辨率固定的 UI 缩放（Media.scalePresets）===');
const presetPin = [[/Media\.scalePresets\s*=/, 'Media 必须有 scalePresets 表']];
for (const [re, label] of presetPin) {
  const ok = re.test(src);
  if (!ok) bad++;
  console.log(`  ${ok ? '[OK]  ' : '[FAIL]'} ${label}`);
}

// 客户端的 UI 缩放滑块下限（Blizzard_SettingsDefinitions_Shared/Graphics.lua:925）。
// 首选值低于它会被夹掉，所以每档都备了下一个候选。
const SLIDER_MIN = 0.65;
const PRESET_HEIGHTS = [1080, 1440, 2160];

// 逐行解析：[height] = { { scale = <expr>, pixels = <n> }, ... }
const presets = {};
let inTable = false, curHeight = null;
for (const line of src.split(/\r?\n/)) {
  if (/Media\.scalePresets\s*=/.test(line)) { inTable = true; continue; }
  if (!inTable) continue;
  if (/^\}/.test(line)) break;                       // 表结束
  let m = line.match(/\[(\d+)\]\s*=\s*\{/);
  if (m) { curHeight = parseInt(m[1], 10); presets[curHeight] = presets[curHeight] || []; }
  m = line.match(/scale\s*=\s*([^,]+?),\s*pixels\s*=\s*(\d+)/);
  if (m && curHeight !== null) {
    let value = NaN;
    try { value = Function('"use strict"; return (' + m[1].trim() + ');')(); } catch (_) {}
    presets[curHeight].push({ scale: value, pixels: parseInt(m[2], 10) });
  }
}

console.log('分辨率        候选   uiScale      1单位=物理px   表里写的   判定');
console.log('-'.repeat(76));
for (const h of PRESET_HEIGHTS) {
  const list = presets[h];
  if (!list || list.length === 0) {
    bad++;
    console.log(`${String(h).padEnd(12)} [FAIL] 固定表里没有这一档`);
    continue;
  }
  list.forEach((cand, idx) => {
    const px = (h / 768) * cand.scale;
    const rounded = Math.round(px);
    const integral = Math.abs(px - rounded) < 1e-9;
    const claimOk = cand.pixels === rounded;
    const inRange = cand.scale >= SLIDER_MIN;
    // 每一档都必须：1 单位落在整数物理像素上，且表里写的 pixels 与算出来的一致。
    // 首选值允许低于滑块下限（会被客户端夹掉）——那正是备候选存在的理由：
    // 这种情况下必须有下一个候选顶得上，而且它得在范围内。
    const ok = integral && claimOk && (inRange || (list[idx + 1] && list[idx + 1].scale >= SLIDER_MIN));
    if (!ok) bad++;
    console.log(`${String(h).padEnd(12)} ${String(idx + 1).padEnd(6)} ${cand.scale.toFixed(6).padEnd(12)} ` +
      `${px.toFixed(4).padEnd(13)} ${String(cand.pixels).padEnd(10)} ` +
      `${ok ? '[OK]' : '[FAIL]'}${integral ? '' : ' 非整数'}${claimOk ? '' : ' 表值不符'}` +
      `${(idx === 0 && !inRange) ? ' (低于滑块下限 ' + SLIDER_MIN + '，会退到候选 2)' : ''}`);
  });
}

console.log('\n' + (bad === 0 ? '全部通过' : bad + ' 项未通过'));
process.exit(bad === 0 ? 0 : 1);