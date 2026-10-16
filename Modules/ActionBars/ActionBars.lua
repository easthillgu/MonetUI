-- Modules/ActionBars/ActionBars.lua
-- MonetUI 的动作条：1 到 8 号动作条，外加接管的宠物条 / 姿态条。
--
-- 主流做法（Bartender4、Dominos、ElvUI、Andromeda 都是这样）：不去驱动暴雪自带的
-- 按钮，而是把默认动作条藏起来，自己在客户端的**安全模板**上新建按钮。
-- 暴雪的按钮绑死在编辑模式、固定几何和它自己的翻页逻辑上，外面一动就会被改回去；
-- 安全模板的按钮则由客户端自己施法，战斗中不失效，也不会被污染。
--
-- 按钮本身来自 LibActionButton-1.0（随包放在 Libs/，BSD-3，见 Libs/NOTICE.md），
-- 和 Bartender4 / ElvUI / Andromeda 用的是同一个库：
--
--   * 每个按钮都是真正的 SecureActionButtonTemplate 按钮，施法由客户端完成；
--   * 每条动作条有一个 SecureHandlerStateTemplate 头（header），翻页（载具 /
--     覆盖 / 变形 / 额外动作条）在客户端内部只换几个属性，Lua 完全不用插手；
--   * MonetUI 只负责外观（图标裁切、1 像素描边、字体）和摆放位置。
--
-- 暴雪默认动作条的按钮不会被删掉，只是被移到隐藏框体里：它们的按键绑定仍然有效，
-- 所以就算自绘动作条出问题，玩家也不会一下子失去所有技能。

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local Color    = ns.Color
local Media    = ns.Media
local EventBus = ns.EventBus

local M = { name = "ActionBars" }

-- -- Client surface -----------------------------------------------------------
-- Everything the module touches that this build could be missing is looked up
-- once and used through a pcall wrapper, so a missing global degrades instead
-- of breaking the addon.

local LibStub = _G.LibStub
local LAB     = LibStub and LibStub("LibActionButton-1.0-MonetUI", true)

local InCombatLockdown        = _G.InCombatLockdown
local RegisterStateDriver     = _G.RegisterStateDriver
local UnregisterStateDriver   = _G.UnregisterStateDriver
local SetOverrideBindingClick = _G.SetOverrideBindingClick
local ClearOverrideBindings   = _G.ClearOverrideBindings
local GetBindingKey           = _G.GetBindingKey
local GetBindingByKey         = _G.C_KeyBindings and _G.C_KeyBindings.GetBindingByKey
local CanExitVehicle          = _G.CanExitVehicle
local VehicleExit             = _G.VehicleExit
local TaxiRequestEarlyLanding = _G.TaxiRequestEarlyLanding
local UnitOnTaxi              = _G.UnitOnTaxi
local RANGE_INDICATOR         = _G.RANGE_INDICATOR

--- True while the client refuses protected work.
local function Locked()
    return (InCombatLockdown and InCombatLockdown()) and true or false
end

--- pcall wrapper.  Action-bar queries can refuse an empty slot and can hand back
-- secret values; neither may ever take the module (or the frame) down.
local function Call(fn, ...)
    if not fn then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c
end

-- -- Geometry and settings ----------------------------------------------------

local BORDER      = 1     -- 1px Monet edge, used as the icon inset everywhere
local CROP        = 0.08  -- icon crop that hides Blizzard's own icon border
local HOTKEY_SIZE = 10
local COUNT_SIZE  = 11
local MACRO_SIZE  = 10

local DEFAULT_SIZE    = 28
local DEFAULT_SPACING = 2
local DEFAULT_BARS    = 5

local BUTTONS_PER_BAR = 12
local BAR_PAGES       = 18   -- pages the paging bar can be switched to

--- 每个按钮都有 0..18 号状态；状态 0 是"没有翻页驱动"时的兜底。
-- 客户端把第 n 页映射到 (n-1)*12+1 .. (n-1)*12+12 号技能槽，和暴雪自己的编号一致。
local function PageSlot(page, index)
    return (page - 1) * BUTTONS_PER_BAR + index
end

local function Config()
    return ns:DB().actionBars or {}
end

local function ButtonSize()
    local size = tonumber(Config().buttonSize)
    return size and size >= 12 and size or DEFAULT_SIZE
end

local function Spacing()
    local spacing = tonumber(Config().spacing)
    return spacing and spacing >= 0 and spacing or DEFAULT_SPACING
end

local function BarCount()
    local count = tonumber(Config().barCount)
    return count and count >= 1 and count or DEFAULT_BARS
end

--- 玩家自己的"按下即施法"偏好；按钮交给客户端时要用同一个值。
local KEY_DOWN
local function ClickOnDown()
    if KEY_DOWN == nil then
        local get = (_G.C_CVar and _G.C_CVar.GetCVarBool) or _G.GetCVarBool
        local ok, value = pcall(get, "ActionButtonUseKeyDown")
        KEY_DOWN = (ok and value) and true or false
    end
    return KEY_DOWN
end

