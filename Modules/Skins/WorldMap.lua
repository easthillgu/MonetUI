-- Modules/Skins/WorldMap.lua
-- The world map: WorldMapFrame's own chrome (border, title, close, zoom, min/max) and the quest panel inside it (QuestMapFrame).  The map canvas and its pins are left to the game.

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

-- 本客户端的 WorldMap 没有独立的 MaximizeButton / MinimizeButton / ZoomIn/OutButton 全局名，
-- 它们挂在 WorldMapFrame.MaximizeMinimizeFrame 下面 —— 点路径照样能确认（ns.ResolveObject 逐段走）。
local MINMAX_PATHS = {
    "WorldMapFrame.MaximizeMinimizeFrame.MaximizeButton",
    "WorldMapFrame.MaximizeMinimizeFrame.MinimizeButton",
}

--- 最大/最小化：先上底板（Skin:Button 那套框），再换字形贴图 —— 否则两颗就是一模一样的空白板。
--- monet_win_maximize 故意留着烤好的金色（"标题栏 = 这是个窗口"的信号），
--- monet_win_minimize 是无色模具（纯白），跟着主题走。
local function StyleMinMaxGlyphs()
    for i = 1, #MINMAX_PATHS do
        local button = Skin:Need(MINMAX_PATHS[i])
        if button then
            local name = button.GetName and select(2, pcall(button.GetName, button))
            local isMax = type(name) == "string" and string.find(name, "Maximize")
            local key = isMax and "monet_win_maximize" or "monet_win_minimize"
            local normal = Skin:SwapArt(button.GetNormalTexture and button:GetNormalTexture(), key)
            local pushed = Skin:SwapArt(button.GetPushedTexture and button:GetPushedTexture(), key)
            if not isMax and normal and normal.SetVertexColor then
                local r, g, b = ns.Color:GetBorder()
                normal:SetVertexColor(r, g, b)
                if pushed and pushed.SetVertexColor then pushed:SetVertexColor(r, g, b) end
            end
        end
    end
end

local function SkinQuestMap()
    M:Dress("QuestMapFrame", { panel = { bgAlpha = 0.95 } })

    -- 详情面板里全是按钮（奖励、难度、坐标…），要整层扫；任务列表只有滚动条 ——
    -- 列表行本身也是按钮，深扫会把它们全成底板，所以那一步留在调用点上明写。
    local details = Skin:Need("QuestMapFrame.DetailsFrame") or Skin:Need("QuestMapFrameDetailsFrame")
    if details then
        M:Dress(details, { panel = { bgAlpha = 0.96 }, deep = true })
    end

    local list = Skin:Need("QuestMapFrame.QuestLog") or Skin:Need("QuestMapFrameQuestLog")
    if list then
        M:Dress(list, { panel = { bgAlpha = 0.96 } })
        M:SkinScrollsIn(list)
    end
end

local function SkinWorldMap()
    if not Skin:Need("WorldMapFrame") then return end

    -- 两条都不走 window 档：地图画布和它的标点是内容，不能连 region 一起剥掉。
    M:Dress("WorldMapFrame", { panel = { bgAlpha = 0.96 } })
    M:Dress("WorldMapFrame.BorderFrame", { panel = { bgAlpha = 0.96 } })

    local title = Skin:Need("WorldMapFrame.BorderFrame.TitleText") or Skin:Need("WorldMapFrame.TitleText")
    if title then Skin:Font(title, 12, "pixel", nil, "edge") end

    M:Dress({ "WorldMapFrame.ZoomInButton", "WorldMapFrame.ZoomOutButton" },
        { as = "button", control = { thickness = 1 } })
    M:Dress(MINMAX_PATHS, { as = "button", control = { thickness = 1 } })
    StyleMinMaxGlyphs()

    -- 关闭按钮保留自己的字形：那是我们的图，不是被压平的底板。
    Skin:CloseButton(Skin:Need("WorldMapFrame.CloseButton") or Skin:Need("WorldMapFrameCloseButton"))

    SkinQuestMap()
end

M:Panel("worldmap", {
    label = "世界地图",
    group = "地图",
    apply = SkinWorldMap,
    frames = {
        "WorldMapFrame", "WorldMapFrame.BorderFrame",
        "WorldMapFrame.TitleText", "WorldMapFrame.CloseButton", "WorldMapFrameCloseButton",
        "WorldMapFrame.BorderFrame.TitleText",
        "WorldMapFrame.ZoomInButton", "WorldMapFrame.ZoomOutButton",
        "WorldMapFrame.MaximizeMinimizeFrame.MaximizeButton",
        "WorldMapFrame.MaximizeMinimizeFrame.MinimizeButton",
        "QuestMapFrame", "QuestMapFrame.DetailsFrame", "QuestMapFrameQuestLog",
    },
})

M:OnEvent("WORLD_MAP_UPDATE", function()
    M:Apply(M.byKey.worldmap)
end)

-- 飞行点地图：本客户端没有 TaxiFrame（vanilla/mainline 专属门控），用的是 Blizzard_FlightMap
-- （无 game-type 门控）。航线图本身是内容，只收拾窗口壳。
local function SkinFlightMap()
    M:Dress("FlightMapFrame", { window = true, panel = { bgAlpha = 0.96 } })
end

M:Panel("flightmap", {
    label = "飞行点地图",
    group = "地图",
    apply = SkinFlightMap,
    addons = { Blizzard_FlightMap = true },
    frames = { "FlightMapFrame", "FlightMapFrame.CloseButton" },
})
