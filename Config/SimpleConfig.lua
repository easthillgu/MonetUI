-- Config/SimpleConfig.lua
-- Lightweight, themed configuration panel (no Ace3 dependency); all widgets bind straight to MonetUIDB, so changes apply immediately and survive a reload.

local ADDON_NAME, ns = ...


-- 旁表标记（见 Core.lua 的 ns:Mark）：不往暴雪的框体上写字段，
-- 否则那个框体之后跑的暴雪代码会被判成“被 MonetUI 污染”。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
-- 模块私有的幂等守卫键走 per-module 弱旁表（ns:NewFrameData）；跨文件共享键仍走 Mark/Marked。
local FFD, GetFFD = ns:NewFrameData()
local Widget = ns.Widget
local Color = ns.Color
local Media = ns.Media
local Secrets = ns.Secrets   -- Utils/Secrets.lua 在 Config 组之前加载（Utils.xml）

local SimpleConfig = {}
ns.Config = SimpleConfig

local panel
local moduleCheckboxes = {}
local refreshStatus
local refreshZonePreview   -- 区域色预览行（"主题"组里建，开面板 / 主题刷新时各更新一次）

-- The rows live in a scrollable content frame: the panel itself stays a fixed size on
-- screen (it is clamped to the screen, so an unbounded height would push the last
-- sections out of reach), and the content is what moves.
local root, view, scrollThumb, scrollTrack   -- root = 滚动内容根框；各分组（可折叠）挂在它下面
local scrollOffset = 0
local setOffset        -- Build 里定义，Show/Toggle 打开面板时归零

local MODULE_ORDER = {
    "UnitFrames", "Cooldown", "BuffFrame",
    "Minimap", "Bags", "QuestTracker", "ActionBars", "Nameplates", "Skins",
    "InfoBar", "Tooltip", "Cursor", "Toast", "Durability",
    "Atmosphere",
}

local MODULE_LABEL = {
    UnitFrames   = "单位框架 (UnitFrames)",
    Cooldown     = "冷却计时 (Cooldown)",
    BuffFrame    = "增益光环 (BuffFrame)",
    Minimap      = "小地图 (Minimap)",
    Bags         = "分类背包 (Bags)",
    QuestTracker = "任务追踪 (QuestTracker)",
    ActionBars   = "动作条 (ActionBars)",
    Nameplates   = "姓名板 (Nameplates)",
    Skins        = "界面美化 (Skins)",
    InfoBar      = "信息栏 (InfoBar)",
    Tooltip      = "鼠标提示 (Tooltip)",
    Cursor       = "光标拖尾 (Cursor)",
    Toast        = "通知横幅 (Toast)",
    Durability   = "耐久警告 (Durability)",
    Atmosphere   = "氛围暗角 (Atmosphere)",
    Tweaks       = "控制台优化 (Tweaks)",
    WhatsNew     = "更新提示 (WhatsNew)",
}

--- 当前区域名：只用客户端给的字符串（`C_Map.GetMapInfo`），读不到 / 读不出就退回引擎数据表里的名字，
--- 再没有就是"未知区域"。为什么不直接用数据表的名字：未覆盖区是按**父链**取色的
--- （LibMonetColor:563-576），数据表那个 name 是祖先层的（"卡利姆多"），玩家站在新手区看到大陆名会当成 bug。
--- name 之后要进字符串拼接（SetText），所以必须先过一次可否读 —— 本仓判例：`type()` 判不出机密字符串。
local function ZoneNameOf(mapID, engineName)
    if type(mapID) == "number" and type(_G.C_Map) == "table" and _G.C_Map.GetMapInfo then
        local ok, info = pcall(_G.C_Map.GetMapInfo, mapID)
        local nm = ok and type(info) == "table" and info.name
        if type(nm) == "string" and nm ~= "" and Secrets and Secrets.CanRead(nm) then
            return nm
        end
    end
    if type(engineName) == "string" and engineName ~= "" then return engineName end
    return "未知区域"
end

