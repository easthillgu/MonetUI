-- Modules/InfoBar/Blocks.lua
-- The six data blocks the strip can carry (money, durability, currency, system, spec, friends).
-- Every value is read defensively: secret numbers go through Utils/Secrets.lua first, and a missing or unfit call simply leaves its block empty. Money formatting and the durability probe are ours, not copied from any reference addon.

local ADDON_NAME, ns = ...
local M = ns.InfoBar
if not M then return end

local Secrets = ns.Secrets

local function Tip()
    return _G.GameTooltip
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
    onClick  = function(_, button)
        if button == "LeftButton" then
            M:OpenPanel("ToggleCharacter", "PaperDollFrame")
        end
    end,
})

local DUR_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 15, 16 }
-- 头 / 肩 / 胸 / 腿 / 脚 / 手腕 / 手 / 腰 / 主手 / 副手

-- This client documents `GetInventoryItemDurability(slot)` where retail has `(unit, slot)`; a wrong arity raises, so the first successful call settles it for the session (shown by `/mui infobar diagnose`).
local function DurabilityForSlot(slot)
    if M.durabilityMode == nil then
        local fn = _G.GetInventoryItemDurability
        if type(fn) ~= "function" then return nil end

        if pcall(fn, slot) then
            M.durabilityMode = "slot"
        elseif pcall(fn, "player", slot) then
            M.durabilityMode = "unit"
        else
            return nil
        end
    end

    local fn = _G.GetInventoryItemDurability
    local ok, current, maximum
    if M.durabilityMode == "unit" then
        ok, current, maximum = pcall(fn, "player", slot)
    else
        ok, current, maximum = pcall(fn, slot)
    end
    if not ok then return nil end

    current, maximum = Secrets.Number(current), Secrets.Number(maximum)
    if not current or not maximum or maximum == 0 then return nil end
    return current, maximum
end

local function DurabilityUpdate(block)
    local sum, count = 0, 0
    for i = 1, #DUR_SLOTS do
        local current, maximum = DurabilityForSlot(DUR_SLOTS[i])
        if current then
            sum = sum + current / maximum
            count = count + 1
        end
    end

    if count == 0 then M:SetText(block, "") return end
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
    onClick  = function(_, button)
        if button == "LeftButton" then
            M:OpenPanel("ToggleCharacter", "PaperDollFrame")
        end
    end,
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
        if okInfo and type(info) == "table" and not info.isHeader and info.isShowInBackpack then
            local name = info.name
            local quantity = Secrets.Number(info.quantity)
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
    onClick  = function(_, button)
        if button == "LeftButton" then
            M:OpenPanel("ToggleTalentFrame")
        end
    end,
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
    onClick  = function(_, button)
        if button == "LeftButton" then
            M:OpenPanel("ToggleFriends")
        end
    end,
})
