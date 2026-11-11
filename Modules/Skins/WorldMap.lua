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
    -- **1.60 没有 `WorldMapFrameCloseButton` 这个全局名**（原文按 retail 老布局取它 ⇒ `Skin:Need`
    -- 恒 nil ⇒ `Skin:CloseButton(nil)` 直接早退，换皮从登录起就没生效过一次）。
    -- `Blizzard_WorldMap.xml` 里 `WorldMapFrame` 继承 `MapCanvasFrameTemplate`，那个模板**只有
    -- Size 和 Scripts、一颗按钮都不建**；关闭钮是模板实例化时由 `BorderFrame` 的
    -- `PortraitFrameTemplateMinimizable` 生成、挂在 parentKey 上，暴雪自己也是这么取的 ——
    -- `Blizzard_WorldMap.lua:1102  self.CloseButton = self.BorderFrame.CloseButton`。
    -- （同文件 1059 行那句 `WorldMapFrameCloseButton:Click()` 是 gamepad 死代码，不能当名字依据。）
    local close = Skin:Need("WorldMapFrame.BorderFrame.CloseButton")
        or Skin:Need("WorldMapFrame.CloseButton")
    Skin:CloseButton(close)

    SkinQuestMap()
end

M:Panel("worldmap", {
    label = "世界地图",
    group = "地图",
    apply = SkinWorldMap,
    frames = {
        "WorldMapFrame", "WorldMapFrame.BorderFrame",
        "WorldMapFrame.BorderFrame.CloseButton", "WorldMapFrameHomeButton", "WorldMapFrameOverflowButton",
        "QuestMapFrame", "QuestMapFrame.DetailsFrame", "QuestScrollFrame", "MapLegendScrollFrame",
    },
})

M:OnEvent("WORLD_MAP_UPDATE", function()
    M:Apply(M.byKey.worldmap)
end)

-- 飞行点地图（2026-11-06 订正，玩家报「飞行地图页面全是黑的」）。
-- **本客户端的飞行图是核心 FrameXML 的 `TaxiFrame`**，不是 `FlightMapFrame`：
-- `Interface/AddOns` 里没有 `Blizzard_FlightMap` 这个包、`_G.FlightMapFrame` = nil，
-- 而 `_G.TaxiFrame` / `_G.TaxiRouteMap` / `TaxiButton1..14` 实机都在。
-- 以前这档挂在不存在的 `FlightMapFrame` 上、还带 `addons = { Blizzard_FlightMap = true }` 门控
-- ⇒ 从来没跑过；同时 `TaxiFrame` 被 `System.lua` 的「杂项常用窗」用通用 `window + deep` 档处理了，
-- 于是**地图本体被当成窗体装饰剥掉**：航线图不是 `TaxiRouteMap` 画的，是客户端渲染进
-- `TaxiFrame.InsetBg` 这张贴图的（Aurora 同一判据，`Blizzard_UIPanels_Game/Shared/TaxiFrame.lua:26`
-- "the flight map is rendered INTO InsetBg (SetTaxiMap(self.InsetBg)) — it must survive the sweep"），
-- 实机读数 `InsetBg tex=8033753 alpha=0` ⇒ 整页黑。
-- 两条动作缺一不可：① `strip.keep` 把那张贴图豁免在剥除之外；② 剥完**显式抬回 α1** ——
-- 本会话里它已经被上一版剥过、`Skin:Fade` 的"隐藏一次"旁表还挂在上面，光靠豁免不会自己回来。
local function SkinFlightMap()
    local tf = Skin:Need("TaxiFrame")
    if not tf then return end
    local mapTex = tf.InsetBg
    M:Dress(tf, {
        window = true,
        panel  = { bgAlpha = 0.96 },
        strip  = mapTex and { keep = function(region) return region == mapTex end } or nil,
    })
    if mapTex and type(mapTex.SetAlpha) == "function" then
        pcall(mapTex.SetAlpha, mapTex, 1)
    end
end

M:Panel("flightmap", {
    label = "飞行点地图",
    group = "地图",
    apply = SkinFlightMap,
    frames = { "TaxiFrame" },
})
