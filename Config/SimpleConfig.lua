-- 轻量主题设置面板：保存设置，并标注需要重载界面的选项。

local ADDON_NAME, ns = ...


-- 自定义标记统一走 Core 的旁表，避免写入暴雪对象。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
-- 模块私有守卫使用独立弱表。
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

-- 仅显示当前页；正文在固定高度的滚动区域内单独计算滚动范围。
local root, view, scrollThumb, scrollTrack   -- root = 滚动内容根框；各**页**（主菜单一项一页）挂在它下面
local scrollOffset = 0
local setOffset        -- Build 里定义，Show/Toggle 打开面板时归零

-- 主菜单：pages 按建页顺序排列，一页 = 一个按钮 + 一块正文。
local pages, tabButtons = {}, {}
local selected = 1
local tabBar           -- 按钮容器（建面板时就挂好，走到 Build 末尾才知道最终有几页）

-- 面板布局令牌：统一行高、宽度、间距与提示区尺寸。
local T = {
    padX     = 24,    -- 内容左右留白，也是所有行的原点（唯一一次缩进）
    capH     = 22,    -- 组名行
    rowH     = 26,    -- 复选框行
    dropH    = 28,    -- 下拉行
    subH     = 20,    -- 副注行（挂在主行下面的一行小字 / 一行状态）
    gapS     = 4,     -- 行尾小留白（光标只前进、不取位置）

    ctrlW    = 190,   -- 下拉控件宽
    ctrlH    = 22,    -- 下拉控件高
    labelW   = 132,   -- 下拉左列标签宽
    swatch   = 12,    -- 配色方块边长
    listRowH = 20,    -- 下拉列表行高

    hintLine = 17,    -- 提示段落行距（12px 像素字不压字的最小值）
    hintPad  = 8,     -- 提示段落上下留白

    tabH     = 26,    -- 主菜单按钮高
    tabGap   = 6,     -- 主菜单间距（横竖同值 ⇒ 网格是方的）
    tabPerRow = 5,    -- 每行最多几个，总行数再按页数均分

    titleH   = 40,    -- 标题行
    bottomH  = 66,    -- 底部提示 + 重载按钮带
    panelH   = 620,   -- 面板固定高：切页不缩放，title / 主菜单钉在顶上，内容多的页靠滚动
}
T.panelW   = 440                      -- 面板宽（400 → 440：长标签不再被切）
T.contentW = T.panelW - T.padX * 2    -- 正文可用宽（392）
T.textW    = T.contentW - 30          -- 复选框标签限宽（框体本身占掉那一截）

--- 按 UTF-8 字节估算提示段落的显示行数。
local function HintLines(text)
    local bytes = string.len(text)
    local ascii = select(2, string.gsub(text, "[\1-\127]", ""))
    local cjk = (bytes - ascii) / 3
    local width = cjk * 12.6 + ascii * 7
    return math.max(1, math.ceil(width / (T.contentW - 12)))
end

--- 计算一段提示占用的总高度。
local function HintH(text)
    return HintLines(text) * T.hintLine + T.hintPad
end

-- 手绘装饰统一登记，换主题时只重绘颜色，不重建对象。
local tinted = {}

local function Tint(tex, colorKey, alpha)
    tinted[#tinted + 1] = { tex = tex, key = colorKey, alpha = alpha }
    local r, g, b = Widget:PaletteColor(colorKey)
    if r and tex.SetVertexColor then tex:SetVertexColor(r, g, b, alpha) end
    return tex
end

local function RepaintTinted()
    for i = 1, #tinted do
        local e = tinted[i]
        local r, g, b = Widget:PaletteColor(e.key)
        if r and e.tex.SetVertexColor then e.tex:SetVertexColor(r, g, b, e.alpha) end
    end
end

--- 本面板所有横细线的唯一画法（monet_hairline 横向撑满 parent 减 inset）。
--- @param opts { inset = T.padX, y = 0, alpha = 0.45, key = "edge", h = 1, side = "top"|"bottom" }
local function HLine(parent, opts)
    opts = opts or {}
    local tex = parent:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(Media:Texture("monet_hairline"))
    local inset, y = opts.inset or T.padX, opts.y or 0
    if opts.side == "bottom" then
        tex:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", inset, y)
        tex:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -inset, y)
    else
        tex:SetPoint("TOPLEFT", parent, "TOPLEFT", inset, y)
        tex:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -inset, y)
    end
    tex:SetHeight(Media:SnapUnit(opts.h or 1))
    -- 单行不透明图：任何亚像素落点都是糊，所以这里确定该贴像素格（同 Widget:Hairline 的理由）。
    if tex.SetSnapToPixelGrid then pcall(tex.SetSnapToPixelGrid, tex, true) end
    if tex.SetTexelSnappingBias then pcall(tex.SetTexelSnappingBias, tex, 0) end
    return Tint(tex, opts.key or "edge", opts.alpha or 0.45)
end

local MODULE_GROUPS = {
    { caption = "外观与交互", names = { "Chat", "Skins", "Tooltip", "Cursor" } },
    { caption = "战斗与动作", names = { "UnitFrames", "ActionBars", "Nameplates", "Cooldown", "BuffFrame" } },
    { caption = "地图与信息", names = { "Minimap", "InfoBar", "Bags", "QuestTracker" } },
    { caption = "提醒与系统", names = { "Toast", "Durability", "Tweaks", "WhatsNew", "KeyFeeder" } },
}

local MODULE_LABEL = {
    UnitFrames   = "单位框架",
    Cooldown     = "冷却计时",
    BuffFrame    = "增益光环",
    Minimap      = "小地图",
    Bags         = "分类背包",
    QuestTracker = "任务追踪",
    ActionBars   = "动作条",
    Nameplates   = "姓名板",
    Skins        = "界面美化",
    InfoBar      = "信息栏",
    Tooltip      = "鼠标提示",
    Chat         = "聊天条",
    Cursor       = "光标效果",
    Toast        = "通知横幅",
    Durability   = "耐久警告",
    Tweaks       = "控制台优化",
    WhatsNew     = "更新提示",
    KeyFeeder    = "按键反馈",
}

--- 获取区域显示名；名称用于文本拼接，读取前先检查机密值。
--- 客户端名称不可用时回退到配色引擎的区域名。
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
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", T.padX, yOffset)
    cb:SetChecked(getter() and true or false)
    cb:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
    end)
    -- 自建复选框不加入 MonetUI 的回滚清单。
    if ns.Skin then ns.Skin:CheckButton(cb) end

    local text = Widget:Font(parent, 12, "pixel", "neutral", "LEFT")
    text:SetPoint("LEFT", cb, "RIGHT", 6, 0)
    -- 长标签限制为单行，避免与下一行重叠。
    text:SetWidth(T.textW)
    text:SetWordWrap(false)
    text:SetText(label)

    return cb, text
end

--- 绘制页内分区标题、分隔线，并消费一个组名行高。
local function Group(parent, cursor, caption)
    local y = cursor(T.capH)
    local fs = Widget:Font(parent, 12, "pixel", "edge", "LEFT")
    if ns.Skin then ns.Skin:TextTier(fs, "section") end -- section 档（12/edge）：组名 = 分区头，统一入口
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", T.padX, y - 4)
    fs:SetText(caption)
    HLine(parent, { y = y - T.capH + 5, alpha = 0.3 })
    return y
end

--- 创建说明文字，按文本行数自动让出布局空间。
local function Hint(parent, cursor, text)
    local fs = Widget:Font(parent, 12, "pixel", "neutral", "LEFT")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", T.padX, cursor(HintH(text)) - 4)
    fs:SetWidth(T.contentW)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

-- 使用自绘列表，避免依赖不同客户端版本的暴雪下拉菜单框架。

local dropdowns = {}   -- list of refreshers, run when the panel is shown
local openList         -- the list currently on screen, if any
local catcher          -- the click-anywhere-else closer

local function CloseDropdown()
    if openList then openList:Hide() end
    openList = nil
    if catcher then catcher:Hide() end
end

--- 创建覆盖屏幕的下拉列表点击层，用于点击外部关闭。
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

