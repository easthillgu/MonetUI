-- 姓名板原生视觉压制离线回归：真实 Nameplates.lua + 模拟暴雪重设 alpha / 框体池复用。
--   lua tools/harness/nameplate-suppression-probe.lua

local root = arg[1] or "."
local unpack = table.unpack or unpack
local env = setmetatable({}, { __index = _G })
env._G = env

local Node = {}
Node.__index = Node
local function NewNode(name, alpha, ignoresParentAlpha)
    return setmetatable({
        name = name, alpha = alpha or 0.65, ignoresParentAlpha = ignoresParentAlpha,
        children = {}, regions = {}, shown = true, alphaWrites = 0,
    }, Node)
end
function Node:GetAlpha()
    if self.unreadableAlpha then error("mock alpha forbidden") end
    return self.alpha
end
function Node:SetAlpha(alpha)
    self.alphaWrites = self.alphaWrites + 1
    if self.failAlpha then return end
    self.alpha = alpha
end
function Node:IsIgnoringParentAlpha() return self.ignoresParentAlpha end
function Node:GetChildren() return unpack(self.children) end
function Node:GetRegions() return unpack(self.regions) end
function Node:IsShown() return self.shown end
function Node:Show() self.shown = true end
function Node:Hide() self.shown = false end
function Node:SetScript() end
function Node:UnregisterAllEvents() end

local marks = setmetatable({}, { __mode = "k" })
local scheduler = { subscriptions = {}, nextId = 0, unregistered = 0 }
function scheduler:Profile(_, _, fn) return fn end
function scheduler:EveryFrame(fn, label)
    assert(label == "姓名板:守卫", "姓名板守卫缺少标签")
    self.nextId = self.nextId + 1
    self.subscriptions[self.nextId] = fn
    return self.nextId
end
function scheduler:Unregister(id)
    assert(self.subscriptions[id], "重复注销姓名板守卫")
    self.subscriptions[id] = nil
    self.unregistered = self.unregistered + 1
end

local module = {}
local ns = {
    Widget = { BORDER = 1, TEXT_GAP = 2 }, Color = {}, EventBus = { Register = function() end },
    Scheduler = scheduler, DEFAULTS = { nameplates = { showAuras = false } },
    Secrets = {
        IsSecret = function() return false end,
        CanRead = function() return true end,
        Bool = function(value, default) if value == nil then return default end return value end,
        Number = function(value) return value end,
    },
}
function ns:InCombat() return false end
function ns:Mark(object, key, value)
    local data = marks[object]
    if not data then data = {}; marks[object] = data end
    if value == nil then data[key] = nil else data[key] = value end
end
function ns:Marked(object, key)
    local data = marks[object]
    return data and data[key]
end
function ns:Register(name, value)
    assert(name == "Nameplates", "加载到的模块不正确")
    module = value
end

local chunk
if _VERSION == "Lua 5.1" then
    chunk = assert(loadfile(root .. "/Modules/Nameplates/Nameplates.lua"))
    setfenv(chunk, env)
else
    chunk = assert(loadfile(root .. "/Modules/Nameplates/Nameplates.lua", "t", env))
end
chunk("MonetUI", ns)
local M = module
M.active = true

local function Upvalue(fn, wanted)
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if name == wanted then return value end
    end
    error("找不到 Nameplates 局部变量: " .. wanted)
end
local Hide = Upvalue(M.UpdatePlate, "HideBlizzardPlate")
local Keep = Upvalue(M.UpdatePlate, "KeepBlizzardHidden")
local Restore = Upvalue(M.UpdatePlate, "RestoreBlizzardPlate")
local GuardTick = Upvalue(M.SyncGuard, "GuardTick")
local plates = Upvalue(M.Added, "plates")
local FadeNativeNode = Upvalue(Keep, "FadeNativeNode")
local RestoreNativeBase = Upvalue(GuardTick, "RestoreNativeBase")
local fadedNodes = Upvalue(FadeNativeNode, "fadedNodes")
local pendingRestores = Upvalue(RestoreNativeBase, "pendingRestores")
local restoreRetryAt = Upvalue(GuardTick, "restoreRetryAt")
local Tick = scheduler.subscriptions[1]

