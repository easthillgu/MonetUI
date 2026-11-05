-- Utils/Skin.lua
-- Blizzard-panel skinning primitives (the addon's private skin toolkit): fade the original art, hang a Monet backplate / border under the frame, restyle the controls so a vanilla window matches the rest of MonetUI.
-- Two rules run through everything here: defensive (a client that lacks a frame, a method or a template simply skips that step; nothing raises) and reversible (every mutation of a Blizzard object is recorded, so Skin:Rollback() puts the original back; objects we add ourselves are merely hidden).
-- Nothing here ever calls SetScript / SetParent / SetShown / Hide on a Blizzard frame -- a skin only fades art and adds its own child frames, which keeps the addon taint-free on protected UI and leaves Edit Mode layouts intact.  All hover handling is polled (Widget:HoverWatch / PollWatch) -- writing a script or method slot on a Blizzard frame is what taints it.

local ADDON_NAME, ns = ...


-- 旁表标记：**绝不往暴雪的框体 / 贴图 / 字体串上写字段**。
-- 本客户端把“插件写过字段的对象”判成脏的（实机：issecurevariable 在 NamePlate1UnitFrame 上唯一为 false 的键就是我们的
-- 标记，随后暴雪自己的 OnUpdate 就报 secret value / anchor family），所以标记一律走
-- Core.lua 的 ns:Mark / ns:Marked（以对象为弱键的旁表）。
local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end

local Color    = ns.Color
local Media    = ns.Media
local Widget   = ns.Widget
local EventBus = ns.EventBus

local Skin = {}
ns.Skin = Skin

Skin.undo      = {}    -- ordered list of restore closures
Skin.recording = false

--- Record a closure that undoes one mutation (only while recording).
function Skin:Record(restore)
    if self.recording and type(restore) == "function" then
        self.undo[#self.undo + 1] = restore
    end
end

function Skin:BeginRecord()
    self.undo = {}
    self.recording = true
end

--- Replay every recorded undo, newest first, then stop recording.
function Skin:Rollback()
    for i = #self.undo, 1, -1 do
        pcall(self.undo[i])
    end
    self.undo = {}
    self.recording = false
end

-- Frames/textures we created: hidden on rollback, shown again on re-apply -- the skin code caches them on the Blizzard frame, so they are built once and merely toggled.
Skin.added = {}

-- Only while recording: things built for a Blizzard window belong to the skin and hide with it, while helpers called for the addon's own frames (the config panel) must not join that rollback list.
function Skin:Track(frame)
    if frame and self.recording then
        self.added[#self.added + 1] = frame
    end
    return frame
end

function Skin:ShowAdded()
    for i = 1, #self.added do
        local frame = self.added[i]
        if frame and frame.SetShown then pcall(frame.SetShown, frame, true) end
    end
end

function Skin:HideAdded()
    for i = 1, #self.added do
        local frame = self.added[i]
        if frame and frame.SetShown then pcall(frame.SetShown, frame, false) end
    end
end

-- Colour changes the Widget theme registration cannot see (a Blizzard texture we recoloured, a thumb we drew ourselves): panels push a refresh closure and the Skins module runs them whenever the theme changes.
Skin.tinters = {}

function Skin:OnTheme(fn)
    if type(fn) == "function" then
        self.tinters[#self.tinters + 1] = fn
    end
    return fn
end

function Skin:RefreshThemes()
    for i = 1, #self.tinters do
        pcall(self.tinters[i])
    end
end

EventBus:Register("MONETUI_THEME_CHANGED", function()
    Skin:RefreshThemes()
end)

-- ---------------------------------------------------------------------------
-- 美化对象确认（AGENTS：帧名 / 对象名永不凭记忆，也不照抄参考插件）
--
-- 皮肤层每一次"找一个暴雪对象"都走 `Skin:Need`：解析和记账是同一次动作。账本记的是
-- **实际发生过的查找**，所以诊断报的是这台客户端真实缺什么，而不是我们手写名单的期望值 ——
-- 名字写错的地方从"静默跳过"变成"一行 ✗"。面板关掉 / LoD 没加载时一次查找都没发生，
-- 那种情况由调用方退回声明名单（见 Skins:Diagnose）。
--
-- 只存字符串和计数，**不存对象引用**：暴雪随时可能换掉一个框（LoD 重载、编辑模式重建），
-- 缓存住旧对象就是"美化没生效"的那种 bug。
-- ---------------------------------------------------------------------------

Skin.targets = {}   -- [scope] = { [path] = { hits = n, misses = n } }
Skin.scope  = nil   -- 当前作用域（一张面板 / 一个模块），没有就记在 "_" 名下

--- 某作用域某条路径的账本行（没有就建）。
function Skin:Ledger(scope, path)
    local byPath = self.targets[scope]
    if not byPath then
        byPath = {}
        self.targets[scope] = byPath
    end
    local led = byPath[path]
    if not led then
        led = { hits = 0, misses = 0 }
        byPath[path] = led
    end
    return led
end

--- 在 scope 名下跑 fn，fn 里的 Need 全部记到它那里。
--- 出错时原样把错误抛回调用方（谁 pcall 谁负责报，这里不吞信息）。
function Skin.With(scope, fn, ...)
    if type(fn) ~= "function" then return nil end
    local outer = Skin.scope
    Skin.scope = scope
    local ok, a, b = pcall(fn, ...)
    Skin.scope = outer
    if not ok then error(a, 0) end
    return a, b
end

--- 取回来的东西是不是"能挂子件、能读区域"的 ScriptObject。
--- `Skin:Need` 按名字解析，**命中的不一定是框体**：老窗口名在本客户端可能已经变成一张表
--- 或一个函数（2026-10-30 实机 12.1.5：11 个面板整批 Apply 失败，报的就是
--- `Usage: CreateFrame("frameType" ...)` —— 那东西被当成 parent 交给了 CreateFrame）。
--- 判定用 GetObjectType 而不是 type()：本客户端的框体是带元表的用户数据。
function Skin:IsScriptObject(obj)
    if obj == nil then return false end
    if type(obj) ~= "table" and type(obj) ~= "userdata" then return false end
    if type(obj.GetObjectType) ~= "function" then return false end
    local ok, kind = pcall(obj.GetObjectType, obj)
    return ok and kind ~= nil
end

--- 一次性提示（同一 topic 只打一次）：Apply 会被三个事件反复触发，不打一次就是几十条同文案。
local warned = {}
-- 提示历史（供 `/mui report` 打包）：`warned` 只有"打没打过"的布尔，出事时最需要的
-- 是"这一趟到底提示过哪几条"——聊天框早就滚掉了，SavedVariables 里又没有。
-- 有界环：12 条封顶（再多也没人读），只存字符串，不存对象引用。
local warnRing, WARN_RING_MAX = {}, 12
local function rememberWarn(topic, message)
    warnRing[#warnRing + 1] = { topic = topic, message = message }
    if #warnRing > WARN_RING_MAX then table.remove(warnRing, 1) end
end

--- 本会话打过的所有一次性提示（副本，调用方随便读；`/mui report` 用它）。
function Skin:WarnRing()
    local out = {}
    for i = 1, #warnRing do out[i] = { topic = warnRing[i].topic, message = warnRing[i].message } end
    return out
end

function Skin:WarnOnce(topic, message)
    if warned[topic] then return end
    warned[topic] = true
    rememberWarn(topic, message)
    ns:Print(message)
end

--- 确认并取回一个美化对象：`"CharacterFrame"`，或 `"Minimap.Buttons.DragonkinComp"` 这样的点路径。
--- 取不到就记一次 miss 并返回 nil —— 调用方照旧"缺了就跳过那一步"，但缺什么从此可查。
function Skin:Need(path)
    local obj = ns.ResolveObject(path)
    local led = self:Ledger(Skin.scope or "_", path)
    if obj == nil then
        led.misses = led.misses + 1
        return nil
    end
    led.hits = led.hits + 1
    -- "命中了，但不是框体"是第三种结果：只在第一次判，之后复用账本里的值（每个 Apply 都要跑几百次）
    -- 顺手记下它**到底是什么**：账本里只写"不是框体"，读的人分不清"我们本来就在探一个函数"
    -- 和"这个真名其实是个 Mixin 表、框体另有其名"（实机三种都出现过）。
    if led.shape == nil then
        if not self:IsScriptObject(obj) then
            local kind = type(obj)
            if kind == "table" and type(obj.GetName) == "function" and type(obj.GetObjectType) == "function" then
                kind = "Mixin 表"
            end
            led.shape = "notObject:" .. kind
        else
            led.shape = "frame"
        end
    end
    return obj
end

--- 把"对象 / 对象名 / 它们的列表"统一成列表，名字一律过 Need。
--- 皮肤文件里那种"同一个窗口名在两个表里各写一遍"的写法因此可以退休。
function Skin:AsList(spec)
    if spec == nil then return {} end
    if type(spec) == "string" then return { self:Need(spec) } end
    if type(spec) == "table" then
        if spec[1] ~= nil then
            -- 逐个解析后**紧凑追加**：取不到的名字直接不进列表。
            -- 按原下标写会留下空洞，而 Lua 的 `#` 遇到空洞可能截断 —— 名单第一个名字
            -- 写错就会把后面所有正确的控件一起丢掉，那比少画一个还难查。
            local out = {}
            for i = 1, #spec do
                local item = spec[i]
                local obj = type(item) == "string" and self:Need(item) or item
                if obj then out[#out + 1] = obj end
            end
            return out
        end
        return { spec }     -- 单个对象（框体在 Lua 眼里就是 table）
    end
    return {}
end

--- 这个作用域跑过查找吗？（诊断用它决定是读账本还是退回声明名单）
function Skin:HasScope(scope)
    local byPath = self.targets[scope]
    if not byPath then return false end
    for _, led in pairs(byPath) do
        if led.hits > 0 or led.misses > 0 then return true end
    end
    return false
end

--- 打印一个作用域的账本行，返回（存在数, 缺失数）。路径是我们自己写的字符串，进 concat 安全。
--- 缺失名单**分行打**：`print` 一行只吃 255 字符，把 26 个名字塞在一行里会被截掉尾巴，
--- 看上去就像"那个名字根本不存在"，而真正的原因是打印。
--- 账本里的"命中但不是框体"标记：`Skin:Need` 写成 `notObject:<类型>`（函数 / 表 / Mixin 表）。
--- 按前缀认，兼容只写了 "notObject" 的旧记录。
local function OddShape(led)
    return type(led.shape) == "string" and led.shape:find("^notObject") ~= nil
end

--- 报名字时带上它到底是什么：`UpdateMicroButtons（函数）` 一眼就知道是"我们本来在探一个函数"，
--- `TradePlayerInputMoneyFrame（Mixin 表）` 才是"真名写错了、框体另有其名"。
local function OddLabel(path, led)
    local kind = type(led.shape) == "string" and led.shape:match("^notObject:(.+)$") or nil
    if not kind then return path end
    if kind == "function" then kind = "函数"
    elseif kind == "table" then kind = "表" end
    return ("%s（%s）"):format(path, kind)
end

function Skin:ReportScope(scope)
    local byPath = self.targets[scope]
    if not byPath then return 0, 0 end
    local missing, found, odd = {}, 0, {}
    for path, led in pairs(byPath) do
        if led.hits > 0 then
            found = found + 1
            -- 命中了但拿回来的不是框体：这一类不会 miss，却会让 CreateFrame / GetRegions 抛，
            -- 必须单独列出来，否则 diagnose 只报"全绿"而实机一片红字。
            if OddShape(led) then odd[#odd + 1] = OddLabel(path, led) end
        else
            missing[#missing + 1] = path
        end
    end
    if found == 0 and #missing == 0 then return 0, 0 end
    if #missing == 0 then
        ns:Print(("|cffffb75c⚠|r [%s] %d 个对象存在，其中 %d 个不是框体"):format(scope, found, #odd))
    else
        table.sort(missing)
        -- 「缺失」是**两种原因的合计数**，别当缺陷数读：① 本客户端确实没这个名字（要改名或摘掉）
        -- ② 那个窗属 LoD 包 / 还没被造出来（开窗之后重跑本命令就会变成"存在"）。
        -- 11-04 实机判例：登录当拍 "225 存在 / 227 缺失" 里，离线对撞 1.60 FrameXML 后有名字能
        -- 对上的占一半以上 —— 把这条口径写在这儿，免得下一位拿着总数去"改 227 个名字"。
        ns:Print(("|cffff6b6b✗|r [%s] %d 存在 / %d 缺失（缺失 = 没这名字 **或** LoD/未出生，开窗后重跑再看）")
            :format(scope, found, #missing))
        local LINE_MAX = 200
        local chunk, count = "", 0
        for i = 1, #missing do
            local piece = (count > 0) and (", " .. missing[i]) or missing[i]
            if #chunk + #piece > LINE_MAX then
                ns:Print("    " .. chunk)
                chunk, count = missing[i], 1
            else
                chunk = chunk .. piece
                count = count + 1
            end
        end
        if chunk ~= "" then ns:Print("    " .. chunk) end
    end
    if #odd > 0 then
        table.sort(odd)
        ns:Print(("    |cffffb75c命中但不是框体|r：%s"):format(table.concat(odd, ", ")))
    end
    return found, #missing
end

--- 只看"命中但不是框体"这一类（`/mui skins diagnose bad`）。
--- 全量 diagnose 有几百行，聊天框只留最后十几行 —— 恰恰是这一类会被顶掉，等于白报。
function Skin:ReportBad()
    local scopes = {}
    for key in pairs(self.targets) do scopes[#scopes + 1] = key end
    table.sort(scopes)
    local n = 0
    for _, scope in ipairs(scopes) do
        local odd = {}
        for path, led in pairs(self.targets[scope]) do
            if led.hits > 0 and OddShape(led) then odd[#odd + 1] = OddLabel(path, led) end
        end
        if #odd > 0 then
            n = n + #odd
            table.sort(odd)
            ns:Print(("|cffffb75c⚠|r [%s] %s"):format(scope, table.concat(odd, ", ")))
        end
    end
    if n == 0 then ns:Print("（没有）：命中的对象全都能当框体用。") end
    return n
end

--- 打印所有作用域的账本，返回（存在数, 缺失数）。
function Skin:Report(header)
    if header then ns:Print(header) end

    local scopes = {}
    for key in pairs(self.targets) do scopes[#scopes + 1] = key end
    table.sort(scopes)

    local totalFound, totalMissing = 0, 0
    for _, scope in ipairs(scopes) do
        local found, missing = self:ReportScope(scope)
        totalFound = totalFound + found
        totalMissing = totalMissing + missing
    end
    if #scopes == 0 then
        ns:Print("|cff808080账本为空|r：还没有任何美化真正跑过（模块关闭？LoD 未加载？）。")
    end
    return totalFound, totalMissing
end

--- 非皮肤模块也用同一本账：把"这个模块假设存在的名字"（API 函数或暴雪对象）逐条确认、
--- 记在 scope 名下，然后打印这个作用域。这样 `/mui skins diagnose` 一处就能看全仓库的
--- 名字可达性，各模块不必再各自抄一份 ✓/✗ 打印循环。
-- @return 存在数, 缺失数
function Skin:Verify(scope, names, header)
    if header then ns:Print(header) end
    Skin.With(scope, function()
        for i = 1, #names do Skin:Need(names[i]) end
    end)
    return self:ReportScope(scope)
end

local function IsTexture(region)
    return region and type(region.IsObjectType) == "function" and region:IsObjectType("Texture")
end

--- The FontString of a button (Blizzard stores it in .Text or via GetFontString).
function Skin:GetText(button)
    if not button then return nil end
    local text = button.Text
    if not text and type(button.GetFontString) == "function" then
        text = button:GetFontString()
    end
    return text
end

--- Fade any region (texture) to invisible without moving it, remembering the old alpha.  Hidden once per region.
function Skin:Fade(region)
    if not region or type(region.SetAlpha) ~= "function" then return region end
    if Marked(region, "hidden") then return region end
    -- Our own art (Skin:SwapArt) is never faded: a later pass restyling the same control must not hide the glyph we just put on it.
    if Marked(region, "art") then return region end
    Mark(region, "hidden", true)

    local old = region.GetAlpha and region:GetAlpha() or 1
    self:Record(function()
        if region.SetAlpha then region:SetAlpha(old) end
        Mark(region, "hidden", nil)
    end)

    region:SetAlpha(0)
    return region
end

--- Fade a texture's four sprite edges / a whole button's art, whatever shape it has.
function Skin:FadeButtonArt(button)
    if not button then return end
    local getters = { "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture", "GetHighlightTexture" }
    for i = 1, #getters do
        local getter = button[getters[i]]
        if type(getter) == "function" then
            local tex = getter(button)
            if tex then self:Fade(tex) end
        end
    end
end

-- Named background pieces Blizzard keeps on its panels.
local BACKDROP_PIECES = {
    "NineSlice", "Bg", "Background", "Border", "BorderFrame", "Inset", "InsetFrame",
    "TopBorder", "BottomBorder", "LeftBorder", "RightBorder", "TitleBg", "TitleBG",
    "BgTop", "BgBottom", "BgLeft", "BgRight", "BG", "Backdrop",
}

--- Fade the original art of a frame.
-- @param opts { regions=false, backdrops=false, keep=function(region), keepTexture=tex, art=true } -- false / absent leaves that layer alone.
function Skin:Strip(frame, opts)
    if not frame or not self:IsScriptObject(frame) then return frame end
    opts = opts or {}

    -- 读暴雪框的字段 / 区域在受限对象上会被拒（2026-10-30 实机「trade」：
    -- `Attempt to access forbidden object from code tainted by an AddOn - Usage: self:GetRegions()`）。
    -- 这类框我们**读不到就别读**，让它保持暴雪原样 —— 少剥一层美术，比整面板 Apply 失败好得多。
    if opts.backdrops ~= false then
        pcall(function()
            for i = 1, #BACKDROP_PIECES do
                local piece = frame[BACKDROP_PIECES[i]]
                if piece and type(piece.SetAlpha) == "function" then
                    self:Fade(piece)
                end
            end
        end)
    end

    if opts.regions ~= false and type(frame.GetRegions) == "function" then
        local keep = opts.keep
        local ok, regions = pcall(function() return { frame:GetRegions() } end)
        if ok then
            for i = 1, #regions do
                local region = regions[i]
                if IsTexture(region) and region ~= opts.keepTexture then
                    if not (keep and keep(region)) then
                        self:Fade(region)
                    end
                end
            end
        end
    end

    -- 12.x 的 9-slice 边框（InsetFrameTemplate 等模板的 UI-Frame-Inner 系）是挂在
    -- frame.NineSlice 上的**独立 Frame 对象**，既不在 GetRegions 也不在 GetChildren
    -- 的常规枚举里（2026-11-02 MerchantMoneyInset 判例：树遍历三遍都看不见的金框）。
    -- 它整体压 α0 即整圈边框消失；走 Fade 通道记录原始值，回滚可用。
    if opts.nineSlice ~= false then
        local ns9 = frame.NineSlice
        if ns9 and type(ns9.SetAlpha) == "function" then
            self:Fade(ns9)
        end
    end

    if opts.art then
        self:FadeButtonArt(frame)
    end

    return frame
end

--- Restyle a FontString with one of the addon fonts and (optionally) a theme colour.  Records the old font so a rollback restores it.
function Skin:Font(fs, size, key, flags, colorKey)
    if not fs or type(fs.SetFont) ~= "function" then return fs end

    if not Marked(fs, "font") then
        Mark(fs, "font", true)
        local path, oldSize, oldFlags = fs:GetFont()
        if path then
            self:Record(function()
                if fs.SetFont then fs:SetFont(path, oldSize, oldFlags) end
                Mark(fs, "font", nil)
            end)
        end
    end

    -- Default flags come from Media.fontFlags ("OUTLINE, MONOCHROME"): 1px 描边 + 关抗锯齿。
    -- 暴雪字体对象也走这一条，所以全局统一字体时描边一致。
    pcall(Widget.SetFont, Widget, fs, size or 12, key or "pixel", flags)
    if colorKey then
        self:ColorText(fs, colorKey)
    end
    return fs
end

--- Recolour a FontString to a theme slot, remembering the old colour.
function Skin:ColorText(fs, colorKey)
    if not fs or type(fs.SetTextColor) ~= "function" then return fs end

    -- 走 Widget:PaletteColor 这唯一一份键表：以前这里用 Color:Get(key)，任何新键都会
    -- 静默落成 edge（Color:Get 的未知键回退），皮肤层的文字颜色和 Widget 层就对不上了。
    local r, g, b, a = Widget:PaletteColor(colorKey or "neutral")
    if not r then
        r, g, b, a = Color:GetNeutral()
    end

    if not Marked(fs, "color") then
        Mark(fs, "color", true)
        local oldR, oldG, oldB, oldA = fs:GetTextColor()
        local oldSR, oldSG, oldSB, oldSA
        if fs.GetShadowColor then oldSR, oldSG, oldSB, oldSA = fs:GetShadowColor() end
        self:Record(function()
            if fs.SetTextColor then fs:SetTextColor(oldR, oldG, oldB, oldA) end
            if oldSR and fs.SetShadowColor then fs:SetShadowColor(oldSR, oldSG, oldSB, oldSA) end
            Mark(fs, "color", nil)
        end)
    end

    fs:SetTextColor(r, g, b, a or 1)
    if fs.SetShadowColor then pcall(fs.SetShadowColor, fs, 0, 0, 0, 0) end
    return fs
end

--- 造一块挂底衬用的空框。三处都必须容忍"这版客户端不给"：
--- * parent 不是 ScriptObject（老窗口名现在是表 / 函数）→ 直接不造，返回 nil；
---   把它交给 CreateFrame 会抛 `Usage: CreateFrame(...)`，一个名字带走整面板。
--- * 模板不存在 → 退回不带模板的框，只是没有 SetBackdrop 可用（调用方各自判）。
local function NewBackdropFrame(parent, levelOffset)
    if not Skin:IsScriptObject(parent) then return nil end
    local ok, frame = pcall(CreateFrame, "Frame", nil, parent, "BackdropTemplate")
    if not ok or not frame then
        ok, frame = pcall(CreateFrame, "Frame", nil, parent)
    end
    if not ok or not frame then return nil end
    local level = (parent.GetFrameLevel and parent:GetFrameLevel() or 1) + (levelOffset or -1)
    pcall(frame.SetFrameLevel, frame, math.max(0, level))
    pcall(frame.EnableMouse, frame, false)
    return frame
end

--- A themed backplate behind a Blizzard frame.  Built once, cached on the frame.
--- `opts.host`（2026-11-02 MerchantFrame 判例）：把背板挂到**另一个框**（通常是窗口本体），
--- 锚点仍指 frame。为什么需要：这台客户端（70688 实测）对"嵌在中间层容器里、level 0 的子框"
--- 不渲染——背板挂在 Inset（lv1）下算出 level 0 就整块隐形；挂在窗口本体直下的 level 0 没问题，
--- 且与根窗大板同父同级、创建在后 → 按创建顺序稳压大板、稳被 level≥1 的内容压住。
--- 背板本体带 `skinPlate` 旁表标记，探针靠它认"我们的背板"（不再依赖"父框的 skinBg 指向它"）。
-- @param opts { thickness=, bgAlpha=, borderAlpha=, borderKey=, inset=, bgSurface=, host=, levelOffset= }
function Skin:Panel(frame, opts)
    if not frame or not self:IsScriptObject(frame) then return nil end
    opts = opts or {}

    local bg = Marked(frame, "skinBg")
    if not bg then
        bg = NewBackdropFrame(opts.host or frame, opts.levelOffset or -1)
        if not bg then return nil end
        local inset = opts.inset or 0
        pcall(bg.SetPoint, bg, "TOPLEFT", frame, "TOPLEFT", inset, -inset)
        pcall(bg.SetPoint, bg, "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
        Widget:Theme(bg, {
            thickness   = opts.thickness or 1,
            bgAlpha     = opts.bgAlpha or 0.85,
            borderAlpha = opts.borderAlpha,
            borderKey   = opts.borderKey,
            bgSurface   = opts.bgSurface,
        })
        Mark(bg, "skinPlate", true)
        Mark(frame, "skinBg", bg)
        self:Track(bg)
    end

    pcall(bg.Show, bg)
    return bg
end

--- 找出一个窗口"正文凹槽"那个子框：优先 `frame.Inset`（暴雪内容底板的通用字段），
--- 没有就退回同名全局 `<窗口名>Inset`。都读不到返回 nil。
--- **只认字段 / 同名全局这两条路，不猜别的帧名** —— 有没有这块由客户端自己决定，我们不记名字。
function Skin:FindInset(frame)
    if not frame then return nil end
    local ok, inset = pcall(function() return frame.Inset end)
    if ok and inset and Widget:Readable(inset) then return inset end
    if type(frame.GetName) == "function" then
        local okN, name = pcall(frame.GetName, frame)
        if okN and name then
            local g = rawget(_G, name .. "Inset")
            if g and Widget:Readable(g) then return g end
        end
    end
    return nil
end

--- 给一个窗口补"正文凹槽"那一档底色（insetFrame.bg），和窗口本身那档（frame.bg，调用方的
--- Skin:Panel 负责）拉开两层次：先剥掉暴雪 inset 自带的美术件（那圈浅底 + 原生边框 = "正文里
--- 漏出的浅框"），再挂**我们自己的**背板 —— 底色走 surface `lost`（比窗口那档 panel 亮一档），
--- 边框走和其它窗口同一套的主题边框（Skin:Panel 的 edgeFile=blank，不是暴雪原生 #4B493C）。
--- 全程只建我们自己的子背板 + ns:Mark 旁表，不写暴雪对象字段。
--- **没有 inset 的窗口直接返回 nil、什么都不画** —— 所以任何窗口都能安全地传 opts.inset = true。
--- **容器 alpha 必须亮回 1**（2026-11-02 实机 MerchantFrame 探针判例）：根窗的 Strip 会把
--- `frame["Inset"]` 当"背景件"整框 Fade 成 α0（BACKDROP_PIECES 含 "Inset"），而背板是这个
--- α0 容器的子框、继承父 alpha —— 不亮回来，凹槽层"已挂我们的背板"却游戏里看不见。
--- 容器里的暴雪美术件已被上面 Strip 逐件压掉（region + 名单内字段），容器亮回不会漏原美术；
--- 回滚不用另记 —— Fade 自己的 Record 存的是 Fade **之前**的原始 alpha。
--- （QuestFrame 的 inset 懒建、躲过了根窗 Strip，所以那一处此前看着是好的 —— 同一套修复对它无操作。）
-- @param opts { bgSurface = "lost", bgAlpha = 0.965, borderKey =, thickness = }
--- Resolve a named content region of a window: the `frame[suffix]` field first, then the
--- global `<frameName>..suffix`, then the **exact global name**（暴雪三种命名混用：
--- `CollectionsJournal.MountDisplay` 是字段；`TabardFrameMoneyBg` 带窗口前缀；
--- `TradeRecipientItemsInset` / `MerchantMoneyBg` 是不带前缀的独立全局名）。
--- 读不到返回 nil —— 调用方必须容忍 no-op（懒建窗口的区在第一次显示前不存在）。
function Skin:FindRegion(frame, suffix)
    if not frame or type(suffix) ~= "string" or suffix == "" then return nil end
    local ok, region = pcall(function() return frame[suffix] end)
    if ok and region and Widget:Readable(region) then return region end
    if type(frame.GetName) == "function" then
        local okN, name = pcall(frame.GetName, frame)
        if okN and name then
            local g = rawget(_G, name .. suffix)
            if g and Widget:Readable(g) then return g end
        end
    end
    local exact = rawget(_G, suffix)
    if exact and Widget:Readable(exact) then return exact end
    return nil
end

--- 正文凹槽那一档（insetFrame.bg）—— 泛化版见 Skin:Well；这里是主凹槽的便捷入口。
function Skin:InsetWell(frame, opts)
    local inset = self:FindInset(frame)
    if not inset then return nil end
    return self:Well(frame, inset, opts)
end

--- 给窗口的**任意内容区**补「凹槽」那一档底色 —— Skin:InsetWell 的泛化，多内容窗口
--- （列表 + 详情 + 侧栏）每块内容区都吃同一套语言：先剥暴雪原生美术（region + 名单内
--- 字段 + NineSlice），容器 alpha 亮回 1，再挂我们自己的背板 —— lost 档（比窗壳亮一档）
--- + 1px 主题边，背板挂窗口本体（2026-11-02 渲染判例：不挂中间容器名下）。
--- region 可以传**对象**或**名字后缀**（走 Skin:FindRegion 解析）；后缀解析不到且
--- opts.lazy ~= false 时挂 Widget:ShowWatch，等窗口第一次显示再试（懒建模板窗口）。
--- Panel 幂等（Marked "skinBg" 去重），所以 ShowWatch 里反复重试安全。
--- @return 背板对象，或 nil（区不存在且尚未懒建）。
function Skin:Well(frame, region, opts)
    if not frame then return nil end
    opts = opts or {}
    if type(region) == "string" then
        local suffix = region
        region = self:FindRegion(frame, suffix)
        if not region then
            -- 懒建区有两种：随窗口建的（首次 Show 前后就有）和**翻页/切页时才建**的
            -- （2026-11-02 实机 AchievementFrameStatsBG 判例：ShowWatch 只在窗口显示时补
            -- 一次，切页赶不上）。自注销 PollWatch（0.5s，找到即 Unwatch）全覆盖；
            -- FindRegion 只是两次表查，空转代价可忽略。
            if opts.lazy ~= false and Widget and Widget.PollWatch and Widget.Unwatch then
                local fn
                fn = function(f)
                    local found = self:FindRegion(f, suffix)
                    if found then
                        Widget:Unwatch(f, fn) -- 按值匹配注销（PollWatch 的 entry 不认）
                        self:Well(f, found, opts)
                    end
                end
                Widget:PollWatch(frame, fn, 0.5)
            end
            return nil
        end
    end
    if not region or not self:IsScriptObject(region) then return nil end
    self:Strip(region)
    local okA, a = pcall(region.GetAlpha, region)
    if okA and a and a <= 0.001 then
        pcall(region.SetAlpha, region, 1)
    end
    -- 背板挂到窗口本体（host = frame）而不是 region 名下：本客户端（70688）对"中间层容器里
    -- level 0 的子框"不渲染，挂窗口直下与根窗大板同父同级、创建在后，层次稳（见 Panel 注释）。
    -- opts.panel == false：纯剥离（比如 Bg 类原生承托美术 —— 它身后已有另一层的背板）。
    if opts.panel == false then return region end
    return self:Panel(region, {
        host        = frame,
        bgSurface   = opts.bgSurface or "lost",
        bgAlpha     = opts.bgAlpha or 0.965,
        borderKey   = opts.borderKey,
        borderAlpha = opts.borderAlpha,
        thickness   = opts.thickness or 1,
    })
end

--- A backplate for a control that already sits inside a panel, drawn *under* the control (buttons / drop-downs / edit boxes).
function Skin:ControlBg(frame, opts)
    if not frame or not self:IsScriptObject(frame) then return nil end
    opts = opts or {}

    local bg = Marked(frame, "controlBg")
    if not bg then
        bg = NewBackdropFrame(frame, -1)
        if not bg then return nil end
        pcall(bg.SetAllPoints, bg, frame)
        Widget:Theme(bg, {
            thickness   = opts.thickness or 1,
            bgAlpha     = opts.bgAlpha or 0.9,
            borderAlpha = opts.borderAlpha,
            borderKey   = opts.borderKey,
        })
        Mark(frame, "controlBg", bg)
        self:Track(bg)
    end

    pcall(bg.Show, bg)
    return bg
end

--- Hover feedback on a Blizzard control: lift the plate we own under it.
--- **不再 HookScript**：那会往暴雪框体的脚本槽里写我们的函数，把它标脏。
--- 改用轮询（Widget:HoverWatch），不写字段、不铺遮挡层、也不吃点击。
--- 2026-11-02（A5 / D +3）：这里以前只把边框涂成 highlight —— 实机读成"鼠标指着没反应"，
--- 因为只有 1px 在动。现在走 `Widget:SetHoverLift`，同一拍里背板抬一档命名亮度（surface `hover`）、
--- 边框换 highlight；写的仍然**只有我们自己的背板**（`skinBg` / `controlBg`），
--- 暴雪控件一个 region 都不碰。没进过工厂的背板退回原来的"只换边框色"。
function Skin:HoverHighlight(control, opts)
    if not control or type(control) ~= "table" then return end
    if Marked(control, "hover") then return end
    Mark(control, "hover", true)
    opts = opts or {}

    local function plate()
        return Marked(control, "skinBg") or Marked(control, "controlBg")
    end

    Widget:HoverWatch(control, function()
        local bg = plate()
        if not bg then return end
        if not Widget:SetHoverLift(bg, true) and bg.SetBackdropBorderColor then
            local r, g, b = Color:GetHighlight()
            bg:SetBackdropBorderColor(r, g, b, opts.alpha or 1)
        end
    end, function()
        local bg = plate()
        if not bg then return end
        if not Widget:SetHoverLift(bg, false) then
            Widget:Refresh(bg)
        end
    end)
end

--- Give a restyled control its pressed and disabled states back.
-- Skin:Button fades the Pushed and Disabled art and puts nothing in their place, so pressing gives no
-- feedback and a disabled button is indistinguishable from an enabled one -- the player clicks things
-- that do nothing.  Both states are expressed on the plate we already own: press darkens it, disable
-- dims it.  HoverHighlight owns the hover look; apply() reproduces the highlight colour itself after a
-- press so releasing while still hovered does not drop the hover tint.
function Skin:ControlState(control, opts)
    if not control or type(control) ~= "table" then return end
    if Marked(control, "state") then return end
    Mark(control, "state", true)
    opts = opts or {}

    local pressed = false

    local function apply()
        local bg = Marked(control, "controlBg") or Marked(control, "skinBg")
        if not bg or type(bg.SetBackdropBorderColor) ~= "function" then return end

        local enabled = true
        if type(control.IsEnabled) == "function" then
            local ok, value = pcall(control.IsEnabled, control)
            if ok then enabled = value and true or false end
        end

        if not enabled then
            local r, g, b = Color:GetNeutral()
            bg:SetBackdropBorderColor(r, g, b, opts.disabledAlpha or 0.3)
            if bg.SetBackdropColor then pcall(bg.SetBackdropColor, bg, 0, 0, 0, opts.disabledBgAlpha or 0.25) end
            return
        end

        if pressed then
            local r, g, b = Color:GetBorder()
            bg:SetBackdropBorderColor(r, g, b, 0.35)
            if bg.SetBackdropColor then
                pcall(bg.SetBackdropColor, bg, 0, 0, 0, (opts.bgAlpha or 0.9) * 0.6)
            end
            return
        end

        -- Widget:IsMouseOver, not a bare IsMouseOver: this client can return a SECRET boolean from it
        -- (SecretWhenAnchoringSecret), and `value and true` on a secret raises.
        if Widget:IsMouseOver(control) then
            local r, g, b = Color:GetHighlight()
            bg:SetBackdropBorderColor(r, g, b, opts.alpha or 1)
            return
        end

        Widget:Refresh(bg)
    end

    -- **不再 HookScript / hooksecurefunc**：两个都会往暴雪框体的脚本/方法槽里写东西，
    -- 把框体标脏（法术书图标那条 OnIconEnter → ClearOnBarHighlightMarks 就是这么被污染的）。
    -- 改用轮询：hover/down/up 由 Widget:HoverWatch 提供，enabled 状态每 0.2 秒比一次。
    local lastEnabled = nil
    Widget:HoverWatch(control, apply, apply, function()
        pressed = true; apply()
    end, function()
        pressed = false; apply()
    end)
    Widget:PollWatch(control, function()
        local enabled = true
        if type(control.IsEnabled) == "function" then
            local ok, value = pcall(control.IsEnabled, control)
            if ok then enabled = value and true or false end
        end
        if enabled ~= lastEnabled then
            lastEnabled = enabled
            apply()
        end
    end)

    apply()
end

-- The control helpers below are *re-appliable*: fades are idempotent through the side-table mark "hidden" (cleared by Rollback) and created objects (backplate, tab underline, thumb fill) are cached on the frame and only toggled, so no helper short-circuits the whole visual pass.

--- Restyle a Blizzard button (flat Monet plate + themed border + font).
function Skin:Button(button, opts)
    if not button then return button end

    -- **滚动条步进钮走专门那条路**（11-05 实机判例）：通用档的 `FadeButtonArt` 只压图不补图，
    -- 于是 `minimal-scrollbar-arrow-*` 被压成 α0、V 形却没放上去 ⇒ 玩家看到的是"箭头不见了"，
    -- 而 `/mui skins arrows` 的"我们的箭头"一直是 0。`Skin:ScrollArrowButton` 才是"压 + 补"成对的做。
    -- 为什么以前没兜住：`ScanScrollArrows` 只在登录后 +1s/+4s 各扫一次，而列表的滚动条是**懒建**的
    -- （第一次滚动才出现）—— 晚出现的箭头就只被通用档压过。放在入口就不依赖扫描时机。
    -- 非箭头按钮这里返回 false（判据是 region 上的 atlas 名），零副作用继续走通用档。
    -- ⚠ 步进钮有**两条腿**（11-05 修完第一条后探针立刻暴露第二条）：
    --   ① 图在按钮自己的 region 上 ⇒ `Skin:ScrollArrowButton` 按 atlas 认脸；
    --   ② 图在子件 `button.Texture` 上、方向记在 `button.upTexture` 字段 ⇒ 只有 `Skin:Stepper` 认。
    --   只分流①的话，那批（CharacterStatsPaneScrollBox / ChatFrame1 的滚动条）照样被通用档压成 α0 没人补图。
    if self:ScrollArrowButton(button) then return button end
    if self:Stepper(button) then return button end

    opts = opts or {}

    self:Strip(button, { keep = opts.keep })
    self:FadeButtonArt(button)
    self:ControlBg(button, {
        thickness   = opts.thickness or 1,
        bgAlpha     = opts.bgAlpha or 0.9,
        borderAlpha = opts.borderAlpha,
        borderKey   = opts.borderKey,
    })

    local text = self:GetText(button)
    if text then
        self:Font(text, opts.size or 12, opts.fontKey or "pixel", opts.flags, opts.textKey or "neutral")
    end

    self:HoverHighlight(button, { alpha = opts.borderAlpha or 1 })
    self:ControlState(button, { alpha = opts.borderAlpha or 1, bgAlpha = opts.bgAlpha or 0.9 })
    return button
end

--- Reflect the selection state on a tab's Monet underline.
-- Skin:Button -> Strip fades every texture region of the tab, SelectedTexture included, so the stock
-- "this tab is active" art is gone and the underline has to carry the state instead.  A panel swaps
-- tabs without any per-tab event we could subscribe to, so PanelTemplates_SelectTab/DeselectTab are
-- hooked once by HookTabState below; this function is also called on every re-apply.
function Skin:UpdateTabState(tab)
    local underline = tab and Marked(tab, "tabBar")
    if not underline then return end

    local selected = false
    if type(tab.IsSelected) == "function" then
        local ok, value = pcall(tab.IsSelected, tab)
        if ok then selected = value and true or false end
    elseif type(tab.Selected) == "table" and type(tab.Selected.GetAlpha) == "function" then
        -- No IsSelected on this template (SettingsPanel's own tabs, for one): fall back to the stock
        -- selected art, which Skin:Fade has already driven to alpha 0 -- so read what the tab wants,
        -- not what we left on screen.
        local ok, alpha = pcall(tab.Selected.GetAlpha, tab.Selected)
        if ok then selected = (alpha or 0) > 0 end
    end

    underline:SetAlpha(selected and 1 or 0.25)
    underline:Show()
end

--- 页签选中态的跟随：**不再 hooksecurefunc(PanelTemplates_SelectTab/DeselectTab)**。
--- 那是全局函数钩子 —— 任何面板切页签时都会在我们的代码里跑一段，整条调用链被记成
--- "tainted by MonetUI"（实机：进入编辑模式时 Blizzard 自己的小队框 setup 因此抛
--- "compare 'oldR' (secret ...)"）。改成 0.5 秒轮询所有装饰过的页签，重算选中态。
local tabWatch = setmetatable({}, { __mode = "k" })
local tabDriver

local function EnsureTabDriver(Skin)
    if tabDriver then return end
    tabDriver = CreateFrame("Frame")
    local acc = 0
    tabDriver:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 0.5 then return end
        acc = 0
        for tab in pairs(tabWatch) do
            pcall(Skin.UpdateTabState, Skin, tab)
        end
    end)
end

local function WatchTab(Skin, tab)
    if not tab then return end
    tabWatch[tab] = true
    EnsureTabDriver(Skin)
end

--- Restyle a tab button (square, themed, accent underline that follows the selection state).
function Skin:Tab(tab, opts)
    if not tab then return tab end
    -- 12.1.5 实测：QuestLogFrameTab1/2 与 InspectFrameTab1/2 在这版客户端是**一张表**
    -- （页签系统换成了 TabInfo），不是框体。Need 已经把它记成 notObject:table，所以这里
    -- 必须自己收口 —— 以前直接 tab:CreateTexture 抛 "attempt to call a nil value"，
    -- 被 Dress 逐件 pcall 兜住后变成 4 条红字，而账本里那条 ✗ 才是有效信息。
    if not self:IsScriptObject(tab) then return tab end
    self:Button(tab, opts)

    if not Marked(tab, "tab") then
        Mark(tab, "tab", true)
        local underline = tab:CreateTexture(nil, "OVERLAY")
        -- Height and offsets go through SnapUnit.  At uiScale 0.71 a raw 2-unit underline is 1.42
        -- physical px and the raw 1-unit offset sits on a half pixel, so it goes soft while every flat
        -- border beside it stays exact -- the failure mode Media:SnapUnit exists to prevent.
        underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", Media:SnapUnit(4), Media:SnapUnit(1))
        underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -Media:SnapUnit(4), Media:SnapUnit(1))
        underline:SetHeight(Media:SnapUnit(2))
        underline:SetTexture(Media.texture["monet_hairline"])
        Mark(tab, "tabBar", underline)
        self:Track(underline)
        WatchTab(self, tab)
        self:OnTheme(function()
            local r, g, b = Color:GetBorder()
            underline:SetVertexColor(r, g, b, 1)
            Skin:UpdateTabState(tab)
        end)
    end
    self:UpdateTabState(tab)
    return tab
end

--- 12.x 的**新式**滚动条步进钮（`MinimalScrollBar` / `WowTrimScrollBar`）：箭头画在**一个**
--- `button.Texture` region 上，mixin 每次按钮状态变化都 `Texture:SetAtlas(...)` 重设
--- （`TrimScrollBar.lua` / `MinimalScrollBar.lua` 的 `OnButtonStateChanged`），所以直接换贴图
--- 会被下一次 hover / 按下 / 禁用盖回去。做法和 ScrollBox 那批 atlas 箭头一致：把原图
--- **alpha 压 0、自己叠一层** —— mixin 照旧改它那张看不见的图，我们的箭头不受影响
--- （它只 SetAtlas、不碰 alpha，压一次就稳）。
---
--- 方向**不猜几何**，读它自己的图键（`upTexture` / `normalTexture`）—— 键值里明写着
--- Up/Down/Left/Right；`Back` / `Forward` 这种成员名只表示"退/进"，横向还是纵向看不出来。
local STEPPER_ATLAS_DIR = {
    ["UI-ScrollBar-ScrollUpButton-Up"]          = "up",
    ["UI-ScrollBar-ScrollDownButton-Up"]        = "down",
    ["UI-ScrollBar-ScrollLeftButton-Up"]        = "left",
    ["UI-ScrollBar-ScrollRightButton-Up"]       = "right",
    ["UI-ScrollBar-ClassicScrollUpButton-Up"]   = "up",
    ["UI-ScrollBar-ClassicScrollDownButton-Up"] = "down",
    ["minimal-scrollbar-arrow-top"]             = "up",
    ["minimal-scrollbar-arrow-bottom"]          = "down",
    ["minimal-scrollbar-arrow-left"]            = "left",
    ["minimal-scrollbar-arrow-right"]           = "right",
}

--- 给一只**新式**步进钮换箭头。老式（图在 GetNormalTexture 上的）直接返回 false，交给
--- `Skin:ScrollBar` 的 SwapArt 那条。幂等：`Marked(button, "scrollArrow")` 去重，
--- 和 `Skin:ScrollArrowButton` 共用一个标记，谁先到谁做。
function Skin:Stepper(button)
    if not button or Marked(button, "scrollArrow") then return false end
    local tex = button.Texture
    if not tex or type(tex.SetAlpha) ~= "function" then return false end
    if self:TexOf(button, "GetNormalTexture") then return false end
    local key = button.upTexture or button.normalTexture
    local dir = key and STEPPER_ATLAS_DIR[key]
    if not dir then return false end

    Mark(button, "scrollArrow", true)
    -- 压原图 + 它自己的 hover 高亮层（Overlay）：两层都是暴雪的图。
    self:Fade(tex)
    if button.Overlay and type(button.Overlay.SetAlpha) == "function" then
        self:Fade(button.Overlay)
    end

    -- 步进钮是 18×16 这种非正方形，直接 SetAllPoints 会把 V 形拉宽 —— 取短边摆正方形。
    local s = math.min(button:GetWidth() or 16, button:GetHeight() or 16)
    local our = button:CreateTexture(nil, "ARTWORK", nil, 2)
    our:SetSize(s, s)
    our:SetPoint("CENTER")
    our:SetTexture(Media:Texture("monet_chevron_up"))
    Widget:Arrow(our, dir)
    local r, g, b = Color:GetBorder()
    if r then our:SetVertexColor(r, g, b) end
    if not Marked(button, "arrowTint") then
        Mark(button, "arrowTint", true)
        self:OnTheme(function()
            local nr, ng, nb = Color:GetBorder()
            if nr then our:SetVertexColor(nr, ng, nb) end
        end)
    end
    return true
end

--- Restyle a scroll bar (track + arrows + thumb).
--- 肖像压成方形 + 收进窗口外框以内（2026-11-05 作者定的口径："肖像改方形，并且注意对齐到外框以内"）。
---
--- 两条实测前提，写下来免得下次又照椭圆去改遮罩：
---   ① `QuestFramePortrait` / `SocialUIFramePortrait` / `CharacterFramePortrait` 都是**贴图不是框**，
---      所以 `/mui compat find`（只枚举框）看不见它们，取用只能靠 `<窗口名>Portrait` 全局名或
---      `frame.Portrait` 成员；
---   ② 圆图本体是 atlas `RTPortrait1`（62×62），**方形靠裁，不靠拉伸**：那张圆图内切于画布，
---      裁到 `0.15..0.85` 正好是它的内接正方形 ⇒ 四角不留透明、也不会把脸拉扁。
--- 越界才重锚：只有当贴图左/上沿跑到窗口外面（暴雪那圈金属边本来就往框外溢）才按窗口左上角收回来，
--- 正常位置一律不动它 —— 免得把已经排好的窗口搞成第二次布局。
function Skin:SquarePortrait(frame)
    if not frame then return false end
    local okN, name = pcall(frame.GetName, frame)
    local por = frame.Portrait
    -- 取用仍走 `Skin:Need` 这唯一漏斗（不是直接查 `_G`）：名字不存在时必须是账本里的一行 ✗，
    -- 不是静默跳过（AGENTS「确认对象存在只有一个漏斗」）。
    if por == nil and okN and name then por = self:Need(name .. "Portrait") end
    if type(por) ~= "table" or type(por.SetTexCoord) ~= "function" then return false end

    -- ⚠ 一次性换肤在这里**不够**（11-05 实测）：ApplyAll 时我们裁好了（`Marked(por,'portraitSquared')=true`），
    -- 但窗口一 Show，暴雪自己的 `SetPortraitTexture` 那类会把 texcoord 重置回 0..1、锚点也摆回越界位置。
    -- ⇒ 和箭头/滚动条同一族："会被暴雪重设的东西"必须每次显示重涂（`Widget:ShowWatch`，引擎自带幂等）。
    -- 闭包按对象存进旁表复用：ShowWatch 按引用去重，每次 Apply 现造闭包就会越挂越多。
    local function applyOnce()
        pcall(por.SetTexCoord, por, 0.15, 0.85, 0.15, 0.85)

        local okW, w = pcall(por.GetWidth, por)
        local okH, h = pcall(por.GetHeight, por)
        if okW and okH and type(w) == "number" and type(h) == "number" then
            local side = math.min(w, h)
            if side > 0 then pcall(por.SetSize, por, side, side) end
        end

        -- GetRect 返回 left, bottom, width, height（不是四个角：11-04 记过这个口径）
        local okF, fl, fb, fw, fh = pcall(frame.GetRect, frame)
        local okP, pl, pb, pw, ph = pcall(por.GetRect, por)
        if okF and okP and type(fl) == "number" and type(pl) == "number" then
            local dx = pl - fl
            local dy = (fb + (fh or 0)) - (pb + (ph or 0))
            if dx < 2 or dy < 2 then
                dx = math.max(dx, 4)
                dy = math.max(dy, 4)
                pcall(por.ClearAllPoints, por)
                pcall(por.SetPoint, por, "TOPLEFT", frame, "TOPLEFT", dx, -dy)
            end
        end
    end

    local fn = Marked(por, "portraitApply")
    if not fn then
        fn = applyOnce
        Mark(por, "portraitApply", fn)
        Mark(por, "portraitSquared", true)
    end
    applyOnce()
    if Widget and Widget.ShowWatch then Widget:ShowWatch(frame, fn) end
    return true
end

function Skin:ScrollBar(scrollbar)
    if not scrollbar then return scrollbar end

    self:Strip(scrollbar, { regions = true })

    -- Vertical scroll bars (UIPanelScrollFrameTemplate): up/down arrows -> chevrons.
    -- Horizontal variants (seen on the auction browse sort bar): left/right -> arrow left/right.
    -- 一张朝上的图 + `Widget:Arrow` 转向（理由见 Widget.lua 头注）：这里只登记**方向**，
    -- 不再一个方向一个材质键。
    local arrowMap = {
        ScrollUpButton    = "up",
        ScrollUp          = "up",
        ScrollDownButton  = "down",
        ScrollDown        = "down",
        ScrollLeftButton  = "left",
        ScrollLeft        = "left",
        ScrollRightButton = "right",
        ScrollRight       = "right",
    }
    for member, dir in pairs(arrowMap) do
        local button = scrollbar[member]
        -- 只管**老式**步进钮（图在 GetNormalTexture 上）。新式那批的图在 `button.Texture` 上、
        -- mixin 每次状态变化都 SetAtlas 重设，走下面的 Skin:Stepper —— 在这里 Strip 会把它的
        -- 图压掉却没有东西补上（箭头直接消失）。
        if button and self:TexOf(button, "GetNormalTexture") then
            self:Strip(button, { regions = true })
            -- FadeButtonArt zeros every art; then SwapArt puts our glyph back.
            self:FadeButtonArt(button)
            local normal = self:SwapArt(self:TexOf(button, "GetNormalTexture"), "monet_chevron_up")
            local pushed = self:SwapArt(self:TexOf(button, "GetPushedTexture"), "monet_chevron_up")
            Widget:Arrow(normal, dir)
            Widget:Arrow(pushed, dir)
            -- Run the same border tint cycle Skin:CloseButton uses -- the glyph sits on a
            -- strip of Monet plate, so it reads as a control belonging to this skin.
            if normal and normal.SetVertexColor then
                local r, g, b = Color:GetBorder()
                normal:SetVertexColor(r, g, b)
                if pushed and pushed.SetVertexColor then pushed:SetVertexColor(r, g, b) end
                if not Marked(button, "arrowTint") then
                    Mark(button, "arrowTint", true)
                    self:OnTheme(function()
                        local nr, ng, nb = Color:GetBorder()
                        if normal.SetVertexColor then normal:SetVertexColor(nr, ng, nb) end
                        if pushed and pushed.SetVertexColor then pushed:SetVertexColor(nr, ng, nb) end
                    end)
                end
            end
        end
    end

    -- 新式步进钮：`MinimalScrollBar` / `WowTrimScrollBar` 的 Back / Forward（有的沿用旧成员名）。
    -- 老式那几只在这里会被 Skin:Stepper 判掉（它们的图在 GetNormalTexture 上）。
    for _, member in ipairs({ "Back", "Forward", "ScrollUpButton", "ScrollDownButton",
                              "ScrollLeftButton", "ScrollRightButton" }) do
        self:Stepper(scrollbar[member])
    end

    local thumb = scrollbar.Thumb
    if thumb then
        self:ScrollThumb(thumb)
    end

    -- **新式滚动条的轨**（`MinimalScrollBar` / `WowTrimScrollBar`：`Track.Begin` / `Track.End` /
    -- `Track.Middle` 三张 ARTWORK atlas）。11-05 子帧探针（`/mui skins layers QuestFrame scrollbar`）
    -- 数出"还看得见的暴雪美术"里就有 `minimal-scrollbar-track ×3` —— 把手和步进钮都换了皮肤，
    -- 唯独槽本身还是暴雪那条 8px 宽的青蓝凹槽，细线风一进去就露馅。
    -- 做法和把手同一套：剥掉暴雪三张 atlas（它们在 ScrollBox 复用前后不重设，不需要轮询兜底），
    -- 再画一条**居中的 1px 细线**（`monet_hairline`，横向拉伸使用），颜色走边框色 + 主题回调。
    local track = scrollbar.Track
    if track and type(track.GetRegions) == "function" and not Marked(track, "scrollTrack") then
        self:Strip(track, { regions = true })
        Mark(track, "scrollTrack", true)
        local line = track:CreateTexture(nil, "ARTWORK")
        line:SetTexture(Media:Texture("monet_hairline"))
        line:SetHeight(1)
        line:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
        line:SetPoint("BOTTOMRIGHT", track, "BOTTOMRIGHT", 0, 0)
        local function tintLine(k, a)
            local r, g, b = Color:GetBorder()
            if line.SetVertexColor then line:SetVertexColor(r * k, g * k, b * k, a) end
        end
        tintLine(1, 0.35)
        self:OnTheme(function() tintLine(1, 0.35) end)
        -- 悬停在把手上时把轨提亮一点：滚动条是个整体，只亮把手会让轨像没换皮。
        if thumb then
            Widget:HoverWatch(thumb, function() tintLine(1.25, 0.6) end, function() tintLine(1, 0.35) end)
        end
    end

    return scrollbar
end

--- 滚动条把手（thumb）统一换肤：barfill 材质 + 主题色 + 悬停提亮。
--- 本体铺一块窄一点的"细把手"（居中留边），读起来是细条而不是整块亮条 —— 2026-10-29 细线风。
--- 经典 Slider（Skin:ScrollBar）和 ScrollBox 的无名滚动条共用这一套。
function Skin:ScrollThumb(thumb)
    if not thumb then return end
    self:Strip(thumb, { regions = true })
    if Marked(thumb, "thumbFill") then return end

    local fill = thumb:CreateTexture(nil, "ARTWORK")
    fill:SetTexture(Media.texture["monet_barfill"])
    Widget:TopLight(fill)
    -- 细条：比 thumb 本体窄（居中留边），别做成铺满整格的实心亮块。
    local w = thumb:GetWidth() or 8
    local bar = math.max(3, math.floor(w * 0.55))
    local inset = math.max(0, math.floor((w - bar) / 2))
    fill:SetPoint("TOPLEFT", thumb, "TOPLEFT", inset, 0)
    fill:SetPoint("BOTTOMRIGHT", thumb, "BOTTOMRIGHT", -inset, 0)
    Mark(thumb, "thumbFill", fill)
    self:Track(fill)

    local function tint(k)
        local r, g, b = Color:GetBorder()
        fill:SetVertexColor(r * k, g * k, b * k, 0.95)
    end
    tint(1)
    self:OnTheme(function() tint(1) end)
    -- 轮询代替 HookScript（滑块手柄是暴雪的贴图，写脚本槽会污染）。
    Widget:HoverWatch(thumb, function() tint(1.35) end, function() tint(1) end)
end

--- ScrollBox 的上下箭头按钮：无名 17×11 Button，贴图是 region 上的
--- atlas `minimal-scrollbar-arrow-top` / `-bottom`（没有 NormalTexture、没有 ScrollUpButton 字段）。
--- **暴雪每次滚动会把这张 atlas 重设回去**，所以不能直接改它的贴图（会被覆盖）。做法：
---   ① 把暴雪那张 atlas region `SetAlpha(0)` 藏掉；
---   ② 另建一张我们自己的箭头贴图（独立纹理，Blizzard 改 atlas 也盖不掉）；
---   ③ 轮询驱动兜底：暴雪偶尔会把 alpha 顶回 1（滚动/禁用态），驱动每 0.3s 重新压回 0。
local SCROLL_ARROW_ATLAS = {
    ["minimal-scrollbar-arrow-top"]    = "up",
    ["minimal-scrollbar-arrow-bottom"] = "down",
    ["minimal-scrollbar-arrow-left"]   = "left",
    ["minimal-scrollbar-arrow-right"]  = "right",
    -- 12.x 的 WowTrimScrollBar 步进钮（Back / Forward）：图也是 atlas，名字里写着方向。
    -- Skin:Stepper 从按钮的 upTexture 键走同一条路；这里是全量扫描的兜底。
    ["UI-ScrollBar-ScrollUpButton-Up"]    = "up",
    ["UI-ScrollBar-ScrollDownButton-Up"]  = "down",
    ["UI-ScrollBar-ScrollLeftButton-Up"]  = "left",
    ["UI-ScrollBar-ScrollRightButton-Up"] = "right",
    ["UI-ScrollBar-ClassicScrollUpButton-Up"]   = "up",
    ["UI-ScrollBar-ClassicScrollDownButton-Up"] = "down",
}
local arrowRegions = setmetatable({}, { __mode = "k" })  -- [blizzardRegion] = true
local arrowDriver, arrowAcc

local function EnsureArrowDriver()
    if arrowDriver then return end
    arrowDriver = CreateFrame("Frame")
    arrowDriver:SetScript("OnUpdate", function(_, elapsed)
        arrowAcc = (arrowAcc or 0) + (elapsed or 0)
        if arrowAcc < 0.3 then return end
        arrowAcc = 0
        for reg in pairs(arrowRegions) do
            if type(reg.GetAlpha) == "function" and type(reg.SetAlpha) == "function" then
                local ok, a = pcall(reg.GetAlpha, reg)
                if ok and type(a) == "number" and a > 0 then pcall(reg.SetAlpha, reg, 0) end
            end
        end
    end)
end

function Skin:ScrollArrowButton(button)
    if not button or Marked(button, "scrollArrow") then return false end
    if type(button.GetRegions) ~= "function" then return false end
    -- GetRegions 返回**多返回值**，必须用 { } 包成 table（直接 pcall 只会拿到第一个 region）。
    local okRegions, regions = pcall(function() return { button:GetRegions() } end)
    if not okRegions or type(regions) ~= "table" then return false end
    for _, reg in ipairs(regions) do
        if type(reg.GetAtlas) == "function" then
            local ok, atlas = pcall(reg.GetAtlas, reg)
            local dir = ok and atlas and SCROLL_ARROW_ATLAS[atlas]
            if dir then
                Mark(button, "scrollArrow", true)
                -- ① 藏掉暴雪 atlas（它每次滚动会重设贴图，但 alpha 由驱动持续压回 0）
                pcall(reg.SetAlpha, reg, 0)
                arrowRegions[reg] = true
                EnsureArrowDriver()
                -- ② 我们自己的箭头：独立纹理，压在上层（一张朝上的图 + Widget:Arrow 转向）
                -- 步进钮多是 18×16 这种非正方形，SetAllPoints 会把 V 形拉宽 —— 取短边摆正方形。
                local s = math.min(button:GetWidth() or 16, button:GetHeight() or 16)
                local our = button:CreateTexture(nil, "ARTWORK", nil, 2)
                our:SetSize(s, s)
                our:SetPoint("CENTER")
                our:SetTexture(Media:Texture("monet_chevron_up"))
                Widget:Arrow(our, dir)
                local r, g, b = Color:GetBorder()
                our:SetVertexColor(r, g, b)
                return true
            end
        end
    end
    return false
end

--- 全局兜底：扫一遍所有帧，把 ScrollBox 的细把手 + 上下箭头都换上。
--- ScrollBox 的滚动条是匿名 Frame + .Thumb + 无名 atlas 箭头，而且标签页懒创建 ——
--- 逐帧换肤（SkinScrollsIn）常常赶不上。登录后延迟扫几遍兜底（EnumerateFrames 一遍几十毫秒）。
---
--- **必须跳过读不了的帧**：`EnumerateFrames` 会把这个客户端里所有帧都交给我们，其中包含
--- 被引擎接管的安全框（forbidden 对象，任何 `IsVisible` / `GetRegions` / `GetName` 都直接抛）。
--- 以前把它们一路喂下去，最后连 `HoverWatch` 都挂在了 forbidden 对象上（实机：一个匿名框每拍
--- 抛一条，暂停后 5 秒复检一次，全程只是噪声）。这个扫尾本来就是"能扫到就扫"，读不到直接放手。
function Skin:ScanScrollArrows()
    if type(EnumerateFrames) ~= "function" then return end
    local frame = EnumerateFrames()
    local guard = 0
    while frame and guard < 200000 do
        guard = guard + 1
        if Widget:Readable(frame) then
            pcall(function()
                if frame.Thumb and Widget:Readable(frame.Thumb) then
                    self:ScrollThumb(frame.Thumb)
                end
                local kind = frame.GetObjectType and frame:GetObjectType()
                -- ⚠ 11-05 实机判例：`/mui skins arrows` 扫 15306 框、命中 400，**我们的箭头 0**，
                -- 而箭头 region 已被 Strip 压成 α0 ⇒ "压掉没人补图"。根因就在这一行：
                -- `MinimalScrollBar` 的步进钮是 **`EventButton`**（`Blizzard_SharedXML/Shared/Scroll/
                -- MinimalScrollBar.xml:101/120`），`GetObjectType()` 返回的是最派生类型名，
                -- 精确比较 `== "Button"` 一条都不命中。⇒ 必须用 `IsObjectType("Button")`
                -- （它认 Button 与 EventButton 两支），老式 `ScrollUpButton` 那些照旧命中。
                local isButton = false
                if frame.IsObjectType then
                    local okT, t = pcall(frame.IsObjectType, frame, "Button")
                    isButton = (okT and t) or false
                elseif kind == "Button" then
                    isButton = true
                end
                if isButton then
                    self:ScrollArrowButton(frame)
                    -- 关闭按钮按**美术签名**兜底：名字不可靠（12.x 有匿名的、也有不叫 CloseButton 的），
                    -- 12.1.5 实测 53 只里 32 只还是暴雪原样（历史证据，5bc814e 正文）；
                    -- 1.60 上这个数要重数才算，待 1.60 复验。见 Skin:CloseButtonByArt。
                    self:CloseButtonByArt(frame)
                end
            end)
        end
        frame = EnumerateFrames(frame)
    end
end

--- 按**美术签名**找关闭按钮并换肤，给全游戏一个统一的 ✕（2026-11-03 玩家定的口径：
--- "全部统一成我们的 ✕"，不再只管美化过的窗口）。
---
--- 判据只认 `RedButton-Exit*` 这个 atlas —— 和 `Skin:FindAnonClose` 同一条签名。
--- **`RedButton-MiniCondense` 千万别碰**：那是最小化 / 隐藏按钮（图形是减号，不是 ✕），
--- 换成 ✕ 会把"收起"变成"关闭"。
--- 幂等：换过之后 normal 贴图不再有 atlas（`SwapArt` 走的是 SetTexture），
--- 下一趟扫到就自然跳过；`Skin:SwapArt` 自己也对已换的贴图早退。
function Skin:CloseButtonByArt(button)
    if not button then return false end
    local tex = self:TexOf(button, "GetNormalTexture")
    if not tex then return false end
    local ok, atlas = pcall(tex.GetAtlas, tex)
    if not ok or type(atlas) ~= "string" then return false end
    if not atlas:lower():find("redbutton%-exit") then return false end
    self:CloseButton(button)
    return true
end

--- 翻页按钮的左右箭头（商人 / 邮件 / 拾取 / 任务文本）：换 Normal/Pushed 贴图 + 主题色。
function Skin:PageArrow(button, dir)
    if not button then return button end
    -- 一张朝上的图 + `Widget:Arrow` 转向（dir 仍是 "left" / "right"，调用点不用改）。
    local normal = self:SwapArt(self:TexOf(button, "GetNormalTexture"), "monet_chevron_up")
    local pushed = self:SwapArt(self:TexOf(button, "GetPushedTexture"), "monet_chevron_up")
    Widget:Arrow(normal, dir)
    Widget:Arrow(pushed, dir)
    if normal and normal.SetVertexColor then
        local r, g, b = Color:GetBorder()
        normal:SetVertexColor(r, g, b)
        if not Marked(button, "pageArrowTint") then
            Mark(button, "pageArrowTint", true)
            self:OnTheme(function()
                local nr, ng, nb = Color:GetBorder()
                if normal.SetVertexColor then normal:SetVertexColor(nr, ng, nb) end
            end)
        end
    end
    return button
end

--- Walk a scroll frame's scroll bar (Blizzard names differ across builds).
function Skin:ScrollFrame(scrollFrame)
    if not scrollFrame then return end
    local bar = scrollFrame.ScrollBar or scrollFrame.Scrollbar
    if not bar and type(scrollFrame.GetScrollBar) == "function" then
        bar = scrollFrame:GetScrollBar()
    end
    if bar then self:ScrollBar(bar) end
    return scrollFrame
end

--- Restyle a slider: a Monet plate under the trough and the same barfill material on the thumb the scroll bars use.
-- Only the documented Slider member is trusted (GetThumbTexture); child names differ across clients and this must never throw, so whatever is missing is simply skipped.
function Skin:Slider(slider)
    if not slider then return slider end

    -- Thumb FIRST, because Skin:Strip fades every texture region of the slider and the thumb is one of
    -- them.  UIPanelSliderTemplate draws its trough as Left/Middle/Right textures on the slider itself,
    -- so skipping Strip leaves the stock blue trough sitting right under the Monet plate.  This was the
    -- one control helper that never called Strip; Skin:EditBox fades the very same three explicitly.
    local thumb
    if type(slider.GetThumbTexture) == "function" then
        local ok, tex = pcall(slider.GetThumbTexture, slider)
        if ok and tex then thumb = tex end
    end
    if not thumb then thumb = slider.Slider or slider.Thumb end

    self:Strip(slider, { keepTexture = thumb })
    self:ControlBg(slider, { thickness = 1, bgAlpha = 0.7 })

    if thumb then
        if type(thumb.CreateTexture) == "function" then
            if not Marked(thumb, "thumbFill") then
                self:ControlBg(thumb, { thickness = 1, bgAlpha = 0.9 })
                local fill = thumb:CreateTexture(nil, "ARTWORK")
                fill:SetAllPoints(thumb)
                fill:SetTexture(Media.texture["monet_barfill"])
                Widget:TopLight(fill)
                Mark(thumb, "thumbFill", fill)
                self:Track(fill)
                local function tint()
                    local r, g, b = Color:GetBorder()
                    fill:SetVertexColor(r, g, b, 0.95)
                end
                tint()
                self:OnTheme(tint)
            end
        elseif thumb.SetTexture then
            -- Go through SwapArt, not a raw SetTexture: SwapArt records the old art and sets
            -- the side-table mark "art", so Rollback can put Blizzard's thumb back.  A bare SetTexture left our
            -- barfill welded on -- a half-rolled-back skin, which is the one thing the Record/Rollback
            -- design promises will not happen.
            self:SwapArt(thumb, "monet_barfill")
            Widget:TopLight(thumb)
            local function tint()
                local r, g, b = Color:GetBorder()
                pcall(thumb.SetVertexColor, thumb, r, g, b, 0.95)
            end
            tint()
            if not Marked(slider, "sliderTint") then
                Mark(slider, "sliderTint", true)
                self:OnTheme(tint)
            end
        end
    end

    -- Low / High / Value captions, when the template has them.
    for _, fs in ipairs({ slider.Low, slider.High, slider.Text }) do
        if type(fs) == "table" and fs.IsObjectType
            and fs:IsObjectType("FontString") then
            self:Font(fs, 12, "pixel", nil, "neutral")
        end
    end
    return slider
end

--- Restyle a check button: fade the box art, draw a Monet box, keep the check glyph but tint it with the theme border colour.
function Skin:CheckButton(check, opts)
    if not check then return check end

    -- Fade the box (Normal) and the pressed / disabled glows, but keep the check texture visible.
    if check.GetNormalTexture   then self:Fade(check:GetNormalTexture()) end
    if check.GetPushedTexture   then self:Fade(check:GetPushedTexture()) end
    if check.GetDisabledTexture then self:Fade(check:GetDisabledTexture()) end
    if check.GetHighlightTexture then self:Fade(check:GetHighlightTexture()) end

    self:ControlBg(check, { thickness = 1, bgAlpha = (opts and opts.bgAlpha) or 0.55 })

    local checked = check.GetCheckedTexture and check:GetCheckedTexture()
    if checked then
        -- Our own checkmark art, tinted into the theme on top of it.
        checked = self:SwapArt(checked, "monet_check") or checked
        if checked.SetVertexColor then
            local r, g, b = Color:GetBorder()
            pcall(checked.SetVertexColor, checked, r, g, b)
            if not Marked(check, "checkTint") then
                Mark(check, "checkTint", true)
                self:OnTheme(function()
                    local nr, ng, nb = Color:GetBorder()
                    if checked.SetVertexColor then checked:SetVertexColor(nr, ng, nb) end
                end)
            end
        end
    end

    -- The stock highlight is gone, so hover feedback rides on the plate border.
    self:HoverHighlight(check, { alpha = (opts and opts.borderAlpha) or 1 })
    self:ControlState(check, { alpha = (opts and opts.borderAlpha) or 1, bgAlpha = (opts and opts.bgAlpha) or 0.55 })

    local text = self:GetText(check) or check.Text
    if text then self:Font(text, (opts and opts.size) or 12, "pixel", nil, "neutral") end
    return check
end

--- Restyle a radio button.  Deliberately NOT a CheckButton alias: a radio's glyph is a dot, not a tick,
-- and M:Buttons/SkinButtonsIn dispatch on GetObjectType() so a CheckButton skin here gave every radio
-- button in the skinned windows a checkmark.  Structure mirrors Skin:CheckButton so the two read as
-- siblings -- same plate, same press/disabled behaviour, same hover, different art.
function Skin:RadioButton(radio, opts)
    if not radio then return radio end

    if radio.GetNormalTexture   then self:Fade(radio:GetNormalTexture()) end
    if radio.GetPushedTexture   then self:Fade(radio:GetPushedTexture()) end
    if radio.GetDisabledTexture then self:Fade(radio:GetDisabledTexture()) end
    if radio.GetHighlightTexture then self:Fade(radio:GetHighlightTexture()) end

    self:ControlBg(radio, { thickness = 1, bgAlpha = (opts and opts.bgAlpha) or 0.55 })

    local checked = radio.GetCheckedTexture and radio:GetCheckedTexture()
    if checked then
        checked = self:SwapArt(checked, "monet_radio") or checked
        if checked.SetVertexColor then
            local r, g, b = Color:GetBorder()
            pcall(checked.SetVertexColor, checked, r, g, b)
            if not Marked(radio, "radioTint") then
                Mark(radio, "radioTint", true)
                self:OnTheme(function()
                    local nr, ng, nb = Color:GetBorder()
                    if checked.SetVertexColor then checked:SetVertexColor(nr, ng, nb) end
                end)
            end
        end
    end

    self:HoverHighlight(radio, { alpha = (opts and opts.borderAlpha) or 1 })
    self:ControlState(radio, { alpha = (opts and opts.borderAlpha) or 1, bgAlpha = (opts and opts.bgAlpha) or 0.55 })

    local text = self:GetText(radio) or radio.Text
    if text then self:Font(text, (opts and opts.size) or 12, "pixel", nil, "neutral") end
    return radio
end

--- Restyle a drop-down button (Blizzard UIDropDownMenuButtonTemplate).
function Skin:Dropdown(button, opts)
    if not button then return button end
    return self:Button(button, opts or { size = 12 })
end

--- 输入框里哪些贴图**不是** chrome：搜索框的放大镜（`common-search-magnifyingglass`）
--- 和边框用的是同一批 region，以前一律 Strip，放大镜也变 alpha 0。
--- 实机 1.60 探针（2026-11-01）：19 个输入框全部 `common-search-magnifyingglass@0.00`，
--- 搜索框只剩一个空框。现在只淡"边框 / 无名底图"，其余 atlas 保留。
local function KeepEditBoxArt(region)
    local ok, atlas = pcall(function() return region.GetAtlas and region:GetAtlas() end)
    if not ok or not atlas then return false end   -- 无名贴图 = 底 / 边框那一类，照旧淡掉
    if atlas:find("border") then return false end
    return true
end

--- Restyle an edit box.
function Skin:EditBox(editBox)
    if not editBox then return editBox end

    self:Fade(editBox.Left)
    self:Fade(editBox.Middle)
    self:Fade(editBox.Right)
    self:Strip(editBox, { regions = true, keep = KeepEditBoxArt })
    self:ControlBg(editBox, { bgAlpha = 0.9 })
    return editBox
end

--- 取一张控件的贴图 region：**必须带 self 调用**。
-- `obj.GetNormalTexture()` 这种点调用在本客户端是 `bad argument #1 to '?' (Usage: local texture
-- = self:Get...)`（12.1.5 实机红字 = 历史证据，ff1bd7c 正文；1.60 是否同样拒点号待复验），而且不是所有方法都这么响 —— `GetDisabledTexture`
-- 抛错，另一些只**静默返回 nil**，于是 `SwapArt(nil)` 直接 no-op、整步换肤悄悄没做还不报错。
-- 统一走这个漏斗：拿不到就返回 nil（调用点的 `SwapArt(nil)` 本来就安全）。
function Skin:TexOf(obj, getter)
    if not obj or type(getter) ~= "string" then return nil end
    local fn = obj[getter]
    if type(fn) ~= "function" then return nil end
    local ok, tex = pcall(fn, obj)
    return ok and tex or nil
end

--- Swap a texture's art for one of ours and remember how to put the original back (atlas name or path, texcoords and alpha, all recorded for Skin:Rollback).
-- The texture carries the side-table mark "art" so Skin:Fade leaves it alone.  Idempotent: a texture already carrying our art is returned as is.  @return the same texture, or nil when it cannot be swapped
function Skin:SwapArt(tex, key)
    if not tex or type(tex.SetTexture) ~= "function" then return nil end
    if Marked(tex, "art") then return tex end

    local atlas = tex.GetAtlas and tex:GetAtlas() or nil
    local path  = tex.GetTexture and tex:GetTexture() or nil
    local u1, v1, u2, v2 = 0, 0, 1, 1
    if tex.GetTexCoord then u1, v1, u2, v2 = tex:GetTexCoord() end
    local alpha = tex.GetAlpha and tex:GetAlpha() or 1

    self:Record(function()
        if atlas and tex.SetAtlas then pcall(tex.SetAtlas, tex, atlas)
        elseif tex.SetTexture then pcall(tex.SetTexture, tex, path or 0) end
        if tex.SetTexCoord then pcall(tex.SetTexCoord, tex, u1, v1, u2, v2) end
        if tex.SetAlpha then pcall(tex.SetAlpha, tex, alpha) end
        Mark(tex, "art", nil)
    end)

    Mark(tex, "art", true)
    pcall(tex.SetTexture, tex, Media:Texture(key))
    if tex.SetTexCoord then pcall(tex.SetTexCoord, tex, 0, 1, 0, 1) end
    if tex.SetAlpha then pcall(tex.SetAlpha, tex, 1) end
    return tex
end

--- Find an *anonymous* close button.  12.x ships a batch of windows (LootFrame, ...) whose
-- close button is an unnamed Button child -- no `.CloseButton` field, no `<name>CloseButton`
-- global -- so all three name-based lookups miss it.  But the whole family carries the same
-- art signature: a RedButton-Exit atlas (RedButton-Exit / -Disabled / -exit-pressed /
-- -Highlight; the casing is not consistent, hence the lowercased match).  Identify by that,
-- never by guessed names.  Named buttons are left alone here -- they belong to the name path.
function Skin:FindAnonClose(frame)
    if not frame or type(frame.GetChildren) ~= "function" then return nil end
    local roots = { frame }
    -- TitleContainer / BorderFrame are two common host layers; absent layers are skipped.
    if type(frame.TitleContainer) == "table" then roots[#roots + 1] = frame.TitleContainer end
    if type(frame.BorderFrame) == "table" then roots[#roots + 1] = frame.BorderFrame end
    for _, root in ipairs(roots) do
        for _, kid in ipairs({ root:GetChildren() }) do
            -- `IsObjectType("Button")` 而不是精确比较：匿名关闭钮可能是 EventButton（11-05 判例）
            if kid.IsObjectType and kid:IsObjectType("Button")
                and kid.GetName and not kid:GetName() then
                for _, region in ipairs({ kid:GetRegions() }) do
                    local atlas = region.GetAtlas and region:GetAtlas()
                    if type(atlas) == "string" and atlas:lower():find("redbutton%-exit") then
                        return kid
                    end
                end
            end
        end
    end
    return nil
end

--- Restyle a standard close button into the theme, with our own art under it: normal = monet_close_normal, pushed = monet_close_push, highlight = monet_close_hover over the top (its blend mode is untouched, so hover only brightens the art), disabled = monet_close_push left untinted.
-- The highlight is left white -- an additive tint would go invisible on the darker border colours.
function Skin:CloseButton(button)
    if not button then return button end

    -- 取图一律走 `Skin:TexOf`（带 self + pcall）：点调用会抛错或静默返回 nil，见 TexOf 的头注。
    -- 四张都要换：disabled 不换就是"多一个方框"（模板的 `RedButton-Exit-Disabled` 是实心方板）。
    local normal = self:SwapArt(self:TexOf(button, "GetNormalTexture"), "monet_close_normal")
    local pushed = self:SwapArt(self:TexOf(button, "GetPushedTexture"), "monet_close_push")
    self:SwapArt(self:TexOf(button, "GetHighlightTexture"), "monet_close_hover")
    -- Disabled：换成灰色档 `monet_close_push`，并且**不跟着主题染色** —— 禁用态就该比常态暗一档。
    self:SwapArt(self:TexOf(button, "GetDisabledTexture"), "monet_close_push")

    if normal and normal.SetVertexColor then
        local r, g, b = Color:GetBorder()
        pcall(normal.SetVertexColor, normal, r, g, b)
        if pushed and pushed.SetVertexColor then
            pcall(pushed.SetVertexColor, pushed, r, g, b)
        end
        if not Marked(button, "closeTint") then
            Mark(button, "closeTint", true)
            self:OnTheme(function()
                local nr, ng, nb = Color:GetBorder()
                if normal.SetVertexColor then normal:SetVertexColor(nr, ng, nb) end
                if pushed and pushed.SetVertexColor then pushed:SetVertexColor(nr, ng, nb) end
            end)
        end
    end
    return button
end

--- 给图标写裁剪（去掉暴雪图标自带的那一圈边框）。
-- 参数是 (x0, x1, y0, y1)：纹素坐标按 SetTexCoord(left, right, bottom, top) 落，横向一对、纵向一对。
--
-- 零售 12.x 的纹素坐标是"秘密值"，只有紧跟在 SetTexture 之后写进去才生效；顺序反了，客户端会把
-- 图标拉成一条竖缝（12.1.5 实测：先裁剪再换贴图 = 竖缝；先换贴图再裁剪 = 正常）。所以这里统一按
-- "换贴图 -> 写裁剪"的顺序落一次，并给图标挂一个钩子：以后每次换贴图都补一遍裁剪（动作条的图标
-- 每刷新一次就会换贴图，不补就会一直保持竖缝）。
--- 图标裁剪（0.08 一圈）。
--- **不再 hooksecurefunc(icon, "SetTexture")**：那是插在暴雪贴图更新链里的钩子 ——
--- 暴雪每次给图标换贴图都会跑一段我们的代码，整条链就被记成 "tainted by MonetUI"。
--- 实机后果（taint.log 原文）：
---   Tainted value written to global ON_BAR_HIGHLIGHT_MARKS by MonetUI
---     ActionButton.lua:66 ClearOnBarHighlightMarks()
---     ← SpellBookItem.lua:521 OnIconEnter()
--- 这个全局表一旦变脏，**所有动作按钮的施法高亮更新**都会被拒，
--- 连带 PetActionButton*:SetShown / PetActionBar:ClearAllPointsBase 刷屏。
--- 改成：只记下裁剪参数，由我们自己的驱动帧每 0.5 秒重压一遍 texcoord。
local cropped = setmetatable({}, { __mode = "k" })
local cropDriver, cropAcc

local function EnsureCropDriver()
    if cropDriver then return end
    cropDriver = CreateFrame("Frame")
    cropDriver:SetScript("OnUpdate", function(_, elapsed)
        cropAcc = (cropAcc or 0) + (elapsed or 0)
        if cropAcc < 0.5 then return end
        cropAcc = 0
        for icon, c in pairs(cropped) do
            if type(icon.SetTexCoord) == "function" then
                pcall(icon.SetTexCoord, icon, c[1], c[2], c[3], c[4])
            end
        end
    end)
end

function Skin:CropIcon(icon, x0, x1, y0, y1)
    if not icon or type(icon.SetTexCoord) ~= "function" then return icon end
    x0, x1 = x0 or 0, x1 or 1
    y0, y1 = y0 or 0, y1 or 1

    cropped[icon] = { x0, x1, y0, y1 }
    EnsureCropDriver()

    -- 先把贴图重写一遍，裁剪必须跟在它后面
    if type(icon.SetTexture) == "function" and type(icon.GetTexture) == "function" then
        local tex = icon:GetTexture()
        if tex then pcall(icon.SetTexture, icon, tex) end
    end
    pcall(icon.SetTexCoord, icon, x0, x1, y0, y1)
    return icon
end

-- ---------------------------------------------------------------------------
--  品质色边（Bags 案共享版）：FlattenSlotArt 压掉了原生 IconBorder（品质色圈），
--  品质色由我们自绘。2026-11-03 改口径：**先问客户端要色** —— `C_Item.GetItemQualityColor`
--  是这个构建里品质色的唯一真值来源（物品链接、鼠标提示里的品质文字色都出自它），我们那
--  六个手调的数只是"接近"，同一件史诗装在提示里是一个色、在我们的边上是另一个色。
--  客户端没给答案（没有 C_Item / 返回读不出 / 数字越界）才落回手调表 —— 缺 API 时逐位
--  等于改动前，所以这是一次"能问到就对齐，问不到不变"的改动。
--  灰 / 白品质（0 / 1）照旧**不上色**，保持素边（引擎的中性 1px 边兜底）。
--  品质不是静态属性（商人翻页 / 交易换物品都会变），走 CropIcon 同款驱动帧：每 0.5s
--  重读一次品质、变了才动边（GetItemInfo 走缓存，未缓存时先素边、缓存落地后自动上色）。
--  唯一出口是 **`Skin:QualityColor(q)`**（2026-11-03 收口）：`Modules/Bags/Bags.lua:369` 那一份
--  自己的手调表已删掉，背包 ring 和格子的品质边现在吃同一个答案。色块形状统一成**命名字段**
--  `{ r =, g =, b = }`（Bags 的 hover 闭包本来就按 `.r/.g/.b` 读），本文件驱动帧同样读 `.r/.g/.b`。
-- ---------------------------------------------------------------------------

local Secrets = ns.Secrets   -- Utils/Secrets.lua 在本文件之前加载（Utils.xml）

-- 客户端问不到色时的兜底：就是改动前那张表，六个数值一个都没动（只是形状从位置表
-- `{ r, g, b }` 改成命名字段 —— 全仓品质色从此只有一种形状）。
local QUALITY_FALLBACK = {
    [2] = { r = 0.20, g = 0.80, b = 0.20 },   -- Uncommon 绿
    [3] = { r = 0.20, g = 0.55, b = 1.00 },   -- Rare    蓝
    [4] = { r = 0.65, g = 0.30, b = 0.95 },   -- Epic    紫
    [5] = { r = 1.00, g = 0.55, b = 0.00 },   -- Legendary 橙
    [6] = { r = 0.90, g = 0.80, b = 0.40 },   -- Artifact
    [7] = { r = 0.90, g = 0.80, b = 0.40 },   -- Heirloom
}

-- 只给这六档上色（0 灰 / 1 白 与 8 以上都不画边，保持素边）。
local QUALITY_PAINTED = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true }

--- 单个品质的色块：问一次、算一次。
--- **必须返回同一个表引用**：驱动帧拿 `color ~= entry.last` 判"品质变了没有"，
--- 每次现造一张新表会让它每 0.5 秒重涂一遍所有边框。
--- @return { r = number, g = number, b = number } | nil
local function QualitySwatch(q)
    if not QUALITY_PAINTED[q] then return nil end

    -- 离线 dump 核实（wow-forever-api/Blizzard_APIDocumentationGenerated/ItemDocumentation.lua:921-937）：
    --   C_Item.GetItemQualityColor(quality: ItemQuality 不可 nil)
    --     -> colorRGBR, colorRGBG, colorRGBB, qualityString
    --   SecretArguments = "AllowedWhenUntainted"，返回值没标机密；旧的**全局** GetItemQualityColor
    --   不在这个客户端的文档里（见下面 QualityOf 的实机判例），所以只走 C_Item.*。
    -- 数字之后要进比较和 SetBackdropBorderColor，仍过一次 Secrets.Number（读不出 = 没有色）。
    if C_Item and type(C_Item.GetItemQualityColor) == "function" then
        local ok, r, g, b = pcall(C_Item.GetItemQualityColor, q)
        if ok then
            local cr, cg, cb
            if Secrets and Secrets.Number then
                cr, cg, cb = Secrets.Number(r), Secrets.Number(g), Secrets.Number(b)
            else
                cr, cg, cb = r, g, b   -- 离线 tooling（没有 Secrets 层）：值本身已是普通数字
            end
            if type(cr) == "number" and type(cg) == "number" and type(cb) == "number"
                and cr >= 0 and cr <= 1 and cg >= 0 and cg <= 1 and cb >= 0 and cb <= 1 then
                return { r = cr, g = cg, b = cb }
            end
        end
    end

    local fb = QUALITY_FALLBACK[q]
    return fb   -- 表引用稳定，和旧行为一致
end

-- 惰性色表：第一次查某个品质才问客户端，问过就 rawset 存下来 —— **同一个品质永远拿到同一张表**，
-- 这正是调用方按引用判"品质变没变"的前提（下面的驱动帧、Bags 的 hover 闭包都靠它）。
-- 上界 = 六个品质 × 至多一次 API 调用，一帧之内也不会重复问。
local QUALITY_COLOR = setmetatable({}, {
    __index = function(t, q)
        local c = QualitySwatch(q)
        if c then rawset(t, q, c) end
        return c
    end,
})

--- 品质色在本仓的**唯一出口**：格子品质边和 Modules/Bags 的 ring 都走这里，别处不要再自己算。
--- 返回值是 memo 里那张表（引用稳定），调用方可以直接 `c ~= 上次那张` 判变化；
--- 每次现造新表 = 每 0.5 秒把所有边框重涂一遍。
--- @param q number|nil 品质（0 灰 / 1 白 / 8 以上一律 nil = 素边）
--- @return { r = number, g = number, b = number } | nil
function Skin:QualityColor(q)
    if q == nil then return nil end
    -- 品质值来自暴雪（容器 / 事件载荷），可能是机密值：机密既不能当表键也不能比较，
    -- 读不出就按"没有色"处理（= 素边），绝不抛。
    local n
    if Secrets and Secrets.Number then
        n = Secrets.Number(q)
    else
        n = tonumber(q)   -- 离线 tooling（没有 Secrets 层）：拿到的本来就是普通数字
    end
    if type(n) ~= "number" then return nil end
    return QUALITY_COLOR[n]
end

local qualityBorders = setmetatable({}, { __mode = "k" })   -- btn -> { frame, last }
local qualityDriver, qualityAcc

--- 品质查询：本客户端（WOWFOREVER 12.1.5）把全局 `GetItemInfo` / `GetItemInfoInstant` /
--- `GetItemQualityColor` 整族**砍了**（实机探针全 nil），但 `C_Item.*` 在——
--- `C_Item.GetItemQualityByID` 直吃 link / itemID，实机验证 q=2 直接解出。
--- 标准客户端走 GetItemInfo 兜底。
local function QualityOf(idOrLink)
    if C_Item and C_Item.GetItemQualityByID then
        local ok, q = pcall(C_Item.GetItemQualityByID, idOrLink)
        if ok and type(q) == "number" then return q end
    end
    if GetItemInfo then
        local ok, _, _, q = pcall(GetItemInfo, idOrLink)
        if ok and type(q) == "number" then return q end
    end
    return nil
end

--- 品质多路解析（模板不齐，按特征不按名字）：`btn.link` 字段（商人 / 交易窗模板常写）
--- → `btn.itemID` 字段 → ItemButtonMixin 的 `GetItemID()` / `GetItem()`（ItemLocation）。
--- 全程 pcall，读不出就 nil（素边），绝不抛。
local function ResolveQuality(btn)
    local okLink, link = pcall(function() return btn.link end)
    if okLink and type(link) == "string" and link ~= "" then
        local q = QualityOf(link)
        if q then return q end
    end
    local okID, itemID = pcall(function() return btn.itemID end)
    if okID and type(itemID) == "number" and itemID > 0 then
        local q = QualityOf(itemID)
        if q then return q end
    end
    if type(btn.GetItemID) == "function" then
        local ok, v = pcall(btn.GetItemID, btn)
        if ok and type(v) == "number" and v > 0 then
            local q = QualityOf(v)
            if q then return q end
        end
    end
    if type(btn.GetItem) == "function" and C_Item and C_Item.GetItemQuality then
        local ok, loc = pcall(btn.GetItem, btn)
        if ok and type(loc) == "table" then
            local okV, valid = pcall(function() return loc:IsValidItem() end)
            if okV and valid then
                local okQ, q = pcall(C_Item.GetItemQuality, loc)
                if okQ and type(q) == "number" then return q end
            end
        end
    end
    return nil
end

--- 物品键多路解析（与 ResolveQuality 同一套顺序，但返回**键本身**而不是品质）：
--- 等级数字与冷却都要吃它。返回 link 字符串或 itemID 数字，读不出 = nil。
--- 只读字段 / pcall 方法，绝不往暴雪按钮写任何东西。
local function ResolveItemKey(btn)
    local okLink, link = pcall(function() return btn.link end)
    if okLink and type(link) == "string" and link ~= "" then return link end
    local okID, itemID = pcall(function() return btn.itemID end)
    if okID and type(itemID) == "number" and itemID > 0 then return itemID end
    if type(btn.GetItemID) == "function" then
        local ok, v = pcall(btn.GetItemID, btn)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return nil
end

--- link → itemID（`C_Item.GetItemID` 只吃 ItemLocation，link 只能自己抠）。
--- **先过 Secrets.CanRead 再做字符串匹配**：受限环境里 link 本身可能被标机密，
--- 未守卫的 `string.match` 会直接抛 invalid value（AGENTS 11-02 判例）。
local function ItemIDOf(key)
    if type(key) == "number" then return key end
    if type(key) ~= "string" then return nil end
    if Secrets and Secrets.CanRead and not Secrets.CanRead(key) then return nil end
    return tonumber(key:match("item(%d+)"))
end

--- 等级 + 冷却（人物面板装备格用；背包 / 我们自己的银行格走 Modules/Bags 那条）。
--- 等级只在 itemKey 变化时取一次（`C_Item.GetItemInfo` 的第 4 返回），冷却每拍重算
--- ——时长在走，但只在拿得到明文数字时才画（同 Bags 的守卫口径）。
local function UpdateSlotInfo(btn, entry)
    local key = ResolveItemKey(btn)
    if key ~= entry.itemKey then
        entry.itemKey = key
        local fs = entry.ilvl
        if fs then
            local text = ""
            if key then
                local info = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
                if info then
                    local ok, _, _, lv = pcall(info, key)
                    local n = ok and Secrets.Number(lv) or nil
                    if n and n > 0 then text = tostring(math.floor(n)) end -- TAINT-OK: Secrets.Number 守卫
                end
            end
            if text ~= entry.ilvlText then
                entry.ilvlText = text
                fs:SetText(text)
            end
        end
    end
    local cd = entry.cd
    if cd then
        local id = ItemIDOf(entry.itemKey)
        local getter = C_Container and C_Container.GetItemCooldown
        local start, duration, enable
        if id and getter then
            local ok, s, d, e = pcall(getter, id)
            start, duration, enable = ok and Secrets.Number(s) or nil, Secrets.Number(d), Secrets.Number(e)
        end
        if start and duration and duration > 0 and enable ~= 0 then -- TAINT-OK: 三个数全过 Secrets.Number
            cd:Show()
            if not pcall(cd.SetCooldown, cd, start, duration) then cd:Hide() end -- TAINT-OK: 三个数全过 Secrets.Number；物品冷却没有 duration-object API（那条只服务 GetActionCooldownDuration 的动作槽），Bags 同款
        else
            cd:Hide()
        end
    end
end

--- 把品质边框矩形吸附到物理像素栅格：外扩 1 物理像素（不是 1 UI 单位——有效缩放
--- 0.6 时 1 单位只有 0.6 物理像素），且四缘各自取整到整数像素。2026-11-02 实机
--- 判例：商人窗按钮物理坐标是小数（16.2 / 111.0 / 133.2 / 38.4），硬外扩 1 单位
--- 让四边落在不同的亚像素位置——顶边被拆成两行各 55% 强度、底边满强度一行，
--- 视觉上"底边比三边厚"。吸附后四边都是完整 1px。
--- 0.5s 驱动帧顺带重吸附：窗口拖动 / 缩放变化自动跟上（几何没变时 SetPoint
--- 写的是同值，幂等）。
local function AbsRectUnits(fr)
    -- 绝对单位坐标（父链同尺度累计；读不动就放弃，调用方保持现状）
    local absL, absB = 0, 0
    while fr do
        local okL, l = pcall(fr.GetLeft, fr)
        local okB, b = pcall(fr.GetBottom, fr)
        if not okL or not okB or type(l) ~= "number" or type(b) ~= "number" then return nil end
        absL, absB = absL + l, absB + b
        if fr == UIParent then return absL, absB end
        fr = fr:GetParent()
    end
    return nil
end

local function SnapQualityBorder(btn, border)
    local okS, s = pcall(btn.GetEffectiveScale, btn)
    if not okS or type(s) ~= "number" or s <= 0 then return end
    local absL, absB = AbsRectUnits(btn)
    if not absL then return end
    local okW, W = pcall(btn.GetWidth, btn)
    local okH, H = pcall(btn.GetHeight, btn)
    if not okW or not okH or type(W) ~= "number" or type(H) ~= "number" then return end
    local pxL, pxB = absL * s, absB * s
    local pxR, pxT = pxL + W * s, pxB + H * s
    -- 边框矩形 = 按钮矩形外扩 1 物理像素，四缘全部落在整数像素上（局部坐标以按钮
    -- 左下角为原点、y 向上；backdrop 的 edge 画在矩形内侧 = 按钮外那一整行像素）。
    local xl = (math.floor(pxL + 0.5) - 1 - pxL) / s
    local xr = W + (math.floor(pxR + 0.5) + 1 - pxR) / s
    local yb = (math.floor(pxB + 0.5) - 1 - pxB) / s
    local yt = H + (math.floor(pxT + 0.5) + 1 - pxT) / s
    pcall(border.ClearAllPoints, border)
    pcall(border.SetPoint, border, "BOTTOMLEFT", btn, "BOTTOMLEFT", xl, yb)
    pcall(border.SetPoint, border, "TOPRIGHT", btn, "BOTTOMLEFT", xr, yt)
end

local function EnsureQualityDriver()
    if qualityDriver then return end
    qualityDriver = CreateFrame("Frame")
    qualityDriver:SetScript("OnUpdate", function(_, elapsed)
        qualityAcc = (qualityAcc or 0) + (elapsed or 0)
        if qualityAcc < 0.5 then return end
        qualityAcc = 0
        for btn, entry in pairs(qualityBorders) do
            local border = entry.frame
            if border and border.GetAlpha then
                SnapQualityBorder(btn, border)
                local q = ResolveQuality(btn)
                local color = Skin:QualityColor(q)
                if color ~= entry.last then
                    entry.last = color
                    if color then
                        Widget:SetBorderState(border, color.r, color.g, color.b, 1)
                    else
                        Widget:SetBorderState(border, nil)
                    end
                end
            end
            -- 等级 + 冷却只在显式开过格（CharacterFrame 的装备格）上跑：
            -- 商人 / 邮件那些同走这条扫描的窗口一个字节都不多写。
            if entry.ilvl or entry.cd then UpdateSlotInfo(btn, entry) end
        end
    end)
end

--- Draw a quality-coloured 1px border around a flattened item button.  The border starts
--- as the plain neutral edge and recolours itself (poll driver) once the item's quality is
--- resolvable; unknown / poor / common keep the plain edge, exactly like Bags.
--- @param withInfo 给这个格子加"等级数字 + 冷却遮罩"（人物面板装备格点名开；默认不开 ——
---   商人 / 邮件这些同一条扫描吃到的窗口维持原样）。已登记过的格子也能事后升级，
---   谁先扫到都不影响结果。两个新对象不入 Track 名单（`ShowAdded` 会把冷却遮罩强 Show 出来）。
function Skin:ItemQualityBorder(btn, withInfo)
    if not btn then return btn end
    local entry = qualityBorders[btn]
    if not entry then
        local border = NewBackdropFrame(btn, 1)
        Widget:Theme(border, { thickness = 1, bgAlpha = 0 })
        self:Track(border)
        entry = { frame = border }
        qualityBorders[btn] = entry
        SnapQualityBorder(btn, border)
        EnsureQualityDriver()
    end
    if withInfo and not entry.ilvl then
        local fs = Widget:Font(btn, 10, "pixel", "bright", "LEFT", "OVERLAY",
                               "THICKOUTLINE, MONOCHROME")
        fs:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
        fs:SetDrawLayer("OVERLAY", 9)      -- 图标被抬到 OVERLAY 7，数字要压在它上面
        entry.ilvl = fs
        local cd = Widget:Cooldown(btn)
        cd:SetHideCountdownNumbers(true)   -- 装备格不到 40px：遮罩够了，倒计时数字会挤
        cd:Hide()
        entry.cd = cd
    end
    return btn
end

--- Flatten an item-slot button's native art (Bags 案的共享版，原实现在 Modules/Bags/Bags.lua).
-- 本客户端的物品格按钮有**圆角 IconMask**（遮罩把图标四角裁圆）+ **圆角 NormalTexture**
-- （quickslot 槽框）——两样都和方形凹槽语言冲突。压掉遮罩与槽框、图标抬到 OVERLAY 7
-- 铺满按钮，质量描边 (IconBorder) 一并压掉（品质色由 Skin:ItemQualityBorder 自绘补回）。
-- 全程 pcall：不同模板的字段不齐（没有的就跳过）。
function Skin:FlattenSlotArt(btn)
    if not btn then return btn end
    if btn.icon then
        pcall(btn.icon.RemoveMaskTexture, btn.icon, btn.IconMask)
        pcall(btn.icon.SetVertexColor, btn.icon, 1, 1, 1, 1)
        pcall(btn.icon.SetTexCoord, btn.icon, 0, 1, 0, 1)
        pcall(btn.icon.SetDrawLayer, btn.icon, "OVERLAY", 7)
        pcall(btn.icon.ClearAllPoints, btn.icon)
        pcall(btn.icon.SetAllPoints, btn.icon, btn)
        pcall(btn.icon.Show, btn.icon)
    end
    if btn.IconMask then
        pcall(btn.IconMask.SetTexture, btn.IconMask, nil)
        pcall(btn.IconMask.SetSize, btn.IconMask, 0.001, 0.001)
        pcall(btn.IconMask.Hide, btn.IconMask)
    end
    if btn.NewItemTexture then
        pcall(btn.NewItemTexture.SetAlpha, btn.NewItemTexture, 0)
        pcall(btn.NewItemTexture.Hide, btn.NewItemTexture)
    end
    if btn.BattlepayItemTexture then
        pcall(btn.BattlepayItemTexture.SetAlpha, btn.BattlepayItemTexture, 0)
        pcall(btn.BattlepayItemTexture.Hide, btn.BattlepayItemTexture)
    end
    if btn.flash then
        pcall(btn.flash.SetAlpha, btn.flash, 0)
        pcall(btn.flash.Hide, btn.flash)
    end
    if btn.NormalTexture then
        pcall(btn.NormalTexture.SetAlpha, btn.NormalTexture, 0)
    end
    if btn.IconBorder then
        pcall(btn.IconBorder.SetAlpha, btn.IconBorder, 0)
    end
    local ht = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if ht then
        pcall(ht.ClearAllPoints, ht)
        pcall(ht.SetAllPoints, ht, btn)
    end
    return btn
end

--- Crop an icon to a square and give it a Monet border.
--- **Atlas 门**：UI 图形图标（锤子 / 钱袋 / 箭头这类）是 atlas 贴图，内容只占图集页
--- 的一小块——对它们做 0.08 裁切 = 把整页图集拉到按钮上，比例必崩（2026-11-02 实机
--- 判例：商人修理 / 出售 / 回购三钮）。物品图标是文件贴图（整幅 0..1），裁切才有意义；
--- atlas 图标原样保留。
function Skin:Icon(icon, border)
    if not icon or Marked(icon, "icon") then return icon end
    Mark(icon, "icon", true)

    local okAtlas, atlas = pcall(icon.GetAtlas, icon)
    if okAtlas and type(atlas) == "string" then return icon end
    self:CropIcon(icon, 0.08, 0.92, 0.08, 0.92)
    if border and icon.GetObjectType and icon:GetObjectType() == "Texture" then
        local bg = NewBackdropFrame(icon:GetParent(), 1)
        bg:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
        bg:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        Widget:Theme(bg, { thickness = 1, bgAlpha = 0 })
        self:Track(bg)
    end
    return icon
end

--- Style a panel title bar: hide Blizzard's art and recolour the title text.
function Skin:TitleBar(frame, text, size)
    if not frame then return end
    local title = text or frame.TitleContainer and frame.TitleContainer.TitleText or frame.TitleText or frame.Title
    if title then
        self:Font(title, size or 12, "pixel", nil, "edge")
    end
end

--- A themed divider the caller anchors itself.  Uses monet_hairline (256×1 single opaque row);
--- height = whatever the caller gives via SetHeight, or 1 default.
function Skin:Divider(parent)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture(Media.texture["monet_hairline"])
    local r, g, b = Color:GetNeutral()
    line:SetVertexColor(r, g, b, 0.3)
    self:Track(line)
    self:OnTheme(function()
        local nr, ng, nb = Color:GetNeutral()
        line:SetVertexColor(nr, ng, nb, 0.3)
    end)
    return line
end

-- ==================== 诊断：一个窗口的"底"有几层（`/mui skins layers <窗口名>`） ====================
-- 背景件在 FrameXML 里有三种身份，而 `Skin:Strip` 只认前两种：
--   region   父框自己的贴图（`<Texture name="$parentBG">`）—— GetRegions 看得见，剥得到
--   字段     子框的名字是"父名 + BACKDROP_PIECES 里那 18 个词之一"—— 剥得到
--   要点名   有父框，但既不是父框的 region、字段名也不在名单里 —— Strip 一个都碰不到，
--            只能在面板 `frames` 名单里把它本人点出来
-- 分不清这三类就表现为"剥了一层还剩一层纸"：实机在任务对话框里三种各占一个
-- （QuestFrameBG / QuestFrameInset 底下的 BG / QuestFrameDetailPanelBG），而我们的名单只点到面板本人。
local MAX_PROBE_NODES, MAX_PROBE_DEPTH, MAX_PROBE_PRINT, MAX_PROBE_REGIONS = 600, 6, 20, 24

local BACKDROP_SET = {}
for i = 1, #BACKDROP_PIECES do BACKDROP_SET[BACKDROP_PIECES[i]] = true end

local function probeLabel(obj)
    local ok, name = pcall(obj.GetName, obj)
    if ok and type(name) == "string" and name ~= "" then return name end
    return "无名"
end

local function probeSize(obj)
    local okW, w = pcall(obj.GetWidth, obj)
    local okH, h = pcall(obj.GetHeight, obj)
    if okW and okH and w and h then
        return ("%dx%d"):format(math.floor(w + 0.5), math.floor(h + 0.5))
    end
    return "?"
end

-- 斜纹/织纹那层的 alpha 就是从这儿读的（AGENTS：GetAlpha 和顶点色 alpha 同一个存储）。
local function probeAlpha(obj)
    local ok, a = pcall(obj.GetAlpha, obj)
    if ok and type(a) == "number" then return ("α%.2f"):format(a), a end
    return "α?", nil
end

-- "这是谁画的"：这版客户端的窗口美术基本走 atlas（SetAtlas），GetTexture 只在少数几件上给得出
-- 路径、其余返回文件 id 或 nil —— 三样都印出来，否则一屏全是"无名"，等于没探。
local function probeArt(obj)
    local okA, atlas = pcall(obj.GetAtlas, obj)
    if okA and type(atlas) == "string" and atlas ~= "" then return atlas end
    local okT, tex = pcall(obj.GetTexture, obj)
    if okT then
        if type(tex) == "string" and tex ~= "" then return (tex:gsub("[^\\/]*[\\/]", "")) end
        if type(tex) == "number" then return "id:" .. tex end
    end
    return "-"
end

-- 状态分三档，第二档必须**随父继承**：一个 α0 的父框，底下二十件 α1.00 的贴图是看不见的，
-- 按件数算"暴雪原样"会得出 147 件这种没有意义的数（实机第一版就是这样报的）。
-- 我们自己的件（背板 / 织纹）都是匿名 CreateFrame，只能靠"挂在父框上的旁表指向谁"认出来。
local function probeState(obj, owner, fadedParent)
    if Marked(obj, "skinPlate") then return "我们的背板", false end
    if owner then
        if Marked(owner, "skinBg") == obj then return "我们的背板", false end
        if Marked(owner, "questWeave") == obj then return "我们的织纹", false end
        if Marked(owner, "controlBg") == obj then return "我们的控件底", false end
    end
    if Marked(obj, "skinBg") then
        -- 背板挂在谁身上，谁的 alpha 决定它显不显形（2026-11-02 MerchantFrame 判例：
        -- 容器被 Strip 整框 Fade 成 α0，「已挂我们的背板」的绿标签会把这件事遮住）。
        local _, hostA = probeAlpha(obj)
        if hostA and hostA <= 0.001 then return "已挂背板但容器α0", true end
        return "已挂我们的背板", false
    end
    if Marked(obj, "questWeave") then return "已挂我们的织纹", false end
    if Marked(obj, "art") then return "我们的美术件", false end
    if Marked(obj, "hidden") then return "已剥掉", true end
    local _, alpha = probeAlpha(obj)
    if alpha and alpha <= 0.001 then return fadedParent and "随父已剥" or "α0", true end
    if fadedParent then return "随父已剥", true end
    return "暴雪原样", false
end

-- 子框能不能被 Strip 顺着字段名剥到：把父名前缀去掉，剩下的正好在名单里才算。
local function probeTag(name, parentName)
    if type(name) == "string" and type(parentName) == "string"
        and #name > #parentName and name:sub(1, #parentName) == parentName then
        if BACKDROP_SET[name:sub(#parentName + 1)] then return "字段可剥" end
    end
    return "要点名"
end

--- 一个窗口的"底"有几层、每层谁能碰。`filter` 只影响打印，不影响账本。
--- 图集/贴图名归成"家族"：`UI-Frame-Metal-EdgeTop` → `ui-frame-metal`，路径取末段去扩展名，
--- 纯文件 ID 的图标单成一类。600 件的窗子逐行读不完，只能按家族数出"剩下的是哪一坨美术"。
local function artFamily(art)
    if type(art) ~= "string" or art == "" or art == "-" then return "无美术" end
    local s = string.lower(art)
    if s:find("^id:") or s:find("^atlas:%s*id:") then return "文件ID 图标" end
    s = s:match("([%w_%-%.:%,]+)$") or s
    s = s:match("([^/\\]+)$") or s
    s = s:gsub("%.%w+$", "")
    s = s:gsub("^[!_]+", "")
    local parts = {}
    for seg in s:gmatch("[^%-]+") do parts[#parts + 1] = seg end
    local fam = table.concat(parts, "-", 1, math.min(3, #parts))
    if fam == "" then return "无美术" end
    if #fam > 28 then fam = fam:sub(1, 28) end
    return fam
end

function Skin:ProbeLayers(path, filter)
    local root = self:Need(path)
    if not root then
        ns:Print(("「%s」不在美化对象账本里，或这版客户端没有它 —— /mui skins diagnose 读那本账。"):format(tostring(path)))
        return 0
    end

    local rows, nodes = {}, 0
    local counts = { plain = 0, faded = 0, ours = 0, hidden = 0 }

    -- "看得见"的口径（11-05 自纠）：以前只看 alpha 和我们的标记，于是手柄专用的
    -- `gamepad-uiframemetal-largeportrait-focus`（宿主框根本没显示）也被算进"还看得见的暴雪美术"，
    -- QuestFrame 报出 300 件这种虚高数 —— 数字虚高时按家族/按宿主的两张表全部不可用。
    -- ⇒ 现在同时要求：宿主框 `IsVisible()`（含父链）为真 **且** 贴图自己 `IsShown()` 为真。
    -- 读不出来时一律算"看得见"（保守：宁可多算，不能把真问题算没了）。
    local function visOf(obj, method)
        if type(obj[method]) ~= "function" then return true end
        local ok, v = pcall(obj[method], obj)
        if not ok then return true end
        return v and true or false
    end

    -- 整扇窗关着时探结构还有意义，但"看得见"这一列全空是废话 ⇒ 单独提醒，不让它冒充观感结论。
    local rootVisible = visOf(root, "IsVisible")

    local function placeOfFrame(obj)
        local okS, strata = pcall(obj.GetFrameStrata, obj)
        local okL, level = pcall(obj.GetFrameLevel, obj)
        return ("%s/lv%s"):format(okS and tostring(strata) or "?", okL and tostring(level) or "?")
    end

    -- 贴图没有 frame level，只有 layer/sublayer；`GetDrawInfo` 在这版客户端不存在（快照里查不到），
    -- 用它会整列打成 "?"。
    local function placeOfTex(obj)
        local ok, layer, sub = pcall(obj.GetDrawLayer, obj)
        if ok and layer then return ("%s/%s"):format(tostring(layer), tostring(sub or 0)) end
        return "?"
    end

    local function push(indent, tag, obj, place, owner, fadedParent, hostHidden, regionSelf)
        local label = probeLabel(obj)
        local art = probeArt(obj)
        local alphaText = probeAlpha(obj)
        local state, invisible = probeState(obj, owner, fadedParent)
        if state == "暴雪原样" and (hostHidden or regionSelf == false) then
            state = hostHidden and "看不见（宿主未显示）" or "看不见（自己隐藏）"
        end
        if state == "暴雪原样" then counts.plain = counts.plain + 1
        elseif state == "看不见（宿主未显示）" or state == "看不见（自己隐藏）" then counts.hidden = counts.hidden + 1
        elseif state == "已剥掉" or state == "随父已剥" or state == "α0" then counts.faded = counts.faded + 1
        else counts.ours = counts.ours + 1 end
        rows[#rows + 1] = {
            text = ("%s%s %s %s %s %s %s %s"):format(
                string.rep("  ", indent), tag, label, place, art,
                probeSize(obj), alphaText, state),
            key = string.lower(label .. " " .. art .. " " .. state),
            -- 两张汇总表用的字段（600 件的窗子逐行读不完，只能按家族/按宿主数）：
            state = state,
            family = artFamily(art),
            host = (owner and probeLabel(owner)) or label,
        }
        return invisible
    end

    local function walkRegions(frame, depth, fadedParent, hostHidden)
        if type(frame.GetRegions) ~= "function" then return end
        local ok, regions = pcall(function() return { frame:GetRegions() } end)
        if not ok or type(regions) ~= "table" then return end
        local shown = 0
        for i = 1, #regions do
            local region = regions[i]
            if IsTexture(region) then
                if nodes >= MAX_PROBE_NODES then return end
                if shown < MAX_PROBE_REGIONS then
                    nodes = nodes + 1
                    shown = shown + 1
                    -- region 是父框本人的贴图，Strip 的 regions 这一层直接够得到
                    push(depth + 1, "region", region, placeOfTex(region), frame, fadedParent,
                        hostHidden, visOf(region, "IsShown"))
                end
            end
        end
        if #regions > MAX_PROBE_REGIONS then
            rows[#rows + 1] = {
                text = ("%s（region 还有 %d 个没列）"):format(string.rep("  ", depth + 2), #regions - MAX_PROBE_REGIONS),
                key = "",
            }
        end
    end

    local function walk(frame, parentName, depth, fadedParent, hostHidden)
        if nodes >= MAX_PROBE_NODES or depth > MAX_PROBE_DEPTH then return end
        nodes = nodes + 1
        if not Widget:Readable(frame) then
            rows[#rows + 1] = {
                text = ("%s读不出（forbidden） %s"):format(string.rep("  ", depth), probeLabel(frame)),
                key = "forbidden",
            }
            return
        end
        -- 只按"自己"判，父链交给 IsVisible（它本身就含父链），避免两层口径互相抵消
        local hiddenHere = hostHidden or (rootVisible and not visOf(frame, "IsShown"))
        local invisible = push(depth, depth == 0 and "根框" or probeTag(probeLabel(frame), parentName),
            frame, placeOfFrame(frame), nil, fadedParent, hiddenHere, nil)
        walkRegions(frame, depth, invisible or fadedParent, hiddenHere)
        local ok, kids = pcall(function() return { frame:GetChildren() } end)
        if ok and type(kids) == "table" then
            local myName = probeLabel(frame)
            for i = 1, #kids do
                if nodes >= MAX_PROBE_NODES then return end
                walk(kids[i], myName, depth + 1, invisible or fadedParent, hiddenHere)
            end
        end
    end

    walk(root, nil, 0, false, not rootVisible)

    -- 全量进 SavedVariables：聊天框只留最后十几行，几十行一定被顶掉（读法同 compatReport，
    -- 落盘比 /reload 晚 1–2 分钟）。
    local needle = (type(filter) == "string" and filter ~= "") and string.lower(filter) or nil
    local texts = {}
    for i = 1, #rows do texts[i] = rows[i].text end
    local okDb, db = pcall(function() return ns.DB and ns:DB() end)
    if okDb and type(db) == "table" then
        db.layerReport = {
            when = (_G.date and _G.date("%Y-%m-%d %H:%M:%S")) or nil,
            root = tostring(path), filter = needle, total = #rows,
            rootVisible = rootVisible,
            plain = counts.plain, faded = counts.faded, hidden = counts.hidden, ours = counts.ours,
            rows = texts,
        }
    end

    local printed, matched = 0, 0
    for i = 1, #rows do
        if not needle or string.find(rows[i].key, needle, 1, true) then
            matched = matched + 1
            if printed < MAX_PROBE_PRINT then
                printed = printed + 1
                ns:Print(rows[i].text)
            end
        end
    end
    if matched > printed then
        ns:Print(("  （还有 %d 行没打，全量在 MonetUIDB.layerReport）"):format(matched - printed))
    end

    -- 两张汇总表：只数**还看得见的暴雪美术**，回答"下一步该剥哪一坨 / 该给哪个容器补美化"。
    -- 没这两张表时，587 件的窗子只能看到前 20 行，等于没有结论（11-05 实测 SocialUIFrame 就是这样）。
    local fams, hosts = {}, {}
    for i = 1, #rows do
        local r = rows[i]
        if r.state == "暴雪原样" and (not needle or string.find(r.key, needle, 1, true)) then
            fams[r.family] = (fams[r.family] or 0) + 1
            hosts[r.host] = (hosts[r.host] or 0) + 1
        end
    end
    local function topOf(t, n)
        local list = {}
        for k, v in pairs(t) do list[#list + 1] = { k, v } end
        table.sort(list, function(a, b)
            if a[2] ~= b[2] then return a[2] > b[2] end
            return a[1] < b[1]
        end)
        local out = {}
        for i = 1, math.min(n, #list) do out[i] = ("%s ×%d"):format(list[i][1], list[i][2]) end
        return out, #list
    end
    local famTop, famN = topOf(fams, 8)
    local hostTop, hostN = topOf(hosts, 6)
    if counts.plain > 0 then
        ns:Print(("  还看得见的美术家族（%d 类，前 8）：%s"):format(famN, table.concat(famTop, "、")))
        ns:Print(("  这些美术挂在谁身上（%d 个宿主，前 6）：%s"):format(hostN, table.concat(hostTop, "、")))
        ns:Print("  读法：家族 = 该补哪一类剥离；宿主 = 该给哪个容器开深扫。"
            .. "宿主名后带 ×N 越大越优先，×1 的零头不用管。")
    end

    if okDb and type(db) == "table" then
        db.layerReport.families, db.layerReport.hosts = famTop, hostTop
    end
    ns:Print(("|cffffd100%s 的底层|r：%d 件 —— 还看得见的暴雪美术 %d / 已剥或看不见 %d / 没显示 %d / 我们自己的 %d%s%s"):format(
        tostring(path), #rows, counts.plain, counts.faded, counts.hidden, counts.ours,
        needle and ("；其中含 %q 的 %d 件"):format(needle, matched) or "",
        nodes >= MAX_PROBE_NODES and "，到上限截断" or ""))
    if not rootVisible then
        ns:Print("|cffff6b6b这扇窗此刻没显示|r ⇒ 结构能读，但\"看得见的美术\"那一列全是 0 —— "
            .. "**先打开这扇窗再跑一次**，否则数出来的是结构，不是玩家看到的画面。")
    end
    return #rows
end
