-- Modules/UnitFrames/UnitFrames.lua
-- Player / target / focus / pet unit frames, slim-bar style.
-- Bars are fed raw values via Secrets.SetBar; numeric text only once the client
-- confirms the values are readable (see Utils/Secrets.lua).

local ADDON_NAME, ns = ...

local Secrets = ns.Secrets
local Widget  = ns.Widget
local Color   = ns.Color
local Math    = ns.Math
local Media   = ns.Media
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

-- Build order matters: every frame anchors to one earlier in the list.
local UNITS = { "player", "target", "targettarget", "focus", "pet" }

-- Name caps, in CHARACTERS and per locale: a Chinese glyph is about twice as
-- wide as a Latin one at the same size, so the same line holds roughly half as many.
local ZH          = GetLocale() == "zhCN"
local NAME_CAP    = ZH and 8 or 10   -- player / target
local NAME_CAP_SM = ZH and 5 or 8    -- targettarget / focus (half-width frames)

-- Text sits above the bar: name "LEFT"|"RIGHT"|"CENTER",
-- level true = drawn beside the name, healthText "LEFT"|"RIGHT". Pet frames carry no text.
local TEXT_LAYOUT = {
    player       = { name = "LEFT",   level = true,  healthText = "RIGHT", cap = NAME_CAP    },
    target       = { name = "LEFT",   level = true,  healthText = "RIGHT", cap = NAME_CAP    },
    targettarget = { name = "CENTER", level = false,                       cap = NAME_CAP_SM },
    focus        = { name = "CENTER", level = false,                       cap = NAME_CAP_SM },
    pet          = {},
}

local TEXT_GAP   = 3   -- gap between the frame's top edge and the text row
local NAME_SIZE  = 10
local SMALL_SIZE = 10

-- Frame globals are PlayerFrame / TargetFrame / ... not unit.."Frame"; look them up explicitly.
local BLIZZARD_FRAMES = {
    player       = "PlayerFrame",
    target       = "TargetFrame",
    targettarget = "TargetFrameToT",
    focus        = "FocusFrame",
    pet          = "PetFrame",
}

--- Suppress the default Blizzard unit frames (the oUF pattern).  In borrow mode
--- TargetFrame is hidden visually only, or the borrowed aura list would freeze.
function M:SuppressBlizzard(enable)
    for _, globalName in pairs(BLIZZARD_FRAMES) do
        local blizzard = _G[globalName]
        if blizzard then
            if enable and not blizzard.__monetSuppressed then
                blizzard.__monetSuppressed = true
                -- Read from the DB: Shared() is a local defined further down, out of scope here.
                local units = ns:DB().unitFrames or {}
                local borrow = globalName == "TargetFrame" and units.showTargetAuras ~= false
                if borrow then
                    if type(blizzard.EnableMouse) == "function" then
                        pcall(blizzard.EnableMouse, blizzard, false)
                    end
                    if type(blizzard.SetAlpha) == "function" then
                        pcall(blizzard.SetAlpha, blizzard, 0)
                    end
                    -- Deliberately not hidden or unregistered: events must keep firing for the borrowed list.
                else
                    pcall(blizzard.UnregisterAllEvents, blizzard)
                    if blizzard.SetScript then
                        pcall(blizzard.SetScript, blizzard, "OnShow", blizzard.Hide)
                    end
                    blizzard:Hide()
                end
            elseif not enable and blizzard.__monetSuppressed then
                blizzard.__monetSuppressed = nil
                pcall(blizzard.SetScript, blizzard, "OnShow", nil)
                if type(blizzard.EnableMouse) == "function" then
                    pcall(blizzard.EnableMouse, blizzard, true)
                end
                if type(blizzard.SetAlpha) == "function" then
                    pcall(blizzard.SetAlpha, blizzard, 1)
                end
                blizzard:Show()
            end
        end
    end
end

local function Shared(key)
    local stored = (ns:DB().unitFrames or {})[key]
    if stored ~= nil then return stored end
    return (ns.DEFAULTS.unitFrames or {})[key]
end

--- One setting for one unit: stored value, then per-unit default, then the shared block.
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
           Setting(unit, "health") or 4,
           Setting(unit, "power")  or 1
end

local function FrameChrome()
    local b = Shared("border") or 1
    return b, 0  -- split removed: using 1px separator line instead
end

--- The "current" part of a health bar: "highlight" (player, pet), "class" (target,
--- focus) or "health".  UnitSelectionColor is never secret, so no identity guard.
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

