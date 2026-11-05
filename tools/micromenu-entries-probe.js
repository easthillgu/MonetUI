/**
 * 微菜单入口闸门 —— `node tools/micromenu-entries-probe.js`。
 *
 * 为什么需要：`Modules/Minimap/MicroMenu.lua` 是 11-05 开服 P0 的现场
 * （`GetScript("OnClick")` 把暴雪的 Lua 拉进我们的执行环境跑 → `TextStatusBar.lua:110`
 * 机密值比较记到 MonetUI 名下，每个点角色/背包的玩家都会看到一条红）。
 * harness 里没有微菜单阶段（`grep MicroMenu tools/harness/run.lua` = 0 命中），
 * 所以"harness 红 0"**不是**这条路径的证据；这条探针钉的是同一类缺陷会不会自己回来。
 *
 * 断言三组：
 *   A 越权边界 —— 安全转发三件套在位，暴雪 Lua 全局一个都不许调（注释里提可以）。
 *   B 实名账 —— 1.60 实测不存在的那六颗按钮名不许回到代码里（死名 = 台账上消不掉的 ✗）。
 *   C 建行纪律 —— 没有可转发目标又没有纯 C_* 动作的行，一个都不建。
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SRC = fs.readFileSync(path.join(ROOT, 'Modules/Minimap/MicroMenu.lua'), 'utf8');

// 去掉整行注释与行尾注释，只留真代码（"调没调暴雪全局"必须按代码算，不能按提没提这个词算）。
const CODE = SRC.split(/\r?\n/).map((l) => l.replace(/--.*$/, "")).join("\n");

// ENTRIES 块 = 从 `local ENTRIES = {` 到第一个单独成行的 `}`。
const ENTRIES = (CODE.match(/local ENTRIES = \{[\s\S]*?\n\}/) || [''])[0];

let pass = 0;
let fail = 0;
const ok = (cond, label) => {
  if (cond) { pass++; console.log('  [OK]   ' + label); }
  else { fail++; console.log('  [FAIL] ' + label); }
};

// ---------------------------------------------------------------- A 越权边界
ok(!/GetScript/.test(CODE),
  'A1 全文不出现 GetScript —— 把暴雪脚本抠出来自己调用 = P0 判例（11-05 `TextStatusBar.lua:110`）');
ok(/CreateFrame\("Button", nil, frame, "SecureActionButtonTemplate"\)/.test(CODE),
  'A2 有转发目标的行是安全按钮模板（客户端在受限环境里代点）');
ok(/SetAttribute, row, "type", "click"/.test(CODE) && /SetAttribute, row, "click", target/.test(CODE),
  'A3 type="click" + click=<那颗暴雪按钮> 两个属性都写在我们自己造的按钮上');
ok(/return \(type\(entry\.luaAction\) == "function"\) and entry\.luaAction or nil/.test(CODE),
  'A4 备用动作只认 luaAction（纯 C_* API）；老 `action` 字段不再是路径');
ok(!/^\s*action\s*=/m.test(ENTRIES),
  'A5 ENTRIES 块里没有 `action =` 字段：留着就是"看着有兜底、其实一行不跑"，还会引回污染路');

const FORBIDDEN = [
  'ToggleGameMenu', 'ToggleAllBags', 'ToggleWorldMap', 'ToggleFriendsFrame',
  'ToggleQuestLog', 'ToggleQuestFrame', 'ToggleAchievementFrame', 'ToggleCalendar',
  'ToggleCollectionsJournal', 'ToggleEncounterJournal', 'ToggleSpellBook',
  'PlayerSpellsUtil', 'ShowUIPanel', 'HideUIPanel', 'ToggleFrame',
];
const hit = FORBIDDEN.filter((n) => new RegExp('\\b' + n + '\\b').test(CODE));
ok(hit.length === 0,
  'A6 代码里一个暴雪 Lua 全局都没被调用（命中：' + (hit.length ? hit.join(', ') : '无') + '）');

// ---------------------------------------------------------------- B 实名账
const DEAD = [
  'BagMicroButton', 'MapMicroButton', 'CalendarMicroButton',
  'GJMicroButton', 'SocialsMicroButton', 'PVPMicroButton',
];
const deadHit = DEAD.filter((n) => CODE.includes(n));
ok(deadHit.length === 0,
  'B1 1.60 实测不存在的六颗名字不在源码里（命中：' + (deadHit.length ? deadHit.join(', ') : '无') +
  '）—— 实名账：`/mui compat find MicroButton` 全客户端 17 个命中');
const NAMED = [
  'CharacterMicroButton', 'PlayerSpellsMicroButton', 'QuestLogMicroButton',
  'AchievementMicroButton', 'GuildMicroButton', 'CollectionsMicroButton',
  'EJMicroButton', 'ProfessionMicroButton', 'LFDMicroButton', 'HousingMicroButton',
  'StoreMicroButton', 'HelpMicroButton', 'MainMenuMicroButton',
];
const missing = NAMED.filter((n) => !ENTRIES.includes(n));
ok(missing.length === 0,
  'B2 十三颗有实名证据的按钮都在 ENTRIES 里（缺：' + (missing.length ? missing.join(', ') : '无') + '）');

// ---------------------------------------------------------------- C 建行纪律
ok(/local luaAction = target and nil or SafeActionFor\(entry\)/.test(CODE),
  'C1 有转发目标时**不取** luaAction（两个动作源不会同时生效）');
ok(/if target or luaAction then/.test(CODE),
  'C2 两者都没有 ⇒ 这一行一个都不建（宁可少一行，不建点了没反应的行）');
ok(/if ns:IsRestricted\(\) then return end[\s\S]{0,240}C_Map\.OpenWorldMap/.test(CODE),
  'C3 地图行走 `C_Map.OpenWorldMap`（文档标 [受限]）⇒ 前面必须有 ns:IsRestricted() 门');
ok(/ns:GetModule\("Bags"\)[\s\S]{0,240}bags:Toggle\(true\)/.test(CODE),
  'C4 背包行走我们自己的背包模块（本客户端没有可转发的背包微按钮，`ToggleAllBags` 又不许调）');

console.log('');
console.log(`微菜单入口闸门：${pass} 通过 / ${fail} 失败`);
if (fail > 0) {
  console.log('判读：A 组任一失败 = 11-05 那条 P0 回来了（拦截会记在 MonetUI 名下）；' +
    'B 组失败 = 台账里会长出一行消不掉的 ✗；C 组失败 = 菜单里出现"点了没反应"的行。');
}
process.exit(fail > 0 ? 1 : 0);
