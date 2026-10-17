-- Modules/Cooldown/Cooldown.lua
-- Action bar cooldowns: our own auto-scaling countdown text over Blizzard's swipe, addon fonts for charges/hotkeys/names, and ability state shown via icon tint.
-- The client keeps cooldown values secret in restricted states, so nothing here does arithmetic on a start/duration pair before Secrets.Number approves it.

local ADDON_NAME, ns = ...

local Widget = ns.Widget
local Secrets = ns.Secrets
local EventBus = ns.EventBus
local Media = ns.Media
local Color = ns.Color
local Math = ns.Math

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

-- Blizzard owns the swipe and cannot be re-formatted, so we draw our own font string over it -- but only while the numbers are readable.
-- Two clocks: a SetCooldown hook captures expiry at start (secret pairs fall back to Blizzard's numbers); a light poll re-adopts running cooldowns and picks the display back up when a restriction lifts.

local BASE_SIZE     = 12    -- pixel grid step, see Media:SnapSize
local ALERT_RATIO   = 1.5   -- tight cooldowns render 12 -> 18
local ALERT_WIDTH   = 0.6   -- ... but never wider than 60% of the cooldown
local POLL_INTERVAL = 0.5   -- unreadable-state probe (adoption / restriction)
local SLOW_INTERVAL = 0.5   -- normal refresh cadence
local FAST_INTERVAL = 0.05   -- last second: keep it smooth

-- cd frame -> state.  Weak keys, so destroyed frames drop out on their own.
local attached = setmetatable({}, { __mode = "k" })

-- True only inside our own SetHideCountdownNumbers writes, so the hook records what *outside* code asked for, never our own override.
local selfWrite = false

local function Options()
    local db = ns:DB()
    local saved = type(db.cooldown) == "table" and db.cooldown or {}
    local defaults = ns.DEFAULTS.cooldown or {}

    local scale = saved.scale
    if scale == nil then scale = defaults.scale end
    local alert = saved.alert
    if alert == nil then alert = defaults.alert end
    local alertSeconds = tonumber(saved.alertSeconds)
        or tonumber(defaults.alertSeconds) or 5

    return scale ~= false, alert ~= false, alertSeconds
end

local function SetNumbers(cd, hidden)
    selfWrite = true
    pcall(cd.SetHideCountdownNumbers, cd, hidden and true or false)
    selfWrite = false
end

local function EnsureText(cd, state)
    if state.text then return state.text end

    -- A child frame (not a region of the cooldown) so Widget:StyleCooldownText's re-styling pass can never reach this font string.
    local holder = CreateFrame("Frame", nil, cd)
    holder:SetAllPoints()
    holder:SetFrameLevel(cd:GetFrameLevel() + 5)

    local fs = holder:CreateFontString(nil, "OVERLAY")
    fs:SetAllPoints()
    fs:SetJustifyH("CENTER")
    fs:SetJustifyV("MIDDLE")
    pcall(fs.SetFont, fs, Media:Font("cooldown"), Media:SnapSize(state.size), Media.fontFlags)
    fs:SetTextColor(1, 1, 1, 1)
    fs:Hide()

    state.holder = holder
    state.text = fs
    return fs
end

--- We render the countdown ourselves: step on Blizzard's numbers.
local function TakeOver(cd, state)
    if state.own then return end
    state.own = true
    state.look = nil
    EnsureText(cd, state):Show()
    SetNumbers(cd, true)
end

--- Hand the display back to Blizzard's countdown numbers; writes nothing when we never took over.
local function HandBack(cd, state)
    if not state.own then return end
    state.own = false
    state.look = nil
    state.shownText = nil
    if state.text then
        state.text:SetText("")
        state.text:Hide()
    end
    SetNumbers(cd, state.externalHide)
end

local function ApplyLook(cd, state, tight)
    if state.look == tight then return end
    state.look = tight

    local fs = state.text
    if not fs then return end

    if tight then
        local size = state.size * ALERT_RATIO
        local width = cd:GetWidth()
        if width and width > 0 then
            -- Small bars would rather keep the readable size than overflow.
            size = math.min(size, math.max(state.size, math.floor(width * ALERT_WIDTH)))
        end
        pcall(fs.SetFont, fs, Media:Font("cooldown"), size, Media.fontFlags)
        local r, g, b = Color:GetDanger()
        fs:SetTextColor(r, g, b, 1)
    else
        pcall(fs.SetFont, fs, Media:Font("cooldown"), Media:SnapSize(state.size), Media.fontFlags)
        fs:SetTextColor(1, 1, 1, 1)
    end
end

local function Tick(cd, elapsed)
    local state = attached[cd]
    if not state then
        cd:SetScript("OnUpdate", nil)
        return
    end

    state.accum = (state.accum or 0) + elapsed
    if state.accum < (state.next or 0) then return end
    state.accum = 0

    local scale, alert, alertSeconds = Options()
    if not scale or not ns:IsModuleEnabled("Cooldown") then
        HandBack(cd, state)
        state.next = POLL_INTERVAL
        return
    end

    local expiry = state.expiry
    if not expiry then
        -- Nothing readable yet: stand aside, then look for a readable start (already running when we attached, or a restriction that just lifted).
        HandBack(cd, state)
        local ok, start, duration = pcall(cd.GetCooldownTimes, cd)
        if ok then
            start = Secrets.Number(start)
            duration = Secrets.Number(duration)
            if start and duration and duration > 0 then
                state.expiry = start + duration
                state.next = 0
                return
            end
        end
        state.next = POLL_INTERVAL
        return
    end

    local remain = expiry - GetTime()
    if remain <= 0 then
        state.expiry = nil
        HandBack(cd, state)
        state.next = POLL_INTERVAL
        return
    end

    TakeOver(cd, state)

    -- Outside code may have re-enabled Blizzard's numbers (every action bar update does); take the display back rather than trusting one write.
    local ok, hidden = pcall(cd.GetHideCountdownNumbers, cd)
    if ok and not hidden then SetNumbers(cd, true) end

    local tight = alert and remain < 60
        and math.floor(remain + 0.5) <= alertSeconds
    ApplyLook(cd, state, tight and true or false)

    local text = remain >= 0.5 and Math:DurationText(remain) or ""
    if state.shownText ~= text then
        state.text:SetText(text)
        state.shownText = text
    end

    state.next = remain >= 1 and SLOW_INTERVAL or FAST_INTERVAL
end

local function OnCooldownStart(cd, start, duration)
    local state = cd and attached[cd]
    if not state then return end

    local plainStart = Secrets.Number(start)
    local plainDuration = Secrets.Number(duration)
    if plainStart and plainDuration and plainDuration > 0 then
        state.expiry = plainStart + plainDuration
    else
        -- A secret or empty start: Blizzard's own numbers show until we can read one again.
        state.expiry = nil
        HandBack(cd, state)
    end
    state.next = 0
end

local function OnSetHideCountdownNumbers(cd, hidden)
    if selfWrite then return end
    local state = cd and attached[cd]
    if not state then return end

    state.externalHide = hidden and true or false
    if state.own then state.next = 0 end  -- re-assert on the next pass
end

local hooksDone = false
local function EnsureHooks()
    if hooksDone then return end
    hooksDone = true

    -- All cooldown widgets share one metatable, so hooking its methods once covers Blizzard's action buttons and LibActionButton's alike.
    local probe = _G.ActionButton1Cooldown
    if not probe then
        local ok, frame = pcall(CreateFrame, "Cooldown", "MonetUIProbeCooldown")
        if ok then probe = frame end
    end

    local meta = probe and getmetatable(probe)
    local methods = meta and meta.__index
    if type(methods) ~= "table" then
        ns:Print("冷却计时：未找到 Cooldown 方法表，自动缩放不会生效。")
        return
    end

    if type(methods.SetCooldown) == "function" then
        pcall(hooksecurefunc, methods, "SetCooldown", OnCooldownStart)
    end
    if type(methods.SetHideCountdownNumbers) == "function" then
        pcall(hooksecurefunc, methods, "SetHideCountdownNumbers", OnSetHideCountdownNumbers)
    end
end

--- Register a cooldown frame with the auto-scaling text renderer.
-- Safe to call repeatedly (theme refresh, size change): it only re-styles and asks for an immediate re-render.
function M:Attach(cd, size)
    if not cd then return nil end
    size = tonumber(size) or BASE_SIZE

    local state = attached[cd]
    if state then
        if state.size ~= size then
            state.size = size
            state.look = nil          -- force the font/colour to be re-applied
        end
        state.next = 0                -- render on the next frame
        return state
    end

    state = {
        size         = size,
        externalHide = false,         -- what outside code last asked for
        own          = false,
        next         = 0,
        accum        = 0,
    }
    attached[cd] = state

    -- Blizzard's own numbers stay styled for the fallback path.
    Widget:StyleCooldownText(cd, size, "cooldown")

    EnsureHooks()
    cd:SetScript("OnUpdate", Tick)
    return state
end

--- Style hook used everywhere a cooldown frame is dressed (this module and the action bars): keeps Blizzard's numbers on until the text can be ours.
function M:StyleCooldown(cd, size)
    local state = self:Attach(cd, size)
    if state and not state.own then
        state.externalHide = false
        SetNumbers(cd, false)
    end
    return state
end

--- Re-render everything after a settings change (config panel).
function M:ApplyDisplay()
    for cd in pairs(attached) do
        local state = attached[cd]
        if state then
            state.look = nil
            state.next = 0
        end
    end
end

local function StyleButton(button)
    if not button or button.__monetStyled then return end
    button.__monetStyled = true

    -- Blizzard already drives the swipe (its start time may be secret), so only re-style the widgets it owns; never create our own.
    local cd = button.Cooldown or button.cooldown
    if cd then
        M:StyleCooldown(cd, BASE_SIZE)
    end

    if button.Count then  pcall(Widget.SetFont, Widget, button.Count, 12, "pixel") end
    if button.HotKey then pcall(Widget.SetFont, Widget, button.HotKey, 12, "pixel") end
    if button.Name and button.Name.SetFont then
        pcall(Widget.SetFont, Widget, button.Name, 12, "pixel")
    end
end

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

    -- Hand every countdown back to Blizzard (or wake our text up) at once instead of waiting for the next tick.
    for cd in pairs(attached) do
        local state = attached[cd]
        if state then
            state.next = 0
            if not enabled then HandBack(cd, state) end
        end
    end
end

ns:Register("Cooldown", M)
