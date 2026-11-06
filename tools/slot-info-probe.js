/**
 * 装备格「物品等级 + 冷却」接线闸门（`node tools/slot-info-probe.js`）。
 *
 * 只证**接线**，不证数值：等级数字来自 `C_Item.GetItemInfo` 第 4 返回、冷却来自
 * `C_Container.GetItemCooldown`，这两个在离线里拿不到真值（桩给的是编的数）。
 * 观感与"装上了装备到底显不显示"归 11-05 实机那一趟（docs/VERIFY-1.60-CHECKLIST.md）。
 *
 * 断言分三组：
 *   A 背包 / 银行（Modules/Bags）：格子建时造数字、重绘时写、空槽清空、值过 Secrets.Number。
 *   B 人物面板（Utils/Skin + Modules/Skins）：开关从面板规格一路传到边框，默认面不被扩大。
 *   C 守卫口径：新加的每一次取值都要过 Secrets（数字 Secrets.Number，字符串 CanRead）。
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const READ = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

const BAGS = READ('Modules/Bags/Bags.lua');
const SKIN = READ('Utils/Skin.lua');
const SKINS = READ('Modules/Skins/Skins.lua');
const CHAR = READ('Modules/Skins/Character.lua');

let pass = 0;
let fail = 0;
function ok(cond, label) {
  if (cond) { pass++; console.log('  [OK]   ' + label); }
  else { fail++; console.log('  [FAIL] ' + label); }
}

// ---------------------------------------------------------------- A 背包 / 银行
ok(/Mark\(shell, "ilvlF", ilvl\)/.test(BAGS),
  'A1 AcquireButton 给每格造了等级字体串并登记进旁表');
ok(/if ilvlFs then ilvlFs:SetText\(""\) end/.test(BAGS),
  'A2 空槽路径清等级文字（不留上一件的数字）');
// 2026-11-06：等级取词/写入的守卫**已收口到 `Skin:SlotInfoText`**（`1fae0b0` 把物品格三件套
// 抽成共享原语）。断言跟着单源走 —— 仍要证明"过 Secrets.Number + >0 才写"，
// 但位置从 Bags 内联搬到 Skin；再加一条**反向守卫**：Bags 必须调那个原语，
// 否则等于有人在背包侧又写了一份内联算术（闸门要拦的是这个）。
ok(/local n = Secrets\.Number\(raw\)/.test(SKIN) && /function Skin:SlotInfoText\(raw\)/.test(SKIN),
  'A3 等级取值过 Secrets.Number 才比较（单源 Skin:SlotInfoText）');
ok(/if n and n > 0 then return tostring\(math\.floor\(n\)\)/.test(SKIN),
  'A4 只在 ilvl > 0 时写数字（材料/布料不画 0）');
ok(/ilvlFs:SetText\(Skin:SlotInfoText\(rec\.ilvl\)\)/.test(BAGS),
  'A5 背包/银行格用的是同一个原语（没有第二份内联取词）');

// ---------------------------------------------------------------- B 人物面板
ok(/function Skin:ItemQualityBorder\(btn, withInfo\)/.test(SKIN),
  'B1 边框入口接了 withInfo 参数');
ok(/if withInfo and not entry\.ilvl then/.test(SKIN),
  'B2 数字与冷却只在显式开格时创建，且可事后升级（谁先扫到都一样）');
ok(/if entry\.ilvl or entry\.cd then UpdateSlotInfo\(btn, entry\) end/.test(SKIN),
  'B3 0.5s 品质驱动顺带刷新等级/冷却，不开第二根定时器');
ok(/pcall\(Skin\.ItemQualityBorder, Skin, target, withInfo\)/.test(SKINS),
  'B4 图标扫描把 withInfo 透传给边框');
ok(/M:IconWidgetsIn\(frame, nil, withInfo\)/.test(SKINS),
  'B5 SweepDeep 的可见期补扫也带上（懒建格子跑不掉）');
ok(/M:SweepDeep\(frame, opts\.control, opts\.slotInfo(, opts\.deepRows)?\)/.test(SKINS),
  'B6 Dress 的 deep 分支从面板规格取 slotInfo（第四个参数 deepRows 可有可无）');
ok(/M:IconWidgetsIn\(frame, nil, opts\.slotInfo\)/.test(SKINS),
  'B7 Dress 的 icons 默认分支同样取 slotInfo');
ok(/local PAPERDOLL_PANEL = .*\bslotInfo = true/.test(CHAR),
  'B8 只有 PaperDoll 那一档开 slotInfo');
const PANEL_LIST = (CHAR.match(/local CHARACTER_PANELS = \{[\s\S]*?\}/) || [''])[0];
ok(PANEL_LIST !== '' && !/PaperDollFrame/.test(PANEL_LIST),
  'B9 PaperDoll 已从共用面板名单里拆出（否则 SUB_PANEL 会先把它无信息地扫掉）');
ok(/M:Dress\("PaperDollFrame", PAPERDOLL_PANEL\)/.test(CHAR),
  'B10 拆出去的 PaperDoll 确实被 Dress 了');

// ---------------------------------------------------------------- D 功能图标豁免
// 11-05 玩家实测判例：商人修理 / 修全部的铁槌（atlas `SpellIcon-256x256-Repair(All)`）被剥美术的
// 循环当成窗体装饰压成 α0 ⇒「维修和全修的铁槌图标看不到了」。
// ⚠ 而当时 `/mui skins layers` 的"还看得见的暴雪美术"是**下降**的 —— 删掉图标同样会让它下降，
//   所以那个指标不能单独当验收（AGENTS 已加口径提醒：图标类控件要逐颗肉眼过）。
ok(/local CONTENT_ICON_ATLAS = \{/.test(SKIN) && /spellicon/.test(SKIN),
  'D1 内容图标 atlas 前缀表在位（含 spellicon 家族，否则铁槌还会被压掉）');
ok(/if tex and not IsContentIcon\(tex\) then self:Fade\(tex\) end/.test(SKIN),
  'D2 FadeButtonArt 走豁免：normal / pushed / disabled / highlight 里的功能图标不剥');
ok(/if not IsContentIcon\(region\) then/.test(SKIN),
  'D3 Strip 的 region 循环走同一条豁免（两条剥图路径不能只修一条）');

// ---------------------------------------------------------------- C 守卫口径
ok(/local function ItemIDOf\(key\)/.test(SKIN) && /Secrets\.CanRead\(key\)/.test(SKIN),
  'C1 link 抠 itemID 前先过 Secrets.CanRead（未守卫的 string.match 会抛 invalid value）');
ok(/text = Skin:SlotInfoText\(ok and lv or nil\)/.test(SKIN),
  'C2 装备格等级过 Secrets.Number（同一条 Skin:SlotInfoText）');
ok(/start, duration, enable = ok and Secrets\.Number\(s\) or nil, Secrets\.Number\(d\), Secrets\.Number\(e\)/.test(SKIN),
  'C3 冷却三个返回全过 Secrets.Number 才比较');
ok(/cd:SetHideCountdownNumbers\(true\)/.test(SKIN),
  'C4 装备格冷却只画遮罩、不开倒计时数字（作者定的保守档）');

console.log(`slot-info-probe: ${pass} 过 / ${fail} 失`);
process.exit(fail === 0 ? 0 : 1);
