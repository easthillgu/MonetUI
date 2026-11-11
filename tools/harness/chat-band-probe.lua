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
    -- §8.92 层级切换：桩里给一个可读写的 frameLevel（默认 1，与实机 LOW/lvl1 一致）
    function f:GetFrameLevel() return self.frameLevel or 1 end
    function f:SetFrameLevel(v) self.frameLevel = v; self.levelWrites = (self.levelWrites or 0) + 1 end
    -- §8.95 按钮框：α0 时必须同时关鼠标，否则"看不见但点得到"
    function f:EnableMouse(v) self.mouse = v and true or false; self.mouseWrites = (self.mouseWrites or 0) + 1 end
    -- §8.96/§8.92 鼠标仲裁断言用：几何悬停态（桩里手动置 mouseOver）
    function f:IsMouseOver() return self.mouseOver == true end
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
local cfs, ebs, bfs, tabs = {}, {}, {}, {}
for i = 1, 10 do
    cfs[i] = add("ChatFrame" .. i, 256, 1)
    ebs[i] = add("ChatFrame" .. i .. "EditBox", 32, (i == 1 and 1 or 0.35))
    -- §8.92 鼠标仲裁断言用：页签对象（几何悬停态手动置 mouseOver）
    tabs[i] = add("ChatFrame" .. i .. "Tab", 32, 1)
    -- §8.95 实机：ChatFrame1..4 = 1.00、5..10 = 0.20（暴雪按窗口激活态写），我们接手后统一写同一值
    bfs[i] = add("ChatFrame" .. i .. "ButtonFrame", 32, (i <= 4 and 1 or 0.2))
end
-- §8.95 挂在聊天框外、逻辑属聊天框的两枚暴雪按钮（ReparentChatFrames 重挂到 UIParent）
local qj = add("QuickJoinToastButton", 32, 1)          -- 作者说的"左上的社交按钮"
local tts = add("TextToSpeechButtonFrame", 26, 1)

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
check("§8.93 InputBand 恒 0（外框不再从框内挖 32 输入带）",
    band:find("function ChatBand:InputBand", 1, true) ~= nil
    and band:find("function ChatBand:InputBand()\n    return 0\nend", 1, true) ~= nil)
check("§8.93 TargetHeight 固定扣 CHAT_INPUT_BAND（cf 顶边对齐小地图上沿）",
    band:find("return h - CHAT_INPUT_BAND", 1, true) ~= nil)
check("§8.91 skinner.frame hidden 也 PinEditBox（不落底部）+ HideEditBox",
    band:find('pos == "top" or pos == "hidden"', 1, true) ~= nil
    and band:find("self:HideEditBox(name)", 1, true) ~= nil)
check("§8.91 新增 HideEditBox（按焦点态 SetShown）",
    band:find("function ChatBand:HideEditBox", 1, true) ~= nil)
check("§8.96 配置面板暴露输入框三档下拉 + 位置下拉",
    cfgSrc:find('"输入框平时状态"', 1, true) ~= nil
    and cfgSrc:find('"输入框位置（常显 / 渐隐时）"', 1, true) ~= nil
    and cfgSrc:find('{ value = "fade"', 1, true) ~= nil)
check("§8.96 DEFAULTS 默认渐隐档 + 保留废弃键做迁移",
    coreSrc:find('chatEditBoxMode = "fade"', 1, true) ~= nil
    and coreSrc:find('chatEditBoxAutoHide = true', 1, true) ~= nil)

-- ---------------------------------------------------------------- §8.96 输入框空闲渐隐
-- 参考实现（千问 ChatEditFade.lua）在实测环境里两处硬伤：`UIFade` 为 nil、
-- `OnEditFocusGained/Lost/OnUpdate` 脚本槽已被暴雪占用（SetScript 会顶掉暴雪逻辑）。
-- 这里把"必须换掉"钉成回归断言，防止以后有人照抄回去。
check("§8.96 四个渐隐参数与参考实现对齐",
    band:find("CHAT_EDIT_IDLE_ALPHA  = 0.25", 1, true) ~= nil
    and band:find("CHAT_EDIT_FADE_OUT    = 0.35", 1, true) ~= nil
    and band:find("CHAT_EDIT_FADE_IN     = 0.20", 1, true) ~= nil
    and band:find("CHAT_EDIT_IDLE_DELAY  = 3.0", 1, true) ~= nil)