--- 某个暴雪绑定名绑着的键，没有就返回 nil。
-- GetBindingKey 是经典全局函数；这个 build 上如果它没了，就用命名空间版本兜底
-- （后者要的是键、返回的是绑定名，所以结果要做一次排错）。
local function BindingFor(action)
    if not action then return nil end

    if GetBindingKey then
        local key = Call(GetBindingKey, action)
        if type(key) == "string" and key ~= "" then return key end
    end

    if GetBindingByKey then
        local key = Call(GetBindingByKey, action)
        if type(key) == "string" and key ~= ""
            and key ~= action and not key:find("ACTIONBUTTON") then
            return key
        end
    end

    return nil
end

-- -- Bar definitions ----------------------------------------------------------
-- `page` 是这条动作条显示的那一页（状态 0 的兜底值）；`bind` 是暴雪原本给这排
-- 按钮的绑定名前缀，玩家已有的按键设置因此原样生效。
--
-- 位置存在存档里（见 Core.lua），表里给的只是第一次运行的锚点。

local BAR_DEFS = {
    { key = "Bar1", index = 1, page = 1,  paged = true,  bind = "ACTIONBUTTON",
      blizzard = "MainMenuBar",
      point = "BOTTOM", relativeTo = "UIParent", relativePoint = "BOTTOM", x = 0,   y = 24 },
    { key = "Bar2", index = 2, page = 6,  bind = "MULTIACTIONBAR1BUTTON",
      blizzard = "MultiBarBottomLeft",
      point = "BOTTOM", relativeTo = "Bar1",     relativePoint = "TOP",    x = 0,   y = 2 },
    { key = "Bar3", index = 3, page = 5,  bind = "MULTIACTIONBAR2BUTTON",
      blizzard = "MultiBarBottomRight",
      point = "BOTTOM", relativeTo = "Bar2",     relativePoint = "TOP",    x = 0,   y = 2 },
    { key = "Bar4", index = 4, page = 3,  bind = "MULTIACTIONBAR3BUTTON",
      blizzard = "MultiBarRight",
      point = "BOTTOM", relativeTo = "Bar3",     relativePoint = "TOP",    x = 0,   y = 2 },
    { key = "Bar5", index = 5, page = 4,  bind = "MULTIACTIONBAR4BUTTON",
      blizzard = "MultiBarLeft",
      point = "BOTTOM", relativeTo = "Bar4",     relativePoint = "TOP",    x = 0,   y = 2 },
    { key = "Bar6", index = 6, page = 13, bind = "MULTIACTIONBAR5BUTTON",
      blizzard = "MultiBar5",
      point = "BOTTOM", relativeTo = "Bar5",     relativePoint = "TOP",    x = 0,   y = 2 },
    { key = "Bar7", index = 7, page = 14, bind = "MULTIACTIONBAR6BUTTON",
      blizzard = "MultiBar6",
      point = "BOTTOM", relativeTo = "Bar6",     relativePoint = "TOP",    x = 0,   y = 2 },
    { key = "Bar8", index = 8, page = 15, bind = "MULTIACTIONBAR7BUTTON",
      blizzard = "MultiBar7",
      point = "BOTTOM", relativeTo = "Bar7",     relativePoint = "TOP",    x = 0,   y = 2 },
}

-- 我们自己接管的那几条暴雪动作条：不重画，只搬家、缩放和裁图标。
--
-- 搬的是**最外层**那个框体（`containers` 里第一个存在的）：暴雪显隐宠物的做法
-- 可能是 Hide 外层容器、也可能是 Hide 里面的条，搬外层两种情况都还归它管。
-- 只搬内层的话，暴雪一 Hide 外层，我们的条就留在屏幕上了。
--
-- 位置：都在 3 号条上方那一行，宠物条右对齐、姿态条左对齐（两条通常不会同时
-- 出现；死骑的食尸鬼 + 灵气是例外，那时它们会重叠，改 positions 错开即可）。
local ADOPTED_DEFS = {
    { key = "BarPet",    containers = { "PetActionBarFrame", "PetActionBar" },
      pattern = "PetActionButton%d", count = 10, label = "宠物",
      point = "BOTTOMRIGHT", relativeTo = "Bar3", relativePoint = "TOPRIGHT", x = 0, y = 2 },
    { key = "BarStance", containers = { "StanceBarFrame", "StanceBar" },
      pattern = "StanceButton%d", count = 10, label = "姿态",
      point = "BOTTOMLEFT", relativeTo = "Bar3", relativePoint = "TOPLEFT", x = 0, y = 2 },
}

-- 暴雪自己的动作条，顺序和它们的按钮绑定一致：1 号条的按键是 ACTIONBUTTON<i>，
-- 2 号条是 MULTIACTIONBAR1BUTTON<i>，以此类推。
local ACTION_BAR_FRAMES = {
    "MainMenuBar", "MultiBarBottomLeft", "MultiBarBottomRight",
    "MultiBarLeft", "MultiBarRight", "MultiBar5", "MultiBar6", "MultiBar7",
    "OverrideActionBar", "PossessActionBar",
}

-- 右下角的背包条 / 背包按钮。
local BAG_BAR_FRAMES = {
    "BagsBar", "MainMenuBarBackpackButton",
}

