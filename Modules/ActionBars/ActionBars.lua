-- Modules/ActionBars/ActionBars.lua
-- MonetUI 的动作条：1 到 8 号动作条，外加接管的宠物条 / 姿态条。
--
-- **不依赖任何动作条库**（LibActionButton 已从本文件与 .toc 里移除）。
-- 按钮全部自建，但**施法由客户端完成**，所以战斗中不会失效：
--
--   * 按钮 = CreateFrame("CheckButton", name, bar, "SecureActionButtonTemplate", index)
--     第 5 个参数是 id，客户端靠它算槽位：slot = id + (page - 1) * 12。
--   * 条 = SecureHandlerStateTemplate。_onstate-page 片段把状态页写进条自己的
--     "actionpage" 属性；按钮设 useparent-actionpage，客户端每次点击都重新算槽位，
--     于是翻页 / 载具 / 覆盖条 / 变形条全部由客户端决定，我们不碰任何安全逻辑。
--   * 图标 / 数量 / 宏名 / 热键 由我们自己读 C_ActionBar 的数据画；
--     冷却交给客户端（RegisterActionUIButton），所以永远不会和真实状态脱节。
--
-- 暴雪自己的条只是**藏起来**（Park），不搬动：零售 12.x 上搬动受保护的框体会变成
-- 强污染，暴雪的编辑模式再想挪一下就被拒（ADDON_ACTION_BLOCKED 一片刷屏）。
-- 藏起来不影响按键：ACTIONBUTTON1 这类绑定走的是 _G["ActionButton1"]，
-- 那是暴雪的按钮，玩家按下去照常施法；我们另外把同一批键覆盖到自己按钮上，
-- 于是"按下去看到的"和"按下去生效的"是同一个按钮。
--
-- 宠物条 / 姿态条不重画：它们是暴雪自己的按钮（图标更新、自动施法圈、冷却都由
-- 客户端在管），我们只搬位置、缩放、裁图标（见 ADOPTED_DEFS）。

local ADDON_NAME, ns = ...


-- 旁表标记（见 Core.lua 的 ns:Mark）：不往暴雪的框体上写字段，
-- 否则那个框体之后跑的暴雪代码会被判成“被 MonetUI 污染”。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
local Widget   = ns.Widget
local Color    = ns.Color
local Media    = ns.Media
local EventBus = ns.EventBus
local Secrets  = ns.Secrets
local Skin     = ns.Skin

local M = { name = "ActionBars" }


local ActionBar        = _G.C_ActionBar
local RegisterStateDriver   = _G.RegisterStateDriver
local UnregisterStateDriver = _G.UnregisterStateDriver
local SetOverrideBindingClick = _G.SetOverrideBindingClick
local ClearOverrideBindings   = _G.ClearOverrideBindings
local GetBindingKey           = _G.GetBindingKey
local C_KeyBindings            = _G.C_KeyBindings and _G.C_KeyBindings.GetBindingByKey
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

local BORDER      = Widget.BORDER     -- 1px Monet edge, used as the icon inset everywhere
local CROP        = 0.08  -- icon crop that hides Blizzard's own icon border
local HOTKEY_SIZE = 12
local COUNT_SIZE  = 12
local MACRO_SIZE  = 12

local DEFAULT_SIZE    = 28
local DEFAULT_SPACING = 2
local DEFAULT_BARS    = 5

local BUTTONS_PER_BAR = 12

--- 冷却数字交给 Cooldown 模块渲染（自动缩放 + 紧急变色放大）；模块缺席时退回原纯字体样式。
local function StyleCooldownFrame(cd)
    if not cd then return end
    local cooldowns = ns:GetModule("Cooldown")
    if cooldowns and cooldowns.StyleCooldown then
        cooldowns:StyleCooldown(cd, COUNT_SIZE)
    else
        Widget:StyleCooldownText(cd, COUNT_SIZE, "cooldown")
    end
end

--- 每个按钮有 0..18 号状态，状态 0 是"没有翻页驱动"时的兜底；第 n 页映射到 (n-1)*12+1 起的 12 个槽，和暴雪编号一致。
local function PageSlot(page, index)
    return (page - 1) * BUTTONS_PER_BAR + index
end

local function Config()
    return ns:DB().actionBars or {}
end

--- 面板上的显示开关（默认开：DEFAULTS 里同为 true，读到 false 才关）。
local function Toggle(key)
    return Config()[key] ~= false
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

--- 玩家自己的"按下即施法"偏好由客户端自己处理（SecureActionButton_OnClick 看
--- ActionButtonUseKeyDown），我们不需要知道它。

--- 某个暴雪绑定名绑着的键，没有就返回 nil。
-- GetBindingKey 缺席时用命名空间版本兜底（后者要键、返回绑定名，所以结果要排错）。
local function BindingFor(action)
    if not action then return nil end

    if GetBindingKey then
        local key = Call(GetBindingKey, action)
        if type(key) == "string" and key ~= "" then return key end
    end

    if C_KeyBindings then
        local key = Call(C_KeyBindings, action)
        if type(key) == "string" and key ~= ""
            and key ~= action and not key:find("ACTIONBUTTON") then
            return key
        end
    end

    return nil
end

-- `page` 是这条动作条显示的那一页（状态 0 的兜底值）；`bind` 是暴雪原本给这排按钮的绑定名
-- 前缀，玩家已有的按键设置因此原样生效。位置存在存档里（见 Core.lua），表里给的只是初次锚点。

local BAR_DEFS = {
    -- 屏幕底边基线由 Utils/Layout.lua 统一给出（小地图、聊天框都按它对齐），别在这里写死数字。
    { key = "Bar1", index = 1, page = 1,  paged = true,  bind = "ACTIONBUTTON",
      blizzard = "MainMenuBar",
      point = "BOTTOM", relativeTo = "UIParent", relativePoint = "BOTTOM", x = 0,
      y = (ns.Layout and ns.Layout.bottom) or 24 },
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

    -- 自绘宠物条：按钮是**收养来的**暴雪 PetActionButton（本客户端没有通用 type="pet" 的安全
    -- 按钮）。位置：**1 号条下方、右对齐**，并按玩家的要求"平时半透明、悬停变清晰"（hover = true，
    -- 见 SetupHoverOnly：不是 Hide 而是调 alpha，帧仍算显示，鼠标因此进得来）。
    -- 层级 66：高于 1–8 号条的 60/61，低于接住器 70。
    { key = "BarPet", index = 9, page = 0, count = 10, pet = true, hover = true, bind = "BONUSACTIONBUTTON",
      level = 66,
      point = "TOPRIGHT", relativeTo = "Bar1", relativePoint = "BOTTOMRIGHT", x = 0, y = -2 },

    -- 姿态条（德鲁伊形态 / 死骑灵气 / 战士姿态 / 潜行）：和宠物条一样**收养**暴雪的
    -- StanceButton1..10（本客户端没有可用的通用安全按钮；暴雪按钮的施法路径才是原生的）。
    -- 位置：**最上面那条的正上方、左对齐**（默认 3 组时就是 Bar3 的 TOPLEFT；锚点每次排布按
    -- 当前条数重算，见 SyncStanceAnchor），按钮从左往右排；
    -- 只显示当前职业的形态数（1..N），N+1..10 藏起来排在右边。
    -- hover = true：和宠物条同一套"平时 0.3 / 悬停 1"（见 SetupHoverOnly）。
    { key = "BarStance", index = 10, page = 0, count = 10, stance = true, hover = true,
      level = 66,
      point = "BOTTOMLEFT", relativeTo = "Bar3", relativePoint = "TOPLEFT", x = 0, y = 2 },
}

-- 接管的那几条暴雪动作条：不重画，只搬最外层容器（只搬内层的话，暴雪一 Hide 外层，我们的条就留在
-- 屏幕上了）、缩放、裁图标。都在 3 号条上方一行，宠物右对齐、姿态左对齐；死骑食尸鬼 + 灵气时会重叠，改 positions 错开即可。
local ADOPTED_DEFS = {
    { key = "BarPet",    containers = { "PetActionBarFrame", "PetActionBar" },
      pattern = "PetActionButton%d", count = 10, label = "宠物",
      glow = "autoCast",
      point = "BOTTOMRIGHT", relativeTo = "Bar3", relativePoint = "TOPRIGHT", x = 0, y = 2 },
    { key = "BarStance", containers = { "StanceBarFrame", "StanceBar" },
      pattern = "StanceButton%d", count = 10, label = "姿态",
      point = "BOTTOMLEFT", relativeTo = "Bar3", relativePoint = "TOPLEFT", x = 0, y = 2 },
}

--- 宠物条（唯一带自动施法提示的那条）。自绘动作条关掉时它没被接管，也要能单独拿到。
local PET_DEF
for _, def in ipairs(ADOPTED_DEFS) do
    if def.glow == "autoCast" then
        PET_DEF = def
        break
    end
end

