// tools/env-source-check.js
// 区域环境色「色源优先级」守门（只读脚本，不进发行包）。
//
// 2026-11-08 拍板的唯一口径：
//   1. 官方地图美术贴图（wuxianwow atlas webp）  -> MonetColorMapEnvAtlas.lua
//   2. 缺的走 wuxianwow/trip 艾泽拉斯旅拍截图     -> MonetColorMapData-1.0.lua, source=trip
//   3. 还缺的走自己的游戏截图（Gamepics）        -> MonetColorMapData-1.0.lua, source=game
//   4. 三条大陆/世界层 override 是派生色，只当父链祖先，不参与精确区竞争。
//
// 为什么要有它：优先级过去只是「碰巧成立」—— Atlas 走 override（引擎最高优先级），
// MapData 里 trip 与 game 平铺且不重号，所以数值恰好对。但没人守着：
// 换一次生成、调一次 Libs.xml 顺序、给某个 game 区补一条 trip，都可能静默把口径打回混合而无告警。
// 本脚本按优先级算出每区「应该生效的色」，再模拟 LibMonetColor:GetMapEnv 的解析序
// （override -> data -> parent -> fallback，见 LibMonetColor-1.0.lua:580-611）拿到「实际生效的色」，
// 逐区对账；任何漂移、缺标签、加载序错误都退出码 1。
//
// 数据源：monetcolors 仓的 data/game_palette_v1.json 是唯一带 source 标签的底账（只读）。
// 不在预期位置时用 --palette <path> 指过去；缺它就不许蒙，直接判失败。
//
// Usage:
//   node tools/env-source-check.js                    人读账本
//   node tools/env-source-check.js --json             机器可读（含每区 source）
//   node tools/env-source-check.js --palette <json>  指定底账

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const DIR = path.join(ROOT, "Libs", "MonetColorMapData-1.0");
const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
function flagVal(name, def) {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[i + 1] : def;
}

const ATLAS_FILE = path.join(DIR, "MonetColorMapEnvAtlas.lua");
const DATA_FILE = path.join(DIR, "MonetColorMapData-1.0.lua");
const PARENT_FILE = path.join(DIR, "MonetColorMapEnvOverride.lua");
const LIBS_XML = path.join(ROOT, "Libs", "Libs.xml");
const PALETTE = flagVal(
  "--palette",
  "C:/Users/EastHillGu/Documents/wowaddonsdev/monetcolors/data/game_palette_v1.json"
);

const errors = [];
const fail = (msg) => errors.push(msg);

/** 抠一行一条的扁平 Lua 表；解析不出任何一条就抛错，绝不静默给空表。 */
function parseRows(file, marker) {
  if (!fs.existsSync(file)) throw new Error(`读不到 ${file}`);
  const src = fs.readFileSync(file, "utf8");
  const start = src.indexOf(marker);
  if (start < 0) throw new Error(`${path.basename(file)} 里找不到 ${marker}`);
  const rows = new Map();
  const re = /\[(\d+)\]\s*=\s*\{[^}]*?name\s*=\s*['"]([^'"]+)['"][^}]*?\}/g;
  let m;
  while ((m = re.exec(src.slice(start)))) {
    const seg = m[0];
    const num = (k) => {
      const mm = seg.match(new RegExp(k + "\\s*=\\s*(-?[0-9.]+)"));
      return mm ? Number(mm[1]) : null;
    };
    const h = num("h"), s = num("s"), l = num("l");
    if (h === null || s === null || l === null) {
      throw new Error(`${path.basename(file)}: mapID ${m[1]} 的 h/s/l 抠不全`);
    }
    rows.set(Number(m[1]), { name: m[2], h, s, l });
  }
  if (!rows.size) throw new Error(`${path.basename(file)} 里一条表项都没抠到`);
  return rows;
}

const same = (a, b) =>
  Math.abs(a.h - b.h) < 1e-6 && Math.abs(a.s - b.s) < 1e-6 && Math.abs(a.l - b.l) < 1e-6;

// --- 读四份输入 -------------------------------------------------------------
const atlas = parseRows(ATLAS_FILE, "local ATLAS_ENV = {");
const data = parseRows(DATA_FILE, "MDM.MapEnv = {");
const parent = parseRows(PARENT_FILE, "local OVERRIDE = {");
const xml = fs.readFileSync(LIBS_XML, "utf8");

// 加载序：Override(父层) -> Atlas(贴图) -> Anim。Atlas 必须在 Override 之后，
// 否则父层 override 会按 mapID 覆盖回去（引擎 overrideEnv 是后写者赢）。
// 只认 <Script file=...> 真实加载行；注释里也会提到这些名字，用全文 indexOf 会误判。
const scriptOrder = [...xml.matchAll(/<Script\s+file="([^"]+)"/g)].map((m) => m[1]);
const at = (frag) => scriptOrder.findIndex((f) => f.includes(frag));
const iParent = at("MonetColorMapEnvOverride.lua");
const iAtlas = at("MonetColorMapEnvAtlas.lua");
const iAnim = at("LibMonetColor-Anim-1.0");
if (iAtlas < 0) fail("Libs/Libs.xml 没有注册 MonetColorMapEnvAtlas.lua —— 贴图色整层不会加载");
else if (!(iParent >= 0 && iParent < iAtlas && iAtlas < iAnim)) {
  fail("Libs/Libs.xml 加载序错误：必须 Override(父层) -> Atlas(贴图) -> Anim");
}
if (!/LMC:RegisterMapEnv/.test(fs.readFileSync(ATLAS_FILE, "utf8"))) {
  fail("Atlas 文件里没有 LMC:RegisterMapEnv 调用 —— 数据不会进 overrideEnv");
}

