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

-- -- Settings ----------------------------------------------------------------

local function Shared(key)
    local stored = (ns:DB().unitFrames or {})[key]
    if stored ~= nil then return stored end
    return (ns.DEFAULTS.unitFrames or {})[key]
end

--- One setting for one unit: the stored value wins, then the shipped per-unit
-- default, then the shared option block (border / split / textColorByPercent).
-- Everything is read from MonetUIDB so the numbers stay tweakable without a
-- code change.
local function Setting(unit, key)
    local stored = (ns:DB().unitFrames or {})[unit]
    local value = stored and stored[key]
    if value ~= nil then return value end
    local fallback = (ns.DEFAULTS.unitFrames or {})[unit]
    value = fallback and fallback[key]
    if value ~= nil then return value end
    return Shared(key)
end

local function UnitGeometry(unit)
    return Setting(unit, "width")  or 160,
           Setting(unit, "health") or 2,
           Setting(unit, "power")  or 1
end

local function FrameChrome()
    return Shared("border") or 1, Shared("split") or 1
end

-- -- Health colours ------------------------------------------------------------

--- The "current" part of a health bar.
--   "highlight" : the Monet signature wash            (player, pet)
--   "class"     : the colour the game itself draws the unit in (target, focus)
--   "health"    : the flat UI health green
-- UnitSelectionColor gives class colours for players and reaction colours for
-- NPCs in a single call, and -- unlike UnitClass -- it is never secret, so no
-- identity guard is needed even in combat.
local function FillColor(unit)
    local style = Setting(unit, "fillColor")
    if style == "class" then
        local ok, r, g, b = pcall(UnitSelectionColor, unit)
        if ok and r then return r, g, b, 1 end
    elseif style == "health" then
        return Color:GetHealth()
    end
    local r, g, b = Color:GetHighlight()
    return r, g, b, 1
end

--- The *missing* part of a health bar.  It is pure background, so it needs no
-- unit value at all and stays correct while the client hides health.
local function LostColor(unit)
    if Setting(unit, "lostColor") == "danger" then
        return Color:GetDanger()
    end
    return 0, 0, 0, 1
end

local function UpdateHealthColor(frame)
    frame.health:SetStatusBarColor(FillColor(frame.unit))

    local lost = frame.healthLost
    if lost then
        local r, g, b, a = LostColor(frame.unit)
        lost:SetVertexColor(r, g, b, a or 1)
    end
end

-- -- Dead / offline -----------------------------------------------------------

--- Is this unit dead, a ghost or disconnected?  Both calls return plain
-- booleans and are safe in combat; Secrets.Bool only guards against a build that
-- starts hiding them.
local function IsUnavailable(unit)
    if not UnitExists(unit) then return false end
    if Secrets.Bool(UnitIsDeadOrGhost(unit), false) then return true end
    return not Secrets.Bool(UnitIsConnected(unit), true)
end

--- Grey the bars out rather than recolouring them by hand: the client performs
-- the desaturation, so it keeps working while the bar values are hidden.
local function UpdateDesaturation(frame)
    local grey = IsUnavailable(frame.unit)

    if frame.health then frame.health:SetStatusBarDesaturated(grey) end
    if frame.power  then frame.power:SetStatusBarDesaturated(grey)  end

    -- The class-resource pips empty out on death anyway, but greying them keeps
    -- the whole player frame reading the same way.
    local pips = frame.classPower and frame.classPower.pips
    if pips then
        for i = 1, #pips do
            pips[i]:SetStatusBarDesaturated(grey)
        end
    end

    -- A dead unit has no health left, so the bar shows its *missing* overlay end
    -- to end -- and that overlay is a plain texture the client will not
    -- desaturate for us.  Grey it by hand so a corpse still reads as a corpse.
    local lost = frame.healthLost
    if lost then
        if grey then
            local r, g, b = Color:GetNeutral()
            lost:SetVertexColor(r, g, b, 1)
        else
            lost:SetVertexColor(LostColor(frame.unit))
        end
    end
end

--- Everything about a bar that does not depend on its current value.
local function UpdateBarLook(frame)
    UpdateHealthColor(frame)
    UpdateDesaturation(frame)
end

-- -- Power colour -------------------------------------------------------------

