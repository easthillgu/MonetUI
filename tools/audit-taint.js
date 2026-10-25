#!/usr/bin/env node
/**
 * audit-taint.js — commit 前 taint 机械闸门（.opencode/skills/wow-secret-value-taint-audit 的执行器）
 *
 * 启发式扫描本仓 Lua，找秘密值(taint)/污染家族的高危模式：
 *   BLOCKER  几乎必报错/污染，必须清零后才能 commit
 *   HIGH     碰生产者/暴雪对象家族，需要人工判定（TAINT-OK 豁免走文档）
 *   SOFT     单位/接口提醒
 *
 * 豁免：行内注释含 `-- TAINT-OK`（建议带原因）全规则跳过。
 * 用法：node tools/audit-taint.js [--json] [--strict] [paths...]
 *  paths  默认扫根目录 + Modules/ 下所有 .lua（排除 .git）
 *  --strict HIGH 也计入退出码
 * 退出码：有 BLOCKER → 1；--strict 且有 HIGH → 1；否则 0。
 */
'use strict';

const fs = require('fs');
const path = require('path');

// ---------- 规则表 ----------

const BLIZZ = [
  'TargetFrameToT', 'TargetFrame', 'PlayerFrame', 'FocusFrame', 'BossFrames',
  'PetActionBar', 'MainActionBar', 'MultiBar', 'MinimapCluster', 'MiniMap',
  'SpellBookFrame', 'BuffBar', 'NamePlateDriverFrame', 'CompactRaid',
  'CompactParty', 'EditModeManagerFrame', 'AuraFrame', 'DebuffListFrame',
];

// 秘值词汇（and/or 真值链的"中间操作数"判定用）：这条链的真值测试落点
const SECRET_VOCAB = /(?:result\[\d+\]|UnitHealthMax?|UnitPower\b|UnitAura|C_UnitAuras\.|GetSpellCooldown|GetSpellCharges|GetActionCooldown|expiration\b|duration\b)/;

