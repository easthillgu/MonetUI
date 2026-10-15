-- Modules/UnitFrames/UnitFrames.lua
-- Player / target / focus / pet unit frames in Andromeda's slim-bar style.
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
    player       = "玩家",
    target       = "目标",
    targettarget = "目标的目标",
    focus        = "焦点",
    pet          = "宠物",
}

-- Units we build a frame for (and therefore take over from Blizzard).
-- The order matters: every frame anchors to one earlier in the list
-- (targettarget hangs off target, which hangs off player).
local UNITS = { "player", "target", "targettarget", "focus", "pet" }

-- Where each unit's text sits, following Andromeda's tag anchors: everything is
-- drawn just above the bar, clear of the frame's top edge.
--   name       "LEFT" (above-left) | "RIGHT" (above-right) | "CENTER" (above)
--   level      true when the level is drawn beside the name
--   healthText "LEFT" | "RIGHT"
-- Andromeda gives the player health/power above its bar, the target health left
-- and name right, the focus a centred name and the target-of-target a centred
-- name; its pet frames carry no text at all (60px is too narrow for a name),
-- which MonetUI keeps.
local TEXT_LAYOUT = {
    player       = { name = "LEFT",   level = true,  healthText = "RIGHT" },
    target       = { name = "RIGHT",  level = true,  healthText = "LEFT"  },
    targettarget = { name = "CENTER", level = false                       },
    focus        = { name = "CENTER", level = false                       },
    pet          = {},
}

local TEXT_GAP   = 3   -- Andromeda's offset from the frame's top edge
local NAME_SIZE  = 12
local SMALL_SIZE = 11

-- Blizzard frames we optionally take over.  Note the capitalisation: the frame
-- globals are PlayerFrame / TargetFrame / FocusFrame / PetFrame, not
-- unit .. "Frame", so they must be looked up explicitly.
local BLIZZARD_FRAMES = {
    player       = "PlayerFrame",
    target       = "TargetFrame",
    targettarget = "TargetFrameToT",
    focus        = "FocusFrame",
    pet          = "PetFrame",
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

-- -- Geometry ----------------------------------------------------------------

--- Per-unit width and bar heights, with the stored value winning over the
-- shipped default so the numbers stay tweakable from MonetUIDB.
local function UnitGeometry(unit)
    local stored  = ns:DB().unitFrames[unit] or {}
    local default = ns.DEFAULTS.unitFrames[unit] or {}
    return stored.width  or default.width  or 160,
           stored.health or default.health or 4,
           stored.power  or default.power  or 1
end

local function FrameChrome()
    local db = ns:DB().unitFrames
    return db.border or 1, db.split or 1
end

-- -- Text ---------------------------------------------------------------------

local function UpdateName(frame)
    local nameText = frame.name
    if not nameText then return end   -- pet frames carry no text
    local unit = frame.unit
    if not UnitExists(unit) then return end

    local name, classFile
    if Secrets.CanReadIdentity(unit) then
        name = UnitName(unit)
        local _, class = UnitClass(unit)
        classFile = class
    end
    nameText:SetText(name or frame.label)

    local r, g, b = Color:ClassColor(classFile)
    if not r then
        r, g, b = Color:GetEdge()
    end
    nameText:SetTextColor(r, g, b, 1)

    local levelText = frame.level
    if levelText then
        local level = Secrets.Number(UnitLevel(unit))
        if level and level > 0 then
            levelText:SetText("Lv" .. level)
        elseif level == -1 then
            levelText:SetText("??")
        else
            levelText:SetText("")
        end
    end
end

local function UpdateHealth(frame)
    local unit = frame.unit
    if not UnitExists(unit) then return end

    Secrets.SetBar(frame.health, UnitHealth(unit), UnitHealthMax(unit))

    local healthText = frame.healthText
    if not healthText then return end -- pet frames carry no text

    if Secrets.CanMeasureHealth(unit) then
        local current = Secrets.Number(UnitHealth(unit))
        local maximum = Secrets.Number(UnitHealthMax(unit))
        if current and maximum and maximum > 0 then
            healthText:SetText(Math:ShortNumber(current) .. " / " .. Math:ShortNumber(maximum))
        else
            healthText:SetText("")
        end
    else
        -- restricted: keep the bar, hide the numbers
        healthText:SetText("")
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

-- -- Construction -------------------------------------------------------------

--- Resolve the frame a stored position is anchored to.
-- "UIParent" (or nil) means the screen; anything else names another unit frame
-- built by this module, which lets target / focus / pet follow the player.
local function ResolveRelative(stored)
    local name = stored.relativeTo
    if not name or name == "UIParent" then return UIParent end
    return frames[name] or UIParent
end

local function PositionFrame(frame)
    local db = ns:DB()
    local stored = (db.unitFrames and db.unitFrames[frame.unit]) or frame.position or {}
    local point = stored.point or "CENTER"
    local relativePoint = stored.relativePoint or point
    frame:ClearAllPoints()
    frame:SetPoint(point, ResolveRelative(stored), relativePoint, stored.x or 0, stored.y or 0)
end

--- A FontString anchored above the bar: side "LEFT", "RIGHT" or "CENTER".
local function TextAbove(frame, side, size, key, colorKey, justify)
    local text = Widget:Font(frame, size, key, colorKey, justify or side)
    if side == "CENTER" then
        text:SetPoint("BOTTOM", frame, "TOP", 0, TEXT_GAP)
    elseif side == "RIGHT" then
        text:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, TEXT_GAP)
    else
        text:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, TEXT_GAP)
    end
    return text
