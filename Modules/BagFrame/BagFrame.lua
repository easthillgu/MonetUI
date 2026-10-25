-- Modules/BagFrame/BagFrame.lua
-- Bag integration: tidies the default containers into one row and frames them with the Monet border; the item grid stays Blizzard's.

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local EventBus = ns.EventBus

local M = { name = "BagFrame" }

local MAX_CONTAINERS = 13
local GAP            = 6
local skinned        = {}
local borders        = {}

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

    -- Border sits one frame level *below* the bag so the item buttons still draw on top of it.
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

    local title = frame.TitleContainer and frame.TitleContainer.TitleText
    if title and title.SetFont then
        pcall(Widget.SetFont, Widget, title, 12, "pixel")
    end

    -- 污染审查（2026-10-25）：不再 HookScript —— frame 是暴雪的 ContainerFrame，
    -- 往它脚本槽写函数会把它标脏（此后暴雪自己在包裹框上跑的代码全部记到
    -- MonetUI 名下，战斗中就是 ADDON_ACTION_BLOCKED 家族）。改用 Widget:ShowWatch
    -- 轮询（旁表 + 0.2s 轮查 IsVisible，零框体写），隐藏→显示的瞬间重排一次。
    Widget:ShowWatch(frame, function() M:ArrangeBags() end)
end

function M:Initialize()
    for index = 1, MAX_CONTAINERS do
        SkinContainer(_G["ContainerFrame" .. index])
    end

    -- Containers can be created on demand (bank / reagent tabs), so re-skin on bag updates.
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