check("§8.96 不占用暴雪的焦点脚本槽（不 SetScript OnEditFocus*）",
    band:find('SetScript("OnEditFocusGained"', 1, true) == nil
    and band:find('SetScript("OnEditFocusLost"', 1, true) == nil)
check("§8.96 焦点态走 HasFocus 轮询（不挂钩子）",
    band:find("eb.HasFocus, eb", 1, true) ~= nil)
check("§8.96 不调用不存在的 UIFade",
    band:find("UIFade(", 1, true) == nil)
check("§8.96 EditBoxMode 三档 + 老布尔迁移",
    band:find("function ChatBand:EditBoxMode", 1, true) ~= nil
    and band:find('if m == "hide" or m == "fade" or m == "show" then return m end', 1, true) ~= nil
    and band:find('if self:Opt("chatEditBoxAutoHide") == false then return "show" end', 1, true) ~= nil)
check("§8.96 PinEditBox 在 fade 档不把 alpha 拉回 1（否则永远渐不隐）",
    band:find('shown and self:EditBoxMode() ~= "fade"', 1, true) ~= nil)
check("§8.96 HideEditBox 在 fade 档早退到 HoldEditBox（两条路不打架）",
    band:find('if self:EditBoxMode() == "fade" then\n        self:HoldEditBox(name)\n        return\n    end', 1, true) ~= nil)

-- §8.90/§8.91 判例（2026-11-11 实机：输入框背景色一直在、频道色不生效）
-- `ns:Marked` 是冒号方法，写成 `ns.Marked(obj, "controlBg")` 会把 self 顶成 object、
-- 把 key 顶成 "controlBg" 的上一级 → 恒返回 nil，背板永远取不到。这里把该类写法钉死。
check("§8.91 无 ns.Marked( 点调用（少 self 的回归）",
    social:find("ns%.Marked%(") == nil)
check("§8.91 有 ns:Marked 局部别名（项目惯例）",
    social:find("local Marked = function(o, k) return ns:Marked(o, k) end", 1, true) ~= nil
    or social:find("local Marked = function(o,k) return ns:Marked(o,k) end", 1, true) ~= nil)
check("§8.90 ApplyChannelColor 走局部 Marked 取 controlBg",
    band:find('local cb = Marked(eb, "controlBg")', 1, true) ~= nil)
check("§8.91 HideEditBox 走局部 Marked 取 controlBg",
    band:find('pcall(Marked, eb, "controlBg")', 1, true) ~= nil)

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
-- controlBg 背板桩 + env.Marked 覆盖**必须**在第一次行为级 PinLayout 之前装好：
-- §8.92 三态层级在 skinner 拍里跑 SyncInputLayer，第一次见输入框就记原始层级；
-- 那时 Marked 还取不到背板，rec.cb 记成 nil，后面"还原"分支就永远跳过背板
-- （2026-11-11 三态层级修复时抓到的桩序问题；实机 Marked 恒可用，不受影响）。
-- 另：切片在 env 里执行，`Marked(...)` 解析到 **env.Marked**（不是 ns.Marked）；
-- 2026-11-11 实机判例：写成 `ns.Marked(eb,"controlBg")`（点调用少 self）会恒返回 nil，
-- 背板永远取不到 —— 所以这里必须覆盖 env.Marked，才能验到真实取背板路径。
ebs[1].bg = add("ChatFrame1EditBoxBg", 32, 1)
env.Marked = function(o, k)
    if k == "controlBg" and o == ebs[1] then return ebs[1].bg end
    return nil
