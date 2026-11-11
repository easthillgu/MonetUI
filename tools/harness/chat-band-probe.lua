-- tools/harness/chat-band-probe.lua
-- 用法（项目根目录）：lua tools/harness/chat-band-probe.lua
--
-- 回归目标（2026-11-10 §8.89）：把聊天输入框嵌进「框体内顶部」，并让页签行悬停才显示。
-- 实机真值：cf B32 H256 T288 (LOW/lvl5)、eb T389 B357 (LOW/lvl1)、Tab T323 B291 (lvl2)、
-- GDM T317 B291 (lvl1)、skinBg 是 cf 子框 lvl4；chatStyle=im ⇒ 输入框常驻、消息已满 128 行。
-- 方案 A（直接挪进 cf 矩形）会被消息文字盖住且长期遮字；方案 B（底板上扩 32）会盖住页签。
-- 方案 C：cf 减高 32 + skinBg 上沿上扩 32 + eb 底边贴 cf 顶，落在外框内顶部的空带里。
--
-- 本桩**抽取线上 Social.lua 的 CHAT BAND 段原文**在桩环境里执行，不是照抄逻辑自己验自己；
-- 另用静态断言守住「不碰 cf 锚点 / 不写 tab alpha / 隐藏走 GDM / 配置开关」这些边界。

local function read(path)
    local f = assert(io.open(path, "r"), "missing " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

local function slice(src, from, upto)
    local a = assert(src:find(from, 1, true), "missing marker " .. from)
    local b = assert(src:find(upto, a, true), "missing marker " .. upto)
    return src:sub(a, b - 1)
end

local social = read("Modules/Skins/Social.lua")
local skinSrc = read("Utils/Skin.lua")
local coreSrc = read("Core.lua")
local cfgSrc = read("Config/SimpleConfig.lua")
local band = slice(social, "-- === CHAT BAND §8.89 BEGIN ===", "-- === CHAT BAND §8.89 END ===")

local failed = 0
local function check(name, ok, detail)
    if ok then
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. (detail ~= nil and (" -> " .. tostring(detail)) or ""))
    end
end

