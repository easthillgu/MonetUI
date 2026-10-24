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

local BORDER      = 1     -- 1px Monet edge, used as the icon inset everywhere
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

--- 退出暴雪的"托管框体"系统（ManagedFrameSystem）：只把条目从 showingFrames 里摘掉。
--- **绝不写 frame.ignoreFramePositionManager。** 那个字段一写，这个受保护的条就成了
--- "被 MonetUI 写过的框"（issecurevariable 实测为 false），它的 OnEvent 脚本随之以我们的名义
--- 执行 —— 而 OnEvent 里（PLAYER_REGEN_ENABLED/DISABLED → UpdateVisibility）会调用暴雪的
--- 安全函数，于是整条链全被拒，连**别人的**干净框也一起遭殃：
---   MultiBar*/PetActionBar:OnEvent → UpdateVisibility → SetShownBase        BLOCKED
---     → EditModeManagerFrame:UpdateActionBarLayout → SetPointBase(MainActionBar) BLOCKED
--- 表现就是"一进战斗就弹：插件导致界面行为失效"。
--- 不走 container:RemoveManagedFrame()：它末尾会 container:Layout()，从我们的脏栈里去挪别的
--- 受保护框，一样被拒。直接把条目从表里摘掉即可。
local function LeaveManagedFrameSystem(frame)
    if not frame then return false end

    local getContainer = frame.GetManagedFrameContainer
    if type(getContainer) == "function" then
        local ok, container = pcall(getContainer, frame)
        if ok and type(container) == "table" and type(container.showingFrames) == "table" then
            container.showingFrames[frame] = nil
        end
    end
    return true
end

--- 让暴雪自己把按钮藏起来：不碰受保护的 Hide/SetShown，只写 statehidden。
local function QuietHideButton(button)
    if not button then return end
    pcall(button.UnregisterAllEvents, button)
    pcall(button.SetAttributeNoHandler, button, "statehidden", true)
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
local applied = false
local bindingsDirty = false
local adoptedDirty  = false
local refreshDirty  = false
local layoutDirty   = false   -- 战斗中改不动受保护的按钮，脱战补做
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
local function Park(name)
    local frame = _G[name]
    if not frame or Marked(frame, "parked") then return false end
    Mark(frame, "parked", true)
    Mark(frame, "alpha", frame:GetAlpha())
    Mark(frame, "parent", frame:GetParent())

    if name == "MainActionBar" then
        -- **1 号条不能换父。** 每次进/出战斗、宠物栏显隐、变形/载具切页，暴雪都会走
        --   EditModeActionBarMixin:UpdateVisibility (ActionBar.lua:334)
        --     → EditModeManagerFrame:UpdateActionBarLayout (EditModeManager.lua:574)
        --       → UpdateBottomActionBarPositions (630)
        -- 对"显示中且处于默认位置"的底部条做 ClearAllPoints + SetPoint（649/661/662）。
        -- 换过父的框会把这些**安全调用**全部拒掉，实机堆栈逐帧对得上：
        --   EditModeSystemTemplates.lua:154 ClearAllPoints → ClearAllPointsBase
        --   EditModeSystemTemplates.lua:148 SetPoint       → SetPointBase
        -- 表现就是"一进战斗就弹：插件导致界面行为失效"。所以 1 号条留在 UIParent 下面：
        -- 位置随便它排（我们 alpha 0 看不见），只要**不吃鼠标**就行。
        -- 鼠标必须自己关：EnableMouse(false) 只关父框，翻页箭头（frameLevel 100）照样
        -- 可点，所以 KillPagerMouse 也要跟一遍。
        pcall(frame.SetAlpha, frame, 0)
        pcall(frame.EnableMouse, frame, false)
        if frame.EnableMouseClicks then pcall(frame.EnableMouseClicks, frame, false) end
        if frame.EnableMouseMotion then pcall(frame.EnableMouseMotion, frame, false) end
        KillPagerMouse(frame)

        -- 变形 / 载具 / 翻页 / 骑乘时暴雪会重新 Show 它：Show 本身是安全的（父链没被我们
        -- 改过），只要把 alpha 压回去。SetAlpha 不受保护、战斗中也能写，不会把框弄脏。
        if type(hooksecurefunc) == "function" and not Marked(frame, "showHook") then
            Mark(frame, "showHook", true)
            pcall(hooksecurefunc, frame, "Show", function(self)
                pcall(self.SetAlpha, self, 0)
                KillPagerMouse(self)
            end)
        end
        if frame.Selection and frame.Selection.SetAlpha then
            pcall(frame.Selection.SetAlpha, frame.Selection, 0)
        end

        if type(frame.actionButtons) == "table" then
            for _, button in pairs(frame.actionButtons) do QuietHideButton(button) end
        end
        return true
    end

    -- 其余条：换父到常隐框体（它们不在 UpdateBottomActionBarPositions 的"显示中"集合里，
    -- 且被藏着时 IsShown() 为假，安全重排不会碰它们）。
    pcall(frame.SetParent, frame, HiddenParent())
    LeaveManagedFrameSystem(frame)

    -- 事件也摘掉：暴雪在这些条自己的 OnEvent 里做 PLAYER_REGEN_* → UpdateVisibility → 重排，
    -- 而这些脚本正是"被我们的字段污染过的框"跑起来的。不摘的话，进战斗时它会拖着整条链
    -- （包括对别的条的安全调用）一起被拒。载具条/接管条要保留事件，暴雪靠它切显隐。
    if name ~= "OverrideActionBar" and name ~= "PossessActionBar" then
        pcall(frame.UnregisterAllEvents, frame)
    end

    if name == "MainMenuBar" then
        KillPagerMouse(frame)
    end

    if type(frame.actionButtons) == "table" then
        for _, button in pairs(frame.actionButtons) do QuietHideButton(button) end
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
    if type(hooksecurefunc) == "function" and not Marked(frame, "parkHook") then
        Mark(frame, "parkHook", true)
        hooksecurefunc(frame, "Show", function(self)
            if Marked(self, "parked") and Marked(self, "hidden") then pcall(self.Hide, self) end
        end)
    end
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
            pcall(button.SetAttributeNoHandler, button, "statehidden", nil)
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