end

local function CreateUnitFrame(unit, position)
    local border, split = FrameChrome()
    local width, healthHeight, powerHeight = UnitGeometry(unit)
    local height = border * 2 + healthHeight + split + powerHeight

    local frame = Widget:CreateFrame("MonetUI" .. unit:gsub("^%l", string.upper) .. "Frame",
        UIParent, width, height)
    frame.unit = unit
    frame.label = UNIT_LABEL[unit] or unit

    -- Slim bars: health hugs the top inset, power the bottom one.
    local health = Widget:Bar(frame, width - border * 2, healthHeight)
    health:SetPoint("TOPLEFT", frame, "TOPLEFT", border, -border)
    health:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -border, -border)
    health:SetStatusBarColor(Color:GetHealth())

    local power = Widget:Bar(frame)
    power:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", border, border)
    power:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -border, border)
    power:SetHeight(powerHeight)
    power:SetStatusBarColor(Color:GetResource())

    frame.health = health
    frame.power = power

    local layout = TEXT_LAYOUT[unit] or {}
    if layout.name then
        frame.name = TextAbove(frame, layout.name, NAME_SIZE, "pixel", "edge",
            layout.name == "CENTER" and "CENTER" or layout.name)
    end

    if frame.name and layout.level then
        -- Beside the name, on the inner side so it never leaves the bar.
        local level = Widget:Font(frame, SMALL_SIZE, "pixel", "neutral",
            layout.name == "RIGHT" and "RIGHT" or "LEFT")
        if layout.name == "RIGHT" then
            level:SetPoint("RIGHT", frame.name, "LEFT", -5, 0)
        else
            level:SetPoint("LEFT", frame.name, "RIGHT", 5, 0)
        end
        frame.level = level
    end

    if layout.healthText then
        frame.healthText = TextAbove(frame, layout.healthText, SMALL_SIZE, "pixel",
            { r = 1, g = 1, b = 1 })
    end

    Widget:Theme(frame, { thickness = border, bgAlpha = 0.9 })
    Widget:UnitTooltip(frame, unit)

    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, relativeTo, relativePoint, x, y = self:GetPoint()
        local db = ns:DB()
        local stored = db.unitFrames[unit]
        stored.point         = point
        stored.relativeTo    = (relativeTo == UIParent) and "UIParent"
                               or (relativeTo and relativeTo.unit) or "UIParent"
        stored.relativePoint = relativePoint
        stored.x = Math:Round(x, 0)
        stored.y = Math:Round(y, 0)

        -- Re-anchor in dependency order so anything hanging off this frame
        -- (directly or through a chain, e.g. player -> target -> targettarget)
        -- follows it.
        for _, name in ipairs(UNITS) do
            if frames[name] then PositionFrame(frames[name]) end
        end
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

--- Show / hide a frame for the unit and refresh all of its parts.
local function RefreshUnit(unit)
    local frame = frames[unit]
    if not frame then return end
    if UnitExists(unit) then
        frame:Show()
        UpdateHealth(frame)
        UpdatePower(frame)
        UpdateName(frame)
    else
        frame:Hide()
    end
end

function M:UpdateAll()
    for _, unit in ipairs(UNITS) do
        RefreshUnit(unit)
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
        RefreshUnit("target")
        RefreshUnit("targettarget")
    end)

    -- A new target means a new target-of-target.
    EventBus:Register("UNIT_TARGET", function(_, unit)
        if unit == "target" then RefreshUnit("targettarget") end
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
