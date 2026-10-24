-- Modules/UnitFrames/UnitFrames.lua
-- Player / target / focus / pet unit frames, slim-bar style.
-- Bars are fed raw values via Secrets.SetBar; numeric text only once the client
-- confirms the values are readable (see Utils/Secrets.lua).

local ADDON_NAME, ns = ...


-- 旁表标记（见 Core.lua 的 ns:Mark）：不往暴雪的框体上写字段，
-- 否则那个框体之后跑的暴雪代码会被判成“被 MonetUI 污染”。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
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

-- 可见性交给安全环境：这些框是 SecureUnitButtonTemplate，战斗中不能由我们 Show/Hide
-- （日志里 MonetUITargetFrame:Show()/Hide() 攒了两百多次的根因）。用 state driver 描述
-- "有这个单位就显示"，由客户端的受限环境在战斗中自己切换，我们只负责内容。
-- player 永远存在，所以是无条件 show；其余按 @unit 判断。
local VISIBILITY = {
    player       = "show",
    target       = "[@target,exists] show; hide",
    targettarget = "[@targettarget,exists] show; hide",
    focus        = "[@focus,exists] show; hide",
    pet          = "[@pet,exists] show; hide",
}

--- 换驱动，而不是写显隐：enabled=false 时整块收起。
local function ApplyVisibility(frame, enabled)
    if not frame or type(_G.RegisterStateDriver) ~= "function" then return end
    local condition = enabled and VISIBILITY[frame.unit] or "hide"
    pcall(_G.RegisterStateDriver, frame, "visibility", condition or "hide")
end

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

local TEXT_GAP   = Widget.TEXT_GAP   -- gap between the frame's top edge and the text row
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
            if enable and not Marked(blizzard, "suppressed") then
                Mark(blizzard, "suppressed", true)
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
            elseif not enable and Marked(blizzard, "suppressed") then
                Mark(blizzard, "suppressed", nil)
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

-- 暴雪的施法条：这一套我们自己画（单位框上的火花），暴雪那条必须藏掉，
-- 否则两条叠在一起。
-- 名字按客户端代际不同：零售 12.x 是 PlayerCastingBarFrame / OverlayPlayerCastingBarFrame /
-- PetCastingBarFrame，老客户端是 CastingBarFrame / PlayerCastFrame。
-- TargetFrameSpellBar 是目标框的子帧（跟着目标框一起被藏）。
local CAST_BAR_FRAMES = {
    "PlayerCastingBarFrame",
    "OverlayPlayerCastingBarFrame",
    "PetCastingBarFrame",
    "CastingBarFrame",
    "PlayerCastFrame",
    "CastingBarFrame1",
    "CastingBarFrame2",
    "CastingBarFrame3",
    "CastingBarFrame4",
    "TargetFrameSpellBar",
}

--- 藏掉暴雪的施法条（幂等：暴雪自己会 Show 回来，所以钩一次 Show 按回去）。
function M:HideBlizzardCastBars(enable)
    for _, name in ipairs(CAST_BAR_FRAMES) do
        local frame = _G[name]
        if frame then
            if enable then
                if not Marked(frame, "castHidden") then
                    Mark(frame, "castHidden", true)
                    if frame.SetScript then
                        pcall(frame.SetScript, frame, "OnShow", frame.Hide)
                    end
                    -- 不再 hooksecurefunc(Show)（写方法槽 = 污染）：轮询"变显示了"再藏。
                    if ns.Widget then
                        Mark(frame, "castHook", true)
                        ns.Widget:ShowWatch(frame, function(self)
                            if Marked(self, "castHidden") then pcall(self.Hide, self) end
                        end)
                    end
                end
                pcall(frame.Hide, frame)
            elseif Marked(frame, "castHidden") then
                Mark(frame, "castHidden", nil)
                if frame.SetScript then
                    pcall(frame.SetScript, frame, "OnShow", nil)
                end
                pcall(frame.Show, frame)
            end
        end
    end
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
    -- 血条与能量条之间用 1px 独立分隔线（早先的双段拆分已删，不再需要第二个返回值）。
    return Shared("border") or 1
end

--- 把颜色向白提亮（factor>1）。对每个分量独立 pcall：秘密值乘法会抛错，失败就原样返回，
--- 保证受限环境下能量/血条仍能上色、只是不提亮。
local function Brighten(r, g, b, factor)
    if factor <= 1 then return r, g, b end
    local function bump(c)
        local ok, v = pcall(function() return math.min(c * factor, 1) end)
        return ok and v or c
    end
    return bump(r), bump(g), bump(b)
end

--- The "current" part of a health bar: "highlight" (player, pet), "class" (target,
--- focus) or "health".
--- 玩家单位一律用主题血条色（和玩家自己同一条奶油色）：职业辨认交给能量条
--- （UpdatePowerColor 给 target / focus / targettarget 上职业色），血条不再染职业色。
--- NPC 仍用 UnitSelectionColor 的敌我色（敌对红 / 友善绿）——那是"敌我"信号。
local function FillColor(unit)
    local style = Setting(unit, "fillColor")
    if style == "class" then
        if UnitIsPlayer(unit) then
            local hr, hg, hb = Color:GetHighlight()
            return hr * 0.8, hg * 0.8, hb * 0.8, 1
        end

        local ok, r, g, b = pcall(UnitSelectionColor, unit)
        if ok and r then
            -- target / targettarget 比 player 的暗 highlight 稍亮，层次感更清楚。
            if unit == "target" or unit == "targettarget" then
                r, g, b = Brighten(r, g, b, 1.15)
            end
            return r, g, b, 1
        end
    elseif style == "health" then
        return Color:GetHealth()
    elseif style == "dark" then
        -- 反相风（Andromeda 默认的 style 1）：填充近黑，剩下的血量靠"暗块面积"读。
        -- 要配 lostColor 的 "light" / "theme25" 才有意义，否则暗填充压在黑底上什么都看不到。
        return 0.10, 0.10, 0.10, 1
    end
    -- highlight（player / pet）是 Monet 招牌奶油色，但原色 {0.95,0.93,0.84} 太接近白，
    -- 铺满整条血条会发灰发白、看不出"血量"。压暗 20% 变成有分量的暖奶油，仍读得出来是 highlight。
    local r, g, b = Color:GetHighlight()
    return r * 0.8, g * 0.8, b * 0.8, 1
