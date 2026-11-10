-- tools/harness/currency-gold-probe.lua
-- 用法（项目根目录）：lua tools/harness/currency-gold-probe.lua
--
-- 回归目标（2026-11-10 作者口径 §8.82）：「默认追踪金币，其他的做提示可以自己添加」。
-- 线上 Modules/InfoBar/Currency.lua **整份原文**加载执行（只定义函数，加载期不碰 Frame），
-- 配一层最小 WoW 桩，验证：
--   ① Snapshot 首位恒为金币基线，格式化走 g/s/c 而不是万/亿缩写；
--   ② 默认模式下一个其它货币都不自动追踪（旧 EnsureCustom 会带有余额项）；
--   ③ Suggestions 能列出可添加项 + ID；
--   ④ 玩家 add / 勾选之后金币仍在、货币追加在后面；
--   ⑤ GetMoney 读不到（受限窗口机密值）时静默降级不报错。
-- 另加一组静态断言，盯住三个消费方与提示文案不要被改回去。

local function read(path)
    local f = assert(io.open(path, "r"), "missing " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

local loader = loadstring or load
local failed = 0

local function check(name, ok, detail)
    if not ok then
        print("FAIL " .. name .. (detail and ("  ->  " .. tostring(detail)) or ""))
        failed = failed + 1
    else
        print("PASS " .. name)
    end
end

-- ==========================================================================
-- 最小游戏桩
-- ==========================================================================
-- 与 2026-11-10 16:14 实机读数一致：4 行里 2 个是分类表头（无 currencyID），
-- 真正能监控的只有 3402 商人青睐 / 1792 荣誉点数。表头必须被 Available 过滤掉。
local CURRENCIES = {
    { name = "专业与商业技能", isHeader = true },
    { currencyID = 3402, name = "商人青睐", quantity = 80, maxQuantity = 0,
      iconFileID = 0, isShowInBackpack = false, isHeader = false },
    { name = "Unused", isHeader = true },
    { currencyID = 1792, name = "荣誉点数", quantity = 16, maxQuantity = 0,
      iconFileID = 0, isShowInBackpack = false, isHeader = false },
}

local byID = {}
for i = 1, #CURRENCIES do
    if CURRENCIES[i].currencyID then
        byID[CURRENCIES[i].currencyID] = CURRENCIES[i]
    end
end

_G.C_CurrencyInfo = {
    GetCurrencyListSize = function() return #CURRENCIES end,
    GetCurrencyListInfo = function(i) return CURRENCIES[i] end,
    -- 客户端一枚「背包显示」都没勾：这正是背包标题行原本空白的现场。
    GetBackpackCurrencyInfo = function() return nil end,
    GetCurrencyInfo = function(id) return byID[id] end,
}
_G.GetMoney = function() return 1234567 end   -- 123g 45s 67c

local db = { infobar = {
    currencyMode = "backpack", currencyWatch = {},
    currencyMax = 3, currencyShowZero = true,
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
    DEFAULTS = { infobar = {
        currencyMode = "backpack", currencyWatch = {},
        currencyMax = 3, currencyShowZero = true,
    } },
    DB = function() return db end,
    Print = function() end,
}

local src = read("Modules/InfoBar/Currency.lua")
local chunk = assert(loader(src, "@Currency.lua"))
chunk("MonetUI", ns)
local C = ns.InfoBar.Currency
check("数据层原文可加载且挂到 InfoBar.Currency", type(C) == "table")

-- ==========================================================================
-- ① 默认态：只有金币
-- ==========================================================================
local entries, missing, mode, list = C:Snapshot()
check("默认模式仍是 backpack（不改存档语义）", mode == "backpack", mode)
check("Snapshot 首位是金币基线", entries[1] and entries[1].isGold == true
    and entries[1].name == "金币")
check("金币 display 走 g/s/c", entries[1] and entries[1].display == "123g 45s 67c",
    entries[1] and entries[1].display)
check("金币用伪 ID 0，不与真实 currencyID 冲突", entries[1] and entries[1].id == 0)
check("默认一个其它货币都不追踪（背包标题行不再空白）", #entries == 1, "#entries=" .. #entries)
check("没有读不到的监控 ID", missing == 0)
check("货币页 2 个表头被过滤，只剩 2 项真实货币", #list == 2, "#list=" .. #list)
check("BarText 含金币且不缩写", C:BarText(entries) == "金币 123g 45s 67c", C:BarText(entries))

-- ==========================================================================
-- ② 提示：可添加清单
-- ==========================================================================
local suggestions = C:Suggestions(5)
check("Suggestions 列出 2 项未监控货币（不含表头）", #suggestions == 2, "#=" .. #suggestions)
check("Suggestions 按货币页顺序，首项商人青睐 3402", suggestions[1]
    and suggestions[1].id == 3402 and suggestions[1].name == "商人青睐")
check("Suggestions 含荣誉点数 1792", suggestions[2] and suggestions[2].id == 1792)
check("Suggestions 尊重 limit", #C:Suggestions(1) == 1)

-- ==========================================================================
-- ③ 切 custom 不自动补有余额项
-- ==========================================================================
C:SetMode("custom")
check("SetMode 切到 custom", C:Mode() == "custom")
check("EnsureCustom 没把有余额项塞进 watch（作者口径）",
    #C:Watch() == 0, "#watch=" .. #C:Watch())
local afterMode = C:Snapshot()
check("切档后 Snapshot 仍只有金币", #afterMode == 1, "#entries=" .. #afterMode)

-- ==========================================================================
-- ④ 玩家自己添加：金币仍第一，货币追加在后
-- ==========================================================================
C:AddByText("1792")
check("add 1792 后 watch 只多一项", #C:Watch() == 1 and C:Watch()[1] == 1792,
    "#watch=" .. #C:Watch())
local added = C:Snapshot()
check("添加后金币仍是第一项", added[1] and added[1].isGold == true)
check("添加后共 2 项", #added == 2, "#entries=" .. #added)
check("添加后荣誉点数在金币之后", added[2] and added[2].id == 1792)
check("BarText 顺序为 金币 · 荣誉点数", C:BarText(added) == "金币 123g 45s 67c · 荣誉点数 16",
    C:BarText(added))

C:ToggleWatch(3402)
check("ToggleWatch 加入商人青睐", #C:Watch() == 2 and C:Watch()[2] == 3402)
local both = C:Snapshot()
check("两项货币 + 金币 = 3 项", #both == 3, "#entries=" .. #both)
check("金币不进 watch（伪 ID 0 未污染存档）", (function()
    for i = 1, #C:Watch() do if C:Watch()[i] == 0 then return false end end
    return true
end)())

C:RemoveByText("1792")
check("del 后 watch 只剩 3402", #C:Watch() == 1 and C:Watch()[1] == 3402)

-- ==========================================================================
-- ⑤ 机密值降级
-- ==========================================================================
_G.GetMoney = function() return "secret" end
local okSecret, secretEntries = pcall(function() return C:Snapshot() end)
check("GetMoney 读不到时不抛错", okSecret)
check("GetMoney 读不到时不插入金币", okSecret and not (secretEntries[1] and secretEntries[1].isGold))
check("GetMoney 读不到时其它货币仍在", okSecret and #secretEntries == 1,
    okSecret and ("#entries=" .. #secretEntries) or "err")
_G.GetMoney = function() return 1234567 end

-- ==========================================================================
-- 静态断言：消费方与提示文案
-- ==========================================================================
local blocks = read("Modules/InfoBar/Blocks.lua")
local bags   = read("Modules/Bags/Bags.lua")
local cfg    = read("Config/SimpleConfig.lua")
local core   = read("Core.lua")
local currencySrc = src

check("Blocks 条身过滤金币，避免与独立金钱块重复",
    blocks:find("M:BlockEnabled%(\"gold\"%)", 1, false) ~= nil
    and blocks:find("not entries%[i%]%.isGold", 1, false) ~= nil)
check("Blocks tooltip 读 display 并列可添加货币",
    blocks:find("entry.display or currency:FormatQuantity", 1, true) ~= nil
    and blocks:find("currency:Suggestions%(5%)", 1, false) ~= nil)
check("Blocks 注册 PLAYER_MONEY，金币变化即时刷",
    blocks:find("\"PLAYER_MONEY\"", 1, true) ~= nil)
check("Bags 标题行读 display",
    bags:find("entries%[i%]%.display or C:FormatQuantity", 1, false) ~= nil)
check("Currency BarText 读 display",
    currencySrc:find("entry.display or self:FormatQuantity", 1, true) ~= nil)
check("EnsureCustom 不再带「有余额的其它项」",
    currencySrc:find("有余额", 1, true) ~= nil
    and currencySrc:find("if entry%.quantity and entry%.quantity > 0 and not seen", 1, false) == nil)
check("选择面板在清单空时提示自己添加",
    currencySrc:find("默认追踪金币 · 点下面的行添加其它货币", 1, true) ~= nil)
check("斜杠命令 Usage 说明默认只追踪金币",
    currencySrc:find("默认只追踪金币；其它货币用 add", 1, true) ~= nil)
check("配置面板说明其它货币要自己添加",
    cfg:find("其它货币不自动带入", 1, true) ~= nil)
check("DEFAULTS 不写死 1792 / 3402（不替玩家选货币）",
    core:find("currencyWatch%s*=%s*{%s*}", 1, false) ~= nil
    and not core:find("currencyWatch%s*=%s*{%s*1792", 1, false))
check("数据层注释标明金币是基线条目",
    currencySrc:find("默认只追踪金币", 1, true) ~= nil)

print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
if failed > 0 then os.exit(1) end
