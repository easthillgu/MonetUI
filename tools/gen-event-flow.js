#!/usr/bin/env node
/**
 * tools/gen-event-flow.js
 * 抽 MonetUI 的事件接线，产出两张 Graphviz DOT：
 *   docs/architecture/flow-event-map.dot   事件 ↔ 消费者 扇入图（谁和我抢同一个事件）
 *   docs/architecture/flow-main.dot        派发机制主路径 + 失败/降级支路
 *   docs/architecture/events.json          中间数据（逐事件、逐消费者、形态、出处）
 *
 *   node tools/gen-event-flow.js
 *
 * 七种接线形态，形态不同在图里线型也不同：
 *   bus        EventBus:Register("EVT", fn)                    —— 共享帧，一条引擎注册（Utils/EventBus.lua:75）
 *   bus-unit   EventBus:RegisterUnit("EVT", "unit", fn)       —— 带单位过滤（EventBus.lua:110）
 *   bus-loop   for _, e in ipairs(事件表) do Register(e)       —— 命名表与行内字面量表都展开
 *   wrap       M:OnEvent("EVT", fn)                            —— 模块自己的包装（Skins.lua:486）
 *   data       events = { "EVT", ... }                         —— 逐块数据驱动（InfoBar/Blocks.lua）
 *   own-frame  非总线的框自己 RegisterEvent / OnEvent          —— Nameplates 每块牌、ActionBars 探测器、Libs 的 eventFrame
 *   fire       EventBus:Fire("MONETUI_*")                      —— 内部事件生产者
 *
 * 落盘前拿 docs/api/EVENTS.md（本客户端事件快照）逐名对账：图上有没有"客户端不存在、
 * 懒注册会静默跳过"的死线（DEAD），以及带 `受限事件` 标记的注册（RESTRICTED）。只报不判死。
 *
 * flow-main 的机制节点不是猜的：每条都带 file:line，改实现时同步改这张表。
 */
const fs = require('fs');
const path = require('path');
const A = require('./arch-load');

const DIR = path.join(A.ROOT, 'docs/architecture');
const EVENT_RE = /^[A-Z][A-Z0-9_]{4,}$/;      // 全大写带下划线才算事件名
const lineOf = (src, index) => src.slice(0, index).split('\n').length;

/* ---------- 1. 抽取 ---------- */

