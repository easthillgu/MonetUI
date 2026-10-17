-- Modules/Nameplates/Nameplates.lua
-- Nameplates (姓名板) in the Monet slim-bar style: our own bar hung on Blizzard's base plate
-- with their UnitFrame child hidden (the Andromeda / ElvUI / Plater approach, no oUF).  The game
-- keeps drawing the auras on a reparented frame; bars are fed raw (possibly secret) values.

local ADDON_NAME, ns = ...

local Secrets  = ns.Secrets
local Widget   = ns.Widget
local Color    = ns.Color
local EventBus = ns.EventBus

local M = { name = "Nameplates" }

local plates = {}   -- unit token ("nameplate3") -> our plate frame
local driverHooked = false

local BORDER   = 1
local TEXT_GAP = 3     -- the gap the unit frames keep above their bars
local CAST_GAP = 4

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

-- Which units the game gives a plate to is a CVar, not an addon decision, so the module
-- steers these; every call is pcall'd (unknown CVars raise, and they come and go per build).
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
        -- Saved once, so turning the module off hands the client back exactly as it was
        -- found (for whatever nameplate addon runs next).
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

-- Blizzard owns the clickable area; matching it to our box keeps clicks precise (its default
-- is far larger and can target the plate behind).  Three API generations exist; feature-detected.
local savedPlateSize

local function VisualSize()
    local width  = Setting("width")  or 120
    local height = Setting("height") or 12

    local textRow = 0
    if Setting("showName") ~= false or Setting("showLevel") ~= false then
        textRow = ns.Media:SnapSize(Setting("nameSize")) + TEXT_GAP
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

    -- Only the documented setter is used: the API manual lists no per-faction setters, so `SetNamePlateEnemySize` / `FriendlySize` are never borrowed --
    -- borrowing an object from another addon instead of the manual is how one silently fails on the build it runs on.
    if type(C_NamePlate.SetNamePlateSize) == "function" then
        pcall(C_NamePlate.SetNamePlateSize, width, height)
    end
end

function M:RestorePlateSize()
    if not savedPlateSize or not C_NamePlate then return end
    if type(C_NamePlate.SetNamePlateSize) == "function" then
        pcall(C_NamePlate.SetNamePlateSize, savedPlateSize[1], savedPlateSize[2])
    end
    savedPlateSize = nil
end

-- Blizzard's own driver recomputes plate sizes on CVar/settings change and would put its
-- default back; re-apply ours afterwards (the pattern Andromeda uses).  Optional everywhere.
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

