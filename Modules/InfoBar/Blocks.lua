-- Modules/InfoBar/Blocks.lua
-- The eight data blocks the strip can carry (money, durability, currency, system, spec, friends, quest, stats).
-- Every value is read defensively: secret numbers go through Utils/Secrets.lua first, and a missing or unfit call simply leaves its block empty. Money formatting and the durability probe are ours, not copied from any reference addon.

local ADDON_NAME, ns = ...
local M = ns.InfoBar
if not M then return end

local Secrets = ns.Secrets
local Widget  = ns.Widget

local function Tip()
    return _G.GameTooltip
end

--- 格子点击动作的**唯一入口**：动作本体住在 `MicroMenu.lua` 的 `M.actions`（11-07 抽成函数），
--- 信息栏这里只按名字取，**不抄第二份开窗逻辑**（AGENTS：一处判据一份实现）。
---
--- 映射按"数据住在哪"来定，不是随手分配：
---   金钱 / 耐久 / 货币 → **我们自己的背包窗**（钱数就显示在背包窗底部，而耐久与代币的数据
---     本来就只能从背包物品读 —— 见本文件 `DurabilityUpdate` 上方那条 1.60 API 限制注释）；
---   延迟/帧率/内存 → **设置**（`Settings.OpenToCategory`，纯 C_*，无暴雪 Lua 链）；
---   专精 / 任务 / 好友 → **先开代点坞**（`MicroMenuSecure`），第二击才到面板。
---     这三格要开的暴雪面板**没有纯 C_* 开口**，而信息栏是"内容驱动排版"的框 ——
---     它永远不能挂安全模板（AGENTS 硬判据 / HANDOFF §8.64），所以走坞，不走格子直连。
--- 坞自己锚在小地图旁、与信息栏没有锚定关系 ⇒ 这条路不会把信息栏标成受保护。
--- 提示行用的文案（动作名 → 一句话）。信息栏的提示层读 `block.onClick.hint`，
--- 一处集中、不用给 7 个注册表各加一个字段。
local CLICK_HINT = {
    bags     = "打开背包",
    settings = "打开设置",
    dock     = "打开快捷入口（角色 / 任务 / 好友 / 天赋 …）",
}

local function BlockClick(actionName)
    return setmetatable({ hint = CLICK_HINT[actionName] or actionName }, {
        __call = function(_, _, button)
            if button ~= "LeftButton" then return end
            local minimap = ns:GetModule("Minimap")
            local actions = minimap and minimap.microMenu and minimap.microMenu.actions
            local fn = actions and actions[actionName]
            if type(fn) == "function" then pcall(fn) end
        end,
    })
end

-- `GetMoneyString` is not in this client's API manual, so the formatting is done here rather than assumed.
local function FormatMoney(copper)
    copper = Secrets.Number(copper)
    if not copper then return nil end

    copper = math.floor(copper)
    local gold   = math.floor(copper / 10000)
    local silver = math.floor(copper / 100) % 100
    local small  = copper % 100

    if gold > 0 then
        return string.format("%dg %ds %dc", gold, silver, small)
    elseif silver > 0 then
        return string.format("%ds %dc", silver, small)
    end
    return string.format("%dc", small)
end

local sessionEarned, sessionSpent, lastMoney = 0, 0, nil

local function GoldUpdate(block)
    if type(_G.GetMoney) ~= "function" then M:SetText(block, "") return end

    local now = Secrets.Number(_G.GetMoney())
    if not now then M:SetText(block, "") return end

    if lastMoney then
        local delta = now - lastMoney
        if delta > 0 then
            sessionEarned = sessionEarned + delta
        elseif delta < 0 then
            sessionSpent = sessionSpent - delta
        end
    end
    lastMoney = now

    M:SetText(block, FormatMoney(now))
end

local function GoldTooltip()
    local tip = Tip()
    if not tip then return end

    pcall(tip.AddLine, tip, "金钱", 0.6, 0.8, 1)
    pcall(tip.AddDoubleLine, tip, "本次会话收入", FormatMoney(sessionEarned) or "-", 1, 1, 1, 1, 1, 1)
    pcall(tip.AddDoubleLine, tip, "本次会话支出", FormatMoney(sessionSpent) or "-", 1, 1, 1, 1, 1, 1)

    local net = sessionEarned - sessionSpent
    local r, g, b = 1, 1, 1
    if net > 0 then r, g, b = 0, 1, 0 elseif net < 0 then r, g, b = 1, 0, 0 end
    pcall(tip.AddDoubleLine, tip, "净额", FormatMoney(math.abs(net)) or "-", r, g, b, 1, 1, 1)
end

M:RegisterBlock({
    key      = "gold",
    label    = "金钱",
    position = "LEFT",
    events   = { "PLAYER_ENTERING_WORLD", "PLAYER_MONEY" },
    update   = GoldUpdate,
    tooltip  = GoldTooltip,
    onClick  = BlockClick("bags"),   -- 钱数就显示在背包窗底部
})

