-- Modules/Skins/Quest.lua
-- Questing windows: the quest log (standalone QuestLogFrame on clients that still have one) and the NPC quest / gossip dialog windows.
-- Quest *content* (objective text, reward icons) is deliberately left alone -- only the frame's own chrome is faded, so item buttons keep working.

local ADDON_NAME, ns = ...

local M = ns.Skins
local Media = ns.Media
local Widget = ns.Widget
local Skin = ns.Skin

-- 任务对话框斜纹底板：暗色半透明衬底 + monet_stripe_weave + 亮色文字。
-- 替代原来的 Strip + Panel（纯深色底），解决暴雪 FontString 在深底上看不清的问题。
local WEAVE_SIZE = 64
local Mark = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

-- 按当前尺寸重算斜纹 texcoord（两轴同一密度 → 45° 不变形）
local function UpdateWeave(panel)
    local weave = Marked(panel, "questWeave")
    if not weave then return end
    local tex = Media.texture["monet_stripe_weave"]
    if not tex then return end
    weave:SetTexture(tex, "REPEAT", "REPEAT")
    local mult = Media:Mult()
    local w = panel:GetWidth() or 0
    local h = panel:GetHeight() or 0
    if w > 0 and h > 0 and mult > 0 then
        local cols = w / (mult * WEAVE_SIZE)
        local v0 = 1 / WEAVE_SIZE
        local v1 = v0 + h / (mult * WEAVE_SIZE)
        weave:SetTexCoord(0, cols, v0, v1)
    end
end

-- 递归提亮暗色 FontString（暴雪正文 0,0,0 / 深棕，深底上看不清）
local function BrightenTree(f)
    if not f or not f.GetObjectType then return end
    if f:GetObjectType() == "FontString" then
        local ok, r, g, b = pcall(f.GetTextColor, f)
        if ok and r and r < 0.55 and g < 0.55 and b < 0.55 then
            pcall(f.SetTextColor, f, 0.88, 0.86, 0.82, 1)
        end
    end
    if f.GetChildren then
        for _, c in ipairs({ f:GetChildren() }) do BrightenTree(c) end
    end
end

local function WeavePanel(panel, opts)
    if not panel then return end
    opts = opts or {}
    local baseAlpha = opts.baseAlpha or 0.70
    local weaveAlpha = opts.weaveAlpha or 0.30
    local weaveColor = opts.weaveColor or { 0.55, 0.53, 0.50 }

    -- 去掉暴雪原始贴图和边框
    ns.Skin:Strip(panel)

    -- 衬底层：半透明深色，控制底板的整体明度
    local bg = Marked(panel, "questBg")
    if not bg then
        bg = panel:CreateTexture(nil, "BACKGROUND", nil, -2)
        bg:SetAllPoints(panel)
        Mark(panel, "questBg", bg)
    end
    bg:SetColorTexture(0.12, 0.12, 0.14, baseAlpha)

    -- 斜纹层：monet_stripe_weave 铺满，ADD 混合做柔光
    local weave = Marked(panel, "questWeave")
    if not weave then
        weave = panel:CreateTexture(nil, "BACKGROUND", nil, -1)
        weave:SetAllPoints(panel)
        weave:SetBlendMode("ADD")
        Mark(panel, "questWeave", weave)
    end
    weave:SetVertexColor(weaveColor[1], weaveColor[2], weaveColor[3], weaveAlpha)
    UpdateWeave(panel)

    BrightenTree(panel)
end

-- 面板显示时再亮一次（暴雪 quest 数据是 Show 后才塞进去的）
local function HookQuestBrighten(frame)
    M:HookShow(frame, function()
        local panels = {
            _G.QuestFrameGreetingPanel, _G.QuestFrameProgressPanel,
            _G.QuestFrameRewardPanel, _G.QuestFrameDetailPanel,
        }
        for _, panel in ipairs(panels) do
            if panel then
                UpdateWeave(panel)
                BrightenTree(panel)
            end
        end

        -- 全局 FontString 也一起提亮
        local questFonts = {
            "QuestProgressText", "QuestGreetingText", "QuestDetailText",
            "QuestRewardText", "QuestProgressRequiredItemsText",
            "QuestProgressRequiredMoneyText", "QuestProgressCompleteText",
            "QuestProgressShowItemsText", "QuestRewardChoiceRequiredText",
            "QuestRewardTextRequiredText",
        }
        for _, name in ipairs(questFonts) do
            local f = _G[name]
            if f and f.SetTextColor then
                local ok, r, g, b = pcall(f.GetTextColor, f)
                if ok and r and r < 0.55 and g < 0.55 and b < 0.55 then
                    pcall(f.SetTextColor, f, 0.88, 0.86, 0.82, 1)
                end
            end
        end
    end)
