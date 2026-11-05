/**
 * 微菜单入口闸门 —— `node tools/micromenu-entries-probe.js`。
 *
 * 11-05 开服这一天，这个文件连着错三次，三次都归到 MonetUI 名下，所以每条断言都有判例：
 *   ① `GetScript("OnClick")` 抠暴雪脚本自己调 → `TextStatusBar.lua:110` 机密值比较按我们的名义抛
 *      （P0，日志有完整栈；`4a458d1` 撤掉）。
 *   ② 改成"每行 `SecureActionButtonTemplate` + `type=click` 代点暴雪微按钮" → 行锚进菜单面板，
 *      **把面板传染成受保护**：实机 `/mui minimap menu` 读出 `IsProtected()=true`、
 *      `GetNumPoints()=0`，之后 `frame:SetPoint/SetHeight` **静默丢弃**（不记 BLOCKED、不报错），
 *      玩家看到的就是「右键小地图没反应」（HANDOFF §8.38）。
 *   ③ 于是入口只剩一条合法出口：**纯 C_* API 或我们自己的模块**。本客户端只有
 *      `C_Map.OpenWorldMap` / `Settings.OpenToCategory` 这一小撮，角色/法术/任务那一排
 *      没有 C 侧开口 ⇒ 这一版微菜单只有三行，其余等 #43。
 *
 * **harness 不派微菜单阶段**（`grep MicroMenu tools/harness/run.lua` = 0 命中），
 * 所以 `run.js red=0` 不是这条路径的证据；证据 = 本闸门 + `/mui minimap menu` 实机读数。
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SRC = fs.readFileSync(path.join(ROOT, 'Modules/Minimap/MicroMenu.lua'), 'utf8');
const CODE = SRC.split(/\r?\n/).map((l) => l.replace(/--.*$/, "")).join("\n");
const ENTRIES = (CODE.match(/local ENTRIES = \{[\s\S]*?\n\}/) || [''])[0];

let pass = 0;
let fail = 0;
const ok = (cond, label) => {
  if (cond) { pass++; console.log('  [OK]   ' + label); }
  else { fail++; console.log('  [FAIL] ' + label); }
};

// ---------------------------------------------------------------- A 只有一个动作源
ok(!/GetScript/.test(CODE),
  'A1 全文不出现 GetScript —— 把暴雪脚本抠出来自己调用 = 开服 P0 判例（`TextStatusBar.lua:110`）');
ok(!/SecureActionButtonTemplate/.test(CODE),
  'A2 全文不出现 SecureActionButtonTemplate —— 安全模板锚进面板会把面板标成受保护，' +
  '我们的 SetPoint 从此静默失效（实机：IsProtected=true + GetNumPoints=0 + 菜单展不开）');
ok(!/SetAttribute/.test(CODE),
  'A3 没有 SetAttribute 残留（安全属性写法只剩 A2 那一条成因）');
ok(!/^\s*action\s*=/m.test(ENTRIES),
  'A4 ENTRIES 里没有 `action =` 字段：那条兜底正是调暴雪 Lua 全局的路，不能被"留着无害"骗回来');

const FORBIDDEN = [
  'ToggleGameMenu', 'ToggleAllBags', 'ToggleWorldMap', 'ToggleFriendsFrame',
  'ToggleQuestLog', 'ToggleQuestFrame', 'ToggleAchievementFrame', 'ToggleCalendar',
  'ToggleCollectionsJournal', 'ToggleEncounterJournal', 'ToggleSpellBook',
  'PlayerSpellsUtil', 'ShowUIPanel', 'HideUIPanel', 'ToggleFrame', 'ToggleCharacter',
];
const hit = FORBIDDEN.filter((n) => new RegExp('\\b' + n + '\\b').test(CODE));
ok(hit.length === 0,
  'A5 一个暴雪 Lua 全局都不被调用（命中：' + (hit.length ? hit.join(', ') : '无') + '）');

// ---------------------------------------------------------------- B 入口只剩合法出口
const entries = [...ENTRIES.matchAll(/label\s*=\s*"([^"]+)"/g)].map((m) => m[1]);
ok(entries.length >= 1 && entries.length <= 6,
  `B1 入口数量收到 ${entries.length} 行（${entries.join('、') || '无'}）—— 有纯 C_* 开口的就那么几个，多出来的一定是又去点暴雪按钮了`);
ok(!/buttons\s*=/.test(ENTRIES),
  'B2 ENTRIES 里不再有 `buttons =` 微按钮名单（那是 A2 那条路的输入）');
const withAction = [...ENTRIES.matchAll(/luaAction\s*=\s*function/g)].length;
ok(withAction === entries.length,
  `B3 每一行都自带 luaAction（${withAction}/${entries.length}）—— 没有动作的行造出来就是"点了没反应"`);
ok(/if ns:IsRestricted\(\) then return end[\s\S]{0,240}C_Map\.OpenWorldMap/.test(CODE),
  'B4 地图行走 `C_Map.OpenWorldMap`（文档标 [受限]）⇒ 前面必须有 ns:IsRestricted() 门');
ok(/ns:GetModule\("Bags"\)[\s\S]{0,240}bags:Toggle\(true\)/.test(CODE),
  'B5 背包行走我们自己的背包模块（动作全在我们名下，不牵动暴雪 Lua 面板链）');

// ---------------------------------------------------------------- C 判据命令在位
ok(/function M:Probe\(enabledSetting\)/.test(CODE) && /GetNumPoints/.test(CODE),
  'C1 `/mui minimap menu` 在位且会读 GetNumPoints —— 「静默丢弃 SetPoint」只有这个数能看出来');
ok(/type\(frame\.GetRect\) == "function"[\s\S]{0,120}frame:GetRect\(\)/.test(CODE),
  'C2 面板矩形用 GetRect（left,bottom,width,height 四值口径，11-04 记过：当成四个角会读错）');
ok(/代价说清楚/.test(SRC) && /#43/.test(SRC),
  'C3 文件里写着"为什么只剩这三行"的代价说明 + #43 的去处（没有这段，下一趟一定把它当"被删功能"补回来）');

console.log('');
console.log(`微菜单入口闸门：${pass} 通过 / ${fail} 失败`);
if (fail > 0) {
  console.log('判读：A 组失败 = 开服日那两条 P0 之一回来（红字 / 界面行为失效）；' +
    'B 组失败 = 菜单里出现"点了没反应"的行，或又有人想代点暴雪按钮；' +
    'C 组失败 = 下次「展不开」没有一条命令能自证，只能靠猜。');
}
process.exit(fail > 0 ? 1 : 0);
