-- tools/harness/bags-currency-icon-probe.lua
-- 用法（项目根目录）：lua tools/harness/bags-currency-icon-probe.lua
--
-- 回归目标（2026-11-10 作者 §8.84）：「货币的 title 能用图标代替吗，这样可以节省位置，
-- 不然追踪多了就放不下了」。标题行原本是「名称 + 完整数量」（金币还有 `35g 59s 51c`），
-- 项数一多就被 FittedCurrencyText 折成 +N 甚至整行隐藏。图标模式改成
-- 「图标 + 短数量，名称与完整值走悬停提示」，文字模式保留为可切回的兜底。
--
-- 本桩：① 整份加载线上 Currency.lua 原文（金币条目 / ShortQuantity / IconOf 都是真实现）；
--       ② 抽取线上 Bags.lua 的 BuildCurrencyText / CurrencyIconSignature / CurrencyCell /
--          FitCurrencyIcons 原文执行；③ 静态断言守住开关、事件、tooltip 与配置联动。

local function read(path)
    local f = assert(io.open(path, "r"), "missing " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

local function slice(src, from, upto)
    local a = assert(src:find(from, 1, true), "missing marker " .. from)
    local b = assert(src:find(upto, a, true), "missing marker " .. upto)
    return src:sub(a, b - 1)
end

local loader = loadstring or load
local failed = 0
local function check(name, ok, detail)
    if not ok then failed = failed + 1 end
    print((ok and "PASS " or "FAIL ") .. name
        .. (detail and ("  ->  " .. tostring(detail)) or ""))
end

-- ==========================================================================
-- ① 最小游戏桩 + 整份线上 Currency.lua
-- ==========================================================================
local CURRENCIES = {
    { name = "专业与商业技能", isHeader = true },
    { currencyID = 3402, name = "商人青睐", quantity = 80, maxQuantity = 0,
      iconFileID = 135725, isShowInBackpack = true, isHeader = false },
    { name = "Unused", isHeader = true },
    { currencyID = 1792, name = "荣誉点数", quantity = 16, maxQuantity = 0,
      iconFileID = 2173920, isShowInBackpack = false, isHeader = false },
}
local byID = {}
for i = 1, #CURRENCIES do
    if CURRENCIES[i].currencyID then byID[CURRENCIES[i].currencyID] = CURRENCIES[i] end
end
_G.C_CurrencyInfo = {
    GetCurrencyListSize = function() return #CURRENCIES end,
    GetCurrencyListInfo = function(i) return CURRENCIES[i] end,
    GetBackpackCurrencyInfo = function() return nil end,
    GetCurrencyInfo = function(id) return byID[id] end,
}
_G.GetMoney = function() return 355951 end     -- 实机读数：35g 59s 51c

local db = { infobar = {
    currencyMode = "backpack", currencyWatch = {},
    currencyMax = 4, currencyShowZero = true,
} }
local ns = {
    InfoBar = {
        Settings = function() return db.infobar end,
        RefreshBlock = function() end,
        GetBlock = function() return nil end,
        GetSetting = function() return true end,
    },
    Secrets = {
        Number = function(v) return type(v) == "number" and v or nil end,
        Bool = function(v, d) return type(v) == "boolean" and v or d end,
        CanRead = function(v) return type(v) == "string" end,
    },
    Widget = {},
    DEFAULTS = { infobar = db.infobar },
    DB = function() return db end,
    Print = function() end,
}
local currencySrc = read("Modules/InfoBar/Currency.lua")
assert(loader(currencySrc, "@Currency.lua"))("MonetUI", ns)
local C = ns.InfoBar.Currency

check("数据层原文加载并挂到 InfoBar.Currency", type(C) == "table")
check("ShortQuantity / IconOf 由数据层统一提供",
    type(C.ShortQuantity) == "function" and type(C.IconOf) == "function")

local gold = C:GoldEntry()
check("金币条目带内置图标 133784", gold and C:IconOf(gold) == 133784,
    gold and tostring(gold.icon))
check("金币完整 display 仍是 g/s/c", gold and gold.display == "35g 59s 51c",
    gold and gold.display)
check("金币短数量缩成 35g", C:ShortQuantity(gold) == "35g", C:ShortQuantity(gold))
check("金币不足 1g 时缩成 s/c", C:ShortQuantity({ isGold = true, quantity = 5951 }) == "59s")
check("金币不足 1s 时缩成 c", C:ShortQuantity({ isGold = true, quantity = 51 }) == "51c")
check("真实货币短数量走缩写", C:ShortQuantity({ quantity = 80 }) == "80"
    and C:ShortQuantity({ quantity = 12345 }) == "1.2万")
check("IconOf 读货币页 iconFileID", C:IconOf({ icon = 135725 }) == 135725)
check("IconOf 对 0 / nil 返回 nil", C:IconOf({ icon = 0 }) == nil
    and C:IconOf({}) == nil)

-- ==========================================================================
-- ② 抽取线上 Bags.lua 的布局纯函数原文执行
-- ==========================================================================
local bagsSrc = read("Modules/Bags/Bags.lua")
local buildText = slice(bagsSrc, "local function BuildCurrencyText(entries, C, n)",
    "--- 图标模式的缓存签名")
local layout = slice(bagsSrc, "local function CurrencyIconSignature(entries, C)",
    "--- 懒建一格")

local chunk = [[
local CURRENCY_ICON    = 14
local CURRENCY_IGAP    = 3
local CURRENCY_CGAP    = 8
local CURRENCY_MAXCELL = 8
]] .. buildText .. "\n" .. layout .. [[
return {
    BuildCurrencyText = BuildCurrencyText,
    CurrencyIconSignature = CurrencyIconSignature,
    CurrencyCell = CurrencyCell,
    FitCurrencyIcons = FitCurrencyIcons,
}
]]
local B = assert(loader(chunk, "@BagsCurrencyIcon.lua"))()

-- 实机形态：金币 + 2 项真实货币 + 1 项没图标的（货币页偶发缺 iconFileID）。
local entries = {
    gold,
    { id = 3402, name = "商人青睐", quantity = 80, icon = 135725, maxQuantity = 0 },
    { id = 1792, name = "荣誉点数", quantity = 16, icon = 2173920, maxQuantity = 0 },
    { id = 1901, name = "无图标货币", quantity = 5, icon = 0, maxQuantity = 0 },
}

-- 11px 点阵字体约 7 UI/字符；桩只求相对宽度，不追求像素级精确。
local function measure(text) return #tostring(text) * 7 end

local n, cells, widths, tail = B.FitCurrencyIcons(entries, C, 1000, measure)
check("宽度够：4 项全显示、无 +N", n == 4 and tail == 0,
    "n=" .. n .. " tail=" .. tail)
check("第 1 格是金币，图标 133784 / 短数量 35g",
    cells[1].icon == 133784 and cells[1].text == "35g"
    and cells[1].label == "金币" and cells[1].full == "35g 59s 51c",
    tostring(cells[1].text) .. " / " .. tostring(cells[1].full))
check("第 2 格取货币页图标 + 短数量",
    cells[2].icon == 135725 and cells[2].text == "80" and cells[2].label == "商人青睐")
check("缺 iconFileID 的项 icon=nil（渲染方隐藏图标只留数字）",
    cells[4].icon == nil and cells[4].text == "5")
check("格宽 = 图标 14 + 间隔 3 + 文字宽", widths[1] == 14 + 3 + measure("35g"),
    "w=" .. tostring(widths[1]))

-- 核心诉求：同样 4 项，图标模式必须明显比文字模式窄。
local iconTotal = 0
for i = 1, #widths do iconTotal = iconTotal + widths[i] end
iconTotal = iconTotal + (#widths - 1) * 8
local textTotal = measure(B.BuildCurrencyText(entries, C, 4))
check("★ 图标模式比文字模式省位（4 项）", iconTotal < textTotal * 0.6,
    "icon=" .. iconTotal .. " text=" .. textTotal)

-- 宽度从宽到窄：逐项减，尾部折 +N，极端时一格不放。
local n2, _, w2, tail2 = B.FitCurrencyIcons(entries, C, 90, measure)
check("窄标题行：减项并折 +N", n2 < 4 and n2 >= 1 and tail2 == 4 - n2,
    "n=" .. n2 .. " tail=" .. tail2)
check("+N 格宽也参与预算", w2[n2 + 1] ~= nil and w2[n2 + 1] > 0)
local n3, _, _, tail3 = B.FitCurrencyIcons(entries, C, 1, measure)
check("极端窄：不放格、全部折 +N", n3 == 0 and tail3 == 4,
    "n=" .. n3 .. " tail=" .. tail3)

-- 超过 8 项：只画前 8，其余折 +N（与文字模式同一上限）。
local many = {}
for i = 1, 12 do
    many[i] = { id = 4000 + i, name = "货币" .. i, quantity = i, icon = 1000 + i }
end
local n4, c4, _, tail4 = B.FitCurrencyIcons(many, C, 10000, measure)
check("超过 8 项只画 8 格、其余折 +4", n4 == 8 and #c4 == 8 and tail4 == 4,
    "n=" .. n4 .. " tail=" .. tail4)

-- 缓存签名：数量 / 名称 / 图标任一变化都要变；内容不变要稳定。
local sig1 = B.CurrencyIconSignature(entries, C)
local sig2 = B.CurrencyIconSignature(entries, C)
check("签名内容不变时稳定", sig1 == sig2)
local changed = {}
for i = 1, #entries do changed[i] = entries[i] end
changed[2] = { id = 3402, name = "商人青睐", quantity = 81, icon = 135725 }
check("数量变化会让签名变化（轮询能刷新）",
    B.CurrencyIconSignature(changed, C) ~= sig1)
local changedIcon = {}
for i = 1, #entries do changedIcon[i] = entries[i] end
changedIcon[2] = { id = 3402, name = "商人青睐", quantity = 80, icon = 999 }
check("图标变化会让签名变化", B.CurrencyIconSignature(changedIcon, C) ~= sig1)

-- 测量失败（机密值）按 0 处理：宁可显示全，也不能清空整行。
local n5, _, _, tail5 = B.FitCurrencyIcons(entries, C, 1000, function() return nil end)
check("机密值量不到时仍显示全部", n5 == 4 and tail5 == 0, "n=" .. n5)

-- ==========================================================================
-- ③ 静态断言：开关 / 事件 / tooltip / 配置联动不被改回去
-- ==========================================================================
local core = read("Core.lua")
local config = read("Config/SimpleConfig.lua")
check("默认开启图标模式（DEFAULTS.bags.currencyIcons = true）",
    core:find("currencyIcons%s*=%s*true", 1, false) ~= nil)
check("UpdateCurrencyTitle 按开关分流两套排版",
    bagsSrc:find('local useIcons = Setting%("currencyIcons"%) ~= false', 1, false) ~= nil
    and bagsSrc:find("RenderCurrencyIcons(win, entries, C, avail, -reserve)", 1, true) ~= nil
    and bagsSrc:find("FittedCurrencyText(fs, entries, C, avail)", 1, true) ~= nil)
check("缓存 key 带模式前缀（切换必重画）",
    bagsSrc:find('(useIcons and "i|" or "t|")', 1, true) ~= nil)
check("清空路径同时收两套控件",
    bagsSrc:find("HideCurrencyCells(win)", 1, true) ~= nil
    and bagsSrc:find("win.currencyKey = nil", 1, true) ~= nil)
check("金币变化注册 PLAYER_MONEY（不等轮询）",
    bagsSrc:find('EventBus:Register%("PLAYER_MONEY", RefreshCurrencyTitles%)', 1, false) ~= nil)
check("窗口带隐藏度量 FontString",
    bagsSrc:find("win.currencyMeasure = measure", 1, true) ~= nil)
check("渲染方量不到宽度时按字符数兜底（不叠格）",
    bagsSrc:find("if not w or w <= 0 then return #tostring(text) * 7 end", 1, true) ~= nil)
check("缓存命中时把当前模式的格子扶正",
    bagsSrc:find("for i = 1, win.currencyRendered or 0 do", 1, true) ~= nil)
check("每格有 tooltip 与拖动转发",
    bagsSrc:find('cell:SetScript%("OnEnter"', 1, false) ~= nil
    and bagsSrc:find('cell:SetScript%("OnDragStart"', 1, false) ~= nil
    and bagsSrc:find("SaveWindowPosition(win)", 1, true) ~= nil)
check("命令 icons on|off 与状态打印都在",
    bagsSrc:find('rest == "currency icons on"', 1, true) ~= nil
    and bagsSrc:find('标题行图标模式 = ', 1, true) ~= nil)
check("公开 RefreshCurrencyTitles 给配置面板调用",
    bagsSrc:find("function M:RefreshCurrencyTitles()", 1, true) ~= nil)
check("配置面板有图标开关且联动刷新",
    config:find("背包标题行：货币用图标", 1, true) ~= nil
    and config:find('bags:RefreshCurrencyTitles()', 1, true) ~= nil)
check("配置提示说明图标 + 悬停看名称",
    config:find("悬停看名称与完整数值", 1, true) ~= nil)
check("文字模式仍保留（icons off 可切回）",
    bagsSrc:find("local function FittedCurrencyText", 1, true) ~= nil)

print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
os.exit(failed == 0 and 0 or 1)
