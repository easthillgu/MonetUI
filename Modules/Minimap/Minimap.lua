-- Modules/Minimap/Minimap.lua
-- 方形小地图：右下角 256×190 的矩形可见区（正方画布 256×256 + 遮罩裁掉上下两条带）
-- + Monet 面板 + 顶部区域名条，并接管暴雪的集群按钮（时钟 / 邮件 / 追踪 / 缩放 / 难度 /
-- 制造订单 / 着陆页 / 插件收纳 / 罗盘底板），默认逐项隐藏，可在配置面板单独开关。
--
-- 皮肤动过的一切都在首次套用时快照，关闭模块即完整还原。
--
-- 第三方小地图 pin（HBD）落进被裁的带子里的处理，在 Modules/Minimap/Pins.lua。
--
-- 本客户端（Interface 16001，camelot）的暴雪 UI 与零售版不同，帧名以客户端源码为准：
--   Interface/AddOns/Blizzard_Minimap/Mainline/Minimap.xml —— 集群结构（ZoneTextButton /
--   Tracking / IndicatorFrame / MinimapContainer）
--   Interface/AddOns/Blizzard_Minimap/Camelot/Minimap.lua —— 昼夜球、遮罩图集、UpdateMinimapConfig
-- 这个客户端**没有** MinimapBorder / MinimapBorderTop / MinimapNorthTag，也没有
-- GetMinimapShape（手册与暴雪源码里都查不到），所以旧代码里的那几条是空转。

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local EventBus = ns.EventBus
local Secrets  = ns.Secrets

local M = { name = "Minimap" }

-- ------------------------------------------------------------------ 几何

-- 可见的地图：256×190。画布保持正方 256×256，用遮罩裁掉上下两条带 —— 地图画面**不重绘**，
-- 所以不会被拉伸（非正方形 SetSize 在 WoW 里是把正方渲染拉伸，见 TODO 里 2026-10-21 那条）。
--
-- 上下两条带**等宽**（各 33）：可见带 = 画布 33..223，地图圆心就是画布圆心，圆角上下对称。
-- 唯一的硬约束是"画布不能有任何像素探到屏幕外"：客户端给"被屏幕切过"的帧算遮罩时，会把整张
-- 遮罩按**可见高度**重算（实测：画布底 −7 时 33/33 的遮罩落成 32.1/27.1，可见底边跑到 34，
-- 比面板内底高 8，露出一条 7 单位宽的面板底色 —— 就是"小地图底部与边框之间的灰条"）。
-- 画布整个在屏幕里时遮罩才是严格 1:1（texel = UI 单位），几何才可预测。
-- 所以画布底贴屏幕底(0)，底部基线（Utils/Layout.lua 的 bottom）就得抬到
-- MASK_CROP − PANEL_PAD = 31，小地图/动作条/聊天框一起跟着抬。
local MINIMAP_GAP    = 33        -- 集群贴到屏幕右下角的间距
local MAP_WIDTH      = 256      -- 可见的地图宽度
local MAP_HEIGHT     = 190      -- 可见的地图高度
local MASK_CANVAS    = 256      -- 画布：正方
local MASK_CROP      = (MASK_CANVAS - MAP_HEIGHT) / 2   -- 33：上下各一条等宽透明带

-- 面板（边框 + 底色）围着**可见带**画，不再围着 256×256 的画布。
-- 边框固定 1 个物理像素（Media:Mult 把像素换算成 UI 单位），再留 1 个单位的缝，
-- 于是面板比可见带每边大 (边框 + 缝)。原来面板大 8（每边 4）、边框 2，
-- 中间空出 2 个单位，看起来就是"边框和地图脱节"。
local BORDER_PX      = 1
local PANEL_PAD      = 2        -- 面板每边比可见带多出的 UI 单位（边框 1px + 缝 1 单位）

-- 暴雪用图集遮罩画圆形地图（客户端自己的 MinimapClusterMixin:UpdateMinimapConfig 会
-- 把它设回 ui-hud-minimap-frame-generic-mask）。帧体没有「读遮罩」的接口，所以还原
-- 时优先请客户端自己设回去，退路才是这个图集名。
local DEFAULT_MASK = "ui-hud-minimap-frame-generic-mask"

local panel, zoneText, blocker
local original  = nil      -- 首次套用时的快照，Restore() 依此还原
local active    = false
local warned    = {}       -- 一次性提示

-- 战斗队列：战斗中受保护的方法会被**无声拒绝**（连报错都没有），把要做的事按 key
-- 排队，脱战（PLAYER_REGEN_ENABLED）后排空。同一个 key 只排一次 —— 多个按钮同时被拒
-- 也只补一次（Ellesmere 的战斗队列就是这么去重的）。
local queued = {}

-- 前置声明：排空队列要用到 Restore / Skin，而它们定义在后面
local Restore, Skin

--- 排队（按 key 去重）。
local function Queue(key)
    queued[key] = true
end

--- 排空队列。先还原再套用：两者互斥，还原优先；每个动作单独 pcall，
--- 一个失败不拖累另一个，失败的那个重新排回去等下一次脱战。
local function RunQueue()
    local wantRestore = queued["restore"]
    local wantSkin    = queued["skin"]
    queued = {}
    if wantRestore then
        if not pcall(Restore) then Queue("restore") end
        return
    end
    if wantSkin then
        if not pcall(Skin) then Queue("skin") end
    end
end

local shapeOverridden = false
local originalShape   = nil
local shapeHadOriginal = false   -- 接管前这个全局本来存不存在（决定还原时是放回还是删掉）
local pingSuppressed  = false   -- 右键要弹我们的菜单，暴雪那条"右键打标记"要堵掉
local pingOriginal    = nil

-- 前置声明：覆盖层要用它做悬停显隐，而实现在下面的"区域名"一节
local SetZoneTextVisible

-- ------------------------------------------------------------------ 设置

--- 存于 MonetUIDB.minimap；默认值在 Core.DEFAULTS 里。
local function Settings()
    local db = ns:DB()
    if type(db.minimap) ~= "table" then db.minimap = {} end
    return db.minimap
end

-- ------------------------------------------------------------------ 集群按钮

