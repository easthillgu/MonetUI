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

--- 收养暴雪宠物/姿态条的开关。**保持 false，而且现在连"收起"都不做** ——
--- 这两个受保护的条我们**一个字段都不写、一个方法都不调**，完全交给暴雪：
--- 它就按自己的默认位置/大小显示，玩家能用。
--- 为什么连 EnableMouse(false) 都不能留：实测这一下也会让 PetActionBar 的
--- flyoutDirection 变脏，之后暴雪自己的 PetActionButton*:SetShown /
--- PetActionBar:ClearAllPoints 战斗中被拒（taint.log: "tainted from MonetUI"）。
--- 想要"挪到我们的位置 + 自绘外观"，只能像 Bar1..8 那样建自己的安全按钮（宠物 type="pet"）。
local ADOPT_BLIZZARD_BARS = false

--- 收养之后要不要再排版（SetScale / SetPoint 到我们的位置）。
--- **保持 false**：排版写的每一个 SetScale/SetPoint 都会把这些受保护框标脏。
--- 只关外壳鼠标（那个壳 1303×1193，会把屏幕中间的点击全吃掉）—— 那是必须的。
--- 想让它长得跟自绘条一致、还落在我们的位置：得像 Bar1..8 那样建自己的安全按钮
--- （宠物 type="pet"），见 AGENTS 待办。
local STYLE_ADOPTED_BARS = false

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
    -- 按钮）。位置默认放在 1 号条左侧 —— 原来放 3 号条上方会和 4 号条整条重叠（实测 4 号条的
    -- 按钮在同一层级更靠前，把点击全吃掉了）。层级 66：高于 1–8 号条的 60/61，低于接住器 70。
    { key = "BarPet", index = 9, page = 0, count = 10, pet = true, bind = "BONUSACTIONBUTTON",
      level = 66,
      point = "BOTTOMRIGHT", relativeTo = "Bar1", relativePoint = "BOTTOMLEFT", x = -8, y = 0 },
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

-- 8 条动作条：暴雪那几条只做 alpha 0（见 Park），点击板盖住它们看不见的裸按钮；
-- 显示与施法全部由我们自己的按钮承担（槽位由安全片段写，见 PAGE_CHILD 那段）。
local ACTION_BAR_FRAMES = {
    "MainMenuBar", "MainActionBar",
    "MultiBarBottomLeft", "MultiBarBottomRight",
    "MultiBarRight", "MultiBarLeft", "MultiBar5", "MultiBar6", "MultiBar7",
    "OverrideActionBar", "PossessActionBar",
}

-- 右下角的背包条 / 背包按钮。
local BAG_BAR_FRAMES = {
    "BagsBar", "MainMenuBarBackpackButton",
}

-- 收起暴雪那几条动作条的做法（照 Ellesmere 在 12.x 上验证过的，参考插件
-- EllesmereUIActionBars.lua:1004-1036 与 :1308-1319）：
--   * MainActionBar 留在原地（宠物对战要还原微型菜单）：只 alpha 0 + 收掉两端装饰；
--   * 其余条 SetParent 到一个常隐框体 —— 不经过 Hide()/SetShown() 那条受保护 setter，
--     也就不会在战斗转换时被记成 ADDON_ACTION_BLOCKED；
--   * 按钮一律 UnregisterAllEvents + SetAttributeNoHandler("statehidden", true)：不自己 Hide，
--     暴雪自己的 UpdateShownButtons 读到这个属性就会 SetShown(false)。这一步很关键：以前
--     我们自己 Hide/SetShown，战斗转换时暴雪的 SetShownBase 就被拒（日志里那一串
--     MultiBarBottomLeftButton1:SetShown()）。
--   * OverrideActionBar / PossessActionBar 不碰：搬它们会把受保护子树弄脏、阻断
--     BeginActionBarTransition（Ellesmere :1595 的教训）。载具时让暴雪自己显示。
local hiddenParent

local function HiddenParent()
    if not hiddenParent then
        hiddenParent = CreateFrame("Frame", "MonetUIActionBarDump", UIParent)
        hiddenParent:SetAllPoints(UIParent)
        hiddenParent:Hide()
    end
    return hiddenParent
end


--- 让暴雪的按钮收不到鼠标：**一个属性都不写**，只关鼠标。
---
--- 以前这里是 UnregisterAllEvents + SetAttributeNoHandler("statehidden", true)，让它自己
--- SetShown(false)。实机 taint.log 证明这条路会反噬：
---   SetAttributeNoHandler 把受保护按钮标脏 → 暴雪自己之后 UpdateShownButtons 的
---   SetShown 被拒（"blocked in combat because of taint from MonetUI"）→ 按钮留在"显示"
---   状态 → alpha 0 看不见但**照样收 OnEnter** → ActionButton.lua:1391 OnEnter →
---   UpdateAction → SetAttribute/ClearAttribute 再一次被拒 → 每次鼠标扫过都刷一屏。
--- 关鼠标不是受保护操作，不写任何字段，也不会让按钮卡在错误状态。
local function KillMouse(frame, depth)
    if not frame then return end
    pcall(frame.EnableMouse, frame, false)
    if frame.EnableMouseClicks then pcall(frame.EnableMouseClicks, frame, false) end
    if frame.EnableMouseMotion then pcall(frame.EnableMouseMotion, frame, false) end
    if (depth or 0) <= 0 then return end
    local ok, children = pcall(function() return { frame:GetChildren() } end)
    if not ok or not children then return end
    for i = 1, #children do KillMouse(children[i], depth - 1) end
end

--- 收起一条暴雪动作条时用在它整棵子树上：按钮 + 按钮容器都不能收鼠标。
local function QuietHideButton(button)
    if not button then return end
    pcall(button.UnregisterAllEvents, button)
    KillMouse(button, 1)
end

-- 1 号条会自己翻页（载具、覆盖、变形、额外动作条都用它），所以挂一个状态驱动；换页片段跑在
-- 客户端内部：`newstate` 是新页号，`self` 是头框体。片段在**安全环境**里写 actionpage，
-- 再 ChildUpdate 让每个按钮的安全子片段重算自己的 "action"（槽位只能这么写，见 PAGE_CHILD 那段）。

local ON_STATE_PAGE = [[
    local page = tonumber(newstate) or 1
    self:SetAttribute("actionpage", page)
    self:ChildUpdate("mui-page", page)
]]

-- 1 号条：宠物对战时暴雪会换成宠物技能，这里跟着藏。
local VISIBILITY_MAIN = "[petbattle] hide; show"

-- 其余几条条：载具 / 覆盖 / 附身 / 变形时让位给 1 号条。
local VISIBILITY_OTHER =
    "[petbattle][overridebar][vehicleui][possessbar][shapeshift] hide; show"

-- 状态页 → 槽位页的映射（客户端实测量：载具 16 / 覆盖 18 / 变形 17 / 奖励条 7..11）。
local FULL_PAGE = "[bar:6]6;[bar:5]5;[bar:4]4;[bar:3]3;[bar:2]2;[possessbar]16;" ..
                  "[overridebar]18;[shapeshift]17;[vehicleui]16;[bonusbar:5]11;" ..
                  "[bonusbar:4]10;[bonusbar:3]9;[bonusbar:2]8;[bonusbar:1]7;1"

-- 载具 / 飞行点的"提前下马"按钮：片段跑在客户端内部，只有能下车（或在飞行路线上）才显示；UnitOnTaxi 万一不在受限环境里，前半句仍然可用。
local EXIT_SNIPPET = [[
    if CanExitVehicle() or (UnitOnTaxi and UnitOnTaxi("player")) then
        self:Show()
    else
        self:Hide()
    end
]]

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
-- 最后只剩一条稳的：**留在原地，只 SetAlpha(0) + 关鼠标**（见 Park）。

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

--- 1 号条自带的翻页箭头（ActionBarPageNumber，frameLevel 100，压在我们上面）：
--- 条 alpha 0 之后它看不见，但仍然是可点的普通按钮。只关鼠标，不 Hide()。
--- 这块**不是**受保护的框体（实测 IsProtected=false），所以关鼠标不会弄脏谁；
--- 又因为它 level 100 比我们的条（61/66）高，没法靠层级盖住，只能关掉。
local function KillPagerMouse(bar)
    local pager = bar and bar.ActionBarPageNumber
    if not pager then return end
    local function killOne(f)
        if not f or type(f.EnableMouse) ~= "function" then return end
        pcall(f.EnableMouse, f, false)
        if f.EnableMouseClicks then pcall(f.EnableMouseClicks, f, false) end
        if f.EnableMouseMotion then pcall(f.EnableMouseMotion, f, false) end
    end
    killOne(pager)
    killOne(pager.UpButton)
    killOne(pager.DownButton)
    if type(pager.GetChildren) == "function" then
        for i = 1, pager:GetNumChildren() do
            killOne((select(i, pager:GetChildren())))
        end
    end
