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

local function SkinLoot()
    local frame = _G.LootFrame
    if frame then
        M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
        -- The close button is handled by SkinWindow; only the pager arrows go through the text-button skin.
        M:Buttons({ "LootFramePrevPageButton", "LootFrameNextPageButton" })
        Skin:ScrollFrame(frame.LootFrameScrollFrame)
    end

    M:Controls({ "GroupLootFrame1", "GroupLootFrame2", "GroupLootFrame3", "GroupLootFrame4" }, function(roll)
        Skin:Strip(roll)
        Skin:Panel(roll, { bgAlpha = 0.96 })
    end)

    -- The rolling history window builds its entry buttons lazily on open, so the list gets re-skinned on every show (HookShow is one handler per frame).
    local history = _G.GroupLootHistoryFrame
    if history then
        local function skinHistory()
            M:SkinWindow(history, { panel = { bgAlpha = 0.96 } })
            M:SkinScrollsIn(history)
            M:SkinButtonsIn(history)
        end
        skinHistory()
        M:HookShow(history, skinHistory)
    end
end

local function SkinPopups()
    for index = 1, 4 do
        local popup = _G["StaticPopup" .. index]
        if popup then
            Skin:Strip(popup)
            Skin:Panel(popup, { bgAlpha = 0.97 })
            M:Controls({
                _G["StaticPopup" .. index .. "Button1"],
                _G["StaticPopup" .. index .. "Button2"],
                _G["StaticPopup" .. index .. "Button3"],
            }, function(button)
                Skin:Button(button, { bgAlpha = 0.9 })
            end)
        end
    end

    -- 数量拆分框：顶部金色条是帧自己的美术，去掉；内容（加减号、输入框）保留。
    local split = _G.StackSplitFrame
    if split then
        Skin:Strip(split)
        Skin:Panel(split, { bgAlpha = 0.97 })
        if split.SingleItemSplitBackground then Skin:Fade(split.SingleItemSplitBackground) end
        if split.MultiItemSplitBackground then Skin:Fade(split.MultiItemSplitBackground) end
        M:SkinButtonsIn(split)
    end

    -- 组队邀请弹窗：零售式与经典式两个模板都试，缺的那个自动跳过。
    for _, name in ipairs({ "LFGListInviteDialog", "LFGInvitePopup" }) do
        local dialog = _G[name]
        if dialog then
            Skin:Strip(dialog)
            Skin:Panel(dialog, { bgAlpha = 0.97 })
            M:SkinButtonsIn(dialog)
        end
    end

    -- 就绪确认：主框（发确认者）与监听框（参与者）是两个独立窗口。
    for _, name in ipairs({ "ReadyCheckFrame", "ReadyCheckListenerFrame" }) do
        local frame = _G[name]
        if frame then
            Skin:Strip(frame)
            Skin:Panel(frame, { bgAlpha = 0.97 })
            M:SkinButtonsIn(frame)
        end
    end

    -- 地下城队列状态气泡（小地图按钮弹出的那张列表）。
    local queue = _G.QueueStatusFrame
    if queue then
        Skin:Strip(queue)
        Skin:Panel(queue, { bgAlpha = 0.97 })
    end

    -- Battle.net 提示。
    local toast = _G.BNToastFrame
    if toast then
        Skin:Strip(toast)
        Skin:Panel(toast, { bgAlpha = 0.97 })
    end
end

local function SkinGameMenu()
    local frame = _G.GameMenuFrame
    if not frame then return end
    Skin:Strip(frame)
    Skin:Panel(frame, { bgAlpha = 0.97 })
    M:Controls({ "GameMenuButtonContinue", "GameMenuButtonSettings", "GameMenuButtonMacros",
        "GameMenuButtonAddons", "GameMenuButtonLogout", "GameMenuButtonQuit",
        "GameMenuButtonExit", "GameMenuButtonStore" }, function(button)
        Skin:Button(button)
    end)
end

local function SkinSettings()
    local frame = _G.SettingsPanel
    if not frame then return end
    M:SkinWindow(frame, { panel = { bgAlpha = 0.97 } })
    M:SkinScrollsIn(frame)
end

-- Edit Mode: the manager bar plus the three dialogs it opens.  Without this, moving a bar leaves you
-- staring at stock Blizzard chrome with no indication of what the click did.
local function SkinEditMode()
    local manager = _G.EditModeManager
    if manager then
        Skin:Strip(manager)
        Skin:Panel(manager, { bgAlpha = 0.97 })
    end

    M:Controls({
        "EditModeSystemSettingsDialog", "EditModeUnsavedChangesDialog", "EditModeLayoutDialog",
    }, function(dialog)
        if not dialog then return end
        Skin:Strip(dialog)
        Skin:Panel(dialog, { bgAlpha = 0.97 })
    end)

    M:Buttons({
        "EditModeManagerFrameAcceptChanges", "EditModeManagerFrameCancelChanges",
        "EditModeSystemSettingsDialogAccept", "EditModeSystemSettingsDialogCancel",
        "EditModeUnsavedChangesDialogOkay", "EditModeUnsavedChangesDialogCancel",
        "EditModeLayoutDialogSave", "EditModeLayoutDialogCancel",
    })

    -- The system-settings dialog builds its rows lazily from a button pool, so restyle whatever has
    -- been created by the time the panel is applied (HookShow covers the rest on each open).
    local settings = _G.EditModeSystemSettingsDialog
    if settings then
        local function skinRows()
            M:SkinButtonsIn(settings)
            M:SkinSlidersIn(settings)
            M:SkinScrollsIn(settings)
        end
        skinRows()
        M:HookShow(settings, skinRows)
    end