-- A unit can change power type at runtime (shapeshifts, stances, vehicles,
-- encounter mechanics), so this is re-read on every UNIT_DISPLAYPOWER rather
-- than decided once.  UnitPowerType returns both the token and the client's own
-- colour for it; the table below only overrides the ones worth tuning, and
-- anything unknown falls through to the client colour and then to the theme.
local POWER_COLOR = {
    MANA           = { 0.20, 0.50, 0.90 },
    RAGE           = { 0.85, 0.20, 0.20 },
    FOCUS          = { 0.85, 0.45, 0.15 },
    ENERGY         = { 0.90, 0.85, 0.25 },
    COMBO_POINTS   = { 0.85, 0.35, 0.55 },
    RUNES          = { 0.45, 0.75, 0.85 },
    RUNIC_POWER    = { 0.30, 0.80, 0.90 },
    SOUL_SHARDS    = { 0.55, 0.35, 0.85 },
    LUNAR_POWER    = { 0.35, 0.45, 0.90 },
    HOLY_POWER     = { 0.95, 0.90, 0.55 },
    ALTERNATE      = { 0.55, 0.80, 0.35 },
    MAELSTROM      = { 0.25, 0.60, 0.95 },
    CHI            = { 0.60, 0.95, 0.85 },
    INSANITY       = { 0.55, 0.25, 0.75 },
    BURNING_EMBERS = { 0.90, 0.45, 0.10 },
    DEMONIC_FURY   = { 0.60, 0.35, 0.80 },
    ARCANE_CHARGES = { 0.35, 0.65, 0.95 },
    FURY           = { 0.80, 0.25, 0.55 },
    PAIN           = { 0.90, 0.50, 0.10 },
    ESSENCE        = { 0.45, 0.75, 0.85 },
}

local function UpdatePowerColor(frame)
    local unit = frame.unit

    if Setting(unit, "powerColor") == "theme" then
        frame.power:SetStatusBarColor(Color:GetResource())
        return
    end

    -- The token is a plain string; the extra guard keeps a client that starts
    -- hiding it from ever handing us a secret table key.
    local _, token, r, g, b = UnitPowerType(unit)
    local tuned = (type(token) == "string" and not Secrets.IsSecret(token))
                  and POWER_COLOR[token] or nil
    if tuned then
        frame.power:SetStatusBarColor(tuned[1], tuned[2], tuned[3])
        return
    end

    local nr, ng, nb = Secrets.Number(r), Secrets.Number(g), Secrets.Number(b)
    if nr and ng and nb and (nr + ng + nb) > 0 then
        frame.power:SetStatusBarColor(nr, ng, nb)
        return
    end

    frame.power:SetStatusBarColor(Color:GetResource())
end

-- -- Class resource (combo points) ----------------------------------------------

-- Blizzard draws the player's class resource -- a rogue's or a feral druid's
-- combo points -- inside PlayerFrame.classPowerBar, and its alternate power bar
-- in PlayerFrame.powerBarAlt.  Both are *children* of PlayerFrame, so hiding
-- PlayerFrame (see SuppressBlizzard) takes them off screen with it: a rogue
-- would keep the energy bar drawn above and lose the combo points entirely.
-- This block is the replacement -- one slim pip per combo point, under the frame.
--
-- Only the classes the Forever client actually has a combo point resource for are
-- listed.  Holy power / chi / soul shards / arcane charges / essence do not exist
-- on this build, so they are not drawn.
--
-- Nothing here ever does maths on a unit value: every pip is a StatusBar whose
-- range is (i - 1, i), so handing it the raw point count lets the *client* clamp
-- and decide which pips are lit, exactly like the health/power bars
-- (see Utils/Secrets.lua).
local POWER = (_G.Enum and _G.Enum.PowerType) or {}
local COMBO_POINTS = POWER.ComboPoints or 4
local ENERGY       = POWER.Energy      or 3

-- Per class: the power the resource lives in, its `POWER_COLOR` token, how many
-- pips to draw before the client tells us the real maximum, and an optional gate
-- on the unit's *primary* power type (a druid only has combo points as a cat).
--
-- Death knight runes are deliberately absent too: six runes are cooldown-driven
-- rather than points, and UnitPower(Runes) is not what the client animates for
-- them (the reference implementations read GetRuneCooldown instead).
local CLASS_POWER = {
    ROGUE = { power = COMBO_POINTS, token = "COMBO_POINTS", max = 5 },
    DRUID = { power = COMBO_POINTS, token = "COMBO_POINTS", max = 5,
              requirePower = ENERGY },
}

