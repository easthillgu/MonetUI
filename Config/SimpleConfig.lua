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

-- Only the selected page is on screen: the rows live in a scrollable content frame (the panel itself
-- stays a fixed size on screen -- it is clamped to the screen, so an unbounded height would push the
-- last rows out of reach), and the scroll range is that one page's height, never the sum of all pages.
local root, view, scrollThumb, scrollTrack   -- root = 滚动内容根框；各**页**（主菜单一项一页）挂在它下面
local scrollOffset = 0
local setOffset        -- Build 里定义，Show/Toggle 打开面板时归零

-- 主菜单：pages 按建页顺序排列，一页 = 一个按钮 + 一块正文。
local pages, tabButtons = {}, {}
local selected = 1
local tabBar           -- 按钮容器（建面板时就挂好，走到 Build 末尾才知道最终有几页）

-- ══ 设计令牌 —— 面板美术的唯一口径 ---------------------------------------------------
-- 以前同一个面板里同时躺着 20 / 22 / 24 / 26 / 28 / 30 六种行高、120 / 216 / 276 / 300 / 328 五种
-- 限宽，而且 view 和行**各缩一次 24**（合计 48）：加一行只能照抄邻居的魔法数，于是"每个分组各画
-- 一套"。现在只有一个来源 —— 行高三档（组名 / 复选框 / 下拉）+ 提示按行数现算，横向只缩一次
-- （T.padX），正文宽 = 面板宽 - 2×padX：所有行、按钮、细线共用同一条竖线。
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

--- 提示段落的行数：按 UTF-8 字节现算（全角 3 字节 / 半角 1 字节）。不查客户端的字体度量 ——
--- 本仓的判例是"量到的不一定是这一帧的布局"，宁可估宽一点多空一格，也不要压字。
local function HintLines(text)
    local bytes = string.len(text)
    local ascii = select(2, string.gsub(text, "[\1-\127]", ""))
    local cjk = (bytes - ascii) / 3
    local width = cjk * 12.6 + ascii * 7
    return math.max(1, math.ceil(width / (T.contentW - 12)))
end

--- 一段提示占的整块行高（几行就是几行，不再逐处手写 34 / 38 / 44 / 46 / 48）。
local function HintH(text)
    return HintLines(text) * T.hintLine + T.hintPad
end

-- ---------------------------------------------------------------------------
-- 手画的那几笔（分隔线、下拉箭头、滚动条、页签指示线）不进 Widget 的主题登记表：它们是裸贴图，
-- 创建时把颜色烙上去之后就不动了，换主题会留下旧色。统一登记到 tinted、一次重涂；颜色只从
-- Widget:PaletteColor 的命名档取，本文件不出现字面色值。
-- ---------------------------------------------------------------------------
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

