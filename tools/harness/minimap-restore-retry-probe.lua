-- 小地图按钮还原重试 + ping 原生透传离线回归：加载真实 Buttons.lua / Minimap.lua，注入受限与静默写失败。
--   lua tools/harness/minimap-restore-retry-probe.lua

local root = arg[1] or "."
local unpack = table.unpack or unpack
local env = setmetatable({}, { __index = _G })
env._G = env

local Region = {}
Region.__index = Region
function Region:GetAlpha() return self.alpha end
function Region:SetAlpha(alpha)
    if self.failAlpha then return end
    self.alpha = alpha
end
function Region:Show() self.shown = true end
function Region:Hide() self.shown = false end
function Region:IsShown() return self.shown end
function Region:SetTexture(texture) self.texture = texture end
function Region:SetPoint(...) self.points = { ... } end
function Region:SetSize(width, height) self.width, self.height = width, height end
function Region:SetVertexColor(...) self.color = { ... } end
function Region:SetAllPoints(...) self.allPoints = { ... } end

local Frame = {}
Frame.__index = Frame
function Frame:GetParent() return self.parent end
function Frame:SetParent(parent)
    if self.failParent then self.failParent = false; error("mock SetParent denied") end
    self.parent = parent
end
function Frame:ClearAllPoints() self.pointList = {} end
function Frame:SetPoint(...) self.pointList[#self.pointList + 1] = { ... } end
function Frame:GetNumPoints() return #self.pointList end
function Frame:GetPoint(index) return unpack(self.pointList[index]) end
function Frame:SetSize(width, height)
    if self.failSize then self.failSize = false; return end
    self.width, self.height = width, height
end
function Frame:SetAllPoints(...) self.allPoints = { ... } end
function Frame:GetWidth() return self.width end
function Frame:GetHeight() return self.height end
function Frame:SetShown(shown) self.shown = shown end
function Frame:EnableMouse(enabled) self.mouse = enabled end
function Frame:IsMouseEnabled() return self.mouse end
function Frame:GetAlpha() return self.alpha end
function Frame:SetAlpha(alpha)
    if self.failAlpha then self.failAlpha = false; return end
    self.alpha = alpha
end
function Frame:CreateTexture() return setmetatable({ alpha = 1, shown = true }, Region) end
function Frame:GetChildren() return end
function Frame:GetRegions() return end

local function NewFrame(name, parent)
    return setmetatable({
        name = name, parent = parent, pointList = {}, width = 32, height = 24,
        alpha = 0.8, mouse = true, shown = true,
    }, Frame)
end

local Blocker = {}
Blocker.__index = function(_, key)
    local method = Frame[key]
    if method then return method end
    return Blocker[key]
end
function Blocker:SetScript(name, fn) self.scripts[name] = fn end
function Blocker:HookScript(name, fn) self.scripts[name] = fn end
function Blocker:GetFrameLevel() return 1 end
function Blocker:SetFrameLevel() end
function Blocker:SetPropagateMouseMotion() end
function Blocker:SetPropagateMouseClicks(value) self.propagateMouseClicks = value end
function Blocker:SetShown(shown) self.shown = shown end
function Blocker:GetParent() return self.parent end
function Blocker:SetParent(parent) self.parent = parent end
function Blocker:ClearAllPoints() end
function Blocker:SetPoint() end
function Blocker:GetWidth() return 256 end

function env.CreateFrame(_, name)
    local frame = setmetatable({ scripts = {} }, Blocker)
    if name then env[name] = frame end
    return frame
end

local oldParent, button = NewFrame("Tracking"), nil
button = NewFrame("TrackingButton", oldParent)
button.NormalTexture = setmetatable({ alpha = 0.65 }, Region)
button:SetPoint("CENTER", oldParent, "CENTER", 7, -3)
env.UIParent = NewFrame("UIParent")
env.MinimapCluster = { Tracking = { Button = button } }
env.InCombatLockdown = function() return env.combat end
env.UnitAffectingCombat = function() return env.combat end
env.GetInstanceInfo = function() return nil, "none" end
local cursor = { 130, 70 }
env.GetCursorPosition = function() return cursor[1], cursor[2] end
env.combat = false
env.restricted = false

local marks = setmetatable({}, { __mode = "k" })
local function Data(object)
    local data = marks[object]
    if not data then data = {}; marks[object] = data end
    return data
end
local settings = { mapTracking = true, mapCompartment = false, mapDifficulty = false, mapQueueStatus = false }
local module = { settings = settings }
function module:GetSettings() return self.settings end
function module:IsActive() return true end

local scheduler = { subscriptions = {}, registrations = 0, unregistrations = 0 }
function scheduler:Every(_, fn, label)
    assert(label == "小地图:按钮还原重试", "还原重试缺少标签")
    self.registrations = self.registrations + 1
    self.id = self.registrations
    self.subscriptions[self.id] = fn
    return self.id
end
function scheduler:Unregister(id)
    assert(self.subscriptions[id], "重复注销还原重试")
    self.subscriptions[id] = nil
    self.unregistrations = self.unregistrations + 1
end
local widget = {}
function widget:CreateFrame() return NewFrame("MonetUIMinimapButtons") end
function widget:Font()
    local font = NewFrame("ZoneText")
    function font:SetPoint() end
    function font:SetWordWrap() end
    function font:SetShadowOffset() end
    function font:SetWidth(width) self.width = width end
    function font:Hide() self.shown = false end
    return font
end
function widget:PollWatch() end
function widget:Unwatch() end
function widget:HoverWatch() end
local skin = { GlyphBadgeOff = function() end }
local registered = {}
local ns = {
    Widget = widget, Skin = skin, Scheduler = scheduler,
    Media = { Texture = function(_, key) return key end },
    Secrets = {
        IsSecret = function(value) return value == env.secret end,
        Number = function(value)
            if value == env.secret then return nil end
            if type(value) == "number" then return value + 0 end
        end,
        Bool = function(value, default)
            if value == env.secret then return default end
            return value and true or false
        end,
    },
    EventBus = { Register = function() end },
    Color = { GetBorder = function() return 1, 1, 1 end, Get = function() return 1, 1, 1 end },
}
function ns:Mark(object, key, value)
    local data = Data(object)
    if value == nil then data[key] = nil else data[key] = value end
end
function ns:Marked(object, key) return Data(object)[key] end
function ns:NewFrameData()
    local store = setmetatable({}, { __mode = "k" })
    return store, function(object)
        local data = store[object]
        if not data then data = {}; store[object] = data end
        return data
    end
end
function ns.ResolveObject(path)
    if path == "MinimapCluster.Tracking.Button" then return button end
end
function ns:GetModule() return module end
function ns:Register(name, value) registered[name] = value end
function ns:IsRestricted() return env.restricted end
function ns.InCombat() return env.combat end
function ns:AfterCombat() end
function ns:DB() return { minimap = { scrollZoom = false, microMenu = false, microMenuSecure = false } } end

local chunk
if _VERSION == "Lua 5.1" then
    chunk = assert(loadfile(root .. "/Modules/Minimap/Buttons.lua"))
    setfenv(chunk, env)
else
    chunk = assert(loadfile(root .. "/Modules/Minimap/Buttons.lua", "t", env))
end
chunk("MonetUI", ns)
local B = module.buttons
local overlay = NewFrame("Overlay")

B:Apply(overlay)
assert(button:GetParent() ~= oldParent and button.width == B.WIDTH, "按钮未被收养")
settings.mapTracking = false
env.combat = true
B:Apply(overlay)
assert(scheduler.registrations == 1 and button:GetParent() ~= oldParent, "受限时未保留快照与重试")
env.combat = false
button.failParent = true
scheduler.subscriptions[scheduler.id](0.5)
assert(scheduler.registrations == 1 and button:GetParent() ~= oldParent, "写失败后丢失快照或重复注册")
scheduler.subscriptions[scheduler.id](0.5)
assert(button:GetParent() == oldParent, "重试后父级未恢复")
assert(button.width == 32 and button.height == 24 and button:GetNumPoints() == 1, "重试后几何未恢复")
assert(button.NormalTexture.alpha == 0.65, "重试后按钮美术未恢复")
assert(scheduler.unregistrations == 1 and next(scheduler.subscriptions) == nil, "成功后未摘重试驱动")
print("PASS 小地图按钮受限/写失败保留快照，重试成功后恢复并摘驱动")

settings.mapTracking = true
B:Apply(overlay)
settings.mapTracking = false
B:Apply(overlay)
assert(button:GetParent() == oldParent and scheduler.registrations == 1, "正常开关未同步还原")
print("PASS 小地图按钮正常开关同步还原")

local file = assert(io.open(root .. "/Modules/Minimap/Minimap.lua", "r"))
local source = file:read("*a")
file:close()
assert(source:find("if M.buttons and not M.buttons:Restore() then failed = true end", 1, true),
    "Minimap 总还原没有消费按钮还原结果")
print("PASS Minimap 总还原将按钮失败计入未完成状态")
assert(source:find("if InCombat() or ns:IsRestricted() then return end", 1, true),
    "小地图 ping 的受保护调用缺少受限前置守卫")
assert(source:find("blocker:SetPropagateMouseClicks(true)", 1, true),
    "小地图点击没有透传给暴雪原生 OnClick")
assert(not source:find("pingHandler.Execute", 1, true) and not source:find("GetFrameRef", 1, true),
    "小地图 ping 仍依赖受限句柄没有的帧方法")
assert(source:find("Secrets.Number(rawX), Secrets.Number(rawY)", 1, true),
    "小地图 ping 的坐标没有先过机密值守卫")
print("PASS 小地图 ping 有点击透传接线、圆内不直接补调用且坐标先守卫")

local function Upvalue(fn, wanted, seen)
    seen = seen or {}
    if seen[fn] then return end
    seen[fn] = true
    for i = 1, math.huge do
        local name, value = debug.getupvalue(fn, i)
        if not name then return end
        if name == wanted then return value end
        if type(value) == "function" then
            local found = Upvalue(value, wanted, seen)
            if found ~= nil then return found end
        end
    end
end

if _VERSION == "Lua 5.1" then
    chunk = assert(loadfile(root .. "/Modules/Minimap/Minimap.lua"))
    setfenv(chunk, env)
else
    chunk = assert(loadfile(root .. "/Modules/Minimap/Minimap.lua", "t", env))
end
chunk("MonetUI", ns)
local M = assert(registered.Minimap, "Minimap 模块未注册")
local minimap = NewFrame("Minimap")
minimap.width = 256
minimap.pings = {}
env.Minimap = minimap
function minimap:GetEffectiveScale() return 2 end
function minimap:GetCenter() return 50, 50 end
function minimap:GetFrameLevel() return 1 end
function minimap:EnableMouseWheel() end
function minimap:PingLocation(x, y)
    assert(not env.combat and not env.restricted, "插件上下文在受限时直接调用了 PingLocation")
    self.pings[#self.pings + 1] = { x, y }
end

local skinFn = assert(Upvalue(M.Initialize, "Skin"), "找不到 Skin 闭包")
local ensureBlocker = assert(Upvalue(skinFn, "EnsureBlocker"), "找不到遮罩闭包")
ensureBlocker(minimap)
local blocker = assert(env.MonetUIMinimapOverlay, "遮罩未创建")
local onMouseUp = assert(blocker.scripts.OnMouseUp, "遮罩未注册鼠标回调")
assert(blocker.propagateMouseClicks == true, "遮罩没有开启点击透传")

local function Click()
    onMouseUp(blocker, "LeftButton")
end

cursor[1], cursor[2] = 356, 290
Click()
assert(#minimap.pings == 1 and minimap.pings[1][1] == 128 and minimap.pings[1][2] == 95,
    "脱战方形四角未补 ping")
print("PASS 脱战圆外只补一次方形角 ping")

cursor[1], cursor[2] = 100, 100
Click()
assert(#minimap.pings == 1,
    "圆内点击被插件重复调用 PingLocation")
print("PASS 圆内插件不重复补 ping（原生事件透传仍需实机）")

cursor[1], cursor[2] = 356, 290
env.combat = true
Click()
assert(#minimap.pings == 1,
    "战斗中圆外仍直接调用受保护 PingLocation")
cursor[1], cursor[2] = 100, 100
Click()
assert(#minimap.pings == 1,
    "战斗中圆内仍直接调用受保护 PingLocation")
env.combat = false
print("PASS 战斗圆内/圆外均不直接调用受保护方法（原生透传仍需实机）")

env.restricted = true
cursor[1], cursor[2] = 356, 290
Click()
assert(#minimap.pings == 1, "地图/聊天限制下仍直接调用 PingLocation")
env.restricted = false
print("PASS 地图/聊天限制下不直接调用 PingLocation")

env.secret = {}
cursor[1] = env.secret
onMouseUp(blocker, "LeftButton")
assert(#minimap.pings == 1, "机密坐标仍进入直接 ping 计算")
cursor[1] = 356
env.secret = nil
print("PASS 机密光标坐标在直接 ping 计算前被丢弃")
print("ALL PASS")
