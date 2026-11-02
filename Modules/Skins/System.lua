-- Modules/Skins/System.lua
-- System windows: the loot window and group-loot rolls, static pop-ups, the game menu, the settings panel, the add-on list, and -- opt-in -- the drop-down menus and the tooltip.  Item buttons keep their icons.

local ADDON_NAME, ns = ...

local M    = ns.Skins

-- 旁表标记：**绝不往暴雪的框体 / 贴图 / 字体串上写字段**。
-- 本客户端把“插件写过字段的对象”判成脏的（实机：issecurevariable 在 NamePlate1UnitFrame 上唯一为 false 的键就是我们的
-- 标记，随后暴雪自己的 OnUpdate 就报 secret value / anchor family），所以标记一律走
-- Core.lua 的 ns:Mark / ns:Marked（以对象为弱键的旁表）。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

local Skin = ns.Skin

local LOOT_ARROWS = { "LootFramePrevPageButton", "LootFrameNextPageButton" }

local GROUP_LOOT_FRAMES = { "GroupLootFrame1", "GroupLootFrame2", "GroupLootFrame3", "GroupLootFrame4" }

local function SkinLoot()
    M:Dress("LootFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 }, rule = true, buttons = LOOT_ARROWS })
    -- The close button is handled by SkinWindow; the pager arrows above get the plate, then their glyphs.
    Skin:PageArrow(Skin:Need("LootFramePrevPageButton"), "left")
    Skin:PageArrow(Skin:Need("LootFrameNextPageButton"), "right")
    -- 老框架把滚动区挂在名字全局上，新框架挂在帧的成员上；短路取第一个，只有真找不到的那个才记账。
    local scroll = Skin:Need("LootFrame.LootFrameScrollFrame") or Skin:Need("LootFrameScrollFrame")
    if scroll then Skin:ScrollFrame(scroll) end

    M:Dress(GROUP_LOOT_FRAMES, { panel = { bgAlpha = 0.96 } })

    -- The rolling history window builds its entry buttons lazily on open（deep 的显示时补扫就是为它）.
    M:Dress("GroupLootHistoryFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true })
end

local POPUP_FRAMES = { "LFGListInviteDialog", "LFGInvitePopup" }
local READYCHECK_FRAMES = { "ReadyCheckFrame", "ReadyCheckListenerFrame" }
local NOTICE_FRAMES = { "QueueStatusFrame", "BNToastFrame" }

local function SkinPopups()
    -- 四个静态弹窗是运行期拼名字的：一次只处理确实存在的那个，按钮名同样过 Need 记账。
    for index = 1, 4 do
        local popup = Skin:Need("StaticPopup" .. index)
        if popup then
            M:Dress(popup, {
                panel = { bgAlpha = 0.97 },
                buttons = {
                    "StaticPopup" .. index .. "Button1",
                    "StaticPopup" .. index .. "Button2",
                    "StaticPopup" .. index .. "Button3",
                },
                control = { bgAlpha = 0.9 },
            })
        end
    end

    -- 数量拆分框：顶部金色条是帧自己的美术，去掉；内容（加减号、输入框）保留。
    M:Dress("StackSplitFrame", { panel = { bgAlpha = 0.97 }, deep = true })
    M:Dress({
        "StackSplitFrame.SingleItemSplitBackground",
        "StackSplitFrame.MultiItemSplitBackground",
    }, { as = "fade" })

    M:Dress(POPUP_FRAMES, { panel = { bgAlpha = 0.97 }, deep = true })
    M:Dress(READYCHECK_FRAMES, { panel = { bgAlpha = 0.97 }, deep = true })
    M:Dress(NOTICE_FRAMES, { panel = { bgAlpha = 0.97 } })
end

-- 老版本客户端（12.1.5 之前）的主菜单按钮还带这些全局名；本客户端已改成匿名按钮。
-- 名单留着只是为了旧客户端 / 方便对照，本客户端靠下面的子控件遍历命中。
local GAMEMENU_BUTTONS = {
    "GameMenuButtonContinue", "GameMenuButtonSettings", "GameMenuButtonMacros",
    "GameMenuButtonAddons", "GameMenuButtonLogout", "GameMenuButtonQuit",
    "GameMenuButtonExit", "GameMenuButtonStore",
}

-- 12.x 的主菜单按钮是**匿名 + 按需创建**的（`GameMenuButtonSettings` 这类全局名已经没有了）：
-- 名单式 `buttons` 一个都命中不了，而且这些按钮要等菜单打开时才建出来。所以：
--   1) 按子控件遍历（幂等，重复 Apply 只是一次查表）；
--   2) 再挂一个"每次显示补一遍"（M:HookShow 走轮询，不写暴雪脚本槽）。
-- 实机对照：改之前 11 个按钮全是 `128-RedButton-*` 三件套 atlas、alpha 1；改之后是
-- 我们的 1px 底板 + neutral 文字。
local function DressMenuButtons(frame)
    local ok, kids = pcall(function() return { frame:GetChildren() } end)
    if not ok then return end
    for i = 1, #kids do
        local child = kids[i]
        local okT, kind = pcall(child.GetObjectType, child)
        if okT and kind == "Button" then
            -- 主菜单按钮是大号（200×36）深底：文字用 "bright"（neutral 往白推的**中性**亮色），
            -- 默认的 neutral 在这一档尺寸上会读成"禁用"（实机：一眼看不出能不能点）。
            M:Dress(child, { as = "button", control = { textKey = "bright" } })
        end
    end
