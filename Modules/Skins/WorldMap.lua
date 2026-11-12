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
-- §8.107 实机补充：这句只说 **`WorldMapFrame` 的字段**；`WorldMapFrame.BorderFrame` 上
-- `NineSlice / Bg / PortraitContainer / TitleContainer / TopTileStreaks / InsetBorderTop /
-- CloseButton / MaximizeMinimizeFrame / Tutorial` 九项**全都存在**（只是父层不同）。
-- 别把「WorldMapFrame 没这个字段」读成「1.60 整个地图没有这些控件」。
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

-- §8.107（11-12 Aurora 研读 + 实机复扫）：边框层「压过又回来」的纠回。
-- 实机读数：`BorderFrame` 自己 3 张 Texture 是 **α1.00**，而它下面 `NineSlice` 的 9 张是 α0。
-- 原因不是换皮没做 —— §8.106 的 `Skin:Strip` 特判确实压过那 3 张，但 `Skin:Fade` 是
-- **「隐藏一次」+ 旁表 hidden 标记**；暴雪在最大化/最小化换边框布局时把 alpha 重设回 1，
-- 标记还在 ⇒ 后续每趟 `Fade` 直接早退，永远纠不回来。
-- Aurora 的同处解法是 `EventRegistry` 回调 + `C_Timer.After(0)` 重跑 `RestyleBorderFrame`
-- （它明确写过：blizzard 在 Minimize 顶部发事件、后面才重锚，必须延后一帧）。
-- 我们不 hook 任何方法（taint 政策），只做两件事：每趟都写 α0 + 事件/轮询触发。
-- **绝不整层 Fade BorderFrame**：那是 1035x534 的全窗容器，下面挂着 11 个子控件（含关闭钮）。
local function RestyleBorderFrame()
    local bf = Skin:Need("WorldMapFrame.BorderFrame")
    if not bf then return end
    local ok, regions = pcall(function() return { bf:GetRegions() } end)
    if ok then
        for _, reg in ipairs(regions) do
            local okT, ty = pcall(reg.GetObjectType, reg)
            if okT and ty == "Texture" then pcall(reg.SetAlpha, reg, 0) end
        end
    end
    local ns = bf.NineSlice
    if ns and type(ns.GetRegions) == "function" then
        local ok2, pieces = pcall(function() return { ns:GetRegions() } end)
        if ok2 then
            for _, reg in ipairs(pieces) do
                local okT, ty = pcall(reg.GetObjectType, reg)
                if okT and ty == "Texture" then pcall(reg.SetAlpha, reg, 0) end
            end
        end
    end
end

local borderEventsHooked = false
local function RestyleBorderFrameLater()
    -- 事件在 Minimize/Maximize 顶部发，暴雪自己的重锚/重贴还在后面 ⇒ 延后一帧才落得住。
    local after = _G.C_Timer and _G.C_Timer.After
    if after then pcall(after, 0, RestyleBorderFrame) else RestyleBorderFrame() end
end

local function EnsureBorderEvents(wm)
    if borderEventsHooked or not wm then return end
    local ER = _G.EventRegistry
    if not ER or type(ER.RegisterCallback) ~= "function" then return end
    local ok = pcall(function()
        ER:RegisterCallback("WorldMapMinimized", function() RestyleBorderFrameLater() end, wm)
        ER:RegisterCallback("WorldMapMaximized", function() RestyleBorderFrameLater() end, wm)
    end)
    borderEventsHooked = ok
end

local function SkinWorldMap()
    local wm = Skin:Need("WorldMapFrame")
    if not wm then return end

    -- 两条都不走 window 档：地图画布和它的标点是内容，不能连 region 一起剥掉。
    M:Dress("WorldMapFrame", { panel = { bgAlpha = 0.96 } })
    -- §8.106 **不再给 BorderFrame 铺整窗底板**：它是 1035x534 的全窗容器，铺一张 α0.96 的
    -- 深色背板会把地图画布整块盖住（11-12 实机：把父层 α 恢复成 1 后地图变纯深色空白）。
    -- 窗口边框由上一行 WorldMapFrame 的 panel 提供；BorderFrame 自己那 3 张原生 Texture
    -- 已由 Skin:Strip 的容器特判压掉，11 个子控件（含关闭钮）原样保留。这里只登记查找。
    Skin:Need("WorldMapFrame.BorderFrame")
    M:Dress(MAP_BUTTONS, { as = "button", control = { thickness = 1 } })

    -- 关闭按钮保留自己的字形：那是我们的图，不是被压平的底板。
    -- **11-12 实机订正**：`WorldMapFrameCloseButton` 全局名确实存在，且与
    -- `WorldMapFrame.BorderFrame.CloseButton` 是**同一个对象**（`$parentCloseButton` 模板展开，
    -- 静态快照 grep 不到而已）；两条取法都有效，换皮从登录起一直是成功的。
    -- 旧结论「没有这个全局名 ⇒ 从没换过皮」是错的：X 看不见是 §8.106 之前 Strip 把整个
    -- 容器 Fade 成 α0，连坐吞掉了它下面 11 个子控件。点路径保留作首选、全局名兜底。
    local close = Skin:Need("WorldMapFrame.BorderFrame.CloseButton")
        or Skin:Need("WorldMapFrameCloseButton")
    Skin:CloseButton(close)

    SkinQuestMap()

    -- §8.107：纠回那 3 张被暴雪抬回 α1 的边框贴图。PollWatch 兜住没发事件的时刻，
    -- EventRegistry 兜住最大化 / 最小化换布局 —— 两条都不写暴雪方法槽，不产生 taint。
    RestyleBorderFrame()
    if ns.Widget and ns.Widget.PollWatch then ns.Widget:PollWatch(wm, RestyleBorderFrame, 1) end
    EnsureBorderEvents(wm)
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
    -- 地图更新常伴随边框布局重贴；Apply 是同步的，再排一帧收尾（§8.107）。
    RestyleBorderFrameLater()
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