--- useOnKeyDown 跟着玩家的 cvar 走（按下 / 抬起施法）。cvar 变化时由 SetClickOptions 重写。
local function SetUseOnKeyDown(button)
    local cvar = _G.GetCVarBool and GetCVarBool("ActionButtonUseKeyDown")
    pcall(button.SetAttribute, button, "useOnKeyDown", cvar ~= false)
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
    if ok and info and info.isActive and C_ActionBar.GetActionCooldownDuration then
        local ok2, dur = pcall(C_ActionBar.GetActionCooldownDuration, slot)
        if ok2 then durationObject = dur end
    end


    if durationObject and cooldown.SetCooldownFromDurationObject then
        pcall(cooldown.SetCooldownFromDurationObject, cooldown, durationObject)
    else
        pcall(cooldown.Clear, cooldown)
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

--- 光标落在这一条的第几格（1..12），不在条上返回 nil。
local function IndexAtCursor(bar)
    local cx, cy = CursorUI()
    if not cx or not cy then return nil end
    local frame = bar.frame
    local left, bottom = frame:GetLeft(), frame:GetBottom()
    if not left or not bottom then return nil end
    local s = (frame:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    local x0, y0 = left * s, bottom * s
    local w, h = (frame:GetWidth() or 0) * s, (frame:GetHeight() or 0) * s
    if cx < x0 or cx > x0 + w or cy < y0 or cy > y0 + h then return nil end
    local pitch = (ButtonSize() + Spacing()) * s
    if pitch <= 0 then return nil end
    local index = math.floor((cx - x0) / pitch) + 1
    if index < 1 then index = 1 end
    if index > #bar.buttons then index = #bar.buttons end
    return index
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
local function CreateSecureButton(name, parent, id)
    for _, template in ipairs(BUTTON_TEMPLATES) do
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

local function BuildButton(bar, index)
    local def  = bar.def
    local name = "MonetUI" .. def.key .. "Button" .. index

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
        button:HookScript("OnHide", function(self)
            local popup = _G.SpellFlyout
            if popup and popup.flyoutButton == self then
                pcall(popup.DetatchFromButton, popup)
            end
        end)
    end
    pcall(button.SetAttribute, button, "type", "action")
    pcall(button.SetAttribute, button, "typerelease", "actionrelease")
    pcall(button.SetAttribute, button, "checkselfcast", true)
    pcall(button.SetAttribute, button, "checkfocuscast", true)
    pcall(button.SetAttribute, button, "checkmouseovercast", true)
    SetUseOnKeyDown(button)
    InstallPageChild(button, index)

    -- 拖出 / 拖入：PickupAction / PlaceAction 同样是受保护全局，战斗外可以用（战斗中客户端会拒）。
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

    button.bindName = def.bind .. index
    -- bar 必须是**框体**（SetHotkey 之类还会用到）。
    button.bar      = bar.frame

    SkinButton(button)

    -- 热键文字（跟着玩家的按键设置走）
    SetHotkey(button)

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
local function RefreshBar(bar)
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
    pcall(frame.SetFrameLevel, frame, 60)

    local bar = {
        def        = def,
        index      = def.index,
        frame      = frame,
        buttons    = {},
        visibility = def.paged and VISIBILITY_MAIN or VISIBILITY_OTHER,
    }

    for index = 1, BUTTONS_PER_BAR do
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
        pcall(RegisterStateDriver, frame, "page", def.paged and FULL_PAGE or tostring(def.page))
    end

    LayoutBar(bar)
    PositionBar(bar)
    -- 按钮建好、位置定好后，把当前页下发给它们一次（片段跑，安全环境里写 action）
    PushPageToChildren(bar)
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
local function SuppressAutoCastShine(button)
    local overlay = button.AutoCastOverlay
    if not overlay then return end
    if not overlay.monetShineSuppressed then
        overlay.monetShineSuppressed = true
        if type(overlay.UpdateShineAnim) == "function" then
            overlay.monetShineUpdate = overlay.UpdateShineAnim
            overlay.UpdateShineAnim = function() end
        end
    end
    local shine = overlay.Shine
    if shine then
        if shine.Anim then pcall(shine.Anim.Stop, shine.Anim) end
        shine:Hide()
    end
end

--- 还原成暴雪原样（只在模块整个停用时走这条，否则玩家会永久失去原版提示）。
-- 只是关掉「自绘动作条」不算：那时宠物条归暴雪管，但提示换成一圈静态像素环。
local function RestoreAutoCastShine(button)
    local overlay = button.AutoCastOverlay
    if not overlay or not overlay.monetShineUpdate then return end
    overlay.UpdateShineAnim = overlay.monetShineUpdate
    overlay.monetShineUpdate = nil
    overlay.monetShineSuppressed = nil
    overlay:UpdateShineAnim()
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

    -- 暴雪改按钮显隐时不发事件，直接后钩条自己的 UpdateShownButtons（Lua 方法，安全钩）：
    -- 每次它刷新完，把空槽美术同步一遍。
    if not Marked(bar, "slotHook") then
        Mark(bar, "slotHook", true)
        if type(hooksecurefunc) == "function" and type(bar.UpdateShownButtons) == "function" then
            hooksecurefunc(bar, "UpdateShownButtons", function()
                for index = 1, def.count do
                    local b = _G[def.pattern:format(index)]
                    if b then SyncEmptySlot(b) end
                end
            end)
        end
    end

    for index = 1, def.count do
        local button = _G[def.pattern:format(index)]
        if not button then break end
        if BuildEmptySlot(button) then SyncEmptySlot(button) end
        local icon = button.icon
        if icon then Skin:CropIcon(icon, CROP, 1 - CROP, CROP, 1 - CROP) end
        -- 暴雪的按钮是受保护的（改它自己的美术会把框体弄脏），所以外观由我们垫在它下面的一块
        -- Monet 底板来做：底色和描边换成主题的，图标、键位数字照旧。
        Skin:ControlBg(button, { thickness = 1, bgAlpha = 0.55 })
        -- 暴雪自己的按钮美术（外框 / 按下 / 高亮）收掉，只留图标 —— 和自绘动作条一个样子。
        Skin:FadeButtonArt(button)
        -- 织理 + 顶亮底沉的高光，和自绘动作条同一套材质。
        -- 但收养按钮的图标在 **BACKGROUND/0**（实测 StanceButton1.icon = BACKGROUND/0，
        -- 自绘按钮的图标在 ARTWORK），BACKGROUND/2、3 是同层更高的 sublevel，会画到图标
        -- 上面 —— 姿态条图标上叠着斜纹就是这么来的。CreateTexture 的 sublevel 允许 -8..7，
        -- 所以这里把织理/光泽压到负 sublevel（-2、-1），垫在暴雪图标之下、我们自己的
        -- ControlBg 底板之上。
        Widget:ButtonMaterial(button, {
            alpha = 0, weaveAlpha = 0.25,
            weaveLayer = "BACKGROUND", weaveSublevel = -2,
            layer = "BACKGROUND",      sublevel = -1,
        })
        -- 热键用白色（主题的 edge 色在图标上看不清）。
        Widget:SetFont(button.HotKey, HOTKEY_SIZE, "pixel")
        Widget:SetFont(button.Count, COUNT_SIZE, "pixel")
        if button.HotKey then
            Widget:ColorText(button.HotKey, { r = 1, g = 1, b = 1 })
        end

        -- 我们自己给这些受保护按钮套了美术，暴雪自己的 UpdateShownButtons 就可能被拒
        -- （日志里 PetActionButton7:SetShown() 那一串），结果按钮停在"藏起来"的状态 ——
        -- 表现就是宠物条只显示几个、格子被吃掉。脱战时我们直接把整排显示出来：
        -- 空槽也显示（空格子的美术由 BuildEmptySlot 补），和"10 个按钮"的预期一致。
        if not InCombatLockdown() then
            pcall(button.Show, button)
        end
    end

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
        bindingsDirty = true
        return
    end
    if not (SetOverrideBinding and ClearOverrideBindings) then return end
    bindingsDirty = false

    for _, bar in pairs(bars) do
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
}