-- 1.60 客户端的耐久 API 只支持背包物品：C_Container.GetContainerItemDurability(containerIndex, slotIndex)
-- containerIndex: 0-4（角色背包 + 4 个背包）
-- slotIndex: 背包内的槽位
-- 已装备物品的耐久无法直接查询，需要实机验证是否有其他 API。
local function DurabilityUpdate(block)
    local api = _G.C_Container
    if not api or type(api.GetContainerItemDurability) ~= "function" then
        M:SetText(block, "")
        return
    end
    
    local sum, count = 0, 0
    
    -- 遍历 5 个背包（0 = 角色背包，1-4 = 额外背包）
    for bagIndex = 0, 4 do
        local numSlotsFn = api.GetContainerNumSlots
        if type(numSlotsFn) ~= "function" then break end
        
        local okSlots, numSlots = pcall(numSlotsFn, bagIndex)
        if not okSlots or not numSlots or numSlots < 1 then break end
        numSlots = Secrets.Number(numSlots)
        if not numSlots or numSlots < 1 then break end
        
        -- 遍历背包内的每个槽位
        for slotIndex = 1, numSlots do
            local ok, current, maximum = pcall(api.GetContainerItemDurability, bagIndex, slotIndex)
            if ok and current and maximum then
                current, maximum = Secrets.Number(current), Secrets.Number(maximum)
                if current and maximum and maximum > 0 then
                    sum = sum + current / maximum
                    count = count + 1
                end
            end
        end
    end
    
    if count == 0 then
        M:SetText(block, "")
        return
    end
    
    M:SetText(block, string.format("%.0f%%", sum / count * 100))
end

local function DurabilityTooltip()
    local tip = Tip()
    if not tip then return end
    pcall(tip.AddLine, tip, "装备耐久", 0.6, 0.8, 1)
    pcall(tip.AddLine, tip, "取件平均值；数值越低修理越贵。", 0.8, 0.8, 0.8)
end

M:RegisterBlock({
    key      = "durability",
    label    = "耐久",
    position = "LEFT",
    events   = { "UPDATE_INVENTORY_DURABILITY", "PLAYER_ENTERING_WORLD" },
    update   = DurabilityUpdate,
    tooltip  = DurabilityTooltip,
    onClick  = BlockClick("bags"),   -- 耐久数据本来就只能从背包物品读
})

-- Retail's "watched" flag has no equivalent here; `isShowInBackpack` (the currency shown beside the gold in the bag bar) is the closest and is used instead.
local function WatchedCurrencies()
    local api = _G.C_CurrencyInfo
    if not api then return nil end
    if type(api.GetCurrencyListSize) ~= "function" then return nil end
    if type(api.GetCurrencyListInfo) ~= "function" then return nil end

    local ok, size = pcall(api.GetCurrencyListSize)
    if not ok then return nil end
    size = Secrets.Number(size)
    if not size or size < 1 then return nil end

    local list = {}
    for i = 1, size do
        local okInfo, info = pcall(api.GetCurrencyListInfo, i)
        -- 字段是机密布尔时 `not info.isHeader` / `info.isShowInBackpack` 一次真值测试就被拦
        -- （ADDON_ACTION_BLOCKED UNKNOWN()）—— 走唯一的漏斗 Secrets.Bool。
        if okInfo and type(info) == "table"
            and not Secrets.Bool(info.isHeader, false)
            and Secrets.Bool(info.isShowInBackpack, false) then
            local name = info.name
            local quantity = Secrets.Number(info.quantity)
            -- name 之后要进 string.format / table.concat：type() 判不出机密串，必须再过 IsSecret。
            if type(name) == "string" and not Secrets.IsSecret(name) and quantity then
                list[#list + 1] = {
                    name     = name,
                    quantity = quantity,
                    maximum  = Secrets.Number(info.maxQuantity),
                }
            end
        end
    end
    return list
end

