// tools/map-env-coverage.js
// 区域环境色**覆盖率**账（只读脚本，不进发行包）。
//
// 为什么要它：在此之前"补了多少区"全靠感觉，而运行期配色是 mapID -> 查表 -> 派生四槽
// （LibMonetColor:619 默认采样器就是查表），一条没命中就落无彩灰兜底（:78）。
// 这个脚本把三档数出来：**有色 / 走父链 / 落兜底**。
//
// 解析序与引擎逐条对齐（LibMonetColor:580-611，不要在这里改口径）：
//   1. overrideEnv（运行时补充行，两层：派生父层 MonetColorMapEnvOverride.lua
//      + 官方地图贴图色 MonetColorMapEnvAtlas.lua）。2026-11-08 色源优先级 = 贴图 > trip > 游戏截图，
//      所以贴图行顶掉同名实测行是**预期**（优先级闸门见 tools/env-source-check.js），不是缺陷；
//      只有派生父层行顶掉实测区域行才算缺陷。
//   2. MapEnv（生成文件 MonetColorMapData-1.0.lua，AUTO-GENERATED）
//   3. C_Map.GetMapInfo(mapID).parentMapID 往上走，**深度上限 5**，命中 override/data 即 parent:*
//   4. fallback（无彩灰）
//
// 两个数据源，同一套判定：
//   --dump <json>   实机导出的地图树 [{ mapID, name, parentMapID }, ...]
//                   （父链真值，全量三档只有这条路能给）
//   默认            仓库里**已记录**的地图清单（docs/HANDOFF.md 8.14.1 / 8.14.2 / :2092），
//                   父层按已知的"区域 -> 大陆 -> 世界"结构填，标 ASSUMED；
//                   清单外的 mapID 一个都不臆造 —— 报"覆盖不了全量"而不是报一个漂亮数。
//
// API 名字与结构按离线 dump 核过（本车道没有 docs/api，口径同 tools/api-audit.js 的回退源
// C:/Users/EastHillGu/Documents/wowaddonsdev/wow-forever-api）：
//   C_Map.GetMapInfo(uiMapID: number) -> UiMapDetails { mapID, name, mapType, parentMapID, flags }
//       MayReturnNothing = true，SecretArguments = "AllowedWhenUntainted"
//   C_Map.GetMapChildrenInfo(uiMapID: number, mapType: UIMapType?, allDescendants: bool?)
//       -> { UiMapDetails, ... }，同样 MayReturnNothing + AllowedWhenUntainted
//   两者返回值在 dump 里**没有**标成机密；但 name 之后要进 format/SetText，
//   仍按 AGENTS 的规矩先过一次 Secrets.CanRead（本仓判例：type() 判不出机密字符串）。
// 导出 dump 的落点在实机（本车道不部署、不进游戏，所以这条路留给有客户端的一趟）。
//
// Usage:
//   node tools/map-env-coverage.js                 已记录清单的三档账（含缺口表）
//   node tools/map-env-coverage.js --dump t.json   实机地图树的完整账
//   node tools/map-env-coverage.js --json          机器可读输出（给别的脚本接着算）

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const val = (f, d) => {
  const i = argv.indexOf(f);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[i + 1] : d;
};

const DATA_FILE = path.join(ROOT, "Libs", "MonetColorMapData-1.0", "MonetColorMapData-1.0.lua");
const OVERRIDE_FILE = path.join(ROOT, "Libs", "MonetColorMapData-1.0", "MonetColorMapEnvOverride.lua");
const ATLAS_FILE = path.join(ROOT, "Libs", "MonetColorMapData-1.0", "MonetColorMapEnvAtlas.lua");

/** 从 Lua 源里抠 `MDM.MapEnv` / `OVERRIDE` 那一段表。
 *  这两个文件都是"一行一条"的扁平表，用文本抠比引一个 Lua 解析器实在；
 *  解析不出条数会直接报错退出，绝不静默给 0 条。 */
