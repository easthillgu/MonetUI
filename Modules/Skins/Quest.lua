-- Modules/Skins/Quest.lua
-- Questing windows: the quest log (standalone QuestLogFrame on clients that still have one) and the NPC quest / gossip dialog windows.
-- Quest *content* (objective text, reward icons) is deliberately left alone -- only the frame's own chrome is faded, so item buttons keep working.

local ADDON_NAME, ns = ...

local M = ns.Skins

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

        -- The greeting / progress / reward / detail sub-panels each carry their own backdrop art; plate them so the dialog reads as one surface.
        M:Controls({
            "QuestFrameGreetingPanel", "QuestFrameProgressPanel",
            "QuestFrameRewardPanel", "QuestFrameDetailPanel",
        }, function(panel)
            ns.Skin:Strip(panel)
            ns.Skin:Panel(panel)
        end)
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
    M:Scrolls({ "ItemTextScrollFrame" })
end

M:Panel("itemtext", { label = "书籍 / 阅读", group = "任务", apply = SkinItemText,
    frames = {
        "ItemTextFrame", "ItemTextCloseButton",
        "ItemTextNextPageButton", "ItemTextPrevPageButton", "ItemTextScrollFrame",
    } })
