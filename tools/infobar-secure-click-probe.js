/**
 * 信息栏「点一格开面板」越权闸门 —— `node tools/infobar-secure-click-probe.js`。
 *
 * 为什么存在：11-05 开服这一天，这一条路上连踩三次，每次都是**我们自己的账**：
 *   第 1 次（P0，日志 id 1441）：`M:OpenPanel("ToggleCharacter")` = 在我们的 Lua 里调暴雪
 *     FrameXML 全局 → 栈走到 `TextStatusBar.lua:110` 的机密值比较，按 MonetUI 名义执行。
 *   第 2 次（离线 66 条红）：把格子本体做成 `SecureActionButtonTemplate` → `Relayout` 每拍的
 *     `ClearAllPoints/SetPoint` 变成对安全框做受保护写入（`InfoBar.lua:287`，fl.pm）。
 *   第 3 次（实机几百条 BLOCKED）：改成"格子上盖一层安全接住器 + `SetAllPoints(frame)`" →
 *     **锚定家族把格子和整条 `MonetUIInfoBar` 一起标成受保护**（`IsProtected()` 实测 true），
 *     `SetPoint/ClearAllPoints/SetWidth/SetShown` 全被拒，每 10 秒上百条
 *     `ADDON_ACTION_BLOCKED MonetUI Button:…`，且 `当前受限：无 · InCombatLockdown()=false` 照样拒。
 *     这台机器的 `taint.log` 对 ADDON_ACTION_BLOCKED **零记录**，所以归因只能靠
 *     "无名 Button + 这一组写入形状"对上 InfoBar 的排版三件套。
 *
 * ⇒ 定下的规矩：**逐拍排版的框永远不能和 `SecureActionButtonTemplate` 建立锚定关系**。
 * 信息栏因此不提供"点一格开暴雪面板"（任务 #43 找别的载体）。
 *
 * 断言三组：
 *   A 越权边界 —— OpenPanel 这个函数不存在，两个文件里暴雪 Lua 全局零出现。
 *   B 不重试 —— InfoBar 全文不得再出现安全模板 / 安全接住器写法。
 *   C 出口只剩自己的 —— 五个格没有 secureClick，唯一的 onClick 开的是我们自己的属性面板。
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const BAR = fs.readFileSync(path.join(ROOT, 'Modules/InfoBar/InfoBar.lua'), 'utf8');
const BLOCKS = fs.readFileSync(path.join(ROOT, 'Modules/InfoBar/Blocks.lua'), 'utf8');

const strip = (src) => src.split(/\r?\n/).map((l) => l.replace(/--.*$/, "")).join("\n");
const BAR_CODE = strip(BAR);
const BLOCKS_CODE = strip(BLOCKS);

let pass = 0;
let fail = 0;
const ok = (cond, label) => {
  if (cond) { pass++; console.log('  [OK]   ' + label); }
  else { fail++; console.log('  [FAIL] ' + label); }
};

// ---------------------------------------------------------------- A 越权边界
ok(!/function M:OpenPanel/.test(BAR_CODE),
  'A1 `M:OpenPanel` 不存在 —— 按名字调暴雪 FrameXML 全局是通用入口，留着就会被用回去');
ok(!/OpenPanel/.test(BLOCKS_CODE),
  'A2 五个格的注册表里没有一处 OpenPanel');

const FORBIDDEN = [
  'ToggleCharacter', 'ToggleFriends', 'ToggleTalentFrame', 'ToggleQuestLog',
  'ToggleAllBags', 'ToggleWorldMap', 'ToggleCalendar', 'ToggleEncounterJournal',
  'ShowUIPanel', 'HideUIPanel', 'SetUIPanel', 'ToggleFrame', 'ToggleGameMenu',
];
const hit = FORBIDDEN.filter((n) =>
  new RegExp('\\b' + n + '\\b').test(BAR_CODE) || new RegExp('\\b' + n + '\\b').test(BLOCKS_CODE));
ok(hit.length === 0,
  'A3 两个文件里 13 个暴雪 Lua 全局一个都不出现（命中：' + (hit.length ? hit.join(', ') : '无') + '）');

// ---------------------------------------------------------------- B 不许在这里重试安全模板
ok(!/SecureActionButtonTemplate/.test(BAR_CODE),
  'B1 InfoBar 全文没有 SecureActionButtonTemplate —— 无论做成本体还是盖一层接住器，' +
  '排版框都会因锚定家族变成受保护（实测 IsProtected()=true，每 10 秒上百条 BLOCKED）');
ok(/local frame = CreateFrame\("Button", nil, bar, "BackdropTemplate"\)/.test(BAR_CODE),
  'B2 格子本体是普通 BackdropTemplate 按钮（`Relayout` 每拍在它身上写锚点，必须是我们的框）');
ok(!/SetAllPoints\(frame\)/.test(BAR_CODE),
  'B3 没有"接住器 SetAllPoints(格子)"这种写法残留');
ok(!/secureClick/.test(BAR_CODE),
  'B4 注册表里没有 secureClick 字段（有字段没实现 = 下一条改这里的人会以为还能转发）');

// ---------------------------------------------------------------- C 出口只剩我们自己的面板
const names = [...BLOCKS_CODE.matchAll(/secureClick\s*=\s*"([A-Za-z0-9_]+)"/g)].map((m) => m[1]);
ok(names.length === 0,
  `C1 五个格都没有转发目标（当前 ${names.length} 个：${names.join(', ') || '无'}）` +
  ' —— 本客户端的角色/天赋/好友/任务日志没有纯 C_* 开窗 API，宁可点了没反应');
const clicks = [...BLOCKS_CODE.matchAll(/onClick\s*=\s*function\([\s\S]{0,200}?end/g)].map((m) => m[0]);
ok(clicks.length === 1 && /ToggleStatsPanel\(\)/.test(clicks[0]),
  `C2 唯一的 onClick 开的是我们自己的属性面板（当前 ${clicks.length} 处 onClick）`);
ok(!/CharacterMicroButton|GuildMicroButton|TalentMicroButton|QuestLogMicroButton/.test(BAR_CODE),
  'C3 `/mui infobar diagnose` 的名单里不再列那四颗微按钮（没有代码取用它们 = 假账）');

console.log('');
console.log(`信息栏越权闸门：${pass} 通过 / ${fail} 失败`);
if (fail > 0) {
  console.log('判读：A 组失败 = id 1441 那条脏链回来（点一次数字一屏红）；' +
    'B 组失败 = 排版框被标成受保护（每 10 秒上百条 BLOCKED，与战斗无关）；' +
    'C 组失败 = 有字段没实现，或在没有任何合法载体的情况下试图开暴雪面板。');
}
process.exit(fail > 0 ? 1 : 0);
