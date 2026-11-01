-- Modules/Cooldown/Cooldown.lua
-- Action bar cooldowns: our own auto-scaling countdown text over Blizzard's swipe, addon fonts for charges/hotkeys/names, and ability state shown via icon tint.
-- The client keeps cooldown values secret in restricted states, so nothing here does arithmetic on a start/duration pair before Secrets.Number approves it.

local ADDON_NAME, ns = ...


-- 旁表标记（见 Core.lua 的 ns:Mark）：不往暴雪的框体上写字段，
-- 否则那个框体之后跑的暴雪代码会被判成“被 MonetUI 污染”。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
local Widget = ns.Widget
local Secrets = ns.Secrets
local EventBus = ns.EventBus
local Media = ns.Media
local Color = ns.Color
local Math = ns.Math

local M = { name = "Cooldown" }

local buttons = {}

-- **只处理我们自己的按钮。** 暴雪那 8 条动作条是隐藏的（alpha 0），给它们的按钮/冷却框
-- 做任何事都看不见，却会带来污染：StyleCooldownText / SetHideCountdownNumbers /
-- 改写 OnUpdate 全都落在**暴雪的**冷却框上（taint.log 里宠物条成片的
-- PetActionButton*:SetShown 就是在我们碰过冷却框之后被拒的）。
-- 我们自己的按钮在 ActionBars 里通过 cooldowns:StyleCooldown(cd, ...) 注册，不依赖这张表。
local ACTION_BUTTON_GROUPS = {}
for i = 1, 8 do
    ACTION_BUTTON_GROUPS[#ACTION_BUTTON_GROUPS + 1] = { prefix = "MonetUIBar" .. i .. "Button", count = 12 }
end

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
    -- 像素字体（super-effective）必须落在 12px 网格上；PingFangPixel 这类矢量字体不吸附，
    -- 否则 8-10px 的光环时长会被顶到 10 或 12 而撑出格子。
    local raw = (state.size or BASE_SIZE) * scale
    state.fontPx = (state.font == "cooldown") and Media:SnapSize(raw) or math.max(8, math.floor(raw + 0.5))
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
    local px = state.fontPx or Media:SnapSize(state.size)
    pcall(fs.SetFont, fs, Media:FontFor(state.font or "cooldown", px),
        px, Media:EffectiveFlags(state.flags, px))
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
    SetNumbers(cd, false)
end

local function ApplyLook(cd, state, tight)
    if state.look == tight then return end
    state.look = tight

    local fs = state.text
    if not fs then return end

    local base = state.fontPx or Media:SnapSize(state.size)
    local size = base
    if tight then
        size = base * ALERT_RATIO
        local width = cd:GetWidth()
        if width and width > 0 then
            -- Small bars would rather keep the readable size than overflow.
            size = math.min(size, math.max(base, math.floor(width * ALERT_WIDTH)))
        end
        pcall(fs.SetFont, fs, Media:FontFor(state.font or "cooldown", size), size, Media:EffectiveFlags(state.flags, size))
        local r, g, b = Color:GetDanger()
        fs:SetTextColor(r, g, b, 1)
    else
        pcall(fs.SetFont, fs, Media:FontFor(state.font or "cooldown", base), base, Media:EffectiveFlags(state.flags, base))
        fs:SetTextColor(1, 1, 1, 1)
    end
    -- 记下这一档"理想字号"：FitCooldownText 每次都从这里重新回缩，
    -- 否则上一次为长串缩小的字号会一直留着（文字变短也不会长回来）。
    state.appliedPx = size
end

--- 把时长文字缩进冷却框宽度以内 —— **每个 icon 各算各的**。
---
--- 为什么要它（玩家 2026-11-01 报"左上角 buff 时间显示不完整"）：字号只按按钮尺寸算
--- 一个值，而文字长度是会变的（"9S" → "6:56" → "1H37M"）。实测 28px 的 buff 图标上
--- 12 号字光 "6:56" 就占 25px，两侧只剩 1.5px；再长一点就撑出格子，被相邻图标盖住。
---
--- 做法：从 `state.appliedPx`（ApplyLook 那一档）重新设一遍，再按**实际渲染宽度**逐档缩，
--- 最低 MIN_TEXT_PX。宽度读不出来（机密值）就保持原样 —— 宁可长一点，不要瞎猜。
--- 只在文字或外观变化时调用（见 Tick），不是每拍都跑。
local MIN_TEXT_PX = 6

local function FitCooldownText(cd, state)
    local fs = state.text
    if not fs or not state.own then return end

    local okW, w = pcall(cd.GetWidth, cd)
    local maxWidth = okW and Secrets.Number(w) or nil
    if not maxWidth or maxWidth <= 0 then return end
    -- 上限取 72%（和光环那边同一口径）：贴满整个宽度在视觉上就已经"要溢出了"。
    maxWidth = maxWidth * 0.72

    local size = state.appliedPx or state.fontPx
    if type(size) ~= "number" then return end

    -- 先回到理想字号（上一次可能为长串缩过）
    pcall(fs.SetFont, fs, Media:FontFor(state.font or "cooldown", size), size,
        Media:EffectiveFlags(state.flags, size))

    local guard = 0
    while size > MIN_TEXT_PX and guard < 32 do
        local okS, width = pcall(fs.GetStringWidth, fs)
        local plain = okS and Secrets.Number(width) or nil
        if not plain then return end               -- 机密 / 读不到：不动它
        if plain <= maxWidth then return end
        size = size - 1
        guard = guard + 1
        pcall(fs.SetFont, fs, Media:FontFor(state.font or "cooldown", size), size,
            Media:EffectiveFlags(state.flags, size))
    end
end

local function Tick(cd, elapsed)
    local state = attached[cd]
    if not state then return end

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
            -- **GetCooldownTimes 给的是毫秒**（实机：48680011 / 360000），而 GetTime() 与
            -- state.expiry 都是秒。以前直接相加 → 剩余算成 568 天，buff 图标上就画出一个
            -- "568d"（还是带颜色码的），看起来就像"时间显示被加密了"。
            if start and duration and duration > 0 then -- TAINT-OK: :239-240 Secrets.Number 守卫,机密→None
                state.expiry = (start + duration) / 1000
                state.next = 0
                return
            end
        end
        state.next = POLL_INTERVAL
        return
    end

    local remain = expiry - GetTime()
    if remain > 86400 * 30 then
        -- 明显不可能是真的（单位换算错 / 拿到的是别的时钟）：宁可不画，也别把"568d"糊在图标上。
        state.expiry = nil
        HandBack(cd, state)
        state.next = POLL_INTERVAL
        return
    end
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
    local lookChanged = state.look ~= (tight and true or false)
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
    local textChanged = state.shownText ~= text
    if textChanged then
        state.text:SetText(text)
        state.shownText = text
    end

    -- 文字或外观变了才重新量一次宽度（每拍都量等于每帧多两次 GetStringWidth）
    if textChanged or lookChanged then
        FitCooldownText(cd, state)
    end

    if not nextUpdate or nextUpdate > SLOW_INTERVAL then nextUpdate = SLOW_INTERVAL end
    if nextUpdate < 0.02 then nextUpdate = 0.02 end
    state.next = nextUpdate
end


--- 所有冷却文字共用一个**我们自己的**驱动帧。
--- 绝不 `cd:SetScript("OnUpdate", Tick)`：那等于改写暴雪冷却框的脚本 —— 写字段本身就是污染，
--- 而且我们的代码会夹在暴雪的更新链里执行，链上后续的安全调用全被拒
--- （实机：PetActionButton*:SetShown / PetActionBar:ClearAllPointsBase，就是这条链）。
local driver
local driverAcc = 0

local function EnsureDriver()
    if driver then return end
    driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(_, elapsed)
        driverAcc = driverAcc + (elapsed or 0)
        if driverAcc < 0.05 then return end
        local dt = driverAcc
        driverAcc = 0
        for cd, state in pairs(attached) do
            if state then Tick(cd, dt) end
        end
    end)