end

--- The *missing* part of a health bar: pure background, needs no unit value.
local function LostColor(unit)
    local style = Setting(unit, "lostColor")
    if style == "danger" then
        return Color:GetDanger()
    elseif style == "light" then
        -- 反相风的"亮底"：填充压暗（fillColor = dark）之后，空血这边提亮才读得出血量。
        return 0.60, 0.60, 0.60, 1
    elseif style == "theme25" then
        -- Andromeda 的 bg.multiplier = 0.25：空血带一点同色系的暗调，比纯黑 / 纯红柔和。
        local r, g, b = Color:GetPrimary()
        return r * 0.25, g * 0.25, b * 0.25, 1
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
    -- player / target / targettarget 的能量条提亮，和压暗后的血条拉开层次。
    -- 自己的条再高一档：玩家血条现在是统一的暗奶油色（不再染职业色），
    -- 身上唯一的"亮点"就是这条能量，不提亮就显得比目标那条暗。
    local brighten = (unit == "player") and 1.45
                  or ((unit == "target" or unit == "targettarget") and 1.25 or 1)

    if Setting(unit, "powerColor") == "theme" then
        local r, g, b = Color:GetResource()
        r, g, b = Brighten(r, g, b, brighten)
        frame.power:SetStatusBarColor(r, g, b)
        return
    end

    -- 对方是玩家：能量条直接上它的**职业色**（血条已经是统一色，职业就靠这一条认）。
    -- 自己的条不这么干 —— 自己的职业自己知道，保持按能量类型更直观。
    -- UnitClassBase 标着 SecretWhenUnitIdentityRestricted，机密时退回能量类型色。
    if unit ~= "player" and UnitIsPlayer(unit) then
        local classFile = UnitClassBase(unit)
        if type(classFile) == "string" and not Secrets.IsSecret(classFile) then
            local cr, cg, cb = Color:ClassColor(classFile)
            if cr then
                cr, cg, cb = Brighten(cr, cg, cb, brighten)
                frame.power:SetStatusBarColor(cr, cg, cb)
                return
            end
        end
    end

    -- Guard so a client that hides the token never hands us a secret table key.
    local _, token, r, g, b = UnitPowerType(unit)
    local tuned = (type(token) == "string" and not Secrets.IsSecret(token))
                  and POWER_COLOR[token] or nil
    if tuned then
        local tr, tg, tb = Brighten(tuned[1], tuned[2], tuned[3], brighten)
        frame.power:SetStatusBarColor(tr, tg, tb)
        return
    end

    local nr, ng, nb = Secrets.Number(r), Secrets.Number(g), Secrets.Number(b)
    if nr and ng and nb and (nr + ng + nb) > 0 then
        nr, ng, nb = Brighten(nr, ng, nb, brighten)
        frame.power:SetStatusBarColor(nr, ng, nb)
        return
    end

    local cr, cg, cb = Color:GetResource()
    cr, cg, cb = Brighten(cr, cg, cb, brighten)
    frame.power:SetStatusBarColor(cr, cg, cb)
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
        frame.cast:SetScript("OnUpdate", nil)
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

    -- 受限时 startMS / endMS 是保密值（Secret number），OnUpdate 里的减法会抛
    -- "attempt to perform arithmetic on a secret number value"（零售服实测）。拿不到普通数字就
    -- 把火花钉在起点并停掉 OnUpdate，收尾交给下一次施法事件；施法条本身照常显示。
    if Secrets.IsSecret(startMS) or Secrets.IsSecret(endMS) then
        frame.cast.startTimeMS = nil
        frame.cast.endTimeMS = nil
        frame.cast.channeling = channel
        frame.cast:Show()
        frame.cast.spark:Show()
        frame.cast.spark:ClearAllPoints()
        frame.cast.spark:SetPoint("BOTTOM", frame.cast, "BOTTOMLEFT", 0, 0)
        frame.cast:SetScript("OnUpdate", nil)
        return
    end

    -- Store times for spark calculation
    frame.cast.startTimeMS = startMS
    frame.cast.endTimeMS = endMS
    frame.cast.channeling = channel
    frame.cast:Show()
    frame.cast.spark:Show()

    -- OnUpdate 挂在**普通子框**（frame.cast）上，不挂在单位框上：
    -- 单位框现在是受保护的安全单位按钮，战斗中改它的脚本会被拒，
    -- 而战斗恰恰是施条动画最要紧的时候。
    local castFrame = frame.cast
    castFrame:SetScript("OnUpdate", function(self, elapsed)
        local cast = castFrame
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
    frame.cast:SetScript("OnUpdate", nil)
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
--   158px content / 24px wide icons => 6 per row, gaps = (158 - 6*24) / 5 = 2.8px.
-- Height 18 keeps the icons compact (24:18 = 4:3); the square spell art is cropped to that aspect.
-- 时长 / 堆叠数字的字号按**图标高度**等比算（见 StyleAuraButton），所以这里改图标尺寸，
-- 字会自己跟着走 —— 没有任何写死的字号。
local TARGET_AURA_ICON_W   = 24
local TARGET_AURA_ICON_H   = 18
local TARGET_AURA_BORDER_PX = 0   -- no width inset: keeps the full 24px, so the art is not stretched
local TARGET_AURA_V_CROP_PX = 3   -- height crop top and bottom (24 - 3 - 3 = 18)
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
local function TintAuraButton(button)
    local host = Marked(button, "borderHost")
    if not host then return end
    -- 只写我们自己的子帧。写在按钮的 region 上会被 Bad self 拒掉（pcall 吞掉后边框就永远是
    -- 创建那一刻的颜色，换主题也不变）—— 子帧没有这个限制，重涂是幂等的。
    Widget:TintIconBorder(host)   -- 与 NP 的 debuff 色带共用一点(review #4)
end

-- 时长文本的染色曲线：配色和动作条冷却（Modules/Cooldown）同一套 ——
--   <10s 红 · <60s 黄 · <1h 蓝 · <1d 绿 · 更长灰
-- 曲线由**引擎**按剩余时长求值（DurationTextBinding 的 RemainingDuration 属性），
-- 所以就算光环数值是机密的，颜色照样会变；只建一条，所有光环按钮共用。
local durationColorCurve

local function GetDurationColorCurve()
    if durationColorCurve ~= nil then return durationColorCurve or nil end

    local curveUtil = _G.C_CurveUtil
    if type(curveUtil) ~= "table" or type(curveUtil.CreateColorCurve) ~= "function"
        or type(_G.CreateColor) ~= "function" then
        durationColorCurve = false
        return nil
    end
    local ok, curve = pcall(curveUtil.CreateColorCurve)
    -- 注意：本客户端的曲线对象是 **userdata**（不是 table），只认 table 会把它当成失败。
    local curveType = type(curve)
    if not ok or (curveType ~= "table" and curveType ~= "userdata")
        or type(curve.AddPoint) ~= "function" then
        durationColorCurve = false
        return nil
    end

    local function point(x, r, g, b)
        local okColor, color = pcall(_G.CreateColor, r, g, b, 1)
        if okColor and color then pcall(curve.AddPoint, curve, x, color) end
    end
    -- 每个单位切换点两侧各放一个点，做出 1 秒的快速过渡（曲线本身是连续插值的）。
    point(0,        0.99, 0.21, 0.07)   -- 秒：红（<10s）
    point(10,       0.99, 0.21, 0.07)
    point(11,       1.00, 0.91, 0.00)   -- 秒：黄
    point(59,       1.00, 0.91, 0.00)
    point(61,       0.13, 0.78, 0.87)   -- 分钟：蓝
    point(3599,     0.13, 0.78, 0.87)
    point(3601,     0.31, 0.80, 0.21)   -- 小时：绿
    point(86399,    0.31, 0.80, 0.21)
    point(86401,    0.75, 0.75, 0.70)   -- 天：灰
    point(31536000, 0.75, 0.75, 0.70)

    durationColorCurve = curve
    return curve
end

--- debuff 的**解魔法类型色边框**。原来那条有色边框不是被裁图标裁掉的，是模板差异：
--- 我们用的是 CustomAuraButtonTemplate（光板，没有任何边框 region），暴雪目标框的 debuff
--- 按钮模板才自带 DispelBorder。
---
--- 做法：用引擎的 AddDispelTypeTexture 把边框交回**引擎**上色（暴雪代码按 auraData.dispelName
--- 调 AuraUtil.SetAuraBorderColor），全程不经过插件代码，所以"initializeFrame 之后按钮不可写"
--- 这条限制不影响它。样式用 PreserveAsset：引擎**只改顶点色**、不动贴图，于是形状还是我们的
--- —— 四条 1 物理像素的直边拼一个平直矩形环，和 buff 那圈主题边框同一套几何（暴雪那种圆角厚
--- 图集边框太"重"，不贴 Monet）。
--- 引擎要求一个边框 = 一个 Texture，所以四条边各自注册一次；它们同时被 Show/Hide、同时上色。
local function AddDispelBorder(button, pad, expand)
    local styles = _G.Enum and _G.Enum.CustomAuraButtonDispelTypeTextureStyle
    local style = styles and styles.PreserveAsset
    if style == nil or type(button.AddDispelTypeTexture) ~= "function" then return false end
    -- expand = 环相对按钮外扩多少（正数向外）；厚度永远是 pad。默认向外扩一个 pad，
    -- 目标框用这个；玩家 buff 行传 0，环就贴着按钮边、画在按钮**里面**，和自绘那套一致。
    if type(expand) ~= "number" then expand = pad end

    -- 和暴雪原版一致：没有解魔法类型的 debuff（物理/流血）也画一圈灰边，不然后者完全没边框。
    local opts = {
        style = style,
        showWhenHarmful = true,     -- 有害光环（debuff）
        showWhenHelpful = false,
        showWithoutDispelType = true,
    }

    local edges = {
        -- { 起点, 终点, 起点偏移, 终点偏移, 方向 }
        { "TOPLEFT",     "TOPRIGHT",    -expand,  expand, "h" },
        { "BOTTOMLEFT",  "BOTTOMRIGHT", -expand, -expand, "h" },
        { "TOPLEFT",     "BOTTOMLEFT",  -expand,  expand, "v" },
        { "TOPRIGHT",    "BOTTOMRIGHT",  expand,  expand, "v" },
    }

    local made = 0
    for i = 1, #edges do
        local from, to, off, offY, axis = edges[i][1], edges[i][2], edges[i][3], edges[i][4], edges[i][5]
        local texture = button:CreateTexture(nil, "OVERLAY")
        if texture then
            -- 先定白色（引擎随后把顶点色改成解魔法类型色），再定几何，最后才交给引擎。
            pcall(texture.SetColorTexture, texture, 1, 1, 1, 1)
            if axis == "h" then
                pcall(texture.SetPoint, texture, from, button, from, off, offY)
                pcall(texture.SetPoint, texture, to, button, to, -off, offY)
                pcall(texture.SetHeight, texture, pad)
            else
                pcall(texture.SetPoint, texture, from, button, from, off, offY)
                pcall(texture.SetPoint, texture, to, button, to, off, -offY)
                pcall(texture.SetWidth, texture, pad)
            end
            if pcall(button.AddDispelTypeTexture, button, texture, opts) then
                made = made + 1
                Mark(button, "dispelBorder", texture)
            else
                pcall(texture.Hide, texture)
            end
        end
    end
    return made > 0
end

--- initializeFrame：一个引擎按钮只进来一次。碰按钮的事必须在这里做完。
--- spec（可选）：{ width, height, crop } —— BuffFrame 的战斗兜底复用这套样式，但玩家 buff 行是
--- 方形图标、且不裁边（目标框的 18x14 槽才需要 3:4 裁切）。不传 spec 就等于原来的目标框样子。
local function StyleAuraButton(button, kind, spec)
    if type(button) ~= "table" then return end

    local specW = (type(spec) == "table" and spec.width) or TARGET_AURA_ICON_W
    local specH = (type(spec) == "table" and spec.height) or TARGET_AURA_ICON_H
    pcall(button.SetSize, button, specW, specH)
    -- 引擎按钮默认**可点**：压在条上会吃掉换目标的点击。只有这个窗口能可靠关掉。
    pcall(button.SetMouseClickEnabled, button, false)

    local okLevel, buttonLevel = pcall(button.GetFrameLevel, button)
    if not (okLevel and type(buttonLevel) == "number") then buttonLevel = 1 end
    local pad = Media:Mult()
    if type(pad) ~= "number" or pad <= 0 then pad = 1 end

    -- spec.borderInside = true：边框画在按钮**里面**（自绘那套就是这样：边框占按钮矩形内侧
    -- 那 1px，图标再内缩 1px 让出来）。默认仍向外扩，目标框那套沿用这个已验证的外观。
    local borderInside = (type(spec) == "table" and spec.borderInside) and true or false

    -- debuff 优先用引擎的解魔法类型色边框（就是"原始那种带色边框"）；buff 用主题边框。
    -- 引擎那条建不出来（枚举/方法缺失）时退回主题边框，不会出现完全没边框的图标。
    if kind ~= "debuff" or not AddDispelBorder(button, pad, borderInside and 0 or nil) then
        -- 边框画在**我们自己的子帧**上，不画进按钮的贴图：引擎按钮在 initializeFrame 返回之后
        -- 就受 DenyTaintedAccessWhenAurasAreSecret 约束，之后再对它的 region 调 SetColorTexture
        -- 会被拒 —— 这就是"边框染色失败"、换主题也不跟随的根因。子帧是我们建的，任何时候都能重涂
        -- （Ellesmere 的 borderHost 同一个道理）。
        -- 几何：默认比图标外扩 1 个**物理像素**（Media:Mult 就是那个换算），层级压到按钮之下，所以环
        -- 只在图标外沿露出来；用 ApplyBorder（只有边、无底色）而不是整块色贴图 —— 万一层级没压住，
        -- 也只有那 1px 的环会盖到图标，不会把图标糊成一块色。
        local borderHost = CreateFrame("Frame", nil, button, "BackdropTemplate")
        if borderInside then
            borderHost:SetAllPoints(button)
        else
            borderHost:SetPoint("TOPLEFT", button, "TOPLEFT", -pad, pad)
            borderHost:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", pad, -pad)
        end
        borderHost:SetFrameLevel(math.max(0, buttonLevel - 1))
        borderHost:EnableMouse(false)
        Widget:ApplyBorder(borderHost, 1)
        Mark(button, "borderHost", borderHost)
    end

    local icon = button:CreateTexture(nil, "ARTWORK")
    -- spec.iconInset：图标从按钮四边内缩多少（要和边框宽度一致，否则边框会被图标压住）。
    local iconInset = (type(spec) == "table" and spec.iconInset) or 0
    if type(iconInset) == "number" and iconInset > 0 then
        icon:SetPoint("TOPLEFT", button, "TOPLEFT", iconInset, -iconInset)
        icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -iconInset, iconInset)
    else
        icon:SetAllPoints(button)
    end
    -- spec.crop：nil = 目标框那套 3:4 槽裁切；false = 不裁；{x0,x1,y0,y1} = 指定裁切。
    -- 玩家 buff 行要的正是自绘那套 CropIcon(0.08, 0.92, …)：法术图标自带一圈 8% 的描边，
    -- 不裁掉的话画面会缩在格子中间，和脱战时那套看着不是一个东西。
    local crop = type(spec) == "table" and spec.crop or nil
    if crop == nil then
        -- Crop the square spell art to the 3:4 (H:W) slot aspect.
        local x0, x1, y0, y1 = AuraIconTexCoord()
        ns.Skin:CropIcon(icon, x0, x1, y0, y1)
    elseif type(crop) == "table" then
        ns.Skin:CropIcon(icon, crop[1], crop[2], crop[3], crop[4])
    end

    local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    -- 冷却覆盖图标本身（不是整颗按钮），这样扫过的底色不会染到边框那一圈。
    cd:SetAllPoints(icon)
    pcall(cd.SetDrawEdge, cd, false)
    pcall(cd.SetDrawSwipe, cd, true)

    -- 时长 / 堆叠数字的字号**跟着图标当前的实际尺寸走**（不写死字号）：现量按钮的宽高，
    -- 高度不超过 45%（上下各留约 2 单位内边距）、宽度保证最长 5 个字符（"1h37m"）不越界，
    -- 两个上限取更小的那个，再夹一个可读下限。
    -- Andromeda 的口径是 fontSize = floor(size / 30 * 10 + 0.5)（modules/blizzard/aura.lua），
    -- 但那是给 30px 方形图标、外加 HalfHeight 字体算的；我们的图标是 4:3 的小格，
    -- 直接照抄会顶满整格还往外溢。只要图标尺寸（TARGET_AURA_ICON_W/H 或以后的配置项）
    -- 变了，这里算出来的字号就跟着变，不需要改代码。
    -- exact = true 让算出来的值真的生效（Widget:SetFont 默认会把 ≤10 的都夹到 10）。
    local okW, iconW = pcall(button.GetWidth, button)
    local okH, iconH = pcall(button.GetHeight, button)
    if not (okW and type(iconW) == "number" and iconW > 0) then iconW = TARGET_AURA_ICON_W end
    if not (okH and type(iconH) == "number" and iconH > 0) then iconH = TARGET_AURA_ICON_H end
    local textSize = math.max(4, math.min(
        math.floor(iconH * 0.45 + 0.5),
        math.floor(iconW / 3.4 + 0.5)))
    -- 调用方可以强制字号（BuffFrame 要跟它自绘那套的 12px 对齐）。
    if type(spec) == "table" and type(spec.textSize) == "number" then
        textSize = spec.textSize
    end

    -- 时长文本：先给冷却自带的那行数字留条后路（换成像素字体、压进图标下沿），
    -- 万一下面 RegisterDurationText 不被客户端接受，就继续用它们。
    local inset = math.max(2, math.floor(textSize * 0.55 + 0.5))
    local okRegions, regions = pcall(function() return { cd:GetRegions() } end)
    if okRegions then
        for i = 1, #regions do
            local region = regions[i]
            if type(region) == "table" and type(region.GetObjectType) == "function"
                and region:GetObjectType() == "FontString" then
                Widget:SetFont(region, textSize, "pingfang", Media.outlineFlags, true)
                pcall(region.ClearAllPoints, region)
                pcall(region.SetPoint, region, "BOTTOM", button, "BOTTOM", 0, inset)
                pcall(region.SetJustifyH, region, "CENTER")
            end
        end
    end

    -- 自己建 FontString 注册给 SetDurationText：只有这条路能带**颜色曲线**
    -- （textColor.curve + RemainingDuration，引擎按剩余时长求值，机密值也有效）。
    -- 建在冷却帧上（作为它的 region）—— 实测引擎自己那行数字就是这样画的、位于图标之上；
    -- 挂在按钮的子帧里会被图标盖住。
    local duration = cd:CreateFontString(nil, "OVERLAY")
    -- 时长数字用 PingFangPixel + 硬描边：这套字号是跟着图标尺寸算的（目标框光环 14-20px，
    -- 算出来 4-8px），像素字体在这个尺寸下认不出来。
    Widget:SetFont(duration, textSize, "pingfang", Media.outlineFlags, true)
    duration:SetPoint("BOTTOM", button, "BOTTOM", 0, inset)
    duration:SetJustifyH("CENTER")

    -- 层数：同样画在冷却帧上（在图标之上），锚在右上角，和左下角的时长错开。
    local stack = cd:CreateFontString(nil, "OVERLAY")
    Widget:SetFont(stack, textSize, "pixel", nil, true)
    stack:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
    stack:SetJustifyH("RIGHT")

    -- 区域全部就绪之后才注册（见上面第 3 条约束）。
    pcall(button.SetIcon, button, icon)
    pcall(button.SetDurationCooldown, button, cd)
    pcall(button.SetApplicationCount, button, stack, {})

    -- 带颜色曲线注册时长；客户端不接受这套选项时退回最简形式，再不行才用冷却自带的数字。
    local prop = _G.Enum and Enum.DurationTextBindingProperty
    prop = prop and prop.RemainingDuration
    local curve = GetDurationColorCurve()
    local registered = false
    if curve and prop ~= nil then
        registered = pcall(button.SetDurationText, button, duration,
            { textColor = { curve = curve, property = prop } })
    end
    if not registered then
        registered = pcall(button.SetDurationText, button, duration, {})
        -- 退一步：文本已注册、只是这次没接受颜色选项，就单独给绑定设曲线
        -- （不同客户端对 options 的校验不一致，这条路等价）。
        if registered and curve and prop ~= nil
            and type(button.GetDurationTextBinding) == "function" then
            local okBinding, binding = pcall(button.GetDurationTextBinding, button)
            local bindingType = type(binding)
            if okBinding and (bindingType == "table" or bindingType == "userdata")
                and type(binding.SetTextColorCurve) == "function" then
                pcall(binding.SetTextColorCurve, binding, curve, prop)
            end
        end
    end
    if registered then
        -- 我们自己的文本生效了：关掉冷却自带的那行数字，避免同一格里两份时长。
        pcall(cd.SetHideCountdownNumbers, cd, true)
    else
        duration:Hide()
    end

    TintAuraButton(button)
end

--- 导出给 BuffFrame：战斗里客户端不给插件读光环，玩家 buff 行改由引擎 AuraContainer 显示，
--- 按钮样式必须和目标框一致，所以共用这一个函数（尺寸/裁切由 spec 覆盖）。
ns.AuraButtonStyle = StyleAuraButton
--- 曲线必须由**非 securecall** 的调用方先建好：引擎的 initializeFrame 是 securecall 进去跑的，
--- 在里面首次调 C_CurveUtil.CreateColorCurve 会被拒。
ns.PrepareAuraStyle = GetDurationColorCurve

--- 流式布局：贴左下、向右上长、每行自动计算图标数并两端对齐（justified）。
-- Anchor at BOTTOMLEFT of frame (frame outer left edge), grow RIGHT then UP.
local function ApplyContainerLayout(container, frame)
    local iconsPerRow, actualSpacing, rowWidth = ComputeAuraLayout(frame:GetWidth())

    FlowCall(container, "SetFlowLayoutAnchorPoint", "SetAuraLayoutAnchorPoint", "BOTTOMLEFT")
    -- 生长方向必须传 AnchorUtil.FlowDirection 的**枚举值**（Right=1 / Up=1、Left/Down=-1）。
    -- 传字符串 "RIGHT"/"UP" 会被 wrapper 里的 assert 拒掉，pcall 吞掉之后方向还是默认的
    -- 向下 —— 这就是之前"满一行往下换行"的原因。先试数字版，老客户端再退字符串版。
    local flow = _G.AnchorUtil and _G.AnchorUtil.FlowDirection
    local growthSet = false
    if type(flow) == "table" and flow.Right ~= nil and flow.Up ~= nil then
        growthSet = FlowCall(container, "SetFlowLayoutGrowthDirection", "SetAuraLayoutGrowthDirection",
            flow.Right, flow.Up)
    end
    if not growthSet then
        FlowCall(container, "SetFlowLayoutGrowthDirection", "SetAuraLayoutGrowthDirection", "RIGHT", "UP")
    end

    local axes = _G.AnchorUtil and _G.AnchorUtil.FlowLayoutAxis
    if axes and type(container.SetFlowLayoutAxis) == "function" then
        pcall(container.SetFlowLayoutAxis, container, axes.Horizontal)
    end

    -- Set element spacing to the justified spacing (may be fractional, FlowLayout handles it)
    FlowCall(container, "SetFlowLayoutElementSpacing", "SetAuraLayoutElementSpacing", actualSpacing)
    FlowCall(container, "SetFlowLayoutLineSpacing", "SetAuraLayoutLineSpacing", actualSpacing)

    -- 最大行宽。**不能**正好给 rowWidth：引擎判断换行时会先把一个 elementSpacing 也算进
    -- 下一格的位置（即 6 格需要 6*24 + 6*2.8 = 160.8，而不是我们算的两端对齐 158），
    -- 于是恰好排满 6 个的一行在第 6 个之前就换行了（实测 5 个就换行）。多给一个间距的余量，
    -- 刚好放下 iconsPerRow 个、又放不下 iconsPerRow + 1 个。
    local lineSize = rowWidth + actualSpacing
    FlowCall(container, "SetFlowLayoutMaximumLineSize", "SetAuraLayoutRowWidth", lineSize)

    -- Store for potential refresh
    Mark(container, "auraLayout", {
        iconsPerRow = iconsPerRow,
        spacing = actualSpacing,
        rowWidth = rowWidth,
    })
    return iconsPerRow, actualSpacing, rowWidth
end

--- 建一个只装一组光环的容器。成功返回 container，失败返回 nil + 原因。
local function CreateAuraContainer(parent, key, filterString, kind)
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
        -- 闭包把"这是 debuff 组"带进 init：debuff 走引擎的解魔法类型色边框。
        initializeFrame = function(button) StyleAuraButton(button, kind) end,
    }
    -- 这两个是枚举**表**（AuraContainerSortMethod.Default = 0、SortDirection.Normal = 0），
    -- 直接把表当参数传会被引擎拒绝（"sortMethod must be a valid AuraContainerSortMethod"，
    -- 零售 12.x 实测）。取出标量再传；取不到就干脆不传，让引擎用默认排序。
    local sortMethod = _G.AuraContainerSortMethod
    if type(sortMethod) == "table" then sortMethod = sortMethod.Default end
    if type(sortMethod) == "number" then opts.sortMethod = sortMethod end

    local sortDirection = _G.AuraContainerSortDirection
    if type(sortDirection) == "table" then sortDirection = sortDirection.Normal end
    if type(sortDirection) == "number" then opts.sortDirection = sortDirection end

    local okAdd, err = pcall(container.AddAuraGroup, container, key, filterString, opts)
    if not okAdd then
        return nil, "AddAuraGroup 失败: " .. tostring(err)
    end

    pcall(container.SetUnit, container, "target")
    pcall(container.UpdateAllAuras, container)
    return container
