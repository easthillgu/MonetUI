-- Utils/EventBus.lua
-- Event bus: decoupled pub/sub between Core and the modules.
-- Events are registered *lazily*: the shared frame only listens to what a module actually asked for. On the Forever client a restricted / unknown event raises, so the bus never blindly registers a fixed list (and never touches COMBAT_LOG_EVENT_UNFILTERED).
-- Callbacks always receive the event name first.

local ADDON_NAME, ns = ...

local EventBus = {}
ns.EventBus = EventBus

local callbacks     = {}   -- event -> ordered list of callbacks
local unitListeners = {}   -- event -> ordered list of { unit = unit, cb = cb }
local unitSets      = {}   -- event -> { unit -> refcount }
local registered    = {}   -- event -> true (plain RegisterEvent already done)
local frame

-- Report a handler failure, but only the FIRST time per event.  Without this a handler that throws on
-- a high-frequency event (UPDATE_*, PLAYER_ENTERING_WORLD, ...) prints the same line on every single
-- fire, which floods the chat log -- exactly what the project rule "失败一次性 print 警告，不刷屏" forbids.
-- The count is kept so the final message says how many times it was swallowed after the burst.
local reported = {}

local function Report(event, err)
    local key = tostring(event)
    local n = (reported[key] or 0) + 1
    reported[key] = n
    -- First failure prints in full; after that stay silent.  A handler that throws on a
    -- high-frequency event would otherwise print once per fire and flood the chat log.
    if n == 1 then
        print("|cffff6b6b[MonetUI]|r EventBus '" .. key .. "': " .. tostring(err))
    end
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

-- Refcounts shrink on unregister: re-register the filter with the surviving
-- units, and drop the engine registration entirely once nothing listens --
-- otherwise dead units would sit in RegisterUnitEvent's filter forever.
local function ResyncUnitFilter(event)
    local sets = unitSets[event]
    if sets then
        local units = {}
        for u in pairs(sets) do units[#units + 1] = u end
        if #units > 0 then
            pcall(frame.RegisterUnitEvent, frame, event, unpack(units))
            return
        end
        unitSets[event] = nil
    end
    local list = callbacks[event]
    if list and #list > 0 then return end
    local listeners = unitListeners[event]
    if listeners and #listeners > 0 then return end
    unitListeners[event] = nil
    if frame then pcall(frame.UnregisterEvent, frame, event) end
    registered[event] = nil
end

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
        -- Internal MONETUI_* events are fired by Fire(): the shared frame must never RegisterEvent them.
        if not string.find(event, "^MONETUI_") then
            -- The frame must exist *before* pcall evaluates its arguments: writing pcall(frame.RegisterEvent, EnsureFrame(), event) indexes the still-nil `frame` outside the pcall. An unknown or restricted event must never abort module setup.
            local f = EnsureFrame()
            -- 零售服删掉/改名了的事件（例如 WORLD_MAP_UPDATE）不必在登录时往聊天框里报一行：
            -- 先问客户端认不认；没有这个 API 的客户端退回原来的 pcall 兜底。
            local known = true
            local valid = _G.C_EventUtils and _G.C_EventUtils.IsEventValid
            if type(valid) == "function" then
                local okValid, isValid = pcall(valid, event)
                if okValid then known = isValid and true or false end
            end
            if known then
                local ok, err = pcall(f.RegisterEvent, f, event)
                if not ok then Report(event, err) end
            end
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
        local changed = false
        for i = #listeners, 1, -1 do
            if listeners[i].cb == callback then
                local unit = listeners[i].unit
                table.remove(listeners, i)
                local sets = unitSets[event]
                local count = sets and sets[unit]
                if count then
                    if count > 1 then sets[unit] = count - 1 else sets[unit] = nil end
                    changed = true
                end
            end
        end
        if changed then ResyncUnitFilter(event) end
    end
end

function EventBus:UnregisterAll(event)
    callbacks[event] = nil
    unitListeners[event] = nil
    unitSets[event] = nil
end

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
