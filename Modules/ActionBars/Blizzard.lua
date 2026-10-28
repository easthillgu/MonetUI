-- Modules/ActionBars/Blizzard.lua
-- 暴雪自己那几条动作条的"压制 / 归还"（P5' 拆分，2026-10-26）：
--   * Park / ParkBag：把暴雪的条收起来（alpha 0 + 关鼠标，绝不 Hide/SetParent）；
--   * KeepParked + ParkWatch：0.5 秒的独立驱动，暴雪把条 Show 回来就再压一次；
--   * Restore：原样放回去（模块停用、或玩家改回用暴雪动作条时）；
--   * M:ParkBlizzard / M:RestoreBlizzard：按清单批处理，Apply / SetEnabled 调它。
-- move-only：逻辑原样搬自 ActionBars.lua；接口面：
--   * 输入：ns:Mark / ns:Marked（旁表标记，不往暴雪框体上写字段）；
--   * 输出：M.blizzard.Park / M.blizzard.ParkBag / M.blizzard.Restore（Apply 里背包条那两处调用），
--           以及仍然挂在模块上的 M:ParkBlizzard / M:RestoreBlizzard。

local ADDON_NAME, ns = ...

local M = ns:GetModule("ActionBars")
if not M then return end

local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

-- 8 条动作条：暴雪那几条只做 alpha 0（见 Park），点击板盖住它们看不见的裸按钮；
-- 显示与施法全部由我们自己的按钮承担（槽位由安全片段写，见 Secure.lua 的 PAGE_CHILD 段）。
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

-- Apply 里背包条那两处直接叫 Park：模块方法在别的文件里也能拿到同一份实现。
M.blizzard = {
    Park = Park,
    ParkBag = ParkBag,
    Restore = Restore,
}