end

local targetAuraDebuffs, targetAuraBuffs
local RebuildTargetAuras   -- 前置声明：EnsureTargetAuras 战斗中要把它排进 ns:AfterCombat（实现在下面）

--- 建/显示目标光环容器。取代 A 方案的 BorrowTargetAuras。
--- buff 贴着血条、debuff 叠在 buff 之上，两组都是满一行往上换行。
local function EnsureTargetAuras(frame)
    if not frame then return end

    if not Shared("showTargetAuras") then
        if targetAuraDebuffs then targetAuraDebuffs:Hide() end
        if targetAuraBuffs then targetAuraBuffs:Hide() end
        return
    end

    -- 染色曲线必须在这里（不安全上下文）先建好：引擎按钮的 initializeFrame 是
    -- securecall 进去跑的，在里面第一次调 C_CurveUtil.CreateColorCurve 会被拒，
    -- 结果所有按钮都拿不到曲线、时长只剩白色。
    GetDurationColorCurve()

    if not targetAuraDebuffs then
        -- 战斗中建容器会被拦：拿到的一组容器**永远是空的**（实测 0 个按钮显示、换目标也不刷新），
        -- 而且之后没人再重建。所以战斗里干脆不建，排队到脱战补做（ns:AfterCombat）。
        if type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() then
            ns:AfterCombat("unitframes-auras", RebuildTargetAuras)
            return
        end
        local debuffs, why = CreateAuraContainer(frame, "monetTargetDebuffs", "HARMFUL", "debuff")
        if not debuffs then
            -- 一次性警告，不刷屏。
            if not M.__auraWarned then
                M.__auraWarned = true
                ns:Print("目标光环（原生 AuraContainer）不可用：" .. tostring(why))
            end
            return
        end
        targetAuraDebuffs = debuffs

        local buffs = CreateAuraContainer(frame, "monetTargetBuffs", "HELPFUL", "buff")
        targetAuraBuffs = buffs

        -- 排法（都是 BOTTOMLEFT 锚点 + 向上生长）：buff 贴着血条，第一行满了往上排第二行；
        -- debuff 再叠在 buff 上面，同样是满行往上换行。buff 变高时 debuff 跟着往上抬。
        local gap = Shared("targetAuraGap") or 22
        if buffs then
            buffs:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, gap)
            debuffs:SetPoint("BOTTOMLEFT", buffs, "TOPLEFT", 0, TARGET_AURA_SPACING)
        else
            debuffs:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, gap)
        end
    end

    if targetAuraDebuffs then targetAuraDebuffs:Show() end
    if targetAuraBuffs then targetAuraBuffs:Show() end

    -- 换目标以后上一个目标的光环还留在屏幕上：引擎只在光环**变化**时刷新按钮，
    -- 换目标本身不算变化。客户端自己留了口子 —— AuraContainerSharedMixin:UpdateAllAuras
    -- 的注释就写着 "Exposed to allow external events to trigger refreshes where needed
    -- (e.g. target changes)" —— 这里就是那个 external event。
    if targetAuraDebuffs then pcall(targetAuraDebuffs.UpdateAllAuras, targetAuraDebuffs) end
    if targetAuraBuffs then pcall(targetAuraBuffs.UpdateAllAuras, targetAuraBuffs) end