function extract() {
  const files = A.loadOrder();
  const { registers, sources } = A.scanFiles(files);
  const subs = new Map();     // event -> Map(owner -> {kinds:Set, where:[], units:Set})
  const prods = new Map();    // event -> [{owner, where}]
  const stats = { tables: 0, loopExpansions: 0 };

  const addSub = (ev, owner, kind, where, unit) => {
    if (!EVENT_RE.test(ev)) return;
    if (!subs.has(ev)) subs.set(ev, new Map());
    const byOwner = subs.get(ev);
    if (!byOwner.has(owner)) byOwner.set(owner, { kinds: new Set(), where: [], units: new Set() });
    const s = byOwner.get(owner);
    s.kinds.add(kind);
    if (s.where.length < 4) s.where.push(where);
    if (unit) s.units.add(unit);
  };

  files.forEach((f, i) => {
    const src = sources.get(f);
    if (src === undefined) return;
    const owner = A.nodeId(f, registers);
    if (!owner) return;
    const order = i + 1;

    // 事件表：local NAME = { "UNIT_HEALTH", ... } 或 { UNIT_HEALTH = true, ... }
    const tables = new Map();
    for (const m of src.matchAll(/local\s+(\w+)\s*=\s*\{([^{}]*)\}/g)) {
      const names = [...m[2].matchAll(/"([A-Z][A-Z0-9_]+)"|^\s*([A-Z][A-Z0-9_]+)\s*=/gm)]
        .map(x => x[1] || x[2]).filter(Boolean);
      if (names.length && names.every(n => EVENT_RE.test(n))) {
        tables.set(m[1], { events: [...new Set(names)], line: lineOf(src, m.index) });
        stats.tables++;
      }
    }

    for (const m of src.matchAll(/EventBus:(Register|RegisterUnit)\(\s*"([^"]+)"(?:\s*,\s*"([^"]+)")?/g)) {
      addSub(m[2], owner, m[1] === 'RegisterUnit' ? 'bus-unit' : 'bus', f + ':' + lineOf(src, m.index), m[3]);
    }
    // 事件名的间接层：M:OnEvent("EVT", fn) 这类包装（Skins.lua:486）+ 逐块数据里的 events = { ... }（InfoBar）
    for (const m of src.matchAll(/[:.]OnEvent\(\s*"([^"]+)"/g)) {
      addSub(m[1], owner, 'wrap', f + ':' + lineOf(src, m.index));
    }
    for (const m of src.matchAll(/\bevents\s*=\s*\{([^{}]*)\}/g)) {
      const names = [...m[1].matchAll(/"([A-Z][A-Z0-9_]+)"/g)].map(x => x[1]);
      for (const ev of names) addSub(ev, owner, 'data', f + ':' + lineOf(src, m.index));
      stats.loopExpansions += names.length;
    }
    for (const m of src.matchAll(/(?:ipairs|pairs)\(\s*\{([^{}]*)\}\s*\)/g)) {
      // 行内匿名表：for _, e in ipairs({ "UI_SCALE_CHANGED", ... })（Media.lua:385）
      const names = [...m[1].matchAll(/"([A-Z][A-Z0-9_]+)"/g)].map(x => x[1]);
      for (const ev of names) addSub(ev, owner, 'bus-loop', f + ':' + lineOf(src, m.index));
      stats.loopExpansions += names.length;
    }
    for (const m of src.matchAll(/(?:ipairs|pairs)\(\s*(\w+)\s*\)/g)) {
      const t = tables.get(m[1]);
      if (!t) continue;
      const near = src.slice(m.index, m.index + 400);
      const ownFrame = /RegisterUnitEvent|RegisterEvent/.test(near);
      for (const ev of t.events) {
        addSub(ev, owner, ownFrame ? 'own-frame' : 'bus-loop', f + ':' + t.line, ownFrame ? 'per-object' : null);
      }
      stats.loopExpansions += t.events.length;
    }
    if (f !== 'Utils/EventBus.lua') {
      for (const m of src.matchAll(/\w+\s*:\s*(?:RegisterEvent|RegisterUnitEvent)\(\s*"([^"]+)"/g)) {
        addSub(m[1], owner, 'own-frame', f + ':' + lineOf(src, m.index));
      }
    }
    for (const m of src.matchAll(/EventBus:Fire\(\s*"([^"]+)"/g)) {
      if (!prods.has(m[1])) prods.set(m[1], []);
      prods.get(m[1]).push({ owner, where: f + ':' + lineOf(src, m.index) });
      addSub(m[1], owner, 'fire', f + ':' + lineOf(src, m.index));
    }
    if (f === 'Utils/EventBus.lua') {
      // 共享帧自己：懒注册，登记序 8
      addSub('__BUSFRAME__', owner, 'bus', 'Utils/EventBus.lua:36');
    }
    void order;
  });
  subs.delete('__BUSFRAME__');
  return { files, subs, prods, stats };
}

/* ---------- 2. 扇入图 ---------- */

const CATS = [
  ['internal', '内部事件（本插件自己派发）', /^MONETUI_/],
  ['zone', '区域 / 世界（触发重配色）', /^ZONE_|^PLAYER_ENTERING|^ADDON_LOADED|^UI_SCALE/],
  ['combat', '战斗与限制窗口', /^PLAYER_REGEN|^ENCOUNTER|^ADDON_RESTRICTION|^PLAYER_DEAD|^PLAYER_ALIVE|^PLAYER_UNGHOST|^PLAYER_UPDATE_RESTING/],
  ['unit', '单位事件（UNIT_* / 目标切换）', /^UNIT_|^PLAYER_TARGET|^GROUP_ROSTER|^RAID_|^PARTY_/],
  ['bar', '动作条 / 冷却 / 宠物 / 姿态', /^ACTIONBAR|^ACTION_|^SPELL_|^PET_|^SHAPESHIFT|^UPDATE_BINDINGS|^UPDATE_VEHICLE/],
  ['inv', '背包 / 物品 / 耐久', /^BAG_|^ITEM_|^CURRENCY|^LOOT|^MERCHANT|^UNIT_INVENTORY|^PLAYERBANKS|^UPDATE_PENDING_MAIL/],
];
const catOf = ev => { for (const c of CATS) if (c[2].test(ev)) return c[0]; return 'other'; };

