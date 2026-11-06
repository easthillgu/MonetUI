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
// 2026-11-06 面板删除后 A9 的对象变成了标题行工具件 —— 同一类错（`local function` 遮蔽前置声明）
// 在新代码里也要守住：必须"先前置声明、后用赋值"，且声明在 Rebuild 之前。
const declIdx = SRC.indexOf('local EnsureBankTitleTools');
const rebuildIdx = SRC.indexOf('local function Rebuild(');
ok(declIdx >= 0 && rebuildIdx > declIdx && !/local function EnsureBankTitleTools/.test(SRC)
  && /EnsureBankTitleTools = function\(win\)/.test(SRC),
  'A9 EnsureBankTitleTools 先前置声明再赋值（写 `local function` = Rebuild 抓到全局 nil）');
ok(!/\(\(isBank and "银行 · "\) \.\. ""\)/.test(SRC) && /isBank and "银行 · " or ""/.test(SRC),
  'A10 标题前缀写成 `and ... or ""`（`(x and "串") .. ""` 在 x=false 时是 concat boolean）');
const ensureWin = (SRC.match(/local function EnsureWindow\(key\)[\s\S]*?\nend/) || [''])[0];
const iCreate = ensureWin.indexOf('Widget:CreateFrame(name');
const iReg = ensureWin.indexOf('windows[key] = win');
const iFirstUse = ensureWin.indexOf('Widget:Theme(win');   // 登记之后才会开始美化
ok(iCreate >= 0 && iReg >= 0 && iFirstUse >= 0 && iCreate < iReg && iReg < iFirstUse,
  'A11 EnsureWindow 建框当场就登记 windows[key]（登记排在末尾 = 中间抛错留下"名占表空"，下次必炸 already exists）');

// ---------------------------------------------------------------- B 不猜索引
// 2026-11-06 定性（1.60.1/70790 实机）：本客户端 `-1` = **Keyring（钥匙扣）**，
// 它不是银行页面 —— 留在候选里会让"银行空格"多算 32 格（实测 55 = 钥匙扣 32 + 银行 23）。
// B1 因此**反向**断言：候选里不许再出现 -1，同时保留"为什么不轻信正式服语义"的记录。
ok(/local BANK_PAGE_CANDIDATES = \{ -2, -3 \}/.test(SRC) && /-1 是钥匙扣/.test(SRC),
  'B1 银行候选里不含 -1（本客户端 -1 = Keyring；正式服那套 Bank 语义在这里不成立）');