--- The *missing* part of a health bar: pure background, needs no unit value.
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

    -- Separator: pure black is invisible against the near-black frame background
    -- (and against the player's black lost-health area).  Tint it with the theme's
    -- border colour so it always reads as a divider, and follow theme changes here.
    local sep = frame.healthSeparator
    if sep then
        local r, g, b = Color:GetBorder()
        sep:SetColorTexture(r, g, b, 0.55)
    end
end

--- Dead, ghost or disconnected?  Plain booleans; Secrets.Bool guards a hiding build.
local function IsUnavailable(unit)
    if not UnitExists(unit) then return false end
    if Secrets.Bool(UnitIsDeadOrGhost(unit), false) then return true end
    return not Secrets.Bool(UnitIsConnected(unit), true)
end

--- Grey the bars via the client's desaturation: it keeps working while values are hidden.
local function UpdateDesaturation(frame)
    local grey = IsUnavailable(frame.unit)

    if frame.health then frame.health:SetStatusBarDesaturated(grey) end
    if frame.power  then frame.power:SetStatusBarDesaturated(grey)  end

    -- Pips empty out on death anyway; greying keeps the player frame consistent.
    local pips = frame.classPower and frame.classPower.pips
    if pips then
        for i = 1, #pips do
            pips[i]:SetStatusBarDesaturated(grey)
        end
    end

    -- A dead unit shows the *missing* overlay end to end; the client won't desaturate a
    -- plain texture, so grey it by hand.
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

-- Power type can change at runtime (shapeshift/vehicle); re-read on UNIT_DISPLAYPOWER,
-- unknown tokens fall through to the client colour, then the theme.
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

    -- Guard so a client that hides the token never hands us a secret table key.
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

-- Replacement for PlayerFrame.classPowerBar / powerBarAlt (children of the frame we hide): one
-- slim pip per combo point, a StatusBar fed the raw count so the client clamps and lights it.
local POWER = (_G.Enum and _G.Enum.PowerType) or {}
local COMBO_POINTS = POWER.ComboPoints or 4
local ENERGY       = POWER.Energy      or 3

-- Per class: power, POWER_COLOR token, default pip count, optional gate on the primary power
-- (a druid only has combo points as a cat). DK runes are cooldown-driven, not points, so absent.
local CLASS_POWER = {
    ROGUE = { power = COMBO_POINTS, token = "COMBO_POINTS", max = 5 },
    DRUID = { power = COMBO_POINTS, token = "COMBO_POINTS", max = 5,
              requirePower = ENERGY },
}

-- Defensive ceiling: a garbage maximum must not build a hundred bars.
local MAX_PIPS = 10

--- The player's class file name ("ROGUE", ...), cached.  UnitClassBase preferred;
--- both calls pcall'd because identity can be hidden in restricted states.
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

--- Does this power event concern the frame's class resource?  A missing or
--- non-string token (UNIT_MAXPOWER, a full refresh) always refreshes.
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

    -- Shapeshifters only have the resource in one form; UnitPowerType reports the
    -- primary power and is never secret, so it is a safe gate.
    if def.requirePower and UnitPowerType(unit) ~= def.requirePower then
        holder:Hide()
        return
    end

    local maximum = Secrets.Number(UnitPowerMax(unit, def.power))
    if maximum and maximum <= 0 then
        holder:Hide()   -- this class / spec does not have the resource
        return
    end

    -- A hidden maximum must not re-layout: keep the last readable count, else the
    -- class default.
    local count = maximum or holder.count or def.max
    if count > MAX_PIPS then count = MAX_PIPS end
    if count ~= holder.count then
        LayoutClassPower(holder, count)
    end

    local current = UnitPower(unit, def.power)
    local r, g, b = Color:GetResource()
    local tuned = POWER_COLOR[def.token]
    if tuned then r, g, b = tuned[1], tuned[2], tuned[3] end

    -- "Full" tint needs both numbers readable; a secret pair keeps the colour.
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

--- The interpolation to hand to the client: nil means "snap straight to it" (a saved preference).
local function Smoothing()
    if Shared("smoothBars") == false then return nil end
    return Secrets.SMOOTH
end

--- Health-percentage ramp with explicit stops; a red-to-green lerp passes through
--- muddy brown.
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

local function UpdateName(frame)
    local unit = frame.unit
    if not UnitExists(unit) then return end

    -- Colouring follows identity, so it is refreshed here: the pet frame still needs its bar coloured.
    UpdateBarLook(frame)

    local nameText = frame.name
    if not nameText then return end   -- pet frames carry no text

    local name, classFile
    if Secrets.CanReadIdentity(unit) then
        name = UnitName(unit)
        local _, class = UnitClass(unit)
        classFile = class
    end
    if name then
        -- Leading words become initials, then the whole thing
        -- is capped.  The text row is shared with the level, so an untruncated NPC name would run
        -- past the bar's edge.
        name = Math:Shorten(Math:AbbrName(name), frame.nameCap or NAME_CAP, true)
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
            -- Target frame shows percentage; others show current/max
            if unit == "target" then
                local pct = math.floor(current / maximum * 100 + 0.5)
                healthText:SetText(pct .. "%")
            else
                local style = (ns:DB().numberFormat == "cn") and "cn" or nil
                healthText:SetText(Math:ShortNumber(current, 1, style) .. " / "
                    .. Math:ShortNumber(maximum, 1, style))
            end
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

-- ============================================================================
-- Cast indicator (player & target): NO fill bar, only a red triangle spark (2px)
-- that moves RIGHT->LEFT (reverse) under the power bar as the cast progresses.
-- CAST_GAP = 1px between power bar and spark.
-- ============================================================================

local CAST_GAP       = 1          -- gap between power bar and spark
local SPARK_HEIGHT   = 2          -- triangle height in pixels (2px)
local SPARK_WIDTH    = 4          -- triangle width in pixels
local SPARK_RED      = { 1, 0, 0 }  -- normal / interruptible cast

--- Create a red upward-pointing triangle spark using a FontString (▲ U+25B2).
local function CreateTriangleSpark(parent)
    local spark = parent:CreateFontString(nil, "OVERLAY")
    local fontPath = Media:Font("pixel")
    spark:SetFont(fontPath, SPARK_HEIGHT, Media.fontFlags)
    if spark.SetShadowOffset then spark:SetShadowOffset(0, 0) end
    spark:SetText("▲")  -- U+25B2 BLACK UP-POINTING TRIANGLE
    spark:SetTextColor(1, 0, 0, 1)  -- solid red
    spark:SetJustifyH("CENTER")
    spark:Hide()
    return spark
end

--- Build the cast indicator: a simple frame holding only the spark.
local function CreateCastBar(frame)
    if frame.unit ~= "player" and frame.unit ~= "target" then return end

    local width = Setting(frame.unit, "width") or 160
    local border = (Shared("border") or 1)
    local barWidth = width - border * 2

    -- A plain frame (no StatusBar, no fill, no background) to anchor the spark
    local cast = CreateFrame("Frame", nil, frame)
    cast:SetSize(barWidth, SPARK_HEIGHT)
    cast:SetPoint("TOPLEFT", frame.power, "BOTTOMLEFT", 0, -CAST_GAP)

    -- Red triangle spark (moves RIGHT->LEFT as cast progresses)
    local spark = CreateTriangleSpark(cast)
    -- Anchor to bottom of the cast frame
    spark:SetPoint("BOTTOM", cast, "BOTTOM", 0, 0)

    cast.spark = spark
    cast:Hide()

    frame.cast = cast
    return cast
end

--- Read cast/channel info without letting a restricted call break the frame.
local function CastInfo(channel, unit)
    local fn = channel and UnitChannelInfo or UnitCastingInfo
    if type(fn) ~= "function" then return nil end

    local result = { pcall(fn, unit) }
    if not result[1] then return nil end

    -- pcall wraps returns: result[1]=ok, result[2]=name, result[3]=text, result[4]=texture,
    -- result[5]=startTimeMS, result[6]=endTimeMS, result[7]=isTradeSkill,
    -- result[8]=castID (cast) / notInterruptible (channel),
    -- result[9]=notInterruptible (cast) / spellID (channel),
    -- result[10]=spellID (cast)
    local name      = result[2]
    local texture   = result[4]
    local startMS   = result[5]
    local endMS     = result[6]
    local notInt    = channel and result[8] or result[9]
    local spellID   = channel and result[9] or result[10]
    return name, texture, startMS, endMS, notInt, spellID
end

--- Update the cast indicator for the player/target frame.
--- Only positions the red triangle spark (no fill bar, no text).
local function UpdateCast(frame)
    if not frame.cast then return end
    local unit = frame.unit
    if unit ~= "player" and unit ~= "target" then return end

    local name, texture, startMS, endMS, notInterruptible, spellID = CastInfo(false, unit)
    local channel = false
    if type(name) == "nil" then
        name, texture, startMS, endMS, notInterruptible, spellID = CastInfo(true, unit)
        channel = true
    end
    if type(name) == "nil" then
        frame.cast:Hide()
        frame.cast.spark:Hide()
        frame:SetScript("OnUpdate", nil)
        return
    end

    -- An uninterruptible cast turns the spark grey; a normal
    -- (interruptible) cast stays red.
    if Secrets.Bool(notInterruptible, false) then
        local nr, ng, nb = Color:GetNeutral()
        frame.cast.spark:SetTextColor(nr, ng, nb, 1)
    else
        frame.cast.spark:SetTextColor(SPARK_RED[1], SPARK_RED[2], SPARK_RED[3], 1)
    end

    -- Store times for spark calculation
    frame.cast.startTimeMS = startMS
    frame.cast.endTimeMS = endMS
    frame.cast.channeling = channel
    frame.cast:Show()
    frame.cast.spark:Show()

    frame:SetScript("OnUpdate", function(self, elapsed)
        local cast = self.cast
        if not cast or not cast.endTimeMS then
            self:SetScript("OnUpdate", nil)
            return
        end

        local now = GetTime() * 1000
        local startMS = cast.startTimeMS or 0
        local endMS = cast.endTimeMS
        local maxDur = endMS - startMS
        if maxDur <= 0 then maxDur = 1 end

        local progress
        if cast.channeling then
            -- Channeling: progresses from 1 to 0
            progress = (endMS - now) / maxDur
        else
            -- Casting: progresses from 0 to 1
            progress = (now - startMS) / maxDur
        end
        if progress < 0 then progress = 0 elseif progress > 1 then progress = 1 end

        -- Move spark RIGHT -> LEFT (reverse): at progress=0 (start), spark at RIGHT; at progress=1, spark at LEFT
        local barWidth = cast:GetWidth()
        local x = barWidth * (1 - progress)
        cast.spark:SetPoint("BOTTOM", cast, "BOTTOMLEFT", x, 0)

        -- Auto-hide when cast ends
        if (cast.channeling and now >= endMS) or (not cast.channeling and now >= endMS) then
            cast:Hide()
            cast.spark:Hide()
            self:SetScript("OnUpdate", nil)
        end
    end)
end

--- Hide cast bar (called on STOP/FAILED/INTERRUPTED/CHANNEL_STOP).
local function HideCast(frame)
    if not frame.cast then return end
    frame.cast:Hide()
    frame.cast.spark:Hide()
    frame.cast.endTimeMS = nil
    frame.cast.startTimeMS = nil
    frame.cast.channeling = false
    frame:SetScript("OnUpdate", nil)
end

-- ============================================================================
-- B 方案：Blizzard 原生 AuraContainer（当前启用）
-- ============================================================================
--
-- A 方案（借 TargetFrame 的光环子帧）整段注释在下面，保留以便回滚。切换理由：
--   A 改的是暴雪自己的子帧，暴雪每次重排都要抢回来（StackTargetAuras），而且它读不到
--   C_UnitAuras，只能指望 TargetFrame 继续替我们画。
--   B 让暴雪自己画：池化、排序、机密值处理、战斗中可变，全归引擎。
--
-- 本客户端的三个硬约束（EllesmereUI_AuraKit.lua 里都踩过）：
--   1. AuraContainer 属于 LoD 插件 Blizzard_AuraContainer，必须先 LoadAddOn 才能 CreateFrame。
--   2. 容器必须**先有可渲染的矩形**（SetSize(1,1)）：引擎的 parse/layout 是从一个
--      run-when-visible 的 OnUpdate 里排空的，没有矩形就永远不跑第一次布局。
--   3. initializeFrame 里必须**先把区域建好、上好样式，最后才注册给按钮**：每个 Set*
--      注册都会立刻触发引擎的 UpdateAuraDisplay -> SetText()，字体没设的 FontString 直接报错。
--
-- 回滚：删掉下面 A 方案的 --[==[ 和 ]==] 两行，把本段三个调用点换回
--       BorrowTargetAuras / RestoreTargetAuras / StackTargetAuras + HookAuraRelayout()。

-- Icon size chosen so the justified row lands on an integer spacing:
--   158px content / 18px wide icons => 8 per row, gaps = (158 - 8*18) / 7 = 2.0px exactly.
-- Height 14 keeps the icons compact (18:14); the square spell art is cropped to that aspect.
local TARGET_AURA_ICON_W   = 18
local TARGET_AURA_ICON_H   = 14
local TARGET_AURA_BORDER_PX = 0   -- no width inset: keeps the full 18px, so the art is not stretched
local TARGET_AURA_V_CROP_PX = 2   -- height crop top and bottom (18 - 2 - 2 = 14)
local TARGET_AURA_SPACING  = 2    -- base spacing (used when icons don't fill row)
local TARGET_AURA_ROWS     = 2

--- Compute justified aura layout for given frame width.
-- Returns: iconsPerRow, actualSpacing, rowWidth
-- Goal: align both left and right edges to frame outer edges.
local function ComputeAuraLayout(frameWidth)
    local border = (Shared("border") or 1)
    local contentWidth = frameWidth - border * 2  -- frame content width (inner)
    -- Maximum icons that fit with minimum spacing
    local maxIcons = math.floor((contentWidth + TARGET_AURA_SPACING) / (TARGET_AURA_ICON_W + TARGET_AURA_SPACING))
    if maxIcons < 1 then maxIcons = 1 end
    if maxIcons > 12 then maxIcons = 12 end  -- cap at reasonable max

    -- Calculate spacing to exactly fill the row (justified)
    -- rowWidth = icons * iconWidth + (icons - 1) * spacing = contentWidth
    local actualSpacing
    if maxIcons > 1 then
        actualSpacing = (contentWidth - maxIcons * TARGET_AURA_ICON_W) / (maxIcons - 1)
        if actualSpacing < 0 then actualSpacing = 0 end
        if actualSpacing > 8 then actualSpacing = 8 end
    else
        actualSpacing = TARGET_AURA_SPACING
    end

    local rowWidth = maxIcons * TARGET_AURA_ICON_W + (maxIcons - 1) * actualSpacing
    return maxIcons, actualSpacing, rowWidth
end

--- TexCoord for a square spell icon shown in an 18 x 14 slot.
--- Reference square is TARGET_AURA_ICON_W px (18):
---   width  : full 0..1  (no inset -- keeps the source aspect at 18:14, so no stretch)
---   height : crop 2px top and bottom  (18 - 2 - 2 = 14)
--- => SetTexCoord(0, 1, 2/18, 16/18) = (0, 1, 0.1111, 0.8889)
local function AuraIconTexCoord()
    local n = TARGET_AURA_ICON_W
    local x0 = TARGET_AURA_BORDER_PX / n
    local x1 = 1 - TARGET_AURA_BORDER_PX / n
    local y0 = TARGET_AURA_V_CROP_PX / n
    local y1 = 1 - TARGET_AURA_V_CROP_PX / n
    return x0, x1, y0, y1
end

local auraAddonReady = false

--- AuraContainer 是 LoD 插件，没加载时 CreateFrame 拿不到那个模板。
local function EnsureAuraContainerAddOn()
    if auraAddonReady then return true end
    local C = _G.C_AddOns
    if not C or type(C.LoadAddOn) ~= "function" then return false end
    local ok, loaded = pcall(C.IsAddOnLoaded, "Blizzard_AuraContainer")
    if not ok then return false end
    if not loaded and not pcall(C.LoadAddOn, "Blizzard_AuraContainer") then return false end
    auraAddonReady = true
    return true
end

-- 两代 API：Flow* 是新名字，AuraLayout* 是旧名字。这个 fork 上哪一代在，实机才知道，
-- 所以每个 setter 都「新名优先、旧名兜底、都没有就跳过」，绝不裸调。
local function FlowCall(container, newName, oldName, ...)
    local f = container[newName]
    if type(f) ~= "function" and oldName then f = container[oldName] end
    if type(f) ~= "function" then return false end
    return pcall(f, container, ...)
end

-- 引擎按钮只在我们手里一次：之后光环变机密（战斗中），Post-creation 访问会被拒。
local auraButtons = setmetatable({}, { __mode = "k" })

local function TintAuraButton(button)
    local border = button.__monetBorder
    if not border then return end
    local r, g, b = Color:GetBorder()
    local _, _, _, a = Color:GetEdge()
    border:SetColorTexture(r, g, b, a or 1)
end

--- initializeFrame：一个引擎按钮只进来一次。碰按钮的事必须在这里做完。
local function StyleAuraButton(button)
    if type(button) ~= "table" then return end

    local frameLevel = 1
    local okLevel, level = pcall(button.GetFrameLevel, button)
    if okLevel and type(level) == "number" then frameLevel = level end

    pcall(button.SetSize, button, TARGET_AURA_ICON_W, TARGET_AURA_ICON_H)
    -- 引擎按钮默认**可点**：压在条上会吃掉换目标的点击。只有这个窗口能可靠关掉。
    pcall(button.SetMouseClickEnabled, button, false)

    -- 1px 边框 = 比图标大 1px 的底色，图标再盖上去。
    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", button, "TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0, 0, 0, 1)
    button.__monetBorder = border

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(button)
    -- Crop the square spell art to the 3:4 (H:W) slot aspect.
    local x0, x1, y0, y1 = AuraIconTexCoord()
    icon:SetTexCoord(x0, x1, y0, y1)

    local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cd:SetAllPoints(button)
    pcall(cd.SetDrawEdge, cd, false)
    pcall(cd.SetDrawSwipe, cd, true)

    -- 文字载体：在冷却之上，且**不吃鼠标**。
    local textHost = CreateFrame("Frame", nil, button)
    textHost:SetAllPoints(button)
    textHost:SetFrameLevel(frameLevel + 5)
    textHost:EnableMouse(false)

    local stack = textHost:CreateFontString(nil, "OVERLAY")
    Widget:SetFont(stack, 10, "pixel")        -- 字体必须在 SetApplicationCount 之前
    stack:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    stack:SetJustifyH("RIGHT")

    local duration = textHost:CreateFontString(nil, "OVERLAY")
    Widget:SetFont(duration, 10, "pixel")
    duration:SetPoint("CENTER", button, "CENTER", 0, 0)

    -- 区域全部就绪之后才注册（见上面第 3 条约束）。
    pcall(button.SetIcon, button, icon)
    pcall(button.SetDurationCooldown, button, cd)
    pcall(button.SetApplicationCount, button, stack, {})
    -- 时长文本的选项参数各代客户端不一致：失败一次就退回最简形式，再失败就不显示。
    if not pcall(button.SetDurationText, button, duration, {}) then
        duration:Hide()
    end

    button.__monetDuration = duration
    auraButtons[button] = true
    TintAuraButton(button)
end

--- 流式布局：贴左下、向右上长、每行自动计算图标数并两端对齐（justified）。
-- Anchor at BOTTOMLEFT of frame (frame outer left edge), grow RIGHT then UP.
local function ApplyContainerLayout(container, frame)
    local iconsPerRow, actualSpacing, rowWidth = ComputeAuraLayout(frame:GetWidth())

    FlowCall(container, "SetFlowLayoutAnchorPoint", "SetAuraLayoutAnchorPoint", "BOTTOMLEFT")
    FlowCall(container, "SetFlowLayoutGrowthDirection", "SetAuraLayoutGrowthDirection", "RIGHT", "UP")

    local axes = _G.AnchorUtil and _G.AnchorUtil.FlowLayoutAxis
    if axes and type(container.SetFlowLayoutAxis) == "function" then
        pcall(container.SetFlowLayoutAxis, container, axes.Horizontal)
    end

    -- Set element spacing to the justified spacing (may be fractional, FlowLayout handles it)
    FlowCall(container, "SetFlowLayoutElementSpacing", "SetAuraLayoutElementSpacing", actualSpacing)
    FlowCall(container, "SetFlowLayoutLineSpacing", "SetAuraLayoutLineSpacing", actualSpacing)

    -- Maximum line size = frame content width (so it wraps at frame edge)
    FlowCall(container, "SetFlowLayoutMaximumLineSize", "SetAuraLayoutRowWidth", rowWidth)

    -- Store for potential refresh
    container.__monetAuraLayout = {
        iconsPerRow = iconsPerRow,
        spacing = actualSpacing,
        rowWidth = rowWidth,
    }
    return iconsPerRow, actualSpacing, rowWidth
end

--- 建一个只装一组光环的容器。成功返回 container，失败返回 nil + 原因。
local function CreateAuraContainer(parent, key, filterString)
    if not EnsureAuraContainerAddOn() then
        return nil, "Blizzard_AuraContainer 未加载"
    end

    local ok, container = pcall(CreateFrame, "AuraContainer", nil, parent, "CustomAuraContainerTemplate")
    if not ok or type(container) ~= "table" then
        return nil, "CreateFrame(AuraContainer) 失败（模板可能不存在）"
    end

    -- 约束 2：先给一个可渲染的矩形，否则引擎那轮 OnUpdate 永远不会跑第一次布局。
    container:SetSize(1, 1)

    -- Compute justified layout based on parent frame width
    local iconsPerRow, actualSpacing, rowWidth = ApplyContainerLayout(container, parent)

    local opts = {
        maxFrameCount = iconsPerRow * TARGET_AURA_ROWS,
        candidateFilters = {},              -- 空表 = 不设白名单，引擎自己决定显示什么
        layout = {
            elementSpacing = actualSpacing,
            lineSpacing    = actualSpacing,
            elementWidth   = TARGET_AURA_ICON_W,
            elementHeight  = TARGET_AURA_ICON_H,
            layoutIndex    = 1,
        },
        initializeFrame = StyleAuraButton,
    }
    -- 这两个枚举常量缺失时传 nil 更安全，别塞 0 让引擎按「第 0 种排序」处理。
    if _G.AuraContainerSortMethod then opts.sortMethod = _G.AuraContainerSortMethod end
    if _G.AuraContainerSortDirection then opts.sortDirection = _G.AuraContainerSortDirection end

    local okAdd, err = pcall(container.AddAuraGroup, container, key, filterString, opts)
    if not okAdd then
        return nil, "AddAuraGroup 失败: " .. tostring(err)
    end

    pcall(container.SetUnit, container, "target")
    pcall(container.UpdateAllAuras, container)
    return container
end

local targetAuraDebuffs, targetAuraBuffs

--- 建/显示目标光环容器。取代 A 方案的 BorrowTargetAuras。
--- debuff 贴近血条，buff 叠在 debuff 之上（和暴雪 TargetFrame 的排法一致）。
local function EnsureTargetAuras(frame)
    if not frame then return end

    if not Shared("showTargetAuras") then
        if targetAuraDebuffs then targetAuraDebuffs:Hide() end
        if targetAuraBuffs then targetAuraBuffs:Hide() end
        return
    end

    if not targetAuraDebuffs then
        local debuffs, why = CreateAuraContainer(frame, "monetTargetDebuffs", "HARMFUL")
        if not debuffs then
            -- 一次性警告，不刷屏。
            if not M.__auraWarned then
                M.__auraWarned = true
                ns:Print("目标光环（原生 AuraContainer）不可用：" .. tostring(why))
            end
            return
        end
        targetAuraDebuffs = debuffs
        targetAuraDebuffs:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, Shared("targetAuraGap") or 22)

        local buffs = CreateAuraContainer(frame, "monetTargetBuffs", "HELPFUL")
        if buffs then
            targetAuraBuffs = buffs
            targetAuraBuffs:SetPoint("BOTTOMLEFT", targetAuraDebuffs, "TOPLEFT", 0, TARGET_AURA_SPACING)
        end
    end

    if targetAuraDebuffs then targetAuraDebuffs:Show() end
    if targetAuraBuffs then targetAuraBuffs:Show() end