-- -- Secure paging ------------------------------------------------------------
-- 1 号条会自己翻页（载具、覆盖、变形、额外动作条都用它），所以它挂一个状态驱动。
-- 驱动换页时这条片段在客户端内部跑：`newstate` 就是新页号，`self` 是头框体，
-- 按钮是它的"孩子"，ChildUpdate 会把新页号交给每个按钮的 secure 片段。

local ON_STATE_PAGE = [[
    self:SetAttribute("state", newstate)
    control:ChildUpdate("state", newstate)
]]

-- 1 号条：宠物对战时暴雪会换成宠物技能，这里跟着藏。
local VISIBILITY_MAIN = "[petbattle] hide; show"

-- 其余几条条：载具 / 覆盖 / 附身 / 变形时让位给 1 号条。
local VISIBILITY_OTHER =
    "[petbattle][overridebar][vehicleui][possessbar][shapeshift] hide; show"

local FULL_PAGE = "[bar:6]6;[bar:5]5;[bar:4]4;[bar:3]3;[bar:2]2;[possessbar]16;" ..
                  "[overridebar]18;[shapeshift]17;[vehicleui]16;[bonusbar:5]11;" ..
                  "[bonusbar:4]10;[bonusbar:3]9;[bonusbar:2]8;[bonusbar:1]7;1"

-- 载具 / 飞行点的"提前下马"按钮。片段跑在客户端内部，只有能下车（或正坐在
-- 飞行路线上）时才把框体放出来；UnitOnTaxi 万一不在受限环境里，前半句仍然可用。
local EXIT_SNIPPET = [[
    if CanExitVehicle() or (UnitOnTaxi and UnitOnTaxi("player")) then
        self:Show()
    else
        self:Hide()
    end
]]

-- 留出降落伞：模板缺失时用来创建框体 / 退回暴雪动作条。
local CONTAINER_TEMPLATES = {
    "SecureHandlerStateTemplate, BackdropTemplate",
    "SecureHandlerStateTemplate",
    "BackdropTemplate",
    "Frame",
}

-- -- State --------------------------------------------------------------------

local bars    = {}   -- key -> { def, frame, buttons }
local adopted = {}   -- key -> { def, frame }
local built   = false
local applied = false
local bindingsDirty = false
local adoptedDirty  = false
local refreshDirty  = false
local announced     = false
local announcedFailure = false
local buildFailure  -- "lab" | "header" | "button" | "template"
local leaveVehicle

local FAILURE_TEXT = {
    lab      = "没找到 LibActionButton-1.0，已保留暴雪默认动作条。",
    header   = "此客户端没有安全头框体模板，已保留暴雪默认动作条。",
    button   = "此客户端没有安全按钮模板，已保留暴雪默认动作条。",
    template = "自绘动作条创建失败，已保留暴雪默认动作条。",
}

-- -- Blizzard chrome: park / restore -------------------------------------------
-- 把暴雪的框体塞进一个永远隐藏的框里，而不是销毁它：它的按键仍然能按、事件
-- 仍然能收，只是玩家看不见。任何情况下都能原样放回去。

local hidden

local function NewFrame(kind, name, parent, templates)
    for _, template in ipairs(templates) do
        local ok, frame = pcall(CreateFrame, kind, name, parent, template)
        if ok and frame then return frame, template end
    end
    return nil
end

local function HiddenFrame()
    if not hidden then
        hidden = NewFrame("Frame", "MonetUIHiddenFrame", UIParent, { "Frame" })
        if hidden then hidden:Hide() end
    end
    return hidden
end

local function Park(name, parent)
    local frame = _G[name]
    if not frame or frame.__monetParked then return false end
    if not pcall(frame.SetParent, frame, parent) then return false end
    frame.__monetParked = true
    return true
end

local function Restore(name)
    local frame = _G[name]
    if not frame or not frame.__monetParked then return false end
    frame.__monetParked = nil
    pcall(frame.SetParent, frame, UIParent)
    pcall(frame.Show, frame)
    return true
end

-- -- Position bookkeeping -----------------------------------------------------

local function ResolveRelative(name)
    if not name or name == "UIParent" then return UIParent end
    local entry = adopted[name]
    if entry and entry.frame then return entry.frame end
    local bar = bars[name]
    if bar then return bar.frame end
    return UIParent
end

local function StoredPosition(def, key)
    local positions = Config().positions
    return (positions and positions[key]) or def
end

local function Anchor(frame, stored, def)
    local point = stored.point or def.point or "CENTER"
    pcall(frame.ClearAllPoints, frame)
    pcall(frame.SetPoint, frame, point,
        ResolveRelative(stored.relativeTo or def.relativeTo),
        stored.relativePoint or def.relativePoint or point,
        stored.x or def.x or 0, stored.y or def.y or 0)
end

-- -- The MonetUI button look ---------------------------------------------------
-- 库里把暴雪 ActionButtonTemplate 的一堆部件都留着（冷却、堆叠、宏名、射程、
-- 闪光、自动施法圈……）。这里把它们收敛成 MonetUI 的样子：图标内缩 1 像素，
-- 露出来的那圈就是描边；多余的美术全部关掉。

