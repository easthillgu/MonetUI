-- infobar-durability-probe.lua
-- 「耐久」格回归桩（11-26 改口径：按**槽位**读身上那套，提示给「总评 → 最低 → 逐件」，
-- 数据源统一走 `Modules/Tools/Durability.lua` 的 `M:Scan()`）。
--   lua tools/harness/infobar-durability-probe.lua
--
-- 动态部分抽取 Blocks.lua 里 DurabilityData / DurabilityLevelColor / DurabilityUpdate /
-- DurabilityTooltip 四个函数的**线上原文**执行（不是照抄逻辑），静态部分钉住注册规格与口径。

local function read(path)
    local f = assert(io.open(path, "rb"), "missing file: " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

local src = read("Modules/InfoBar/Blocks.lua")
local toolsSrc = read("Modules/Tools/Durability.lua")
local passed, failed = 0, 0
local function check(name, ok, extra)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. (extra and ("  [" .. tostring(extra) .. "]") or ""))
    end
end

-- ---------------------------------------------------------------------------
-- 静态：注册规格不注册 onClick；口径是槽位读取；探测只有 Tools 一份。
-- ---------------------------------------------------------------------------
local function codeOnly(s)
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = (line:gsub("%-%-.*$", ""))
    end
    return table.concat(out, "\n")
end
local specA = src:find('key      = "durability"', 1, true)
local spec = specA and codeOnly(src:sub(specA, (src:find("\n})", specA, true) or specA) + 3)) or ""
check("找到 durability 注册规格", specA ~= nil)
check("注册规格不注册 onClick（注释不算）", spec:find("onClick") == nil, spec)
check("注册规格仍保留 update / tooltip",
    spec:find("update%s*=%s*DurabilityUpdate") ~= nil
    and spec:find("tooltip%s*=%s*DurabilityTooltip") ~= nil)
check("换装也触发刷新（PLAYER_EQUIPMENT_CHANGED）",
    spec:find("PLAYER_EQUIPMENT_CHANGED") ~= nil)
check("不再扫背包物品的耐久（C_Container.GetContainerItemDurability 已撤，注释不算）",
    codeOnly(src):find("GetContainerItemDurability") == nil)
check("数据源是 Tools 模块（一处判据一份实现）",
    src:find("ns.Durability", 1, true) ~= nil and src:find("mod.Scan", 1, true) ~= nil)
check("Tools 模块导出 Scan / ScanBags / Signature / SLOTS",
    toolsSrc:find("function M:Scan()", 1, true) ~= nil
    and toolsSrc:find("function M:ScanBags()", 1, true) ~= nil
    and toolsSrc:find("function M:Signature()", 1, true) ~= nil
    and toolsSrc:find("M.SLOTS = SLOTS", 1, true) ~= nil)
check("兜底数据源写明是背包（本客户端没有已装备耐久 API）",
    src:find("mod.ScanBags", 1, true) ~= nil
    and toolsSrc:find('source = "bags"', 1, true) ~= nil)
check("工具模块的背包扫描只认耐久列（不扫空格子）",
    toolsSrc:find("GetContainerItemDurability", 1, true) ~= nil
    and toolsSrc:find("if current and maximum and maximum > 0 then", 1, true) ~= nil)
check("Tools 的形态探测要求读出数字（不再只认 pcall 成功）",
    toolsSrc:find("if current then\n            mode = kind", 1, true) ~= nil)
check("头注写明这格只读", src:find("取消点击，不弹小菜单", 1, true) ~= nil)
check("MicroMenu 的 character 动作保留给微菜单",
    read("Modules/Minimap/MicroMenu.lua"):find("character%s*=%s*OpenCharacter") ~= nil)

-- ---------------------------------------------------------------------------
-- 动态：抽取四个函数原文，装进桩环境执行。
-- ---------------------------------------------------------------------------
local segStart = src:find("local function DurabilityData()", 1, true)
local segEnd = src:find("M:RegisterBlock({", segStart or 1, true)
check("能定位耐久度函数段", segStart ~= nil and segEnd ~= nil and segEnd > segStart)
local segment = src:sub(segStart, segEnd - 1)
check("函数段含四个目标函数",
    segment:find("local function DurabilityData", 1, true) ~= nil
    and segment:find("local function DurabilityLevelColor", 1, true) ~= nil
    and segment:find("local function DurabilityUpdate", 1, true) ~= nil
    and segment:find("local function DurabilityTooltip", 1, true) ~= nil)

local chunk = "local M, ns, Tip = ...\n"
    .. segment
    .. "\nreturn DurabilityData, DurabilityLevelColor, DurabilityUpdate, DurabilityTooltip"
local compiled, err = load(chunk, "durability-segment", "t")
check("函数段可编译", compiled ~= nil, err)