end

--- 主题变化时重涂边框。引擎按钮由引擎持有，我们只留弱引用。
local function TintTargetAuras()
    for button in pairs(auraButtons) do TintAuraButton(button) end
end

-- ============================================================================
-- A 方案（已停用，保留以便回滚）
-- ============================================================================
--[==[
-- Borrow Blizzard's target aura list: aura reads are restricted, but TargetFrame keeps drawing
-- its own, so its aura children are reparented above our bar (the ForeverUI trick).  Position only.

-- Candidate aura children on Blizzard's TargetFrame; whichever are found stack above the frame.
local TARGET_AURA_CHILDREN = { "DebuffFrame", "AurasFrame", "BuffFrame" }

--- One aura child by candidate name: a raw field first, then a guarded lookup.
local function AuraChild(blizzard, name)
    if not blizzard then return nil end
    local child = rawget(blizzard, name)
    if not child then
        local ok, value = pcall(function() return blizzard[name] end)
        if ok then child = value end
    end
    if type(child) == "table" and type(child.SetParent) == "function" then
        return child
    end
    return nil
end

--- Anchor one borrowed list `gap` px above `below` (BOTTOMLEFT, growing up).
local function AnchorAuraList(list, below, gap)
    pcall(list.ClearAllPoints, list)
    pcall(list.SetPoint, list, "BOTTOMLEFT", below, "TOPLEFT", 0, gap)
end

-- Defined below; forward-declared for the option-off path.
local RestoreTargetAuras

--- (Re)stack the borrowed lists above the frame; also pulls them back after
--- Blizzard re-anchors them to its own hidden frame.
local function StackTargetAuras(frame)
    local lists = frame.blizzardAuras
    if not lists then return end

    local gap = Shared("targetAuraGap") or 22
    for i, list in ipairs(lists) do
        -- Blizzard may have reparented it back to itself; claim it again.
        if list:GetParent() ~= frame then
            pcall(list.SetParent, list, frame)
        end
        pcall(list.SetAlpha, list, 1)
        local below = (i == 1) and frame or lists[i - 1]
        AnchorAuraList(list, below, i == 1 and gap or 2)
    end
end

--- Lift Blizzard's aura children onto our target frame; runs on every target change.
local function BorrowTargetAuras(frame)
    if not Shared("showTargetAuras") then
        RestoreTargetAuras(frame)
        return
    end

    local blizzard = _G.TargetFrame
    if not blizzard then return end

    local lists = {}
    for _, name in ipairs(TARGET_AURA_CHILDREN) do
        local child = AuraChild(blizzard, name)
        if child then lists[#lists + 1] = child end
    end

    if #lists == 0 then
        if not frame.__monetAuraWarned then
            frame.__monetAuraWarned = true
            print("|cffce3e2fMonetUI|r: 未在 TargetFrame 上找到光环子帧，目标框光环已跳过（帧名待实机核对）")
        end
        return
    end

    frame.__monetAuraWarned = nil
    frame.blizzardAuras = lists
    StackTargetAuras(frame)
end

--- Hand the list back to Blizzard (module off, or the option turned off).
function RestoreTargetAuras(frame)
    local lists = frame.blizzardAuras
    if not lists then return end

    local blizzard = _G.TargetFrame
    for _, list in ipairs(lists) do
        if blizzard and type(list.SetParent) == "function" then
            pcall(list.SetParent, list, blizzard)
        end
    end
    -- Let the game re-anchor its own list now that it owns it again.
    if blizzard and type(_G.TargetFrame_Update) == "function" then
        pcall(_G.TargetFrame_Update, blizzard)
    end

    frame.blizzardAuras = nil
end

-- Blizzard re-anchors the list to its own hidden frame on every target / aura
-- update; the hook re-stacks it (the same guard pattern as Nameplates).
local function HookAuraRelayout()
    if M.__auraHooked then return end
    M.__auraHooked = true

    local function restack()
        local frame = frames.target
        if frame and frame.blizzardAuras then StackTargetAuras(frame) end
    end

    for _, name in ipairs({ "TargetFrame_Update", "TargetFrame_UpdateAuras", "TargetFrame_SetUnit" }) do
        if type(_G[name]) == "function" and type(hooksecurefunc) == "function" then
            pcall(hooksecurefunc, name, restack)
        end
    end
end
]==]

--- 摆好一个单位框。位置读写统一交给 Utils/Mover.lua：归一落点、网格/互相吸附、战斗锁、依赖顺序都在那边。
local function PositionFrame(frame)
    if not frame then return end
    ns.Mover:Apply(frame.unit)
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

-- The border doubles as a live signal; the colour runs
-- through Widget:SetBorderState so a theme refresh re-applies the state.

--- Threat glow colours via the Monet palette: 1 primary, 2 blend, 3 danger,
--- 4 tanking -> health ("safe" because you hold it).
local function ThreatBorder(status)
    if status == 4 then return Color:GetHealth() end
    if status == 3 then return Color:GetDanger() end
    if status == 2 then return Color:Blend("primary", "danger", 0.6) end
    return Color:GetPrimary()
end

--- The colour the state layer (LibMonetColor-Anim-1.0) last delivered for this
--- frame.  It is the BASE of the border: hover and threat paint over it and
--- hand it back when they are done, so the state tint is never lost.
local function RestoreDynamicBorder(frame)
    if not frame then return end
    local c = frame.monetColor
    if c then
        Widget:SetBorderState(frame, c.r, c.g, c.b, c.a)
    else
        Widget:SetBorderState(frame, nil)
    end
end

--- Paint the state layer's colour -- unless hover or threat currently owns
--- the border.
local function ApplyDynamicBorder(frame)
    if not frame or frame.monetBorderOverride then return end
    local c = frame.monetColor
    if not c then return end
    Widget:SetBorderState(frame, c.r, c.g, c.b, c.a)
end

--- Re-evaluate the threat glow.  A secret status must not raise nor clear a glow
--- that is still true: the last state is kept until PLAYER_REGEN_ENABLED.
local function UpdateThreat(frame)
    if not Shared("threatGlow") then return end

    -- nil means both "no threat API answer" and "value hidden by the client".
    local status = Secrets.Number(UnitThreatSituation(frame.unit))
    if status == nil then return end

    frame.threatStatus = status
    if status > 0 then
        -- The threat owns the border until it ends.
        frame.monetBorderOverride = true
        local r, g, b, a = ThreatBorder(status)
        Widget:SetBorderState(frame, r, g, b, a)
    elseif not Widget:IsMouseOver(frame) then
        -- Drop the glow; the state layer's colour is the base again.
        frame.monetBorderOverride = false
        RestoreDynamicBorder(frame)
    end
end

--- Hover: the border washes to the highlight slot (a 1px wash).  HookScript, because
--- Widget:UnitTooltip owns OnEnter / OnLeave.
local function HoverBorder(frame, enter)
    if not Shared("hoverGlow") then return end
    if frame.threatStatus and frame.threatStatus > 0 then return end

    frame.monetBorderOverride = enter and true or false
    if enter then
        local r, g, b, a = Color:GetHighlight()
        Widget:SetBorderState(frame, r, g, b, a)
    else
        -- The hover is over: the state layer's colour comes back.
        RestoreDynamicBorder(frame)
    end
end

--- The state layer (LibMonetColor-Anim-1.0) drives the border colour: the
--- combat brightening, the entry flash, the low-health red, the
--- out-of-combat dimming and the rest tint.  One sink per frame -- the layer
--- judges the state, this module only paints what it is handed.
local function RegisterDynamicBorders()
    local Anim = ns:GetAnim()
    if not Anim then return end
    for _, unit in ipairs(UNITS) do
        local frame = frames[unit]
        if frame and not frame.monetBorder then
            frame.monetBorder = Anim:RegisterColorSink(function(r, g, b, a)
                frame.monetColor = { r = r, g = g, b = b, a = a }
                ApplyDynamicBorder(frame)
            end, {
                -- The border slot follows the user's choice (edge / ambient /
                -- highlight / neutral), so it is resolved on every repaint.
                base = function() return Color:GetBorderKey() end,
                pulse = true,
            })
        end
    end