local base, uf, sibling, nested, highlight, inherited = NewNode("Base", 0.9), NewNode("UF", 0.8)
sibling, nested = NewNode("Sibling", 0.7), NewNode("Nested", 0.6)
highlight, inherited = NewNode("Selection", 0.25, true), NewNode("InheritedRegion", 0.4)
base.UnitFrame = uf
base.children = { uf, sibling }
uf.children = { nested }
uf.regions = { highlight, inherited }
local plate = NewNode("MonetPlate")
plates.nameplate1 = plate
plate.base = base

assert(Hide(base, plate), "原生姓名板接管失败")
M:SyncGuard()
local _, Tick = next(scheduler.subscriptions)
assert(Tick and type(Tick) == "function", "接管后未注册逐帧守卫")
assert(uf.alpha == 0 and sibling.alpha == 0 and nested.alpha == 0, "原生帧未完整压制")
assert(highlight.alpha == 0 and inherited.alpha == 0, "原生 region 未压制")
assert(#plate.fastFaded == 3 and #plate.deepFaded == 2, "ignoreParentAlpha 节点没有进入逐帧列表")
print("PASS 首次接管覆盖 UnitFrame、兄弟帧、深层 region 与 ignoreParentAlpha")

uf.alpha, sibling.alpha, highlight.alpha = 1, 1, 0.8
Tick(0.016)
assert(uf.alpha == 0 and sibling.alpha == 0 and highlight.alpha == 0, "已知节点未在下一帧回压")
local inheritedWrites = inherited.alphaWrites
Tick(0.016)
assert(inherited.alphaWrites == inheritedWrites, "已经压住的普通节点仍在重复写 alpha")
uf.unreadableAlpha, uf.alpha = true, 1
Tick(0.016)
assert(uf.alpha == 0, "alpha 读不出来时没有继续回压")
uf.unreadableAlpha = nil
print("PASS 暴雪重设 alpha 后逐帧回压，ignoreParentAlpha 不等全树扫描")

local late = NewNode("LateBuff", 1)
base.children[#base.children + 1] = late
Tick(0.1)
assert(late.alpha == 1, "探针在低频扫描前就制造了被测状态")
Tick(0.1)
assert(late.alpha == 1, "尚未到 250ms 不应执行全树扫描")
Tick(0.05)
assert(late.alpha == 0 and fadedNodes[late].alpha == 1, "动态新建子框未在补扫中压制并留快照")
local lateHighlight = NewNode("LateSelection", 1, true)
uf.regions[#uf.regions + 1] = lateHighlight
Tick(0.3)
assert(lateHighlight.alpha == 0, "动态 ignoreParentAlpha region 未被补扫压制")
lateHighlight.alpha = 1
Tick(0.016)
assert(lateHighlight.alpha == 0, "动态 ignoreParentAlpha region 未进入逐帧回压")
print("PASS 动态新建原生子框由低频全树补扫接管")

local priorUf, priorSibling, priorHighlight = 0.8, 0.7, 0.25
highlight.failAlpha = true
assert(Restore(base, plate) == false, "静默写失败被误判为还原成功")
assert(pendingRestores[base], "还原失败后没有保留欠账")
assert(uf.alpha == priorUf and sibling.alpha == priorSibling, "其它已成功节点没有恢复")
local attempts = highlight.alphaWrites
Tick(0.016)
assert(highlight.alphaWrites == attempts + 1, "首个守卫 tick 应重试失败节点")
attempts = highlight.alphaWrites
Tick(0.2)
assert(highlight.alphaWrites == attempts, "失败还原仍在每帧重试")
highlight.failAlpha = nil
Tick(0.05)
assert(highlight.alpha == priorHighlight and not pendingRestores[base], "重试成功后未恢复 alpha 或未清欠账")
assert(scheduler.unregistered == 1 and next(scheduler.subscriptions) == nil, "全部还原后未摘掉守卫")
assert(not restoreRetryAt[base], "成功后仍保留重试时间")
print("PASS 还原写失败保留欠账、限频重试，成功后摘除逐帧守卫")

-- 同一 base 换池中的 UnitFrame：旧快照必须还原，新对象必须重新接管。
local oldUf = NewNode("PooledUF1", 0.55)
local newUf = NewNode("PooledUF2", 0.45)
local pooledBase = NewNode("PooledBase")
local pooledPlate = NewNode("PooledMonetPlate")
pooledBase.UnitFrame = oldUf
pooledBase.children = { oldUf }
plates.nameplate2 = pooledPlate
pooledPlate.base = pooledBase
assert(Hide(pooledBase, pooledPlate))
oldUf.failAlpha = true
pooledBase.UnitFrame = newUf
pooledBase.children = { newUf }
Keep(pooledPlate, false)
assert(pendingRestores[pooledBase], "换池时旧节点还原失败被丢弃")
assert(newUf.alpha == 0 and pooledPlate.blizzardUF == newUf, "新 UnitFrame 未重新接管")
M:SyncGuard()
local _, Tick = next(scheduler.subscriptions)
oldUf.failAlpha = nil
Tick(0.3)
assert(oldUf.alpha == 0.55 and newUf.alpha == 0, "旧 UnitFrame 未按原快照恢复，或新 UnitFrame 被旧快照顶亮")
assert(not pendingRestores[pooledBase], "换池还原欠账未清")
print("PASS 框体池替换 UnitFrame 时保留旧欠账并隔离新旧快照")

-- 已经在 alpha=0 的共享节点换主时，也必须把还原责任转给新 base。
local shared = NewNode("SharedNode", 0.35)
local ownerA, ownerB = NewNode("OwnerA"), NewNode("OwnerB")
local ownerPlateA, ownerPlateB = NewNode("PlateA"), NewNode("PlateB")
ownerA.children = { shared }
ownerB.children = { shared }
ownerA.UnitFrame = shared
ownerB.UnitFrame = shared
assert(Hide(ownerA, ownerPlateA))
shared.alpha = 0
assert(Hide(ownerB, ownerPlateB))
Keep(ownerPlateB, true)
assert(fadedNodes[shared].base == ownerB and fadedNodes[shared].alpha == 0.35, "alpha=0 节点换主时丢失原快照或归属")
assert(Restore(ownerA, ownerPlateA))
assert(shared.alpha == 0, "旧 base 仍能改写已换主的节点")
assert(Restore(ownerB, ownerPlateB))
assert(shared.alpha == 0.35, "新 base 未恢复共享节点原 alpha")
print("PASS alpha=0 的复用节点随新 base 转移还原责任")

local removedBase, removedUf = NewNode("RemovedBase"), NewNode("RemovedUF", 0.75)
removedBase.UnitFrame = removedUf
removedBase.children = { removedUf }
local removedPlate = NewNode("RemovedPlate")
plates.nameplate3 = removedPlate
removedPlate.base = removedBase
assert(Hide(removedBase, removedPlate))
assert(M.Removed("nameplate3"))
assert(removedUf.alpha == 0.75 and not plates.nameplate3, "移除事件未在框体回池前恢复原生 alpha")
print("PASS 姓名板移除事件先恢复原生视觉再交还框体")

plates.nameplate2 = nil
pooledPlate.blizzardHidden = nil
M:SyncGuard()
assert(next(scheduler.subscriptions) == nil, "交还最后一块牌后守卫未注销")
print("ALL PASS")
