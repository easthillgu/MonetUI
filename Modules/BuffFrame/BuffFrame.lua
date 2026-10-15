-- Modules/BuffFrame/BuffFrame.lua
-- Player buff / debuff display.
--
-- Replaces the Blizzard aura frame with a compact, themed grid anchored under
-- the minimap.  Aura data comes from C_UnitAuras / AuraData; when the client
-- marks auras secret the module steps aside instead of erroring.

local ADDON_NAME, ns = ...

local Secrets  = ns.Secrets
local Widget   = ns.Widget
local Color    = ns.Color
local Math     = ns.Math
local EventBus = ns.EventBus

local M = { name = "BuffFrame" }

local ICON_SIZE   = 34
local ICON_GAP    = 4
local PER_ROW     = 8
local MAX_AURAS   = 32

-- The container is anchored top-left and the buttons grow right / down from its
-- top-left corner, so the grid always hugs the top-left edge of the screen.
local ROW_STRIDE  = ICON_SIZE + ICON_GAP
local AURA_GAP    = 33   -- Andromeda's UI_GAP, used for the top-left inset

--- Resize a container to exactly hug the icons it currently shows.
local function FitContainer(container, count)
    if count <= 0 then
        container:SetSize(0, 0)
        return
    end
    local rows = math.ceil(count / PER_ROW)
    local cols = math.min(count, PER_ROW)
    container:SetSize(
        cols * ROW_STRIDE - ICON_GAP,
        rows * ROW_STRIDE - ICON_GAP)
end

local buffButtons, debuffButtons = {}, {}
local buffContainer, debuffContainer
local pending

-- -- Data ---------------------------------------------------------------------

--- Read + sort the auras of one unit.  Wrapped because a restricted client can
-- still hand back aura data we are not allowed to inspect.
local function CollectAuras(unit, filter)
    local list = {}
    if not Secrets.CanReadAuras() then return list end

    local ok = Secrets.Measure(function()
        for index = 1, MAX_AURAS do
            local aura = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
            if not aura then break end
            list[#list + 1] = aura
        end
    end)
    if not ok then return {} end

    table.sort(list, function(a, b)
        local ea = Secrets.Number(a.expirationTime) or math.huge
        local eb = Secrets.Number(b.expirationTime) or math.huge
        if ea ~= eb then return ea < eb end
        return (Secrets.Number(a.spellId) or 0) < (Secrets.Number(b.spellId) or 0)
    end)

    return list
end

-- -- Buttons ------------------------------------------------------------------

local function CreateAuraButton(parent)
    local button = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    button:SetSize(ICON_SIZE, ICON_SIZE)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button.cooldown = Widget:Cooldown(button)
    button.cooldown:SetAllPoints()

    button.count = Widget:Font(button, 13, "pixel", { r = 1, g = 1, b = 1 }, "RIGHT")
    button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)

    button.timer = Widget:Font(button, 11, "pixel", { r = 1, g = 0.95, b = 0.6 }, "CENTER")
    button.timer:SetPoint("TOP", button, "TOP", 0, -2)

    Widget:Theme(button, { thickness = 1, bgAlpha = 0.6 })
    button:Hide()
    return button
end

local function EnsureButtons(list, parent, needed)
    for i = #list + 1, needed do
        list[i] = CreateAuraButton(parent)
    end
    for i = needed + 1, #list do
        list[i]:Hide()
    end
end

local function ShowAura(button, aura, index)
    local column = (index - 1) % PER_ROW
    local row = math.floor((index - 1) / PER_ROW)

    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", button:GetParent(), "TOPLEFT",
        column * ROW_STRIDE, -row * ROW_STRIDE)

    -- Show first: everything below must be allowed to fail without leaving the
    -- button stuck hidden.
    button:Show()

    button.icon:SetTexture(aura.icon or aura.spellId)

    local count = Secrets.Number(aura.applications)
    if count and count > 1 then
        button.count:SetText(count)
        button.count:Show()
    else
        button.count:Hide()
    end

    local duration = Secrets.Number(aura.duration)
    local expiration = Secrets.Number(aura.expirationTime)
    local remaining = (duration and expiration) and (expiration - GetTime()) or nil

    if duration and duration > 0 and expiration and remaining and remaining > 0 then
        button.timer:SetText(Math:DurationText(remaining))
        button.timer:Show()
        -- SetCooldown is a protected method; never let it abort the update.
        if not pcall(button.cooldown.SetCooldown, button.cooldown, expiration - duration, duration) then
            pcall(button.cooldown.Clear, button.cooldown)
        end
    else
        button.timer:Hide()
        pcall(button.cooldown.Clear, button.cooldown)
    end

    local r, g, b = Color:GetEdge()
    if Secrets.Bool(aura.isHarmful, false) then
        r, g, b = Color:GetDanger()
    end
    if button.SetBackdropBorderColor then
        button:SetBackdropBorderColor(r, g, b, 0.9)
    end

    button.auraInstanceID = aura.auraInstanceID
