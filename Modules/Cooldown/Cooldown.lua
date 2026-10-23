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
local SLOW_INTERVAL = 0.5   -- cap on the sleep between two text changes
local FAST_INTERVAL = 0.05   -- last half second: keep it smooth

-- Text follows the button size: 12px at the default
-- 28px button, hidden entirely below half of that.
local REF_ICON      = 28
local MIN_SCALE     = 0.5

-- FormattedTimer palette: seconds red/yellow, minutes blue,
-- hours green, days grey; the unit suffix is dimmed.
local CD_COLOR = {
    seconds = "|cfffd3612",   -- red when < 10s, yellow otherwise (see ColorCountdown)
    minutes = "|cff21c8de",   -- blue
    hours   = "|cff4fcd35",   -- green
    days    = "|cffbebfb3",   -- grey
}
local CD_YELLOW = "|cffffe700"
local CD_SUFFIX = "|cffa28d7b"
local CD_RESET  = "|r"

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
    -- TenthTH / MmssTH: below tenthsTH show 0.1s; at/above mmssTH use mm:ss.
    local tenthsTH = tonumber(saved.tenthsTH)
        or tonumber(defaults.tenthsTH) or 10
    local mmssTH = tonumber(saved.mmssTH)
        or tonumber(defaults.mmssTH) or 60

    return scale ~= false, alert ~= false, alertSeconds, tenthsTH, mmssTH
end

local function SetNumbers(cd, hidden)
    selfWrite = true
    pcall(cd.SetHideCountdownNumbers, cd, hidden and true or false)
    selfWrite = false
end

--- FormattedTimer colours: seconds red (<10s) or yellow, minutes
--- blue, hours green, days grey, with the unit suffix dimmed.
local function ColorCountdown(value, suffix, bucket)
    if not value or value == "" then return "" end
    local color
    if bucket == "seconds" then
        local n = tonumber(value)
        color = (n and n < 10) and CD_COLOR.seconds or CD_YELLOW
    else
        color = CD_COLOR[bucket] or ""
    end
    local text = color .. value .. CD_RESET
    if suffix and suffix ~= "" then
        text = text .. CD_SUFFIX .. suffix .. CD_RESET
    end
    return text
end

--- Recompute the font size from the cooldown's own size (it is anchored to the
--- button, so this follows the action bar's buttonSize).  Below MIN_SCALE the
--- text is hidden entirely (minScale = 0.5).
local function UpdateScale(cd, state)
    local w, h = 0, 0
    if cd.GetWidth then
        local ok, v = pcall(cd.GetWidth, cd)
        if ok and type(v) == "number" then w = v end
    end
    if cd.GetHeight then
        local ok, v = pcall(cd.GetHeight, cd)
        if ok and type(v) == "number" then h = v end
    end

    local avg = (w + h) / 2
    local scale = avg > 0 and (avg / REF_ICON) or 1
    state.scale = scale
    state.hiddenBySize = scale < MIN_SCALE
    state.fontPx = Media:SnapSize((state.size or BASE_SIZE) * scale)
    return scale
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
    pcall(fs.SetFont, fs, Media:Font("cooldown"),
        state.fontPx or Media:SnapSize(state.size), Media.fontFlags)
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

    local base = state.fontPx or Media:SnapSize(state.size)
    if tight then
        local size = base * ALERT_RATIO
        local width = cd:GetWidth()
        if width and width > 0 then
            -- Small bars would rather keep the readable size than overflow.
            size = math.min(size, math.max(base, math.floor(width * ALERT_WIDTH)))
        end
        pcall(fs.SetFont, fs, Media:Font("cooldown"), size, Media.fontFlags)
        local r, g, b = Color:GetDanger()
        fs:SetTextColor(r, g, b, 1)
    else
        pcall(fs.SetFont, fs, Media:Font("cooldown"), base, Media.fontFlags)
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

    local scale, alert, alertSeconds, tenthsTH, mmssTH = Options()
    if not scale or not ns:IsModuleEnabled("Cooldown") then
        HandBack(cd, state)
        state.next = POLL_INTERVAL
        return
    end

    -- Too small to read (minScale): keep the text hidden until the
    -- button grows again.  We still own the frame so HandBack can restore it.
    if state.hiddenBySize then
        state.own = true
        if state.text then
            state.text:SetText("")
            state.text:Hide()
        end
        state.shownText = nil
        state.look = nil
        SetNumbers(cd, true)
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

    if not state.own then
        TakeOver(cd, state)
    else
        -- Coming back from hiddenBySize: the frame is already ours, so just
        -- re-show the text (TakeOver would return early).
        local fs = EnsureText(cd, state)
        if not fs:IsShown() then
            state.look = nil
            fs:Show()
        end
    end

    -- Outside code may have re-enabled Blizzard's numbers (every action bar update does); take the display back rather than trusting one write.
    local ok, hidden = pcall(cd.GetHideCountdownNumbers, cd)
    if ok and not hidden then SetNumbers(cd, true) end

    local tight = alert and remain < 60
        and math.floor(remain + 0.5) <= alertSeconds
    ApplyLook(cd, state, tight and true or false)

    -- Math:Countdown also returns when the text next changes, so we do not wake
    -- up on a fixed cadence any more.  The
    -- 0.5s cap keeps the per-tick re-hide check and the alert colour responsive.
    local value, suffix, nextUpdate, bucket
    if remain >= 0.5 then
        -- compact 帧（buff 图标）关掉 mm:ss 开关，走 "59m" 这种短格式。
        value, suffix, nextUpdate, bucket = Math:Countdown(remain, tenthsTH, state.compact and 0 or mmssTH)
    else
        value, suffix, bucket = "", "", nil
        nextUpdate = FAST_INTERVAL
    end
    local text = ColorCountdown(value, suffix, bucket)
    if state.shownText ~= text then
        state.text:SetText(text)
        state.shownText = text
    end

    if not nextUpdate or nextUpdate > SLOW_INTERVAL then nextUpdate = SLOW_INTERVAL end
    if nextUpdate < 0.02 then nextUpdate = 0.02 end
    state.next = nextUpdate