end

--- 外部（ActionBars 的 PaintCooldown）拿到明文 start/duration 时告诉我们，
--- 用来给自动缩放的倒计时文字提供"到期时间"。拿不到明文就不用调（机密值不能算）。
function M:NoteStart(cd, start, duration)
    local state = cd and attached[cd]
    if not state then return end
    start, duration = Secrets.Number(start), Secrets.Number(duration)
    if type(start) ~= "number" or type(duration) ~= "number" then return end
    state.expiry = start + duration
    state.next = 0
end

--- Register a cooldown frame with the auto-scaling text renderer.
-- Safe to call repeatedly (theme refresh, size change): it only re-styles and asks for an immediate re-render.
-- compact = true：不用 mm:ss 那种宽格式（"1:05"），退回紧凑的 "59m"/"23h"/"3d"。
-- 小格子（buff 图标 28px）放不下 5 个字符，颜色 / 放大 / 缩放逻辑完全一样。
--- @param font "cooldown"（像素，动作条）| "pingfang"（矢量 + 硬描边，光环时长，小字号也看得清）
function M:Attach(cd, size, compact, font)
    if not cd then return nil end
    size = tonumber(size) or BASE_SIZE
    compact = compact and true or false
    -- 允许的矢量键：pingfang（文楷）/ thin（NanoDyongChyangSong 细体，光环时长用）。
    -- 其余一律归到 "cooldown"（Super Effective，像素网格）。
    font = (font == "pingfang" or font == "thin") and font or "cooldown"

    local state = attached[cd]
    if state then
        state.size = size
        state.compact = compact
        state.font = font
        state.flags = (font == "pingfang" or font == "thin") and Media.outlineFlags or Media.fontFlags
        UpdateScale(cd, state)        -- the bar may have been resized
        state.look = nil              -- force the font/colour to be re-applied
        state.next = 0                -- render on the next frame
        return state
    end

    state = {
        size         = size,
        compact      = compact,
        font         = font,
        flags        = (font == "pingfang" or font == "thin") and Media.outlineFlags or Media.fontFlags,
        own          = false,
        next         = 0,
        accum        = 0,
    }
    UpdateScale(cd, state)
    attached[cd] = state

    -- Blizzard's own numbers stay styled for the fallback path.
    -- **这里必须用调用方要的字体键**，不能写死 "cooldown"：受限状态下（冷却时间是机密）
    -- 我们的文字渲染器会 HandBack，屏幕上真正显示的就是这行暴雪数字 ——
    -- 写死的话 buff 那边换成细体后看不出任何变化（实机 2026-11-01 就是这么卡住的）。
    Widget:StyleCooldownText(cd, Media:SnapSize(size), font)

    -- Follow a live resize of the action bar (buttonSize setting). 只挂**我们自己的**冷却框：
    -- 挂到暴雪的冷却框上等于插进它的事件链，一样会污染（见文件头"绝不全局钩脚本槽"的说明）。
    local name = cd.GetName and cd:GetName()
    if cd.HookScript and name and name:find("^MonetUI") then
        cd:HookScript("OnSizeChanged", function(self) -- TAINT-OK: 有 name:find("^MonetUI") 门控，只挂自建冷却框
            local st = attached[self]
            if not st then return end
            UpdateScale(self, st)
            st.look = nil
            st.next = 0
        end)
    end

    EnsureDriver()
    return state