end

local function SkinGameMenu()
    local frame = Skin:Need("GameMenuFrame")
    if not frame then return end
    M:Dress(frame, { panel = { bgAlpha = 0.97 } })
    DressMenuButtons(frame)
    M:HookShow(frame, function() DressMenuButtons(frame) end)
end

local function SkinSettings()
    M:Dress("SettingsPanel", { window = true, inset = true, panel = { bgAlpha = 0.97 }, deep = true })
end

-- Edit Mode: the manager bar plus the three dialogs it opens.  Without this, moving a bar leaves you
-- staring at stock Blizzard chrome with no indication of what the click did.
local EDITMODE_DIALOGS = {
    "EditModeManagerFrame", "EditModeUnsavedChangesDialog", "EditModeLayoutDialog",
}

-- 管理条那两个按钮在不同构建里叫 Accept/Cancel 还是 AcceptChanges/CancelChanges，两份参考各说一种。
-- 两种拼法都列进名单：存在的那个被换肤，不存在的那个在账本留一行 ✗。实机跑一次 `/mui skins diagnose`
-- 就知道该删哪一个 —— 以前这里是"凭记忆猜一个，猜错就静默跳过"，屏幕上永远是原皮，谁也不知道为什么。
local EDITMODE_BUTTONS = {
    "EditModeManagerFrameAccept", "EditModeManagerFrameAcceptChanges",
    "EditModeManagerFrameCancel", "EditModeManagerFrameCancelChanges",
    "EditModeSystemSettingsDialogAccept", "EditModeSystemSettingsDialogCancel",
    "EditModeUnsavedChangesDialogOkay", "EditModeUnsavedChangesDialogCancel",
    "EditModeLayoutDialogSave", "EditModeLayoutDialogCancel",
}

local function SkinEditMode()
    M:Dress(EDITMODE_DIALOGS, { panel = { bgAlpha = 0.97 } })
    M:Dress(EDITMODE_BUTTONS, { as = "button" })
    -- 系统设置对话框的行由按钮池懒建，所以单独走 deep：显示时把行 / 滑块 / 滚动区补扫一遍。
    M:Dress("EditModeSystemSettingsDialog", { panel = { bgAlpha = 0.97 }, deep = true })
end

local function SkinAddonList()
    M:Dress("AddonList", {
        window = true,
        inset = true,
        panel = { bgAlpha = 0.97 },
        buttons = {
            "AddonListEnableAllButton", "AddonListDisableAllButton",
            "AddonList.EnableAllButton", "AddonList.DisableAllButton",
        },
    })
    local scroll = Skin:Need("AddonList.AddonListScrollFrame") or Skin:Need("AddonList.ScrollFrame")
    if scroll then Skin:ScrollFrame(scroll) end
    M:Dress({ "AddonListFilterButton", "AddonList.FilterButton" }, { as = "dropdown" })
end

--- NineSlice 面板（本客户端的 GameTooltip / ItemRefTooltip 都是这种）：边框和底色不是 backdrop，
--- 而是子框架 NineSlice 上各片贴图的顶点色 —— 对它们调 SetBackdropBorderColor 一点反应都没有，
--- 所以「鼠标提示边框」以前在这个客户端是空转的。返回 true 表示这个框架走的是这条线。
local function PaintNine(frame, nine)
    -- 提示框走了自绘 1px 背板（PlateTooltip）：暴雪这层只留**透明壳**，
    -- 尺寸/排版仍由它算，但视觉全交给我们的细边（它的边是厚贴图，改不了粗细）。
    -- 颜色和 frame alpha 一起归零：只清顶点色在某些情况下还会漏出贴图本身的边。
    if Marked(frame, "tooltipPlate") then
        nine:SetBorderColor(0, 0, 0, 0)
        nine:SetCenterColor(0, 0, 0, 0)
        if nine.SetAlpha then nine:SetAlpha(0) end
        return
    end

    local r, g, b = ns.Color:GetBorder()
    nine:SetBorderColor(r, g, b, 1)
    local ar, ag, ab = ns.Color:GetAmbient()
    nine:SetCenterColor(ar * 0.35, ag * 0.35, ab * 0.35, 0.95)
end

