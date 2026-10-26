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
local tracker, scrollFrame, content, scrollBar
local LINE_H  = 12         -- measured line pitch of the pixel font
local minH = HEADER_H + PAD   -- 最小化后只剩标题栏
local minimized = false

local titlePool, objPool, foldPool = {}, {}, {}
local entries = {}         -- per-quest records for the current render pass
local renderPending = false

local Render, QueueRender
local SuppressBlizzard          -- 前置声明：Render 每次刷新都要补一刀（定义在下面）

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
        fs = Widget:Font(content or tracker, 12, "pingfang", "neutral", "LEFT", nil, Media.outlineFlags)
        fs:SetWordWrap(true)
        fs:SetNonSpaceWrap(true)   -- CJK has no spaces: must wrap mid-"word"
    end
    fs:SetParent(content or tracker)
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
        btn = CreateFrame("Button", nil, content or tracker)
        btn:SetSize(13, 13)
        Widget:Theme(btn, { thickness = 1, bgAlpha = 0.7 })
        btn.glyph = Widget:Font(btn, 12, "pingfang", "edge", "CENTER", nil, Media.outlineFlags)
        btn.glyph:SetPoint("CENTER", btn, "CENTER", 0, 0)
        Widget:Highlight(btn, 0.9)
    end
    btn:SetParent(content or tracker)
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

    -- 每次刷新都顺手核对一眼暴雪的追踪框（它可能刚被换成新对象 / 又被显示）。
    if SuppressBlizzard then SuppressBlizzard() end

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
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
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
            btn:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, titleTop)
            entry.fold = btn
        end

        y = y - ENTRY_GAP
    end

    -- content 是 ScrollChild，高度 = 全部追踪内容 + 标题栏占位
    local contentH = math.max(HEADER_H + PAD, -y + PAD)
    content:SetHeight(contentH)

    -- tracker 外壳高度：最小化时只留标题栏，否则 min(内容总高, 屏幕一半 - buff 容器)
    local screenH = (_G.UIParent and _G.UIParent.GetHeight and _G.UIParent:GetHeight()) or 1080
    local maxH = screenH / 2 - AURA_TOP
    local trackH
    if minimized then
        trackH = minH
        scrollFrame:Hide()
    else
        trackH = math.min(contentH, maxH)
        if contentH > trackH then
            scrollFrame:Show()
            local range = math.max(0, contentH - trackH)
            scrollBar:SetMinMaxValues(0, range)
            scrollBar:SetValueStep(LINE_H)
            scrollBar:Show()
            scrollBar.ScrollUpButton:Show()
            scrollBar.ScrollDownButton:Show()
        else
            scrollFrame:Hide()
        end
    end
    tracker:SetHeight(trackH)

    if #entries == 0 then
        tracker:Hide()
    elseif enabled then
        tracker:Show()
    end

    -- Wrapped height is only trustworthy once the layout catches up, so one deferred
    -- re-render follows a measuring pass; the settle pass never queues another.
    if not settle then QueueRender() end
end

--- 把暴雪的追踪框"静音"：**不 Hide()，只压 alpha + 关鼠标**。
---
--- 三条实机教训：
---   1. 它在 **LoD 包**（Blizzard_ObjectiveTracker）里，登录瞬间 `_G.ObjectiveTrackerFrame`
---      还不存在；只在 Skin() 里试一次就永远藏不住（症状：自绘的和默认的同时挂着）。
---   2. LoD 包加载时会把它**换成一个新对象** —— 我们藏过的那块已经不是屏幕上那块，
---      所以"藏一次 + ShowWatch"不够（新对象没被登记过）。
---   3. **Hide() 会和暴雪打架**：它一有任务更新就自己 Show 回来，我们 1 秒补一刀，
---      屏幕上就是"一闪一闪、时而可见"。alpha 0 不会触发它的 Show 逻辑（框一直"显示着"），
---      也就不再有拉锯 —— 和收起暴雪动作条用的是同一套（MainActionBar 的结论）。
--- 待机成本为零：alpha 只在第一次登记时写，之后每次调用最多两次 SetAlpha（幂等）。
--- 子树级鼠标静音：Frame 的 EnableMouse **不递归**——本客户端追踪框的点击件是深层
--- 的任务块按钮池（实机探针 2026-10-25：根 mouse=false 但深层 ~17 个无名 Button
--- 各带鼠标，逐目标生成），只关根框照样能点（用户实机："原始的目标追踪的鼠标没
--- 杀掉，还能点击"）。
--- 幂等与恢复：旁表守卫（mutedMouse / muteMousePrior 记**原状态**），恢复时只还回
--- "原本开着鼠标"的那些；新池化的按钮等 1 秒兜底补关。一律旁表，不写暴雪框字段。
local function MuteMouseTree(root, restore)
    if not root or not root.EnableMouse then return end
    -- 战斗中完全跳过（连登记守卫都不落）：追踪器的子按钮可能带 secure 属性，对它
    -- EnableMouse 在战斗里 = ADDON_ACTION_BLOCKED（实机 ×29 一次一阵的形态：新任务块
    -- 涌进池的第一批全拦）。脱战之后 1 秒 ticker 自动补关，不丢功能。
    if not restore and type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() then
        return
    end
    local function apply(f)
        if f.EnableMouse then
            if restore then
                if Marked(f, "mutedMouse") then
                    pcall(f.EnableMouse, f, Marked(f, "muteMousePrior") == true)
                    Mark(f, "mutedMouse", nil)
                    Mark(f, "muteMousePrior", nil)
                end
            else
                if not Marked(f, "mutedMouse") then
                    local _, prior = pcall(f.IsMouseEnabled, f)
                    -- prior == false（本来没开）就只登记守卫不动它，恢复时直接跳过
                    pcall(f.EnableMouse, f, false)
                    Mark(f, "mutedMouse", true)
                    Mark(f, "muteMousePrior", prior == true)
                end
            end
        end
        for _, c in ipairs({ f:GetChildren() }) do apply(c) end
    end
    apply(root)