end

local QUESTLOG_BUTTONS = {
    "QuestLogFrameAbandonButton", "QuestLogFrameTrackButton", "QuestLogFrameShareButton",
    "QuestLogFrameCancelButton", "QuestLogFramePushQuestButton",
}

local QUESTLOG_TABS = { "QuestLogFrameTab1", "QuestLogFrameTab2" }

local QUESTLOG_SCROLLS = {
    "QuestLogListScrollFrame", "QuestLogDetailScrollFrame", "QuestLogObjectiveScrollFrame",
}

local function SkinQuestLog()
    local log = _G.QuestLogFrame
    if log then
        M:SkinWindow(log, { panel = { bgAlpha = 0.95 } })
        M:Buttons(QUESTLOG_BUTTONS)
        M:Tabs(QUESTLOG_TABS)
        M:Scrolls(QUESTLOG_SCROLLS)
    end

    local detail = _G.QuestLogDetailFrame
    if detail then
        M:SkinWindow(detail, { noTitle = true, panel = { bgAlpha = 0.95 } })
    end

    local popup = _G.QuestLogPopupDetailFrame
    if popup then
        M:SkinWindow(popup, { noTitle = true, panel = { bgAlpha = 0.96 } })
    end
end

local QUESTFRAME_BUTTONS = {
    "QuestFrameAcceptButton", "QuestFrameDeclineButton", "QuestFrameCompleteButton",
    "QuestFrameCompleteQuestButton", "QuestFrameGoodbyeButton", "QuestFramePushQuestButton",
}

local QUESTFRAME_SCROLLS = {
    "QuestProgressScrollFrame", "GossipGreetingScrollFrame", "QuestInfoObjectiveScrollFrame",
}

local function SkinQuestFrame()
    local quest = _G.QuestFrame
    if quest then
        M:SkinWindow(quest, { panel = { bgAlpha = 0.95 } })
        M:Buttons(QUESTFRAME_BUTTONS)
        M:Scrolls(QUESTFRAME_SCROLLS)

        -- 斜纹底板：暗色衬底 + monet_stripe_weave，解决暴雪正文在深底上看不清的问题
        M:Controls({
            "QuestFrameGreetingPanel", "QuestFrameProgressPanel",
            "QuestFrameRewardPanel", "QuestFrameDetailPanel",
        }, function(panel)
            WeavePanel(panel, { baseAlpha = 0.70, weaveAlpha = 0.30 })
        end)

        -- Show 后再亮一次（暴雪 quest 数据是 Show 后才塞的）
        HookQuestBrighten(quest)
    end

    local gossip = _G.GossipFrame
    if gossip then
        M:SkinWindow(gossip, { panel = { bgAlpha = 0.95 } })
        M:Scrolls(QUESTFRAME_SCROLLS)
        M:Controls({ "GossipFrameGreetingGoodbyeButton" }, function(button) ns.Skin:Button(button) end)

        -- Greeting option buttons are created lazily; restyle them on show.
        M:HookShow(gossip, function()
            local panel = gossip.GreetingPanel or _G.GossipFrameGreetingPanel
            if not panel then return end
            for index = 1, 8 do
                local button = _G["GossipGreetingButton" .. index]
                if button then ns.Skin:Button(button) end
            end
        end)
    end
end