local function TintNineSlice(frame)
    local nine = frame and frame.NineSlice
    if not nine or type(nine.SetBorderColor) ~= "function" or type(nine.SetCenterColor) ~= "function" then
        return false
    end

    if not Marked(frame, "nineTint") then
        Mark(frame, "nineTint", true)

        local dr, dg, db, da = nine:GetBorderColor()
        local cr, cg, cb, ca = nine:GetCenterColor()
        local oldAlpha = nine.GetAlpha and nine:GetAlpha() or 1

        Skin:Record(function()
            if dr then nine:SetBorderColor(dr, dg, db, da) end
            if cr then nine:SetCenterColor(cr, cg, cb, ca) end
            if nine.SetAlpha then nine:SetAlpha(oldAlpha or 1) end
            Mark(frame, "nineTint", nil)
        end)

        -- 关掉美化后主题刷新还会跑，所以这里先问一句"这片框架现在还算被美化着吗"
        Skin:OnTheme(function()
            if Marked(frame, "nineTint") then PaintNine(frame, nine) end
        end)
    end

    PaintNine(frame, nine)
    return true
end

--- Recolour a frame's existing backdrop.  Menus and the tooltip already own a backdrop, so no backplate child is added; originals are recorded for rollback.
local function TintBackdrop(frame)
    if not frame or type(frame.SetBackdropBorderColor) ~= "function" then return end

    if not Marked(frame, "backdropTint") then
        Mark(frame, "backdropTint", true)

        local br, bg, bb, ba
        if type(frame.GetBackdropColor) == "function" then
            br, bg, bb, ba = frame:GetBackdropColor()
        end
        local dr, dg, db, da
        if type(frame.GetBackdropBorderColor) == "function" then
            dr, dg, db, da = frame:GetBackdropBorderColor()
        end

        Skin:Record(function()
            if frame.SetBackdropColor and br then frame:SetBackdropColor(br, bg, bb, ba) end
            if frame.SetBackdropBorderColor and dr then frame:SetBackdropBorderColor(dr, dg, db, da) end
            Mark(frame, "backdropTint", nil)
        end)

        Skin:OnTheme(function()
            if frame.SetBackdropBorderColor then
                local r, g, b = ns.Color:GetBorder()
                frame:SetBackdropBorderColor(r, g, b, 1)
            end
            if frame.SetBackdropColor then
                local ar, ag, ab = ns.Color:GetAmbient()
                frame:SetBackdropColor(ar * 0.35, ag * 0.35, ab * 0.35, 0.95)
            end
        end)
    end

    if frame.SetBackdropColor then
        local ar, ag, ab = ns.Color:GetAmbient()
        frame:SetBackdropColor(ar * 0.35, ag * 0.35, ab * 0.35, 0.95)
    end
    local r, g, b = ns.Color:GetBorder()
    frame:SetBackdropBorderColor(r, g, b, 1)
end

--- 面板底：先试 NineSlice（本客户端的提示框、下拉菜单都是这种），没有 NineSlice 才退回 backdrop。
local function TintPanel(frame)
    if not frame then return end
    if TintNineSlice(frame) then return end
    TintBackdrop(frame)
end

--- 现代 UIMenu：右键菜单（UnitPopup）/ 各种 CreateContextMenu / 下拉菜单本体。
---
--- 这套菜单**没有具名框体，也没有"打开"事件**：MenuUtil 现场拼一个 Menu 帧，关掉进池子复用。
--- 本仓不碰 MenuManager 的方法槽（hooksecurefunc 会被 tools/audit-taint.js 判成 HOOK-PROTECTED），
--- 所以照老规矩"轮询 + 旁表"：每 0.1 秒问一次当前打开的菜单，把没涂过的补一遍。
---
--- **12.x 的菜单是 assertsafe 包起来的（实机验证，2026-10-31）**：
---   `menu:CreateTexture()` / `menu:CreateFontString()` 直接被拒（**返回 nil**，同时把
---   "Use of function 'CreateTexture' is disallowed" 打到屏幕上）；菜单里 FontString 的
---   `SetFont` 同样被拒。所以**不能**给菜单加自己的 region、也**不用**换字体 ——
---   菜单文字挂的是 GameFontHighlight 这类 font object，早被"统一字体"面板换过了
---   （实机读到的是 LXGWWenKai 15px）。
--- 能做的只有两件事：改**已有 region 的颜色**，以及挂一个**我们自己的子框体**当底板。
---
--- 12.1.5 实机结构：
---   menu 自身只有一个 region = 底衬贴图（atlas `common-dropdown-bg`，ARTWORK，alpha 0.93）
---   子级：0x0 的内容锚、MinimalScrollBar（`minimal-scrollbar-*` 系列 atlas）、标题 Frame、元素 Button
---   元素 Button：一块 BACKGROUND 贴图（白）+ 一个 FontString（GameFontHighlight）
---   层级：menu 501，元素按钮 521 —— 子框体取 menu 的等级时**画在按钮下面**（实测）。
local MENU_POLL = 0.1
local menuThemeGen = 0
Skin:OnTheme(function() menuThemeGen = menuThemeGen + 1 end)

