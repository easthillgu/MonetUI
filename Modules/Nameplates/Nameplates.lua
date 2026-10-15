-- Modules/Nameplates/Nameplates.lua
-- Nameplates (姓名板) in the Monet slim-bar style.
--
-- Built *on top of* Blizzard's nameplates rather than from scratch: for every
-- unit in the world the client already hands out one "base" frame
-- (C_NamePlate.GetNamePlateForUnit), the box that flies over the unit's head and
-- owns targeting/clicks.  This module hangs its own bar on that base, hides
-- Blizzard's UnitFrame child and keeps drawing everything itself -- the same
-- approach Andromeda / ElvUI / Plater take (they use oUF for the frame part),
-- without pulling oUF in.
--
-- Two "Forever" client rules shape the code (see Utils/Secrets.lua):
--
--   * Health, cast and threat values may arrive as <secret>.  A secret value can
--     be handed straight to a widget (StatusBar/FontString accept them), but the
--     moment *our* code does arithmetic, comparison, formatting or a length on
--     one the client raises.  So the bars are fed the raw values and only text
--     that needs a number (health %, level, cast timer) is produced after asking
--     the client whether the value is plain.
--   * Auras cannot be read at all while restricted -- and that is exactly when
--     they matter.  The module therefore never reads an aura: Blizzard's own
--     per-plate aura frame is reparented onto our plate and the *game* keeps
--     drawing the debuffs (the trick ForeverUI documents).
--
-- Not done in this version: name-only plates, plate stacking/spacing CVars,
-- class power on the target plate, and drag support for the plates (they follow
-- Blizzard's plate position, which the game itself keeps above the unit).

local ADDON_NAME, ns = ...

local Secrets  = ns.Secrets
local Widget   = ns.Widget
local Color    = ns.Color
local EventBus = ns.EventBus

local M = { name = "Nameplates" }

local plates = {}   -- unit token ("nameplate3") -> our plate frame
local driverHooked = false

-- -- Geometry constants -------------------------------------------------------

local BORDER   = 1
local TEXT_GAP = 3     -- the gap the unit frames keep above their bars
local CAST_GAP = 4

-- -- Settings ----------------------------------------------------------------

local function DB()
    local db = ns:DB()
    if type(db.nameplates) ~= "table" then db.nameplates = {} end
    return db.nameplates
end

--- One setting: what the player saved, else what shipped in Core's DEFAULTS.
local function Setting(key)
    local stored = DB()[key]
    if stored ~= nil then return stored end
    return (ns.DEFAULTS.nameplates or {})[key]
end

M.Setting = Setting

-- -- Client CVars ------------------------------------------------------------

-- Which units the *game* gives a plate to is a CVar, not something an addon can
-- decide after the fact, so the module steers these.  Every call goes through a
-- pcall: a client that has never heard of a CVar raises rather than shrugging,
-- and half of them come and go between builds.
local CVARS = {
    "nameplateShowFriends", "nameplateShowEnemies", "nameplateShowFriendlyNpcs",
    "nameplateShowEnemyMinus", "nameplateShowEnemyTotems", "nameplateShowFriendlyTotems",
    "nameplateShowSelf", "nameplateMaxDistance",
}

local savedCVars

local function ReadCVar(cvar)
    if not GetCVar then return nil end
    local ok, value = pcall(GetCVar, cvar)
    if ok then return value end
    return nil
end

local function WriteCVar(cvar, value)
    if not SetCVar then return end
    pcall(SetCVar, cvar, value)
end

local function OnOff(value)
    return (value ~= false) and "1" or "0"
end

--- Push the "who gets a plate" settings into the client.
function M:ApplyCVars()
    if not savedCVars then
        -- Remembered once, so turning the module off can hand the client back
        -- exactly as it was found for whatever nameplate addon runs next.
        savedCVars = {}
        for _, cvar in ipairs(CVARS) do
            savedCVars[cvar] = ReadCVar(cvar)
        end
    end

    WriteCVar("nameplateShowFriends",       OnOff(Setting("showFriendly")))
    WriteCVar("nameplateShowEnemies",       OnOff(Setting("showEnemy")))
    WriteCVar("nameplateShowFriendlyNpcs",  OnOff(Setting("showNPC")))
    WriteCVar("nameplateShowEnemyMinus",    Setting("showMinor") and "1" or "0")
    WriteCVar("nameplateShowEnemyTotems",   OnOff(Setting("showTotems")))
    WriteCVar("nameplateShowFriendlyTotems", OnOff(Setting("showTotems")))
    WriteCVar("nameplateShowSelf",          Setting("showSelf") and "1" or "0")
    WriteCVar("nameplateMaxDistance",       tostring(Setting("viewDistance") or 60))
end

function M:RestoreCVars()
    if not savedCVars then return end
    for cvar, value in pairs(savedCVars) do
        if value ~= nil then WriteCVar(cvar, value) end
    end
    savedCVars = nil
end

-- -- Hitbox size -------------------------------------------------------------

-- The clickable area of a nameplate is Blizzard's, not ours.  Matching it to the
-- box we draw keeps clicks precise: Blizzard's default box is far larger than a
-- slim Monet bar and overlaps its neighbours, so clicking the plate you see can
-- otherwise target the one behind it.  Three generations of the API exist and
-- only one of them is on any given build, so each is feature-detected and the
-- shared fallback is used when the per-side setters are missing.
local savedPlateSize

local function VisualSize()
    local width  = Setting("width")  or 120
    local height = Setting("height") or 12

    local textRow = 0
    if Setting("showName") ~= false or Setting("showLevel") ~= false then
        textRow = (Setting("nameSize") or 11) + TEXT_GAP
    end

    local castRow = 0
    if Setting("showCast") ~= false then
        castRow = (Setting("castHeight") or 13) + CAST_GAP
    end

    return width, height + textRow + castRow
end

--- Resize Blizzard's plate hitbox to the box this module draws.
function M:ApplyPlateSize()
    if Setting("forcePlateSize") == false then return end
    if InCombatLockdown and InCombatLockdown() then
        -- Protected territory: retried from PLAYER_REGEN_ENABLED.
        self.sizePending = true
        return
    end
    self.sizePending = nil

    local width, height = VisualSize()

    if not savedPlateSize and C_NamePlate and C_NamePlate.GetNamePlateSize then
        local ok, w, h = pcall(C_NamePlate.GetNamePlateSize)
        if ok then savedPlateSize = { w, h } end
    end

    if not C_NamePlate then return end

    local applied = false
    if type(C_NamePlate.SetNamePlateEnemySize) == "function" then
        applied = pcall(C_NamePlate.SetNamePlateEnemySize, width, height) or applied
    end
    if type(C_NamePlate.SetNamePlateFriendlySize) == "function" then
        applied = pcall(C_NamePlate.SetNamePlateFriendlySize, width, height) or applied
    end
    if not applied and type(C_NamePlate.SetNamePlateSize) == "function" then
        pcall(C_NamePlate.SetNamePlateSize, width, height)
    end
end

function M:RestorePlateSize()
    if not savedPlateSize or not C_NamePlate then return end
    local restore = function(fn)
        if type(fn) == "function" then pcall(fn, savedPlateSize[1], savedPlateSize[2]) end
    end
    restore(C_NamePlate.SetNamePlateEnemySize)
    restore(C_NamePlate.SetNamePlateFriendlySize)
    if type(C_NamePlate.SetNamePlateSize) == "function" then
        pcall(C_NamePlate.SetNamePlateSize, savedPlateSize[1], savedPlateSize[2])
    end
    savedPlateSize = nil
end

-- Blizzard's own driver recomputes plate sizes when CVars/settings change and
-- would put its default back; re-apply ours afterwards (the pattern Andromeda
-- uses).  Optional everywhere: the frame may not exist on every build.
function M:HookDriver()
    if driverHooked then return end
    local driver = _G.NamePlateDriverFrame
    if not driver or type(driver.UpdateNamePlateOptions) ~= "function"
        or type(hooksecurefunc) ~= "function" then
        return   -- not created yet: retried from PLAYER_ENTERING_WORLD
    end
    hooksecurefunc(driver, "UpdateNamePlateOptions", function()
        M:ApplyPlateSize()
    end)
    driverHooked = true
end

-- -- Filters ----------------------------------------------------------------

-- Every query is pcall'd: on this client a unit call can be refused outright in
-- a restricted state, and a filter must never take the whole plate down.
local function Query(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

-- A unit is one of four things: a friendly player, an enemy (player or npc), a
-- friendly npc, or a critter.  Friendly npcs are their own switch because the
-- client has its own CVar for them; everything hostile lands under the enemy
-- switch so an addon's enemy toggle really does mean "all enemies".
local function Category(unit)
    local friend = Secrets.Bool(Query(UnitIsFriend, "player", unit), false)
    local player = Secrets.Bool(Query(UnitIsPlayer, unit), false)
    if friend then
        return player and "friendly" or "npc"
    end
    return "enemy"
end

M.Category = Category

local function RuleFor(category)
    if category == "friendly" then return Setting("showFriendly") end
    if category == "enemy"    then return Setting("showEnemy") end
    return Setting("showNPC")
end

--- Is this unit supposed to show a MonetUI plate at all?
function M:ShouldShow(unit)
    if not unit or not Secrets.Bool(Query(UnitExists, unit), false) then
        return false
    end

    if Setting("hideDead") and Secrets.Bool(Query(UnitIsDeadOrGhost, unit), false) then
        return false
    end

    if Setting("hideCritters") ~= false then
        -- Both of these can come back secret (identity restriction), so the
        -- string comparisons are guarded: type() is legal on a secret, == is not.
        local classification = Query(UnitClassification, unit)
        if type(classification) == "string" and not Secrets.IsSecret(classification)
            and classification == "minus" then
            return false
        end

        local creature = Query(UnitCreatureType, unit)
        if type(creature) == "string" and not Secrets.IsSecret(creature)
            and creature == "Critter" then
            return false
        end
    end

    return RuleFor(Category(unit)) ~= false
end

-- -- Colours -----------------------------------------------------------------

--- The bar colour: the game's own answer for class / reaction, with a tapped
-- unit going grey.  UnitSelectionColor gives class colours for players and
-- reaction colours for NPCs in one call and never returns a secret, so the
-- colour survives combat where the health number does not.
local function HealthColor(unit)
    if not Secrets.Bool(Query(UnitIsPlayer, unit), false)
        and Secrets.Bool(Query(UnitIsTapDenied, unit), false) then
        return Color:GetNeutral()
    end

    if Setting("classColor") ~= false then
        local ok, r, g, b = pcall(UnitSelectionColor, unit)
        if ok and type(r) == "number" then return r, g, b end
    end

    local reaction = Secrets.Number(Query(UnitReaction, "player", unit))
    if reaction then
        if reaction >= 5 then
            return 0.31, 0.65, 0.35          -- friendly
        elseif reaction == 4 then
            return 0.85, 0.77, 0.36          -- neutral
        elseif reaction == 3 then
            return 0.82, 0.45, 0.22          -- unfriendly
        end
        return 0.78, 0.25, 0.25              -- hostile
    end

    return Color:GetNeutral()
end

-- Elite / rare / boss marks, the same letters Blizzard's own plates use.
local CLASSIFICATION_MARK = {
    elite = "+", rareelite = "R+", rare = "R", worldboss = "B",
}

-- -- Geometry helpers --------------------------------------------------------

local function PlateWidth()  return Setting("width")  or 120 end
local function PlateHeight() return Setting("height") or 12  end

-- -- The plate itself --------------------------------------------------------

--- One plate: the health box, the name/level row above it and the cast bar under
--- it -- three pieces that all hang off the base frame Blizzard hands us.
local function Build(base)
    local width, height = PlateWidth(), PlateHeight()

    local plate = Widget:CreateFrame(nil, base, width, height)
    Widget:Theme(plate, { thickness = BORDER, bgAlpha = 0.92 })
    plate:SetPoint("CENTER", base, "CENTER", 0, 0)

    local health = Widget:Bar(plate, width - BORDER * 2, height - BORDER * 2)
    health:SetPoint("TOPLEFT", plate, "TOPLEFT", BORDER, -BORDER)
    health:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -BORDER, BORDER)

    -- The *missing* health, drawn under the fill: a plain texture (never a
    -- secret), so it gives the bar a dark "lost" body without reading a value.
    local lost = health:CreateTexture(nil, "BACKGROUND")
    lost:SetAllPoints(health)
    lost:SetVertexColor(0, 0, 0, 1)

    plate.health = health
    plate.healthLost = lost

    local nameSize = Setting("nameSize") or 11

    plate.name = Widget:Font(plate, nameSize, "pixel", { r = 1, g = 1, b = 1 }, "LEFT")
    plate.name:SetPoint("BOTTOMLEFT", plate, "TOPLEFT", 0, TEXT_GAP)
    plate.name:SetWordWrap(false)

    plate.level = Widget:Font(plate, nameSize, "pixel", "neutral", "RIGHT")
    plate.level:SetPoint("BOTTOMRIGHT", plate, "TOPRIGHT", 0, TEXT_GAP)

    plate.percent = Widget:Font(health, math.max(8, nameSize - 1), "pixel",
        { r = 1, g = 1, b = 1 }, "RIGHT")
    plate.percent:SetPoint("RIGHT", health, "RIGHT", -3, 0)

    -- Cast bar, hanging under the plate.
    local castHeight = Setting("castHeight") or 13
    local cast = Widget:CreateFrame(nil, plate, width, castHeight)
    Widget:Theme(cast, { thickness = BORDER, bgAlpha = 0.92 })
    cast:SetPoint("TOPLEFT", plate, "BOTTOMLEFT", 0, -CAST_GAP)

    local fill = Widget:Bar(cast, width - BORDER * 2, castHeight - BORDER * 2)
    fill:SetPoint("TOPLEFT", cast, "TOPLEFT", BORDER, -BORDER)
    fill:SetPoint("BOTTOMRIGHT", cast, "BOTTOMRIGHT", -BORDER, BORDER)

    local iconSize = castHeight - BORDER * 2
    local icon = Widget:Icon(fill, iconSize, "ARTWORK")
    icon:SetPoint("TOPLEFT", cast, "TOPLEFT", BORDER, -BORDER)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local timer = Widget:Font(cast, math.max(8, nameSize - 1), "pixel", "neutral", "RIGHT")
    timer:SetPoint("RIGHT", cast, "RIGHT", -3, 0)

    local text = Widget:Font(cast, math.max(8, nameSize - 1), "pixel",
        { r = 1, g = 1, b = 1 }, "LEFT")
    text:SetPoint("LEFT", icon, "RIGHT", 3, 0)
    text:SetPoint("RIGHT", timer, "LEFT", -3, 0)
    text:SetWordWrap(false)

    cast.fill = fill
    cast.icon = icon
    cast.text = text
    cast.timer = timer
    cast:Hide()

    plate.cast = cast
    plate.base = base
    plate.layoutDirty = true

    return plate
end

--- Re-apply geometry and fonts (settings can change at any moment).  Kept off
-- the per-event path: a plate only lays itself out when it was just built or
-- the player changed a setting (see UpdatePlate's layoutDirty check).
local function Layout(plate)
    local width, height = PlateWidth(), PlateHeight()
    local nameSize = Setting("nameSize") or 11
    local castHeight = Setting("castHeight") or 13

    plate:SetSize(width, height)
    plate.health:SetPoint("TOPLEFT", plate, "TOPLEFT", BORDER, -BORDER)
    plate.health:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -BORDER, BORDER)
    plate.health:SetStatusBarTexture(ns.Media:Texture("statusbar"))

    plate.name:SetShown(Setting("showName") ~= false)
    plate.level:SetShown(Setting("showLevel") ~= false)
    plate.name:SetFont(ns.Media:Font("pixel"), nameSize, "")
    plate.level:SetFont(ns.Media:Font("pixel"), nameSize, "")
    plate.percent:SetFont(ns.Media:Font("pixel"), math.max(8, nameSize - 1), "")
    plate.percent:SetShown(Setting("showPercent") ~= false)

    plate.cast:SetSize(width, castHeight)
    plate.cast.fill:SetStatusBarTexture(ns.Media:Texture("statusbar"))
    plate.cast.icon:SetSize(castHeight - BORDER * 2, castHeight - BORDER * 2)
    plate.cast:Hide()

    -- The name stops where the level starts, so a long name never runs under it.
    plate.name:ClearAllPoints()
    plate.level:ClearAllPoints()
    plate.name:SetPoint("BOTTOMLEFT", plate, "TOPLEFT", 0, TEXT_GAP)
    plate.level:SetPoint("BOTTOMRIGHT", plate, "TOPRIGHT", 0, TEXT_GAP)
    plate.name:SetPoint("RIGHT", plate.level, "LEFT", -4, 0)
end

-- -- Blizzard's plate, and the auras we borrow -------------------------------

--- Your debuffs: an addon cannot read auras while restricted, but Blizzard's
-- plate still can -- its AurasFrame goes on listing your Moonfire and Faerie
-- Fire on its own frames.  That child is moved onto our plate (the game keeps
-- drawing it, we only say where) and hung above the name row.  Plates are
-- pooled and reused, so this is redone for every plate that appears.
local function AnchorDebuffs(auras, plate)
    local list = auras and rawget(auras, "DebuffListFrame")
    if not list or type(list.SetPoint) ~= "function" then return end

    local gap = Setting("auraGap") or 4
    local textRow = 0
    if Setting("showName") ~= false or Setting("showLevel") ~= false then
        textRow = (Setting("nameSize") or 11) + TEXT_GAP
    end

    pcall(list.ClearAllPoints, list)
    pcall(list.SetPoint, list, "BOTTOMLEFT", plate, "TOPLEFT", 0, textRow + gap)
end

local function BlizzardUnitFrame(base)
    return base and rawget(base, "UnitFrame") or nil
end

--- Take the plate over: hide Blizzard's own box (kept around, not destroyed) and
-- borrow its aura list.  The frame is only hidden, so a later Restore gives the
-- unit back exactly what the game drew for it.
local function HideBlizzardPlate(base, plate)
    local uf = BlizzardUnitFrame(base)
    if not uf then return false end

    pcall(uf.Hide, uf)
    if uf.SetAlpha then pcall(uf.SetAlpha, uf, 0) end

    local auras = rawget(uf, "AurasFrame")
    if auras and Setting("showDebuffs") ~= false then
        if type(auras.SetParent) == "function" then pcall(auras.SetParent, auras, plate) end
        if type(auras.SetAlpha) == "function" then pcall(auras.SetAlpha, auras, 1) end
        auras.__monetPlate = plate
        plate.blizzardAuras = auras
        AnchorDebuffs(auras, plate)
    end

    -- Blizzard re-runs this when it relayouts its own plate; follow it or our
    -- borrowed aura list would be put back under the hidden frame.
    if type(hooksecurefunc) == "function" and type(uf.ApplyFrameOptions) == "function"
        and not uf.__monetAuraHook then
        uf.__monetAuraHook = true
        pcall(hooksecurefunc, uf, "ApplyFrameOptions", function(self)
            local a = rawget(self, "AurasFrame")
            if a and a.__monetPlate then AnchorDebuffs(a, a.__monetPlate) end
        end)
    end

    plate.blizzardUF = uf
    plate.blizzardHidden = true
    return true
end

--- Hand the plate back the way it was found (module off, or the unit filtered
-- out): Blizzard's box shown again, the aura list returned to it.
local function RestoreBlizzardPlate(base, plate)
    local uf = BlizzardUnitFrame(base)
    if uf then
        local auras = rawget(uf, "AurasFrame")
        if auras and rawget(auras, "__monetPlate") then
            auras.__monetPlate = nil
            if type(auras.SetParent) == "function" then pcall(auras.SetParent, auras, uf) end
        end
        if type(uf.ApplyFrameOptions) == "function" then
            pcall(uf.ApplyFrameOptions, uf)   -- the game re-anchors its own list
        end
        if uf.SetAlpha then pcall(uf.SetAlpha, uf, 1) end
        pcall(uf.Show, uf)
    end
    if plate then
        plate.blizzardHidden = nil
        plate.blizzardAuras = nil
    end
    return uf ~= nil
end

-- -- Cast bar ---------------------------------------------------------------

-- The bar's *fill* is driven by an OnUpdate that only ever computes with
-- GetTime() (our own plain number) and hands it to SetValue: the client clamps
-- it against the (possibly secret) start/end it was given, so the fill animates
-- correctly even while the cast times are hidden.  The *timer text* needs real
-- arithmetic, so it is only produced when the end time came back plain.
local function CastTick(plate)
    local cast = plate.cast
    if not cast or not plate.castEndMS then return end

    pcall(cast.fill.SetValue, cast.fill, GetTime() * 1000)

    if plate.castEndClock then
        local left = plate.castEndClock - GetTime()
        if left < 0 then left = 0 end
        if left < 10 then
            cast.timer:SetText(string.format("%.1f", left))
        else
            cast.timer:SetText(string.format("%d", math.floor(left + 0.5)))
        end
    else
        cast.timer:SetText("")
    end
end

local function HideCast(plate)
    local cast = plate.cast
    if not cast then return end
    plate.castEndMS = nil
    plate.castEndClock = nil
    plate:SetScript("OnUpdate", nil)
    cast:Hide()
end

--- Read the cast tuple without ever letting a restricted call break the plate.
-- type() is legal on a secret and reports the underlying type, so
-- `type(name) == "nil"` is the safe way to ask "is anything being cast".
-- Both queries start `name, displayName, texture, start, end, tradeskill` but
-- then diverge: a channel puts notInterruptible 7th, a cast 8th (castID is 7th).
local function CastInfo(channel, unit)
    local fn = channel and UnitChannelInfo or UnitCastingInfo
    if type(fn) ~= "function" then return nil end

    local result = { pcall(fn, unit) }
    if not result[1] then return nil end

    return result[2], result[4], result[5], result[6],
        (channel and result[7] or result[8])
end

local function UpdateCast(plate)
    local unit = plate.unit
    if not plate.cast then return end
    if Setting("showCast") == false or not unit then return HideCast(plate) end

    local name, texture, startMS, endMS, notInterruptible = CastInfo(false, unit)
    local channel = false
    if type(name) == "nil" then
        name, texture, startMS, endMS, notInterruptible = CastInfo(true, unit)
        channel = true
    end
    if type(name) == "nil" then return HideCast(plate) end

    -- Name and texture go straight to the widgets: FontString:SetText and
    -- Texture:SetTexture accept a secret.
    plate.cast.text:SetText(name)
    if type(texture) ~= "nil" then
        plate.cast.icon:SetTexture(texture)
        plate.cast.icon:Show()
    else
        plate.cast.icon:Hide()
    end

    -- Bars take the raw times; no arithmetic of ours touches them.
    pcall(plate.cast.fill.SetMinMaxValues, plate.cast.fill, startMS or 0, endMS or 1)
    plate.castEndMS = endMS

    -- Plain end => a real countdown; hidden end => the bar still moves but the
    -- number is left blank (see 4.6 in MonetUI.md).
    local endClock = Secrets.Number(endMS)
    plate.castEndClock = endClock and (endClock / 1000) or nil

    if Secrets.Bool(notInterruptible, false) then
        plate.cast.fill:SetStatusBarColor(Color:GetNeutral())
    elseif channel then
        plate.cast.fill:SetStatusBarColor(0.62, 0.62, 0.92)
    else
        plate.cast.fill:SetStatusBarColor(Color:GetResource())
    end

    plate.cast:Show()
    plate:SetScript("OnUpdate", CastTick)
end

-- -- Updating one plate ------------------------------------------------------

local function UpdateHealth(plate)
    local unit = plate.unit

    local interpolation = (Setting("smooth") ~= false) and Secrets.SMOOTH or nil
    Secrets.SetBar(plate.health, UnitHealth(unit), UnitHealthMax(unit), interpolation)

    local r, g, b = HealthColor(unit)
    plate.health:SetStatusBarColor(r, g, b)

    -- Dead / disconnected: the client greys the bar for us, and the "lost"
    -- overlay -- which has no player-visible value of its own -- is greyed by
    -- hand so a corpse still reads as a corpse (the same rule as the unit
    -- frames; see UpdateDesaturation there).
    local gone = Secrets.Bool(UnitIsDeadOrGhost(unit), false)
        or not Secrets.Bool(UnitIsConnected(unit), true)
    plate.health:SetStatusBarDesaturated(gone)
    if gone then
        local nr, ng, nb = Color:GetNeutral()
        plate.healthLost:SetVertexColor(nr, ng, nb, 1)
    else
        plate.healthLost:SetVertexColor(0, 0, 0, 1)
    end

    -- Percentage text needs real numbers, so it is only produced when the client
    -- says health is readable; the bar itself always fills.  Secrets.Number is
    -- what makes the division below safe: it hands back a plain number or nil.
    if Setting("showPercent") ~= false and Secrets.CanMeasureHealth(unit) then
        local current = Secrets.Number(UnitHealth(unit))
        local maximum = Secrets.Number(UnitHealthMax(unit))
        if current and maximum and maximum > 0 then
            local percent = current / maximum * 100
            plate.percent:SetText(string.format("%d%%", math.floor(percent + 0.5)))
        else
            plate.percent:SetText("")
        end
    else
        plate.percent:SetText("")
    end
end

local function UpdateText(plate)
    local unit = plate.unit

    local name = Query(UnitName, unit)
    if type(name) == "string" then
        -- Truncating needs a length, which a secret refuses -- so a hidden name
        -- is drawn whole and only a plain one is shortened.
        if not Secrets.IsSecret(name) and Setting("truncate") ~= false then
            local limit = Setting("nameLength") or 16
            if #name > limit then name = name:sub(1, limit) .. "..." end
        end
        plate.name:SetText(name)
    else
        plate.name:SetText("")
    end

    local parts = {}
    if Setting("showLevel") ~= false then
        local level = Secrets.Number(Query(UnitLevel, unit))
        if level and level > 0 then
            parts[#parts + 1] = "Lv" .. level
        elseif level == -1 then
            parts[#parts + 1] = "??"
        end

        local classification = Query(UnitClassification, unit)
        if type(classification) == "string" and not Secrets.IsSecret(classification) then
            local mark = CLASSIFICATION_MARK[classification]
            if mark then parts[#parts + 1] = mark end
        end
    end
    plate.level:SetText(table.concat(parts, " "))
end

--- The border says what the unit is doing to you: threat first, then your
--- target.  UnitThreatSituation can be secret, so it goes through the guard and
--- simply keeps the theme colour when it cannot be read.
local function UpdateBorder(plate)
    local unit = plate.unit
    local r, g, b = Color:GetBorder()

    local status = nil
    if Setting("showThreat") ~= false then
        status = Secrets.Number(Query(UnitThreatSituation, "player", unit))
    end

    if status == 3 then
        r, g, b = 0.90, 0.20, 0.20
    elseif status == 2 or status == 1 then
        r, g, b = 0.95, 0.70, 0.25
    elseif Setting("highlightTarget") ~= false
        and Secrets.Bool(Query(UnitIsUnit, unit, "target"), false) then
        r, g, b = Color:GetHighlight()
    end

    if plate.SetBackdropBorderColor then
        plate:SetBackdropBorderColor(r, g, b, 1)
    end
    if plate.cast and plate.cast.SetBackdropBorderColor then
        plate.cast:SetBackdropBorderColor(r, g, b, 1)
    end
end

--- Blizzard can show its own UnitFrame again on any update; keep it hidden while
--- this plate is ours.
local function KeepBlizzardHidden(plate)
    local uf = plate.blizzardUF
    if not uf then return end
    if uf.IsShown and uf:IsShown() then
        pcall(uf.Hide, uf)
        if uf.SetAlpha then pcall(uf.SetAlpha, uf, 0) end
    end
end

local function UpdatePlate(plate)
    local unit = plate.unit
    if not unit or not Secrets.Bool(Query(UnitExists, unit), false) then
        plate:Hide()
        return false
    end

    if not M:ShouldShow(unit) then
        -- Filtered out: give the unit the plate the game would have drawn
        -- (widgets, soft-target icon, Blizzard's own look) and stand down.
        if plate.blizzardHidden then RestoreBlizzardPlate(plate.base, plate) end
        plate:Hide()
        HideCast(plate)
        return false
    end

    if not plate.blizzardHidden then
        HideBlizzardPlate(plate.base, plate)
    else
        KeepBlizzardHidden(plate)
    end

    if plate.layoutDirty then
        Layout(plate)
        plate.layoutDirty = nil
    end

    plate:Show()
    UpdateHealth(plate)
    UpdateText(plate)
    UpdateBorder(plate)
    UpdateCast(plate)
    return true
end

M.UpdatePlate = UpdatePlate

function M:UpdateAll()
    for _, plate in pairs(plates) do
        UpdatePlate(plate)
    end
end

-- -- Plate lifecycle ---------------------------------------------------------

-- One handler on the plate itself: the unit events are registered per plate with
-- RegisterUnitEvent, so only the plates on screen cost anything.
local PLATE_EVENTS = {
    UNIT_HEALTH = true, UNIT_MAXHEALTH = true,
    UNIT_NAME_UPDATE = true, UNIT_LEVEL = true,
    UNIT_FACTION = true, UNIT_CONNECTION = true,
}

local THREAT_EVENTS = {
    UNIT_THREAT_SITUATION_UPDATE = true, UNIT_THREAT_LIST_UPDATE = true,
}

local CAST_EVENTS = {
    UNIT_SPELLCAST_START = true, UNIT_SPELLCAST_STOP = true,
    UNIT_SPELLCAST_FAILED = true, UNIT_SPELLCAST_INTERRUPTED = true,
    UNIT_SPELLCAST_DELAYED = true, UNIT_SPELLCAST_CHANNEL_START = true,
    UNIT_SPELLCAST_CHANNEL_UPDATE = true, UNIT_SPELLCAST_CHANNEL_STOP = true,
    UNIT_SPELLCAST_INTERRUPTIBLE = true, UNIT_SPELLCAST_NOT_INTERRUPTIBLE = true,
}

local UNIT_EVENTS = {
    "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_NAME_UPDATE", "UNIT_LEVEL",
    "UNIT_FACTION", "UNIT_CONNECTION",
    "UNIT_THREAT_SITUATION_UPDATE", "UNIT_THREAT_LIST_UPDATE",
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_INTERRUPTIBLE",
    "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
}

local function OnPlateEvent(plate, event)
    if not plate.unit or not plates[plate.unit] then return end

    if CAST_EVENTS[event] then
        if event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP"
            or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
            -- The cast that just ended can still read back stale, so the end is
            -- taken from the event, not from a fresh query.
            HideCast(plate)
        else
            UpdateCast(plate)
        end
        return
    end

    if THREAT_EVENTS[event] then
        UpdateBorder(plate)
        return
    end

    if PLATE_EVENTS[event] then
        UpdatePlate(plate)
    end
end

--- Attach to the base frame Blizzard gave this unit.
local function Added(unit)
    local base = C_NamePlate and C_NamePlate.GetNamePlateForUnit
        and Query(C_NamePlate.GetNamePlateForUnit, unit) or nil
    if not base then return nil end

    local plate = rawget(base, "__monetPlate")
    if not plate then
        plate = Build(base)
        base.__monetPlate = plate
        plate:SetScript("OnEvent", OnPlateEvent)
    end

    plate.unit = unit
    plate:ClearAllPoints()
    plate:SetPoint("CENTER", base, "CENTER", 0, 0)
    plate:SetFrameLevel(base:GetFrameLevel() + 1)

    for _, event in ipairs(UNIT_EVENTS) do
        plate:RegisterUnitEvent(event, unit)
    end

    plates[unit] = plate
    UpdatePlate(plate)
    return plate
end

M.Added = Added

local function Removed(unit)
    local plate = plates[unit]
    if not plate then return false end

    plates[unit] = nil
    plate.unit = nil
    plate:UnregisterAllEvents()
    plate:SetScript("OnUpdate", nil)
    plate.castEndMS = nil
    plate.castEndClock = nil
    plate:Hide()
    plate.cast:Hide()
    -- The Blizzard unit frame is left hidden: whoever gets this pooled base next
    -- (us, on the next NAME_PLATE_UNIT_ADDED) will settle it again.
    return true
end

M.Removed = Removed

-- -- Events ------------------------------------------------------------------

function M:RegisterEvents()
    if self.eventsRegistered then return end
    self.eventsRegistered = true

    EventBus:Register("NAME_PLATE_UNIT_ADDED", function(_, unit)
        if not M.active then return end
        Added(unit)
    end)

    EventBus:Register("NAME_PLATE_UNIT_REMOVED", function(_, unit)
        if not M.active then return end
        Removed(unit)
    end)

    -- A new target re-tints every plate's border.
    EventBus:Register("PLAYER_TARGET_CHANGED", function()
        if not M.active then return end
        for _, plate in pairs(plates) do UpdateBorder(plate) end
    end)

    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        if not M.active then return end
        M:HookDriver()
        M:ApplyPlateSize()
        M:AbsorbExisting()
        M:UpdateAll()
    end)

    EventBus:Register("PLAYER_REGEN_ENABLED", function()
        if not M.active then return end
        if M.sizePending then M:ApplyPlateSize() end
        M:UpdateAll()
    end)

    -- Once a restriction lifts the numbers come back.
    EventBus:Register("MONETUI_RESTRICTION_CHANGED", function()
        if not M.active then return end
        M:UpdateAll()
    end)

    -- The theme listener in Utils/Widget.lua runs first (it is registered when
    -- Widget.lua loads), so the borders are re-tinted here after it, in the
    -- same tick.
    EventBus:Register("MONETUI_THEME_CHANGED", function()
        if not M.active then return end
        M:UpdateAll()
    end)
end

--- Pick up plates that were already up when the module (re)loaded: Blizzard
-- hands out nameplate tokens in a fixed range, so asking for each of them and
-- attaching to whatever exists is enough.
function M:AbsorbExisting()
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if Secrets.Bool(Query(UnitExists, unit), false) then
            Added(unit)
        end
    end
end

-- -- Public ------------------------------------------------------------------

--- Re-apply every setting: CVars, hitbox, then repaint the plates on screen.
-- The borrowed aura list is handed back first so a showDebuffs change is picked
-- up by the re-hide below (UpdateAll).
function M:Apply()
    if not ns:IsModuleEnabled("Nameplates") then return end

    for _, plate in pairs(plates) do
        plate.layoutDirty = true
        if plate.blizzardHidden and plate.base then
            RestoreBlizzardPlate(plate.base, plate)
        end
    end

    self:ApplyCVars()
    self:ApplyPlateSize()
    self:HookDriver()
    self:UpdateAll()
end

function M:Initialize()
    self.active = true
    self:RegisterEvents()
    self:HookDriver()
    self:ApplyCVars()
    self:ApplyPlateSize()
    self:AbsorbExisting()
end

--- Turning the module off is a real handover: each plate is given back to
-- Blizzard, every CVar the module steered is put back, and the plate size
-- returns to whatever it was.
function M:SetEnabled(enabled)
    enabled = enabled and true or false

    if enabled then
        self.active = true
        self:RegisterEvents()
        self:HookDriver()
        self:ApplyCVars()
        self:ApplyPlateSize()
        self:AbsorbExisting()
        self:UpdateAll()
        return
    end

    self.active = false
    for unit, plate in pairs(plates) do
        if plate.base then RestoreBlizzardPlate(plate.base, plate) end
        plate.unit = nil
        plate:UnregisterAllEvents()
        plate:SetScript("OnUpdate", nil)
        plate:Hide()
        plate.cast:Hide()
        plates[unit] = nil
    end

    self:RestoreCVars()
    self:RestorePlateSize()
end

ns:Register("Nameplates", M)