end

local function CreateUnitFrame(unit, position)
    local border = FrameChrome()
    local width, healthHeight, powerHeight = UnitGeometry(unit)
    -- No split: health + 1px separator + power
    local height = border * 2 + healthHeight + 1 + powerHeight

    local frame = Widget:CreateFrame("MonetUI" .. unit:gsub("^%l", string.upper) .. "Frame",
        UIParent, width, height)
    frame.unit = unit
    frame.label = UNIT_LABEL[unit] or unit

    local health = Widget:Bar(frame, width - border * 2, healthHeight)
    health:SetPoint("TOPLEFT", frame, "TOPLEFT", border, -border)
    health:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -border, -border)

    -- The *missing* part: a plain texture behind the fill, tinted by UpdateHealthColor.
    local lost = health:CreateTexture(nil, "BACKGROUND")
    lost:SetAllPoints(health)
    lost:SetColorTexture(1, 1, 1, 1)

    -- The ground the bar sits on: the Monet canvas weave, so the empty part of the bar reads
    -- as cloth instead of a flat hole.  Created after `lost` (so it draws over it) and still
    -- under the fill -- the filled part stays flat colour.
    Widget:BarWeave(health)

    -- 1px separator line between health and power.  It is tinted
    -- with the border colour rather than black: a black line vanishes against the
    -- near-black frame background and the player's black lost-health area.
    local separator = health:CreateTexture(nil, "OVERLAY")
    separator:SetHeight(1)
    separator:SetPoint("TOPLEFT", health, "BOTTOMLEFT", 0, 0)
    separator:SetPoint("TOPRIGHT", health, "BOTTOMRIGHT", 0, 0)
    local sr, sg, sb = Color:GetBorder()
    separator:SetColorTexture(sr, sg, sb, 0.55)
    frame.healthSeparator = separator

    local power = Widget:Bar(frame)
    power:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", border, border)
    power:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -border, border)
    power:SetHeight(powerHeight)
    power:SetStatusBarColor(Color:GetResource())

    -- Same woven ground as the health bar.
    Widget:BarWeave(power)

    frame.health = health
    frame.healthLost = lost
    frame.power = power

    -- The class resource hangs under the player frame only; it owns Blizzard's class power.
    if unit == "player" then
        CreateClassPower(frame)
    end
    -- Cast bar for player and target.
    if unit == "player" or unit == "target" then
        CreateCastBar(frame)
    end

    UpdateBarLook(frame)

    local layout = TEXT_LAYOUT[unit] or {}
    frame.nameCap = layout.cap

    -- New layout: [Name(LEFT)] ...... [2px] [Health%] [2px] [Level(RIGHT)]
    -- Name anchored to TOPLEFT, Level anchored to TOPRIGHT, Health% between them

    if layout.name then
        frame.name = Widget:Font(frame, NAME_SIZE, "pixel", "edge",
            layout.name == "CENTER" and "CENTER" or layout.name)
        if layout.name == "LEFT" then
            frame.name:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, TEXT_GAP)
        elseif layout.name == "RIGHT" then
            frame.name:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, TEXT_GAP)
        else
            frame.name:SetPoint("BOTTOM", frame, "TOP", 0, TEXT_GAP)
        end
    end

    if layout.name and layout.level then
        frame.level = Widget:Font(frame, SMALL_SIZE, "pixel", "neutral", "RIGHT")
        -- Level anchored to TOPRIGHT of frame
        frame.level:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, TEXT_GAP)
    end

    if layout.healthText then
        frame.healthText = Widget:Font(frame, SMALL_SIZE, "pixel", { r = 1, g = 1, b = 1 }, "RIGHT")
        -- Health% sits 2px left of Level (or right of Name if no Level).
        -- The level must exist first: this used to test frame.level before it was
        -- created, so every health text silently anchored after the name instead.
        if frame.level then
            frame.healthText:SetPoint("RIGHT", frame.level, "LEFT", -2, 0)
        elseif frame.name then
            frame.healthText:SetPoint("LEFT", frame.name, "RIGHT", 2, 0)
        else
            frame.healthText:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, TEXT_GAP)
        end
    end

    Widget:Theme(frame, { thickness = border, bgAlpha = 0.9 })
    Widget:UnitTooltip(frame, unit)
    frame:HookScript("OnEnter", function(self) HoverBorder(self, true) end)
    frame:HookScript("OnLeave", function(self) HoverBorder(self, false) end)

    -- 拖动 / 吸附 / 位置记忆统一走 Utils/Mover.lua（默认位置是调用方给的 position 表）。
    ns.Mover:Register(frame, unit, {
        group   = "unitframes",
        label   = UNIT_LABEL[unit] or unit,
        default = position,
        store   = function() return ns:DB().unitFrames[unit] end,
    })

    frame.position = position
    frame:Hide()
    return frame