--- 当前打开的菜单；没有（或这套客户端的 Menu 结构不一样）就是 nil。
local function OpenMenu()
    local manager = _G.Menu and _G.Menu.GetManager and _G.Menu.GetManager()
    if not manager or type(manager.GetOpenMenu) ~= "function" then return nil end
    local ok, menu = pcall(manager.GetOpenMenu, manager)
    if ok then return menu end
end

local function RegionsOf(obj)
    if type(obj.GetRegions) ~= "function" then return nil end
    local ok, list = pcall(function() return { obj:GetRegions() } end)
    if ok then return list end
end

local function RegionKind(rgn)
    local ok, kind = pcall(rgn.GetObjectType, rgn)
    if ok then return kind end
end

--- 我们自己的底板：CreateFrame 是全局函数（不在 assertsafe 名单里），子框体可以建；
--- 等级取 menu 自己的，于是它画在暴雪的底衬之上、元素按钮（521）之下 —— 实机截图验过。
--- 建过一次就记住，池化复用同一帧时跟着 SetAllPoints 自己变大变小。
local function MenuPlate(menu, s)
    if s.plate then return s.plate end
    local plate = CreateFrame("Frame", nil, menu, "BackdropTemplate")
    plate:SetAllPoints(menu)
    plate:SetFrameLevel(menu:GetFrameLevel())
    pcall(plate.EnableMouse, plate, false)
    ns.Widget:Theme(plate, { thickness = 1, bgAlpha = 0.97 })
    s.plate = plate
    return plate
end

--- 暴雪底衬是圆角 atlas 图：藏掉它（SetAlpha 允许），让我们的方角底板露出来。
--- 它每次打开会重贴一次 atlas，所以每拍比一次 alpha（一次读，平时零成本）。
--- **只在底板真的建起来之后才藏**，否则菜单会整体透明（看不见任何东西）。
local function HideMenuBody(s)
    local tex = s.body
    if not tex or not s.plate then return end
    local okA, alpha = pcall(tex.GetAlpha, tex)
    if okA and alpha == 0 then return end
    pcall(tex.SetAlpha, tex, 0)
end

local function MenuButtonTint(btn, hovered)
    local s = Marked(btn, "menuButton")
    if not s or not s.bg then return end
    local r, g, b
    if hovered then
        r, g, b = ns.Color:GetHighlight()
    else
        r, g, b = ns.Color:GetSurface("fill")
    end
    pcall(s.bg.SetVertexColor, s.bg, r, g, b, hovered and 0.9 or 0.45)
end

--- 一个菜单元素按钮：底衬贴图（本来就是白的）染我们的按钮色。
--- 悬停走 Widget:HoverWatch（**绝不挂 OnEnter**：那是往暴雪框的脚本槽写我们的函数）。
local function StyleMenuButton(btn, force)
    local s = Marked(btn, "menuButton")
    if s and not force then return s end
    if not s then
        s = {}
        Mark(btn, "menuButton", s)
        local list = RegionsOf(btn) or {}
        for i = 1, #list do
            local rgn = list[i]
            local kind = RegionKind(rgn)
            if kind == "Texture" then
                local okL, layer = pcall(rgn.GetDrawLayer, rgn)
                if okL and layer == "BACKGROUND" and not s.bg then
                    -- 白色模具 + 顶点色：暴雪之后自己改色也能被我们的轮询顶回来。
                    s.bg = rgn
                    pcall(rgn.SetColorTexture, rgn, 1, 1, 1, 1)
                end
            elseif kind == "FontString" then
                s.text = rgn
            end
        end
        ns.Widget:HoverWatch(btn, function(self) MenuButtonTint(self, true) end,
                                 function(self) MenuButtonTint(self, false) end)
    end
    MenuButtonTint(btn, false)
    if s.text then
        -- 字体不能换（assertsafe 拒 SetFont），只改颜色。
        local r, g, b = ns.Color:Get("neutral")
        pcall(s.text.SetTextColor, s.text, r, g, b, 1)
    end
    return s
end

--- 标题 / 分隔线这类非按钮子控件：字体已经被"统一字体"换过，这里只补颜色。
local function StyleMenuTexts(node)
    local list = RegionsOf(node) or {}
    for i = 1, #list do
        local rgn = list[i]
        if RegionKind(rgn) == "FontString" then
            local r, g, b = ns.Color:Get("neutral")
            pcall(rgn.SetTextColor, rgn, r, g, b, 1)
        end
    end
end

--- 菜单滚动条（MinimalScrollBar）：轨道与箭头都是 atlas，染主题色即可，不换图。
local function TintMenuScroll(node, depth)
    local list = RegionsOf(node) or {}
    for i = 1, #list do
        local rgn = list[i]
        if RegionKind(rgn) == "Texture" then
            local okA, atlas = pcall(rgn.GetAtlas, rgn)
            if okA and type(atlas) == "string" and atlas:find("scrollbar") then
                local r, g, b = ns.Color:GetBorder()
                pcall(rgn.SetVertexColor, rgn, r, g, b, 0.55)
            end
        end
    end
    if (depth or 0) >= 2 then return end
    local ok, kids = pcall(function() return { node:GetChildren() } end)
    for i = 1, #(ok and kids or {}) do
        TintMenuScroll(kids[i], (depth or 0) + 1)
    end