local function MakeCheckbox(parent, label, yOffset, getter, setter)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 24, yOffset)
    cb:SetChecked(getter() and true or false)
    cb:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
    end)
    -- Monet plate + our own checkmark (never tracked: this is our own panel, it must not join the Skins module's rollback list).
    if ns.Skin then ns.Skin:CheckButton(cb) end

    local text = Widget:Font(parent, 12, "pixel", "neutral", "LEFT")
    text:SetPoint("LEFT", cb, "RIGHT", 6, 0)
    -- 单行 + 限宽：长标签（"剩余时间紧张时变红、放大字体"这种）换行后会压到下一行，
    -- 实机看到的就是两行字叠在一起。限宽后最多是被切掉一点，不会重叠。
    text:SetWidth(276)
    text:SetWordWrap(false)
    text:SetText(label)

    return cb, text
end

-- Blizzard's menu framework (UIDropDownMenu / MenuUtil) is not part of the documented client API and differs between builds, so the panel paints its own small themed list instead of depending on either.

local dropdowns = {}   -- list of refreshers, run when the panel is shown
local openList         -- the list currently on screen, if any
local catcher          -- the click-anywhere-else closer

local function CloseDropdown()
    if openList then openList:Hide() end
    openList = nil
    if catcher then catcher:Hide() end
end

--- Covers the screen while a list is open and closes it on any click elsewhere (clicking the dropdown button itself closes, a second click re-opens it).
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

--- A settings row: caption on the left, the current choice on the right, and a floating list of the alternatives under it.
-- @param items { { value = <stored value>, text = <shown label> }, ... }
--- 一个下拉行。swatch 可选：传一个 `(当前值) -> r, g, b` 的函数就在标签和下拉之间画一块
--- 12×12 的实色小方块 —— 配色类下拉光看文字名（"暗织纹" / "高亮红"）根本分不出差别，
--- 看见颜色才知道自己选的是哪个（2026-10-31 玩家反馈"血量颜色设置界面有点混乱"）。
local function MakeDropdown(parent, y, caption, items, getter, setter, swatch)
    local label = Widget:Font(parent, 12, "pixel", "neutral", "LEFT")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", 24, y - 4)
    -- 同 1)：描述限宽到控件左侧，超出的部分切掉而不是钻到下拉框下面
    label:SetWidth(120)
    label:SetWordWrap(false)
    label:SetText(caption)

    local button = Widget:CreateFrame(nil, parent, 190, 20)
    Widget:Theme(button, { thickness = 1, bgAlpha = 0.9 })
    -- 织纹底（ADD 混合，和动作条按钮一致）：垫在 Theme 的深色底板之上、文字之下。
    Widget:ButtonMaterial(button, { alpha = 0, weaveAlpha = 0.25 })
    button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -24, y)
    button:EnableMouse(true)

    local chip, chipFill
    if swatch then
        chip = Widget:CreateFrame(nil, parent, 12, 12)
        Widget:Theme(chip, { thickness = 1, bgAlpha = 1 })
        chip:SetPoint("RIGHT", button, "LEFT", -8, 0)
        pcall(chip.EnableMouse, chip, false)
        chipFill = chip:CreateTexture(nil, "ARTWORK")
        chipFill:SetAllPoints()
    end

    local value = Widget:Font(button, 12, "pixel", "edge", "LEFT")
    value:SetPoint("LEFT", button, "LEFT", 7, 0)
    value:SetPoint("RIGHT", button, "RIGHT", -16, 0)
    -- 长选项（"自动（按分辨率固定，像素完美）"）会折成两行、从 20px 高的按钮里溢出来，
    -- 压到下一行上。关掉换行，超宽就切在按钮右边。
    value:SetWordWrap(false)

    local chevron = Widget:Font(button, 12, "pixel", "neutral", "RIGHT")
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
        if chipFill then
            local ok, r, g, b = pcall(swatch, item and item.value)
            if ok and type(r) == "number" then
                chipFill:SetColorTexture(r, g, b or 0, 1)
            end
        end
    end

    for index, item in ipairs(items) do
        local row = CreateFrame("Button", nil, list)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 2, -2 - (index - 1) * 20)
        row:SetSize(186, 20)
        -- 行的底色比按钮更淡（列表本身已有深色底），只留一层织纹。
        Widget:ButtonMaterial(row, { alpha = 0, weaveAlpha = 0.15 })

        local hover = row:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints()
        -- The HIGHLIGHT texture is only shown on hover, so its colour is sampled then and follows the theme wherever the player is.
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

    local fd = GetFFD(parent)
    if not fd.hideHook then
        fd.hideHook = true
        parent:HookScript("OnHide", CloseDropdown) -- TAINT-OK: parent 是自建设置面板（Widget:CreateFrame），上方有 Marked 幂等守卫
    end

    dropdowns[#dropdowns + 1] = Refresh
    Refresh()
    return button
end

local function RefreshUnitFrames()
    local unitFrames = ns:GetModule("UnitFrames")
    if not unitFrames then return end
    -- Apply 会重涂颜色（血条 / 损失部分 / 能量条）再刷新数值；只有它没有时才退回 UpdateAll。
    if unitFrames.Apply then
        unitFrames:Apply()
    elseif unitFrames.UpdateAll then
        unitFrames:UpdateAll()
    end
end

--- Action-bar changes go through Apply: it re-parks Blizzard's chrome, rebuilds the visibility drivers and re-lays the bars out.
local function RefreshActionBars()
    local actionBars = ns:GetModule("ActionBars")
    if actionBars and actionBars.Apply then actionBars:Apply() end
end

--- 小队 / 团队框架改尺寸或开关都走 Apply：它只在脱战重贴安全头（战斗中会自动排队）。
local function RefreshGroups()
    local groups = ns:GetModule("GroupFrames")
    if groups and groups.Apply then groups:Apply() end
end

--- Nameplate settings live in MonetUIDB.nameplates; Apply re-pushes the CVars, the hitbox size and repaints whatever is on screen.
local function RefreshNameplates()
    local nameplates = ns:GetModule("Nameplates")
    if nameplates and nameplates.Apply then nameplates:Apply() end
end

--- Read a nameplate setting through the module (so it falls back to Core's shipped defaults), then write it back and repaint.
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

--- One setting, read from a group of units and written to all of them: the units ship with different defaults but a group is meant to move together.
local function UnitSetting(units, key, default)
    local function get()
        local unitFrames = ns:DB().unitFrames or {}
        for _, unit in ipairs(units) do
            local stored = unitFrames[unit]
            local value = stored and stored[key]
            if value ~= nil then return value end   -- a stored false is a real choice
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

function SimpleConfig:Build()
    if panel then return panel end

    panel = Widget:CreateFrame("MonetUIConfigFrame", UIParent, 400, 800)
    -- 直角版（square-blp）：不带 round，走 SetBackdrop 的直角边框。
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

    local title = Widget:Font(panel, 24, "pixel", "edge", "CENTER")
    title:SetPoint("TOP", panel, "TOP", 0, -16)
    title:SetText("MonetUI")

    -- Logo：就是插件列表那张睡莲图标，挂标题左侧、垂直居中（边中点对边中点）。
    -- 整图烘焙彩色（见 Media 注册处），只给 alpha，不染色。
    local logo = panel:CreateTexture(nil, "ARTWORK")
    logo:SetTexture(Media:Texture("monet_addon_icon"))
    logo:SetSize(24, 24)
    logo:SetPoint("RIGHT", title, "LEFT", -8, 0)

    local subtitle = Widget:Font(panel, 12, "pixel", "neutral", "CENTER")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -4)
    subtitle:SetText("v" .. ns.version .. " · 印象派自适应界面")

    local close = Widget:CloseButton(panel)
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)
    if ns.Skin then ns.Skin:CloseButton(close) end

    -- Chrome: a cool drop shadow plus brush corner ornaments; the top-right corner stays bare because the close button already owns it.
    Widget:Shadow(panel, { size = 7, alpha = 0.5 })
    Widget:Corners(panel, { omit = { "TOPRIGHT" } })

    -- Scrollable body: the rows are parented to `content`, which sits inside a clipping
    -- `view`.  The view starts below the subtitle, so a scrolled row never slides over
    -- the title.
    view = CreateFrame("Frame", nil, panel)
    view:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, -50)
    view:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -24, 58)
    view:SetClipsChildren(true)

    root = CreateFrame("Frame", nil, view)
    root:SetPoint("TOPLEFT", view, "TOPLEFT", 0, 0)
    root:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, 0)
    root:SetHeight(100)

    -- ---- 可折叠分组 ------------------------------------------------------------
    -- 每个分组 = 一个容器（常显的标题带 + 可隐藏的 body）。行代码不用改：
    -- 它们照旧以 `content`（= 当前分组的 body）左上角为原点、行偏移由 `row` 光标给出。
    -- 展开状态变了只做一件事：relayout() 把各组重新摞一遍、面板跟着内容缩放。
    local SECTIONS = {}
    local HEADER_H = 24
    local relayout          -- 定义在滚动逻辑里（要用到 SetOffset）
    local content, row, sec   -- row = 行布局光标(每个分组 LayoutCursor(0) 重新赋值)

    -- 光标式行布局(review 2026-10-24 #8):设置面板是纯垂直流,以前每行手写
    -- "y = y - 28" 记账、增删一行要重算一片偏移;现在 row(h) 取"当前行的 y"并
    -- 前进 h —— 取用即记账。row.y 为纯读(分组结算 bodyHeight 用)。
    local function LayoutCursor(yStart)
        return setmetatable({ y = yStart }, {
            __call = function(self, step)
                local at = self.y
                self.y = self.y - step
                return at
            end,
        })
    end

    local function BeginSection(caption, expanded)
        local holder = CreateFrame("Frame", nil, root)
        holder:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
        holder:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, 0)
        holder:SetHeight(HEADER_H)

        local header = CreateFrame("Button", nil, holder)
        header:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        header:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, 0)
        header:SetHeight(HEADER_H)
        header:EnableMouse(true)

        local line = header:CreateTexture(nil, "ARTWORK")
        line:SetPoint("TOPLEFT", header, "TOPLEFT", 20, -6)
        line:SetPoint("TOPRIGHT", header, "TOPRIGHT", -20, -6)
        line:SetHeight(1)
        local nr, ng, nb = Color:GetNeutral()
        line:SetColorTexture(nr, ng, nb, 0.35)

        -- 展开标记画在标题**左边**，标题再往右让 14：这样折叠时那一行仍然是可读的"分组名"。
        local mark = Widget:Font(header, 12, "pixel", "edge", "LEFT")
        mark:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -3)
        mark:SetText(expanded and "-" or "+")

        local title = Widget:Font(header, 12, "pixel", "edge", "LEFT")
        title:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 14, -3)
        title:SetText(caption)

        local glow = header:CreateTexture(nil, "HIGHLIGHT")
        glow:SetAllPoints(header)
        glow:SetColorTexture(1, 1, 1, 0.05)

        local body = CreateFrame("Frame", nil, holder)
        body:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -HEADER_H)
        body:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, -HEADER_H)
        body:SetHeight(1)
        body:SetShown(expanded)

        local entry = { holder = holder, body = body, mark = mark, expanded = expanded, bodyHeight = 1 }
        SECTIONS[#SECTIONS + 1] = entry

        header:SetScript("OnClick", function()
            entry.expanded = not entry.expanded
            entry.body:SetShown(entry.expanded)
            entry.mark:SetText(entry.expanded and "-" or "+")
            CloseDropdown()
            if relayout then relayout() end
        end)

        return entry
    end

    -- Slim scrollbar on the right: a track plus a draggable thumb, both drawn here
    -- (the client's own scrollbar art is not part of the Monet look).
    scrollTrack = panel:CreateTexture(nil, "ARTWORK")
    scrollTrack:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, -50)
    scrollTrack:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -14, 58)
    scrollTrack:SetWidth(4)
    local nr, ng, nb = Color:GetNeutral()
    scrollTrack:SetColorTexture(nr, ng, nb, 0.25)

    scrollThumb = CreateFrame("Button", nil, panel)
    scrollThumb:SetPoint("TOPLEFT", scrollTrack, "TOPLEFT", 0, 0)
    scrollThumb:SetWidth(4)
    scrollThumb:SetHeight(40)
    scrollThumb:EnableMouse(true)
    local thumbTex = scrollThumb:CreateTexture(nil, "BACKGROUND")
    thumbTex:SetAllPoints()
    local er, eg, eb = Color:GetEdge()
    thumbTex:SetColorTexture(er, eg, eb, 0.8)

    -- The scrollbar is drawn by hand, so it does not follow Widget's theme registry;
    -- repaint it when the theme changes.
    ns.EventBus:Register("MONETUI_THEME_CHANGED", function()
        if not panel then return end
        local nr, ng, nb = Color:GetNeutral()
        local er, eg, eb = Color:GetEdge()
        scrollTrack:SetColorTexture(nr, ng, nb, 0.25)
        thumbTex:SetColorTexture(er, eg, eb, 0.8)
    end)

    -- 主题 / 模块：默认展开（其余收起，一屏就能看完，点标题带展开）
    sec = BeginSection("主题", true)
    content = sec.body
    row = LayoutCursor(0)

    MakeCheckbox(content, "使用 MonetColor 动态主题", row(28),
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

    local statusText = Widget:Font(content, 12, "pixel", "neutral", "LEFT")
    statusText:SetPoint("TOPLEFT", content, "TOPLEFT", 46, row(20))
    statusText:SetWidth(300)
    statusText:SetJustifyH("LEFT")

    refreshStatus = function()
        local source, profile = Color:GetSource()
        local colorText
        if source == "monet" then
            colorText = string.format("引擎输出 · 配置 %s", tostring(profile))
        else
            colorText = ns:HasMonetColor() and "内置调色板（引擎已关闭）" or "内置调色板（未找到 LibMonetColor）"
        end
        statusText:SetText(colorText)
        -- 关掉 / 打开 MonetColor 会换掉整本主题，区域预览行跟着重算（它在下面定义，
        -- 这里只是引用那个 local 单元格：Build 里第一次调 refreshStatus 时它还是 nil，守卫兜住）。
        if refreshZonePreview then refreshZonePreview() end
    end
    refreshStatus()

    -- 区域色预览（2026-11-03）——玩家唯一能看见"这一区到底采到色没有"的入口。
    -- 运行期配色 = mapID 查表 → 环境 HSL → 莫奈规则派生四槽 → 亮度阶梯定位（LibMonetColor:619/647-650），
    -- 全程零像素读取；没采到色的区域落**无彩灰兜底**（:78），而"这一区本来就是灰的"和"没数据"
    -- 在屏幕上长得一模一样。这一行把两件事分开：左边当前区域名 + 右边阶梯四档实色块，
    -- 缺数据时另外标一句。纯 UI：数据全走 Color（GetZoneInfo 查表、GetSurface 读阶梯）。
    local yZone = row(20)
    local zoneCaption = Widget:Font(content, 12, "pixel", "neutral", "LEFT")
    zoneCaption:SetPoint("TOPLEFT", content, "TOPLEFT", 24, yZone - 4)
    zoneCaption:SetWidth(96)
    zoneCaption:SetWordWrap(false)
    zoneCaption:SetText("区域配色")

    -- 四档 = Color.lua 的 SURFACE_STEPS 里"画在屏幕上"的那四档
    -- （panel / hover / lost / fill；weave 是织纹发丝线，不是一块底衬，不进这一行）。
    -- 色块取 RGB 后按 alpha 1 平涂，和下拉行的 swatch 同一口径（Color:GetSurface 只给 RGB，
    -- 不透明度归调用点 —— 见该函数注释），玩家看到的就是这一档**最终**的颜色。
    local ZONE_STEPS = { "panel", "hover", "lost", "fill" }
    local zoneChips, zoneFills = {}, {}
    for i = #ZONE_STEPS, 1, -1 do
        local chip = Widget:CreateFrame(nil, content, 12, 12)
        Widget:Theme(chip, { thickness = 1, bgAlpha = 1 })
        if i == #ZONE_STEPS then
            chip:SetPoint("TOPRIGHT", content, "TOPRIGHT", -24, yZone)
        else
            chip:SetPoint("RIGHT", zoneChips[i + 1], "LEFT", -6, 0)
        end
        pcall(chip.EnableMouse, chip, false)
        local fill = chip:CreateTexture(nil, "ARTWORK")
        fill:SetAllPoints()
        zoneChips[i] = chip
        zoneFills[i] = fill
    end

    local zoneText = Widget:Font(content, 12, "pixel", "neutral", "LEFT")
    zoneText:SetPoint("LEFT", zoneCaption, "RIGHT", 8, 0)
    zoneText:SetPoint("RIGHT", zoneChips[1], "LEFT", -8, 0)
    zoneText:SetWordWrap(false)

    -- 第二行：左边一句状态（缺色时才有字），右边四档的名字，按从暗到亮的阶梯顺序。
    local yMark = row(16)
    local zoneMark = Widget:Font(content, 10, "pixel", "edge", "LEFT")
    zoneMark:SetPoint("TOPLEFT", content, "TOPLEFT", 24, yMark - 2)
    zoneMark:SetWidth(216)
    zoneMark:SetWordWrap(false)
    zoneMark:SetText("")

    local zoneLegend = Widget:Font(content, 10, "pixel", "neutral", "RIGHT")
    zoneLegend:SetPoint("TOPRIGHT", content, "TOPRIGHT", -24, yMark - 2)
    zoneLegend:SetWordWrap(false)
    zoneLegend:SetText("面板 · 悬停 · 空槽 · 填充")

    refreshZonePreview = function()
        local mapID, engineName, source = Color:GetZoneInfo()
        if not Color:HasMonetColor() then
            zoneText:SetText("引擎未接入 · 内置调色板")
            zoneMark:SetText("")
        elseif not mapID then
            zoneText:SetText("区域未知")
            zoneMark:SetText("读不到当前地图 ID（受限窗口），配色退回兜底灰")
        elseif source == "fallback" then
            zoneText:SetText(ZoneNameOf(mapID, engineName))
            zoneMark:SetText("这个区域没有环境色记录 · 四档走兜底灰")
        else
            zoneText:SetText(ZoneNameOf(mapID, engineName))
            -- 父链继承 / 派生父层：颜色来自更大的一片区域，如实写出来（数据表的 name 就是那一片的名字）
            local inherited = source == "override"
                or (type(source) == "string" and string.find(source, "^parent:") ~= nil)
            zoneMark:SetText(inherited and type(engineName) == "string" and engineName ~= ""
                and ("环境色取自 " .. engineName) or "")
        end
        for i = 1, #ZONE_STEPS do
            local r, g, b = Color:GetSurface(ZONE_STEPS[i])
            zoneFills[i]:SetColorTexture(r, g, b, 1)
        end
    end
    refreshZonePreview()
    -- 区域切换 / 引擎回调 / 关掉 MonetColor 都会广播主题刷新，这一行跟着重算一遍。
    ns.EventBus:Register("MONETUI_THEME_CHANGED", function()
        if refreshZonePreview then refreshZonePreview() end
    end)

    -- Border colour source: one row re-tints every border in the addon, because they all draw through Widget:Theme -> Color:GetBorder.
    local BORDER_ITEMS = {
        { value = "edge",      text = "边缘色（Monet 签名）" },
        { value = "ambient",   text = "环境色" },
        { value = "highlight", text = "高亮色" },
        { value = "neutral",   text = "中性灰" },
    }
    MakeDropdown(content, row(28), "边框颜色", BORDER_ITEMS,
        function() return Color:GetBorderKey() end,
        function(value)
            ns:DB().theme.borderKey = value
            ns.RefreshTheme("config")
        end)

    -- UI scale: the addon's sizes are authored in UI units, so the scale decides whether
    -- they land on whole physical pixels.  "auto" pins it per resolution (see
    -- Utils/Media.lua scalePresets); "game" leaves it to the client's own setting.
    local SCALE_ITEMS = {
        { value = "auto", text = "自动（按分辨率固定）" },
        { value = "game", text = "跟随游戏设置" },
    }
    MakeDropdown(content, row(28), "UI 缩放", SCALE_ITEMS,
        function() return (ns:DB().theme or {}).uiScaleMode or "auto" end,
        function(value)
            ns:DB().theme.uiScaleMode = value
            if value == "auto" then
                ns:DB().theme.uiScaleApplied = nil
            end
            ns:Print("UI 缩放模式：" .. (value == "auto" and "自动（下次 /reload 生效）" or "跟随游戏设置") .. "。")
        end)

    sec.bodyHeight = -row.y + 4

    sec = BeginSection("模块", true)
    content = sec.body
    row = LayoutCursor(0)

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
        moduleCheckboxes[name] = MakeCheckbox(content, MODULE_LABEL[name] or name, row(28),
            moduleGetter(name), moduleSetter(name))
    end

    sec.bodyHeight = -row.y + 4

    sec = BeginSection("冷却计时", false)
    content = sec.body
    row = LayoutCursor(0)

    local function CooldownSaved()
        local db = ns:DB()
        if type(db.cooldown) ~= "table" then db.cooldown = {} end
        return db.cooldown
    end

    --- Re-render every countdown right away (colour, size, unit switch).
    local function CooldownRefresh()
        local cooldowns = ns:GetModule("Cooldown")
        if cooldowns and cooldowns.ApplyDisplay then cooldowns:ApplyDisplay() end
    end

    local function CooldownSetting(key)
        return function()
            local saved = ns:DB().cooldown
            local value = saved and saved[key]
            if value == nil then value = (ns.DEFAULTS.cooldown or {})[key] end
            return value
        end
    end

    MakeCheckbox(content, "单位自动缩放（秒 → 分钟 → 小时 → 天）", row(28),
        CooldownSetting("scale"),
        function(value)
            CooldownSaved().scale = value
            CooldownRefresh()
        end)

    MakeCheckbox(content, "剩余时间紧张时变红 + 放大字体", row(28),
        CooldownSetting("alert"),
        function(value)
            CooldownSaved().alert = value
            CooldownRefresh()
        end)

    local ALERT_ITEMS = {
        { value = 3,  text = "3 秒" },
        { value = 5,  text = "5 秒" },
        { value = 8,  text = "8 秒" },
        { value = 10, text = "10 秒" },
    }
    MakeDropdown(content, row(30), "紧张阈值（秒）", ALERT_ITEMS,
        CooldownSetting("alertSeconds"),
        function(value)
            CooldownSaved().alertSeconds = value
            CooldownRefresh()
        end)

    -- TenthTH: below this many seconds show one decimal ("4.3").
    local TENTH_ITEMS = {
        { value = 0,  text = "关闭" },
        { value = 3,  text = "3 秒" },
        { value = 5,  text = "5 秒" },
        { value = 10, text = "10 秒" },
        { value = 20, text = "20 秒" },
    }
    MakeDropdown(content, row(30), "小数秒阈值（低于则显示 0.1s）", TENTH_ITEMS,
        CooldownSetting("tenthsTH"),
        function(value)
            CooldownSaved().tenthsTH = value
            CooldownRefresh()
        end)

    -- MmssTH: at/above this many seconds use mm:ss ("1:05").
    local MMSS_ITEMS = {
        { value = 0,   text = "关闭（用 1m / 1h）" },
        { value = 30,  text = "30 秒" },
        { value = 60,  text = "60 秒" },
        { value = 120, text = "120 秒" },
    }
    MakeDropdown(content, row(30), "m:ss 阈值（达到则显示 1:05）", MMSS_ITEMS,
        CooldownSetting("mmssTH"),
        function(value)
            CooldownSaved().mmssTH = value
            CooldownRefresh()
        end)

    sec.bodyHeight = -row.y + 4

    local minimap = ns:GetModule("Minimap")
    if minimap then
        sec = BeginSection("小地图", false)
        content = sec.body
        row = LayoutCursor(0)

        local function MapSetting(key)
            return function() return minimap:GetSettings()[key] end
        end
        local function MapSetter(key)
            return function(value)
                minimap:GetSettings()[key] = value
                if minimap.Apply then minimap:Apply() end
            end
        end

        MakeCheckbox(content, "悬停小地图时显示区域名", row(26),
            MapSetting("zoneText"), MapSetter("zoneText"))

        MakeCheckbox(content, "战区时区域名染成危险色", row(26),
            MapSetting("zonePvPColor"), MapSetter("zonePvPColor"))

        MakeCheckbox(content, "滚轮缩放（方形地图四角也够得到）", row(26),
            MapSetting("scrollZoom"), MapSetter("scrollZoom"))

        MakeCheckbox(content, "右键小地图弹出微型游戏菜单", row(28),
            MapSetting("microMenu"), MapSetter("microMenu"))

        MakeCheckbox(content, "微型菜单用全量安全载体（自有动作 + 代点原生按钮）", row(28),
            MapSetting("microMenuSecure"), MapSetter("microMenuSecure"))

        -- 地图形状只有一套（正方画布 + 遮罩裁带），不再提供切换

        -- 地图内的三个独立按钮（3:4 矩形图标）
        local mapCaption = Widget:Font(content, 12, "pixel", "edge", "LEFT")
        mapCaption:SetPoint("TOPLEFT", content, "TOPLEFT", 24, row(22))
        mapCaption:SetText("· 地图内的按钮")

        MakeCheckbox(content, "追踪（左下）", row(26),
            MapSetting("mapTracking"), MapSetter("mapTracking"))

        MakeCheckbox(content, "难度（左上）", row(26),
            MapSetting("mapDifficulty"), MapSetter("mapDifficulty"))

        MakeCheckbox(content, "插件收纳（右上）", row(24),
            MapSetting("mapCompartment"), MapSetter("mapCompartment"))

        local mapHint = Widget:Font(content, 12, "pixel", "neutral", "LEFT")
        mapHint:SetPoint("TOPLEFT", content, "TOPLEFT", 24, row(38))
        mapHint:SetWidth(328)
        mapHint:SetJustifyH("LEFT")
        mapHint:SetText("追踪 / 插件收纳开着时，暴雪原来那一个被搬进地图，不再单独隐藏。")
        -- 上面这句在 328 宽里折成两行，行距要给到 38 才不压下一行。

        -- 手势速查（写在面板里，免得翻文档）
        local gestureHint = Widget:Font(content, 12, "pixel", "neutral", "LEFT")
        gestureHint:SetPoint("TOPLEFT", content, "TOPLEFT", 24, row(38))
        gestureHint:SetWidth(328)
        gestureHint:SetJustifyH("LEFT")
        gestureHint:SetText("左键打标记（四个角也算）· 中键开追踪菜单 · 右键微型菜单 · 滚轮缩放")

        -- 底边高度是统一的（Utils/Layout.lua 的基线，和第一动作条同一条线），
        -- 这个下拉只管**右边缘**离屏幕右边多远。
        MakeDropdown(content, row(30), "右边缘间距", {
            { value = 0,  text = "0（贴边）" },
            { value = 16, text = "16" },
            { value = 33, text = "33（默认）" },
            { value = 50, text = "50" },
            { value = 66, text = "66" },
        }, MapSetting("gap"), MapSetter("gap"))

        -- 暴雪的集群按钮：勾选＝藏起来（方形面板和暴雪原样按钮混在一起最难看），
        -- 取消勾选＝把暴雪那个按钮原样放回来。
        local caption = Widget:Font(content, 12, "pixel", "edge", "LEFT")
        caption:SetPoint("TOPLEFT", content, "TOPLEFT", 24, row(22))
        caption:SetText("· 暴雪集群按钮（勾选＝藏起来）")

        for _, entry in ipairs(minimap:ButtonList()) do
            -- 追踪 / 插件收纳由"地图内的按钮"那一组管，这里不重复列
            if not entry.skipKey then
                MakeCheckbox(content, entry.label, row(26), MapSetting(entry.key), MapSetter(entry.key))
            end
        end

        row(4)                -- 行尾留白：纯前进，不取位置
        sec.bodyHeight = -row.y + 4
    end

    sec = BeginSection("单位框架", false)
    content = sec.body
    row = LayoutCursor(0)

    MakeCheckbox(content, "隐藏暴雪默认的玩家/目标框架（需重载恢复）", row(30),
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

    -- 分成两组的理由是 2026-10-25 的配色案：玩家 / 宠物 / 目标的目标是一套"反相 + 暗织纹"
    -- （和小队/团队格同款，见 Groups.lua），目标 / 焦点保持职业色 + 红色空槽。
    -- 一组两个下拉（血条 + 空槽），组内默认必须一致 —— 否则 UnitSetting 显示的是
    -- 组里第一个单位的值，玩家一改就整组跟着变。
    --
    -- 2026-10-31 重排（玩家反馈"血量颜色设置界面有点混乱"）：
    --   原来四行的标签是「玩家 / 宠物 / 目标的目标 血条」这种长句，120px 的标签列装不下、
    --   被切掉，四行前缀又几乎一样 —— 看不出哪个属于哪一组。现在：
    --     组名单独一行（edge + 细线）→ 组内两行只写「血条」「空槽」；
    --     每个下拉右边加一块 12×12 实色块，颜色直接取自**真正上色用的函数**
    --     （UnitFrames:PreviewColor），所以面板上看到的色 = 条上的色。
    local COLOR_GROUPS = {
        { label = "玩家 / 宠物 / 目标的目标", units = { "player", "pet", "targettarget" },
          fill = "inverse", lost = "weave" },
        { label = "目标 / 焦点", units = { "target", "focus" },
          fill = "class", lost = "danger" },
    }

    local FILL_ITEMS = {
        { value = "inverse",   text = "反相（主题阶梯）" },
        { value = "highlight", text = "高亮色（Monet）" },
        { value = "class",     text = "职业 / 阵营色" },
        { value = "health",    text = "生命绿" },
        { value = "dark",      text = "深色（反相）" },
    }
    local LOST_ITEMS = {
        { value = "weave",   text = "暗织纹（主题阶梯）" },
        { value = "danger",  text = "高亮红" },
        { value = "black",   text = "黑色（背景）" },
        { value = "light",   text = "浅灰（反相）" },
        { value = "theme25", text = "主题色 25%" },
    }
    local POWER_ITEMS = {
        { value = "type",  text = "按能量类型" },
        { value = "theme", text = "统一主题色" },
    }

    -- 预览色：走模块里的同一套函数（面板上看到的色就是条上的色）。
    local unitFrames = ns:GetModule("UnitFrames")
    local function Preview(kind, unit)
        return function(value)
            if unitFrames and type(unitFrames.PreviewColor) == "function" then
                return unitFrames:PreviewColor(kind, value, unit)
            end
        end
    end

    -- 组名一行（edge 色 + 下面一条发丝线），把"哪个下拉属于哪一组"从标签里拆出来。
    local function GroupHeader(caption, y)
        local fs = Widget:Font(content, 12, "pixel", "edge", "LEFT")
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 24, y - 4)
        fs:SetText(caption)
        local line = content:CreateTexture(nil, "ARTWORK")
        line:SetPoint("TOPLEFT", content, "TOPLEFT", 24, y - 20)
        line:SetPoint("TOPRIGHT", content, "TOPRIGHT", -24, y - 20)
        line:SetHeight(1)
        local nr, ng, nb = Color:GetNeutral()
        line:SetColorTexture(nr, ng, nb, 0.25)
    end

    for _, group in ipairs(COLOR_GROUPS) do
        GroupHeader(group.label, row(30))
        local unit = group.units[1]
        -- UnitSetting 返回 (get, set) **两个值**：直接塞在参数表里时，只有出现在最后一位才会
        -- 展开；放中间会被截成 1 个值，后面的参数就整体错位（第一版就是这样把 swatch 挤进了
        -- setter 位、下拉选择变成静默不保存）。所以这里显式接住再说。
        local getFill, setFill = UnitSetting(group.units, "fillColor", group.fill)
        local getLost, setLost = UnitSetting(group.units, "lostColor", group.lost)
        MakeDropdown(content, row(26), "血条", FILL_ITEMS, getFill, setFill, Preview("fill", unit))
        MakeDropdown(content, row(26), "空槽（损失部分）", LOST_ITEMS, getLost, setLost, Preview("lost", unit))
    end

    GroupHeader("能量条", row(30))
    MakeDropdown(content, row(26), "颜色", POWER_ITEMS,
        function() return ns:DB().unitFrames.powerColor end,
        function(value)
            ns:DB().unitFrames.powerColor = value
            RefreshUnitFrames()
        end,
        function(value)
            if value == "theme" then return Color:GetResource() end
            -- "按能量类型"：用玩家当前的资源类型作参考（预览而已）
            local _, token = UnitPowerType("player")
            local map = { MANA = { 0.20, 0.50, 0.90 }, RAGE = { 0.85, 0.20, 0.20 },
                          ENERGY = { 0.90, 0.85, 0.25 }, FOCUS = { 0.85, 0.45, 0.15 } }
            local c = map[token or ""]
            if c then return c[1], c[2], c[3] end
            return Color:GetResource()
        end)

    local fillHint = Widget:Font(content, 12, "pixel", "neutral", "LEFT")
    fillHint:SetPoint("TOPLEFT", content, "TOPLEFT", 24, row(46))
    fillHint:SetWidth(328)
    fillHint:SetJustifyH("LEFT")
    fillHint:SetText("血条 = 有血的那段；空槽 = 掉掉的那段（选实色时那层布纹会自动压淡）。右边小方块就是实际颜色。")

    -- One row for two settings: 0 means "off", anything else is the pip height.
    local CLASS_ITEMS = {
        { value = 0, text = "关闭" },
        { value = 2, text = "2 px" },
        { value = 3, text = "3 px" },
        { value = 4, text = "4 px" },
        { value = 5, text = "5 px" },
    }

    MakeDropdown(content, row(28), "连击点（盗贼 / 德鲁伊）", CLASS_ITEMS,
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

    MakeCheckbox(content, "血量数字按百分比着色", row(28),
        function() return ns:DB().unitFrames.textColorByPercent end,
        function(value)
            ns:DB().unitFrames.textColorByPercent = value
            RefreshUnitFrames()
        end)

    MakeCheckbox(content, "血条数值平滑过渡", row(28),
        function() return ns:DB().unitFrames.smoothBars end,
        function(value)
            ns:DB().unitFrames.smoothBars = value
            RefreshUnitFrames()
        end)

    MakeCheckbox(content, "宠物框悬停 / 选中才显示", row(30),
        function() return ns:DB().unitFrames.petHover ~= false end,
        function(value)
            ns:DB().unitFrames.petHover = value
            RefreshUnitFrames()
        end)

    local NUMBER_ITEMS = {
        { value = "auto", text = "自动 (K / M / B)" },
        { value = "cn",   text = "中文 (万 / 亿)" },
    }
    MakeDropdown(content, row(30), "大数字格式", NUMBER_ITEMS,
        function() return ns:DB().numberFormat end,
        function(value)
            ns:DB().numberFormat = value
            RefreshUnitFrames()
        end)

    -- The borrowed list's on/off is decided when Blizzard's TargetFrame is first suppressed, so -- like "hideBlizzard" above -- this applies on the next load: a runtime switch cannot re-register what a full-kill removed.
    MakeCheckbox(content, "显示目标框光环（借用暴雪，需重载）", row(30),
        function() return ns:DB().unitFrames.showTargetAuras end,
        function(value)
            ns:DB().unitFrames.showTargetAuras = value
            RefreshUnitFrames()
        end)

    sec.bodyHeight = -row.y + 4

    sec = BeginSection("小队 / 团队框架", false)
    content = sec.body
    row = LayoutCursor(0)

    local function GroupGetter(section, key, fallback)
        return function()
            local cfg = ns:DB().groupFrames
            local value = cfg and cfg[section] and cfg[section][key]
            if value == nil then return fallback end
            return value
        end
    end

    local function GroupSetter(section, key)
        return function(value)
            ns:DB().groupFrames[section][key] = value
            RefreshGroups()
        end
    end

    MakeCheckbox(content, "小队框架（自己 + 小队 1-4）", row(26),
        GroupGetter("party", "enabled", true), GroupSetter("party", "enabled"))

    MakeCheckbox(content, "团队框架（8 组 × 5 人）", row(26),
        GroupGetter("raid", "enabled", true), GroupSetter("raid", "enabled"))

    MakeCheckbox(content, "小队框里显示自己", row(26),
        GroupGetter("party", "showPlayer", true), GroupSetter("party", "showPlayer"))

    MakeCheckbox(content, "隐藏暴雪自带的小队 / 团队框", row(30),
        function() return ns:DB().groupFrames.hideBlizzard end,
        function(value)
            ns:DB().groupFrames.hideBlizzard = value
            RefreshGroups()
        end)

    local PARTY_WIDTHS = {
        { value = 100, text = "100 px" },
        { value = 110, text = "110 px" },
        { value = 120, text = "120 px" },
        { value = 140, text = "140 px" },
    }
    MakeDropdown(content, row(28), "小队框宽度", PARTY_WIDTHS,
        GroupGetter("party", "width", 110), GroupSetter("party", "width"))

    local RAID_WIDTHS = {
        { value = 60, text = "60 px" },
        { value = 72, text = "72 px" },
        { value = 84, text = "84 px" },
        { value = 96, text = "96 px" },
    }
    MakeDropdown(content, row(28), "团队框宽度", RAID_WIDTHS,
        GroupGetter("raid", "width", 72), GroupSetter("raid", "width"))

    local HEALTH_TEXT_MODES = {
        { value = "none", text = "不显示" },
        { value = "percent", text = "百分比" },
        { value = "value", text = "当前值" },
    }
    MakeDropdown(content, row(28), "小队血量文字", HEALTH_TEXT_MODES,
        GroupGetter("party", "healthText", "none"), GroupSetter("party", "healthText"))

    MakeDropdown(content, row(26), "团队血量文字", HEALTH_TEXT_MODES,
        GroupGetter("raid", "healthText", "none"), GroupSetter("raid", "healthText"))

    MakeCheckbox(content, "血条上显示治疗预估（主题色的浅色延伸段）", row(26),
        function() return ns:DB().groupFrames.showIncomingHeals ~= false end,
        function(value)
            ns:DB().groupFrames.showIncomingHeals = value
            RefreshGroups()
        end)

    MakeCheckbox(content, "血条上显示吸收盾（白色叠层）", row(30),
        function() return ns:DB().groupFrames.showAbsorbs ~= false end,
        function(value)
            ns:DB().groupFrames.showAbsorbs = value
            RefreshGroups()
        end)

    MakeCheckbox(content, "锁定所有可移动框（网格吸附与拖动）", row(30),
        function() return ns:DB().mover.locked end,
        function(value)
            ns:DB().mover.locked = value
            -- 锁是即时判断的（拖动时才读），不需要重贴：下一帧拖动就按新状态走
        end)

    sec.bodyHeight = -row.y + 4

    sec = BeginSection("首领框架", false)
    content = sec.body
    row = LayoutCursor(0)

    local function BossGetter(key, fallback)
        return function()
            local cfg = ns:DB().bossFrames
            local value = cfg and cfg[key]
            if value == nil then return fallback end
            return value
        end
    end

    local function BossSetter(key)
        return function(value)
            local cfg = ns:DB().bossFrames
            if cfg then cfg[key] = value end
            local mod = ns:GetModule("BossFrames")
            if mod and type(mod.Apply) == "function" then mod:Apply() end
        end
    end

    MakeCheckbox(content, "启用首领框架", row(26),
        BossGetter("enabled", true), BossSetter("enabled"))

    MakeCheckbox(content, "隐藏暴雪自带首领框", row(26),
        BossGetter("hideBlizzard", true),
        function(value)
            local cfg = ns:DB().bossFrames
            if cfg then cfg.hideBlizzard = value end
            local mod = ns:GetModule("BossFrames")
            if mod and type(mod.Apply) == "function" then mod:Apply() end
        end)

    local BOSS_WIDTHS = {
        { value = 140, text = "140 px" },
        { value = 160, text = "160 px" },
        { value = 180, text = "180 px" },
        { value = 200, text = "200 px" },
    }
    MakeDropdown(content, row(28), "首领框宽度", BOSS_WIDTHS,
        BossGetter("width", 180), BossSetter("width"))

    local BOSS_HEALTH = {
        { value = 14, text = "14 px" },
        { value = 16, text = "16 px" },
        { value = 20, text = "20 px" },
        { value = 24, text = "24 px" },
    }
    MakeDropdown(content, row(28), "首领血条高度", BOSS_HEALTH,
        BossGetter("health", 20), BossSetter("health"))

    MakeDropdown(content, row(28), "首领血量文字", HEALTH_TEXT_MODES,
        BossGetter("healthText", "none"), BossSetter("healthText"))

    sec.bodyHeight = -row.y + 4

    sec = BeginSection("动作条", false)
    content = sec.body
    row = LayoutCursor(0)

    MakeCheckbox(content, "自绘动作条（LibActionButton）", row(28),
        function() return ns:DB().actionBars.ownBars end,
        function(value)
            ns:DB().actionBars.ownBars = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "隐藏暴雪默认动作条", row(28),
        function() return ns:DB().actionBars.hideBlizzard end,
        function(value)
            ns:DB().actionBars.hideBlizzard = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "隐藏暴雪默认背包条", row(28),
        function() return ns:DB().actionBars.hideBagBar end,
        function(value)
            ns:DB().actionBars.hideBagBar = value
            RefreshActionBars()
        end)

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

    MakeDropdown(content, row(28), "按钮尺寸", SIZE_ITEMS,
        function() return ns:DB().actionBars.buttonSize end,
        function(value)
            ns:DB().actionBars.buttonSize = value
            RefreshActionBars()
        end)

    MakeDropdown(content, row(28), "按钮间距", SPACING_ITEMS,
        function() return ns:DB().actionBars.spacing end,
        function(value)
            ns:DB().actionBars.spacing = value
            RefreshActionBars()
        end)

    MakeDropdown(content, row(28), "显示动作条数量", COUNT_ITEMS,
        function() return ns:DB().actionBars.barCount end,
        function(value)
            ns:DB().actionBars.barCount = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "显示快捷键", row(28),
        function() return ns:DB().actionBars.showHotkey end,
        function(value)
            ns:DB().actionBars.showHotkey = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "显示堆叠数量", row(28),
        function() return ns:DB().actionBars.showCount end,
        function(value)
            ns:DB().actionBars.showCount = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "显示宏名", row(30),
        function() return ns:DB().actionBars.showMacro end,
        function(value)
            ns:DB().actionBars.showMacro = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "宠物动作条悬停高亮（平时 30%）", row(30),
        function() return ns:DB().actionBars.petHover ~= false end,
        function(value)
            ns:DB().actionBars.petHover = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "姿态条悬停高亮（平时 30%）", row(30),
        function() return ns:DB().actionBars.stanceHover ~= false end,
        function(value)
            ns:DB().actionBars.stanceHover = value
            RefreshActionBars()
        end)

    sec.bodyHeight = -row.y + 4

    sec = BeginSection("姓名板", false)
    content = sec.body
    row = LayoutCursor(0)

    -- Which units get a plate at all (CVars; see Modules/Nameplates).
    MakeCheckbox(content, "显示敌方姓名板", row(28), NameplateCheckbox("showEnemy"))
    MakeCheckbox(content, "显示友方玩家姓名板", row(28), NameplateCheckbox("showFriendly"))
    MakeCheckbox(content, "显示友方 NPC 姓名板", row(28), NameplateCheckbox("showNPC"))
    MakeCheckbox(content, "显示低等级（minus）敌人", row(28), NameplateCheckbox("showMinor"))
    MakeCheckbox(content, "显示图腾", row(28), NameplateCheckbox("showTotems"))
    MakeCheckbox(content, "显示自己的姓名板", row(28), NameplateCheckbox("showSelf"))
    MakeCheckbox(content, "过滤小动物", row(28), NameplateCheckbox("hideCritters"))
    MakeCheckbox(content, "过滤死亡单位", row(30), NameplateCheckbox("hideDead"))

    MakeCheckbox(content, "显示名称", row(28), NameplateCheckbox("showName"))
    MakeCheckbox(content, "显示等级 / 精英标记", row(28), NameplateCheckbox("showLevel"))
    MakeCheckbox(content, "显示血量百分比", row(28), NameplateCheckbox("showPercent"))
    MakeCheckbox(content, "显示施法条", row(28), NameplateCheckbox("showCast"))
    MakeCheckbox(content, "职业 / 阵营着色", row(28), NameplateCheckbox("classColor"))
    MakeCheckbox(content, "仇恨描边", row(28), NameplateCheckbox("showThreat"))
    MakeCheckbox(content, "当前目标：金色描边 + 放大 1.1 倍", row(28), NameplateCheckbox("highlightTarget"))
    MakeCheckbox(content, "数值平滑过渡", row(28), NameplateCheckbox("smooth"))
    MakeCheckbox(content, "同步暴雪点击区域", row(30), NameplateCheckbox("forcePlateSize"))

    local NP_WIDTH = {}
    for _, w in ipairs({ 90, 100, 110, 120, 130, 140, 160 }) do
        NP_WIDTH[#NP_WIDTH + 1] = { value = w, text = w .. " px" }
    end
    local NP_HEIGHT = {}
    for _, h in ipairs({ 8, 10, 12, 14, 16 }) do
        NP_HEIGHT[#NP_HEIGHT + 1] = { value = h, text = h .. " px" }
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

    MakeDropdown(content, row(28), "姓名板宽度", NP_WIDTH,
        function() return NameplateSetting("width") end, NameplateSetter("width"))
    MakeDropdown(content, row(28), "姓名板高度", NP_HEIGHT,
        function() return NameplateSetting("height") end, NameplateSetter("height"))
    -- Name/level font size is fixed on the 12px pixel grid (Media:SnapSize), so there is no size picker any more -- every choice would render as 12.
    MakeDropdown(content, row(28), "施法条高度", NP_CAST,
        function() return NameplateSetting("castHeight") end, NameplateSetter("castHeight"))
    MakeDropdown(content, row(28), "名称截断长度", NP_LENGTH,
        function() return NameplateSetting("nameLength") end, NameplateSetter("nameLength"))
    MakeDropdown(content, row(30), "显示距离", NP_DISTANCE,
        function() return NameplateSetting("viewDistance") end, NameplateSetter("viewDistance"))

    sec.bodyHeight = -row.y + 4

    local skins = ns:GetModule("Skins")
    if skins then
        sec = BeginSection("界面美化", false)
        content = sec.body
        row = LayoutCursor(0)

        local FONT_ITEMS = {
            { value = "off",   text = "关闭（原生字体）" },
            { value = "pixel", text = "像素字体（推荐）" },
        }
        -- Legacy saved values ("roadway", "number", ...) normalize through GetFontKey, so the row always shows one of the two entries above.
        MakeDropdown(content, row(24), "统一字体（全局）", FONT_ITEMS,
            function() return skins:GetFontKey() or "off" end,
            function(value)
                ns:DB().skins.font = value
                if skins.active then
                    skins:ApplyFont()
                    ns:Print("切换字体：重启界面可完全恢复原生字体。")
                end
            end)

        local fontHint = Widget:Font(content, 12, "pixel", "neutral", "LEFT")
        fontHint:SetPoint("TOPLEFT", content, "TOPLEFT", 24, row(34))
        fontHint:SetWidth(328)
        fontHint:SetJustifyH("LEFT")
        fontHint:SetText("统一字体影响所有暴雪窗口文字；关闭需重载界面恢复。")

        -- Group the windows by section, in registration order.
        local groups, seen = {}, {}
        for _, entry in ipairs(skins.registry) do
            if not seen[entry.group] then
                seen[entry.group] = true
                groups[#groups + 1] = entry.group
            end
        end

        for _, group in ipairs(groups) do
            local caption = Widget:Font(content, 12, "pixel", "edge", "LEFT")
            caption:SetPoint("TOPLEFT", content, "TOPLEFT", 24, row(20))
            caption:SetText("· " .. group)

            for _, entry in ipairs(skins.registry) do
                if entry.group == group then
                    MakeCheckbox(content, entry.label, row(26),
                        function() return skins:IsEnabled(entry.key) end,
                        function(value) skins:SetPanelEnabled(entry.key, value) end)
                end
            end
        end

        row(4)                -- 行尾留白：纯前进，不取位置
        sec.bodyHeight = -row.y + 4
    end

    local tooltip = ns:GetModule("Tooltip")
    if tooltip then
        sec = BeginSection("鼠标提示", false)
        content = sec.body
        row = LayoutCursor(0)

        -- 位置是全局行为：一个下拉管所有 GameTooltip（物品 / 技能 / 角色 / 光环 / 动作条……），
        -- 和信息栏自己的悬停提示也共用。
        local TIP_ANCHOR = {
            { value = "cursor",  text = "跟随鼠标" },
            { value = "minimap", text = "小地图右上角" },
            { value = "off",     text = "暴雪默认位置" },
        }
        MakeDropdown(content, row(24), "提示框位置", TIP_ANCHOR,
            function() return tooltip:ResolveMode(tooltip) end,
            function(value)
                tooltip:Settings().anchor = value
                tooltip:Apply()
            end)

        MakeCheckbox(content, "单位提示补一行「目标」（它正在打谁）", row(26),
            function() return tooltip:GetSetting("enrich") end,
            function(value)
                tooltip:Settings().enrich = value and true or false
                tooltip:Apply()
            end)

        MakeCheckbox(content, "按住 Alt 显示 ID（NPC / 物品 / 法术）", row(26),
            function() return tooltip:GetSetting("idsByAlt") end,
            function(value)
                tooltip:Settings().idsByAlt = value and true or false
                tooltip:Apply()
            end)

        -- 正文归一只动"通用文字"（白 / 灰 / 纯黄的描述行），品质、职业、套装绿、未达标红
        -- 这些身份信息一律不碰；标题行不参与（判据见 Modules/Tooltip.lua 的 IsStaticTextColor）。
        MakeCheckbox(content, "提示框正文统一成主题文字色（保留品质 / 职业色）", row(26),
            function() return tooltip:GetSetting("neutralText") end,
            function(value)
                tooltip:Settings().neutralText = value and true or false
                tooltip:Apply()
            end)

        local tipHint = Widget:Font(content, 12, "pixel", "neutral", "LEFT")
        tipHint:SetPoint("TOPLEFT", content, "TOPLEFT", 24, row(44))
        tipHint:SetWidth(328)
        tipHint:SetJustifyH("LEFT")
        tipHint:SetText("用鼠标＝跟手（贴屏幕右/上边缘自动翻边）；用小地图＝提示框右下角对齐小地图面板右上角（小地图模块关掉时自动退回跟随）。边框与底色在上方「界面美化 → 系统 → 鼠标提示边框」。")

        -- 光标装饰（Modules/Cursor）：纯视觉，跟着主题色走；用模块开关整体关掉。
        local cursor = ns:GetModule("Cursor")
        if cursor then
            MakeCheckbox(content, "光标拖尾（快速移动时拖出一条主题色笔迹）", row(26),
                function() return cursor:GetSetting("trail") end,
                function(value)
                    cursor:Settings().trail = value and true or false
                    cursor:Apply()
                end)

            MakeCheckbox(content, "光标速度星芒（快速甩动时出现十字光）", row(26),
                function() return cursor:GetSetting("glow") end,
                function(value)
                    cursor:Settings().glow = value and true or false
                    cursor:Apply()
                end)
        end

        sec.bodyHeight = -row.y + 4
    end

    local toast = ns:GetModule("Toast")
    if toast then
        sec = BeginSection("通知", false)
        content = sec.body
        row = LayoutCursor(0)

        MakeCheckbox(content, "收到新邮件时弹一条提示（小地图邮件图标已隐藏）", row(26),
            function() return toast:GetSetting("mail") end,
            function(value)
                toast:Settings().mail = value and true or false
            end)

        MakeCheckbox(content, "背包满时弹一条提示（腾出空间后可再次提示）", row(28),
            function() return toast:GetSetting("bagFull") end,
            function(value)
                toast:Settings().bagFull = value and true or false
            end)

        MakeCheckbox(content, "进入 / 离开战斗时弹一条提醒（剑 / 盾 + 着色 + 文字）", row(28),
            function() return toast:GetSetting("combatAlert") ~= false end,
            function(value)
                toast:Settings().combatAlert = value and true or false
            end)

        MakeDropdown(content, row(26), "停留时长", {
            { value = 3, text = "3 秒" },
            { value = 5, text = "5 秒" },
            { value = 8, text = "8 秒" },
        },
            function() return toast:GetSetting("duration") or 5 end,
            function(value)
                toast:Settings().duration = value
            end)

        local toastHint = Widget:Font(content, 12, "pixel", "neutral", "LEFT")
        toastHint:SetPoint("TOPLEFT", content, "TOPLEFT", 24, row(34))
        toastHint:SetWidth(328)
        toastHint:SetJustifyH("LEFT")
        toastHint:SetText("横幅在屏幕顶部居中，一次只显示一条，多的排队；底边一条细线随停留时间排空，点一下可提前关掉。")
        sec.bodyHeight = -row.y + 4
    end

    local durability = ns:GetModule("Durability")
    if durability then
        sec = BeginSection("耐久警告", false)
        content = sec.body
        row = LayoutCursor(0)

        MakeCheckbox(content, "装备耐久过低时弹一条提示（修好 / 换装后才会再提醒）", row(28),
            function() return durability:GetSetting("warn") end,
            function(value)
                durability:Settings().warn = value and true or false
                durability:Apply()
            end)

        MakeDropdown(content, row(26), "提醒阈值", {
            { value = 20, text = "低于 20%" },
            { value = 30, text = "低于 30%" },
            { value = 50, text = "低于 50%" },
        },
            function() return durability:GetSetting("threshold") or 30 end,
            function(value)
                durability:Settings().threshold = value
                durability:Apply()
            end)

        local durHint = Widget:Font(content, 12, "pixel", "neutral", "LEFT")
        durHint:SetPoint("TOPLEFT", content, "TOPLEFT", 24, row(30))
        durHint:SetWidth(328)
        durHint:SetJustifyH("LEFT")
        durHint:SetText("只看身上穿着的 10 个部位（头肩胸腿脚腕手腰主副手），取最低的那件。")
        sec.bodyHeight = -row.y + 4
    end

    local atmosphere = ns:GetModule("Atmosphere")
    if atmosphere then
        sec = BeginSection("氛围暗角", false)
        content = sec.body
        row = LayoutCursor(0)

        MakeDropdown(content, row(28), "强度", {
            { value = 0.06, text = "轻 0.06" },
            { value = 0.10, text = "中 0.10（默认）" },
            { value = 0.12, text = "重 0.12" },
        },
            function() return atmosphere:Tier().alpha end,
            function(value) atmosphere:SetTier(value) end)

        local atHint = Widget:Font(content, 12, "pixel", "neutral", "LEFT")
        atHint:SetPoint("TOPLEFT", content, "TOPLEFT", 24, row(44))
        atHint:SetWidth(328)
        atHint:SetJustifyH("LEFT")
        atHint:SetText("只在画面四周压暗，越靠中心越亮：压的是游戏世界，所有界面（面板、动作条、姓名板）都天然在这层之上，文字亮度一位不减。默认关。")
        sec.bodyHeight = -row.y + 4
    end

    local tweaks = ns:GetModule("Tweaks")
    if tweaks then
        sec = BeginSection("控制台优化", false)
        content = sec.body
        row = LayoutCursor(0)

        local list = tweaks:Tweaks()
        for i = 1, #list do
            local t = list[i]
            MakeCheckbox(content, t.label, row(26),
                function() return tweaks:IsOn(t.key) end,
                function(value)
                    tweaks:Settings()[t.key] = value and true or false
                    tweaks:Apply()
                end)
        end

        local tweakHint = Widget:Font(content, 12, "pixel", "neutral", "LEFT")
        tweakHint:SetPoint("TOPLEFT", content, "TOPLEFT", 24, row(44))
        tweakHint:SetWidth(328)
        tweakHint:SetJustifyH("LEFT")
        tweakHint:SetText("逐条开关客户端控制台设置：打开写入、关掉还原成你原来的值。名单来自《无限》服常用优化，个别名字在本客户端可能不存在或被拒写——那样这条会空转，用 /mui tweaks status 看账本。默认全关。")
        sec.bodyHeight = -row.y + 4
    end

    local infobar = ns:GetModule("InfoBar")
    if infobar then
        sec = BeginSection("信息栏", false)
        content = sec.body
        row = LayoutCursor(0)

        -- Rebuild nothing on a settings change: the strip is re-anchored and the blocks re-measured in place.
        local function ApplyBar()
            if infobar.Reapply then infobar.Reapply()
            else infobar:ApplyLayout() end
        end

        MakeDropdown(content, row(28), "贴边", {
            { value = true,  text = "顶边" },
            { value = false, text = "底边" },
        },
            function() return infobar:Settings().anchorTop end,
            function(value)
                infobar:Settings().anchorTop = value
                ApplyBar()
            end)

        MakeDropdown(content, row(28), "高度", {
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

        MakeCheckbox(content, "悬停淡入（平时只露底板）", row(26),
            function() return infobar:Settings().mouseover end,
            function(value)
                infobar:Settings().mouseover = value and true or false
                ApplyBar()
            end)

        MakeCheckbox(content, "战斗时边缘呼吸闪烁", row(26),
            function() return infobar:Settings().combatPulse end,
            function(value)
                infobar:Settings().combatPulse = value and true or false
                if infobar.RefreshPulse then infobar.RefreshPulse() end
            end)

        MakeCheckbox(content, "底部经验线（悬停三角看数值）", row(26),
            function() return infobar:GetSetting("xp") end,
            function(value)
                infobar:Settings().xp = value and true or false
                ApplyBar()
            end)

        MakeCheckbox(content, "满级后这条线改显示声望", row(26),
            function() return infobar:GetSetting("xpFaction") end,
            function(value)
                infobar:Settings().xpFaction = value and true or false
                ApplyBar()
            end)

        -- One switch per block, in registration order.
        for _, block in ipairs(infobar.blocks) do
            MakeCheckbox(content, block.label, row(26),
                function() return infobar:BlockEnabled(block.key) end,
                function(value)
                    local settings = infobar:Settings()
                    if type(settings.blocks) ~= "table" then settings.blocks = {} end
                    settings.blocks[block.key] = value and true or false
                    ApplyBar()
                end)
        end

        row(4)                -- 行尾留白：纯前进，不取位置
        sec.bodyHeight = -row.y + 4
    end

    -- 面板最高只到屏幕 - 40，正文在里面滚；提示行和「重载界面」按钮固定在最下面那条带子里。
    -- 内容高度不再写死：分组折叠后由 relayout() 现算。

    -- Scroll: the wheel moves the content, the thumb shows where we are and can be dragged.
    local function ContentHeight()
        return root:GetHeight() or 0
    end

    local function MaxOffset()
        return math.min(0, (view:GetHeight() or 0) - ContentHeight())
    end

    local function UpdateThumb()
        local viewH = view:GetHeight() or 0
        local maxOffset = MaxOffset()
        if maxOffset >= 0 then
            scrollThumb:Hide()
            return
        end
        scrollThumb:Show()
        local contentH = ContentHeight()
        local thumbH = math.max(24, viewH * (viewH / (contentH > 0 and contentH or viewH)))
        scrollThumb:SetHeight(thumbH)
        -- 0 = 列表顶（滑块在轨道顶端），1 = 列表底。原来是 (offset - max) / -max：
        -- offset 为 0 时算出 1，滑块一打开就贴在轨道最下面（实机就是这个现象）。
        local t = (maxOffset ~= 0) and (scrollOffset / maxOffset) or 0
        scrollThumb:ClearAllPoints()
        scrollThumb:SetPoint("TOPLEFT", scrollTrack, "TOPLEFT", 0, -t * (viewH - thumbH))
    end

    local function SetOffset(value)
        scrollOffset = math.max(MaxOffset(), math.min(0, value))
        -- 两个角一起挪：只改 TOPLEFT 时，创建时钉在 view 顶边的 TOPRIGHT 会跟它打架，
        -- 内容会被拉变（宽高固定时表现为位置忽上忽下）。
        root:ClearAllPoints()
        root:SetPoint("TOPLEFT", view, "TOPLEFT", 0, scrollOffset)
        root:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, scrollOffset)
        UpdateThumb()
    end
    setOffset = SetOffset

    -- 展开 / 收起：重新摞一遍分组，内容高度、面板高度、滚动范围一起更新。
    relayout = function()
        local acc = 0
        for i = 1, #SECTIONS do
            local entry = SECTIONS[i]
            entry.holder:ClearAllPoints()
            entry.holder:SetPoint("TOPLEFT", root, "TOPLEFT", 0, -acc)
            entry.holder:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, -acc)
            local height = HEADER_H + (entry.expanded and entry.bodyHeight or 0)
            entry.holder:SetHeight(height)
            acc = acc + height
        end
        root:SetHeight(acc + 10)
        local screenH = (_G.GetScreenHeight and _G.GetScreenHeight()) or 800
        Widget:Height(panel, math.min((root:GetHeight() or 0) + 108, screenH - 40))
        SetOffset(scrollOffset)
    end

    -- One handler for the whole panel: the wheel event bubbles up from the row widgets,
    -- and no intermediate frame handles it, so the content moves exactly one step.
    panel:SetScript("OnMouseWheel", function(_, delta)
        -- 本客户端的滚轮符号是反的（实测：往下滚 delta = +1）。既然往下滚要看后面的内容，
        -- 偏移就得往负走，所以这里是减号。之前我照零售服的直觉改成加号，方向就反了。
        SetOffset(scrollOffset - delta * 48)
    end)

    local dragging, dragStartY, dragStartOffset
    -- 零售 12.x 的 SetScript 会校验脚本名，"OnMouseDrag" 不是客户端认的名字（会直接报错，
    -- 配置面板因此开不起来）。拖动改成"按住时每帧跟一次光标"：OnUpdate 只在拖动期间挂着。
    local function Drag()
        if not dragging then
            scrollThumb:SetScript("OnUpdate", nil)
            return
        end
        local _, my = GetCursorPosition()
        SetOffset(dragStartOffset + (my - dragStartY) * Media:Mult())
    end

    -- 拖动期间才挂着的每帧回调（松手即摘）⇒ 走外部账，不进订阅表（否则面板一开就常驻空转）。
    local DragTracked = ns.Scheduler and ns.Scheduler:Profile("config:scroll", "配置滚动条拖动", Drag) or Drag

    scrollThumb:SetScript("OnMouseDown", function()
        -- GetCursorPosition is the documented cursor API on this client; it reports
        -- physical pixels, so the delta is converted to UI units with Media:Mult().
        local _, my = GetCursorPosition()
        dragging, dragStartY, dragStartOffset = true, my, scrollOffset
        scrollThumb:SetScript("OnUpdate", DragTracked)
    end)
    scrollThumb:SetScript("OnMouseUp", function()
        dragging = false
        scrollThumb:SetScript("OnUpdate", nil)
    end)

    relayout()

    local hint = Widget:Font(panel, 12, "pixel", "neutral", "LEFT")
    hint:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 24, 52)
    hint:SetWidth(352)
    hint:SetText("提示：/mui status 查看模块状态，/mui reset 恢复默认设置。")
    hint:SetJustifyH("LEFT")

    local reload = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reload:SetSize(120, 24)
    reload:SetPoint("BOTTOM", panel, "BOTTOM", 0, 16)
    reload:SetText("重载界面")
    -- 和下拉按钮同款织纹底，让面板里所有"按钮"视觉统一。
    Widget:ButtonMaterial(reload, { alpha = 0, weaveAlpha = 0.25 })
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
        if setOffset then setOffset(0) end
        frame:Show()
    end
end

function SimpleConfig:Show()
    self:Build()
    if setOffset then setOffset(0) end
    panel:Show()
end

function SimpleConfig:Hide()
    if panel then panel:Hide() end
end