-- 暴雪条压制 / 归还（Park / ParkBag / Restore / 0.5s 压 alpha 的驱动）已拆到
-- Modules/ActionBars/Blizzard.lua（P5'，move-only）：M.blizzard.Park / ParkBag / Restore，
-- M:ParkBlizzard / M:RestoreBlizzard 也定义在那个文件里。

-- 状态驱动的条件串与 _onstate 片段（ON_STATE_PAGE / VISIBILITY_MAIN / VISIBILITY_OTHER /
-- FULL_PAGE / EXIT_SNIPPET）已拆到 Modules/ActionBars/Secure.lua（P5'，move-only）：
-- M.secure.*；CreateBar / CreateLeaveVehicle 的调用点已改名走那里。

-- 留出降落伞：模板缺失时用来创建框体 / 退回暴雪动作条。
-- 顺序有讲究：零售 12.x 上把 SecureHandlerStateTemplate 和 BackdropTemplate 写在**同一条**模板串
-- 里，建出来的框体仍有 SetAttribute，却没有 WrapScript / Execute —— 安全处理器等于没装上
-- （实测：单独用 SecureHandlerStateTemplate 有 WrapScript，合写就是 nil）。动作条的美术全是自绘的，用不到
-- BackdropTemplate。
local CONTAINER_TEMPLATES = {
    "SecureHandlerStateTemplate",
    "SecureHandlerStateTemplate, BackdropTemplate",
    "BackdropTemplate",
    "",   -- 不带模板（零售 12.x 里 "Frame" 不是合法模板）
}

-- 按钮模板：只要 SecureActionButtonTemplate。
-- **绝对不要再拼 QuickKeybindButtonTemplate**：它在 QuickKeybind.xml:13 里写了

-- <OnClick method="QuickKeybindButtonOnClick"/>，而模板串里后写的覆盖先写的 ——
-- 安全点击处理器 SecureActionButton_OnClick 会被整个顶掉。那个 OnClick 只在
-- 快速按键模式（KeybindFrames_InQuickKeybindMode）下干活，平时一次点击什么都不做：
-- 不发技能、不显示错误、连"按钮被按下"都没有，表现就是"点上去毫无反应"。
-- 暴雪自家按钮靠 ActionBarButtonTemplate 的 mixin 手动二合一（ActionButton.lua:1503-1506：
-- 先调 ActionBarActionButtonMixin.OnClick 再调 QuickKeybindButtonOnClick），
-- 自绘按钮没有那层 mixin，就只能二选一 —— 选能施法的那个。
local BUTTON_TEMPLATES = {
    "SecureActionButtonTemplate",
    "",   -- 不带模板（保底：至少还能画个图标）
}

local bars    = {}   -- key -> { def, frame, buttons }
local adopted = {}   -- key -> { def, frame }
local built   = false
local announced     = false
local announcedFailure = false
local buildFailure  -- "lab" | "header" | "button" | "template"
local leaveVehicle

local FAILURE_TEXT = {
    lab      = "没找到安全按钮模板，已保留暴雪默认动作条。",
    header   = "此客户端没有安全头框体模板，已保留暴雪默认动作条。",
    button   = "此客户端没有安全按钮模板，已保留暴雪默认动作条。",
    template = "自绘动作条创建失败，已保留暴雪默认动作条。",
}

-- 把暴雪的框体藏起来，而不是销毁它：按键仍然能按、事件仍然能收，只是玩家看不见，
-- 任何情况下都能原样放回去。
--
-- 三条都被这个客户端否掉了：Hide()/SetShown() 会被暴雪的 SetShownBase 复活；
-- SetParent 搬进隐藏框会让编辑模式（UpdateRightActionBarPositions）算出的缩放变 0
-- （"MultiBarRight:SetScale(): Scale must be > 0"）；销毁更不行（按键绑在它身上）。
-- 最后只剩一条稳的：**留在原地，只 SetAlpha(0) + 关鼠标**（见 Modules/ActionBars/Blizzard.lua 的 Park）。

local function NewFrame(kind, name, parent, templates, validate)
    for _, template in ipairs(templates) do
        local ok, frame
        if template == "" then
            -- 零售 12.x 里 "Frame" 已经不是合法模板了（CreateFrame 会报
            -- "Couldn't find inherited node 'Frame'"），不带模板建框体才是对的。
            ok, frame = pcall(CreateFrame, kind, name, parent)
        else
            ok, frame = pcall(CreateFrame, kind, name, parent, template)
        end
        if ok and frame and (not validate or validate(frame)) then return frame, template end
    end
    return nil
end

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

-- ---------------------------------------------------------------------------
-- 按钮
-- ---------------------------------------------------------------------------

-- 库里把暴雪 ActionButtonTemplate 的一堆部件都留着（冷却、堆叠、宏名、射程、闪光、自动施法圈……）。
-- 这里收敛成 MonetUI 的样子：图标内缩 1 像素，露出来的那圈就是描边；多余的美术全部不要。

local RINGS = setmetatable({}, { __mode = "k" })

--- 描边颜色：装着装备的槽位用高亮色，其余用当前边框色。
-- ring 铺满按钮、只在图标外露 1 像素即描边；well 只铺图标范围，空槽时就是"空格子"的底色（有图标时被完全盖住）。
local function RefreshRing(button)
    local parts = RINGS[button]
    if not parts then return end

    local r, g, b = Color:GetBorder()
    parts.ring:SetColorTexture(r, g, b, 0.9)

    -- 空槽底色参考 NDui：纯黑 0.25，比灰底更通透、不泛白。
    parts.well:SetColorTexture(0, 0, 0, 0.25)
end

local function RefreshRings()
    for button in pairs(RINGS) do
        RefreshRing(button)
    end
end

--- 当前这一格对应哪个槽位。
-- 条自己的 "actionpage" 属性是客户端写的（状态驱动 → _onstate-page 片段），
-- 槽位 = 页号 * 12 + 按钮序号，和暴雪的编号一致。
local function SlotFor(bar, index)
    local page = bar.frame:GetAttribute("actionpage")
    page = tonumber(page) or bar.def.page
    return PageSlot(page, index)
end

-- 翻页 / 槽位契约与翻页子片段（PAGE_CHILD / PageChildSnippet / InstallPageChild）已拆到
-- Modules/ActionBars/Secure.lua（P5'，move-only）：M.secure.*；契约的长注释（槽位为什么
-- 只能由片段写、实机对照数据）也搬过去了，要看去那边。

-- ---------------------------------------------------------------------------
-- **点击用到的属性必须由安全片段写。**
--
-- 片段本体（KIND_CHILD / KEYDOWN_CHILD / KIND_SNIPPET / KEYDOWN_SNIPPET）与装上 / 下发
-- 函数（InstallSecureInit / PushSecureInit / PushPageToChildren）已拆到
-- Modules/ActionBars/Secure.lua（P5'，move-only）：M.secure.*；调用点已改名走那里。
-- 为什么必须走片段（Lua 写属性 = 脏值 → 连锁 ADDON_ACTION_BLOCKED）的长注释在 Secure.lua。

--- 这一格现在对应哪个槽位：优先用片段写的 "action" 属性（和客户端点击时算的完全一致）。
local function SlotOf(button, bar, index)
    if button and button.GetAttribute then
        local slot = button:GetAttribute("action")
        if type(slot) == "number" and slot > 0 then return slot end
    end
    return SlotFor(bar, index)
end

--- useOnKeyDown 跟着玩家的 cvar 走（按下 / 抬起施法）——本体在 Secure.lua：M.secure.SetUseOnKeyDown。

--- 冷却：**自己画，但绝不读机密数字**。
--- 用 C_ActionBar.GetActionCooldown 只取 isActive（NeverSecret），计时交给
--- GetActionCooldownDuration 返回的 duration 对象，再 SetCooldownFromDurationObject。
--- 这样在副本/战斗中（冷却被标成机密）也不会触发
--- "Secret values are only allowed during untainted execution"。
--- 用 C_ActionBar.RegisterActionUIButton 是错的：客户端回写我们的冷却框，参数是机密值，必报错
--- （Ellesmere 的注释里也写了它对自建按钮 "paints NOTHING"）。
local function PaintCooldown(button, slot)
    local cooldown = button and button.cooldown
    if not cooldown or type(slot) ~= "number" then return end
    local ok, info = pcall(C_ActionBar.GetActionCooldown, slot)
    local durationObject
    if ok and info and info.isActive and C_ActionBar.GetActionCooldownDuration then -- TAINT-OK: GetActionCooldown().isActive 是 NeverSecret,链里其余是全局表
        local ok2, dur = pcall(C_ActionBar.GetActionCooldownDuration, slot)
        if ok2 then durationObject = dur end
    end


    if durationObject and cooldown.SetCooldownFromDurationObject then
        pcall(cooldown.SetCooldownFromDurationObject, cooldown, durationObject)
    else
        pcall(cooldown.Clear, cooldown)
    end

    -- 把明文 start/duration 告诉冷却文字渲染器（以前靠 SetCooldown 的全局钩子拿，
    -- 那个钩子会污染暴雪调用链，已经拆掉；这里是我们自己的调用点，拿到就给）。
    if ok and info and info.isActive then
        local cooldowns = ns:GetModule("Cooldown")
        if cooldowns and cooldowns.NoteStart then
            pcall(cooldowns.NoteStart, cooldowns, cooldown, info.startTime, info.duration)
        end
    end