local function CurrencyUpdate(block)
    local list = WatchedCurrencies()
    if not list or #list == 0 then M:SetText(block, "") return end

    local parts = {}
    for i = 1, math.min(#list, 2) do
        parts[#parts + 1] = string.format("%s %d", list[i].name, list[i].quantity)
    end
    M:SetText(block, table.concat(parts, " · "))
end

local function CurrencyTooltip()
    local tip = Tip()
    if not tip then return end

    local list = WatchedCurrencies()
    if not list or #list == 0 then
        pcall(tip.AddLine, tip, "没有标记为背包显示的货币。", 0.8, 0.8, 0.8)
        return
    end

    pcall(tip.AddLine, tip, "货币", 0.6, 0.8, 1)
    for i = 1, #list do
        local entry = list[i]
        local value = string.format("%d / %s", entry.quantity,
            entry.maximum and string.format("%d", entry.maximum) or "-")
        pcall(tip.AddDoubleLine, tip, entry.name, value, 1, 1, 1, 1, 1, 1)
    end
end

M:RegisterBlock({
    key      = "currency",
    label    = "货币",
    position = "LEFT",
    events   = { "CURRENCY_DISPLAY_UPDATE", "PLAYER_ENTERING_WORLD" },
    update   = CurrencyUpdate,
    tooltip  = CurrencyTooltip,
    onClick  = BlockClick("bags"),   -- 代币/货币的实物就在背包里，钱数也显示在那扇窗底部
})

local function Latency()
    if type(_G.GetNetStats) ~= "function" then return nil end
    -- The third return is typed `number` in this client's manual (not a table), so it can be used directly -- but it still goes through Secrets.
    local ok, _, _, ms = pcall(_G.GetNetStats)
    if not ok then return nil end
    ms = Secrets.Number(ms)
    return ms and math.floor(ms + 0.5) or nil
end

local function Framerate()
    if type(_G.GetFramerate) ~= "function" then return nil end
    local ok, value = pcall(_G.GetFramerate)
    if not ok then return nil end
    value = Secrets.Number(value)
    return value and math.floor(value + 0.5) or nil
end

-- No "total addon memory" call exists: the total is summed from `GetAddOnMemoryUsage(name)`, and the count/name calls live in `C_AddOns` -- the bare globals of that name do not exist on this client.
local function MemoryUsage()
    local api = _G.C_AddOns
    if not api then return nil end

    local numFn    = api.GetNumAddOns
    local nameFn   = api.GetAddOnName
    local usageFn  = _G.GetAddOnMemoryUsage
    if type(numFn) ~= "function" then return nil end
    if type(nameFn) ~= "function" then return nil end
    if type(usageFn) ~= "function" then return nil end

    local okCount, count = pcall(numFn)
    if not okCount then return nil end
    count = Secrets.Number(count)
    if not count or count < 1 then return nil end

    if type(_G.UpdateAddOnMemoryUsage) == "function" then
        pcall(_G.UpdateAddOnMemoryUsage)
    end

    local total = 0
    for i = 1, count do
        local okName, name = pcall(nameFn, i)
        if okName and type(name) == "string" then
            local okUsage, kb = pcall(usageFn, name)
            if okUsage then
                kb = Secrets.Number(kb)
                if kb then total = total + kb end
            end
        end
    end
    return total > 0 and total or nil
end

local function SystemUpdate(block)
    local parts = {}

    local latency = Latency()
    if latency then parts[#parts + 1] = string.format("%dms", latency) end

    local fps = Framerate()
    if fps then parts[#parts + 1] = string.format("%d FPS", fps) end

    -- Summing every addon takes a real pass, so it is cached and only redone every fifth tick (see SystemOnUpdate).
    if block.memory then
        parts[#parts + 1] = string.format("%.1fM", block.memory / 1024)
    end

    M:SetText(block, table.concat(parts, " · "))
end

local function SystemOnUpdate(block, elapsed)
    block.tick = (block.tick or 0) + elapsed
    if block.tick < 1 then return end
    block.tick = 0

    block.memoryTick = (block.memoryTick or 4) + 1
    if block.memoryTick >= 5 then
        block.memoryTick = 0
        block.memory = MemoryUsage()
    end

    M:RefreshBlock("system")
end

local function SystemTooltip(block)
    local tip = Tip()
    if not tip then return end

    pcall(tip.AddLine, tip, "系统", 0.6, 0.8, 1)
    local latency = Latency()
    if latency then pcall(tip.AddDoubleLine, tip, "延迟", latency .. " ms", 1, 1, 1, 1, 1, 1) end
    local fps = Framerate()
    if fps then pcall(tip.AddDoubleLine, tip, "帧率", fps .. " FPS", 1, 1, 1, 1, 1, 1) end
    if block.memory then
        pcall(tip.AddDoubleLine, tip, "插件内存", string.format("%.1f MB", block.memory / 1024), 1, 1, 1, 1, 1, 1)
    end
end

M:RegisterBlock({
    key      = "system",
    label    = "延迟 / 帧率 / 内存",
    position = "RIGHT",
    events   = { "PLAYER_ENTERING_WORLD" },
    update   = SystemUpdate,
    tooltip  = SystemTooltip,
    onUpdate = SystemOnUpdate,
    onClick  = BlockClick("settings"),   -- 纯 C_*：`Settings.OpenToCategory`
})

local function CurrentSpecIndex()
    local api = _G.C_SpecializationInfo
    if not api or type(api.GetSpecialization) ~= "function" then return nil end

    local ok, index = pcall(api.GetSpecialization)
    if not ok then return nil end
    index = Secrets.Number(index)
    if not index or index < 1 then return nil end
    return index
end

local function ClassID()
    -- Identity is one of the values the client may hide; without it the spec list cannot be enumerated, so the block degrades to just the current name.
    if not Secrets.CanReadIdentity("player") then return nil end
    if type(_G.UnitClass) ~= "function" then return nil end

    local ok, _, _, id = pcall(_G.UnitClass, "player")
    if not ok then return nil end
    return Secrets.Number(id)
end

local function SpecUpdate(block)
    local api = _G.C_SpecializationInfo
    if not api or type(api.GetSpecializationInfo) ~= "function" then
        M:SetText(block, "")
        return
    end

    local index = CurrentSpecIndex()
    if not index then M:SetText(block, "") return end

    -- Returns: specId, name, description, icon, role, ...
    local ok, _, name = pcall(api.GetSpecializationInfo, index, false, false)
    if not ok or type(name) ~= "string" or name == "" then
        M:SetText(block, "")
        return
    end

    M:SetText(block, name)
end

local ROLE_TEXT = { TANK = "坦克", HEALER = "治疗", DAMAGER = "输出" }

local function SpecTooltip()
    local tip = Tip()
    if not tip then return end

    local api = _G.C_SpecializationInfo
    local classID = ClassID()
    if not api or not classID
       or type(api.GetNumSpecializationsForClassID) ~= "function" then
        pcall(tip.AddLine, tip, "专精", 0.6, 0.8, 1)
        return
    end

    local okCount, count = pcall(api.GetNumSpecializationsForClassID, classID)
    if not okCount then return end
    count = Secrets.Number(count)
    if not count or count < 1 then return end

    local current = CurrentSpecIndex()
    pcall(tip.AddLine, tip, "专精", 0.6, 0.8, 1)

    for i = 1, count do
        local ok, _, name, _, _, role = pcall(api.GetSpecializationInfo,
            i, false, false, nil, nil, nil, classID)
        if ok and type(name) == "string" then
            local isCurrent = (i == current)
            local r, g, b = isCurrent and 0 or 1, isCurrent and 1 or 1, isCurrent and 0 or 1
            pcall(tip.AddDoubleLine, tip,
                (isCurrent and "> " or "") .. name,
                ROLE_TEXT[role] or "", r, g, b, 0.8, 0.8, 0.8)
        end
    end
end

M:RegisterBlock({
    key      = "spec",
    label    = "专精",
    position = "RIGHT",
    events   = { "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_ENTERING_WORLD" },
    update   = SpecUpdate,
    tooltip  = SpecTooltip,
    onClick  = BlockClick("dock"),   -- 专精→天赋面板没有纯 C_* 开口：先开代点坞，第二击到面板
})

local function FriendsUpdate(block)
    local api = _G.C_FriendList
    if not api then M:SetText(block, "") return end

    local total, online
    if type(api.GetNumFriends) == "function" then
        local ok, value = pcall(api.GetNumFriends)
        if ok then total = Secrets.Number(value) end
    end
    if type(api.GetNumOnlineFriends) == "function" then
        local ok, value = pcall(api.GetNumOnlineFriends)
        if ok then online = Secrets.Number(value) end
    end

    -- Both are marked "RequiresFriendList": before Blizzard loads the list they read as zero; an entirely unavailable pair hides the block instead.
    if total == nil and online == nil then M:SetText(block, "") return end
    M:SetText(block, string.format("%d / %d", online or 0, total or 0))
end

local function FriendsTooltip()
    local tip = Tip()
    if not tip then return end
    pcall(tip.AddLine, tip, "好友", 0.6, 0.8, 1)
    pcall(tip.AddLine, tip, "在线 / 总数", 1, 1, 1)
    -- Names deliberately not listed: this build's C_FriendList.GetFriendInfo takes a *name* where retail takes an index, and guessing would mean guessing at someone else's data.
end

M:RegisterBlock({
    key      = "friends",
    label    = "好友",
    position = "RIGHT",
    events   = { "FRIENDLIST_UPDATE", "PLAYER_ENTERING_WORLD" },
    update   = FriendsUpdate,
    tooltip  = FriendsTooltip,
    onClick  = BlockClick("dock"),   -- 好友/社区窗没有纯 C_* 开口：先开代点坞
})

-- =========================================================================
-- 任务（Quest）
-- =========================================================================

local function QuestUpdate(block)
    local api = _G.C_QuestLog
    if not api or type(api.GetNumQuestLogEntries) ~= "function" then
        M:SetText(block, "")
        return
    end
    
    local ok, numEntries = pcall(api.GetNumQuestLogEntries)
    if not ok then
        M:SetText(block, "")
        return
    end
    
    numEntries = Secrets.Number(numEntries)
    if not numEntries then
        M:SetText(block, "")
        return
    end
    
    M:SetText(block, string.format("%d", numEntries))
end

local function QuestTooltip()
    local tip = Tip()
    if not tip then return end
    
    local api = _G.C_QuestLog
    if not api then return end
    
    pcall(tip.AddLine, tip, "任务日志", 0.6, 0.8, 1)
    
    local ok, numShown, numTotal = pcall(api.GetNumQuestLogEntries)
    if ok then
        numShown = Secrets.Number(numShown)
        numTotal = Secrets.Number(numTotal)
        
        if numShown and numTotal then
            pcall(tip.AddDoubleLine, tip, "显示任务", string.format("%d", numShown), 1, 1, 1, 1, 1, 1)
            pcall(tip.AddDoubleLine, tip, "总任务数", string.format("%d", numTotal), 1, 1, 1, 1, 1, 1)
        elseif numShown then
            pcall(tip.AddLine, tip, string.format("当前任务: %d", numShown), 1, 1, 1)
        else
            pcall(tip.AddLine, tip, "没有活跃任务", 0.8, 0.8, 0.8)
        end
    else
        pcall(tip.AddLine, tip, "无法读取任务日志", 0.8, 0.8, 0.8)
    end
end

M:RegisterBlock({
    key      = "quest",
    label    = "任务",
    position = "RIGHT",
    events   = { "QUEST_LOG_UPDATE", "PLAYER_ENTERING_WORLD" },
    update   = QuestUpdate,
    tooltip  = QuestTooltip,
    onClick  = BlockClick("dock"),   -- 任务日志没有纯 C_* 开口：先开代点坞
})

-- =========================================================================
-- 属性（Stats）
-- =========================================================================
-- 按职业 + 专精把玩家归到三类之一，分别显示对应的四项：
--   法系输出：命中 / 法强 / 暴击 / 穿透（有值才显示）
--   坦克    ：躲闪 / 招架 / 格挡 / 护甲减伤
--   物理输出：命中 / AP / 暴击
-- 每个 API 都 pcall + Secrets.Number，读不到就跳过这一行；分类失败整块空。
-- 属性来源与 StatsPro_Forever 一致（本客户端所有 Unit*/Get* 都带
-- SecretWhenUnitStatsRestricted 标记，脱战能读、战斗/副本可能变 nil）。

-- 坦克 / 法系 / 物理 三档的判定 —— **不写职业表**（2026-11-03 修）。
--
-- 这里原本是一张按 classID **数字**排的 SPEC_CATEGORY，而那套编号是照"1.60 只有九职业"
-- 的**猜测**排的。12.1.5 实机一测就翻车（历史证据，cd1f6d7 正文；classID 跨客户端不共享，1.60 上盗贼归类待复验）：`UnitClass("player")` 返回 `潜行者 / ROGUE / classID=4`，
-- 盗贼是 **4** 不是 3 —— 于是盗贼查到了**德鲁伊**那一行（spec 2 = "tank"），
-- 狂徒贼被显示成坦克。职业 ID 在不同客户端里本来就不是同一套编号，写死必然踩雷；
-- 专精顺序同样是客户端说了算（德鲁伊在零售有 4 个专精，老表只有 3 格）。
--
-- 改成读客户端自己的事实，一张表都不需要：
--   1. `GetSpecializationInfo(GetSpecialization())` 第 5 个返回值 `role`
--      = "TANK" / "HEALER" / "DAMAGER" —— 客户端最清楚这个专精是干什么的；
--   2. 非坦克按**主属性**分法系 / 物理：智力最高 = 法系（治疗也归这里，智力 + 法强，
--      符合"坦克 / 法系 / 其余"的三分法），否则 = 物理。
-- role 读不到（受限状态、或客户端没这套数据）就只按主属性判 —— 最坏也是"物理"，
-- 不会再出现"盗贼 = 坦克"这种把人吓一跳的结论。

-- 属性档位枚举：**优先读客户端自己的 LE_UNIT_STAT_* 全局**，读不到才退回下面的硬编码值
-- （退化值与旧表逐位一致，拿不到全局的客户端行为不变）。手写数字表在枚举序不同的客户端上
-- 会整排错位（耐力当智力 → 坦克/法系/物理全档错），口径同 `cd1f6d7`（不靠自造表猜档位）。
local LE_UNIT_STAT_STRENGTH  = _G.LE_UNIT_STAT_STRENGTH or 1
local LE_UNIT_STAT_AGILITY   = _G.LE_UNIT_STAT_AGILITY or 2
local LE_UNIT_STAT_INTELLECT = _G.LE_UNIT_STAT_INTELLECT or 4

-- pcall 一个函数，把第 n 个返回值走 Secrets.Number（读不到 → nil）。
local function ReadNth(fn, n, ...)
    if type(fn) ~= "function" then return nil end
    local pack = { pcall(fn, ...) }
    if not pack[1] then return nil end
    return Secrets.Number(pack[n + 1])
end

-- 同一 API 的前 count 个返回值累加（UnitAttackPower 的 base / posBuff / negBuff）。
local function SumNth(fn, from, count, ...)
    if type(fn) ~= "function" then return nil end
    local pack = { pcall(fn, ...) }
    if not pack[1] then return nil end
    local total = 0
    for i = from, from + count - 1 do
        local v = Secrets.Number(pack[i + 1])
        if not v then return nil end
        total = total + v
    end
    return total
end

-- 命中 = GetCombatRatingBonus(rating) + 对应的 *HitModifier（两个百分比相加）。
-- rating 常量是本客户端的全局数字（CR_HIT_MELEE 等），拿不到就整行跳过。
local function HitRating(ratingName, modifierName)
    local rating = _G[ratingName]
    if type(rating) ~= "number" then return nil end
    local bonus = ReadNth(_G.GetCombatRatingBonus, 1, rating)
    local mod   = ReadNth(_G[modifierName], 1)
    if not bonus or not mod then return nil end
    return bonus + mod
end

local function SpellHit()   return HitRating("CR_HIT_SPELL", "GetSpellHitModifier") end
local function MeleeHit()   return HitRating("CR_HIT_MELEE", "GetHitModifier")      end
local function MeleeCrit()  return ReadNth(_G.GetCritChance, 1)                     end
local function SpellCrit()  return ReadNth(_G.GetSpellCritChance, 1)                end
local function SpellPen()   return ReadNth(_G.GetSpellPenetration, 1)               end
local function Dodge()      return ReadNth(_G.GetDodgeChance, 1)                    end
local function Parry()      return ReadNth(_G.GetParryChance, 1)                    end
local function Block()      return ReadNth(_G.GetBlockChance, 1)                    end

-- UnitAttackPower 返回 (base, posBuff, negBuff)；三者相加与角色面板对齐，客户端允许负 buff（虚弱等 debuff）
-- 时钳到 0，与 StatsPro 的 Nonnegative 一致。
local function MeleeAP()
    local total = SumNth(_G.UnitAttackPower, 1, 3, "player")
    if not total then return nil end
    return math.max(0, total)
end

-- 六系法强取最大值：Holy=2 / Fire=3 / Nature=4 / Frost=5 / Shadow=6 / Arcane=7（StatsPro 同款 school 索引）。
-- 不猜专精对应哪系，直接给"你能打出的最高那一系"；对多系职业（战斗/惩戒圣骑士、平衡德）尤其合适。
local function BestSpellPower()
    local best
    for school = 2, 7 do
        local v = ReadNth(_G.GetSpellBonusDamage, 1, school)
        if v and (not best or v > best) then best = v end
    end
    return best
end

-- 护甲减伤：优先用 C_PaperDollInfo.GetArmorEffectiveness（返回伤害倍率，1 - 倍率 = 减伤）；
-- 客户端没这条 API 时退回经典公式 armor / (armor + 400 + 85 * attackerLevel)，上限 75%。
-- attackerLevel 用 玩家等级 + 3（副本 BOSS 的等级修正）。
local function ArmorMitigation()
    local armor = ReadNth(_G.UnitArmor, 2, "player")
    if not armor then return nil end
    local level = ReadNth(_G.UnitLevel, 1, "player")
    if not level or level < 1 then return nil end
    local attackerLevel = level + 3

    local api = _G.C_PaperDollInfo
    if api and type(api.GetArmorEffectiveness) == "function" then
        local ok, eff = pcall(api.GetArmorEffectiveness, armor, attackerLevel)
        eff = ok and Secrets.Number(eff) or nil
        if eff and eff >= 0 and eff <= 1 then
            local pct = (1 - eff) * 100
            if pct > 75 then pct = 75 end
            return pct
        end
    end

    local pct = armor / (armor + 400 + 85 * attackerLevel) * 100
    if pct > 75 then pct = 75 end
    return pct
end

local ROWS = {
    caster = {
        { label = "命中", value = SpellHit,        format = "%.1f%%" },
        { label = "法强", value = BestSpellPower,  format = "%.0f"   },
        { label = "暴击", value = SpellCrit,       format = "%.1f%%" },
        { label = "穿透", value = SpellPen,        format = "%.0f"   }, -- 属性不存在时 value 返回 nil，自动不显示
    },
    tank = {
        { label = "躲闪", value = Dodge,          format = "%.1f%%" },
        { label = "招架", value = Parry,          format = "%.1f%%" },
        { label = "格挡", value = Block,          format = "%.1f%%" },
        { label = "减伤", value = ArmorMitigation, format = "%.1f%%" },
    },
    physical = {
        { label = "命中", value = MeleeHit,   format = "%.1f%%" },
        { label = "AP",   value = MeleeAP,    format = "%.0f"   },
        { label = "暴击", value = MeleeCrit,  format = "%.1f%%" },
    },
}

local CATEGORY_LABEL = { caster = "法系输出", tank = "坦克", physical = "物理输出" }

--- 当前专精的角色（"TANK" / "HEALER" / "DAMAGER"），读不到返回 nil。
--- 入口取 `C_SpecializationInfo`：12.1.5 实机验过这个命名空间（cd1f6d7 正文），1.60 侧目前只有
--- 离线依据（`docs/api/FUNCTIONS.md` 收录它）—— **待 1.60 复验，上线日随 `/mui compat` 补**；
--- 而 `GetSpecialization` / `GetSpecializationInfo` 那对全局在 1.60 不是全局（api-audit 的
--- `[moved]` 就是它）—— 所以只走 C_*，不要再加全局兜底。
--- 返回序：specId, name, description, icon, **role**, ...（12.1.5 实测序 = 历史证据；1.60 与上一句一并 `/mui compat` 核）。
local function CurrentSpecRole()
    local index = CurrentSpecIndex()
    if not index then return nil end
    local api = _G.C_SpecializationInfo
    if not api or type(api.GetSpecializationInfo) ~= "function" then return nil end
    local ok, _, _, _, _, role = pcall(api.GetSpecializationInfo, index, false, false)
    if not ok or type(role) ~= "string" then return nil end
    return role
end

--- 智力是不是主属性（法系 / 治疗 → true）。三样里任何一样读不到 → nil。
local function IntellectPrimary()
    local int = ReadNth(_G.UnitStat, 1, "player", LE_UNIT_STAT_INTELLECT)
    if not int then return nil end
    local str = ReadNth(_G.UnitStat, 1, "player", LE_UNIT_STAT_STRENGTH)
    local agi = ReadNth(_G.UnitStat, 1, "player", LE_UNIT_STAT_AGILITY)
    if not str or not agi then return nil end
    return int >= str and int >= agi
end

--- 坦克 / 法系 / 物理 三档（口径见文件头上那段注释）。
local function ComputeCategory()
    if CurrentSpecRole() == "TANK" then return "tank" end
    local intel = IntellectPrimary()
    if intel == nil then return nil end
    return intel and "caster" or "physical"
end

-- 分类**只算两次**：角色进入世界时一次、点开面板时再算一次（2026-11-03 玩家定的时机）。
-- 别每 2 秒重算 —— 受限状态下 role / 属性都是机密值，重算只会把已经对的结果改错。
local cachedCategory

local function RefreshCategory()
    cachedCategory = ComputeCategory()
    return cachedCategory
end

local function CurrentCategory()
    return cachedCategory
end

-- 职业判定在**角色进入世界**那一刻算一次（玩家定的时机），之后只靠点击触发。
-- 算完就注销：`PLAYER_ENTERING_WORLD` 每次换地图都会发，重算没有意义。
local categoryDriver = CreateFrame("Frame")
categoryDriver:RegisterEvent("PLAYER_ENTERING_WORLD")
categoryDriver:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    RefreshCategory()
end)

-- 下挂窗口：块本体只画"属性"两个字（入口按钮）；点击才建面板、才读 API，关闭即停表。
-- 之所以点开才读：本客户端所有属性 API 都带 SecretWhenUnitStatsRestricted，
-- 常驻轮询在战斗 / 副本里 90% 是拿到 nil 的空转；玩家真要看时才读，节省资源。

local PANEL_WIDTH   = 200
local PANEL_LINE_H  = 18
local PANEL_PAD     = 10
local PANEL_REFRESH = 2   -- 面板开着时每 2 秒重读一遍
local PANEL_ROWS    = 4   -- 最多四行（caster / tank 有 4 行，physical 只有 3 行，最后一行留空）

local statsPanel, statsPanelTitle, statsPanelClose
local statsPanelRows, statsTick = {}, 0

local function HideStatsPanel()
    if statsPanel then statsPanel:Hide() end
end

-- 每次打开 / 每次 tick 都跑：读值 + 写字段。读不到写 "—"（专精判不出则整块空）。
local function FillStatsPanel()
    if not statsPanel then return end

    local category = CurrentCategory()
    if not category then
        statsPanelTitle:SetText("属性")
        for i = 1, PANEL_ROWS do
            local view = statsPanelRows[i]
            if view then
                view.label:SetText("")
                view.value:SetText("")
            end
        end
        return
    end

    statsPanelTitle:SetText("属性 · " .. (CATEGORY_LABEL[category] or ""))
    local spec = ROWS[category]
    for i = 1, PANEL_ROWS do
        local view = statsPanelRows[i]
        local row  = spec[i]
        if view then
            if not row then
                view.label:SetText("")
                view.value:SetText("")
            else
                local v = row.value()
                view.label:SetText(row.label)
                view.value:SetText(v and string.format(row.format, v) or "—")
            end
        end
    end
end

-- 条贴屏幕上沿 → 面板向下挂；贴下沿 → 向上挂。每次 Show 都重锚（编辑模式可能已经搬动过条）。
local function AnchorStatsPanel()
    local block = M:GetBlock("stats")
    if not statsPanel or not block or not block.frame then return end
    statsPanel:ClearAllPoints()
    if M:GetSetting("anchorTop") ~= false then
        statsPanel:SetPoint("TOPLEFT",  block.frame, "BOTTOMLEFT", 0, -2)
    else
        statsPanel:SetPoint("BOTTOMLEFT", block.frame, "TOPLEFT",   0,  2)
    end
end

local function BuildStatsPanel()
    if statsPanel then return statsPanel end
    local block = M:GetBlock("stats")
    if not block or not block.frame then return nil end
    if type(Widget) ~= "table" or type(Widget.Theme) ~= "function" then return nil end

    -- UIParent 子框（不是 block.frame 的子框）：条体是 BACKGROUND 档，面板要压过游戏世界。
    local frame = CreateFrame("Frame", "MonetUIInfoBarStatsPanel", UIParent, "BackdropTemplate")
    frame:SetFrameStrata("DIALOG")
    frame:SetSize(PANEL_WIDTH, PANEL_PAD * 2 + PANEL_LINE_H * (PANEL_ROWS + 1))
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(false)
    if Widget.Theme then
        Widget:Theme(frame, { thickness = 1, bgAlpha = 0.92, borderAlpha = 1 })
    end

    -- 标题
    local title = Widget:Font(frame, 12, "pixel", "bright", "LEFT")
    title:SetPoint("TOPLEFT",  frame, "TOPLEFT",  PANEL_PAD, -PANEL_PAD)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PANEL_PAD * 3, -PANEL_PAD)
    title:SetText("属性")
    statsPanelTitle = title

    -- 关闭：尺寸 / 行为来自 UIPanelCloseButton，✕ 材质由 `Widget:CloseButton` 统一换上
    -- （monet_close_{normal,hover,push} + 边框色染色）—— 别再在调用点补 `Skin:CloseButton`，
    -- 那正是以前漏掉一处、面板上留了暴雪红圆钮的原因。OnClick 覆盖成"只收我们的面板"。
    local close = Widget:CloseButton(frame, 20)
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 3, 3)
    close:SetScript("OnClick", HideStatsPanel)
    statsPanelClose = close

    -- 四行 label / value
    for i = 1, PANEL_ROWS do
        local label = Widget:Font(frame, 12, "pixel", "neutral", "LEFT")
        label:SetPoint("TOPLEFT", frame, "TOPLEFT", PANEL_PAD, -PANEL_PAD - PANEL_LINE_H * i)
        label:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PANEL_WIDTH / 2, -PANEL_PAD - PANEL_LINE_H * i)

        local value = Widget:Font(frame, 12, "pixel", "bright", "RIGHT")
        value:SetPoint("TOPLEFT", frame, "TOPLEFT", PANEL_WIDTH / 2, -PANEL_PAD - PANEL_LINE_H * i)
        value:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PANEL_PAD, -PANEL_PAD - PANEL_LINE_H * i)

        statsPanelRows[i] = { label = label, value = value }
    end

    -- 关窗即停表：OnUpdate 只在 Show 期间跑；隐藏后什么都不做。
    frame:SetScript("OnUpdate", function(self, elapsed)
        local b = M:GetBlock("stats")
        if not b or not b.frame or not b.frame:IsShown() then self:Hide() return end
        local parent = b.frame:GetParent()
        if parent and not parent:IsShown() then self:Hide() return end
        statsTick = statsTick + elapsed
        if statsTick >= PANEL_REFRESH then
            statsTick = 0
            FillStatsPanel()
        end
    end)

    -- 条本体在宠物对战 / 关模块时会被 SetShown(false)；面板此时也要跟着收，不然会残留一个 DIALOG 层的框体。
    if block.frame.SetScript then
        local prevOnHide = block.frame:GetScript("OnHide")
        block.frame:SetScript("OnHide", function(self)
            if prevOnHide then prevOnHide(self) end
            HideStatsPanel()
        end)
    end

    statsPanel = frame
    frame:Hide()
    return frame
