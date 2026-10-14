-- Modules/Cooldown/Cooldown.lua
-- Cooldown: cooldown text and frames

local ADDON_NAME = ...

local Cooldown = {
    name = "Cooldown",
    enabled = true,
}

-- Private state
local cooldownFrames = {}

-- Public API
function Cooldown:Initialize()
    -- TODO: Hook cooldown frames
    print("|cFF88AAFF[MonetUI]|r Cooldown: initialized")
end

function Cooldown:Update()
    if not self.enabled then return end
    -- TODO: Update cooldown display
end

function Cooldown:SetEnabled(val)
    self.enabled = val
end

-- Register with core
if _G.MonetUI then
    MonetUI:Register("Cooldown", Cooldown)
end

return Cooldown