end

local function DressMenu(menu)
    local s = Marked(menu, "menuSkin")
    if not s then
        s = { gen = -1 }
        Mark(menu, "menuSkin", s)
        local list = RegionsOf(menu) or {}
        for i = 1, #list do
            if RegionKind(list[i]) == "Texture" then
                s.body = list[i]
                break
            end
        end
    end

    HideMenuBody(s)
    if s.gen ~= menuThemeGen then
        s.gen = menuThemeGen
        MenuPlate(menu, s)     -- 建一次；换主题时回来重上色
        if s.plate then
            ns.Widget:Refresh(s.plate)
            HideMenuBody(s)    -- 底板有了才敢把暴雪的圆角底衬藏掉
        end
    end

    -- 菜单是池化复用的：同一帧重新打开会换一批元素（数量/高度都变）。
    -- 拿"子控件数 + 高度"当签名，变了才整轮重刷 —— 平时每拍只多一次比较。
    local ok, kids = pcall(function() return { menu:GetChildren() } end)
    if not ok then return end
    local height = 0
    local okH, h = pcall(menu.GetHeight, menu)
    if okH and type(h) == "number" then height = math.floor(h + 0.5) end
    local sig = #kids .. "x" .. height
    if s.sig == sig then return end
    s.sig = sig

    for i = 1, #kids do
        local child = kids[i]
        local kind = RegionKind(child)
        if kind == "Button" then
            StyleMenuButton(child, true)
        elseif kind == "Frame" then
            StyleMenuTexts(child)
            TintMenuScroll(child, 0)
        end
    end
end

--- 把现代菜单接上：一个 UIParent 上的轮询，覆盖右键菜单 / 上下文菜单 / 下拉菜单本体。
local function WatchModernMenus(anchor)
    if not _G.Menu or not _G.Menu.GetManager then return end
    ns.Widget:PollWatch(anchor, function()
        local menu = OpenMenu()
        if menu then DressMenu(menu) end
    end, MENU_POLL)
end

local function SkinMenus()
    local up = Skin:Need("UIParent")
    if not up or Marked(up, "menuPoll") then return end
    Mark(up, "menuPoll", true)
    -- 不再 hooksecurefunc("UIDropDownMenu_CreateFrames")（全局函数钩子 = 污染，见 AGENTS）。
    -- 改成轮询：每 0.5 秒把可见的下拉列表重新染一遍（只染显示中的，成本可忽略）。
    ns.Widget:PollWatch(up, function()
        for level = 1, 8 do
            local list = _G["DropDownList" .. level]
            if list and list.IsShown and list:IsShown() then TintPanel(list) end
            for menu = 1, 8 do
                local sub = _G["DropDownList" .. level .. "Menu" .. menu]
                if sub and sub.IsShown and sub:IsShown() then TintPanel(sub) end
            end
        end
    end)
    WatchModernMenus(up)
end

local PaintTooltipPlate      -- 前向声明：下面的轮询要用它（定义在本文件后面）

--- 提示框的九宫格颜色每次隐藏都会被 GameTooltip_ClearStyle 刷回暴雪默认值
--- （GameTooltipDataMixin:OnHide → SharedTooltip_SetBackdropStyle(self, nil)），只在登录时染一次等于没染。
--- 挂到那个函数上补一刀：只补「默认样式」；暴雪自己的特殊样式（符文锻造金、腐化紫、Azerite）保留原样。
local tooltipStyleWatched = false
local function WatchTooltipStyle()
    if tooltipStyleWatched or type(Skin:Need("SharedTooltip_SetBackdropStyle")) ~= "function" then return end
    tooltipStyleWatched = true

    -- 不再 hooksecurefunc("SharedTooltip_SetBackdropStyle")（全局函数钩子 = 污染）：
    -- 改成轮询——提示框显示期间每 0.2 秒补一次九宫格染色。暴雪自己换特殊样式
    -- （符文锻造金 / 腐化紫 / Azerite）时，Mark 里的 nineTint 仍在，但颜色会被它覆盖，
    -- 所以这里只在"还是我们标记过的那个框"时补色。
    local tip = Skin:Need("GameTooltip")
    if tip then
        ns.Widget:PollWatch(tip, function(self)
            if not self:IsShown() then return end
            if Marked(self, "nineTint") then TintNineSlice(self) end
            -- **背板也要补**：那个"刷回默认"是遍历 regions 染顶点色的，我们自己画的底和
            -- 四条边一起被刷成纯白（实机 2026-11-01 探针：our.bg = 1,1,1,1，而九宫格是透明的），
            -- 于是光环提示的边框看起来完全是暴雪样式。
            if Marked(self, "tooltipPlate") then PaintTooltipPlate(self, true) end
        end)
    end