end

--- 收起一条暴雪动作条：**只 SetAlpha(0)**，别的一个都不碰。
---
--- 走过的弯路，留在这里免得再踩：
---   * Hide() / SetShown()：暴雪的显示状态走受保护的 SetShownBase / UpdateShownButtons，
---     Hide 一次它下一拍就 SetShown(true) 回来（这条路不经过 Lua 的 Show，hook 抓不到）——
---     屏幕上那三排"发白"的 45×45 按钮一直是暴雪的，我们的 28×28 只在下面露一条边。
---   * SetParent 到隐藏框体：编辑模式（UpdateRightActionBarPositions）按父级几何算条的缩放，
---     算出来是 0，直接炸 "MultiBarRight:SetScale(): Scale must be > 0"。
---   * 关它按钮的鼠标（EnableMouse）：那些按钮/容器是**受保护**框体，碰一下就被弄脏，
---     之后暴雪自己更新它们就变成 ADDON_ACTION_FORBIDDEN，每次点击动作条都弹
---     "MonetUI 已被禁用，因为该功能只对暴雪的 UI 开放"。
--- 现在：普通动作条换到常隐框体；**MainActionBar 例外，必须留在暴雪的父链上**（见下）。
--- 被收起的暴雪条清单 + 驱动：暴雪会在变形 / 载具 / 召唤宠物 / 翻页时重新 Show 它们，
--- 我们每 0.5 秒把 alpha 压回 0（顺带再关一次翻页箭头）。
--- **为什么不用 `hooksecurefunc(frame, "Show")`**：secure hook 插在暴雪调用链中间，
--- 我们的代码一跑，同一条链后面暴雪的安全调用（Show → UpdateVisibility →
--- UpdateShownButtons → SetShown）就会整片被拒 —— taint.log 里宠物条那一串
--- `PetActionButton*:SetShown()` 正是这么来的。定时驱动属于独立的一次执行，不夹在链里。
local parkedList = {}
local parkDriver

local function KeepParked()
    -- **战斗里什么都不做。** 受保护的条/按钮上，战斗中写 alpha / 鼠标本身就是受限制的；
    -- 我们那一下会成为"暴雪后续安全调用被拒"的污染源（taint.log 里宠物条
    -- PetActionButton*:SetShown / PetActionBar:ClearAllPointsBase 那一串就是这么来的）。
    -- 脱战后（PLAYER_REGEN_ENABLED 会立刻调一次）再收拾。
    if InCombatLockdown() then return end
    for i = 1, #parkedList do
        local frame = parkedList[i]
        if Marked(frame, "parked") then
            if Marked(frame, "hidden") then
                -- ParkBag 那条路：暴雪把它 Show 回来就再藏一次。
                if frame:IsShown() then pcall(frame.Hide, frame) end
            elseif frame:GetAlpha() > 0 then
                pcall(frame.SetAlpha, frame, 0)
                KillPagerMouse(frame)
            end
        end
    end
end

local function ParkWatch(frame)
    for i = 1, #parkedList do
        if parkedList[i] == frame then return end
    end
    parkedList[#parkedList + 1] = frame

    if parkDriver then return end
    parkDriver = CreateFrame("Frame")
    local acc = 0
    parkDriver:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 0.5 then return end
        acc = 0
        KeepParked()
    end)
end

local function Park(name)
    local frame = _G[name]
    if not frame or Marked(frame, "parked") then return false end
    Mark(frame, "parked", true)
    Mark(frame, "alpha", frame:GetAlpha())
    Mark(frame, "parent", frame:GetParent())

    -- **一律留在暴雪的父链上，只做"看不见 + 不吃鼠标"。**
    --
    -- 踩过的坑（都有实机证据，别再试）：
    --   * **SetParent 到常隐框体**：被插件换过父的受保护框，之后暴雪自己的位置计算
    --     （EditModeManagerFrame:UpdateBottomActionBarPositions → ClearAllPoints/SetPoint，
    --      EditModeSystemTemplates.lua:148/154）全被判 ADDON_ACTION_BLOCKED。
    --     这个拒绝会**在整条调用链上传播**：一条被写过字段的条跑 OnEvent
    --     （PLAYER_REGEN_* → UpdateVisibility），链里对**别的**条的安全调用也一起被拒，
    --     于是"一进战斗就弹：插件导致界面行为失效"。
    --     实测对照：MainActionBar 不换父那一版 → issecurevariable 全 clean；
    --     换过父的 7 条 → flyoutDirection / popupDirection 被写成脏值，越传越广。
    --   * Hide()/SetShown()：暴雪下一拍 SetShownBase 把它盖回来。
    --   * 往这些框上写任何字段：都算污染（见 Core 里 ns:Mark 的注释）。
    --
    -- 所以只剩这一套（原本只用在 MainActionBar 上）：alpha 0 + 关鼠标（含翻页箭头）
    -- + 每次 Show 后把 alpha 压回去。位置让暴雪随便排 —— 反正看不见，
    -- 换来的是它的安全重排不再被拒。
    pcall(frame.SetAlpha, frame, 0)
    -- 整棵子树都关鼠标：alpha 0 只是看不见，按钮/容器照样收 OnEnter，而一进战斗
    -- 暴雪按钮的 OnEnter（ActionButton.lua:1391）会 UpdateAction → SetAttribute，
    -- 那一下会被判 BLOCKED（taint.log 里 335 条全是这一类）。
    KillMouse(frame, 2)
    KillPagerMouse(frame)

    -- 变形 / 载具 / 翻页 / 骑乘 / 召唤宠物时，暴雪会重新 Show 这些条。**不能用
    -- hooksecurefunc(frame, "Show") 在里面压 alpha**：secure hook 是插在暴雪调用链中间的，
    -- 我们的代码一跑，这条链后续的暴雪安全调用（Show → UpdateVisibility → UpdateShownButtons
    -- → SetShown）就全被判 BLOCKED —— taint.log 里宠物条那一串 PetActionButton*:SetShown
    -- 就是这么来的。改成我们自己的驱动帧定时把 alpha 压回去：那属于独立的一次执行，
    -- 不夹在暴雪的调用链里。
    ParkWatch(frame)

    if frame.Selection and frame.Selection.SetAlpha then
        pcall(frame.Selection.SetAlpha, frame.Selection, 0)
    end

    if type(frame.actionButtons) == "table" then
        for _, button in pairs(frame.actionButtons) do
            pcall(button.UnregisterAllEvents, button)
            KillMouse(button, 1)
        end
    end
    return true
end


--- 背包条走 Hide：它的位置正好压在我们的小地图上，而小地图在 LOW 层，铺不了点击板
--- （板子必须在 MEDIUM 才盖得住暴雪的按钮，那样会连小地图一起挡掉）。
--- 背包条不是动作条那种"被 SetShownBase 复活"的框体，Hide 之后不会再自己冒出来。
local function ParkBag(name)
    local frame = _G[name]
    if not frame or Marked(frame, "parked") then return false end
    Mark(frame, "parked", true)
    Mark(frame, "hidden", true)
    Mark(frame, "alpha", frame:GetAlpha())
    -- 同样不挂 Show 后钩（会夹在暴雪调用链里）：交给 0.5s 的驱动再藏一次。
    ParkWatch(frame)
    pcall(frame.Hide, frame)
    return true
end

local function Restore(name)
    local frame = _G[name]
    if not frame or not Marked(frame, "parked") then return false end
    Mark(frame, "parked", nil)
    if Marked(frame, "hidden") then
        Mark(frame, "hidden", nil)
        pcall(frame.Show, frame)
        pcall(frame.SetAlpha, frame, Marked(frame, "alpha") or 1)
        return true
    end
    pcall(frame.SetAlpha, frame, Marked(frame, "alpha") or 1)
    pcall(frame.EnableMouse, frame, true)
    if frame.EnableMouseClicks then pcall(frame.EnableMouseClicks, frame, true) end
    if frame.EnableMouseMotion then pcall(frame.EnableMouseMotion, frame, true) end
    if Marked(frame, "leftManager") then
        frame.ignoreFramePositionManager = nil    -- 交还：让编辑模式的托管系统重新接管它
    end
    if Marked(frame, "parent") and Marked(frame, "parent") ~= hiddenParent then
        pcall(frame.SetParent, frame, Marked(frame, "parent"))
    end
    Mark(frame, "parent", nil)
    if type(frame.actionButtons) == "table" then
        for _, button in pairs(frame.actionButtons) do
            pcall(button.EnableMouse, button, true)
        end
    end
    return true
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

