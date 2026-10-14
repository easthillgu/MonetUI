-- Modules/QuestTracker/QuestTracker.lua
-- QuestTracker: quest log enhancements

local ADDON_NAME = ...

local QuestTracker = {
    name = "QuestTracker",
    enabled = true,
}

function QuestTracker:Initialize()
    -- TODO: Hook quest tracker frame
    print("|cFF88AAFF[MonetUI]|r QuestTracker: initialized")
end

function QuestTracker:Update()
    if not self.enabled then return end
end

function QuestTracker:SetEnabled(val)
    self.enabled = val
end

if _G.MonetUI then
    MonetUI:Register("QuestTracker", QuestTracker)
end

return QuestTracker
