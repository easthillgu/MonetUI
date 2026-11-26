-- 小地图日历入口回归：加载真实 MicroMenu.lua / MicroMenuSecure.lua，验证代点接线与 shown 链。
--   lua tools/harness/micromenu-calendar-probe.lua [repo-root]

local root = arg[1] or "."
local checks = 0
local function check(name, condition)
    assert(condition, name)
    checks = checks + 1
    print("PASS  " .. name)
end

local function loadModule(env, relative)
    local chunk
    if _VERSION == "Lua 5.1" then
        chunk = assert(loadfile(root .. "/" .. relative))
        setfenv(chunk, env)
    else
        chunk = assert(loadfile(root .. "/" .. relative, "t", env))
    end
    chunk("MonetUI", env.ns)
end

local function world(clockState)
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local state = { frames = {}, clicks = {}, prints = {}, hideClock = true, secure = true }

    local Frame = {}
    Frame.__index = Frame
    function Frame:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function Frame:ClearAllPoints() self.points = {} end
    function Frame:GetNumPoints() return #self.points end
    function Frame:SetWidth(width) self.width = width end
    function Frame:SetHeight(height) self.height = height end
    function Frame:GetHeight() return self.height or 1080 end
    function Frame:GetBottom() return self.bottom or 100 end
    function Frame:GetTop() return self.top or 124 end
    function Frame:SetFrameStrata(strata) self.strata = strata end
    function Frame:SetFrameLevel(level) self.level = level end
    function Frame:EnableMouse(enabled) self.mouse = enabled end
    function Frame:SetClampedToScreen(value) self.clamped = value end
    function Frame:SetAllPoints(...) self.allPoints = { ... } end
    function Frame:SetBackdrop() self.backdrop = true end
    function Frame:SetAttribute(key, value) self.attributes[key] = value end
    function Frame:RegisterForClicks(...) self.clickRegistrations = { ... } end
    function Frame:SetScript(name, fn) self.scripts[name] = fn end
    function Frame:Show() self.shown = true end
    function Frame:Hide() self.shown = false end
    function Frame:IsShown() return self.shown end
    function Frame:SetShown(shown) self.shown = shown end
    function Frame:SetAlpha(alpha) self.alpha = alpha end
    function Frame:IsVisible()
        if not self.shown then return false end
        return not self.parent or self.parent:IsVisible()
    end
    function Frame:IsEnabled() return self.enabled end
    function Frame:Disable() self.enabled = false end
    function Frame:IsProtected() return self.protected or false end
    function Frame:GetRect() return 0, 0, self.width or 120, self.height or 40 end
    function Frame:Click(button)
        state.clicks[#state.clicks + 1] = { target = self, button = button }
        if self.nativeClick then self.nativeClick(self, button) end
    end

    env.UIParent = setmetatable({ name = "UIParent", shown = true, points = {}, scripts = {}, attributes = {},
        clickRegistrations = {}, alpha = 1, protected = false }, Frame)
    env.Minimap = setmetatable({ name = "Minimap", shown = true, points = {}, scripts = {}, attributes = {},
        clickRegistrations = {}, alpha = 1, protected = false }, Frame)
    env.MicroMenuContainer = setmetatable({ name = "MicroMenuContainer", shown = false, points = {}, scripts = {},
        attributes = {}, clickRegistrations = {}, alpha = 1, protected = false }, Frame)
    env.MicroMenu = setmetatable({ name = "MicroMenu", parent = env.MicroMenuContainer, shown = false, points = {},
        scripts = {}, attributes = {}, clickRegistrations = {}, alpha = 1, protected = false }, Frame)

    if clockState ~= "missing" then
        env.GameTimeFrame = setmetatable({ name = "GameTimeFrame", parent = env.MicroMenu, shown = false,
            enabled = clockState ~= "disabled", points = {}, scripts = {}, attributes = {},
            clickRegistrations = {}, alpha = 1, protected = false }, Frame)
        function env.GameTimeFrame:nativeClick()
            state.calendarLoaded = true
            state.calendarShown = true
        end
    end

    function env.CreateFrame(_, name, parent, template)
        local frame = setmetatable({ name = name, parent = parent, shown = true, points = {}, scripts = {},
            attributes = {}, clickRegistrations = {}, alpha = 1,
            protected = template == "SecureActionButtonTemplate" and true or false }, Frame)
        state.frames[#state.frames + 1] = frame
        return frame
    end

    local Widget = {}
    function Widget:CreateFrame(name, parent, width, height)
        local frame = env.CreateFrame("Frame", name, parent, "BackdropTemplate")
        frame:SetWidth(width)
        frame:SetHeight(height)
        return frame
    end
    function Widget:Theme(frame) frame.themed = true end
    function Widget:Font(parent)
        local label = setmetatable({ parent = parent, shown = true, points = {}, scripts = {}, attributes = {} }, Frame)
        function label:SetText(text)
            self.text = text
            parent.fontLabel = self
        end
        function label:SetNonSpaceWrap(value) self.wrap = value end
        return label
    end
    function Widget:ColorText() end

    local module = {}
    local ns = {
        Widget = Widget,
        IsRestricted = function() return false end,
        AfterCombat = function() end,
        DB = function() return { minimap = { hideClock = state.hideClock, microMenuSecure = state.secure } } end,
        Print = function(_, message) state.prints[#state.prints + 1] = message end,
        GetModule = function(_, name)
            if name == "Minimap" then return module end
        end,
    }
    env.ns = ns
    loadModule(env, "Modules/Minimap/MicroMenu.lua")
    loadModule(env, "Modules/Minimap/MicroMenuSecure.lua")
    return env, state, module.microMenu, module.microMenuSecure
end

local function captureLabels(state)
    local labels = {}
    for _, frame in ipairs(state.frames) do
        if frame.fontLabel then labels[#labels + 1] = frame.fontLabel.text end
    end
    return labels
end

local function hasLabel(labels, wanted)
    for _, label in ipairs(labels) do
        if label == wanted then return true end
    end
    return false
end

local env, state, menu, dock = world("enabled")
check("日历入口只声明原生安全目标", menu.ownEntries[3].label == "日历"
    and menu.ownEntries[3].secureTarget == "GameTimeFrame" and menu.ownEntries[3].luaAction == nil)
menu:Probe(true)
local ordinaryLabels = captureLabels(state)
check("普通回退菜单不保留点了无反应的日历行", #ordinaryLabels == 3
    and ordinaryLabels[1] == "背包" and ordinaryLabels[2] == "地图" and ordinaryLabels[3] == "设置")
dock:Toggle()
check("安全菜单成功展开", dock:IsOpen() == true)
check("隐藏的时钟恢复 shown 链", env.GameTimeFrame.shown == true and env.GameTimeFrame:IsVisible() == true)
check("隐藏时钟仅压 alpha，不影响安全代点", env.GameTimeFrame.alpha == 0 and env.GameTimeFrame:IsVisible() == true)
dock:Probe(true)
check("可点诊断分母包含日历目标", table.concat(state.prints, "\n"):find("代点目标此刻可点 1/13", 1, true) ~= nil)

local calendarRow
for _, frame in ipairs(state.frames) do
    if frame.fontLabel and frame.fontLabel.text == "日历" and frame.protected then calendarRow = frame end
end
check("日历行使用安全模板", calendarRow ~= nil)
check("日历行属性为 click + GameTimeFrame", calendarRow.attributes.type == "click"
    and calendarRow.attributes.clickbutton == env.GameTimeFrame)
check("日历行同时注册 Down 与 Up", calendarRow.clickRegistrations[1] == "AnyDown"
    and calendarRow.clickRegistrations[2] == "AnyUp")
check("建菜单与诊断不会自行触发原生点击", #state.clicks == 0)
if calendarRow.attributes.clickbutton:IsVisible() then
    calendarRow.attributes.clickbutton:Click("LeftButton")
end
check("原生时钟点击路径被代点一次", #state.clicks == 1 and state.clicks[1].target == env.GameTimeFrame
    and state.calendarLoaded == true and state.calendarShown == true)

env, state, menu, dock = world("enabled")
state.hideClock = false
env.GameTimeFrame.alpha = 0.7
dock:Toggle()
check("用户显示时钟时 ensureVisible 不强行隐藏", env.GameTimeFrame.shown and env.GameTimeFrame.alpha == 0.7)

env, state, menu, dock = world("missing")
dock:Toggle()
check("时钟缺失时仍可打开其余安全菜单", dock:IsOpen() == true)
check("时钟缺失时跳过日历行", not hasLabel(captureLabels(state), "日历"))
dock:Probe(true)
check("时钟缺失原因进入诊断账", table.concat(state.prints, "\n"):find("日历：本客户端没有这颗按钮", 1, true) ~= nil)

env, state, menu, dock = world("disabled")
dock:Toggle()
check("时钟禁用时跳过日历行", not hasLabel(captureLabels(state), "日历"))
dock:Probe(true)
check("时钟禁用原因进入诊断账", table.concat(state.prints, "\n"):find("日历：此刻不可用", 1, true) ~= nil)

print(("小地图日历行为回归：%d 通过 / 0 失败"):format(checks))
