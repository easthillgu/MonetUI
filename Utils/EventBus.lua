-- Utils/EventBus.lua
-- Event bus: decoupled communication between modules (replaces CallbackHandler)

local ADDON_NAME = ...

local EventBus = {}

-- Private state
local callbacks = {}      -- event -> { [callback] = true }
local eventFrame = nil

-- ============================================================================
-- Event Frame Setup
-- ============================================================================

local WoWEvents = {
    "UNIT_HEALTH",
    "UNIT_MAXHEALTH",
    "UNIT_POWER_UPDATE",
    "UNIT_AURA",
    "ACTIONBAR_UPDATE_COOLDOWN",
    "BAG_UPDATE",
    "QUEST_LOG_UPDATE",
    "ZONE_CHANGED",
    "ZONE_CHANGED_INDOORS",
    "ZONE_CHANGED_NEW_AREA",
    "PLAYER_TARGET_CHANGED",
    "PLAYER_FOCUS_CHANGED",
    "PARTY_MEMBERS_CHANGED",
    "RAID_ROSTER_UPDATE",
    "COMBAT_LOG_EVENT_UNFILTERED",
    "SPELL_UPDATE_COOLDOWN",
    "PLAYER_REGEN_ENABLED",
    "PLAYER_REGEN_DISABLED",
}

local function GetEventFrame()
    if eventFrame then return eventFrame end
    eventFrame = CreateFrame("Frame")
    for _, event in ipairs(WoWEvents) do
        eventFrame:RegisterEvent(event)
    end
    eventFrame:SetScript("OnEvent", function(_, event, ...)
        EventBus:Fire(event, ...)
    end)
    return eventFrame
end

-- ============================================================================
-- Public API
-- ============================================================================

function EventBus:Register(event, callback)
    assert(type(event) == "string", "Event name must be a string")
    assert(type(callback) == "function", "Callback must be a function")
    callbacks[event] = callbacks[event] or {}
    callbacks[event][callback] = true
    GetEventFrame()
end

function EventBus:Unregister(event, callback)
    if callbacks[event] then
        callbacks[event][callback] = nil
    end
end

function EventBus:Fire(event, ...)
    if callbacks[event] then
        for callback in pairs(callbacks[event]) do
            local ok, err = pcall(callback, event, ...)
            if not ok then
                print("|cFFFF6B6B[MonetUI EventBus]|r Error in callback: " .. tostring(err))
            end
        end
    end
end

return EventBus
