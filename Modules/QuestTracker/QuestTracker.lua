-- Modules/QuestTracker/QuestTracker.lua
-- Objective tracker beautification: themed frame, draggable header and a
-- restyled title.  The tracker's own content is left untouched.

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local Color    = ns.Color
local Math     = ns.Math
local EventBus = ns.EventBus

local M = { name = "QuestTracker" }

local border
local tracker

local function SavePosition()
    if not tracker then return end
    if tracker.StopMovingOrSizing then tracker:StopMovingOrSizing() end
    local point, _, _, x, y = tracker:GetPoint()
    if not point then return end
    local db = ns:DB()
    db.questTracker = {
        point = point,
        x = Math:Round(x, 0),
        y = Math:Round(y, 0),
    }
end

local function RestorePosition()
    local db = ns:DB()
    local stored = db.questTracker
    if stored and stored.point then
        tracker:ClearAllPoints()
        tracker:SetPoint(stored.point, UIParent, stored.point, stored.x, stored.y)
    end
end

-- -- Skinning -----------------------------------------------------------------

function M:Skin()
    tracker = _G.ObjectiveTrackerFrame
    if not tracker then return false end

    pcall(tracker.SetMovable, tracker, true)
    pcall(tracker.SetClampedToScreen, tracker, true)

    -- Make the header the drag handle so clicks on objectives still work.  Hook
    -- instead of overwrite so any Blizzard script on the header is preserved.
    local header = tracker.Header
    if header and header.RegisterForDrag then
        header:RegisterForDrag("LeftButton")
        if header.HookScript then
            header:HookScript("OnDragStart", function() tracker:StartMoving() end)
            header:HookScript("OnDragStop", SavePosition)
        else
            header:SetScript("OnDragStart", function() tracker:StartMoving() end)
            header:SetScript("OnDragStop", SavePosition)
        end
    end

    RestorePosition()

    local headerText = header and header.Text
    if headerText and headerText.SetFont then
        pcall(Widget.SetFont, Widget, headerText, 14, "roadway", "OUTLINE")
        local r, g, b = Color:GetEdge()
        pcall(headerText.SetTextColor, headerText, r, g, b, 1)
    end

    if not border then
        border = Widget:CreateFrame("MonetUIQuestTrackerBorder", UIParent, 1, 1)
        border:SetPoint("TOPLEFT", tracker, "TOPLEFT", -8, 8)
        border:SetPoint("BOTTOMRIGHT", tracker, "BOTTOMRIGHT", 8, -8)
        border:SetFrameStrata("BACKGROUND")
        border:EnableMouse(false)
        Widget:Theme(border, { thickness = 1, bgAlpha = 0.4 })
    end

    return true
end

-- -- Lifecycle ----------------------------------------------------------------

function M:Initialize()
    if not self:Skin() then
        EventBus:Register("PLAYER_ENTERING_WORLD", function() M:Skin() end)
    end

    EventBus:Register("QUEST_LOG_UPDATE", function()
        if not tracker then M:Skin() end
    end)
end

function M:SetEnabled(enabled)
    if border then border:SetShown(enabled and true or false) end
    if tracker and enabled then
        RestorePosition()
    end
end

ns:Register("QuestTracker", M)