end

function M:UpdateUnit(unit, kind, powerType)
    local frame = frames[unit]
    if not frame or not frame:IsShown() then return end
    if kind == "health" then
        UpdateHealth(frame)
    elseif kind == "power" then
        UpdatePower(frame)
        -- Only the resource's own power type is worth a refresh (energy ticks all the time).
        if ClassPowerIn(frame, powerType) then
            UpdateClassPower(frame)
        end
    elseif kind == "cast" then
        UpdateCast(frame)
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
        -- A fresh target means a fresh aura list; lift (or re-stack) it above our bar.
        if unit == "target" then EnsureTargetAuras(frame) end
    else
        -- B 方案：容器是 target 帧的子帧，frame:Hide() 会连带隐藏，无需归还
        frame:Hide()
    end
end

function M:UpdateAll()
    for _, unit in ipairs(UNITS) do
        RefreshUnit(unit)
    end
end

local UNIT_EVENTS = {
    UNIT_HEALTH               = "health",
    UNIT_MAXHEALTH            = "health",
    UNIT_POWER_UPDATE         = "power",
    UNIT_MAXPOWER             = "power",
    UNIT_DISPLAYPOWER         = "power",
    UNIT_NAME_UPDATE          = "name",
    UNIT_CONNECTION           = "name",
    UNIT_SPELLCAST_START      = "cast",
    UNIT_SPELLCAST_STOP       = "cast",
    UNIT_SPELLCAST_FAILED     = "cast",
    UNIT_SPELLCAST_INTERRUPTED = "cast",
    UNIT_SPELLCAST_DELAYED    = "cast",
    UNIT_SPELLCAST_CHANNEL_START = "cast",
    UNIT_SPELLCAST_CHANNEL_UPDATE = "cast",
    UNIT_SPELLCAST_CHANNEL_STOP = "cast",
    UNIT_SPELLCAST_INTERRUPTIBLE = "cast",
    UNIT_SPELLCAST_NOT_INTERRUPTIBLE = "cast",
}