end

local function UpdateRow(list, parent, auras)
    local needed = math.min(#auras, MAX_AURAS)
    EnsureButtons(list, parent, needed)

    for index = 1, needed do
        Secrets.Measure(ShowAura, list[index], auras[index], index)
    end
end

local function HideContainer(container)
    if not container then return end
    container:Hide()
end

function M:Update()
    if not buffContainer then return end

    if not Secrets.CanReadAuras() then
        HideContainer(buffContainer)
        HideContainer(debuffContainer)
        return
    end

    local buffs = CollectAuras("player", "HELPFUL")
    local debuffs = CollectAuras("player", "HARMFUL")

    UpdateRow(buffButtons, buffContainer, buffs)
    FitContainer(buffContainer, #buffs)
    UpdateRow(debuffButtons, debuffContainer, debuffs)
    FitContainer(debuffContainer, #debuffs)

    buffContainer:SetShown(#buffs > 0)
    debuffContainer:SetShown(#debuffs > 0)
end

--- Throttled update: UNIT_AURA can fire very often during combat.
local function QueueUpdate()
    local frame = buffContainer
    if not frame or pending then return end
    pending = true
    frame:SetScript("OnUpdate", function(self, elapsed)
        self.__elapsed = (self.__elapsed or 0) + elapsed
        if self.__elapsed < 0.25 then return end
        self.__elapsed = 0
        self:SetScript("OnUpdate", nil)
        pending = false
        M:Update()
    end)
end

-- -- Blizzard takeover --------------------------------------------------------

local function SuppressBlizzard()
    local found = 0
    for _, name in ipairs({ "BuffFrame", "DebuffFrame", "TempEnchantFrame" }) do
        local blizzard = _G[name]
        if blizzard then
            found = found + 1
            pcall(blizzard.UnregisterAllEvents, blizzard)
            if blizzard.SetScript then
                pcall(blizzard.SetScript, blizzard, "OnShow", blizzard.Hide)
            end
            blizzard:Hide()
        end
    end
    if found == 0 then
        ns:Print("未找到暴雪光环框架，若同时出现两套 Buff 显示请告知开发者。")
    end
end

-- -- Lifecycle ----------------------------------------------------------------

function M:Initialize()
    -- Anchored top-left, matching Andromeda's BuffAnchor (its UI_GAP is 33).
    buffContainer = Widget:CreateFrame("MonetUIBuffFrame", UIParent, 1, 1)
    buffContainer:SetPoint("TOPLEFT", UIParent, "TOPLEFT", AURA_GAP, -AURA_GAP)

    debuffContainer = Widget:CreateFrame("MonetUIDebuffFrame", UIParent, 1, 1)
    debuffContainer:SetPoint("TOPLEFT", buffContainer, "BOTTOMLEFT", 0, -8)

    SuppressBlizzard()

    EventBus:RegisterUnit("UNIT_AURA", "player", QueueUpdate)
    EventBus:Register("PLAYER_ENTERING_WORLD", function() M:Update() end)
    EventBus:Register("PLAYER_SPECIALIZATION_CHANGED", function() M:Update() end)
    EventBus:Register("MONETUI_RESTRICTION_CHANGED", function() M:Update() end)

    self:Update()
end

function M:SetEnabled(enabled)
    if enabled then
        self:Update()
    else
        if buffContainer then buffContainer:Hide() end
        if debuffContainer then debuffContainer:Hide() end
        for _, button in ipairs(buffButtons) do button:Hide() end
        for _, button in ipairs(debuffButtons) do button:Hide() end
    end
end

ns:Register("BuffFrame", M)
