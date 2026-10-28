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

--- 入口定义：label 是显示文字，buttons 是暴雪微型按钮的候选名字（两个客户端的名字不一样，
--- 谁在用谁），action 是按钮不在时的备用开关函数。
--
-- 动作优先直接调按钮自己的 OnClick —— 和玩家点那一排按钮完全一样，客户端改名也不会失效
-- （零售 12.x 把 ToggleCharacterSheet 之类删干净了，角色面板只能这么开）。
local ENTRIES = {
    { label = "角色", buttons = { "CharacterMicroButton" } },
    { label = "法术", buttons = { "PlayerSpellsMicroButton", "SpellbookMicroButton" },
      action = function()
        local util = _G.PlayerSpellsUtil
        if util and type(util.ToggleSpellBookFrame) == "function" then
            return util.ToggleSpellBookFrame()
        end
        if type(_G.ToggleSpellBook) == "function" then return _G.ToggleSpellBook() end
      end },
    { label = "背包", buttons = { "BagMicroButton" },
      action = function() if type(_G.ToggleAllBags) == "function" then _G.ToggleAllBags() end end },
    { label = "任务", buttons = { "QuestLogMicroButton" },
      action = function() if type(_G.ToggleQuestLog) == "function" then _G.ToggleQuestLog() end end },
    { label = "成就", buttons = { "AchievementMicroButton" },
      action = function() if type(_G.ToggleAchievementFrame) == "function" then _G.ToggleAchievementFrame() end end },
    { label = "好友", buttons = { "GuildMicroButton", "GJMicroButton", "SocialsMicroButton" },
      action = function() if type(_G.ToggleFriendsFrame) == "function" then _G.ToggleFriendsFrame() end end },
    { label = "地图", buttons = { "MapMicroButton" },
      action = function() if type(_G.ToggleWorldMap) == "function" then _G.ToggleWorldMap() end end },
    { label = "日历", buttons = { "CalendarMicroButton" },
      action = function() if type(_G.ToggleCalendar) == "function" then _G.ToggleCalendar() end end },
    { label = "收藏", buttons = { "CollectionsMicroButton" },
      action = function() if type(_G.ToggleCollectionsJournal) == "function" then _G.ToggleCollectionsJournal() end end },
    { label = "副本", buttons = { "EJMicroButton" },
      action = function() if type(_G.ToggleEncounterJournal) == "function" then _G.ToggleEncounterJournal() end end },
    { label = "职业", buttons = { "ProfessionMicroButton" } },
    { label = "寻找组", buttons = { "LFDMicroButton" } },
    { label = "住房", buttons = { "HousingMicroButton" } },
    { label = "商店", buttons = { "StoreMicroButton" } },
    { label = "帮助", buttons = { "HelpMicroButton" } },
    { label = "设置", buttons = { "MainMenuMicroButton" },
      action = function()
        local settings = _G.Settings
        if settings and type(settings.OpenToCategory) == "function" and settings.INTERFACE_CATEGORY_ID then
            return settings.OpenToCategory(settings.INTERFACE_CATEGORY_ID)
        end
        if type(_G.ToggleGameMenu) == "function" then return _G.ToggleGameMenu() end
      end },
}

--- 这一行的动作：优先用微型按钮自己的 OnClick（和点那一排按钮一模一样），
--- 按钮不在（零售 12.x 把背包/地图/日历那几个撤了）就用备用的开关函数。
local function ActionFor(entry)
    for _, name in ipairs(entry.buttons or {}) do
        local button = _G[name]
        if button and type(button.GetScript) == "function" then
            local ok, fn = pcall(button.GetScript, button, "OnClick")
            if ok and type(fn) == "function" then
                return function() pcall(fn, button) end
            end
        end
    end
    if type(entry.action) == "function" then return entry.action end
    return nil
end

--- 菜单贴着地图左上角展开（向左下），比"跟着鼠标跑"稳：地图本来就在屏幕右下角，
--- 菜单往左展开一定完整可见，不用去猜鼠标的屏幕坐标换算。
local function Build()
    if frame then return frame end

    frame = Widget:CreateFrame("MonetUIMinimapMicroMenu", UIParent, MENU_W, 40)
    -- 直角版（square-blp）：不带 round，走 SetBackdrop 的直角边框。
    Widget:Theme(frame, { thickness = 1, bgAlpha = 0.96, borderAlpha = 1 })
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(20)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:Hide()

    rows = {}
    local y = -4
    for _, entry in ipairs(ENTRIES) do
        local action = ActionFor(entry)
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
            row:HookScript("OnEnter", function() Widget:ColorText(label, "highlight") end) -- TAINT-OK: row 是自建微型菜单行
            row:HookScript("OnLeave", function() Widget:ColorText(label, "neutral") end) -- TAINT-OK: 同上

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

--- 现在有没有别的菜单开着？
--- 暴雪的追踪菜单、LibDBPanel 这类插件会在同一次右键里开菜单；我们再 Toggle 一次，
--- 人家刚开的菜单就被我们关掉了（同一个右键既开又关，看着像"点了没反应"）。
--- AishCore 的做法：查 DropDownList1 与菜单管理器（Comfort.lua 544-551）。
local function AnyMenuOpen()
    local list = _G.DropDownList1
    if list and list.IsShown then
        local ok, shown = pcall(list.IsShown, list)
        if ok and shown then return true end
    end
    local menu = _G.Menu
    if menu and menu.GetManager then
        -- 布尔换算也放在 pcall 里：万一返回值是保密值，条件判断会直接报错
        local ok, anyOpen = pcall(function()
            local open = menu.GetManager():GetOpenMenu()
            return open and true or false
        end)
        if ok and anyOpen then return true end
    end
    return false
end

--- 在小地图旁边弹出（anchor 一般是小地图面板）。
function M:Toggle(anchor)
    if frame and frame:IsShown() then
        self:Close()
        return
    end
    -- 已经有别的菜单开着就别抢（见 AnyMenuOpen 的说明）
    if AnyMenuOpen() then return end
    Build()
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
