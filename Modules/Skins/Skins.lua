-- Modules/Skins/Skins.lua
-- Blizzard panel beautification (界面美化) engine: panel files (Modules/Skins/*.lua) register windows through Skins:Panel(key, { apply = fn, ... }); the engine applies them at login / ADDON_LOADED / loading screen, records every mutation for rollback, and exposes the list to the config panel.
-- Skins only fade Blizzard art and add our own child frames: no SetScript / SetParent / SetShown / Hide on a Blizzard frame; hover feedback is polled (Widget:HoverWatch) -- never HookScript.

local ADDON_NAME, ns = ...

local Skin     = ns.Skin
local Media    = ns.Media
local EventBus = ns.EventBus
local Widget   = ns.Widget


-- 旁表标记：**绝不往暴雪的框体 / 贴图 / 字体串上写字段**。
-- 本客户端把“插件写过字段的对象”判成脏的（实机：issecurevariable 在 NamePlate1UnitFrame 上唯一为 false 的键就是我们的
-- 标记，随后暴雪自己的 OnUpdate 就报 secret value / anchor family），所以标记一律走
-- Core.lua 的 ns:Mark / ns:Marked（以对象为弱键的旁表）。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

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

--- The common window treatment: fade the frame's *own* chrome (not its children, so icons stay intact), hang a Monet backplate under it, restyle title and close button.
-- @param opts { layer, inset, panel = Widget:Theme opts, titleSize, noTitle = true, noClose = true }
function M:SkinWindow(frame, opts)
    if not frame then return nil end
    opts = opts or {}

    Skin:Strip(frame, opts.strip)
    Skin:Panel(frame, opts.panel)

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
        if close then Skin:CloseButton(close) end
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
    editbox  = function(obj) if IsAnyType(obj, "EditBox", "SearchBox") then Skin:EditBox(obj) end end,
    fade     = function(obj) Skin:Fade(obj) end,
}

--- 深扫一个框的直接子控件，并在它**可见期间**继续补扫。
--- 为什么不是"显示时补扫一次"：标签页 / 列表的行是在帧**已经显示着**的时候懒建出来的
--- （切标签、翻页、滚进视野），OnShow 那一刻它们还不存在。轮询按可见性计时，隐藏的框不跑。
--- 登记以帧去重：`M:Apply` 会被 QUEST_LOG_UPDATE / ADDON_LOADED / PLAYER_ENTERING_WORLD 反复触发，
--- 不去重就是每触发一次多塞一条轮询回调。
function M:SweepDeep(frame, controlOpts)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    -- 读不出可见性 = forbidden 对象（被引擎接管的安全框那一类）。给它挂常驻轮询没有任何意义：
    -- 驱动每拍都只能把它暂停掉，5 秒复检一次、永远检不回来，账本里多一条查不下去的"无名框"。
    -- 直接放手：这个框保持暴雪原样，等下一次 Apply 它若能读了再补。
    if not Widget:Readable(frame) then
        Skin:WarnOnce("sweepSkip:" .. Widget:FrameLabel(frame),
            ("%s 读不出来（forbidden 对象），跳过子控件补扫，不挂轮询。"):format(Widget:FrameLabel(frame)))
        return
    end
    -- 轮询里的抛错不在任何 Apply 的 pcall 保护下，而且每秒一次 —— 自己吞，并借
    -- Skin:WarnOnce 报名字（受限框读 GetChildren 就会被拒）。
    local sweep = function()
        local ok, err = pcall(function()
            M:SkinButtonsIn(frame, controlOpts)
            M:SkinScrollsIn(frame)
            M:SkinSlidersIn(frame)
        end)
        if not ok then
            -- 名字走 Widget 那本账：这个框变 forbidden 之后 GetName 自己也会抛。
            local label = Widget:FrameLabel(frame)
            Skin:WarnOnce("sweep:" .. label,
                ("补扫 %s 的子控件失败: %s"):format(label, tostring(err)))
        end
    end
    sweep()
    if Marked(frame, "deepSweep") then return end
    Mark(frame, "deepSweep", true)
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
    if Marked(frame, "extrasSweep") then return end
    if not Widget:Readable(frame) then return end
    Mark(frame, "extrasSweep", true)

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
--               （window 档还吃 titleSize / noTitle / noClose；noPanel 只剥原美术、不挂底衬）
function M:Dress(spec, opts)
    opts = opts or {}
    local list = Skin:AsList(spec)

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
                        M:SweepDeep(frame, opts.control)
                    else
                        M:SkinButtonsIn(frame, opts.control)
                        M:SkinScrollsIn(frame)
                        M:SkinSlidersIn(frame)
                    end
                elseif opts.templates ~= false then
                    -- 模板层默认开（`templates = false` 可关）：只铺金币 / 输入框 /
                    -- ColoredProgressBar 这几类静态控件，**不碰按钮** —— 所以对每个面板
                    -- 都安全，不必像 `deep` 那样逐个确认。deep 里已经包含它，别重复登记。
                    M:SweepTemplates(frame, opts.control)
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
function M:SkinButtonsIn(frame, opts)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    local children = { frame:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        -- 受保护窗口的子控件在零售服上是 forbidden object：连 GetObjectType 都可能抛
        -- "Attempt to access forbidden object from code tainted by an AddOn"，所以整段都走 pcall。
        local okKind, kind = pcall(child.GetObjectType, child)
        if okKind then
            if kind == "RadioButton" then
                pcall(Skin.RadioButton, Skin, child, opts)
            elseif kind == "CheckButton" then
                pcall(Skin.CheckButton, Skin, child, opts)
            elseif kind == "Button" then
                local okItem, isItem = pcall(LooksLikeItemButton, child)
                if not okItem or not isItem then
                    pcall(Skin.Button, Skin, child, opts)
                end
            end
        end
    end
end

--- Restyle every child ScrollFrame / ScrollBox scrollbar of a frame (recurses a little,
--- because ScrollBox scrollbars are anonymous Frames nested inside the list).
function M:SkinScrollsIn(frame, depth)
    if not frame or type(frame.GetChildren) ~= "function" then return end
    depth = depth or 0
    local children = { frame:GetChildren() }
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
    local children = { frame:GetChildren() }
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
    local list = Marked(frame, "showHook")
    if not list then
        list = {}
        Mark(frame, "showHook", list)
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

    EventBus:Register("ADDON_LOADED", function(_, addonName)
        if not M.active then return end
        if addonName then
            for i = 1, #M.registry do
                local entry = M.registry[i]
                if entry.addons and entry.addons[addonName] then
                    M:Apply(entry)
                end
            end
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

    ns:Print("界面美化已启用（" .. tostring(#self.registry) .. " 个窗口）。")
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
        ns:Print("缺失的那些在本客户端用了别的名字：改皮肤文件里的字符串即可，查找会自动跟着记账。")
    end
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
    return false
end

ns:Register("Skins", M)