end

--- 主题变化时**重建**容器。引擎光环按钮在 initializeFrame 返回之后就不可再写 —— 实测连我们
--- 自己建在按钮里的子帧都被 DenyTaintedAccessWhenAurasAreSecret 拒掉（SetBackdropBorderColor /
--- SetAlpha / Hide 全部报 "Attempt to access forbidden object from code tainted by an AddOn"）。
--- 所以边框颜色只能在创建窗口里定稿，换主题的唯一出路是把容器连同按钮一起扔掉重建。
--- 战斗中建容器会被拦（会得到一组永远空的容器）：把自己排进 ns:AfterCombat，脱战重试。
function RebuildTargetAuras()
    if type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() then
        ns:AfterCombat("unitframes-auras", RebuildTargetAuras)
        return
    end
    for _, container in ipairs({ targetAuraDebuffs, targetAuraBuffs }) do
        if container then
            pcall(container.ClearAllPoints, container)
            pcall(container.Hide, container)
            pcall(container.SetParent, container, nil)
        end
    end
    targetAuraDebuffs, targetAuraBuffs = nil, nil
    EnsureTargetAuras(frames.target)
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
        if not Marked(frame, "auraWarned") then
            Mark(frame, "auraWarned", true)
            print("|cffce3e2fMonetUI|r: 未在 TargetFrame 上找到光环子帧，目标框光环已跳过（帧名待实机核对）")
        end
        return
    end

    Mark(frame, "auraWarned", nil)
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

    -- UnitThreatSituation 返回 nil 有两种完全不同的含义：
    --   * 机密值（受限环境下）-> 保留上次状态，等 PLAYER_REGEN_ENABLED 再判；
    --   * 普通的 nil -> 客户端压根没有威胁信息（脱战后就是这样），此时必须**清掉**红边。
    -- 以前把两者当一回事（`if status == nil then return end`），于是脱战后 threatStatus 停在 3、
    -- monetBorderOverride 一直是 true，红边就再也不会消失。
    local raw = UnitThreatSituation(frame.unit)
    if raw ~= nil and Secrets.IsSecret(raw) then return end
    local status = Secrets.Number(raw) or 0

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

    -- 安全单位按钮：和暴雪一样，左键 = 选中（设为目标），右键 = 弹单位菜单
    -- （设置焦点等）。SecureUnitButtonTemplate 的两个模板写在同一条串里实测可用。
    -- 受保护的框体上非安全脚本（OnEnter / OnLeave / OnUpdate）照样能设，
    -- 只有 SetAttribute / RegisterForClicks 这类安全动作在战斗中会被拒。
    local frame = Widget:CreateFrame("MonetUI" .. unit:gsub("^%l", string.upper) .. "Frame",
        UIParent, width, height, "SecureUnitButtonTemplate, BackdropTemplate", "CheckButton")
    frame.unit = unit
    frame.label = UNIT_LABEL[unit] or unit

    -- 单位按钮的契约：unit + *type1(target) + *type2(togglemenu)。
    -- 全部在创建时设好（登录时不在战斗中），之后战斗里不需要再改。
    pcall(frame.SetAttribute, frame, "unit", unit)
    pcall(frame.SetAttribute, frame, "*type1", "target")
    pcall(frame.SetAttribute, frame, "*type2", "togglemenu")
    pcall(frame.RegisterForClicks, frame, "AnyUp")

    local health = Widget:Bar(frame, width - border * 2, healthHeight)
    health:SetPoint("TOPLEFT", frame, "TOPLEFT", border, -border)
    health:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -border, -border)

    -- The *missing* part: a plain texture behind the fill, tinted by UpdateHealthColor.
    local lost = Widget:LostBarBG(health, 1, 1, 1)

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