-- key 是 MonetUIDB.minimap 里的开关名，paths 是候选帧路径（能解析到的都算）。
-- art = true 表示是装饰贴图：只压 alpha，不隐藏 —— 隐藏父帧会停掉罗盘旋转，
-- 第三方战斗工具正是靠 MinimapCompassTexture:GetRotation() 读玩家朝向。
-- skipKey：那个开关开着时，这一条就交给它管（追踪 / 收纳按钮被搬进地图后，
-- 再"藏起来"就把刚搬进去的按钮藏没了）。
local BUTTONS = {
    { key = "hideZoneText",    label = "区域文字", paths = { "MinimapCluster.ZoneTextButton" } },
    { key = "hideCoords",      label = "坐标",     paths = { "MinimapCluster.MinimapContainer.PlayerCoords" } },
    { key = "hideClock",       label = "时钟",     paths = { "TimeManagerClockButton", "GameTimeFrame" } },
    { key = "hideMail",        label = "邮件",     paths = { "MinimapCluster.IndicatorFrame.MailFrame", "MiniMapMailFrame" } },
    { key = "hideTracking",    label = "追踪",     paths = { "MinimapCluster.Tracking.Button", "MiniMapTrackingButton" }, skipKey = "mapTracking" },
    { key = "hideZoom",        label = "缩放按钮", paths = { "MinimapCluster.MinimapContainer.Minimap.ZoomIn",
                                                            "MinimapCluster.MinimapContainer.Minimap.ZoomOut" } },
    { key = "hideDifficulty",  label = "难度",     paths = { "MiniMapInstanceDifficulty", "GuildInstanceDifficulty",
                                                            "MinimapCluster.InstanceDifficulty" } },
    { key = "hideCrafting",    label = "制造订单", paths = { "MinimapCluster.IndicatorFrame.CraftingOrderFrame", "MiniMapCraftingOrderFrame" } },
    { key = "hideLanding",     label = "着陆页",   paths = { "ExpansionLandingPageMinimapButton" } },
    { key = "hideCompartment", label = "插件收纳", paths = { "AddonCompartmentFrame" }, skipKey = "mapCompartment" },
    { key = "hidePromo",       label = "活动链接", paths = { "MinimapBackdrop.ExternalEventURLButton" } },
    { key = "hideCompass",     label = "罗盘底板", paths = { "MinimapCompassTexture", "MinimapCompassTextureUnderlay",
                                                            "MinimapBackdrop.StaticOverlayTexture" }, art = true },
    -- 旧小地图的顶边：零售 12.x 把它拆成了 MinimapCluster.BorderTop（老名字 MinimapBorderTop
    -- 在这个客户端上不存在），一条横条留在地图上方，只能按新名字收掉。
    { key = "hideBorderTop",   label = "地图顶边", paths = { "MinimapCluster.BorderTop", "MinimapBorderTop" } },
    -- 微型菜单那一排：零售 12.x 的按钮改名了（PlayerSpellsMicroButton 之类），整排只剩空格子，
    -- 右键小地图弹出的菜单已经接管了这些入口，所以零售上把整排收起来；老客户端（和 Forever）
    -- 保留那排经典按钮，只压美术（见 Modules/Skins/Forever.lua）。
    { key = "hideMicroMenu",   label = "微型菜单", paths = { "MicroMenu" }, retailOnly = true },
}

-- 零售 12.x 的微型按钮改过名（PlayerSpellsMicroButton 而不是 SpellbookMicroButton）；
-- 老客户端（和 Forever）上认这两个老名字。
local RETAIL_MICRO = (_G.PlayerSpellsMicroButton ~= nil) and (_G.SpellbookMicroButton == nil)

--- 走点号路径取对象（MinimapCluster.ZoneTextButton 这类 parentKey 路径）。
--- 帧是 userdata，取子字段不会报错，但仍逐段 pcall，免得碰到没有 __index 的对象。
local function Resolve(path)
    local node = _G
    for segment in path:gmatch("[^%.]+") do
        if node == nil then return nil end
        local ok, value = pcall(function() return node[segment] end)
        if not ok then return nil end
        node = value
    end
    return node
end

--- 一次性提示（不刷屏）。
local function WarnOnce(topic, message)
    if warned[topic] then return end
    warned[topic] = true
    ns:Print(message)
end

--- 记录对象在套用皮肤前的状态。重复套用不能覆盖原值，否则「关掉开关」还原的
--- 就是我们自己改过的 0 了。
local function RememberObject(obj)
    if not original or not obj then return end
    if original.objects[obj] then return end
    local state = {}
    if obj.GetAlpha then
        local ok, alpha = pcall(obj.GetAlpha, obj)
        if ok then state.alpha = alpha end
    end
    if obj.IsShown then
        local ok, shown = pcall(obj.IsShown, obj)
        if ok then state.shown = shown end
    end
    original.objects[obj] = state
end

--- 把一个对象按回套用皮肤之前的样子。
local function RestoreObject(obj)
    local state = original and original.objects[obj]
    if not state then return end
    if state.alpha ~= nil and obj.SetAlpha then pcall(obj.SetAlpha, obj, state.alpha) end
    if state.shown ~= nil and obj.SetShown then pcall(obj.SetShown, obj, state.shown) end
end

local hooked = setmetatable({}, { __mode = "k" })

--- 暴雪在换区域、过场、载入之后会重新 Show 这些按钮，钩一次 Show 把它们按回去。
--- 钩子里只做「按回去」的动作，不碰暴雪的逻辑，所以它自己的状态机不会错乱。
local function HookShow(obj, entry)
    if hooked[obj] then return end
    hooked[obj] = true
    hooksecurefunc(obj, "Show", function(self)
        if not active then return end
        if not Settings()[entry.key] then return end
        if InCombatLockdown() then
            Queue("skin")
            return
        end
        if entry.art then
            pcall(self.SetAlpha, self, 0)
        else
            pcall(self.Hide, self)
            pcall(self.SetAlpha, self, 0)
        end
    end)
end

--- 隐藏一个集群按钮。
--- 战斗中 Hide() 会被无声拒绝（连报错都没有），所以先排队，脱战后再补一次。
local function HideObject(obj, entry)
    RememberObject(obj)
    if entry.art then
        pcall(obj.SetAlpha, obj, 0)
    else
        if InCombatLockdown() and obj.IsProtected and obj:IsProtected() then
            Queue("skin")
        else
            pcall(obj.Hide, obj)
        end
        pcall(obj.SetAlpha, obj, 0)
    end
    HookShow(obj, entry)
end

--- 套用 / 还原整张清单。
local function ApplyButtons()
    local settings = Settings()
    for _, entry in ipairs(BUTTONS) do
        -- 只在零售上生效的条目（比如微型菜单那一排），老客户端上跳过。
        if entry.retailOnly and not RETAIL_MICRO then
            -- 跳过
        -- 追踪 / 收纳按钮被搬进地图后，"藏起来"就归搬进去的那一路管
        elseif entry.skipKey and settings[entry.skipKey] then
            -- 交给 mapTracking / mapCompartment 处理
        else
            local wanted = settings[entry.key] and true or false
            for _, path in ipairs(entry.paths) do
                local obj = Resolve(path)
                if obj then
                    if wanted then
                        HideObject(obj, entry)
                    else
                        RestoreObject(obj)
                    end
                end
            end
        end
    end
end

-- ------------------------------------------------------------------ 地图本体

--- 把集群挪到右下角。编辑模式也会给这个帧设锚点，所以 SetPoint 要防一手；每次套用都重做一遍。
---
--- 对齐的是**眼睛看到的底边**，不是集群的底边：可见底边 = Minimap 帧底 + 遮罩下裁(MASK_CROP)，
--- 面板再向下凸出 PANEL_PAD。而 Minimap 帧本身又不贴 MinimapCluster 的底（暴雪集群内部有偏移），
--- 所以先用目标值锚一次、再按实测差值补一下 —— 否则"常量写 26、看着却是 47.5"那种失真会一直在。
local clusterAnchor = { x = 0, y = 0 }   -- 集群当前的锚点（补差后的绝对值，单位 UI）
local clusterTarget = { gap = MINIMAP_GAP, bottom = MINIMAP_GAP }

