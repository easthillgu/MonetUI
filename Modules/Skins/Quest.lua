-- Modules/Skins/Quest.lua
-- Questing windows: the quest log (the standalone QuestLogFrame on clients that
-- still have one) and the NPC quest / gossip dialog windows.  Each window gets
-- the Monet plate + themed border, and its own action buttons / tabs / scroll
-- bars are restyled.  The quest *content* (objective text, reward item icons)
-- is deliberately left alone -- only the frame's own chrome is faded, so icons
-- and item buttons keep working.

local ADDON_NAME, ns = ...

local M = ns.Skins

-- -- Quest log ----------------------------------------------------------------

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

-- -- Quest / gossip dialogs ---------------------------------------------------

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

        -- The greeting / progress / reward / detail sub-panels each carry their
        -- own backdrop art; plate them so the dialog reads as one surface.
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

-- -- Registration -------------------------------------------------------------

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