-- Defensive ceiling: a garbage maximum must not build a hundred bars.
local MAX_PIPS = 10

--- The player's class file name ("ROGUE", ...), read once and cached.
-- UnitClassBase is preferred (it never hands back a localised name); both calls
-- are pcall'd because identity can be hidden from addons in restricted states.
local playerClass
local function PlayerClass()
    if playerClass then return playerClass end

    local class
    if _G.UnitClassBase then
        local ok, file = pcall(_G.UnitClassBase, "player")
        if ok then class = file end
    end
    if not class and _G.UnitClass then
        local ok, _, file = pcall(_G.UnitClass, "player")
        if ok then class = file end
    end

    if type(class) == "string" then playerClass = class end
    return playerClass
end

--- Does this power event concern the frame's class resource?
-- UNIT_POWER_UPDATE hands over the power type *token* ("ENERGY",
-- "COMBO_POINTS", ...) and energy ticks several times a second, so anything
-- that is not the resource itself is skipped.  A missing or non-string token
-- (UNIT_MAXPOWER, a full refresh) always refreshes.
local function ClassPowerIn(frame, powerType)
    if not frame.classPower then return false end
    if type(powerType) ~= "string" then return true end

    local class = PlayerClass()
    local def = class and CLASS_POWER[class]
    return (not def) or powerType == def.token
end

--- Build the pip holder: an invisible strip under the player frame.
local function CreateClassPower(frame)
    local holder = CreateFrame("Frame", nil, frame)
    holder:SetSize(Setting(frame.unit, "width") or 160, Shared("classPowerHeight") or 3)
    holder:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -(Shared("classPowerGap") or 3))
    holder.pips = {}
    frame.classPower = holder
    holder:Hide()
    return holder
end

--- (Re)build the pips so that `count` of them fill the holder.
local function LayoutClassPower(holder, count)
    local gap = Shared("classPowerGap") or 3
    local pipWidth = (holder:GetWidth() - (count - 1) * gap) / count
    if pipWidth < 1 then pipWidth = 1 end

    for i = 1, count do
        local pip = holder.pips[i]
        if not pip then
            -- Widget:Bar already brings the dim "empty" background along.
            pip = Widget:Bar(holder)
            pip:SetHeight(holder:GetHeight())
            holder.pips[i] = pip
        end

        pip:ClearAllPoints()
        if i > 1 then
            pip:SetPoint("LEFT", holder.pips[i - 1], "RIGHT", gap, 0)
        else
            pip:SetPoint("LEFT", holder, "LEFT", 0, 0)
        end
        pip:SetWidth(pipWidth)
        pip:Show()
    end

    for i = count + 1, #holder.pips do
        holder.pips[i]:Hide()
    end

    holder.count = count
end

--- Refresh the player's class resource pips.
local function UpdateClassPower(frame)
    local holder = frame.classPower
    if not holder then return end

    local class = PlayerClass()
    local def = class and CLASS_POWER[class]
    if not def or Shared("classPower") == false then
        holder:Hide()
        return
    end

    local unit = frame.unit

    -- Shapeshifters only have the resource in one form (a druid's combo points
    -- exist while it is a cat).  UnitPowerType reports the *primary* power and is
    -- never secret, so it is a safe gate; UNIT_DISPLAYPOWER drives it.
    if def.requirePower and UnitPowerType(unit) ~= def.requirePower then
        holder:Hide()
        return
    end

    local maximum = Secrets.Number(UnitPowerMax(unit, def.power))
    if maximum and maximum <= 0 then
        holder:Hide()   -- this class / spec does not have the resource
        return
    end

    -- A hidden maximum must not re-layout the row: keep the last count we could
    -- read, or the class default before the first readable one.
    local count = maximum or holder.count or def.max
    if count > MAX_PIPS then count = MAX_PIPS end
    if count ~= holder.count then
        LayoutClassPower(holder, count)
    end

    local current = UnitPower(unit, def.power)
    local r, g, b = Color:GetResource()
    local tuned = POWER_COLOR[def.token]
    if tuned then r, g, b = tuned[1], tuned[2], tuned[3] end

    -- "Full" is the one state worth shouting about (the reference UIs tint it
    -- too); it needs both numbers readable, so a secret pair keeps the colour.
    local cur = Secrets.Number(current)
    if cur and maximum and cur >= maximum then
        r, g, b = Color:GetDanger()
    end

    for i = 1, holder.count do
        local pip = holder.pips[i]
        pip:SetStatusBarColor(r, g, b)
        pcall(pip.SetMinMaxValues, pip, i - 1, i)
        pcall(pip.SetValue, pip, current)
    end

    holder:Show()
