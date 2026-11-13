-- Modules/Skins/Skins.lua
-- Blizzard panel beautification (界面美化) engine: panel files (Modules/Skins/*.lua) register windows through Skins:Panel(key, { apply = fn, ... }); the engine applies them at login / ADDON_LOADED / loading screen, records every mutation for rollback, and exposes the list to the config panel.
-- Skins only fade Blizzard art and add our own child frames: no SetScript / SetParent / SetShown / Hide on a Blizzard frame; hover feedback is polled (Widget:HoverWatch) -- never HookScript.

local ADDON_NAME, ns = ...

local Skin     = ns.Skin
local Media    = ns.Media
local EventBus = ns.EventBus
local Widget   = ns.Widget
local Secrets  = ns.Secrets


-- 旁表标记：**绝不往暴雪的框体 / 贴图 / 字体串上写字段**。
-- 本客户端把“插件写过字段的对象”判成脏的（实机：issecurevariable 在 NamePlate1UnitFrame 上唯一为 false 的键就是我们的
-- 标记，随后暴雪自己的 OnUpdate 就报 secret value / anchor family），所以标记一律走
-- Core.lua 的 ns:Mark / ns:Marked（以对象为弱键的旁表）。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
-- 模块私有的幂等守卫键走 per-module 弱旁表（ns:NewFrameData，Ellesmere 同款）：
-- `deepSweep`/`extrasSweep`/`showHook` 只在本文件读写，迁到这里就不再占全局键名空间。
-- 跨文件共享的键（art/hidden/skinBg…）仍走上面的 Mark/Marked。
local FFD, GetFFD = ns:NewFrameData()

local M = { name = "Skins" }
ns.Skins = M

M.registry = {}   -- ordered list of panel entries
M.byKey    = {}   -- key -> entry
M.active   = false

--- 展平 `frames` 名单：字符串照收，表递归展开。
--- 名单允许直接引用皮肤文件里那份**代码在用的**常量表，不再手抄第二遍 —— 抄的那份会漂
--- （本轮就抓到 EditModeManager / EditModeManagerFrameAcceptChanges / MacroEditBox 三处
--- 名单与代码不一致）。Lua 5.1 的 `unpack` 只有摆在表构造器**最末位**才展开全部返回值，
--- 中间位置会被截成一个，所以这里不用 unpack，用嵌套表。
local function FlattenFrames(spec, out)
    out = out or {}
    if type(spec) ~= "table" then return out end
    for i = 1, #spec do
        local item = spec[i]
        if type(item) == "string" then
            out[#out + 1] = item
        else
            FlattenFrames(item, out)
        end
    end
    return out
end

--- Register one window / group of windows for beautification.
-- @param opts { label, group, apply = function(entry) (idempotent), default = false to ship off, addons = { ... }, frames = { ... 字符串或常量表 } }
function M:Panel(key, opts)
    assert(type(key) == "string", "Skins:Panel needs a string key")
    opts = opts or {}

    local entry = {
        key     = key,
        label   = opts.label or key,
        group   = opts.group or "其它",
        apply   = opts.apply,
        default = opts.default ~= false,
        -- Blizzard load-on-demand addons this pack waits for, e.g. { Blizzard_Collections = true }; the pack is applied once one is loaded, and re-applied the moment one arrives.
        addons  = opts.addons,
        -- 这个皮肤包**打算**碰的暴雪对象（点路径）。诊断优先读实际查找的账本，这一份只在
        -- 面板从没跑过时兜底核对；同时它是离线闸门 tools/check-frame-list.js 的输入。
        frames  = FlattenFrames(opts.frames),
    }

    if not self.byKey[key] then
        self.registry[#self.registry + 1] = entry
    else
        -- replace the placeholder in place
        for i = 1, #self.registry do
            if self.registry[i].key == key then
                self.registry[i] = entry
                break
            end
        end
    end

    self.byKey[key] = entry
    return entry
end

function M:Settings()
    local db = ns:DB()
    if type(db.skins) ~= "table" then db.skins = {} end
    return db.skins
end

function M:IsEnabled(key)
    local entry = self.byKey[key]
    local panels = self:Settings().panels
    local value = panels and panels[key]
    if value == nil then
        value = entry and entry.default
    end
    return value ~= false
end

--- Has a pack's load-on-demand addon (if declared) actually loaded?  A missing addon keeps the pack idle; the lookup is pcall'd, so it can never raise.
local function AddonLoaded(name)
    local api = _G.C_AddOns
    if not (api and api.IsAddOnLoaded) then return false end
    local ok, loaded = pcall(api.IsAddOnLoaded, name)
    return ok and loaded and true or false
end

--- Can this pack be applied right now?  Packs that declared `addons` wait for one of them; everything else is always applicable.
function M:IsApplicable(entry)
    local addons = entry and entry.addons
    if not addons then return true end
    for name in pairs(addons) do
        if AddonLoaded(name) then return true end
    end
    return false
end

--- Toggle a single panel.  Enabling applies live; disabling needs a /reload to put Blizzard's art fully back, which the message says.
function M:SetPanelEnabled(key, value)
    local skins = self:Settings()
    skins.panels = skins.panels or {}
    skins.panels[key] = value and true or false

    if value then
        if self.active then
            self:Apply(self.byKey[key])
        end
    else
        ns:Print("界面美化「" .. tostring(key) .. "」已关闭，执行 /reload 后恢复原生外观。")
    end
end

function M:IsActive()
    return self.active and true or false
end

function M:Apply(entry)
    if not entry or type(entry.apply) ~= "function" then return end
    if not self:IsApplicable(entry) then return end
    if not self:IsEnabled(entry.key) then return end

    local ok, err = pcall(Skin.With, entry.key, entry.apply, entry)
    if not ok then
        -- Report a given panel once, not once per pass.  A pack that throws on this client is re-applied
        -- by every ApplyAll, every ADDON_LOADED burst, every PLAYER_ENTERING_WORLD and its own
        -- QUEST_LOG_UPDATE / WORLD_MAP_UPDATE hook, so an unguarded print turns one broken frame name
        -- into dozens of identical lines per session.
        if not entry.__applyFailed then
            entry.__applyFailed = true -- TAINT-OK: entry 是自建注册表记录（纯 Lua table），非暴雪对象
            ns:Print("界面美化「" .. tostring(entry.key) .. "」应用失败: " .. tostring(err))
        end
    end
end

function M:ApplyAll()
    for i = 1, #self.registry do
        self:Apply(self.registry[i])
    end
end

--- Collapse a burst of calls into a single pass on the next frame (C_Timer.After(0)); wrap repaint hooks in this so a burst costs one repaint, not dozens.
function M:Debounce(fn)
    local pending = false
    return function()
        if pending then return end
        pending = true
        C_Timer.After(0, function()
            pending = false
            if M.active then pcall(fn) end
        end)
    end
end

--- 物品图标的"显示期补扫"（稳定引用，ShowWatch 与 PollWatch 共用同一个函数）。
--- **LoD 图标裁切失效的主因就是缺这一条**：`M:Dress` 的 Apply 只在登录那拍扫一次图标，
--- 而 LoD 包的格子那时还没出生 / 还没排版；只有 `deep + lazy` 的窗口有 `SweepDeep` 轮询兜着，
--- 其余窗口此后再没人进来看一眼。这里按"可见期每秒一趟"补，窗口藏着时驱动自己停。
local function IconPass(frame)
    if not M.active or not frame then return end
    local fd = GetFFD(frame)
    if not fd.iconPass then return end
    pcall(M.IconWidgetsIn, M, frame, nil, fd.iconInfo)
end

--- 窗口**每次显示**补的一趟（LoD 包的救场，稳定引用：`Widget:ShowWatch` 按函数身份去重）。
--- 补四样"显示时才出生 / 会被暴雪重设"的东西：
---   ① 滚动条（`SkinScrollsIn`：ScrollFrame / ScrollBox 细把手 / 上下箭头）；
---   ② 肖像（`Skin:HidePortraits`：三种放法一并压掉）；
---   ③ 方向钮（`Skin:WatchMaximizeMinimize`：sweep 一遍 + 自己登记 ShowWatch）；
---   ④ 物品图标（`IconPass`，与 Dress 登记的可见期轮询同一个函数）。
--- 关闭按钮不在这里：它自己的 `FadeChildBoxArt` 已经按显示时机补过。
local function WindowShowPass(frame)
    if not M.active or not frame then return end
    pcall(M.SkinScrollsIn, M, frame)
    pcall(Skin.HidePortraits, Skin, frame)
    pcall(Skin.WatchMaximizeMinimize, Skin, frame)
    IconPass(frame)
end

--- The common window treatment: fade the frame's *own* chrome (not its children, so icons stay intact), hang a Monet backplate under it, restyle title and close button.
-- @param opts { layer, inset, panel = Widget:Theme opts, titleSize, noTitle = true, noClose = true, inset = true|{opts} }
function M:SkinWindow(frame, opts)
    if not frame then return nil end
    opts = opts or {}

    Skin:Strip(frame, opts.strip)
    Skin:Panel(frame, opts.panel)

    -- 正文凹槽那一档（insetFrame.bg）：窗口有 `.Inset` 就补 lost 底 + 我们的凹槽边框，没有就什么都不做
    -- （Skin:InsetWell 自带这层判断）。`inset = true` 用默认档；要调底色/边框传 `inset = { bgSurface=..., ... }`。
    if opts.inset then
        Skin:InsetWell(frame, type(opts.inset) == "table" and opts.inset or nil)
    end

    -- 多内容窗口的次级内容区（列表 / 详情 / 侧栏 / 底栏）：同一套凹槽语言
    -- （Skin:Well）。键是**名字后缀**：`wells = { MountDisplay = true, MoneyBg = { borderAlpha = 0 } }`
    -- 解析 frame[suffix] 或同名全局 <窗口名>..suffix；懒建区（第一次显示才生成）由 Well 内部的
    -- ShowWatch 延迟补。区不存在整体 no-op，任何窗口都能安全地写。
    if opts.wells then
        for suffix, wopts in pairs(opts.wells) do
            Skin:Well(frame, suffix, type(wopts) == "table" and wopts or nil)
        end
    end

    -- 肖像：**一律剥掉**（2026-11-13 作者口径："各个界面的 portrait 都要剥除掉"）。
    -- 以前是逐窗口 opt-in（`opts.portrait`），没写这个开关的窗口各留一张圆肖像；
    -- 取法三种（`.Portrait` / `PortraitContainer` / `PortraitOverlay`）见 `Skin:HidePortraits`。
    -- `portrait = false` 仍可单独豁免（给"那个位置其实不是肖像"的窗口留口子）。
    if opts.portrait ~= false then Skin:HidePortraits(frame) end

    -- 标题字串和关闭按钮的位置各家不同：新框架挂在 TitleContainer 里，老框架直接挂在框上，
    -- 还有一批（WorldMapFrame 这类）两者都在 BorderFrame 那一层。
    local border = frame.BorderFrame

    if not opts.noTitle then
        local title = (frame.TitleContainer and frame.TitleContainer.TitleText)
            or frame.TitleText or frame.Title
            or (border and (border.TitleText or border.Title))
        if title then
            Skin:Font(title, opts.titleSize or 12, "pixel", nil, "edge")
            -- 标题下一条发丝线：**默认关**，逐窗口 opt-in（rule = true）。
            -- 为什么默认关：皮肤是在窗口隐藏时跑的，线的位置要等它第一次显示才算得出来
            -- （Widget:HeaderRule 内部用 ShowWatch 补），没在实机上确认过位置的窗口先别开，
            -- 见 docs/DESIGN-LANGUAGE.md §5.2 与 §8 的验法。
            if opts.rule then
                ns.Widget:HeaderRule(frame, title, {
                    pad = opts.rulePad or 8,
                    gap = opts.ruleGap or 3,
                    -- ruleTop 必须往下传：它是"标题矩形比字形小"那类窗口的唯一正确锚法，
                    -- 上一版漏了这一句，TimeManager 的线就一直穿过"时钟"两个字。
                    ruleTop = opts.ruleTop,
                    rulePad = opts.rulePad,
                })
            end
        end
    end

    if not opts.noClose then
        local close = frame.CloseButton or (border and border.CloseButton)
        if not close and type(frame.GetName) == "function" then
            local name = frame:GetName()
            if name then close = _G[name .. "CloseButton"] end
        end
        -- 名字三路全空时按 RedButton-Exit atlas 签名认一次（12.x 一批窗口的关闭按钮是匿名
        -- Button，LootFrame 实测如此；见 Skin:FindAnonClose）。
        if not close then close = Skin:FindAnonClose(frame) end
        if close then Skin:CloseButton(close) end
    end

    -- 右上角的"最大化 / 最小化"斜箭头。宿主位置不统一：`CommunitiesFrame` 挂在窗口本身，
    -- `WorldMapFrame` 挂在 `BorderFrame` 上（§8.107 实测），**法术书的两颗直接挂在窗口下、没有容器字段**
    -- —— 所以容器字段走一遍之后再来一次浅层扫（认 atlas 签名），并且登记"每次显示再扫一遍"：
    -- 那两颗是 LoD 包打开时才建出来的，登录时这一层还是空的（11-13 作者实测：法术书的 max/min 没处理）。
    local maxFrame = frame.MaximizeMinimizeFrame or (border and border.MaximizeMinimizeFrame)
    if maxFrame then Skin:MaximizeMinimizeFrame(maxFrame) end
    Skin:WatchMaximizeMinimize(frame)

    -- LoD 包的"显示那一拍补齐"：这些包（法术书 / 专业 / 日历 / 收藏 / 地下城手册…）里的
    -- 滚动条、肖像、方向钮**往往是窗口第一次显示时才建出来的** —— 登录时 `M:Dress` 跑到的是空壳，
    -- 于是作者看到的是"LoD 包的 close / maxmin / scroll 没处理"。关闭按钮本身由
    -- `Skin:CloseButton → FadeChildBoxArt` 的 ShowWatch 自补；这里把另外三样一起补上。
    if not Marked(frame, "winShowPass") then
        Mark(frame, "winShowPass", true)
        if Widget and Widget.ShowWatch then Widget:ShowWatch(frame, WindowShowPass) end
    end

    return frame
end

--- 点名控件的换肤器（`Dress(spec, { as = "tab" })` 用它分派）。
--- 点名控件的换肤器（`M:Dress(spec, { as = "tab" })` 用它分派）。
--- 只有 editbox / slider 需要认类型：名单里的名字在本客户端可能是别的控件
--- （拍卖行的 BrowseMinLevel 就既见过 EditBox 也见过 Slider），认错就跳过，不硬套。
local function IsAnyType(obj, ...)
    if type(obj.GetObjectType) ~= "function" then return false end
    local ok, got = pcall(obj.GetObjectType, obj)
    if not ok then return false end
    for i = 1, select("#", ...) do
        if got == select(i, ...) then return true end
    end
    return false
end

--- 对象叫什么（诊断用）：命名框给 GetName，匿名件给类型。绝不抛 —— 它就在报错路径上。
local function ObjectName(obj)
    if obj == nil then return "?" end
    if type(obj.GetName) == "function" then
        local ok, name = pcall(obj.GetName, obj)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    if type(obj.GetObjectType) == "function" then
        local ok, kind = pcall(obj.GetObjectType, obj)
        if ok and kind then return "<" .. tostring(kind) .. ">" end
    end
    return tostring(obj)
end

local DRESSERS = {
    tab      = function(obj, opts) Skin:Tab(obj, opts and opts.control) end,
    button   = function(obj, opts) M:Buttons({ obj }, opts and opts.control) end,
    scroll   = function(obj) Skin:ScrollFrame(obj) end,
    slider   = function(obj) if IsAnyType(obj, "Slider") then Skin:Slider(obj) end end,
    dropdown = function(obj, opts) Skin:Dropdown(obj, opts and opts.control) end,
    editbox  = function(obj, opts) if IsAnyType(obj, "EditBox", "SearchBox") then Skin:EditBox(obj, opts and opts.control) end end,
    fade     = function(obj) Skin:Fade(obj) end,
}

--- 深扫一个框的直接子控件，并在它**可见期间**继续补扫。
--- 为什么不是"显示时补扫一次"：标签页 / 列表的行是在帧**已经显示着**的时候懒建出来的
--- （切标签、翻页、滚进视野），OnShow 那一刻它们还不存在。轮询按可见性计时，隐藏的框不跑。
--- 登记以帧去重：`M:Apply` 会被 QUEST_LOG_UPDATE / ADDON_LOADED / PLAYER_ENTERING_WORLD 反复触发，
--- 不去重就是每触发一次多塞一条轮询回调。
--- forbidden 对象的身份描述：类型 + 父链两级，**全部 pcall**（对这种对象连 `GetName`
--- 都可能抛）。为什么值得多这一句：以前这行只印"无名框"，读的人分不清两种完全不同的情况
--- ——`Widget:Readable` 把"没有 IsVisible 方法"也算 forbidden，所以"被引擎接管的安全框"和
--- "我们其实递进来一个非框体对象"长成同一条红字外的普通警告，处置方式却不一样。
local function UnreadableDesc(frame)
    local kind = select(2, pcall(function() return frame:GetObjectType() end)) or "?"
    if type(frame.IsVisible) ~= "function" then kind = kind .. "(无 IsVisible 方法)" end
    local parents = {}
    local node = frame
    for _ = 1, 2 do
        local ok, parent = pcall(function() return node:GetParent() end)
        if not ok or not parent then break end
        local okName, name = pcall(function() return parent:GetName() end)
        parents[#parents + 1] = (okName and type(name) == "string" and name ~= "") and name or "?"
        node = parent
    end
    return ("%s · 父链 %s"):format(kind, #parents > 0 and table.concat(parents, " ← ") or "读不出")
end

function M:SweepDeep(frame, controlOpts, withInfo, rowDepth)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    -- 读不出可见性 = forbidden 对象（被引擎接管的安全框那一类）。给它挂常驻轮询没有任何意义：
    -- 驱动每拍都只能把它暂停掉，5 秒复检一次、永远检不回来，账本里多一条查不下去的"无名框"。
    -- 直接放手：这个框保持暴雪原样，等下一次 Apply 它若能读了再补。
    if not Widget:Readable(frame) then
        local who = ("%s｜%s"):format(Widget:FrameLabel(frame), UnreadableDesc(frame))
        -- 带上"是哪个面板把它交进来的"（`Skin.scope` 在 M:Panel 的 Apply 期间就是那档的名字，
        -- 和 Skin:Need 账本同一个来源）：只有对象身份的话，知道"有个 forbidden 框"也无处下手。
        who = who .. ("｜来源档 %s"):format(tostring(Skin.scope or "-"))
        Skin:WarnOnce("sweepSkip:" .. who,
            ("%s 读不出来（forbidden 对象），跳过子控件补扫，不挂轮询。"):format(who))
        return
    end
    -- 轮询里的抛错不在任何 Apply 的 pcall 保护下，而且每秒一次 —— 自己吞，并借
    -- Skin:WarnOnce 报名字（受限框读 GetChildren 就会被拒）。
    local sweep = function()
        local ok, err = pcall(function()
            M:SkinButtonsIn(frame, controlOpts, rowDepth)
            M:SkinScrollsIn(frame)
            M:SkinSlidersIn(frame)
            M:IconWidgetsIn(frame, nil, withInfo)
        end)
        if not ok then
            -- 名字走 Widget 那本账：这个框变 forbidden 之后 GetName 自己也会抛。
            local label = Widget:FrameLabel(frame)
            Skin:WarnOnce("sweep:" .. label,
                ("补扫 %s 的子控件失败: %s"):format(label, tostring(err)))
        end
    end
    sweep()
    local fd = GetFFD(frame)
    if fd.deepSweep then return end
    fd.deepSweep = true
    Widget:PollWatch(frame, sweep)

    M:SweepTemplates(frame, controlOpts)
end

--- 模板层补扫：只处理**静态**控件（金币 / 输入框 / 1.60 的 ColoredProgressBar），
--- 不碰按钮 —— 所以可以安全地加到每一个面板上，而不用把 `deep`（会重铺每个按钮）也打开。
---
--- 2 秒一次而不是 0.2 秒：这几类控件不会每帧变，没必要占热路径。
--- 回调必须是稳定引用（AGENTS：在 Apply 里现造闭包会每触发一次多挂一条轮询）。
function M:SweepTemplates(frame, controlOpts)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    local fd = GetFFD(frame)
    if fd.extrasSweep then return end
    if not Widget:Readable(frame) then return end
    fd.extrasSweep = true

    local extras = function()
        if not M.active then return end
        local ok, err = pcall(Skin.ExtrasIn, Skin, frame, controlOpts)
        if not ok then
            Skin:WarnOnce("extras:" .. Widget:FrameLabel(frame),
                ("模板补扫 %s 失败: %s"):format(Widget:FrameLabel(frame), tostring(err)))
        end
    end
    extras()
    Widget:PollWatch(frame, extras, 2)
end

--- 本仓唯一的"美化一个对象"入口：确认对象 → 剥暴雪原美术 → 挂我们的底衬 →
--- 窗口件（标题 / 关闭）→ 子控件深扫 → 懒建内容在显示时补扫。
--- 以前这一段在每个皮肤文件里手抄一遍，而且**顺序各写各的**：有的先挂底衬再 Strip
--- （我们的底衬被自己剥掉），有的忘了补扫（懒建的 ScrollBox 把手永远是暴雪的 atlas）。
--- 新皮肤一律走这里，别再复制那五行。
-- @param spec  对象、对象名（可点路径，每个都过 `Skin:Need` 记账）、或它们的列表
-- @param opts  { window=true 走窗口装饰, panel={底衬参数}, strip={剥的参数}, noStrip,
--               deep=true 扫直接子控件并在可见期间补扫, lazy=false 关掉补扫,
--               templates=false 关掉模板层补扫（金币/输入框/ColoredProgressBar，默认开）,
--               control={传给单个控件的参数}, as="tab|button|scroll|slider|dropdown|editbox|fade",
--               tabs / buttons / scrolls = { 点名的控件 } }
--               （window 档还吃 titleSize / noTitle / noClose / inset=true|{opts} 补正文凹槽那一档底色；
--               wells={ 后缀=true|{opts} } 给次级内容区吃同一套凹槽语言（多内容窗口）；
--               icons=false 关掉图标铺平裁切（**默认开**：.icon 指纹按钮压圆角遮罩 / 原生
--               槽框 + 8% 裁切 + 1px 方边，与背包 / 动作条同语言；deep 轮询里追新格子）；
--               noPanel 只剥原美术、不挂底衬）
function M:Dress(spec, opts)
    opts = opts or {}
    local list = Skin:AsList(spec)

    -- **非框体条目在门口就挡掉**。名单里会有"命中但不是框体"的东西（Mixin 表 / 函数 ——
    -- `TRADE_MONEY_FRAMES` 里的 `TradePlayerInputMoneyFrame` 就是），它们带着共享的方法名，
    -- 能一层层过掉 `type(x.GetChildren)=="function"` 这类判断，然后在**每一个**真正的方法调用上
    -- 抛 `calling 'X' on bad self (Attempt to access forbidden object …)`。11-04 实机那行
    -- 「无名框｜…Skins.lua:286…｜来源档 trade」就是这么长出来的：不是有个神秘禁框，
    -- 是我们把一张表当成了框体递进去。
    -- `Skin:IsScriptObject` 是唯一靠得住的前置（它 pcall `GetObjectType`，真取不到的也一并挡掉，
    -- 那种东西本来一个美化都做不了）。身份留在 Need 台账里（`/mui skins diagnose bad` 能看到
    -- `notObject:mixin 表`），这里只汇总成一行，不再逐次抛。
    -- `AsList` 会把名字解析成对象、名字本身就丢了；跳过时若只有数量，明天分不清
    -- "这 48 个是本来就不该进来的 Mixin 表"还是"我误伤了真框体"。所以这里自己解一遍，
    -- 把 (原始名 → 解析结果) 成对拿着。
    local raw = {}
    if type(spec) == "string" then
        raw[1] = spec
    elseif type(spec) == "table" and spec[1] ~= nil then
        for i = 1, #spec do raw[i] = spec[i] end
    else
        raw[1] = spec
    end

    local real, skipped = {}, {}
    for i = 1, #raw do
        local item = raw[i]
        local obj = (type(item) == "string") and Skin:Need(item) or item
        if obj ~= nil and Skin:IsScriptObject(obj) then
            real[#real + 1] = obj
        elseif obj ~= nil then
            skipped[#skipped + 1] = (type(item) == "string") and item or "?"
        end
    end
    if #skipped > 0 then
        table.sort(skipped)
        -- 这一行原来写成"以前它们每个方法调用都静默抛，一个像素也没涂上"—— 那是**说过头了**：
        -- 这一批里 `InspectFrame` / `CollectionsJournal` / `AchievementFrame` / `EncounterJournal`
        -- / `PlayerSpellsFrame` / `ClassTrainerFrame` / `CalendarFrame` / `ProfessionsFrame` 在
        -- 1.60 的 FrameXML 里都是**声明过的窗**，此刻拿到的是 Mixin 表 ⇒ 更可能是"窗还没被造出来，
        -- 这个名字现在指向 mixin 表"（LoD 时序），不是名字写错。真判定要靠开窗后复查。
        Skin:WarnOnce("dressDrop:" .. tostring(Skin.scope or "-"),
            ("档「%s」此刻跳过 %d 个非框体条目：%s")
                :format(tostring(Skin.scope or "-"), #skipped, table.concat(skipped, ", ")))
        Skin:WarnOnce("dressDropHint",
            "非框体有两种：① 窗还没出生（开了那个窗再跑 /mui skins diagnose，变成「存在」就是时序）"
                .. "② 这客户端真没这名字（一直「不存在」才要改名，用 /mui compat find <片段> 扫真名）")
    end
    list = real

    -- **一个控件炸了不能带走整面板**。2026-10-30 实机（12.1.5）：45 个窗口里 11 个整批红字，
    -- 原因只是名单里某个老窗口名在这版客户端已经变成一张表 —— 它被当成 parent 交给 CreateFrame，
    -- 抛 `Usage: CreateFrame(...)`，于是那个窗口一点没美化。逐对象 pcall + 一次性报名字，
    -- 剩下的控件照常涂。
    local function dressOne(frame, what, fn)
        local ok, err = pcall(fn)
        if not ok then
            local name = ObjectName(frame)
            Skin:WarnOnce("dress:" .. what .. ":" .. name,
                ("美化 %s 的「%s」这步失败: %s"):format(name, what, tostring(err)))
        end
    end

    if opts.as then
        local dress = DRESSERS[string.lower(opts.as)]
        if not dress then return end
        for i = 1, #list do
            if list[i] then
                local obj = list[i]
                dressOne(obj, "as=" .. tostring(opts.as), function() dress(obj, opts) end)
            end
        end
        return
    end

    for i = 1, #list do
        local frame = list[i]
        if frame then
            dressOne(frame, "body", function()
                if opts.window then
                    M:SkinWindow(frame, opts)
                else
                    if not opts.noStrip then Skin:Strip(frame, opts.strip) end
                    if not opts.noPanel then Skin:Panel(frame, opts.panel) end
                end

                if opts.deep then
                    if opts.lazy ~= false then
                        M:SweepDeep(frame, opts.control, opts.slotInfo, opts.deepRows)
                    else
                        M:SkinButtonsIn(frame, opts.control)
                        M:SkinScrollsIn(frame)
                        M:SkinSlidersIn(frame)
                        M:IconWidgetsIn(frame, nil, opts.slotInfo)
                    end
                elseif opts.templates ~= false then
                    -- 模板层默认开（`templates = false` 可关）：只铺金币 / 输入框 /
                    -- ColoredProgressBar 这几类静态控件，**不碰按钮** —— 所以对每个面板
                    -- 都安全，不必像 `deep` 那样逐个确认。deep 里已经包含它，别重复登记。
                    M:SweepTemplates(frame, opts.control)
                end

                -- 物品图标铺平 + 裁切（**默认开**，`icons = false` 才关）：子树里带 .icon 指纹的
                -- 按钮压掉圆角遮罩 / 原生槽框，图标 8% 裁切 + 品质色方边（素底兜底）——
                -- 与背包 / 动作条同一语言。与 deep 互补——deep 的按钮扫**跳过**物品按钮，
                -- 这条只管它们；deep+lazy 的窗口由 SweepDeep 的轮询补扫追新格子，
                -- 非 lazy 的窗口建格时机覆盖不了的（如运行期才建的列表）单独点名 `icons = true` 再补一遍。
                if opts.icons ~= false then
                    -- 登记"可见期补扫"：LoD 包的格子是开窗之后才建出来 / 才排版的，
                    -- 登录这一趟扫到的是空壳。fd 记下本档的 slotInfo，补扫时原样透传。
                    local fd = GetFFD(frame)
                    fd.iconPass = true
                    fd.iconInfo = opts.slotInfo
                    M:IconWidgetsIn(frame, nil, opts.slotInfo)
                    if Widget and Widget.PollWatch and Widget:Readable(frame) then
                        Widget:PollWatch(frame, IconPass, 1)
                    end
                end
            end)
        end
    end

    -- 深扫够不到的（不在直接子层）再点名补一遍。
    if opts.tabs then M:Tabs(opts.tabs, opts.control) end
    if opts.buttons then M:Buttons(opts.buttons, opts.control) end
    if opts.scrolls then M:Scrolls(opts.scrolls) end
end

--- Run `fn` over a list of named controls; each may be a string (resolved and counted by
--- `Skin:Need`) or an object, and missing ones are skipped.
function M:Controls(list, fn)
    if not list then return end
    for i = 1, #list do
        local item = list[i]
        local object = type(item) == "string" and Skin:Need(item) or item
        if object then pcall(fn, object) end
    end
end

--- Restyle a list of buttons (check boxes get the check-button skin, with our own checkmark art, instead of the text-button plate).
function M:Buttons(list, opts)
    self:Controls(list, function(button)
        local kind = type(button.GetObjectType) == "function" and button:GetObjectType()
        -- RadioButton is a CheckButton subclass, so without this branch every radio button in the
        -- skinned windows falls into Skin:CheckButton and gets a CHECK glyph.  monet_radio is drawn
        -- and registered for exactly this and had no call site until now.
        if kind == "RadioButton" then
            Skin:RadioButton(button, opts)
        elseif kind == "CheckButton" then
            Skin:CheckButton(button, opts)
        elseif not kind or kind == "Button" then
            Skin:Button(button, opts)
        end
    end)
end

--- Restyle a list of tabs.
function M:Tabs(list, opts)
    self:Controls(list, function(tab)
        Skin:Tab(tab, opts)
    end)
end

--- Restyle a list of scroll frames (and their scroll bars).
function M:Scrolls(list)
    self:Controls(list, function(scroll)
        Skin:ScrollFrame(scroll)
    end)
end

--- Item buttons (the ones carrying an icon -- reward / slot icons we must not fade) are skipped.
--- 实现已下沉到 `Utils/SkinTemplates.lua`（模板层也要用同一份判断）；这里保留同名局部，
--- 调用点一个字都不用改。
local LooksLikeItemButton = function(button) return Skin:LooksLikeItemButton(button) end

--- Restyle every direct child Button of a frame, skipping item buttons.
function M:SkinButtonsIn(frame, opts, depth)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    -- GetChildren 本身也可能撞 forbidden object（IconWidgetsIn 同款判例），裹住。
    local okKids, children = pcall(function() return { frame:GetChildren() } end)
    if not okKids or type(children) ~= "table" then return end
    -- `depth` 只给"列表行藏在 ScrollBox 好几层下面"的窗口用（11-05 实测：社交窗的行是
    -- `Button:匿名 <- Frame <- Frame <- Frame <- SocialUIFrame`，四深，直接子件档永远扫不到）。
    -- 默认仍然 1 层：递归深度是轮询成本的主要来源，不给所有窗口默认打开。
    local maxDepth = tonumber(depth) or 1
    local function walk(node, d)
        local kids
        if node == frame then
            kids = children
        else
            local ok, c = pcall(function() return { node:GetChildren() } end)
            kids = ok and c or nil
        end
        if type(kids) ~= "table" then return end
        for i = 1, #kids do
            local child = kids[i]
            -- 受保护窗口的子控件在零售服上是 forbidden object：连 GetObjectType 都可能抛
            -- "Attempt to access forbidden object from code tainted by an AddOn"，所以整段都走 pcall。
            local okKind, kind = pcall(child.GetObjectType, child)
            if okKind then
                -- 类型判断走 IsObjectType：`EventButton` 的 GetObjectType 回的是最派生名，
                -- 精确比较会整批漏掉（#44/#45 同一族，别再留第三处）。
                local isButton = false
                if child.IsObjectType then
                    local okB, v = pcall(child.IsObjectType, child, "Button")
                    isButton = (okB and v) or false
                else
                    isButton = (kind == "Button")
                end
                if kind == "RadioButton" then
                    pcall(Skin.RadioButton, Skin, child, opts)
                elseif kind == "CheckButton" then
                    pcall(Skin.CheckButton, Skin, child, opts)
                elseif isButton then
                    local okItem, isItem = pcall(LooksLikeItemButton, child)
                    if not okItem or not isItem then
                        pcall(Skin.Button, Skin, child, opts)
                    end
                end
                if d < maxDepth then walk(child, d + 1) end
            end
        end
    end
    walk(frame, 1)
end

--- Flatten + square-crop every item-icon button in a frame's subtree.  This is Dress's
--- **default pass**（`icons = false` 才关）：物品按钮是按钮扫**故意跳过**的那批
--- （`Skin:LooksLikeItemButton` 指纹，`.icon` / `.Icon` / ... 字段），这条是它们的补集——
--- 压掉圆角 IconMask 与原生 NormalTexture 槽框、图标 8% 裁切 + 品质色 1px 方边
--- （灰/白品质与解析不出品质的按钮保持素边），与背包 / 动作条完全同一套语言。
--- **认字段不认名字**：12.x 的物品格大量匿名（商人物品格 / 交易双方物品格 / 附魔格都是
--- 「容器 frame > ItemButton」的形状），按名字的名单永远追不上，按指纹一遍全收。
--- 裁剪参数进 `Skin:CropIcon` 的轮询账本：商人翻页 / 交易换物品重设贴图后，每 0.5s
--- 重压一遍 texcoord，不会退回竖缝（12.x 秘密纹素那条判例）。
--- 已处理的按钮走旁表标记（iconFlat）跳过：deep 轮询补扫反复进来时不再做功，
--- 也不会跟账本抢 texcoord（FlattenSlotArt 会把 texcoord 重置回 0..1，重复调用就是拉锯）。
--- 模板计数（SetItemButtonCount 写的 .count）抬到 OVERLAY 8——图标在 OVERLAY 7，
--- 不抬会被整个盖住（Bags 案判例；Bags 自绘白字在 9，不受影响）。
--- @param withInfo 透传给 Skin:ItemQualityBorder：这些格子额外挂"等级数字 + 冷却遮罩"
---   （只有人物面板那类点名 `slotInfo = true` 的面板会开）。
function M:IconWidgetsIn(frame, depth, withInfo)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    depth = depth or 0
    if depth > 4 then return end
    -- GetChildren 也会撞 forbidden object（2026-11-02 实机红字判例：无名框枚举子层直接抛
    -- "bad argument #1 ... self:GetChildren()"）——不裹起来整棵子树连同 body 一起炸。
    local okKids, children = pcall(function() return { frame:GetChildren() } end)
    if not okKids or type(children) ~= "table" then return end
    for i = 1, #children do
        local child = children[i]
        -- forbidden 对象上连 GetObjectType 都会抛（见 SkinButtonsIn 同款注释），全程 pcall。
        local okKind, kind = pcall(child.GetObjectType, child)
        if okKind then
            if kind == "Button" then
                if not Marked(child, "iconFlat") then
                    -- `.itemButton / .ItemButton` 指纹：真正的格子按钮挂在字段上（容器框包一格）。
                    local target = child
                    for _, key in ipairs({ "itemButton", "ItemButton" }) do
                        local okInner, inner = pcall(function() return child[key] end)
                        if okInner and type(inner) == "table" and inner.GetObjectType
                            and pcall(inner.GetObjectType, inner) == "Button" then
                            target = inner
                            break
                        end
                    end
                    -- **方形门**：铺平档只认近似方形的按钮——`.icon` 字段不是物品格专属，
                    -- 训练师的技能列表行（ClassTrainerFrameSkillStepButton 316x40、滚动行
                    -- 301x47）也带 `.icon`，误铺平会把图标 SetAllPoints 拉满整行（2026-11-02
                    -- 实机判例：训练师列表全拉花）。物品格语义 = 宽高比在 1.5 以内。
                    -- `sized` 与 `isSlot` 分开记：**尺寸还没落地**（LoD 包那拍 w/h = 0，或受限
                    -- 窗口读出来是机密值）不是"按设计跳过"，不能落标记 —— 落了就等于把这个格子
                    -- 永久排除，之后补扫进来也只读到 iconFlat=Y（与表头发丝线同一类缺陷）。
                    local okW, w = pcall(target.GetWidth, target)
                    local okH, h = pcall(target.GetHeight, target)
                    local sized = okW and okH and type(w) == "number" and type(h) == "number"
                        and Secrets.CanRead(w) and Secrets.CanRead(h) and w > 0 and h > 0
                    local isSlot = false
                    if sized then
                        local ratio = w / h
                        if ratio < 1 then ratio = 1 / ratio end
                        isSlot = ratio <= 1.5
                    end
                    -- **Atlas 门**：图标纹理是 atlas（锤子 / 钱袋 / 回购箭头这类 UI 图形，
                    -- 内容只占图集页一小块）就整钮跳过——FlattenSlotArt 的 SetTexCoord 0..1
                    -- 和 Skin:Icon 的 0.08 裁切都按"整幅文件贴图"假设来，对 atlas 是整页
                    -- 拉伸（2026-11-02 实机判例：商人修理 / 出售 / 回购三钮比例崩）。
                    -- 物品格图标是文件贴图（SetTexture fileID，GetAtlas 为 nil），不受影响。
                    local hasAtlas = false
                    for _, key in ipairs({ "icon", "Icon", "iconTexture", "IconTexture" }) do
                        local okIcon, tex = pcall(function() return target[key] end)
                        if okIcon and type(tex) == "table" and type(tex.GetAtlas) == "function" then
                            local okA, atlas = pcall(tex.GetAtlas, tex)
                            if okA and type(atlas) == "string" then
                                hasAtlas = true
                                break
                            end
                        end
                    end
                    -- **标记落在门之后**：只有"这一趟真做了事"或"按设计确定跳过"才落 iconFlat。
                    -- 尺寸没落地的那一档不落标记，留给显示期补扫（IconPass）下一趟再来。
                    if sized and isSlot and not hasAtlas then
                    Mark(child, "iconFlat", true)
                    pcall(Skin.FlattenSlotArt, Skin, target)
                    for _, key in ipairs({ "icon", "Icon", "iconTexture", "IconTexture" }) do
                        local okIcon, tex = pcall(function() return target[key] end)
                        local okTex, texKind
                        if okIcon and type(tex) == "table" then
                            okTex, texKind = pcall(tex.GetObjectType, tex)
                        end
                        if okTex and texKind == "Texture" then
                            -- 只裁切；1px 边由 ItemQualityBorder 接管（品质色 / 素边兜底，
                            -- 翻页换物品后轮询重读，Bags 同款语言）。
                            pcall(Skin.Icon, Skin, tex)
                        end
                    end
                    pcall(Skin.ItemQualityBorder, Skin, target, withInfo)
                    -- 模板计数抬层（Bags 案判例：图标 OVERLAY 7 会盖住模板 count）。
                    -- 注意 `.count` 不一定是字体串——商人窗实测是**数字**（本格数量），
                    -- 先验 type(table) 再索引方法，否则 "attempt to index a number" 炸 body。
                    local okCount, count = pcall(function() return target.count end)
                    if okCount and type(count) == "table" and type(count.SetDrawLayer) == "function" then
                        pcall(count.SetDrawLayer, count, "OVERLAY", 8)
                        pcall(count.ClearAllPoints, count)
                        pcall(count.SetPoint, count, "BOTTOMRIGHT", target, "BOTTOMRIGHT", -2, 2)
                    end
                    elseif sized then
                        -- 尺寸读出来了但不是物品格（非方形 / atlas 图标）：按设计跳过，
                        -- 落标记免得每趟重复读一遍宽高与 atlas。
                        Mark(child, "iconFlat", true)
                    end -- sized and isSlot and not hasAtlas
                end
            elseif kind == "Frame" then
                M:IconWidgetsIn(child, depth + 1, withInfo)
            end
        end
    end
end

--- Restyle every child ScrollFrame / ScrollBox scrollbar of a frame (recurses a little,
--- because ScrollBox scrollbars are anonymous Frames nested inside the list).
function M:SkinScrollsIn(frame, depth)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    depth = depth or 0
    -- GetChildren 本身也可能撞 forbidden object（本函数带递归，IconWidgetsIn 同款判例），裹住。
    local okKids, children = pcall(function() return { frame:GetChildren() } end)
    if not okKids or type(children) ~= "table" then return end
    for i = 1, #children do
        local child = children[i]
        -- forbidden object 上连 GetObjectType 都会抛（见 SkinButtonsIn 的注释），一律 pcall。
        local okKind, kind = pcall(child.GetObjectType, child)
        if okKind then
            if kind == "ScrollFrame" then
                pcall(Skin.ScrollFrame, Skin, child)
            elseif kind == "Button" then
                -- ScrollBox 的上下箭头（atlas minimal-scrollbar-arrow-*）。
                pcall(Skin.ScrollArrowButton, Skin, child)
            elseif child.Thumb then
                -- ScrollBox 的滚动条：无名 Frame + .Thumb Button（没有具名的 ScrollUpButton）。
                pcall(Skin.ScrollThumb, Skin, child.Thumb)
            end
        end
        if depth < 3 then
            pcall(M.SkinScrollsIn, M, child, depth + 1)
        end
    end
end

--- Restyle every direct child Slider of a frame.
function M:SkinSlidersIn(frame)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    local okKids, children = pcall(function() return { frame:GetChildren() } end)
    if not okKids or type(children) ~= "table" then return end
    for i = 1, #children do
        local child = children[i]
        local okKind, kind = pcall(child.GetObjectType, child)
        if okKind and kind == "Slider" then
            pcall(Skin.Slider, Skin, child)
        end
    end
end

--- 让 `fn` 在某个暴雪框从隐藏变显示的那一刻跑一次（懒建内容的皮肤靠这个补）。
--- **不再 HookScript("OnShow")**：那是往暴雪框体的脚本槽里写我们的函数（污染源）。
--- 改用 Widget:ShowWatch 轮询"从隐藏变显示"这一个瞬间。
--- 同一帧可以挂多个**不同**的回调（以前用标记位判重，第二个调用点会被静默丢掉，实机表现是
--- "皮肤时有时无"，取决于哪个 Apply 先跑）。因此**回调必须是稳定引用**：模块级函数，
--- 或 `SweepDeep` 那样自己带去重的一次性登记。在 Apply 里现造的闭包每次都是新函数，
--- 每触发一次 Apply 就多挂一条 —— 需要补扫子控件时用 M:SweepDeep，别在这里造闭包。
function M:HookShow(frame, fn)
    if not frame or type(fn) ~= "function" then return end
    local fd = GetFFD(frame)
    local list = fd.showHook
    if not list then
        list = {}
        fd.showHook = list
        ns.Widget:ShowWatch(frame, function()
            if not M.active then return end
            for i = 1, #list do pcall(list[i]) end
        end)
    end
    for i = 1, #list do
        if list[i] == fn then return end
    end
    list[#list + 1] = fn
end

--- Run `fn` on a WoW event, but only while the module is active.
function M:OnEvent(event, fn)
    EventBus:Register(event, function()
        if M.active then pcall(fn) end
    end)
end

-- Restyles Blizzard's shared font objects so static vanilla text matches the MonetUI pixel font.  Off by default: it touches every window at once, so it stays the player's explicit choice.
local FONT_OBJECTS = {
    "GameFontNormal", "GameFontNormalSmall", "GameFontNormalLarge", "GameFontNormalHuge",
    "GameFontHighlight", "GameFontHighlightSmall", "GameFontHighlightLarge",
    "GameFontDisable", "GameFontDisableSmall", "GameFontDisableLarge",
    "GameFontDarkGraySmall", "GameFontGreen", "GameFontGreenSmall",
    "GameFontRed", "GameFontRedSmall", "GameFontWhite", "GameFontWhiteSmall",
    "GameFontNormalMed1", "GameFontNormalMed2", "GameFontNormalMed3",
    "NumberFontNormal", "NumberFontNormalSmall", "NumberFontNormalLarge",
    "NumberFontNormalHuge", "NumberFont_Shadow_Small",
    -- 提示框用自己的字体对象（不是 GameFont*），不在这里列出来，全局字体开关就管不到物品 / 技能 / 角色
    -- 那几万行提示框文字 —— 它们会继续用暴雪的 FRIZQT__/ARHei，和界面其余部分不一样。
    "GameTooltipText", "GameTooltipTextSmall", "GameTooltipHeaderText",
    -- 聊天：正文和说话泡泡各用一个共享字体对象，原先一个都不在这个名单里，
    -- 于是"统一字体"号称管到所有暴雪窗口，聊天框和说话泡泡其实一直是暴雪的 FRIZQT__/ARHei。
    -- 两个名字都取本客户端实名证据：EnhanceQoLChatSocial/ChatIM/UI.lua:269（读 ChatFontNormal:GetFont()
    -- 拿聊天正文字体）、EnhanceQoL/EnhanceQoL_Camelot.lua:6 的 globals 行 + :3447（改 ChatBubbleFont）。
    -- 同机的插件真在 SetFont 这两个对象，说明它们在这版客户端上就是活的字体对象。
    "ChatFontNormal", "ChatBubbleFont",
}

function M:GetFontKey()
    local key = self:Settings().font
    if key == "off" or key == nil then return nil end
    return key
end

function M:ApplyFont()
    local key = self:GetFontKey()
    if not key then return end

    -- 记账在"统一字体"这个作用域下：哪个字体对象在本客户端不存在，`/mui skins diagnose` 直接读账本。
    Skin.With("统一字体", function()
        for i = 1, #FONT_OBJECTS do
            local fs = Skin:Need(FONT_OBJECTS[i])
            if fs and type(fs.SetFont) == "function" then
                if not Marked(fs, "globalFont") then
                    Mark(fs, "globalFont", true)
                    local oldPath, oldSize, oldFlags = fs:GetFont()
                    if oldPath then
                        Skin:Record(function()
                            if fs.SetFont then fs:SetFont(oldPath, oldSize, oldFlags) end
                            Mark(fs, "globalFont", nil)
                        end)
                    end
                end
                local _, size = fs:GetFont()
                -- Keep Blizzard's own size (their layouts are built around it); 字体与标志按字号
                -- 换挡（<12px 点阵苹方硬边，≥12px 文楷抗锯齿），见 Media 双轨漏斗。
                size = size or 12
                pcall(fs.SetFont, fs, Media:FontFor(key, size), size, Media:EffectiveFlags(Media.fontFlags, size))
            end
        end
    end)
end

local hooksInstalled = false

local function InstallHooks()
    if hooksInstalled then return end
    hooksInstalled = true

    -- Blizzard windows are load-on-demand: a pack that declared its addon is re-applied the moment that exact addon arrives; packs that declared nothing get ONE debounced pass per burst, so the login ADDON_LOADED burst collapses into a single re-skin.
    local loosePass = M:Debounce(function()
        for i = 1, #M.registry do
            local entry = M.registry[i]
            if not entry.addons then M:Apply(entry) end
        end
    end)

    -- LoD 包里的**匿名美术**（✕ / ↗↙ / 滚动条细把手）只有等这个包加载之后才存在于世界里：
    -- 登录那几趟全局扫描（+1/+3/+6/+10 秒）全都扫不到它们，于是一批 LoD 窗口的按钮一直是原样。
    -- ⇒ 每有 Blizzard UI 包加载就推迟 1 秒补扫一趟。`Async` 切片 + 重触发先取消，连扫几趟不会叠着跑；
    -- 1 秒的窗口把"同一个包拆成好几次 ADDON_LOADED"的突发合并成一趟（`C_Timer.After` 只排一条）。
    local rescanPending = false
    local function ArtRescan()
        if rescanPending then return end
        rescanPending = true
        C_Timer.After(1, function()
            rescanPending = false
            if M.active and Skin.ScanScrollArrows then Skin:ScanScrollArrows() end
        end)
    end

    EventBus:Register("ADDON_LOADED", function(_, addonName)
        if not M.active then return end
        if type(addonName) == "string" then
            for i = 1, #M.registry do
                local entry = M.registry[i]
                if entry.addons and entry.addons[addonName] then
                    M:Apply(entry)
                end
            end
            -- Blizzard UI 包（`Blizzard_*`）：新窗口里的匿名按钮 / 滚动条要重扫才会被认出来。
            if addonName:sub(1, 9) == "Blizzard_" then ArtRescan() end
        end
        loosePass()
    end)

    -- Edit Mode / loading screens can rebuild chrome, so re-apply.
    -- Debounced for the same reason as the ADDON_LOADED burst above: PLAYER_ENTERING_WORLD fires on
    -- every loading screen and relog, and a full ApplyAll walks every panel's Strip.
    EventBus:Register("PLAYER_ENTERING_WORLD", M:Debounce(function()
        if not M.active then return end
        M:ApplyAll()
    end))

    -- The UI scale slider is the one input that invalidates the pixel model itself.  Media:Mult() reads
    -- the uiScale CVar, and every border edgeSize / inset and every SnapUnit length is derived from it,
    -- so without this the borders keep their old physical width while new widgets get the new one --
    -- two different border widths on screen at once.  This is the only place that reacts to it.
    -- Login catch-up.  The client frequently applies the UI scale AFTER the first frames are built,
    -- and our UI_SCALE_CHANGED listener may not be installed yet when that happens -- so the event
    -- never reaches us and the borders keep a grid computed from a stale CVar.  AishCore's PixelSnap
    -- documents the same race and re-snaps at 1s and 4s; these two passes close that window.
    -- Guarded to run once per session, not once per zone.
    local loginRescaled = false
    EventBus:Register("PLAYER_ENTERING_WORLD", function()
        if loginRescaled then return end
        loginRescaled = true
        if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return end
        local function pass()
            if M.active then Widget:RefreshThemes(true) end
        end
        C_Timer.After(1, pass)
        C_Timer.After(4, pass)
        -- 滚动条细把手 / 上下箭头：ScrollBox 懒创建，多扫几遍兜底（只扫存在的帧）。
        local function scanScrolls()
            if M.active and Skin.ScanScrollArrows then Skin:ScanScrollArrows() end
        end
        C_Timer.After(1, scanScrolls)
        C_Timer.After(3, scanScrolls)
        C_Timer.After(6, scanScrolls)
        C_Timer.After(10, scanScrolls)
    end)

    EventBus:Register("UI_SCALE_CHANGED", M:Debounce(function()
        if not M.active then return end
        Widget:RefreshThemes(true)   -- re-derive edgeSize / insets, then re-tint
        M:ApplyAll()                  -- skin-layer plates are Widget:Theme'd, so this picks them up too
    end))
end

function M:Initialize()
    self.active = true
    InstallHooks()

    Skin:BeginRecord()
    self:ApplyFont()
    self:ApplyAll()

    ns:DevPrint("界面美化已启用（" .. tostring(#self.registry) .. " 个窗口）。")
end

function M:SetEnabled(enabled)
    enabled = enabled and true or false

    if enabled then
        if self.active then return end
        self.active = true
        Skin:BeginRecord()
        self:ApplyFont()
        Skin:ShowAdded()
        self:ApplyAll()
    else
        self.active = false
        Skin:Rollback()
        Skin:HideAdded()
    end
end

-- Frame names are our own recall of the retail UI (never lifted from a reference addon, which may target another build); a guarded lookup fails silently, so `/mui skins diagnose` turns that silence into an exact list.
-- 优先读 `Skin:Need` 的账本 —— 那是**这个客户端上真实发生过的查找**。只有从没跑过的面板
-- （关着 / LoD 未到 / 选项没打开）才退回声明名单核一遍，两种情况分开报，别混成一个数。
-- 退回核对也走 `Skin:Need`：全仓只有这一个"确认对象存在"的入口，核过的名字同样进账。

--- 当场核对一份声明名单，返回（存在数, 缺失名列表）。
local function VerifyList(scope, names)
    local missing, found = {}, 0
    Skin.With(scope, function()
        for i = 1, #names do
            if Skin:Need(names[i]) then
                found = found + 1
            else
                missing[#missing + 1] = names[i]
            end
        end
    end)
    return found, missing
end

local function PrintVerified(key, names, applied)
    local found, missing = VerifyList(key, names)
    if #missing == 0 then
        local tone = applied and "88ff88" or "808080"
        ns:Print(("|c%s%s|r [%s] %d/%d 对象存在"):format(tone, applied and "✓" or "○", key, found, #names))
    else
        ns:Print(("|cffff6b6b✗|r [%s] %d/%d 存在，缺少: %s"):format(
            key, found, #names, table.concat(missing, ", ")))
    end
    return found, #missing
end

function M:Diagnose(onlyBad)
    if onlyBad then
        ns:Print("命中但不是框体的对象（会让 CreateFrame / GetRegions 抛的那一类）：")
        return Skin:ReportBad()
    end
    ns:Print("界面美化对象自检（按实际发生的查找）：")

    local totalFound, totalMissing = Skin:Report()

    for _, entry in ipairs(self.registry) do
        local names = entry.frames
        if names and #names > 0 and not Skin:HasScope(entry.key) then
            local found, missing = PrintVerified(entry.key, names, false)
            totalFound = totalFound + found
            totalMissing = totalMissing + missing
        end
    end

    -- 共享字体对象不属于任何窗口；全局字体开关没打开时也没有查找发生过，这里补核一遍。
    if not Skin:HasScope("统一字体") then
        local found, missing = PrintVerified("统一字体", FONT_OBJECTS, false)
        totalFound = totalFound + found
        totalMissing = totalMissing + missing
    end

    ns:Print(("合计 %d 存在 / %d 缺失。"):format(totalFound, totalMissing))
    if totalMissing > 0 then
        -- 这句以前写成"缺失的那些在本客户端用了别的名字：改字符串即可"—— 那是**错的归因**：
        -- 登录当拍的缺失里，很大一块是 LoD 包还没加载 / 那个窗还没被造出来，名字本身没问题
        -- （11-04 实机判例："225 存在 / 227 缺失"，离线对撞 1.60 FrameXML 后有名字可对上的过半）。
        -- 所以口径必须是"先分清两种原因，再决定改不改名"，并给出可执行的下一步。
        ns:Print("缺失 ≠ 缺陷：分两种 —— ① 这客户端没这名字（要改名/摘掉）② 属 LoD 包或窗还没出生（开了那个窗再跑一次就会变成存在）。")
        ns:Print("要改名的那批，用「/mui compat find <片段>」在真客户端里扫真名，别照参考插件或记忆写。")
    end
end

--- `/mui skins templates [片段]`（2026-11-03）：模板库账本。
--- 不带参数：模板总数 / 有 skinAs 的条数 / Camelot 覆盖数 / 类型与 skinAs 分布；
--- 带片段：按模板名或 skinAs 子串匹配，回答"这个控件会被认成什么"。
--- 只读 `ns.TemplateDB`，不碰任何框，也不改识别结果。
function M:PrintTemplates(raw)
    local db = ns.TemplateDB
    if type(db) ~= "table" then
        ns:Print("模板数据库未加载：Templates.xml 必须排在 Skins.xml 之前（见 MonetUI.toc）。")
        return
    end

    local filter = string.match(raw or "", "^%s*templates?%s+(%S+)%s*$")
    if filter then
        filter = string.lower(filter)
        local names = {}
        for name, entry in pairs(db) do
            local skinAs = type(entry.skinAs) == "string" and entry.skinAs or ""
            if string.find(string.lower(name), filter, 1, true)
                or string.find(string.lower(skinAs), filter, 1, true) then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        ns:Print(("模板库里匹配 \"%s\" 的：|cffffd100%d|r 条"):format(filter, #names))
        for i = 1, math.min(#names, 15) do
            local entry = db[names[i]]
            ns:Print(("  %s  →  %s%s"):format(
                names[i],
                tostring(entry.skinAs or "-"),
                entry.camelotOnly and "  (Camelot 覆盖)" or ""))
        end
        if #names > 15 then
            ns:Print(("  …另有 %d 条（用更长的片段缩小范围）"):format(#names - 15))
        end
        return
    end

    local total, mapped, camelot, matchable = 0, 0, 0, 0
    local byType, bySkinAs = {}, {}
    for _, entry in pairs(db) do
        total = total + 1
        local t = entry.type or "?"
        byType[t] = (byType[t] or 0) + 1
        if entry.skinAs then
            mapped = mapped + 1
            bySkinAs[entry.skinAs] = (bySkinAs[entry.skinAs] or 0) + 1
        end
        if entry.camelotOnly then camelot = camelot + 1 end
        -- 只有带指纹的条目会被 LookupTemplate 真正匹配（MatchFingerprints 对无指纹的条目直接返回 false）。
        if entry.fingerprints then matchable = matchable + 1 end
    end

    --- 按数量降序、同数量按名字升序（结果稳定，不会每次刷新顺序不同）。
    local function ranked(map)
        local list = {}
        for k, n in pairs(map) do list[#list + 1] = { k = k, n = n } end
        table.sort(list, function(a, b)
            if a.n ~= b.n then return a.n > b.n end
            return a.k < b.k
        end)
        return list
    end

    ns:Print(("模板库（运行时）：|cffffd100%d|r 条，|cffffd100%d|r 条带指纹（能被 LookupTemplate 匹配），|cffffd100%d|r 条映射到 skinAs，Camelot 覆盖 |cffffd100%d|r 条")
        :format(total, matchable, mapped, camelot))
    if matchable < total then
        ns:Print(("  注：%d 条没有指纹 —— 只登记了 type/skinAs，识别时不会被命中（生成文件里无指纹的模板多以注释保留）。")
            :format(total - matchable))
    end

    local types = ranked(byType)
    ns:Print("类型分布：")
    for i = 1, math.min(#types, 8) do
        ns:Print(("  %-12s %d"):format(types[i].k, types[i].n))
    end

    local mappedList = ranked(bySkinAs)
    if #mappedList > 0 then
        ns:Print("skinAs 分布：")
        for i = 1, math.min(#mappedList, 8) do
            ns:Print(("  %-14s %d"):format(mappedList[i].k, mappedList[i].n))
        end
        if #mappedList > 8 then
            ns:Print(("  …另有 %d 种"):format(#mappedList - 8))
        end
    end

    ns:Print("用法：/mui skins templates <片段> 按模板名 / skinAs 查映射。")
end

--- `/mui Skins <sub>`.  Returns false when the sub-command is unknown, so the slash handler can fall back to printing the usage line.
function M:HandleCommand(rest)
    local raw = rest or ""
    local sub = string.lower(raw)
    if sub == "diagnose bad" or sub == "diag bad" or sub == "probe bad" then
        self:Diagnose(true)
        return true
    end
    if sub == "diagnose" or sub == "diag" or sub == "probe" then
        self:Diagnose()
        return true
    end
    -- 模板库账本（2026-11-03）：不带参数看统计，带片段按名字 / skinAs 查映射。
    if string.find(sub, "^templates?") then
        self:PrintTemplates(raw)
        return true
    end
    -- 窗口"底"有几层：参数是窗口名（可再跟一个名字片段做过滤），**帧名大小写敏感**，
    -- 所以从原始参数里取、不能过 string.lower
    if string.find(sub, "^layers") then
        local name, filter = string.match(raw, "^%s*layers%s+(%S+)%s*(%S*)%s*$")
        if not name then
            ns:Print("用法：/mui skins layers <窗口名> [名字片段]，例如 /mui skins layers QuestFrame Bg")
        else
            Skin:ProbeLayers(name, filter)
        end
        return true
    end
    -- 只读探针（2026-11-03，上线日验收用）：换皮覆盖面三档清点，实现在 DevTools，
    -- 这里只开一个入口，皮肤层本身一个字节都不写。
    if sub == "closes" or sub == "inset" or sub == "arrows" then
        local DevTools = ns.GetModule and ns:GetModule("DevTools")
        if DevTools and type(DevTools.SkinsProbe) == "function" then
            DevTools:SkinsProbe(sub)
            return true
        end
        ns:DevPrint("DevTools 探针模块没加载（检查 Modules/Tools/Tools.xml）。")
        return true
    end
    return false
end

ns:Register("Skins", M)