end

local function OnCooldownStart(cd, start, duration, modRate)
    local state = cd and attached[cd]
    if not state then return end

    local plainStart = Secrets.Number(start)
    local plainDuration = Secrets.Number(duration)
    local plainModRate = Secrets.Number(modRate) or 1
    if plainModRate <= 0 then plainModRate = 1 end

    if plainStart and plainDuration and plainDuration > 0 then
        -- modRate > 1 recovers faster, so the wall-clock duration is duration / modRate
        -- (Andromeda's TimerOnUpdate uses the same division).
        state.expiry = plainStart + plainDuration / plainModRate
    else
        -- A secret or empty start: Blizzard's own numbers show until we can read one again.
        state.expiry = nil
        HandBack(cd, state)
    end
    state.next = 0

    -- Charge-based abilities: when the main cooldown starts, stop a separate
    -- charge timer on the same button so two numbers never run at once
    -- (Andromeda's parent.chargeCooldown reconciliation).  If that frame is
    -- ours, hand it back to Blizzard, which keeps its own numbers hidden.
    local parent = cd.GetParent and cd:GetParent()
    local charge = parent and parent.chargeCooldown
    if charge and charge ~= cd then
        local chargeState = attached[charge]
        if chargeState then
            chargeState.expiry = nil
            chargeState.shownText = nil
            chargeState.next = 0
            HandBack(charge, chargeState)
        end
    end
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
-- compact = true：不用 mm:ss 那种宽格式（"1:05"），退回紧凑的 "59m"/"23h"/"3d"。
-- 小格子（buff 图标 28px）放不下 5 个字符，颜色 / 放大 / 缩放逻辑完全一样。
function M:Attach(cd, size, compact)
    if not cd then return nil end
    size = tonumber(size) or BASE_SIZE
    compact = compact and true or false

    local state = attached[cd]
    if state then
        state.size = size
        state.compact = compact
        UpdateScale(cd, state)        -- the bar may have been resized
        state.look = nil              -- force the font/colour to be re-applied
        state.next = 0                -- render on the next frame
        return state
    end

    state = {
        size         = size,
        compact      = compact,
        externalHide = false,         -- what outside code last asked for
        own          = false,
        next         = 0,
        accum        = 0,
    }
    UpdateScale(cd, state)
    attached[cd] = state

    -- Blizzard's own numbers stay styled for the fallback path.
    Widget:StyleCooldownText(cd, Media:SnapSize(size), "cooldown")

    -- Follow a live resize of the action bar (buttonSize setting).
    if cd.HookScript then
        cd:HookScript("OnSizeChanged", function(self)
            local st = attached[self]
            if not st then return end
            UpdateScale(self, st)
            st.look = nil
            st.next = 0
        end)
    end

    EnsureHooks()
    cd:SetScript("OnUpdate", Tick)
    return state
end

--- Style hook used everywhere a cooldown frame is dressed (this module and the action bars): keeps Blizzard's numbers on until the text can be ours.
function M:StyleCooldown(cd, size, compact)
    local state = self:Attach(cd, size, compact)
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
            UpdateScale(cd, state)   -- buttonSize may have changed
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