end
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
check("PinDock 目标偏移 = CHAT_TAB_LIFT − 页签落座量（§8.94）",
    band:find("local want = CHAT_TAB_LIFT - TabSeat(gdm)", 1, true) ~= nil)
check("PinDock 锚我们自己的 skinBg（不锚内缩 3 的暴雪 Background）",
    band:find('Marked(host, "skinBg")', 1, true) ~= nil
    and band:find("local ref = bg or r1", 1, true) ~= nil)
check("PinDock 有 target 空守卫", band:find("local target = self:TargetHeight()", 1, true) ~= nil)
-- §8.94 三层浓度统一：常量定义 + 三处引用，任何一处被改回裸数字都会红。
check("§8.94 统一定义 CHAT_PLATE_ALPHA / CHAT_EDGE_ALPHA",
    band:find("local CHAT_PLATE_ALPHA = 0.35", 1, true) ~= nil
    and band:find("local CHAT_EDGE_ALPHA  = 0.80", 1, true) ~= nil)
check("§8.94 聊天框 / 页签 / 输入框三处共用同一档",
    band:find("bgAlpha = CHAT_PLATE_ALPHA", 1, true) ~= nil
    and band:find("borderAlpha = CHAT_EDGE_ALPHA", 1, true) ~= nil
    and band:find("bgAlpha = CHAT_PLATE_ALPHA, borderAlpha = CHAT_EDGE_ALPHA", 1, true) ~= nil)
check("§8.94 频道色边框也用同一档浓度",
    band:find("Widget:SetBorderState(cb, r, g, b, CHAT_EDGE_ALPHA)", 1, true) ~= nil)
-- §8.94 暴雪自带的黑底板（BACKGROUND 447×233）+ 8 张黑边框（BORDER）有效 α0.25，
-- 叠在我们的 0.35 板上会让框体比页签块实一倍 —— 必须在每次 PinLayout 里压成 0。
check("§8.94 压掉 cf 自带的黑底板/黑边框",
    band:find("function ChatBand:FadeNativePlate", 1, true) ~= nil
    and band:find("self:FadeNativePlate(cf)", 1, true) ~= nil)
check("§8.94 只按 layer 认（BACKGROUND/BORDER），不点名贴图",
    band:find('layer == "BACKGROUND" or layer == "BORDER"', 1, true) ~= nil)

local function DockPointY(i)
    local p = gdm.points[i]
    return p and p[5] or nil
end
-- §8.92：页签与 EditBox 共用 32 带，目标偏移是 0。模拟暴雪把整条抹到 -32（掉进消息区）：
-- PinLayout 在 PinHeight 之后跑 PinDock ⇒ 应拉回 0。
gdm.points = { { "BOTTOMLEFT", bg1, "TOPLEFT", 0, -32 }, { "BOTTOMRIGHT", bg1, "TOPRIGHT", 0, -32 } }
ChatBand:PinLayout("ChatFrame1")
check("PinLayout 把页签容器拉回输入带内（第一锚点偏移 0）",
    DockPointY(1) == 0 and gdm.points[1][2] == bg1, DockPointY(1))
check("页签容器第二锚点也回 0", DockPointY(2) == 0, DockPointY(2))
local dockCalls = gdm.setCalls
ChatBand:PinDock()
check("已到位时不重复写", gdm.setCalls == dockCalls, gdm.setCalls - dockCalls)
gdm.points = { { "BOTTOMLEFT", bg1, "TOPLEFT", 0, -32 }, { "BOTTOMRIGHT", bg1, "TOPRIGHT", 0, -32 } }
check("Blizzard 抹回偏移后自愈", ChatBand:PinDock() == true and DockPointY(1) == 0)
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
local inset, topExtend = 0, ChatBand:InputBand()
local bgTop = frameTop + (-inset + topExtend) -- Skin:Panel 的 TOPLEFT 相对 cf:TOPLEFT
local ebBottom, ebTop = frameTop, frameTop + 32 -- eb 底贴 cf 顶；Size.y = 32 向下延伸
check("§8.93 外框与消息区等高（不再多出 32 输入带）", bgTop - frameTop == 0, bgTop - frameTop)
check("§8.93 输入框整条落在框顶外侧（骑在边框上）", ebBottom == bgTop and ebTop == bgTop + 32,
    ebBottom .. ".." .. ebTop)
