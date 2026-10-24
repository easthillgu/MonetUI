-- Modules/Minimap/Pins.lua
-- 小地图的可见区是"正方画布 + 遮罩裁掉上下两条带（上 40 / 下 26）"裁出来的，第三方小地图 pin 不吃 Minimap
-- 的遮罩：它们是挂在 Minimap 上的独立 frame，落进那两条带子里会浮在面板外（WindTools 的
-- RectangleMinimap 为此专门写了一整段补丁）。这里把 HereBeDragons-Pins-2.0 的 pin 按
-- "可见带半高"压掉 alpha，离开带子再按原值放回去。
--
-- 只在模块开着时生效：模块一关就把压下去的全放回去。
-- 没装 HBD 时整段空转 —— 不注册事件、不装钩子。
-- 依赖的是 HBD 的公开入口（AddMinimapIcon*）与它的 pin 表（minimapPins /
-- activeMinimapPins），两者都按存在性判断：版本不对就退化成一件事都不做，不报错。
--
-- 为什么用 alpha 而不是 Hide()：HBD 每次都先 Show() 再 SetPoint()，Hide 会被它自己推翻，
-- 两边会打架；压 alpha 不碰它的状态机（WindTools 同一做法）。

local ADDON_NAME, ns = ...

local Secrets = ns.Secrets

local P = {}

local HBD_MAJOR = "HereBeDragons-Pins-2.0"

-- 弱键表：HBD 的 pin 池会复用、也会释放
local seen   = setmetatable({}, { __mode = "k" })   -- pin -> true（钩子只装一次）
local hidden = setmetatable({}, { __mode = "k" })   -- pin -> 压掉之前的 alpha

local writing    = false   -- 我们自己正在 SetAlpha，别让 SetAlpha 钩子再进来
local lib                  -- HBD Pins 库
local module               -- ns:GetModule("Minimap")

local function Module()
    if not module then module = ns:GetModule("Minimap") end
    return module
end

--- 现在该不该管这些 pin：模块开着就管（可见带永远是遮罩裁出来的）。
local function Wanted()
    local m = Module()
    return m ~= nil and m:IsActive()
end

--- 读 pin 相对地图中心的纵向偏移（UI 单位）。
--- HBD 把 pin 锚成 CENTER ← Minimap:CENTER，offsetY 就是我们要的数；
--- 被别的插件重锚过就退回中心点相减（pin 挂在 Minimap 上，两者缩放一致）。
local function OffsetY(pin, minimap)
    local ok, point, relTo, _, _, y = pcall(pin.GetPoint, pin, 1)
    if ok and point == "CENTER" and relTo == minimap and type(y) == "number" then
        return y
    end
    local okPin, _, pinY = pcall(pin.GetCenter, pin)
    local okMap, _, mapY = pcall(minimap.GetCenter, minimap)
    if okPin and okMap and type(pinY) == "number" and type(mapY) == "number" then
        return pinY - mapY
    end
    return nil
end

--- 压掉 / 放回一个 pin 的 alpha。
--- 原值只记第一次：重复套用不会被我们自己写进去的 0 覆盖成"原值 0"。
--- 已经压着的就不再写 —— HBD 每 0.1 秒会给每个 pin 重设一次锚点，别每次都调 SetAlpha。
local function ApplyAlpha(pin, hide)
    if writing then return end
    if not hide then
        local alpha = hidden[pin]
        if alpha == nil then return end
        hidden[pin] = nil
        writing = true
        pcall(pin.SetAlpha, pin, alpha)
        writing = false
        return
    end

    if hidden[pin] ~= nil then return end
    local ok, alpha = pcall(pin.GetAlpha, pin)
    if not ok or type(alpha) ~= "number" or Secrets.IsSecret(alpha) then alpha = 1 end
    hidden[pin] = alpha

    writing = true
    pcall(pin.SetAlpha, pin, 0)
    writing = false
end

--- 按 pin 当前位置决定压不压。
local function Refresh(pin)
    if not pin then return end
    local minimap = _G.Minimap
    local m = Module()
    if not minimap or not m or not Wanted() then
        ApplyAlpha(pin, false)
        return
    end
    local y = OffsetY(pin, minimap)
    -- 读不到位置就保持原状（宁可多一个 pin，也不要因为读失败把地图上的 pin 全压掉）
    if not y then return end
    local top, bottom = m:VisibleBand()
    ApplyAlpha(pin, y > top or y < bottom)
end

--- 给一个 pin 登记（不挂任何钩子）：位置/显隐由 0.5 秒的驱动重算。
--- 以前这里 hooksecurefunc(SetPoint/Show/SetAlpha)，写的是第三方库帧的方法槽，
--- 同样属于"污染"（见 AGENTS 的皮肤原则），而且这些帧每次更新都会跑我们的代码。
local function HookPin(pin)
    if not pin or seen[pin] then return end
    seen[pin] = true

    if type(pin.IsObjectType) == "function" then
        local ok, isFrame = pcall(pin.IsObjectType, pin, "Frame")
        if not ok or not isFrame then return end
    elseif type(pin.SetAlpha) ~= "function" then
        return
    end
end

--- 扫一遍 HBD 的 pin 表：给所有见过的 pin 装钩子，只对"当前活动的"重算位置。
local function Sweep()
    if not lib then return end
    if type(lib.minimapPins) == "table" then
        for pin in pairs(lib.minimapPins) do HookPin(pin) end
    end
    if type(lib.activeMinimapPins) == "table" then
        for pin in pairs(lib.activeMinimapPins) do
            HookPin(pin)
            Refresh(pin)
        end
    end
end

--- 先把自己压着的都放回去，再按当前状态重算（模块关了 / 重新套皮都要还原再算）。
local function RefreshAll()
    for pin in pairs(hidden) do ApplyAlpha(pin, false) end
    if not Wanted() then return end
    Sweep()
end

local function FindLib()
    local stub = _G.LibStub
    if type(stub) ~= "function" then return nil end
    local ok, found = pcall(stub, HBD_MAJOR, true)
    if not ok or type(found) ~= "table" then return nil end
    return found
end


--- 0.5 秒一次的驱动：扫 pin 表（新 pin 会被登记）+ 重算位置。代替原来的 Add 钩子。
local driver
local function EnsureDriver()
    if driver then return end
    driver = CreateFrame("Frame")
    local acc = 0
    driver:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 0.5 then return end
        acc = 0
        Sweep()
    end)
end

--- 每次套皮都调（幂等）：找库、启动驱动、把现有 pin 扫一遍。
function P:Apply()
    lib = lib or FindLib()
    if not lib then return end
    EnsureDriver()
    RefreshAll()
end

--- 关模块：把压下去的 pin 全部放回去。
function P:Restore()
    for pin in pairs(hidden) do ApplyAlpha(pin, false) end
end

--- 给 `/mui minimap diagnose` 用：HBD 有没有接上、现在压着几个、活动 pin 有几个。
function P:Status()
    local hiding = 0
    for _ in pairs(hidden) do hiding = hiding + 1 end
    local active = 0
    if lib and type(lib.activeMinimapPins) == "table" then
        for _ in pairs(lib.activeMinimapPins) do active = active + 1 end
    end
    return lib ~= nil, hiding, active
end

-- HBD 可能比我们晚加载：它一落地就把皮肤按一遍（Apply 自己幂等）。
ns.EventBus:Register("ADDON_LOADED", function()
    if lib then return end
    local m = Module()
    if m and m:IsActive() then P:Apply() end
end)

ns:GetModule("Minimap").pins = P