const RULES = [
  {
    id: 'OLD-COOLDOWN',
    sev: 'BLOCKER',
    desc: '旧冷却接口 SetCooldown(start,duration)/SetCooldownFromExpirationTime —— 受限环境秘值必报，改 SetCooldownFromDurationObject + GetActionCooldownDuration',
    re: /[:.\s]SetCooldown\s*\(|[:.\s]SetCooldown\s*,|SetCooldownFromExpirationTime\s*\(/,
  },
  {
    id: 'REGISTER-ACTION-UI',
    sev: 'BLOCKER',
    desc: 'C_ActionBar.RegisterActionUIButton —— 引擎回写引擎冷却框传机密值，受限时 SetCooldown 必报；本链不用',
    re: /RegisterActionUIButton\s*\(/,
  },
  {
    id: 'RAW-FIELD-WRITE',
    sev: 'HIGH',
    desc: '往对象写字段（污染按键记忆）—— 先确认对象是不是暴雪帧；一律 ns:Mark(obj,key,value) 旁表（自己的表/累加器也建议走）',
    re: /\.__\w+\s*=/,
  },
  {
    id: 'CREATE-IN-INIT',
    sev: 'BLOCKER',
    desc: 'initializeFrame 回调体内未包 pcall 的 Create* —— 受限窗生产必拒，抛出穿出 securecall 炸整批(bitmap: 案 3453b10)',
    re: null, // 特处理（窗口扫描）
  },
  {
    id: 'SECRET-ANDOR',
    sev: 'BLOCKER',
    desc: 'and/or 真值链掠过可能秘值 —— a and b or c 会在 a 真时真值测试 b，秘值必抛；改显式 if（案 96c7482）',
    re: /\w+(?:\.\w+|\[\d+\])?\s+and\s+/,
    extra: (line) =>
      !/issecretvalue|C_Secrets/.test(line) &&
      SECRET_VOCAB.test(line.slice(line.indexOf(' and ') + 5)), // 只认"and 与 or 之间"是否战斗数据
  },
  {
    id: 'SECRET-ARITH',
    sev: 'BLOCKER',
    desc: '战斗数据同一行参与算术/比较且无 issecretvalue/C_Secrets 守卫 —— 条件性秘值在战斗必抛',
    re: /(UnitHealth\w*|UnitPower\w*|UnitRangedDamage|UnitAura\w*|GetSpellCooldown|GetSpellCharges|GetActionCooldown)\s*\(/,
    extra: (line) =>
      !/issecretvalue|C_Secrets|safe/.test(line) &&
      /(hp|max|health|power|duration|expiration|cooldown|percent|frac)\s*[\+\-\*\/]=?|\.\d*\s*[><=]/i.test(line),
  },
  {
    id: 'SETPARENT-BLIZZ',
    sev: 'HIGH',
    desc: 'SetParent 暴雪框 —— 换父被记脏，暴雪自己的布局被拒连锁；正文规则:全走常隐框体，借用必须 pcall(案件存档见 skill 案 A)',
    re: null, // 特处理（需要结合 BLIZZ 名单 + pcall 判级）
  },
  {
    id: 'HOOK-PROTECTED',
    sev: 'HIGH',
    desc: 'hooksecurefunc/HookScript 挂暴雪框或方法 —— 按 HookScript 写槽位被记脏（美化走轮询/M:HookShow）',
    re: /hooksecurefunc\s*\(|[:.]HookScript\s*\(/,
    extra: (line) => !/M:HookShow|TAINT/.test(line),
  },
  {
    id: 'SETSCALE-BLIZZ',
    sev: 'HIGH',
    desc: 'SetScale 写在暴雪框上 —— 编辑模式会算出 SetScale(0) 直接报错（案 MinimapCluster）',
    re: /[:.]SetScale\s*\(/,
    extra: (line) => BLIZZ.some((n) => line.includes(n)),
  },
  {
    id: 'HIDE-BLIZZ',
    sev: 'HIGH',
    desc: 'Hide() 收暴雪 HUD —— 拉锯闪烁，正解 SetAlpha(0)+EnableMouse(false)（不触发它的 Show 逻辑）',
    re: /[:.]Hide\s*\(\s*\)/,
    extra: (line) => BLIZZ.some((n) => new RegExp('(?<!MonetUI)\\b' + n + '\\b').test(line)),
  },
  {
    id: 'SETSHOWN-SECURE',
    sev: 'HIGH',
    desc: 'SetShown/Show/Hide 直控 secure 按钮 —— 用 visibility state driver（战斗中必拒）',
    re: null, // 特处理（需要结合按钮名单）
  },
  {
    id: 'COMBAT-LOG',
    sev: 'HIGH',
    desc: 'COMBAT_LOG_EVENT_UNFILTERED —— 本客户端受限事件；run/try 不许注册，做实时战斗判断不建议',
    re: /COMBAT_LOG_EVENT_UNFILTERED/,
  },
  {
    id: 'IS-ANCHORING',
    sev: 'SOFT',
    desc: 'IsAnchoringSecret —— 本客户端不存在（实机证否），锚点守卫用 issecretvalue + C_Secrets 谓词',
    re: /IsAnchoringSecret/,
  },
  {
    id: 'CD-TIMES-MS',
    sev: 'SOFT',
    desc: 'GetCooldownTimes —— 返回毫秒，GetTime() 是秒；混算把 6 分钟画成 568d（别忘了 >30 天兜底）',
    re: /GetCooldownTimes\s*\(/,
  },
];

// ---------- 扫描 ----------

function walkLua(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === '.git' || e.name === 'Assets' || e.name === 'node_modules' || e.name === 'tools') continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walkLua(p, out);
    else if (e.isFile() && e.name.endsWith('.lua')) out.push(p);
  }
  return out;
}

function scanFile(file, findings) {
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  const ctx = { file, lines, findings };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.trimLeft().startsWith('--')) continue; // 注释/documentation 行不扫
    if (line.includes('-- TAINT-OK')) continue;
    for (const r of RULES) {
      if (r.re && r.re.test(line) && (!r.extra || r.extra(line))) {
        add(findings, r.sev, r.id, file, i + 1, r.desc, line.trim());
      }
    }
  }
  scanInitializeFrame(ctx);  // CREATE-IN-INIT 窗口
  scanSetParent(ctx);        // SETPARENT-BLIZZ 分级
  scanSetShown(ctx);         // SETSHOWN-SECURE
}

function add(findings, sev, id, file, lineNo, desc, snippet) {
  findings.push({
    sev, id, file: file.replace(/\\/g, '/'), line: lineNo, desc,
    snippet: snippet.length > 120 ? snippet.slice(0, 117) + '...' : snippet,
  });
}

// CREATE-IN-INIT：initializeFrame = function(body) ... end[,)] 窗口内裸 Create*
function scanInitializeFrame({ file, lines, findings }) {
  for (let i = 0; i < lines.length; i++) {
    if (!/initializeFrame\s*=\s*function/.test(lines[i])) continue;
    if (lines[i].includes('-- TAINT-OK')) { i += 1; continue; }
    for (let j = i; j < Math.min(i + 20, lines.length); j++) {
      const s = lines[j];
      if (j > i && /^\s*end[,)]?\s*$/.test(s)) break;
      if (s.includes('-- TAINT-OK')) continue;
      if (/:Create\w+\s*\(|\bCreateFrame\s*\(|CreateFontString\s*\(/.test(s) && !/pcall/.test(s)) {
        add(findings, 'BLOCKER', 'CREATE-IN-INIT', file, j + 1,
          'initializeFrame 回调体内裸 Create*（受限窗整批必死）', s.trim());
      }
    }
  }
}

// SETPARENT-BLIZZ：裸写 → BLOCKER；pcall 包裹（借用模式）→ SOFT
function scanSetParent({ file, lines, findings }) {
  for (let i = 0; i < lines.length; i++) {
    const s = lines[i];
    if (s.includes('-- TAINT-OK') || !/SetParent\s*\(/.test(s)) continue;
    if (!BLIZZ.some((n) => s.includes(n))) continue;
    const sev = /pcall/.test(s) ? 'SOFT' : 'BLOCKER';
    add(findings, sev, 'SETPARENT-BLIZZ', file, i + 1,
      sev === 'BLOCKER' ? '裸 SetParent 暴雪框' : 'pcall 包装的借用 SetParent（确认进 TAINT-OK 文档）', s.trim());
  }
}

// SETSHOWN-SECURE：ActionButton/PetActionButton 等 secure 按钮显隐直控
function scanSetShown({ file, lines, findings }) {
  for (let i = 0; i < lines.length; i++) {
    const s = lines[i];
    if (s.includes('-- TAINT-OK')) continue;
    if (!/[:.]SetShown\s*\(|[:.](Show|Hide)\s*\(\s*\)/.test(s)) continue;
    if (!/(Pet)?ActionButton\d|SecureActionButton|UnitButton/.test(s)) continue;
    if (/state driver|SetAttributeNoHandler/.test(s)) continue;
    add(findings, 'HIGH', 'SETSHOWN-SECURE', file, i + 1,
      'secure 按钮显隐直控（战斗必拒，走 visibility state driver）', s.trim());
  }
}

// ---------- 主 ----------
const argv = process.argv.slice(2);
const asJson = argv.includes('--json');
const strict = argv.includes('--strict');
const paths = argv.filter((a) => !a.startsWith('--'));
const roots = paths.length ? paths : ['.'];
let files = [];
for (const r of roots) {
  const st = fs.statSync(r);
  if (st.isDirectory()) walkLua(r, files); else files.push(r);
}

const findings = [];
for (const f of files) scanFile(f, findings);
const order = { BLOCKER: 0, HIGH: 1, SOFT: 2 };
findings.sort((a, b) => order[a.sev] - order[b.sev] || a.file.localeCompare(b.file) || a.line - b.line);

const bySev = { BLOCKER: [], HIGH: [], SOFT: [] };
for (const f of findings) bySev[f.sev].push(f);

if (asJson) {
  console.log(JSON.stringify({ files: files.length, blockers: bySev.BLOCKER.length, highs: bySev.HIGH.length, softs: bySev.SOFT.length, findings }, null, 2));
} else {
  for (const [sev, label] of [['BLOCKER', '⛔ BLOCKER'], ['HIGH', '⚠️  HIGH'], ['SOFT', 'ℹ️  SOFT']]) {
    if (!bySev[sev].length) continue;
    console.log(`\n== ${label} (${bySev[sev].length}) ==`);
    for (const f of bySev[sev]) {
      console.log(`${f.file}:${f.line}  [${f.id}]`);
      console.log(`    ${f.desc}`);
      console.log(`    > ${f.snippet}`);
    }
  }
  console.log(`\nscanned ${files.length} lua files: ${bySev.BLOCKER.length} BLOCKER / ${bySev.HIGH.length} HIGH / ${bySev.SOFT.length} SOFT`);
  if (bySev.BLOCKER.length) console.log('→ 清零 BLOCKER 再 commit（豁免见行内 -- TAINT-OK 与 skill 案例档）');
}

process.exitCode = bySev.BLOCKER.length || (strict && bySev.HIGH.length) ? 1 : 0;
