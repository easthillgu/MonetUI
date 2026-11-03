-- Modules/Tools/Durability.lua
-- 装备耐久警告（durability warning）：最低的装备耐久掉到阈值以下时，用通知横幅提醒一次；
-- 修好 / 换装回到阈值以上之后才重新武装。
--
-- 只读装备耐久，不改任何东西：事件由 UPDATE_INVENTORY_DURABILITY / PLAYER_EQUIPMENT_CHANGED /
-- PLAYER_ENTERING_WORLD 驱动，平时没有 OnUpdate。没有 Toast 模块时退化成聊天框一行提示。
--
-- `GetInventoryItemDurability` 在 1.60 手册里没有条目，而且参数形态和零售不同（本客户端是
-- (slot)，零售是 (unit, slot)）—— 和 InfoBar/Blocks.lua 用同一套"第一次调用成功就定形"的探测。

local ADDON_NAME, ns = ...

local EventBus = ns.EventBus
local Secrets  = ns.Secrets

local M = { name = "Durability" }
ns.Durability = M

-- 头 / 肩 / 胸 / 腿 / 脚 / 手腕 / 手 / 腰 / 主手 / 副手（同 InfoBar/Blocks.lua 的 DUR_SLOTS）
local SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 15, 16 }
local HYSTERESIS = 5     -- 高出阈值这么多才算"修好了"，免得在阈值上下反复报警

local mode               -- "slot" | "unit"：本会话用哪种参数形态，探测一次就定
local armed = true       -- true = 下次跌破阈值还要报警

function M:Settings()
    local db = ns:DB()
    if type(db) ~= "table" then return {} end
    if type(db.durability) ~= "table" then db.durability = {} end
    return db.durability
end

function M:GetSetting(key)
    local value = self:Settings()[key]
    if value == nil then value = ns.DEFAULTS.durability[key] end
    return value
end

local function DurabilityForSlot(slot)
    local fn = _G.GetInventoryItemDurability
    if type(fn) ~= "function" then return nil end

    if not mode then
        if pcall(fn, slot) then
            mode = "slot"
        elseif pcall(fn, "player", slot) then
            mode = "unit"
        else
            return nil
        end
    end

    local ok, current, maximum
    if mode == "unit" then
        ok, current, maximum = pcall(fn, "player", slot)
    else
        ok, current, maximum = pcall(fn, slot)
    end
    if not ok then return nil end

    current, maximum = Secrets.Number(current), Secrets.Number(maximum)
    if not current or not maximum or maximum <= 0 then return nil end
    return current, maximum
end

--- 所有装备里最低的那件：返回百分比（0..100），没有可读数据时 nil。
local function Lowest()
    local worst
    for _, slot in ipairs(SLOTS) do
        local current, maximum = DurabilityForSlot(slot)
        if current then
            local pct = current / maximum * 100
            if not worst or pct < worst then worst = pct end
        end
    end
    return worst
end

local function Check()
    if not M.active then return end
    if M:GetSetting("warn") == false then return end

    local pct = Lowest()
    if not pct then return end

    local threshold = tonumber(M:GetSetting("threshold")) or 30
    if pct <= threshold then
        if not armed then return end
        armed = false

        local text = string.format("最低剩 %d%%，记得修理", math.floor(pct + 0.5))
        local toast = ns:GetModule("Toast")
        if toast and toast.Notify then
            toast:Notify("装备耐久", text)
        else
            ns:Print("装备耐久：" .. text)
        end
    elseif pct > threshold + HYSTERESIS then
        armed = true
    end
end

function M:Initialize()
    self.active = true
    EventBus:Register("UPDATE_INVENTORY_DURABILITY", function()
        if M.active then Check() end
    end)
    EventBus:Register("PLAYER_EQUIPMENT_CHANGED", function()
        if M.active then Check() end
    end)
    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        -- 不重新武装：不然每换一个区域就会再提醒一次。登录那次 armde 仍是初始的 true，
        -- 所以"带着残血装备上线"照样会提示一次。
        if M.active then Check() end
    end)
end

--- 设置改了就立刻按新阈值判一次（调高阈值时不必等到下次掉耐久）。
function M:Apply()
    if self.active then
        armed = true
        Check()
    end
end

function M:SetEnabled(value)
    self.active = value and true or false
    if self.active then
        armed = true
        Check()
    end
end

ns:Register("Durability", M)
