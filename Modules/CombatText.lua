-- Modules/CombatText.lua
-- 自身战斗文字 (self combat text): 玩家受到的伤害 / 治疗 / 闪避招架，以及（可选）进出战斗，
-- 在玩家框上方浮起、上飘淡出。
--
-- 数据来源：事件 COMBAT_TEXT_UPDATE（载荷 = 类型字符串）+ C_CombatText.GetCurrentEventInfo()，
-- 后者按暴雪自己的用法返回 `data, arg3, arg4`（Blizzard_CombatText/Shared/CombatText.lua:104）。
-- 注意它在本客户端标着 SecretReturns：数值一律过 Secrets.Number，拿不到明文就整条不画 ——
-- 宁可少一行，也不让战斗里因为机密值运算崩掉。
--
-- 替代暴雪自己的浮动战斗文字：开模块时把暴雪「对玩家造成伤害 / 治疗 / 进出战斗」三条 CVar 存下原值
-- 并置 0，关掉时还原（找不到的 CVar 直接跳过，不动别的设置）。
--
-- 常驻成本：只有一个容器帧；没有浮字时 OnUpdate 是摘掉的。

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local Color    = ns.Color
local Media    = ns.Media
local Secrets  = ns.Secrets
local EventBus = ns.EventBus

local M = { name = "CombatText" }
ns.CombatText = M

local POOL_MAX    = 14      -- 同时最多几行
local LIFE        = 1.15    -- 一行活多久（秒）
local RISE        = 44      -- 上飘高度（UI 单位）
local SPREAD      = 30      -- 水平散开的半宽，避免叠成一坨

-- 类型表：和暴雪 CombatText 的分类一致，只挑"玩家自身"会收到的那些。
local DAMAGE = {
    DAMAGE = true, DAMAGE_CRIT = true, SPELL_DAMAGE = true, SPELL_DAMAGE_CRIT = true,
    DAMAGE_SHIELD = true,
}
local HEAL = {
    HEAL = true, HEAL_CRIT = true, PERIODIC_HEAL = true, PERIODIC_HEAL_CRIT = true,
}
local AVOID = {
    MISS = true, DODGE = true, PARRY = true, BLOCK = true, ABSORB = true, RESIST = true,
    EVADE = true, IMMUNE = true, DEFLECT = true, DAMAGE_SHIELD_MISSED = true,
}

-- 暴雪的对应 CVar：存在就接管，不存在就跳过（不写任何找不到的名字）。
local CVARS = {
    damage = { "floatingCombatTextCombatDamage_v2", "floatingCombatTextCombatDamage" },
    heal   = { "floatingCombatTextCombatHealing_v2", "floatingCombatTextCombatHealing" },
    combat = { "floatingCombatTextCombatState_v2", "floatingCombatTextCombatState" },
}

local container
local active = {}       -- 正在飘的：{ fs=, t=, dx= }
local spare = {}        -- 回收的 FontString
local running           -- OnUpdate 是否挂着

function M:Settings()
    local db = ns:DB()
    if type(db) ~= "table" then return {} end
    if type(db.combatText) ~= "table" then db.combatText = {} end
    return db.combatText
end

function M:GetSetting(key)
    local value = self:Settings()[key]
    if value == nil then value = ns.DEFAULTS.combatText[key] end
    return value
end

-- ---------------------------------------------------------------- 暴雪 CVar 接管
local function CVarApi()
    local api = _G.C_CVar
    if api and type(api.GetCVar) == "function" and type(api.SetCVar) == "function" then return api end
    return nil
end

--- 原值存档（跟着 DB 走，重登后还能还原）。
local function Saved()
    local db = M:Settings()
    if type(db.saved) ~= "table" then db.saved = {} end
    return db.saved
end

--- 把某一类的暴雪浮动文字关掉，原值存进存档（只存第一次见到的值）。
local function Suppress(key)
    local api = CVarApi()
    if not api then return end
    local saved = Saved()
    for _, name in ipairs(CVARS[key] or {}) do
        local ok, value = pcall(api.GetCVar, name)
        if ok and value ~= nil then
            if saved[name] == nil then saved[name] = value end
            pcall(api.SetCVar, name, "0")
            return
        end
    end
end

local function Restore(key)
    local api = CVarApi()
    if not api then return end
    local saved = Saved()
    for _, name in ipairs(CVARS[key] or {}) do
        local value = saved[name]
        if value ~= nil then
            pcall(api.SetCVar, name, value)
            saved[name] = nil
            return
        end
    end
end

-- ---------------------------------------------------------------- 渲染
local function EnsureContainer()
    if container then return end
    container = CreateFrame("Frame", "MonetUICombatText", _G.UIParent)
    container:SetSize(180, 80)
    container:SetFrameStrata("HIGH")
    container:EnableMouse(false)
end

--- 挂到玩家框上方（跟着框走）；拿不到玩家框就退回屏幕中央偏上。
local function Anchor()
    if not container then return end
    container:ClearAllPoints()

    local uf = ns:GetModule("UnitFrames")
    local player = uf and type(uf.GetFrame) == "function" and uf:GetFrame("player")
    if player and type(player.GetTop) == "function" then
        container:SetPoint("BOTTOM", player, "TOP", 0, 6)
        container:SetFrameLevel((player:GetFrameLevel() or 1) + 8)
    else
        container:SetPoint("BOTTOM", _G.UIParent, "CENTER", 0, 120)
        container:SetFrameLevel(200)
    end
end

