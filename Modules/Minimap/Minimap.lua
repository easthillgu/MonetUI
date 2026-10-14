-- Modules/Minimap/Minimap.lua
-- Minimap: minimap skin and enhancements

local ADDON_NAME = ...

local Minimap = {
    name = "Minimap",
    enabled = true,
}

function Minimap:Initialize()
    -- TODO: Apply minimap border and styling
    print("|cFF88AAFF[MonetUI]|r Minimap: initialized")
end

function Minimap:Update()
    if not self.enabled then return end
end

function Minimap:SetEnabled(val)
    self.enabled = val
end

if _G.MonetUI then
    MonetUI:Register("Minimap", Minimap)
end

return Minimap