function M:GetFrame(unit)
    return frames[unit]
end

function M:UpdateUnit(unit, kind, powerType)
    local frame = frames[unit]
    -- IsShown 在 1.60 标了 SecretReturnsForAspect（Shown），受限时会是机密值：用 Secrets.Bool 兜。
    if not frame or not Secrets.Bool(frame:IsShown(), false) then return end
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
--- 显隐本身不在这里做：visibility 驱动负责（战斗中 Show/Hide 是受保护的），
--- 这里只把内容刷成当前单位的值。
local function RefreshUnit(unit)
    local frame = frames[unit]
    if not frame then return end
    if not UnitExists(unit) then
        -- 单位没了：顺手把威胁状态清掉，否则下次显形会先亮一圈旧红边（targettarget 尤其常见）。
        frame.threatStatus = nil
        if frame.monetBorderOverride then
            frame.monetBorderOverride = false
            RestoreDynamicBorder(frame)
        end
        return
    end

    UpdateHealth(frame)
    UpdatePower(frame)
    UpdateClassPower(frame)
    UpdateName(frame)
    UpdateThreat(frame)
    -- A fresh target means a fresh aura list; lift (or re-stack) it above our bar.
    if unit == "target" then EnsureTargetAuras(frame) end
end

function M:UpdateAll()
    for _, unit in ipairs(UNITS) do
        RefreshUnit(unit)
    end
