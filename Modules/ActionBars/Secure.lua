-- Modules/ActionBars/Secure.lua
-- 安全片段的生成与注入（P5' 拆分，2026-10-28）：状态驱动的条件串与 _onstate 片段、
-- 按钮的 _childupdate 子片段（page / kind / keydown），以及把它们装上 / 下发的函数。
-- 接口面：
--   * 输入：无（Mark/Marked 在本文件重新包一层 ns:Mark，与主文件同款两行包装）；
--   * 输出：M.secure.ON_STATE_PAGE / VISIBILITY_MAIN / VISIBILITY_OTHER / FULL_PAGE /
--     EXIT_SNIPPET / InstallPageChild / InstallSecureInit / PushSecureInit /
--     PushPageToChildren / SetUseOnKeyDown（主文件调用点已改名走这里）。
--
-- **为什么这一段是全仓最敏感的**：槽位（action）与点击属性（type / typerelease /
-- checkselfcast / useOnKeyDown）只能由片段在安全环境里写，Lua 写进去的是脏值——
-- 详见下方 PAGE_CHILD / KIND_CHILD 两段长注释。

local ADDON_NAME, ns = ...

local M = ns:GetModule("ActionBars")
if not M then return end

local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

M.secure = M.secure or {}

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

M.secure.ON_STATE_PAGE      = ON_STATE_PAGE
M.secure.VISIBILITY_MAIN    = VISIBILITY_MAIN
M.secure.VISIBILITY_OTHER   = VISIBILITY_OTHER
M.secure.FULL_PAGE          = FULL_PAGE
M.secure.EXIT_SNIPPET       = EXIT_SNIPPET
M.secure.PAGE_CHILD         = PAGE_CHILD
M.secure.InstallPageChild   = InstallPageChild
M.secure.InstallSecureInit  = InstallSecureInit
M.secure.PushSecureInit     = PushSecureInit
M.secure.PushPageToChildren = PushPageToChildren
M.secure.SetUseOnKeyDown    = SetUseOnKeyDown
