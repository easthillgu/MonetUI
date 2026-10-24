-- Modules/QuestTracker/QuestTracker.lua
-- A self-drawn quest tracker: Blizzard's ObjectiveTrackerFrame is suppressed and a
-- Monet window lists watched quests in our fonts and colours. Data comes from the
-- public C_QuestLog API only (the clamp/fold UI cannot overlay Blizzard's internals).

local ADDON_NAME, ns = ...


-- 旁表标记（见 Core.lua 的 ns:Mark）：不往暴雪的框体上写字段，
-- 否则那个框体之后跑的暴雪代码会被判成“被 MonetUI 污染”。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
local Widget   = ns.Widget
local Color    = ns.Color
local Math     = ns.Math
local EventBus = ns.EventBus
local Media    = ns.Media

local M = { name = "QuestTracker" }

-- The window measures the same as the minimap PANEL (264), not the 256 map canvas, so the two outer
-- frames stack at one width and one right edge.
local WIDTH     = 264
local PAD       = 8
local TEXT_W    = WIDTH - PAD * 2
local HEADER_H  = 18
local LINE_GAP  = 2
local ENTRY_GAP = 8
local FOLD_W    = 16
local MAX_LINES = 3
local BIG       = 999      -- "unlimited" for SetMaxLines (0's meaning varies)

-- Content colours: the difficulty ramp is quest data, not a theme slot.
local GREEN   = { r = 0.35, g = 0.80, b = 0.40 }
local RED     = { r = 0.85, g = 0.35, b = 0.30 }
local ORANGE  = { r = 0.90, g = 0.55, b = 0.25 }
local YELLOW  = { r = 0.85, g = 0.75, b = 0.35 }
local GREY    = { r = 0.55, g = 0.55, b = 0.55 }

local enabled = true       -- Core only calls SetEnabled on runtime toggles
local tracker
local LINE_H  = 12         -- measured line pitch of the pixel font

local titlePool, objPool, foldPool = {}, {}, {}
local entries = {}         -- per-quest records for the current render pass
local renderPending = false

local Render, QueueRender

local function SavePosition()
    if not tracker then return end
    if tracker.StopMovingOrSizing then tracker:StopMovingOrSizing() end
    local point, _, _, x, y = tracker:GetPoint()
    if not point then return end
    local db = ns:DB()
    db.questTracker = db.questTracker or {}
    local qt = db.questTracker
    qt.point = point
    qt.x = Math:Round(x, 0)
    qt.y = Math:Round(y, 0)
end

-- Where the tracker sits until the player drags it: top-right, its right edge on the minimap panel's
-- right edge and its top on the buff container's top, so the HUD's right-hand column shares one edge.
-- Two points rather than one, so a re-scaled or moved minimap drags that edge along while the top
-- stays pinned to the screen.
local AURA_TOP   = 33       -- BuffFrame's AURA_GAP: the buff container's TOP inset from UIParent
local PANEL_EDGE = AURA_TOP - 4   -- the panel is 8 UI units wider than the map canvas, i.e. 4 per side

local function ApplyDefaultPosition()
    tracker:ClearAllPoints()
    local minimap = ns:GetModule("Minimap")
    local panel = minimap and minimap.panel
    if panel then
        tracker:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    else
        -- Minimap module off: the cluster keeps its parked inset, so this lands on the same edge.
        tracker:SetPoint("RIGHT", UIParent, "RIGHT", -PANEL_EDGE, 0)
    end
    tracker:SetPoint("TOP", UIParent, "TOP", 0, -AURA_TOP)
end

local function RestorePosition()
    local stored = ns:DB().questTracker
    if stored and stored.point then
        tracker:ClearAllPoints()
        tracker:SetPoint(stored.point, UIParent, stored.point, stored.x, stored.y)
    else
        ApplyDefaultPosition()
    end
end

local function TitleColor(questID, complete, failed)
    if failed then return RED end
    if complete then return GREEN end
    local ok, qLevel = pcall(C_QuestLog.GetQuestDifficultyLevel, questID)
    local pLevel = (UnitLevel and UnitLevel("player")) or 0
    if not ok or not qLevel or pLevel <= 0 then
        local r, g, b = Color:GetEdge()
        return { r = r, g = g, b = b }
    end
    local d = qLevel - pLevel
    if d >= 5 then return RED end
    if d >= 3 then return ORANGE end
    if d >= -2 then return YELLOW end
    return GREY
end

--- How many wrapped lines a font string currently occupies.
local function RowsOf(fs)
    local h = fs:GetHeight()
    if not h or h <= 0 then return 1 end
    return math.max(1, math.ceil(h / LINE_H - 0.2))
end

local function AcquireFont(pool)
    local fs = table.remove(pool)
    if not fs then
        fs = Widget:Font(tracker, 12, "pingfang", "neutral", "LEFT", nil, Media.outlineFlags)
        fs:SetWordWrap(true)
        fs:SetNonSpaceWrap(true)   -- CJK has no spaces: must wrap mid-"word"
    end
    fs:SetParent(tracker)
    fs:SetWidth(TEXT_W)
    fs:SetMaxLines(BIG)
    fs:Show()
    return fs
end

local function ReleaseFont(pool, fs)
    fs:Hide()
    pool[#pool + 1] = fs
end

local function ToggleFold(questID)
    local db = ns:DB()
    db.questTracker = db.questTracker or {}
    local exp = db.questTracker.expanded
    if not exp then
        exp = {}
        db.questTracker.expanded = exp
    end
    exp[questID] = not exp[questID] or nil
    Render(false)
end

local function AcquireFold(questID, expanded)
    local btn = table.remove(foldPool)
    if not btn then
        btn = CreateFrame("Button", nil, tracker)
        btn:SetSize(13, 13)
        Widget:Theme(btn, { thickness = 1, bgAlpha = 0.7 })
        btn.glyph = Widget:Font(btn, 12, "pingfang", "edge", "CENTER", nil, Media.outlineFlags)
        btn.glyph:SetPoint("CENTER", btn, "CENTER", 0, 0)
        Widget:Highlight(btn, 0.9)
    end
    btn:SetParent(tracker)
    btn:SetScript("OnClick", function() ToggleFold(questID) end)
    btn.glyph:SetText(expanded and "-" or "+")
    btn:Show()
    return btn
end

QueueRender = function()
    if renderPending then return end
    renderPending = true
    C_Timer.After(0, function()
        renderPending = false
        pcall(Render, true)
    end)
end

Render = function(settle)
    if not tracker then return end

    for _, e in ipairs(entries) do
        ReleaseFont(titlePool, e.title)
        for _, fs in ipairs(e.objs) do ReleaseFont(objPool, fs) end
        if e.fold then e.fold:Hide() foldPool[#foldPool + 1] = e.fold end
    end
    entries = {}

    -- watched quests, in log order (headers never carry a watch)
    local list = {}
    local okNum, num = pcall(C_QuestLog.GetNumQuestLogEntries)
    if okNum and num then
        for i = 1, num do
            local ok, info = pcall(C_QuestLog.GetInfo, i)
            if ok and info and not info.isHeader and info.questID
                and C_QuestLog.GetQuestWatchType(info.questID) ~= nil then
                list[#list + 1] = info
            end
        end
    end

    local qt = ns:DB().questTracker
    local expDB = (qt and qt.expanded) or {}
    local y = -HEADER_H

    for i = 1, #list do
        local info = list[i]
        local questID = info.questID

        local okC, complete = pcall(C_QuestLog.IsComplete, questID)
        complete = okC and complete or false
        local okF, failed = pcall(C_QuestLog.IsFailed, questID)
        failed = okF and failed or false

        -- The manual types GetQuestObjectives' return only as a table; field names read defensively.
        local texts = {}
        local okOb, objectives = pcall(C_QuestLog.GetQuestObjectives, questID)
        if okOb and objectives then
            for j = 1, #objectives do
                local o = objectives[j] or {}
                local text = o.text or ""
                if text ~= "" then
                    local have = o.numFulfilled or o.have or 0
                    local need = o.numRequired or o.needed or 0
                    local done = o.isFinished or (need > 0 and have >= need) or false
                    if need > 1 and not done then
                        text = text .. " (" .. tostring(have) .. "/" .. tostring(need) .. ")"
                    end
                    texts[#texts + 1] = { text = text, done = done }
                end
            end
        end

        local entry = { questID = questID, objs = {} }
        entries[#entries + 1] = entry

        entry.title = AcquireFont(titlePool)
        entry.title:SetText(info.title or ("#" .. tostring(questID)))
        local tc = TitleColor(questID, complete, failed)
        entry.title:SetTextColor(tc.r, tc.g, tc.b, 1)

        for j = 1, #texts do
            local fs = AcquireFont(objPool)
            fs:SetText(texts[j].text)
            if texts[j].done or complete then
                fs:SetTextColor(GREEN.r, GREEN.g, GREEN.b, 1)
            else
                local r, g, b = Color:GetNeutral()
                fs:SetTextColor(r, g, b, 1)
            end
            entry.objs[#entry.objs + 1] = fs
        end

        local fullRows = RowsOf(entry.title)
        for j = 1, #entry.objs do
            fullRows = fullRows + RowsOf(entry.objs[j])
        end

        local expanded = not not expDB[questID]
        local showFold = fullRows > MAX_LINES
        local clamped = (not expanded) and showFold
        if showFold then
            entry.title:SetWidth(TEXT_W - FOLD_W)  -- the fold takes the corner
        end

        local titleTop = y
        local budget = clamped and MAX_LINES or BIG
        local function place(fs)
            local r = RowsOf(fs)
            if budget <= 0 then
                fs:Hide()                    -- beyond the fold: hide, don't cut
                return 0
            end
            if r > budget then               -- cuts mid-string at the budget
                fs:SetMaxLines(budget)
                r = budget
                budget = 0
            else
                fs:SetMaxLines(BIG)
                budget = budget - r
            end
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", tracker, "TOPLEFT", PAD, y)
            fs:Show()
            return r
        end

        y = y - place(entry.title) * LINE_H
        for j = 1, #entry.objs do
            y = y - place(entry.objs[j]) * LINE_H - LINE_GAP
        end

        if showFold then
            local btn = AcquireFold(questID, expanded)
            btn:ClearAllPoints()
            btn:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", -PAD, titleTop)
            entry.fold = btn
        end

        y = y - ENTRY_GAP
    end

    tracker:SetHeight(math.max(HEADER_H + PAD, -y + PAD))

    if #entries == 0 then
        tracker:Hide()
    elseif enabled then
        tracker:Show()
    end

    -- Wrapped height is only trustworthy once the layout catches up, so one deferred
    -- re-render follows a measuring pass; the settle pass never queues another.
    if not settle then QueueRender() end
end

local function SuppressBlizzard()
    local bt = _G.ObjectiveTrackerFrame
    if not bt or Marked(bt, "hiddenHook") then return end
    Mark(bt, "hiddenHook", true)
    -- 不再 HookScript("OnShow")（写脚本槽 = 污染，见 AGENTS）；轮询"变显示了"再藏。
    if ns.Widget then
        ns.Widget:ShowWatch(bt, function()
            if enabled then pcall(bt.Hide, bt) end
        end)
    end
    if enabled and bt.IsShown and bt:IsShown() then pcall(bt.Hide, bt) end
end

function M:Skin()
    if tracker then return true end
    if not Widget or not C_QuestLog then return false end

    tracker = Widget:CreateFrame("MonetUIQuestTracker", UIParent, WIDTH, HEADER_H + PAD)
    -- round: the border is the 9-slice edge art, so it stays correct at any height the tracker grows to
    -- (a mask is applied pixel for pixel, so its radius would stretch with the window instead).  The
    -- content is inset by PAD, far inside the 3px corner arc, so nothing else has to change.
    Widget:Theme(tracker, { thickness = 2, bgAlpha = 0.92, round = true })
    tracker:SetMovable(true)
    tracker:SetClampedToScreen(true)

    -- The header row doubles as the drag handle; the title above it is non-mouse.
    local handle = CreateFrame("Button", nil, tracker)
    handle:SetPoint("TOPLEFT", tracker, "TOPLEFT", 0, 0)
    handle:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", 0, 0)
    handle:SetHeight(HEADER_H)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function() tracker:StartMoving() end)
    handle:SetScript("OnDragStop", SavePosition)

    local headText = Widget:Font(tracker, 12, "pingfang", "edge", "LEFT", nil, Media.outlineFlags)
    headText:SetPoint("TOPLEFT", tracker, "TOPLEFT", PAD, -3)
    headText:SetText("任务追踪")

    -- measure the pixel font's real line pitch (the wrap math needs it)
    local probe = Widget:Font(tracker, 12, "pingfang", "neutral", "LEFT", nil, Media.outlineFlags)
    probe:SetText("字")
    local h = probe:GetHeight()
    if h and h > 0 then LINE_H = h end
    probe:Hide()

    SuppressBlizzard()
    RestorePosition()
    Render(false)
    return true
end

function M:Initialize()
    if not self:Skin() then
        EventBus:Register("PLAYER_ENTERING_WORLD", function() M:Skin() end)
    end

    EventBus:Register("QUEST_LOG_UPDATE", QueueRender)
    EventBus:Register("QUEST_WATCH_UPDATE", QueueRender)
    EventBus:Register("QUEST_ACCEPTED", QueueRender)
end

function M:SetEnabled(value)
    enabled = value and true or false

    local bt = _G.ObjectiveTrackerFrame
    if bt then
        if enabled then
            SuppressBlizzard()
        elseif bt.Show and (not bt.IsShown or not bt:IsShown()) then
            pcall(bt.Show, bt)
        end
    end

    if tracker then
        if enabled then QueueRender() else tracker:Hide() end
    end
end

ns:Register("QuestTracker", M)
