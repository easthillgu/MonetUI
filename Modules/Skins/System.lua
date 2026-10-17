-- Modules/Skins/System.lua
-- System windows: the loot window and group-loot rolls, static pop-ups, the game menu, the settings panel, the add-on list, and -- opt-in -- the drop-down menus and the tooltip.  Item buttons keep their icons.

local ADDON_NAME, ns = ...

local M    = ns.Skins
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

--- Recolour a frame's existing backdrop.  Menus and the tooltip already own a backdrop, so no backplate child is added; originals are recorded for rollback.
local function TintBackdrop(frame)
    if not frame or type(frame.SetBackdropBorderColor) ~= "function" then return end

    if not frame.__monetBackdropTint then
        frame.__monetBackdropTint = true

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
            frame.__monetBackdropTint = nil
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

local function SkinMenus()
    local create = _G.UIDropDownMenu_CreateFrames
    if type(create) ~= "function" or create.__monetHooked then return end
    create.__monetHooked = true

    hooksecurefunc("UIDropDownMenu_CreateFrames", function(level, menuIndex)
        TintBackdrop(_G["DropDownList" .. tostring(level)])
        TintBackdrop(_G["DropDownList" .. tostring(level) .. "Menu" .. tostring(menuIndex)])
    end)
end

local function SkinTooltip()
    TintBackdrop(_G.GameTooltip)
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
    frames = { "SettingsPanel", "SettingsPanelCloseButton" } })

M:Panel("addonlist", { label = "插件列表", group = "系统", apply = SkinAddonList,
    frames = {
        "AddonList", "AddonListEnableAllButton", "AddonListDisableAllButton",
        "AddonListFilterButton", "AddonListScrollFrame",
    } })

M:Panel("menus", { label = "下拉菜单", group = "系统", apply = SkinMenus, default = false,
    frames = { "UIDropDownMenu_CreateFrames", "DropDownList1" } })

M:Panel("tooltip", { label = "鼠标提示边框", group = "系统", apply = SkinTooltip, default = false,
    frames = { "GameTooltip" } })