end

-- 拖放接住器已拆到 Modules/ActionBars/DragDrop.lua（P5'，move-only）：M.dragdrop.EnsureDropCatcher。
-- 子文件要用本文件的局部函数 SlotOf（格子 → 槽位），这里显式挂到 M 上。
M.SlotOf = SlotOf

--- 快捷键太长会顶出按钮（SHIFT-1、MOUSEWHEELUP…），缩成 s1 / MU 这类写法。
local function ShortenKey(text)
    if type(text) ~= "string" or text == "" then return text end
    if RANGE_INDICATOR and text == RANGE_INDICATOR then return text end

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
    return short
end

--- 把热键写在按钮角上（没有绑定、或面板里关了就藏起来）。
local function SetHotkey(button)
    if not button or not button.hotkey then return end
    local key = Toggle("showHotkey") and BindingFor(button.bindName) or nil
    if key then
        pcall(button.hotkey.SetText, button.hotkey, ShortenKey(key))
        pcall(button.hotkey.Show, button.hotkey)
    else
        pcall(button.hotkey.SetText, button.hotkey, "")
        pcall(button.hotkey.Hide, button.hotkey)
    end
end

-- 图标件：底色描边（ring/well）、图标本体、织纹。抽自 SkinButton（P4 拆分，逐条保留语义）。
local function BuildButtonIcon(button)
    -- 图标往后缩 1 像素，露出来的底色就是描边；空槽时 well 顶上（见 RefreshRing）。
    local ring = button:CreateTexture(nil, "BACKGROUND", nil, 0)
    ring:SetAllPoints(button)

    local well = button:CreateTexture(nil, "BACKGROUND", nil, 1)
    well:SetPoint("TOPLEFT", button, "TOPLEFT", BORDER, -BORDER)
    well:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -BORDER, BORDER)

    RINGS[button] = { ring = ring, well = well }

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", BORDER, -BORDER)
    icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -BORDER, BORDER)
    button.icon = icon

    -- 图标自带一圈 8% 的描边（暴雪画的）；不裁掉，我们的 1 像素描边外面还会多一圈黑边。
    -- 收养的宠物条 / 姿态条在 AdoptBar 里裁的是同一份 CROP，两条条看起来才一致。
    Skin:CropIcon(icon, CROP, 1 - CROP, CROP, 1 - CROP)

    -- 美化材质：weave（底纹）铺在图标下方（BACKGROUND/2），sheen（顶亮渐变）也放在
    -- 图标下方（BACKGROUND/3，高于 weave 低于 ARTWORK 图标）。之前 sheen 走默认 OVERLAY/1
    -- —— ADD 混合的近白渐变直接叠在图标上，等于给每个图标蒙一层白，实测隐藏 sheen 后
    -- 图标区域平均像素差 ~11（明显发白），隐藏 weave 则几乎无变化（~0.2）。把 sheen 压到
    -- 图标之下后：空槽仍有"顶亮底沉"的体积感，有图标时图标保持原色不被洗白。
    -- sheen 暂时去掉（alpha=0）；weave 织纹降到 0.25，参考 NDui 的通透感。
    Widget:ButtonMaterial(button, { alpha = 0, weaveAlpha = 0.25, layer = "BACKGROUND", sublevel = 3 })
end

-- 热键 / 堆叠数 / 宏名三个文本。抽自 SkinButton（P4 拆分，逐条保留语义）。
local function BuildButtonFonts(button)
    -- 热键
    -- 颜色必须是白的（原来用主题的 edge 色，在技能图标上根本看不清）。
    local hotkey = Widget:Font(button, HOTKEY_SIZE, "pixel", { r = 1, g = 1, b = 1 }, "LEFT")
    hotkey:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -1)
    button.hotkey = hotkey

    -- 堆叠数量
    local count = Widget:Font(button, COUNT_SIZE, "pixel", { r = 1, g = 1, b = 1 }, "RIGHT")
    count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 1)
    button.count = count

    -- 宏名
    local macro = Widget:Font(button, MACRO_SIZE, "pixel", "edge", "CENTER")
    macro:SetPoint("BOTTOM", button, "BOTTOM", 0, 1)
    button.macro = macro
end

-- 冷却框：**自己建自己的框**，但计时由我们自己从 duration 对象灌进去（见 PaintCooldown）。
-- 抽自 SkinButton（P4 拆分，逐条保留语义）。
local function BuildButtonCooldown(button)
    -- 绝不能用 C_ActionBar.RegisterActionUIButton：客户端回写我们的冷却框时参数是机密值，
    -- 受限环境（副本/战斗）里必报 "Secret values are only allowed during untainted execution"。
    local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cooldown:SetAllPoints(button)
    if cooldown.SetDrawEdge then pcall(cooldown.SetDrawEdge, cooldown, false) end
    if cooldown.SetDrawBling then pcall(cooldown.SetDrawBling, cooldown, false) end
    if cooldown.SetDrawSwipe then pcall(cooldown.SetDrawSwipe, cooldown, true) end
    if cooldown.SetHideCountdownNumbers then pcall(cooldown.SetHideCountdownNumbers, cooldown, false) end
    StyleCooldownFrame(cooldown)
    button.cooldown = cooldown
end

-- 按下 / 悬停反馈贴图（默认必须是隐藏的）。抽自 SkinButton（P4 拆分，逐条保留语义）。
local function BuildButtonFeedback(button)
    -- 按下 / 悬停：默认**必须是隐藏的**，由按钮自己的事件来显隐。
    -- 以前这两张贴图建出来就一直 shown（全仓没有一处切 visible），45% 黑 + 15% 白常年压在
    -- 图标上：对比度掉一半、整体发灰发白。
    local pushed = button:CreateTexture(nil, "OVERLAY")
    pushed:SetPoint("TOPLEFT", button, "TOPLEFT", BORDER, -BORDER)
    pushed:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -BORDER, BORDER)
    pushed:SetColorTexture(0, 0, 0, 0.45)
    pushed:Hide()
    button.pushed = pushed

    -- 悬停高亮
    local highlight = button:CreateTexture(nil, "OVERLAY")
    highlight:SetPoint("TOPLEFT", button, "TOPLEFT", BORDER, -BORDER)
    highlight:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -BORDER, BORDER)
    highlight:SetColorTexture(1, 1, 1, 0.15)
    highlight:Hide()
    button.highlight = highlight
end

--- 画一个按钮的自绘部分（底板、图标、数字、宏名、热键、冷却）。
-- 装配顺序：图标件 → 文本 → 冷却 → 按下/悬停反馈 → 描边状态。
local function SkinButton(button)
    if Marked(button, "skinned") then return end
    Mark(button, "skinned", true)

    BuildButtonIcon(button)
    BuildButtonFonts(button)
    BuildButtonCooldown(button)
    BuildButtonFeedback(button)

    RefreshRing(button)
end

--- 把这一格的内容（图标 / 数字 / 宏名 / 冷却）刷新成槽位 slot 的样子。
local function UpdateButtonContent(button, slot)
    if not button then return end

    -- 图标：文件 ID 不是秘密值，可以直接给贴图。
    local texture = ActionBar and ActionBar.GetActionTexture and ActionBar.GetActionTexture(slot)
    if type(texture) == "number" and texture > 0 then
        pcall(button.icon.SetTexture, button.icon, texture)
        pcall(button.icon.Show, button.icon)
    else
        pcall(button.icon.SetTexture, button.icon, nil)
        pcall(button.icon.Hide, button.icon)
    end

    -- 堆叠数量：本客户端的 C_ActionBar.GetActionDisplayCount 返回的是**字符串**
    -- （use count 或充能数，超出上限时是 "*"，见 docs/api/FUNCTIONS.md），不是数字 ——
    -- 以前判 type(count)=="number"，所以数字从来没显示出来过。
    -- 受限环境下它整体是机密值，而机密串的 type() 照样是 "string"：判完类型必须再过
    -- issecretvalue，否则 SetText / 比较会抛 invalid value (secret)。
    local count
    if Toggle("showCount") and ActionBar and ActionBar.GetActionDisplayCount
        and not Secrets.CooldownsSecret() then
        count = ActionBar.GetActionDisplayCount(slot)
    end
    if type(count) == "string" and not Secrets.IsSecret(count) and count ~= "" and count ~= "1" then
        pcall(button.count.SetText, button.count, count)
        pcall(button.count.Show, button.count)
    else
        pcall(button.count.SetText, button.count, "")
        pcall(button.count.Hide, button.count)
    end

    -- 宏名
    local macroText
    if Toggle("showMacro") and ActionBar and ActionBar.GetActionText then
        macroText = ActionBar.GetActionText(slot)
    end
    if type(macroText) == "string" and macroText ~= "" then
        pcall(button.macro.SetText, button.macro, macroText)
        pcall(button.macro.Show, button.macro)
    else
        pcall(button.macro.SetText, button.macro, "")
        pcall(button.macro.Hide, button.macro)
    end

    -- 冷却自己画（不读机密数字，见 PaintCooldown）
    PaintCooldown(button, slot)
