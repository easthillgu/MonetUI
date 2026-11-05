/**
 * 信息栏「点一格开一个面板」的越权闸门 —— `node tools/infobar-secure-click-probe.js`。
 *
 * 为什么需要：11-05 开服实机第 2 条 P0（日志 id 1441 有完整栈）。金钱格 / 耐久格 / 专精格 /
 * 好友格 / 任务格的 `onClick` 走 `M:OpenPanel("ToggleCharacter", …)`，也就是**在我们的 Lua 里
 * 调用暴雪的 FrameXML 全局**。栈一路跑到
 * `CharacterFrame.lua:729 → TextStatusBar.lua:110` 的机密值比较，整段以 MonetUI 的名义执行
 * ⇒ 玩家点一下金钱数字就吃一条红 + 后续 8 条 `ADDON_ACTION_BLOCKED MonetUI UNKNOWN()`。
 * 与微菜单同型（AGENTS「绝不直调暴雪 Lua 全局」），修法同型：安全转发。
 *
 * **不能用 `run.js red=0` 当这条的证据**：harness 里没有信息栏点击阶段（`grep InfoBar tools/harness/run.lua`），
 * 这条探针 + 实机点一次才是证据。
 *
 * 断言三组：
 *   A 出口只有一个 —— OpenPanel 这个函数不存在，暴雪 Lua 全局一个都不调。
 *   B 安全转发在位 —— 模板 + 三件套 + 有目标时不再挂我们的 OnClick。
 *   C 实名账 —— 五个转发目标必须是 1.60 实测存在的微按钮名。
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

// ---------------------------------------------------------------- A 出口只有一个
ok(!/function M:OpenPanel/.test(BAR_CODE),
  'A1 `M:OpenPanel` 这个函数已经不存在（按名字调暴雪 FrameXML 全局 = 通用入口，留着就会被用回去）');
ok(!/OpenPanel/.test(BLOCKS_CODE),
  'A2 五个可点块里没有一处 OpenPanel 调用');

const FORBIDDEN = [
  'ToggleCharacter', 'ToggleFriends', 'ToggleTalentFrame', 'ToggleQuestLog',
  'ToggleAllBags', 'ToggleWorldMap', 'ToggleCalendar', 'ToggleEncounterJournal',
  'ShowUIPanel', 'HideUIPanel', 'ToggleFrame', 'ToggleGameMenu',
];
const hit = FORBIDDEN.filter((n) =>
  new RegExp('\\b' + n + '\\b').test(BAR_CODE) || new RegExp('\\b' + n + '\\b').test(BLOCKS_CODE));
ok(hit.length === 0,
  'A3 两个文件里一个暴雪 Lua 全局都没出现（命中：' + (hit.length ? hit.join(', ') : '无') + '）');

// ---------------------------------------------------------------- B 安全转发在位
ok(/local frame = CreateFrame\("Button", nil, bar, "BackdropTemplate"\)/.test(BAR_CODE) &&
   !/SecureActionButtonTemplate, BackdropTemplate/.test(BAR_CODE),
  'B0 格子本体是**普通**按钮 —— 第一版把格子本身做成安全框，harness 当场 66 条红：' +
  '`Relayout` 每拍的 ClearAllPoints/SetPoint 落在安全框上 = 受保护写入（restricted:Combat / Encounter 都撞）');
ok(/CreateFrame\("Button", nil, frame, "SecureActionButtonTemplate"\)/.test(BAR_CODE),
  'B1 转发由格子上那层安全接住器承担（造框那一刻一次）');
ok(/catcher:SetAllPoints\(frame\)/.test(BAR_CODE),
  'B1b 接住器一次 SetAllPoints 之后不再被排版碰：格子随便挪，安全框一个字节不写');
ok(/pcall\(catcher\.SetAttribute, catcher, "type", "click"\)/.test(BAR_CODE) &&
   /pcall\(catcher\.SetAttribute, catcher, "click", target\)/.test(BAR_CODE),
  'B2 type="click" + click=<那颗暴雪按钮> 都写在**我们自己造的**接住器上');
ok(/if not target and block\.onClick then/.test(BAR_CODE),
  'B3 有转发目标 ⇒ 不再挂我们的 OnClick（两个动作源不会同时生效）');
ok(/catcher:RegisterForClicks\("LeftButtonUp"\)/.test(BAR_CODE),
  'B4 转发只认左键抬起（和原来 onClick 的 LeftButton 语义一致）');
ok(/local target = SecureClickTarget\(block\)/.test(BAR_CODE),
  'B5 目标在造框之前一次取出（缺席就不转发，而不是"先挂 Lua 兜底"）');
ok(/hover:SetScript\("OnEnter"/.test(BAR_CODE) && /hover = catcher/.test(BAR_CODE),
  'B6 悬停挂在真正收到鼠标的那层（接住器压住格子，OnEnter 挂本体就永远不触发 = 没有提示框）');

// ---------------------------------------------------------------- C 实名账
const NAMES = [...BLOCKS_CODE.matchAll(/secureClick\s*=\s*"([A-Za-z0-9_]+)"/g)].map((m) => m[1]);
ok(NAMES.length === 5,
  `C1 五个可点格都声明了 secureClick（当前 ${NAMES.length} 个：${NAMES.join(', ') || '无'}）`);
// 1.60 实测（`/mui compat find MicroButton`，全客户端 17 个命中）里存在的那几颗：
const REAL = new Set([
  'CharacterMicroButton', 'ProfessionMicroButton', 'PlayerSpellsMicroButton',
  'AchievementMicroButton', 'QuestLogMicroButton', 'GuildMicroButton',
  'LFDMicroButton', 'CollectionsMicroButton', 'EJMicroButton',
  'StoreMicroButton', 'MainMenuMicroButton', 'HelpMicroButton',
  'HousingMicroButton', 'SpellbookMicroButton', 'TalentMicroButton', 'LegacyMicroButton',
]);
const bogus = NAMES.filter((n) => !REAL.has(n));
ok(bogus.length === 0,
  'C2 转发目标全在 1.60 实名集合里（不在：' + (bogus.length ? bogus.join(', ') : '无') + '）');
ok(/ns\.Skin and ns\.Skin:Need\(name\)/.test(BAR_CODE),
  'C3 目标查找过 `Skin:Need` 一个漏斗 ⇒ 缺席会是账本里的一行 ✗，不是静默');

console.log('');
console.log(`信息栏安全转发闸门：${pass} 通过 / ${fail} 失败`);
if (fail > 0) {
  console.log('判读：A 组任一失败 = id 1441 那条栈回来了（点一次数字 = 一屏红 + UNKNOWN() 拦截）；' +
    'B 组失败 = 格子点击落到我们自己的 Lua 里；C 组失败 = 台账里多一行消不掉的 ✗、那一格点了没反应。');
}
process.exit(fail > 0 ? 1 : 0);
