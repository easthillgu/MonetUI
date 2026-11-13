/**
 * 像素级质量审计
 * 查三类问题：
 *
 *  1) 半覆盖像素 —— alpha 不是 0 也不是 255。曲线的抗锯齿边缘天然有，不算缺陷；
 *     但整幅由矩形/直线构成的纹理（STRICT 表）一个都不该有。
 *  2) 软边直边   —— 一条本该实心的直边，边缘却挂着半覆盖像素，也就是没落在像素
 *     边界上。判据是"长度 >= 8 的满 alpha 横/竖段，中段的邻居是半覆盖"。
 *     45° 斜线每行只连成 1–2 个像素，够不着长度门槛，所以斜笔和曲线不会被误判。
 *  3) 孤立像素   —— 描边路径上出现单独一个像素（8 邻域全透明），缩到显示尺寸会闪格。
 *     所有纹理都必须为 0。
 *
 * 用法：node tools/audit-pixels.js [目录]
 */

const fs = require('fs');
const path = require('path');

// 审计对象是 **TGA 源**（Assets-src/Textures，进 git 不发行）；发行包里的 BLP 由它们同步生成。
const DIR = process.argv[2] || path.join(__dirname, '..', 'Assets-src', 'Textures');

function decodeTGA(file) {
  const b = fs.readFileSync(file);
  const w = b.readUInt16LE(12), h = b.readUInt16LE(14);
  const topLeft = (b.readUInt8(17) & 0x20) !== 0;
  let o = 18;
  const px = new Uint8Array(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    const bl = b[o++], g = b[o++], r = b[o++], a = b[o++];
    const row = topLeft ? (i / w | 0) : h - 1 - (i / w | 0);
    const idx = (row * w + (i % w)) * 4;
    px[idx] = r; px[idx + 1] = g; px[idx + 2] = bl; px[idx + 3] = a;
  }
  return { w, h, px };
}

const partialCount = (d) => {
  let n = 0;
  for (let i = 0; i < d.w * d.h; i++) {
    const a = d.px[i * 4 + 3];
    if (a > 0 && a < 255) n++;
  }
  return n;
};

function isolatedCount(d) {
  const A = (x, y) => (x < 0 || y < 0 || x >= d.w || y >= d.h) ? 0 : d.px[(y * d.w + x) * 4 + 3];
  let n = 0;
  for (let y = 0; y < d.h; y++) {
    for (let x = 0; x < d.w; x++) {
      if (A(x, y) === 0) continue;
      let solid = 0;
      for (let dy = -1; dy <= 1; dy++)
        for (let dx = -1; dx <= 1; dx++) {
          if (!dx && !dy) continue;
          if (A(x + dx, y + dy) > 0) solid++;
        }
      if (solid === 0) n++;
    }
  }
  return n;
}

// 直边判定与"是否对齐"：
//   · 只有长度 >= 8 的满 alpha 横/竖段才算"直边"；
//   · 段的两端各留 5px 不检查 —— 那是圆角弧与斜笔转入直边的过渡区，半覆盖是应该的；
//   · 看中段：**整段的多数像素**都有半覆盖邻居，才算这条边落在像素边界之外。
//
// 为什么是"多数"而不是"任意一个"（2026-10-28 修）：粗笔画（12.5% 画布宽）的 45° 斜线在
// 交汇处（X 的中心、勾的肘部）会拼出 11px 以上的横向满 alpha 段，那些段的**个别**像素上方
// 是斜线的抗锯齿边 —— 那是几何必然，不是"边没对齐"。旧判据见到一个就判 FAIL，
// 于是所有加粗后的斜线图形都被误判（8/31 张）。真正的错位（一条边整体偏半个像素）会让
// 中段**每一个**像素都挂着半覆盖邻居，占比接近 100%，与交汇处的零星过渡区分得很开。
const MIN_RUN = 8, TRIM = 5, SOFT_FRACTION = 0.5;
function misalignedEdges(d) {
  const A = (x, y) => (x < 0 || y < 0 || x >= d.w || y >= d.h) ? 0 : d.px[(y * d.w + x) * 4 + 3];
  let runs = 0, soft = 0;
  const scan = (len, at, nbrA, nbrB) => {
    let i = 0;
    while (i < len) {
      if (at(i) !== 255) { i++; continue; }
      const i0 = i;
      while (i < len && at(i) === 255) i++;
      const i1 = i - 1;
      if (i1 - i0 + 1 < MIN_RUN) continue;
      runs++;
      let checked = 0, fuzzy = 0;
      for (let k = i0 + TRIM; k <= i1 - TRIM; k++) {
        checked++;
        const a = nbrA(k), b = nbrB(k);
        if ((a > 0 && a < 255) || (b > 0 && b < 255)) fuzzy++;
      }
      if (checked && fuzzy / checked >= SOFT_FRACTION) soft++;
    }
  };
  for (let y = 0; y < d.h; y++) scan(d.w, x => A(x, y), k => A(k, y - 1), k => A(k, y + 1));
  for (let x = 0; x < d.w; x++) scan(d.h, y => A(x, y), k => A(x - 1, k), k => A(x + 1, k));
  return { runs, soft };
}