end

--- The interpolation to hand to the client: nil means "snap straight to it".
-- Easing is a user-facing preference, so it is read from the saved settings.
local function Smoothing()
    if Shared("smoothBars") == false then return nil end
    return Secrets.SMOOTH
end

--- Health-percentage ramp for the numeric text.  Explicit stops are interpolated
-- rather than lerping red straight to green, which would pass through a muddy
-- brown in the middle (and stay hard to read for colour-blind players).
local HEALTH_RAMP = {
    { at = 1.00, r = 0.40, g = 0.88, b = 0.42 },
    { at = 0.60, r = 0.94, g = 0.86, b = 0.36 },
    { at = 0.30, r = 0.95, g = 0.58, b = 0.24 },
    { at = 0.00, r = 0.94, g = 0.26, b = 0.26 },
}

local function PercentColor(pct)
    if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
    for i = 1, #HEALTH_RAMP - 1 do
        local high, low = HEALTH_RAMP[i], HEALTH_RAMP[i + 1]
        if pct >= low.at then
            local span = high.at - low.at
            local t = span > 0 and (pct - low.at) / span or 0
            return low.r + (high.r - low.r) * t,
                   low.g + (high.g - low.g) * t,
                   low.b + (high.b - low.b) * t
        end
    end
    local last = HEALTH_RAMP[#HEALTH_RAMP]
    return last.r, last.g, last.b
end

-- -- Text ---------------------------------------------------------------------

local function UpdateName(frame)
    local unit = frame.unit
    if not UnitExists(unit) then return end

    -- Colouring follows identity, so it is refreshed here -- the pet frame has
    -- no name text but still needs its bar coloured.
    UpdateBarLook(frame)

    local nameText = frame.name
    if not nameText then return end   -- pet frames carry no text

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

    Secrets.SetBar(frame.health, UnitHealth(unit), UnitHealthMax(unit), Smoothing())
    UpdateDesaturation(frame)

    local healthText = frame.healthText
    if not healthText then return end -- pet frames carry no text

    if Secrets.CanMeasureHealth(unit) then
        local current = Secrets.Number(UnitHealth(unit))
        local maximum = Secrets.Number(UnitHealthMax(unit))
        if current and maximum and maximum > 0 then
            healthText:SetText(Math:ShortNumber(current) .. " / " .. Math:ShortNumber(maximum))
            if Setting(unit, "textColorByPercent") ~= false then
                healthText:SetTextColor(PercentColor(current / maximum))
            end
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

    Secrets.SetBar(frame.power, UnitPower(unit), UnitPowerMax(unit), Smoothing())
    UpdatePowerColor(frame)
    UpdateDesaturation(frame)

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

-- -- Edge glow states ---------------------------------------------------------
-- The frame border doubles as a live signal (the Andromeda idea), but the
-- colour runs through Widget:SetBorderState so the theme-refresh broadcast
-- re-applies the *state* instead of stomping it.  Priority:
-- threat > hover > themed border.

--- The glow colour for a threat status, ramping through the Monet palette
-- instead of borrowing Blizzard's raw red / orange / yellow:
--   1 insecure  -> primary (warm ochre)
--   2           -> primary/danger blend
--   3 high      -> danger
--   4 tanking   -> health (you hold it: this reads "safe")
local function ThreatBorder(status)
    if status == 4 then return Color:GetHealth() end
    if status == 3 then return Color:GetDanger() end
    if status == 2 then return Color:Blend("primary", "danger", 0.6) end
    return Color:GetPrimary()
end

--- Re-evaluate the threat glow for one frame.  A *secret* status (this client
-- hides threat state while restricted, see Secrets) must not raise and must
-- not clear a glow that is still true: the last known state is kept, and the
-- PLAYER_REGEN_ENABLED refresh re-evaluates it.
local function UpdateThreat(frame)
    if not Shared("threatGlow") then return end

    -- nil means both "no threat API answer" and "value hidden by the client".
    local status = Secrets.Number(UnitThreatSituation(frame.unit))
    if status == nil then return end

    frame.threatStatus = status
    if status > 0 then
        local r, g, b, a = ThreatBorder(status)
        Widget:SetBorderState(frame, r, g, b, a)
    elseif not (frame.IsMouseOver and frame:IsMouseOver()) then
        -- Drop the glow; when the cursor is on the frame, the hover wash that
        -- is already applied stays until OnLeave.
        Widget:SetBorderState(frame, nil)
    end
end

--- Hover: the border washes to the highlight slot.  A 1px wash matches the
-- Monet language better than Andromeda's PetBattle glow art.  HookScript,
-- because Widget:UnitTooltip already owns OnEnter / OnLeave.
local function HoverBorder(frame, enter)
    if not Shared("hoverGlow") then return end
    if frame.threatStatus and frame.threatStatus > 0 then return end

    if enter then
        local r, g, b, a = Color:GetHighlight()
        Widget:SetBorderState(frame, r, g, b, a)
    else
        Widget:SetBorderState(frame, nil)
    end
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

    -- The *missing* part of the bar: a plain texture behind the fill.  A
    -- StatusBar only covers the health that is left, so this shows through
    -- exactly where the unit has taken damage -- and, unlike sizing an overlay,
    -- it never has to look at a unit value.  UpdateHealthColor tints it.
    local lost = health:CreateTexture(nil, "BACKGROUND")
    lost:SetAllPoints(health)
    lost:SetColorTexture(1, 1, 1, 1)

    local power = Widget:Bar(frame)
    power:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", border, border)
    power:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -border, border)
    power:SetHeight(powerHeight)
    power:SetStatusBarColor(Color:GetResource())

    frame.health = health
    frame.healthLost = lost
    frame.power = power

    -- The class resource (combo points ...) hangs under the player frame only:
    -- it is the unit that owns Blizzard's class power display.
    if unit == "player" then
        CreateClassPower(frame)
    end

    UpdateBarLook(frame)

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
    frame:HookScript("OnEnter", function(self) HoverBorder(self, true) end)
    frame:HookScript("OnLeave", function(self) HoverBorder(self, false) end)

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