end

-- CreateFrame 的第 5 个参数（id）只有直接调用才能给，所以按钮不走 NewFrame。
local function CreateSecureButton(name, parent, id, templates)
    for _, template in ipairs(templates or BUTTON_TEMPLATES) do
        local ok, frame
        if template == "" then
            ok, frame = pcall(CreateFrame, "CheckButton", name, parent, nil, id)
        else
            ok, frame = pcall(CreateFrame, "CheckButton", name, parent, template, id)
        end
        if ok and frame then return frame, template end
    end
    return nil
end

-- 托盘提示只打印一次（每个会话），不刷屏。
local hintedFlyout

--- 拖出 / 拖入。动作条走 PickupAction/PlaceAction。
--- 这些全是受保护全局，战斗中会被客户端拒，所以一律先看 InCombatLockdown。
--- （宠物条不在这里：它收养的是暴雪 PetActionButton，拖放由暴雪自己处理，
---  原来的 isPet 分支在 def.pet 提前 return 之后就已经走不到了。）
local function InstallDrag(bar, button, index)
    pcall(button.RegisterForDrag, button, "LeftButton", "RightButton")
    button:SetScript("OnDragStart", function(self)
        if InCombatLockdown() then return end
        local slot = SlotOf(self, bar, index)
        if slot and not IsModifiedClick("PICKUPACTION") then
            local locked = true
            if Settings and Settings.GetValue then
                local ok, value = pcall(Settings.GetValue, "lockActionBars")
                if ok then locked = value end
            end
            if locked then return end
        end
        if slot and PickupAction then pcall(PickupAction, slot) end
    end)
    button:SetScript("OnReceiveDrag", function(self)
        if InCombatLockdown() then return end
        local slot = SlotOf(self, bar, index)
        if slot and PlaceAction then pcall(PlaceAction, slot) end
    end)
end

-- 按钮要实现的最小一份 SpellFlyout（弹出托盘）接口。抽自 BuildButton（P4 拆分，逐条保留语义）。
-- 暴雪的 SpellFlyout（多阶法术 / 宠物技能那种"弹出托盘"）要求按钮实现
-- FlyoutButtonMixin 的最小一份（Blizzard_Flyout/Flyout.lua:72-116）：
--   GetPopupDirection()  托盘朝哪边展开（SpellFlyout.lua:260 要用）
--   TogglePopup()        挂上 / 摘掉 SpellFlyout（SpellFlyout.lua:350 要用）
--   IsPopupOpen/ClosePopup
-- 裸 SecureActionButtonTemplate 一个都没有 → 点开托盘就报
-- "SpellFlyout.lua:260/350: attempt to call a nil value"。
local function EnsureFlyoutMixin(button)
    button.popupDirection = "UP"
    button.popupOffset = 0
    if not button.GetPopupDirection then
        button.GetPopupDirection = function(self) return self.popupDirection or "UP" end
    end
    if not button.IsPopupOpen then
        button.IsPopupOpen = function(self)
            local popup = _G.SpellFlyout
            return (popup and popup:IsAttachedToButton(self)) and true or false
        end
    end
    if not button.TogglePopup then
        -- 本客户端的边界：托盘挂在我们（插件）的按钮下面时，选项的施法一定是脏的 ——
        -- 实机 ADDON_ACTION_FORBIDDEN MonetUI CastSpellByID（父级改了 UIParent 也没用，
        -- 因为 SpellFlyout:Toggle 在布托盘时就已把法术 ID 通过 SetAttribute 写进脏上下文）。
        -- 所以鼠标点击**不展开**托盘，改成提示用快捷键：那条走暴雪自己的 ActionButton，
        -- 展开的托盘选项可以正常点击（已实机确认）。
        button.TogglePopup = function(self)
            if not hintedFlyout then
                hintedFlyout = true
                ns:Print("这类技能的弹出托盘请用快捷键打开 —— 用鼠标从插件动作条展开的托盘，选项无法施放。")
            end
        end
    end
    if not button.ClosePopup then
        -- 托盘如果曾经挂在我们身上（旧版行为），这里仍要能干净放手，否则暴雪按钮再弹会撞
        -- assertsafe("FlyoutPopup already has a button set.")。
        button.ClosePopup = function(self)
            local popup = _G.SpellFlyout
            if popup and popup.flyoutButton == self then
                pcall(popup.DetatchFromButton, popup)
            end
        end
    end
    -- 条隐藏 / 换页 / 上载具时按钮会被藏起来：托盘不能留在我们身上，
    -- 否则下一次别人（包括暴雪自己的 ActionButton）要弹托盘就撞断言。
    if not Marked(button, "flyoutHooked") then
        Mark(button, "flyoutHooked", true)
        button:HookScript("OnHide", function(self) -- TAINT-OK: button 是自建动作按钮（托盘 FlyoutMixin 的旧版残留收尾），实机案已入 AGENTS/PLAN
            local popup = _G.SpellFlyout
            if popup and popup.flyoutButton == self then
                pcall(popup.DetatchFromButton, popup)
            end
        end)
    end
end

-- 按钮鼠标提示：走轮询（Widget:HoverWatch），**不挂任何脚本钩子**（见 AGENTS 的皮肤原则）。
-- GameTooltip:SetAction 在本客户端可用（实测 function）。
local function EnsureButtonTooltip(button, bar, index)
    if Marked(button, "tooltip") then return end
    Mark(button, "tooltip", true)
    Widget:HoverWatch(button, function(self)
        local slot = SlotOf(self, bar, index)
        if not slot then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if not pcall(GameTooltip.SetAction, GameTooltip, slot) then
            GameTooltip:SetText("")
        end
        GameTooltip:Show()
    end, function()
        GameTooltip:Hide()
    end)
end

local function BuildButton(bar, index)
    local def  = bar.def
    local name = "MonetUI" .. def.key .. "Button" .. index

    -- 只有自绘条会走到这里（宠物条 / 姿态条在 CreateBar 里提前 return 去收养暴雪按钮），
    -- 所以模板固定用安全动作按钮那一套。
    local button = CreateSecureButton(name, bar.frame, index)
    if not button then return nil end

    -- 安全按钮契约（和 Ellesmere 在 12.x 上验证过的写法一致）：
    --   * SetID(0)：让客户端的 CalculateAction 走"显式 action 属性"这条（path 2），
    --     而不是 id + actionpage；
    --   * type / typerelease：鼠标点击走 up 边（客户端对硬件鼠标强制 useOnKeyDown=false），
    --     键盘走 down 边；
    --   * useOnKeyDown 跟着玩家的 cvar 走，cvar 变化时由 SetUseOnKeyDown 重写；
    --   * **action 属性只由安全片段写**（InstallPageChild / _childupdate-mui-page）。
    --     这是"能不能施法"的分水岭：Lua 写 action → 客户端判插件越权，每次点击弹
    --     "MonetUI 已被禁用，因为该功能只对暴雪的 UI 开放"；片段写 → 正常施法（已实机验证）。
    pcall(button.SetID, button, 0)
    pcall(button.RegisterForClicks, button, "AnyDown", "AnyUp")

    EnsureFlyoutMixin(button)

    -- 类型 / 按下抬起 / 槽位全部由安全片段写（见 InstallSecureInit 的注释）。
    M.secure.InstallSecureInit(button)
    M.secure.InstallPageChild(button, index)

    -- 拖出 / 拖入
    InstallDrag(bar, button, index, false)

    button.bindName = def.bind .. index
    -- bar 必须是**框体**（SetHotkey 之类还会用到）。
    button.bar      = bar.frame

    SkinButton(button)

    -- 热键文字（跟着玩家的按键设置走）
    SetHotkey(button)

    EnsureButtonTooltip(button, bar, index)

    return button
end

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

--- 姿态条贴在"当前最上面那条"的顶边。
--- 默认锚在 `Bar3`，但玩家把「显示动作条数量」开到 4 组以上时，`Bar4` 会长在**同一个 y** ——
--- 两条直接叠在一起。实机症状（2026-10-26）：点在姿态格上，命中的却是 bar4 的拖放接住器
--- （level 70，压在姿态条 67 之上），于是"点姿态放出动作条第 1 格"。条数是活的，所以每次排布
--- 都按当前最高的一条重算一次默认锚点；玩家自己拖过的位置存在 `positions` 里，优先级更高，不受影响。
local function SyncStanceAnchor()
    local bar = bars.BarStance
    if not bar or not bar.def then return end
    bar.def.relativeTo = "Bar" .. math.max(1, math.min(BarCount(), 8))
end