--- 按实测的可见面板边补差；平移是线性的，量一次就差多少补多少。
--- 返回是否还需要再看一眼（差值还没收敛）。
local function AlignCluster()
    -- 集群是编辑模式管理的受保护框体：战斗中 SetPoint 会被判越权。本函数还会从
    -- C_Timer.After 的回调里跑（见 MoveCluster），所以守卫必须放在最前面。
    if InCombatLockdown() then
        Queue("skin")
        return false
    end
    local cluster = _G.MinimapCluster
    local minimap = _G.Minimap
    if not cluster or not minimap or type(minimap.GetRect) ~= "function" then return false end

    local okRect, left, bottom, width = pcall(minimap.GetRect, minimap)
    if not okRect or type(left) ~= "number" or type(bottom) ~= "number"
        or type(width) ~= "number" then
        return false
    end
    if Secrets.IsSecret(left) or Secrets.IsSecret(bottom) then return false end

    local okParent, parentWidth = pcall(UIParent.GetWidth, UIParent)
    if not okParent or type(parentWidth) ~= "number" or Secrets.IsSecret(parentWidth) then return false end

    local gap, target = clusterTarget.gap, clusterTarget.bottom
    local panelBottom = bottom + MASK_CROP - PANEL_PAD
    local panelRight  = left + width + PANEL_PAD

    local dx = (parentWidth - gap) - panelRight
    local dy = target - panelBottom
    if math.abs(dx) < 0.5 and math.abs(dy) < 0.5 then return false end

    clusterAnchor.x = clusterAnchor.x + dx
    clusterAnchor.y = clusterAnchor.y + dy
    pcall(cluster.SetPoint, cluster, "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", clusterAnchor.x, clusterAnchor.y)
    return true
end

local function MoveCluster()
    if InCombatLockdown() then
        Queue("skin")
        return
    end
    local cluster = _G.MinimapCluster
    if not cluster then return end

    local gap = tonumber(Settings().gap) or MINIMAP_GAP
    local target = (ns.Layout and ns.Layout.bottom) or MINIMAP_GAP
    clusterTarget.gap, clusterTarget.bottom = gap, target
    clusterAnchor.x, clusterAnchor.y = -gap, target

    -- 暴雪给集群开了"夹在屏幕内"，锚到 -7 会被悄悄夹回 0（面板就停在 31）。
    -- 集群下面的 7 个单位在画布透明区里，放出去看不见，必须放开夹取才能对齐基线。
    pcall(cluster.SetClampedToScreen, cluster, false)

    pcall(cluster.ClearAllPoints, cluster)
    local ok = pcall(cluster.SetPoint, cluster, "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", clusterAnchor.x, clusterAnchor.y)
    if not ok then
        if not warned.cluster then
            warned.cluster = true
            ns:Print("小地图定位失败，已保留暴雪默认位置。")
        end
        return
    end

    -- 暴雪在集群挪动之后还会重摆一次 Minimap 自己的锚点，晚一帧才生效（实测：补完差又自己下沉
    -- 5.5，面板底边从 24 变成 31）。所以下一帧再量一次；量到收敛就停，最多补三遍。
    AlignCluster()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if InCombatLockdown() then Queue("skin") return end
            for _ = 1, 3 do
                if not AlignCluster() then break end
            end
        end)
    end
end

--- 逼引擎按新尺寸重画地图。
--- 改了画布尺寸之后，引擎有时还沿用旧视口（地图比例不对 / 像是旧图）。
--- Ellesmere 的做法：抖一下缩放档位再抖回来 —— 引擎被这个变化惊动，就按新尺寸重画了；
--- 抖完立刻抖回来，肉眼只看到一瞬间。
local function NudgeZoom(minimap)
    if not minimap.GetZoom or not minimap.SetZoom then return end
    local ok, zoom = pcall(minimap.GetZoom, minimap)
    if not ok or type(zoom) ~= "number" then return end
    if Secrets.IsSecret(zoom) then return end
    pcall(minimap.SetZoom, minimap, zoom > 0 and 0 or 1)
    pcall(minimap.SetZoom, minimap, zoom)
end

--- 告诉编辑模式：小地图集群已经不在它的"默认位置"了。
---
--- 编辑模式算右侧动作条（MultiBarRight / MultiBarLeft）的缩放时，用的是
--- `topLimit = MinimapCluster:IsInDefaultPosition() and (MinimapCluster:GetBottom() - 10) or UIParent:GetTop()`
--- 和 `bottomLimit = MicroButtonAndBagsBar:GetTop() + 24`，再 `newScale = availableSpace / multiBarHeight`。
--- 暴雪假定小地图在右上角、在微型菜单**上方**；我们把集群搬到右下角（在微型菜单下方）之后
--- availableSpace 变成负数（实测 -101.5），它就算出 -0.18 去 SetScale，直接报
--- `MultiBarRight:SetScale(): Scale must be > 0`（打开法术书/天赋、换角色、改分辨率都会触发）。
---
--- `IsInDefaultPosition` 读的是编辑模式自己的 `systemInfo.isInDefaultPosition`，跟我们实际搬没搬
--- 无关 —— 所以我们搬完就得把这句话改成"不在默认位置"，它才会退回 UIParent 的整屏高度、
--- 把缩放按 1 处理（右侧那两条我们本来就 Park 成透明的）。
local function MarkClusterMoved()
    local cluster = _G.MinimapCluster
    if not cluster then return end
    if cluster.__monetMovedFlag then return end
    if type(cluster.IsInDefaultPosition) ~= "function" then return end
    cluster.__monetMovedFlag = true
    cluster.IsInDefaultPosition = function() return false end
end

