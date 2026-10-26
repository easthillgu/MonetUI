-- Modules/Skins/WorldMap.lua
-- The world map: WorldMapFrame's own chrome (border, title, close, zoom, min/max) and the quest panel inside it (QuestMapFrame).  The map canvas and its pins are left to the game.

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

local MAP_BUTTONS = {
    -- Forever WorldMap 没有独立的 MaximizeButton/MinimizeButton/ZoomInButton/ZoomOutButton 全局名，
    -- 它们挂在 WorldMapFrame.MaximizeMinimizeFrame 点路径里。
}

local function SkinQuestMap()
    local questMap = _G.QuestMapFrame
    if not questMap then return end

    Skin:Strip(questMap)
    Skin:Panel(questMap, { bgAlpha = 0.95 })

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

    Skin:Strip(map)
    Skin:Panel(map, { bgAlpha = 0.96 })

    local border = map.BorderFrame
    if border then
        Skin:Strip(border)
        Skin:Panel(border, { bgAlpha = 0.96 })

        local title = border.TitleText or map.TitleText
        if title then
            Skin:Font(title, 12, "pixel", nil, "edge")
        end
    end

    M:Buttons(MAP_BUTTONS)
    M:Controls({ map.ZoomInButton, map.ZoomOutButton }, function(button)
        Skin:Button(button, { thickness = 1 })
    end)
    if map.MaximizeMinimizeFrame then
        M:Controls({ map.MaximizeMinimizeFrame.MaximizeButton, map.MaximizeMinimizeFrame.MinimizeButton }, function(button)
            -- Plate (Skin:Button) gives the frame chrome; then swap glyph art so players can
            -- tell them apart -- otherwise they would just be two blank Monet plates.
            Skin:Button(button, { thickness = 1 })
            local name = button.GetName and button:GetName()
            local isMax = name and name:find("Maximize")
            local key = isMax and "monet_win_maximize" or "monet_win_minimize"
            local normal = Skin:SwapArt(button.GetNormalTexture and button:GetNormalTexture(), key)
            local pushed = Skin:SwapArt(button.GetPushedTexture and button:GetPushedTexture(), key)
            -- monet_win_maximize deliberately keeps its baked gold (it is the "title bar = this is a window" signal);
            -- monet_win_minimize is stencilled (neutral white), so it follows the theme.
            if isMax then return end
            if normal and normal.SetVertexColor then
                local r, g, b = ns.Color:GetBorder()
                normal:SetVertexColor(r, g, b)
                if pushed and pushed.SetVertexColor then pushed:SetVertexColor(r, g, b) end
            end
        end)
    end
    -- The close button keeps its glyph: our own art, not the faded plate.
    Skin:CloseButton(map.CloseButton or _G.WorldMapFrameCloseButton)

    SkinQuestMap()
end

M:Panel("worldmap", {
    label = "世界地图",
    group = "地图",
    apply = SkinWorldMap,
    frames = {
        "WorldMapFrame", "WorldMapFrame.BorderFrame",
        "WorldMapFrameCloseButton",
        "WorldMapFrame.MaximizeMinimizeFrame.MaximizeButton",
        "WorldMapFrame.MaximizeMinimizeFrame.MinimizeButton",
        "QuestMapFrame", "QuestMapFrame.DetailsFrame", "QuestMapFrame.QuestLog",
    },
})

M:OnEvent("WORLD_MAP_UPDATE", function()
    M:Apply(M.byKey.worldmap)
end)

-- 飞行点地图：本客户端没有 TaxiFrame（vanilla/mainline 专属门控），用的是 Blizzard_FlightMap
-- （无 game-type 门控）。航线图本身是内容，只收拾窗口壳。
local function SkinFlightMap()
    local frame = _G.FlightMapFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
end

M:Panel("flightmap", {
    label = "飞行点地图",
    group = "地图",
    apply = SkinFlightMap,
    addons = { Blizzard_FlightMap = true },
    frames = { "FlightMapFrame", "FlightMapFrame.CloseButton" },
})
