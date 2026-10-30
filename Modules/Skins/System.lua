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
    M:Dress("LootFrame", { window = true, panel = { bgAlpha = 0.96 }, buttons = LOOT_ARROWS })
    -- The close button is handled by SkinWindow; the pager arrows above get the plate, then their glyphs.
    Skin:PageArrow(Skin:Need("LootFramePrevPageButton"), "left")
    Skin:PageArrow(Skin:Need("LootFrameNextPageButton"), "right")
    -- 老框架把滚动区挂在名字全局上，新框架挂在帧的成员上；短路取第一个，只有真找不到的那个才记账。
    local scroll = Skin:Need("LootFrame.LootFrameScrollFrame") or Skin:Need("LootFrameScrollFrame")
    if scroll then Skin:ScrollFrame(scroll) end

    M:Dress(GROUP_LOOT_FRAMES, { panel = { bgAlpha = 0.96 } })

    -- The rolling history window builds its entry buttons lazily on open（deep 的显示时补扫就是为它）.
    M:Dress("GroupLootHistoryFrame", { window = true, panel = { bgAlpha = 0.96 }, deep = true })
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

local GAMEMENU_BUTTONS = {
    "GameMenuButtonContinue", "GameMenuButtonSettings", "GameMenuButtonMacros",
    "GameMenuButtonAddons", "GameMenuButtonLogout", "GameMenuButtonQuit",
    "GameMenuButtonExit", "GameMenuButtonStore",
}

local function SkinGameMenu()
    M:Dress("GameMenuFrame", { panel = { bgAlpha = 0.97 }, buttons = GAMEMENU_BUTTONS })
end

local function SkinSettings()
    M:Dress("SettingsPanel", { window = true, panel = { bgAlpha = 0.97 }, deep = true })
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
end

--- 提示框的九宫格颜色每次隐藏都会被 GameTooltip_ClearStyle 刷回暴雪默认值
--- （GameTooltipDataMixin:OnHide → SharedTooltip_SetBackdropStyle(self, nil)），只在登录时染一次等于没染。
--- 挂到那个函数上补一刀：只补「默认样式」；暴雪自己的特殊样式（符文锻造金、腐化紫、Azerite）保留原样。
local tooltipStyleWatched = false
local function WatchTooltipStyle()
    if tooltipStyleWatched or type(Skin:Need("SharedTooltip_SetBackdropStyle")) ~= "function" then return end
    tooltipStyleWatched = true

    -- 不再 hooksecurefunc("SharedTooltip_SetBackdropStyle")（全局函数钩子 = 污染）：
    -- 改成轮询——提示框显示期间每 0.5 秒补一次九宫格染色。暴雪自己换特殊样式
    -- （符文锻造金 / 腐化紫 / Azerite）时，Mark 里的 nineTint 仍在，但颜色会被它覆盖，
    -- 所以这里只在"还是我们标记过的那个框"时补色。
    local tip = Skin:Need("GameTooltip")
    if tip then
        ns.Widget:PollWatch(tip, function(self)
            if not self:IsShown() then return end
            if Marked(self, "nineTint") then TintNineSlice(self) end
        end)
    end
end

--- 提示框的 1px 边：**直接画在提示框自己的贴图槽上**（4 条边 + 一块底），
--- 不走 SetBackdrop 的 edgeFile —— 这台客户端的 edgeFile 只吃 BLP，TGA/WHITE8X8 那条路
--- 在子框上有时整条不显示（实机就发生过"边框还是没有"）。画成提示框自己的 region 最稳：
--- BACKGROUND(-8) 的底 + BORDER 层的四条线，都在文字下面，也不吃鼠标。
local function PaintTooltipPlate(tip)
    local s = Marked(tip, "tooltipEdges")
    if not s then return end

    local px = 1 * (ns.Media:Mult() or 1)          -- 1 物理像素
    local r, g, b = ns.Color:GetBorder()           -- 主题边框槽（默认 edge）
    local ar, ag, ab = ns.Color:GetAmbient()

    s.bg:SetColorTexture(ar * 0.35, ag * 0.35, ab * 0.35, 0.95)

    local top, bottom, left, right = s.top, s.bottom, s.left, s.right
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

M:Panel("menus", { label = "下拉菜单", group = "系统", apply = SkinMenus, default = false,
    -- DropDownList1..8 / DropDownListNMenu1..8 全在轮询回调里由 level、menu 两个循环变量拼出来，
    -- 静态列不出来；能确认的只有承载轮询的 UIParent。
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
    M:Dress({ "TimeManagerFrame", "StopwatchFrame" },
        { window = true, panel = { bgAlpha = 0.96 }, deep = true })
    -- 全局名不带 Frame 后缀，M:SkinWindow 的 name.."CloseButton" 推导够不到，显式接一次。
    Skin:CloseButton(Skin:Need("TimeManagerCloseButton"))
end

M:Panel("timemanager", { label = "时钟 / 秒表", group = "系统", apply = SkinTimeManager,
    addons = { Blizzard_TimeManager = true },
    frames = { "TimeManagerFrame", "TimeManagerFrame.CloseButton",
        "TimeManagerCloseButton", "StopwatchFrame" } })

-- 帮助 / 客服：Blizzard_HelpFrame 是 AllowLoad: Game。
local function SkinHelp()
    M:Dress("HelpFrame", { window = true, panel = { bgAlpha = 0.96 }, deep = true })
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
