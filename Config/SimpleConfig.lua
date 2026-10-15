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
    "Minimap", "BagFrame", "QuestTracker", "ActionBars", "Nameplates", "Skins",
    "InfoBar",
}

local MODULE_LABEL = {
    UnitFrames   = "单位框架 (UnitFrames)",
    Cooldown     = "冷却计时 (Cooldown)",
    BuffFrame    = "增益光环 (BuffFrame)",
    Minimap      = "小地图 (Minimap)",
    BagFrame     = "背包整合 (BagFrame)",
    QuestTracker = "任务追踪 (QuestTracker)",
    ActionBars   = "动作条 (ActionBars)",
    Nameplates   = "姓名板 (Nameplates)",
    Skins        = "界面美化 (Skins)",
    InfoBar      = "信息栏 (InfoBar)",
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

-- -- Dropdown ----------------------------------------------------------------

-- Blizzard's menu framework (UIDropDownMenu / MenuUtil) is not part of the
-- documented client API and differs between builds, so the panel paints its own
-- small themed list instead of depending on either.

local dropdowns = {}   -- list of refreshers, run when the panel is shown
local openList         -- the list currently on screen, if any
local catcher          -- the click-anywhere-else closer

local function CloseDropdown()
    if openList then openList:Hide() end
    openList = nil
    if catcher then catcher:Hide() end
end

--- Covers the screen while a list is open and closes it on any click elsewhere.
-- Clicking the dropdown button itself also closes (the catcher is above it); a
-- second click re-opens it, which reads naturally enough.
local function Catcher()
    if catcher then return catcher end
    catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", CloseDropdown)
    catcher:Hide()
    return catcher
end

local function RefreshDropdowns()
    for i = 1, #dropdowns do
        dropdowns[i]()
    end
end

--- A settings row: caption on the left, the current choice on the right, and a
-- floating list of the alternatives under it.
-- @param items { { value = <stored value>, text = <shown label> }, ... }
local function MakeDropdown(parent, y, caption, items, getter, setter)
    local label = Widget:Font(parent, 12, "pixel", "neutral", "LEFT")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 24, y - 4)
    label:SetText(caption)

    local button = Widget:CreateFrame(nil, parent, 190, 20)
    Widget:Theme(button, { thickness = 1, bgAlpha = 0.9 })
    button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -24, y)
    button:EnableMouse(true)

    local value = Widget:Font(button, 12, "pixel", "edge", "LEFT")
    value:SetPoint("LEFT", button, "LEFT", 7, 0)
    value:SetPoint("RIGHT", button, "RIGHT", -16, 0)

    local chevron = Widget:Font(button, 10, "pixel", "neutral", "RIGHT")
    chevron:SetPoint("RIGHT", button, "RIGHT", -5, 0)
    chevron:SetText("v")

    -- The list hangs off the panel (UIParent) so the panel can never clip it.
    local list = Widget:CreateFrame(nil, UIParent, 190, #items * 20 + 4)
    Widget:Theme(list, { thickness = 1, bgAlpha = 0.98 })
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -2)
    list:EnableMouse(true)
    list:SetClampedToScreen(true)
    list:Hide()

    local function Selected()
        local wanted = getter()
        for _, item in ipairs(items) do
            if item.value == wanted then return item end
        end
        return items[1]
    end

    local function Refresh()
        local item = Selected()
        value:SetText(item and item.text or "?")
    end

    for index, item in ipairs(items) do
        local row = CreateFrame("Button", nil, list)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 2, -2 - (index - 1) * 20)
        row:SetSize(186, 20)

        local hover = row:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints()
        -- The HIGHLIGHT texture is only shown on hover, so its colour is
        -- sampled then and follows the theme wherever the player is.
        row:SetScript("OnEnter", function()
            local hr, hg, hb = Color:GetHighlight()
            hover:SetColorTexture(hr, hg, hb, 0.3)
        end)

        local rowText = Widget:Font(row, 12, "pixel", "neutral", "LEFT")
        rowText:SetPoint("LEFT", row, "LEFT", 6, 0)
        rowText:SetText(item.text)

        row:SetScript("OnClick", function()
            setter(item.value)
            CloseDropdown()
            RefreshDropdowns()
        end)
    end

    button:SetScript("OnMouseDown", function()
        if openList == list then
            CloseDropdown()
            return
        end
        CloseDropdown()
        Refresh()
        Catcher():Show()
        list:Show()
        openList = list
    end)

    parent:HookScript("OnHide", CloseDropdown)

    dropdowns[#dropdowns + 1] = Refresh
    Refresh()
    return button
end

-- -- Unit-frame settings ------------------------------------------------------

local function RefreshUnitFrames()
    local unitFrames = ns:GetModule("UnitFrames")
    if unitFrames and unitFrames.UpdateAll then unitFrames:UpdateAll() end
end

--- Action-bar changes go through Apply: it re-parks Blizzard's chrome, rebuilds
-- the visibility drivers and re-lays the bars out.
local function RefreshActionBars()
    local actionBars = ns:GetModule("ActionBars")
    if actionBars and actionBars.Apply then actionBars:Apply() end
end

--- Nameplate settings live in MonetUIDB.nameplates; Apply re-pushes the CVars,
-- the hitbox size and repaints whatever is on screen.
local function RefreshNameplates()
    local nameplates = ns:GetModule("Nameplates")
    if nameplates and nameplates.Apply then nameplates:Apply() end
end

--- Read a nameplate setting through the module (so it falls back to Core's
-- shipped defaults), then write it back and repaint.
local function NameplateSetting(key)
    local nameplates = ns:GetModule("Nameplates")
    if nameplates and nameplates.Setting then return nameplates.Setting(key) end
    return (ns.DEFAULTS.nameplates or {})[key]
end

local function NameplateSetter(key)
    return function(value)
        local db = ns:DB()
        db.nameplates = db.nameplates or {}
        db.nameplates[key] = value
        RefreshNameplates()
    end
end

--- Build a getter/setter pair for a checkbox row (checked when not false).
local function NameplateCheckbox(key)
    return function() return NameplateSetting(key) ~= false end, NameplateSetter(key)
end

--- One setting, read from a group of units and written to all of them.  The
-- units ship with different defaults (player/pet are lit, enemy frames follow
-- the game's own colour) but a group is meant to move together.
local function UnitSetting(units, key, default)
    local function get()
        local unitFrames = ns:DB().unitFrames or {}
        for _, unit in ipairs(units) do
            local stored = unitFrames[unit]
            local value = stored and stored[key]
            if value then return value end
        end
        return default
    end

    local function set(value)
        local unitFrames = ns:DB().unitFrames
        for _, unit in ipairs(units) do
            unitFrames[unit] = unitFrames[unit] or {}
            unitFrames[unit][key] = value
        end
        RefreshUnitFrames()
    end

    return get, set
end

-- -- Panel --------------------------------------------------------------------

function SimpleConfig:Build()
    if panel then return panel end

    panel = Widget:CreateFrame("MonetUIConfigFrame", UIParent, 400, 800)
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

    -- Border colour source: one row re-tints every border in the addon -- unit
    -- frames, the minimap panel, action bars, buffs, bags, the tracker and this
    -- panel -- because they all draw through Widget:Theme -> Color:GetBorder.
    local BORDER_ITEMS = {
        { value = "edge",      text = "边缘色（Monet 签名）" },
        { value = "ambient",   text = "环境色" },
        { value = "highlight", text = "高亮色" },
        { value = "neutral",   text = "中性灰" },
    }
    MakeDropdown(panel, y, "边框颜色", BORDER_ITEMS,
        function() return Color:GetBorderKey() end,
        function(value)
            ns:DB().theme.borderKey = value
            ns.RefreshTheme("config")
        end)
    y = y - 28

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

    -- -- Bar colours ----------------------------------------------------------
    local SELF  = { "player", "pet" }
    local OTHER = { "target", "focus", "targettarget" }

    local FILL_ITEMS = {
        { value = "highlight", text = "高亮色（Monet）" },
        { value = "class",     text = "职业 / 阵营色" },
        { value = "health",    text = "生命绿" },
    }
    local LOST_ITEMS = {
        { value = "danger", text = "高亮红" },
        { value = "black",  text = "黑色（背景）" },
    }
    local POWER_ITEMS = {
        { value = "type",  text = "按能量类型" },
        { value = "theme", text = "统一主题色" },
    }

    MakeDropdown(panel, y, "玩家 / 宠物 血条",
        FILL_ITEMS, UnitSetting(SELF, "fillColor", "highlight"))
    y = y - 28
    MakeDropdown(panel, y, "目标 / 焦点 血条",
        FILL_ITEMS, UnitSetting(OTHER, "fillColor", "class"))
    y = y - 28
    MakeDropdown(panel, y, "目标 / 焦点 损失部分",
        LOST_ITEMS, UnitSetting(OTHER, "lostColor", "danger"))
    y = y - 28
    MakeDropdown(panel, y, "能量条颜色", POWER_ITEMS,
        function() return ns:DB().unitFrames.powerColor end,
        function(value)
            ns:DB().unitFrames.powerColor = value
            RefreshUnitFrames()
        end)
    y = y - 28

    -- One row for two settings: 0 means "off", anything else is the pip height.
    local CLASS_ITEMS = {
        { value = 0, text = "关闭" },
        { value = 2, text = "2 px" },
        { value = 3, text = "3 px" },
        { value = 4, text = "4 px" },
        { value = 5, text = "5 px" },
    }

    MakeDropdown(panel, y, "连击点（盗贼 / 德鲁伊）", CLASS_ITEMS,
        function()
            local db = ns:DB().unitFrames
            if db.classPower == false then return 0 end
            return db.classPowerHeight
        end,
        function(value)
            local db = ns:DB().unitFrames
            db.classPower = value > 0
            if value > 0 then db.classPowerHeight = value end
            RefreshUnitFrames()
        end)
    y = y - 28

    MakeCheckbox(panel, "血量数字按百分比着色", y,
        function() return ns:DB().unitFrames.textColorByPercent end,
        function(value)
            ns:DB().unitFrames.textColorByPercent = value
            RefreshUnitFrames()
        end)
    y = y - 28

    MakeCheckbox(panel, "血条数值平滑过渡", y,
        function() return ns:DB().unitFrames.smoothBars end,
        function(value)
            ns:DB().unitFrames.smoothBars = value
            RefreshUnitFrames()
        end)
    y = y - 30

    -- -- Action bar options ---------------------------------------------------
    MakeSeparator(panel, y, "动作条")
    y = y - 28

    MakeCheckbox(panel, "自绘动作条（LibActionButton）", y,
        function() return ns:DB().actionBars.ownBars end,
        function(value)
            ns:DB().actionBars.ownBars = value
            RefreshActionBars()
        end)
    y = y - 28

    MakeCheckbox(panel, "隐藏暴雪默认动作条", y,
        function() return ns:DB().actionBars.hideBlizzard end,
        function(value)
            ns:DB().actionBars.hideBlizzard = value
            RefreshActionBars()
        end)
    y = y - 28

    MakeCheckbox(panel, "隐藏暴雪默认背包条", y,
        function() return ns:DB().actionBars.hideBagBar end,
        function(value)
            ns:DB().actionBars.hideBagBar = value
            RefreshActionBars()
        end)
    y = y - 28

    local SIZE_ITEMS = {}
    for _, size in ipairs({ 20, 24, 28, 32, 36 }) do
        SIZE_ITEMS[#SIZE_ITEMS + 1] = { value = size, text = size .. " px" }
    end

    local SPACING_ITEMS = {}
    for _, gap in ipairs({ 0, 2, 4, 6 }) do
        SPACING_ITEMS[#SPACING_ITEMS + 1] = { value = gap, text = gap .. " px" }
    end

    local COUNT_ITEMS = {}
    for count = 1, 8 do
        COUNT_ITEMS[#COUNT_ITEMS + 1] = { value = count, text = count .. " 组" }
    end

    MakeDropdown(panel, y, "按钮尺寸", SIZE_ITEMS,
        function() return ns:DB().actionBars.buttonSize end,
        function(value)
            ns:DB().actionBars.buttonSize = value
            RefreshActionBars()
        end)
    y = y - 28

    MakeDropdown(panel, y, "按钮间距", SPACING_ITEMS,
        function() return ns:DB().actionBars.spacing end,
        function(value)
            ns:DB().actionBars.spacing = value
            RefreshActionBars()
        end)
    y = y - 28

    MakeDropdown(panel, y, "显示动作条数量", COUNT_ITEMS,
        function() return ns:DB().actionBars.barCount end,
        function(value)
            ns:DB().actionBars.barCount = value
            RefreshActionBars()
        end)
    y = y - 28

    MakeCheckbox(panel, "显示快捷键", y,
        function() return ns:DB().actionBars.showHotkey end,
        function(value)
            ns:DB().actionBars.showHotkey = value
            RefreshActionBars()
        end)
    y = y - 28

    MakeCheckbox(panel, "显示堆叠数量", y,
        function() return ns:DB().actionBars.showCount end,
        function(value)
            ns:DB().actionBars.showCount = value
            RefreshActionBars()
        end)
    y = y - 28

    MakeCheckbox(panel, "显示宏名", y,
        function() return ns:DB().actionBars.showMacro end,
        function(value)
            ns:DB().actionBars.showMacro = value
            RefreshActionBars()
        end)
    y = y - 30

    -- -- Nameplate options ----------------------------------------------------
    MakeSeparator(panel, y, "姓名板")
    y = y - 28

    -- Which units get a plate at all (CVars; see Modules/Nameplates).
    MakeCheckbox(panel, "显示敌方姓名板", y, NameplateCheckbox("showEnemy"))
    y = y - 28
    MakeCheckbox(panel, "显示友方玩家姓名板", y, NameplateCheckbox("showFriendly"))
    y = y - 28
    MakeCheckbox(panel, "显示友方 NPC 姓名板", y, NameplateCheckbox("showNPC"))
    y = y - 28
    MakeCheckbox(panel, "显示低等级（minus）敌人", y, NameplateCheckbox("showMinor"))
    y = y - 28
    MakeCheckbox(panel, "显示图腾", y, NameplateCheckbox("showTotems"))
    y = y - 28
    MakeCheckbox(panel, "显示自己的姓名板", y, NameplateCheckbox("showSelf"))
    y = y - 28
    MakeCheckbox(panel, "过滤小动物", y, NameplateCheckbox("hideCritters"))
    y = y - 28
    MakeCheckbox(panel, "过滤死亡单位", y, NameplateCheckbox("hideDead"))
    y = y - 30

    -- What the plate draws.
    MakeCheckbox(panel, "显示名称", y, NameplateCheckbox("showName"))
    y = y - 28
    MakeCheckbox(panel, "显示等级 / 精英标记", y, NameplateCheckbox("showLevel"))
    y = y - 28
    MakeCheckbox(panel, "显示血量百分比", y, NameplateCheckbox("showPercent"))
    y = y - 28
    MakeCheckbox(panel, "显示施法条", y, NameplateCheckbox("showCast"))
    y = y - 28
    MakeCheckbox(panel, "显示减益光环（借用暴雪）", y, NameplateCheckbox("showDebuffs"))
    y = y - 28
    MakeCheckbox(panel, "职业 / 阵营着色", y, NameplateCheckbox("classColor"))
    y = y - 28
    MakeCheckbox(panel, "仇恨描边", y, NameplateCheckbox("showThreat"))
    y = y - 28
    MakeCheckbox(panel, "当前目标描边高亮", y, NameplateCheckbox("highlightTarget"))
    y = y - 28
    MakeCheckbox(panel, "数值平滑过渡", y, NameplateCheckbox("smooth"))
    y = y - 28
    MakeCheckbox(panel, "同步暴雪点击区域", y, NameplateCheckbox("forcePlateSize"))
    y = y - 30

    local NP_WIDTH = {}
    for _, w in ipairs({ 90, 100, 110, 120, 130, 140, 160 }) do
        NP_WIDTH[#NP_WIDTH + 1] = { value = w, text = w .. " px" }
    end
    local NP_HEIGHT = {}
    for _, h in ipairs({ 8, 10, 12, 14, 16 }) do
        NP_HEIGHT[#NP_HEIGHT + 1] = { value = h, text = h .. " px" }
    end
    local NP_FONT = {}
    for _, s in ipairs({ 9, 10, 11, 12, 13 }) do
        NP_FONT[#NP_FONT + 1] = { value = s, text = s .. " px" }
    end
    local NP_CAST = {}
    for _, h in ipairs({ 11, 12, 13, 14, 16 }) do
        NP_CAST[#NP_CAST + 1] = { value = h, text = h .. " px" }
    end
    local NP_LENGTH = {}
    for _, n in ipairs({ 8, 12, 16, 20, 24 }) do
        NP_LENGTH[#NP_LENGTH + 1] = { value = n, text = n .. " 字" }
    end
    local NP_DISTANCE = {}
    for _, d in ipairs({ 20, 30, 40, 50, 60, 80, 100 }) do
        NP_DISTANCE[#NP_DISTANCE + 1] = { value = d, text = d .. " 码" }
    end

    MakeDropdown(panel, y, "姓名板宽度", NP_WIDTH,
        function() return NameplateSetting("width") end, NameplateSetter("width"))
    y = y - 28
    MakeDropdown(panel, y, "姓名板高度", NP_HEIGHT,
        function() return NameplateSetting("height") end, NameplateSetter("height"))
    y = y - 28
    MakeDropdown(panel, y, "字号", NP_FONT,
        function() return NameplateSetting("nameSize") end, NameplateSetter("nameSize"))
    y = y - 28
    MakeDropdown(panel, y, "施法条高度", NP_CAST,
        function() return NameplateSetting("castHeight") end, NameplateSetter("castHeight"))
    y = y - 28
    MakeDropdown(panel, y, "名称截断长度", NP_LENGTH,
        function() return NameplateSetting("nameLength") end, NameplateSetter("nameLength"))
    y = y - 28
    MakeDropdown(panel, y, "显示距离", NP_DISTANCE,
        function() return NameplateSetting("viewDistance") end, NameplateSetter("viewDistance"))
    y = y - 30

    -- -- Skins (Blizzard panel beautification) -------------------------------
    local skins = ns:GetModule("Skins")
    if skins then
        MakeSeparator(panel, y, "界面美化")
        y = y - 26

        local FONT_ITEMS = {
            { value = "off",     text = "关闭（原生字体）" },
            { value = "pixel",   text = "像素字体（正文）" },
            { value = "roadway", text = "标题字体" },
            { value = "number",  text = "数字字体" },
        }
        MakeDropdown(panel, y, "统一字体（全局）", FONT_ITEMS,
            function() return ns:DB().skins.font end,
            function(value)
                ns:DB().skins.font = value
                if skins.active then
                    skins:ApplyFont()
                    ns:Print("切换字体：重启界面可完全恢复原生字体。")
                end
            end)
        y = y - 24

        local fontHint = Widget:Font(panel, 11, "pixel", "neutral", "LEFT")
        fontHint:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, y)
        fontHint:SetWidth(350)
        fontHint:SetJustifyH("LEFT")
        fontHint:SetText("统一字体影响所有暴雪窗口文字；关闭需重载界面恢复。")
        y = y - 26

        -- Group the windows by section, in registration order.
        local groups, seen = {}, {}
        for _, entry in ipairs(skins.registry) do
            if not seen[entry.group] then
                seen[entry.group] = true
                groups[#groups + 1] = entry.group
            end
        end

        for _, group in ipairs(groups) do
            local caption = Widget:Font(panel, 12, "roadway", "edge", "LEFT")
            caption:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, y)
            caption:SetText("· " .. group)
            y = y - 20

            for _, entry in ipairs(skins.registry) do
                if entry.group == group then
                    MakeCheckbox(panel, entry.label, y,
                        function() return skins:IsEnabled(entry.key) end,
                        function(value) skins:SetPanelEnabled(entry.key, value) end)
                    y = y - 26
                end
            end
        end

        y = y - 4
    end

    -- -- InfoBar (screen-edge strip) ----------------------------------------
    local infobar = ns:GetModule("InfoBar")
    if infobar then
        MakeSeparator(panel, y, "信息栏")
        y = y - 26

        -- Rebuild nothing on a settings change: the strip is re-anchored and
        -- the blocks re-measured in place.
        local function ApplyBar()
            if infobar.Reapply then infobar.Reapply()
            else infobar:ApplyLayout() end
        end

        MakeDropdown(panel, y, "贴边", {
            { value = true,  text = "顶边" },
            { value = false, text = "底边" },
        },
            function() return infobar:Settings().anchorTop end,
            function(value)
                infobar:Settings().anchorTop = value
                ApplyBar()
            end)
        y = y - 28

        MakeDropdown(panel, y, "高度", {
            { value = 12, text = "12 px" },
            { value = 14, text = "14 px" },
            { value = 16, text = "16 px" },
            { value = 18, text = "18 px" },
        },
            function() return infobar:Settings().height end,
            function(value)
                infobar:Settings().height = value
                ApplyBar()
            end)
        y = y - 28

        MakeCheckbox(panel, "悬停淡入（平时只露底板）", y,
            function() return infobar:Settings().mouseover end,
            function(value)
                infobar:Settings().mouseover = value and true or false
                ApplyBar()
            end)
        y = y - 26

        MakeCheckbox(panel, "战斗时边缘呼吸闪烁", y,
            function() return infobar:Settings().combatPulse end,
            function(value)
                infobar:Settings().combatPulse = value and true or false
                if infobar.RefreshPulse then infobar.RefreshPulse() end
            end)
        y = y - 26

        -- One switch per block, in registration order (gold, durability,
        -- currency | system, spec, friends).
        for _, block in ipairs(infobar.blocks) do
            MakeCheckbox(panel, block.label, y,
                function() return infobar:BlockEnabled(block.key) end,
                function(value)
                    local settings = infobar:Settings()
                    if type(settings.blocks) ~= "table" then settings.blocks = {} end
                    settings.blocks[block.key] = value and true or false
                    ApplyBar()
                end)
            y = y - 26
        end

        y = y - 4
    end

    -- -- Footer --------------------------------------------------------------
    -- The row stack keeps growing as features land, so the panel is sized to
    -- whatever was just built rather than to a hard-coded number; the hint and
    -- the reload button live in the strip below the last row.
    panel:SetHeight(math.abs(y) + 78)

    local hint = Widget:Font(panel, 11, "pixel", "neutral", "LEFT")
    hint:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 24, 52)
    hint:SetWidth(352)
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
        CloseDropdown()
        frame:Hide()
    else
        if refreshStatus then refreshStatus() end
        for name, checkbox in pairs(moduleCheckboxes) do
            if checkbox and checkbox.SetChecked then
                checkbox:SetChecked(ns:IsModuleEnabled(name) and true or false)
            end
        end
        RefreshDropdowns()
        frame:Show()
    end
end

function SimpleConfig:Show()
    self:Build():Show()
end

function SimpleConfig:Hide()
    if panel then panel:Hide() end
end