end

local function ShowStatsPanel()
    if not BuildStatsPanel() then return end
    -- 点开 = 重新触发一次判定（玩家定的时机：进入世界一次 + 点击）。
    RefreshCategory()
    AnchorStatsPanel()
    statsTick = 0
    FillStatsPanel()
    statsPanel:Show()
    statsPanel:SetFrameStrata("DIALOG")
end

local function ToggleStatsPanel()
    if statsPanel and statsPanel:IsShown() then
        HideStatsPanel()
    else
        ShowStatsPanel()
    end
end

local function StatsUpdate(block)
    -- 块本体只是入口按钮：常驻只画"属性"两个字，不做任何属性读取。
    M:SetText(block, "属性")
end

local function StatsTooltip(block)
    local tip = Tip()
    if not tip then return end
    if statsPanel and statsPanel:IsShown() then
        pcall(tip.AddLine, tip, "再次点击收起面板", 0.8, 0.8, 0.8)
    else
        pcall(tip.AddLine, tip, "点击查看属性面板", 0.8, 0.8, 0.8)
    end
end

M:RegisterBlock({
    key      = "stats",
    label    = "属性",
    position = "LEFT",
    -- 面板打开时由 OnUpdate 自己刷；关闭后一条 API 都不问，所以块本体不需要挂事件。
    update   = StatsUpdate,
    tooltip  = StatsTooltip,
    onClick  = function(_, button)
        if button == "LeftButton" then ToggleStatsPanel() end
    end,
})