// 下面两张表是**验收标准**，不是描述。写进来是为了让这把尺子有明确的及格线，
// 否则"半覆盖 508"这种数字没人知道该不该紧张。
//
// STRICT —— 整幅由吸附过的矩形/直线构成，半覆盖像素必须为 0。
const STRICT = new Set([
  'monet_barfill', 'monet_hairline',
]);

// NO_SOFT_EDGE —— 含直边段的纹理，那些直边必须落在像素边界上。
// 纯曲线纹理（勾 / V 形 / X / 圆）不在表内：圆与切线本来就该有半覆盖。
const NO_SOFT_EDGE = new Set([
  ...STRICT,
  'minimap_rect_mask', 'monet_corner',
  'monet_check', 'monet_chevron_up',
  'monet_close_normal', 'monet_close_hover', 'monet_close_push',
  // 窗口按钮：maximize / minimize 都是横竖直边（minimize 是那条横杠）。
  'monet_win_maximize', 'monet_win_minimize',
]);

// STENCIL —— 纯粹当染色模具用的纹理：运行期用 SetVertexColor / SetBackdropBorderColor 上色，
// 贴图自己只该提供 alpha。引擎是 贴图 × 顶点色 **相乘**，所以贴图里带的色相会原样乘进最终颜色：
//   #fffcf6 → borderColor × (1, 0.988, 0.965)，蓝少 3.5%。
// 边框是几百像素长的连续色带，这点偏差一眼能看出来；主题换成冷色时，被染的按下态金色 X
// 会变成浑浊的蓝褐。所以模具必须中性 —— 与透明像素用纯白衬底、role 图标用纯灰度同源。
//
// 不在表内的几张，色相本身就是美术，各有各的理由，别顺手"拉平"：
//   monet_close_hover   —— Skin.lua 注释明说 highlight 刻意不染色（加色混合，染色在深边框上会直接
//                          看不见），金色是 hover 状态信号本身。
//   monet_win_maximize  —— 顶部那条金色标题栏 = '这是个窗口' 的结构语义。
//   monet_brush_stroke  —— Widget:Rule 只调 alpha，奶油芯 / 赭石边的双色是这张图的存在理由。
//   monet_corner        —— Widget:Corners 同样只调 alpha，暖白弧线是画上去的。
//   minimap_rect_mask   —— 遮罩，根本不上色。
const STENCIL = new Set([
  'monet_barfill', 'monet_hairline',
  'monet_close_normal', 'monet_close_push',
  'monet_win_minimize',   // WorldMap 的还原/minimize 按钮：中性白，跟主题染色
  'monet_check', 'monet_radio',
  'monet_chevron_up',
  // 窗口右上角的 maximize / minimize 斜箭头：与 close 同一口径，纯白模具，运行期染主题边框色。
  'monet_maximize_arrow', 'monet_minimize_arrow',
  // 施法条火花 / 经验线三角：整张图只提供 alpha，颜色全交给 SetVertexColor（红 / 中性 / 经验色）。
  'monet_spark_up', 'monet_spark_down',
  'monet_role_tank', 'monet_role_heal', 'monet_role_dps',
  // 地图内的三个 4:3 徽章：运行期用 SetVertexColor 染成主题色 / 副本难度色，
  // 所以底色必须中性灰、描边必须纯白（它们的底与描边都在贴图里）。
  'monet_map_tracking', 'monet_map_compartment', 'monet_map_difficulty',
  // 进出战斗提示的剑 / 盾：运行期 SetVertexColor 染主题高光 / 主题色，图内只许明度层次。
  'monet_combat_sword', 'monet_combat_shield',
  // 背包 / 银行工具钮图标（整理 / 一键存入 / 栏位管理）：纯白剪影，运行期染 bright 档。
  'monet_tool_sort', 'monet_tool_deposit', 'monet_tool_slots',
  // A4 氛围暗角：整张图只给径向 alpha，压暗的颜色（近黑）由运行期 SetVertexColor 给 ——
  // 模具带色相会把那一点色相乘进"整个世界"，所以必须纯白。
  'monet_vignette_62', 'monet_vignette_55',
]);