--- 这条是不是"收养暴雪按钮"的条（宠物 / 姿态）：图标、冷却、选中态全由暴雪自己刷，
--- 我们的图标/冷却/绑定/翻页那几套循环必须绕开它们（否则会读到错的槽位，把原生冷却清掉）。
local function IsAdopted(bar)
    return bar and bar.def and (bar.def.pet or bar.def.stance) or false
end

local function RefreshBar(bar)
    -- 宠物条 / 姿态条是收养来的暴雪按钮：图标/冷却/自动施法提示/选中态由暴雪自己刷新，我们不碰。
    if IsAdopted(bar) then return end
    for index, button in ipairs(bar.buttons) do
        UpdateButtonContent(button, SlotOf(button, bar, index))
    end
end

-- 页号是**客户端**写的：状态驱动每 0.2 秒才结算一次，然后 _onstate-page 片段把
-- 新页号写进条自己的 "actionpage" 属性。我们的事件（翻页 / 槽位变化）发生在
-- 结算之前或之后都说不准，中间那一小段时间按钮显示的还是旧页的图标。
-- 所以这里盯一次 actionpage：变了就重画（每 0.2 秒读 8 个属性，很便宜）。
local pageWatcher

local function WatchPages(show)
    if not pageWatcher then
        pageWatcher = CreateFrame("Frame")
        pageWatcher:SetScript("OnUpdate", function(self, elapsed)
            self.timer = (self.timer or 0) + (elapsed or 0)
            if self.timer < 0.2 then return end
            self.timer = 0
            for _, bar in pairs(bars) do
                local page = tonumber(bar.frame:GetAttribute("actionpage")) or bar.def.page
                if page ~= bar.page then
                    bar.page = page
                    RefreshBar(bar)
                end
            end
        end)
    end
    if show then pageWatcher:Show() else pageWatcher:Hide() end
end