--- 把地图变成矩形。
---
--- 做法是"正方画布 + 遮罩裁带"：画布保持 256×256，用 `minimap_rect_mask`（上 40 / 下 26 全透明）
--- 裁出 190 高的可见带。地图画面**不重绘**，所以不会被拉伸 —— 这是相对"把画布直接设成
--- 256×190"的关键区别：非正方形 SetSize 在 WoW 里是把正方渲染拉伸（纵向压扁约 26%），
--- 那一档已经删掉（证据与决策见 TODO 2026-10-21 两条）。
---
--- 这时**必须**把命中区也裁成 0,0,40,26：上下那两条被遮罩挡着看不见，
--- 却是"活的"（引擎仍按 256×256 的视口画，坐标换算也按那个视口），
--- 不裁的话点在那两条上会打出一个看不见的标记。
---
--- 注意：**SetHitRectInsets 不是"方形化的开关"**。这个客户端的暴雪 Minimap 一处都
--- 没用它（整个 Blizzard_Minimap 包 0 处）—— 圆形小地图的限制是写在代码里的
--- （Blizzard_Minimap/Mainline/Minimap.lua:141 的
---  `if ( sqrt(x * x + y * y) < (self:GetWidth() / 2) )`），
--- 也就是说命中区一直是方的，圆的只是"**能不能打标记**"。
--- 所以四角打不了标记跟命中区裁不裁无关，也正因为如此，
--- 四角要能打标记只能自己算坐标（PingAtCursor）——SquareMap / EKMinimap 那种
--- "交给暴雪处理"的做法在方形下必然打不出四角。
local function ReshapeMinimap(minimap)
    -- 这些几何调用（SetSize / SetPoint / SetHitRectInsets / SetClampedToScreen /
    -- EnableMouseWheel …）在客户端手册里全是 **protected function**：
    -- 战斗中调用会被**静默拒绝** —— 不报错、也不生效。所以必须看 pcall 的结果，
    -- 失败就排队，脱战后再补一次（Queue 见文件头的战斗队列）。
    local failed = false
    local function try(ok) if not ok then failed = true end end

    local beforeW, beforeH
    if minimap.GetSize then
        local ok, w, h = pcall(minimap.GetSize, minimap)
        if ok then beforeW, beforeH = w, h end
    end

    try(pcall(minimap.SetMaskTexture, minimap, ns.Media:Texture("minimapRect")))
    try(pcall(minimap.SetSize, minimap, MASK_CANVAS, MASK_CANVAS))
    try(pcall(minimap.SetHitRectInsets, minimap, 0, 0, MASK_CROP, MASK_CROP))
    try(pcall(minimap.SetClampRectInsets, minimap, 0, 0, 0, 0))
    -- 画布**必须整个留在屏幕里**：被屏幕切过时客户端会按可见高度重算遮罩（见文件头那段），
    -- 可见带会缩水、下沿抬高，露出一条面板底色。现在画布底正好贴屏幕底(0)，不夹取也不会越界。
    try(pcall(minimap.SetClampedToScreen, minimap, false))

    -- 暴雪那圈 "blob ring"（任务区域 / 考古点的环）是按圆画的：套在矩形地图上，
    -- 蓝色任务区域里会露出一圈圆形的"华夫饼"纹（BasicMinimap 的注释原话）。
    -- scalar 归零把它收掉 —— Ellesmere 是 `isCircle and 1 or 0`，Andromeda 直接 0，
    -- 两家都不碰 alpha（没必要：环的尺寸已经是 0）。
    -- 没有 getter（手册里只有 Set*），所以还原时按默认值 1 放回。
    for _, method in ipairs({ "SetArchBlobRingScalar", "SetQuestBlobRingScalar" }) do
        if type(minimap[method]) == "function" then
            try(pcall(minimap[method], minimap, 0))
        end
    end

    -- 只在尺寸**真的**变了才抖：Skin() 每次换区域都会重跑，无条件抖会看到缩放闪一下。
    -- 顺便让引擎按新视口重画一遍 blip（任务点 / 队友那些图标是引擎画在画布上的，
    -- 改了尺寸不一定会跟着重画；遮罩方案下它们会留在旧的 256×256 视口里，
    -- 画到被裁掉的那两条带子上）。
    if beforeW then
        local ok, w, h = pcall(minimap.GetSize, minimap)
        if ok and (w ~= beforeW or h ~= beforeH) then
            NudgeZoom(minimap)
            if minimap.UpdateBlips then pcall(minimap.UpdateBlips, minimap) end
        end
    end

    if failed then Queue("skin") end

    MarkClusterMoved()
end

--- ElvUI / NDui 约定：全局 GetMinimapShape 告诉第三方小地图按钮"现在的小地图是方的"，
--- 它们据此把按钮摆进矩形里，而不是按圆形摆。
---
--- 这**不是暴雪 API**：暴雪自己的源码（4481 个文件）和 API 手册（mainline/mists/cata/wrath/
--- tbc/vanilla/forever 七个版本）里都查不到这个名字。它是 ElvUI 自创的约定全局 ——
--- ElvUI\Game\Shared\Modules\Maps\Minimap.lua 的 SetGetMinimapShape() 写着
--- `GetMinimapShape = M.GetMinimapShape`，初始化处还留了一句
--- "this is just to support for other mods"；NDui 抄了同一套（Core\GUI.lua 里
--- `GetMinimapShape = B.GetMinimapShape`，且只在自家小地图启用时才赋）。
---
--- 按这个约定，**谁给小地图换皮，谁负责回答**。所以：
---   * 皮肤在的时候，保证这个全局存在，且答 "SQUARE"（可见区是 256×190 的矩形，
---     第三方按钮要的正是"别按圆摆"）；
---   * 皮肤撤了，把接管前的值原样放回去；接管前本来没有，就删掉，别留一个过期的全局。
---     （之前只在全局已存在时才覆写，等于"皮肤在但没人回答"，第三方按钮拿到 nil 会直接报错。）
---
--- 写法用 rawset：写的是**别人的全局**，不是我们漏写的 local；
--- 而且这是 wuxian check 唯一不报 global-write 的形式（实测 `_G.X =` / `_G["X"] =` /
--- 裸 `X =` / `-- GLOBALS:` 注释都会被报成 "writes the global GetMinimapShape"）。
local function ApplyShape()
    if shapeOverridden then return end
    originalShape = rawget(_G, "GetMinimapShape")
    shapeHadOriginal = originalShape ~= nil
    rawset(_G, "GetMinimapShape", function() return "SQUARE" end)
    shapeOverridden = true
end

--- 把 GetMinimapShape 还回去（只有真的接管过才动它）。
local function RestoreShape()
    if not shapeOverridden then return end
    if shapeHadOriginal then
        rawset(_G, "GetMinimapShape", originalShape)
    else
        rawset(_G, "GetMinimapShape", nil)
    end
    shapeOverridden = false
    originalShape = nil
    shapeHadOriginal = false
end

-- ------------------------------------------------------------------ 缩放

--- 缩放一档，上下限和客户端自己的按钮一致（GetZoomLevels()-1）。
local function ZoomStep(delta)
    local minimap = _G.Minimap
    if not minimap or not minimap.GetZoom or not minimap.SetZoom then return end
    local levels = minimap.GetZoomLevels and minimap:GetZoomLevels() or 5
    local current = minimap:GetZoom() or 0
    local target = math.max(0, math.min(current + delta, levels - 1))
    if target == current then return end
    pcall(minimap.SetZoom, minimap, target)
    Settings().zoom = target
end

--- 方形地图上打标记。
--- 暴雪自己的 MinimapMixin:OnClick 只在点击落在**圆内**时才 PingLocation（那个判断是给
--- 圆形小地图写的），方形皮肤下四个角会被判成"点在圆外"而什么也不做。
--- 这里照抄它那套坐标换算，只是去掉圆的判断：方形的地图，四角也是地图的一部分。
local function PingAtCursor(minimap)
    if not minimap or not minimap.PingLocation or not _G.GetCursorPosition then return end
    local x, y = GetCursorPosition()
    local scale = minimap.GetEffectiveScale and minimap:GetEffectiveScale()
    if not scale or scale == 0 then return end
    x = x / scale
    y = y / scale
    local cx, cy = minimap:GetCenter()
    if not cx then return end
    pcall(minimap.PingLocation, minimap, x - cx, y - cy)
end

--- 方形地图的命中区。
-- 定义在本文件靠后的位置（~458 行），但 EnsureBlocker 的中键处理要调它：不先声明成 upvalue
-- 的话那里看到的是全局 `OpenTrackingMenu`（零售服 nil，Forever 上是别人的），中键一点就报
-- "attempt to call a nil value"。
local OpenTrackingMenu

