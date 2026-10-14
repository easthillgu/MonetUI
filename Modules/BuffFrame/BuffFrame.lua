-- Modules/BuffFrame/BuffFrame.lua
-- BuffFrame: buff/debuff display

local ADDON_NAME = ...

local BuffFrame = {
    name = "BuffFrame",
    enabled = true,
}

function BuffFrame:Initialize()
    -- TODO: Create buff frame UI
    print("|cFF88AAFF[MonetUI]|r BuffFrame: initialized")
end

function BuffFrame:Update()
    if not self.enabled then return end
end

function BuffFrame:SetEnabled(val)
    self.enabled = val
end

if _G.MonetUI then
    MonetUI:Register("BuffFrame", BuffFrame)
end

return BuffFrame
