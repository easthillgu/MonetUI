-- Modules/Cooldown/Cooldown.lua
-- Action bar cooldowns + ability state.
--
--  * the built-in cooldown swipe / countdown numbers are re-styled with the
--    addon's countdown font;
--  * charge counts, hotkeys and macro names get the addon fonts;
--  * ability state (usable / lacking resources / out of range) is reflected in
--    the icon tint, "触发监控" style.
--
-- The client keeps the cooldown values themselves secret in restricted states,
-- so this module never reads a start time: it only styles the widgets Blizzard
-- already drives.

local ADDON_NAME, ns = ...

local Widget = ns.Widget
local Secrets = ns.Secrets
local EventBus = ns.EventBus

local M = { name = "Cooldown" }

local buttons = {}

-- Bars that exist on a standard action bar layout.
local ACTION_BUTTON_GROUPS = {
    { prefix = "ActionButton",              count = 12 },
    { prefix = "MultiBarBottomLeftButton",  count = 12 },
    { prefix = "MultiBarBottomRightButton", count = 12 },
    { prefix = "MultiBarRightButton",       count = 12 },
    { prefix = "MultiBarLeftButton",        count = 12 },
    { prefix = "MultiBar5Button",           count = 12 },
    { prefix = "MultiBar6Button",           count = 12 },
    { prefix = "MultiBar7Button",           count = 12 },
}

-- -- Styling ------------------------------------------------------------------

local function StyleCooldown(cd, size)
    if not cd then return end
    cd:SetHideCountdownNumbers(false)
    if cd.SetDrawEdge then cd:SetDrawEdge(false) end
    if cd.SetDrawBling then cd:SetDrawBling(false) end
    Widget:StyleCooldownText(cd, size or 15, "cooldown")
end

local function StyleButton(button)
    if not button or button.__monetStyled then return end
    button.__monetStyled = true

    -- Blizzard already drives the swipe (and its start time may be secret), so we
    -- only ever re-style the widgets it owns instead of creating our own.
    local cd = button.Cooldown or button.cooldown
    if cd then
        StyleCooldown(cd)
    end

    if button.Count then  pcall(Widget.SetFont, Widget, button.Count, 13, "pixel", "OUTLINE") end
    if button.HotKey then pcall(Widget.SetFont, Widget, button.HotKey, 11, "pixel", "OUTLINE") end
    if button.Name and button.Name.SetFont then
        pcall(Widget.SetFont, Widget, button.Name, 10, "pixel", "OUTLINE")
    end
end

-- -- Ability state ------------------------------------------------------------

local TINT = {
    normal   = { 1.00, 1.00, 1.00 },
    lacking  = { 0.35, 0.35, 0.95 },  -- not enough resource
    outRange = { 0.55, 0.25, 0.25 },  -- out of range
}

local function IsUsable(slot)
    local api = _G.C_ActionBar
    if api and api.IsUsableAction then
        return api.IsUsableAction(slot)
    end
    return nil
end

local function InRange(slot)
    local api = _G.C_ActionBar
    if api and api.IsActionInRange then
        return api.IsActionInRange(slot)
    end
    return nil
end

local function UpdateState(button)
    local slot = button.action
    local icon = button.icon
    if not slot or not icon then return end

    local usable, lacking = IsUsable(slot)
    local inRange = InRange(slot)

    usable  = Secrets.Bool(usable, true)
    lacking = Secrets.Bool(lacking, false)
    inRange = Secrets.Bool(inRange, true)

    local tint = TINT.normal
    if not inRange then
        tint = TINT.outRange
    elseif not usable and lacking then
        tint = TINT.lacking
    end

    icon:SetVertexColor(tint[1], tint[2], tint[3])
end

-- -- Update -------------------------------------------------------------------

local function RefreshAll()
    for i = 1, #buttons do
        StyleButton(buttons[i])
        UpdateState(buttons[i])
    end
end

function M:CollectButtons()
    buttons = {}
    for _, group in ipairs(ACTION_BUTTON_GROUPS) do
        for index = 1, group.count do
            local button = _G[group.prefix .. index]
            if button then
                buttons[#buttons + 1] = button
                StyleButton(button)
            end
        end
    end
end

function M:Initialize()
    self:CollectButtons()

    EventBus:Register("ACTIONBAR_UPDATE_COOLDOWN", RefreshAll)
    EventBus:Register("ACTIONBAR_UPDATE_USABLE", RefreshAll)
    EventBus:Register("ACTIONBAR_SLOT_CHANGED", RefreshAll)
    EventBus:Register("UPDATE_BINDINGS", RefreshAll)
    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        self:CollectButtons()
        RefreshAll()
    end)
    EventBus:Register("MONETUI_THEME_CHANGED", RefreshAll)

    RefreshAll()
end

function M:SetEnabled(enabled)
    if enabled then
        self:CollectButtons()
        RefreshAll()
    else
        -- restore the icons
        local normal = TINT.normal
        for i = 1, #buttons do
            local icon = buttons[i].icon
            if icon then icon:SetVertexColor(normal[1], normal[2], normal[3]) end
        end
    end
end

ns:Register("Cooldown", M)