end

local function SkinAddonList()
    local frame = _G.AddonList
    if not frame then return end
    M:SkinWindow(frame, { panel = { bgAlpha = 0.97 } })
    Skin:ScrollFrame(frame.AddonListScrollFrame or frame.ScrollFrame)
    M:Buttons({ "AddonListEnableAllButton", "AddonListDisableAllButton" })
    M:Controls({ "AddonListFilterButton" }, function(button)
        Skin:Dropdown(button)
    end)
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
    if Marked(_G.UIParent, "menuPoll") then return end
    Mark(_G.UIParent, "menuPoll", true)
    -- 不再 hooksecurefunc("UIDropDownMenu_CreateFrames")（全局函数钩子 = 污染，见 AGENTS）。
    -- 改成轮询：每 0.5 秒把可见的下拉列表重新染一遍（只染显示中的，成本可忽略）。
    ns.Widget:PollWatch(_G.UIParent, function()
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
    if tooltipStyleWatched or type(_G.SharedTooltip_SetBackdropStyle) ~= "function" then return end
    tooltipStyleWatched = true

    -- 不再 hooksecurefunc("SharedTooltip_SetBackdropStyle")（全局函数钩子 = 污染）：
    -- 改成轮询——提示框显示期间每 0.5 秒补一次九宫格染色。暴雪自己换特殊样式
    -- （符文锻造金 / 腐化紫 / Azerite）时，Mark 里的 nineTint 仍在，但颜色会被它覆盖，
    -- 所以这里只在"还是我们标记过的那个框"时补色。
    local tip = _G.GameTooltip
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
    PlateTooltip(_G.GameTooltip)
    TintPanel(_G.GameTooltip)
    WatchTooltipStyle()

    -- ItemRefTooltip is the *separate* frame a ctrl-clicked item link opens in.  It has its own
    -- chrome and its own close button and nothing in the game touches either, so every item link the
    -- player inspects shows stock Blizzard chrome even when the tooltip option is on.
    local ref = _G.ItemRefTooltip
    if ref then
        PlateTooltip(ref)
        TintPanel(ref)
        if ref.CloseButton then Skin:CloseButton(ref.CloseButton) end
    end
end

M:Panel("loot", { label = "拾取 / 掷骰", group = "系统", apply = SkinLoot,
    frames = {
        "LootFrame", "LootFrameCloseButton",
        "LootFramePrevPageButton", "LootFrameNextPageButton", "LootFrameScrollFrame",
        "GroupLootFrame1", "GroupLootFrame2", "GroupLootFrame3", "GroupLootFrame4",
        "GroupLootHistoryFrame",
    } })

M:Panel("popups", { label = "确认弹窗", group = "系统", apply = SkinPopups,
    frames = {
        "StaticPopup1", "StaticPopup1Button1", "StaticPopup1Button2",
        "StaticPopup2", "StaticPopup2Button1",
        "StaticPopup3", "StaticPopup3Button1",
        "StaticPopup4", "StaticPopup4Button1",
        "StackSplitFrame",
        "LFGListInviteDialog", "LFGInvitePopup",
        "ReadyCheckFrame", "ReadyCheckListenerFrame",
        "QueueStatusFrame", "BNToastFrame",
    } })

M:Panel("gamemenu", { label = "游戏菜单", group = "系统", apply = SkinGameMenu,
    frames = {
        "GameMenuFrame",
        "GameMenuButtonContinue", "GameMenuButtonSettings", "GameMenuButtonMacros",
        "GameMenuButtonAddons", "GameMenuButtonLogout", "GameMenuButtonQuit",
        "GameMenuButtonExit", "GameMenuButtonStore",
    } })

M:Panel("settings", { label = "设置面板", group = "系统", apply = SkinSettings,
    frames = { "SettingsPanel", "SettingsPanel.CloseButton" } })

M:Panel("editmode", { label = "编辑模式", group = "系统", apply = SkinEditMode,
    frames = {
        "EditModeManagerFrame", "EditModeManagerFrameAccept", "EditModeManagerFrameCancel",
        "EditModeSystemSettingsDialog", "EditModeUnsavedChangesDialog", "EditModeLayoutDialog",
        "EditModeSystemSettingsDialogAccept", "EditModeSystemSettingsDialogCancel",
        "EditModeUnsavedChangesDialogOkay", "EditModeUnsavedChangesDialogCancel",
        "EditModeLayoutDialogSave", "EditModeLayoutDialogCancel",
    } })

M:Panel("addonlist", { label = "插件列表", group = "系统", apply = SkinAddonList,
    frames = {
        "AddonList", "AddonList.EnableAllButton", "AddonList.DisableAllButton",
        "AddonList.FilterButton", "AddonList.ScrollFrame",
    } })

M:Panel("menus", { label = "下拉菜单", group = "系统", apply = SkinMenus, default = false,
    -- Only the hook itself: every DropDownListN is reached inside the hook from the level argument,
    -- so listing them here would be decoration (see ALLOW_DYNAMIC in tools/check-frame-list.js).
    frames = { "UIDropDownMenu_CreateFrames" } })

M:Panel("tooltip", { label = "鼠标提示边框", group = "系统", apply = SkinTooltip, default = true,
    -- Same for ItemRefTooltipCloseButton: reached as ref.CloseButton (a member), not a global.
    frames = { "GameTooltip", "ItemRefTooltip" } })

-- 宏编辑器：Blizzard_MacroUI 无 game-type 门控（wow-ui-source forever 分支），本客户端存在。
-- 图标选择弹窗（MacroPopupFrame）是独立的 LoD 窗口，名字/图标网格是内容，不动。
local function SkinMacroPopup()
    local popup = _G.MacroPopupFrame
    if not popup then return end
    if Marked(popup, "macroPopupSkinned") then return end
    Mark(popup, "macroPopupSkinned", true)

    M:SkinWindow(popup, { panel = { bgAlpha = 0.97 } })
    M:SkinButtonsIn(popup)
end

local function SkinMacros()
    local frame = _G.MacroFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:Tabs({ "MacroFrameTab1", "MacroFrameTab2" })
    M:SkinButtonsIn(frame)
    M:SkinScrollsIn(frame)
    M:Controls({ "MacroEditBox" }, function(box) Skin:EditBox(box) end)

    -- MacroPopupFrame 是点"选图标"时才创建的：那时主窗口一定开着，所以挂在主窗口的
    -- PollWatch 上等它出现（主窗口关着时轮询不跑，零成本）。
    SkinMacroPopup()
    ns.Widget:PollWatch(frame, SkinMacroPopup)
end

M:Panel("macros", { label = "宏编辑器", group = "系统", apply = SkinMacros,
    addons = { Blizzard_MacroUI = true },
    frames = {
        "MacroFrame", "MacroFrameTab1", "MacroFrameTab2",
        "MacroFrameEditBox",
        "MacroPopupFrame",
    } })

-- 时钟 / 秒表：Blizzard_TimeManager 带 camelot 专属覆写文件（Camelot\Blizzard_TimeManagerOverrides.lua）。
-- 秒表是独立小窗（StopwatchFrame）；关闭按钮的全局名是 TimeManagerCloseButton
-- （不带 Frame 后缀，SkinWindow 的 name.."CloseButton" 推导够不到，显式接）。
local function SkinTimeManager()
    local frame = _G.TimeManagerFrame
    if frame then
        M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
        M:SkinButtonsIn(frame)
    end
    -- 正式服 12.1.5 TimeManagerFrame.CloseButton 是成员不是全局名
    if frame and frame.CloseButton then Skin:CloseButton(frame.CloseButton) end
    M:Controls({ "StopwatchFrame" }, function(watch)
        M:SkinWindow(watch, { panel = { bgAlpha = 0.96 } })
    end)
end

M:Panel("timemanager", { label = "时钟 / 秒表", group = "系统", apply = SkinTimeManager,
    addons = { Blizzard_TimeManager = true },
    frames = { "TimeManagerFrame", "TimeManagerFrame.CloseButton", "StopwatchFrame" } })

-- 帮助 / 客服：Blizzard_HelpFrame 是 AllowLoad: Game。关闭按钮同理显式接全局名。
local function SkinHelp()
    local frame = _G.HelpFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.96 } })
    M:SkinButtonsIn(frame)
    M:SkinScrollsIn(frame)
    -- 正式服 12.1.5 HelpFrame.CloseButton 是成员不是全局名
    if frame.CloseButton then Skin:CloseButton(frame.CloseButton) end
end

M:Panel("help", { label = "帮助", group = "系统", apply = SkinHelp,
    addons = { Blizzard_HelpFrame = true },
    frames = { "HelpFrame", "HelpFrame.CloseButton" } })

-- 拾色器：设置面板等处弹出，无门控。12.1.5 正式服按钮是 Footer 成员 + ColorPickerFrameOkay/ColorPickerFrameCancel 全局名。
local function SkinColorPicker()
    local frame = _G.ColorPickerFrame
    if not frame then return end

    M:SkinWindow(frame, { panel = { bgAlpha = 0.97 } })
    M:Buttons({ "ColorPickerFrameOkay", "ColorPickerFrameCancel" })
    local footer = frame.Footer
    if footer then
        local members = {}
        if footer.OkayButton then members[#members + 1] = footer.OkayButton end
        if footer.CancelButton then members[#members + 1] = footer.CancelButton end
        M:Controls(members, function(button) Skin:Button(button) end)
    end
end

M:Panel("colorpicker", { label = "拾色器", group = "系统", apply = SkinColorPicker,
    frames = { "ColorPickerFrame", "ColorPickerFrameOkay", "ColorPickerFrameCancel" } })