const KIND_STYLE = {
  bus: ['Register（共享帧）', 'style=solid'],
  'bus-unit': ['RegisterUnit（单位过滤）', 'style=solid color="#1a5276"'],
  'bus-loop': ['事件表展开', 'style=solid color="#117a65"'],
  'own-frame': ['框自己注册（绕过总线）', 'style=dashed color="#b9770e"'],
  fire: ['Fire（生产者）', 'style=bold color="#8e44ad"'],
  wrap: ['OnEvent 包装（间接层）', 'style=dotted color="#943126"'],
  data: ['逐块数据 events 表', 'style=dotted color="#6c3483"'],
};

function eventMapDot(subs, prods) {
  const consumers = ev => [...subs.get(ev).keys()];
  const multi = [...subs.entries()].filter(e => consumers(e[0]).length >= 2);
  const singles = [...subs.entries()].filter(e => consumers(e[0]).length < 2);
  const L = [];
  const push = s => L.push(s);

  push('// MonetUI 事件扇入图 —— 由 tools/gen-event-flow.js 生成，勿手工编辑');
  push('// 只画 >=2 个消费者的事件（共 ' + multi.length + ' 个）；单消费者事件 ' + singles.length + ' 个折进右下角账本');
  push('digraph EventFlow {');
  push('  rankdir=TB; nodesep=0.22; ranksep=0.70;');
  push('  graph [fontname="Sans-Serif", fontsize=12, label="MonetUI 事件流：谁订阅同一个事件\\l", labelloc=t, concentration=true];');
  push('  node  [shape=box, style="rounded,filled", fontname="Sans-Serif", fontsize=10];');
  push('  edge  [fontname="Sans-Serif", fontsize=8];');

  // 消费者按层分簇（与 module-map 同一套 id，便于对照）
  const owners = new Set();
  for (const [, m] of multi) for (const o of m.keys()) owners.add(o);
  const tierOf = o => o.startsWith('mod:') ? 'mod' : o.startsWith('u:') ? 'util'
    : o.startsWith('lib:') ? 'lib' : o === 'cfg' ? 'cfg' : 'core';
  const TIERS = {
    lib: ['Libs（引擎自带 eventFrame，不经我们的总线）', '#f4f8fc', '#dce8f4'],
    util: ['Utils（驱动与皮肤层也订阅）', '#f1f7f1', '#dcecdc'],
    core: ['Core 引擎', '#fdf3e8', '#f0d9b8'],
    cfg: ['Config 面板', '#fdf3e8', '#f0d9b8'],
    mod: ['Modules', '#f8f1fa', '#efdcf3'],
  };
  for (const t of ['lib', 'util', 'core', 'cfg', 'mod']) {
    const list = [...owners].filter(o => tierOf(o) === t).sort();
    if (!list.length) continue;
    push('  subgraph cluster_' + t + ' { label="' + TIERS[t][0] + '"; style=filled; color="' + TIERS[t][1] + '"; fontsize=10;');
    for (const o of list) {
      const fan = [...subs.values()].filter(m => m.has(o)).length;
      push('    "' + o + '" [fillcolor="' + TIERS[t][2] + '", label="' + o.replace(/^(mod:|u:|lib:)/, '')
        + '\\n订阅 ' + fan + ' 个事件", tooltip="订阅 ' + fan + ' 个事件（含单消费者）"]');
    }
    push('  }');
  }

  const catBands = [];
  for (const cat of [...CATS.map(c => c[0]), 'other']) {
    const evs = multi.filter(e => catOf(e[0]) === cat).sort((a, b) => consumers(b[0]).length - consumers(a[0]).length);
    if (!evs.length) continue;
    catBands.push([evs[0][0], evs[evs.length - 1][0]]);
    const title = (CATS.find(c => c[0] === cat) || ['', '其它事件'])[1];
    push('  subgraph cluster_ev_' + cat + ' { label="' + title + '"; style=dashed; color="#aab7c4"; fontsize=10;');
    for (const [ev, byOwner] of evs) {
      const prod = (prods.get(ev) || [])[0];
      push('    "ev:' + ev + '" [shape=ellipse, fillcolor="#eaf2f8", label="' + ev + '\\n' + byOwner.size + ' 个消费者"'
        + (prod ? ', tooltip="生产者 ' + prod.where + '"' : '') + ']');
    }
    push('  }');
    for (const [ev, byOwner] of evs) {
      for (const entry of byOwner) {
        const o = entry[0], s = entry[1];
        for (const k of s.kinds) {
          if (k === 'fire') continue;                       // 生产边单独画
          const st = KIND_STYLE[k];
          const units = [...s.units].join(',');
          // 线型本身已经表达形态，170 条边再各写一遍标签会把图撑成糊团；
          // 标签只留给单位过滤，形态名放进 tooltip。
          push('  "ev:' + ev + '" -> "' + o + '" [' + st[1]
            + (units ? ' label="' + units + '"' : '')
            + ' tooltip="' + st[0] + (units ? ' · 单位 ' + units : '') + ' · ' + s.where.join(' | ') + '"]');
        }
      }
    }
  }
  // 分类簇之间拉一条隐形链：不连的话 dot 会把 7 个簇并排成一条 12000pt 宽的横带，
  // 连上之后它们被迫分层竖排，出图宽度降到可看的量级（SVG/PNG 都受益）。
  for (let i = 1; i < catBands.length; i++) {
    push('  "ev:' + catBands[i - 1][1] + '" -> "ev:' + catBands[i][0] + '" [style=invis]');
  }
  for (const entry of prods) {
    const ev = entry[0];
    if (!subs.has(ev) || consumers(ev).length < 2) continue;
    for (const p of entry[1]) {
      push('  "' + p.owner + '" -> "ev:' + ev + '" [style=bold color="#8e44ad" label="Fire" tooltip="' + p.where + '"]');
    }
  }

  const byOwnerSingle = new Map();
  for (const [ev, m] of singles) for (const o of m.keys()) {
    byOwnerSingle.set(o, (byOwnerSingle.get(o) || []).concat(ev));
  }
  const ledger = [...byOwnerSingle.entries()].sort((a, b) => b[1].length - a[1].length)
    .map(e => e[0].replace(/^(mod:|u:|lib:)/, '') + ' ' + e[1].length).join('\\n');
  const kindLegend = Object.keys(KIND_STYLE).filter(k => k !== 'fire')
    .map(k => k + ' = ' + KIND_STYLE[k][0]).join('\\n');
  push('  legend [shape=note, fillcolor="#fffde7", style=filled, fontsize=9, label="线型 = 接线形态（同一事件可有多种，边标签已省，形态在 tooltip 里）\\l'
    + kindLegend + '\\l椭圆 = 事件，只画 >=2 消费者的；单消费者事件不画成节点，折进下面这本账\\n\\n只有 1 个消费者的事件按节点计数：\\n'
    + ledger + '\\n\\n合计 去重事件 ' + subs.size + ' / 多消费者 ' + multi.length + ' / 单消费者 ' + singles.length + '"];');

  push('}');
  return { dot: L.join('\n') + '\n', multi: multi.length, singles: singles.length };
}

