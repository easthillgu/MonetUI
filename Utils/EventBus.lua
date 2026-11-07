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

-- 复用同一张 scratch 表，避免每次 Dispatch 都给快照新建表（UNIT_AURA / UNIT_POWER_UPDATE
-- 等高频事件每派发一次就稳定分配 1~2 张表，是持续的 GC 压力）。dispatchDepth 防重入：
-- 若回调里又触发了别的事件（重入 Dispatch），内层走"每次新建"分支，绝不污染外层正在用的 buffer。
local dispatchScratch = {}
local dispatchDepth = 0

-- Report a handler failure, but only the FIRST time per event.  Without this a handler that throws on
-- a high-frequency event (UPDATE_*, PLAYER_ENTERING_WORLD, ...) prints the same line on every single
-- fire, which floods the chat log -- exactly what the project rule "失败一次性 print 警告，不刷屏" forbids.
-- The count is kept (1) so the player learns at the SECOND failure that the noise is being suppressed
-- instead of thinking the error stopped, and (2) for a future `/mui` diagnostic to read.
local reported = {}

--- 每个事件被静默掉的失败次数（诊断用；不要在热路径里调用）。
function EventBus:FailureCounts()
    local copy = {}
    for event, n in pairs(reported) do copy[event] = n end
    return copy
end

local function Report(event, err)
    local key = tostring(event)
    local n = (reported[key] or 0) + 1
    reported[key] = n
    -- First failure prints in full; after that stay silent.  A handler that throws on a
    -- high-frequency event would otherwise print once per fire and flood the chat log.
    if n == 1 then
        print("|cffff6b6b[MonetUI]|r EventBus '" .. key .. "': " .. tostring(err))
    elseif n == 2 then
        -- 第二条才说"后面的不再打印"：只静默、什么都不提示，会让人以为错误只发生了一次。
        print("|cffff6b6b[MonetUI]|r EventBus '" .. key .. "' 的失败会继续被静默（同一事件只提示一次）")
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
    local list = callbacks[event]
    local plainCount = (list and #list) or 0
    local sets = unitSets[event]
    -- 关键边界（与 RegisterUnit:152 同一条规则，必须对称）：同一事件上只要还有普通
    -- Register 回调，引擎就必须保持「全单位」投递（RegisterEvent），绝不能下推成单位过滤。
    -- RegisterUnitEvent 会顶掉 RegisterEvent 的整事件投递，否则残留的普通回调只在注册过的
    -- 那几个单位上触发（删掉其中一个普通回调触发本函数时就会踩到）。只有「没有任何普通回调、
    -- 仅剩单位监听器」时，才把过滤下推给引擎。
    if sets and plainCount == 0 then
        local units = {}
        for u in pairs(sets) do units[#units + 1] = u end
        if #units > 0 then
            pcall(frame.RegisterUnitEvent, frame, event, unpack(units))
            return
        end
        unitSets[event] = nil
    end
    if plainCount > 0 then
        if not registered[event] then
            registered[event] = true
            pcall(frame.RegisterEvent, frame, event)
        end
        return
    end
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
    --
    -- **但同一事件上已经有普通 Register 回调时不能设单位过滤**：RegisterUnitEvent 会顶掉
    -- RegisterEvent 的整事件投递，普通回调从此只在那几个单位上触发（review 2026-10-29 4.4）。
    -- 这种情况下退成普通注册，单位过滤交给 Dispatch 自己做（它本来就按 entry.unit 比）。
    local plain = callbacks[event]
    if plain and #plain > 0 then
        if not registered[event] then
            registered[event] = true
            pcall(frame.RegisterEvent, frame, event)
        end
        return callback
    end

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

    -- 最后一个回调走了就把引擎注册也退掉：以前非单位事件在这里只清表、不 UnregisterEvent，
    -- 于是那个事件一直往我们身上派发（review 2026-10-29 4.4）。
    ResyncUnitFilter(event)
end

function EventBus:UnregisterAll(event)
    callbacks[event] = nil
    unitListeners[event] = nil
    unitSets[event] = nil
    ResyncUnitFilter(event)
end

function EventBus:Dispatch(event, ...)
    -- **先快照再派发**：回调里调 Unregister 会改列表（table.remove 前移），直接遍历会跳过后面几个回调。
    -- 热路径上复用模块级 dispatchScratch，不再每次新建快照表；重入时退回一次性分配。
    local list = callbacks[event]
    if list and #list > 0 then
        if dispatchDepth == 0 then
            dispatchDepth = dispatchDepth + 1
            local n = #list
            for i = 1, n do dispatchScratch[i] = list[i] end
            for i = 1, n do
                local cb = dispatchScratch[i]
                dispatchScratch[i] = nil
                local ok, err = pcall(cb, event, ...)
                if not ok then Report(event, err) end
            end
            dispatchDepth = dispatchDepth - 1
        else
            local snapshot = {}
            for i = 1, #list do snapshot[i] = list[i] end
            for i = 1, #snapshot do
                local ok, err = pcall(snapshot[i], event, ...)
                if not ok then Report(event, err) end
            end
        end
    end

    local listeners = unitListeners[event]
    if listeners and #listeners > 0 then
        local unit = ...
        if dispatchDepth == 0 then
            dispatchDepth = dispatchDepth + 1
            local n = #listeners
            for i = 1, n do dispatchScratch[i] = listeners[i] end
            for i = 1, n do
                local entry = dispatchScratch[i]
                dispatchScratch[i] = nil
                if entry.unit == unit then
                    local ok, err = pcall(entry.cb, event, ...)
                    if not ok then Report(event, err) end
                end
            end
            dispatchDepth = dispatchDepth - 1
        else
            local snapshot = {}
            for i = 1, #listeners do snapshot[i] = listeners[i] end
            for i = 1, #snapshot do
                local entry = snapshot[i]
                if entry.unit == unit then
                    local ok, err = pcall(entry.cb, event, ...)
                    if not ok then Report(event, err) end
                end
            end
        end
    end
end

--- Fire an internal (non-WoW) event, e.g. "MONETUI_THEME_CHANGED".
function EventBus:Fire(event, ...)
    self:Dispatch(event, ...)
end