local MODULE_ORDER = {
    "UnitFrames", "Cooldown", "BuffFrame",
    "Minimap", "Bags", "QuestTracker", "ActionBars", "Nameplates", "Skins",
    "InfoBar", "Tooltip", "Cursor", "Toast", "Durability",
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
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", T.padX, yOffset)
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
    text:SetWidth(T.textW)
    text:SetWordWrap(false)
    text:SetText(label)

    return cb, text
end

--- 页内组名：一行字 + 一条发丝线，画法与标题带、页签底下的线同一套。
--- 自己吃掉一个组名行高，调用点只写 `Group(content, row, "能量条")`；页里要再分小组时才用。
local function Group(parent, cursor, caption)
    local y = cursor(T.capH)
    local fs = Widget:Font(parent, 12, "pixel", "edge", "LEFT")
    if ns.Skin then ns.Skin:TextTier(fs, "section") end -- section 档（12/edge）：组名 = 分区头，统一入口
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", T.padX, y - 4)
    fs:SetText(caption)
    HLine(parent, { y = y - T.capH + 5, alpha = 0.3 })
    return y
end

--- 一段说明文字：原点、限宽、行距、颜色档全从令牌走，占几行按文本现算，布局光标自动让位。
--- 以前这里是每处自己 SetWidth(328) + 手写 34 / 38 / 44 / 46 / 48，改一次面板宽就要全表重算。
local function Hint(parent, cursor, text)
    local fs = Widget:Font(parent, 12, "pixel", "neutral", "LEFT")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", T.padX, cursor(HintH(text)) - 4)
    fs:SetWidth(T.contentW)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
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
    -- 长选项（"自动（按分辨率固定，像素完美）"）会折成两行、从按钮里溢出来，
    -- 压到下一行上。关掉换行，超宽就切在按钮右边。
    value:SetWordWrap(false)

    -- 箭头用真材质（monet_chevron_up 朝下翻转）：像素字的 "v" 在小字号下读成字母而不是
    -- 控件符号，和全仓滚动条/步进钮的 chevron 也不是一种画风。颜色走 tinted 登记，换主题重涂。
    local chevron = button:CreateTexture(nil, "ARTWORK", nil, 2)
    chevron:SetSize(8, 8)
    chevron:SetPoint("RIGHT", button, "RIGHT", -6, 0)
    chevron:SetTexture(Media:Texture("monet_chevron_up"))
    Widget:Arrow(chevron, "down")
    Tint(chevron, "neutral", 1)

    -- The list hangs off the panel (UIParent) so the panel can never clip it.
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

    -- 页 / 页签 / 手画贴图都登记在模块级的表里；Build 只跑一次（上面有 panel 守卫），
    -- 这里清一遍，是为了万一以后面板能被销毁重建时不会攒出第二套页签。
    pages, tabButtons, tinted = {}, {}, {}
    selected = 1

    panel = Widget:CreateFrame("MonetUIConfigFrame", UIParent, T.panelW, T.panelH)
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

    -- ---- ① 标题行：独占一行，标题不再和正文抢地方 ------------------------------------
    -- 三段：睡莲 logo + 名字（左）· 版本与一句话（右，让开关闭钮）· 关闭钮（右上角）。
    local titleBar = CreateFrame("Frame", nil, panel)
    titleBar:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    Widget:Height(titleBar, T.titleH)

    -- Logo 整图烘焙彩色（见 Media 注册处），只给 alpha、不染色。
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
    subtitle:SetText("v" .. ns.version .. " · 印象派自适应界面")

    -- 关闭钮的 Monet 细金 ✕ 由 Widget:CloseButton 工厂内部就挂好了（全仓唯一入口），这里不再补一句。
    local close = Widget:CloseButton(panel)
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)

    -- Chrome: a cool drop shadow plus brush corner ornaments; the top-right corner stays bare because the close button already owns it.
    Widget:Shadow(panel, { size = 7, alpha = 0.5 })
    Widget:Corners(panel, { omit = { "TOPRIGHT" } })

    -- 标题下一笔手绘笔刷（2026-11-20 A4）：monet_brush_stroke 保留美术色、只调 alpha；
    -- Widget:Rule 靠 Marked(panel,"rule") 幂等，重复开面板不会越叠越多；一屏只此一条。
    Widget:Rule(titleBar, title, { alpha = 0.9 })

    -- ---- ② 主菜单：横向按钮，点一个只显示那一页 --------------------------------------
    tabBar = CreateFrame("Frame", nil, panel)
    tabBar:SetPoint("TOPLEFT", panel, "TOPLEFT", T.padX, -T.titleH)
    tabBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -T.padX, -T.titleH)
    Widget:Height(tabBar, T.tabH)

    -- ---- ③ 正文：`content` = 当前页的 body，行以它的左上角为原点 ------------------------
    -- 剪进 view 的是"这一页"，所以滚过的行绝不会滑到标题或主菜单上面。
    view = CreateFrame("Frame", nil, panel)
    view:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -T.tabGap)
    view:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, T.bottomH)
    view:SetClipsChildren(true)

    root = CreateFrame("Frame", nil, view)
    root:SetPoint("TOPLEFT", view, "TOPLEFT", 0, 0)
    root:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, 0)
    root:SetHeight(100)

    local content, row, sec   -- row = 行布局光标（每页 LayoutCursor(0) 重新赋值）

    -- 光标式行布局(review 2026-10-24 #8):设置面板是纯垂直流,以前每行手写
    -- "y = y - 28" 记账、增删一行要重算一片偏移;现在 row(h) 取"当前行的 y"并
    -- 前进 h —— 取用即记账。row.y 为纯读(页结算 bodyHeight 用)。
    local function LayoutCursor(yStart)
        return setmetatable({ y = yStart }, {
            __call = function(self, step)
                local at = self.y
                self.y = self.y - step
                return at
            end,
        })
    end

    --- 建一页 = 建一块正文（主菜单按钮在 Build 末尾按 pages 现生成，所以模块没加载 ⇒ 页没建 ⇒ 按钮也没有）。
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

    -- 页签的三态就这三处：常态（暗底 + 中性字）、悬停（背板抬一档，SetHoverLift）、选中
    -- （边框换 highlight + 亮字 + 底下一条指示线）。颜色一律从命名档取，页签自己不持有任何色值。
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

    --- 切页：只显示那一页的正文，滚动范围跟着那一页走。面板高固定（T.panelH），
    --- title 和主菜单钉在顶上不随内容多少上下跳。
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
        -- 页框的高和滚动内容的高都在切页时一次落定：bodyHeight 建页时已经把这页的行、
        -- 分界线、末尾留白全算进去了（含 hintPad），这里只是把它们写到框子上。
        Widget:Height(page.body, bodyH)
        Widget:Height(root, bodyH)
        if setOffset then setOffset(0) end
    end

    -- Slim scrollbar on the right: a track plus a draggable thumb, both drawn here
    -- (the client's own scrollbar art is not part of the Monet look).  上下贴 view 那一段，
    -- 主菜单换行 / 底部带变高都自动让位 —— 以前是写死的 -50 / 58，一改标题行高度就对不上。
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

    -- 这两块是 SetColorTexture 平涂的纯色（不是贴图），换主题只能重涂颜色本身；
    -- 贴图那几笔（细线 / 下拉箭头 / 页签指示线）走 tinted → RepaintTinted。
    local function RepaintScrollbar()
        local nr, ng, nb = Color:GetNeutral()
        scrollTrack:SetColorTexture(nr, ng, nb, 0.25)
        local er, eg, eb = Color:GetEdge()
        thumbTex:SetColorTexture(er, eg, eb, 0.8)
    end
    RepaintScrollbar()

    -- 主题换色只留这一个出口：贴图重染、纯色块重涂、选中页签把 highlight 重新按一遍。
    -- （Widget / Skin 各自的 handler 在文件加载时就注册了，本面板的注册在它们之后，
    --   所以这里按上去的是最终色，不会被登记表的老口径盖回去。）
    ns.EventBus:Register("MONETUI_THEME_CHANGED", function()
        if not panel then return end
        RepaintTinted()
        RepaintScrollbar()
        for i = 1, #tabButtons do PaintTab(i) end
    end)

    -- ① 主题外观
    sec = BeginPage("theme", "主题外观")
    content = sec.body
    row = LayoutCursor(0)

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
    local yZone = row(T.subH)
    local zoneCaption = Widget:Font(content, 10, "pixel", "neutral", "LEFT")
    if ns.Skin then ns.Skin:TextTier(zoneCaption, "caption") end -- caption 档（10/neutral）：区域配色标签是小字
    zoneCaption:SetPoint("TOPLEFT", content, "TOPLEFT", T.padX, yZone - 4)
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

    -- 第二行：左边一句状态（缺色时才有字），右边四档的名字，按从暗到亮的阶梯顺序。
    -- 图例先建，状态行再把右边缘挂在图例左边缘上：以前状态行是"contentW - 150"的写死宽，
    -- 图例比 150 宽一点（10 号字 ~133 + 左边距），两个文本会压在一起 7px。
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
    MakeDropdown(content, row(T.dropH), "边框颜色", BORDER_ITEMS,
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
    MakeDropdown(content, row(T.dropH), "UI 缩放", SCALE_ITEMS,
        function() return (ns:DB().theme or {}).uiScaleMode or "auto" end,
        function(value)
            ns:DB().theme.uiScaleMode = value
            if value == "auto" then
                ns:DB().theme.uiScaleApplied = nil
            end
            ns:Print("UI 缩放模式：" .. (value == "auto" and "自动（下次 /reload 生效）" or "跟随游戏设置") .. "。")
        end)

    sec.bodyHeight = -row.y + T.hintPad

    sec = BeginPage("modules", "模块")
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
        moduleCheckboxes[name] = MakeCheckbox(content, MODULE_LABEL[name] or name, row(T.rowH),
            moduleGetter(name), moduleSetter(name))
    end

    sec.bodyHeight = -row.y + T.hintPad

    sec = BeginPage("cooldown", "冷却计时")
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

    MakeCheckbox(content, "单位自动缩放（秒 → 分钟 → 小时 → 天）", row(T.rowH),
        CooldownSetting("scale"),
        function(value)
            CooldownSaved().scale = value
            CooldownRefresh()
        end)

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

    -- TenthTH: below this many seconds show one decimal ("4.3").
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

    -- MmssTH: at/above this many seconds use mm:ss ("1:05").
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

        MakeCheckbox(content, "悬停小地图时显示区域名", row(T.rowH),
            MapSetting("zoneText"), MapSetter("zoneText"))

        MakeCheckbox(content, "战区时区域名染成危险色", row(T.rowH),
            MapSetting("zonePvPColor"), MapSetter("zonePvPColor"))

        MakeCheckbox(content, "滚轮缩放（方形地图四角也够得到）", row(T.rowH),
            MapSetting("scrollZoom"), MapSetter("scrollZoom"))

        MakeCheckbox(content, "右键小地图弹出微型游戏菜单", row(T.rowH),
            MapSetting("microMenu"), MapSetter("microMenu"))

        MakeCheckbox(content, "微型菜单用全量安全载体（自有动作 + 代点原生按钮）", row(T.rowH),
            MapSetting("microMenuSecure"), MapSetter("microMenuSecure"))

        -- 地图形状只有一套（正方画布 + 遮罩裁带），不再提供切换

        -- 地图内的三个独立按钮（3:4 矩形图标）
        Group(content, row, "地图内的按钮")

        MakeCheckbox(content, "追踪（左下）", row(T.rowH),
            MapSetting("mapTracking"), MapSetter("mapTracking"))

        MakeCheckbox(content, "难度（左上）", row(T.rowH),
            MapSetting("mapDifficulty"), MapSetter("mapDifficulty"))

        MakeCheckbox(content, "插件收纳（右上）", row(T.rowH),
            MapSetting("mapCompartment"), MapSetter("mapCompartment"))

        Hint(content, row, "追踪 / 插件收纳开着时，暴雪原来那一个被搬进地图，不再单独隐藏。")

        -- 手势速查（写在面板里，免得翻文档）
        Hint(content, row, "左键打标记（四个角也算）· 中键开追踪菜单 · 右键微型菜单 · 滚轮缩放")

        -- 底边高度是统一的（Utils/Layout.lua 的基线，和第一动作条同一条线），
        -- 这个下拉只管**右边缘**离屏幕右边多远。
        MakeDropdown(content, row(T.dropH), "右边缘间距", {
            { value = 0,  text = "0（贴边）" },
            { value = 16, text = "16" },
            { value = 33, text = "33（默认）" },
            { value = 50, text = "50" },
            { value = 66, text = "66" },
        }, MapSetting("gap"), MapSetter("gap"))

        -- 暴雪的集群按钮：勾选＝藏起来（方形面板和暴雪原样按钮混在一起最难看），
        -- 取消勾选＝把暴雪那个按钮原样放回来。
        Group(content, row, "暴雪集群按钮（勾选＝藏起来）")

        for _, entry in ipairs(minimap:ButtonList()) do
            -- 追踪 / 插件收纳由"地图内的按钮"那一组管，这里不重复列
            if not entry.skipKey then
                MakeCheckbox(content, entry.label, row(T.rowH), MapSetting(entry.key), MapSetter(entry.key))
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

    for _, group in ipairs(COLOR_GROUPS) do
        Group(content, row, group.label)
        local unit = group.units[1]
        -- UnitSetting 返回 (get, set) **两个值**：直接塞在参数表里时，只有出现在最后一位才会
        -- 展开；放中间会被截成 1 个值，后面的参数就整体错位（第一版就是这样把 swatch 挤进了
        -- setter 位、下拉选择变成静默不保存）。所以这里显式接住再说。
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
            -- "按能量类型"：用玩家当前的资源类型作参考（预览而已）
            local _, token = UnitPowerType("player")
            local map = { MANA = { 0.20, 0.50, 0.90 }, RAGE = { 0.85, 0.20, 0.20 },
                          ENERGY = { 0.90, 0.85, 0.25 }, FOCUS = { 0.85, 0.45, 0.15 } }
            local c = map[token or ""]
            if c then return c[1], c[2], c[3] end
            return Color:GetResource()
        end)

    Hint(content, row, "血条 = 有血的那段；空槽 = 掉掉的那段（选实色时那层布纹会自动压淡）。右边小方块就是实际颜色。")

    -- One row for two settings: 0 means "off", anything else is the pip height.
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

    MakeCheckbox(content, "宠物框悬停 / 选中才显示", row(T.rowH),
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

    -- The borrowed list's on/off is decided when Blizzard's TargetFrame is first suppressed, so -- like "hideBlizzard" above -- this applies on the next load: a runtime switch cannot re-register what a full-kill removed.
    MakeCheckbox(content, "显示目标框光环（借用暴雪，需重载）", row(T.rowH),
        function() return ns:DB().unitFrames.showTargetAuras end,
        function(value)
            ns:DB().unitFrames.showTargetAuras = value
            RefreshUnitFrames()
        end)

    sec.bodyHeight = -row.y + T.hintPad

    sec = BeginPage("groups", "团队框架")
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

    MakeCheckbox(content, "锁定所有可移动框（网格吸附与拖动）", row(T.rowH),
        function() return ns:DB().mover.locked end,
        function(value)
            ns:DB().mover.locked = value
            -- 锁是即时判断的（拖动时才读），不需要重贴：下一帧拖动就按新状态走
        end)

    sec.bodyHeight = -row.y + T.hintPad

    -- 首领框和小队 / 团队框是同一类东西（一屋子人的血条）：同一页，用一个组名分开。
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

    MakeCheckbox(content, "自绘动作条（LibActionButton）", row(T.rowH),
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

    -- Which units get a plate at all (CVars; see Modules/Nameplates).
    MakeCheckbox(content, "显示敌方姓名板", row(T.rowH), NameplateCheckbox("showEnemy"))
    MakeCheckbox(content, "显示友方玩家姓名板", row(T.rowH), NameplateCheckbox("showFriendly"))
    MakeCheckbox(content, "显示友方 NPC 姓名板", row(T.rowH), NameplateCheckbox("showNPC"))
    MakeCheckbox(content, "显示低等级（minus）敌人", row(T.rowH), NameplateCheckbox("showMinor"))
    MakeCheckbox(content, "显示图腾", row(T.rowH), NameplateCheckbox("showTotems"))
    MakeCheckbox(content, "显示自己的姓名板", row(T.rowH), NameplateCheckbox("showSelf"))
    MakeCheckbox(content, "过滤小动物", row(T.rowH), NameplateCheckbox("hideCritters"))
    MakeCheckbox(content, "过滤死亡单位", row(T.rowH), NameplateCheckbox("hideDead"))

    MakeCheckbox(content, "显示名称", row(T.rowH), NameplateCheckbox("showName"))
    MakeCheckbox(content, "显示等级 / 精英标记", row(T.rowH), NameplateCheckbox("showLevel"))
    MakeCheckbox(content, "显示血量百分比", row(T.rowH), NameplateCheckbox("showPercent"))
    MakeCheckbox(content, "显示暴雪团队标记", row(T.rowH), NameplateCheckbox("showRaidIcon"))
    MakeCheckbox(content, "显示施法条", row(T.rowH), NameplateCheckbox("showCast"))
    MakeCheckbox(content, "职业 / 阵营着色", row(T.rowH), NameplateCheckbox("classColor"))
    MakeCheckbox(content, "仇恨描边", row(T.rowH), NameplateCheckbox("showThreat"))
    MakeCheckbox(content, "当前目标：金色描边 + 放大 1.1 倍", row(T.rowH), NameplateCheckbox("highlightTarget"))
    MakeCheckbox(content, "数值平滑过渡", row(T.rowH), NameplateCheckbox("smooth"))
    MakeCheckbox(content, "同步暴雪点击区域", row(T.rowH), NameplateCheckbox("forcePlateSize"))

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
    -- Name/level font size is fixed on the 12px pixel grid (Media:SnapSize), so there is no size picker any more -- every choice would render as 12.
    MakeDropdown(content, row(T.dropH), "施法条高度", NP_CAST,
        function() return NameplateSetting("castHeight") end, NameplateSetter("castHeight"))
    MakeDropdown(content, row(T.dropH), "名称截断长度", NP_LENGTH,
        function() return NameplateSetting("nameLength") end, NameplateSetter("nameLength"))
    MakeDropdown(content, row(T.dropH), "显示距离", NP_DISTANCE,
        function() return NameplateSetting("viewDistance") end, NameplateSetter("viewDistance"))

    sec.bodyHeight = -row.y + T.hintPad

    local skins = ns:GetModule("Skins")
    if skins then
        sec = BeginPage("skins", "界面美化")
        content = sec.body
        row = LayoutCursor(0)

        local FONT_ITEMS = {
            { value = "off",   text = "关闭（原生字体）" },
            { value = "pixel", text = "像素字体（推荐）" },
        }
        -- Legacy saved values ("roadway", "number", ...) normalize through GetFontKey, so the row always shows one of the two entries above.
        MakeDropdown(content, row(T.dropH), "统一字体（全局）", FONT_ITEMS,
            function() return skins:GetFontKey() or "off" end,
            function(value)
                ns:DB().skins.font = value
                if skins.active then
                    skins:ApplyFont()
                    ns:Print("切换字体：重启界面可完全恢复原生字体。")
                end
            end)

        Hint(content, row, "统一字体影响所有暴雪窗口文字；关闭需重载界面恢复。")

        -- §8.89：页签行整框 alpha 由 GDM 控制，改设置即时生效（不用 /reload）。
        MakeCheckbox(content, "聊天页签悬停才显示", row(T.rowH),
            function() return ns:DB().skins.hoverChatTabs ~= false end,
            function(value)
                ns:DB().skins.hoverChatTabs = value and true or false
                if ns.Skins and ns.Skins.RefreshChatTabHover then
                    ns.Skins:RefreshChatTabHover()
                end
            end)

        -- §8.96 输入框平时状态三档（取代 §8.91 的二元「自动隐藏」复选框）：
        -- 渐隐（参考 ChatEditFade：空闲 25%、失焦 3 秒后开始、聚焦全亮）/ 全隐 / 常显。
        -- 切换由 PollWatch 下一拍按新值重钉或交给渐隐引擎，不必 /reload。
        MakeDropdown(content, row(T.dropH), "输入框平时状态", {
            { value = "fade", text = "渐隐（空闲 25%，聚焦全亮）" },
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

        -- 输入框位置：`show` / `fade` 档才看得出区别（`hide` 档一律折在顶部带里）。
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

        -- §8.90 聊天页签三态色 + 独立淡入时长。颜色用预设命名色（hex，不含 #），值直接存进
        -- ns:DB().skins.tabColor*；0.5 秒页签驱动会重上色（≤0.5s 即时反馈）。
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

        -- Group the windows by section, in registration order.
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

    local tooltip = ns:GetModule("Tooltip")
    if tooltip then
        sec = BeginPage("tooltip", "鼠标提示")
        content = sec.body
        row = LayoutCursor(0)

        -- 位置是全局行为：一个下拉管所有 GameTooltip（物品 / 技能 / 角色 / 光环 / 动作条……），
        -- 和信息栏自己的悬停提示也共用。
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

        -- 正文归一只动"通用文字"（白 / 灰 / 纯黄的描述行），品质、职业、套装绿、未达标红
        -- 这些身份信息一律不碰；标题行不参与（判据见 Modules/Tooltip.lua 的 IsStaticTextColor）。
        MakeCheckbox(content, "提示框正文统一成主题文字色（保留品质 / 职业色）", row(T.rowH),
            function() return tooltip:GetSetting("neutralText") end,
            function(value)
                tooltip:Settings().neutralText = value and true or false
                tooltip:Apply()
            end)

        -- 战斗中禁用全部提示：战斗中提示数据多是机密值，默认关掉最稳；
        -- 开 = 战斗中照常显示。setter 走 Apply，让 PlaceTick 的缓存立刻读到新值。
        MakeCheckbox(content, "战斗中禁用全部鼠标提示（默认开；关掉则战斗中照常显示）", row(T.rowH),
            function() return tooltip:GetSetting("hideInCombat") end,
            function(value)
                tooltip:Settings().hideInCombat = value and true or false
                tooltip:Apply()
            end)

        Hint(content, row, "用鼠标＝跟手（贴屏幕右/上边缘自动翻边）；用小地图＝提示框右下角对齐小地图面板右上角（面板临时隐藏时保持原位，只有小地图模块关掉才退回跟随）。边框与底色在上方「界面美化 → 系统 → 鼠标提示边框」。")

        -- 光标装饰（Modules/Cursor）：纯视觉，跟着主题色走；用模块开关整体关掉。
        local cursor = ns:GetModule("Cursor")
        if cursor then
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

        sec.bodyHeight = -row.y + T.hintPad
    end

    local toast = ns:GetModule("Toast")
    if toast then
        sec = BeginPage("notify", "通知横幅")
        content = sec.body
        row = LayoutCursor(0)

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

        MakeCheckbox(content, "进入 / 离开战斗时弹一条提醒（剑 / 盾 + 着色 + 文字）", row(T.rowH),
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

        Hint(content, row, "横幅在屏幕顶部居中，一次只显示一条，多的排队；底边一条细线随停留时间排空，点一下可提前关掉。")
        sec.bodyHeight = -row.y + T.hintPad
    end

    local durability = ns:GetModule("Durability")
    if durability then
        sec = BeginPage("durability", "耐久警告")
        content = sec.body
        row = LayoutCursor(0)

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

        Hint(content, row, "只看身上穿着的 10 个部位（头肩胸腿脚腕手腰主副手），取最低的那件。")
        sec.bodyHeight = -row.y + T.hintPad
    end

    local tweaks = ns:GetModule("Tweaks")
    if tweaks then
        sec = BeginPage("tweaks", "控制台优化")
        content = sec.body
        row = LayoutCursor(0)

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

        Hint(content, row, "逐条开关客户端控制台设置：打开写入、关掉还原成你原来的值。名单来自《无限》服常用优化，个别名字在本客户端可能不存在或被拒写——那样这条会空转，用 /mui tweaks status 看账本。默认全关。")
        sec.bodyHeight = -row.y + T.hintPad
    end

    local infobar = ns:GetModule("InfoBar")
    if infobar then
        sec = BeginPage("infoBar", "信息栏")
        content = sec.body
        row = LayoutCursor(0)

        -- Rebuild nothing on a settings change: the strip is re-anchored and the blocks re-measured in place.
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

        MakeCheckbox(content, "悬停淡入（平时只露底板）", row(T.rowH),
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

        -- 货币自定义监控（Modules/InfoBar/Currency.lua）：这里只放"模式 / 上限 / 0 值"
        -- 三档静态设置。逐项勾选的清单会随角色面板「货币」子标签变化，配置面板只在
        -- 第一次打开时构建一次，不适合放动态列表 —— 那份放在货币格的右键面板里。
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

            -- §8.84：追踪项一多，「名称 + 完整数量」会被标题行折成 +N。
            -- 图标模式改画「图标 + 短数量」，名称与完整值移到悬停提示。
            MakeCheckbox(content, "背包标题行：货币用图标（省位置，名称悬停可见）", row(T.rowH),
                function() return ns:DB().bags.currencyIcons ~= false end,
                function(value)
                    ns:DB().bags.currencyIcons = value and true or false
                    local bags = ns:GetModule("Bags")
                    if bags and bags.RefreshCurrencyTitles then bags:RefreshCurrencyTitles() end
                end)

            -- 自建框 + Theme + 织纹底：面板里每一颗按钮（含底部「重载界面」）都是这一套。
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

            Hint(content, row, "默认只追踪金币（背包标题行与提示框都会显示）。背包标题行默认用图标 + 短数量，悬停看名称与完整数值；关掉上面的勾选可换回纯文字。其它货币不自动带入：右键信息栏的货币格勾选，或 /mui infobar currency add <ID|名称> 添加；list 查 ID。清单来自角色面板 → 货币 子标签，折叠的分类请先在面板里展开。")
        end

        -- One switch per block, in registration order.
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

    -- 面板高固定（T.panelH）：title 和主菜单钉在顶上不随内容上下跳，正文在里面滚；
    -- 提示行和「重载界面」按钮固定在最下面那条带子里。每页建完就地结算正文高（sec.bodyHeight）。

    -- Scroll: the wheel moves the content, the thumb shows where we are and can be dragged.
    -- 约定（2026-11 校正）：scrollOffset = "从顶部往上顶了多少像素"，非负，0 = 在顶部。
    -- 暴雪的 y 轴朝上，所以内容要向上滚就是把 root 的 TOP 挂成 +scrollOffset；
    -- 原来这里存的是负数、又直接当偏移用，滚一下内容反而往下跑（旧版所有分组默认收起、
    -- 一屏放得下，所以没暴露）。滑块同理：轨道往下 = 列表往下 = offset 变大。
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
        -- 0 = 列表顶（滑块在轨道顶端），1 = 列表底。
        local t = scrollOffset / maxOffset
        scrollThumb:ClearAllPoints()
        scrollThumb:SetPoint("TOPLEFT", scrollTrack, "TOPLEFT", 0, -t * (viewH - thumbH))
    end

    local function SetOffset(value)
        scrollOffset = math.max(0, math.min(MaxOffset(), value))
        -- 两个角一起挪：只改 TOPLEFT 时，创建时钉在 view 顶边的 TOPRIGHT 会跟它打架，
        -- 内容会被拉变（宽高固定时表现为位置忽上忽下）。
        root:ClearAllPoints()
        root:SetPoint("TOPLEFT", view, "TOPLEFT", 0, scrollOffset)
        root:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, scrollOffset)
        UpdateThumb()
    end
    setOffset = SetOffset

    -- ---- ② 主菜单：按"实际建出来了几页"排按钮 ------------------------------------------
    -- 行数 = ceil(页数 / 每行上限)，再把每行几个均分回去：模块没加载就少一页，剩下的页签照样
    -- 排成方整的网格（15 页 → 5×3，12 页 → 4×3），不会出现末行孤零零一个、列宽还变来变去。
    local function BuildTabs()
        local n = #pages
        local rows = math.max(1, math.ceil(n / T.tabPerRow))
        local perRow = math.max(1, math.ceil(n / rows))
        local w = Media:SnapUnit((T.contentW - (perRow - 1) * T.tabGap) / perRow)

        for i, page in ipairs(pages) do
            local r = math.floor((i - 1) / perRow)
            local c = (i - 1) % perRow
            -- 名字带 MonetUI 前缀：Widget:ButtonMaterial 认这个名字才用 HookScript 跟尺寸，
            -- 否则每个页签都得挂一条 0.5 秒轮询（那是给读不到脚本槽的暴雪框体留的路子）。
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

            -- 选中线压在按钮底边：2px、highlight 档，和边框用的是同一档色，不另发明颜色。
            local mark = HLine(tab, { side = "bottom", inset = 2, h = 2, key = "highlight", alpha = 1 })
            mark:Hide()

            tab:SetScript("OnClick", function() SelectPage(i) end)
            -- 自建框体的脚本槽是自己的：直接 OnEnter / OnLeave，不去占 HoverWatch 的轮询名额。
            tab:SetScript("OnEnter", function() Widget:SetHoverLift(tab, true) end)
            tab:SetScript("OnLeave", function() Widget:SetHoverLift(tab, false) end)

            tabButtons[#tabButtons + 1] = { frame = tab, text = fs, mark = mark }
        end

        local barH = rows * T.tabH + (rows - 1) * T.tabGap
        Widget:Height(tabBar, barH)
        -- 主菜单与正文的分界：和标题行底下那条同一个画法、同一个 alpha。
        HLine(panel, { y = -(T.titleH + barH + T.tabGap + 1), inset = 14, alpha = 0.45 })
    end

    -- One handler for the whole panel: the wheel event bubbles up from the row widgets,
    -- and no intermediate frame handles it, so the content moves exactly one step.
    panel:SetScript("OnMouseWheel", function(_, delta)
        -- 本客户端的滚轮符号是反的（实测：往下滚 delta = +1），而偏移量存的是"往上顶了多少"，
        -- 两者相合就是加号：往下滚 → 偏移变大 → 内容往上走，看到后面的行。
        SetOffset(scrollOffset + delta * 48)
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
        -- GetCursorPosition 的 y 朝上：手往下拖 = my 变小 = 偏移要变大，所以是减号。
        SetOffset(dragStartOffset - (my - dragStartY) * Media:Mult())
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

    BuildTabs()
    SelectPage(1)

    -- ---- ④ 底部带：分界线 + 命令提示（左）+ 重载按钮（右）--------------------------------
    HLine(panel, { side = "bottom", y = T.bottomH - 8, inset = 14, alpha = 0.45 })

    local hint = Widget:Font(panel, 12, "pixel", "neutral", "LEFT")
    hint:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", T.padX, 36)
    hint:SetWidth(T.contentW)
    hint:SetJustifyH("LEFT")
    hint:SetText("提示：/mui status 查看模块状态，/mui reset 恢复默认设置。")

    -- 和下拉按钮同一套（自建框 + Theme + 织纹底），不再用 UIPanelButtonTemplate：
    -- 暴雪那颗按钮的边框和底色不归主题登记套管，面板里就只有它是另一种画风。
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