--- 创建主题样式设置行。
-- swatch 可在当前选项旁显示对应的预览色。
local function MakeDropdown(parent, y, caption, items, getter, setter, swatch)
    local label = Widget:Font(parent, 12, "pixel", "neutral", "LEFT")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", T.padX, y - 4)
    -- 同 1)：描述限宽到控件左侧，超出的部分切掉而不是钻到下拉框下面
    label:SetWidth(T.labelW)
    label:SetWordWrap(false)
    label:SetText(caption)

    local button = Widget:CreateFrame(nil, parent, T.ctrlW, T.ctrlH)
    Widget:Theme(button, { thickness = 1, bgAlpha = 0.9 })
    -- 织纹底（ADD 混合，和动作条按钮一致）：垫在 Theme 的深色底板之上、文字之下。
    Widget:ButtonMaterial(button, { alpha = 0, weaveAlpha = 0.25 })
    button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -T.padX, y)
    button:EnableMouse(true)

    local chip, chipFill
    if swatch then
        chip = Widget:CreateFrame(nil, parent, T.swatch, T.swatch)
        Widget:Theme(chip, { thickness = 1, bgAlpha = 1 })
        chip:SetPoint("RIGHT", button, "LEFT", -8, 0)
        pcall(chip.EnableMouse, chip, false)
        chipFill = chip:CreateTexture(nil, "ARTWORK")
        chipFill:SetAllPoints()
    end

    local value = Widget:Font(button, 12, "pixel", "edge", "LEFT")
    value:SetPoint("LEFT", button, "LEFT", 7, 0)
    value:SetPoint("RIGHT", button, "RIGHT", -16, 0)
    -- 长选项保持单行，超宽时在按钮内裁切。
    value:SetWordWrap(false)

    -- 下拉箭头使用主题材质，并登记换肤重绘。
    local chevron = button:CreateTexture(nil, "ARTWORK", nil, 2)
    chevron:SetSize(8, 8)
    chevron:SetPoint("RIGHT", button, "RIGHT", -6, 0)
    chevron:SetTexture(Media:Texture("monet_chevron_up"))
    Widget:Arrow(chevron, "down")
    Tint(chevron, "neutral", 1)

    -- 列表挂在 UIParent 下，避免被面板裁剪。
    local list = Widget:CreateFrame(nil, UIParent, T.ctrlW, #items * T.listRowH + 4)
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
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 2, -2 - (index - 1) * T.listRowH)
        row:SetSize(T.ctrlW - 4, T.listRowH)
        -- 行的底色比按钮更淡（列表本身已有深色底），只留一层织纹。
        Widget:ButtonMaterial(row, { alpha = 0, weaveAlpha = 0.15 })

        local hover = row:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints()
        -- 悬停高亮在使用时读取主题色。
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
    -- 优先通过 Apply 同时重涂颜色与数值。
    if unitFrames.Apply then
        unitFrames:Apply()
    elseif unitFrames.UpdateAll then
        unitFrames:UpdateAll()
    end
end

--- 通过 Apply 重排动作条并刷新可见性。
local function RefreshActionBars()
    local actionBars = ns:GetModule("ActionBars")
    if actionBars and actionBars.Apply then actionBars:Apply() end
end

--- 通过 Apply 刷新小队与团队框架；受限时由模块自动延后。
local function RefreshGroups()
    local groups = ns:GetModule("GroupFrames")
    if groups and groups.Apply then groups:Apply() end
end

--- 通过 Apply 同步姓名板设置与当前显示。
local function RefreshNameplates()
    local nameplates = ns:GetModule("Nameplates")
    if nameplates and nameplates.Apply then nameplates:Apply() end
end

--- 通过模块读写姓名板设置，保留默认值回退。
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

--- 为姓名板复选框生成读写函数。
local function NameplateCheckbox(key)
    return function() return NameplateSetting(key) ~= false end, NameplateSetter(key)
end