-- 翻页 / 槽位契约（照 Ellesmere 在同一客户端验证过的做法，实机已证实）：
--
--   RegisterStateDriver(bar, "page", 条件)
--     → 条的 _onstate-page 片段（**安全环境**里跑）写 actionpage + ChildUpdate("mui-page", page)
--     → 每个按钮的 _childupdate-mui-page 片段（**安全环境**里跑）写自己的 "action" 属性
--
-- **槽位只能由片段写。** 用 Lua 写 "action" / "actionpage" 得到的是脏值，客户端拿着它调
-- `UseAction`（受保护全局）就判插件越权 → ADDON_ACTION_FORBIDDEN「MonetUI 已被禁用，因为该功能
-- 只对暴雪的 UI 开放」。实机对照：同一个按钮，Lua 写 action → 每次点击必弹窗；改成片段写
-- action → 正常施法、零弹窗（UNIT_SPELLCAST_SUCCEEDED 收到 185358 奥术射击）。
--
-- 因此：按钮一律 SetID(0) + type=action + typerelease=actionrelease，槽位只来自 "action" 属性，
-- 而这个属性只有下面的片段会写。
local PAGE_CHILD = "mui-page"

--- 第 i 个按钮的翻页子片段：page → 槽位（12 个一组，和暴雪编号一致）。
local function PageChildSnippet(baseIndex)
    return ("local page = tonumber(message) or 1; self:SetAttribute('action', %d + (page - 1) * 12)")
        :format(baseIndex)
end

--- 给按钮装翻页子片段（幂等）：客户端换页时由 ChildUpdate 触发，跑在安全环境里。
local function InstallPageChild(button, index)
    if Marked(button, "pageChild") then return end
    Mark(button, "pageChild", true)
    pcall(button.SetAttributeNoHandler, button, "_childupdate-" .. PAGE_CHILD, PageChildSnippet(index))
end

-- ---------------------------------------------------------------------------
-- **点击用到的属性必须由安全片段写。**
--
-- 客户端点击安全按钮时，`SecureTemplates.lua` 会读 type / typerelease / checkselfcast /
-- useOnKeyDown 这些属性来决定怎么执行。**Lua 写进去的值是"脏值"**，客户端照用，但整条执行
-- 会被记成"被 MonetUI 污染"，于是同一次点击里暴雪自己的安全调用（例如 CastPetAction →
-- PetActionBar:UpdateShownButtons → SetShown、UseAction → MainActionBar:ClearAllPoints）
-- 全部被判 ADDON_ACTION_BLOCKED —— 实机 taint.log 的链就是：
--   OnActionButtonClick → PerformAction → handler → CastPetAction
--     → PetActionBar:UpdateShownButtons → PetActionButton10:SetShown()  BLOCKED -- TAINT-OK: 注释内引用的拦截记录（说明为何不直控 SetShown），非代码
--
-- 所以这些属性改由 ChildUpdate 片段在**安全环境**里写（和 action 同一个套路）。
local KIND_CHILD   = "mui-kind"
local KEYDOWN_CHILD = "mui-keydown"

local KIND_SNIPPET = [[
    self:SetAttribute("type", message)
    if message == "pet" then
        self:SetAttribute("typerelease", nil)
    else
        self:SetAttribute("typerelease", "actionrelease")
    end
    self:SetAttribute("checkselfcast", true)
    self:SetAttribute("checkfocuscast", true)
    self:SetAttribute("checkmouseovercast", true)
]]

local KEYDOWN_SNIPPET = [[
    self:SetAttribute("useOnKeyDown", message == "true")
]]

--- 给一个按钮装上"类型 / 按下抬起"两条子片段（幂等）。
local function InstallSecureInit(button)
    if Marked(button, "secureInit") then return end
    Mark(button, "secureInit", true)
    pcall(button.SetAttributeNoHandler, button, "_childupdate-" .. KIND_CHILD, KIND_SNIPPET)
    pcall(button.SetAttributeNoHandler, button, "_childupdate-" .. KEYDOWN_CHILD, KEYDOWN_SNIPPET)
end

--- 在安全环境里把类型 / useOnKeyDown 下发一遍（不经过 Lua 的脏值）。
local function PushSecureInit(bar, kind)
    local down = true
    if _G.GetCVarBool then
        local ok, value = pcall(_G.GetCVarBool, "ActionButtonUseKeyDown")
        if ok then down = value ~= false end
    end
    pcall(bar.frame.Execute, bar.frame,
        ("self:ChildUpdate(%q, %q)"):format(KIND_CHILD, kind or "action"))
    pcall(bar.frame.Execute, bar.frame,
        ("self:ChildUpdate(%q, %q)"):format(KEYDOWN_CHILD, tostring(down)))
end

--- 让条把当前页下发给所有按钮一次（片段跑，安全环境）。
local function PushPageToChildren(bar)
    local page = tonumber(bar.frame:GetAttribute("actionpage")) or bar.def.page
    pcall(bar.frame.Execute, bar.frame,
        ("self:ChildUpdate(%q, %d)"):format(PAGE_CHILD, page))
end

--- 这一格现在对应哪个槽位：优先用片段写的 "action" 属性（和客户端点击时算的完全一致）。
local function SlotOf(button, bar, index)
    if button and button.GetAttribute then
        local slot = button:GetAttribute("action")
        if type(slot) == "number" and slot > 0 then return slot end
    end
    return SlotFor(bar, index)
end

--- useOnKeyDown 跟着玩家的 cvar 走（按下 / 抬起施法）。
--- **必须走安全片段**：Lua 写进去的是脏值，客户端点一下就会被判越权，
--- 并连带把同一次点击里暴雪的安全调用全部拒掉（见 InstallSecureInit 的注释）。
local function SetUseOnKeyDown(button)
    local barFrame = button and button.bar
    if not barFrame or type(barFrame.Execute) ~= "function" then return end
    local down = true
    if _G.GetCVarBool then
        local ok, value = pcall(_G.GetCVarBool, "ActionButtonUseKeyDown")
        if ok then down = value ~= false end
    end
    pcall(barFrame.Execute, barFrame,
        ("self:ChildUpdate(%q, %q)"):format(KEYDOWN_CHILD, tostring(down)))
end

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

-- ---------------------------------------------------------------------------
-- 拖放接住器
--
-- 为什么需要它：把技能拖到格子上时，客户端是按"光标下最上层的可点框体"派发 OnReceiveDrag 的。
-- 我们的按钮虽然 level 61，但暴雪主条（MainActionBar，alpha 0、鼠标还开着、level 50）
-- 的矩形 786,45 562×45 正好压住 bar1 上半截和 bar2 整条 —— 实测 bar2 整排收不到
-- OnReceiveDrag（日志里只有 dstart，没有一次 receive），表现就是"bar2 放不进去、
-- 其它两排要对准一点"。
--
-- 解法：每条条上挂一只**只在手里拿着东西时才开鼠标**的透明接住器（level 70，压住整条），
-- 放下时按光标坐标**算**出目标格（不再依赖命中判定），再 PlaceAction。
-- 平时它关着鼠标，所以点击照旧落在我们自己的按钮上。
local dropCatchers = setmetatable({}, { __mode = "k" })

local function CursorUI()
    local x, y = GetCursorPosition()
    if not x then return nil end
    local scale = UIParent:GetEffectiveScale() or 1
    if scale == 0 then scale = 1 end
    return x / scale, y / scale
end

--- 光标落在这一条的第几格（1..n），不在条上返回 nil。
--- **按每个按钮自己的矩形判断**，不再用"条的左下角 + 格子间距"推算：
---   * GetLeft/GetBottom 已经是屏幕（UIParent 缩放后）坐标，再乘一次缩放会整体偏移；
---   * 间距/内边距一旦和 LayoutBar 不一致，推算出来的格子就会错位。
--- 逐格命中不存在这两个问题，而且天然支持将来每条不同的格子尺寸。
local function IndexAtCursor(bar)
    local cx, cy = CursorUI()
    if not cx or not cy then return nil end
    local upScale = UIParent:GetEffectiveScale() or 1
    for index, button in ipairs(bar.buttons) do
        local left, bottom = button:GetLeft(), button:GetBottom()
        if left and bottom then
            local s = (button:GetEffectiveScale() or upScale) / upScale
            local w = (button:GetWidth() or 0) * s
            local h = (button:GetHeight() or 0) * s
            if cx >= left and cx <= left + w and cy >= bottom and cy <= bottom + h then
                return index
            end
        end
    end
    return nil
end