/* ---------- 3. 机制主路径图（每条都带已核对的 file:line） ---------- */

const MECH = [
  // [节点 id, 标签, 出处, 所属簇]
  ['src_client', '客户端引擎派发\n(WoW 事件)', 'n/a', 'source'],
  ['src_timer', 'OnUpdate 每拍\n(0.1s 阈值累计)', 'Utils/Widget.lua:201,292,355,1245,1489', 'source'],
  ['bus_frame', '总线共享帧\nCreateFrame("Frame") + OnEvent', 'Utils/EventBus.lua:36-39', 'entry'],
  ['plate_frame', '每块姓名板自己挂\nplate:SetScript("OnEvent")', 'Modules/Nameplates/Nameplates.lua:879,892', 'entry'],
  ['probe_frame', '距离探测器自己挂\nrangeProbe:RegisterEvent', 'Modules/ActionBars/ActionBars.lua:2070-2071', 'entry'],
  ['lib_frame', 'Libs 自带 eventFrame\n(zone/PEW 直接听)', 'Libs/LibMonetColor-1.0.lua:1065-1069; Anim:1031,1044', 'entry'],
  ['drivers', '三个轮询驱动\nHoverWatch / ShowWatch / PollWatch', 'Utils/Widget.lua:264,308,335', 'entry'],
  ['dispatch', 'EventBus:Dispatch\n先快照再派发', 'Utils/EventBus.lua:190-216', 'dispatch'],
  ['unit_filter', '单位过滤\nentry.unit == 载荷 unit', 'Utils/EventBus.lua:202-214', 'dispatch'],
  ['lazy_reg', '懒注册\nIsEventValid 先问客户端认不认', 'Utils/EventBus.lua:88-105', 'dispatch'],
  ['unit_conflict', '同事件已有普通回调\n→ 不设单位过滤，改由 Dispatch 比', 'Utils/EventBus.lua:132-142', 'dispatch'],
  ['guard_secret', '机密值守卫\nSecrets.CanRead / Bool / Number', 'Utils/Secrets.lua:80,121', 'guard'],
  ['guard_restrict', '限制窗口守卫\nns:IsRestricted（六类）/ InCombatLockdown', 'Core.lua:595；仓内 59 处', 'guard'],
  ['guard_visible', 'forbidden 守卫\nVisibilityOf → 暂停该框 5 秒', 'Utils/Widget.lua:125-154, PAUSE_RETRY=47', 'guard'],
  ['consumers', '17 个模块回调\n+ Utils(Skin/Widget) + Config', '见 flow-event-map.dot', 'consume'],
  ['after', '脱战/解限后重试\nns:AfterCombat + MONETUI_RESTRICTION_CHANGED', 'Core.lua:538,614,633', 'guard'],
  ['sink_own', '写自建框\n（我们的手，安全）', '各模块', 'sink'],
  ['sink_bliz', '写暴雪受保护框\nalpha / SetPoint / 属性片段', 'AGENTS.md 安全边界节', 'sink'],
  ['sink_db', '落盘 MonetUIDB\nSavedVariables', 'MonetUI.toc:9', 'sink'],
  ['f_invalid', '客户端不认这个事件名\n静默不注册（登录不报错）', 'Utils/EventBus.lua:94-103', 'fail'],
  ['f_throw', '回调抛错\nReport 只印第一次 + 计数', 'Utils/EventBus.lua:23-32,197', 'fail'],
  ['f_secret', '机密值\nBool 落回 default / Number 保留上次', 'Utils/Secrets.lua:121-134', 'fail'],
  ['f_block', 'ADDON_ACTION_BLOCKED\n写被拒（归因到 MonetUI）', 'Core.lua:633 记账', 'fail'],
  ['f_forbid', 'IsVisible 直接抛\n暂停 5 秒、期满自动复检', 'Utils/Widget.lua:125-154', 'fail'],
];
const MECH_EDGES = [
  ['src_client', 'bus_frame', 'async 引擎派发', 'style=bold'],
  ['src_client', 'plate_frame', 'async 每对象', 'style=dashed color="#b9770e"'],
  ['src_client', 'probe_frame', 'async 每对象', 'style=dashed color="#b9770e"'],
  ['src_client', 'lib_frame', 'async 库自用', 'style=dashed color="#b9770e"'],
  ['src_timer', 'drivers', 'in-process 每拍', 'style=bold'],
  ['bus_frame', 'dispatch', 'OnEvent → Dispatch', 'style=bold'],
  ['plate_frame', 'consumers', 'OnPlateEvent 直接进模块', 'style=dashed color="#b9770e"'],
  ['probe_frame', 'consumers', 'OnEvent 直接进模块', 'style=dashed color="#b9770e"'],
  ['lazy_reg', 'bus_frame', '首次订阅才注册', 'style=dotted'],
  ['unit_conflict', 'dispatch', '过滤降级', 'style=dotted'],
  ['dispatch', 'unit_filter', '快照后逐个 pcall', 'style=bold'],
  ['dispatch', 'consumers', 'in-process 回调（事件名做第一参数）', 'style=bold'],
  ['drivers', 'guard_visible', '每拍先问可读/可见', 'style=solid'],
  ['consumers', 'guard_secret', '读值之前', 'style=solid'],
  ['consumers', 'guard_restrict', '写之前', 'style=solid'],
  ['guard_restrict', 'after', '被限时挂起，换边重读', 'style=dotted'],
  ['consumers', 'sink_own', '写', 'style=solid'],
  ['consumers', 'sink_bliz', '写（受保护，会归因）', 'style=solid color="#c0392b"'],
  ['consumers', 'sink_db', '异步落盘（退后 1-2 分钟）', 'style=dotted'],
  ['lazy_reg', 'f_invalid', 'false → 不注册', 'style=dotted color="#7f8c8d"'],
  ['dispatch', 'f_throw', 'pcall 失败', 'style=dotted color="#c0392b"'],
  ['guard_secret', 'f_secret', '读不到 → 回退值', 'style=dotted color="#c0392b"'],
  ['guard_restrict', 'f_block', '生效期写入被拒', 'style=dotted color="#c0392b"'],
  ['guard_visible', 'f_forbid', '抛 → 暂停', 'style=dotted color="#c0392b"'],
];
const CLUSTERS = {
  source: ['触发源', '#f7f9fb'], entry: ['入口层（三条：总线 / 每对象框 / 轮询驱动）', '#eef6fb'],
  dispatch: ['派发层 Utils/EventBus.lua', '#eaf3ea'], guard: ['守卫层（读之前 / 写之前）', '#fbf3e6'],
  consume: ['消费层', '#f6eff8'], sink: ['落点', '#eef2f5'], fail: ['失败与降级支路（本项目的真实形态）', '#fbeeee'],
};