--- 生成一组单位共用的设置读写函数。
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

    -- 重建面板时清空模块级登记。
    pages, tabButtons, tinted = {}, {}, {}
    selected = 1

    panel = Widget:CreateFrame("MonetUIConfigFrame", UIParent, T.panelW, T.panelH)
    -- 面板使用直角主题背板。
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

    -- 标题行：左侧标识与名称，右侧版本信息和关闭按钮。
    local titleBar = CreateFrame("Frame", nil, panel)
    titleBar:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    Widget:Height(titleBar, T.titleH)

    -- 标识贴图保留原始色彩，只调整透明度。
    local logo = titleBar:CreateTexture(nil, "ARTWORK")
    logo:SetTexture(Media:Texture("monet_addon_icon"))
    Widget:Size(logo, 22, 22)
    logo:SetPoint("LEFT", titleBar, "LEFT", T.padX, 0)

    local title = Widget:Font(titleBar, 15, "pixel", "edge", "LEFT")
    if ns.Skin then ns.Skin:TextTier(title, "title") end -- title 档（15/edge）：主标题原 20 是禁档，收进档位
    title:SetPoint("LEFT", logo, "RIGHT", Media:SnapUnit(10), 0)
    title:SetText("MonetUI")

    local subtitle = Widget:Font(titleBar, 10, "pixel", "neutral", "RIGHT")
    if ns.Skin then ns.Skin:TextTier(subtitle, "caption") end -- caption 档（10/neutral）：版本副标题是小字
    subtitle:SetPoint("RIGHT", titleBar, "RIGHT", -(T.padX + 22), 0)
    subtitle:SetWordWrap(false)
    subtitle:SetText("v" .. ns.version .. " · 印象派自适应界面" .. (ns.dev and " |cffffa940[DEV]|r" or ""))

    -- 关闭按钮由工厂统一完成主题化。
    local close = Widget:CloseButton(panel)
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)

    -- 添加阴影与角落笔触，右上角留给关闭按钮。
    Widget:Shadow(panel, { size = 7, alpha = 0.5 })
    Widget:Corners(panel, { omit = { "TOPRIGHT" } })

    -- 标题下方添加主题笔触。
    Widget:Rule(titleBar, title, { alpha = 0.9 })

    -- 主菜单：点击页签只切换对应正文。
    tabBar = CreateFrame("Frame", nil, panel)
    tabBar:SetPoint("TOPLEFT", panel, "TOPLEFT", T.padX, -T.titleH)
    tabBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -T.padX, -T.titleH)
    Widget:Height(tabBar, T.tabH)

    -- 正文裁剪区域固定标题栏和页签栏，仅当前页参与滚动。
    view = CreateFrame("Frame", nil, panel)
    view:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -T.tabGap)
    view:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, T.bottomH)
    view:SetClipsChildren(true)

    root = CreateFrame("Frame", nil, view)
    root:SetPoint("TOPLEFT", view, "TOPLEFT", 0, 0)
    root:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, 0)
    root:SetHeight(100)

    local content, row, sec   -- row = 行布局光标（每页 LayoutCursor(0) 重新赋值）

    -- 垂直布局光标：取当前行位置并自动向下推进。
    -- row.y 只读当前页已消费的高度。
    local function LayoutCursor(yStart)
        return setmetatable({ y = yStart }, {
            __call = function(self, step)
                local at = self.y
                self.y = self.y - step
                return at
            end,
        })
    end

    --- 创建一页隐藏正文；页签在全部页面建完后统一生成。
    local function BeginPage(key, caption)
        local body = CreateFrame("Frame", nil, root)
        body:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
        body:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, 0)
        body:SetHeight(1)
        body:Hide()
        local entry = { key = key, caption = caption, body = body, bodyHeight = 1 }
        pages[#pages + 1] = entry
        return entry
    end
    -- 绘制页签常态、悬停与选中状态。
    local function PaintTab(i)
        local tab = tabButtons[i]
        if not tab then return end
        local on = (i == selected)
        if on then
            local r, g, b = Color:GetHighlight()
            Widget:SetBorderState(tab.frame, r, g, b, 1)
        else
            Widget:SetBorderState(tab.frame, nil)
        end
        Widget:ColorText(tab.text, on and "bright" or "neutral")
        if on then tab.mark:Show() else tab.mark:Hide() end
    end

    --- 切换页面，并同步正文高度与滚动范围。
    --- 标题栏和页签栏保持固定。
    local function SelectPage(index)
        local page = pages[index]
        if not page then return end
        selected = index
        CloseDropdown()
        for i = 1, #pages do
            pages[i].body:SetShown(i == index)
        end
        for i = 1, #tabButtons do PaintTab(i) end
        local bodyH = page.bodyHeight
        -- 页面高度在建页时统一结算，切页时只写入框体。
        Widget:Height(page.body, bodyH)
        Widget:Height(root, bodyH)
        if setOffset then setOffset(0) end
    end

    -- 自绘滚动条贴合正文区域，标题栏或页签栏变高时自动让位。
    scrollTrack = panel:CreateTexture(nil, "ARTWORK")
    scrollTrack:SetPoint("TOPRIGHT", view, "TOPRIGHT", -Media:SnapUnit(10), 0)
    scrollTrack:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -Media:SnapUnit(10), 0)
    Widget:Width(scrollTrack, 4)

    scrollThumb = CreateFrame("Button", nil, panel)
    scrollThumb:SetPoint("TOPLEFT", scrollTrack, "TOPLEFT", 0, 0)
    Widget:Width(scrollThumb, 4)
    scrollThumb:SetHeight(40)
    scrollThumb:EnableMouse(true)
    local thumbTex = scrollThumb:CreateTexture(nil, "BACKGROUND")
    thumbTex:SetAllPoints()

    -- 纯色块重绘颜色，贴图装饰统一走主题重绘。
    local function RepaintScrollbar()
        local nr, ng, nb = Color:GetNeutral()
        scrollTrack:SetColorTexture(nr, ng, nb, 0.25)
        local er, eg, eb = Color:GetEdge()
        thumbTex:SetColorTexture(er, eg, eb, 0.8)
    end
    RepaintScrollbar()

    -- 面板内所有主题颜色通过同一个出口刷新。
    ns.EventBus:Register("MONETUI_THEME_CHANGED", function()
        if not panel then return end
        RepaintTinted()
        RepaintScrollbar()
        for i = 1, #tabButtons do PaintTab(i) end
    end)

    -- ① 外观与布局
    sec = BeginPage("theme", "外观与布局")
    content = sec.body
    row = LayoutCursor(0)

    Group(content, row, "主题配色")

    MakeCheckbox(content, "使用 MonetColor 动态主题", row(T.rowH),
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
    statusText:SetPoint("TOPLEFT", content, "TOPLEFT", T.padX + 22, row(T.subH))
    statusText:SetWidth(T.contentW - 22)
    statusText:SetJustifyH("LEFT")

    refreshStatus = function()
        local source, profile = Color:GetSource()
        local colorText
        if source == "monet" then
            colorText = string.format("引擎输出 · 配置 %s", tostring(profile))
        else
            colorText = ns:HasMonetColor() and "内置调色板（引擎已关闭）" or "内置调色板（未找到 LibMonetColor）"
        end
        -- MonetColor 开关变化后同步刷新区域配色预览。
        if refreshZonePreview then refreshZonePreview() end
    end
    refreshStatus()

    -- 区域配色预览：显示当前区域与四档表面色，缺数据时单独提示。
    local yZone = row(T.subH)
    local zoneCaption = Widget:Font(content, 10, "pixel", "neutral", "LEFT")
    if ns.Skin then ns.Skin:TextTier(zoneCaption, "caption") end -- caption 档（10/neutral）：区域配色标签是小字
    zoneCaption:SetPoint("TOPLEFT", content, "TOPLEFT", T.padX, yZone - 4)
    zoneCaption:SetWidth(96)
    zoneCaption:SetWordWrap(false)
    zoneCaption:SetText("区域配色")

    -- 四档表面色对应面板、悬停、损失与填充层级。
    -- 色块使用不透明 RGB，与下拉预览色保持一致。
    local ZONE_STEPS = { "panel", "hover", "lost", "fill" }
    local zoneChips, zoneFills = {}, {}
    for i = #ZONE_STEPS, 1, -1 do
        local chip = Widget:CreateFrame(nil, content, T.swatch, T.swatch)
        Widget:Theme(chip, { thickness = 1, bgAlpha = 1 })
        if i == #ZONE_STEPS then
            chip:SetPoint("TOPRIGHT", content, "TOPRIGHT", -T.padX, yZone)
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

    -- 状态文字右边缘跟随图例，避免固定宽度造成重叠。
    local yMark = row(T.hintLine)
    local zoneLegend = Widget:Font(content, 10, "pixel", "neutral", "RIGHT")
    zoneLegend:SetPoint("TOPRIGHT", content, "TOPRIGHT", -T.padX, yMark - 2)
    zoneLegend:SetWordWrap(false)
    zoneLegend:SetText("面板 · 悬停 · 空槽 · 填充")

    local zoneMark = Widget:Font(content, 10, "pixel", "edge", "LEFT")
    zoneMark:SetPoint("TOPLEFT", content, "TOPLEFT", T.padX, yMark - 2)
    zoneMark:SetPoint("RIGHT", zoneLegend, "LEFT", -8, 0)
    zoneMark:SetWordWrap(false)
    zoneMark:SetText("")

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
            -- 继承或派生配色明确标注其来源区域。
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
    -- 区域或主题变化时刷新预览。
    ns.EventBus:Register("MONETUI_THEME_CHANGED", function()
        if refreshZonePreview then refreshZonePreview() end
    end)

    -- 边框色是全局主题色，统一作用于所有主题背板。
    local BORDER_ITEMS = {
        { value = "edge",      text = "边缘色（Monet 签名）" },
        { value = "ambient",   text = "环境色" },
        { value = "highlight", text = "高亮色" },
        { value = "neutral",   text = "中性灰" },
    }
    MakeDropdown(content, row(T.dropH), "边框颜色", BORDER_ITEMS,
        function() return Color:GetBorderKey() end,
        function(value)
            ns:DB().theme.borderKey = value
            ns.RefreshTheme("config")
        end)

    Group(content, row, "界面布局")

    -- 界面缩放决定控件是否对齐物理像素；自动模式按分辨率选择。
    local SCALE_ITEMS = {
        { value = "auto", text = "自动（按分辨率固定）" },
        { value = "game", text = "跟随游戏设置" },
    }
    MakeDropdown(content, row(T.dropH), "UI 缩放（重载生效）", SCALE_ITEMS,
        function() return (ns:DB().theme or {}).uiScaleMode or "auto" end,
        function(value)
            ns:DB().theme.uiScaleMode = value
            if value == "auto" then
                ns:DB().theme.uiScaleApplied = nil
            end
            ns:Print("UI 缩放模式：" .. (value == "auto" and "自动（下次 /reload 生效）" or "跟随游戏设置") .. "。")
        end)

    MakeCheckbox(content, "锁定所有可移动框（默认开）", row(T.rowH),
        function() return ns:DB().mover.locked end,
        function(value)
            ns:DB().mover.locked = value
        end)

    sec.bodyHeight = -row.y + T.hintPad

    sec = BeginPage("chat", "聊天")
    content = sec.body
    row = LayoutCursor(0)

    Group(content, row, "独立聊天条")

    MakeCheckbox(content, "启用聊天条", row(T.rowH),
        function() return ns:DB().modules.Chat ~= false end,
        function(value) ns:SetModuleEnabled("Chat", value) end)

    Hint(content, row, "点击频道只切换目标；Tab / Shift+Tab 正向或反向切换，Enter 发送，Escape 清空并退出输入。")
    Hint(content, row, "密语可输入「名字 内容」，也可用 /w 名字 内容；自定义频道会列出已加入的频道。")
    Hint(content, row, "聊天条可拖动；先用 /mui unlock 解锁，摆好后用 /mui lock 重新锁定。")

    sec.bodyHeight = -row.y + T.hintPad

    local skins = ns:GetModule("Skins")
    if skins then
        sec = BeginPage("skins", "界面美化")
        content = sec.body
        row = LayoutCursor(0)

        Group(content, row, "字体与聊天")

        local FONT_ITEMS = {
            { value = "off",   text = "关闭（原生字体）" },
            { value = "pixel", text = "像素字体（推荐）" },
        }
        -- 旧字体值统一规范化为当前支持的选项。
        MakeDropdown(content, row(T.dropH), "统一字体", FONT_ITEMS,
            function() return skins:GetFontKey() or "off" end,
            function(value)
                ns:DB().skins.font = value
                if skins.active then
                    skins:ApplyFont()
                    ns:Print("切换字体：重启界面可完全恢复原生字体。")
                end
            end)

        Hint(content, row, "替换暴雪共享字体与 MonetUI 文字，不改字号；关闭后需重载才能完全恢复。")

        -- 聊天页签的悬停显示无需重载。
        MakeCheckbox(content, "聊天页签悬停才显示", row(T.rowH),
            function() return ns:DB().skins.hoverChatTabs ~= false end,
            function(value)
                ns:DB().skins.hoverChatTabs = value and true or false
                if ns.Skins and ns.Skins.RefreshChatTabHover then
                    ns.Skins:RefreshChatTabHover()
                end
            end)

        -- 输入框渐隐行为受 ChatEditFade 插件聊天输入框渐隐函数启发。
        -- 状态切换在下一拍生效，无需重载。
        MakeDropdown(content, row(T.dropH), "输入框平时状态", {
            { value = "fade", text = "渐隐（失焦 3 秒后变淡）" },
            { value = "hide", text = "全隐（仅聚焦才出现）" },
            { value = "show", text = "常显" },
        },
            function()
                local m = ns:DB().skins.chatEditBoxMode
                if m == "hide" or m == "show" then return m end
                return "fade"
            end,
            function(value)
                ns:DB().skins.chatEditBoxMode = value
                if ns.Skins and ns.Skins.RefreshChatTabHover then
                    ns.Skins:RefreshChatTabHover()
                end
            end)

        -- 仅在渐隐或常显模式下显示位置设置。
        MakeDropdown(content, row(T.dropH), "输入框位置（常显 / 渐隐时）", {
            { value = "top",    text = "框内顶部（推荐）" },
            { value = "bottom", text = "框底（原生位置）" },
        },
            function()
                local p = ns:DB().skins.chatEditBoxPos
                return (p == "bottom") and "bottom" or "top"
            end,
            function(value)
                ns:DB().skins.chatEditBoxPos = value
                if ns.Skins and ns.Skins.RefreshChatTabHover then
                    ns.Skins:RefreshChatTabHover()
                end
            end)

        -- 聊天页签三态色与淡入时长由主题驱动实时刷新。
        local function HexToRGB(hex)
            if type(hex) ~= "string" then return nil end
            local h = hex:gsub("#", "")
            if #h ~= 6 then return nil end
            local r, g, b = h:match("(..)(..)(..)")
            if not r then return nil end
            return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
        end
        local function TabColorSwatch(hex)
            local r, g, b = HexToRGB(hex)
            if r then return r, g, b end
            return 1, 1, 1
        end
        local TAB_COLOR_ITEMS = {
            { value = "9a9a9a", text = "中性灰" },
            { value = "ffffff", text = "白" },
            { value = "ff6b6b", text = "警示红" },
            { value = "5bd6a0", text = "绿（公会）" },
            { value = "6db3ff", text = "蓝（说 / 密）" },
            { value = "ffd479", text = "金" },
            { value = "c08bff", text = "紫" },
        }
        local function TabColorGetter(key)
            return function() return ns:DB().skins[key] end
        end
        local function TabColorSetter(key)
            return function(value)
                ns:DB().skins[key] = value
                if ns.Skins and ns.Skins.RefreshChatTabHover then
                    ns.Skins:RefreshChatTabHover()
                end
            end
        end

        MakeDropdown(content, row(T.dropH), "页签淡入时长", {
            { value = 0.1,  text = "0.1 秒" },
            { value = 0.18, text = "0.18 秒（默认）" },
            { value = 0.3,  text = "0.3 秒" },
            { value = 0.5,  text = "0.5 秒" },
        }, function() local f = ns:DB().skins.tabFade; return tonumber(f) or 0.18 end,
           function(value)
               ns:DB().skins.tabFade = value
               if ns.Skins and ns.Skins.RefreshChatTabHover then
                   ns.Skins:RefreshChatTabHover()
               end
           end)

        MakeDropdown(content, row(T.dropH), "页签色·未选中", TAB_COLOR_ITEMS,
            TabColorGetter("tabColorNormal"), TabColorSetter("tabColorNormal"), TabColorSwatch)
        MakeDropdown(content, row(T.dropH), "页签色·选中", TAB_COLOR_ITEMS,
            TabColorGetter("tabColorSelected"), TabColorSetter("tabColorSelected"), TabColorSwatch)
        MakeDropdown(content, row(T.dropH), "页签色·未读", TAB_COLOR_ITEMS,
            TabColorGetter("tabColorFlash"), TabColorSetter("tabColorFlash"), TabColorSwatch)

        -- 按注册顺序分组显示窗口美化开关。
        local groups, seen = {}, {}
        for _, entry in ipairs(skins.registry) do
            if not seen[entry.group] then
                seen[entry.group] = true
                groups[#groups + 1] = entry.group
            end
        end

        for _, group in ipairs(groups) do
            Group(content, row, group)

            for _, entry in ipairs(skins.registry) do
                if entry.group == group then
                    MakeCheckbox(content, entry.label, row(T.rowH),
                        function() return skins:IsEnabled(entry.key) end,
                        function(value) skins:SetPanelEnabled(entry.key, value) end)
                end
            end
        end

        row(T.gapS)                -- 行尾留白：纯前进，不取位置
        sec.bodyHeight = -row.y + T.hintPad
    end

    sec = BeginPage("unitFrames", "单位框架")
    content = sec.body
    row = LayoutCursor(0)

    MakeCheckbox(content, "隐藏暴雪默认的玩家/目标框架（需重载恢复）", row(T.rowH),
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

    -- 相关单位共用一组血条与空槽配色，预览使用模块实际上色函数。
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

    -- 配色预览与单位框架使用同一套颜色计算。
    local unitFrames = ns:GetModule("UnitFrames")
    local function Preview(kind, unit)
        return function(value)
            if unitFrames and type(unitFrames.PreviewColor) == "function" then
                return unitFrames:PreviewColor(kind, value, unit)
            end
        end
    end

    for _, group in ipairs(COLOR_GROUPS) do
        Group(content, row, group.label)
        local unit = group.units[1]
        -- Lua 多返回值只在最后参数位置展开，因此显式接收读写函数。
        local getFill, setFill = UnitSetting(group.units, "fillColor", group.fill)
        local getLost, setLost = UnitSetting(group.units, "lostColor", group.lost)
        MakeDropdown(content, row(T.dropH), "血条", FILL_ITEMS, getFill, setFill, Preview("fill", unit))
        MakeDropdown(content, row(T.dropH), "空槽（损失部分）", LOST_ITEMS, getLost, setLost, Preview("lost", unit))
    end

    Group(content, row, "能量条")
    MakeDropdown(content, row(T.dropH), "颜色", POWER_ITEMS,
        function() return ns:DB().unitFrames.powerColor end,
        function(value)
            ns:DB().unitFrames.powerColor = value
            RefreshUnitFrames()
        end,
        function(value)
            if value == "theme" then return Color:GetResource() end
            -- 按能量类型预览当前角色的资源色。
            local _, token = UnitPowerType("player")
            local map = { MANA = { 0.20, 0.50, 0.90 }, RAGE = { 0.85, 0.20, 0.20 },
                          ENERGY = { 0.90, 0.85, 0.25 }, FOCUS = { 0.85, 0.45, 0.15 } }
            local c = map[token or ""]
            if c then return c[1], c[2], c[3] end
            return Color:GetResource()
        end)

    -- 关闭时显示 0，否则数值为职业标记高度。
    local CLASS_ITEMS = {
        { value = 0, text = "关闭" },
        { value = 2, text = "2 px" },
        { value = 3, text = "3 px" },
        { value = 4, text = "4 px" },
        { value = 5, text = "5 px" },
    }

    MakeDropdown(content, row(T.dropH), "连击点（盗贼 / 德鲁伊）", CLASS_ITEMS,
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

    Group(content, row, "显示与行为")

    MakeCheckbox(content, "血量数字按百分比着色", row(T.rowH),
        function() return ns:DB().unitFrames.textColorByPercent end,
        function(value)
            ns:DB().unitFrames.textColorByPercent = value
            RefreshUnitFrames()
        end)

    MakeCheckbox(content, "血条数值平滑过渡", row(T.rowH),
        function() return ns:DB().unitFrames.smoothBars end,
        function(value)
            ns:DB().unitFrames.smoothBars = value
            RefreshUnitFrames()
        end)

    MakeCheckbox(content, "宠物框平时透明（悬停 / 选中才显现）", row(T.rowH),
        function() return ns:DB().unitFrames.petHover ~= false end,
        function(value)
            ns:DB().unitFrames.petHover = value
            RefreshUnitFrames()
        end)

    MakeCheckbox(content, "显示暴雪团队标记（目标 / 焦点 / 目标的目标）", row(T.rowH),
        function() return ns:DB().unitFrames.showRaidIcon ~= false end,
        function(value)
            ns:DB().unitFrames.showRaidIcon = value
            RefreshUnitFrames()
        end)

    local NUMBER_ITEMS = {
        { value = "auto", text = "自动 (K / M / B)" },
        { value = "cn",   text = "中文 (万 / 亿)" },
    }
    MakeDropdown(content, row(T.dropH), "大数字格式", NUMBER_ITEMS,
        function() return ns:DB().numberFormat end,
        function(value)
            ns:DB().numberFormat = value
            RefreshUnitFrames()
        end)

    MakeCheckbox(content, "显示目标框光环（战斗中延后）", row(T.rowH),
        function() return ns:DB().unitFrames.showTargetAuras end,
        function(value)
            ns:DB().unitFrames.showTargetAuras = value
            RefreshUnitFrames()
        end)

    sec.bodyHeight = -row.y + T.hintPad

    sec = BeginPage("groups", "团队与首领")
    content = sec.body
    row = LayoutCursor(0)

    Group(content, row, "小队与团队")

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

    MakeCheckbox(content, "小队框架（自己 + 小队 1-4）", row(T.rowH),
        GroupGetter("party", "enabled", true), GroupSetter("party", "enabled"))

    MakeCheckbox(content, "团队框架（8 组 × 5 人）", row(T.rowH),
        GroupGetter("raid", "enabled", true), GroupSetter("raid", "enabled"))

    MakeCheckbox(content, "小队框里显示自己", row(T.rowH),
        GroupGetter("party", "showPlayer", true), GroupSetter("party", "showPlayer"))

    MakeCheckbox(content, "隐藏暴雪自带的小队 / 团队框", row(T.rowH),
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
    MakeDropdown(content, row(T.dropH), "小队框宽度", PARTY_WIDTHS,
        GroupGetter("party", "width", 110), GroupSetter("party", "width"))

    local RAID_WIDTHS = {
        { value = 60, text = "60 px" },
        { value = 72, text = "72 px" },
        { value = 84, text = "84 px" },
        { value = 96, text = "96 px" },
    }
    MakeDropdown(content, row(T.dropH), "团队框宽度", RAID_WIDTHS,
        GroupGetter("raid", "width", 72), GroupSetter("raid", "width"))

    local HEALTH_TEXT_MODES = {
        { value = "none", text = "不显示" },
        { value = "percent", text = "百分比" },
        { value = "value", text = "当前值" },
    }
    MakeDropdown(content, row(T.dropH), "小队血量文字", HEALTH_TEXT_MODES,
        GroupGetter("party", "healthText", "none"), GroupSetter("party", "healthText"))

    MakeDropdown(content, row(T.dropH), "团队血量文字", HEALTH_TEXT_MODES,
        GroupGetter("raid", "healthText", "none"), GroupSetter("raid", "healthText"))

    MakeCheckbox(content, "血条上显示治疗预估（主题色的浅色延伸段）", row(T.rowH),
        function() return ns:DB().groupFrames.showIncomingHeals ~= false end,
        function(value)
            ns:DB().groupFrames.showIncomingHeals = value
            RefreshGroups()
        end)

    MakeCheckbox(content, "血条上显示吸收盾（白色叠层）", row(T.rowH),
        function() return ns:DB().groupFrames.showAbsorbs ~= false end,
        function(value)
            ns:DB().groupFrames.showAbsorbs = value
            RefreshGroups()
        end)

    -- 首领框架与小队、团队框架共用页面。
    Group(content, row, "首领框架")

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

    MakeCheckbox(content, "启用首领框架", row(T.rowH),
        BossGetter("enabled", true), BossSetter("enabled"))

    MakeCheckbox(content, "隐藏暴雪自带首领框", row(T.rowH),
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
    MakeDropdown(content, row(T.dropH), "首领框宽度", BOSS_WIDTHS,
        BossGetter("width", 180), BossSetter("width"))

    local BOSS_HEALTH = {
        { value = 14, text = "14 px" },
        { value = 16, text = "16 px" },
        { value = 20, text = "20 px" },
        { value = 24, text = "24 px" },
    }
    MakeDropdown(content, row(T.dropH), "首领血条高度", BOSS_HEALTH,
        BossGetter("health", 20), BossSetter("health"))

    MakeDropdown(content, row(T.dropH), "首领血量文字", HEALTH_TEXT_MODES,
        BossGetter("healthText", "none"), BossSetter("healthText"))

    sec.bodyHeight = -row.y + T.hintPad

    sec = BeginPage("actionBars", "动作条")
    content = sec.body
    row = LayoutCursor(0)

    Group(content, row, "动作条与布局")

    MakeCheckbox(content, "启用 MonetUI 动作条", row(T.rowH),
        function() return ns:DB().actionBars.ownBars end,
        function(value)
            ns:DB().actionBars.ownBars = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "隐藏暴雪默认动作条", row(T.rowH),
        function() return ns:DB().actionBars.hideBlizzard end,
        function(value)
            ns:DB().actionBars.hideBlizzard = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "隐藏暴雪默认背包条", row(T.rowH),
        function() return ns:DB().actionBars.hideBagBar end,
        function(value)
            ns:DB().actionBars.hideBagBar = value
            RefreshActionBars()
        end)

    Hint(content, row, "关闭 MonetUI 动作条时，请同时关闭“隐藏暴雪默认动作条”；战斗等受限期间，创建或收养会延后到限制解除。")

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

    MakeDropdown(content, row(T.dropH), "按钮尺寸", SIZE_ITEMS,
        function() return ns:DB().actionBars.buttonSize end,
        function(value)
            ns:DB().actionBars.buttonSize = value
            RefreshActionBars()
        end)

    MakeDropdown(content, row(T.dropH), "按钮间距", SPACING_ITEMS,
        function() return ns:DB().actionBars.spacing end,
        function(value)
            ns:DB().actionBars.spacing = value
            RefreshActionBars()
        end)

    MakeDropdown(content, row(T.dropH), "显示动作条数量", COUNT_ITEMS,
        function() return ns:DB().actionBars.barCount end,
        function(value)
            ns:DB().actionBars.barCount = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "显示快捷键", row(T.rowH),
        function() return ns:DB().actionBars.showHotkey end,
        function(value)
            ns:DB().actionBars.showHotkey = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "显示堆叠数量", row(T.rowH),
        function() return ns:DB().actionBars.showCount end,
        function(value)
            ns:DB().actionBars.showCount = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "显示宏名", row(T.rowH),
        function() return ns:DB().actionBars.showMacro end,
        function(value)
            ns:DB().actionBars.showMacro = value
            RefreshActionBars()
        end)

    Group(content, row, "宠物与姿态")

    MakeCheckbox(content, "宠物动作条悬停高亮（平时 30%）", row(T.rowH),
        function() return ns:DB().actionBars.petHover ~= false end,
        function(value)
            ns:DB().actionBars.petHover = value
            RefreshActionBars()
        end)

    MakeCheckbox(content, "姿态条悬停高亮（平时 30%）", row(T.rowH),
        function() return ns:DB().actionBars.stanceHover ~= false end,
        function(value)
            ns:DB().actionBars.stanceHover = value
            RefreshActionBars()
        end)

    sec.bodyHeight = -row.y + T.hintPad

    sec = BeginPage("nameplates", "姓名板")
    content = sec.body
    row = LayoutCursor(0)

    Group(content, row, "显示单位")

    -- 姓名板显示开关由客户端 CVar 驱动。
    MakeCheckbox(content, "显示敌方姓名板", row(T.rowH), NameplateCheckbox("showEnemy"))
    MakeCheckbox(content, "显示友方玩家姓名板", row(T.rowH), NameplateCheckbox("showFriendly"))
    MakeCheckbox(content, "显示友方 NPC 姓名板", row(T.rowH), NameplateCheckbox("showNPC"))
    MakeCheckbox(content, "显示低等级（minus）敌人", row(T.rowH), NameplateCheckbox("showMinor"))
    MakeCheckbox(content, "显示图腾", row(T.rowH), NameplateCheckbox("showTotems"))
    MakeCheckbox(content, "显示自己的姓名板", row(T.rowH), NameplateCheckbox("showSelf"))
    MakeCheckbox(content, "过滤小动物", row(T.rowH), NameplateCheckbox("hideCritters"))
    MakeCheckbox(content, "过滤死亡单位", row(T.rowH), NameplateCheckbox("hideDead"))

    Group(content, row, "姓名板内容")

    MakeCheckbox(content, "显示名称", row(T.rowH), NameplateCheckbox("showName"))
    MakeCheckbox(content, "显示等级 / 精英标记", row(T.rowH), NameplateCheckbox("showLevel"))
    MakeCheckbox(content, "显示血量百分比", row(T.rowH), NameplateCheckbox("showPercent"))
    MakeCheckbox(content, "显示暴雪团队标记", row(T.rowH), NameplateCheckbox("showRaidIcon"))
    MakeCheckbox(content, "显示施法条", row(T.rowH), NameplateCheckbox("showCast"))
    MakeCheckbox(content, "显示减益光环（仅自己施放）", row(T.rowH), NameplateCheckbox("showAuras"))
    MakeCheckbox(content, "职业 / 阵营着色", row(T.rowH), NameplateCheckbox("classColor"))
    MakeCheckbox(content, "仇恨描边", row(T.rowH), NameplateCheckbox("showThreat"))
    MakeCheckbox(content, "当前目标：金色描边 + 放大 1.1 倍", row(T.rowH), NameplateCheckbox("highlightTarget"))
    MakeCheckbox(content, "数值平滑过渡", row(T.rowH), NameplateCheckbox("smooth"))
    MakeCheckbox(content, "同步暴雪点击区域", row(T.rowH), NameplateCheckbox("forcePlateSize"))

    Group(content, row, "尺寸与距离")

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

    MakeDropdown(content, row(T.dropH), "姓名板宽度", NP_WIDTH,
        function() return NameplateSetting("width") end, NameplateSetter("width"))
    MakeDropdown(content, row(T.dropH), "姓名板高度", NP_HEIGHT,
        function() return NameplateSetting("height") end, NameplateSetter("height"))
    -- 姓名与等级字号固定在像素网格上，不提供无效尺寸选项。
    MakeDropdown(content, row(T.dropH), "施法条高度", NP_CAST,
        function() return NameplateSetting("castHeight") end, NameplateSetter("castHeight"))
    MakeDropdown(content, row(T.dropH), "名称截断长度", NP_LENGTH,
        function() return NameplateSetting("nameLength") end, NameplateSetter("nameLength"))
    MakeDropdown(content, row(T.dropH), "最大显示距离", NP_DISTANCE,
        function() return NameplateSetting("viewDistance") end, NameplateSetter("viewDistance"))

    sec.bodyHeight = -row.y + T.hintPad

    sec = BeginPage("cooldown", "冷却计时")
    content = sec.body
    row = LayoutCursor(0)

    local function CooldownSaved()
        local db = ns:DB()
        if type(db.cooldown) ~= "table" then db.cooldown = {} end
        return db.cooldown
    end

    --- 立即刷新全部冷却倒计时的颜色、大小与单位。
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

    Group(content, row, "时间格式")

    MakeCheckbox(content, "单位自动缩放（秒 → 分钟 → 小时 → 天）", row(T.rowH),
        CooldownSetting("scale"),
        function(value)
            CooldownSaved().scale = value
            CooldownRefresh()
        end)

    Group(content, row, "紧迫提醒")

    MakeCheckbox(content, "剩余时间紧张时变红 + 放大字体", row(T.rowH),
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
    MakeDropdown(content, row(T.dropH), "紧张阈值（秒）", ALERT_ITEMS,
        CooldownSetting("alertSeconds"),
        function(value)
            CooldownSaved().alertSeconds = value
            CooldownRefresh()
        end)

    -- 低于该秒数时显示一位小数。
    local TENTH_ITEMS = {
        { value = 0,  text = "关闭" },
        { value = 3,  text = "3 秒" },
        { value = 5,  text = "5 秒" },
        { value = 10, text = "10 秒" },
        { value = 20, text = "20 秒" },
    }
    MakeDropdown(content, row(T.dropH), "小数秒阈值（低于则显示 0.1s）", TENTH_ITEMS,
        CooldownSetting("tenthsTH"),
        function(value)
            CooldownSaved().tenthsTH = value
            CooldownRefresh()
        end)

    -- 达到该秒数后改用 mm:ss 格式。
    local MMSS_ITEMS = {
        { value = 0,   text = "关闭（用 1m / 1h）" },
        { value = 30,  text = "30 秒" },
        { value = 60,  text = "60 秒" },
        { value = 120, text = "120 秒" },
    }
    MakeDropdown(content, row(T.dropH), "m:ss 阈值（达到则显示 1:05）", MMSS_ITEMS,
        CooldownSetting("mmssTH"),
        function(value)
            CooldownSaved().mmssTH = value
            CooldownRefresh()
        end)

    sec.bodyHeight = -row.y + T.hintPad

    local minimap = ns:GetModule("Minimap")
    if minimap then
        sec = BeginPage("minimap", "小地图")
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

        Group(content, row, "地图交互")

        MakeCheckbox(content, "悬停小地图时显示区域名", row(T.rowH),
            MapSetting("zoneText"), MapSetter("zoneText"))

        MakeCheckbox(content, "战区时区域名染成危险色", row(T.rowH),
            MapSetting("zonePvPColor"), MapSetter("zonePvPColor"))

        MakeCheckbox(content, "滚轮缩放（方形地图四角也够得到）", row(T.rowH),
            MapSetting("scrollZoom"), MapSetter("scrollZoom"))

        MakeCheckbox(content, "右键小地图打开微型菜单", row(T.rowH),
            MapSetting("microMenu"), MapSetter("microMenu"))

        MakeCheckbox(content, "完整微型菜单（含日历与原生按钮）", row(T.rowH),
            MapSetting("microMenuSecure"), MapSetter("microMenuSecure"))

        Hint(content, row, "关闭完整菜单后仅保留背包、地图、设置，日历入口也会消失；无需重载。")

        -- 小地图使用统一的正方画布与矩形遮罩。
        -- 地图内三个按钮共用矩形图标布局。
        Group(content, row, "地图内的按钮")

        MakeCheckbox(content, "追踪（左下）", row(T.rowH),
            MapSetting("mapTracking"), MapSetter("mapTracking"))

        MakeCheckbox(content, "难度徽章（左上）", row(T.rowH),
            MapSetting("mapDifficulty"), MapSetter("mapDifficulty"))

        MakeCheckbox(content, "插件收纳（右上）", row(T.rowH),
            MapSetting("mapCompartment"), MapSetter("mapCompartment"))

        Hint(content, row, "追踪与插件收纳沿用暴雪按钮；难度为 MonetUI 自建徽章，仅在有难度信息时显示。")
        Hint(content, row, "左键标记 · 中键追踪菜单 · 右键微型菜单 · 滚轮缩放")

        -- 所有小地图按钮共用底部基线，此处只调整右边缘间距。
        MakeDropdown(content, row(T.dropH), "右边缘间距", {
            { value = 0,  text = "0（贴边）" },
            { value = 16, text = "16" },
            { value = 33, text = "33（默认）" },
            { value = 50, text = "50" },
            { value = 66, text = "66" },
        }, MapSetting("gap"), MapSetter("gap"))

        -- 勾选隐藏暴雪集群按钮，取消勾选恢复原样。
        Group(content, row, "暴雪集群按钮（勾选＝藏起来）")

        for _, entry in ipairs(minimap:ButtonList()) do
            -- 追踪与插件收纳由地图内按钮分组管理。
            if not entry.skipKey then
                MakeCheckbox(content, entry.label, row(T.rowH), MapSetting(entry.key), MapSetter(entry.key))
            end
        end

        row(T.gapS)                -- 行尾留白：纯前进，不取位置
        sec.bodyHeight = -row.y + T.hintPad
    end

    local infobar = ns:GetModule("InfoBar")
    if infobar then
        sec = BeginPage("infoBar", "信息栏")
        content = sec.body
        row = LayoutCursor(0)

        Group(content, row, "位置与外观")

        -- 设置变化只重新锚定和测量，不重建信息栏。
        local function ApplyBar()
            if infobar.Reapply then infobar.Reapply()
            else infobar:ApplyLayout() end
        end

        MakeDropdown(content, row(T.dropH), "贴边", {
            { value = true,  text = "顶边" },
            { value = false, text = "底边" },
        },
            function() return infobar:Settings().anchorTop end,
            function(value)
                infobar:Settings().anchorTop = value
                ApplyBar()
            end)

        MakeDropdown(content, row(T.dropH), "高度", {
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

        MakeCheckbox(content, "悬停淡入（系统信息格常显）", row(T.rowH),
            function() return infobar:Settings().mouseover end,
            function(value)
                infobar:Settings().mouseover = value and true or false
                ApplyBar()
            end)

        MakeCheckbox(content, "战斗时边缘呼吸闪烁", row(T.rowH),
            function() return infobar:Settings().combatPulse end,
            function(value)
                infobar:Settings().combatPulse = value and true or false
                if infobar.RefreshPulse then infobar.RefreshPulse() end
            end)

        Group(content, row, "经验与声望")

        MakeCheckbox(content, "底部经验线（悬停三角看数值）", row(T.rowH),
            function() return infobar:GetSetting("xp") end,
            function(value)
                infobar:Settings().xp = value and true or false
                ApplyBar()
            end)

        MakeCheckbox(content, "满级后这条线改显示声望", row(T.rowH),
            function() return infobar:GetSetting("xpFaction") end,
            function(value)
                infobar:Settings().xpFaction = value and true or false
                ApplyBar()
            end)

        -- 货币格仅提供模式、上限和零值设置；动态监控清单在货币格右键面板中。
        Group(content, row, "货币显示")

        local currency = infobar.Currency
        if currency then
            MakeDropdown(content, row(T.dropH), "货币来源", {
                { value = "backpack", text = "跟随背包显示" },
                { value = "custom",   text = "自定义监控清单" },
                { value = "all",      text = "全部已发现货币" },
            },
                function() return currency:Mode() end,
                function(value) currency:SetMode(value) end)

            local maxItems = {}
            for i = 1, 8 do maxItems[i] = { value = i, text = i .. " 项" } end
            MakeDropdown(content, row(T.dropH), "条上最多", maxItems,
                function() return currency:MaxOnBar() end,
                function(value) currency:SetMax(value) end)

            MakeDropdown(content, row(T.dropH), "0 值货币", {
                { value = true,  text = "显示" },
                { value = false, text = "隐藏" },
            },
                function() return currency:ShowZero() end,
                function(value) currency:SetShowZero(value) end)

        -- 图标模式在标题行显示图标与短数量，完整信息放入悬停提示。
            MakeCheckbox(content, "背包标题行：货币用图标（省位置，名称悬停可见）", row(T.rowH),
                function() return ns:DB().bags.currencyIcons ~= false end,
                function(value)
                    ns:DB().bags.currencyIcons = value and true or false
                    local bags = ns:GetModule("Bags")
                    if bags and bags.RefreshCurrencyTitles then bags:RefreshCurrencyTitles() end
                end)

            -- 自建按钮统一使用主题背板与织纹底。
            local picker = Widget:CreateFrame("MonetUIConfigCurrencyPicker", content, 150, T.ctrlH,
                "BackdropTemplate", "Button")
            Widget:Theme(picker, { thickness = 1, bgAlpha = 0.9 })
            Widget:ButtonMaterial(picker, { alpha = 0, weaveAlpha = 0.25 })
            picker:SetPoint("TOPLEFT", content, "TOPLEFT", T.padX, row(T.dropH) - 3)
            picker:EnableMouse(true)
            local pickerText = Widget:Font(picker, 12, "pixel", "edge", "CENTER")
            pickerText:SetPoint("CENTER", picker, "CENTER", 0, 1)
            pickerText:SetText("编辑监控清单")
            picker:SetScript("OnClick", function() currency:TogglePanel() end)

            Hint(content, row, "金币始终显示。跟随背包会读取客户端的背包显示标记；自定义清单跨角色保存，切换时继承当前显示项；全部已发现包含当前货币页项目。")
            Hint(content, row, "条上上限只折叠多余项，提示框仍列全；0 值默认隐藏。清单为空时先打开角色面板 → 货币加载数据。")
        end

        Group(content, row, "信息格")

        -- 信息格开关按注册顺序显示。
        for _, block in ipairs(infobar.blocks) do
            MakeCheckbox(content, block.label, row(T.rowH),
                function() return infobar:BlockEnabled(block.key) end,
                function(value)
                    local settings = infobar:Settings()
                    if type(settings.blocks) ~= "table" then settings.blocks = {} end
                    settings.blocks[block.key] = value and true or false
                    ApplyBar()
                end)
        end

        row(T.gapS)                -- 行尾留白：纯前进，不取位置
        sec.bodyHeight = -row.y + T.hintPad
    end

    local notifyPage
    local function NotifyPage()
        if not notifyPage then
            notifyPage = BeginPage("notify", "提示与通知")
            content = notifyPage.body
            row = LayoutCursor(0)
        end
        return notifyPage
    end

    local tooltip = ns:GetModule("Tooltip")
    if tooltip then
        NotifyPage()
        Group(content, row, "鼠标提示")

        -- 通用提示框位置同时应用于物品、技能、角色与信息栏提示。
        local TIP_ANCHOR = {
            { value = "cursor",  text = "跟随鼠标" },
            { value = "minimap", text = "小地图右上角" },
            { value = "off",     text = "暴雪默认位置" },
        }
        MakeDropdown(content, row(T.dropH), "提示框位置", TIP_ANCHOR,
            function() return tooltip:ResolveMode(tooltip) end,
            function(value)
                tooltip:Settings().anchor = value
                tooltip:Apply()
            end)

        MakeCheckbox(content, "单位提示补一行「目标」（它正在打谁）", row(T.rowH),
            function() return tooltip:GetSetting("enrich") end,
            function(value)
                tooltip:Settings().enrich = value and true or false
                tooltip:Apply()
            end)

        MakeCheckbox(content, "按住 Alt 显示 ID（NPC / 物品 / 法术）", row(T.rowH),
            function() return tooltip:GetSetting("idsByAlt") end,
            function(value)
                tooltip:Settings().idsByAlt = value and true or false
                tooltip:Apply()
            end)

        -- 只统一通用正文颜色，保留品质、职业与状态色。
        MakeCheckbox(content, "提示框正文统一成主题文字色（保留品质 / 职业色）", row(T.rowH),
            function() return tooltip:GetSetting("neutralText") end,
            function(value)
                tooltip:Settings().neutralText = value and true or false
                tooltip:Apply()
            end)

        MakeCheckbox(content, "战斗中隐藏主鼠标提示（默认开，含信息栏）", row(T.rowH),
            function() return tooltip:GetSetting("hideInCombat") end,
            function(value)
                tooltip:Settings().hideInCombat = value and true or false
                tooltip:Apply()
            end)

        Hint(content, row, "跟随鼠标会在屏幕边缘翻转；固定到小地图时，小地图模块关闭会退回跟随鼠标。边框与底色见「界面美化 → 系统 → 鼠标提示边框」。")

    end

    local cursor = ns:GetModule("Cursor")
    if cursor then
        NotifyPage()
        Group(content, row, "光标效果")

        MakeCheckbox(content, "光标拖尾（快速移动时拖出一条主题色笔迹）", row(T.rowH),
            function() return cursor:GetSetting("trail") end,
            function(value)
                cursor:Settings().trail = value and true or false
                cursor:Apply()
            end)

        MakeCheckbox(content, "光标速度星芒（快速甩动时出现十字光）", row(T.rowH),
            function() return cursor:GetSetting("glow") end,
            function(value)
                cursor:Settings().glow = value and true or false
                cursor:Apply()
            end)
    end

    local toast = ns:GetModule("Toast")
    if toast then
        NotifyPage()
        Group(content, row, "通知横幅")

        MakeCheckbox(content, "收到新邮件时弹一条提示（小地图邮件图标已隐藏）", row(T.rowH),
            function() return toast:GetSetting("mail") end,
            function(value)
                toast:Settings().mail = value and true or false
            end)

        MakeCheckbox(content, "背包满时弹一条提示（腾出空间后可再次提示）", row(T.rowH),
            function() return toast:GetSetting("bagFull") end,
            function(value)
                toast:Settings().bagFull = value and true or false
            end)

        MakeCheckbox(content, "进入 / 离开战斗时提醒", row(T.rowH),
            function() return toast:GetSetting("combatAlert") ~= false end,
            function(value)
                toast:Settings().combatAlert = value and true or false
            end)

        MakeDropdown(content, row(T.dropH), "停留时长", {
            { value = 3, text = "3 秒" },
            { value = 5, text = "5 秒" },
            { value = 8, text = "8 秒" },
        },
            function() return toast:GetSetting("duration") or 5 end,
            function(value)
                toast:Settings().duration = value
            end)

        Hint(content, row, "顶部居中显示，一次一条，其余排队；底边细线表示剩余时间，点击可提前关闭。")
    end

    local durability = ns:GetModule("Durability")
    if durability then
        NotifyPage()
        Group(content, row, "耐久警告")

        MakeCheckbox(content, "装备耐久过低时弹一条提示（修好 / 换装后才会再提醒）", row(T.rowH),
            function() return durability:GetSetting("warn") end,
            function(value)
                durability:Settings().warn = value and true or false
                durability:Apply()
            end)

        MakeDropdown(content, row(T.dropH), "提醒阈值", {
            { value = 20, text = "低于 20%" },
            { value = 30, text = "低于 30%" },
            { value = 50, text = "低于 50%" },
        },
            function() return durability:GetSetting("threshold") or 30 end,
            function(value)
                durability:Settings().threshold = value
                durability:Apply()
            end)

        Hint(content, row, "检查身上 10 个装备部位，取耐久最低的一件。")
    end

    if notifyPage then
        notifyPage.bodyHeight = -row.y + T.hintPad
    end

    local tweaks = ns:GetModule("Tweaks")
    if tweaks then
        sec = BeginPage("tweaks", "控制台优化")
        content = sec.body
        row = LayoutCursor(0)

        Group(content, row, "画面与行为")

        local list = tweaks:Tweaks()
        for i = 1, #list do
            local t = list[i]
            MakeCheckbox(content, t.label, row(T.rowH),
                function() return tweaks:IsOn(t.key) end,
                function(value)
                    tweaks:Settings()[t.key] = value and true or false
                    tweaks:Apply()
                end)
        end

        Hint(content, row, "打开写入预设值；关闭时恢复插件记录的原值，你中途改过的值不会被覆盖。新存档默认开启；不存在或拒写的项见 /mui tweaks status。")
        sec.bodyHeight = -row.y + T.hintPad
    end

    sec = BeginPage("modules", "模块管理")
    content = sec.body
    row = LayoutCursor(0)

    Hint(content, row, "开关自动保存；部分布局、容器或安全框体变更会在战斗等受限窗口结束后生效。")

    local function moduleGetter(name)
        return function() return ns:IsModuleEnabled(name) end
    end
    local function moduleSetter(name)
        return function(value)
            ns:SetModuleEnabled(name, value)
            if refreshStatus then refreshStatus() end
        end
    end

    for _, group in ipairs(MODULE_GROUPS) do
        Group(content, row, group.caption)
        for _, name in ipairs(group.names) do
            moduleCheckboxes[name] = MakeCheckbox(content, MODULE_LABEL[name] or name, row(T.rowH),
                moduleGetter(name), moduleSetter(name))
        end
        row(T.gapS)
    end

    sec.bodyHeight = -row.y + T.hintPad

    -- 标题、页签与底部操作区固定，每页正文独立结算高度并滚动。

    -- 滚轮移动正文，滚动条滑块显示并拖动当前位置。
    -- scrollOffset 表示内容相对顶部向上移动的非负距离。
    local function ContentHeight()
        return root:GetHeight() or 0
    end

    local function MaxOffset()
        return math.max(0, ContentHeight() - (view:GetHeight() or 0))
    end

    local function UpdateThumb()
        local viewH = view:GetHeight() or 0
        local maxOffset = MaxOffset()
        if maxOffset <= 0 then
            scrollThumb:Hide()
            return
        end
        scrollThumb:Show()
        local contentH = ContentHeight()
        local thumbH = math.max(24, viewH * (viewH / (contentH > 0 and contentH or viewH)))
        scrollThumb:SetHeight(thumbH)
        -- 0 位于轨道顶端，1 位于轨道底端。
        local t = scrollOffset / maxOffset
        scrollThumb:ClearAllPoints()
        scrollThumb:SetPoint("TOPLEFT", scrollTrack, "TOPLEFT", 0, -t * (viewH - thumbH))
    end

    local function SetOffset(value)
        scrollOffset = math.max(0, math.min(MaxOffset(), value))
        -- 同时移动两个锚点，避免固定锚点拉扯内容尺寸。
        root:ClearAllPoints()
        root:SetPoint("TOPLEFT", view, "TOPLEFT", 0, scrollOffset)
        root:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, scrollOffset)
        UpdateThumb()
    end
    setOffset = SetOffset

    -- 按实际页数均分页签网格，模块缺失不会破坏排列。
    local function BuildTabs()
        local n = #pages
        local rows = math.max(1, math.ceil(n / T.tabPerRow))
        local perRow = math.max(1, math.ceil(n / rows))
        local w = Media:SnapUnit((T.contentW - (perRow - 1) * T.tabGap) / perRow)

        for i, page in ipairs(pages) do
            local r = math.floor((i - 1) / perRow)
            local c = (i - 1) % perRow
            -- MonetUI 前缀按钮由材质工厂自动维护悬停效果。
            local tab = Widget:CreateFrame("MonetUIConfigTab" .. i, tabBar, w, T.tabH,
                "BackdropTemplate", "Button")
            tab:SetPoint("TOPLEFT", tabBar, "TOPLEFT", c * (w + T.tabGap), -r * (T.tabH + T.tabGap))
            Widget:Theme(tab, { thickness = 1, bgAlpha = 0.55, borderAlpha = 1 })
            Widget:ButtonMaterial(tab, { alpha = 0, weaveAlpha = 0.18 })
            tab:EnableMouse(true)

            local fs = Widget:Font(tab, 12, "pixel", "neutral", "CENTER")
            fs:SetPoint("CENTER", tab, "CENTER", 0, 1)
            fs:SetWordWrap(false)
            fs:SetText(page.caption)

            -- 选中指示线使用与边框相同的主题高亮色。
            local mark = HLine(tab, { side = "bottom", inset = 2, h = 2, key = "highlight", alpha = 1 })
            mark:Hide()

            tab:SetScript("OnClick", function() SelectPage(i) end)
            -- 自建按钮直接使用脚本槽，不占用暴雪对象轮询。
            tab:SetScript("OnEnter", function() Widget:SetHoverLift(tab, true) end)
            tab:SetScript("OnLeave", function() Widget:SetHoverLift(tab, false) end)

            tabButtons[#tabButtons + 1] = { frame = tab, text = fs, mark = mark }
        end

        local barH = rows * T.tabH + (rows - 1) * T.tabGap
        Widget:Height(tabBar, barH)
        -- 页签栏与正文之间绘制分隔线。
        HLine(panel, { y = -(T.titleH + barH + T.tabGap + 1), inset = 14, alpha = 0.45 })
    end

    -- 面板统一处理滚轮事件，每次移动固定步长。
    panel:SetScript("OnMouseWheel", function(_, delta)
        -- 客户端向下滚动 delta 为正，对应偏移增大。
        SetOffset(scrollOffset + delta * 48)
    end)

    local dragging, dragStartY, dragStartOffset
    -- 拖动期间逐帧读取光标位置，松手后立即停止更新。
    local function Drag()
        if not dragging then
            scrollThumb:SetScript("OnUpdate", nil)
            return
        end
        local _, my = GetCursorPosition()
        -- 光标纵坐标向上，向下拖动对应偏移增大。
        SetOffset(dragStartOffset - (my - dragStartY) * Media:Mult())
    end

    -- 拖动回调只在工作期间登记到性能账本。
    local DragTracked = ns.Scheduler and ns.Scheduler:Profile("config:scroll", "配置滚动条拖动", Drag) or Drag

    scrollThumb:SetScript("OnMouseDown", function()
        -- 光标坐标是物理像素，位移需换算为界面单位。
        local _, my = GetCursorPosition()
        dragging, dragStartY, dragStartOffset = true, my, scrollOffset
        scrollThumb:SetScript("OnUpdate", DragTracked)
    end)
    scrollThumb:SetScript("OnMouseUp", function()
        dragging = false
        scrollThumb:SetScript("OnUpdate", nil)
    end)
    scrollThumb:SetScript("OnHide", function()
        dragging = false
        scrollThumb:SetScript("OnUpdate", nil)
    end)

    BuildTabs()
    SelectPage(1)

    -- 底部操作区：命令提示与重载按钮。
    HLine(panel, { side = "bottom", y = T.bottomH - 8, inset = 14, alpha = 0.45 })

    local hint = Widget:Font(panel, 12, "pixel", "neutral", "LEFT")
    hint:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", T.padX, 36)
    hint:SetWidth(T.contentW)
    hint:SetJustifyH("LEFT")
    hint:SetText("设置自动保存；/mui status 查状态，/mui reset 恢复默认。")

    -- 重载按钮与下拉按钮共用主题材质。
    local reload = Widget:CreateFrame("MonetUIConfigReload", panel, 120, T.ctrlH, "BackdropTemplate", "Button")
    Widget:Theme(reload, { thickness = 1, bgAlpha = 0.9 })
    Widget:ButtonMaterial(reload, { alpha = 0, weaveAlpha = 0.25 })
    reload:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -T.padX, 12)
    reload:EnableMouse(true)
    local reloadText = Widget:Font(reload, 12, "pixel", "edge", "CENTER")
    reloadText:SetPoint("CENTER", reload, "CENTER", 0, 1)
    reloadText:SetText("重载界面")
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