-- The quest objective tracker that sits under the minimap.  It has no tabs and no chrome of its own --
-- just a header, a scroll and a list of tracker blocks, so the header font and the scroll carry it.
local function SkinObjectiveTracker()
    local tracker = _G.ObjectiveTrackerFrame
    if not tracker then return end

    -- QuestTracker 模块默认开着，并且把暴雪的追踪框整个隐藏、自己画一份（QuestTracker.lua:305
    -- SuppressBlizzard）。给一个玩家永远看不见的框架换字体/关贴图不只是白做 —— 它会把这个框架
    -- 染成我们的，之后暴雪自己的布局代码里读光环就被拒，实机报过：
    --   GetAuraDataByIndex(): Auras cannot be accessed when secret while tainted by 'MonetUI'
    --   （Blizzard_MawBuffs → ScenarioObjectiveTracker:LayoutContents）
    -- 所以只有玩家关掉 QuestTracker、暴雪追踪框真的在显示时，才需要这层皮肤。
    if ns:IsModuleEnabled("QuestTracker") then return end

    -- Only the header: the blocks below it are content and must stay legible.
    M:Controls({
        "ObjectiveTrackerHeader", "QuestLogObjectiveHeader",
    }, function(header)
        if not header then return end
        local text = header.Text or (type(header.GetName) == "function"
            and header:GetName() and _G[header:GetName() .. "Text"])
        if text then ns.Skin:Font(text, 12, "pixel", nil, "edge") end
    end)

    -- The tracker rows are created lazily and reused, so restyle them on every show.  Header keeps its
    -- own level; we only walk the containers below it.
    M:HookShow(tracker, function()
        M:SkinScrollsIn(tracker)
        ns.Skin:Strip(tracker, { regions = false, backdrops = true })
    end)
end

M:Panel("objectivetracker", {
    label = "目标追踪",
    group = "任务",
    apply = SkinObjectiveTracker,
    frames = {
        "ObjectiveTrackerFrame", "ObjectiveTrackerHeader", "QuestLogObjectiveHeader",
    },
})

M:Panel("questlog", {
    label = "任务日志",
    group = "任务",
    apply = SkinQuestLog,
    frames = {
        "QuestLogFrame", "QuestLogDetailFrame", "QuestLogPopupDetailFrame",
        "QuestLogFrameAbandonButton", "QuestLogFrameTrackButton", "QuestLogFrameShareButton",
        "QuestLogFrameCancelButton", "QuestLogFramePushQuestButton",
        "QuestLogFrameTab1", "QuestLogFrameTab2",
        "QuestLogListScrollFrame", "QuestLogDetailScrollFrame", "QuestLogObjectiveScrollFrame",
    },
})

M:Panel("questframe", {
    label = "任务 / 对话窗口",
    group = "任务",
    apply = SkinQuestFrame,
    frames = {
        "QuestFrame", "GossipFrame", "GossipFrameGreetingPanel",
        "QuestFrameGreetingPanel", "QuestFrameProgressPanel",
        "QuestFrameRewardPanel", "QuestFrameDetailPanel",
        "QuestFrameAcceptButton", "QuestFrameDeclineButton", "QuestFrameCompleteButton",
        "QuestFrameCompleteQuestButton", "QuestFrameGoodbyeButton", "QuestFramePushQuestButton",
        "QuestProgressScrollFrame", "GossipGreetingScrollFrame", "QuestInfoObjectiveScrollFrame",
        "GossipFrameGreetingGoodbyeButton", "GossipGreetingButton1",
    },
})

-- The windows are load-on-demand and rebuilt as quests change; re-apply.
M:OnEvent("QUEST_LOG_UPDATE", function()
    M:Apply(M.byKey.questlog)
    M:Apply(M.byKey.questframe)
end)

-- 书籍 / 信件正文阅读窗：UIPanels_Game 的 [Family] ItemTextFrame 无 game-type 门控，本客户端存在。
local function SkinItemText()
    local frame = _G.ItemTextFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:Buttons({ "ItemTextCloseButton", "ItemTextNextPageButton", "ItemTextPrevPageButton" })
    Skin:PageArrow(_G.ItemTextPrevPageButton, "left")
    Skin:PageArrow(_G.ItemTextNextPageButton, "right")
    M:Scrolls({ "ItemTextScrollFrame" })
end

M:Panel("itemtext", { label = "书籍 / 阅读", group = "任务", apply = SkinItemText,
    frames = {
        "ItemTextFrame", "ItemTextCloseButton",
        "ItemTextNextPageButton", "ItemTextPrevPageButton", "ItemTextScrollFrame",
    } })
