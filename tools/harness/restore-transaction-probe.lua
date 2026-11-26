-- 还原事务离线回归：真实 Widget.lua + ActionBars/Blizzard.lua。
--   lua tools/harness/restore-transaction-probe.lua

local root = arg[1] or "."
local unpack = table.unpack or unpack
local env = setmetatable({}, { __index = _G })
env._G = env

local Frame = {}
Frame.__index = Frame
local function NewFrame(name)
    return setmetatable({
        name = name, alpha = 0.75, mouse = true, shown = true,
        children = {}, events = { PLAYER_ENTERING_WORLD = true },
    }, Frame)
end
function Frame:GetAlpha() return self.alpha end
function Frame:SetAlpha(alpha)
    if self.failAlpha then return end
    self.alpha = alpha
end
function Frame:EnableMouse(enabled)
    if self.failMouse then return end
    self.mouse = enabled
end
function Frame:EnableMouseClicks(enabled)
    if self.failMouse then return end
    self.clicks = enabled
end
function Frame:EnableMouseMotion(enabled)
    if self.failMouse then return end
    self.motion = enabled
end
function Frame:IsMouseEnabled() return self.mouse end
function Frame:GetChildren() return unpack(self.children) end
function Frame:UnregisterAllEvents() self.events = {} end
function Frame:Show() self.shown = true end
function Frame:Hide()
    if self.failHide then error("mock Hide denied") end
    if not self.silentHide then self.shown = false end
end
function Frame:IsShown() return self.shown end

local marks = setmetatable({}, { __mode = "k" })
local function Data(object)
    local data = marks[object]
    if not data then data = {}; marks[object] = data end
    return data
end
local ns = { combat = false, subscriptions = {}, nextId = 0 }
function ns:Mark(object, key, value)
    local data = Data(object)
    if value == nil then data[key] = nil else data[key] = value end
end
function ns:Marked(object, key) return Data(object)[key] end
function ns:InCombat() return self.combat end
function ns:NewFrameData()
    local store = setmetatable({}, { __mode = "k" })
    return store, function(object)
        local data = store[object]
        if not data then data = {}; store[object] = data end
        return data
    end
end
function ns:GetModule() return ns.module end
local scheduler = { subscriptions = {}, nextId = 0 }
function scheduler:Every(_, fn, label)
    assert(label == "动作条:暴雪框停靠", "停靠驱动缺少标签")
    self.nextId = self.nextId + 1
    self.subscriptions[self.nextId] = fn
    return self.nextId
end
function scheduler:Unregister(id) self.subscriptions[id] = nil end
ns.Scheduler = scheduler
ns.Color = {}
ns.Media = {}
ns.Math = { FX = { hoverFade = 0.1 }, Clamp = function(_, value) return value end }
ns.EventBus = { Register = function() end }
ns.Secrets = {
    IsSecret = function() return false end,
    CanRead = function() return true end,
    Bool = function(value, default) if value == nil then return default end return value end,
}
local locked = false
ns.module = { blizzard = {}, ProtectedLocked = function() return locked end }

local function Load(path)
    local chunk
    if _VERSION == "Lua 5.1" then
        chunk = assert(loadfile(root .. "/" .. path))
        setfenv(chunk, env)
    else
        chunk = assert(loadfile(root .. "/" .. path, "t", env))
    end
    return chunk("MonetUI", ns)
end

Load("Utils/Widget.lua")
local Widget = ns.Widget
local frame, child = NewFrame("Hud"), NewFrame("HudChild")
frame.children[1] = child
assert(Widget:Mute(frame, { depth = 1 }), "Mute 未执行")
assert(frame.alpha == 0 and child.mouse == false, "Mute 未覆盖 alpha 与子树鼠标")