// 色相偏离：非全透明像素里，三个通道两两之差的最大值。0 = 完全中性（纯白或纯灰都合法）。
// 用色相而不是"离纯白多远"当判据：role 图标是纯灰的，明度差 90+ 是刻意的明暗渐变撑立体感，
// 不该被判失败；而 #fffcf6 这种"几乎纯白但带一点暖"的会被抓出来 —— 那正是要修的。
function hueShift(d) {
  let max = 0;
  for (let i = 0; i < d.w * d.h; i++) {
    if (d.px[i * 4 + 3] === 0) continue;
    const r = d.px[i * 4], g = d.px[i * 4 + 1], b = d.px[i * 4 + 2];
    const d1 = r > g ? r - g : g - r;
    const d2 = g > b ? g - b : b - g;
    const d3 = r > b ? r - b : b - r;
    if (d1 > max) max = d1;
    if (d2 > max) max = d2;
    if (d3 > max) max = d3;
  }
  return max;
}

// 白衬底：Alpha=0 的像素里 RGB 不是纯白的个数。必须为 0，且**所有**纹理都适用，不分名单。
// 客户端建 mip / 滤波时会把边缘颜色拖进可见区，黑衬底（或任何非白衬底）会让图标镶一圈边；
// 纯白衬底乘任何染色正好等于那个染色，所以这是所有贴图的底线，不是可选项。
function matteCount(d) {
  let n = 0;
  for (let i = 0; i < d.w * d.h; i++) {
    if (d.px[i * 4 + 3] !== 0) continue;
    if (d.px[i * 4] === 255 && d.px[i * 4 + 1] === 255 && d.px[i * 4 + 2] === 255) continue;
    n++;
  }
  return n;
}

const files = fs.readdirSync(DIR).filter(f => f.endsWith('.tga')).sort();
console.log(`目录: ${DIR}\n`);
console.log('纹理'.padEnd(26) + '尺寸'.padEnd(11) + '半覆盖'.padStart(9) + '孤立'.padStart(8) + '直边段'.padStart(8) + '软边'.padStart(7) + '色相'.padStart(7) + '衬底'.padStart(8) + '  判定');
console.log('-'.repeat(104));

let fail = 0, totalPartial = 0, totalIso = 0, totalSoft = 0, totalMatte = 0;
for (const f of files) {
  const name = f.replace('.tga', '');
  const d = decodeTGA(path.join(DIR, f));
  const p = partialCount(d);
  const iso = isolatedCount(d);
  const m = misalignedEdges(d);
  const t = hueShift(d);
const m0 = matteCount(d);
totalPartial += p; totalIso += iso; totalSoft += m.soft; totalMatte += m0;

  const bad = [];
  if (STRICT.has(name) && p > 0) bad.push(`半覆盖应=0 实=${p}`);
  if (NO_SOFT_EDGE.has(name) && m.soft > 0) bad.push(`软边应=0 实=${m.soft}`);
  if (iso > 0) bad.push(`孤立应=0 实=${iso}`);
if (m0 > 0) bad.push(`透明衬底非纯白 应=0 实=${m0}`);
  if (STENCIL.has(name) && t > 0) bad.push(`模具带色相 应=0 实=${t}`);
  if (bad.length) fail++;

  console.log(name.padEnd(26) +
    `${d.w}x${d.h}`.padEnd(11) +
    String(p).padStart(9) + String(iso).padStart(8) +
    String(m.runs).padStart(8) + String(m.soft).padStart(7) + String(t).padStart(7) + String(m0).padStart(8) +
    '  ' + (bad.length ? '[FAIL] ' + bad.join('; ') : '[PASS]'));
}
console.log('-'.repeat(86));
console.log(`合计: 半覆盖 ${totalPartial}，孤立像素 ${totalIso}，软边直边 ${totalSoft}，非纯白衬底 ${totalMatte}，未通过 ${fail} / ${files.length}`);

console.log('\n判据：');
console.log('  半覆盖 —— 曲线抗锯齿边缘天然有，不算缺陷；纯矩形纹理（STRICT）必须为 0');
console.log('  孤立   —— 描边断点，缩到 16–22px 会闪格，所有纹理都必须为 0');
console.log('  软边   —— 本该实心的直边在发虚，含直边段的纹理（NO_SOFT_EDGE）必须为 0');
console.log('  色相   —— 非全透明像素里三通道两两之差的最大值；染色模具（STENCIL）必须为 0。');
console.log('            贴图×顶点色 是相乘：#fffcf6 染完蓝少 3.5%，边框那种长色带一眼看得出来，');
console.log('            主题换冷色时按下态会变成浑浊的蓝褐');
console.log('  衬底   —— Alpha=0 的像素里 RGB 不是纯白的个数；**所有**纹理都必须为 0。黑衬底会在建 mip /');
console.log('            滤波时把边缘颜色拖进可见区，图标镶一圈边；纯白衬底乘任何染色正好等于那个染色');
console.log('            圆 / 弧 / 切线不在表内：曲线的切点本来就该有半覆盖');