// 父层派生行只当祖先，不许占据任何精确区（不管那个区是贴图色还是提取色）。
for (const id of parent.keys()) {
  if (atlas.has(id) || data.has(id)) fail(`派生父层 override 抢占了精确区 ${id}`);
}

// --- 底账：按 mapID 分组，trip 优先于 game -----------------------------------
let zones = [];
if (!fs.existsSync(PALETTE)) {
  fail(`取不到色源底账 ${PALETTE}（用 --palette 指定 game_palette_v1.json）`);
} else {
  zones = JSON.parse(fs.readFileSync(PALETTE, "utf8"));
  if (!Array.isArray(zones)) fail("色源底账应当是 JSON 数组");
}
const byID = new Map();
for (const z of zones || []) {
  if (!z || !z.mapID) continue;
  if (!["trip", "game"].includes(z.source)) {
    fail(`底账 mapID ${z.mapID} 的 source=${String(z.source)} 不是 trip/game`);
    continue;
  }
  if (!z.env || [z.env.h, z.env.s, z.env.l].some((v) => typeof v !== "number")) {
    fail(`底账 mapID ${z.mapID} 缺 env.h/s/l`);
    continue;
  }
  if (!byID.has(z.mapID)) byID.set(z.mapID, []);
  byID.get(z.mapID).push(z);
}
const pick = (list) => list.find((z) => z.source === "trip") || list.find((z) => z.source === "game");

// --- 对账：期望色（按优先级） vs 实际色（按引擎解析序） -----------------------
// 引擎实际：override = 父层 ∪ 贴图（Libs.xml 里贴图后加载，同 mapID 后写者赢），然后 data。
const override = new Map([...parent, ...atlas]);
const actual = (id) => {
  if (override.has(id)) {
    return { ...override.get(id), via: atlas.has(id) ? "override:atlas" : "override:parent" };
  }
  if (data.has(id)) return { ...data.get(id), via: "data" };
  return null;
};

const rows = [];
for (const id of [...new Set([...atlas.keys(), ...byID.keys(), ...data.keys()])].sort((a, b) => a - b)) {
  const zonesForID = byID.get(id);
  let expect = null;
  let source = "unknown";

  if (atlas.has(id)) {
    expect = atlas.get(id);
    source = "atlas";
  } else if (zonesForID) {
    const z = pick(zonesForID);
    source = z.source;
    const row = data.get(id);
    if (!row) {
      fail(`mapID ${id}: 底账有 ${source} 数据，但 MapData 缺行`);
      continue;
    }
    if (!same(row, z.env)) {
      fail(`mapID ${id}: MapData 与底账 ${source} 提取值不一致（生成链漂移或选错来源）`);
    }
    // 同区同时有 trip/game 两条时，用了 game 的值就会在上面这行被抓到。
    expect = row;
  } else {
    fail(`mapID ${id}: MapData 有行但底账没有 source 标签`);
    continue;
  }

  const got = actual(id);
  if (!got) {
    fail(`mapID ${id}: 引擎解析不到任何色（应来自 ${source}）`);
    continue;
  }
  if (!same(got, expect)) {
    fail(`mapID ${id}: 生效色不是最高优先级色源（期望 ${source}，实际 ${got.via}）`);
  }
  rows.push({ mapID: id, name: got.name, source, via: got.via, h: got.h, s: got.s, l: got.l });
}

const count = (s) => rows.filter((r) => r.source === s).length;
const shadowed = [...atlas.keys()].filter((id) => data.has(id));
const counts = {
  atlas: count("atlas"),
  trip: count("trip"),
  game: count("game"),
  total: rows.length,
  parentOverride: parent.size,
  priorityOverride: shadowed.length,
};

if (has("--json")) {
  console.log(JSON.stringify({ ok: errors.length === 0, counts, shadowed, errors, rows }, null, 2));
} else {
  const out = [];
  out.push("色源优先级守门  atlas(官方地图贴图) > trip(wuxianwow) > game(游戏截图)");
  out.push(`  贴图色   ${String(counts.atlas).padStart(2)} 区   override:atlas   ${path.relative(ROOT, ATLAS_FILE)}`);
  out.push(`  trip     ${String(counts.trip).padStart(2)} 区   data(source=trip)`);
  out.push(`  game     ${String(counts.game).padStart(2)} 区   data(source=game)`);
  out.push(`  父层派生 ${String(counts.parentOverride).padStart(2)} 区   override:parent（仅父链兜底，不占精确区）`);
  out.push(`  精确区合计 ${counts.total}`);
  out.push(`  按优先级顶掉 data 实测行 ${counts.priorityOverride} 区：${shadowed.join(",") || "无"}（预期，不算缺陷）`);
  out.push("");
  if (errors.length) {
    out.push(`FAIL  ${errors.length} 项`);
    for (const e of errors) out.push("  - " + e);
  } else {
    out.push("PASS  每区生效色 = 该区最高可用优先级色源；加载序、source 标签、生成值全部对齐");
  }
  console.log(out.join("\r\n"));
}
process.exit(errors.length ? 1 : 0);