local RINGS = setmetatable({}, { __mode = "k" })

--- 描边颜色：装着装备的槽位用高亮色（和暴雪一样表达"这件装备在身"），
-- 其余用当前边框色（配置项「边框颜色」，见 Color:GetBorder）。
-- 库里用 Border 的显隐表示"已装备"，这里跟着它走。
--
-- 每个按钮两块底色：
--   ring 铺满整个按钮，只在图标外圈露出 1 像素，那就是描边；
--   well 只铺图标范围，空槽时它就是"空格子"的底色（有图标时被图标完全盖住）。
local function RefreshRing(button)
    local parts = RINGS[button]
    if not parts then return end

    local r, g, b
    if button.Border and button.Border:IsShown() then
        r, g, b = Color:GetHealth()
    else
        r, g, b = Color:GetBorder()
    end
    parts.ring:SetColorTexture(r, g, b, 0.9)

    local nr, ng, nb = Color:GetNeutral()
    parts.well:SetColorTexture(nr, ng, nb, 0.45)
end

local function RefreshRings()
    for button in pairs(RINGS) do
        RefreshRing(button)
    end
end

--- 堆叠数量库里只有写字、没有开关（它只对 FontString SetText，不控制显隐），
-- 所以显隐归我们管，而且随时可以改回来。
local function ApplyCountVisibility(button)
    local count = button and button.Count
    if not count then return end
    if Config().showCount == false then
        count:Hide()
    else
        count:Show()
    end
end

--- 快捷键太长会顶出按钮（SHIFT-1、MOUSEWHEELUP…），缩成 s1 / MU 这类写法。
-- 库用 SetText 更新快捷键，这里挂在 SetText 之后，用 SetFormattedText 回写，
-- 所以不会自己套自己；射程指示点（RANGE_INDICATOR）原样留给孩子。
local function ShortenHotkey(fs)
    local ok, text = pcall(fs.GetText, fs)
    if not ok or type(text) ~= "string" or text == "" then return end
    if RANGE_INDICATOR and text == RANGE_INDICATOR then return end

    local short = text
    short = short:gsub("MOUSEWHEELUP", "MU")
    short = short:gsub("MOUSEWHEELDOWN", "MD")
    short = short:gsub("SHIFT%-", "s")
    short = short:gsub("CTRL%-", "c")
    short = short:gsub("ALT%-", "a")
    short = short:gsub("META%-", "m")
    short = short:gsub("BUTTON", "M")
    short = short:gsub("NUMPAD", "N")
    short = short:gsub("SPACE", "Sp")
    short = short:gsub("CAPSLOCK", "CL")

    if short ~= text then
        pcall(fs.SetFormattedText, fs, "|cffffffff%s|r", short)
    end
end

local function SkinButton(button)
    if button.__monetSkinned then return end
    button.__monetSkinned = true

    local icon = button.icon

    -- 图标往后缩 1 像素，露出来的底色就是描边；空槽时 well 顶上（见 RefreshRing）。
    local ring = button:CreateTexture(nil, "BACKGROUND", nil, 0)
    ring:SetAllPoints(button)

    local well = button:CreateTexture(nil, "BACKGROUND", nil, 1)
    well:SetPoint("TOPLEFT", button, "TOPLEFT", BORDER, -BORDER)
    well:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -BORDER, BORDER)

    RINGS[button] = { ring = ring, well = well }

    if icon then
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", button, "TOPLEFT", BORDER, -BORDER)
        icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -BORDER, BORDER)
        icon:SetTexCoord(CROP, 1 - CROP, CROP, 1 - CROP)
    end

    -- 暴雪的原生美术：空槽的方框、装备绿光、闪光、新技能提示，统统不要。
    if button.NormalTexture then button.NormalTexture:SetAlpha(0) end
    if button.SlotBackground then button.SlotBackground:SetAlpha(0) end
    if button.Flash then button.Flash:SetAlpha(0) end
    if button.NewActionTexture then button.NewActionTexture:SetAlpha(0) end
    if button.IconMask then pcall(button.IconMask.Hide, button.IconMask) end

    -- Border 这块贴图本身不画（暴雪的"已装备"边框），但它的显隐就是库表达
    -- "这件装备在身"的地方，所以留给描边用。
    if button.Border then
        pcall(button.Border.SetTexture, button.Border, nil)
        RefreshRing(button)
        hooksecurefunc(button.Border, "Show", function() RefreshRing(button) end)
        hooksecurefunc(button.Border, "Hide", function() RefreshRing(button) end)
    end

    local anchor = icon or button

    local cooldown = button.cooldown
    if cooldown then
        cooldown:ClearAllPoints()
        cooldown:SetAllPoints(anchor)
        Widget:StyleCooldownText(cooldown, COUNT_SIZE, "cooldown")
    end

    local pushed = button.PushedTexture
    if pushed then
        pushed:ClearAllPoints()
        pushed:SetAllPoints(anchor)
        pushed:SetColorTexture(0, 0, 0, 0.45)
    end

    -- "当前动作"（比如战士的当前姿态技能）用高亮色，而不是暴雪的对勾。
    local checked = button.CheckedTexture
    if checked then
        checked:ClearAllPoints()
        checked:SetAllPoints(anchor)
        local r, g, b = Color:GetHighlight()
        checked:SetColorTexture(r, g, b, 0.3)
    end

    local highlight = button.HighlightTexture
    if highlight then
        highlight:ClearAllPoints()
        highlight:SetAllPoints(anchor)
        highlight:SetColorTexture(1, 1, 1, 0.15)
    end

    if button.SpellHighlightTexture then
        pcall(button.SpellHighlightTexture.SetAllPoints, button.SpellHighlightTexture, button)
    end

    if button.HotKey then
        button.HotKey:SetWordWrap(false)
        hooksecurefunc(button.HotKey, "SetText", ShortenHotkey)
    end

    -- 堆叠数量库里没有开关，自己关（见 ApplyCountVisibility）。
    ApplyCountVisibility(button)
