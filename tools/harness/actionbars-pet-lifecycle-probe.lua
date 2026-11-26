-- actionbars-pet-lifecycle-probe.lua
-- 宠物条生命周期离线回归：加载真实 ActionBars.lua + PetBar.lua，只把客户端对象换成可注入失败的 mock。
--   lua tools/harness/actionbars-pet-lifecycle-probe.lua

local unpack = table.unpack or unpack
local env = setmetatable({}, { __index = _G })
env._G = env
env.unpack = unpack

local FrameMethods = {}
local TextureMethods = {}
local FontMethods = {}

local function NewTexture(name)
    return setmetatable({
        name = name, points = {}, width = 1, height = 1, scale = 1,
        shown = true, alpha = 1, u0 = 0, u1 = 1, v0 = 0, v1 = 1,
    }, { __index = TextureMethods })
end

function TextureMethods:GetName() return self.name end
function TextureMethods:GetParent() return self.parent end
function TextureMethods:SetParent(parent) self.parent = parent end
function TextureMethods:GetNumPoints() return #self.points end
function TextureMethods:GetPoint(index) return unpack(self.points[index] or {}) end
function TextureMethods:SetPoint(...) self.points[#self.points + 1] = { ... } end
function TextureMethods:ClearAllPoints() self.points = {} end
function TextureMethods:GetWidth() return self.width end
function TextureMethods:GetHeight() return self.height end
function TextureMethods:SetSize(width, height)
    if self.failSetSizeOnce then self.failSetSizeOnce = false; error("mock SetSize denied") end
    self.width, self.height = width, height
end
function TextureMethods:GetScale() return self.scale end
function TextureMethods:SetScale(scale) self.scale = scale end
function TextureMethods:IsShown() return self.shown end
function TextureMethods:Show() self.shown = true end
function TextureMethods:Hide() self.shown = false end
function TextureMethods:GetAlpha() return self.alpha end
function TextureMethods:SetAlpha(alpha) self.alpha = alpha end
function TextureMethods:GetTexCoord() return self.u0, self.u1, self.v0, self.v1 end
function TextureMethods:SetTexCoord(u0, u1, v0, v1) self.u0, self.u1, self.v0, self.v1 = u0, u1, v0, v1 end
function TextureMethods:SetColorTexture(...) self.color = { ... } end
function TextureMethods:AddMaskTexture(mask) self.mask = mask end
function TextureMethods:RemoveMaskTexture(mask) if self.mask == mask then self.mask = nil end end

local function NewFont(name, font, size, flags, r, g, b, a)
    return setmetatable({
        name = name, font = font, size = size, flags = flags,
        r = r, g = g, b = b, a = a,
    }, { __index = FontMethods })
end

function FontMethods:GetFont() return self.font, self.size, self.flags end
function FontMethods:SetFont(font, size, flags) self.font, self.size, self.flags = font, size, flags end
function FontMethods:GetTextColor() return self.r, self.g, self.b, self.a end
function FontMethods:SetTextColor(r, g, b, a) self.r, self.g, self.b, self.a = r, g, b, a end

local function NewFrame(name, parent)
    return setmetatable({
        name = name, parent = parent, points = {}, width = 1, height = 1,
        scale = 1, shown = true, frameLevel = 1,
    }, { __index = FrameMethods })
end

function FrameMethods:GetName() return self.name end
function FrameMethods:GetParent() return self.parent end
function FrameMethods:SetParent(parent)
    if self.failSetParentOnce then self.failSetParentOnce = false; error("mock SetParent denied") end
    self.parent = parent
end
function FrameMethods:GetNumPoints() return #self.points end
function FrameMethods:GetPoint(index) return unpack(self.points[index] or {}) end
function FrameMethods:SetPoint(...)
    if self.failSetPointOnce then self.failSetPointOnce = false; error("mock SetPoint denied") end
    self.points[#self.points + 1] = { ... }
end
function FrameMethods:ClearAllPoints() self.points = {} end
function FrameMethods:GetWidth() return self.width end
function FrameMethods:GetHeight() return self.height end
function FrameMethods:SetSize(width, height)
    if self.failSetSizeOnce then self.failSetSizeOnce = false; error("mock SetSize denied") end
    self.width, self.height = width, height
end
function FrameMethods:GetScale() return self.scale end
function FrameMethods:SetScale(scale)
    if self.failSetScaleOnce then self.failSetScaleOnce = false; error("mock SetScale denied") end
    self.scale = scale
end
function FrameMethods:IsShown() return self.shown end
function FrameMethods:Show() self.shown = true end
function FrameMethods:Hide() self.shown = false end
function FrameMethods:GetFrameLevel() return self.frameLevel end
function FrameMethods:SetFrameLevel(level) self.frameLevel = level end
function FrameMethods:EnableMouse(enabled) self.mouseEnabled = enabled end
function FrameMethods:CreateTexture(name) return NewTexture(name) end
function FrameMethods:GetRegions() return end
function FrameMethods:RegisterEvent() end
function FrameMethods:UnregisterAllEvents() end
function FrameMethods:SetScript() end
function FrameMethods:GetAttribute() return nil end
function FrameMethods:SetAttribute() end

local function NewPetButton(name, parent)
    local button = NewFrame(name, parent)
    button.width, button.height, button.scale, button.shown = 40, 30, 0.8, false
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", 3, 4)
    button:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -5, -6)
    button.icon = NewTexture(name .. "Icon")
    button.icon:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.HotKey = NewFont(name .. "HotKey", "Blizzard", 10, "MONOCHROME", 1, 1, 1, 1)
    button.Count = NewFont(name .. "Count", "Blizzard", 10, "MONOCHROME", 1, 1, 1, 1)
    return button
end

env.UIParent = NewFrame("UIParent")
env.CreateFrame = function(_, name, parent) return NewFrame(name, parent) end
env.PetActionBar = NewFrame("PetActionBar", env.UIParent)
env.RegisterStateDriver = function() end
env.UnregisterStateDriver = function() end
env.InCombatLockdown = function() return false end
env.UnitAffectingCombat = function() return false end
env.GetPetActionInfo = function() return nil end

local modules = {}
local marks = setmetatable({}, { __mode = "k" })
local nextSubscription = 0
local subscriptions = {}
local db = { actionBars = { buttonSize = 28, spacing = 2 } }

local function MarkTable(object)
    local data = marks[object]
    if not data then data = {}; marks[object] = data end
    return data
end

local ns = {}
function ns:Register(name, module) modules[name] = module end
function ns:GetModule(name) return modules[name] end
function ns:NewFrameData()
    local store = setmetatable({}, { __mode = "k" })
    return store, function(object)
        local data = store[object]
        if not data then data = {}; store[object] = data end
        return data
    end
end
function ns:Mark(object, key, value)
    local data = MarkTable(object)
    if value == nil then data[key] = nil else data[key] = value end
end
function ns:Marked(object, key) return MarkTable(object)[key] end
function ns:DB() return db end
function ns:IsRestricted() return env.restricted == true end
function ns:AfterCombat() error("宠物事务不应依赖下一次脱战事件") end
function ns:Print() end
function ns:DevPrint() end
ns.Layout = { bottom = 24 }
ns.EventBus = {}
ns.Secrets = {
    Number = function(value) return type(value) == "number" and value or nil end,
    Bool = function(value, default) return type(value) == "boolean" and value or default end,
    IsSecret = function() return false end,
}
ns.Media = { SnapUnit = function(_, value) return math.floor(value + 0.5) end }
ns.Color = {
    GetBorder = function() return 0.2, 0.4, 0.6 end,
    GetSurface = function() return 0.05, 0.07, 0.08 end,
}
ns.Skin = {
    CropIcon = function(_, icon, u0, u1, v0, v1) icon:SetTexCoord(u0, u1, v0, v1) end,
}
ns.Scheduler = {
    Every = function(_, _, fn, label)
        nextSubscription = nextSubscription + 1
        subscriptions[nextSubscription] = { fn = fn, label = label }
        return nextSubscription
    end,
    Unregister = function(_, id) subscriptions[id] = nil end,
}
ns.Widget = {
    BORDER = 1,
    PaletteColor = function() return 1, 1, 1, 1 end,
    SetFont = function(_, fs, size, key) fs:SetFont("Monet:" .. key, size, "OUTLINE") end,
    Font = function() return NewFont(nil, "Monet", 12, "OUTLINE", 1, 1, 1, 1) end,
    StyleCooldownText = function() end,
    PollWatch = function() end,
    Unwatch = function() end,
    HoverWatch = function() end,
    Theme = function() end,
    ButtonMaterial = function() end,
    Mute = function() end,
    Unmute = function() end,
    StopPixelGlow = function() end,
    PixelGlow = function() end,
}

local function Load(path)
    local chunk, err
    if _VERSION == "Lua 5.1" then
        chunk, err = loadfile(path)
        if chunk then setfenv(chunk, env) end
    else
        chunk, err = loadfile(path, "t", env)
    end
    assert(chunk, err)
    chunk("MonetUI", ns)
end

Load("Modules/ActionBars/ActionBars.lua")
local M = assert(modules.ActionBars, "ActionBars did not register")
M.own = true
M.PositionBar = function() end -- 几何事务探针只验按钮；条位置不在此用例范围。
Load("Modules/ActionBars/PetBar.lua")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

local function Capture(object)
    local points = {}
    for i = 1, object:GetNumPoints() do points[i] = { object:GetPoint(i) } end
    return {
        parent = object:GetParent(), points = points,
        width = object:GetWidth(), height = object:GetHeight(),
        scale = object:GetScale(), shown = object:IsShown(),
    }
end

local function SameSnapshot(actual, expected)
    if actual.parent ~= expected.parent or actual.width ~= expected.width
        or actual.height ~= expected.height or actual.scale ~= expected.scale
        or actual.shown ~= expected.shown or #actual.points ~= #expected.points then
        return false
    end
    for i = 1, #expected.points do
        if #actual.points[i] ~= #expected.points[i] then return false end
        for j = 1, #expected.points[i] do
            if actual.points[i][j] ~= expected.points[i][j] then return false end
        end
    end
    return true
end

local function SetPetButtons(count)
    for i = 1, 10 do env["PetActionButton" .. i] = nil end
    local buttons = {}
    for i = 1, count do
        local parent = NewFrame("OriginalPetParent" .. i, env.PetActionBar)
        buttons[i] = NewPetButton("PetActionButton" .. i, parent)
        env["PetActionButton" .. i] = buttons[i]
    end
    return buttons
end

local function NewBar()
    local frame = NewFrame("MonetUIBarPet", env.UIParent)
    local bar = { frame = frame, def = M.PET_DEF, buttons = {}, page = 1 }
    M.bars.BarPet = bar
    return bar
end

local function PetRetry()
    for _, subscription in pairs(subscriptions) do
        if subscription.label == "动作条:宠物事务重试" then return subscription.fn end
    end
end

-- 1) 正常收养 → 释放：父级、全部锚点、尺寸、缩放、显隐逐项还原。
local buttons = SetPetButtons(2)
local originals = {}
for i, button in ipairs(buttons) do originals[i] = Capture(button) end
local bar = NewBar()
local adoptedBar = M.petbar.EnsurePetAdoption(bar)
check("正常收养发布 bar", adoptedBar == bar and bar.petAdopted == true and #bar.buttons == 2)
for i, button in ipairs(buttons) do
    check("收养回读 parent/size/points #" .. i,
        button:GetParent() == bar.frame and button:GetWidth() == 28 and button:GetHeight() == 21
        and button:GetScale() == 1 and button:IsShown() == true
        and button:GetNumPoints() == 1
        and button:GetPoint(1) == "TOPLEFT")
end
check("正常释放成功", M.petbar.ReleasePetBar(bar) == true)
check("释放清空发布状态", #bar.buttons == 0 and bar.petAdopted == nil)
for i, button in ipairs(buttons) do
    check("释放恢复原几何 #" .. i, SameSnapshot(Capture(button), originals[i]))
end

-- 2) 释放写失败：保留按钮清单与快照，由低频 Scheduler 重试，不依赖下一次脱战事件。
buttons = SetPetButtons(2)
originals = {}
for i, button in ipairs(buttons) do originals[i] = Capture(button) end
bar = NewBar()
M.petbar.EnsurePetAdoption(bar)
buttons[1].failSetParentOnce = true
check("释放写失败返回 false", M.petbar.ReleasePetBar(bar) == false)
check("释放失败保留 bar.buttons/petAdopted", #bar.buttons == 2 and bar.buttons[1] == buttons[1] and bar.petAdopted == true)
local retry = PetRetry()
check("释放失败进入低频 Scheduler 重试链", type(retry) == "function")
env.restricted = true
if retry then check("仍受限时重试不硬写", retry() == nil and #bar.buttons == 2) end
env.restricted = false
if retry then check("脱战写失败无需下一次脱战即可重试成功", retry() == true) end
check("重试后清空发布状态", #bar.buttons == 0 and bar.petAdopted == nil)
for i, button in ipairs(buttons) do
    check("重试后恢复原几何 #" .. i, SameSnapshot(Capture(button), originals[i]))
end

-- 3) 收养写失败：关键几何回读不通过时不发布，并回滚到原状态。
buttons = SetPetButtons(2)
originals = {}
for i, button in ipairs(buttons) do originals[i] = Capture(button) end
bar = NewBar()
buttons[1].failSetSizeOnce = true
check("收养写失败返回 false", M.petbar.EnsurePetAdoption(bar) == false)
check("收养失败不发布已收养", bar.petAdopted == nil and #bar.buttons == 0)
for i, button in ipairs(buttons) do
    check("收养失败回滚原几何 #" .. i, SameSnapshot(Capture(button), originals[i]))
end

-- 4) 二次收养：ReleaseAdoptedButton 还回 Blizzard 字体后，SkinAdoptedButton 必须重新上 Monet 字体与颜色。
local fontButton = NewPetButton("PetActionButton1", NewFrame("FontOriginalParent", env.PetActionBar))
M.SkinAdoptedButton(fontButton)
check("首次收养应用 Monet 热键/计数", fontButton.HotKey.font == "Monet:pixel"
    and fontButton.Count.font == "Monet:pixel" and fontButton.HotKey.size == 12 and fontButton.Count.size == 12)
M.ReleaseAdoptedButton(fontButton)
check("释放恢复 Blizzard 热键/计数", fontButton.HotKey.font == "Blizzard" and fontButton.Count.font == "Blizzard")
M.SkinAdoptedButton(fontButton)
local function SameColor(fs)
    local r, g, b, a = fs:GetTextColor()
    return math.abs(r - 0.48) < 0.0001 and math.abs(g - 0.61) < 0.0001
        and math.abs(b - 0.74) < 0.0001 and a == 1
end
check("二次收养恢复 Monet 字体与颜色", fontButton.HotKey.font == "Monet:pixel"
    and fontButton.Count.font == "Monet:pixel" and SameColor(fontButton.HotKey) and SameColor(fontButton.Count))

print(failed == 0 and ("ALL PASS (" .. passed .. ")") or (failed .. " FAILED / " .. passed .. " passed"))
os.exit(failed == 0 and 0 or 1)