check("§8.93 输入框带零遮字（底边不低于框顶）", ebBottom >= frameTop)
check("§8.93 外框高度 = 小地图高 − 32（顶边落在上沿的前提）", bgTop - 31 == 224, bgTop - 31)

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

-- ---------------------------------------------------------------- §8.95 聊天镀铬
-- 作者 11-11："聊天框左上的社交按钮没有隐藏掉"。实机 ChatFrameNButtonFrame 的 alpha 我们从没管过，
-- 暴雪按窗口激活态写 1.00（1..4）或 0.20（5..10），所以页签淡到 0 了喇叭按钮还亮着。
check("§8.95 页签隐藏时 ButtonFrame 一起归 0",
    bfs[1].alpha == 0 and bfs[4].alpha == 0,
    "bf1=" .. tostring(bfs[1].alpha) .. " bf4=" .. tostring(bfs[4].alpha))
check("§8.95 未激活窗的 0.2 也统一到同一档", bfs[5].alpha == 0, bfs[5].alpha)
check("§8.95 α0 时关掉鼠标（否则看不见但能点，会误弹频道菜单）",
    bfs[1].mouse == false, tostring(bfs[1].mouse))
bfs[2].alpha = 1                       -- 模拟暴雪在 CHAT_UPDATE / 窗口激活时写回 1.0
ChatBand:SyncChrome()
check("§8.95 暴雪改回 1.0 后 1 秒轮询纠回 0", bfs[2].alpha == 0, bfs[2].alpha)
bfs[3].alpha = 0.2
check("§8.95 GDM 已达标时 SetTabsVisible 仍纠 ButtonFrame",
    ChatBand:SetTabsVisible(false) == false and bfs[3].alpha == 0, bfs[3].alpha)
check("§8.95 框外两枚社交按钮（QuickJoin / TTS）同样归 0 且关鼠标",
    qj.alpha == 0 and qj.mouse == false and tts.alpha == 0 and tts.mouse == false,
    "qj=" .. tostring(qj.alpha) .. "/" .. tostring(qj.mouse))
qj.alpha = 1                           -- 暴雪给快速加入按钮做 toast 动画时会写回 1.0
ChatBand:SyncChrome()
check("§8.95 QuickJoin 被暴雪写回后仍纠回 0", qj.alpha == 0, qj.alpha)
ChatBand:SetTabsVisible(true)
check("§8.95 显示时 ButtonFrame α1 且鼠标恢复",
    bfs[1].alpha == 1 and bfs[1].mouse == true,
    tostring(bfs[1].alpha) .. "/" .. tostring(bfs[1].mouse))
check("§8.95 显示时框外社交按钮也恢复可点",
    qj.alpha == 1 and qj.mouse == true, tostring(qj.alpha) .. "/" .. tostring(qj.mouse))
check("§8.95 新增 ApplyChromeAlpha / SyncChrome",
    band:find("function ChatBand:ApplyChromeAlpha", 1, true) ~= nil
    and band:find("function ChatBand:SyncChrome", 1, true) ~= nil)
check("§8.95 按钮框名由窗口名派生（不硬编码十个）",
    band:find('Skin:Need(name .. "ButtonFrame")', 1, true) ~= nil)
