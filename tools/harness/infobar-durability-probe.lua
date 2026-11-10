-- infobar-durability-probe.lua
-- 「耐久」格只读回归桩（11-10 作者指示：取消点击，只保留悬停显示平均耐久）。
--   lua tools/harness/infobar-durability-probe.lua
--
-- 动态部分抽取 Blocks.lua 里 AverageDurability / DurabilityUpdate / DurabilityTooltip
-- 三个函数的**线上原文**执行（不是照抄逻辑），静态部分钉住注册规格与注释口径。

local function read(path)
    local f = assert(io.open(path, "rb"), "missing file: " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

local src = read("Modules/InfoBar/Blocks.lua")
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
-- 静态：注册规格里不许再有 onClick，也不许再提「点开角色界面」。
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
check("不再代点角色界面动作", src:find('BlockClick("character")', 1, true) == nil)
check("点击提示表不再有 character 项", src:find("character%s*=%s*\"打开角色界面\"") == nil)
check("头注写明这格只读", src:find("取消点击，不弹小菜单", 1, true) ~= nil)
check("MicroMenu 的 character 动作保留给微菜单",
    read("Modules/Minimap/MicroMenu.lua"):find("character%s*=%s*OpenCharacter") ~= nil)

-- ---------------------------------------------------------------------------
-- 动态：抽取三个函数原文，装进桩环境执行。
-- ---------------------------------------------------------------------------
local segStart = src:find("local function AverageDurability()", 1, true)
local segEnd = src:find("M:RegisterBlock({", segStart or 1, true)
check("能定位耐久度函数段", segStart ~= nil and segEnd ~= nil and segEnd > segStart)
local segment = src:sub(segStart, segEnd - 1)
check("函数段含三个目标函数",
    segment:find("local function AverageDurability", 1, true) ~= nil
    and segment:find("local function DurabilityUpdate", 1, true) ~= nil
    and segment:find("local function DurabilityTooltip", 1, true) ~= nil)

local chunk = "local M, Secrets, Tip = ...\n"
    .. segment
    .. "\nreturn AverageDurability, DurabilityUpdate, DurabilityTooltip"
local compiled, err = load(chunk, "durability-segment", "t")
check("函数段可编译", compiled ~= nil, err)

local texts, tipLines = {}, {}
local M = { SetText = function(_, _, text) texts[#texts + 1] = text end }
local Secrets = { Number = function(x) return type(x) == "number" and x or nil end }
_G.GameTooltip = {
    AddLine = function(_, text) tipLines[#tipLines + 1] = tostring(text) end,
}
local Tip = function() return _G.GameTooltip end

local avgFn, updateFn, tooltipFn = compiled(M, Secrets, Tip)
check("三个函数都导出", type(avgFn) == "function" and type(updateFn) == "function"
    and type(tooltipFn) == "function")

local function setBags(slots, durability)
    _G.C_Container = {
        GetContainerNumSlots = function(bag) return slots[bag] or 0 end,
        GetContainerItemDurability = function(bag, slot)
            local row = durability[bag]
            local item = row and row[slot]
            if not item then return nil end
            return item[1], item[2]
        end,
    }
end

-- 两件：50/100 与 100/100 ⇒ 平均 75%，取件数 2。
setBags({ [0] = 2 }, { [0] = { { 50, 100 }, { 100, 100 } } })
local avg, count = avgFn()
check("平均耐久 = 75%（50% 与 100% 取件平均）", avg == 75 and count == 2,
    "avg=" .. tostring(avg) .. " count=" .. tostring(count))
local block = {}
updateFn(block)
check("条身显示 75%", texts[#texts] == "75%", texts[#texts])
check("平均值与件数缓存在注册表上", block.avgPercent == 75 and block.avgCount == 2)
tipLines = {}
tooltipFn(block)
local tipText = table.concat(tipLines, " | ")
check("悬停显示平均耐久与取件数", tipText:find("平均耐久 75%", 1, true) ~= nil
    and tipText:find("2 件取件平均", 1, true) ~= nil, tipText)
check("悬停不再出现点击提示", tipText:find("点击：", 1, true) == nil, tipText)
check("悬停仍有标题与修理说明",
    tipText:find("装备耐久", 1, true) ~= nil and tipText:find("修理越贵", 1, true) ~= nil)

-- 一件都读不出：条身清空、tooltip 给诚实降级。
setBags({ [0] = 0 }, {})
local avg2, count2 = avgFn()
check("空背包返回 nil", avg2 == nil and count2 == nil)
texts = {}
updateFn(block)
check("空背包条身清空", texts[#texts] == "" and block.avgPercent == nil)
tipLines = {}
tooltipFn(block)
check("空背包悬停显示「读不出」",
    table.concat(tipLines, " | "):find("平均耐久：读不出", 1, true) ~= nil)

-- API 缺失不抛。
_G.C_Container = nil
local okMissing, avg3 = pcall(avgFn)
check("C_Container 缺失时安全返回 nil", okMissing and avg3 == nil, tostring(avg3))

-- 机密值：Secrets.Number 过滤掉非数字，不许当成 0 拉低平均。
setBags({ [0] = 2 }, { [0] = { { {}, 100 }, { 100, 100 } } })
local avg4, count4 = avgFn()
check("机密 current 被过滤，只剩有效件", avg4 == 100 and count4 == 1,
    "avg=" .. tostring(avg4) .. " count=" .. tostring(count4))

print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
os.exit(failed == 0 and 0 or 1)