end

function SuppressBlizzard()
    -- 战斗中一概不动手：不只是子树静音，根框的 SetAlpha/EnableMouse 同样是被拦面
    -- （×29 修后残余的 ×2 低频形态与"个别时机从两个入口穿过子树闸"吻合——根框
    -- 写入每秒都随 ticker 重打，一次性事件路径在战斗里也会进来）。脱战后 ticker 秒级补关。
    if type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() then
        return
    end
    local bt = _G.ObjectiveTrackerFrame
    if not bt then return end

    if not Marked(bt, "muted") then
        Mark(bt, "muted", true)
        local okA, alpha = pcall(bt.GetAlpha, bt)
        if okA then Mark(bt, "alpha", alpha) end
        if bt.IsMouseEnabled then
            local okM, mouse = pcall(bt.IsMouseEnabled, bt)
            if okM then Mark(bt, "mouse", mouse) end
        end
    end

    if not enabled then return end
    pcall(bt.SetAlpha, bt, 0)
    if bt.EnableMouse then pcall(bt.EnableMouse, bt, false) end
    -- 关键：连带子树（任务块按钮池）一起关鼠标；每秒兜底会再跑一遍补新按钮。
    MuteMouseTree(bt, false)
end

--- 模块关掉时把透明度 / 鼠标还回去。
local function UnmuteBlizzard()
    local bt = _G.ObjectiveTrackerFrame
    if not bt or not Marked(bt, "muted") then return end
    pcall(bt.SetAlpha, bt, Marked(bt, "alpha") or 1)
    if bt.EnableMouse then pcall(bt.EnableMouse, bt, Marked(bt, "mouse") ~= false) end
    MuteMouseTree(bt, true)
    Mark(bt, "muted", nil)
end

--- 1 秒一次的低频兜底：上面那些时机都没赶上（或者框被谁重新显示）时补一刀。
local ticker
local function EnsureTicker()
    if ticker then return end
    ticker = CreateFrame("Frame")
    local acc = 0
    ticker:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 1 then return end
        acc = 0
        if enabled then SuppressBlizzard() end
    end)
end