function parseRows(file, marker) {
  if (!fs.existsSync(file)) throw new Error(`读不到 ${file}`);
  const src = fs.readFileSync(file, "utf8");
  const start = src.indexOf(marker);
  if (start < 0) throw new Error(`${path.basename(file)} 里找不到 ${marker}`);
  const body = src.slice(start);
  const rows = new Map();
  const re = /\[(\d+)\]\s*=\s*\{[^}]*?name\s*=\s*['"]([^'"]+)['"][^}]*?\}/g;
  let m;
  while ((m = re.exec(body))) {
    const seg = m[0];
    const num = (k) => {
      const mm = seg.match(new RegExp(k + "\\s*=\\s*(-?[0-9.]+)"));
      return mm ? Number(mm[1]) : null;
    };
    const h = num("h"), s = num("s"), l = num("l");
    if (h === null || s === null || l === null) {
      throw new Error(`${path.basename(file)}: mapID ${m[1]} 的 h/s/l 抠不全，正则口径要改`);
    }
    rows.set(Number(m[1]), { name: m[2], h, s, l });
  }
  if (!rows.size) throw new Error(`${path.basename(file)} 里一条 ${marker} 都没抠到`);
  return rows;
}

// ---------------------------------------------------------------------------
// 已记录清单（本仓文档里逐个号对过名的 mapID）
//   zone     = 类型标签（区域 / 首都 / 父层 / 新内容）
//   parent   = 假定父层；ASSUMED —— 真实 parentMapID 只有 --dump 能给
//   缺口出处：docs/HANDOFF.md 8.14.2 的表 + :2092（实机银月城 2393 落 fallback）
// ---------------------------------------------------------------------------
const KNOWN = [
  // 14 条实测区域行（生成文件本体）
  [1413, "贫瘠之地", "区域", 1414], [1417, "阿拉希高地", "区域", 1415],
  [1420, "提瑞斯法林地", "区域", 1415], [1421, "银松森林", "区域", 1415],
  [1424, "希尔斯布莱德丘陵", "区域", 1415], [1429, "艾尔文森林", "区域", 1415],
  [1436, "西部荒野", "区域", 1415], [1440, "灰谷", "区域", 1414],
  [1441, "千针石林(含闪光平原)", "区域", 1414], [1444, "菲拉斯", "区域", 1414],
  [1446, "塔纳利斯", "区域", 1414], [1454, "奥格瑞玛", "首都", 1414],
  [1458, "幽暗城", "首都", 1415], [2521, "泽风岛", "新内容", 947],
  // 缺口：四个新手区 + 四座联盟/部落首都 + 三个 1.60 新增区（HANDOFF 8.14.2）
  [1411, "杜隆塔尔", "新手区", 1414], [1412, "莫高雷", "新手区", 1414],
  [1438, "泰达希尔", "新手区", 1414], [1426, "丹莫罗", "新手区", 1415],
  [1453, "暴风城", "首都", 1415], [1455, "铁炉堡", "首都", 1415],
  [1457, "达纳苏斯", "首都", 1414], [1456, "雷霆崖", "首都", 1414],
  [2482, "海加尔山", "新内容", 1414], [2652, "辛德拉", "新内容", null],
  [2548, "河林", "新内容", null],
  // 2026-11-08 官方地图贴图色层新增的 8 区（只有这 17 区有贴图可取）。
  // 父层按经典大陆划分填 1414，ASSUMED；它们都有 override 直接命中，父层不参与判定。
  [1439, "黑海岸", "区域", 1414], [1442, "石爪山脉", "区域", 1414],
  [1443, "凄凉之地", "区域", 1414], [1445, "尘泥沼泽", "区域", 1414],
  [1447, "艾萨拉", "区域", 1414], [1448, "费伍德森林", "区域", 1414],
  [1449, "安戈洛环形山", "区域", 1414], [1450, "月光林地", "区域", 1414],
  // 实机已知的兜底受害者（HANDOFF:2092）；父层不在 1414/1415 里，属"还有别的父层没补"那一类
  [2393, "银月城(实机)", "首都", null],
  // 父层三行（override 派生）
  [1414, "卡利姆多", "父层", 947], [1415, "东部王国", "父层", 947], [947, "艾泽拉斯", "父层", 0],
];

