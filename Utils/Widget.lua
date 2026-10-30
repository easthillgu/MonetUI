-- Utils/Widget.lua
-- Widget factory: shared UI construction (the addon's private API).
-- Everything created here can be themed: Widget:Theme() registers the widget in a weak table and every registered widget is re-tinted when Core fires "MONETUI_THEME_CHANGED" -- the loose coupling the modules rely on.

local ADDON_NAME, ns = ...


-- 旁表标记（见 Core.lua 的 ns:Mark）：Widget 也会被套到**暴雪的**按钮上
-- （动作条 / 宠物栏的 ButtonMaterial），写字段会把它们标脏，之后暴雪自己的安全调用就被拒。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
local Color = ns.Color
local Media = ns.Media
local EventBus = ns.EventBus

-- ---------------------------------------------------------------------------
-- 轮询式 hover / 显隐观察（见 AGENTS.md 的「界面美化原则」）
--
-- **绝不在暴雪的框体上 HookScript**：HookScript 会往这个框体的脚本槽里写我们的函数，
-- 等于给框体打上"被插件写过"的标记；它自己的脚本（例如法术书图标的 OnIconEnter →
-- ClearOnBarHighlightMarks）之后就跑在"被 MonetUI 污染"的执行里，进而把
-- ON_BAR_HIGHLIGHT_MARKS 这种全局表写脏 —— 所有动作按钮的高亮/显隐更新随之被拒。
--
-- 这里改成轮询：鼠标位置用 MouseIsOver / GetMouseFocus 查，按键状态用轮询，
-- 不写任何字段、不铺遮挡层，因此也不会吃掉点击。

local Widget = {}

-- 主题参数常量：各模块以前各自复制一份（review 2026-10-24 第 6 条），现在单点定义。
-- bgAlpha **不**收进来：0.9 / 0.92 / 0.85 / 0.55 / 0.6 / 0.25 各处是按表面语义挑的
-- （面板 bg、施法条 bg、条底、按钮底），合并会悄悄改视觉。
Widget.BORDER   = 1   -- 1px Monet 发丝边（框 / 条 / 牌 / 按钮的内嵌边）
Widget.TEXT_GAP = 3   -- 文字行与条顶边之间的空隙

-- 弱键：自建框体被丢弃后条目跟着回收（以前是强引用，永不释放）。
local hoverWatch, hoverDriver, hoverAcc = setmetatable({}, { __mode = "k" }), nil, 0

--- 驱动循环遇到暂停中的框时用它替下监听表：状态照常推进，但一个回调都不跑。
local idleList = {}

--- 读一个框的可见性。本客户端里有**forbidden 对象**（被接管的安全框、战斗里的受保护框等）：
--- 对它们调 `IsVisible` 会抛 "Attempt to access forbidden object from code tainted by an AddOn"，
--- 而三个轮询驱动（hover 0.1s / show 0.2s / poll 0.2s）每拍都要读一次 —— 实机一个框就刷了 2087 条。
--- 第二个返回值 `readable` 为 false 时调用方这一拍**什么都不要做**：那些回调全是对这个框的写入，
--- 同样会被客户端拒，跑一次只是多一条拦截。每个框只警告一次，好让我们知道到底是谁。
local forbidWarned
local PAUSE_RETRY = 5
local function FrameLabel(frame)
    local name
    local Secrets = ns.Secrets
    local okName, n = pcall(function() return frame.GetName and frame:GetName() end)
    if okName and type(n) == "string" and not (Secrets and Secrets.IsSecret(n)) then name = n end
    if not name then
        local okP, parent = pcall(function() return frame.GetParent and frame:GetParent() end)
        if okP and parent and parent ~= frame then
            local okN, pn = pcall(function() return parent.GetName and parent:GetName() end)
            if okN and type(pn) == "string" and not (Secrets and Secrets.IsSecret(pn)) then
                name = pn .. " 的子框"
            end
        end
    end
    return name
end

local function Visible(frame)
    local ok, value = pcall(frame.IsVisible, frame)
    if ok then return value and true or false, true end

    forbidWarned = forbidWarned or setmetatable({}, { __mode = "k" })
    if not forbidWarned[frame] then
        forbidWarned[frame] = true
        ns:Print(("|cffffa940轮询读不到可见性|r：%s（forbidden 对象），暂停它的轮询，%d 秒复检一次。")
            :format(FrameLabel(frame) or "无名框", PAUSE_RETRY))
    end
    return false, false
end

--- 带暂停的可见性读（三个驱动都走这里）。读不出来就先把这个框挂起 PAUSE_RETRY 秒：
--- 期间一次都不碰（不抛错、不跑回调），期满再真读一次，读得出来就自动恢复。
--- 为什么不直接把它从轮询表里摘掉：模块那边用旁表标记去重（`deepSweep` / `showHook` /
--- `reassertHooked`…），条目没了标记还在，之后这个框就永远没人管了。而"读不到"多半是
--- **战斗中临时受限**，框本身没错，脱战就该继续被照看 —— 所以只暂停，不除名。
local pausedUntil = setmetatable({}, { __mode = "k" })
local function VisibilityOf(frame)
    local untilTime = pausedUntil[frame]
    if untilTime then
        if GetTime() < untilTime then return false, false end
        pausedUntil[frame] = nil          -- 到复检点：这一拍真读一次
    end
    local shown, readable = Visible(frame)
    if readable then return shown, true end
    pausedUntil[frame] = GetTime() + PAUSE_RETRY
    return false, false
end

--- 受限窗口换边（进战斗 / 脱战 / 地图 / 聊天锁定…）时把手里挂起的框全部放行：
--- 下一拍各真读一次，读得出来立刻恢复正常轮询，不用干等 5 秒复检点。
--- 走 Core 在 `ADDON_RESTRICTION_STATE_CHANGED` 里推的内部事件（Utils 比 Core 先加载，
--- 所以这里只能订阅，不能反过来调 Core 的注册接口）。
ns.EventBus:Register("MONETUI_RESTRICTION_CHANGED", function()
    for frame in pairs(pausedUntil) do pausedUntil[frame] = nil end
end)

local function MouseOver(frame)
    -- 本客户端没有 MouseIsOver / GetMouseFocus（实测都是 nil），但有 frame:IsMouseOver()。
    -- 顺序：先按最可靠的 frame 方法，再退到全局函数。
    local okFrame, over = pcall(frame.IsMouseOver, frame)
    if okFrame then return over and true or false end
    if _G.MouseIsOver then
        local ok, value = pcall(_G.MouseIsOver, frame)
        return ok and value
    end
    local focus = _G.GetMouseFocus and _G.GetMouseFocus()
    local guard = 0
    while focus and guard < 32 do
        if focus == frame then return true end
        focus = focus.GetParent and focus:GetParent()
        guard = guard + 1
    end
    return false
end

local function EnsureHoverDriver()
    if hoverDriver then return end
    hoverDriver = CreateFrame("Frame")
    hoverDriver:SetScript("OnUpdate", function(_, elapsed)
        hoverAcc = hoverAcc + (elapsed or 0)
        if hoverAcc < 0.1 then return end
        hoverAcc = 0
        local down = _G.IsMouseButtonDown and _G.IsMouseButtonDown("LeftButton")
        for frame, st in pairs(hoverWatch) do
            local shown, readable = VisibilityOf(frame)
            -- 暂停中的框：shown=false → inside=false，状态照常推进但 list 是空的，
            -- 一个回调都不跑（那些回调全是往这个框写东西，跑了也只是多一条拦截）。
            -- 复检到可读时按真实悬停重来一次 enter。
            local list = readable and st.list or idleList
            local inside = shown and MouseOver(frame)
            if inside ~= st.inside then
                st.inside = inside
                if inside then
                    for i = 1, #list do
                        local e = list[i]
                        if e.enter then pcall(e.enter, frame) end
                    end
                else
                    if st.pressed then
                        st.pressed = false
                        for i = 1, #list do
                            local e = list[i]
                            if e.up then pcall(e.up, frame) end
                        end
                    end
                    for i = 1, #list do
                        local e = list[i]
                        if e.leave then pcall(e.leave, frame) end
                    end
                end
            end
            if inside then
                local wantsDown = false
                for i = 1, #list do
                    if list[i].down then wantsDown = true break end
                end
                if wantsDown then
                    if down and not st.pressed then
                        st.pressed = true
                        for i = 1, #list do
                            local e = list[i]
                            if e.down then pcall(e.down, frame) end
                        end
                    elseif not down and st.pressed then
                        st.pressed = false
                        for i = 1, #list do
                            local e = list[i]
                            if e.up then pcall(e.up, frame) end
                        end
                    end
                end
            end
        end
    end)
end

--- 轮询式 hover。onEnter/onLeave/onDown/onUp 都只收到 frame。
---
--- **一个框体可以挂多个监听**：以前这里是"后来的覆盖前面的"（`st.enter = onEnter`），
--- 而 Skin:Button 先挂 HoverHighlight 再挂 ControlState —— 前者的 enter/leave 被静默顶掉，
--- 按钮的高亮就再也不亮（review 2026-10-29 4.1）。现在同一个框的各监听各存一份。
function Widget:HoverWatch(frame, onEnter, onLeave, onDown, onUp)
    if not frame then return end
    local st = hoverWatch[frame]
    if not st then
        st = { list = {}, inside = false, pressed = false }
        hoverWatch[frame] = st
        EnsureHoverDriver()
    end
    for i = 1, #st.list do
        local e = st.list[i]
        if e.enter == onEnter and e.leave == onLeave and e.down == onDown and e.up == onUp then
            return e
        end
    end
    local entry = { enter = onEnter, leave = onLeave, down = onDown, up = onUp }
    st.list[#st.list + 1] = entry
    return entry
end

--- 同样的轮询思路，观察"从隐藏变成显示"这一个瞬间（替掉 HookScript("OnShow")）。
--- 同样支持一个框多个监听（以前后来的覆盖前面的）。
local showWatch, showDriver, showAcc = setmetatable({}, { __mode = "k" }), nil, 0

local function EnsureShowDriver()
    if showDriver then return end
    showDriver = CreateFrame("Frame")
    showDriver:SetScript("OnUpdate", function(_, elapsed)
        showAcc = showAcc + (elapsed or 0)
        if showAcc < 0.2 then return end
        showAcc = 0
        for frame, st in pairs(showWatch) do
            local shown, readable = VisibilityOf(frame)
            if readable then
                if shown and not st.shown then
                    for i = 1, #st.list do pcall(st.list[i], frame) end
                end
                st.shown = shown
            end
        end
    end)
end

function Widget:ShowWatch(frame, fn)
    if not frame or type(fn) ~= "function" then return end
    local st = showWatch[frame]
    if not st then
        st = { list = {}, shown = VisibilityOf(frame) }
        showWatch[frame] = st
        EnsureShowDriver()
    end
    for i = 1, #st.list do
        if st.list[i] == fn then return fn end
    end
    st.list[#st.list + 1] = fn
    return fn
end

--- 通用轮询：默认每 0.2 秒对登记的框体调一次 fn(frame)；第三个参数可给每个回调
--- **自己的间隔**（秒）—— 以前这里是全局 0.2 秒，调用处写的 "2 秒" 其实没生效。
--- 用在"暴雪改了状态但没有任何 Lua 钩子"的场合（按钮 enabled、皮肤需要复检的东西…）。
local pollWatch, pollDriver = {}, nil
local POLL_INTERVAL = 0.2

--- 一个框体可以挂**多个**回调：早先这里是 `pollWatch[frame] = fn`（一个框只能一个回调），
--- 而四个模块都拿 UIParent 当锚点（Skins/System、Nameplates、Cooldown、QuestTracker）——
--- 后注册的会把先注册的**静默顶掉**，那些轮询就等于没装（"藏不掉、对不齐"的怪现象就出在这）。
--- 返回一个句柄，交给 Widget:Unwatch 注销（一次性的补扫必须注销，否则会一直空转）。
function Widget:PollWatch(frame, fn, interval)
    if not frame or type(fn) ~= "function" then return end
    local list = pollWatch[frame]
    if not list then
        -- forbidden 对象不进轮询：每拍读可见性必抛，而回调对它的写入同样会被拒。
        list = {}
        pollWatch[frame] = list
    end
    for i = 1, #list do
        if list[i].fn == fn then
            -- 同一回调重复登记只更新间隔，不重复执行。
            list[i].interval = tonumber(interval) or POLL_INTERVAL
            return list[i]
        end
    end
    local entry = { fn = fn, interval = tonumber(interval) or POLL_INTERVAL, acc = 0 }
    list[#list + 1] = entry
    if pollDriver then return entry end
    pollDriver = CreateFrame("Frame")
    pollDriver:SetScript("OnUpdate", function(_, elapsed)
        elapsed = elapsed or 0
        for f, cbs in pairs(pollWatch) do
            -- 隐藏的框不累加时间：等它显示时再从 0 开始算，不会"一显示就补执行一堆"。
            local shown, readable
            if type(f) == "table" and f.IsVisible then shown, readable = VisibilityOf(f) end
            if shown and readable then
                for i = 1, #cbs do
                    local cb = cbs[i]
                    cb.acc = cb.acc + elapsed
                    if cb.acc >= cb.interval then
                        cb.acc = 0
                        pcall(cb.fn, f)
                    end
                end
            end
        end
    end)
    return entry
end

--- 注销回调。三种 Watch（PollWatch / ShowWatch / HoverWatch）都从这里走：
---   * 省略 fn 时注销该框的全部回调；
---   * 给了 fn：HoverWatch 的监听按"任一回调等于 fn"匹配整条摘掉，ShowWatch / PollWatch 按值匹配。
--- 框体没有回调了就整条移除（驱动帧自己留着，开销只是一次空循环）。
function Widget:Unwatch(frame, fn)
    if not frame then return end

    local list = pollWatch[frame]
    if list then
        if not fn then
            pollWatch[frame] = nil
        else
            for i = #list, 1, -1 do
                if list[i].fn == fn then table.remove(list, i) end
            end
            if #list == 0 then pollWatch[frame] = nil end
        end
    end

    local show = showWatch[frame]
    if show then
        if not fn then
            showWatch[frame] = nil
        else
            for i = #show.list, 1, -1 do
                if show.list[i] == fn then table.remove(show.list, i) end
            end
            if #show.list == 0 then showWatch[frame] = nil end
        end
    end

    local hover = hoverWatch[frame]
    if hover then
        if not fn then
            hoverWatch[frame] = nil
        else
            for i = #hover.list, 1, -1 do
                local e = hover.list[i]
                if e.enter == fn or e.leave == fn or e.down == fn or e.up == fn then
                    table.remove(hover.list, i)
                end
            end
            if #hover.list == 0 then hoverWatch[frame] = nil end
        end
    end
end

--- 子树级鼠标静音：本客户端的 HUD 框（追踪框的任务块按钮池尤甚）点击件埋在深层，
--- 只关根框照样能点。
--- 两个旁表键各管一件事，**不能合成一个**："本来就没开鼠标"的节点要登记"已经处理过"，
--- 但还原时不能替它打开。如果只存一个键、并用 false 表示"本来没开"，那次 false 会同时
--- 被下一次的 `== nil` 判成"已处理"，而 Unmute 又只认真值、永远不清它 —— 于是这个节点
--- 之后被暴雪打开鼠标（池化按钮复用）就再也没人关回去，实机症状是"原始目标追踪还能点"。
local function MuteMouseTree(node, depth, on)
    if not node then return end
    if node.EnableMouse then
        if on then
            if not Marked(node, "muiMouseHeld") then
                Mark(node, "muiMouseHeld", true)
                local ok, was = pcall(node.IsMouseEnabled, node)
                if ok and was == true then Mark(node, "muiMousePrior", true) end
                pcall(node.EnableMouse, node, false)
                if node.EnableMouseClicks then pcall(node.EnableMouseClicks, node, false) end
                if node.EnableMouseMotion then pcall(node.EnableMouseMotion, node, false) end
            end
        elseif Marked(node, "muiMouseHeld") then
            local prior = Marked(node, "muiMousePrior")
            Mark(node, "muiMouseHeld", nil)
            Mark(node, "muiMousePrior", nil)
            if prior then
                pcall(node.EnableMouse, node, true)
                if node.EnableMouseClicks then pcall(node.EnableMouseClicks, node, true) end
                if node.EnableMouseMotion then pcall(node.EnableMouseMotion, node, true) end
            end
        end
    end
    if depth <= 0 then return end
    local ok, kids = pcall(function() return { node:GetChildren() } end)
    if not ok or not kids then return end
    for i = 1, #kids do MuteMouseTree(kids[i], depth - 1, on) end
end

--- 把暴雪的 HUD 框收起来：alpha 0 + 关鼠标。各模块以前各自抄一份
--- （BuffFrame / QuestTracker / Tooltip / 宠物条壳 / 姿态条壳），纪律却完全一样，抄的
--- 那份迟早漏一条 —— 现在只有这一处。
---
--- * **不 Hide()**：暴雪"一有更新就 Show 一次"，我们补一刀它顶一刀，屏幕上就是一闪一闪；
---   alpha 0 的框一直算显示着，不触发它的 Show 逻辑，拉锯就不存在。
--- * **不写字段 / 不卸事件 / 不换父**：那都会把这个框标成"被 MonetUI 写过"，之后它自己跑的
---   暴雪代码全记在我们名下（见 AGENTS.md 的污染模型）。
--- * 原状态存进 ns:Mark 的旁表（对象为弱键），所以重复调用只是一次表查询；
---   暴雪后来新建的池化子按钮由下一次调用补关（这就是各模块保留低频兜底的原因）。
---
-- @param opts { depth = 子树关鼠标的层数（0 = 只根框，默认 2；math.huge = 整棵树）,
--               alpha = 压到几（默认 0）, combat = "write" 时战斗里也写（默认跳过） }
-- @return 是否真的动了手（战斗里跳过返回 false）
function Widget:Mute(frame, opts)
    if not frame then return false end
    opts = opts or {}
    if opts.combat ~= "write" and ns:InCombat() then return false end
    if not Marked(frame, "muiMuted") then
        Mark(frame, "muiMuted", true)
        local ok, alpha = pcall(frame.GetAlpha, frame)
        if ok then Mark(frame, "muiMuteAlpha", alpha) end
    end
    pcall(frame.SetAlpha, frame, opts.alpha or 0)
    MuteMouseTree(frame, opts.depth or 2, true)
    return true
end

--- 放开：alpha 与鼠标状态都还原成 Mute 之前记下的那一份（只还我们改过的节点）。
function Widget:Unmute(frame, opts)
    if not frame or not Marked(frame, "muiMuted") then return false end
    opts = opts or {}
    if opts.combat ~= "write" and ns:InCombat() then return false end
    local prior = Marked(frame, "muiMuteAlpha")
    Mark(frame, "muiMuted", nil)
    Mark(frame, "muiMuteAlpha", nil)
    pcall(frame.SetAlpha, frame, prior or 1)
    MuteMouseTree(frame, opts.depth or 2, false)
    return true
end

--- 这块框现在是不是被我们压着。给"战斗里被跳过、要等脱战补一刀"的调用方判断还有没有活干：
--- 没压过就没什么可还原的，不必留在队列里空转。
function Widget:IsMuted(frame)
    return frame ~= nil and Marked(frame, "muiMuted") == true
end

ns.Widget = Widget

-- weak keys so hidden / discarded widgets do not leak
local themed = setmetatable({}, { __mode = "k" })

-- Shading is geometry, not art: a StatusBar's texture is a flat tintable base colour and the volume
-- comes from a gradient set at runtime, along the bar's own axis.  Baking the ramp into the texture
-- (what monet_barfill used to do) ties the shading to one bar height -- stretch a 16px ramp over a
-- 40px slider thumb and it stops reading as a cross-section and becomes one long fade.
-- Two shared colour pairs serve every bar and every surface: SetGradient copies the values at call time,
-- so there is no per-widget state and no per-event allocation.  Built lazily and once -- a client without
-- CreateColor just keeps the flat base colour instead of raising on every bar.
local gradTail, gradHead   -- StatusBar fill: trailing end -> leading edge
local surfLit, surfSunk    -- flat surface: lit on top -> sunk below
local function EnsureGradients()
    if gradTail then return true end
    if type(CreateColor) ~= "function" then return false end
    gradTail = CreateColor(0.60, 0.60, 0.64, 1)
    gradHead = CreateColor(1, 1, 1, 1)
    surfLit  = CreateColor(1, 1, 1, 1)
    surfSunk = CreateColor(0.28, 0.28, 0.30, 1)
    return true
end

--- Re-derive a StatusBar's fill gradient from the bar's own orientation.
-- 只在**显式要求**老视觉时用：Widget:Bar 的两条默认路径（烤进贴图的剖面）都不叠它。
-- MUST be called again after SetStatusBarTexture: that call builds a brand new texture object, and the
-- old one carried the gradient (the same trap that catches their fill rotation after a texture swap).
function Widget:BarGradient(bar)
    if not bar then return end
    local tex = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    if not tex or not EnsureGradients() then return end
    local vertical = false
    if bar.GetOrientation then
        local ok, o = pcall(bar.GetOrientation, bar)
        vertical = ok and o == "VERTICAL"
    end
    tex:SetGradient(vertical and "VERTICAL" or "HORIZONTAL", gradTail, gradHead)
end

--- Cross-sectional shading for a flat surface (button sheen, scroll thumb): lit from the top, sinking
-- toward the bottom.  Unlike a bar this is about the surface's thickness, not its fill direction, so it
-- is always vertical -- a 12x40 thumb reads as a rounded grip instead of a smear.
function Widget:TopLight(tex)
    if not tex or not EnsureGradients() then return end
    tex:SetGradient("VERTICAL", surfLit, surfSunk)
end

--- The border colour for a widget: its own override if it set one, otherwise the user's global slot (see Color:GetBorderKey).
-- Only the hue comes from the key: the opacity stays the edge slot's, so switching to the (translucent) ambient tint can never make a border invisible.
local function BorderColor(opts)
    local key = (opts and opts.borderKey) or Color:GetBorderKey()
    local r, g, b = Color:Get(key)
    return r, g, b
end

-- Every size the addon hands to the engine goes through one of these three, so the whole UI lands on
-- the pixel grid without any call site having to remember.  They are the reason the rest of the file
-- is still allowed to call plain SetSize: a raw size is a size that missed the grid.
function Widget:Size(frame, width, height)
    if not frame then return frame end
    local w = Media:SnapUnit(width)
    local h = height and Media:SnapUnit(height) or w
    frame:SetSize(w, h)
    -- 条：定了尺寸就按最终高度重选剖面（粗条 / 细条两张贴图）。
    if Widget.SyncBarFill then Widget:SyncBarFill(frame) end
    return frame
end

function Widget:Width(frame, width)   if frame then frame:SetWidth(Media:SnapUnit(width)) end return frame end
function Widget:Height(frame, height)
    if frame then
        frame:SetHeight(Media:SnapUnit(height))
        if Widget.SyncBarFill then Widget:SyncBarFill(frame) end
    end
    return frame
end

--- 建一个框体。
--- kind = "Frame"（默认）/ "CheckButton" / "Button"……
--- template 省略时用 "BackdropTemplate"（要有 SetBackdrop）。
--- 单位框要当"安全单位按钮"用（见 Modules/UnitFrames/UnitFrames.lua）：
--- kind = "CheckButton" + template = "SecureUnitButtonTemplate, BackdropTemplate"
--- —— 两个模板写在同一条串里实测可用（SetBackdrop 在、SetAttribute 在、受保护标记也在）。
function Widget:CreateFrame(name, parent, width, height, template, kind)
    local frame = CreateFrame(kind or "Frame", name, parent, template or "BackdropTemplate")
    if width then Widget:Size(frame, width, height or width) end
    return frame
end

--- 细条阈值：条高 <= 这个值就改用细条剖面（monet_barfill_thin：上亮下暗的单向）。
--- 4–6px 上 64 行渐变只剩 4 个台阶，单向剖面在细条上读起来最像"被上方打光"。
local THIN_BAR_MAX = 6

--- 某条高的条该用哪张剖面填充贴图。
function Widget:BarFillTexture(height)
    if height and height <= THIN_BAR_MAX then return "monet_barfill_thin" end
    return "monet_barfill_gradient"
end

-- 由 Widget:Bar 建出来的条：true = 剖面自动跟着高度走；字符串 = 调用方显式指定的材质。
-- 弱键，免得丢弃的条一直占着表。
local barFill = setmetatable({}, { __mode = "k" })

--- 按条**当前**高度重选剖面。只对 Widget:Bar 建出来的、且没显式指定材质的条生效。
--- 触发点是 Widget:Size / Widget:Height：条可以是"先建、后定高"的，建的时候拿不到最终
--- 高度；只按创建时的高度选，1px 的条会拿到"粗条"那张剖面（1px 只采样到最顶一行，
--- 整条看着和预期不一致）。用裸 SetHeight 改高的条接不到这一步 —— 走 Widget:Size/Height。
--- 能量条不走这条路径：它显式指定了扁平材质（纯高亮平涂）。
function Widget:SyncBarFill(bar, height)
    if not bar then return end
    if barFill[bar] ~= true then return end
    -- height 可省：调用方是"按锚点定高"（GetHeight 这一帧可能还没结算）时显式给一个。
    local h = height or (bar.GetHeight and bar:GetHeight())
    local key = Widget:BarFillTexture(h)
    if Marked(bar, "fillKey") == key then return end
    Mark(bar, "fillKey", key)
    bar:SetStatusBarTexture(Media:Texture(key))
end

--- 建一条状态条。
--- textureKey **不传**时按条高自动选剖面：细条用上亮下暗的单向细条剖面
--- （monet_barfill_thin），其余用整条单向剖面（monet_barfill_gradient）。两张都已烤进贴图，
--- 所以都不叠 Widget:BarGradient（运行时渐变会和贴图相乘，等于双倍压暗）。
--- textureKey **传了**就按字面用，**不叠任何渐变**：调用方要的是那块材质本身
--- （能量条就是这条路径 —— 纯高亮平涂，只要顶点色）。
function Widget:Bar(parent, width, height, textureKey)
    local key = textureKey or Widget:BarFillTexture(height)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(Media:Texture(key))
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    -- 登记必须**在** Widget:Size 之前：Size 会调 SyncBarFill 按最终高度复核剖面，
    -- 这时 barFill[bar] 还是 nil 的话那次复核就是空转（创建时选的那张就此定死）。
    barFill[bar] = textureKey or true
    Mark(bar, "fillKey", key)
    if width then Widget:Size(bar, width, height or 18) end

    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    local r, g, b = Color:GetNeutral()
    bar.bg:SetColorTexture(r, g, b, 0.25)

    themed[bar] = { kind = "bar", bgAlpha = 0.25, texture = key }
    return bar
end

--- 血条的"损失部分"底（review 2026-10-24 #4）：UnitFrames / Groups / Nameplates 三处原本
--- 各自复制 CreateTexture + SetAllPoints + 底色，这里统一。底色走 SetVertexColor 而不是
--- SetColorTexture 烧 texel —— 底面还要被顶点色动态改（UF / Groups 血量换色、Nameplates
--- 死亡灰化），烧死 texel 会堵死那条路（黑 texel × 灰顶点色 = 永远黑）。
--- UF / Groups 白底（之后按血量染色），Nameplates 黑底（死亡时贴中性灰）；Groups 需要
--- subLevel 1（垫在 weave 织纹之下），另两处默认 0。
--- @return the just-created "lost health" underlay texture
function Widget:LostBarBG(bar, r, g, b, subLevel)
    local lost = bar:CreateTexture(nil, "BACKGROUND", nil, subLevel)
    lost:SetAllPoints(bar)
    lost:SetVertexColor(r, g, b, 1)
    return lost
end

-- The bar ground (Assets/Textures/monet_stripe_weave.tga, drawn by tools/regen-textures.js):
-- 64x64, one-direction 45° hairlines on a 4px period.  The number is the texture's, not a
-- taste call -- the texcoord window below is measured in it.
local WEAVE_SIZE = 64

--- The Monet ground for a bar: a fine 45° hairline cloth (monet_stripe_weave), laid over the
--- bar's background so the empty part of a bar reads as painted cloth instead of a flat hole.
--- The fill stays flat on purpose -- a bar's volume is SetGradient geometry (see
--- Widget:BarGradient), and a patterned fill would fight it.
--- ORDER MATTERS: call this AFTER the bar's other background textures, so the cloth draws
--- over them (same draw layer, creation order) while the fill still covers it.
--- The texture is TILED, not stretched: one texel per physical pixel on both axes, so the 45°
--- angle stays 45° at any bar width and a 4px health bar still shows fine lines instead of a
--- smeared grid.  The window always starts on the same row of the tile, so a 1px power bar and
--- a 4px health bar show the same phase.
---   opts.height  bar height in UI units (default: the bar's own height)
---   opts.alpha   opacity of the cloth (default 0.85: high enough to read against the black /
---                red "lost" colour that sits under it)
--- @return the weave texture, cached on the bar as __monetWeave
function Widget:BarWeave(bar, opts)
    if not bar then return nil end
    opts = opts or {}

    local weave = Marked(bar, "weave")
    if not weave then
        -- Same layer as the bar's other background textures (BACKGROUND, sublevel 0) and
        -- created after them, so it draws over them -- the StatusBar's own fill texture sits
        -- in a higher layer, so the fill still covers the cloth wherever the bar is filled.
        -- (Andromeda's health element is the reference: its "lost" background is created the
        -- same way and the fill stays on top.)
        weave = bar:CreateTexture(nil, "BACKGROUND")
        -- REPEAT on both axes: the texcoord below asks for more than one tile of the
        -- 64px stripe (1 texel = 1 physical pixel), so the default CLAMP would smear
        -- the last column instead of repeating the hatch.
        weave:SetTexture(Media.texture["monet_stripe_weave"], "REPEAT", "REPEAT")
        weave:SetAllPoints(bar)
        Mark(bar, "weave", weave)
    end

    -- One texel per physical pixel on both axes.  Media:Mult() is UI units per physical pixel,
    -- so the tile spans 64 * Mult() UI units; the count of repeats is width / (64 * Mult()).
    -- The vertical window is CONTINUOUS (height / Mult, not rounded to whole texels): rounding
    -- it while the horizontal span stays exact would sample x and y at different densities and
    -- tilt the 45° hatch on fractional scales.  With both axes on the same Mult(), the angle is
    -- 45° for every bar size, including a 1px power bar.
    local mult = Media:Mult()
    local width = opts.width or (bar:GetWidth() or 1)
    local height = opts.height or (bar:GetHeight() or 2)
    local cols = math.max(0, width / (mult * WEAVE_SIZE))
    local v0 = 1 / WEAVE_SIZE
    local v1 = v0 + height / (mult * WEAVE_SIZE)
    weave:SetTexCoord(0, cols, v0, v1)

    local r, g, b = Color:GetNeutral()
    local alpha = opts.alpha or 0.85
    weave:SetVertexColor(r, g, b, alpha)

    -- The ground follows the theme like the flat background does.
    local entry = themed[bar]
    if entry then
        entry.weave = weave
        entry.weaveAlpha = alpha
    end
    return weave
end

function Widget:Icon(parent, size, layer, sublevel)
    local icon = parent:CreateTexture(nil, layer or "ARTWORK", nil, sublevel)
    if size then Widget:Size(icon, size, size) end
    return icon
end

--- A FontString using the addon fonts.
-- @param key font key in Media.font ("pixel", "cooldown", "pingfang"); @param colorKey "edge" | "neutral" | "highlight" | "border" | "health" | "danger" | {r,g,b}
-- @param flags optional render flags；传 Media.fontFlags / Media.outlineFlags（"默认口径"的
--        两种拼写）或不传时，按字号换挡（Media:EffectiveFlags：<12px 点阵苹方硬边、
--        ≥12px 文楷抗锯齿）；自定义 flags 尊重调用方。
function Widget:Font(parent, size, key, colorKey, justify, layer, flags)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    local finalSize = Media:SnapSize(size)
    fs:SetFont(Media:FontFor(key, finalSize), finalSize, Media:EffectiveFlags(flags, finalSize))
    if fs.SetShadowOffset then fs:SetShadowOffset(0, 0) end
    fs:SetJustifyH(justify or "LEFT")
    Widget:ColorText(fs, colorKey)

    themed[fs] = { kind = "text", colorKey = colorKey }
    return fs
end

--- Re-apply an existing FontString's font (used when a widget already exists).
--- exact = true 时**不**吸附到像素格（Media:SnapSize 把 ≤10 的都夹到 10）。
--- 只有"按图标尺寸等比缩放"的场合用得上：光环图标只有 14 单位高，
--- 10px 的数字塞进去就顶满整格，按比例算出来是 8 —— 那就得让它真的是 8。
function Widget:SetFont(fs, size, key, flags, exact)
    if not fs or not fs.SetFont then return fs end
    local finalSize = exact and (tonumber(size) or 12) or Media:SnapSize(size)
    pcall(fs.SetFont, fs, Media:FontFor(key, finalSize), finalSize, Media:EffectiveFlags(flags, finalSize))
    return fs
end

--- 把文本塞进 `maxWidth`：超宽就**逐档缩小字号**（1px 步进），绝不裁字。
-- 用途（玩家 2026-10-27 定的规则）：名字最多占姓名条 70%，超了就缩字号 ——
-- 姓名板 / 单位框 / 小队框全部走这一个入口，旧的按字数截断（Shorten/AbbrName）停用。
-- 机密文本、或宽度读回来是机密（FontString 锚在机密几何上时 GetStringWidth 会变机密）→
-- 不测不缩，原样按 baseSize 显示（宁可溢出也不瞎猜，见 AGENTS 秘密值规矩）。
-- @param fs FontString；text 要显示的文本；maxWidth 允许的最大宽度（UI 单位）
-- @return 最终字号（像素字符串，未吸附网格 —— 缩字需要连续档）
function Widget:FitText(fs, text, maxWidth, baseSize, flags, minSize, boxWidth)
    if not (fs and fs.SetText) then return baseSize end
    baseSize = tonumber(baseSize) or 12
    minSize  = tonumber(minSize) or 6
    local Secrets = ns.Secrets

    -- 字体按**当档字号**换挡：FitText 会逐档缩字号、跨过 12 的边界时要从小字轨（点阵苹方
    -- 硬边）切到大字轨（文楷 AA）或切回去，所以不能在外面定死一个 fontPath。
    local function apply(size)
        if fs.SetFont then
            fs:SetFont(Media:FontFor("pixel", size), size, Media:EffectiveFlags(flags, size))
        end
    end

    apply(baseSize)
    fs:SetText(text or "")

    if Secrets and Secrets.IsSecret(text) then return baseSize end
    if not (maxWidth and maxWidth > 0) then return baseSize end

    -- 名字框固定 SetSize 的调用方（Groups）显式传 boxWidth：盒子比限额窄就以盒子为准。
    -- **不要用 fs:GetWidth() 去猜** —— 自动宽度的 FontString（只锚一个点）GetWidth 跟着
    -- 文本走，等于把限额压到"文本自身宽度"，然后 `width > maxWidth` 是同源浮点
    -- 比大小，毛刺一翻就白白缩一档（2026-10-28 实机判例：玩家名 10 号被压成 9）。
    local box = tonumber(boxWidth)
    if box and box > 0 and box < maxWidth then
        maxWidth = box
    end

    local width = fs.GetStringWidth and fs:GetStringWidth() or 0
    if type(width) ~= "number" or (Secrets and Secrets.IsSecret(width)) then return baseSize end

    local size = baseSize
    while width > maxWidth and size > minSize do
        size = size - 1
        apply(size)
        width = fs:GetStringWidth()
        if type(width) ~= "number" or (Secrets and Secrets.IsSecret(width)) then return size end
    end
    return size
end

function Widget:ColorText(fs, colorKey)
    if not fs or not fs.SetTextColor then return fs end

    local r, g, b, a
    if type(colorKey) == "table" then
        r, g, b, a = colorKey.r, colorKey.g, colorKey.b, colorKey.a or 1
    elseif colorKey == "edge" then
        r, g, b, a = Color:GetEdge()
    elseif colorKey == "highlight" then
        r, g, b, a = Color:GetHighlight()
    elseif colorKey == "border" then
        -- 跟随用户的边框槽（edge / ambient / highlight / neutral）：文字和描边用同一套主题色。
        r, g, b, a = Color:GetBorder()
        a = 1
    elseif colorKey == "health" then
        r, g, b, a = Color:GetHealth()
    elseif colorKey == "danger" then
        r, g, b, a = Color:GetDanger()
    elseif colorKey == "resource" then
        r, g, b, a = Color:GetResource()
    else
        r, g, b, a = Color:GetNeutral()
    end

    fs:SetTextColor(r, g, b, a or 1)
    return fs
end

function Widget:Cooldown(parent, size)
    local cd = CreateFrame("Cooldown", nil, parent, "CooldownFrameTemplate")
    cd:SetAllPoints()
    if size then Widget:Size(cd, size) end
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetDrawSwipe(true)
    cd:SetHideCountdownNumbers(false)
    Widget:StyleCooldownText(cd)
    return cd
end

--- Style the built-in countdown numbers of a Cooldown widget.
function Widget:StyleCooldownText(cd, size, key, color, flags, exact)
    if not cd then return end
    for _, region in ipairs({ cd:GetRegions() }) do
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
            local px = exact and (tonumber(size) or 12) or Media:SnapSize(size)
            pcall(region.SetFont, region, Media:FontFor(key or "cooldown", px), px, Media:EffectiveFlags(flags, px))
            local r, g, b = 1, 1, 1
            if type(color) == "table" then r, g, b = color.r, color.g, color.b end
            pcall(region.SetTextColor, region, r, g, b, 1)
        end
    end
end

function Widget:CloseButton(parent, size)
    local btn = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    Widget:Size(btn, size or 24)
    return btn
end

-- The rounded-border art, in three ring widths.  Each entry is fixed by the texture, not by taste:
--   ring   = the ring's width in texels, which 9-slice maps 1:1 into UI units  -> also the background inset
--   slice  = the outer arc radius in texels, which is also the smallest edgeSize that shows the whole arc
-- Source TGA lives in Assets-src/Textures (tracked, not shipped); the shipped copy is
-- Assets/Textures/monet_round_edge{,_thin,_thick}.blp.  The three numbers have to stay in step with
-- tools/regen-textures.js (ROUND_EDGES) or the border drifts or gets clipped.
-- (SetBackdrop's edgeFile cannot ingest these at all in this client -- see Widget:ApplyBackdrop -- so the
-- rings are only ever drawn as plain textures; the old *_blp alias keys were removed 2026-10-28.)
-- 2026-10-28：外弧从 3 提到 8（纹理 32×32），三档只差环宽，slice 统一 8。
-- 角部用**曲率渐变**（欧拉螺线）而不是圆弧：曲率从 0 线性升到峰值再降回 0（G2 连续），
-- 直边与角部的接口没有"折一下"的观感；同外弧下曲率峰值比圆弧/超椭圆低三成。
local ROUND_EDGES = {
    { key = "monet_round_edge_thin",   ring = 1, slice = 8 },
    { key = "monet_round_edge",        ring = 2, slice = 8 },
    { key = "monet_round_edge_thick",  ring = 3, slice = 8 },
}

--- Pick the ring whose width is nearest the physical thickness asked for.
-- The ring lives in the texture, so its width can only be a whole number of UI units; the width we
-- actually want is thickness / uiScale, which is usually fractional (thickness=2 at uiScale 0.71 wants
-- 2.82).  Rounding to the nearest available ring keeps the error under half a physical pixel instead
-- of letting the two rounded panels drift by 2/uiScale against every flat border in the addon.
local function PickRoundEdge(thickness)
    local want = thickness * Media:Mult()        -- 想要的 UI 单位数
    local best, bestErr = ROUND_EDGES[2], nil
    for i = 1, #ROUND_EDGES do
        local e = ROUND_EDGES[i]
        local err = math.abs(e.ring - want)
        if not bestErr or err < bestErr then best, bestErr = e, err end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- 自绘 9-slice 圆角边框
-- ---------------------------------------------------------------------------
-- SetBackdrop 的 edgeFile 在本引擎上不可用（连 RAW3 BLP 都渲染成碎线），所以四角与四边由我们
-- 自己摆贴图：4 块角（原尺寸，1 纹素 = 1 UI 单位，弧线因此精确）+ 4 条边（沿轴向拉伸），
-- 外加 4 块**圆角填充**压在下面，补住 SetBackdrop 方底在圆角处戳出来的那一小块。
--
-- 贴图共用一张：靠 SetTexCoord 取九宫格里的不同块。全部挂在框体自己的 BORDER 层（边框）与
-- BACKGROUND 层（填充），不碰任何暴雪对象，也不往框体上写字段（状态走 ns:Mark 的旁表）。
local ROUND_TEX = 32          -- 圆角贴图的边长（纹素），与 regen-textures.js 一致
local ROUND_SLICE = 8         -- 外弧半径（纹素 = UI 单位），与 ROUND_EDGES 的 slice 一致

local function LayoutRoundBorder(st)
    local frame, s, w = st.frame, ROUND_SLICE, st.ring
    local u0, u1 = 0, s / ROUND_TEX                       -- 角部横向纹理区间
    local v0, v1 = 0, s / ROUND_TEX
    local ru = w / ROUND_TEX                              -- 边带宽度的纹理区间

    local function place(tex, point, relPoint, x, y, w2, h2)
        tex:ClearAllPoints()
        tex:SetPoint(point, frame, relPoint, x, y)
        if w2 then tex:SetSize(w2, h2) end
    end

    -- 四角
    place(st.corner.tl, "TOPLEFT", "TOPLEFT", 0, 0, s, s)
    place(st.corner.tr, "TOPRIGHT", "TOPRIGHT", 0, 0, s, s)
    place(st.corner.bl, "BOTTOMLEFT", "BOTTOMLEFT", 0, 0, s, s)
    place(st.corner.br, "BOTTOMRIGHT", "BOTTOMRIGHT", 0, 0, s, s)

    -- 四边：只在两个角之间铺，厚度 = 环宽
    local function span(tex, p1, r1, x1, y1, p2, r2, x2, y2, thickness, vertical)
        tex:ClearAllPoints()
        tex:SetPoint(p1, frame, r1, x1, y1)
        tex:SetPoint(p2, frame, r2, x2, y2)
        if vertical then tex:SetWidth(thickness) else tex:SetHeight(thickness) end
    end
    span(st.edge.top, "TOPLEFT", "TOPLEFT", s, 0, "TOPRIGHT", "TOPRIGHT", -s, 0, w, false)
    span(st.edge.bottom, "BOTTOMLEFT", "BOTTOMLEFT", s, 0, "BOTTOMRIGHT", "BOTTOMRIGHT", -s, 0, w, false)
    span(st.edge.left, "TOPLEFT", "TOPLEFT", 0, -s, "BOTTOMLEFT", "BOTTOMLEFT", 0, s, w, true)
    span(st.edge.right, "TOPRIGHT", "TOPRIGHT", 0, -s, "BOTTOMRIGHT", "BOTTOMRIGHT", 0, s, w, true)

    -- 纹理区间：角 = 九宫格的四个角；边 = 两角之间的那条带
    st.corner.tl:SetTexCoord(0, u1, 0, v1)
    st.corner.tr:SetTexCoord(1 - u1, 1, 0, v1)
    st.corner.bl:SetTexCoord(0, u1, 1 - v1, 1)
    st.corner.br:SetTexCoord(1 - u1, 1, 1 - v1, 1)
    st.edge.top:SetTexCoord(u1, 1 - u1, 0, ru)
    st.edge.bottom:SetTexCoord(u1, 1 - u1, 1 - ru, 1)
    st.edge.left:SetTexCoord(0, ru, v1, 1 - v1)
    st.edge.right:SetTexCoord(1 - ru, 1, v1, 1 - v1)

    -- 圆角填充的角：与环同形（同一个外沿），只负责补住方底
    for _, key in ipairs({ "tl", "tr", "bl", "br" }) do
        st.fill[key]:ClearAllPoints()
        st.fill[key]:SetPoint(({ tl = "TOPLEFT", tr = "TOPRIGHT", bl = "BOTTOMLEFT", br = "BOTTOMRIGHT" })[key], frame,
            ({ tl = "TOPLEFT", tr = "TOPRIGHT", bl = "BOTTOMLEFT", br = "BOTTOMRIGHT" })[key], 0, 0)
        st.fill[key]:SetSize(s, s)
        st.fill[key]:SetTexCoord(st.corner[key]:GetTexCoord())
    end

end

--- 开启（或更新）一个框体的圆角边框。opts.thickness 与方角边框同义。
function Widget:RoundBorder(frame, opts)
    if not frame or not frame.CreateTexture then return nil end
    opts = opts or {}
    local edge = PickRoundEdge(opts.thickness or 1)

    local st = Marked(frame, "roundBorder")
    if not st then
        st = { frame = frame, ringKey = edge.key, corner = {}, edge = {}, fill = {} }
        Mark(frame, "roundBorder", st)
        local ringTex = Media.texture[edge.key]
        local fillTex = Media.texture.monet_round_fill
        for _, key in ipairs({ "tl", "tr", "bl", "br" }) do
            local tex = frame:CreateTexture(nil, "BORDER", nil, 1)
            tex:SetTexture(ringTex)
            st.corner[key] = tex

            local fill = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
            fill:SetTexture(fillTex)
            st.fill[key] = fill
        end
        for _, key in ipairs({ "top", "bottom", "left", "right" }) do
            local tex = frame:CreateTexture(nil, "BORDER", nil, 1)
            tex:SetTexture(ringTex)
            st.edge[key] = tex
        end
        -- 尺寸变化时重排。只挂**我们自己的**框（名字前缀 MonetUI）——挂到暴雪框上等于插进它的
        -- 事件链，一样会污染；没名字的框靠 Refresh 里的尺寸比对兜底（见下）。
        local fname = frame.GetName and frame:GetName()
        if frame.HookScript and fname and fname:find("^MonetUI") then
            frame:HookScript("OnSizeChanged", function(self) -- TAINT-OK: name 门控，只挂自建框
                local state = Marked(self, "roundBorder")
                if state then LayoutRoundBorder(state) end
            end)
        end
    elseif st.ringKey ~= edge.key then
        -- 换了环宽：贴图换成新的一档
        local ringTex = Media.texture[edge.key]
        st.ringKey = edge.key
        for _, key in ipairs({ "tl", "tr", "bl", "br" }) do st.corner[key]:SetTexture(ringTex) end
        for _, key in ipairs({ "top", "bottom", "left", "right" }) do st.edge[key]:SetTexture(ringTex) end
    end

    st.ring = edge.ring
    LayoutRoundBorder(st)
    return st
end

--- (Re)build the backdrop table and push it to the frame.  Split out of Theme so it can be re-run on
--- its own: every value here is derived from Media:Mult(), i.e. from the uiScale CVar, so a UI scale
--- change invalidates all of them.  Without this the borders built before the player moved the slider
--- keep their old physical width while newly created widgets get the new one -- two border widths on
--- screen at once.
function Widget:ApplyBackdrop(frame, opts)
    if not frame or not frame.SetBackdrop then return end
    local bd = Marked(frame, "backdrop")
    if not bd then
        bd = {}
        Mark(frame, "backdrop", bd)
    end
    bd.bgFile = Media.texture.blank
    if opts.round then
        -- 圆角：SetBackdrop 的 edgeFile 在本引擎上不可用（连 RAW3 BLP 都渲染成碎线，见
        -- Widget:RoundBorder 的注释），所以边框完全自绘 9-slice；这里只留下背景，并把背景
        -- 内缩到环的内沿，别让方底盖住我们的边框。
        local ring = PickRoundEdge(opts.thickness or 1)
        bd.edgeFile = nil
        bd.edgeSize = 0
        bd.insets = { left = ring.ring, right = ring.ring, top = ring.ring, bottom = ring.ring }
        frame:SetBackdrop(bd)
        Widget:RoundBorder(frame, opts)
        return
    else
        -- Square corners: a continuous line of WHITE8X8.  edgeSize / insets are physical pixels
        -- (thickness * Media:Mult()), so the line stays crisp at any UI scale instead of softening
        -- when scale ~= 1.
        local edge = opts.thickness * Media:Mult()
        bd.edgeFile = Media.texture.blank
        bd.edgeSize = edge
        bd.insets = { left = edge, right = edge, top = edge, bottom = edge }
    end
    frame:SetBackdrop(bd)
end

--- Register a frame for themed background + border.
-- @param opts table { thickness=, bgAlpha=, borderAlpha=, bgTexture=, borderKey=, round= }
function Widget:Theme(frame, opts)
    if not frame then return frame end
    opts = opts or {}
    opts.thickness = opts.thickness or 1
    opts.bgAlpha = opts.bgAlpha or 0.85
    opts.kind = "frame"

    themed[frame] = opts

    Widget:ApplyBackdrop(frame, opts)
    Widget:Refresh(frame, opts)
    return frame
end

function Widget:Refresh(frame, opts)
    opts = opts or themed[frame] or {}

    if opts.kind == "pixelglow" then
        -- 像素环：颜色跟主题走，刷新只重新上色，不动几何。
        Widget:RefreshPixelGlow(frame)
    elseif opts.kind == "bar" then
        if frame.bg then
            local r, g, b = Color:GetNeutral()
            frame.bg:SetColorTexture(r, g, b, opts.bgAlpha or 0.25)
        end
        -- The woven ground follows the theme like the flat background does, and its texcoord
        -- window follows the UI scale (one texel per physical pixel).
        if opts.weave then
            Widget:BarWeave(frame, { alpha = opts.weaveAlpha })
        end
    elseif opts.kind == "text" then
        Widget:ColorText(frame, opts.colorKey)
    elseif frame.SetBackdropColor then
        local ar, ag, ab = Color:GetAmbient()
        frame:SetBackdropColor(ar * 0.35, ag * 0.35, ab * 0.35, opts.bgAlpha or 0.85)

        local state = opts.borderState
        local kr, kg, kb, ka
        if state then
            -- A live state (threat glow ...) outranks the themed colour and lives in this opts table, so a theme-refresh broadcast re-applies *it* instead of stomping it.
            frame:SetBackdropBorderColor(state.r, state.g, state.b, state.a or 1)
            kr, kg, kb, ka = state.r, state.g, state.b, state.a or 1
        else
            kr, kg, kb = BorderColor(opts)
            local _, _, _, ea = Color:GetEdge()
            ka = opts.borderAlpha or ea or 1
            frame:SetBackdropBorderColor(kr, kg, kb, ka)
        end
        -- 自绘圆角边框自己上色：环吃边框色，填充块吃背景色（与 SetBackdropColor 同源）
        local st = Marked(frame, "roundBorder")
        if st then
            -- 尺寸兜底：没名字的框挂不了 OnSizeChanged，这里比对一下再重排（12 个 SetPoint，很轻）
            local fw, fh = frame:GetWidth(), frame:GetHeight()
            if fw ~= st.lastW or fh ~= st.lastH then
                st.lastW, st.lastH = fw, fh
                LayoutRoundBorder(st)
            end
            local a = opts.bgAlpha or 0.85
            for _, key in ipairs({ "tl", "tr", "bl", "br" }) do
                st.corner[key]:SetVertexColor(kr, kg, kb, ka)
                st.fill[key]:SetVertexColor(ar * 0.35, ag * 0.35, ab * 0.35, a)
            end
            for _, key in ipairs({ "top", "bottom", "left", "right" }) do
                st.edge[key]:SetVertexColor(kr, kg, kb, ka)
            end
        end
    end
end

--- Give a themed frame a live border colour, or take it back with no colour.
-- Dynamic states (threat glow, hover) write here instead of SetBackdropBorderColor: the override is kept in the widget's theme entry, so a MONETUI_THEME_CHANGED repaint applies the same override rather than resetting to the global slot.  Returns false for a frame that was never themed.
function Widget:SetBorderState(frame, r, g, b, a)
    local opts = frame and themed[frame]
    if not opts then return false end

    if r then
        -- The table is reused: the state layer repaints the border on every
        -- pulse frame, and a fresh table each time would be pure garbage.
        local state = opts.borderState
        if not state then
            state = { r = r, g = g, b = b, a = a }
            opts.borderState = state
        else
            state.r, state.g, state.b, state.a = r, g, b, a
        end
    else
        opts.borderState = nil
    end
    Widget:Refresh(frame, opts)
    return true
end

--- Re-tint every widget created through the factory.
-- Also re-derives the backdrop geometry, not just the colours: edgeSize / insets are built from
-- Media:Mult(), so a UI scale change leaves them stale.  `rescale` is set by the UI_SCALE_CHANGED
-- handler; on an ordinary theme change only the colours move and the backdrop is left alone.
function Widget:RefreshThemes(rescale)
    for frame, opts in pairs(themed) do
        if frame then
            if rescale and opts.kind == "frame" then
                Widget:ApplyBackdrop(frame, opts)
            end
            Widget:Refresh(frame, opts)
        end
    end
end

--- Border only (no background) using the current border colour.
function Widget:ApplyBorder(frame, thickness, borderKey)
    local r, g, b
    if borderKey then
        r, g, b = Color:Get(borderKey)
    else
        r, g, b = Color:GetBorder()
    end
    local _, _, _, a = Color:GetEdge()
    thickness = thickness or 1
    local edge = thickness * Media:Mult()   -- N physical pixels at any scale
    if not frame.backdrop then
        frame.backdrop = {}
    end
    frame.backdrop.bgFile = Media.texture.blank
    frame.backdrop.edgeFile = Media.texture.blank
    frame.backdrop.edgeSize = edge
    frame.backdrop.insets = { left = edge, right = edge, top = edge, bottom = edge }
    if frame.SetBackdrop then
        frame:SetBackdrop(frame.backdrop)
        frame:SetBackdropColor(0, 0, 0, 0)
        frame:SetBackdropBorderColor(r, g, b, a or 1)
    end
    return frame
end

--- 光环类小按钮的 1px 主题边框重涂(共用点,review 2026-10-24 #4):
--- UnitFrames 的 AuraContainer 按钮(TintAuraButton)与 Nameplates 的 debuff 按钮色带
--- 原来各写一套。两类目标分叉:
--- - 带 Backdrop 的框体 → 交给 Widget:ApplyBorder(顺带重建几何,主题换色/缩放两用),
---   颜色忽略传参,恒走主题边框色(与 UF 现状一致);
--- - 纯 Texture(暴雪按钮的色带)→ 先垫白 texel 再 SetVertexColor:染色走顶点色,
---   主题_changed 之后可以重复重涂(沿用 LostBarBG 的那套道理,texel 不烧死)。
--- r/g/b 缺省 = 当前主题边框色;pcall 全程兜底(受限环境这些目标可能暂时拿不到)。
--- @return the target (for chaining), ok=nil when the target was unusable
function Widget:TintIconBorder(target, r, g, b, a)
    if not target or type(target) ~= "table" then return target end
    if type(target.SetBackdropBorderColor) == "function" then
        return self:ApplyBorder(target, 1)
    end
    if r == nil then r, g, b = Color:GetBorder() end
    pcall(target.SetColorTexture, target, 1, 1, 1, 1)   -- white stencil, tint by vertex colour
    pcall(target.SetVertexColor, target, r, g, b, a or 1)
    return target
end

--- Subtle hover highlight used by the modules: one shared driver breathes the border alpha every ~1.2 s between 40% and full while hovered -- the Andromeda "button hover animation" idea, run against our border slot so it reads as the Monet edge quietly pulsing.
local pulsing = setmetatable({}, { __mode = "k" })
local PULSE_PERIOD = 1.2

--- Put a border back to whatever it should show when not hovered: its live dynamic state (quality, threat) if it has one, otherwise the theme slot.
local function RestoreBorder(frame)
    if not frame or not frame.SetBackdropBorderColor then return end
    local opts = themed[frame]
    local st = opts and opts.borderState
    if st then
        frame:SetBackdropBorderColor(st.r, st.g, st.b, st.a or 1)
    else
        local r, g, b = BorderColor(opts)
        local _, _, _, a = Color:GetEdge()
        frame:SetBackdropBorderColor(r, g, b, a or 1)
    end
end

--- IsMouseOver that can never raise.
-- This client declares IsMouseOver's return as SecretWhenAnchoringSecret: it is a SECRET boolean
-- whenever the frame's anchoring is secret (protected frames in combat, exactly when a threat pulse is
-- running).  pcall does not help -- the call succeeds and hands back a secret -- and `not secret` or
-- `secret and x` raises.  Every hover question in the addon goes through this one guarded answer.
-- The secret test has to come before ANY comparison: `value == nil` on a secret raises too.
function Widget:IsMouseOver(frame)
    if not frame or type(frame.IsMouseOver) ~= "function" then return false end
    local ok, value = pcall(frame.IsMouseOver, frame)
    if not ok then return false end
    if type(_G.issecretvalue) == "function" and _G.issecretvalue(value) then return false end
    if value == nil then return false end
    return value and true or false
end

local pulseDriver = CreateFrame("Frame")
pulseDriver:Hide()
pulseDriver:SetScript("OnUpdate", function(self, elapsed)
    for frame, st in pairs(pulsing) do
        if not frame:IsShown() or not Widget:IsMouseOver(frame) then
            -- lost the leave event (hidden / teleported) -- close out by hand
            pulsing[frame] = nil
            if frame.icon then frame.icon:SetVertexColor(1, 1, 1) end
            RestoreBorder(frame)
        else
            st.t = st.t + elapsed
            local wave = 0.5 + 0.5 * math.sin(st.t * (2 * math.pi) / PULSE_PERIOD)
            frame:SetBackdropBorderColor(st.r, st.g, st.b,
                st.amax * (0.4 + 0.6 * wave))
        end
    end
    if next(pulsing) == nil then self:Hide() end
end)

--- Start the border breath on a frame.  Public so hand-written hover scripts (the bag slots also drive a tooltip) can breathe exactly like Widget:Highlight -- one driver, one look.
--   r,g,b  hue to breathe;  amax peak alpha (default 1)
function Widget:Pulse(frame, r, g, b, amax)
    if not frame or not frame.SetBackdropBorderColor then return end
    pulsing[frame] = { r = r, g = g, b = b, amax = amax or 1, t = 0 }
    frame:SetBackdropBorderColor(r, g, b, amax or 1)
    pulseDriver:Show()
end

--- Stop the breath and put the border back (dynamic state first).
function Widget:UnPulse(frame)
    if not frame then return end
    pulsing[frame] = nil
    RestoreBorder(frame)
end

function Widget:Highlight(frame, alpha)
    frame:SetScript("OnEnter", function(self)
        if self.icon then self.icon:SetVertexColor(1.2, 1.2, 1.2) end
        local r, g, b = Color:GetHighlight()
        local st = themed[self] and themed[self].borderState
        if st then r, g, b = st.r, st.g, st.b end   -- pulse the live hue
        Widget:Pulse(self, r, g, b, alpha or 1)
    end)
    frame:SetScript("OnLeave", function(self)
        if self.icon then self.icon:SetVertexColor(1, 1, 1) end
        Widget:UnPulse(self)
    end)
    return frame
end

--- The Monet button/slot "material": a seamless weave tile laid UNDER the content (this is the Andromeda/NDui "tiled backdrop texture" step, drawn from scratch) plus an ADD-blended top-lit gradient sheen (monet_barfill) OVER the content.
-- Both layers are near-white and tintable, so one theme colour drives the whole material; purely additive -- two texture regions, the frame itself untouched, which keeps it safe on Blizzard secure buttons.
-- Weave uses ADD blend (same as Andromeda's BackdropStripes): on a black 0.25 well it adds a faint cloth brightening instead of covering; the vertex alpha (default 0.25) is the strength.
--   opts.weaveAlpha / opts.alpha  strength of weave / sheen (defaults 0.25 / 0 -- the通透 style: no white wash, faint cloth only);  opts.r,g,b tint;  opts.weaveLayer,Sublevel / layer,Sublevel draw layers (BACKGROUND/2, OVERLAY/1)
function Widget:ButtonMaterial(frame, opts)
    if Marked(frame, "material") then return Marked(frame, "material") end
    opts = opts or {}

    local weave = frame:CreateTexture(nil, opts.weaveLayer or "BACKGROUND", nil, opts.weaveSublevel or 2)
    -- Same fine 45° hatch as the bar ground, tiled 1 texel = 1 physical pixel: a 28px
    -- button shows 28x28 texels of the 64px tile, so two neighbouring buttons continue
    -- the same hatch instead of each squeezing a whole tile into its own square.
    weave:SetTexture(Media.texture["monet_stripe_weave"], "REPEAT", "REPEAT")
    weave:SetAllPoints(frame)
    -- ADD blend (Andromeda style): the hatch brightens the black well instead of painting over it,
    -- so a low vertex alpha reads as faint cloth grain rather than a grey wash.
    weave:SetBlendMode("ADD")
    local function FitWeave()
        local mult = Media:Mult()
        local fw = frame:GetWidth() or 0
        local fh = frame:GetHeight() or 0
        weave:SetTexCoord(0, math.max(0, fw / (mult * WEAVE_SIZE)),
            0, math.max(0, fh / (mult * WEAVE_SIZE)))
    end
    FitWeave()
    -- Action buttons are created at Blizzard's template size and resized to the user's
    -- buttonSize later; re-fit so the hatch stays 1:1 at the final size.
    --
    -- **只有我们自己的框才挂 OnSizeChanged**：ButtonMaterial 也会套到**暴雪的受保护按钮**上
    -- （收养的宠物条 / 姿态条），给它们写脚本槽等于把它们标脏，之后暴雪自己的
    -- SetShown / 冷却刷新都会被判成"以 MonetUI 的名义执行"（AGENTS 的污染模型）。
    -- 暴雪那一侧改用轮询比对尺寸：变了再 re-fit，同样保持 1:1。
    local fname = frame.GetName and frame:GetName()
    if type(frame.HookScript) == "function" and fname and fname:find("^MonetUI") then
        frame:HookScript("OnSizeChanged", FitWeave) -- TAINT-OK: 名字门控，只挂我们自己的框
    else
        local lastW, lastH
        Widget:PollWatch(frame, function()
            -- 用闭包里的 frame（不用 self:）：test-skin-lua 会把 Widget.lua 里的 self:X
            -- 当成 Widget 自己的方法去校验，而 GetWidth 是框体方法。
            local w, h = frame:GetWidth(), frame:GetHeight()
            if w ~= lastW or h ~= lastH then
                lastW, lastH = w, h
                FitWeave()
            end
        end, 0.5)
    end
    weave:SetVertexColor(opts.r or 1, opts.g or 1, opts.b or 1, opts.weaveAlpha or 0.25)

    local sheen = frame:CreateTexture(nil, opts.layer or "OVERLAY", nil, opts.sublevel or 1)
    sheen:SetTexture(Media.texture["monet_barfill"])
    sheen:SetAllPoints(frame)
    sheen:SetBlendMode("ADD")
    -- The sheen is a flat base colour too; the top-lit look comes from this gradient, not from the art.
    -- Under ADD a dark end simply stops adding, so the button reads lit from above and neutral below.
    Widget:TopLight(sheen)
    sheen:SetVertexColor(opts.r or 1, opts.g or 1, opts.b or 1, opts.alpha or 0)

    Mark(frame, "material", { weave = weave, sheen = sheen })
    return Marked(frame, "material")
end

--- Soft drop shadow around a frame: four gradient strips reaching outward from the frame edge (opaque where they touch the frame, fading to nothing at the far side), tinted from the Monet ambient tone so it reads as a cool painted grey-blue.
-- Pure SetGradient geometry -- no texture ships for it and the fade direction is explicit per side, which a single edgeFile texture cannot guarantee (the Andromeda equivalent is one self-drawn ui-shadow-outline used as an edgeFile).
--   opts.size   reach, in physical pixels (default 6);  opts.alpha  opacity at the frame edge (default 0.55)
function Widget:Shadow(frame, opts)
    if not frame then return nil end
    if Marked(frame, "shadow") then return Marked(frame, "shadow") end
    opts = opts or {}

    -- The shadow sits one level below the frame; a level-0 frame would tie with its own child, so lift the frame first.
    if frame.GetFrameLevel and frame:GetFrameLevel() < 1 then
        frame:SetFrameLevel(1)
    end

    local reach = (opts.size or 6) * Media:Mult()
    local a = opts.alpha or 0.55
    local ar, ag, ab = Color:GetAmbient()
    local r, g, b = ar * 0.3, ag * 0.3, ab * 0.3

    local sh = CreateFrame("Frame", nil, frame)
    sh:SetFrameLevel(frame:GetFrameLevel() - 1)
    sh:SetAllPoints(frame)
    pcall(sh.EnableMouse, sh, false)
    Mark(frame, "shadow", sh)

    local function MakeColor(rr, gg, bb, aa)
        if type(CreateColor) == "function" then return CreateColor(rr, gg, bb, aa) end
        return { GetRGBA = function() return rr, gg, bb, aa end }
    end
    local far  = MakeColor(r, g, b, 0)
    local near = MakeColor(r, g, b, a)

    local okAll = false
    -- Two anchors fix the strip's span, SetHeight/SetWidth fix its reach; every strip is oriented so the opaque end lands against the frame.
    local function Strip(orient, minC, maxC, ...)
        local tex = sh:CreateTexture(nil, "ARTWORK")
        tex:ClearAllPoints()
        tex:SetPoint(...)
        local ok = false
        if type(CreateColor) == "function" then
            ok = pcall(tex.SetGradient, tex, orient, minC, maxC)
        end
        if not ok then
            local r1, g1, b1, a1 = minC:GetRGBA()
            local r2, g2, b2, a2 = maxC:GetRGBA()
            ok = pcall(tex.SetGradient, tex, orient, r1, g1, b1, a1, r2, g2, b2, a2)
        end
        if ok then okAll = true else tex:Hide() end
        return tex
    end

    -- SetGradient puts minColor at the BOTTOM for VERTICAL and at the LEFT for HORIZONTAL.  So the
    -- argument order depends on which end of the strip touches the frame, and the four strips do NOT
    -- pair up the way it looks like they should:
    --   top / bot are VERTICAL, anchored at the frame's top / bottom edge.  For top that edge is the
    --   strip's BOTTOM (opaque end must be minC); for bot it is the strip's TOP (opaque end must be
    --   maxC).  lef / rig are HORIZONTAL: for lef the frame edge is the RIGHT end (maxC), for rig the
    --   LEFT end (minC).  Passing them the other way round fades the shadow from nothing at the window
    --   edge to 0.55 alpha out in open space -- a halo instead of a contact shadow.
    local top = Strip("VERTICAL", near, far,
        "TOPLEFT", sh, "TOPLEFT", 0, reach,
        "TOPRIGHT", sh, "TOPRIGHT", 0, reach)
    top:SetHeight(reach)

    local bot = Strip("VERTICAL", far, near,
        "BOTTOMLEFT", sh, "BOTTOMLEFT", 0, -reach,
        "BOTTOMRIGHT", sh, "BOTTOMRIGHT", 0, -reach)
    bot:SetHeight(reach)

    local lef = Strip("HORIZONTAL", far, near,
        "TOPLEFT", sh, "TOPLEFT", -reach, 0,
        "BOTTOMLEFT", sh, "BOTTOMLEFT", -reach, 0)
    lef:SetWidth(reach)

    local rig = Strip("HORIZONTAL", near, far,
        "TOPRIGHT", sh, "TOPRIGHT", reach, 0,
        "BOTTOMRIGHT", sh, "BOTTOMRIGHT", reach, 0)
    rig:SetWidth(reach)

    if not okAll then
        sh:Hide()
        Mark(frame, "shadow", nil)
        return nil
    end
    return sh
end

-- 像素环：一串小方块沿着框体的边缘跑。
-- 暴雪的宠物条用一圈旋转的"蚂蚁"（按钮的 AutoCastOverlay.Shine）提示自动施法；这个环把它替掉。
-- 全部是几何 + 纯色方块，不带贴图：颜色由主题给，粗细按物理像素算（任何 UI 缩放下都是同一个粗细）。
local pixelGlows = setmetatable({}, { __mode = "k" })

--- 沿正方形边框走一圈：d 是从左上角起、顺时针量出的边长距离，返回相对中心的 x / y。
local function SquarePoint(side, d)
    local half = side / 2
    if d < side then return -half + d, half end
    if d < side * 2 then return half, half - (d - side) end
    if d < side * 3 then return half - (d - side * 2), -half end
    return -half, -half + (d - side * 3)
end

--- 把一串方块摆到环上。
-- 动画环：头像素在前，尾巴依次往后（沿着跑动的反方向排），整串沿边框跑。
-- 静态环：方块等距铺满一圈，不动（自绘动作条关掉时的样子）。
local function LayoutPixelGlow(st)
    local side = st.side
    if not side or side <= 0 then return end
    local perimeter = side * 4
    local count = st.count
    for i = 1, count do
        local tex = st.tex[i]
        if tex then
            local d, alpha
            if st.static then
                d = (i - 1) * (st.step or 0)
                alpha = st.ringAlpha
            else
                -- 尾巴在头后面，所以距离是减的；取模把尾巴绕回环的另一头，不然它会跑到框外面去。
                d = (st.phase * perimeter - (i - 1) * st.spacing) % perimeter
                -- 尾巴比头淡：一串方块里最前的那颗最亮。
                local t = count > 1 and (i - 1) / (count - 1) or 0
                alpha = st.headAlpha + (st.alpha - st.headAlpha) * t
            end
            local x, y = SquarePoint(side, d)
            tex:ClearAllPoints()
            tex:SetPoint("CENTER", st.frame, "CENTER", x, y)
            tex:SetVertexColor(st.r, st.g, st.b, alpha)
        end
    end
end

-- 一个驱动跑所有动画环：环自己在转，驱动只在有动画环的时候醒着（静态环铺一次就不再吃每帧开销）。
local animatedGlows = 0
local pixelGlowDriver = CreateFrame("Frame")
pixelGlowDriver:Hide()
pixelGlowDriver:SetScript("OnUpdate", function(self, elapsed)
    for frame, st in pairs(pixelGlows) do
        if not st.static then
            if not frame:IsShown() then
                -- 框体藏了（宠物条收起来、条被换页）：收摊，等下次点亮再重新开始
                Widget:StopPixelGlow(frame)
            else
                st.phase = (st.phase + elapsed / st.period) % 1
                LayoutPixelGlow(st)
            end
        end
    end
    if animatedGlows <= 0 then
        animatedGlows = 0
        self:Hide()
    end
end)

--- 上色：调用方给了颜色就用给定的，否则取主题的 highlight 槽。
function Widget:RefreshPixelGlow(frame)
    local st = pixelGlows[frame]
    if not st then return end
    local opts = st.opts or {}
    local r, g, b = opts.r, opts.g, opts.b
    if not r then r, g, b = Color:GetHighlight() end
    st.r, st.g, st.b = r, g, b
    LayoutPixelGlow(st)
end

--- 开启（或更新）一个框体的像素环。环画在框体自己的 ARTWORK 层：图标之上，按键提示之下。
--   opts.side     环的边长，单位是框体自己的单位（默认取框体宽度）
--   opts.scale    框体父链上的缩放：物理像素要靠它换算成框体单位
--   opts.static   true = 静态环（等距铺满一圈、不动），默认是沿边框跑的动画环
--   opts.pixel    一颗方块几物理像素（默认 2）；  opts.spacing  方块之间几物理像素（默认 3）
--   opts.count    动画环几颗方块（默认 7）；  opts.period  跑一圈几秒（默认 3.5）
--   opts.pitch    静态环的点距，物理像素（默认 4）；  opts.ringAlpha  静态环的透明度（默认 0.85）
--   opts.alpha    尾巴的透明度（默认 0.2）；  opts.headAlpha  头部的透明度（默认 1）
--   opts.r,g,b    颜色（默认取主题的 highlight 槽）
function Widget:PixelGlow(frame, opts)
    if not frame then return end
    opts = opts or {}

    local st = pixelGlows[frame]
    if not st then
        st = { tex = {}, phase = 0 }
        pixelGlows[frame] = st
        st.frame = frame
    end

    st.opts = opts
    st.period = opts.period or 3.5
    st.alpha = opts.alpha or 0.2
    st.headAlpha = opts.headAlpha or 1

    -- 物理像素 -> 框体单位：被缩放过的条里，框体自己的单位比 UIParent 的单位大 scale 倍。
    local scale = opts.scale or 1
    local mult = Media:Mult()
    local pixel = (opts.pixel or 2) * mult / scale
    st.spacing = (opts.spacing or 3) * mult / scale
    st.side = opts.side or frame:GetWidth() or 0

    -- 静态环 / 动画环切换：驱动只跟动画环，切一次就改一次计数，免得白跑每帧。
    local wasAnimated = st.animated or false
    st.static = opts.static and true or false
    st.animated = not st.static
    if st.animated ~= wasAnimated then
        animatedGlows = animatedGlows + (st.animated and 1 or -1)
    end

    if st.static then
        -- 等距铺满一圈：点距是物理像素，点数按周长推，余数摊平（step 按实际点数重算，首尾不会撞在一起）。
        local pitch = (opts.pitch or 4) * mult / scale
        local perimeter = st.side * 4
        if pitch <= 0 then pitch = 1 end
        st.count = math.max(4, math.floor(perimeter / pitch))
        st.step = perimeter / st.count
        st.ringAlpha = opts.ringAlpha or 0.85
    else
        st.count = opts.count or 7
        st.step = nil
    end

    for i = 1, st.count do
        local tex = st.tex[i]
        if not tex then
            tex = frame:CreateTexture(nil, "ARTWORK")
            tex:SetTexture(Media.texture.blank)
            tex:SetBlendMode("ADD")
            st.tex[i] = tex
        end
        tex:SetSize(pixel, pixel)
        tex:Show()
    end
    for i = st.count + 1, #st.tex do
        st.tex[i]:Hide()
    end

    -- 主题变了要重新上色：登记进 themed，RefreshThemes 会回来刷。
    local entry = themed[frame]
    if not entry or entry.kind ~= "pixelglow" then
        themed[frame] = { kind = "pixelglow" }
    end

    Widget:RefreshPixelGlow(frame)
    if st.animated then pixelGlowDriver:Show() end
end

--- 停掉像素环：方块藏起来，登记也撤掉。
function Widget:StopPixelGlow(frame)
    local st = pixelGlows[frame]
    if not st then return end
    pixelGlows[frame] = nil
    local entry = themed[frame]
    if entry and entry.kind == "pixelglow" then themed[frame] = nil end
    for i = 1, #st.tex do
        local tex = st.tex[i]
        if tex then tex:Hide() end
    end
    if st.animated then
        animatedGlows = animatedGlows - 1
        if animatedGlows <= 0 then
            animatedGlows = 0
            pixelGlowDriver:Hide()
        end
    end
end

--- An oil-painted brush underline (monet_brush_stroke) beneath `anchor` -- our version of Andromeda's gradient hairline.
-- The art carries its own colours (cream core / ochre rim / dark dry edge, five tones in all), so it is only faded, never re-tinted.
-- The texture is stretched between the two anchors and squeezed to `height`, and the art is drawn for exactly that:
-- there is no thickness taper (a taper would stretch into a long spike) and every variation along the length is an
-- integer number of periods, so the stroke stays a stroke at any width.
--   opts.gap  distance below the anchor, physical px (default 3);  opts.height  stroke height, physical px (default 9);  opts.alpha  (default 0.9)
function Widget:Rule(frame, anchor, opts)
    if not frame or not anchor then return nil end
    if Marked(frame, "rule") then return Marked(frame, "rule") end
    opts = opts or {}
    local gap = (opts.gap or 3) * Media:Mult()
    local tex = frame:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(Media.texture["monet_brush_stroke"])
    tex:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -gap)
    tex:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -gap)
    tex:SetHeight((opts.height or 9) * Media:Mult())
    tex:SetVertexColor(1, 1, 1, opts.alpha or 0.9)
    Mark(frame, "rule", tex)
    return tex
end

--- A plain 1px rule (monet_hairline) stretched between two points -- the quiet sibling of Widget:Rule,
-- which draws the hand-painted brush underline.  Same "texture carries no direction" trick: the 256x1 art
-- is one opaque row, so it only reads as a hairline while the widget stays 1px tall; give it height and it
-- becomes a separator band, which is usually what you want anyway.
--   opts.alpha (default 0.55);  opts.anchor  anchor point pair, default TOPLEFT/TOPRIGHT
function Widget:Hairline(frame, anchor, opts)
    if not frame or not anchor then return nil end
    if Marked(frame, "hairline") then return Marked(frame, "hairline") end
    opts = opts or {}
    local tex = frame:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(Media.texture["monet_hairline"])
    tex:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(opts.gap or 1))
    tex:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -(opts.gap or 1))
    tex:SetHeight(Media:SnapUnit(1))
    -- A hairline is the one place where texel snapping is unambiguously right: the image is a single
    -- opaque row, so any sub-texel placement is pure blur.  Both setters are call:ok on this client.
    -- (Animated fills want the opposite -- snapping makes a growing bar jump a pixel at a time --
    -- which is why this is set per texture and not globally.)
    if tex.SetSnapToPixelGrid then pcall(tex.SetSnapToPixelGrid, tex, true) end
    if tex.SetTexelSnappingBias then pcall(tex.SetTexelSnappingBias, tex, 0) end
    local r, g, b = Color:GetEdge()
    tex:SetVertexColor(r, g, b, opts.alpha or 0.55)
    -- Deliberately NOT Skin:Track()ed.  A hairline is drawn on one of our own frames, so there is no
    -- Blizzard art to roll back; on Skin's undo list it would only make the Skins toggle hide our own
    -- separators.  This used to call self:Track() -- but Track lives on Skin, not Widget, so every
    -- call raised "attempt to call method 'Track' (a nil value)".
    Mark(frame, "hairline", tex)
    return tex
end

--- Four brush ornaments on the frame corners (monet_corner), a small flourish Andromeda has no equivalent for -- its only chrome decoration is a gradient hairline.
-- The ornament lives on a child frame raised above the content level, so a window's own buttons can never bury the corners; it keeps the asset's painted two-tone (tinted only for opacity).
--   opts.size  edge length, physical px (default 16);  opts.alpha  (default 0.9);  opts.omit  corner names left bare, e.g. { "TOPRIGHT" } when a close button owns it
function Widget:Corners(frame, opts)
    if not frame then return nil end
    if Marked(frame, "corners") then return Marked(frame, "corners") end
    opts = opts or {}

    local omit = {}
    for _, name in ipairs(opts.omit or {}) do omit[name] = true end

    local orn = CreateFrame("Frame", nil, frame)
    orn:SetFrameLevel(frame:GetFrameLevel() + 10)
    orn:SetAllPoints(frame)
    pcall(orn.EnableMouse, orn, false)
    Mark(frame, "ornament", orn)

    local size = (opts.size or 16) * Media:Mult()
    local r, g, b = Color:GetEdge()
    local a = opts.alpha or 0.9
    local path = Media.texture["monet_corner"]

    -- The asset is the top-left arc; the other three are mirror images.
    local defs = {
        { "TOPLEFT",     nil, nil },
        { "TOPRIGHT",    true, nil },
        { "BOTTOMLEFT",  nil, true },
        { "BOTTOMRIGHT", true, true },
    }
    local list = {}
    for _, d in ipairs(defs) do
        if not omit[d[1]] then
            local tex = orn:CreateTexture(nil, "ARTWORK")
            tex:SetTexture(path)
            tex:SetPoint(d[1], orn, d[1], 0, 0)
            tex:SetSize(Media:SnapUnit(size), Media:SnapUnit(size))
            if d[2] and d[3] then
                tex:SetTexCoord(1, 0, 1, 0)
            elseif d[2] then
                tex:SetTexCoord(1, 0, 0, 1)
            elseif d[3] then
                tex:SetTexCoord(0, 1, 1, 0)
            end
            tex:SetVertexColor(r, g, b, a)
            list[#list + 1] = tex
        end
    end
    Mark(frame, "corners", list)
    return list
end

--- Themed, safe tooltip helper (GameTooltip methods are guarded).
function Widget:UnitTooltip(frame, unit)
    local GameTooltip = _G.GameTooltip
    if not GameTooltip then return frame end

    frame:SetScript("OnEnter", function(self)
        pcall(GameTooltip.SetOwner, GameTooltip, self, "ANCHOR_RIGHT")
        pcall(GameTooltip.SetUnit, GameTooltip, unit)
        pcall(GameTooltip.Show, GameTooltip)
    end)
    frame:SetScript("OnLeave", function()
        pcall(GameTooltip.Hide, GameTooltip)
    end)
    frame:EnableMouse(true)
    return frame
end

-- Re-tint automatically whenever the theme changes.
EventBus:Register("MONETUI_THEME_CHANGED", function()
    Widget:RefreshThemes()
end)
