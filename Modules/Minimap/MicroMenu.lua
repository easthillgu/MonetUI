-- Modules/Minimap/MicroMenu.lua
-- 右键小地图弹出的微型游戏菜单：一列游戏面板的快捷入口，面板用统一的 Monet 材质。
--
-- 入口全部"存在才显示"：这些面板的开关函数在暴雪代码里（API 手册没收），所以运行时
-- 探测 _G，客户端上缺哪个就不画哪一行 —— 点不到不存在的函数，版本差异也不会出事。

local ADDON_NAME, ns = ...

local Widget = ns.Widget

local M = {}

local ROW_H  = 16
local MENU_W = 56

local frame      -- 菜单面板
local catcher    -- 点别处关闭
local rows       -- 已建的行

--- 入口定义：label 是显示文字，find 返回可调用的函数（没有就返回 nil，这一行不画）。
local ENTRIES = {
    { label = "角色", find = function()
        if type(_G.ToggleCharacterSheet) == "function" then return _G.ToggleCharacterSheet end
        if type(_G.CharacterFrame_ToggleCharacterFrame) == "function" then return _G.CharacterFrame_ToggleCharacterFrame end
    end },
    { label = "法术", find = function()
        local util = _G.PlayerSpellsUtil
        if util and type(util.ToggleSpellBookFrame) == "function" then
            return function() util.ToggleSpellBookFrame() end
        end
        if type(_G.ToggleSpellBook) == "function" then return _G.ToggleSpellBook end
    end },
    { label = "背包", find = function()
        if type(_G.ToggleAllBags) == "function" then return _G.ToggleAllBags end
    end },
    { label = "任务", find = function()
        if type(_G.ToggleQuestLog) == "function" then return _G.ToggleQuestLog end
    end },
    { label = "成就", find = function()
        if type(_G.ToggleAchievementFrame) == "function" then return _G.ToggleAchievementFrame end
    end },
    { label = "好友", find = function()
        if type(_G.ToggleFriendsFrame) == "function" then return _G.ToggleFriendsFrame end
    end },
    { label = "地图", find = function()
        if type(_G.ToggleWorldMap) == "function" then return _G.ToggleWorldMap end
    end },
    { label = "日历", find = function()
        if type(_G.ToggleCalendar) == "function" then return _G.ToggleCalendar end
    end },
    { label = "收藏", find = function()
        if type(_G.ToggleCollectionsJournal) == "function" then return _G.ToggleCollectionsJournal end
    end },
    { label = "副本", find = function()
        if type(_G.ToggleEncounterJournal) == "function" then return _G.ToggleEncounterJournal end
    end },
    { label = "设置", find = function()
        local settings = _G.Settings
        if settings and type(settings.OpenToCategory) == "function" and settings.INTERFACE_CATEGORY_ID then
            return function() settings.OpenToCategory(settings.INTERFACE_CATEGORY_ID) end
        end
        if type(_G.ToggleGameMenu) == "function" then return _G.ToggleGameMenu end
    end },
}

--- 菜单贴着地图左上角展开（向左下），比"跟着鼠标跑"稳：地图本来就在屏幕右下角，
--- 菜单往左展开一定完整可见，不用去猜鼠标的屏幕坐标换算。
local function Build()
    if frame then return frame end

    frame = Widget:CreateFrame("MonetUIMinimapMicroMenu", UIParent, MENU_W, 40)
    Widget:Theme(frame, { thickness = 1, bgAlpha = 0.96, borderAlpha = 1, round = true })
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(20)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:Hide()

    rows = {}
    local y = -4
    for _, entry in ipairs(ENTRIES) do
        local action = entry.find and entry.find()
        if action then
            local row = CreateFrame("Button", nil, frame)
            row:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, y)
            row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, y)
            row:SetHeight(ROW_H)
            row:EnableMouse(true)

            local label = Widget:Font(row, 12, "pixel", "neutral", "CENTER")
            label:SetPoint("LEFT", row, "LEFT", 4, 0)
            label:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            label:SetText(entry.label)

            row:SetScript("OnClick", function()
                pcall(action)
                M:Close()
            end)
            row:HookScript("OnEnter", function() Widget:ColorText(label, "highlight") end)
            row:HookScript("OnLeave", function() Widget:ColorText(label, "neutral") end)

            rows[#rows + 1] = row
            y = y - (ROW_H + 1)
        end
    end

    frame:SetHeight(math.abs(y) + 10)

    -- 点别处关闭：整屏 catcher，层级比菜单低，菜单自己的点击不会被它吃掉。
    catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:SetFrameLevel(10)
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", function() M:Close() end)
    catcher:Hide()

    return frame
end

--- 在小地图旁边弹出（anchor 一般是小地图面板）。
function M:Toggle(anchor)
    if frame and frame:IsShown() then
        self:Close()
        return
    end
    self:Build()
    if not frame then return end

    frame:ClearAllPoints()
    if anchor then
        frame:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -6, 0)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    frame:Show()
    if catcher then catcher:Show() end
end

function M:Close()
    if frame then frame:Hide() end
    if catcher then catcher:Hide() end
end

function M:IsOpen()
    return frame and frame:IsShown() and true or false
end

ns:GetModule("Minimap").microMenu = M
