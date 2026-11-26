-- 独立聊天条真实源码回归。
--   lua tools/harness/chatbar-probe.lua [repo-root]

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

local function world(dockAvailable)
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local state = {
        objects = {}, marks = {}, listeners = {}, calls = {}, prints = {},
        channels = {
            [1] = { localID = 1, name = "综合", channelType = 1 },
            [2] = { localID = 2, name = "Trade", channelType = 3 },
            [3] = { localID = 3, name = "社区", channelType = 2 },
            [4] = { localID = 4, name = "LocalDefense", channelType = 3 },
        },
        homeParty = true, homeRaid = false, instanceParty = false,
        guild = true, officer = false, shift = false,
        lockdown = false, restricted = false, restrictedCalls = 0, lockdownError = false, lockdownSecret = false,
        sendResult = nil, sendError = false, sendSecret = false,
    }
    state.secret = setmetatable({}, { __metatable = "secret" })

    local Frame = {}
    Frame.__index = Frame
    function Frame:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function Frame:ClearAllPoints() self.points = {} end
    function Frame:SetAllPoints(parent) self.allPoints = parent end
    function Frame:SetSize(width, height) self.width, self.height = width, height end
    function Frame:SetWidth(width) self.width = width end
    function Frame:SetHeight(height) self.height = height end
    function Frame:SetShown(value) self.shown = value and true or false end
    function Frame:Show() self.shown = true end
    function Frame:Hide() self.shown = false end
    function Frame:IsShown() return self.shown end
    function Frame:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
    function Frame:SetScript(name, fn) self.scripts[name] = fn end
    function Frame:GetScript(name) return self.scripts[name] end
    function Frame:Click(button) if self.scripts.OnClick then self.scripts.OnClick(self, button) end end
    function Frame:SetText(text) self.text = text == nil and "" or tostring(text) end
    function Frame:GetText() return self.text or "" end
    function Frame:SetTextColor(r, g, b, a)
        if self.kind == "FontString" then
            assert(type(r) == "number" and type(g) == "number" and type(b) == "number"
                and type(a) == "number", "FontString:SetTextColor 必须接收 r,g,b,a")
            self.textColor = { r, g, b, a }
        else
            self.textColor = { r, g, b, a }
        end
    end
    function Frame:SetFontString(fontString) self.fontString = fontString end
    function Frame:GetFontString() return self.fontString end
    function Frame:SetTextInsets(...) self.textInsets = { ... } end
    function Frame:SetMaxLetters(value) self.maxLetters = value end
    function Frame:SetAutoFocus(value) self.autoFocus = value end
    function Frame:SetCursorPosition(value) self.cursor = value end
    function Frame:SetFocus() self.focused = true end
    function Frame:ClearFocus() self.focused = false end
    function Frame:HasFocus() return self.focused and true or false end
    function Frame:SetFrameStrata(value) self.strata = value end
    function Frame:SetFrameLevel(value) self.level = value end
    function Frame:EnableMouse(value) self.mouse = value end
    function Frame:SetBackdrop(value) self.backdrop = value end
    function Frame:SetBackdropColor(...) self.backdropColor = { ... } end
    function Frame:SetBackdropBorderColor(...) self.borderColor = { ... } end
    function Frame:CreateFontString()
        local fs = newObject(env, state, "FontString", nil, self)
        fs:SetAllPoints(self)
        return fs
    end

    function newObject(env, state, kind, name, parent)
        local object = setmetatable({ kind = kind, name = name, parent = parent, shown = true,
            points = {}, scripts = {}, focused = false }, Frame)
        state.objects[#state.objects + 1] = object
        return object
    end

    env.UIParent = newObject(env, state, "Frame", "UIParent", nil)
    if dockAvailable ~= false then
        env.GeneralDockManager = newObject(env, state, "Frame", "GeneralDockManager", env.UIParent)
    end
    function env.CreateFrame(kind, name, parent)
        return newObject(env, state, kind, name, parent)
    end
    env.IsShiftKeyDown = function() return state.shift end
    env.LE_PARTY_CATEGORY_HOME = 1
    env.LE_PARTY_CATEGORY_INSTANCE = 2
    env.Enum = { PermanentChatChannelType = { Custom = 3 } }
    env.issecretvalue = function(value) return value == state.secret end
    env.canaccessvalue = function(value) return value ~= state.secret end

    local blizzardTouches = 0
    env.ChatFrame1 = setmetatable({}, { __index = function()
        blizzardTouches = blizzardTouches + 1
        error("chat bar touched a Blizzard chat object")
    end })
    state.blizzardTouches = function() return blizzardTouches end

    env.GetDefaultLanguage = function() return "zhCN", 7 end
    env.IsInGroup = function(category) return category == 1 and state.homeParty or category == 2 and state.instanceParty end
    env.IsInRaid = function(category) return category == 1 and state.homeRaid end
    env.IsInGuild = function() return state.guild end
    env.C_GuildInfo = { IsGuildOfficer = function() return state.officer end }
    env.GetChannelName = function(identifier)
        if type(identifier) == "number" then
            local channel = state.channels[identifier]
            return channel and channel.localID or 0
        end
        for _, channel in pairs(state.channels) do
            if channel.name == identifier then return channel.localID, channel.name end
        end
        return 0
    end
    env.C_ChatInfo = {
        GetChannelInfoFromIdentifier = function(identifier)
            return state.channels[tonumber(identifier)]
        end,
        InChatMessagingLockdown = function()
            if state.lockdownError then error("mock lockdown failure") end
            if state.lockdownSecret then return state.secret end
            return state.lockdown
        end,
        AreOutgoingAddonChatMessagesRestricted = function()
            state.restrictedCalls = state.restrictedCalls + 1
            return state.restricted
        end,
        SendChatMessage = function(message, chatType, languageID, target)
            state.calls[#state.calls + 1] = {
                message = message, chatType = chatType, languageID = languageID, target = target,
            }
            if state.sendError then error("mock send failure") end
            if state.sendSecret then return state.secret end
            return state.sendResult
        end,
    }

    local Widget, Skin, Mover, Color, EventBus = {}, {}, {}, {}, {}
    function Widget:CreateFrame(name, parent, width, height)
        local object = env.CreateFrame("Frame", name, parent)
        object:SetSize(width, height)
        return object
    end
    function Widget:Theme(frame)
        local bg = newObject(env, state, "Frame", nil, frame)
        state.marks[frame] = { controlBg = bg }
        return frame
    end
    function Widget:Font(parent)
        return parent:CreateFontString()
    end
    function Widget:SetFont() end
    function Widget:SetBorderState(frame, r, g, b, a)
        frame.borderState = r and { r, g, b, a } or nil
    end
    function Skin:EditBox(editBox) return editBox end
    function Skin:Need(path) return env[path] end
    function Skin:Button(button)
        local bg = newObject(env, state, "Frame", nil, button)
        state.marks[button] = { controlBg = bg }
    end
    function Mover:Register(frame, key, opts)
        state.mover = { frame = frame, key = key, opts = opts }
    end
    function Color:GetHighlight() return 0.9, 0.8, 0.4 end
    function Color:GetNeutral() return 0.7, 0.7, 0.7 end
    function Color:GetEdge() return 0.8, 0.8, 0.8 end
    function EventBus:Register(event, fn)
        state.listeners[event] = state.listeners[event] or {}
        state.listeners[event][#state.listeners[event] + 1] = fn
    end

    local ns
    ns = {
        Widget = Widget, Skin = Skin, Mover = Mover, Color = Color, EventBus = EventBus,
        DB = function() return { chat = { positions = {} } } end,
        Print = function(_, message) state.prints[#state.prints + 1] = message end,
        Marked = function(object, key) return state.marks[object] and state.marks[object][key] end,
        Register = function(_, name, module) ns[name] = module end,
    }
    env.ns = ns
    loadModule(env, "Utils/Secrets.lua")
    loadModule(env, "Modules/Chat/Chat.lua")
    return env, state, ns.Chat
end

local function targetType(chat)
    return chat:GetTarget().chatType
end

local function targetID(chat)
    return chat:GetTarget().localID
end

local function fire(state, event)
    for _, fn in ipairs(state.listeners[event] or {}) do fn(event) end
end

local function byLabel(state, label)
    for _, object in ipairs(state.objects) do
        if object.kind == "FontString" and object.text == label and object.parent then
            return object.parent
        end
    end
end

local function click(state, label)
    local button = byLabel(state, label)
    assert(button, "missing button " .. label)
    button:Click("LeftButton")
end

local function editBox(state)
    for _, object in ipairs(state.objects) do
        if object.name == "MonetUIChatBarEditBox" then return object end
    end
    error("missing chat edit box")
end

local function enter(state, text)
    local box = editBox(state)
    box:SetText(text)
    box:GetScript("OnEnterPressed")(box)
end

local function resetSend(state)
    state.calls = {}
    state.lockdown, state.restricted = false, false
    state.lockdownError, state.lockdownSecret = false, false
    state.restricted, state.restrictedCalls = false, 0
    state.sendError, state.sendSecret = false, false
    state.sendResult = nil
end

local env, state, chat = world()
chat:Initialize()
check("只创建 MonetUI 聊天条与输入框",
    state.mover.frame.name == "MonetUIChatBar" and editBox(state).name == "MonetUIChatBarEditBox")
local default = state.mover.opts.default
check(("默认位置左对齐聊天 Tab 容器上方 (%s/%s/%s,%s,%s)"):format(
    tostring(default.relativeTo), tostring(default.relativePoint), tostring(default.point),
    tostring(default.x), tostring(default.y)),
    default.relativeTo == "GeneralDockManager"
    and default.relativePoint == "TOPLEFT"
    and default.point == "BOTTOMLEFT"
    and default.x == 0 and default.y == 12)
check("聊天 Tab 容器缺失时保留屏幕左下角兜底", state.mover.opts.default.fallback.relativeTo == "UIParent"
    and state.mover.opts.default.fallback.x == 20 and state.mover.opts.default.fallback.y == 2)
check("默认目标为说", targetType(chat) == "SAY")
check("初始化后可见且输入框不自动抢焦点", state.mover.frame:IsShown() and not editBox(state):HasFocus())
check("Tab 正向循环并跳过密语与喊", (function()
    chat:Cycle(false); return targetType(chat) == "PARTY"
end)() and (function()
    chat:Cycle(false); return targetType(chat) == "GUILD"
end)() and (function()
    chat:Cycle(false); return targetID(chat) == 2
end)() and (function()
    chat:Cycle(false); return targetID(chat) == 4
end)() and (function()
    chat:Cycle(false); return targetType(chat) == "SAY"
end)())
chat:Cycle(true)
check("Shift+Tab 从循环外反向落到最后自定义频道", targetID(chat) == 4)

state.homeRaid, state.instanceParty, state.officer = true, true, true
fire(state, "GROUP_ROSTER_UPDATE")
check("队伍与团队状态变化时排除普通队伍并开放团队/副本/官员",
    not byLabel(state, "队"):IsShown() and byLabel(state, "团"):IsShown()
    and byLabel(state, "本"):IsShown() and byLabel(state, "官"):IsShown())
check("只收集 Custom 频道", targetID(chat) == 4 and byLabel(state, "Local…")
    and not byLabel(state, "综合") and not byLabel(state, "社区"))
click(state, "Local…")
check("点击自定义频道只选中并聚焦", targetID(chat) == 2 and editBox(state):HasFocus() and #state.calls == 0)
click(state, "Trade")
check("自定义频道按钮循环到下一项", targetID(chat) == 4)
click(state, "喊")
state.shift = false
editBox(state):GetScript("OnTabPressed")()
check("喊不进入普通 Tab 循环", targetType(chat) == "SAY")
state.shift = true
editBox(state):GetScript("OnTabPressed")()
check("EditBox 真实 Tab 脚本读取 Shift 方向", targetID(chat) == 4)
state.shift = false

click(state, "密")
check("空输入点击密语只预填命令", editBox(state):GetText() == "/w " and editBox(state):HasFocus())
resetSend(state)
enter(state, "/w Friend hello")
check("密语通过纯 C API 发送并清空", #state.calls == 1
    and state.calls[1].message == "hello" and state.calls[1].chatType == "WHISPER"
    and state.calls[1].target == "Friend" and state.calls[1].languageID == 7
    and editBox(state):GetText() == "" and editBox(state):HasFocus())
resetSend(state)
enter(state, "Friend direct")
check("选中密语后支持名字加内容直发", #state.calls == 1 and state.calls[1].target == "Friend"
    and state.calls[1].message == "direct")

click(state, "说")
resetSend(state)
enter(state, "hello")
check("普通频道发送后清空但保持焦点", #state.calls == 1 and state.calls[1].chatType == "SAY"
    and state.calls[1].message == "hello" and editBox(state):GetText() == "" and editBox(state):HasFocus())
resetSend(state)
enter(state, "")
check("空输入不调用发送", #state.calls == 0)
resetSend(state)
enter(state, "/invite Bob")
check("不支持的斜杠命令保留文本且不进入暴雪路径", #state.calls == 0
    and editBox(state):GetText() == "/invite Bob"
    and table.concat(state.prints, "\n"):find("不支持这个斜杠命令", 1, true) ~= nil)
resetSend(state)
enter(state, "/2 channel message")
check("频道别名发送本地频道 ID", #state.calls == 1 and state.calls[1].chatType == "CHANNEL"
    and state.calls[1].target == 2 and state.calls[1].message == "channel message")
resetSend(state)
enter(state, "/channel Trade ping")
check("channel 名称别名发送本地频道 ID", #state.calls == 1 and state.calls[1].target == 2
    and state.calls[1].message == "ping")

resetSend(state)
state.homeParty, state.homeRaid, state.instanceParty = false, false, false
fire(state, "GROUP_ROSTER_UPDATE")
enter(state, "/party blocked")
check("不可用显式频道拒发且保留文本", #state.calls == 0 and editBox(state):GetText() == "/party blocked")

local function rejected(name, configure, attempted)
    resetSend(state)
    configure()
    enter(state, "keep this")
    check(name, #state.calls == (attempted and 1 or 0) and editBox(state):GetText() == "keep this")
end
rejected("聊天 lockdown 拒发且保留文本", function() state.lockdown = true end)
rejected("lockdown 查询抛错时失败关闭", function() state.lockdownError = true end)
rejected("lockdown 机密返回值失败关闭", function() state.lockdownSecret = true end)
resetSend(state)
state.restricted = true
enter(state, "player message")
check("ADDON 通信限制不阻断玩家频道发送", #state.calls == 1
    and state.calls[1].message == "player message" and editBox(state):GetText() == ""
    and state.restrictedCalls == 0)
rejected("SendChatMessage 抛错时保留文本", function() state.sendError = true end, true)
rejected("SendChatMessage 返回 false 时保留文本", function() state.sendResult = false end, true)
rejected("SendChatMessage 返回机密值时保留文本", function() state.sendSecret = true end, true)

resetSend(state)
local chatAPI = env.C_ChatInfo
env.C_ChatInfo = nil
enter(state, "no api")
check("聊天 API 缺失时失败关闭", #state.calls == 0 and editBox(state):GetText() == "no api")
env.C_ChatInfo = chatAPI

local name = state.channels[4].name
state.channels[4].name = state.secret
fire(state, "CHANNEL_UI_UPDATE")
check("机密频道名不参与展示或比较", byLabel(state, "Trade") ~= nil
    and byLabel(state, "Local…") == nil)
state.channels[4].name = name
local localID = state.channels[4].localID
state.channels[4].localID = state.secret
fire(state, "CHANNEL_FLAGS_UPDATED")
check("机密频道 ID 不参与表键或比较", byLabel(state, "Local…") == nil)
state.channels[4].localID = localID
local channelType = state.channels[4].channelType
state.channels[4].channelType = state.secret
fire(state, "CHANNEL_UI_UPDATE")
check("机密频道类型不参与比较", byLabel(state, "Local…") == nil)
state.channels[4].channelType = channelType
fire(state, "CHANNEL_UI_UPDATE")

editBox(state):SetText("TOPSECRET")
chat:HandleCommand("status")
check("诊断不打印玩家输入内容", table.concat(state.prints, "\n"):find("TOPSECRET", 1, true) == nil
    and table.concat(state.prints, "\n"):find("自定义频道=2", 1, true) ~= nil)
editBox(state):GetScript("OnEscapePressed")(editBox(state))
check("Escape 清空并失焦", editBox(state):GetText() == "" and not editBox(state):HasFocus())
local objectCount = #state.objects
chat:Initialize()
chat:SetEnabled(true)
check("重复启用幂等且事件不重复注册", #state.objects == objectCount
    and #state.listeners.CHANNEL_UI_UPDATE == 1 and #state.listeners.MONETUI_THEME_CHANGED == 1)
chat:SetEnabled(false)
check("禁用只隐藏自建聊天条并清焦点", not state.mover.frame:IsShown() and not editBox(state):HasFocus())
chat:SetEnabled(true)
check("重新启用恢复显示", state.mover.frame:IsShown())
check("全程零暴雪聊天对象字段、脚本、hook 或布局写入", state.blizzardTouches() == 0)

local fallbackEnv, fallbackState, fallbackChat = world(false)
fallbackChat:Initialize()
check("Tab 容器缺失时直接使用 UIParent 默认位置", fallbackState.mover.opts.default.relativeTo == "UIParent"
    and fallbackState.mover.opts.default.relativePoint == "BOTTOMLEFT"
    and fallbackState.mover.opts.default.x == 20 and fallbackState.mover.opts.default.y == 2)

print(("聊天条行为回归：%d 通过 / 0 失败"):format(checks))
