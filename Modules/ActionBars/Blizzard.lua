-- Modules/ActionBars/Blizzard.lua
-- 暴雪自己那几条动作条的"压制 / 归还"（P5' 拆分，2026-10-26）：
--   * Park / ParkBag：动作条只做 alpha 0 + 关鼠标；非保护背包条走 Hide；
--   * KeepParked + ParkWatch：0.5 秒的独立驱动，暴雪把条 Show 回来就再压一次；
--   * Restore：原样放回去（模块停用、或玩家改回用暴雪动作条时）；
--   * M:ParkBlizzard / M:RestoreBlizzard：按清单批处理，Apply / SetEnabled 调它。
-- 接口面：
--   * 输入：ns:Mark / ns:Marked（旁表标记，不往暴雪框体上写字段）；
--   * 输出：M.blizzard.Park / M.blizzard.ParkBag / M.blizzard.Restore（Apply 里背包条那两处调用），
--           以及仍然挂在模块上的 M:ParkBlizzard / M:RestoreBlizzard。

local ADDON_NAME, ns = ...
local Scheduler = ns.Scheduler

local M = ns:GetModule("ActionBars")
if not M then return end

local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
-- 模块私有的幂等守卫键走 per-module 弱旁表（ns:NewFrameData）；hidden（与 Skin 共享）仍走 Mark/Marked。
local FFD, GetFFD = ns:NewFrameData()
local Widget = ns.Widget
local Secrets = ns.Secrets
local Locked = M.ProtectedLocked

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

--- 收起动作条只改 alpha 与鼠标，不换父、不 Hide、不卸事件、不写属性。
--- 定时补压不能换成 Show 钩子：安全钩子会插进暴雪自己的受保护调用链。
local parkedList = {}
local parkSubId
local Restore

local function KeepParked()
    for i = #parkedList, 1, -1 do
        local frame = parkedList[i]
        local data = GetFFD(frame)
        if data.parked then
            if data.restoring then
                -- 背包条是非保护框，Map/Chat 限制不该拖住它的还原。
                if Marked(frame, "hidden") or not Locked() then
                    Restore(data.name)
                end
            elseif Marked(frame, "hidden") then
                -- ParkBag 那条路：暴雪把它 Show 回来就再藏一次。它不是受保护动作条，
                -- 六类限制里也必须补压，否则副本/聊天窗口会露出原背包条。
                if frame:IsShown() then pcall(frame.Hide, frame) end
            elseif not Locked() and frame:GetAlpha() > 0 then
                -- 暴雪在变形 / 载具 / 翻页之后把 alpha 顶回来了：再压一次（子树鼠标顺带复检，
                -- 新池化出来的按钮也在这一步被关掉）。
                Widget:Mute(frame, { depth = 2 })
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

    if parkSubId then return end
    parkSubId = Scheduler:Every(500, KeepParked, "动作条:暴雪框停靠")
end

local function Park(name)
    local frame = _G[name]
    if not frame or GetFFD(frame).parked then return false end
    if not Widget:Mute(frame, { depth = 2 }) then return false end
    GetFFD(frame).parked = true
    GetFFD(frame).name = name

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
    -- 全仓唯一的一份"收起暴雪 HUD"：alpha 0 + 整棵子树关鼠标，原状态记在旁表里，
    -- Restore 逐项还原（以前这里只关根框，子树是漏的）。
    -- Park 由脱战 Apply 调用；0.5 秒补刀在六类限制里都跳过，不能强行写受保护子树。
    -- 整棵子树都关鼠标：alpha 0 只是看不见，按钮/容器照样收 OnEnter，而一进战斗
    -- 暴雪按钮的 OnEnter（ActionButton.lua:1391）会 UpdateAction → SetAttribute，
    -- 那一下会被判 BLOCKED（taint.log 里 335 条全是这一类）。
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

    return true
end

--- 背包条走 Hide：它的位置正好压在我们的小地图上，而小地图在 LOW 层，铺不了点击板
--- （板子必须在 MEDIUM 才盖得住暴雪的按钮，那样会连小地图一起挡掉）。
--- 背包条不是动作条那种"被 SetShownBase 复活"的框体，Hide 之后不会再自己冒出来。
local function ParkBag(name)
    local frame = _G[name]
    if not frame or GetFFD(frame).parked then return false end
    if not pcall(frame.Hide, frame) then return false end
    local okShown, shown = pcall(frame.IsShown, frame)
    if not okShown or Secrets.Bool(shown, false) then return false end
    GetFFD(frame).parked = true
    GetFFD(frame).name = name
    Mark(frame, "hidden", true)
    GetFFD(frame).alpha = frame:GetAlpha()
    -- 同样不挂 Show 后钩（会夹在暴雪调用链里）：交给 0.5s 的驱动再藏一次。
    ParkWatch(frame)
    return true
end

local function StopParkWatch(frame)
    for i = #parkedList, 1, -1 do
        if parkedList[i] == frame then table.remove(parkedList, i) end
    end
    if #parkedList == 0 and parkSubId then
        Scheduler:Unregister(parkSubId)
        parkSubId = nil
    end
end

Restore = function(name)
    local frame = _G[name]
    if not frame or not GetFFD(frame).parked then return false end
    local data = GetFFD(frame)
    data.restoring = true
    if Marked(frame, "hidden") then
        local alpha = data.alpha or 1
        if not pcall(frame.Show, frame) or not pcall(frame.SetAlpha, frame, alpha) then return false end
        local okShown, shown = pcall(frame.IsShown, frame)
        local okAlpha, current = pcall(frame.GetAlpha, frame)
        if not okShown or not Secrets.Bool(shown, false)
            or not okAlpha or not Secrets.CanRead(current) or current ~= alpha then
            return false
        end
        Mark(frame, "hidden", nil)
        data.alpha = nil
    elseif not Widget:Unmute(frame, { depth = 2 }) then
        return false
    end
    data.parked = nil
    data.name = nil
    data.restoring = nil
    StopParkWatch(frame)
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