end

--- 库认得的那部分配置：字体、位置、颜色、点击时机。
local function ButtonConfig()
    local db = Config()
    local er, eg, eb = Color:GetEdge()

    return {
        outOfRangeColoring = "button",
        tooltip            = "enabled",
        clickOnDown        = ClickOnDown(),
        flyoutDirection    = "UP",
        hideElements = {
            hotkey        = db.showHotkey == false,
            macro         = db.showMacro == false,
            equipped      = false,  -- 已装备的提示留给描边（见 SkinButton）
            border        = true,   -- 暴雪的图标外框，永远不画
            borderIfEmpty = true,
        },
        text = {
            hotkey = {
                font     = { font = Media:Font("pixel"), size = HOTKEY_SIZE, flags = "" },
                position = { anchor = "TOPLEFT", relAnchor = "TOPLEFT", offsetX = 2, offsetY = -1 },
                justifyH = "LEFT",
                color    = { 1, 1, 1 },
            },
            count = {
                font     = { font = Media:Font("pixel"), size = COUNT_SIZE, flags = "" },
                position = { anchor = "BOTTOMRIGHT", relAnchor = "BOTTOMRIGHT", offsetX = -2, offsetY = 1 },
                justifyH = "RIGHT",
                color    = { 1, 1, 1 },
            },
            macro = {
                font     = { font = Media:Font("pixel"), size = MACRO_SIZE, flags = "" },
                position = { anchor = "BOTTOM", relAnchor = "BOTTOM", offsetX = 0, offsetY = 1 },
                justifyH = "CENTER",
                color    = { er, eg, eb },
            },
        },
    }
end

-- -- Buttons ------------------------------------------------------------------

local function CreateButton(bar, index)
    local def  = bar.def
    local name = "MonetUI" .. def.key .. "Button" .. index

    local ok, button = pcall(LAB.CreateButton, LAB, index, name, bar.frame)
    if not ok or not button then return nil end

    button.bindName = def.bind .. index
    button.bar      = bar

    -- 状态 0 是兜底：翻页驱动万一没装上，1 号条就停在第一页，其余条本来就固定。
    -- 1..18 号状态是驱动换页时客户端要查的表。
    for state = 0, BAR_PAGES do
        local slot
        if def.paged then
            slot = (state == 0) and index or PageSlot(state, index)
        else
            slot = PageSlot(def.page, index)
        end
        button:SetState(state, "action", slot)
    end

    Widget:SetFont(button.HotKey, HOTKEY_SIZE, "pixel")
    Widget:SetFont(button.Count, COUNT_SIZE, "pixel")
    Widget:SetFont(button.Name, MACRO_SIZE, "pixel")

    SkinButton(button)
    -- 只在这里刷一次：CreateButton 内部那次更新跑在钩子装上之前。
    pcall(button.UpdateConfig, button, ButtonConfig())

    return button
end

-- -- Bars ---------------------------------------------------------------------

local function LayoutBar(bar)
    if Locked() then return end

    local size    = ButtonSize()
    local spacing = Spacing()
    local perRow  = bar.def.perRow or BUTTONS_PER_BAR
    local count   = #bar.buttons
    if count == 0 then return end

    local columns = math.min(count, perRow)
    local rows    = math.ceil(count / perRow)

    for index, button in ipairs(bar.buttons) do
        local column = (index - 1) % perRow
        local row    = math.floor((index - 1) / perRow)
        button:ClearAllPoints()
        button:SetSize(size, size)
        button:SetPoint("TOPLEFT", bar.frame, "TOPLEFT",
            column * (size + spacing), -row * (size + spacing))
    end

    bar.frame:SetSize(
        columns * size + math.max(columns - 1, 0) * spacing,
        rows * size + math.max(rows - 1, 0) * spacing)
end

local function PositionBar(bar)
    Anchor(bar.frame, StoredPosition(bar.def, bar.def.key), bar.def)
end