check("§8.95 PinLayout 只在 ChatFrame1 这一拍同步镀铬",
    band:find('if name == "ChatFrame1" then self:SyncChrome() end', 1, true) ~= nil)
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
check("§8.93 Apply 传 topExtend = 0（框内不再留带）", topExtendSeen == 0, topExtendSeen)
check("Apply 为 10 个聊天窗各挂一条 PollWatch", #pollLog == 10, #pollLog)
check("PEW 再校一次高度", #busLog >= 1 and busLog[1] == "PLAYER_ENTERING_WORLD")
check("chat 面板注册带 apply", #panelLog == 1 and panelLog[1].key == "chat"
    and type(panelLog[1].opts.apply) == "function")

-- §8.91 输入框自动隐藏（默认开启；此处开 autoHide 验折叠 + 背景色同步）
db.skins.chatEditBoxAutoHide = true
db.skins.chatEditBoxPos = "top"   -- 关闭时的位置
check("§8.91 EditBoxPos 默认隐藏（autoHide 开）", ChatBand:EditBoxPos() == "hidden")
check("§8.93 InputBand 恒 0（与 EditBox 位置档无关）",
    ChatBand:InputBand() == 0, ChatBand:InputBand())
check("§8.93 目标高度 = 小地图高 − 32（与隐藏档无关）", ChatBand:TargetHeight() == 224, ChatBand:TargetHeight())
cfs[1].height = 256   -- 模拟 bottom 遗留高度（不扣带），hidden 应写回 224
check("§8.91 PinHeight 写回 224", ChatBand:PinHeight(cfs[1]) == true and cfs[1].height == 224, cfs[1].height)
gdm.points = { { "BOTTOMLEFT", bg1, "TOPLEFT", 0, 0 }, { "BOTTOMRIGHT", bg1, "TOPRIGHT", 0, 0 } }
ChatBand:PinLayout("ChatFrame1")
check("§8.91 hidden 时页签容器仍落带内（偏移 0，§8.92 同区）", DockPointY(1) == 0, DockPointY(1))
-- controlBg 背板桩与 env.Marked 覆盖已前移到第一次行为级 PinLayout 之前（见上文注）。
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
-- §8.92 同区层级：页签与输入框共用 32 带，聚焦时把输入框压到页签（GDM+1）之上，失焦原样放回。
check("§8.92 聚焦时输入框抬到 GDM 之上（GDM+3）",
    ebs[1]:GetFrameLevel() == gdm:GetFrameLevel() + 3, tostring(ebs[1]:GetFrameLevel()))
check("§8.92 背板随输入框一起抬（eb-1）",
    ebs[1].bg:GetFrameLevel() == ebs[1]:GetFrameLevel() - 1, tostring(ebs[1].bg:GetFrameLevel()))
check("§8.92 HideEditBox 先 SyncInputLayer 再 SetShown",
    band:find("self:SyncInputLayer(name", 1, true) ~= nil)
ebs[1].focused = false
ChatBand:PinLayout("ChatFrame1")
check("§8.91 PinLayout hidden 分支调 HideEditBox 折叠输入框 + 背板",
    ebs[1].shown == false and ebs[1].bg.shown == false,
    "eb=" .. tostring(ebs[1].shown) .. " bg=" .. tostring(ebs[1].bg.shown))
check("§8.92 失焦后输入框与背板层级都还原",
    ebs[1]:GetFrameLevel() == 1 and ebs[1].bg:GetFrameLevel() == 1,
    tostring(ebs[1]:GetFrameLevel()) .. "/" .. tostring(ebs[1].bg:GetFrameLevel()))
-- §8.96 fade 档行为：只写 alpha、不写显隐；alpha 必须同时到背板（§8.91 踩过的坑）
ebs[1].alpha, ebs[1].bg.alpha = 1, 1
ChatBand:SetEditAlpha("ChatFrame1", 0.25)
check("§8.96 SetEditAlpha 同时写 EditBox 与 controlBg 背板",
    math.abs(ebs[1].alpha - 0.25) < 0.01 and math.abs(ebs[1].bg.alpha - 0.25) < 0.01,
    tostring(ebs[1].alpha) .. "/" .. tostring(ebs[1].bg.alpha))
db.skins.chatEditBoxMode = "fade"
ChatBand:ReleaseEditFade("ChatFrame1")
check("§8.96 ReleaseEditFade 无状态时不乱写 alpha",
    math.abs(ebs[1].alpha - 0.25) < 0.01, tostring(ebs[1].alpha))
ebs[1].shown = false
ChatBand:HoldEditBox("ChatFrame1")
check("§8.96 fade 档 HoldEditBox 把输入框保持 shown（渐隐不用 SetShown 藏）",
    ebs[1].shown == true, tostring(ebs[1].shown))
ChatBand:ReleaseEditFade("ChatFrame1")
check("§8.96 退出渐隐档 alpha 复位 1（否则半透明会漂到 show 档）",
    math.abs(ebs[1].alpha - 1) < 0.01, tostring(ebs[1].alpha))

-- §8.92 输入框鼠标仲裁（2026-11-11 二次修复：实机证伪层级仲裁 —— 压到 L0 仍被抢，
-- 裁决与 level 无关 ⇒ 改几何让位，三档通用）：鼠标在任何页签上 = 恒让位；
-- 否则聚焦或悬停输入框自身时开。
db.skins.chatEditBoxMode = "fade"
ebs[1].shown = true
ebs[1].focused = false
ebs[1].mouseOver = false
tabs[1].mouseOver = false
ChatBand:SyncEditMouse("ChatFrame1")
check("§8.92 鼠标不在聊天区：输入框鼠标关（让位页签 / 世界）",
    ebs[1].mouse == false, tostring(ebs[1].mouse))
ebs[1].mouseOver = true
ChatBand:SyncEditMouse("ChatFrame1")
check("§8.92 悬停输入框自身（不在页签上）：鼠标开（点输入框聚焦的手感）",
    ebs[1].mouse == true, tostring(ebs[1].mouse))
tabs[1].mouseOver = true
ChatBand:SyncEditMouse("ChatFrame1")
check("§8.92 悬停页签：未聚焦也让位（页签点击修复核心）",
    ebs[1].mouse == false, tostring(ebs[1].mouse))
ebs[1].focused = true
ChatBand:SyncEditMouse("ChatFrame1")
check("§8.92 聚焦但鼠标在页签上：仍让位（修打字时点页签被抢）",
    ebs[1].mouse == false, tostring(ebs[1].mouse))
tabs[1].mouseOver = false
ChatBand:SyncEditMouse("ChatFrame1")
check("§8.92 聚焦且不在页签上：鼠标开（点输入框内可摆光标）",
    ebs[1].mouse == true, tostring(ebs[1].mouse))
ebs[1].focused = false
-- §8.92 三态层级（2026-11-11 页签点击修复）：常显 + 未聚焦时输入框压到页签容器之下（GDM−1），
-- 点击归页签 —— 平局裁决按建框先后，同 level 时晚建的输入框会赢，必须显式错开。
db.skins.chatEditBoxMode = "fade"
ebs[1].shown = true
ebs[1].focused = false
ChatBand:SyncInputLayer("ChatFrame1")
check("§8.92 常显未聚焦：输入框压到 GDM-1（页签点击修复）",
    ebs[1]:GetFrameLevel() == gdm:GetFrameLevel() - 1, tostring(ebs[1]:GetFrameLevel()))
check("§8.92 常显未聚焦：背板跟着压（eb-1，不低于 0）",
    ebs[1].bg:GetFrameLevel() == math.max(0, ebs[1]:GetFrameLevel() - 1), tostring(ebs[1].bg:GetFrameLevel()))
ebs[1].focused = true
ChatBand:SyncInputLayer("ChatFrame1")
check("§8.92 聚焦仍抬到 GDM+3（原设计不变）",
    ebs[1]:GetFrameLevel() == gdm:GetFrameLevel() + 3, tostring(ebs[1]:GetFrameLevel()))
ebs[1].focused = false
ChatBand:SyncInputLayer("ChatFrame1")
check("§8.92 失焦仍显示：再压回 GDM-1",
    ebs[1]:GetFrameLevel() == gdm:GetFrameLevel() - 1, tostring(ebs[1]:GetFrameLevel()))
db.skins.chatEditBoxAutoHide = false

print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
os.exit(failed == 0 and 0 or 1)