end

--- Style hook used everywhere a cooldown frame is dressed (this module and the action bars): keeps Blizzard's numbers on until the text can be ours.
function M:StyleCooldown(cd, size, compact, font)
    local state = self:Attach(cd, size, compact, font)
    if state and not state.own then
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
    if not button or Marked(button, "styled") then return end
    Mark(button, "styled", true)

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

local function RefreshAll()
    for i = 1, #buttons do
        StyleButton(buttons[i])
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

-- ------------------------------------------------------------------ 暴雪的「冷却管理器」
-- 12.x 的冷却管理器（编辑模式里那一项）会在玩家框附近自己画一排技能图标 + 冷却扫描 ——
-- 实机就是"player 框架下面一堆带冷却的技能图标，查不到来源"。它是 Blizzard_CooldownViewer
-- 这个 **LoD 包**里的独立帧（不是动作按钮、也不是动作条），既不在我们的条上，也不受我们的
-- 冷却接管影响，所以看起来像幽灵。这里把这几块收掉（模块关掉时再放回来）。
--
-- 它们在登录时还不一定存在（LoD），所以：先轮询等包加载（最多 12 秒），
-- 出现后用 ShowWatch 盯着"又被显示"（编辑模式应用布局时会 Show 一次）。
local VIEWER_FRAMES = {
    "EssentialCooldownViewer",   -- 主要技能
    "UtilityCooldownViewer",     -- 功能技能
    "BuffIconCooldownViewer",    -- 图标式增益
    "BuffBarCooldownViewer",     -- 条式增益
}

local function ParkViewer(frame)
    if not frame then return end
    if not Marked(frame, "viewerParked") then return end
    if InCombatLockdown and InCombatLockdown() then return end
    pcall(frame.Hide, frame)
end

function M:HideBlizzardViewer()
    for i = 1, #VIEWER_FRAMES do
        local frame = _G[VIEWER_FRAMES[i]]
        if frame and not Marked(frame, "viewerParked") then
            Mark(frame, "viewerParked", true)
            Widget:ShowWatch(frame, ParkViewer)
            ParkViewer(frame)
        end
    end
end

local function RestoreBlizzardViewer()
    for i = 1, #VIEWER_FRAMES do
        local frame = _G[VIEWER_FRAMES[i]]
        if frame and Marked(frame, "viewerParked") then
            Mark(frame, "viewerParked", nil)
            pcall(frame.Show, frame)
        end
    end
end

function M:Initialize()
    self:CollectButtons()

    self:HideBlizzardViewer()
    local tries = 0
    Widget:PollWatch(_G.UIParent, function()
        tries = tries + 1
        if tries > 60 then return end   -- 12 秒还没出现：这个客户端没有这套东西
        self:HideBlizzardViewer()
    end)

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
        self:HideBlizzardViewer()
        self:CollectButtons()
        RefreshAll()
    else
        RestoreBlizzardViewer()
        -- 图标染色（TINT）已随空转的 UpdateState 一并删除：自建按钮没有 `.action` 字段，
        -- 那条路径从来没生效过，也就没有"还原染色"这回事。
        buttons = {}
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