frame.failAlpha = true
assert(Widget:Unmute(frame, { depth = 1 }) == false, "alpha 静默失败被当成成功")
assert(Widget:IsMuted(frame), "失败后提前清除了静音快照")
frame.failAlpha = nil
child.failMouse = true
assert(Widget:Unmute(frame, { depth = 1 }) == false, "子树鼠标静默失败被当成成功")
assert(Widget:IsMuted(frame), "子树失败后提前清除了静音快照")
child.failMouse = nil
assert(Widget:Unmute(frame, { depth = 1 }), "恢复重试未成功")
assert(frame.alpha == 0.75 and frame.mouse and child.mouse, "原状态未完整恢复")
assert(not Widget:IsMuted(frame), "成功后仍保留静音快照")
print("PASS Widget:Mute/Unmute 写失败保留快照并可重试")

child.mouse = false
assert(Widget:Mute(frame, { depth = 1 }))
assert(Widget:Unmute(frame, { depth = 1 }))
assert(not child.mouse, "Unmute 打开了原本关闭鼠标的子框")
print("PASS Widget:Unmute 不打开原本关闭鼠标的子框")

Load("Modules/ActionBars/Blizzard.lua")
local bar = NewFrame("MainActionBar")
local button = NewFrame("ActionButton1")
bar.children[1] = button
bar.actionButtons = { button }
env.MainActionBar = bar

assert(ns.module.blizzard.Park("MainActionBar"), "动作条停靠失败")
assert(bar.alpha == 0 and not bar.mouse and not button.mouse, "动作条子树未静音")
assert(button.events.PLAYER_ENTERING_WORLD, "停靠时卸载了暴雪按钮事件")
bar.failAlpha = true
assert(ns.module.blizzard.Restore("MainActionBar") == false, "动作条还原吞掉 alpha 写失败")
bar.failAlpha = nil
scheduler.subscriptions[1](0.5)
assert(bar.alpha == 0.75 and bar.mouse and button.mouse, "动作条原状态未恢复")
assert(button.events.PLAYER_ENTERING_WORLD, "还原后暴雪按钮事件缺失")
assert(next(scheduler.subscriptions) == nil, "动作条还原后仍保留停靠驱动")
print("PASS 暴雪动作条保留事件、失败重试、成功后摘驱动")

local bag = NewFrame("BagsBar")
env.BagsBar = bag
assert(ns.module.blizzard.ParkBag("BagsBar"), "背包条停靠失败")
assert(not bag.shown and ns:Marked(bag, "hidden"), "背包条停靠未隐藏")
local bagSubId = scheduler.nextId
locked = true
bag:Show()
scheduler.subscriptions[bagSubId](0.5)
assert(not bag.shown, "Map/Chat 限制期间背包条被暴雪 Show 回来后没有补压")
assert(ns.module.blizzard.Restore("BagsBar"), "非保护背包条被限制拖住还原")
assert(bag.shown and bag.alpha == 0.75 and not ns:Marked(bag, "hidden"), "背包条原状态未还原")
assert(scheduler.subscriptions[bagSubId] == nil, "背包条还原后仍保留停靠驱动")

bag.silentHide = true
assert(ns.module.blizzard.ParkBag("BagsBar") == false, "背包条 Hide 静默失败被当成成功")
assert(not ns:Marked(bag, "hidden"), "Hide 失败后仍发布停靠状态")
bag.silentHide = nil
assert(ns.module.blizzard.ParkBag("BagsBar"), "背包条停靠重试失败")
bagSubId = scheduler.nextId
bag.alpha = 0
bag.failAlpha = true
assert(ns.module.blizzard.Restore("BagsBar") == false, "背包条 alpha 静默失败被当成成功")
assert(ns:Marked(bag, "hidden") and scheduler.subscriptions[bagSubId], "背包条还原失败后丢失快照/重试")
bag.failAlpha = nil
scheduler.subscriptions[bagSubId](0.5)
assert(bag.shown and bag.alpha == 0.75 and not ns:Marked(bag, "hidden"), "限制中背包条还原重试未成功")
print("PASS 背包条限制期补压、写读回校验、失败重试与完整还原")

print("ALL PASS")