end

--- 颜色类设置改了要立刻看得到：重涂血条 / 损失部分 / 能量条 / 分隔线，再刷一遍数值。
--- （颜色是在 CreateUnitFrame 里一次性涂的，只跑 UpdateAll 不会重涂 —— 之前改颜色下拉
--- 必须 /reload 才生效，就是这里缺了这一层。）
function M:Apply()
    for _, frame in pairs(frames) do
        UpdateHealthColor(frame)
        UpdatePowerColor(frame)
    end
    self:UpdateAll()
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
        if frame and Secrets.Bool(frame:IsShown(), false) then UpdateThreat(frame) end
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
    EventBus:Register("PLAYER_REGEN_ENABLED", function()
        -- 战斗中被拦的容器重建 / 开关排队都由 ns:AfterCombat 在更早的统一排空里做掉。
        M:UpdateAll()
    end)
    -- Death / resurrection: the bars grey out and come back.
    EventBus:Register("PLAYER_DEAD", function() M:UpdateAll() end)
    EventBus:Register("PLAYER_ALIVE", function() M:UpdateAll() end)
    EventBus:Register("PLAYER_UNGHOST", function() M:UpdateAll() end)
    EventBus:Register("MONETUI_RESTRICTION_CHANGED", function() M:UpdateAll() end)
    EventBus:Register("MONETUI_THEME_CHANGED", function()
    -- The aura buttons belong to the engine and are unwritable after creation, so a theme change
    -- cannot re-tint them: the containers are rebuilt instead (border colour is fixed at creation).
    RebuildTargetAuras()
    M:UpdateAll()
end)
end

