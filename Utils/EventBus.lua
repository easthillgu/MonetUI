-- Utils/EventBus.lua
-- Event bus: decoupled pub/sub between Core and the modules.
--
-- Events are registered *lazily*: the shared frame only listens to the WoW
-- events some module actually asked for.  This matters on the Forever client
-- because registering a restricted / unknown event raises an error, so the bus
-- must never blindly register a fixed list (in particular it never touches
-- COMBAT_LOG_EVENT_UNFILTERED).
--
-- Callbacks always receive the event name first:
--     EventBus:Register("PLAYER_LOGIN", function(event) ... end)

local ADDON_NAME, ns = ...

local EventBus = {}
ns.EventBus = EventBus

local callbacks     = {}   -- event -> ordered list of callbacks
local unitListeners = {}   -- event -> ordered list of { unit = unit, cb = cb }
local unitSets      = {}   -- event -> { unit -> refcount }
local registered    = {}   -- event -> true (plain RegisterEvent already done)
local frame

local function Report(event, err)
    print("|cffff6b6b[MonetUI]|r EventBus '" .. tostring(event) .. "': " .. tostring(err))
end

local function EnsureFrame()
    if frame then return frame end
    frame = CreateFrame("Frame")
    frame:SetScript("OnEvent", function(_, event, ...)
        EventBus:Dispatch(event, ...)
    end)
    return frame
end

local function RemoveFromList(list, value)
    for i = #list, 1, -1 do
        if list[i] == value then
            table.remove(list, i)
        end
    end
end

-- -- Registration -------------------------------------------------------------

--- Subscribe to a WoW (or internal) event.
function EventBus:Register(event, callback)
    if type(event) ~= "string" then return end
    if type(callback) ~= "function" then return end

    local list = callbacks[event]
    if not list then
        list = {}
        callbacks[event] = list
    end
    list[#list + 1] = callback

    if not registered[event] then
        registered[event] = true
        -- Internal events are fired by the addon itself (see Fire): they are
        -- not WoW events, so the shared frame must never be asked to listen
        -- for them -- RegisterEvent would reject the name on every login.
        if not string.find(event, "^MONETUI_") then
            -- The frame must exist *before* pcall evaluates its arguments:
            -- writing pcall(frame.RegisterEvent, EnsureFrame(), event) indexes
            -- the still-nil `frame` outside the pcall, which used to raise at
            -- the first registration and abort the whole boot chain in Core.
            -- An unknown or restricted event must never abort module setup.
            local f = EnsureFrame()
            local ok, err = pcall(f.RegisterEvent, f, event)
            if not ok then Report(event, err) end
        end
    end
    return callback
end

--- Subscribe to a unit event, filtered to one unit token.
function EventBus:RegisterUnit(event, unit, callback)
    if type(event) ~= "string" or type(unit) ~= "string" then return end
    if type(callback) ~= "function" then return end

    EnsureFrame()

    local listeners = unitListeners[event]
    if not listeners then
        listeners = {}
        unitListeners[event] = listeners
    end
    listeners[#listeners + 1] = { unit = unit, cb = callback }

    local sets = unitSets[event]
    if not sets then
        sets = {}
        unitSets[event] = sets
    end
    sets[unit] = (sets[unit] or 0) + 1

    -- Re-register with the full set of units so the engine filters for us.
    local units = {}
    for u in pairs(sets) do
        units[#units + 1] = u
    end
    local ok = pcall(frame.RegisterUnitEvent, frame, event, unpack(units))
    if not ok and not registered[event] then
        registered[event] = true
        pcall(frame.RegisterEvent, frame, event)
    end
    return callback
end

function EventBus:Unregister(event, callback)
    local list = callbacks[event]
    if list then RemoveFromList(list, callback) end

    local listeners = unitListeners[event]
    if listeners then
        for i = #listeners, 1, -1 do
            if listeners[i].cb == callback then
                table.remove(listeners, i)
            end
        end
    end
end

function EventBus:UnregisterAll(event)
    callbacks[event] = nil
    unitListeners[event] = nil
end

-- -- Dispatch -----------------------------------------------------------------

function EventBus:Dispatch(event, ...)
    local list = callbacks[event]
    if list then
        for i = 1, #list do
            local ok, err = pcall(list[i], event, ...)
            if not ok then Report(event, err) end
        end
    end

    local listeners = unitListeners[event]
    if listeners then
        local unit = ...
        for i = 1, #listeners do
            local entry = listeners[i]
            if entry.unit == unit then
                local ok, err = pcall(entry.cb, event, ...)
                if not ok then Report(event, err) end
            end
        end
    end
end

--- Fire an internal (non-WoW) event, e.g. "MONETUI_THEME_CHANGED".
function EventBus:Fire(event, ...)
    self:Dispatch(event, ...)
end
