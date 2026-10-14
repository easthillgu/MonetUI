-- Modules/UnitFrames/UnitFrames.lua
-- Unit frames: player/target/focus/raid frames

local ADDON_NAME = ...

local UnitFrames = {
    name = "UnitFrames",
    enabled = true,
}

-- Private state
local frames = {}

-- Private functions
local function CreatePlayerFrame_()
    local frame = CreateFrame("Frame", "MonetUIPlayerFrame", UIParent, "BackdropTemplate")
    frame:SetSize(200, 60)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -100)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0.1, 0.1, 0.15, 0.8)
    frame:SetBackdropBorderColor(0.6, 0.4, 0.1, 0.9)

    local healthBar = CreateFrame("StatusBar", nil, frame)
    healthBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, -5)
    healthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -5, 5)
    healthBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    healthBar:SetStatusBarColor(0.2, 0.8, 0.2)
    healthBar:SetMinMaxValues(0, 100)
    healthBar:SetValue(80)

    return frame
end

-- Public API
function UnitFrames:Initialize()
    frames.player = CreatePlayerFrame_()
    print("|cFF88AAFF[MonetUI]|r UnitFrames: initialized")
end

function UnitFrames:Update()
    if not self.enabled then return end
    -- TODO: Update frame colors from MonetColor
end

function UnitFrames:SetEnabled(val)
    self.enabled = val
    if frames.player then
        frames.player:SetShown(val)
    end
end

-- Register with core
if _G.MonetUI then
    MonetUI:Register("UnitFrames", UnitFrames)
end

return UnitFrames
