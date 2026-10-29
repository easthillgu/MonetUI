-- Modules/UnitFrames/ClassPower.lua
-- 单位框的职业资源小格（P5 拆分，2026-10-26）：一格一点的细条，仅玩家框、只服务于有"点数"资源的职业
-- （盗贼/德鲁伊连击点；DK 符文是冷却驱动、不是点数，故不在表里）。
-- move-only：逻辑原样搬自 UnitFrames.lua；接口面：
--   * 输入：M.Setting（单位设置）/ M.Shared（共享设置）/ M.POWER_COLOR（资源色 token 表）；
--   * 输出：M.classpower.{CreateClassPower, ClassPowerIn, UpdateClassPower}。

local ADDON_NAME, ns = ...

local Secrets = ns.Secrets
local Widget  = ns.Widget
local Color   = ns.Color

local M = ns:GetModule("UnitFrames")
if not M then return end

local Setting     = M.Setting
local Shared      = M.Shared
local POWER_COLOR = M.POWER_COLOR

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
            -- 资源点：纯高亮平涂（显式材质 = 不叠渐变、也不按高度换剖面）。
            pip = Widget:Bar(holder, nil, nil, "monet_barfill")
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

M.classpower = {
    CreateClassPower  = CreateClassPower,
    ClassPowerIn      = ClassPowerIn,
    UpdateClassPower  = UpdateClassPower,
}