ok(/for _, i in ipairs\(BANK_PAGE_CANDIDATES\) do indexes\[#indexes \+ 1\] = i end/.test(SRC),
  'B2 银行索引 = 主页候选 + 标签页，不是只扫 6..14（旧行为等于主页一个没扫）');
ok(/local num = Secrets\.Number\(C_Container\.GetContainerNumSlots\(bag\)\)/.test(SRC)
  && /if num and num > 0 then/.test(SRC),
  'B3 槽数过 Secrets.Number 且 >0 才收（读不出/为 0 绝不画假空页）');

// ---------------------------------------------------------------- C 停车纪律
// ⚠ 11-04 改判：接管的前置从"画出银行物品"收紧成"**并且** hideBlizzardBank 开着"。
// 2026-11-06 作者拍板把该项**默认改 on**（空格已是真槽位 + 三向拖放实测通过，HANDOFF §8.57），
// 所以这里断言的是"停车前置 = 开关 且 真画出物品"，**不是**默认值本身（默认值在 Core.lua DEFAULTS）。
// 原因是玩家实机报的功能回退：我们的空格子是占位壳、不是真容器槽，把暴雪银行框 alpha 0 +
// 关鼠标收掉 = 拿走唯一能落东西的面 ⇒ 背包↔银行"能拖不能放"。②A 的保险逻辑仍然成立，
// 但 11-06 起默认就是接管（空格已做成真 ItemButton），两套并存改成可选项。
ok(/ParkBlizzardBank\(\(Setting\("hideBlizzardBank"\).*?and bankDrawn > 0\)/.test(SRC),
  'C2 停车前置 = hideBlizzardBank 且真画出银行物品（开关默认值见 Core.lua DEFAULTS）');
ok(/EnsureBankTitleTools\(freeWin\)[\s\S]{0,300}ParkBlizzardBank\(\(Setting\("hideBlizzardBank"\)/.test(SRC),
  'C2b 重绘末尾顺序：标题行工具件 → 停车（工具件先建好再决定停不停）');
ok(/if rest == "hidebliz on" or rest == "hidebliz off" then/.test(SRC),
  'C2c `/mui bags hidebliz on|off` 在（作者要单套观感时的开关，代价写在输出里）');
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
// 2026-11-06 作者改判：「包裹管理」折叠面板整块删除，两个动作搬到 `bank:free` 的**标题行**
//（一键存入 / 栏位管理）。E4/E5 因此改测标题行那一对钮，而不是面板与折叠状态。
ok(/EnsureBankTitleTools = function\(win\)/.test(SRC) && /BankHeadButton\(win, "一键存入"/.test(SRC)
  && /BankHeadButton\(win, "栏位管理"/.test(SRC),
  'E4 标题行两颗动作钮（一键存入 / 栏位管理）由 EnsureBankTitleTools 懒建');
ok(/local button = Widget:CreateFrame\(nil, parent, width, 18, nil, "Button"\)/.test(SRC),
  'E5 标题钮建成 Button（`Widget:CreateFrame` 不传 kind 默认 Frame，Frame 没有 RegisterForClicks）');
ok(!/bankToolsBody|bankToolsInfo|bankToolsArrow|EnsureBankTools|LayoutBankTools|"包裹管理"/.test(SRC),
  'E5b 旧面板已彻底删除（body/info/arrow/Ensure/Layout/标题字 全无，避免第二处入口分叉）');
ok(/if keepTitle then[\s\S]{0,400}win:SetShown\(true\)/.test(SRC) && /if rows == 0 then h = TITLE_H \+ PAD end/.test(SRC),
  'F7 银行空仓库时仍显示标题行（只有标题 + 两颗钮，高度 TITLE_H+PAD）');

// ---------------------------------------------------------------- F 空格真槽位（#25 背包侧）
// 玩家 11-04 实机："能拖出来、放不进空格"，背包→背包同样坏 —— 占位壳没有容器身份。
const FREEFN = (SRC.match(/local function FillFreeWindow\(win, empties, keepTitle\)[\s\S]*?\nend\n/) || [''])[0];
ok(FREEFN !== '', 'F0 FillFreeWindow 函数体可定位（定位不到则 F3/F4 全是空判）');
ok(/empties\[#empties \+ 1\] = \{ bag = bag, slot = slot \}/.test(SRC),
  'F1 Scan 收集空格的真实坐标 (bag,slot)，不再只报数量');
ok(/local FREE_ROWS = 1/.test(SRC) && /math\.min\(total, columns \* FREE_ROWS\)/.test(SRC),
  'F2 空格只画一行（FREE_ROWS=1 × columns），其余走 +N —— 11-06 作者定（旧 84 格多行作废）');
ok(/count:SetText\(\(i == draw and hidden > 0\) and \("\+" \.\. tostring\(hidden\)\) or ""\)/.test(SRC),
  'F2b +N 写在最后一格、且 N = total - draw（最后一格仍是真槽位，不把自己算进去）');
ok(/shell = AcquireButton\(win\)/.test(FREEFN) && /UpdateButton\(shell, \{ bag = list\[i\]\.bag, slot = list\[i\]\.slot \}\)/.test(FREEFN),
  'F3 空格用真 ItemButton + UpdateButton 绑身份（落点靠 GetBagID 的父级 GetID 兜底）');
ok(FREEFN !== '' && !/AcquireFreeSlot/.test(FREEFN),
  'F4 占位壳工厂已删（留着就会有第二条"看着像格子但不能落"的路径）');
// 2026-11-06：银行侧**已接**（原先"索引语义未定性就不接"的临时口径作废）。
// 定性的硬证据：`Enum.BagIndex` 里 6..14 = CharacterBankTab_1..9；站银行 NPC 前实测
// `6:48 槽 / 26 件 / 22 空`、7..14 全 0 槽 ⇒ 索引与物理格子 1:1，不存在"同一格多个索引"。
ok(/FillFreeWindow\(freeWin, empties, activeMode == "bank"\)/.test(SRC),
  'F5 银行侧也传真槽位坐标 + keepTitle（空银行也留标题行，见 F7）');
ok(/Skin:ApplySlotCooldown\(cd, rec\.itemID\)/.test(SRC) && /if not rec\.itemID then return end/.test(SRC),
  'F6 空格复用清冷却遮罩（共用 Skin:ApplySlotCooldown，nil itemID 也显式收）+ 空槽悬停不弹提示');

console.log(`bank-parity-probe: ${pass} 过 / ${fail} 失`);
process.exit(fail === 0 ? 0 : 1);