--- 暴雪的 Minimap 命中区是圆的，方形皮肤下四角够不到；这层透明帧铺满**可见区**
--- （不是整个 256×256 画布：上下那两条已经被遮罩裁掉了，落在那儿的位置地图上并不显示）：
---   * 滚轮 —— 缩放；
---   * 左键 —— 自己打标记（四角也算），所以不穿透给地图；
---   * 右键 —— 弹微型菜单；
---   * 鼠标移动 —— 透传给地图，地图自己的悬停效果照旧。
local function EnsureBlocker(minimap)
    if not blocker then
        blocker = CreateFrame("Frame", "MonetUIMinimapOverlay", minimap)
        blocker:SetFrameLevel(minimap:GetFrameLevel() + 10)
        blocker:SetPropagateMouseMotion(true)
        blocker:EnableMouse(true)
        blocker:SetScript("OnMouseWheel", function(_, delta)
            if not Settings().scrollZoom then return end
            ZoomStep(delta > 0 and 1 or -1)
        end)
        blocker:SetScript("OnMouseUp", function(_, button)
            if button == "LeftButton" then
                -- 左键自己处理：方形的地图四角也要能打标记
                PingAtCursor(_G.Minimap)
                return
            end
            if button == "MiddleButton" then
                -- 中键 = 暴雪的追踪菜单（那个按钮已经在地图里了）。
                -- 不做"停在按钮上就让位"的判断：暴雪的这些按钮不用中键，
                -- 而中键按在追踪按钮上恰恰是最自然的"开追踪菜单"手势。
                OpenTrackingMenu()
                return
            end
            if button ~= "RightButton" then return end
            -- 停在按钮上时不弹菜单（暴雪按钮自己要用这个键）
            if M.buttons and M.buttons:IsOverButton() then return end
            if M.microMenu and Settings().microMenu then M.microMenu:Toggle(M.panel) end
        end)
        -- 区域名：悬停小地图才显示，平时藏起来
        blocker:HookScript("OnEnter", function() SetZoneTextVisible(true) end)
        blocker:HookScript("OnLeave", function() SetZoneTextVisible(false) end)
    end
    blocker:ClearAllPoints()
    -- 画布上下各有一条被裁掉的带子，覆盖层只铺**可见区**（落在那儿的位置地图上并不显示）。
    -- 偏移的符号：SetPoint 的 y 正值是**向上**。可见带是画布从上往下 33..223 行，
    -- 所以顶边要往下 33（-33）、底边要往上 33（+33）。原来两个符号都写反了，
    -- 覆盖层比可见带高出 66（322 单位），地图里那三个按钮也跟着跑到带子外面去了。
    blocker:SetPoint("TOPLEFT", minimap, "TOPLEFT", 0, -MASK_CROP)
    blocker:SetPoint("BOTTOMRIGHT", minimap, "BOTTOMRIGHT", 0, MASK_CROP)
    blocker:SetShown(active)

    -- 滚轮归覆盖层管（缩放地图），暴雪小地图自己那条要关掉 ——
    -- 否则两边都响应，同一个滚轮既缩地图又缩相机（Ellesmere 5424-5425 的做法）。
    if minimap.EnableMouseWheel then
        pcall(minimap.EnableMouseWheel, minimap, false)
    end

    if not zoneText then
        -- 区域名条画在覆盖层上（地图内部，中间靠上），不是面板的标题条
        zoneText = Widget:Font(blocker, 12, "pixel", "edge", "CENTER")
        zoneText:SetPoint("TOP", blocker, "TOP", 0, -6)
        -- 地图上是花背景，1px 阴影让字读得出来
        if zoneText.SetShadowOffset then zoneText:SetShadowOffset(1, -1) end
        zoneText:Hide()
    end
end

--- 打开暴雪的追踪菜单。
---
--- 追踪按钮我们已经搬进地图了（Modules/Minimap/Buttons.lua 的 SetupTracking），
--- 它是客户端的 DropdownButton，菜单由 Blizzard_Menu 的菜单系统开
--- （DropdownButtonMixin:OpenMenu → Menu.GetManager():OpenMenu），
--- 所以中键直接调它即可，不用自己画菜单。
--- 不同版本这个入口方法名不一样，逐个退路（OpenMenu → ToggleMenu → Click）。
function OpenTrackingMenu()
    local cluster = _G.MinimapCluster
    local btn = cluster and cluster.Tracking and cluster.Tracking.Button
    btn = btn or _G.MiniMapTrackingButton or _G.MiniMapTracking
    if not btn then return false end
    for _, name in ipairs({ "OpenMenu", "ToggleMenu", "Click" }) do
        local fn = btn[name]
        if type(fn) == "function" then
            if pcall(fn, btn) then return true end
        end
    end
    return false
end

--- 把暴雪自己的"点击 = 打标记"堵掉。
--- 左键由覆盖层接管（方形的四角也要能打标记），右键留给微型菜单，两边都不要再走
--- 暴雪那条只认圆内的路，否则会打两次标记 / 在地图上留下标记。
--- 只换 OnMouseUp 这一个脚本，原脚本留着（还原时放回去）。
local function SuppressClientPing(minimap)
    if pingSuppressed then return end
    if not minimap.GetScript or not minimap.SetScript then return end
    -- 我们自己打不了标记时不要接管（宁可让暴雪那条路照旧），免得点了没反应
    if not _G.GetCursorPosition or not minimap.PingLocation then return end
    local original = minimap:GetScript("OnMouseUp")
    if type(original) ~= "function" then return end
    minimap:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" or button == "RightButton" then return end
        return original(self, button)
    end)
    pingOriginal = original
    pingSuppressed = true
end

-- ------------------------------------------------------------------ 客户端重设遮罩

-- Restore() 自己会调 UpdateMinimapConfig() 请客户端还原遮罩，钩子不能把皮肤又套回去
local restoring    = false
local configHooked = false
local reskinQueued = false

--- 客户端每次换小地图形态都会走 MinimapClusterMixin:UpdateMinimapConfig
--- （Camelot/Minimap.lua:31：`rotateMinimap` 的 CVar 回调就注册在这里），它会：
---   minimap:SetMaskTexture(圆形图集)、MinimapContainer / MinimapBackdrop /
---   MinimapCompassTexture 全部 SetSize 回默认。
--- 我们装的矩形遮罩因此会失效，要等下次换区域才恢复 ——
--- 圆形图集套到 256×190 上就是椭圆 + 四角被切。
--- 所以钩一次：把重套皮排到下一帧（别在客户端自己的调用栈里改它的帧），战斗中照旧排队。
local function HookMinimapConfig()
    if configHooked then return end
    local cluster = _G.MinimapCluster
    if not cluster or type(cluster.UpdateMinimapConfig) ~= "function" then return end
    configHooked = true

    hooksecurefunc(cluster, "UpdateMinimapConfig", function()
        if restoring or not active or reskinQueued then return end
        reskinQueued = true
        local function reskin()
            reskinQueued = false
            if restoring or not active then return end
            if InCombatLockdown() then
                Queue("skin")
            else
                Skin()
            end
        end
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            C_Timer.After(0, reskin)
        else
            reskin()
        end
    end)