--- 给收养来的暴雪按钮"换皮"（宠物条 / 姿态条共用；ElvUI 的 StyleButton 同一思路，但只做最必要的几层）：
---   * 藏掉它自己的美术（NormalTexture / Border / SlotBackground / Flash）—— 只调它们的方法；
---   * 垫一块**我们自己的**底板 + 1px 边框（子框体属于我们，不会污染暴雪对象）；
---   * 图标裁外圈 8%（CropIcon 现在是轮询实现，不挂钩子）；
---   * 热键/数量换像素字体；冷却文字接我们那套渲染。
--- 全部 pcall：这个客户端对受保护按钮的某些方法会拒绝，失败就保持原生样子，不能崩。
local function SkinAdoptedButton(btn)
    if not btn or Marked(btn, "adoptedSkinned") then return end
    Mark(btn, "adoptedSkinned", true)

    local function fade(region)
        if region and type(region.SetAlpha) == "function" then pcall(region.SetAlpha, region, 0) end
    end
    fade(btn.NormalTexture)
    fade(btn.Border)
    fade(btn.SlotBackground)
    fade(btn.Flash)
    fade(btn.AutoCastShine)

    -- 空槽底色：收养来的按钮图标是**铺满整格**的，暴雪自己的灰底（SlotBackground / NormalTexture）
    -- 又被上面几行关掉了 —— 于是没有动作的槽位（宠物条 8..10 格）整格透明，实机就是玩家说的
    -- "空白按钮看不到"。补一块和自绘槽位同色的 well（纯黑 0.25，见 RefreshRing），垫在图标
    -- **下面**：暴雪图标是 BACKGROUND 层，我们取更低的子层级（-8），有图标时被完全盖住，空槽时露出来。
    local well = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    well:SetPoint("TOPLEFT", btn, "TOPLEFT", BORDER, -BORDER)
    well:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -BORDER, BORDER)
    well:SetColorTexture(0, 0, 0, 0.25)
    Mark(btn, "adoptedWell", well)

    -- 边框：收养来的按钮**图标是铺满整格的**（我们不能像自绘那样把图标内缩 1px），
    -- 所以底板/边框不能垫在下面（会被图标完全盖住）——改成在按钮**上方**画一圈 1px 的边框。
    -- 必须带 BackdropTemplate：Widget:Theme 走的是 SetBackdrop，没有该模板的面板画不出边。
    local border = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    border:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
    border:SetFrameLevel(btn:GetFrameLevel() + 1)
    border:EnableMouse(false)
    Widget:Theme(border, { thickness = 1, bgAlpha = 0 })
    Mark(btn, "adoptedBorder", border)

    -- 图标内缩 1px，和我们自绘按钮完全一致（露出来的那 1px 就是边框）。
    local icon = btn.icon
    if not icon and btn.GetName and type(btn.GetName) == "function" then
        local name = btn:GetName()
        icon = name and _G[name .. "Icon"]
    end
    if icon and icon.ClearAllPoints and icon.SetPoint then
        pcall(icon.ClearAllPoints, icon)
        pcall(icon.SetPoint, icon, "TOPLEFT", btn, "TOPLEFT", 1, -1)
        pcall(icon.SetPoint, icon, "BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
        pcall(Skin.CropIcon, Skin, icon, CROP, 1 - CROP, CROP, 1 - CROP)
    end

    if btn.HotKey then pcall(Widget.SetFont, Widget, btn.HotKey, HOTKEY_SIZE, "pixel") end
    if btn.Count then pcall(Widget.SetFont, Widget, btn.Count, COUNT_SIZE, "pixel") end

    -- 冷却**交给暴雪自己**：我们那套渲染会给它的冷却框 SetHideCountdownNumbers(true) 再自己画字，
    -- 而暴雪冷却框在本客户端受限（SetCooldown 参数可能是机密值、调用被拒），
    -- 结果两层都没显示 —— 实机表现就是"冷却看不到"。收养来的按钮直接用原生冷却。
    -- local cd = btn.cooldown or btn.Cooldown
    -- if cd then pcall(StyleCooldownFrame, cd) end
end

--- 宠物条 / 姿态条"悬停高亮"的静默透明度。**用 alpha 而不是 Hide**：alpha 不为 0 的帧在客户端
--- 眼里仍然是"显示着"的，鼠标照样进得来（暴雪自己收 HUD 帧也是这招），也不会和 [pet] 状态驱动的
--- Show/Hide 打架（补一刀 Show 会被它顶回来，屏幕上一闪一闪）。
--- 0.3 而不是 0：玩家 2026-10-26 的要求是"平时看得到、悬停变清晰"，0 会让两个关键条平时完全隐形。
local HOVER_IDLE_ALPHA = 0.3

--- 判定走轮询（`Widget:HoverWatch`，0.1 秒一次）：**绝不往暴雪的受保护按钮上挂 OnEnter**，
--- 那是往它的脚本槽里写我们的函数（AGENTS 污染模型第一条）。宠物条和姿态条共用这一套。
local function SetupHoverOnly(bar, enabled)
    local frame = bar.frame
    if not enabled then
        -- 关掉悬停模式：恢复常显（配置面板把勾去掉时走这条）。
        -- 回调是常驻登记的（bar.hoverReady），所以先关开关，否则下次鼠标进出又会被拉回 0.3。
        bar.hoverOnly = false
        pcall(frame.SetAlpha, frame, 1)
        return
    end

    bar.hoverOnly = true
    if not bar.hoverReady then
        bar.hoverReady = true
        -- 框体自己得开鼠标：不开的话，鼠标落在子按钮上时 `IsMouseOver()` 对父框体不成立。
        -- 这是**我们自己的**框体（按钮只是换了父），不写暴雪的框。
        pcall(frame.EnableMouse, frame, true)
        Widget:HoverWatch(frame,
            function() if bar.hoverOnly then pcall(frame.SetAlpha, frame, 1) end end,
            function() if bar.hoverOnly then pcall(frame.SetAlpha, frame, HOVER_IDLE_ALPHA) end end)
    end

    -- 立刻按当前鼠标位置定一次：鼠标本来就在条上时不会触发 OnEnter，否则一进来是半透明的。
    local ok, inside = pcall(frame.IsMouseOver, frame)
    local over = ok and Secrets.Bool(inside, false)
    pcall(frame.SetAlpha, frame, over and 1 or HOVER_IDLE_ALPHA)
end

--- 姿态条的可见性：宠物对战 / 载具 / 超控条时交给暴雪自己藏（它不比我们少算一步）。
local STANCE_VISIBILITY = "[petbattle][overridebar][vehicleui][possessbar] hide; show"

--- 当前职业有几个形态（德鲁伊 3、死骑 3、战士 3、盗贼 1、猎人/牧师 0…）。
--- 0 就是"这个职业没有姿态条"：我们的条不显示，暴雪的壳也放开（它本来就是空的）。
local function StanceFormCount()
    -- 本客户端只有复数那个全局（`GetNumShapeshiftForms`，实机返回 3）；单数名不存在。
    if not GetNumShapeshiftForms then return 0 end
    local ok, count = pcall(GetNumShapeshiftForms)
    if ok and type(count) == "number" then return count end
    return 0
end

--- 把暴雪 StanceButton1..10 收养进我们自己的条。**幂等**：重复调用只是按当前尺寸重摆一遍，
--- 玩家关掉自绘条（Apply 里 ReleaseStance）后再打开时也走这里。
---
--- 为什么收养而不是像 ElvUI 那样自建 `StanceButtonTemplate` 按钮：ElvUI 的做法在正式服没问题
--- （模板的 OnClick 调 `StanceBar:Select` → `CastShapeshiftForm`），但它要求"我们自己建的受保护
--- 按钮点下去能施法"，这恰恰是本客户端踩过坑的地方（自绘 `type="pet"` 按钮属性全对、点击没反应）。
--- 收养得到的是原生按钮 + 原生施法路径，和宠物条已经验证过的那条完全一致；Ellesmere 在本客户端
--- 也是这么做的（`EllesmereUIActionBars.lua:3136` "Stance bar: reuse StanceButton1-N"）。
local function AdoptStanceButtons(bar)
    local frame = bar.frame
    local size, spacing = ButtonSize(), Spacing()

    -- 先数一遍一共几个（暴雪固定建 10 个；缺哪个就到此为止，不要在中间留空洞）。
    local total = 0
    for i = 1, 10 do
        if not _G["StanceButton" .. i] then break end
        total = i
    end
    if total == 0 then return 0 end

    -- 只显示当前职业实际有的形态数（暴雪自己也会 SetShown，但它的那一步在战斗里可能被拒，
    -- 所以我们在**脱战**的这次排布里把状态写对：多出来的格子直接藏掉，不留一排空格子）。
    local forms = StanceFormCount()

    for i = 1, total do
        local btn = _G["StanceButton" .. i]
        bar.buttons[i] = btn
        pcall(btn.SetParent, btn, frame)
        pcall(btn.ClearAllPoints, btn)
        pcall(btn.SetSize, btn, size, size)
        pcall(btn.SetScale, btn, 1)
        -- 排布：**左对齐**，第 1 个形态贴条的左端，后面依次往右；藏起来的 N+1..10 排在更右边
        -- （会被 Hide，看不见也不响应鼠标），所以可见的那几格左端永远和 3 号条左边对齐。
        local step = size + spacing
        local offset = (i - 1) * step
        -- 竖直方向锚**底边**对齐条底边（不是中心）：这样即使条的尺寸没设上，这一排也和 3 号条同一行。
        pcall(btn.SetPoint, btn, "BOTTOMLEFT", frame, "BOTTOMLEFT", offset, 0)
        if forms >= 1 and i > forms then pcall(btn.Hide, btn) else pcall(btn.Show, btn) end
        SkinAdoptedButton(btn)
        -- 放开过一次（ReleaseStance 藏了边框）再收养回来时，边框要重新露出来。
        local border = Marked(btn, "adoptedBorder")
        if border then pcall(border.Show, border) end
    end
    -- pcall 的第一个参数是**函数**，`self` 还得显式再传一遍（漏了就是静默失败：实机表现为
    -- 这条条宽高停在 2×2、按钮全挂在框外 —— 反而是"按钮位置看着对、条的矩形是错的"）。
    -- 宽度只算**可见的**形态数：藏起来的格子挂在框外更右边，不用占地方。
    local visible = (forms >= 1) and forms or total
    pcall(frame.SetSize, frame, visible * size + math.max(visible - 1, 0) * spacing, size)
    return total
end

--- 姿态条本体（P5' 之后加的，形状照 BuildPetBar）。
local function BuildStanceBar(bar, frame, def)
    if AdoptStanceButtons(bar) == 0 then
        -- 一个按钮都没拿到：**别动暴雪那条**，让它照原生方式显示（宁可丑，不能没有）。
        pcall(frame.Hide, frame)
        return nil
    end

    local shell = _G.StanceBar
    if shell then
        pcall(shell.SetAlpha, shell, 0)
        pcall(shell.EnableMouse, shell, false)
        pcall(shell.EnableMouseMotion, shell, false)
        -- 事件不能卸载：图标 / 选中态 / 冷却都是它自己的 UpdateState 在刷（同宠物条）。
        -- 代价是它的 UpdateShownButtons 会对这几个已搬家的受保护按钮 SetShown，
        -- 日志里多几条 BLOCKED（只进日志、不弹窗、功能正常）。
    end

    bar.visibility = STANCE_VISIBILITY
    if RegisterStateDriver then
        pcall(RegisterStateDriver, frame, "visibility", STANCE_VISIBILITY)
    end
    PositionBar(bar)
    bar.page = 0
    return bar
end

--- 把收养的姿态按钮还给暴雪（外壳也放开）：玩家关掉自绘条时，原生姿态条要能照常显示。
local function ReleaseStance(bar)
    local shell = _G.StanceBar
    if bar then
        for i, btn in ipairs(bar.buttons) do
            -- 我们自己的边框子框体藏起来（按钮回到原生样子时不该多一圈）。
            local border = Marked(btn, "adoptedBorder")
            if border then pcall(border.Hide, border) end
            -- 容器优先用按钮自己记的（`ActionBarMixin:ActionBar_OnLoad` 写的 `actionButton.container`），
            -- 名字只是兜底：`StanceBarButtonContainer1..10`。
            local container = btn.container or _G["StanceBarButtonContainer" .. i]
            if container then
                pcall(btn.SetParent, btn, container)
                pcall(btn.ClearAllPoints, btn)
                pcall(btn.SetSize, btn, 30, 30)
                pcall(btn.SetPoint, btn, "CENTER", container, "CENTER", 0, 0)
            end
        end
    end
    if shell then
        pcall(shell.SetAlpha, shell, 1)
        pcall(shell.EnableMouse, shell, true)
        pcall(shell.EnableMouseMotion, shell, true)
    end
end

local function CreateBar(def)
    if buildFailure then return nil end

    local frame, template = NewFrame("Frame", "MonetUI" .. def.key, UIParent, CONTAINER_TEMPLATES,
        function(f) return type(f.WrapScript) == "function" end)
    if not frame then
        buildFailure = buildFailure or "header"
        return nil
    end
    -- 模板串里有 SecureHandlerStateTemplate 不等于安全处理器真的装上了（见 CONTAINER_TEMPLATES
    -- 的注释）：以 WrapScript 为准，否则要等状态驱动走到 WrapScript 才炸。
    if not template:find("SecureHandlerStateTemplate") or type(frame.WrapScript) ~= "function" then
        buildFailure = buildFailure or "header"
        return nil
    end

    pcall(frame.SetAttributeNoHandler, frame, "_onstate-page", M.secure.ON_STATE_PAGE)
    -- 初始页号也**必须在安全环境里**写：Lua 直接 SetAttribute 得到的是脏值，
    -- 客户端点击时拿它调 UseAction 就会判插件越权（见 Secure.lua 的 PAGE_CHILD 段长注释）。
    pcall(frame.Execute, frame, ("self:SetAttribute('actionpage', %d)"):format(def.page))

    -- 抬到暴雪动作条之上（ActionButton 52 / MultiBar* 3），点击才落到我们自己的按钮上；
    -- 暴雪那几条条被 Park 掉（MainActionBar alpha 0，其余换到常隐框体），点击不会落到它们身上。
    -- def.level 可以按条单独抬（宠物条要压过 1–8 号条）。
    pcall(frame.SetFrameLevel, frame, def.level or 60)

    local bar = {
        def        = def,
        index      = def.index,
        frame      = frame,
        buttons    = {},
        visibility = def.paged and M.secure.VISIBILITY_MAIN or M.secure.VISIBILITY_OTHER,
    }

    -- **宠物条只能收养暴雪的 PetActionButton1..10**：实测这个客户端没有通用安全按钮的
    -- `type="pet"`（属性全对、层级也压过所有条，点了照样没反应，而且没有任何拦截 —— 是
    -- 客户端根本不处理这个 type）。收养之后施法 / 右键切自动施法 / 冷却 / 自动施法提示全原生。
    -- 代价：SetParent/SetSize 会把受保护按钮标脏，暴雪自己的 SetShown 会被拒（日志里 10 条
    -- BLOCKED，只进日志、不弹窗）。功能优先，接受这个代价。
    if def.pet then
        return M.petbar.BuildPetBar(bar, frame, def)
    end

    -- 姿态条同理：收养暴雪 StanceButton1..10（见 BuildStanceBar 的注释）。
    if def.stance then
        return BuildStanceBar(bar, frame, def)
    end

    for index = 1, (def.count or BUTTONS_PER_BAR) do
        local button = BuildButton(bar, index)
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
        pcall(RegisterStateDriver, frame, "page", def.paged and M.secure.FULL_PAGE or tostring(def.page))
    end

    LayoutBar(bar)
    PositionBar(bar)
    -- 按钮建好、位置定好后，把当前页下发给它们一次（片段跑，安全环境里写 action）
    M.secure.PushPageToChildren(bar)
    M.secure.PushSecureInit(bar, "action")
    M.dragdrop.EnsureDropCatcher(bar)
    bar.page = tonumber(frame:GetAttribute("actionpage")) or def.page
    RefreshBar(bar)
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

-- 暴雪的下车按钮长在主菜单条上，而那条已经被我们藏起来了，所以自己做一个：飞行途中请求提前
-- 落地，坐骑 / 载具里则直接下车（点击脚本参考同类插件）。

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

    -- pcall returns (ok, result): capturing only one value would leave `button` a boolean, and button:SetPoint below would index it.
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
    Skin:CropIcon(icon, CROP, 1 - CROP, CROP, 1 - CROP)

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
    pcall(frame.SetAttribute, frame, "_onstate-exit", M.secure.EXIT_SNIPPET)
    pcall(RegisterStateDriver, frame, "exit", "[canexitvehicle]c;[mounted]m;n")
    if not CanExitVehicle() then frame:Hide() end

    Anchor(frame, StoredPosition({ point = "CENTER", relativeTo = "UIParent",
        relativePoint = "CENTER", x = 0, y = -300 }, "BarExit"),
        { point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", x = 0, y = -300 })

    leaveVehicle = { frame = frame, button = button, icon = icon }
    return leaveVehicle
end

-- 这两条条不重画：只把暴雪的动作条从被藏起来的父框体里搬出来、缩放到和自绘按钮一样大、放到
-- 存档里的位置；图标更新、自动施法光圈、当前形态环、冷却全都还是暴雪自己的代码在管，永远不会失同步。

--- 取 def.containers 里第一个真正存在的框体（优先最外层）。
local function ResolveContainer(def)
    for _, name in ipairs(def.containers) do
        local frame = _G[name]
        if frame then return frame, name end
    end
    return nil
end

--- 零售 12.x 的姿态条 / 宠物条外面套了一层编辑模式管理的框体（StanceBar / PetActionBar）：
--- 直接搬它会被暴雪的布局改回去，还会把框体弄成"强污染"（暴雪自己再动它就报
--- ADDON_ACTION_BLOCKED 一片刷屏）。真正装按钮的是里面的按钮容器
--- （StanceBarButtonContainer1…），它们不受布局管：搬容器，外层框体留在原地（它没有美术）。
---
--- 注意每个容器**只装一个按钮**（1..10 号各一个），而且都锚在外层壳的 BOTTOMLEFT 上、按 32
--- 递增排开。所以不能只搬 1 号容器 —— 2..10 号还挂在壳的老位置上，表现就是"宠物条 /
--- 姿态条只显示一个按钮"。这里把整串容器都取出来，由调用方按 1 号的位置重新排。

--- 把 1 号之外的容器串到 1 号旁边：宠物条右对齐、往左长，姿态条往右长。
---
--- 间距要换算成**壳的虚拟坐标系**里的单位：外面看着 30（自绘按钮 28 + 间隙 2），而这一串容器
--- 带着 0.9333 的缩放，真实落点 = 虚拟 × scale，所以虚拟步距 = 30 / scale ≈ 32.14。
--- 写死 32（暴雪自己的值）会让 10 个按钮累计右偏 1.2 个单位 —— 肉眼能看出来。

--- 受保护写入的"签名"：只有这些值变了，才值得去碰暴雪的受保护框体。

--- 已经就位了吗：签名一致 + 实测锚点/步距/缩放都没被暴雪动过。
--- 这里只读不写（GetPoint / GetScale），所以每来一个宠物事件都问一遍也不产生任何 BLOCKED。


--- 放开接管：交还给暴雪原来的大小。位置留给下一次暴雪的排版去纠正，因为插件不能替暴雪写它自己的布局。
-- 缩放归 1：交还后的宠物条不再是自绘按钮的大小，像素环的点距要按未缩放重算（见 SyncPetGlow）。
local function ReleaseBar(entry)
    local bar = entry and entry.frame
    if not bar then return end
    pcall(bar.SetScale, bar, 1)
    entry.scale = 1
    -- 接管时把壳的鼠标关掉了（它 1303×1193，会把屏幕中间整块吃掉），交还时要开回来，
    -- 否则退回暴雪宠物条之后那圈按钮点不动。
    if not InCombatLockdown() then
        pcall(bar.EnableMouse, bar, true)
    end
end

-- 暴雪那排按钮还在（只是藏起来了），玩家的按键其实按的是它们。这里把同一批键**改道**到
-- 暴雪自己的动作命令上（"ACTIONBUTTON1"、"MULTIACTIONBAR1BUTTON1"……）：
--
-- 为什么不用 SetOverrideBindingClick（"按下去就点我们这个按钮"）：
-- 客户端的 SecureActionButton_OnClick 里 clickAction = (down and useOnKeyDown) or
-- (not down and not useOnKeyDown) —— 按键触发的"点击"没有 down 事件，而零售默认
-- ActionButtonUseKeyDown = 1，于是 clickAction 永远是 false，**按下去什么也不会发生**。
-- 走动作命令则和暴雪自己的绑定完全一致（ActionButtonDown → down = true → 动作触发）。
--
-- 键名从暴雪绑定名（ACTIONBUTTON<i>、MULTIACTIONBAR1BUTTON<i>…）反查；
-- 玩家没给这一格绑键就不接管，战斗中只打标记，PLAYER_REGEN_ENABLED 后再补。
local function ReassignBindings()
    if Locked() then
        -- 战斗中写不了 override binding：排队到脱战（ns:AfterCombat）。
        ns:AfterCombat("actionbars-bindings", ReassignBindings)
        return
    end
    if not (SetOverrideBinding and ClearOverrideBindings) then return end

    for _, bar in pairs(bars) do
        -- 宠物条 `/` 姿态条都不走 override binding：它们的键位本来就绑在暴雪的动作命令上
        -- （BONUSACTIONBUTTON1..10 / SHAPESHIFTBUTTON1..10），再包一层会让客户端把整条
        -- `PetActionBar:Show → UpdateVisibility → 重排` 的链记成我们的（taint.log 里 19:12:41
        -- 那一串：BONUSACTIONBUTTON2 → PetActionButtonDown → PetActionBar:Show →
        -- ClearAllPointsBase BLOCKED）。鼠标点击用我们收养的按钮，键盘交给暴雪。
        if not IsAdopted(bar) then
            pcall(ClearOverrideBindings, bar.frame)
            for _, button in ipairs(bar.buttons) do
                local key = BindingFor(button.bindName)
                if key then
                    -- bindName 就是暴雪的动作命令名（ACTIONBUTTON1 / MULTIACTIONBAR1BUTTON1…）
                    pcall(SetOverrideBinding, bar.frame, false, key, button.bindName)
                end
            end
        end
    end
end

local function ClearBindings()
    if Locked() then
        -- 旧实现借 bindingsDirty 让 PLAYER_REGEN_ENABLED 重跑 ReassignBindings，保持一致。
        ns:AfterCombat("actionbars-bindings", ReassignBindings)
        return
    end
    if not ClearOverrideBindings then return end
    for _, bar in pairs(bars) do
        if not IsAdopted(bar) then
            pcall(ClearOverrideBindings, bar.frame)
        end
    end
end

-- 宠物条"自动施法"的状态事件：像素环不受战斗锁影响
-- （往按钮上加几个方块不用搬受保护的框体），开关自动施法在战斗中也得立刻跟上。
local PET_GLOW_EVENTS = {
    "PET_BAR_UPDATE", "PET_BAR_UPDATE_USABLE", "PET_UI_UPDATE", "UNIT_PET",
}

-- 槽位 / 页号变了要重画图标：客户端在这些事件里换槽。
local SLOT_EVENTS = {
    "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED",
    "UPDATE_SHAPESHIFT_FORM", "UPDATE_VEHICLE_ACTIONBAR", "PLAYER_ENTERING_WORLD",
    "SPELLS_CHANGED", "ACTIONBAR_UPDATE_USABLE",
    -- 宠物条（自绘）：图标/槽位变化
    "PET_BAR_UPDATE", "PET_BAR_UPDATE_USABLE", "PET_UI_UPDATE", "UNIT_PET",
}

-- 冷却事件单独一条轻量路径：只重画冷却框，不重扫 96 个按钮的图标/文字。
local COOLDOWN_EVENTS = {
    "ACTIONBAR_UPDATE_COOLDOWN", "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_CHARGES",
    "SPELL_UPDATE_ICON", "ACTIONBAR_UPDATE_USABLE", "SPELLS_CHANGED",
    -- 宠物技能冷却
    "PET_BAR_UPDATE_COOLDOWN", "PET_BAR_UPDATE",
}

function M:RegisterEvents()
    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        M:Apply()
    end)

    -- 战斗中被挡的绑定 / 收养 / 布局 / Apply 各自入口已经 ns:AfterCombat 排队，
    -- 不再单独注册 PLAYER_REGEN_ENABLED（Core 的统一排空先于这里执行）。

    EventBus:Register("UPDATE_BINDINGS", function()
        ReassignBindings()
        M:UpdateHotkeys()
        M:UpdateAll()
    end)

    EventBus:Register("CVAR_UPDATE", function(_, name)
        if name == "ActionButtonUseKeyDown" then
            M:SetClickOptions()
            M:UpdateAll()
        end
    end)

    for _, event in ipairs(PET_GLOW_EVENTS) do
        EventBus:Register(event, function() M.petbar.SyncPetGlowNow() end)
    end

    for _, event in ipairs(SLOT_EVENTS) do
        EventBus:Register(event, function() M:UpdateAll() end)
    end

    for _, event in ipairs(COOLDOWN_EVENTS) do
        EventBus:Register(event, function() M:UpdateCooldowns() end)
    end

    EventBus:Register("MONETUI_THEME_CHANGED", function() M:UpdateAll() end)
    EventBus:Register("MONETUI_RESTRICTION_CHANGED", function() M:UpdateAll() end)
end

--- 只重画冷却（战斗中也要跑：冷却框是我们自己的贴图，不受保护）。
function M:UpdateCooldowns()
    for _, bar in pairs(bars) do
        -- 收养来的按钮（宠物 / 姿态）冷却归暴雪：我们的槽位公式算出来是负的，
        -- GetActionCooldown 读不到 → 只剩 Clear()，等于把原生冷却圈擦掉。
        if not IsAdopted(bar) then
            for index, button in ipairs(bar.buttons) do
                PaintCooldown(button, SlotOf(button, bar, index))
            end
        end
    end
end

--- 刷新所有按钮的外观配置；冷却由客户端驱动，图标 / 数字 / 宏名我们自己读。
function M:UpdateAll()
    -- 这里**不挡战斗**：图标 / 键位文字 / 冷却全是我们自己的贴图，读的也是非机密 API，
    -- 战斗中一样要刷（载具换页、冷却起转都在战斗里发生）。真正的受保护操作在
    -- RefreshLayout（挪框体）里，那里才看 Locked()。

    for _, bar in pairs(bars) do
        RefreshBar(bar)
    end

    RefreshRings()

    if leaveVehicle and not InCombatLockdown() then
        -- 这是个 SecureHandler 框体：战斗中 SetSize / SetPoint 会被客户端拒
        -- （日志里 MonetUIActionBarExit:SetSize()）。改尺寸留到脱战后由 UpdateAll 补。
        local size = ButtonSize()
        leaveVehicle.frame:SetSize(size + 2 * BORDER, size + 2 * BORDER)
        Anchor(leaveVehicle.frame, StoredPosition({ point = "CENTER", relativeTo = "UIParent",
            relativePoint = "CENTER", x = 0, y = -300 }, "BarExit"),
            { point = "CENTER", relativeTo = "UIParent", relativePoint = "CENTER", x = 0, y = -300 })
    end
end

--- 热键文字：跟着玩家的按键设置走（换键、改设置都要重画）。
--- 按下 / 抬起施法的偏好变了：把所有按钮的 useOnKeyDown 重写一遍（属性写入本身不越权）。
function M:SetClickOptions()
    for _, bar in pairs(bars) do
        -- 收养来的按钮（宠物 / 姿态）身上有暴雪写的 `button.bar = PetActionBar / StanceBar`：
        -- 我们的 SetUseOnKeyDown 会拿它当"我们自己的条"去 Execute 片段（那条根本没有这个片段），
        -- 而且它的按下/抬起由暴雪模板决定，不归我们改。
        if not IsAdopted(bar) then
            for _, button in ipairs(bar.buttons) do
                M.secure.SetUseOnKeyDown(button)
            end
        end
    end
end

function M:UpdateHotkeys()
    for _, bar in pairs(bars) do
        if not IsAdopted(bar) then
            for _, button in ipairs(bar.buttons) do
                SetHotkey(button)
            end
        end
    end
end

--- 布局或尺寸改过之后重新摆一遍。
function M:RefreshLayout()
    if Locked() then
        -- 按钮本体是受保护的安全模板：战斗中挪不动（SecureActionButtonTemplate），
        -- 硬来会被客户端拒绝。排队到脱战补做（ns:AfterCombat）。
        ns:AfterCombat("actionbars-layout", function() M:RefreshLayout() end)
        return
    end
    -- 条数可能刚改过：姿态条的默认锚点跟着"最高那条"走，再统一排布。
    SyncStanceAnchor()
    for _, bar in pairs(bars) do
        -- 姿态条收养的按钮是**从右端往左**排的（见 AdoptStanceButtons）：LayoutBar 那套左上是
        -- 给自绘按钮的，用在这条上会把可见的 1..N 格顶到整条最左边、离 3 号条一大段空隙。
        if bar.def and bar.def.stance then
            AdoptStanceButtons(bar)
        else
            LayoutBar(bar)
        end
        PositionBar(bar)
    end
    self:UpdateAll()
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

    if not ActionBar then
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
        -- 战斗中建不了条：排队到脱战（ns:AfterCombat）。
        ns:AfterCombat("actionbars-apply", function() M:Apply() end)
        return
    end

    self:Build()

    local db = Config()
    local own = db.ownBars ~= false and M.ready
    M.own = own

    local count = BarCount()
    -- 姿态条默认锚点先跟着当前条数算好，再走下面的逐条分支（见 SyncStanceAnchor）。
    SyncStanceAnchor()
    for _, def in ipairs(BAR_DEFS) do
        local bar = bars[def.key]
        if bar then
            if def.pet then
                -- 宠物条不走"第几条开着"那套：它的显隐只由 [pet] 状态驱动决定
                -- （CreateBar 里已注册）。自绘动作条关掉时直接藏起来，暴雪那条保持原样。
                if not own then
                    pcall(bar.frame.Hide, bar.frame)
                else
                    SetupHoverOnly(bar, def.hover and Config().petHover ~= false)
                end
            elseif def.stance then
                -- 姿态条同理，但两条退路都要把收养的按钮还给暴雪 —— 否则它们留在我们藏起来的
                -- 框体里，原生姿态条就成了一条空壳（玩家直接没法变形态）：
                --   ① 玩家关掉自绘动作条；② 这个职业根本没有形态（NumShapeshiftForms = 0）。
                if own and StanceFormCount() > 0 then
                    AdoptStanceButtons(bar)
                    -- 条数刚变过也可能走到这里（面板改「显示动作条数量」只调 Apply）：
                    -- 锚点由 SyncStanceAnchor 重算，必须再摆一次，否则姿态条还停在旧位置、
                    -- 和长出来的 Bar4 叠在一起。
                    PositionBar(bar)
                    SetBarShown(bar, true)
                    -- 和宠物条同一套"平时 0.3 / 悬停 1"（玩家 2026-10-26 要求，见 SetupHoverOnly）。
                    SetupHoverOnly(bar, def.hover and Config().stanceHover ~= false)
                else
                    SetBarShown(bar, false)
                    ReleaseStance(bar)
                end
            else
                SetBarShown(bar, own and def.index <= count)
            end
        end
    end
    WatchPages(own)

    if own then
        if not leaveVehicle then leaveVehicle = CreateLeaveVehicle() end
    else
        for _, entry in pairs(adopted) do
            ReleaseBar(entry)
        end
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
    if db.hideBagBar ~= false then
        M.blizzard.Park("BagsBar")
        M.blizzard.Park("MainMenuBarBackpackButton")
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
    self:UpdateHotkeys()

    -- 宠物条的自动施法提示：自绘条开着是动画环，关着是静态环（这条路径不依赖 AdoptAll）。
    M.petbar.SyncPetGlowNow()
end

function M:SetEnabled(enabled)
    if enabled then
        self:Apply()
    else
        M.own = false
        WatchPages(false)
        for _, bar in pairs(bars) do
            if bar.def and bar.def.stance then ReleaseStance(bar) end
            pcall(bar.frame.Hide, bar.frame)
        end
        if leaveVehicle then pcall(leaveVehicle.frame.Hide, leaveVehicle.frame) end
        for _, entry in pairs(adopted) do
            ReleaseBar(entry)
        end
        ClearBindings()
        self:RestoreBlizzard()
        M.petbar.TeardownPetGlow()
    end
end

function M:Initialize()
    self:Build()
    self:Apply()
    self:RegisterEvents()
end

-- ---------------------------------------------------------------------------
-- P5' 拆分共享件（Modules/ActionBars/PetBar.lua）
--
-- 那边用**同名别名**接走（`local ButtonSize = M.ButtonSize`），所以搬过去的三段函数体
-- 一行都不用改。这里是它们唯一的定义处，别再在别处复制一份。
-- ---------------------------------------------------------------------------
M.ButtonSize         = ButtonSize
M.Spacing            = Spacing
M.PositionBar        = PositionBar
M.SkinAdoptedButton  = SkinAdoptedButton
M.ResolveContainer   = ResolveContainer
M.bars               = bars
M.adopted            = adopted
M.PET_DEF            = PET_DEF

ns:Register("ActionBars", M)