-- ---------------------------------------------------------------- fake frames
local function Frame(name, h, alpha)
    local f = {
        name = name, height = h or 256, alpha = alpha or 1,
        points = {}, setCalls = 0, clears = 0, heightWrites = 0, alphaWrites = 0,
    }
    function f:GetHeight() return self.height end
    function f:SetHeight(v) self.height = v; self.heightWrites = self.heightWrites + 1 end
    function f:GetPoint(i)
        local p = self.points[i]
        if not p then return nil end
        return p[1], p[2], p[3], p[4], p[5]
    end
    function f:SetPoint(point, rel, relPoint, x, y)
        self.points[#self.points + 1] = { point, rel, relPoint, x, y }
        self.setCalls = self.setCalls + 1
    end
    function f:ClearAllPoints() self.points = {}; self.clears = self.clears + 1 end
    function f:GetAlpha() return self.alpha end
    function f:SetAlpha(v) self.alpha = v; self.alphaWrites = self.alphaWrites + 1 end
    function f:IsShown() return self.shown ~= false end
    function f:HasFocus() return self.focused == true end
    function f:SetShown(v) self.shown = v end
    return f
end

local objects = {}
local function add(name, h, a)
    objects[name] = Frame(name, h, a)
    return objects[name]
end

local minimap = add("Minimap", 256, 1)
local gdm = add("GeneralDockManager", 26, 1)
local bg1 = add("ChatFrame1Background", 256, 1)   -- GDM 在暴雪源码里锚在它身上
local cfs, ebs = {}, {}
for i = 1, 10 do
    cfs[i] = add("ChatFrame" .. i, 256, 1)
    ebs[i] = add("ChatFrame" .. i .. "EditBox", 32, (i == 1 and 1 or 0.35))
end

local CHAT_FRAMES, CHAT_EDITS, CHAT_TABS = {}, {}, {}
for i = 1, 10 do
    CHAT_FRAMES[i] = "ChatFrame" .. i
    CHAT_EDITS[i] = "ChatFrame" .. i .. "EditBox"
    CHAT_TABS[i] = "ChatFrame" .. i .. "Tab"
end
local CHAT_BUTTONS = { "ChatFrameMenuButton", "ChatFrameChannelButton" }
local CHAT_CHANNEL_POPUPS = { "ChatChannelManagerPopup", "CreateChannelPopup", "EditChannelPopup" }
local CHAT_CHANNEL_BUTTONS = {
    "ChatChannelManagerPopupAcceptButton", "ChatChannelManagerPopupCancelButton",
    "ChatChannelManagerPopupDeleteButton",
}
local CHAT_EXTRA_WINDOWS = { "ChannelFrame", "ChatConfigFrame" }

local dressLog, hoverLog, pollLog, panelLog, busLog, timers = {}, {}, {}, {}, {}, {}
local db = { skins = { hoverChatTabs = true } }
local chatPanelEnabled = true

local ns = {
    Secrets = { IsSecret = function(v) return type(v) == "table" and v.__secret == true end },
    DB = function() return db end,
    EventBus = { Register = function(_, ev) busLog[#busLog + 1] = ev end },
    -- §8.90：桩里 Marked 返回 nil（控件底不在桩里），ApplyChannelColor 据此早退。
    Marked = function() return nil end,
}
local Skin = {
    Need = function(_, name) return objects[name] end,
    ChatScrollAlert = function() end,
}
local Widget = {
    PollWatch = function(_, f, fn, iv) pollLog[#pollLog + 1] = { f = f, fn = fn, iv = iv } end,
    HoverWatch = function(_, f, enter, leave)
        for _, e in ipairs(hoverLog) do
            if e.f == f then return e end
        end
        local e = { f = f, enter = enter, leave = leave }
        hoverLog[#hoverLog + 1] = e
        return e
    end,
}
local M = {
    Dress = function(_, names, opts) dressLog[#dressLog + 1] = { names = names, opts = opts } end,
    IsEnabled = function() return chatPanelEnabled end,
    Panel = function(_, key, opts) panelLog[#panelLog + 1] = { key = key, opts = opts } end,
}
local C_Timer = {
    After = function(t, fn) timers[#timers + 1] = { t = t, fn = fn } end,
}
local function FlushTimers()
    local list = timers
    timers = {}
    for _, e in ipairs(list) do e.fn() end
end

local env = setmetatable({
    ns = ns, Skin = Skin, Widget = Widget, M = M, C_Timer = C_Timer,
    CHAT_FRAMES = CHAT_FRAMES, CHAT_EDITS = CHAT_EDITS, CHAT_TABS = CHAT_TABS,
    CHAT_BUTTONS = CHAT_BUTTONS, CHAT_CHANNEL_POPUPS = CHAT_CHANNEL_POPUPS,
    CHAT_CHANNEL_BUTTONS = CHAT_CHANNEL_BUTTONS, CHAT_EXTRA_WINDOWS = CHAT_EXTRA_WINDOWS,
    -- §8.90：桩环境里 Marked 返回 nil（控件底不在桩里），ApplyChannelColor 据此早退。
    Marked = function() return nil end, Mark = function() end,
}, { __index = _G })

local loader = loadstring or load
local compiled, err = loader(band .. "\nreturn ChatBand, CHAT_INPUT_BAND, SkinChat", "chat-band", "t", env)
if not compiled then
    print("FAIL 线上 CHAT BAND 段加载失败: " .. tostring(err))
    os.exit(1)
end
local ChatBand, BAND, SkinChat = compiled()

-- ---------------------------------------------------------------- 静态边界
check("输入区带高 = EditBox 模板 Size.y 32", BAND == 32, BAND)
check("名单含 ChatFrame10（备用窗口也钉）", social:find('"ChatFrame10"', 1, true) ~= nil)
check("名单含 ChatFrame10EditBox", social:find('"ChatFrame10EditBox"', 1, true) ~= nil)
check("底板传 topExtend 取自 InputBand（top/hidden 保留带，bottom 折叠）",
    band:find("topExtend = ChatBand:InputBand()", 1, true) ~= nil
    and band:find("topExtend = self:InputBand()", 1, true) ~= nil)
check("PollWatch 闭包走 ChatBand:PinLayout", band:find("ChatBand:PinLayout(name)", 1, true) ~= nil)
check("旧框外置顶的 -5,dy 已删除", band:find('"BOTTOMLEFT", cf, "TOPLEFT", -5, dy', 1, true) == nil)
check("绝不写 cf 的 SetPoint", band:find("cf.SetPoint", 1, true) == nil
    and band:find("cf.ClearAllPoints", 1, true) == nil)
check("绝不写 tab 的 SetAlpha", band:find("Tab:SetAlpha", 1, true) == nil
    and band:find("tab.SetAlpha", 1, true) == nil)
check("页签显隐走 GeneralDockManager", band:find('Skin:Need("GeneralDockManager")', 1, true) ~= nil
    and band:find("gdm.SetAlpha", 1, true) ~= nil)
check("HoverWatch 用模块级稳定回调", band:find("Widget:HoverWatch(cf, ChatHoverEnter, ChatHoverLeave)", 1, true) ~= nil)
check("Skin:Panel 支持 topExtend", skinSrc:find("opts.topExtend or 0", 1, true) ~= nil)
check("Skin:Panel 只在私有背板 ClearAllPoints", skinSrc:find("pcall(bg.ClearAllPoints, bg)", 1, true) ~= nil)
check("Skin:Panel opts 变更有幂等重设分支", skinSrc:find("(Marked(bg, \"panelTopExtend\") or 0) ~= topExtend", 1, true) ~= nil)
check("DEFAULTS 默认开启悬停页签", coreSrc:find("hoverChatTabs = true", 1, true) ~= nil)
check("配置面板 setter 即时刷新", cfgSrc:find("ns.Skins:RefreshChatTabHover()", 1, true) ~= nil)
check("配置面板有聊天页签开关", cfgSrc:find("聊天页签悬停才显示", 1, true) ~= nil)
-- §8.90 三项新能力（对照这次优化）
check("§8.90 输入框边框跟频道色（读 chatType→ChatTypeInfo，不经消息文本）",
    band:find("function ChatBand:ChannelColor", 1, true) ~= nil
    and band:find("GetAttribute", 1, true) ~= nil
    and band:find("ChatTypeInfo", 1, true) ~= nil)
check("§8.90 ChatEdit_UpdateHeader 钩子（切频道即时重染）",
    band:find('hooksecurefunc("ChatEdit_UpdateHeader"', 1, true) ~= nil)
check("§8.90 频道色经 Widget:SetBorderState 持久化（不打架）",
    band:find("Widget:SetBorderState", 1, true) ~= nil)
check("§8.90 临时聊天窗动态覆盖（FCF_OpenTemporaryWindow 钩子）",
    band:find('hooksecurefunc("FCF_OpenTemporaryWindow"', 1, true) ~= nil)
check("§8.90 IterateFrames 纳入动态临时窗",
    band:find("for name in pairs(self.dynamic)", 1, true) ~= nil)
check("§8.90 页签淡入时长读 tabFade 配置",
    band:find('self:Opt("tabFade")', 1, true) ~= nil)
check("§8.90 页签三态色写进 DEFAULTS.skins",
    coreSrc:find("tabColorNormal", 1, true) ~= nil
    and coreSrc:find("tabColorSelected", 1, true) ~= nil
    and coreSrc:find("tabColorFlash", 1, true) ~= nil)
check("§8.90 配置面板暴露页签色 + 淡入时长",
    cfgSrc:find("页签色·未选中", 1, true) ~= nil
    and cfgSrc:find("页签色·选中", 1, true) ~= nil
    and cfgSrc:find("页签色·未读", 1, true) ~= nil
    and cfgSrc:find("页签淡入时长", 1, true) ~= nil)
check("§8.90 UpdateTabState 按三态上色（Normal/Selected/Flash）",
    skinSrc:find("TabColor", 1, true) ~= nil
    and skinSrc:find("TabIsFlashing", 1, true) ~= nil)

-- §8.91 输入框 hidden 档（折叠输入框带 + cf 高度恢复 + EditBox 隐藏）
check("§8.91 EditBoxPos 由 chatEditBoxAutoHide 控制 hidden",
    band:find('function ChatBand:EditBoxPos', 1, true) ~= nil
    and band:find('self:Opt("chatEditBoxAutoHide")', 1, true) ~= nil)
check("§8.91 新增 InputBand（仅 bottom→0，top/hidden 保留带）",
    band:find("function ChatBand:InputBand", 1, true) ~= nil
    and band:find('return (self:EditBoxPos() == "bottom") and 0 or CHAT_INPUT_BAND', 1, true) ~= nil)
check("§8.91 TargetHeight 改读 InputBand（带高度联动）",
    band:find("return h - self:InputBand()", 1, true) ~= nil)
check("§8.91 skinner.frame hidden 也 PinEditBox（不落底部）+ HideEditBox",
    band:find('pos == "top" or pos == "hidden"', 1, true) ~= nil
    and band:find("self:HideEditBox(name)", 1, true) ~= nil)
check("§8.91 新增 HideEditBox（按焦点态 SetShown）",
    band:find("function ChatBand:HideEditBox", 1, true) ~= nil)
check("§8.91 配置面板暴露自动隐藏开关 + 关闭时位置下拉",
    cfgSrc:find('"输入框自动隐藏（仅聚焦才显示）"', 1, true) ~= nil
    and cfgSrc:find('"输入框位置（关闭隐藏时）"', 1, true) ~= nil)
check("§8.91 DEFAULTS 默认开启自动隐藏",
    coreSrc:find('chatEditBoxAutoHide = true', 1, true) ~= nil)

-- ---------------------------------------------------------------- 高度账本
check("目标高度 = 小地图高 - 32", ChatBand:TargetHeight() == 224, ChatBand:TargetHeight())
check("PinHeight 首次写入 224", ChatBand:PinHeight(cfs[1]) == true and cfs[1].height == 224,
    cfs[1].height)
local writes = cfs[1].heightWrites
check("PinHeight 已对齐时不重复写", ChatBand:PinHeight(cfs[1]) == false
    and cfs[1].heightWrites == writes)
minimap.height = 300
check("小地图变高时目标跟着变", ChatBand:TargetHeight() == 268, ChatBand:TargetHeight())
minimap.height = 256
cfs[1].height = 256   -- 模拟 FCF_DockUpdate / EditMode 把高度改回去
ChatBand:PinLayout("ChatFrame1")
check("PinLayout 把重排后的高度纠回 224", cfs[1].height == 224, cfs[1].height)
check("PinLayout 同时把输入框钉到空带",
    ebs[1].points[1] and ebs[1].points[1][1] == "BOTTOMLEFT" and ebs[1].points[1][2] == cfs[1],
    ebs[1].points[1] and ebs[1].points[1][1] or "nil")

-- ---------------------------------------------------------------- 输入框锚点
local function Point(f, i)
    local p = f.points[i]
    if not p then return "none" end
    return ("%s>(%s,%s)"):format(tostring(p[1]), tostring(p[4]), tostring(p[5]))
end
check("锚点 1 = BOTTOMLEFT → cf:TOPLEFT (0,0)", Point(ebs[1], 1) == "BOTTOMLEFT>(0,0)", Point(ebs[1], 1))
check("锚点 2 = BOTTOMRIGHT → cf:TOPRIGHT (0,0)", Point(ebs[1], 2) == "BOTTOMRIGHT>(0,0)", Point(ebs[1], 2))
local calls = ebs[1].setCalls
check("锚点已对时不重写", ChatBand:PinEditBox("ChatFrame1") == false and ebs[1].setCalls == calls)
ebs[1].points[2] = { "BOTTOMRIGHT", cfs[1], "TOPLEFT", 8, 69 }   -- 暴雪只改第二点
check("只被改第二锚点也会自愈", ChatBand:PinEditBox("ChatFrame1") == true
    and Point(ebs[1], 2) == "BOTTOMRIGHT>(0,0)", Point(ebs[1], 2))
ebs[1].points[1] = { "BOTTOMLEFT", cfs[1], "TOPLEFT", { __secret = true }, 0 }  -- 机密值
check("机密值读数不误判为已对齐", ChatBand:PinEditBox("ChatFrame1") == true
    and Point(ebs[1], 1) == "BOTTOMLEFT>(0,0)", Point(ebs[1], 1))
ebs[2].alpha = 0.35
ChatBand:PinEditBox("ChatFrame2")
check("非活动窗口的输入框 alpha 抬回 1", ebs[2].alpha == 1, ebs[2].alpha)
check("Skin:Need 缺对象时安全返回", ChatBand:PinEditBox("ChatFrame99") == false)

-- ---------------------------------------------------------------- 页签容器抬升
check("PinLayout 对 ChatFrame1 调 PinDock", band:find("self:PinDock()", 1, true) ~= nil)
check("PinDock 只在 name==ChatFrame1 时调用", band:find('if name == "ChatFrame1" then', 1, true) ~= nil)
check("PinDock 抬升量取自 InputBand（top/hidden→32，bottom→0）", band:find("local want = self:InputBand()", 1, true) ~= nil)
check("PinDock 有 target 空守卫", band:find("local target = self:TargetHeight()", 1, true) ~= nil)

local function DockPointY(i)
    local p = gdm.points[i]
    return p and p[5] or nil
end
-- 模拟 Blizzard 默认锚（GDM 锚在 ChatFrame1Background:TOPLEFT，偏移 0）：cf 缩高 32 后
-- 整条掉进输入框带。PinLayout 在 PinHeight 之后跑 PinDock ⇒ 应抬回 32。
gdm.points = { { "BOTTOMLEFT", bg1, "TOPLEFT", 0, 0 }, { "BOTTOMRIGHT", bg1, "TOPRIGHT", 0, 0 } }
ChatBand:PinLayout("ChatFrame1")
check("PinLayout 把页签容器抬 CHAT_INPUT_BAND（第一锚点）",
    DockPointY(1) == 32 and gdm.points[1][2] == bg1, DockPointY(1))
check("页签容器第二锚点也抬", DockPointY(2) == 32, DockPointY(2))
local dockCalls = gdm.setCalls
ChatBand:PinDock()
check("已抬到位时不重复写", gdm.setCalls == dockCalls, gdm.setCalls - dockCalls)
gdm.points = { { "BOTTOMLEFT", bg1, "TOPLEFT", 0, 0 }, { "BOTTOMRIGHT", bg1, "TOPRIGHT", 0, 0 } }
check("Blizzard 抹回偏移后自愈", ChatBand:PinDock() == true and DockPointY(1) == 32)
gdm.points = { { "BOTTOMLEFT", bg1, "TOPLEFT", 0, 0 }, { "BOTTOMRIGHT", bg1, "TOPRIGHT", 0, 0 } }
local callsBefore = gdm.setCalls
ChatBand:PinLayout("ChatFrame2")
check("非 primary 窗不抬页签容器", gdm.setCalls == callsBefore)
minimap.height = 10
local c = gdm.setCalls
ChatBand:PinDock()
check("minimap 过矮 band 未激活时不抬", gdm.setCalls == c)
minimap.height = 256

-- ---------------------------------------------------------------- 几何重放
local frameTop = 31 + cfs[1].height           -- cf 只锚 BOTTOMLEFT(35,31)，顶 = 底 + 高
local inset, topExtend = 0, BAND
local bgTop = frameTop + (-inset + topExtend) -- Skin:Panel 的 TOPLEFT 相对 cf:TOPLEFT
local ebBottom, ebTop = frameTop, frameTop + 32 -- eb 底贴 cf 顶；Size.y = 32 向下延伸
check("外框比消息区多出整整一条 32 输入带", bgTop - frameTop == 32, bgTop - frameTop)
check("输入框上沿与外框上沿齐平", ebTop == bgTop, ebTop .. " vs " .. bgTop)
check("输入框带完全落在消息区之外（零遮字）", ebBottom >= frameTop)
check("外框顶不侵入页签条（B291）", bgTop <= 291, bgTop)
check("外框轮廓保持原高度（B32..T288）", bgTop - 31 == 256, bgTop - 31)

-- ---------------------------------------------------------------- 悬停显示
check("HoverEnabled：配置开 + chat 面板开", ChatBand:HoverEnabled() == true)
db.skins.hoverChatTabs = false
check("HoverEnabled：配置关", ChatBand:HoverEnabled() == false)
ChatBand:Refresh()
check("关掉开关立刻恢复页签常显", gdm.alpha == 1, gdm.alpha)
db.skins.hoverChatTabs = true
ChatBand:Refresh()
check("无人悬停先排队延迟隐藏", #timers == 1 and gdm.alpha == 1, #timers)
FlushTimers()
check("延迟到期后页签隐藏（GDM alpha 0）", gdm.alpha == 0, gdm.alpha)
local alphaWrites = gdm.alphaWrites
check("重复隐藏不重复写 alpha", ChatBand:SetTabsVisible(false) == false
    and gdm.alphaWrites == alphaWrites)
ChatBand.Enter(cfs[1])
check("鼠标进聊天框立刻显示页签", gdm.alpha == 1 and ChatBand:AnyHover() == true, gdm.alpha)
ChatBand.Leave(cfs[1])
check("离开时先排队隐藏，不立刻灭", #timers == 1 and gdm.alpha == 1, #timers)
ChatBand.Enter(gdm)   -- 跨 3px 缝进入页签条
FlushTimers()
check("跨缝进页签：旧隐藏请求被 token 作废", gdm.alpha == 1, gdm.alpha)
ChatBand.Leave(gdm)
FlushTimers()
check("真正离开后页签隐藏", gdm.alpha == 0, gdm.alpha)
chatPanelEnabled = false
ChatBand:Refresh()
check("chat 皮肤面板关掉时页签恢复常显", gdm.alpha == 1, gdm.alpha)
chatPanelEnabled = true
ChatBand:Setup()
check("Setup 注册 10 cf + 10 eb + 1 GDM = 21 个悬停观察", #hoverLog == 21, #hoverLog)
ChatBand:Setup()
check("Setup 重跑不重复登记", #hoverLog == 21, #hoverLog)
check("M:RefreshChatTabHover 暴露给配置面板", type(M.RefreshChatTabHover) == "function")

-- ---------------------------------------------------------------- Apply 链
SkinChat()
local topExtendSeen
for _, e in ipairs(dressLog) do
    if e.names == CHAT_FRAMES and e.opts and e.opts.panel then
        topExtendSeen = e.opts.panel.topExtend
    end
end
check("Apply 把 topExtend 传给 Skin:Panel", topExtendSeen == BAND, topExtendSeen)
check("Apply 为 10 个聊天窗各挂一条 PollWatch", #pollLog == 10, #pollLog)
check("PEW 再校一次高度", #busLog >= 1 and busLog[1] == "PLAYER_ENTERING_WORLD")
check("chat 面板注册带 apply", #panelLog == 1 and panelLog[1].key == "chat"
    and type(panelLog[1].opts.apply) == "function")

-- §8.91 输入框自动隐藏（默认开启；此处开 autoHide 验折叠 + 背景色同步）
db.skins.chatEditBoxAutoHide = true
db.skins.chatEditBoxPos = "top"   -- 关闭时的位置
check("§8.91 EditBoxPos 默认隐藏（autoHide 开）", ChatBand:EditBoxPos() == "hidden")
check("§8.91 InputBand 保留 32 带（hidden 不回收，避免聚焦落底）",
    ChatBand:InputBand() == 32, ChatBand:InputBand())
check("§8.91 hidden 时目标高度仍扣 32（带保留）", ChatBand:TargetHeight() == 224, ChatBand:TargetHeight())
cfs[1].height = 256   -- 模拟 bottom 遗留高度（不扣带），hidden 应写回 224
check("§8.91 PinHeight 写回 224", ChatBand:PinHeight(cfs[1]) == true and cfs[1].height == 224, cfs[1].height)
gdm.points = { { "BOTTOMLEFT", bg1, "TOPLEFT", 0, 0 }, { "BOTTOMRIGHT", bg1, "TOPRIGHT", 0, 0 } }
ChatBand:PinLayout("ChatFrame1")
check("§8.91 hidden 时页签容器仍抬 32（带保留）", DockPointY(1) == 32, DockPointY(1))
-- controlBg 背板同步（修复"背景色一直显示"）：桩里让 Marked 返回 bg 对象
ebs[1].bg = add("ChatFrame1EditBoxBg", 32, 1)
ns.Marked = function(o, k)
    if k == "controlBg" and o == ebs[1] then return ebs[1].bg end
    return nil
end
ebs[1].focused = false
ChatBand:HideEditBox("ChatFrame1")
check("§8.91 未聚焦时折叠输入框 + 背景色背板",
    ebs[1].shown == false and ebs[1].bg.shown == false,
    "eb=" .. tostring(ebs[1].shown) .. " bg=" .. tostring(ebs[1].bg.shown))
ebs[1].focused = true
ChatBand:HideEditBox("ChatFrame1")
check("§8.91 聚焦时显示输入框 + 背景色背板",
    ebs[1].shown == true and ebs[1].bg.shown == true,
    "eb=" .. tostring(ebs[1].shown) .. " bg=" .. tostring(ebs[1].bg.shown))
ebs[1].focused = false
ChatBand:PinLayout("ChatFrame1")
check("§8.91 PinLayout hidden 分支调 HideEditBox 折叠输入框 + 背板",
    ebs[1].shown == false and ebs[1].bg.shown == false,
    "eb=" .. tostring(ebs[1].shown) .. " bg=" .. tostring(ebs[1].bg.shown))
db.skins.chatEditBoxAutoHide = false

print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
os.exit(failed == 0 and 0 or 1)
