// tools/map-env-derive.js
// 派生「大陆层 / 世界层」环境色 —— 给 MonetColorMapData 的 override 通道喂数据。
//
// 为什么要有这个脚本：数据表只有 14 个**区域**行，父链解析（LibMonetColor:587-611
// override → data → C_Map 父链 → fallback）走到大陆层时一个祖先都没有，未覆盖区只能
// 落硬编码的无彩灰兜底。docs/HANDOFF.md:1942 拍板「先加 1414/1415/947 三行父链兜底，
// 色由该层成员区的已提取色取圆均值派生」——这条不改一行引擎代码就能让未覆盖区落在同陆调子上。
//
// 口径（写死在这里，别在别处手抄数字）：
//   · hue = 成员区 env.h 的**圆均值**（把每个色相投到单位圆上取 atan2），s / l = 算术均值；
//     和生成链 tools/gen_map_env.ps1 对单区多张截图的口径一致（pct 加权在区域内部已经做完，
//     区域之间按**等权**平均 —— 按截图数加权会让灰谷 7 张盖过别人）。
//   · 成员归属来自经典大陆划分，**逐条待实机核**（1.60 的 UiMap parentMapID 没有离线数据源）；
//     泽风岛 2521 是 1.60 新增区，HANDOFF:1923 记它的 parent 直接是 947（不是大陆），
//     所以它只进世界层，不进任何大陆。
//   · 这三行是**派生**值，不是提取值：所以走 override 文件，绝不写回生成文件本体
//     （MonetColorMapData-1.0.lua 头部写明 AUTO-GENERATED —— 手改会被下一次生成覆盖）。
//
// Usage:
//   node tools/map-env-derive.js                       打印派生表 + 三行 Lua
//   node tools/map-env-derive.js --emit <path>         把 override Lua 文件整份重写到 <path>
//   node tools/map-env-derive.js --data <path>         指定 game_palette_v1.json（默认见下）
// 只读 monetcolors 仓，一个字节都不写回去。

const fs = require("fs");
const path = require("path");

const argv = process.argv.slice(2);
function flagVal(name, def) {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : def;
}

const DATA = flagVal(
  "--data",
  "C:/Users/EastHillGu/Documents/wowaddonsdev/monetcolors/data/game_palette_v1.json"
);
const EMIT = flagVal("--emit", null);

// 区域 mapID -> 所属父层。1414 卡利姆多 / 1415 东部王国 / 947 艾泽拉斯（HANDOFF:1921-1923）。
const PARENTS = {
  1414: { name: "卡利姆多", members: [1413, 1440, 1441, 1444, 1446, 1454] },
  1415: { name: "东部王国", members: [1417, 1420, 1421, 1424, 1429, 1436, 1458] },
  947: { name: "艾泽拉斯", members: null }, // null = 全部成员区（含 2521 泽风岛）
};

if (!fs.existsSync(DATA)) {
  console.error(`取不到数据源：${DATA}`);
  console.error("monetcolors 仓不在预期位置（只读）。用 --data <game_palette_v1.json> 指过去。");
  process.exit(1);
}

const zones = JSON.parse(fs.readFileSync(DATA, "utf8"));
const byID = new Map();
for (const z of zones) if (z && z.mapID && z.env) byID.set(z.mapID, z);

const r1 = (v, d) => Number(v.toFixed(d));

/** 圆均值：先把每个色相投到单位圆，取合矢量的角度。直接算术平均在 350°/10° 这种跨零
 *  的样本上会算出 180°（完全反的方向），这是本仓唯一能算错这一行的地方。 */
function circularMeanHue(list) {
  let x = 0, y = 0;
  for (const h of list) {
    const rad = (h * Math.PI) / 180;
    x += Math.cos(rad);
    y += Math.sin(rad);
  }
  let deg = (Math.atan2(y, x) * 180) / Math.PI;
  if (deg < 0) deg += 360;
  return deg;
}

const rows = [];
for (const id of Object.keys(PARENTS).map(Number).sort((a, b) => a - b)) {
  const parent = PARENTS[id];
  const memberIDs = parent.members || [...byID.keys()];
  const found = memberIDs.filter((m) => byID.has(m));
  if (!found.length) {
    console.error(`父层 ${id} 一个成员区都没取到色，跳过`);
    continue;
  }
  const miss = memberIDs.filter((m) => !byID.has(m));
  const envs = found.map((m) => byID.get(m).env);
  const row = {
    mapID: id,
    name: parent.name,
    h: r1(circularMeanHue(envs.map((e) => e.h)), 1),
    s: r1(envs.reduce((a, e) => a + e.s, 0) / envs.length, 3),
    l: r1(envs.reduce((a, e) => a + e.l, 0) / envs.length, 3),
    members: found,
    missing: miss,
  };
  // 合矢量的模长 = 样本的离散度：越接近 0 说明成员色相越互相抵消，"这一层的调子"越没意义。
  let x = 0, y = 0;
  for (const e of envs) {
    const rad = (e.h * Math.PI) / 180;
    x += Math.cos(rad); y += Math.sin(rad);
  }
  row.concentration = r1(Math.hypot(x, y) / envs.length, 3);
  rows.push(row);
}