function buildUniverse() {
  const dumpFile = val("--dump", null);
  if (!dumpFile) {
    return {
      source: "仓库已记录清单（docs/HANDOFF.md 8.14.1 / 8.14.2 / :2092）",
      partial: true,
      rows: KNOWN.map(([id, name, kind, parent]) => ({ id, name, kind, parent, assumed: true })),
    };
  }
  const raw = JSON.parse(fs.readFileSync(path.resolve(dumpFile), "utf8"));
  const list = Array.isArray(raw) ? raw : raw.rows;
  if (!Array.isArray(list)) throw new Error("--dump 文件要是一个数组（或 { rows: [...] }）");
  return {
    source: `实机地图树 ${dumpFile}`,
    partial: false,
    rows: list.map((r) => ({
      id: Number(r.mapID),
      name: String(r.name || `#${r.mapID}`),
      // 大陆层/世界层由导出方标 kind（"父层"）；没标就按"区域"记账，脚本不臆造类型
      kind: r.kind || "区域",
      parent: Number(r.parentMapID) || 0,
      assumed: false,
    })),
  };
}

/** 与 LibMonetColor:GetMapEnv 同一条解析序；返回 { tier, via, entry } */
function resolve(id, parentOf, override, data) {
  if (override.has(id)) return { tier: "有色", via: "override", entry: override.get(id) };
  if (data.has(id)) return { tier: "有色", via: "data", entry: data.get(id) };
  let cur = id;
  for (let depth = 1; depth <= 5; depth++) {  // 深度上限 5 = findParentEnv 的 for _ = 1, 5
    const p = parentOf(cur);
    if (!p || p === 0) break;
    if (override.has(p)) return { tier: "走父链", via: `parent:override(${p})`, entry: override.get(p) };
    if (data.has(p)) return { tier: "走父链", via: `parent:data(${p})`, entry: data.get(p) };
    cur = p;
  }
  return { tier: "落兜底", via: "fallback", entry: null };
}

const parentOverride = parseRows(OVERRIDE_FILE, "local OVERRIDE = {");
const atlas = parseRows(ATLAS_FILE, "local ATLAS_ENV = {");
const data = parseRows(DATA_FILE, "MDM.MapEnv = {");
// 引擎 overrideEnv 后写者赢：Libs.xml 里贴图层排在派生父层之后。
const override = new Map([...parentOverride, ...atlas]);

// 体检：派生父层 override 只该当祖先，抢占精确区 = 把提取值换成派生值（缺陷）。
// 贴图 override 顶掉同名实测行是 2026-11-08 色源优先级的**预期**结果，单列不算缺陷。
const shadow = [...parentOverride.keys()].filter((id) => data.has(id) || atlas.has(id));
const priorityOverride = [...atlas.keys()].filter((id) => data.has(id));
const badRange = [...override.entries(), ...data.entries()].filter(
  ([, e]) => !(e.h >= 0 && e.h <= 360 && e.s >= 0 && e.s <= 1 && e.l >= 0 && e.l <= 1)
);

const universe = buildUniverse();
const byId = new Map(universe.rows.map((r) => [r.id, r]));
const parentOf = (id) => (byId.get(id) ? byId.get(id).parent : undefined);

const tiers = { 有色: [], 走父链: [], 落兜底: [] };
for (const r of universe.rows) {
  const res = resolve(r.id, parentOf, override, data);
  tiers[res.tier].push({ ...r, ...res });
}

const total = universe.rows.length;
const pct = (n) => ((n / total) * 100).toFixed(1) + "%";

