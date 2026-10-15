-- Modules/BagFrame/BagFrame.lua
-- Bag integration: tidies the default containers into one row and frames them
-- with the Monet border.  The item grid itself is left to Blizzard.

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local EventBus = ns.EventBus

local M = { name = "BagFrame" }

local MAX_CONTAINERS = 13
local GAP            = 6
local skinned        = {}
local borders        = {}

-- -- Layout -------------------------------------------------------------------

--- Reposition every visible container into a single bottom row.
function M:ArrangeBags()
    local anchorX = -20
    for index = 1, MAX_CONTAINERS do
        local frame = _G["ContainerFrame" .. index]
        if frame and frame:IsShown() then
            local width = frame:GetWidth()
            if not width or width <= 0 then width = 200 end
            anchorX = anchorX - width

            frame:ClearAllPoints()
            frame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", anchorX, 110)
            anchorX = anchorX - GAP
        end
    end
end

local function SkinContainer(frame)
    if not frame or skinned[frame] then return end
    skinned[frame] = true

    -- The themed border is a child frame sitting one level *below* the bag so
    -- the item buttons still draw on top of it.
    local border = Widget:CreateFrame(nil, frame)
    border:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
    border:SetPoint("TOPLEFT", frame, "TOPLEFT", -5, 5)
    border:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 5, -5)
    border:EnableMouse(false)
    Widget:Theme(border, { thickness = 2, bgAlpha = 0.85 })
    borders[#borders + 1] = border

    -- drop Blizzard's own background in favour of ours
    if frame.NineSlice and frame.NineSlice.SetAlpha then
        frame.NineSlice:SetAlpha(0)
    end

    -- title font
    local title = frame.TitleContainer and frame.TitleContainer.TitleText
    if title and title.SetFont then
        pcall(Widget.SetFont, Widget, title, 13, "roadway", "OUTLINE")
    end

    if frame.HookScript then
        frame:HookScript("OnShow", function() M:ArrangeBags() end)
    end
end

-- -- Lifecycle ----------------------------------------------------------------

function M:Initialize()
    for index = 1, MAX_CONTAINERS do
        SkinContainer(_G["ContainerFrame" .. index])
    end

    -- Containers can be created on demand (bank / reagent tabs).
    EventBus:Register("BAG_UPDATE", function()
        for index = 1, MAX_CONTAINERS do
            SkinContainer(_G["ContainerFrame" .. index])
        end
    end)
end

function M:SetEnabled(enabled)
    for _, border in ipairs(borders) do
        border:SetShown(enabled and true or false)
    end
    if enabled then
        self:ArrangeBags()
    end
end

ns:Register("BagFrame", M)