function M:Skin()
    if tracker then return true end
    if not Widget or not C_QuestLog then return false end

    tracker = Widget:CreateFrame("MonetUIQuestTracker", UIParent, WIDTH, HEADER_H + PAD)
    Widget:Theme(tracker, { thickness = 1, bgAlpha = 0.92 })
    tracker:SetMovable(true)
    tracker:SetClampedToScreen(true)

    -- Minimize / Restore glyph button.  Clicking it flips minimized state and triggers a re-render.
    -- 必须先创建，handle 会锚在它左边（handle 不覆盖它的点击区）。
    local toggleBtn = CreateFrame("Button", nil, tracker)
    toggleBtn:SetSize(13, 13)
    Widget:Theme(toggleBtn, { thickness = 1, bgAlpha = 0.7 })
    toggleBtn:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", -PAD, -3)
    local toggleGlyph = Widget:Font(toggleBtn, 12, "pingfang", "edge", "CENTER", nil, Media.outlineFlags)
    toggleGlyph:SetPoint("CENTER", toggleBtn, "CENTER", 0, 0)
    Widget:Highlight(toggleBtn, 0.9)
    toggleBtn:SetScript("OnClick", function()
        local sv = ns:DB(); sv.questTracker = sv.questTracker or {}
        local db = sv.questTracker
        minimized = not minimized
        db.minimized = minimized or nil
        toggleGlyph:SetText(minimized and "+" or "–")
        QueueRender()
    end)
    -- 从 DB 恢复 minimized 状态
    local qtDB = ns:DB().questTracker or {}
    minimized = not not qtDB.minimized
    toggleGlyph:SetText(minimized and "+" or "–")

    -- Lock glyph: clicking toggles movable / locked.  Locked = SetMovable(false), handle 不响应拖动。
    -- 和 toggleBtn 同高度左对齐。
    local lockBtn = CreateFrame("Button", nil, tracker)
    lockBtn:SetSize(13, 13)
    Widget:Theme(lockBtn, { thickness = 1, bgAlpha = 0.7 })
    lockBtn:SetPoint("RIGHT", toggleBtn, "LEFT", -4, 0)
    local lockGlyph = Widget:Font(lockBtn, 12, "pingfang", "edge", "CENTER", nil, Media.outlineFlags)
    lockGlyph:SetPoint("CENTER", lockBtn, "CENTER", 0, 0)
    Widget:Highlight(lockBtn, 0.9)

    -- The header row doubles as the drag handle.  End anchor is lockBtn.LEFT so handle
    -- never covers the two glyph buttons on the right.
    local handle = CreateFrame("Button", nil, tracker)
    handle:SetPoint("TOPLEFT", tracker, "TOPLEFT", 0, 0)
    handle:SetPoint("TOPRIGHT", lockBtn, "LEFT", -4, 0)
    handle:SetHeight(HEADER_H)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function() tracker:StartMoving() end)
    handle:SetScript("OnDragStop", SavePosition)

    local headText = Widget:Font(tracker, 12, "pingfang", "edge", "LEFT", nil, Media.outlineFlags)
    headText:SetPoint("TOPLEFT", tracker, "TOPLEFT", PAD, -3)
    headText:SetText("任务追踪")

    local function ApplyLock()
        if not tracker then return end
        local locked = not not (ns:DB().questTracker or {}).locked
        -- 本客户端没有 UnregisterForDrag —— SetMovable(false) 后 StartMoving 被拒就够了，
        -- 不需要从 handle 上卸 drag 注册。
        tracker:SetMovable(not locked)
        lockGlyph:SetText(locked and "L" or "U")
    end

    lockBtn:SetScript("OnClick", function()
        local sv = ns:DB(); sv.questTracker = sv.questTracker or {}
        local db = sv.questTracker
        db.locked = not db.locked or nil
        ApplyLock()
    end)
    ApplyLock()

    -- ScrollFrame 占满标题栏下方的内容区。
    scrollFrame = CreateFrame("ScrollFrame", nil, tracker, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", tracker, "TOPLEFT", 0, -HEADER_H)
    scrollFrame:SetPoint("BOTTOMRIGHT", tracker, "BOTTOMRIGHT", -20, 0)
    scrollBar = scrollFrame.ScrollBar
    -- 右侧滚动条样式（ns.Skin:ScrollBar 只 Strip + 换 chevron）
    ns.Skin:ScrollBar(scrollBar)

    -- content 是 ScrollChild，所有字体和 foldBtn 的父元素都挂它。
    content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(WIDTH - PAD * 2, HEADER_H + PAD)
    scrollFrame:SetScrollChild(content)

    -- measure the pixel font's real line pitch (the wrap math needs it)
    local probe = Widget:Font(content, 12, "pingfang", "neutral", "LEFT", nil, Media.outlineFlags)
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

    -- 暴雪的追踪框会晚到、还会被换成新对象（见 SuppressBlizzard 的注释），这几个时机都补一次。
    EventBus:Register("PLAYER_ENTERING_WORLD", function() SuppressBlizzard() end)
    EventBus:Register("ZONE_CHANGED_NEW_AREA", function() SuppressBlizzard() end)
    EventBus:Register("ADDON_LOADED", function(_, name)
        if name == "Blizzard_ObjectiveTracker" then SuppressBlizzard() end
    end)
    EnsureTicker()
end

function M:SetEnabled(value)
    enabled = value and true or false

    if enabled then
        SuppressBlizzard()
    else
        UnmuteBlizzard()
    end

    if tracker then
        if enabled then QueueRender() else tracker:Hide() end
    end
end

ns:Register("QuestTracker", M)
