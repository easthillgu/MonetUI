-- Modules/BagFrame/BagFrame.lua
-- BagFrame: bag integration

local ADDON_NAME = ...

local BagFrame = {
    name = "BagFrame",
    enabled = true,
}

function BagFrame:Initialize()
    -- TODO: Create bag frame UI
    print("|cFF88AAFF[MonetUI]|r BagFrame: initialized")
end

function BagFrame:Update()
    if not self.enabled then return end
end

function BagFrame:SetEnabled(val)
    self.enabled = val
end

if _G.MonetUI then
    MonetUI:Register("BagFrame", BagFrame)
end

return BagFrame
