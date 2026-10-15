-- Modules/Skins/WorldMap.lua
-- The world map: WorldMapFrame's own chrome (border, title, close, zoom, min /
-- max) and the quest panel that lives inside it (QuestMapFrame).  The map canvas
-- and its pins are left to the game.

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

local MAP_BUTTONS = {
    "WorldMapFrameCloseButton", "WorldMapFrameMaximizeButton", "WorldMapFrameMinimizeButton",
    "WorldMapFrameZoomInButton", "WorldMapFrameZoomOutButton",
}

local function SkinQuestMap()
    local questMap = _G.QuestMapFrame
    if not questMap then return end

    Skin:Strip(questMap)
    Skin:Panel(questMap, { bgAlpha = 0.95 })

    -- The quest list panel and the quest detail panel sit inside the map.
    local details = questMap.DetailsFrame or _G.QuestMapFrameDetailsFrame
    local list = questMap.QuestLog or _G.QuestMapFrameQuestLog

    if details then
        Skin:Strip(details)
        Skin:Panel(details, { bgAlpha = 0.96 })
        M:SkinButtonsIn(details)
        M:SkinScrollsIn(details)
    end

    if list then
        Skin:Strip(list)
        Skin:Panel(list, { bgAlpha = 0.96 })
        M:SkinScrollsIn(list)
    end
end

local function SkinWorldMap()
    local map = _G.WorldMapFrame
    if not map then return end

    -- Fade the map's own chrome and hang one backplate behind the whole window.
    Skin:Strip(map)
    Skin:Panel(map, { bgAlpha = 0.96 })

    -- Title bar: plate the border strip and restyle the title.
    local border = map.BorderFrame
    if border then
        Skin:Strip(border)
        Skin:Panel(border, { bgAlpha = 0.96 })

        local title = border.TitleText or map.TitleText
        if title then
            Skin:Font(title, 16, "roadway", "OUTLINE", "edge")
        end
    end

    -- Close / zoom / min-max.
    M:Buttons(MAP_BUTTONS)
    M:Controls({ map.CloseButton, map.ZoomInButton, map.ZoomOutButton }, function(button)
        Skin:Button(button, { thickness = 1 })
    end)
    if map.MaximizeMinimizeFrame then
        M:Controls({ map.MaximizeMinimizeFrame.MaximizeButton, map.MaximizeMinimizeFrame.MinimizeButton }, function(button)
            Skin:Button(button, { thickness = 1 })
        end)
    end

    SkinQuestMap()
end

M:Panel("worldmap", {
    label = "世界地图",
    group = "地图",
    apply = SkinWorldMap,
})

M:OnEvent("WORLD_MAP_UPDATE", function()
    M:Apply(M.byKey.worldmap)
end)