local texts, tipLines = {}, {}
local M = { SetText = function(_, _, text) texts[#texts + 1] = text end }
local ns = {
    Color = {
        GetDanger  = function() return 0.9, 0.2, 0.2 end,
        GetPrimary = function() return 0.8, 0.65, 0.76 end,
    },
}
-- 桩：Tools/Durability 按**背包兜底**给数据（本客户端的实际情形），
-- 两件：旧头盔 50%（最低）/ 厚胸甲 100%，总评 75%。
local bagScan = {
    source = "bags", percent = 75, lowest = 50, lowestName = "旧头盔", count = 2,
    items = {
        { bag = 0, slot = 1, name = "旧头盔", pct = 50 },
        { bag = 0, slot = 2, name = "厚胸甲", pct = 100 },
    },
}
ns.Durability = {
    Scan = function() return nil end,     -- 槽位 API 在本客户端不存在
    ScanBags = function() return bagScan end,
}
_G.GameTooltip = {
    AddLine = function(_, text) tipLines[#tipLines + 1] = tostring(text) end,
    AddDoubleLine = function(_, left, right) tipLines[#tipLines + 1] = tostring(left) .. " = " .. tostring(right) end,
}
local Tip = function() return _G.GameTooltip end

local dataFn, colorFn, updateFn, tooltipFn = compiled(M, ns, Tip)
check("四个函数都导出", type(dataFn) == "function" and type(colorFn) == "function"
    and type(updateFn) == "function" and type(tooltipFn) == "function")

local block = {}
updateFn(block)
check("条身显示总评 75%", texts[#texts] == "75%", texts[#texts])
check("扫描结果缓存在注册表上（悬停不必再扫）", block.durData == bagScan)

tipLines = {}
tooltipFn(block)
local tipText = table.concat(tipLines, " | ")
check("兜底时提示写明数据源是背包", tipText:find("数据源：背包内物品", 1, true) ~= nil, tipText)
check("悬停给总评与件数", tipText:find("总评 75%", 1, true) ~= nil
    and tipText:find("2 件取平均", 1, true) ~= nil, tipText)
check("悬停单列最低那件", tipText:find("最低：旧头盔 = 50%", 1, true) ~= nil, tipText)
check("悬停列出逐件（最该修的在前）",
    tipText:find("旧头盔 = 50%", 1, true) ~= nil and tipText:find("厚胸甲 = 100%", 1, true) ~= nil
    and tipText:find("旧头盔", 1, true) < tipText:find("厚胸甲", 1, true), tipText)
check("悬停不再出现点击提示", tipText:find("点击：", 1, true) == nil, tipText)
check("悬停仍有标题与修理说明",
    tipText:find("装备耐久", 1, true) ~= nil and tipText:find("修理越贵", 1, true) ~= nil)

-- 槽位路径可用时不加「背包」那行（以后客户端若补回 API，提示自动变干净）。
local slotScan = { source = "slots", percent = 80, lowest = 40, lowestName = "护腕", count = 1,
    items = { { slot = 9, name = "护腕", pct = 40 } } }
ns.Durability.Scan = function() return slotScan end
block.durData = nil
tipLines = {}
tooltipFn(block)   -- 没有缓存 → 现场取一次（走 Scan）
local slotText = table.concat(tipLines, " | ")
check("槽位路径不再写「数据源：背包」", slotText:find("数据源：背包", 1, true) == nil, slotText)
check("槽位路径照样列逐件", slotText:find("护腕 = 40%", 1, true) ~= nil, slotText)
ns.Durability.Scan = function() return nil end

-- 分级配色：<30 危险红 / <60 主色 / 其余白。
local dr, dg = colorFn(20)
local pr, pg = colorFn(45)
local wr, wg = colorFn(90)
check("20% 走危险红", dr == 0.9 and dg == 0.2, tostring(dr) .. "," .. tostring(dg))
check("45% 走主题主色", pr == 0.8 and pg == 0.65, tostring(pr) .. "," .. tostring(pg))
check("90% 走白", wr == 1 and wg == 1, tostring(wr) .. "," .. tostring(wg))

-- 读不出：两条数据源都空 → 条身清空、tooltip 给诚实降级。
ns.Durability.Scan = function() return nil end
ns.Durability.ScanBags = function() return nil end
texts = {}
updateFn(block)
check("读不出时条身清空", texts[#texts] == "" and block.durData == nil)
tipLines = {}
tooltipFn(block)
check("读不出时悬停说「读不出」",
    table.concat(tipLines, " | "):find("读不出耐久", 1, true) ~= nil)

-- 模块缺失 / 两条数据源都抛错都不许把格子带崩。
ns.Durability = nil
local okMissing, missingData = pcall(dataFn)
check("Tools 模块缺失时安全返回 nil", okMissing and missingData == nil, tostring(missingData))
ns.Durability = {
    Scan = function() error("boom") end,
    ScanBags = function() error("boom") end,
}
local okError, errorData = pcall(dataFn)
check("两条数据源都抛错时被 pcall 兜住", okError and errorData == nil, tostring(errorData))

print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
os.exit(failed == 0 and 0 or 1)
