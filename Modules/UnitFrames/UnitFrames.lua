-- Modules/UnitFrames/UnitFrames.lua
-- Player / target unit frames.
--
-- The client can hide unit values from addons (see Utils/Secrets.lua).  Bars are
-- therefore fed the raw values through Secrets.SetBar, while numeric text is only
-- produced once the client confirms the values are readable.

local ADDON_NAME, ns = ...

local Secrets = ns.Secrets
local Widget  = ns.Widget
local Color   = ns.Color
local Math    = ns.Math
local EventBus = ns.EventBus

local M = { name = "UnitFrames" }

local frames = {}

local UNIT_LABEL = {
    player = "玩家",
    target = "目标",
    focus  = "焦点",
    pet    = "宠物",
}

-- Units we build a frame for (and therefore take over from Blizzard).
local UNITS = { "player", "target", "focus", "pet" }

local FRAME_WIDTH  = 260
local FRAME_HEIGHT = 52

-- Blizzard frames we optionally take over.  Note the capitalisation: the frame
-- globals are PlayerFrame / TargetFrame / FocusFrame / PetFrame, not
-- unit .. "Frame", so they must be looked up explicitly.
local BLIZZARD_FRAMES = {
    player = "PlayerFrame",
    target = "TargetFrame",
    focus  = "FocusFrame",
    pet    = "PetFrame",
}

-- -- Blizzard takeover --------------------------------------------------------

--- Suppress the default Blizzard unit frames (the pattern used by oUF).
function M:SuppressBlizzard(enable)
    for _, globalName in pairs(BLIZZARD_FRAMES) do
        local blizzard = _G[globalName]
        if blizzard then
            if enable and not blizzard.__monetSuppressed then
                blizzard.__monetSuppressed = true
                pcall(blizzard.UnregisterAllEvents, blizzard)
                if blizzard.SetScript then
                    pcall(blizzard.SetScript, blizzard, "OnShow", blizzard.Hide)
                end
                blizzard:Hide()
            elseif not enable and blizzard.__monetSuppressed then
                blizzard.__monetSuppressed = nil
                pcall(blizzard.SetScript, blizzard, "OnShow", nil)
                blizzard:Show()
            end
        end
    end
end

-- -- Construction -------------------------------------------------------------

local function UpdateName(frame)
    local unit = frame.unit
    if not UnitExists(unit) then return end

    local name
    local classFile
    if Secrets.CanReadIdentity(unit) then
        name = UnitName(unit)
        local _, class = UnitClass(unit)
        classFile = class
    end
    frame.name:SetText(name or frame.label)

    local r, g, b = Color:ClassColor(classFile)
    if not r then
        r, g, b = Color:GetEdge()
    end
    frame.name:SetTextColor(r, g, b, 1)

    local level = Secrets.Number(UnitLevel(unit))
    if level and level > 0 then
        frame.level:SetText("Lv" .. level)
        frame.level:Show()
    elseif level == -1 then
        frame.level:SetText("??")
        frame.level:Show()
    else
        frame.level:Hide()
    end
end

local function UpdateHealth(frame)
    local unit = frame.unit
    if not UnitExists(unit) then return end

    Secrets.SetBar(frame.health, UnitHealth(unit), UnitHealthMax(unit))

    if Secrets.CanMeasureHealth(unit) then
        local current = Secrets.Number(UnitHealth(unit))
        local maximum = Secrets.Number(UnitHealthMax(unit))
        if current and maximum and maximum > 0 then
            frame.healthText:SetText(Math:ShortNumber(current) .. " / " .. Math:ShortNumber(maximum))
            frame.healthText:Show()
        else
            frame.healthText:Hide()
        end
    else
        -- restricted: keep the bar, hide the numbers
        frame.healthText:Hide()
    end
end

local function UpdatePower(frame)
    local unit = frame.unit
    if not UnitExists(unit) then return end

    local _, powerToken = UnitPowerType(unit)
    Secrets.SetBar(frame.power, UnitPower(unit), UnitPowerMax(unit))

    local palette = _G.PowerBarColor
    local color = palette and powerToken and palette[powerToken]
    if color then
        frame.power:SetStatusBarColor(color.r, color.g, color.b)
    else
        frame.power:SetStatusBarColor(Color:GetResource())
    end

    -- Hide a bar the unit simply does not have (e.g. a rogue with 0 max energy).
    local maximum = Secrets.Number(UnitPowerMax(unit))
    frame.power:SetShown(maximum == nil or maximum > 0)
end