local function EnsureDropCatcher(bar)
    if dropCatchers[bar] then return dropCatchers[bar] end
    local frame = bar.frame
    -- **必须用暴雪模板建**：实机证明普通 Frame 收不到 OnReceiveDrag（一次都没有），
    -- 而之前那版 ActionBarButtonTemplate 做的透明代理是能收到拖放的。所以接住器也用它。
    -- **必须带名字**：ActionButtonTemplate 的 OnLoad -> UpdateHotkeys 会拼 GetName()，
    -- 匿名框体会抛 "ActionButton.lua:489: attempt to concatenate a nil value"（日志里 16 次）。
    local catcherName = "MonetUIDropCatcher" .. tostring(bar.index or 0)
    local catcher
    for _, tmpl in ipairs({ "ActionBarButtonTemplate, SecureActionButtonTemplate",
                            "ActionButtonTemplate, SecureActionButtonTemplate",
                            "SecureActionButtonTemplate" }) do
        local ok, made = pcall(CreateFrame, "CheckButton", catcherName, UIParent, tmpl)
        if ok and made then catcher = made break end
    end
    if not catcher then return nil end
    -- **它只是接住拖放，绝不能施法、也不该有提示框。**
    -- ActionBarButtonTemplate 会带来暴雪 ActionButton 的 OnClick / OnEnter：
    --   * OnClick 在它没有 action 属性时会按 CalculateAction(id=0) 算成"动作条第 1 格"，
    --     于是点在它上面会放出 1 号格的法术（实机：宠物条 10 格全放"奥术射击"，
    --     提示框也写着"奥术射击"—— 因为鼠标其实落在它身上，它在 level 70，压着我们的按钮）；
    --   * OnEnter/OnLeave 会挂一个跟我们按钮无关的提示框。
    -- 我们只要它的 OnReceiveDrag / OnMouseUp（下面自己设），所以把模板带来的脚本全摘掉。
    pcall(catcher.SetScript, catcher, "OnClick", nil)
    pcall(catcher.SetScript, catcher, "OnEnter", nil)
    pcall(catcher.SetScript, catcher, "OnLeave", nil)
    pcall(catcher.SetAttribute, catcher, "type", nil)
    pcall(catcher.SetAttribute, catcher, "action", nil)
    if catcher.RegisterForClicks then pcall(catcher.RegisterForClicks, catcher) end
    catcher:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    catcher:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    catcher:SetFrameStrata("MEDIUM")
    catcher:SetFrameLevel(70)
    catcher:SetAlpha(0)
    -- **必须 Show**：OnUpdate 只在 Show 的框体上跑，隐藏的框体也不参与鼠标命中 ——
    -- 之前没 Show，结果它既不轮询也收不到放下事件（拖放依旧全废）。
    catcher:Show()
    catcher:EnableMouse(false)
    catcher:SetScript("OnReceiveDrag", function(self)
        if InCombatLockdown() then return end
        local index = IndexAtCursor(bar)
        local button = index and bar.buttons[index]
        local slot = button and SlotOf(button, bar, index)
        if slot and PlaceAction then pcall(PlaceAction, slot) end
        self.holding = false
        pcall(self.EnableMouse, self, false)
    end)
    -- **OnReceiveDrag 在这个客户端不派发给普通框体**（实机：接住器 mouse=true、光标确实拿着法术，
    -- 但一次 RECV 都没有）。所以真正的落点走 OnMouseUp：松手时只要手里还有东西，就按坐标算格子
    -- 再 PlaceAction —— 这也是"点一下把技能放进格子"的标准行为。
    catcher:SetScript("OnMouseUp", function(self)
        if InCombatLockdown() then return end
        if GetCursorInfo() == nil then return end
        local index = IndexAtCursor(bar)
        local button = index and bar.buttons[index]
        local slot = button and SlotOf(button, bar, index)
        if slot and PlaceAction then pcall(PlaceAction, slot) end
    end)
    -- 10Hz 轮询：只在手里拿着东西（法术/物品/宏）时开鼠标
    local acc = 0
    catcher:SetScript("OnUpdate", function(self, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 0.1 then return end
        acc = 0
        if not frame:IsShown() then
            if self.holding then self.holding = false; pcall(self.EnableMouse, self, false) end
            return
        end
        local holding = GetCursorInfo() ~= nil
        if holding ~= self.holding then
            self.holding = holding
            pcall(self.EnableMouse, self, holding)
        end
    end)
    dropCatchers[bar] = catcher
    return catcher
end

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

--- 把热键写在按钮角上（没有绑定就藏起来）。
local function SetHotkey(button)
    if not button or not button.hotkey then return end
    local key = BindingFor(button.bindName)
    if key then
        pcall(button.hotkey.SetText, button.hotkey, ShortenKey(key))
        pcall(button.hotkey.Show, button.hotkey)
    else
        pcall(button.hotkey.SetText, button.hotkey, "")
        pcall(button.hotkey.Hide, button.hotkey)
    end
end

--- 画一个按钮的自绘部分（底板、图标、数字、宏名、热键、冷却）。
local function SkinButton(button)
    if Marked(button, "skinned") then return end
    Mark(button, "skinned", true)

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

    -- 冷却：**自己建自己的框**，但计时由我们自己从 duration 对象灌进去（见 PaintCooldown）。
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

    -- 堆叠数量：受限环境下可能是秘密值，拿不到就不显示。
    local count
    if ActionBar and ActionBar.GetActionDisplayCount and not Secrets.CooldownsSecret() then
        count = ActionBar.GetActionDisplayCount(slot)
    end
    if type(count) == "number" and count > 1 then
        pcall(button.count.SetText, button.count, count)
        pcall(button.count.Show, button.count)
    else
        pcall(button.count.SetText, button.count, "")
        pcall(button.count.Hide, button.count)
    end

    -- 宏名
    local macroText
    if ActionBar and ActionBar.GetActionText then
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

--- 拖出 / 拖入。动作条走 PickupAction/PlaceAction；宠物条走 PickupPetAction（拖不进去）。
--- 这些全是受保护全局，战斗中会被客户端拒，所以一律先看 InCombatLockdown。
local function InstallDrag(bar, button, index, isPet)
    pcall(button.RegisterForDrag, button, "LeftButton", "RightButton")
    button:SetScript("OnDragStart", function(self)
        if InCombatLockdown() then return end
        if isPet then
            if _G.PickupPetAction then pcall(_G.PickupPetAction, index) end
            return
        end
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
        if InCombatLockdown() or isPet then return end
        local slot = SlotOf(self, bar, index)
        if slot and PlaceAction then pcall(PlaceAction, slot) end
    end)
end

local function BuildButton(bar, index)
    local def  = bar.def
    local name = "MonetUI" .. def.key .. "Button" .. index

    -- 宠物条的按钮要能吃 _onclick 片段（SecureHandlerClickTemplate）；
    -- 带不上就退回原来的安全按钮模板（那时点击不会生效，但不会崩）。
    local templates = def.pet
        and { "", "CheckButton" }   -- 宠物条：普通 CheckButton，点击走 WrapScript 的安全片段
        or nil
    local button = CreateSecureButton(name, bar.frame, index, templates)
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

    if def.pet then
        -- 宠物条：**不在我们自己身上施法**（本客户端没有通用安全按钮的 type="pet"）。
        -- 改成"点击片段去点暴雪自己的 PetActionButton"：
        --   条（SecureHandlerStateTemplate）用 SetFrameRef 指向 PetActionButtonN，
        --   按钮的 OnClick 用 WrapScript 包成安全片段，片段里 owner:GetFrameRef(...):Click()。
        -- 施法 / 冷却 / 自动施法提示全部由暴雪负责，我们只管外观和位置。
        pcall(button.RegisterForClicks, button, "AnyUp")
        InstallPageChild(button, index)
        button.bindName = def.bind .. index
        button.bar      = bar.frame
        SkinButton(button)
        SetHotkey(button)
        InstallDrag(bar, button, index, true)
        return button
    end

    -- 暴雪的 SpellFlyout（多阶法术 / 宠物技能那种"弹出托盘"）要求按钮实现
    -- FlyoutButtonMixin 的最小一份（Blizzard_Flyout/Flyout.lua:72-116）：
    --   GetPopupDirection()  托盘朝哪边展开（SpellFlyout.lua:260 要用）
    --   TogglePopup()        挂上 / 摘掉 SpellFlyout（SpellFlyout.lua:350 要用）
    --   IsPopupOpen/ClosePopup
    -- 裸 SecureActionButtonTemplate 一个都没有 → 点开托盘就报
    -- "SpellFlyout.lua:260/350: attempt to call a nil value"。
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
    -- 类型 / 按下抬起 / 槽位全部由安全片段写（见 InstallSecureInit 的注释）。
    InstallSecureInit(button)
    InstallPageChild(button, index)

    -- 拖出 / 拖入
    InstallDrag(bar, button, index, false)

    button.bindName = def.bind .. index
    -- bar 必须是**框体**（SetHotkey 之类还会用到）。
    button.bar      = bar.frame

    SkinButton(button)

    -- 热键文字（跟着玩家的按键设置走）
    SetHotkey(button)

    -- 鼠标提示：走轮询（Widget:HoverWatch），**不挂任何脚本钩子**（见 AGENTS 的皮肤原则）。
    -- GameTooltip:SetAction 在本客户端可用（实测 function）。
    if not Marked(button, "tooltip") then
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

--- 把一条上所有按钮的内容刷新一遍（槽位变了才需要）。
--- 宠物条的一格：图标 / 冷却 / 自动施法提示。
--- 全部读宠物 API（受限状态下可能是机密值），所以一律 pcall + Secrets 兜底；
--- 像素环画在**我们自己的**按钮上，不碰暴雪的任何宠物框体。
local function RefreshPetContent(button, index)
    if not button then return end

    local texture, isToken
    if _G.GetPetActionInfo then
        local r = { pcall(_G.GetPetActionInfo, index) }
        if r[1] then
            texture, isToken = r[3], r[4]
        end
    end
    -- 宠物条的"基础命令"（攻击/跟随/停留/被动…）返回的是一张**全局变量名**
    -- （"PET_ATTACK_TEXTURE" 这种），不是贴图路径 —— 直接塞给 SetTexture 什么也画不出来。
    -- 实测：只有带数字 fileID 的两个自动施法技能有图标，其余全空。
    if isToken and type(texture) == "string" then
        texture = _G[texture] or texture
    end

    if texture ~= nil then
        pcall(button.icon.SetTexture, button.icon, texture)
        pcall(button.icon.Show, button.icon)
    else
        pcall(button.icon.SetTexture, button.icon, nil)
        pcall(button.icon.Hide, button.icon)
    end

    pcall(button.count.SetText, button.count, "")
    pcall(button.count.Hide, button.count)
    pcall(button.macro.SetText, button.macro, "")

    local cooldown = button.cooldown
    if cooldown then
        local ok, start, duration, enable = pcall(_G.GetPetActionCooldown, index)
        start, duration, enable = Secrets.Number(start), Secrets.Number(duration), Secrets.Number(enable)
        if ok and start and duration and duration > 0 and enable ~= 0 then -- TAINT-OK: 上一行 Secrets.Number 守卫,机密→None
            pcall(cooldown.SetCooldown, cooldown, start, duration) -- TAINT-OK: 同上明文值 + pcall 兜底
        else
            pcall(cooldown.Clear, cooldown)
        end
    end

    local enabled
    if _G.GetPetActionInfo then
        local r = { pcall(_G.GetPetActionInfo, index) }
        if r[1] then enabled = Secrets.Bool(r[7], false) end
    end
    if enabled then
        -- 显式给像素/点距：默认值在本客户端换算出 1.0 单位（≈1 物理像素），肉眼看不见。
        -- pixel/pitch 都是"物理像素"语义，会再乘 Media:Mult()。
        Widget:PixelGlow(button, { side = ButtonSize(), static = true,
            pixel = 5, pitch = 12, ringAlpha = 1 })
    else
        Widget:StopPixelGlow(button)
    end
end

local function RefreshBar(bar)
    -- 宠物条是收养来的暴雪按钮：图标/冷却/自动施法提示由暴雪自己刷新，我们不碰。
    if bar.def and bar.def.pet then return end
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

--- 给收养来的暴雪宠物按钮"换皮"（ElvUI 的 StyleButton 同一思路，但只做最必要的几层）：
---   * 藏掉它自己的美术（NormalTexture / Border / SlotBackground / Flash）—— 只调它们的方法；
---   * 垫一块**我们自己的**底板 + 1px 边框（子框体属于我们，不会污染暴雪对象）；
---   * 图标裁外圈 8%（CropIcon 现在是轮询实现，不挂钩子）；
---   * 热键/数量换像素字体；冷却文字接我们那套渲染。
--- 全部 pcall：这个客户端对受保护按钮的某些方法会拒绝，失败就保持原生样子，不能崩。
local function SkinAdoptedPetButton(btn)
    if not btn or Marked(btn, "petSkinned") then return end
    Mark(btn, "petSkinned", true)

    local function fade(region)
        if region and type(region.SetAlpha) == "function" then pcall(region.SetAlpha, region, 0) end
    end
    fade(btn.NormalTexture)
    fade(btn.Border)
    fade(btn.SlotBackground)
    fade(btn.Flash)
    fade(btn.AutoCastShine)

    -- 边框：收养来的按钮**图标是铺满整格的**（我们不能像自绘那样把图标内缩 1px），
    -- 所以底板/边框不能垫在下面（会被图标完全盖住）——改成在按钮**上方**画一圈 1px 的边框。
    -- 必须带 BackdropTemplate：Widget:Theme 走的是 SetBackdrop，没有该模板的面板画不出边。
    local border = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    border:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
    border:SetFrameLevel(btn:GetFrameLevel() + 1)
    border:EnableMouse(false)
    Widget:Theme(border, { thickness = 1, bgAlpha = 0 })
    Mark(btn, "petBorder", border)

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

--- 宠物条的冷却：收养来的按钮，暴雪只在自己的事件里刷（切目标等），不主动更新 ——
--- 实机表现就是"切个目标才看到冷却时间"。给它一个 0.5 秒的轻量驱动，只调冷却刷新函数
--- （不调 PetActionBar:Update，那会连带 UpdateShownButtons → 那 10 条拦截）。
local petCooldownDriver
local function EnsurePetCooldownDriver()
    if petCooldownDriver then return end
    petCooldownDriver = CreateFrame("Frame")
    local acc = 0
    petCooldownDriver:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 0.5 then return end
        acc = 0
        local bar = bars and bars.BarPet
        if not bar or not bar.frame:IsShown() then return end
        -- 本客户端没有全局 PetActionBar_UpdateCooldowns（实测 nil），但有方法
        -- PetActionBar:UpdateCooldowns()。只刷冷却，不碰 Update（那会连带 UpdateShownButtons）。
        local shell = _G.PetActionBar
        if shell and type(shell.UpdateCooldowns) == "function" then
            pcall(shell.UpdateCooldowns, shell)
        elseif _G.PetActionBar_UpdateCooldowns then
            pcall(_G.PetActionBar_UpdateCooldowns)
        end
    end)
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

    pcall(frame.SetAttributeNoHandler, frame, "_onstate-page", ON_STATE_PAGE)
    -- 初始页号也**必须在安全环境里**写：Lua 直接 SetAttribute 得到的是脏值，
    -- 客户端点击时拿它调 UseAction 就会判插件越权（见 PAGE_CHILD 那段的长注释）。
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
        visibility = def.paged and VISIBILITY_MAIN or VISIBILITY_OTHER,
    }

    -- **宠物条只能收养暴雪的 PetActionButton1..10**：实测这个客户端没有通用安全按钮的
    -- `type="pet"`（属性全对、层级也压过所有条，点了照样没反应，而且没有任何拦截 —— 是
    -- 客户端根本不处理这个 type）。收养之后施法 / 右键切自动施法 / 冷却 / 自动施法提示全原生。
    -- 代价：SetParent/SetSize 会把受保护按钮标脏，暴雪自己的 SetShown 会被拒（日志里 10 条
    -- BLOCKED，只进日志、不弹窗）。功能优先，接受这个代价。
    if def.pet then
        local size, spacing = ButtonSize(), Spacing()
        for i = 1, 10 do
            local btn = _G["PetActionButton" .. i]
            if not btn then break end
            pcall(btn.SetParent, btn, frame)
            pcall(btn.ClearAllPoints, btn)
            pcall(btn.SetSize, btn, size, size)
            pcall(btn.SetScale, btn, 1)
            pcall(btn.SetPoint, btn, "TOPLEFT", frame, "TOPLEFT", (i - 1) * (size + spacing), 0)
            -- 外壳事件被卸载后，没人再替我们把这 10 个按钮 Show 出来（它们可能停在
            -- 壳隐藏时的 SetShown(false) 状态）——直接显式显示一次。
            pcall(btn.Show, btn)
            SkinAdoptedPetButton(btn)
            bar.buttons[#bar.buttons + 1] = btn
        end
        if #bar.buttons == 0 then
            pcall(frame.Hide, frame)
            return nil
        end
        pcall(frame.SetSize, frame, #bar.buttons * size + math.max(#bar.buttons - 1, 0) * spacing, size)

        local shell = _G.PetActionBar
        if shell then
            pcall(shell.SetAlpha, shell, 0)
            pcall(shell.EnableMouse, shell, false)
            pcall(shell.EnableMouseMotion, shell, false)
            -- **事件不能卸载**：实测卸载之后没人再更新这套按钮的图标/冷却（冷却圈直接不转），
            -- 也没人再 Show 它们。代价就是壳的 Update → UpdateShownButtons 会对这 10 个已经
            -- 搬家的受保护按钮 SetShown，日志里出现 10 条 BLOCKED（只进日志、不弹窗）。
            -- 功能优先，接受这个代价。
        end
        if RegisterStateDriver then
            pcall(RegisterStateDriver, frame, "visibility", "[pet] show; hide")
        end
        PositionBar(bar)
        bar.page = 1
        EnsurePetCooldownDriver()
        return bar
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

    if def.pet then
        -- 自绘宠物条：显隐只由"有宠物"决定；页号恒为 1（子片段据此写 action = 本格序号）；
        -- 不装拖放接住器（宠物槽不是动作条槽位）。
        if RegisterStateDriver then
            pcall(RegisterStateDriver, frame, "visibility", "[pet] show; hide")
            pcall(RegisterStateDriver, frame, "page", "1")
        end
        LayoutBar(bar)
        PositionBar(bar)
        bar.page = 1
        PushPageToChildren(bar)
        PushSecureInit(bar, "pet")
        RefreshBar(bar)
        return bar
    end

    -- 翻页驱动：1 号条按客户端状态换页，其余条固定在自己那一页。
    if RegisterStateDriver then
        pcall(RegisterStateDriver, frame, "page", def.paged and FULL_PAGE or tostring(def.page))
    end

    LayoutBar(bar)
    PositionBar(bar)
    -- 按钮建好、位置定好后，把当前页下发给它们一次（片段跑，安全环境里写 action）
    PushPageToChildren(bar)
    PushSecureInit(bar, "action")
    EnsureDropCatcher(bar)
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
    pcall(frame.SetAttribute, frame, "_onstate-exit", EXIT_SNIPPET)
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

-- 宠物条的"自动施法"提示：本客户端暴雪用的是一圈旋转的蚂蚁（按钮的 AutoCastOverlay.Shine），
-- 角标（Corners，"这个技能可以自动施法"）是另一块，别动。这里把蚂蚁换成自绘的像素环：
-- 暴雪的动画摁掉，状态自己按 GetPetActionInfo 的第 6 个返回值（autoCastEnabled）跟。
-- 自绘动作条开着时环沿边框跑；关着时改成静态的一圈（宠物条交还暴雪，但提示不丢）。
-- 战斗中也照常跟：只是往按钮上加几个方块，不碰受保护的框体。

local GetPetActionInfo = _G.GetPetActionInfo

--- 摁掉暴雪的旋转蚂蚁。暴雪每次刷新按钮状态都会把它再点亮，所以这里把方法本身换掉，
-- 顺带把已经点亮的旧动画停掉。
--- 关掉暴雪的自动施法旋转蚂蚁。
--- **只调方法，不写字段。** 以前这里做的是
---   overlay.monetShineSuppressed = true
---   overlay.monetShineUpdate = overlay.UpdateShineAnim
---   overlay.UpdateShineAnim = function() end
--- —— 三行都是往暴雪的 AutoCastOverlay 上写字段。本客户端按"键"判污染：写过就脏，
--- 之后暴雪自己的 PetActionButton:UpdateShownButtons → SetShown 在战斗中全被拒
--- （taint.log: "blocked in combat because of taint from MonetUI - PetActionButton5:SetShown()"）， -- TAINT-OK: 同上，注释非代码
--- 连带 PetActionBar/MainActionBar 的整体重排也被拒。停动画 + 藏起来就够了，不需要改它的函数。
local function SuppressAutoCastShine(button)
    local overlay = button.AutoCastOverlay
    if not overlay then return end
    local shine = overlay.Shine
    if shine then
        if shine.Anim then pcall(shine.Anim.Stop, shine.Anim) end
        pcall(shine.Hide, shine)
        pcall(shine.SetAlpha, shine, 0)
    end
end

--- 还原成暴雪原样（只在模块整个停用时走这条）。
local function RestoreAutoCastShine(button)
    local overlay = button.AutoCastOverlay
    local shine = overlay and overlay.Shine
    if not shine then return end
    pcall(shine.SetAlpha, shine, 1)
    pcall(shine.Show, shine)
    if shine.Anim then pcall(shine.Anim.Play, shine.Anim) end
end

--- 这个槽位开没开自动施法。返回顺序：name, texture, isToken, isActive, autoCastAllowed,
--- autoCastEnabled, spellID ... -- 第 6 个才是"开着"，第 5 个是"可以开"。
local function PetAutoCastEnabled(index)
    if not GetPetActionInfo then return false end
    local ok, _, _, _, _, _, enabled = pcall(GetPetActionInfo, index)
    if not ok then return false end
    return Secrets.Bool(enabled, false)
end

--- 像素环的边长：跟着暴雪的自动施法遮罩走（那圈蚂蚁就画在这块遮罩里：45 - 8 = 37），
--- 遮罩不在就按按钮宽度推。取的是像素环该落在哪，不是图标本身的大小。
local function PetGlowSide(button, entry)
    local overlay = button.AutoCastOverlay
    local mask = overlay and overlay.Mask
    if mask and mask.GetWidth then
        local ok, width = pcall(mask.GetWidth, mask)
        if ok then
            local size = Secrets.Number(width)
            if size and size > 4 then return size end
        end
    end
    return (entry.base or 30) + 7
end

--- 开着自动施法的按钮上跑一圈像素环，其余的干净。
-- 自绘动作条开着 → 环跟着跑；关着 → 宠物条还是暴雪自己的样子，环改成静态的一圈。
local function SyncPetGlow(def, entry)
    local isStatic = not M.own
    local scale = entry.scale or 1
    for index = 1, def.count do
        local button = _G[def.pattern:format(index)]
        if not button then break end

        SuppressAutoCastShine(button)

        if PetAutoCastEnabled(index) then
            Widget:PixelGlow(button, {
                side   = PetGlowSide(button, entry),
                scale  = scale,
                static = isStatic,
            })
        else
            Widget:StopPixelGlow(button)
        end
    end
end

--- 宠物条的像素环跟一遍当前状态。自绘动作条关着时这条条没被接管，得自己去拿容器。
local function SyncPetGlowNow()
    -- 不排版（STYLE_ADOPTED_BARS=false）时不画像素环：环是画在**暴雪的**宠物按钮上的，
    -- 现阶段一碰它们就有把受保护按钮弄脏的风险（见文件开头两个开关的注释）。
    if not STYLE_ADOPTED_BARS then return end
    local def = PET_DEF
    if not def then return end

    local entry = adopted[def.key]
    if not entry or not entry.frame then
        local bar = ResolveContainer(def)
        if not bar then return end
        local first = _G[def.pattern:format(1)]
        local base
        if first and first.GetWidth then
            local ok, width = pcall(first.GetWidth, first)
            if ok then base = Secrets.Number(width) end
        end
        entry = { def = def, frame = bar, scale = 1, base = base }
    end

    SyncPetGlow(def, entry)
end

--- 模块整个关掉：环拆掉，暴雪的旋转蚂蚁还回去（不然玩家会永久失去原版提示）。
local function TeardownPetGlow()
    local def = PET_DEF
    if not def then return end
    for index = 1, def.count do
        local button = _G[def.pattern:format(index)]
        if not button then break end
        Widget:StopPixelGlow(button)
        RestoreAutoCastShine(button)
    end
end

--- 零售 12.x 的姿态条 / 宠物条外面套了一层编辑模式管理的框体（StanceBar / PetActionBar）：
--- 直接搬它会被暴雪的布局改回去，还会把框体弄成"强污染"（暴雪自己再动它就报
--- ADDON_ACTION_BLOCKED 一片刷屏）。真正装按钮的是里面的按钮容器
--- （StanceBarButtonContainer1…），它们不受布局管：搬容器，外层框体留在原地（它没有美术）。
---
--- 注意每个容器**只装一个按钮**（1..10 号各一个），而且都锚在外层壳的 BOTTOMLEFT 上、按 32
--- 递增排开。所以不能只搬 1 号容器 —— 2..10 号还挂在壳的老位置上，表现就是"宠物条 /
--- 姿态条只显示一个按钮"。这里把整串容器都取出来，由调用方按 1 号的位置重新排。
local function ButtonContainers(bar)
    if not bar or type(bar.GetName) ~= "function" then return nil end
    local ok, base = pcall(bar.GetName, bar)
    if not ok or not base then return nil end
    local list
    for i = 1, 12 do
        local c = _G[base .. "ButtonContainer" .. i]
        if c then
            list = list or {}
            list[#list + 1] = c
        end
    end
    return list
end

--- 把 1 号之外的容器串到 1 号旁边：宠物条右对齐、往左长，姿态条往右长。
---
--- 间距要换算成**壳的虚拟坐标系**里的单位：外面看着 30（自绘按钮 28 + 间隙 2），而这一串容器
--- 带着 0.9333 的缩放，真实落点 = 虚拟 × scale，所以虚拟步距 = 30 / scale ≈ 32.14。
--- 写死 32（暴雪自己的值）会让 10 个按钮累计右偏 1.2 个单位 —— 肉眼能看出来。
local function ChainContainers(containers, point, scale)
    local first = containers[1]
    if #containers < 2 or not first then return end

    local growLeft = point:find("RIGHT", 1, true) ~= nil
    local pitch = ButtonSize() + Spacing()
    if not scale or scale <= 0 then scale = 1 end
    local step = pitch / scale

    for i = 2, #containers do
        local c = containers[i]
        pcall(c.ClearAllPoints, c)
        local offset = step * (i - 1)
        pcall(c.SetPoint, c, "BOTTOMLEFT", first, "BOTTOMLEFT", growLeft and -offset or offset, 0)
    end
end

--- 受保护写入的"签名"：只有这些值变了，才值得去碰暴雪的受保护框体。
local function AdoptSignature(point, scale, stored, count)
    return table.concat({
        tostring(point), tostring(scale),
        tostring(stored.relativeTo), tostring(stored.relativePoint),
        tostring(stored.x), tostring(stored.y),
        tostring(count),
    }, "|")
end

--- 已经就位了吗：签名一致 + 实测锚点/步距/缩放都没被暴雪动过。
--- 这里只读不写（GetPoint / GetScale），所以每来一个宠物事件都问一遍也不产生任何 BLOCKED。
local function AdoptInPlace(entry, bar, containers, point, scale, stored, def)
    local count = #(containers or {})
    if not entry.signature or entry.signature ~= AdoptSignature(point, scale, stored, count) then
        return false
    end
    local okScale, barScale = pcall(bar.GetScale, bar)
    if okScale and math.abs((barScale or 1) - scale) > 0.001 then return false end

    local first = containers and containers[1]
    if not first then return true end

    local p1, _, rp1, x1, y1 = first:GetPoint(1)
    if p1 ~= point then return false end
    if rp1 ~= (stored.relativePoint or def.relativePoint or point) then return false end
    if math.abs((x1 or 0) - (stored.x or def.x or 0)) > 0.01 then return false end
    if math.abs((y1 or 0) - (stored.y or def.y or 0)) > 0.01 then return false end

    if count > 1 then
        local p2, _, _, x2 = containers[2]:GetPoint(1)
        if p2 ~= "BOTTOMLEFT" then return false end
        local step = (ButtonSize() + Spacing()) / (scale > 0 and scale or 1)
        local growLeft = point:find("RIGHT", 1, true) ~= nil
        local want = growLeft and -step or step
        if math.abs((x2 or 0) - want) > 0.5 then return false end
    end
    return true
end

--- 这一串容器带着壳的 0.9333 缩放，**`GetRect` / `GetPoint` 对它们报的是"虚拟"坐标**：
--- 容器说自己 L=1215.67，拿一个不缩放的探针框锚到里面的按钮上量，真实落点是 1134.6 ——
--- 正好差 1/0.9333。所以别拿 GetRect 的数字去换算屏幕坐标，那是把已经除过缩放的数字再除一遍。
--- 搬它们照常按壳自己的锚点走：锚点和偏移会一起被缩放，落点反而是准的。

--- 收养条的"空格子"美术。
--- 暴雪只让**有技能的槽位**显示按钮：空格子的按钮本身是 hidden 的，一整排就缺一个口
--- （宠物条最常见：4 号格没有宠物技能，那一格就空着，看着像少画了一块）。
--- 这里把描边 + 中性底 + 织纹/顶光画在**按钮的容器**上：容器的贴图永远画在自己的子按钮
--- 之下，所以按钮在的时候被完全盖住、按钮藏起来时正好露出来 —— 和自绘动作条的空槽是
--- 同一套材质，纯美术，不 Show/Hide 受保护的按钮、也不动层级，没有污染风险。
local function BuildEmptySlot(button)
    local slot = Marked(button, "emptySlot")
    if slot then return slot end

    local holder = button.GetParent and button:GetParent()
    if not holder then return nil end

    local ring = holder:CreateTexture(nil, "BACKGROUND", nil, 0)
    ring:SetAllPoints(button)
    local well = holder:CreateTexture(nil, "BACKGROUND", nil, 1)
    well:SetPoint("TOPLEFT", button, "TOPLEFT", BORDER, -BORDER)
    well:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -BORDER, BORDER)

    local r, g, b = Color:GetBorder()
    ring:SetColorTexture(r, g, b, 0.9)
    well:SetColorTexture(0, 0, 0, 0.25)

    local material = Widget:ButtonMaterial(holder, { alpha = 0, weaveAlpha = 0.25, layer = "BACKGROUND", sublevel = 3 })

    slot = {
        ring  = ring,
        well  = well,
        weave = material and material.weave,
        sheen = material and material.sheen,
    }
    Mark(button, "emptySlot", slot)
    return slot
end

--- 这一格空着（暴雪把按钮藏了）时空槽顶上，有按钮时让开。
local function SyncEmptySlot(button)
    local slot = button and Marked(button, "emptySlot")
    if not slot then return end
    local empty = not button:IsShown()
    if slot.ring  then slot.ring:SetShown(empty)  end
    if slot.well  then slot.well:SetShown(empty)  end
    if slot.weave then slot.weave:SetShown(empty) end
    if slot.sheen then slot.sheen:SetShown(empty) end
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

    -- 只让它"能用"，不排版：原位置、原大小，仅关掉外壳的鼠标（那壳 1303×1193，
    -- 会把屏幕中间整块的点击吃掉）。排版相关的 SetScale / SetPoint 一律不做 ——
    -- 见 STYLE_ADOPTED_BARS 的注释。
    if not STYLE_ADOPTED_BARS then
        pcall(bar.EnableMouse, bar, false)
        pcall(bar.EnableMouseMotion, bar, false)
        return entry
    end

    -- 暴雪的条本来就在 UIParent 下面。以前我们把它们塞进隐藏框（SetParent），零售 12.x 上这会把
    -- 受保护的框体弄成"强污染"，暴雪的编辑模式再想给它们挪一下就被拒（ADDON_ACTION_BLOCKED
    -- 刷屏）。现在只是隐藏，不再搬动它们。

    -- 缩放到自绘按钮的尺寸，暴雪条内部的排布原样不动；基准宽度只量一次（量时缩放还是 1），免得每次乘一遍自己设的缩放。
    local firstButton = _G[def.pattern:format(1)]
    if not entry.base and firstButton then
        local base = firstButton:GetWidth()
        if base and base > 8 then entry.base = base end
    end
    local size  = ButtonSize()
    local scale = entry.base and (size / entry.base) or 1

    local containers = ButtonContainers(bar)
    local first = containers and containers[1]
    local stored = StoredPosition(def, def.key)
    local point = stored.point or def.point or "CENTER"

    -- 记忆化（选项 A）：签名一致、实测锚点也没被暴雪动过，就**跳过所有受保护写操作**。
    -- 宠物事件（PET_BAR_UPDATE / UNIT_PET / 目标变化…）会频繁走到这里；以前每来一次都对
    -- StanceBar / PetActionBar 写一遍 SetScale / SetPoint / EnableMouse，日志里攒出
    -- "StanceBar:SetPointBase()" / "PetActionBar:SetShownBase()" 这类 BLOCKED（只进日志、不弹窗）。
    -- 现在只在"真的要变"或"暴雪把位置改回去了"时才写。
    if not AdoptInPlace(entry, bar, containers, point, scale, stored, def) then
        entry.signature = AdoptSignature(point, scale, stored, #(containers or {}))
        pcall(bar.SetScale, bar, scale)
        entry.scale = scale

        -- 外层壳（PetActionBar / StanceBar）我们不动它，只搬里面的按钮容器。但它是**开鼠标**的：
        -- 宠物条那个实测 1303×1193、贴 UIParent，正好盖住屏幕中间一大块 —— 表现就是
        -- 世界里点不中、按住左/右键都转不了视角，而外圈的 UI（动作条、小地图）照常能点。
        -- 壳自己没有美术也没有按钮（按钮在 ButtonContainer 里各自收鼠标），所以把它的鼠标关掉。
        if first and first ~= bar then
            pcall(bar.EnableMouse, bar, false)
            pcall(bar.EnableMouseMotion, bar, false)

            -- 一个容器只装一个按钮：整串跟着 1 号排开，否则只有 1 号搬过去、其余留在壳的老位置。
            Anchor(first, stored, def)
            ChainContainers(containers, point, scale)
        else
            Anchor(first or bar, stored, def)
        end
    end

    -- **不再碰暴雪的按钮**（这里原本会给它们套 ControlBg / 渐隐边框 / ButtonMaterial /
    -- 像素字体，还会替它们 Show）。
    --
    -- taint.log 实测：这些写入会把**受保护的**动作按钮/按钮容器弄脏。脏了之后：
    --   * 暴雪自己的 UpdateShownButtons → SetShown 在战斗中被拒
    --     （"An action was blocked in combat because of taint from MonetUI - PetActionButton9:SetShown()"）； -- TAINT-OK: 同上，注释非代码
    --   * 按钮卡在错误状态，暴雪只能反复重试 → 每次进战斗刷一屏，并连带把
    --     PetActionBar / MainActionBar 的整体重排也拒掉（ClearAllPointsBase / SetPointBase）；
    --   * 连带 UpdateShownButtons 的后钩也失去意义。
    -- 所以这里只保留"容器摆位置"（容器不是受保护按钮），外观交回暴雪自己。
    -- 代价：宠物/姿态条是暴雪原生外观。要自绘就得像 Bar1..8 那样建自己的安全按钮
    -- （宠物用 type="pet"），那是另一件事，记进 AGENTS 待办。

    if def.glow == "autoCast" then
        SyncPetGlow(def, entry)
    end

    -- **不要给外壳写 ignoreFramePositionManager**（以前这里调 LeaveManagedFrameSystem）。
    -- 那个字段一写，这个受保护的条就变成"被 MonetUI 写过的框"：它的 OnEvent 脚本随之以
    -- 我们的名义执行，于是它内部调用的暴雪安全函数全被拒 —— 实机链条：
    --   PetActionBar:OnEvent → Update → Hide → UpdateVisibility
    --     → SetShownBase (BLOCKED)
    --     → EditModeManagerFrame:UpdateActionBarLayout → UpdateBottomActionBarPositions
    --       → MainActionBar:ClearAllPointsBase / SetPointBase (BLOCKED，明明 MainActionBar 自己是干净的)
    -- 也就是"一进战斗就弹：插件导致界面行为失效"。去掉之后外壳保持干净，链路恢复安全。

    return entry
end

--- 只把一条暴雪条"变透明"（**只 SetAlpha，不动鼠标、不换父、不写字段**）。
--- 用在我们自己已经接管显示（自绘宠物条/姿态条）的时候：暴雪那条留着但它看不见。
--- ParkWatch 会在脱战后把 alpha 压回去（战斗中不碰受保护框体）。
--- 实测记录：连 EnableMouse(false) 都会让这条受保护的条变脏（flyoutDirection / 按钮的
--- popupDirection 被写成脏值），之后暴雪自己的 SetShown / ClearAllPoints 就全被拒 ——
--- 所以这里只保留 alpha 这一项（它只需要"看不见"，鼠标在更上层由我们自己的按钮接住）。
local function GhostBar(name)
    local frame = _G[name]
    if not frame or Marked(frame, "parked") then return end
    Mark(frame, "parked", true)
    Mark(frame, "alpha", frame:GetAlpha())
    pcall(frame.SetAlpha, frame, 0)
    ParkWatch(frame)
end

--- 暴雪的宠物/姿态条现在**完全交给玩家自己的编辑模式设置**：想藏就在
--- 编辑模式里把「宠物栏 / 姿态栏」的可见性设成隐藏（那是玩家操作，不算插件污染）。
--- 我们不再碰它：实测连 SetAlpha(0) 都会让它变脏，之后暴雪自己的
--- PetActionBar:ClearAllPoints / PetActionButton:SetShown 全被拒（就是那串拦截）。
local function AdoptAll()
    if not M.own then return end
    if not ADOPT_BLIZZARD_BARS then
        -- 宠物条是"收养"暴雪按钮做的（见 CreateBar），外壳在 CreateBar 里已经 alpha 0；
        -- 姿态条暂时不接管（同样只透明）。
        GhostBar("StanceBar")
        return
    end
    if Locked() then
        -- 战斗中动不了暴雪的条：排队到脱战（ns:AfterCombat）。
        ns:AfterCombat("actionbars-adopt", AdoptAll)
        return
    end
    for _, def in ipairs(ADOPTED_DEFS) do
        AdoptBar(def)
    end
end

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
        -- 宠物条不走 override binding：宠物技能的键位本来就绑在暴雪的动作命令上
        -- （BONUSACTIONBUTTON1..10），再包一层会让客户端把整条 `PetActionBar:Show →
        -- UpdateVisibility → 重排` 的链记成我们的（taint.log 里 19:12:41 那一串：
        -- BONUSACTIONBUTTON2 → PetActionButtonDown → PetActionBar:Show →
        -- ClearAllPointsBase BLOCKED）。鼠标点击用我们自己的按钮，键盘交给暴雪。
        if not (bar.def and bar.def.pet) then
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
        if not (bar.def and bar.def.pet) then
            pcall(ClearOverrideBindings, bar.frame)
        end
    end
end

-- 这些事件之后暴雪可能重排 / 换过宠物条和姿态条，我们再把位置和缩放放回去；战斗中不能动受保护的框体，留到 PLAYER_REGEN_ENABLED。
local ADOPT_EVENTS = {
    "UNIT_PET", "UNIT_FLAGS", "PET_UI_UPDATE", "PET_BAR_UPDATE",
    "PET_BAR_UPDATE_USABLE", "PET_BAR_UPDATE_COOLDOWN",
    "UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS",
    "PLAYER_CONTROL_GAINED", "PLAYER_CONTROL_LOST", "PLAYER_TARGET_CHANGED",
    "UPDATE_VEHICLE_ACTIONBAR", "PLAYER_MOUNT_DISPLAY_CHANGED",
}

-- 宠物条"自动施法"的状态事件：跟 ADOPT_EVENTS 分开登记，因为像素环不受战斗锁影响
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

    for _, event in ipairs(ADOPT_EVENTS) do
        EventBus:Register(event, function() AdoptAll() end)
    end

    for _, event in ipairs(PET_GLOW_EVENTS) do
        EventBus:Register(event, function() SyncPetGlowNow() end)
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
        for index, button in ipairs(bar.buttons) do
            PaintCooldown(button, SlotOf(button, bar, index))
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
        for _, button in ipairs(bar.buttons) do
            SetUseOnKeyDown(button)
        end
    end
end

function M:UpdateHotkeys()
    for _, bar in pairs(bars) do
        for _, button in ipairs(bar.buttons) do
            SetHotkey(button)
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
    for _, bar in pairs(bars) do
        LayoutBar(bar)
        PositionBar(bar)

    end
    AdoptAll()
    self:UpdateAll()
end

function M:ParkBlizzard()
    for _, name in ipairs(ACTION_BAR_FRAMES) do
        Park(name)
    end
    for _, name in ipairs(BAG_BAR_FRAMES) do
        ParkBag(name)
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
    for _, def in ipairs(BAR_DEFS) do
        local bar = bars[def.key]
        if bar then
            if def.pet then
                -- 宠物条不走"第几条开着"那套：它的显隐只由 [pet] 状态驱动决定
                -- （CreateBar 里已注册）。自绘动作条关掉时直接藏起来，暴雪那条保持原样。
                if not own then pcall(bar.frame.Hide, bar.frame) end
            else
                SetBarShown(bar, own and def.index <= count)
            end
        end
    end
    WatchPages(own)

    if own then
        AdoptAll()
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
        Park("BagsBar")
        Park("MainMenuBarBackpackButton")
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

    -- 宠物条的自动施法提示：自绘条开着是动画环，关着是静态环（这条路径不依赖 AdoptAll）。
    SyncPetGlowNow()
end

function M:SetEnabled(enabled)
    if enabled then
        self:Apply()
    else
        M.own = false
        WatchPages(false)
        for _, bar in pairs(bars) do
            pcall(bar.frame.Hide, bar.frame)
        end
        if leaveVehicle then pcall(leaveVehicle.frame.Hide, leaveVehicle.frame) end
        for _, entry in pairs(adopted) do
            ReleaseBar(entry)
        end
        ClearBindings()
        self:RestoreBlizzard()
        TeardownPetGlow()
    end
end

function M:Initialize()
    self:Build()
    self:Apply()
    self:RegisterEvents()
end

ns:Register("ActionBars", M)