function M:Initialize()
    for _, unit in ipairs(UNITS) do
        local default = ns.DEFAULTS.unitFrames[unit]
        frames[unit] = CreateUnitFrame(unit, default)
        PositionFrame(frames[unit])
        ApplyVisibility(frames[unit], true)
    end

    if ns:DB().unitFrames.hideBlizzard then
        self:SuppressBlizzard(true)
    end

    -- 暴雪的施法条：这一套自己画，暴雪那条藏掉。
    self:HideBlizzardCastBars(true)

    -- The state layer paints the borders; without it the theme slot is used.
    RegisterDynamicBorders()

    self:RegisterEvents()
    self:UpdateAll()
end

--- 安全单位按钮的显隐：走 visibility 驱动（战斗中不能由我们 SetShown ——
--- 日志里 MonetUITargetFrame:Hide()/Show() 攒了两百多次就是这条路径）。
local function ApplyEnabled(enabled)
    for _, frame in pairs(frames) do
        ApplyVisibility(frame, enabled)
        -- A hidden module must not keep the state layer's ticker running.
        if frame.monetBorder and frame.monetBorder.SetEnabled then
            frame.monetBorder:SetEnabled(enabled and true or false)
        end
    end
end

function M:SetEnabled(enabled)
    -- 模块整个关掉：暴雪的施法条还回去（我们自己那条也没了）。
    self:HideBlizzardCastBars(not enabled)

    -- 显隐本身是受保护操作：不在战斗当场做，在战斗排队到脱战（ns:AfterCombat）。
    ns:AfterCombat("unitframes-enabled", function()
        ApplyEnabled(enabled)
        -- 重新开启时 UpdateAll -> RefreshUnit -> EnsureTargetAuras 会把容器显示回来。
        if enabled then self:UpdateAll() end
    end)
end

ns:Register("UnitFrames", M)
