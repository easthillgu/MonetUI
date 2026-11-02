-- Modules/Skins/WorldMap.lua
-- The world map: WorldMapFrame's own chrome (border, title, close, zoom, min/max) and the quest panel inside it (QuestMapFrame).  The map canvas and its pins are left to the game.

local ADDON_NAME, ns = ...

local M    = ns.Skins
local Skin = ns.Skin

-- 12.1.5 实机（`/mui skins diagnose` + 探针）：世界地图**没有**标题文字、缩放钮，也没有
-- MaximizeMinimizeFrame —— `WorldMapFrame` 只有 Close / Overflow / Home 三颗按钮，
-- `BorderFrame` 的 3 个 region 全是 Texture（没有 TitleText）。旧版照 retail 老布局写的
-- `WorldMapFrame.TitleText` / `.ZoomInButton` / `.MaximizeMinimizeFrame.*` 在本客户端一个都不存在，
-- 那些 Dress 只是往账本里堆 miss，皮肤本身什么也没做，已删。
local MAP_BUTTONS = { "WorldMapFrameHomeButton", "WorldMapFrameOverflowButton" }

local function SkinQuestMap()
    M:Dress("QuestMapFrame", { panel = { bgAlpha = 0.96 } })

    -- 详情面板里全是按钮（奖励、难度、坐标…），要整层扫；任务列表只有滚动条 ——
    -- 列表行本身也是按钮，深扫会把它们全成底板，所以那一步留在调用点上明写。
    local details = Skin:Need("QuestMapFrame.DetailsFrame") or Skin:Need("QuestMapFrameDetailsFrame")
    if details then
        M:Dress(details, { panel = { bgAlpha = 0.96 }, deep = true })
    end

    local list = Skin:Need("QuestScrollFrame")
    if list then
        M:Dress(list, { panel = { bgAlpha = 0.96 } })
        M:SkinScrollsIn(list)
    end
    -- 图例列表：与任务列表同族的具名全局，只有滚动条要收。
    local legend = Skin:Need("MapLegendScrollFrame")
    if legend then M:SkinScrollsIn(legend) end
end

local function SkinWorldMap()
    if not Skin:Need("WorldMapFrame") then return end

    -- 两条都不走 window 档：地图画布和它的标点是内容，不能连 region 一起剥掉。
    M:Dress("WorldMapFrame", { panel = { bgAlpha = 0.96 } })
    M:Dress("WorldMapFrame.BorderFrame", { panel = { bgAlpha = 0.96 } })
    M:Dress(MAP_BUTTONS, { as = "button", control = { thickness = 1 } })

    -- 关闭按钮保留自己的字形：那是我们的图，不是被压平的底板。
    Skin:CloseButton(Skin:Need("WorldMapFrameCloseButton"))

    SkinQuestMap()
end

M:Panel("worldmap", {
    label = "世界地图",
    group = "地图",
    apply = SkinWorldMap,
    frames = {
        "WorldMapFrame", "WorldMapFrame.BorderFrame",
        "WorldMapFrameCloseButton", "WorldMapFrameHomeButton", "WorldMapFrameOverflowButton",
        "QuestMapFrame", "QuestMapFrame.DetailsFrame", "QuestScrollFrame", "MapLegendScrollFrame",
    },
})

M:OnEvent("WORLD_MAP_UPDATE", function()
    M:Apply(M.byKey.worldmap)
end)

-- 飞行点地图：本客户端没有 TaxiFrame（vanilla/mainline 专属门控），用的是 Blizzard_FlightMap
-- （无 game-type 门控）。航线图本身是内容，只收拾窗口壳。
local function SkinFlightMap()
    M:Dress("FlightMapFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 } })
end

M:Panel("flightmap", {
    label = "飞行点地图",
    group = "地图",
    apply = SkinFlightMap,
    addons = { Blizzard_FlightMap = true },
    frames = { "FlightMapFrame", "FlightMapFrame.CloseButton" },
})