end

--- 提示框的 1px 边：**直接画在提示框自己的贴图槽上**（4 条边 + 一块底），
--- 不走 SetBackdrop 的 edgeFile —— 这台客户端的 edgeFile 只吃 BLP，TGA/WHITE8X8 那条路
--- 在子框上有时整条不显示（实机就发生过"边框还是没有"）。画成提示框自己的 region 最稳：
--- BACKGROUND(-8) 的底 + BORDER 层的四条线，都在文字下面，也不吃鼠标。
--- 这里是给上面 `local PaintTooltipPlate` 那条**前向声明**赋值（`function Name(...)`
--- 等价于 `Name = function(...)`，Name 是作用域里的 local）—— 上面的 WatchTooltipStyle
--- 已经引用了它，顺序不能反：写成全局同名会让那个 local 永远是 nil，轮询里每拍抛错、
--- 被 pcall 吞掉，表面现象就是"背板不补色"。
--- @param colorsOnly 只重染颜色、不动锚点（轮询路径用：每 0.2 秒 ClearAllPoints+SetPoint 没必要，
---                    还可能和暴雪自己的排版抢一帧）。
function PaintTooltipPlate(tip, colorsOnly)
    local s = Marked(tip, "tooltipEdges")
    if not s then return end

    local px = 1 * (ns.Media:Mult() or 1)          -- 1 物理像素
    local r, g, b = ns.Color:GetBorder()           -- 主题边框槽（默认 edge）
    local ar, ag, ab = ns.Color:GetAmbient()

    s.bg:SetColorTexture(ar * 0.35, ag * 0.35, ab * 0.35, 0.95)

    local top, bottom, left, right = s.top, s.bottom, s.left, s.right
    if not colorsOnly then
        top:ClearAllPoints()
        top:SetPoint("TOPLEFT", tip, "TOPLEFT", 0, 0)
        top:SetPoint("TOPRIGHT", tip, "TOPRIGHT", 0, 0)
        top:SetHeight(px)
        bottom:ClearAllPoints()
        bottom:SetPoint("BOTTOMLEFT", tip, "BOTTOMLEFT", 0, 0)
        bottom:SetPoint("BOTTOMRIGHT", tip, "BOTTOMRIGHT", 0, 0)
        bottom:SetHeight(px)
        left:ClearAllPoints()
        left:SetPoint("TOPLEFT", tip, "TOPLEFT", 0, 0)
        left:SetPoint("BOTTOMLEFT", tip, "BOTTOMLEFT", 0, 0)
        left:SetWidth(px)
        right:ClearAllPoints()
        right:SetPoint("TOPRIGHT", tip, "TOPRIGHT", 0, 0)
        right:SetPoint("BOTTOMRIGHT", tip, "BOTTOMRIGHT", 0, 0)
        right:SetWidth(px)
    end

    top:SetColorTexture(r, g, b, 1)
    bottom:SetColorTexture(r, g, b, 1)
    left:SetColorTexture(r, g, b, 1)
    right:SetColorTexture(r, g, b, 1)
end

local function PlateTooltip(tip)
    if not tip or Marked(tip, "tooltipPlate") then return end
    if not tip.NineSlice then return end    -- 没有九宫格的框（老客户端 / 别的窗口）不套这一层

    Mark(tip, "tooltipPlate", true)

    local s = {}
    s.bg     = tip:CreateTexture(nil, "BACKGROUND", nil, -8)
    s.bg:SetAllPoints(tip)
    s.top    = tip:CreateTexture(nil, "BORDER")
    s.bottom = tip:CreateTexture(nil, "BORDER")
    s.left   = tip:CreateTexture(nil, "BORDER")
    s.right  = tip:CreateTexture(nil, "BORDER")
    Mark(tip, "tooltipEdges", s)

    -- 关掉「鼠标提示边框」时收走（这些是我们自己的贴图，记录里只做 Hide）
    Skin:Record(function()
        s.bg:Hide(); s.top:Hide(); s.bottom:Hide(); s.left:Hide(); s.right:Hide()
        Mark(tip, "tooltipEdges", nil)
        Mark(tip, "tooltipPlate", nil)
    end)

    -- 主题换了跟着重染（关掉美化后 Mark 没了，这里自然什么都不做）
    Skin:OnTheme(function()
        if Marked(tip, "tooltipPlate") then PaintTooltipPlate(tip) end
    end)

    PaintTooltipPlate(tip)
end