function mainDot() {
  const L = [];
  const push = s => L.push(s);
  // 标签里出现真实换行与双引号（CreateFrame("Frame")），必须转义成 DOT 的 \n 与 \"，否则引号被撑破
  const esc = s => String(s).replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/"/g, '\\"');
  push('// MonetUI 事件派发机制主路径 —— 由 tools/gen-event-flow.js 生成（节点/边写在脚本的 MECH 表里，每条带 file:line）');
  push('digraph FlowMain {');
  push('  rankdir=TB; nodesep=0.30; ranksep=0.65;');
  push('  graph [fontname="Sans-Serif", fontsize=12, label="MonetUI 事件流：触发 → 入口 → 派发 → 守卫 → 落点（含失败支路）\\l", labelloc=t];');
  push('  node  [shape=box, style="rounded,filled", fontname="Sans-Serif", fontsize=10];');
  push('  edge  [fontname="Sans-Serif", fontsize=8, color="#5d6d7e"];');
  const fill = { source: '#d6e4f0', entry: '#cfe3f0', dispatch: '#cfe6cf', guard: '#f2dcb8', consume: '#e6d2ee', sink: '#d5dde6', fail: '#f6d5d5' };
  for (const key of Object.keys(CLUSTERS)) {
    const items = MECH.filter(m => m[3] === key);
    if (!items.length) continue;
    push('  subgraph cluster_' + key + ' { label="' + CLUSTERS[key][0] + '"; style=filled; color="' + CLUSTERS[key][1] + '"; fontsize=11; margin=10;');
    for (const m of items) {
      push('    "' + m[0] + '" [fillcolor="' + fill[key] + '", label="' + esc(m[1]) + '", tooltip="' + esc(m[2]) + '"]');
    }
    push('  }');
  }
  for (const e of MECH_EDGES) push('  "' + e[0] + '" -> "' + e[1] + '" [' + e[3] + ' label="' + esc(e[2]) + '"]');
  push('  note [shape=note, fillcolor="#fffde7", style=filled, fontsize=9, label="读法：粗实线 = 主路径（一条共享帧 + 一次 Dispatch 扇出）\\l'
    + '橙虚线 = 绕过总线的每对象注册（全仓只有姓名板 + 距离探测器 + Libs 三处）\\l红点线 = 失败/降级，本项目的设计常态而非异常\\l'
    + '鼠标悬停任意节点看 file:line（tooltip）";]');
  push('  { rank=same; "sink_own"; "sink_bliz"; "sink_db"; }');
  push('}');
  return L.join('\n') + '\n';
}