end

-- ------------------------------------------------------------------ HybridMinimap

-- 客户端自带的 Blizzard_HybridMinimap（LoD）：在"没有小地图地表贴图"的地图里，小地图不再
-- 用引擎渲染，改用世界地图的 MapCanvas 平铺（Blizzard_Minimap 在 PLAYER_ENTERING_WORLD 里按
-- `C_Minimap.ShouldUseHybridMinimap()` 决定 LoadAddOn + `HybridMinimap:Enable()`；
-- 源码见 Blizzard_HybridMinimap/Blizzard_HybridMinimap.lua）。
--
-- 它给画布套的是 XML 里的 `CircleMask`（`HybridMinimap.CircleMask`，帧内缩 3 的圆），
-- 在矩形皮肤里会把地图四角啃成圆的。这里改的是**这块遮罩自己的贴图**，不另建一块：
-- 同一个对象同时罩着 `HybridMinimap.Background`（黑底）和 `MapCanvas`（地图美术），
-- 换一次两边一起变；自建一块只套得住画布，地图画到边界外时角上会露出面板。
-- 做法同 BasicMinimap；差别是它接受"内缩 3"，我们把遮罩临时撑满整帧（可见带贴边），
-- 还原时按快照把贴图和锚点都放回去。
-- 它不是第三方插件，是客户端自己的机制，所以不提供开关：跟皮肤一起进退。

--- 换完贴图抖一次 use-mask（false → true），让画布把遮罩重新挂到贴图上。
--- BasicMinimap 同款：只 SetTexture 有客户端不刷新的记录；重复调用无副作用。
local function RefreshHybridMask(mapCanvas)
    pcall(mapCanvas.SetUseMaskTexture, mapCanvas, false)
    pcall(mapCanvas.SetUseMaskTexture, mapCanvas, true)
end

local hybridSaved   = nil     -- CircleMask 的原始贴图与锚点（只记一次）
local hybridApplied = false   -- 现在画布上装的是不是我们的遮罩（给 diagnose 用）