-- Factory: the loop variable must not be captured directly.
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
    -- B 方案：布局由引擎的 flow layout 负责，不再需要抢回子帧

    for unit in pairs(frames) do
        for event, kind in pairs(UNIT_EVENTS) do
            EventBus:RegisterUnit(event, unit, MakeUnitHandler(kind))
        end
        -- This client carries the classic-era event name; retail's
        -- UNIT_THREAT_SITUATION_CHANGED would fail registration.
        EventBus:RegisterUnit("UNIT_THREAT_SITUATION_UPDATE", unit, MakeThreatHandler())
    end

--    -- Re-stack the borrowed aura list; positioning only (SetPoint), safe while restricted.
--    EventBus:RegisterUnit("UNIT_AURA", "target", function()
--        local frame = frames.target
--        if frame and frame:IsShown() and frame.blizzardAuras then
--            StackTargetAuras(frame)
--        end
--    end)

    EventBus:Register("PLAYER_TARGET_CHANGED", function()
        RefreshUnit("target")
        RefreshUnit("targettarget")
    end)

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
    EventBus:Register("MONETUI_THEME_CHANGED", function()
    -- The aura buttons belong to the engine, so M:UpdateAll cannot reach them: their borders are
    -- re-tinted here, explicitly.
    TintTargetAuras()
    M:UpdateAll()
end)
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

    -- The state layer paints the borders; without it the theme slot is used.
    RegisterDynamicBorders()

    self:RegisterEvents()
    self:UpdateAll()
end

function M:SetEnabled(enabled)
    -- Hand the borrowed aura list back before the target frame goes away.
    if not enabled then
        -- B 方案：容器随 target 帧一起隐藏，没有要归还的暴雪子帧
    end

    for _, frame in pairs(frames) do
        local show = enabled and UnitExists(frame.unit)
        frame:SetShown(show and true or false)
        -- A hidden module must not keep the state layer's ticker running.
        if frame.monetBorder and frame.monetBorder.SetEnabled then
            frame.monetBorder:SetEnabled(enabled and true or false)
        end
    end

    -- 重新开启时 UpdateAll -> RefreshUnit -> EnsureTargetAuras 会把容器显示回来。
    if enabled then
        self:UpdateAll()
    end
end

ns:Register("UnitFrames", M)