/* ---------- 4. 事件名对账 ---------- */

/**
 * 拿本地 API 事件快照（docs/api/EVENTS.md，抓自本客户端）逐名核对图上的事件。
 * 图上有一条"某模块订阅某事件"的边，但客户端没有那个事件 = 死线：
 * EventBus 的懒注册会静默跳过（EventBus.lua:94-103），既不报错也没有任何一行回调执行。
 * 只报不判死（快照本身可能比代码旧），所以不动退出码。
 */
function checkEventNames(subs) {
  const file = path.join(A.ROOT, 'docs/api/EVENTS.md');
  if (!fs.existsSync(file)) {
    console.error('NOTE 没有 docs/api/EVENTS.md，跳过事件名对账（先 node tools/api-fetch.js）');
    return;
  }
  const known = new Set();
  const restricted = new Set();
  for (const line of A.readText(file).split('\n')) {
    const m = line.match(/^-\s+\*\*`([A-Z0-9_]+)`\*\*(.*)/);
    if (m) {
      known.add(m[1]);
      if (m[2].includes('受限事件')) restricted.add(m[1]);
    }
  }
  const names = [...subs.keys()].filter(n => !/^MONETUI_/.test(n));
  const missing = names.filter(n => !known.has(n));
  const risky = names.filter(n => restricted.has(n));
  console.error('事件名对账：快照 ' + known.size + ' 个 / 图上 ' + names.length +
    ' 个 / 快照没有=' + missing.length + ' / 标记受限=' + risky.length);
  for (const n of missing) {
    console.error('  DEAD ' + n + '  ← ' + [...subs.get(n).keys()].map(k => k.replace(/^(mod:|u:|lib:)/, '')).join(', '));
  }
  for (const n of risky) {
    console.error('  RESTRICTED ' + n + '  ← ' + [...subs.get(n).keys()].map(k => k.replace(/^(mod:|u:|lib:)/, '')).join(', '));
  }
}