local function PositionFrame(frame)
    local db = ns:DB()
    local stored = (db.unitFrames and db.unitFrames[frame.unit]) or frame.position or {}
    local point = stored.point or "TOPLEFT"
    frame:ClearAllPoints()
    frame:SetPoint(point, UIParent, point, stored.x or 20, stored.y or -20)
end

local function CreateUnitFrame(unit, position)
    local frame = Widget:CreateFrame("MonetUI" .. unit:gsub("^%l", string.upper) .. "Frame",
        UIParent, FRAME_WIDTH, FRAME_HEIGHT)
    frame.unit = unit
    frame.label = UNIT_LABEL[unit] or unit

    local health = Widget:Bar(frame, FRAME_WIDTH - 4, FRAME_HEIGHT - 4)
    health:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    health:SetStatusBarColor(Color:GetHealth())

    local power = Widget:Bar(frame)
    power:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 2, 2)
    power:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    power:SetHeight(13)
    power:SetStatusBarColor(Color:GetResource())

    local name = Widget:Font(frame, 14, "pixel", "edge", "LEFT")
    name:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -7)

    local level = Widget:Font(frame, 11, "pixel", "neutral", "RIGHT")
    level:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)

    local healthText = Widget:Font(frame, 12, "pixel", { r = 1, g = 1, b = 1 }, "RIGHT")
    healthText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 5)

    frame.health = health
    frame.power = power
    frame.name = name
    frame.level = level
    frame.healthText = healthText

    Widget:Theme(frame, { thickness = 1, bgAlpha = 0.9 })
    Widget:UnitTooltip(frame, unit)

    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        local db = ns:DB()
        db.unitFrames[unit] = { point = point, x = Math:Round(x, 0), y = Math:Round(y, 0) }
    end)

    frame.position = position
    frame:Hide()
    return frame
end

-- -- Public -------------------------------------------------------------------

function M:UpdateUnit(unit, kind)
    local frame = frames[unit]
    if not frame or not frame:IsShown() then return end
    if kind == "health" then
        UpdateHealth(frame)
    elseif kind == "power" then
        UpdatePower(frame)
    else
        UpdateName(frame)
    end
end

function M:UpdateAll()
    for unit, frame in pairs(frames) do
        if UnitExists(unit) then
            frame:Show()
            UpdateHealth(frame)
            UpdatePower(frame)
            UpdateName(frame)
        else
            frame:Hide()
        end
    end
end

local UNIT_EVENTS = {
    UNIT_HEALTH        = "health",
    UNIT_MAXHEALTH     = "health",
    UNIT_POWER_UPDATE  = "power",
    UNIT_MAXPOWER      = "power",
    UNIT_DISPLAYPOWER  = "power",
    UNIT_NAME_UPDATE   = "name",
    UNIT_CONNECTION    = "name",
}

-- Build the handler through a factory: the loop variable must not be captured
-- directly (its identity across iterations is not something to rely on).
local function MakeUnitHandler(kind)
    return function(_, changedUnit)
        M:UpdateUnit(changedUnit, kind)
    end
end

function M:RegisterEvents()
    for unit in pairs(frames) do
        for event, kind in pairs(UNIT_EVENTS) do
            EventBus:RegisterUnit(event, unit, MakeUnitHandler(kind))
        end
    end

    EventBus:Register("PLAYER_TARGET_CHANGED", function()
        local frame = frames.target
        if not frame then return end
        if UnitExists("target") then
            frame:Show()
            UpdateHealth(frame); UpdatePower(frame); UpdateName(frame)
        else
            frame:Hide()
        end
    end)

    EventBus:Register("PLAYER_ENTERING_WORLD", function() M:UpdateAll() end)
    EventBus:Register("GROUP_ROSTER_UPDATE", function() M:UpdateAll() end)
    EventBus:Register("PLAYER_REGEN_ENABLED", function() M:UpdateAll() end)
    EventBus:Register("MONETUI_RESTRICTION_CHANGED", function() M:UpdateAll() end)
    EventBus:Register("MONETUI_THEME_CHANGED", function() M:UpdateAll() end)
end

function M:Initialize()
    for _, unit in ipairs(UNITS) do
        local default = ns.DEFAULTS.unitFrames[unit]
        frames[unit] = CreateUnitFrame(unit, default)
        PositionFrame(frames[unit])
    end

    if ns:DB().unitFrames.hideBlizzard then
        self:SuppressBlizzard(true)
    end

    self:RegisterEvents()
    self:UpdateAll()
end

function M:SetEnabled(enabled)
    for _, frame in pairs(frames) do
        local show = enabled and UnitExists(frame.unit)
        frame:SetShown(show and true or false)
    end
end

ns:Register("UnitFrames", M)