local function SkinTooltip()
    -- 先立背板：PaintNine 看到 tooltipPlate 标记就把暴雪那层刷成透明
    local tip = Skin:Need("GameTooltip")
    PlateTooltip(tip)
    TintPanel(tip)
    WatchTooltipStyle()

    -- ItemRefTooltip is the *separate* frame a ctrl-clicked item link opens in.  It has its own
    -- chrome and its own close button and nothing in the game touches either, so every item link the
    -- player inspects shows stock Blizzard chrome even when the tooltip option is on.
    local ref = Skin:Need("ItemRefTooltip")
    if ref then
        PlateTooltip(ref)
        TintPanel(ref)
        if ref.CloseButton then Skin:CloseButton(ref.CloseButton) end
    end
end

-- 下面这些面板的 frames 名单一律直接引用代码里那份表（M:Panel 会展平嵌套表），不再手抄第二遍：
-- 抄一遍就会漂（本轮就抓到 EditModeManager / AcceptChanges / MacroEditBox 三处名单和代码不一致）。
-- 闸门 tools/check-frame-list.js 会把表名解析回具体字符串再核对取用路径。
M:Panel("loot", { label = "拾取 / 掷骰", group = "系统", apply = SkinLoot,
    frames = {
        "LootFrame", "LootFrameCloseButton", "LootFrame.LootFrameScrollFrame",
        LOOT_ARROWS, GROUP_LOOT_FRAMES, "GroupLootHistoryFrame",
    } })

M:Panel("popups", { label = "确认弹窗", group = "系统", apply = SkinPopups,
    frames = {
        "StaticPopup1", "StaticPopup1Button1", "StaticPopup1Button2",
        "StaticPopup2", "StaticPopup2Button1",
        "StaticPopup3", "StaticPopup3Button1",
        "StaticPopup4", "StaticPopup4Button1",
        "StackSplitFrame",
        POPUP_FRAMES, READYCHECK_FRAMES, NOTICE_FRAMES,
    } })

M:Panel("gamemenu", { label = "游戏菜单", group = "系统", apply = SkinGameMenu,
    frames = { "GameMenuFrame", GAMEMENU_BUTTONS } })

M:Panel("settings", { label = "设置面板", group = "系统", apply = SkinSettings,
    frames = { "SettingsPanel", "SettingsPanel.CloseButton" } })

M:Panel("editmode", { label = "编辑模式", group = "系统", apply = SkinEditMode,
    frames = { EDITMODE_DIALOGS, EDITMODE_BUTTONS } })

M:Panel("addonlist", { label = "插件列表", group = "系统", apply = SkinAddonList,
    frames = {
        "AddonList", "AddonList.AddonListScrollFrame", "AddonList.ScrollFrame",
        "AddonListEnableAllButton", "AddonListDisableAllButton",
        "AddonList.EnableAllButton", "AddonList.DisableAllButton",
        "AddonListFilterButton", "AddonList.FilterButton",
    } })

M:Panel("menus", { label = "菜单 / 右键菜单", group = "系统", apply = SkinMenus, default = true,
    -- 老式下拉：DropDownList1..8 / DropDownListNMenu1..8 全在轮询回调里由 level、menu 两个循环变量
    -- 拼出来；现代 UIMenu（右键菜单 / 上下文菜单）没有名字，从 Menu.GetManager():GetOpenMenu() 拿。
    -- 静态列得出来的只有承载轮询的 UIParent。
    frames = { "UIParent" } })

M:Panel("tooltip", { label = "鼠标提示边框", group = "系统", apply = SkinTooltip, default = true,
    -- Same for ItemRefTooltipCloseButton: reached as ref.CloseButton (a member), not a global.
    frames = { "GameTooltip", "ItemRefTooltip" } })

-- 宏编辑器：Blizzard_MacroUI 无 game-type 门控（wow-ui-source forever 分支），本客户端存在。
-- 图标选择弹窗（MacroPopupFrame）是独立的 LoD 窗口，名字/图标网格是内容，不动。
local function SkinMacroPopup()
    local popup = Skin:Need("MacroPopupFrame")
    if not popup or Marked(popup, "macroPopupSkinned") then return end
    Mark(popup, "macroPopupSkinned", true)
    M:Dress(popup, { window = true, panel = { bgAlpha = 0.97 }, deep = true })
end

local function SkinMacros()
    local frame = Skin:Need("MacroFrame")
    if not frame then return end

    M:Dress(frame, {
        window = true,
        inset = true,
        panel = { bgAlpha = 0.96 },
        deep = true,
        tabs = { "MacroFrameTab1", "MacroFrameTab2" },
    })
    -- 编辑区两种拼法都见过；短路取第一个存在的，另一个才记账为缺失。
    local box = Skin:Need("MacroFrameEditBox") or Skin:Need("MacroEditBox")
    if box then Skin:EditBox(box) end

    -- MacroPopupFrame 是点"选图标"时才创建的：那时主窗口一定开着，所以挂在主窗口的
    -- PollWatch 上等它出现（主窗口关着时轮询不跑，零成本）。
    -- 轮询回调跑在 Apply 之外，作用域得自己带上，否则账目会落到 "_" 名下。
    Skin.With("macros", SkinMacroPopup)
    ns.Widget:PollWatch(frame, function() Skin.With("macros", SkinMacroPopup) end)