/* ---------- 5. 跑 ---------- */

function run() {
  const { files, subs, prods, stats } = extract();
  fs.mkdirSync(DIR, { recursive: true });
  const ev = eventMapDot(subs, prods);
  const mechSrc = mainDot();

  // 先自查再落盘：词法（引号闭合）、悬空节点；机制图另查孤岛（孤岛=MECH 表里写了没人连的节点）
  A.lintDot(ev.dot.split('\n'), 'flow-event-map.dot');
  A.lintDot(mechSrc.split('\n'), 'flow-main.dot');
  const evIds = new Set([...ev.dot.matchAll(/^\s{4}"([^"]+)" \[/gm)].map(m => m[1]));
  A.selfCheck(ev.dot.split('\n'), evIds, {});
  A.selfCheck(mechSrc.split('\n'), new Set(MECH.map(m => m[0])), { isolated: true });

  fs.writeFileSync(path.join(DIR, 'flow-event-map.dot'), ev.dot, 'utf8');
  fs.writeFileSync(path.join(DIR, 'flow-main.dot'), mechSrc, 'utf8');
  fs.writeFileSync(path.join(DIR, 'events.json'), JSON.stringify({
    events: [...subs.entries()].map(e => ({
      ev: e[0],
      owners: [...e[1].entries()].map(x => ({ owner: x[0], kinds: [...x[1].kinds], where: x[1].where, units: [...x[1].units] })),
    })),
    producers: [...prods.entries()],
  }, null, 1), 'utf8');

  const consumers = ev2 => [...subs.get(ev2).keys()];
  const rank = [...subs.entries()].sort((a, b) => consumers(b[0]).length - consumers(a[0]).length);
  console.error('files=' + files.length + ' 事件表展开=' + stats.loopExpansions +
    ' 去重事件=' + subs.size + ' >=2 消费者=' + ev.multi + ' 单消费者=' + ev.singles + ' 内部事件=' + prods.size);
  console.error('\n扇入前 12:');
  for (const e of rank.slice(0, 12)) {
    console.error('  ' + e[0].padEnd(30) + e[1].size + '  ' + [...e[1].keys()].map(k => k.replace(/^(mod:|u:|lib:)/, '')).join(', '));
  }
  console.error('\n-> ' + path.join(DIR, 'flow-event-map.dot'));
  console.error('-> ' + path.join(DIR, 'flow-main.dot'));
  console.error('-> ' + path.join(DIR, 'events.json'));
  checkEventNames(subs);
}

run();