local function SaveHybridMask(hybrid)
    if hybridSaved or not hybrid.CircleMask then return end
    local mask = hybrid.CircleMask

    local points = {}
    if type(mask.GetNumPoints) == "function" and type(mask.GetPoint) == "function" then
        local ok, count = pcall(mask.GetNumPoints, mask)
        if ok and type(count) == "number" then
            for i = 1, count do
                local okPt, point, relTo, relPoint, x, y = pcall(mask.GetPoint, mask, i)
                if okPt then
                    points[#points + 1] = { point, relTo, relPoint, x, y }
                end
            end
        end
    end

    local okTex, texture = pcall(mask.GetTexture, mask)
    hybridSaved = {
        mask    = mask,
        texture = (okTex and type(texture) == "string" and texture)
                   or "Interface\\CharacterFrame\\TempPortraitAlphaMask",
        points  = points,
    }
end

local function ApplyHybrid()
    local hybrid = _G.HybridMinimap
    if not active or not hybrid or not hybrid.CircleMask or not hybrid.MapCanvas then return end
    if hybridApplied then return end

    SaveHybridMask(hybrid)
    local mask = hybridSaved.mask
    pcall(mask.SetTexture, mask, ns.Media:Texture("minimapRect"))
    -- XML 里这块遮罩是"帧内缩 3"的；矩形皮肤要贴满可见带，先撑满整帧
    pcall(mask.ClearAllPoints, mask)
    pcall(mask.SetAllPoints, mask, hybrid)
    RefreshHybridMask(hybrid.MapCanvas)

    hybridApplied = true
end

local function RestoreHybrid()
    local saved = hybridSaved
    if not hybridApplied or not saved then return end

    local mask = saved.mask
    pcall(mask.SetTexture, mask, saved.texture)
    if #saved.points > 0 then
        pcall(mask.ClearAllPoints, mask)
        for _, pt in ipairs(saved.points) do
            pcall(mask.SetPoint, mask, pt[1], pt[2], pt[3], pt[4], pt[5])
        end
    end

    local hybrid = _G.HybridMinimap
    if hybrid and hybrid.MapCanvas then RefreshHybridMask(hybrid.MapCanvas) end

    hybridApplied = false
end

-- ------------------------------------------------------------------ 区域名

--- 一个能安全比较的字符串。保密值不读、不比、不拼，只当作「没有拿到」。
local function PlainText(value)
    if type(value) ~= "string" then return nil end
    if Secrets.IsSecret(value) then return nil end
    if value == "" then return nil end
    return value
end

--- 当前区域名：先用客户端自己的小地图标题文本，退路是地图信息。
local function CurrentZoneName()
    if _G.GetMinimapZoneText then
        local ok, text = pcall(_G.GetMinimapZoneText)
        if ok then
            local plain = PlainText(text)
            if plain then return plain end
        end
    end
    local map = _G.C_Map
    if map and map.GetBestMapForUnit and map.GetMapInfo then
        local ok, mapID = pcall(map.GetBestMapForUnit, "player")
        if ok and type(mapID) == "number" then
            local okInfo, info = pcall(map.GetMapInfo, mapID)
            if okInfo and info then
                local plain = PlainText(info.name)
                if plain then return plain end
            end
        end
    end
    return nil
end

--- 战区 / 冲突区域时把区域名染成危险色。
local function PvPColor()
    if not Settings().zonePvPColor then return nil end
    local api = _G.C_PvP
    if not api or not api.GetZonePVPInfo then return nil end
    local ok, pvpType = pcall(api.GetZonePVPInfo)
    if not ok or Secrets.IsSecret(pvpType) then return nil end
    if pvpType == "war" or pvpType == "contested" then
        local r, g, b = ns.Color:GetDanger()
        return { r = r, g = g, b = b }
    end
    return nil
end

--- 刷新区域名的内容与颜色。
local function UpdateZoneText()
    if not zoneText then return end
    if not Settings().zoneText then
        zoneText:SetText("")
        zoneText:Hide()
        return
    end
    local name = CurrentZoneName()
    if name then zoneText:SetText(name) end
    local tint = PvPColor()
    Widget:ColorText(zoneText, tint or "edge")
end

--- 区域名条只在悬停小地图时出现（平时不占地图，也不挡视线）。
function SetZoneTextVisible(visible)
    if not zoneText then return end
    if visible and Settings().zoneText then
        zoneText:Show()
    else
        zoneText:Hide()
    end
end

-- ------------------------------------------------------------------ 面板

--- 主题面板。
--- 底边维持原样（地图可见区下沿再往下 4）；区域名不再占标题条，它画在地图内部
--- （悬停才出现），所以面板高度回到"地图 + 上下各 4"。
---
--- 面板画在**可见带**外面（每边 PANEL_PAD 个单位），边框固定 1 个物理像素：
--- 边框的粗细由 Widget:Theme 的 thickness 决定（物理像素 → UI 单位由 Media:Mult 换算），
--- 底色只露在地图与边框之间那一圈缝里。
local function EnsurePanel(minimap)
    if not panel then
        panel = Widget:CreateFrame("MonetUIMinimapPanel", UIParent,
            MAP_WIDTH + PANEL_PAD * 2, MAP_HEIGHT + PANEL_PAD * 2)
        panel:SetFrameStrata("BACKGROUND")
        panel:SetFrameLevel(1)
        panel:EnableMouse(false)
    end

    -- 边框固定 1 物理像素（不再跟着设置走）；底色给足，不然地图外面那一圈是"空的"。
    Widget:Theme(panel, { thickness = BORDER_PX, bgAlpha = 0.85, round = true })

    panel:ClearAllPoints()
    -- 可见区是画布中间那条带子（上下各裁 33），面板要对齐可见区而不是画布
    panel:SetPoint("BOTTOM", minimap, "BOTTOM", 0, MASK_CROP - PANEL_PAD)
    panel:SetShown(active)
    -- 发布出去，好让别的模块（任务追踪）对齐的是面板而不是画布：
    -- 画布每边比面板窄 4，人才看得见的那圈边框才是面板。
    M.panel = panel
end

-- ------------------------------------------------------------------ 快照 / 还原

--- 快照一切皮肤会动的东西，只做一次。
local function Remember(minimap)
    if original then return end

    local state = {
        mask = DEFAULT_MASK,
        objects = {},
    }
    if minimap.GetSize           then state.size    = { minimap:GetSize() } end
    if minimap.GetHitRectInsets  then state.hit     = { minimap:GetHitRectInsets() } end
    if minimap.GetClampRectInsets then state.clamp  = { minimap:GetClampRectInsets() } end
    if minimap.IsClampedToScreen then state.clamped = minimap:IsClampedToScreen() end
    -- 滚轮归我们管（覆盖层自己缩放地图），暴雪那条要关掉；还原时按原值放回去
    if minimap.IsMouseWheelEnabled then
        local ok, wheel = pcall(minimap.IsMouseWheelEnabled, minimap)
        if ok then state.wheel = wheel end
    end

    local cluster = _G.MinimapCluster
    if cluster and cluster.GetNumPoints then
        state.points = {}
        for i = 1, cluster:GetNumPoints() do
            local point, relTo, relPoint, x, y = cluster:GetPoint(i)
            state.points[#state.points + 1] = { point, relTo, relPoint, x, y }
        end
        -- 对齐基线要把它放开夹取（见 MoveCluster），还原时按原值放回
        if cluster.IsClampedToScreen then
            local ok, clamped = pcall(cluster.IsClampedToScreen, cluster)
            if ok then state.clusterClamped = clamped end
        end
    end

    original = state
end

--- 把默认小地图还回去：锚点、遮罩、尺寸、点击区、集群按钮、罗盘、GetMinimapShape。
--- 受保护的方法一律 pcall；失败（多半是战斗锁定）就记下来，脱战后再补。
function Restore()
    local state = original
    if not state then return end

    local failed = false
    local function try(ok) if not ok then failed = true end end

    for obj, saved in pairs(state.objects) do
        if saved.alpha ~= nil and obj.SetAlpha then try(pcall(obj.SetAlpha, obj, saved.alpha)) end
        if saved.shown ~= nil and obj.SetShown then try(pcall(obj.SetShown, obj, saved.shown)) end
    end

    local cluster = _G.MinimapCluster
    if cluster and state.points and #state.points > 0 then
        pcall(cluster.ClearAllPoints, cluster)
        for _, pt in ipairs(state.points) do
            try(pcall(cluster.SetPoint, cluster, pt[1], pt[2], pt[3], pt[4], pt[5]))
        end
    end
    if cluster and state.clusterClamped ~= nil and cluster.SetClampedToScreen then
        try(pcall(cluster.SetClampedToScreen, cluster, state.clusterClamped))
    end

    local minimap = _G.Minimap
    if minimap then
        -- 遮罩请客户端自己设回去：它知道自己的图集（也知道自己旋转模式下的底图）。
        -- 钩子会在这之后重套皮肤，所以先立 restoring 旗：这一次是"还原"，不是"重设"。
        if cluster and type(cluster.UpdateMinimapConfig) == "function" then
            restoring = true
            try(pcall(cluster.UpdateMinimapConfig, cluster))
            restoring = false
        else
            try(pcall(minimap.SetMaskTexture, minimap, state.mask))
        end
        if state.size then
            try(pcall(minimap.SetSize, minimap, state.size[1], state.size[2]))
        end
        if state.hit then
            try(pcall(minimap.SetHitRectInsets, minimap,
                      state.hit[1], state.hit[2], state.hit[3], state.hit[4]))
        end
        if state.clamp then
            try(pcall(minimap.SetClampRectInsets, minimap,
                      state.clamp[1], state.clamp[2], state.clamp[3], state.clamp[4]))
        end
        if state.clamped ~= nil then
            try(pcall(minimap.SetClampedToScreen, minimap, state.clamped))
        end
        if state.wheel ~= nil and minimap.EnableMouseWheel then
            try(pcall(minimap.EnableMouseWheel, minimap, state.wheel))
        end
        -- blob ring 的 scalar 没有 getter，按默认值 1 放回去（圆图时的取值）
        for _, method in ipairs({ "SetArchBlobRingScalar", "SetQuestBlobRingScalar" }) do
            if type(minimap[method]) == "function" then
                try(pcall(minimap[method], minimap, 1))
            end
        end
    end

    -- 还原那次有意的全局接管（只有真的接管过才动它）。
    RestoreShape()

    -- HybridMinimap 的矩形遮罩换回它自己的圆形遮罩
    RestoreHybrid()

    -- 右键打标记那条路放回去
    if pingSuppressed and minimap then
        pcall(minimap.SetScript, minimap, "OnMouseUp", pingOriginal)
        pingSuppressed = false
        pingOriginal = nil
    end

    -- 暴雪按钮搬回原来的父级，我们画的底板藏起来
    if M.buttons then M.buttons:Restore() end
    -- 被我们压掉的第三方 pin（遮罩档的带子裁剪）放回去
    if M.pins then M.pins:Restore() end
    if M.microMenu then M.microMenu:Close() end

    if failed then
        Queue("restore")
        WarnOnce("restore", "小地图还原未完全成功（可能处于战斗中），脱战后自动补做。")
    else
        original = nil
    end
end

-- ------------------------------------------------------------------ 主流程

function Skin()
    if not active then return false end
    local minimap = _G.Minimap
    if not minimap then return false end

    Remember(minimap)
    -- 客户端每次改小地图形态（rotateMinimap 开关）都会把遮罩换回圆形图集，
    -- 钩一次；集群晚于我们加载时这里会重试（HookMinimapConfig 自己幂等）。
    HookMinimapConfig()
    -- 先按目标尺寸重塑，再定位：MoveCluster 要实测 Minimap 的帧矩形，尺寸没设好量出来的是旧值。
    ReshapeMinimap(minimap)
    MoveCluster()
    ApplyShape()
    ApplyButtons()
    EnsurePanel(minimap)
    EnsureBlocker(minimap)
    SuppressClientPing(minimap)
    if M.buttons then M.buttons:Apply(blocker) end
    if M.pins then M.pins:Apply() end
    ApplyHybrid()
    UpdateZoneText()

    -- 记住的缩放级别（-1 = 没记过；第一次滚轮之后才有值）。
    -- 客户端自己会在换区域时把缩放复位，所以每次套用都把它按回去。
    local zoom = Settings().zoom
    if type(zoom) == "number" and zoom >= 0 and minimap.GetZoom and minimap.SetZoom then
        if minimap:GetZoom() ~= zoom then pcall(minimap.SetZoom, minimap, zoom) end
    end

    return true
end

function M:Initialize()
    -- 暴雪在换区域时会重排集群，皮肤要跟着重做。
    EventBus:Register("PLAYER_ENTERING_WORLD",   function() Skin() end)
    EventBus:Register("ZONE_CHANGED_NEW_AREA",   function() Skin() end)
    EventBus:Register("ZONE_CHANGED",            function()
        UpdateZoneText()
        if M.buttons then M.buttons:UpdateDifficulty() end
    end)
    EventBus:Register("ZONE_CHANGED_INDOORS",     function()
        UpdateZoneText()
        if M.buttons then M.buttons:UpdateDifficulty() end
    end)
    EventBus:Register("MONETUI_THEME_CHANGED",    function() if active then UpdateZoneText() end end)

    -- 战斗中受保护的方法被无声拒绝：脱战后按队列补做。
    EventBus:Register("PLAYER_REGEN_ENABLED", function()
        RunQueue()
    end)

    -- 客户端的 HybridMinimap 是按需 LoadAddOn 的：它一落地就把 MapCanvas 的遮罩
    -- 换成矩形的（模块没开时 ApplyHybrid 自己跳过，客户端保留自己的圆形遮罩）。
    EventBus:Register("ADDON_LOADED", function(_, addon)
        if addon == "Blizzard_HybridMinimap" then ApplyHybrid() end
    end)

    active = true
    Skin()
end

--- 运行时开关（配置面板 / `/mui minimap on|off`）。关掉是完整还原，不只是藏起面板。
function M:SetEnabled(enabled)
    active = enabled and true or false
    if active then
        Skin()
    else
        Restore()
    end
    if panel then panel:SetShown(active) end
    if blocker then blocker:SetShown(active) end
end

--- 别的模块在战斗里被拒了，排队等脱战补做（战斗队列只有一个出口，交给它统一排）。
function M:RequestSkin()
    Queue("skin")
end

--- 配置面板改完设置后调用：重新套用一遍（幂等）。
function M:Apply()
    if active then Skin() end
end

--- 给配置面板用的设置表。
function M:GetSettings()
    return Settings()
end

--- 模块当前是不是开着（子模块问这个用）。
function M:IsActive()
    return active
end

--- 可见带相对画布中心的上下边界（UI 单位，向上为正）。遮罩上下等宽，就是 ±MAP_HEIGHT/2（±95）。
--- 第三方 pin 离中心超出这两条线就落在被裁掉的带子里（看不见却还挂在地图上）。
function M:VisibleBand()
    local half = MASK_CANVAS / 2
    return half - MASK_CROP, MASK_CROP - half
end

--- 给配置面板用的按钮清单（key + 显示名），顺序即面板里的顺序。
function M:ButtonList()
    return BUTTONS
end

--- `/mui minimap diagnose`：逐条报暴雪帧名在本客户端是否存在。
function M:HandleCommand(rest)
    if rest ~= "diagnose" and rest ~= "diag" then return false end

    ns:Print("---- 小地图自检 ----")
    for _, entry in ipairs(BUTTONS) do
        local found, names = false, {}
        for _, path in ipairs(entry.paths) do
            if Resolve(path) then
                found = true
                names[#names + 1] = path
            end
        end
        if found then
            ns:Print(string.format("  %-16s |cff00ff00存在|r  %s", entry.key, table.concat(names, ", ")))
        else
            ns:Print(string.format("  %-16s |cffff6b6b缺失|r  （本客户端没有这个对象，已跳过）", entry.key))
        end
    end

    local minimap = _G.Minimap
    if minimap then
        local w, h = minimap:GetSize()
        local zoom = minimap.GetZoom and minimap:GetZoom() or "?"
        ns:Print(string.format("  地图 %d×%d，缩放 %s", w or 0, h or 0, tostring(zoom)))
        -- 视野半径（码）：改尺寸前后比这个数，就知道矩形视口是"各向异性"
        -- （横向能看更多世界、纵向更少）还是"被拉伸变形"（世界范围不变、地图被抻了）。
        local api = _G.C_Minimap
        if api and api.GetViewRadius then
            local ok, yards = pcall(api.GetViewRadius)
            if ok and type(yards) == "number" and not Secrets.IsSecret(yards) then
                ns:Print(string.format("  视野半径 %d 码（改尺寸前后比这个数）", math.floor(yards)))
            end
        end
        -- 命中区：暴雪的圆形小地图是**代码里判**的（Minimap.lua:141 的半径判断），
        -- 命中区一直是方的；我们只在遮罩方案下把看不见的上下两条裁掉。
        if minimap.GetHitRectInsets then
            local ok, l, r, t, b = pcall(minimap.GetHitRectInsets, minimap)
            if ok then
                ns:Print(string.format("  命中区内缩 左%d 右%d 上%d 下%d（裁掉看不见的带子）",
                    l or 0, r or 0, t or 0, b or 0))
            end
        end
    else
        ns:Print("  |cffff6b6bMinimap 不存在|r")
    end
    ns:Print("  手势：左键打标记（四角也算）· 中键追踪菜单 · 右键微型菜单 · 滚轮缩放")
    ns:Print(string.format("  形状：遮罩裁剪（画布 %d×%d，上下各裁 %d，可见 %d×%d）",
        MASK_CANVAS, MASK_CANVAS, MASK_CROP, MAP_WIDTH, MAP_HEIGHT))
    ns:Print(string.format("  客户端重设遮罩的钩子 %s（切 rotateMinimap 后形状应保持不变）",
        configHooked and "|cff00ff00已安装|r" or "|cffff6b6b未安装|r"))
    if M.pins and M.pins.Status then
        local found, hiding, pinsActive = M.pins:Status()
        if found then
            ns:Print(string.format("  第三方 pin：HBD 已接入，带子里压掉 %d / 活动 %d 个",
                hiding, pinsActive))
        else
            ns:Print("  第三方 pin：未检测到 HereBeDragons-Pins-2.0（没有要处理的）")
        end
    end
    local hybrid = _G.HybridMinimap
    if hybrid and hybrid.MapCanvas then
        ns:Print(string.format("  HybridMinimap：已加载（当前%s），画布遮罩 %s",
            hybrid:IsShown() and "显示中" or "未显示",
            hybridApplied and "已换成矩形" or "未接管（模块关着？）"))
    else
        ns:Print("  HybridMinimap：未加载（本区域不用它）")
    end
    ns:Print(string.format("  面板 %s，区域名 %s",
        panel and panel:IsShown() and "已显示" or "未显示",
        zoneText and zoneText:GetText() ~= "" and zoneText:GetText() or "空"))
    return true
end

ns:Register("Minimap", M)
