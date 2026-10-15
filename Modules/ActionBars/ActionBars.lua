-- Modules/ActionBars/ActionBars.lua
-- Placeholder for MonetUI's own action bars: it takes Blizzard's default action
-- bars and bag bar off screen, the way Andromeda does.
--
-- The frames are re-parented to a hidden frame rather than destroyed or have
-- their scripts stripped, so every button keeps working for its keybind and the
-- client's action-bar bookkeeping is left alone (only the drawing disappears).
-- Hiding protected frames is not allowed in combat, so this runs at login and
-- on PLAYER_REGEN_ENABLED only.

local ADDON_NAME, ns = ...

local EventBus = ns.EventBus

local M = { name = "ActionBars" }

-- Bars that follow the current action page.
local ACTION_BAR_FRAMES = {
    "MainMenuBar", "MultiBarBottomLeft", "MultiBarBottomRight",
    "MultiBarLeft", "MultiBarRight", "MultiBar5", "MultiBar6", "MultiBar7",
    "OverrideActionBar", "PossessActionBar", "PetActionBar",
    "StanceBar",
}

-- Bag bar / micro menu cluster at the bottom-right.
local BAG_BAR_FRAMES = {
    "BagsBar", "MainMenuBarBackpackButton",
}

local hidden, applied = nil, false

local function HiddenFrame()
    if not hidden then
        hidden = CreateFrame("Frame", "MonetUIHiddenFrame", UIParent)
        hidden:Hide()
    end
    return hidden
end

local function Park(name, parent)
    local frame = _G[name]
    if not frame or frame.__monetParked then return false end
    if not pcall(frame.SetParent, frame, parent) then return false end
    frame.__monetParked = true
    return true
end

local function Restore(name)
    local frame = _G[name]
    if not frame or not frame.__monetParked then return false end
    frame.__monetParked = nil
    -- Blizzard re-anchors its bars itself once they are back on UIParent.
    pcall(frame.SetParent, frame, UIParent)
    pcall(frame.Show, frame)
    return true
end

--- Hide the requested Blizzard chrome.  No-op while the player is in combat.
function M:Apply()
    if InCombatLockdown and InCombatLockdown() then
        applied = false
        return
    end

    local db = ns:DB().actionBars or {}
    local box = HiddenFrame()

    for _, name in ipairs(ACTION_BAR_FRAMES) do
        if db.hideBlizzard ~= false then Park(name, box) else Restore(name) end
    end

    for _, name in ipairs(BAG_BAR_FRAMES) do
        if db.hideBagBar ~= false then Park(name, box) else Restore(name) end
    end

    applied = true
end

function M:RegisterEvents()
    -- Retry after combat: the first attempt may have landed in a lockdown.
    EventBus:Register("PLAYER_REGEN_ENABLED", function()
        if not applied then M:Apply() end
    end)
end

function M:Initialize()
    self:Apply()
    self:RegisterEvents()
end

function M:SetEnabled(enabled)
    if enabled then
        self:Apply()
    else
        for _, name in ipairs(ACTION_BAR_FRAMES) do Restore(name) end
        for _, name in ipairs(BAG_BAR_FRAMES) do Restore(name) end
    end
end

ns:Register("ActionBars", M)
