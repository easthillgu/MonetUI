-- Config/SimpleConfig.lua
-- Lightweight, themed configuration panel (no Ace3 dependency).
--
-- All widgets bind straight to MonetUIDB, so changes apply immediately and
-- survive a reload.

local ADDON_NAME, ns = ...

local Widget = ns.Widget
local Color = ns.Color
local Media = ns.Media

local SimpleConfig = {}
ns.Config = SimpleConfig

local panel
local moduleCheckboxes = {}
local refreshStatus

local MODULE_ORDER = {
    "UnitFrames", "Cooldown", "BuffFrame",
    "Minimap", "BagFrame", "QuestTracker", "ActionBars",
}

local MODULE_LABEL = {
    UnitFrames   = "单位框架 (UnitFrames)",
    Cooldown     = "冷却计时 (Cooldown)",
    BuffFrame    = "增益光环 (BuffFrame)",
    Minimap      = "小地图 (Minimap)",
    BagFrame     = "背包整合 (BagFrame)",
    QuestTracker = "任务追踪 (QuestTracker)",
    ActionBars   = "动作条 (ActionBars)",
}

-- -- Widget helpers -----------------------------------------------------------

local function MakeCheckbox(parent, label, yOffset, getter, setter)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 24, yOffset)
    cb:SetChecked(getter() and true or false)
    cb:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
    end)

    local text = Widget:Font(parent, 13, "pixel", "neutral", "LEFT")
    text:SetPoint("LEFT", cb, "RIGHT", 6, 0)
    text:SetText(label)

    return cb, text
end

local function MakeSeparator(parent, yOffset, caption)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yOffset)
    line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -20, yOffset)
    line:SetHeight(1)
    local r, g, b = Color:GetNeutral()
    line:SetColorTexture(r, g, b, 0.35)

    if caption then
        local title = Widget:Font(parent, 12, "roadway", "edge", "LEFT")
        title:SetPoint("BOTTOMLEFT", line, "TOPLEFT", 0, 4)
        title:SetText(caption)
    end

    return line
end

-- -- Panel --------------------------------------------------------------------

function SimpleConfig:Build()
    if panel then return panel end

    panel = Widget:CreateFrame("MonetUIConfigFrame", UIParent, 400, 570)
    Widget:Theme(panel, { thickness = 2, bgAlpha = 0.96, borderAlpha = 1 })
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetClampedToScreen(true)
    panel:Hide()

    local title = Widget:Font(panel, 20, "roadway", "edge", "CENTER")
    title:SetPoint("TOP", panel, "TOP", 0, -16)
    title:SetText("MonetUI")

    local subtitle = Widget:Font(panel, 11, "pixel", "neutral", "CENTER")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -4)
    subtitle:SetText("v" .. ns.version .. " · 印象派自适应界面")

    local close = Widget:CloseButton(panel)
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)

    local y = -62

    -- -- Theme ---------------------------------------------------------------
    MakeSeparator(panel, y, "主题")
    y = y - 26

    MakeCheckbox(panel, "使用 MonetColor 动态主题", y,
        function()
            local db = ns:DB()
            return db.theme.useMonetColor
        end,
        function(value)
            local db = ns:DB()
            db.theme.useMonetColor = value
            ns.RefreshTheme("config")
            if refreshStatus then refreshStatus() end
        end)
    y = y - 28

    local statusText = Widget:Font(panel, 11, "pixel", "neutral", "LEFT")
    statusText:SetPoint("TOPLEFT", panel, "TOPLEFT", 46, y)
    statusText:SetWidth(330)
    statusText:SetJustifyH("LEFT")
    y = y - 20

    refreshStatus = function()
        local source, profile = Color:GetSource()
        local colorText
        if source == "monet" then
            colorText = string.format("引擎输出 · 配置 %s", tostring(profile))
        else
            colorText = ns:HasMonetColor() and "内置调色板（引擎已关闭）" or "内置调色板（未找到 LibMonetColor）"
        end
        statusText:SetText(colorText)
    end
    refreshStatus()

    -- -- Modules -------------------------------------------------------------
    MakeSeparator(panel, y, "模块")
    y = y - 28

    local function moduleGetter(name)
        return function() return ns:IsModuleEnabled(name) end
    end
    local function moduleSetter(name)
        return function(value)
            ns:SetModuleEnabled(name, value)
            if refreshStatus then refreshStatus() end
        end
    end

    for _, name in ipairs(MODULE_ORDER) do
        moduleCheckboxes[name] = MakeCheckbox(panel, MODULE_LABEL[name] or name, y,
            moduleGetter(name), moduleSetter(name))
        y = y - 28
    end

    -- -- Frame options -------------------------------------------------------
    y = y - 6
    MakeSeparator(panel, y, "单位框架")
    y = y - 28

    MakeCheckbox(panel, "隐藏暴雪默认的玩家/目标框架（需重载恢复）", y,
        function() return ns:DB().unitFrames.hideBlizzard end,
        function(value)
            ns:DB().unitFrames.hideBlizzard = value
            if value then
                local unitFrames = ns:GetModule("UnitFrames")
                if unitFrames and unitFrames.SuppressBlizzard then
                    unitFrames:SuppressBlizzard(true)
                end
            else
                ns:Print("取消隐藏需要 /reload 才能恢复暴雪框架。")
            end
        end)
    y = y - 30

    -- -- Action bar options ---------------------------------------------------
    MakeSeparator(panel, y, "动作条")
    y = y - 28

    MakeCheckbox(panel, "隐藏暴雪默认动作条", y,
        function() return ns:DB().actionBars.hideBlizzard end,
        function(value)
            ns:DB().actionBars.hideBlizzard = value
            local bars = ns:GetModule("ActionBars")
            if bars and bars.Apply then bars:Apply() end
        end)
    y = y - 28

    MakeCheckbox(panel, "隐藏暴雪默认背包条", y,
        function() return ns:DB().actionBars.hideBagBar end,
        function(value)
            ns:DB().actionBars.hideBagBar = value
            local bars = ns:GetModule("ActionBars")
            if bars and bars.Apply then bars:Apply() end
        end)
    y = y - 30

    -- -- Footer --------------------------------------------------------------
    local hint = Widget:Font(panel, 11, "pixel", "neutral", "LEFT")
    hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, y)
    hint:SetWidth(340)
    hint:SetText("提示：/mui status 查看模块状态，/mui reset 恢复默认设置。")
    hint:SetJustifyH("LEFT")

    local reload = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reload:SetSize(120, 24)
    reload:SetPoint("BOTTOM", panel, "BOTTOM", 0, 16)
    reload:SetText("重载界面")
    reload:SetScript("OnClick", function()
        if _G.ReloadUI then _G.ReloadUI() end
    end)

    return panel
end

function SimpleConfig:Toggle()
    local frame = self:Build()
    if frame:IsShown() then
        frame:Hide()
    else
        if refreshStatus then refreshStatus() end
        for name, checkbox in pairs(moduleCheckboxes) do
            if checkbox and checkbox.SetChecked then
                checkbox:SetChecked(ns:IsModuleEnabled(name) and true or false)
            end
        end
        frame:Show()
    end
end

function SimpleConfig:Show()
    self:Build():Show()
end

function SimpleConfig:Hide()
    if panel then panel:Hide() end
end