-- Every query is pcall'd: on this client a unit call can be refused outright in
-- a restricted state, and a filter must never take the whole plate down.
local function Query(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

-- A unit is a friendly player, a friendly npc, or an enemy (player or npc); friendly npcs get
-- their own CVar, so everything hostile lands under the enemy switch ("all enemies").
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
        -- Both can come back secret; type() is legal on a secret, == is not, so == is guarded.
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

--- The bar colour: the game's own class / reaction answer, tapped units grey.  UnitSelectionColor
--- covers players and NPCs in one call and never returns a secret, so it survives combat.
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

local function PlateWidth()  return Setting("width")  or 120 end
local function PlateHeight() return Setting("height") or 12  end

--- One plate: health box, name/level row above, cast bar under -- all off Blizzard's base frame.
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

    local nameSize = ns.Media:SnapSize(Setting("nameSize"))

    plate.name = Widget:Font(plate, nameSize, "pixel", { r = 1, g = 1, b = 1 }, "LEFT")
    plate.name:SetPoint("BOTTOMLEFT", plate, "TOPLEFT", 0, TEXT_GAP)
    plate.name:SetWordWrap(false)

    plate.level = Widget:Font(plate, nameSize, "pixel", "neutral", "RIGHT")
    plate.level:SetPoint("BOTTOMRIGHT", plate, "TOPRIGHT", 0, TEXT_GAP)

    plate.percent = Widget:Font(health, nameSize, "pixel",
        { r = 1, g = 1, b = 1 }, "RIGHT")
    plate.percent:SetPoint("RIGHT", health, "RIGHT", -3, 0)

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

    local timer = Widget:Font(cast, nameSize, "pixel", "neutral", "RIGHT")
    timer:SetPoint("RIGHT", cast, "RIGHT", -3, 0)

    local text = Widget:Font(cast, nameSize, "pixel",
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

--- Re-apply geometry and fonts (settings can change at any moment), off the per-event path:
--- a plate lays out only when just built or the player changed a setting (layoutDirty).
local function Layout(plate)
    local width, height = PlateWidth(), PlateHeight()
    local nameSize = ns.Media:SnapSize(Setting("nameSize"))
    local castHeight = Setting("castHeight") or 13

    plate:SetSize(width, height)
    plate.health:SetPoint("TOPLEFT", plate, "TOPLEFT", BORDER, -BORDER)
    plate.health:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", -BORDER, BORDER)
    plate.health:SetStatusBarTexture(ns.Media:Texture("barfill"))

    plate.name:SetShown(Setting("showName") ~= false)
    plate.level:SetShown(Setting("showLevel") ~= false)
    plate.name:SetFont(ns.Media:Font("pixel"), nameSize, ns.Media.fontFlags)
    plate.level:SetFont(ns.Media:Font("pixel"), nameSize, ns.Media.fontFlags)
    plate.percent:SetFont(ns.Media:Font("pixel"), nameSize, ns.Media.fontFlags)
    plate.percent:SetShown(Setting("showPercent") ~= false)

    plate.cast:SetSize(width, castHeight)
    plate.cast.fill:SetStatusBarTexture(ns.Media:Texture("barfill"))
    plate.cast.icon:SetSize(castHeight - BORDER * 2, castHeight - BORDER * 2)
    plate.cast:Hide()

    -- The name stops where the level starts, so a long name never runs under it.
    plate.name:ClearAllPoints()
    plate.level:ClearAllPoints()
    plate.name:SetPoint("BOTTOMLEFT", plate, "TOPLEFT", 0, TEXT_GAP)
    plate.level:SetPoint("BOTTOMRIGHT", plate, "TOPRIGHT", 0, TEXT_GAP)
    plate.name:SetPoint("RIGHT", plate.level, "LEFT", -4, 0)
end

--- Your debuffs without reading any aura: Blizzard's AurasFrame is moved onto our plate (the
--- game keeps drawing it, we only say where), hung above the name row; redone per pooled plate.
local function AnchorDebuffs(auras, plate)
    local list = auras and rawget(auras, "DebuffListFrame")
    if not list or type(list.SetPoint) ~= "function" then return end

    local gap = Setting("auraGap") or 4
    local textRow = 0
    if Setting("showName") ~= false or Setting("showLevel") ~= false then
        textRow = ns.Media:SnapSize(Setting("nameSize")) + TEXT_GAP
    end

    pcall(list.ClearAllPoints, list)
    pcall(list.SetPoint, list, "BOTTOMLEFT", plate, "TOPLEFT", 0, textRow + gap)
end

local function BlizzardUnitFrame(base)
    return base and rawget(base, "UnitFrame") or nil
end

--- Take the plate over: hide Blizzard's box (kept, not destroyed) and borrow its aura list;
--- only hidden, so a later Restore gives back exactly what the game drew.
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

    -- Blizzard re-runs this on its own relayout; follow it or the borrowed aura list goes back
    -- under the hidden frame.
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

--- Hand the plate back as found (module off or unit filtered out): box shown, aura list returned.
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

-- The fill computes only with GetTime() (our own plain number) and hands SetValue a value the
-- client clamps against the secret start/end; the timer text needs math, only when end came plain.
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

--- Read the cast tuple without letting a restricted call break the plate; `type(name) == "nil"`
--- is the safe "is anything being cast"; slots differ: channel puts notInterruptible 7th, cast 8th.
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

    -- Name and texture go straight to the widgets: SetText / SetTexture accept a secret.
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

    -- Plain end => a real countdown; hidden end => bar moves, number blank (see 4.6 in MonetUI.md).
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

local function UpdateHealth(plate)
    local unit = plate.unit

    -- A refused unit call skips the write entirely so the bar keeps its last state (Secrets contract).
    local hp, hpMax = Query(UnitHealth, unit), Query(UnitHealthMax, unit)
    if hp ~= nil and hpMax ~= nil then
        local interpolation = (Setting("smooth") ~= false) and Secrets.SMOOTH or nil
        Secrets.SetBar(plate.health, hp, hpMax, interpolation)
    end

    local r, g, b = HealthColor(unit)
    plate.health:SetStatusBarColor(r, g, b)

    -- Dead / disconnected: the client greys the bar, and the "lost" overlay (no value of its
    -- own) is greyed by hand so a corpse reads as one (same rule as the unit frames).
    local connected = Query(UnitIsConnected, unit)
    if connected == nil then connected = true end   -- refused query reads as connected
    local gone = Secrets.Bool(Query(UnitIsDeadOrGhost, unit), false)
        or not Secrets.Bool(connected, true)
    plate.health:SetStatusBarDesaturated(gone)
    if gone then
        local nr, ng, nb = Color:GetNeutral()
        plate.healthLost:SetVertexColor(nr, ng, nb, 1)
    else
        plate.healthLost:SetVertexColor(0, 0, 0, 1)
    end

    -- Percentage text needs real numbers, so only when the client says health is readable (the
    -- bar always fills); Secrets.Number hands back a plain number or nil, making it safe.
    if Setting("showPercent") ~= false and Secrets.CanMeasureHealth(unit) then
        local current = Secrets.Number(Query(UnitHealth, unit))
        local maximum = Secrets.Number(Query(UnitHealthMax, unit))
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
        -- Truncating needs a length, which a secret refuses -- a hidden name is drawn whole.
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

--- The border says what the unit is doing to you: threat first, then your target.
--- UnitThreatSituation can be secret, so it keeps the theme colour when it cannot be read.
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

--- Blizzard can show its own UnitFrame again on any update; keep it hidden while ours.
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
        -- Filtered out: give the unit the plate the game would have drawn (widgets,
        -- soft-target icon, Blizzard's own look) and stand down.
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

-- One handler on the plate; unit events register per plate with RegisterUnitEvent, so only
-- on-screen plates cost anything.
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
            -- The cast that just ended can still read back stale, so the end comes from the
            -- event, not a fresh query.
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
    -- The Blizzard unit frame is left hidden: whoever gets this pooled base next (us, on the
    -- next NAME_PLATE_UNIT_ADDED) settles it again.
    return true
end

M.Removed = Removed

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

    -- The theme listener in Utils/Widget.lua runs first (registered at load), so borders are
    -- re-tinted here after it, in the same tick.
    EventBus:Register("MONETUI_THEME_CHANGED", function()
        if not M.active then return end
        M:UpdateAll()
    end)
end

--- Pick up plates already up when the module (re)loaded: nameplate tokens run in a fixed
--- range, so asking for each and attaching to whatever exists is enough.
function M:AbsorbExisting()
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if Secrets.Bool(Query(UnitExists, unit), false) then
            Added(unit)
        end
    end
end

--- Re-apply every setting: CVars, hitbox, then repaint the plates on screen.  The borrowed
--- aura list is handed back first so a showDebuffs change is picked up by the re-hide below.
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

--- Turning the module off is a real handover: plates go back to Blizzard, and every CVar and
--- the plate size the module steered are restored.
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

-- Which objects this module assumes exist on *this* client: functions check against the API
-- manual, frames do not -- so the probe asks the running client (compare `/mui skins diagnose`).
local PROBED = {
    "C_NamePlate",
    "C_NamePlate.GetNamePlateForUnit",
    "C_NamePlate.GetNamePlateSize",
    "C_NamePlate.SetNamePlateSize",
    "NamePlateDriverFrame",
    "NamePlateDriverFrame.UpdateNamePlateOptions",
}

function M:HandleCommand(rest)
    local sub = string.lower(rest or "")
    if sub ~= "diagnose" and sub ~= "diag" and sub ~= "probe" then return false end

    ns:Print("姓名板对象自检（本客户端实测）：")
    local missing = 0
    for i = 1, #PROBED do
        if ns.ResolvePath(PROBED[i]) then
            ns:Print(("|cff88ff88✓|r %s"):format(PROBED[i]))
        else
            missing = missing + 1
            ns:Print(("|cffff6b6b✗|r %s（缺失）"):format(PROBED[i]))
        end
    end

    if missing == 0 then
        ns:Print("全部存在。")
    else
        ns:Print(string.format("%d 个缺失：全部已按特性探测跳过，不会报错；"
            .. "`NamePlateDriverFrame` 缺失时点击区仍会在设置/区域变化时重设。", missing))
    end
    return true
end

ns:Register("Nameplates", M)