const lines = [];
lines.push("-- Libs/MonetColorMapData-1.0/MonetColorMapEnvOverride.lua");
lines.push("-- MonetColorMapData 的**运行时补充行**（大陆层 / 世界层），经 LibMonetColor 的 override 通道注册。");
lines.push("-- 生成：node tools/map-env-derive.js --emit Libs/MonetColorMapData-1.0/MonetColorMapEnvOverride.lua");
lines.push("-- 数据源：monetcolors data/game_palette_v1.json（14 个区域 39 张截图的已提取环境色）—— 本仓只读它，不回写。");
lines.push("--");
lines.push("-- 和 MonetColorMapData-1.0.lua（AUTO-GENERATED，手改会被下一次生成覆盖）的分工：");
lines.push("--   生成文件 = 逐区**提取**色；本文件 = 父层**派生**色（成员区 env 的圆均值 + 算术均值）。");
lines.push("--   引擎解析序 override -> data -> C_Map 父链 -> fallback（LibMonetColor:580-611），");
lines.push("--   所以父层行只作为**别人的祖先**被查到，绝不顶掉任何一条实测区域色。");
lines.push("--");
lines.push("-- 已知未核项：成员归属按经典大陆划分，1.60 的 parentMapID 没有离线数据源，待实机核");
lines.push("--   （tools/map-env-coverage.js --dump 能吃实机导出的父链表）。");
lines.push("");
lines.push("-- mapID -> { name, h, s, l }；数值口径与生成文件一致（h [0,360]、s l [0,1]）。");
lines.push("local OVERRIDE = {");
for (const r of rows) {
  lines.push(
    `    [${r.mapID}] = { name = '${r.name}', h = ${r.h}, s = ${r.s}, l = ${r.l} }, -- 派生自 ${r.members.length} 个成员区（色相集中度 ${r.concentration}${r.missing.length ? `，缺 ${r.missing.join("/")}` : ""}）`
  );
}
lines.push("}");
lines.push("");
lines.push("-- 取引擎实例：Libs.xml 里本文件排在 LibMonetColor-1.0 之后，正常一定拿得到。查法照引擎");
lines.push("-- 自己的双通道（LibStub 表 → 全局别名 _G.LibMonetColor，见 LibMonetColor:542-557 与 :1143），");
lines.push("-- 所以离线 tooling 里 dofile 也接得上；都拿不到（别人裁掉了引擎 / 加载序被改）就整文件");
lines.push("-- 静默跳过，行为退回「没有父层行」。");
lines.push("local LibStub = _G.LibStub");
lines.push("local LMC");
lines.push('if type(LibStub) == "table" then');
lines.push('    local ok, lib = pcall(LibStub, "LibMonetColor-1.0", true)');
lines.push("    if ok and type(lib) == \"table\" then LMC = lib end");
lines.push("end");
lines.push('if type(LMC) ~= "table" then LMC = _G.LibMonetColor end');
lines.push('if not (LMC and type(LMC.RegisterMapEnv) == "function") then return end');
lines.push("");
lines.push("-- 一条一行：RegisterMapEnv 自己会 ClearCache + Refresh（LibMonetColor:819-841）。");
lines.push("-- 本文件在 Libs 组、Core 之前加载，那一刻还没有人订阅引擎回调，所以这几次刷新");
lines.push("-- 只是重算一遍缓存，不会广播重涂。");
lines.push("for mapID, entry in pairs(OVERRIDE) do");
lines.push("    LMC:RegisterMapEnv(mapID, entry.h, entry.s, entry.l, entry.name)");
lines.push("end");
lines.push("");

if (EMIT) {
  const target = path.resolve(EMIT);
  fs.writeFileSync(target, lines.join("\r\n") + "\n", "utf8");
  console.log(`已写出 ${target}`);
} else {
  console.log(lines.join("\n"));
}

console.error("");
console.error("派生明细（父层 = 成员区 env 的圆均值/算术均值）：");
for (const r of rows) {
  console.error(
    `  ${r.mapID} ${r.name}: h ${r.h} s ${r.s} l ${r.l}  <- ${r.members.map((m) => `${m} ${byID.get(m).zone}`).join(" | ")}` +
      (r.missing.length ? `  [缺色成员 ${r.missing.join("/")}]` : "") +
      `  色相集中度 ${r.concentration}`
  );
}