end

M:Panel("macros", { label = "宏编辑器", group = "系统", apply = SkinMacros,
    addons = { Blizzard_MacroUI = true },
    frames = {
        "MacroFrame", "MacroFrameTab1", "MacroFrameTab2",
        "MacroFrameEditBox", "MacroEditBox",
        "MacroPopupFrame",
    } })

-- 时钟 / 秒表：Blizzard_TimeManager 带 camelot 专属覆写文件（Camelot\Blizzard_TimeManagerOverrides.lua）。
-- 秒表是独立小窗（StopwatchFrame）。两者的关闭按钮都挂在帧自己身上（成员，不是全局名），
-- M:Dress 的 window 档会依次试 frame.CloseButton → BorderFrame.CloseButton → name.."CloseButton"。
local function SkinTimeManager()
    -- 标题线：这个窗口的 TitleText 矩形比字形小（按底边锚会穿过"时钟"两个字），所以用固定偏移。
    -- 2026-10-31 实机确认：ruleTop = 26 时线正好落在标题下方。
    M:Dress({ "TimeManagerFrame", "StopwatchFrame" },
        { window = true, panel = { bgAlpha = 0.96 }, deep = true, rule = true, ruleTop = 26 })
    -- 全局名不带 Frame 后缀，M:SkinWindow 的 name.."CloseButton" 推导够不到，显式接一次。
    Skin:CloseButton(Skin:Need("TimeManagerCloseButton"))
end

M:Panel("timemanager", { label = "时钟 / 秒表", group = "系统", apply = SkinTimeManager,
    addons = { Blizzard_TimeManager = true },
    frames = { "TimeManagerFrame", "TimeManagerFrame.CloseButton",
        "TimeManagerCloseButton", "StopwatchFrame" } })

-- 帮助 / 客服：Blizzard_HelpFrame 是 AllowLoad: Game。
local function SkinHelp()
    M:Dress("HelpFrame", { window = true, inset = true, panel = { bgAlpha = 0.96 }, deep = true, rule = true })
end

M:Panel("help", { label = "帮助", group = "系统", apply = SkinHelp,
    addons = { Blizzard_HelpFrame = true },
    frames = { "HelpFrame", "HelpFrame.CloseButton" } })

-- 拾色器：设置面板等处弹出，无门控。12.1.5 正式服按钮是 Footer 成员 + Okay/Cancel 全局名两套并存。
local function SkinColorPicker()
    M:Dress("ColorPickerFrame", {
        window = true,
        panel = { bgAlpha = 0.97 },
        buttons = {
            "ColorPickerFrameOkay", "ColorPickerFrameCancel",
            "ColorPickerFrame.Footer.OkayButton", "ColorPickerFrame.Footer.CancelButton",
        },
    })
end

M:Panel("colorpicker", { label = "拾色器", group = "系统", apply = SkinColorPicker,
    frames = { "ColorPickerFrame", "ColorPickerFrameOkay", "ColorPickerFrameCancel",
        "ColorPickerFrame.Footer.OkayButton", "ColorPickerFrame.Footer.CancelButton" } })

-- 呼吸 / 疲劳 / 溺水条：暴雪自建的三条（MirrorTimerContainer.mirrorTimers[1..3]），
-- 每条的结构是 .StatusBar（真 StatusBar）+ .Border（美术边框）+ .Text —— 字段名按本客户端
-- 校准（Aurora 的 Blizzard_MirrorTimer 皮肤走的就是 `.StatusBar`，它是 isRetail 分支）。
-- 只换填充和边框，尺寸 / 位置一概不动（它在编辑模式里有自己的位置）。
-- 颜色**保留暴雪自己的**（呼吸=蓝、疲劳=紫、火=橙）：那是语义，不是装饰。
-- 复检是必须的：每次计时启动暴雪都会重设填充，静态换肤会被顶掉（Widget:StatusBar 内置轮询）。
local function SkinMirrorTimer()
    local container = Skin:Need("MirrorTimerContainer")
    local timers = container and container.mirrorTimers
    if not timers then return end
    for index = 1, 3 do
        local timer = timers[index]
        if timer then
            Skin:Fade(timer.Border)
            if timer.StatusBar then
                ns.Widget:StatusBar(timer.StatusBar)
                -- 计时框平时是隐藏的，而轮询对隐藏框不跑：暴雪在启动计时时会把填充换回去，
                -- 那一刻没人看得见，等它显示出来又是一条暴雪的填充。用"显示"这个跳变补一次。
                ns.Widget:ShowWatch(timer, function()
                    ns.Widget:ReapplyBar(timer.StatusBar)
                end)
            end
        end
    end
end

M:Panel("mirrortimer", { label = "呼吸 / 疲劳条", group = "系统", apply = SkinMirrorTimer,
    frames = { "MirrorTimerContainer" } })
