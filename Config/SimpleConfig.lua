-- Config/SimpleConfig.lua
-- Lightweight configuration panel (no Ace3 dependency)

local ADDON_NAME = ...

local SimpleConfig = {}

-- Private state
local panel = nil
local checkboxes = {}
local sliders = {}

-- ============================================================================
-- Default Settings
-- ============================================================================

local defaults = {
    enabled = true,
    unitFrames = true,
    cooldown = true,
    buffFrame = true,
    minimap = true,
    bagFrame = true,
    questTracker = true,
    useMonetColor = true,
}

-- ============================================================================
-- Panel Creation
-- ============================================================================

function SimpleConfig:CreatePanel()
    if panel then return panel end

    panel = CreateFrame("Frame", "MonetUIConfigFrame", UIParent, "BackdropTemplate")
    panel:SetSize(400, 500)
    panel:SetPoint("CENTER")
    panel:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets = {left = 4, right = 4, top = 4, bottom = 4},
    })
    panel:SetBackdropColor(0.1, 0.1, 0.15, 0.95)
    panel:SetBackdropBorderColor(0.6, 0.4, 0.1, 1)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()

    -- Title
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -20)
    title:SetText("MonetUI 配置")
    title:SetTextColor(1, 0.85, 0.4, 1)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)
    closeBtn:SetScript("OnClick", function() panel:Hide() end)

    -- Module toggles
    local modules = {
        {"unitFrames", "单位框架 (UnitFrames)"},
        {"cooldown", "冷却计时 (Cooldown)"},
        {"buffFrame", "Buff 框架 (BuffFrame)"},
        {"minimap", "小地图 (Minimap)"},
        {"bagFrame", "背包 (BagFrame)"},
        {"questTracker", "任务追踪 (QuestTracker)"},
    }

    local yOffset = -60
    for _, mod in ipairs(modules) do
        local key, label = mod[1], mod[2]
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        cb:SetPoint("LEFT", 30, yOffset)
        cb:SetChecked(defaults[key])
        cb:SetScript("OnClick", function(self)
            defaults[key] = self:GetChecked()
        end)

        local text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("LEFT", cb, "RIGHT", 5, 0)
        text:SetText(label)
        text:SetTextColor(1, 1, 1, 1)

        checkboxes[key] = cb
        yOffset = yOffset - 35
    end

    -- Use MonetColor toggle
    local mcCb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    mcCb:SetPoint("LEFT", 30, yOffset)
    mcCb:SetChecked(defaults.useMonetColor)
    mcCb:SetScript("OnClick", function(self)
        defaults.useMonetColor = self:GetChecked()
    end)

    local mcText = mcCb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mcText:SetPoint("LEFT", mcCb, "RIGHT", 5, 0)
    mcText:SetText("使用 MonetColor 动态主题")
    mcText:SetTextColor(1, 1, 1, 1)

    checkboxes.useMonetColor = mcCb

    -- Open button (chat command)
    SLASH_MONETUI1 = "/monetui"
    SLASH_MONETUI2 = "/mui"
    SlashCmdList["MONETUI"] = function()
        panel:Show()
    end

    return panel
end

function SimpleConfig:Toggle()
    if not panel then
        self:CreatePanel()
    end
    if panel:IsShown() then
        panel:Hide()
    else
        panel:Show()
    end
end

function SimpleConfig:GetSetting(key)
    return defaults[key]
end

return SimpleConfig