local function CreateBar(def)
    if buildFailure then return nil end

    local frame, template = NewFrame("Frame", "MonetUI" .. def.key, UIParent, CONTAINER_TEMPLATES)
    if not frame then
        buildFailure = buildFailure or "header"
        return nil
    end
    if not template:find("SecureHandlerStateTemplate") then
        buildFailure = buildFailure or "header"
        return nil
    end

    pcall(frame.SetAttribute, frame, "_onstate-page", ON_STATE_PAGE)

    local bar = {
        def        = def,
        index      = def.index,
        frame      = frame,
        buttons    = {},
        visibility = def.paged and VISIBILITY_MAIN or VISIBILITY_OTHER,
    }

    for index = 1, BUTTONS_PER_BAR do
        local button = CreateButton(bar, index)
        if not button then break end
        bar.buttons[#bar.buttons + 1] = button
    end

    if #bar.buttons == 0 then
        pcall(frame.Hide, frame)
        buildFailure = buildFailure or "button"
        return nil
    end

    -- 翻页驱动：1 号条按客户端状态换页，其余条固定在自己那一页。
    if RegisterStateDriver then
        pcall(RegisterStateDriver, frame, "page", def.paged and FULL_PAGE or tostring(def.page))
    end

    LayoutBar(bar)
    PositionBar(bar)
    return bar
end

local function SetBarShown(bar, shown)
    if shown then
        if RegisterStateDriver then
            pcall(RegisterStateDriver, bar.frame, "visibility", bar.visibility)
        end
        pcall(bar.frame.Show, bar.frame)
    else
        if UnregisterStateDriver then
            pcall(UnregisterStateDriver, bar.frame, "visibility")
        end
        pcall(bar.frame.Hide, bar.frame)
    end
end

-- -- The leave-vehicle button --------------------------------------------------
-- 暴雪的下车按钮长在主菜单条上，而那条已经被我们藏起来了，所以自己做一个。
-- 点击脚本参考同类插件：飞行途中请求提前落地，坐骑 / 载具里则直接下车。

local function CreateLeaveVehicle()
    if leaveVehicle then return leaveVehicle end
    if not CanExitVehicle or not RegisterStateDriver then return nil end

    local frame, template = NewFrame("Frame", "MonetUIActionBarExit", UIParent, CONTAINER_TEMPLATES)
    if not frame then return nil end
    if not template:find("SecureHandlerStateTemplate") then
        pcall(frame.Hide, frame)
        return nil
    end

    local size = ButtonSize()
    frame:SetSize(size + 2 * BORDER, size + 2 * BORDER)
    Widget:Theme(frame, { thickness = BORDER, bgAlpha = 0.55 })

    -- pcall returns (ok, result): capturing only one value would leave `button`
    -- as a boolean, and button:SetPoint below would then index a boolean.
    local okButton, button = pcall(CreateFrame, "CheckButton", "MonetUILeaveVehicleButton", frame,
        "SecureHandlerClickTemplate")
    if not okButton or not button then
        pcall(frame.Hide, frame)
        return nil
    end
    button:SetPoint("TOPLEFT", frame, "TOPLEFT", BORDER, -BORDER)
    button:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -BORDER, BORDER)
    button:RegisterForClicks("AnyUp")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(button)
    icon:SetTexture("Interface\\Vehicles\\UI-Vehicles-Button-Exit-Up")
    icon:SetTexCoord(CROP, 1 - CROP, CROP, 1 - CROP)

    button:SetScript("OnClick", function(self)
        if UnitOnTaxi and UnitOnTaxi("player") then
            if TaxiRequestEarlyLanding then pcall(TaxiRequestEarlyLanding) end
        elseif CanExitVehicle() and VehicleExit then
            pcall(VehicleExit)
        end
        self:SetChecked(false)
    end)

    button:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_RIGHT")
        tip:SetText(_G.LEAVE_VEHICLE or "离开载具")
        tip:Show()
    end)
    button:SetScript("OnLeave", function()
        local tip = _G.GameTooltip
        if tip then tip:Hide() end
    end)

    -- 能不能下车由客户端判定；这里只负责显隐。
    pcall(frame.SetAttribute, frame, "_onstate-exit", EXIT_SNIPPET)
    pcall(RegisterStateDriver, frame, "exit", "[canexitvehicle]c;[mounted]m;n")
    if not CanExitVehicle() then frame:Hide() end

    Anchor(frame, StoredPosition({ point = "CENTER", relativeTo = "UIParent",
        relativePoint = "CENTER", x = 0, y = -300 }, "BarExit"),
        { point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", x = 0, y = -300 })

    leaveVehicle = { frame = frame, button = button, icon = icon }
    return leaveVehicle
end

-- -- Adopting Blizzard's pet / stance bars --------------------------------------
-- 这两条条不重画：只把暴雪的动作条从被藏起来的父框体里搬出来、缩放到和自绘
-- 按钮一样大、放到存档里的位置。图标更新、自动施法光圈、当前形态环、冷却全
-- 都还是暴雪自己的代码在管，所以永远不会失同步。

--- 取 def.containers 里第一个真正存在的框体（优先最外层）。
local function ResolveContainer(def)
    for _, name in ipairs(def.containers) do
        local frame = _G[name]
        if frame then return frame, name end
    end
    return nil
end

local function AdoptBar(def)
    local bar, name = ResolveContainer(def)
    if not bar then return nil end

    local entry = adopted[def.key]
    if not entry then
        entry = {}
        adopted[def.key] = entry
    end

    -- 换过容器（比如暴雪这次才把外层建出来）就把缩放的基准丢掉重算。
    if entry.frame ~= bar then
        if entry.frame then pcall(entry.frame.SetScale, entry.frame, 1) end
        entry.base = nil
    end
    entry.def  = def
    entry.frame = bar
    entry.name  = name

    -- 1. 从被藏起来的父框体里搬出来
    if bar:GetParent() ~= UIParent then
        pcall(bar.SetParent, bar, UIParent)
    end

    -- 2. 缩放到自绘按钮的尺寸；暴雪条内部的排布原样不动。
    --    基准宽度只量一次（量的时候缩放还是 1），免得每次都乘一遍自己设的缩放。
    local first = _G[def.pattern:format(1)]
    if not entry.base and first then
        local base = first:GetWidth()
        if base and base > 8 then entry.base = base end
    end
    local size  = ButtonSize()
    local scale = entry.base and (size / entry.base) or 1
    pcall(bar.SetScale, bar, scale)

    -- 3. 摆到设置里的位置
    Anchor(bar, StoredPosition(def, def.key), def)

    -- 4. 图标裁切和字体
    for index = 1, def.count do
        local button = _G[def.pattern:format(index)]
        if not button then break end
        local icon = button.icon
        if icon then pcall(icon.SetTexCoord, icon, CROP, 1 - CROP, CROP, 1 - CROP) end
        Widget:SetFont(button.HotKey, HOTKEY_SIZE, "pixel")
        Widget:SetFont(button.Count, COUNT_SIZE, "pixel")
    end

    return entry
end

local function AdoptAll()
    if not M.own then return end
    if Locked() then
        adoptedDirty = true
        return
    end
    adoptedDirty = false
    for _, def in ipairs(ADOPTED_DEFS) do
        AdoptBar(def)
    end
end

--- 放开接管：交还给暴雪原来的大小。位置留给下一次暴雪的排版去纠正，
-- 因为插件不能替暴雪写它自己的布局。
local function ReleaseBar(entry)
    local bar = entry and entry.frame
    if not bar then return end
    pcall(bar.SetScale, bar, 1)
end

-- -- Keybinds ------------------------------------------------------------------
-- 暴雪那排按钮还在（只是藏起来了），所以玩家的按键其实按的是它们。这里把同一
-- 批按键改成"点击我们自己的按钮"的覆盖绑定：覆盖绑定优先，按下去触发的是玩家
-- 看得见的那一排，而且目标页跟着我们的按钮走。

local function ReassignBindings()
    if Locked() then
        bindingsDirty = true
        return
    end
    if not (SetOverrideBindingClick and ClearOverrideBindings) then return end
    bindingsDirty = false

    for _, bar in pairs(bars) do
        pcall(ClearOverrideBindings, bar.frame)
        for _, button in ipairs(bar.buttons) do
            local key = BindingFor(button.bindName)
            if key then
                pcall(SetOverrideBindingClick, bar.frame, false, key, button:GetName())
            end
        end
    end
end

local function ClearBindings()
    if Locked() then
        bindingsDirty = true
        return
    end
    if not ClearOverrideBindings then return end
    for _, bar in pairs(bars) do
        pcall(ClearOverrideBindings, bar.frame)
    end
end

-- -- Events -------------------------------------------------------------------

-- 这些事件之后暴雪可能重排 / 换过宠物条和姿态条，我们再把位置和缩放放回去。
-- 战斗中不能动受保护的框体，所以留到 PLAYER_REGEN_ENABLED。
local ADOPT_EVENTS = {
    "UNIT_PET", "UNIT_FLAGS", "PET_UI_UPDATE", "PET_BAR_UPDATE",
    "PET_BAR_UPDATE_USABLE", "PET_BAR_UPDATE_COOLDOWN",
    "UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS",
    "PLAYER_CONTROL_GAINED", "PLAYER_CONTROL_LOST", "PLAYER_TARGET_CHANGED",
    "UPDATE_VEHICLE_ACTIONBAR", "PLAYER_MOUNT_DISPLAY_CHANGED",
}

function M:RegisterEvents()
    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        M:Apply()
    end)

    EventBus:Register("PLAYER_REGEN_ENABLED", function()
        if bindingsDirty then ReassignBindings() end
        if adoptedDirty then AdoptAll() end
        if refreshDirty then
            refreshDirty = false
            M:UpdateAll()
        end
        if not applied then M:Apply() end
    end)

    EventBus:Register("UPDATE_BINDINGS", function()
        KEY_DOWN = nil
        ReassignBindings()
        M:UpdateAll()
    end)

    EventBus:Register("CVAR_UPDATE", function(_, name)
        if name == "ActionButtonUseKeyDown" then
            KEY_DOWN = nil
            M:UpdateAll()
        end
    end)

    for _, event in ipairs(ADOPT_EVENTS) do
        EventBus:Register(event, function() AdoptAll() end)
    end

    EventBus:Register("MONETUI_THEME_CHANGED", function() M:UpdateAll() end)
    EventBus:Register("MONETUI_RESTRICTION_CHANGED", function() M:UpdateAll() end)
end

-- -- Updates ------------------------------------------------------------------

--- 刷新所有按钮的外观配置。库自己管冷却、数量、可用性、射程，所以这里只在
-- 主题或设置变化时跑，不需要轮询。
function M:UpdateAll()
    if Locked() then
        refreshDirty = true
        return
    end

    local config = ButtonConfig()
    for _, bar in pairs(bars) do
        for _, button in ipairs(bar.buttons) do
            pcall(button.UpdateConfig, button, config)
            ApplyCountVisibility(button)
            Widget:StyleCooldownText(button.cooldown, COUNT_SIZE, "cooldown")
        end
    end

    RefreshRings()

    if leaveVehicle then
        local size = ButtonSize()
        leaveVehicle.frame:SetSize(size + 2 * BORDER, size + 2 * BORDER)
        Anchor(leaveVehicle.frame, StoredPosition({ point = "CENTER", relativeTo = "UIParent",
            relativePoint = "CENTER", x = 0, y = -300 }, "BarExit"),
            { point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", x = 0, y = -300 })
    end
end

--- 布局或尺寸改过之后重新摆一遍。
function M:RefreshLayout()
    if Locked() then return end
    for _, bar in pairs(bars) do
        LayoutBar(bar)
        PositionBar(bar)
    end
    AdoptAll()
    self:UpdateAll()
end

-- -- Build / apply -------------------------------------------------------------

function M:ParkBlizzard()
    local box = HiddenFrame()
    if not box then return end
    for _, name in ipairs(ACTION_BAR_FRAMES) do
        Park(name, box)
    end
    for _, name in ipairs(BAG_BAR_FRAMES) do
        Park(name, box)
    end
end

function M:RestoreBlizzard()
    for _, name in ipairs(ACTION_BAR_FRAMES) do
        Restore(name)
    end
    for _, name in ipairs(BAG_BAR_FRAMES) do
        Restore(name)
    end
end

local function ReportFailure()
    if announcedFailure then return end
    announcedFailure = true
    ns:Print(FAILURE_TEXT[buildFailure] or FAILURE_TEXT.template)
end

--- 建一次自己的动作条。返回 true 表示自绘动作条可用。
function M:Build()
    if built then return M.ready end
    built = true

    if not LAB then
        buildFailure = "lab"
        M.ready = false
        ReportFailure()
        return false
    end

    for _, def in ipairs(BAR_DEFS) do
        local bar = CreateBar(def)
        if bar then bars[def.key] = bar end
    end

    M.ready = next(bars) ~= nil
    if not M.ready then
        buildFailure = buildFailure or "template"
        ReportFailure()
        return false
    end

    leaveVehicle = CreateLeaveVehicle()
    return true
end

function M:Apply()
    if Locked() then
        applied = false
        return
    end

    self:Build()

    local db = Config()
    local own = db.ownBars ~= false and M.ready
    M.own = own

    local count = BarCount()
    for _, def in ipairs(BAR_DEFS) do
        local bar = bars[def.key]
        if bar then
            SetBarShown(bar, own and def.index <= count)
        end
    end

    if own then
        AdoptAll()
        if not leaveVehicle then leaveVehicle = CreateLeaveVehicle() end
    else
        for _, entry in pairs(adopted) do
            ReleaseBar(entry)
        end
        adoptedDirty = false
        if leaveVehicle then pcall(leaveVehicle.frame.Hide, leaveVehicle.frame) end
    end

    -- 暴雪的框体只在有东西替代它们（或者玩家就是想藏）时才被收起来。
    local park = own or (db.ownBars == false and db.hideBlizzard ~= false)
    if park then
        self:ParkBlizzard()
    else
        self:RestoreBlizzard()
    end

    -- 背包条我们从来不替代，所以它只看自己的开关。
    local box = HiddenFrame()
    if box and db.hideBagBar ~= false then
        Park("BagsBar", box)
        Park("MainMenuBarBackpackButton", box)
    end

    if own and not announced then
        announced = true
        ns:Print(("自绘动作条已就绪：%d 组 × %d 个，按钮 %dpx。"):format(
            count, BUTTONS_PER_BAR, ButtonSize()))
    elseif not own and buildFailure == nil and db.ownBars ~= false then
        if not announced then
            announced = true
            ns:Print("自绘动作条未启用，保留暴雪默认动作条。")
        end
    end

    ReassignBindings()
    self:UpdateAll()
    applied = true
end

-- -- Public -------------------------------------------------------------------

function M:SetEnabled(enabled)
    if enabled then
        self:Apply()
    else
        M.own = false
        for _, bar in pairs(bars) do
            pcall(bar.frame.Hide, bar.frame)
        end
        if leaveVehicle then pcall(leaveVehicle.frame.Hide, leaveVehicle.frame) end
        for _, entry in pairs(adopted) do
            ReleaseBar(entry)
        end
        adoptedDirty = false
        ClearBindings()
        self:RestoreBlizzard()
    end
end

function M:Initialize()
    self:Build()
    self:Apply()
    self:RegisterEvents()
end

ns:Register("ActionBars", M)