-- 冷却事件单独一条轻量路径：只重画冷却框，不重扫 96 个按钮的图标/文字。
local COOLDOWN_EVENTS = {
    "ACTIONBAR_UPDATE_COOLDOWN", "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_CHARGES",
    "SPELL_UPDATE_ICON", "ACTIONBAR_UPDATE_USABLE", "SPELLS_CHANGED",
}

function M:RegisterEvents()
    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        M:Apply()
    end)

    EventBus:Register("PLAYER_REGEN_ENABLED", function()
        M:ReparkBlizzard()
        if bindingsDirty then ReassignBindings() end
        if adoptedDirty then AdoptAll() end
        if refreshDirty then
            refreshDirty = false
            M:UpdateAll()
        end
        if layoutDirty then
            layoutDirty = false
            M:RefreshLayout()
        end
        if not applied then M:Apply() end
    end)

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
        -- 硬来会被客户端拒绝。这次改动记下来，脱战补做。
        layoutDirty = true
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

--- 编辑模式偶尔会把我们换过父的条重新塞回它的托管容器（ApplySystemAnchor → AddManagedFrame），
--- 那些条就会重新出现在屏幕上并吃掉鼠标。脱战后再确认一遍父级，不对就搬回去
--- （战斗中 SetParent 是受保护操作，留给下一次 PLAYER_REGEN_ENABLED）。
function M:ReparkBlizzard()
    if InCombatLockdown() then return end
    local hidden = HiddenParent()
    for _, name in ipairs(ACTION_BAR_FRAMES) do
        local frame = _G[name]
        if frame and name ~= "MainActionBar" and Marked(frame, "parked") then
            if frame:GetParent() ~= hidden then
                pcall(frame.SetParent, frame, hidden)
            end
        end
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
    WatchPages(own)

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

    applied = true
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
        adoptedDirty = false
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
