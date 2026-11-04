/**
 * 银行与背包并存（`f3464cf`）接线闸门 —— `node tools/bank-parity-probe.js`。
 *
 * **只证接线与禁令边界**，不证行为：银行主页到底哪个容器索引有货、停车生不生效、
 * 折叠面板摆不摆得下，都要 11-05 实机那一趟（`/mui bags probe` 出账）。
 * harness 目前不派 BANKFRAME_*（见提交注），所以这里不能用"harness 红 0"当这条改动的证据。
 *
 * 断言四组：
 *   A 模式命名空间 —— 窗口键 / 位置账 / 总控 ✕ 真的分开了（重叠问题的根）。
 *   B 不猜索引 —— 主页走候选 + `槽数>0` 门，绝不写死 -1。
 *   C 停车纪律 —— 只有画出物品才收；只走 Mute/Unmute，不 Hide；名字只过 Skin:Need。
 *   D 越权边界 —— [受限] 与不存在的 API 一次都不许被调用（注释里提可以）。
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SRC = fs.readFileSync(path.join(ROOT, 'Modules/Bags/Bags.lua'), 'utf8');
const LINES = SRC.split(/\r?\n/);

// 去掉整行注释与行尾注释，只留真代码（越权断言要按代码算，不能按"提没提这个词"算）。
const CODE = LINES
  .map((l) => l.replace(/--.*$/, ""))
  .join("\n");

let pass = 0;
let fail = 0;
const ok = (cond, label) => {
  if (cond) { pass++; console.log('  [OK]   ' + label); }
  else { fail++; console.log('  [FAIL] ' + label); }
};

// ---------------------------------------------------------------- A 命名空间
ok(/local function WinKey\(catKey\)/.test(SRC) && /local function ModeOf\(key\)/.test(SRC),
  'A1 WinKey / ModeOf 两个入口存在');
ok(/win\.catKey = key/.test(SRC) && /db\.bags\.positions\[win\.catKey\]/.test(SRC),
  'A2 位置账按**带前缀的键**存（玩家拖过的银行窗不会顶掉背包窗）');
ok(/local function EnsureWindow\(key\)[\s\S]{0,400}CATEGORY_BY_KEY\[BaseKey\(key\)\]/.test(SRC),
  'A3 EnsureWindow 用 BaseKey 查分类（前缀不会让分类查空）');
ok(/local masterKey = \{ bags = nil, bank = nil \}/.test(SRC),
  'A4 总控 ✕ 每模式各一份（银行一开不会抢走背包那枚）');
ok(/if mode == "bank" then\s*x = x - bagsColumnWidth\(\) - spacing/.test(SRC),
  'A5 银行列贴在背包列**再往左**，宽度当场量（不写死常数）');
ok(/银行 · /.test(SRC), 'A6 两套窗同屏，标题带"银行 · "前缀');
// A7/A8：11-04 实机判例 —— masterKey 改成按模式的表之后，`M:Toggle(false)` 里那行
// 旧的重置还写着 `= nil`，下一次 DesignateMaster 索引 nil 直接抛，症状是"按 B 没反应"。
ok(!/masterKey\s*=\s*nil\b/.test(SRC),
  'A7 没有任何地方把 masterKey 赋成 nil（结构已是表，重置也必须写表）');
ok((SRC.match(/masterKey = \{ bags = nil, bank = nil \}/g) || []).length >= 2,
  'A8 声明处与 Toggle(false) 的重置处都用同一份表形状');
// A9/A10/A11：11-04 harness 银行阶段打出来的三个真错，全是本次改动自己引入的。
ok(!/local function LayoutBankTools/.test(SRC) && /LayoutBankTools = function\(\)/.test(SRC),
  'A9 LayoutBankTools 用赋值不是 `local function`（前置声明被 local 遮蔽 = Rebuild 里永远 nil）');
ok(!/\(\(isBank and "银行 · "\) \.\. ""\)/.test(SRC) && /isBank and "银行 · " or ""/.test(SRC),
  'A10 标题前缀写成 `and ... or ""`（`(x and "串") .. ""` 在 x=false 时是 concat boolean）');
const ensureWin = (SRC.match(/local function EnsureWindow\(key\)[\s\S]*?\nend/) || [''])[0];
const iCreate = ensureWin.indexOf('Widget:CreateFrame(name');
const iReg = ensureWin.indexOf('windows[key] = win');
const iFirstUse = ensureWin.indexOf('Widget:Theme(win');   // 登记之后才会开始美化
ok(iCreate >= 0 && iReg >= 0 && iFirstUse >= 0 && iCreate < iReg && iReg < iFirstUse,
  'A11 EnsureWindow 建框当场就登记 windows[key]（登记排在末尾 = 中间抛错留下"名占表空"，下次必炸 already exists）');

// ---------------------------------------------------------------- B 不猜索引
ok(/local BANK_PAGE_CANDIDATES = \{ -1, -2, -3 \}/.test(SRC),
  'B1 主页三个候选一起交给扫描（本客户端 Enum.BagIndex 与正式服不同）');
ok(/for _, i in ipairs\(BANK_PAGE_CANDIDATES\) do indexes\[#indexes \+ 1\] = i end/.test(SRC),
  'B2 银行索引 = 主页候选 + 标签页，不是只扫 6..14（旧行为等于主页一个没扫）');
ok(/local num = Secrets\.Number\(C_Container\.GetContainerNumSlots\(bag\)\)/.test(SRC)
  && /if num and num > 0 then/.test(SRC),
  'B3 槽数过 Secrets.Number 且 >0 才收（读不出/为 0 绝不画假空页）');

// ---------------------------------------------------------------- C 停车纪律
ok(/ParkBlizzardBank\(bankDrawn > 0\)/.test(SRC),
  'C2 停车的唯一前置 = 我们真画出了银行物品（②A）');
ok(/EnsureBankTools\(\)[\s\S]{0,200}LayoutBankTools\(\)[\s\S]{0,200}ParkBlizzardBank\(bankDrawn > 0\)/.test(SRC),
  'C2b 重绘末尾顺序：面板 → 排版 → 停车');
ok(/local bank = Skin:Need\("BankFrame"\)/.test(SRC) && /Skin:Need\("WarbandBankFrame"\)/.test(SRC),
  'C3 银行框名字只过 Skin:Need 一个漏斗（缺席要成为账本里的一行 ✗）');
const parkFn = (SRC.match(/ParkBlizzardBank = function\(park\)[\s\S]*?\nend/) || [''])[0];
ok(parkFn !== '' && /Widget:Mute\(frame/.test(parkFn) && /Widget:Unmute\(frame/.test(parkFn),
  'C4 停车走 Mute / Unmute（alpha 0 + 整树关鼠标）');
ok(parkFn !== '' && !/[:.]Hide\(/.test(parkFn),
  'C5 停车函数里一个 Hide 都没有（Hide 会被暴雪的 Show 顶回来，AGENTS 判例）');
ok(parkFn !== '' && /ns:AfterCombat\("bags-park-bank"/.test(parkFn),
  'C6 战斗中关鼠标那一半排队到脱战补做（不硬写）');

// ---------------------------------------------------------------- D 越权边界
ok(!/C_Bank\.PurchaseBankTab\s*\(/.test(CODE),
  'D1 不买银行栏位：C_Bank.PurchaseBankTab 快照标 [受限]，我们一次都不调');
ok(!/PickupInventoryItem|PutItemInBackpack|BuyBankSlot|GetNumBankSlots|PutItemInBag\b/.test(CODE),
  'D2 那五个"换包/买包"全局在本客户端不存在，代码里一个都不出现（注释除外）');
ok(/pcall\(C_Bank\.AutoDepositItemsIntoBank, bt\)/.test(SRC),
  'D3 一键存入 = pcall 包着（文档无标记，但真客户端若也算受限就不崩不刷屏）');
ok(/C_Bank\.CloseBankFrame/.test(SRC),
  'D4 关闭银行走 C_Bank.CloseBankFrame（无标记）');

// ---------------------------------------------------------------- E 命令与收场
ok(/if rest == "probe" then/.test(SRC) && /\[bags\.probe\]/.test(SRC),
  'E1 `/mui bags probe` 在（④A：银行主页索引的账由实机一条命令打全）');
ok(/if rest == "bank off" then[\s\S]{0,120}CloseAllBags\("bank"\)/.test(SRC),
  'E2 `/mui bags bank off` = 放开暴雪那块（买栏位/换包的唯一出路）');
ok(/EventBus:Register\("BANKFRAME_CLOSED"[\s\S]{0,600}HideModeWindows\("bank"\)[\s\S]{0,300}ParkBlizzardBank\(false\)/.test(SRC),
  'E3 银行关闭：只收银行窗 + 放开停车（不会把 alpha 0 的框留到下趟）');
ok(/SetBankToolsSetting\("bankToolsMinimized"/.test(SRC),
  'E4 折叠状态进 SavedVariables（下次开银行保持玩家的选择）');
ok(/local button = Widget:CreateFrame\(nil, parent, 88, 20, nil, "Button"\)/.test(SRC),
  'E5 面板钮建成 Button（`Widget:CreateFrame` 不传 kind 默认 Frame，Frame 没有 RegisterForClicks）');

console.log(`bank-parity-probe: ${pass} 过 / ${fail} 失`);
process.exit(fail === 0 ? 0 : 1);