function M:UpdateUnit(unit, kind, powerType)
    local frame = frames[unit]
    if not frame or not frame:IsShown() then return end
    if kind == "health" then
        UpdateHealth(frame)
    elseif kind == "power" then
        UpdatePower(frame)
        -- The resource shares the power events, but only the resource's own
        -- power type is worth a refresh (energy ticks all the time).
        if ClassPowerIn(frame, powerType) then
            UpdateClassPower(frame)
        end
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
        UpdateClassPower(frame)
        UpdateName(frame)
        UpdateThreat(frame)
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
    return function(_, changedUnit, ...)
        M:UpdateUnit(changedUnit, kind, ...)
    end
end

local function MakeThreatHandler()
    return function(_, changedUnit)
        local frame = frames[changedUnit]
        if frame and frame:IsShown() then UpdateThreat(frame) end
    end
end

function M:RegisterEvents()
    for unit in pairs(frames) do
        for event, kind in pairs(UNIT_EVENTS) do
            EventBus:RegisterUnit(event, unit, MakeUnitHandler(kind))
        end
        -- Threat glow.  This client carries the classic-era event name;
        -- retail's UNIT_THREAT_SITUATION_CHANGED is not in its API manual and
        -- would fail registration silently.
        EventBus:RegisterUnit("UNIT_THREAT_SITUATION_UPDATE", unit, MakeThreatHandler())
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
    -- Death / resurrection: the bars grey out and come back.
    EventBus:Register("PLAYER_DEAD", function() M:UpdateAll() end)
    EventBus:Register("PLAYER_ALIVE", function() M:UpdateAll() end)
    EventBus:Register("PLAYER_UNGHOST", function() M:UpdateAll() end)
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