const out = [];
out.push("MonetColorMapData 覆盖率账（解析序同 LibMonetColor:580-611）");
out.push("");
out.push(`数据行  MapEnv(提取)      ${String(data.size).padStart(3)} 条   ${path.relative(ROOT, DATA_FILE)}`);
out.push(`数据行  override(派生父层) ${String(parentOverride.size).padStart(2)} 条   ${path.relative(ROOT, OVERRIDE_FILE)}`);
out.push(`数据行  override(贴图优先) ${String(atlas.size).padStart(2)} 条   ${path.relative(ROOT, ATLAS_FILE)}`);
out.push("色源优先级 官方地图贴图 > wuxianwow/trip > 游戏截图（守门：node tools/env-source-check.js）");
out.push(`统计口径 ${universe.source}${universe.partial ? "  [清单不完整，父层 ASSUMED]" : ""}`);
out.push("");
out.push("三档计数");
out.push(`  有色(直接命中)   ${String(tiers["有色"].length).padStart(3)}  ${pct(tiers["有色"].length).padStart(6)}   其中 override ${tiers["有色"].filter((x) => x.via === "override").length} / data ${tiers["有色"].filter((x) => x.via === "data").length}`);
out.push(`  走父链(继承祖先) ${String(tiers["走父链"].length).padStart(3)}  ${pct(tiers["走父链"].length)}`);
out.push(`  落兜底(无彩灰)   ${String(tiers["落兜底"].length).padStart(3)}  ${pct(tiers["落兜底"].length)}`);
out.push(`  合计             ${String(total).padStart(3)}`);
out.push("");
out.push("明细");
out.push("  mapID   档位      来源                     名称");
for (const t of ["有色", "走父链", "落兜底"]) {
  for (const r of tiers[t]) {
    // * 只标"这一档的判定用到 ASSUMED 父层"的行；直接命中（有色）和父链无关，标了是噪音
    const star = universe.partial && r.via !== "override" && r.via !== "data" ? "*" : "";
    out.push(
      `  ${String(r.id).padStart(6)}  ${t.padEnd(6)}   ${(r.via + star).padEnd(24)} ${r.name}${r.kind && r.kind !== "区域" ? `  [${r.kind}]` : ""}`
    );
  }
}
out.push("");
out.push("缺口清单（落兜底 = 玩家看到无彩灰的地方）");
if (!tiers["落兜底"].length) out.push("  （无）");
for (const r of tiers["落兜底"]) {
  out.push(`  ${String(r.id).padStart(6)}  ${r.name}  [${r.kind}]  父层${r.parent ? r.parent : "未记录"} —— 要么补它的父层行，要么给它自己的实测色`);
}
out.push("");
out.push("体检");
out.push(`  派生父层 override 抢占精确区：${shadow.length ? shadow.join(",") + "  <-- 缺陷" : "0 条"}`);
out.push(`  贴图 override 按优先级顶掉实测行：${priorityOverride.length} 条（预期，不算缺陷）`);
out.push(`  h/s/l 越界：${badRange.length ? badRange.map(([i]) => i).join(",") + "  <-- 缺陷" : "0 条"}`);
if (universe.partial) {
  out.push("");
  out.push("  带 * 的父层是 ASSUMED（离线没有 1.60 的 UiMap 表）。全量三档要实机导出地图树：");
  out.push("  C_Map.GetMapChildrenInfo(947, nil, true) 走一遍，每行 { mapID, name, parentMapID }");
  out.push("  写成 JSON 数组喂 --dump。（GetMapInfo / GetMapChildrenInfo 的名字与参数已按离线");
  out.push("  dump 核实，见本文件头部；返回值文档没标机密，但 name 进 format 前仍要过 Secrets.CanRead。）");
}

const text = out.join("\r\n");
if (has("--json")) {
  console.log(JSON.stringify({
    counts: { data: data.size, parentOverride: parentOverride.size, atlas: atlas.size, override: override.size, 有色: tiers["有色"].length, 走父链: tiers["走父链"].length, 落兜底: tiers["落兜底"].length, 合计: total },
    shadow, priorityOverride, badRange: badRange.map(([i]) => i),
    rows: universe.rows.map((r) => ({ ...r, ...resolve(r.id, parentOf, override, data) })),
  }, null, 2));
} else {
  console.log(text);
}
process.exit(shadow.length || badRange.length ? 1 : 0);