local function Acquire()
    local fs = table.remove(spare)
    if fs then
        fs:Show()
        return fs
    end
    fs = Widget:Font(container, 12, "pingfang", "danger", "CENTER", nil, Media.outlineFlags)
    fs:SetWordWrap(false)
    return fs
end

local function Tick(_, elapsed)
    elapsed = elapsed or 0
    local alive = 0

    for i = #active, 1, -1 do
        local entry = active[i]
        entry.t = entry.t + elapsed
        local progress = entry.t / LIFE

        if progress >= 1 then
            entry.fs:Hide()
            spare[#spare + 1] = entry.fs
            table.remove(active, i)
        else
            alive = alive + 1
            entry.fs:SetPoint("BOTTOM", container, "BOTTOM", entry.dx * progress, RISE * progress)
            local alpha = (progress < 0.7) and 1 or (1 - (progress - 0.7) / 0.3)
            entry.fs:SetAlpha(alpha)
        end
    end

    if alive == 0 and running then
        running = false
        container:SetScript("OnUpdate", nil)
    end
end

local function Emit(text, r, g, b, big)
    if not (container and text and text ~= "") then return end

    local fs = Acquire()
    Widget:SetFont(fs, big and 16 or 12, "pingfang", Media.outlineFlags)
    fs:SetText(text)
    fs:SetTextColor(r, g, b, 1)
    fs:SetAlpha(1)
    fs:SetPoint("BOTTOM", container, "BOTTOM", 0, 0)

    if #active >= POOL_MAX then
        -- 挤掉最老的一条，池子才不会被刷屏撑爆
        local oldest = table.remove(active, 1)
        if oldest then
            oldest.fs:Hide()
            spare[#spare + 1] = oldest.fs
        end
    end

    active[#active + 1] = {
        fs = fs,
        t = 0,
        dx = (math.random() - 0.5) * SPREAD,
    }

    if not running then
        running = true
        container:SetScript("OnUpdate", Tick)
    end
end

--- 数字格式化：BreakUpLargeNumbers 在 1.60 手工里存在，但仍 pcall —— 属性表不同版本行为不一致。
local function FormatAmount(value)
    local number = Secrets.Number(value)
    if not number then return nil end
    local breakUp = _G.BreakUpLargeNumbers
    if type(breakUp) == "function" then
        local ok, text = pcall(breakUp, number)
        if ok and text then return text end
    end
    return tostring(number)
end

local function OnCombatText(_, msgType)
    if not (M.active and container) or type(msgType) ~= "string" then return end

    local isDamage = DAMAGE[msgType]
    local isHeal = not isDamage and HEAL[msgType]
    local isAvoid = not isDamage and not isHeal and AVOID[msgType]
    if not (isDamage or isHeal or isAvoid) then return end

    local key = isDamage and "damage" or (isHeal and "heal" or "avoid")
    if M:GetSetting(key) == false then return end

    local api = _G.C_CombatText
    if not api or type(api.GetCurrentEventInfo) ~= "function" then return end

    -- 机密环境下这次调用可能给出机密值；构造整体 pcall，任何异常都当"这条不显示"。
    local ok, data, arg3 = pcall(api.GetCurrentEventInfo)
    if not ok then return end

    local big = msgType:find("_CRIT") ~= nil

    if isDamage then
        local amount = FormatAmount(data)
        if not amount then return end
        local r, g, b = Color:GetDanger()
        Emit("-" .. amount, r, g, b, big)
    elseif isHeal then
        local amount = FormatAmount(arg3)
        if not amount then return end
        local r, g, b = Color:GetHealth()
        Emit("+" .. amount, r, g, b, big)
    else
        local label = _G[msgType]
        if type(label) ~= "string" then label = msgType end
        local r, g, b = Color:GetNeutral()
        Emit(label, r, g, b, false)
    end
end

local function OnCombatState(_, entering)
    if not (M.active and container) then return end
    if M:GetSetting("combat") == false then return end
    local r, g, b = Color:GetBorder()
    Emit(entering and (_G.ENTERING_COMBAT or "+战斗") or (_G.LEAVING_COMBAT or "-战斗"), r, g, b, false)
end

-- ---------------------------------------------------------------- 模块接口
function M:Initialize()
    self.active = true
    EnsureContainer()
    Anchor()

    EventBus:Register("COMBAT_TEXT_UPDATE", function(_, msgType)
        if M.active then OnCombatText(nil, msgType) end
    end)
    EventBus:Register("PLAYER_REGEN_DISABLED", function() if M.active then OnCombatState(nil, true) end end)
    EventBus:Register("PLAYER_REGEN_ENABLED", function() if M.active then OnCombatState(nil, false) end end)

    -- 玩家框可能比我们晚建 / 被拖动：进场时重新贴一次锚点。
    EventBus:Register("PLAYER_ENTERING_WORLD", function() if M.active then Anchor() end end)

    self:Apply()
end

function M:Apply()
    if not self.active then return end
    for key in pairs(CVARS) do
        if self:GetSetting(key) == false then
            Restore(key)
        else
            Suppress(key)
        end
    end
end

function M:SetEnabled(value)
    self.active = value and true or false
    if not container then return end

    if self.active then
        Anchor()
        self:Apply()
        return
    end

    -- 关掉：把暴雪的浮动文字还回去，并清掉屏幕上的浮字。
    for key in pairs(CVARS) do Restore(key) end
    container:SetScript("OnUpdate", nil)
    running = false
    for i = #active, 1, -1 do
        active[i].fs:Hide()
        spare[#spare + 1] = active[i].fs
        active[i] = nil
    end
end

ns:Register("CombatText", M)
