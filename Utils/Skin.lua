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
local Scheduler = ns.Scheduler

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
    -- 发布版静默：这些是开发期的名单/换皮自检提示，账本照样记、/mui report 在本地仍能读。
    ns:DevPrint(message)
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

--- `Skin:Fade` 的**每趟复检**版：第一次压 + 记 `hidden` 标记，之后每趟补写一次 α0（幂等）。
---
--- 存在的理由 = `Fade` 的形态本身：它「隐藏一次 + 标记」，而暴雪**会把同一张贴图的 alpha 抬回来**
--- （§8.107 世界地图三处、角色窗滚动线、技能页底图）。抬回来之后再调 `Fade`，看见标记直接早退，
--- 于是永远纠不回去，画面上就是"我们压过的美术又活了"（11-13 名册窗 `PortraitOverlay` 第 4 张
--- 64×64 徽记就是这样：`hidden=true` 而 α 回到 1.00）。
--- ⇒ **凡是在轮询 / 反复 Apply 的路径里压图，一律用这个**；只压一次的地方继续用 `Fade`
--- （不必每趟多读一次 GetAlpha）。语义与 `Fade` 完全一致（同一本 `hidden` 标记、同样的 rollback）。
function Skin:FadeHold(region)
    if not region or type(region.SetAlpha) ~= "function" then return region end
    if Marked(region, "hidden") then
        -- 已经压过：不重复 `Fade`（那会早退），只把被抬回来的 α 写回去。
        local okA, a = pcall(region.GetAlpha, region)
        if not okA or a ~= 0 then pcall(region.SetAlpha, region, 0) end
        return region
    end
    return self:Fade(region)
end

--- 一张贴图的"身份串"，供各分类器做前缀 / 片段判据：**atlas 名优先，其次是 SetTexture 的文件路径**。
--- 两者都小写、路径分隔符统一成反斜杠（`Interface/Icons/…` 与 `Interface\Icons\…` 同判）。
--- **数字文件 ID 返回 nil**：我们自己的 BLP（`Media:Texture`）与一部分暴雪图标走数字 ID，
--- 没有可读路径，不该被任何路径判据命中 —— 保持旧行为（GetAtlas 回 nil ⇒ 不认）。
--- 2026-11-12（P1-9）：以前 `IsContentIcon` / `FadeRowArt` 只读 `GetAtlas`，
--- `file="Interface\Icons\…"` 型老贴图拿到 nil 就被当窗体装饰剥掉 —— 商人铁槌那条红线的另一面
--- （功能图标走 atlas 时豁免、走 file= 路径时却漏）。这一层把路径也认出来，分类器共用同一只眼睛。
local function ArtIdentity(tex)
    if not tex then return nil end
    if type(tex.GetAtlas) == "function" then
        local okA, atlas = pcall(tex.GetAtlas, tex)
        if okA and type(atlas) == "string" and atlas ~= "" then return (string.lower(atlas)) end
    end
    if type(tex.GetTexture) == "function" then
        local okT, path = pcall(tex.GetTexture, tex)
        if okT and type(path) == "string" and path ~= "" then
            return (string.lower(path):gsub("/", "\\"))
        end
    end
    return nil
end

--- Fade a texture's four sprite edges / a whole button's art, whatever shape it has.
--- **内容图标类 atlas / 图标路径**：这些画的是"这个按钮是什么功能"，不是窗体装饰 —— 压掉就等于把功能图标删了。
--- 11-05 玩家实测判例：商人窗的修理 / 修全部（`SpellIcon-256x256-Repair` / `-RepairAll`）
--- 被 `FadeButtonArt` 连 normal 贴图一起压成 α0 ⇒ "维修和全修的铁槌图标看不到了"。
--- （更早那一版 `RepairAll` 也已经被压掉，只是当时没人看它 —— 一次"看不见的美术变少了"的绿灯
---   把真缺陷读成了进展。）
local CONTENT_ICON_ATLAS = {
    "^spellicon%-", "^spell%-icon%-", "^inv%-", "^ability_", "^spell_", "^item_",
    "^coin%-", "^class%-icon", "^pet%-", "^icons\\", "^interface\\icons\\",
}

local function IsContentIcon(tex)
    -- 走 ArtIdentity：atlas 与 file= 路径都认。名单里 `^icons\\` / `^interface\\icons\\`
    -- 两条本来就是**路径前缀**，以前只喂 atlas 时是死规则，现在 SetTexture 的图标路径也能命中。
    -- 方向严格安全：只多豁免（保住功能图标），绝不会多剥一张。
    local low = ArtIdentity(tex)
    if not low then return false end
    for i = 1, #CONTENT_ICON_ATLAS do
        if low:find(CONTENT_ICON_ATLAS[i]) then return true end
    end
    return false
end

function Skin:FadeButtonArt(button)
    if not button then return end
    local getters = { "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture", "GetHighlightTexture" }
    for i = 1, #getters do
        local getter = button[getters[i]]
        if type(getter) == "function" then
            local tex = getter(button)
            -- 功能图标留着，只换它底下的那层板（Strip / ControlBg 负责）
            if tex and not IsContentIcon(tex) then self:Fade(tex) end
        end
    end
end

--- 把"为浅底设计的深色字"提亮（2026-11-06，法术书 / 天赋页全暗化的配套）。
--- **为什么需要**：剥掉羊皮纸（`spellbook-page-*`）之后，法术名 / 等级 / 分类标题仍然是
--- 暴雪给浅底配的深棕（实测 `0.18,0.11,0.06`，字体 `Fonts\ARKai_T.ttf`）—— 压在 0.96 的
--- 深色背板上等于看不见。11-05 那次只验了"羊皮纸消失"，没验"字还看得见"，这就是那条缺口。
--- **判据是颜色，不是文字内容**（不猜哪个串是标题）：只提亮**暗且接近中性**的字
--- （`max < 0.5` 且 `max-min < 0.18`）—— 后一条是为了放过职业色 / 品质色这类**饱和**文字，
--- 它们本该保留色相。提亮后颜色不再"暗"，下一遍自然跳过（幂等，无需标记表）。
--- 分级沿用调色板：`等级 N` 这类次级行 → `neutral`，其余（名字 / 分类标题）→ `bright`。
function Skin:BrightenDarkText(frame, depth)
    if not frame or (depth or 0) > 8 or type(frame.GetRegions) ~= "function" then return end
    depth = depth or 0
    local okR, regions = pcall(function() return { frame:GetRegions() } end)
    if okR then
        for _, reg in ipairs(regions) do
            local okT, kind = pcall(function() return reg:GetObjectType() end)
            if okT and kind == "FontString" and reg.GetTextColor and reg.SetTextColor then
                local okC, r, g, b = pcall(function() return reg:GetTextColor() end)
                if okC and type(r) == "number" then
                    local hi = math.max(r, g, b)
                    if hi < 0.5 and (hi - math.min(r, g, b)) < 0.18 then
                        local okX, txt = pcall(function() return reg:GetText() end)
                        local key = (okX and type(txt) == "string" and txt:find("^等级")) and "neutral" or "bright"
                        local nr, ng, nb = Widget:PaletteColor(key)
                        if nr then
                            local okA, a = pcall(function() return reg:GetTextAlpha() end)
                            pcall(reg.SetTextColor, reg, nr, ng, nb, (okA and a) or 1)
                        end
                    end
                end
            end
        end
    end
    local okC, kids = pcall(function() return { frame:GetChildren() } end)
    if okC then
        for _, k in ipairs(kids) do self:BrightenDarkText(k, depth + 1) end
    end
end

--- 认领"挂在匿名子帧上的窗口标题"并排成我们的样式（2026-11-06，法术书判例）。
--- **为什么需要**：`Skin:Dress` 的标题通道只认 `frame.TitleContainer.TitleText` / `TitleText` /
--- `Title` 这几个字段；法术书的标题字体串挂在**匿名子帧**上（字段一个都没有），于是它一直是
--- 暴雪原样：居中、`0.53,0.56,0.69 @0.8`、12px，和我们其它窗口的"左对齐 + edge 色 + 发丝线"
--- 完全两套。这里按**几何**认领（宽 ≥ 窗宽 55%、顶边贴窗口顶 26px 以内、有文字），不按文本猜。
--- 锚点写入受保护框的子件在战斗里会被拒 ⇒ 只做非战斗；字体/颜色不受限，随时可做。
function Skin:AdoptTopTitle(frame)
    if not frame or type(frame.GetRegions) ~= "function" then return nil end
    local fs = Marked(frame, "topTitle")
    if not fs or not fs.GetTop then
        local fTop = select(2, pcall(function() return frame:GetTop() end))
        local fW = select(2, pcall(function() return frame:GetWidth() end))
        if type(fTop) ~= "number" or type(fW) ~= "number" then return nil end
        local best, bestW = nil, 0
        local function scan(o, depth)
            if depth > 4 then return end
            for _, reg in ipairs({ o:GetRegions() }) do
                local okT, kind = pcall(function() return reg:GetObjectType() end)
                if okT and kind == "FontString" then
                    local okX, txt = pcall(function() return reg:GetText() end)
                    local okW, w = pcall(function() return reg:GetWidth() end)
                    local okTop, top = pcall(function() return reg:GetTop() end)
                    if okX and txt and txt ~= "" and okW and okTop and w and w >= fW * 0.55
                        and top and top <= fTop + 2 and top >= fTop - 26 then
                        if w > bestW then best, bestW = reg, w end
                    end
                end
            end
            for _, c in ipairs({ o:GetChildren() }) do scan(c, depth + 1) end
        end
        scan(frame, 0)
        fs = best
        if not fs then return nil end
        Mark(frame, "topTitle", fs)
    end
    self:Font(fs, 12, "pixel", "edge", "LEFT")
    if not InCombatLockdown() then
        local fW = select(2, pcall(function() return frame:GetWidth() end))
        pcall(fs.ClearAllPoints, fs)
        pcall(fs.SetPoint, fs, "TOPLEFT", frame, "TOPLEFT", 18, -5)
        if type(fW) == "number" then pcall(fs.SetWidth, fs, fW - 36) end
        pcall(fs.SetJustifyH, fs, "LEFT")
    end
    return fs
end

--- 递归剥"按 atlas 认得出的窗体背景"（11-05 天赋/法术页羊皮纸）。
--- `alpha` 省略 = 压成 0；给数值 = 压到那个值（2026-11-06 EUI 口径：羊皮纸留 0.1 淡纸，
--- 全 0 会让整页变成纯黑，反而失去"书"的感觉 —— `EllesmereUIBlizzardSkin_WindowPacks.lua:556`
--- 对 `BookBGLeft/Right/Halved` 用的就是 0.1）。
function Skin:FadeAtlasBackdrop(frame, patterns, depth, alpha)
    if not frame or (depth or 0) > 8 or type(frame.GetRegions) ~= "function" then return end
    depth = depth or 0
    local okR, regions = pcall(function() return { frame:GetRegions() } end)
    if okR then
        for _, reg in ipairs(regions) do
            local okA, atlas = pcall(reg.GetAtlas, reg)
            if okA and type(atlas) == "string" and atlas ~= "" then
                local low = string.lower(atlas)
                for i = 1, #patterns do
                    if low:find(patterns[i]) then
                        if alpha then
                            -- 指定值：不复用 Fade 的 "hidden" 标记（那标记的含义是"归零"），
                            -- 直接写 alpha；每次重涂都写一遍，幂等。
                            pcall(reg.SetAlpha, reg, alpha)
                        else
                            self:Fade(reg)
                        end
                        break
                    end
                end
            end
        end
    end
    local okC, kids = pcall(function() return { frame:GetChildren() } end)
    if okC then
        for _, k in ipairs(kids) do self:FadeAtlasBackdrop(k, patterns, depth + 1, alpha) end
    end
end

--- §8.107 受控剥「按名字认不出来的大块背景」—— 借鉴 Aurora `HidePaneArt` 的两层粒度，
--- 但比它保守得多：Aurora 在装饰容器里按 region 类型无差别 `Hide()`，是因为它先 Strip 再自建
--- backdrop、清楚哪张是自己的；我们的 `Skin:Panel` 是**新建的 Frame**（不是父框的 Texture region），
--- 但仍不能冒险按类型全 Hide（内容图标 / 职业背景 / 羊皮纸也是 Texture）。
--- 所以这里只收一类：`ArtIdentity` 返回 nil 的贴图 —— 即 **1.60 的 `GetTexture()` 数字 fileID
--- 且没有 atlas**。这类既进不了 atlas 名单、也进不了 `file=` 路径名单，是 11-12 实机
--- 「角色窗口还剩 51 张 / 技能页还剩 35 张大贴图」的主体（全是暴雪 130871 之类的老式底板）。
---
--- 四道门，缺一不可：
---   * 只 BACKGROUND / BORDER 层（ARTWORK / OVERLAY 是内容，OVERLAY 里那张 1216x603 天赋树底不能碰）
---   * 宽或高 > minSize（图标一般 ≤64，不会被卷进来）
---   * 不带我们自己的 `art` 标记；整棵 `skinPlate` 子框直接跳过
---   * 只写 α0，**每趟都写**（不走 Fade 的 hidden 标记）：暴雪换页 / 换布局会把 alpha 抬回来，
---     已有 hidden 标记的 Fade 会早退，永远纠不回 —— 11-12 世界地图 BorderFrame 3 张贴图实证。
---
--- opts = { depth=1, minSize=120, hosts={frame,...} }；hosts 给了就只扫这些具名装饰容器。
function Skin:FadePlainBackdrops(frame, opts)
    if not frame or type(frame.GetRegions) ~= "function" then return end
    opts = opts or {}
    local maxDepth = opts.depth or 1
    local minSize  = opts.minSize or 120

    local function sweep(f, depth)
        if not f or depth > maxDepth then return end
        -- 我们自己的背板 / 控件整棵跳过：别把 Theme 画在它上面的 regions 当成暴雪残留。
        if Marked(f, "skinPlate") or Marked(f, "art") then return end
        local okR, regions = pcall(function() return { f:GetRegions() } end)
        if okR then
            for _, reg in ipairs(regions) do
                local okT, ty = pcall(reg.GetObjectType, reg)
                if okT and ty == "Texture" and not Marked(reg, "art") then
                    local okL, layer = pcall(reg.GetDrawLayer, reg)
                    if okL and (layer == "BACKGROUND" or layer == "BORDER") then
                        local okW, w = pcall(reg.GetWidth, reg)
                        local okH, h = pcall(reg.GetHeight, reg)
                        if (okW and w and w > minSize) or (okH and h and h > minSize) then
                            -- 有 atlas 或有 file= 路径的交给名单处理，这里只收「认不出名字」的。
                            if not ArtIdentity(reg) then
                                pcall(reg.SetAlpha, reg, 0)
                            end
                        end
                    end
                end
            end
        end
        if depth < maxDepth then
            local okC, kids = pcall(function() return { f:GetChildren() } end)
            if okC then
                for _, k in ipairs(kids) do sweep(k, depth + 1) end
            end
        end
    end

    if opts.hosts then
        for _, host in ipairs(opts.hosts) do sweep(host, 0) end
    else
        sweep(frame, 0)
    end
end

--- 把「我们已经压掉的那些贴图」按旁表 `hidden` 标记重新写回 α0（**每趟都写**，幂等）。
--- 存在的理由就是 `Skin:Fade` 的形态：它是「隐藏一次 + 标记」，暴雪把同一张贴图的 alpha
--- 抬回来之后，后续每趟 `Fade` 看见标记就直接早退 —— 永远纠不回来（§8.107 三处实证：
--- 世界地图 BorderFrame 3 张、角色窗 `UI-Character-Info-ScrollLine`、技能页 `talent-background-rogue`）。
--- 与 `FadeAtlasBackdrop(..., alpha)` 的分工：那条按 **atlas 名字**点名、不认标记；
--- 这条按 **标记**点名、不认名字 —— 用在「没有可猜的名字、但确实被我们压过」的窗口
--- （飞行点地图 `TaxiFrame` 那 19 张边框件就属于这一类）。
--- 只碰带 `hidden` 标记的 region，自建美术（`art` 标记 / `skinPlate` 子框）天然不在内。
--- @return 这次真正写了几个（0 = 全都已经是 α0，供探针读）
function Skin:ReassertHidden(frame, depth)
    if not frame or type(frame.GetRegions) ~= "function" then return 0 end
    depth = depth or 0
    if depth > 8 then return 0 end
    local writes = 0
    local okR, regions = pcall(function() return { frame:GetRegions() } end)
    if okR then
        for _, reg in ipairs(regions) do
            if Marked(reg, "hidden") then
                local okA, a = pcall(reg.GetAlpha, reg)
                if not okA or a ~= 0 then
                    if pcall(reg.SetAlpha, reg, 0) then writes = writes + 1 end
                end
            end
        end
    end
    local okC, kids = pcall(function() return { frame:GetChildren() } end)
    if okC then
        for _, k in ipairs(kids) do writes = writes + self:ReassertHidden(k, depth + 1) end
    end
    return writes
end

--- 法术格的美术口径（照 `EllesmereUIBlizzardSkin_WindowPacks.lua:308-330` 的 FadeSpellItem）：
---   `item.Backplate` 归零（每次 populate/hover 都会被暴雪抬回来，所以这一趟要反复跑）；
---   图标金环 `Button.Border` **整圈归零**（2026-11-06 玩家两次点名后改的口径，原 EUI"留半"作废）：
---   金环是圆角 9-slice，图标方角化（下面的 CropIcon）之后它的圆角内沿正好压在图标四角上，
---   玩家看到的就是"图标上的圆形材质"；而"这是个技能格"的信息由我们自己的 1px 方框
---   （`M:IconWidgetsIn` → `ItemQualityBorder`）承接，Aurora 同样把这圈整摘。
---   `BorderSheen` / `IconHighlight` 归零（那两样是羊皮纸底上的高光，同为圆角美术）。
--- 判据只看字段是否存在（EUI 用同一套名字，本客户端实测齐全），不按贴图猜。
---
--- **图标必须自己裁**（2026-11-06 玩家报"图标没有裁切好，只加了一层框"）：EUI 那版只压金环、
--- 不碰 `Button.Icon`，而暴雪给每格图标挂了 `IconMask`（atlas `spellbook-item-spellicon-mask`，
--- 实测 masks=1）—— 带 mask 的贴图 `SetTexCoord` 会被客户端拒绝，图标就永远停在"圆角原样"，
--- 与我们背包/动作条的方角 0.08 裁切对不上。走 `Skin:CropIcon`（先 `StripMasks` 摘 mask 再裁），
--- 驱动帧之后每 0.5 秒补摘一次，暴雪 `UpdateVisuals` 把 mask 挂回来也压得住。
function Skin:SpellbookItemArt(frame, depth)
    if not frame or (depth or 0) > 10 or type(frame.GetChildren) ~= "function" then return end
    depth = depth or 0
    if frame.IsForbidden then
        local okF, forbidden = pcall(function() return frame:IsForbidden() end)
        if okF and forbidden then return end
    end
    local okB, backplate = pcall(function() return frame.Backplate end)
    local okBtn, btn = pcall(function() return frame.Button end)
    if okB and okBtn and backplate and btn then
        -- **每个字段按自己的当前值结算，不要"backplate 压过就整组跳过"的整组前置**
        -- （2026-11-06 实机复验抓到的）：暴雪 `UpdateVisuals` 会**单独**把金环抬回 α1，
        -- 而 backplate 还是 0 —— 整组前置从此永远跳过，金环就停在 α1。
        -- 读 alpha 比写便宜不了多少，但能省掉"值没变也写"的那部分。
        local function press(tex, want)
            if not tex or not tex.GetAlpha then return end
            local ok, a = pcall(function() return tex:GetAlpha() end)
            if ok and type(a) == "number" and math.abs(a - want) < 0.02 then return end
            pcall(tex.SetAlpha, tex, want)
        end
        press(backplate, 0)
        -- 金环整圈归零（圆角美术，压方角图标四角）；去饱和不再需要（alpha 0 没有颜色可谈）。
        press(btn.Border, 0)
        press(btn.BorderSheen, 0)
        press(btn.IconHighlight, 0)
        -- 图标裁切：暴雪 `UpdateVisuals` 会把 `IconMask` 挂回来，补摘靠 `CropIcon` 的
        -- 驱动帧做（每 0.5 秒），这里只负责"第一次登记"。`spellCrop` 旁表键去重，
        -- 2 秒轮询不会反复 SetTexture 重写。
        local okIcon, icon = pcall(function() return btn.Icon end)
        if okIcon and icon and type(icon.SetTexCoord) == "function" and not Marked(icon, "spellCrop") then
            self:CropIcon(icon, 0.08, 0.92, 0.08, 0.92)
            Mark(icon, "spellCrop", true)
            self:Record(function() Mark(icon, "spellCrop", nil) end)
        end
    end
    local okC, kids = pcall(function() return { frame:GetChildren() } end)
    if okC then
        for _, k in ipairs(kids) do self:SpellbookItemArt(k, depth + 1) end
    end
end

--- 页签：**不搬位置**，只把暴雪 TabSystem 的按钮换皮（2026-11-06 照 EUI 口径）。
--- 依据 `EllesmereUIBlizzardSkin_WindowEngine.lua:1253`（WSkin.Tab）：清掉页签自己的全部贴图
--- 与 `Left/Middle/Right` 三段图，自画一块深色底板 + 自建居中文案；暴雪那条文字**只把颜色设成
--- 全透明（不删）**，文案每次从它读回来镜像（动态文案走 `SetFormattedText`，不走 `SetText`）。
--- 选中态读 `tab.isSelected` 字段（不调 `IsSelected()` —— 那是暴雪 Lua）。
function Skin:TabSystemArt(tsys)
    if not tsys or type(tsys.GetChildren) ~= "function" then return end
    local okF, forbidden = pcall(function() return tsys:IsForbidden() end)
    if okF and forbidden then return end
    local okC, kids = pcall(function() return { tsys:GetChildren() } end)
    if not okC then return end
    for _, tab in ipairs(kids) do
        local okT, kind = pcall(function() return tab:GetObjectType() end)
        -- **带图标的页签整组跳过**：图标页签在本客户端是 `Icon + IconMask + SquareTextures 数组
        -- + SquareBackground` 四家并存，任何换皮都可能连带压掉图标（2026-11-06 实机反复验证）。
        -- 判据只看 `Icon` 上有没有贴图，不看名字。
        local hasIcon = false
        if okT and kind == "Button" and tab.Icon and tab.Icon.GetTexture then
            local okX, v = pcall(function() return tab.Icon:GetTexture() end)
            if okX and v ~= nil then hasIcon = true end
        end
        if okT and kind == "Button" and not hasIcon then
            local done = Marked(tab, "tabArt")
            if not done then
                Mark(tab, "tabArt", true)
                -- 1) **清贴图，不压 alpha**（EUI `WSkin.Tab` 原文的判据，2026-11-06 对齐）。
                --    两个理由，都是实机判例：
                --    ① `IconMask` 是 **MaskTexture**，把它 alpha 置 0 = 被它遮的图标整块不画
                --       （我们第二版"只压 alpha"就这么把图标弄没的）。EUI 用
                --       `r:IsObjectType("Texture")` 天然跳过蒙版，这里显式只认 Texture。
                --    ② 清贴图比压 alpha 更彻底：暴雪重新 Show 那些 region 时没东西可显示。
                local okR, regions = pcall(function() return { tab:GetRegions() } end)
                if okR then
                    for _, reg in ipairs(regions) do
                        if reg ~= tab.Icon and reg ~= tab.IconMask then
                            local okK, k2 = pcall(function() return reg:GetObjectType() end)
                            if okK and k2 == "Texture" then
                                pcall(reg.SetTexture, reg, nil)
                                pcall(reg.SetAtlas, reg, "")
                            end
                        end
                    end
                end
                for _, key in ipairs({ "Left", "Middle", "Right", "LeftActive", "MiddleActive",
                                       "RightActive", "LeftHighlight", "MiddleHighlight", "RightHighlight" }) do
                    local piece = rawget(tab, key)
                    if piece and piece.SetTexture then pcall(piece.SetTexture, piece, nil) end
                end
                local hl = tab.GetHighlightTexture and select(2, pcall(function() return tab:GetHighlightTexture() end))
                if hl and hl.SetTexture then pcall(hl.SetTexture, hl, nil) end
                -- 2) 我们的底板：BACKGROUND 子层 -8（永远垫在暴雪 BACKGROUND 美术之下）。
                local bg = tab:CreateTexture(nil, "BACKGROUND", nil, -8)
                bg:SetAllPoints()
                pcall(bg.SetDrawLayer, bg, "BACKGROUND", -8)
                Mark(tab, "tabBg", bg)
                -- 3) 暴雪文案只变透明，不删（要读它的文字）。
                local bliz = tab.Text or (tab.GetFontString and tab:GetFontString())
                if bliz and bliz.SetTextColor then pcall(bliz.SetTextColor, bliz, 0, 0, 0, 0) end
                Mark(tab, "tabBliz", bliz)
                -- 4) 我们自己的居中文案（11px 像素字，跟随主题）。
                local label = Widget:Font(tab, 11, "pixel", "neutral", "CENTER")
                label:SetPoint("CENTER", tab, "CENTER", 0, 0)
                Mark(tab, "tabLabel", label)
            end
            -- 每次重涂：文案镜像 + 选中态（幂等、便宜）。
            local bliz = Marked(tab, "tabBliz")
            local label = Marked(tab, "tabLabel")
            local bg = Marked(tab, "tabBg")
            -- 图标方模式（窗口"收回"时暴雪会切过去）：这时背景板必须整个让位，
            -- 否则它即便在 BACKGROUND/-8 也会和图标抢同一块视觉区域（实机：收回后图标又没了）。
            local iconMode = false
            if tab.SquareBackground then
                local okS, sh = pcall(function() return tab.SquareBackground:IsShown() end)
                iconMode = okS and sh and true or false
            end
            local text
            if bliz and bliz.GetText then
                local okX, v = pcall(function() return bliz:GetText() end)
                if okX and type(v) == "string" then text = v end
            end
            if not text then
                local okX, v = pcall(function() return tab.tabText end)
                if okX and type(v) == "string" then text = v end
            end
            if label then
                if text then pcall(label.SetText, label, text) end
                local sel = rawget(tab, "isSelected") and true or false
                pcall(label.SetTextColor, label, Widget:PaletteColor(sel and "bright" or "neutral"))
            end
            if bg then
                local sel = rawget(tab, "isSelected") and true or false
                local r, g, b = Widget:PaletteColor(sel and "edge" or "ambient")
                if r then
                    bg:SetAlpha(1)
                    bg:SetColorTexture(r * 0.35, g * 0.35, b * 0.35, sel and 0.95 or 0.45)
                end
            end
        end
    end
end

--- 通用版：递归一趟，**三类处理**（11-05 专业窗 + 角色窗共用）。
---   fadePatterns 命中的 → `Fade`（纯装饰底图，压没露我们的深色背板）；
---   swapPatterns  命中的 → `SwapArt` 成 monet_barfill + 染我们的边框色（**实心**选中/悬停条，
---     压没会丢反馈，所以是"换"不是"剥"）；
---   tintPatterns  命中的 → 只 `SetVertexColor` 我们的边框色，**保留暴雪原图形状**
---     （11-05 判例：`common-sidetab-selected` 本是一圈高亮框，SwapArt 换成实心 barfill 后
---      画在 OVERLAY 压在职业图标上 → 图标"发白"；这种框该染色不该替换）。
--- 只认 atlas 字符串；内容图标是数字文件 ID（GetAtlas 回 nil）不会被误伤（AGENTS 功能图标豁免）。
--- 幂等：Fade 靠 `hidden` 标记、SwapArt 靠 `art` 标记；tint 每次重染（幂等）。
function Skin:StyleAtlasBackdrop(frame, fadePatterns, swapPatterns, tintPatterns, depth)
    if not frame or (depth or 0) > 8 or type(frame.GetRegions) ~= "function" then return end
    depth = depth or 0
    local r, g, b = Color:GetBorder()
    local okR, regions = pcall(function() return { frame:GetRegions() } end)
    if okR then
        for _, reg in ipairs(regions) do
            local okA, atlas = pcall(reg.GetAtlas, reg)
            if okA and type(atlas) == "string" and atlas ~= "" then
                local low = string.lower(atlas)
                local handled = false
                if tintPatterns and r then
                    for i = 1, #tintPatterns do
                        if low:find(tintPatterns[i]) then
                            pcall(reg.SetVertexColor, reg, r, g, b, 1)
                            handled = true
                            break
                        end
                    end
                end
                if not handled and swapPatterns then
                    for i = 1, #swapPatterns do
                        if low:find(swapPatterns[i]) then
                            handled = true
                            if self:SwapArt(reg, "monet_barfill") and r then
                                pcall(reg.SetVertexColor, reg, r, g, b, 0.6)
                                -- 11-05 判例：选中态原本是 OVERLAY 的一圈高亮，换成实心 barfill 后
                                -- 画在图标(ARTWORK)之上会把图标糊白。把盒子压到内容之下当选中底色，
                                -- 图标留在上面清晰。重载会恢复原层（SwapArt 的回滚不记 layer）。
                                pcall(reg.SetDrawLayer, reg, "BACKGROUND", -6)
                            end
                            break
                        end
                    end
                end
                if not handled and fadePatterns then
                    for i = 1, #fadePatterns do
                        if low:find(fadePatterns[i]) then self:Fade(reg); break end
                    end
                end
            end
        end
    end
    local okC, kids = pcall(function() return { frame:GetChildren() } end)
    if okC then
        for _, k in ipairs(kids) do self:StyleAtlasBackdrop(k, fadePatterns, swapPatterns, tintPatterns, depth + 1) end
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
                local key = BACKDROP_PIECES[i]
                local piece = frame[key]
                if piece and type(piece.SetAlpha) == "function" then
                    -- §8.106 容器型 BorderFrame **绝不整层 Fade**：WorldMapFrame.BorderFrame 是
                    -- 1035x534 的全窗 Frame，下面挂着 11 个子控件（含 WorldMapFrameCloseButton）。
                    -- 整层 α0 会把它们一起吞掉 —— 世界地图关闭 X 看不到的真正根因（换皮其实
                    -- 一直成功：closeTint 在、顶点色也在）。只压它自己那几张 Texture regions
                    -- （标题条 / 全窗底 / 发丝线），子控件原样留着。
                    -- 16 窗扫描只有这一例容器型 BorderFrame，影响面可控；其它窗口的 Bg /
                    -- Background / Inset 等仍是 Texture 或走既有整件 Fade 路径。
                    if key == "BorderFrame" and type(piece.GetRegions) == "function" then
                        pcall(function()
                            local regs = { piece:GetRegions() }
                            for j = 1, #regs do
                                local region = regs[j]
                                if IsTexture(region) and not IsContentIcon(region) then
                                    self:Fade(region)
                                end
                            end
                        end)
                    else
                        self:Fade(piece)
                    end
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
                        -- 功能图标（法术 / 物品 / 职业 / 货币 atlas）不剥：它不是窗体装饰，
                        -- 剥掉就是把"这按钮是干什么的"删了（FadeButtonArt 同一条豁免）。
                        if not IsContentIcon(region) then
                            self:Fade(region)
                        end
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

    local inset = opts.inset or 0
    -- §8.89 `topExtend`：把背板上沿向外多撑一段（聊天框用它扩出 32 的输入区）。
    -- 只在这条链上生效，**不能改默认 inset**，否则所有皮肤窗口一起上移。
    local topExtend = opts.topExtend or 0
    local bg = Marked(frame, "skinBg")
    local function AnchorPanel()
        pcall(bg.SetPoint, bg, "TOPLEFT", frame, "TOPLEFT", inset, -inset + topExtend)
        pcall(bg.SetPoint, bg, "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
    end

    if not bg then
        bg = NewBackdropFrame(opts.host or frame, opts.levelOffset or -1)
        if not bg then return nil end
        AnchorPanel()
        Widget:Theme(bg, {
            thickness   = opts.thickness or 1,
            bgAlpha     = opts.bgAlpha or 0.85,
            borderAlpha = opts.borderAlpha,
            borderKey   = opts.borderKey,
            bgSurface   = opts.bgSurface,
        })
        Mark(bg, "skinPlate", true)
        Mark(bg, "panelTopExtend", topExtend)
        Mark(frame, "skinBg", bg)
        self:Track(bg)
    elseif (Marked(bg, "panelTopExtend") or 0) ~= topExtend then
        -- 背板是缓存的：opts 变了不能只靠 /reload。这两个点都写在**我们自己的**背板上，
        -- ClearAllPoints 不涉及任何暴雪框，不产生 taint（§8.62 的判例只禁 cf 本体）。
        pcall(bg.ClearAllPoints, bg)
        AnchorPanel()
        Mark(bg, "panelTopExtend", topExtend)
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
-- @param opts { bgSurface = "lost", bgAlpha = 0.96, borderKey =, thickness = }
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
        bgAlpha     = opts.bgAlpha or 0.96,
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
--- 列表行 / 按钮底这一类**新式 atlas**（11-05 子帧探针：社交窗 `friends-card-* ×12`、
--- `common-button-list/tertiary ×22` 全是 `α1.00 暴雪原样`，宿主是 ScrollBox 下第 4 层的匿名 Button）。
local ROW_ART_PATTERNS = {
    "friends%-card%-",
    "common%-button%-list",
    "common%-button%-tertiary",
}

--- 只压**认得出来的那几个** region：行里还有职业图标与名字，整框 `regions = true` 会把图标一起压掉
--- （AGENTS「必需件先注册、装饰件各自 pcall」同一纪律）。
--- 选中态（HIGHLIGHT 层）不压掉 —— 列表必须看得出选中，换成我们的 barfill 染边框色，
--- 读起来是"我们的行"而不是"暴雪的蓝条"。
function Skin:FadeRowArt(button)
    local okRegions, regions = pcall(function() return { button:GetRegions() } end)
    if not okRegions or type(regions) ~= "table" then return false end
    local touched = 0
    for _, reg in ipairs(regions) do
        -- 与 IsContentIcon 共用 ArtIdentity：atlas 与 file= 路径都认（P1-9）。
        -- 现有三条判据都是 atlas 专名，不会误命中路径；机制统一后补 file= 装饰判据即可生效。
        local low = ArtIdentity(reg)
        if low then
            for i = 1, #ROW_ART_PATTERNS do
                if low:find(ROW_ART_PATTERNS[i]) then
                    local isHighlight = false
                    if type(reg.GetDrawLayer) == "function" then
                        local okL, layer = pcall(reg.GetDrawLayer, reg)
                        isHighlight = okL and layer == "HIGHLIGHT"
                    end
                    if isHighlight then
                        if self:SwapArt(reg, "monet_barfill") then
                            local okC, r, g, b = pcall(Color.GetBorder, Color)
                            if okC and r and type(reg.SetVertexColor) == "function" then
                                reg:SetVertexColor(r, g, b, 0.45)
                            end
                            touched = touched + 1
                        end
                    else
                        self:Fade(reg)
                        touched = touched + 1
                    end
                    break
                end
            end
        end
    end
    return touched > 0
end

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
    -- 行底 / 按钮底的 atlas 家族（`friends-card-*`、`common-button-*`）：通用档压不到它们
    -- （那些图在 region 上，不是 NormalTexture），所以在这里单独认脸换掉。
    pcall(self.FadeRowArt, self, button)
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

--- §8.90 把 "#rrggbb" 解成 0..1 的 r,g,b；非法返回 nil（调用点走兜底）。
local function HexToRGB(hex)
    if type(hex) ~= "string" then return nil end
    local h = hex:gsub("#", "")
    if #h ~= 6 then return nil end
    local r, g, b = h:match("(..)(..)(..)")
    if not r then return nil end
    return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end

--- §8.90 读聊天页签三态配置色（Normal / Selected / Flash）。DB 没配或非法时走兜底：
--- 普通→主题边色（贴近旧观感），选中→白，未读→警示红。
local function TabColor(state)
    local db = (type(ns.DB) == "function") and ns:DB() or nil
    local cfg = db and db.skins
    local hex = cfg and cfg["tabColor" .. state]
    local r, g, b = HexToRGB(hex)
    if r then return r, g, b end
    if state == "Selected" then return 1, 1, 1 end
    if state == "Flash" then return 1, 0.42, 0.42 end
    local er, eg, eb = Color:GetBorder(); return er, eg, eb
end

--- §8.90 页签是否处于「未读闪烁」：暴雪把未读指示画在 `ChatFrameNTabFlash` 上，
--- 其 FlashAnim 在播放即代表未读。读不到 / 异常一律按「非闪烁」处理（保守，不误染）。
local function TabIsFlashing(tab)
    if type(tab.GetName) ~= "function" then return false end
    local ok, nm = pcall(tab.GetName, tab)
    if not ok or type(nm) ~= "string" or nm == "" then return false end
    local flash = _G[nm .. "TabFlash"]
    if not flash then return false end
    local okP, playing = pcall(function()
        return flash.FlashAnim and type(flash.FlashAnim.IsPlaying) == "function"
            and flash.FlashAnim:IsPlaying()
    end)
    return okP and playing or false
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

    -- §8.90 三态色：未读闪烁 > 选中 > 普通。普通保持 0.25 弱显（旧观感），选中 / 未读抬满。
    local flashing = TabIsFlashing(tab)
    local state = flashing and "Flash" or (selected and "Selected" or "Normal")
    local r, g, b = TabColor(state)
    local a = (selected or flashing) and 1 or 0.25
    underline:SetVertexColor(r, g, b, a)
    underline:Show()

    -- **整框 alpha 的鬼影**（2026-11-06 实机）：暴雪按"未读 / 非活动"把整个页签框淡到
    -- `0.4` / `0.2`（`ChatFrame1Tab`=0.4、`ChatFrame4Tab`=0.2），我们的贴图与文字挂在同一个框上，
    -- 跟着一起消失 ⇒ 页签"看着没换皮、像没字"。登记过 `tabFullAlpha` 的页签在这里把整框抬回 1，
    -- 选中与否**只由上面那条下划线表达**（与其余 48 个窗口同一语言）。
    -- 实测空闲时暴雪不会自己顶回来（写 1 后 0.2 / 0.6 / 1.5 / 3.0 秒复检都还是 1），
    -- 只有它自己的事件会重设 —— 这条跟着 0.5 秒轮询走，正好兜住那些时刻。
    if Marked(tab, "tabFullAlpha") then
        local S = ns.Secrets   -- 不能用文件末尾那个 `local Secrets`（它在下面 2200+ 行才声明，这里会是全局 nil）
        local ok, a = pcall(tab.GetAlpha, tab)
        local num = ok and type(a) == "number" and (not S or not S.IsSecret(a)) and a or nil
        if num and num < 0.99 then pcall(tab.SetAlpha, tab, 1) end
    end
end

--- 页签选中态的跟随：**不再 hooksecurefunc(PanelTemplates_SelectTab/DeselectTab)**。
--- 那是全局函数钩子 —— 任何面板切页签时都会在我们的代码里跑一段，整条调用链被记成
--- "tainted by MonetUI"（实机：进入编辑模式时 Blizzard 自己的小队框 setup 因此抛
--- "compare 'oldR' (secret ...)"）。改成 0.5 秒轮询所有装饰过的页签，重算选中态。
local tabWatch = setmetatable({}, { __mode = "k" })
local tabId

local function EnsureTabDriver(Skin)
    if tabId then return end
    tabId = Scheduler:Every(500, function()
        for tab in pairs(tabWatch) do
            pcall(Skin.UpdateTabState, Skin, tab)
        end
    end, "皮肤:Tab指示")
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
    -- 调用点传 `fullAlpha = true` ⇒ 这条页签不吃暴雪的"未读 / 非活动"整框淡化
    -- （判据与代价见 `UpdateTabState` 末段；聊天页签实测被压到 0.2~0.4）。
    -- 走 `ns:Mark` 的旁表，不往暴雪框上写字段。
    if opts and opts.fullAlpha then Mark(tab, "tabFullAlpha", true) end
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
            -- §8.90 下划线颜色由 UpdateTabState 按三态统一上色（不再硬编码主题边色）。
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
    -- 方向键有**两个来源**（11-05 实测）：老写法把它存成 Lua 字段（`button.upTexture`），
    -- 而 `CharacterStatsPaneScrollBox` / `ChatFrame1` 那批 MinimalScrollBar 只把它存在
    -- **安全属性**上（`frame:GetAttribute("upTexture")`）—— 字段读不到 ⇒ 旧版在这里返回 false，
    -- 于是原图被通用档压成 α0、V 形却没放上去（`arrows` 探针的"无我们的图"就是这一批）。
    local key = button.upTexture or button.normalTexture
    if type(key) ~= "string" and type(button.GetAttribute) == "function" then
        for _, attr in ipairs({ "upTexture", "normalTexture", "downTexture" }) do
            local okA, v = pcall(button.GetAttribute, button, attr)
            if okA and type(v) == "string" and v ~= "" and Secrets.CanRead(v) then
                key = v
                break
            end
        end
    end
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
    -- 我们自己的这张必须打上 `art` 标记：认脸（probeArt / arrows 探针）只信标记与字符串路径，
    -- 而我们的 BLP 加载后 GetTexture() 回的是**数字 ID**（11-05 实测 -1627）—— 不打标记
    -- 就会被判成"无我们的图"，明明补好了却查不出来（#44/#45 最后这层就是这个）。
    Mark(our, "art", true)
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

--- 窗口肖像的候选件（字段优先，字段都没有再看同名全局）。
--- 1.60 里肖像有三种放法，只认 `frame.Portrait` 会漏一半：
---   ① `PortraitFrameTemplate` 一族 —— `frame.Portrait` + `<窗口名>Portrait` 全局；
---   ② `PortraitContainer`（社会窗 / 世界地图 `BorderFrame` 上那个 1×1 宿主框，
---      里面挂 62×62 徽记贴图）—— **没有** `.Portrait` 成员，只能靠字段名认；
---   ③ `PortraitOverlay`（社会窗那层 814×426 覆盖层，里面 4 张 60×60 徽记）。
local PORTRAIT_FIELDS = { "Portrait", "PortraitContainer", "PortraitOverlay" }

local function IsButtonObject(obj)
    if type(obj) ~= "table" or type(obj.IsObjectType) ~= "function" then return false end
    local ok, v = pcall(obj.IsObjectType, obj, "Button")
    return (ok and v) or false
end

local function PortraitHosts(frame)
    local out = {}
    local hosts = { frame }
    local border = frame.BorderFrame
    if type(border) == "table" then hosts[#hosts + 1] = border end
    for _, host in ipairs(hosts) do
        for _, key in ipairs(PORTRAIT_FIELDS) do
            local obj = host[key]
            -- **按钮身上的 `Portrait` 不是肖像**：1.60 实测 `CharacterMicroButton.Portrait`
            -- 是颗 18×26 的 `RTPortrait1` 小图，那其实是微菜单按钮的脸（压掉就成了空白按钮）。
            -- 窗口肖像都挂在窗口 / BorderFrame 这类普通框上，所以按"宿主是不是按钮"就能分开。
            if type(obj) == "table" and key == "Portrait" and IsButtonObject(host) then obj = nil end
            if type(obj) == "table" then out[#out + 1] = obj end
        end
    end
    local okN, name = pcall(frame.GetName, frame)
    if okN and type(name) == "string" then
        local g = rawget(_G, name .. "Portrait")
        if type(g) == "table" then out[#out + 1] = g end
    end
    return out
end

--- 把一个肖像件压掉：贴图 → α0 + `SetShown(false)`；宿主框 → 递归它的贴图（深度 2）。
--- **3D 模型一律不碰**（`PlayerModel` / `DressUpModel`）：有些窗口的"肖像"是角色模型，
--- 那不是暴雪贴上去的美术，压不掉也不该压（角色窗 / 试衣间的模型要留着）。
local function HidePortraitTree(self, host, depth)
    if type(host) ~= "table" then return 0 end
    local okK, kind = pcall(host.GetObjectType, host)
    if not okK or type(kind) ~= "string" then return 0 end
    if kind == "Texture" then
        -- 直挂的"肖像"必须真有肖像那么大（窗口肖像 60–64px）。18×26 那类小图是按钮图标，
        -- 不进这层判据就会被当肖像压掉（`CharacterMicroButton` 判例）。
        if depth == 0 then
            local okW, w = pcall(host.GetWidth, host)
            local okH, h = pcall(host.GetHeight, host)
            if okW and okH and type(w) == "number" and type(h) == "number"
                and (w < 30 or h < 30) then
                return 0
            end
        end
        self:FadeHold(host)
        pcall(host.SetShown, host, false)
        return 1
    end
    if (kind ~= "Frame" and kind ~= "Button") or depth > 2 then return 0 end
    local n = 0
    local okR, regs = pcall(function() return { host:GetRegions() } end)
    if okR then
        for _, reg in ipairs(regs) do
            local okT, t = pcall(reg.GetObjectType, reg)
            if okT and t == "Texture" then
                self:FadeHold(reg)
                pcall(reg.SetShown, reg, false)
                n = n + 1
            end
        end
    end
    -- 子件也收（`CircleMask` 圆形遮罩 / 肖像外那圈金属边都在这一层）。
    local okC, kids = pcall(function() return { host:GetChildren() } end)
    if okC then
        for _, kid in ipairs(kids) do n = n + HidePortraitTree(self, kid, depth + 1) end
    end
    return n
end

--- 剥掉一个窗口的肖像（2026-11-13 作者口径："各个界面的 portrait 都要剥除掉"）。
---
--- 以前是逐窗口 opt-in（`opts.portrait`），于是没写这个开关的窗口各留一张圆肖像。
--- 一律**压 α0 + `SetShown(false)`**，不 `Hide()`：暴雪一 `Show` 就顶回来（§8.107 同族判例）；
--- 并且每次显示补一刀（`Widget:ShowWatch`，闭包按框缓存；`FadeHold` 顺便把被抬回 α1 的纠回来）。
---
--- 全局那一路直接 `rawget(_G, …)`、**不走 `Skin:Need`**：这是对每个美化窗口都跑的通用扫描，
--- 绝大多数窗口根本没有肖像 —— 走 Need 会给账本塞上百条"预期中的缺失"，把真缺失淹掉
--- （`Skins.lua` 里关闭按钮名字三路全空时的最后一路兜底也是这么写的）。
--- @return 这次压掉的贴图数（0 = 这个窗口没有肖像）
function Skin:HidePortraits(frame)
    if not frame or type(frame.GetRegions) ~= "function" then return 0 end
    local hosts = PortraitHosts(frame)
    local function pass()
        local n = 0
        for _, obj in ipairs(PortraitHosts(frame)) do
            n = n + HidePortraitTree(Skin, obj, 0)
        end
        return n
    end
    local n = pass()
    -- 没有肖像件的框**不挂轮询**：`M:Dress` 会给每个美化过的控件都调这里（窗口里成百颗按钮 / 行 / 格子），
    -- 每个都进 ShowWatch 表纯属浪费。LoD 窗口里"显示时才建出肖像"的情况由 `WindowShowPass` 每趟补，
    -- 那时 `PortraitHosts` 已经能认到，再挂也不迟。
    if #hosts > 0 and not Marked(frame, "portraitApply") then
        Mark(frame, "portraitApply", pass)
        if Widget and Widget.ShowWatch then Widget:ShowWatch(frame, pass) end
    end
    return n
end

--- 旧名（历史调用点仍用）：语义已并入 `Skin:HidePortraits`（以前叫"压成方形"，实为隐藏）。
function Skin:SquarePortrait(frame)
    return self:HidePortraits(frame) > 0
end

--- Restyle a scroll bar (track + arrows + thumb).
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
local arrowId

local function EnsureArrowDriver()
    if arrowId then return end
    arrowId = Scheduler:Every(300, function()
        for reg in pairs(arrowRegions) do
            if type(reg.GetAlpha) == "function" and type(reg.SetAlpha) == "function" then
                local ok, a = pcall(reg.GetAlpha, reg)
                if ok and type(a) == "number" and a > 0 then pcall(reg.SetAlpha, reg, 0) end
            end
        end
    end, "皮肤:箭头")
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
                -- 我们自己的这张必须打上 `art` 标记：认脸（probeArt / arrows 探针）只信标记与字符串路径，
                -- 而我们的 BLP 加载后 GetTexture() 回的是**数字 ID**（11-05 实测 -1627）—— 不打标记
                -- 就会被判成"无我们的图"，明明补好了却查不出来（#44/#45 最后这层就是这个）。
                Mark(our, "art", true)
                local r, g, b = Color:GetBorder()
                our:SetVertexColor(r, g, b)
                return true
            end
        end
    end
    return false
end

--- 逐帧处理一个候选：ScrollBox 细把手 + 步进/关闭按钮。
--- 从 ScanScrollArrows 抽出来，让同步整扫与 Async 切片走同一份逻辑（一处判据，不抄两遍）。
local function ScanArrowFrame(self, frame)
    if not Widget:Readable(frame) then return end
    pcall(function()
        if frame.Thumb and Widget:Readable(frame.Thumb) then
            self:ScrollThumb(frame.Thumb)
        end
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
        elseif frame.GetObjectType then
            local okK, kind = pcall(frame.GetObjectType, frame)
            isButton = okK and kind == "Button" or false
        end
        if isButton then
            self:ScrollArrowButton(frame)
            -- 关闭按钮按**美术签名**兜底：名字不可靠（12.x 有匿名的、也有不叫 CloseButton 的），
            -- 12.1.5 实测 53 只里 32 只还是暴雪原样（历史证据，5bc814e 正文）；
            -- 1.60 上这个数要重数才算，待 1.60 复验。见 Skin:CloseButtonByArt。
            self:CloseButtonByArt(frame)
            -- 右上角的两颗斜箭头（`RedButton-Expand*` / `RedButton-Condense*`）同一条口径：
            -- 它们也是匿名按钮、也铺在没被点名美化的窗口上（世界地图 / 公会 / 日历 / 转服提示…）。
            self:MaximizeMinimizeByArt(frame)
        end
        -- 滑条兜底：deep 窗口的滑条由 SweepDeep → SkinSlidersIn 接住，但懒建 / 没美化过的
        -- 窗口里的滑条（设置面板子页、编辑模式对话框这类）会漏 —— 与关闭按钮同一条口径
        -- （"全部统一"），全量扫碰上 Slider 就穿上。Skin:Slider 全链幂等，重复扫零成本。
        local isSlider = false
        if frame.IsObjectType then
            local okS, s = pcall(frame.IsObjectType, frame, "Slider")
            isSlider = (okS and s) or false
        elseif frame.GetObjectType then
            local okK, kind = pcall(frame.GetObjectType, frame)
            isSlider = okK and kind == "Slider" or false
        end
        if isSlider then
            self:Slider(frame)
        end
    end)
end

-- 当前在跑的切片句柄：ScanScrollArrows 重触发时先取消它，绝不让两片重叠（§8.56 的 cancel 守卫）。
local scrollScanJob = nil

--- 全局兜底：扫一遍所有帧，把 ScrollBox 的细把手 + 上下箭头都换上。
--- ScrollBox 的滚动条是匿名 Frame + .Thumb + 无名 atlas 箭头，而且标签页懒创建 ——
--- 逐帧换肤（SkinScrollsIn）常常赶不上。登录后延迟扫几遍兜底。
---
--- **必须跳过读不了的帧**：`EnumerateFrames` 会把这个客户端里所有帧都交给我们，其中包含
--- 被引擎接管的安全框（forbidden 对象，任何 `IsVisible` / `GetRegions` / `GetName` 都直接抛）。
--- 以前把它们一路喂下去，最后连 `HoverWatch` 都挂在了 forbidden 对象上（实机：一个匿名框每拍
--- 抛一条，暂停后 5 秒复检一次，全程只是噪声）。这个扫尾本来就是"能扫到就扫"，读不到直接放手。
---
--- **切片跑（#38 / §8.56）**：EnumerateFrames 全量 ~1.5 万框，同步整扫是"唯一真常驻掉帧点"。
--- 有 Async 任务器时把整扫包进协程、每 64 框 Checkpoint 一次（超帧预算即 yield 到下帧），箭头
--- 陆续涂好、肉眼无感；重触发先 Cancel 上一片再起新的。没有任务器（离线 harness / 老构建）退回
--- 同步整扫，行为与迁移前逐位一致。
function Skin:ScanScrollArrows()
    if type(EnumerateFrames) ~= "function" then return end

    -- 防两次切片重叠：先取消还在跑的上一片（Cancel 只摘句柄、不触发 onDone）。
    if scrollScanJob then
        pcall(scrollScanJob.Cancel)
        scrollScanJob = nil
    end

    local Async = ns.Async
    if not (Async and type(Async.Run) == "function") then
        local frame = EnumerateFrames()
        local guard = 0
        while frame and guard < 200000 do
            guard = guard + 1
            ScanArrowFrame(self, frame)
            frame = EnumerateFrames(frame)
        end
        return
    end

    local self_ref = self
    local job
    job = Async:Run(function()
        local frame = EnumerateFrames()
        local guard = 0
        while frame and guard < 200000 do
            guard = guard + 1
            ScanArrowFrame(self_ref, frame)
            frame = EnumerateFrames(frame)
            if guard % 64 == 0 then Async.Checkpoint() end
        end
    end, function()
        -- 只清自己这片：若期间已被重触发换成了新句柄，别把新的误清掉。
        if scrollScanJob == job then scrollScanJob = nil end
    end, "ScanScrollArrows")
    scrollScanJob = job
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
    -- 已经换上我们的 ✕：atlas 判据必然落空（SwapArt 走 SetTexture），但钮外面那层装饰框
    -- 会被暴雪抬回 α0.80 ⇒ 每趟补扫都要再压一次，不能跟着签名一起早退。
    -- （11-13 实机：SocialUIFrame / CommunitiesFrame 的 9 张 `hidden=Y` 而 α=0.80。）
    if Marked(button, "closeArt") then
        self:FadeChildBoxArt(button)
        return true
    end
    local tex = self:TexOf(button, "GetNormalTexture")
    if not tex then return false end
    local ok, atlas = pcall(tex.GetAtlas, tex)
    if not ok or type(atlas) ~= "string" then return false end
    if not atlas:lower():find("redbutton%-exit") then return false end
    self:CloseButton(button)
    return true
end

--- 窗口右上角"最大化 / 最小化"的**方向判据**：1.60 实测这两族是 24–28px 的圆钮，每颗挂 4 张
--- 同尺寸 region（normal / pressed / disabled / `RedButton-Highlight` 红环）—— **形状和尺寸都一样**，
--- 只有 atlas 名分得开：`RedButton-Expand*` = 右上箭头（最大化），`RedButton-Condense*` = 左下箭头。
--- ⚠ **`RedButton-MiniCondense` 一定要排除**：那是"收起 / 隐藏"的 20px 小圆钮（ReadyStatus 那种），
--- 名字里含 `Condense`，误中就把"收起"画成了"最小化"。
--- @return "max" | "min" | nil
function Skin:MaximizeMinimizeKind(button)
    local tex = self:TexOf(button, "GetNormalTexture")
    if not tex then return nil end
    -- **尺寸与族名是两道硬门**，缺一条就会误伤：
    --   ① 这批钮都是 24–28px 的方形圆钮；`Options_ListExpand_Left`（344×22 的行内展开条）、
    --      `BagSlotFrame_Expanded_Default`（37×37 的背包格）名字里也带 Expand，靠尺寸挡掉；
    --   ② 只认 `RedButton-` 前缀（暴雪标题栏那族），别的 atlas 里带 expand/condense 一律不碰。
    local w, h = 0, 0
    if type(button.GetWidth) == "function" then
        local okW, ww = pcall(button.GetWidth, button)
        if okW and type(ww) == "number" then w = ww end
    end
    if type(button.GetHeight) == "function" then
        local okH, hh = pcall(button.GetHeight, button)
        if okH and type(hh) == "number" then h = hh end
    end
    if w == 0 or h == 0 or w > 40 or h > 40 then return nil end
    local ok, atlas = pcall(tex.GetAtlas, tex)
    if not ok or type(atlas) ~= "string" then return nil end
    local low = atlas:lower()
    if not low:find("^redbutton%-") then return nil end
    if low:find("minicondense", 1, true) then return nil end
    if low:find("expand", 1, true) then return "max" end
    if low:find("condense", 1, true) or low:find("minimize", 1, true) then return "min" end
    return nil
end

--- 稳定引用的"一次 Show 就补一刀"回调（`Widget:ShowWatch` 按函数身份去重，不能现造闭包）。
local function FadeChildBoxOnShow(button)
    Skin:FadeChildBoxArt(button)
end

--- 暴雪窗口标题栏那族按钮（✕ / ↗ / ↙）下面都垫着一层装饰框：
--- **8 条 1px `UI-Frame-Inner*` 边线（α0.80）+ 一张 α0 底**，在 28×28 的钮外面画出一个方框。
--- 它不是 ARTWORK（我们的字形就在 ARTWORK 层），所以按层压：只压 BORDER / BACKGROUND，
--- 留 ARTWORK / HIGHLIGHT。✕ 那颗挂在 30×31 的子帧上，↗ / ↙ 挂在 31×31 上 —— 判据只看层、不看尺寸。
---
--- **必须每趟都跑，且不能排在"认没认出来"的早退之后**：`SwapArt` 已经把 normal 的 atlas 换成
--- 我们的贴图，重入时认图判据必然返回 nil —— 排在它后面，边线就永远压不掉（11-13 实机判例：
--- 手调 `MaximizeMinimize(mm2)` 得 `res=false`，8 条线原样 α0.80，画面上每颗箭头外面套一个方框；
--- ✕ 那颗同理，作者报的就是"close 的框也还在"）。
---
--- 还有两个**只在实机才看得见**的时序，合起来就是"为什么第一次没压掉"（11-13 全服扫描实测）：
--- ① 这批按钮的子帧是**显示时才建**的（皮肤在登录、窗口还藏着的时候跑一遍，`GetChildren()` 是空的）；
--- ② 有一部分窗口的边线会在 `OnShow` 之后被模板自己抬回 α0.80（`EditModeSystemSettingsDialog`
---    那一族实测 `marked=9` 却 `α=0.8`）。
--- ⇒ 每次压完再登记一次 `Widget:ShowWatch`：**下一次显示的那一拍补一刀**。走轮询，不写脚本槽。
--- @return 这次真正走过的 region 数（0 = 这颗钮身上没有那层装饰框）
function Skin:FadeChildBoxArt(button)
    if not button then return 0 end
    local okKids, kids = pcall(function() return { button:GetChildren() } end)
    if not okKids then return 0 end
    local n = 0
    for _, kid in ipairs(kids) do
        local okR, regs = pcall(function() return { kid:GetRegions() } end)
        if okR then
            for _, reg in ipairs(regs) do
                local layer = select(2, pcall(reg.GetDrawLayer, reg))
                if layer == "BORDER" or layer == "BACKGROUND" then
                    self:FadeHold(reg)
                    n = n + 1
                end
            end
        end
    end
    -- 只有"真走过装饰框"或"这会儿还没有子帧（可能是显示时才建的）"才挂 ShowWatch ——
    -- 我们自建的按钮（Widget:CloseButton 工厂）身上没有这层，没必要进显示轮询表。
    if (n > 0 or #kids == 0) and Widget and Widget.ShowWatch and not Marked(button, "boxWatch") then
        Mark(button, "boxWatch", true)
        Widget:ShowWatch(button, FadeChildBoxOnShow)
    end
    -- 第三种时序：皮肤跑的那一拍**窗口已经显示着**（LoD 包一打开就建、建完就是 shown），
    -- `ShowWatch` 的初值直接记成"显示着"、不会再触发一次 —— 法术书的 ✕ 就是这么漏掉的
    -- （11-13 实测：`PlayerSpellsFrameCloseButton` 装饰框 `vis=9/9` 原样）。
    -- ⇒ 补一次**一次性**延迟复检。`boxRetry` 标记保证每个钮最多补一刀（自建按钮没有子帧也不会无限链）。
    if #kids == 0 and C_Timer and C_Timer.After and not Marked(button, "boxRetry") then
        Mark(button, "boxRetry", true)
        C_Timer.After(1, function() Skin:FadeChildBoxArt(button) end)
    end
    return n
end

--- 把一颗暴雪圆钮换成我们的斜箭头（`monet_maximize_arrow` / `monet_minimize_arrow`）。
--- 四张 region 全换：normal / pushed / disabled 用同一张字形（状态靠染色分档），
--- `RedButton-Highlight` 是**红色圆环**，留着就在箭头外面套一圈红 ⇒ 压掉，悬停改由轮询把箭头
--- 从边框色抬到 highlight 色（和 close 用 hover 图表达悬停同一个用意）。
--- 幂等且**可重入**：方向认过之后记在旁表 `mmKind` 上（atlas 已被换掉，第二次再也读不出来）。
function Skin:MaximizeMinimize(button, kind)
    if not button then return false end

    self:FadeChildBoxArt(button)

    kind = kind or Marked(button, "mmKind") or self:MaximizeMinimizeKind(button)
    if not kind then return false end
    Mark(button, "mmKind", kind)

    local key = (kind == "max") and "monet_maximize_arrow" or "monet_minimize_arrow"

    local normal   = self:SwapArt(self:TexOf(button, "GetNormalTexture"), key)
    local pushed   = self:SwapArt(self:TexOf(button, "GetPushedTexture"), key)
    local disabled = self:SwapArt(self:TexOf(button, "GetDisabledTexture"), key)
    self:FadeHold(self:TexOf(button, "GetHighlightTexture"))

    local function tint(r, g, b)
        if normal and normal.SetVertexColor then pcall(normal.SetVertexColor, normal, r, g, b) end
        if pushed and pushed.SetVertexColor then pcall(pushed.SetVertexColor, pushed, r, g, b) end
    end

    -- 染色 / 主题钩子 / 悬停只登记一次：重入时再写一次基础色会把正悬停的箭头压回边框色。
    if not Marked(button, "mmTint") then
        Mark(button, "mmTint", true)
        local br, bg, bb = Color:GetBorder()
        tint(br, bg, bb)
        if disabled and disabled.SetVertexColor then
            -- 禁用档：同一张字形压暗一档（不跟主题走 —— 禁用就该比常态退后一步）。
            pcall(disabled.SetVertexColor, disabled, 0.60, 0.60, 0.60)
        end
        self:OnTheme(function()
            local nr, ng, nb = Color:GetBorder()
            tint(nr, ng, nb)
        end)
        -- 悬停：箭头抬到 highlight 档（轮询，不写暴雪脚本槽）。
        Widget:HoverWatch(button, function()
            local hr, hg, hb = Color:GetHighlight()
            tint(hr, hg, hb)
        end, function()
            local nr, ng, nb = Color:GetBorder()
            tint(nr, ng, nb)
        end)
    end
    return true
end

--- 按美术签名兜底（配合 `Skin:ScanScrollArrows` 的全量扫描，覆盖没被点名美化的窗口）。
function Skin:MaximizeMinimizeByArt(button)
    if not button then return false end
    -- 全量扫描会拿上万颗按钮来问：先走便宜的旁表 / atlas 判据，不是方向钮就直接走人
    -- （否则每颗按钮都要 GetChildren + GetRegions 扫一遍，纯浪费）。
    if not Marked(button, "mmKind") and not self:MaximizeMinimizeKind(button) then return false end
    -- 直接交给 `MaximizeMinimize`：它认旁表里的 `mmKind`，重入（atlas 已换）也照样把子件补齐。
    return self:MaximizeMinimize(button)
end

--- 稳定引用：容器每次显示再扫一遍（`Widget:ShowWatch` 按函数身份去重，不能现造闭包）。
local function MaximizeMinimizeFrameOnShow(host)
    Skin:MaximizeMinimizeFrame(host)
end

--- 一个 `MaximizeMinimizeFrame` 里全是方向钮（CommunitiesFrame 实测两颗 28×28）。
---
--- **必须给容器登记显示轮询**：世界地图 / 试衣间那两颗在登录那一拍是 **0x0**（窗口还藏着，
--- 模板没给尺寸），`MaximizeMinimizeKind` 的尺寸门直接判 nil；而 `MaximizeMinimizeSweep`
--- 从窗口根只走 2 层，够不到 `WorldMapFrame → BorderFrame → MaximizeMinimizeFrame → 按钮`
--- 这第 3 层 ⇒ 少了这一条，这两颗永远是暴雪红钮（11-13 实机：atlas 仍是
--- `RedButton-Expand` / `RedButton-Condense`、尺寸 0x0）。显示那一拍尺寸落地，重扫即命中。
function Skin:MaximizeMinimizeFrame(host)
    if not host then return 0 end
    local ok, kids = pcall(function() return { host:GetChildren() } end)
    if not ok then return 0 end
    local n = 0
    for _, btn in ipairs(kids) do
        if self:MaximizeMinimizeByArt(btn) then n = n + 1 end
    end
    if not Marked(host, "mmFrameWatch") then
        Mark(host, "mmFrameWatch", true)
        if Widget and Widget.ShowWatch then Widget:ShowWatch(host, MaximizeMinimizeFrameOnShow) end
    end
    return n
end

--- 方向钮的"浅层扫"：不是每个窗口都把 ↗ / ↙ 放进 `MaximizeMinimizeFrame`。
--- 1.60 实测**法术书 `PlayerSpellsFrame` 的两颗直接挂在窗口下**（没有那个容器字段），
--- 而且它们是 `Blizzard_PlayerSpells` 这个 LoD 包**打开时才建**的 —— 登录后的全局扫描（`ScanScrollArrows`）
--- 那会儿根本扫不到，所以作者看到的是"法术书的 max/min 没处理"。
--- 做法：从窗口往下走 `depth` 层（窗口 → 标题容器 → 按钮 就够），每颗按钮仍交给
--- `MaximizeMinimizeByArt` 认 atlas 签名（尺寸 + `RedButton-` 前缀两道门），认不出的一律不碰。
function Skin:MaximizeMinimizeSweep(root, depth)
    if not root then return 0 end
    depth = depth or 2
    local self_ref = self
    local n = 0
    local function walk(host, d)
        local ok, kids = pcall(function() return { host:GetChildren() } end)
        if not ok then return end
        for _, kid in ipairs(kids) do
            local isBtn = false
            if type(kid.IsObjectType) == "function" then
                local okB, v = pcall(kid.IsObjectType, kid, "Button")
                isBtn = (okB and v) or false
            end
            if isBtn then
                if self_ref:MaximizeMinimizeByArt(kid) then n = n + 1 end
            elseif d < depth then
                walk(kid, d + 1)
            end
        end
    end
    walk(root, 1)
    return n
end

--- 稳定引用：`Widget:ShowWatch` 按函数身份去重，不能现造闭包。
local function MaximizeMinimizeOnShow(frame)
    Skin:MaximizeMinimizeSweep(frame, 2)
end

--- 给一个窗口登记"每次显示扫一遍方向钮"（幂等：旁表标记只挂一次）。
function Skin:WatchMaximizeMinimize(frame)
    if not frame then return end
    self:MaximizeMinimizeSweep(frame, 2)
    if Marked(frame, "mmSweep") then return end
    Mark(frame, "mmSweep", true)
    if Widget and Widget.ShowWatch then Widget:ShowWatch(frame, MaximizeMinimizeOnShow) end
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

--- 聊天窗那枚"滚回底部"提示箭头（`ChatFrameN.ScrollToBottomButton`，17×15）。
--- **只能换皮，不能藏**（2026-11-06 实机 + Aurora 同一判据：
--- `Blizzard_ChatFrameBase/Mainline/FloatingChatFrame.lua:154-162`）：窗口被往上滚期间，暴雪用
--- **alpha 动画**逐帧重放它的 `.Flash`（一层 ADD 混合的淡三角）—— `Skin:Fade` 与 `arrowRegions`
--- 那套"压 α0 + 驱动持续压回"都会被动画顶回去，于是玩家看到的是"切页 / 滚过之后，边框外侧
--- 冒出一枚暴雪原样的箭头"（`.Flash` 平时 `IsShown()=false`，所以静止状态扫描一条都抓不到）。
--- 换皮之后：动画脉冲的是我们自己的 V 形，"下面还有未读"这个功能信号也保住。
--- **五层都要换**：Normal / Highlight / Pushed / Disabled + `.Flash`，少一层就还剩一层原样。
function Skin:ChatScrollAlert(button)
    if not button or Marked(button, "chatScrollAlert") then return false end
    local swapped = 0
    local function one(tex)
        if not tex then return end
        local ours = self:SwapArt(tex, "monet_chevron_up")
        if ours then
            Widget:Arrow(ours, "down")
            swapped = swapped + 1
        end
        return ours
    end
    local normal = one(self:TexOf(button, "GetNormalTexture"))
    one(self:TexOf(button, "GetHighlightTexture"))
    one(self:TexOf(button, "GetPushedTexture"))
    one(self:TexOf(button, "GetDisabledTexture"))
    -- Flash 是字段而不是贴图槽，而且它是 ADD 混合：换成我们的白色模具后 ADD 会烧成一团白光，
    -- 所以连混合模式一起改成 BLEND（Aurora 同一处理，`flash:SetBlendMode("BLEND")`）。
    local flash = button.Flash
    if flash and type(flash.GetAtlas) == "function" then
        local ours = self:SwapArt(flash, "monet_chevron_up")
        if ours then
            Widget:Arrow(ours, "down")
            pcall(ours.SetBlendMode, ours, "BLEND")
            swapped = swapped + 1
        end
    end
    if swapped == 0 then return false end
    Mark(button, "chatScrollAlert", true)
    if normal and normal.SetVertexColor then
        local r, g, b = Color:GetBorder()
        normal:SetVertexColor(r, g, b)
        self:OnTheme(function()
            local nr, ng, nb = Color:GetBorder()
            if normal.SetVertexColor then normal:SetVertexColor(nr, ng, nb) end
        end)
    end
    return true
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
--- 输入框换皮：`opts` 可传 `bgAlpha` / `borderAlpha`（§8.94 聊天窗用它对齐底板与边框浓度）。
--- 不传时维持历史默认 0.9/主题边 —— 其他窗口的搜索框/输入框行为不变。
function Skin:EditBox(editBox, opts)
    if not editBox then return editBox end
    opts = opts or {}

    self:Fade(editBox.Left)
    self:Fade(editBox.Middle)
    self:Fade(editBox.Right)
    self:Strip(editBox, { regions = true, keep = KeepEditBoxArt })
    self:ControlBg(editBox, { bgAlpha = opts.bgAlpha or 0.9, borderAlpha = opts.borderAlpha })
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

    -- 先压掉钮外面那层 1px 装饰方框（8 条 `UI-Frame-Inner*`，α0.80）。**放在最前面**：
    -- 这步与"这张图是不是暴雪的 ✕"无关，重入时 atlas 早已被换掉、上面的签名判据必然落空，
    -- 排在判据后面就永远压不掉（11-13 作者实测："close 的框也还在"）。
    self:FadeChildBoxArt(button)

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
    -- 补扫认钮只靠这个标记：换过图之后 atlas 签名就没了（见 CloseButtonByArt）。
    Mark(button, "closeArt", true)
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
local cropId

--- 摘掉一张贴图上的**全部**遮罩，返回被摘掉的清单（供回滚重新挂回）。
-- 2026-11-06 补：客户端**拒绝给带遮罩的贴图 SetTexCoord**（"Cannot set tex coords when
-- texture has mask"），于是 CropIcon 里那个 `pcall(SetTexCoord)` 一直静默失败 —— 裁剪
-- 从来没生效过，而驱动帧每 0.5s 重试也永远失败。本客户端的物品格 `IconMask`、动作条
-- `IconFrame` 遮罩都会触发；对齐 Aurora 12.1.5.3 的同一处修复（`Base.CropIcon` 先倒序
-- 摘遮罩）。**倒序**是必须的：摘掉一个会让后面的索引整体前移。
-- 只调方法、不写字段，符合 AGENTS 的污染纪律；读写全部 pcall（forbidden 对象上连
-- `GetNumMaskTextures` 都可能抛）。
-- @return table 被摘下的遮罩数组（可能为空）
function Skin:StripMasks(tex)
    local removed = {}
    if not tex
        or type(tex.GetNumMaskTextures) ~= "function"
        or type(tex.RemoveMaskTexture) ~= "function" then
        return removed
    end
    local ok, n = pcall(tex.GetNumMaskTextures, tex)
    if not ok or type(n) ~= "number" then return removed end
    for i = n, 1, -1 do
        local okM, mask = pcall(tex.GetMaskTexture, tex, i)
        if okM and mask then
            local okR = pcall(tex.RemoveMaskTexture, tex, mask)
            if okR then removed[#removed + 1] = mask end
        end
    end
    return removed
end

--- 摘遮罩 + 记账：**CropIcon 与裁切驱动共用这一个入口**。
--- 摘下的遮罩累积进同一个旁表清单（`cropMasks`），关掉美化时倒序挂回去；undo 只登记一次。
--- 为什么要共用：驱动每拍补摘时如果另起一份清单，回滚就只还第一次摘的那批，
--- 后来被模板挂回、又被我们摘掉的遮罩永久丢失。
local function CropMasksOff(icon)
    local removed = Skin:StripMasks(icon)
    if #removed == 0 then return end
    local list = Marked(icon, "cropMasks")
    if type(list) == "table" then
        -- list 与 undo 闭包捕获的是同一张表，追加即进回滚清单。
        for i = 1, #removed do list[#list + 1] = removed[i] end
        return
    end
    Mark(icon, "cropMasks", removed)
    Skin:Record(function()
        if type(icon.AddMaskTexture) == "function" then
            for i = #removed, 1, -1 do pcall(icon.AddMaskTexture, icon, removed[i]) end
        end
        Mark(icon, "cropMasks", nil)
    end)
end

local function EnsureCropDriver()
    if cropId then return end
    cropId = Scheduler:Every(500, function()
        for icon, c in pairs(cropped) do
            if type(icon.SetTexCoord) == "function" then
                -- **每拍都要看遮罩有没有被挂回来**：有些模板在贴图更新时重新 AddMaskTexture，
                -- 而带遮罩的贴图 SetTexCoord 会被客户端直接拒（"Cannot set tex coords when
                -- texture has mask"）。以前这里用 `stripped[icon]` 只摘第一次，之后遮罩一回来
                -- 裁剪就永久失效 —— 这正是"LoD 图标裁切失效"的第二条根因。
                if type(icon.GetNumMaskTextures) == "function" then
                    local okN, n = pcall(icon.GetNumMaskTextures, icon)
                    if okN and type(n) == "number" and n > 0 then CropMasksOff(icon) end
                end
                pcall(icon.SetTexCoord, icon, c[1], c[2], c[3], c[4])
            end
        end
    end, "皮肤:裁切")
end

function Skin:CropIcon(icon, x0, x1, y0, y1)
    if not icon or type(icon.SetTexCoord) ~= "function" then return icon end
    x0, x1 = x0 or 0, x1 or 1
    y0, y1 = y0 or 0, y1 or 1

    -- **先摘遮罩再裁剪**（顺序反了 SetTexCoord 会被拒）。摘下的留着，关掉美化时挂回去。
    CropMasksOff(icon)

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

--- 方形裁剪的**圆形**版：清掉贴图自身的 mask、藏掉框上的 `CircleMask`，再走方形裁剪。
-- 与 Aurora `Base.CropCircularIcon` 同语义；本客户端没有 `SetMask("")` 时靠 StripMasks 兜底。
function Skin:CropCircularIcon(icon, parent)
    if not icon then return icon end
    if type(icon.SetMask) == "function" then pcall(icon.SetMask, icon, "") end
    local frame = parent or (type(icon.GetParent) == "function" and icon:GetParent())
    if frame and frame.CircleMask and type(frame.CircleMask.Hide) == "function" then
        pcall(frame.CircleMask.Hide, frame.CircleMask)
    end
    return self:CropIcon(icon)
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
local qualityId

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
--- 取值函数提出去复用：`pcall(function() return btn.link end)` 这种写法每次调用都新建
--- 一个闭包 —— 品质驱动每 0.5 秒扫一遍所有格子（背包 100+ 格），一秒就是几百次分配。
local function ReadLink(btn) return btn.link end
local function ReadItemID(btn) return btn.itemID end
local function LocIsValid(loc) return loc:IsValidItem() end

local function ResolveQuality(btn)
    local okLink, link = pcall(ReadLink, btn)
    if okLink and type(link) == "string" and link ~= "" then
        local q = QualityOf(link)
        if q then return q end
    end
    local okID, itemID = pcall(ReadItemID, btn)
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
            local okV, valid = pcall(LocIsValid, loc)
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

--- 物品格三件套里"等级数字"字体的统一创建：10px 点阵 + 描边、主题亮色（不是品质色 ——
--- 紫装上的紫字读不出来，边框已经替品质说过一次话），压在 OVERLAY 9 层（图标被抬到
--- OVERLAY 7，数字要盖过它）。共享原语（CharacterFrame / 交易）与背包 / 银行格（Modules/Bags）
--- 都走这一档，字体口径不再各写各的。
function Skin:SlotInfoFont(btn)
    local fs = Widget:Font(btn, 10, "pixel", "bright", "LEFT", "OVERLAY",
                            "THICKOUTLINE, MONOCHROME")
    fs:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
    fs:SetDrawLayer("OVERLAY", 9)
    return fs
end

--- 等级数字的统一取词口径：过 `Secrets.Number`（受限环境 `C_Item.GetItemInfo` 第 4 返回
--- 可能是机密值），>0 才写（材料 / 布料的 ilvl 是 0 或 nil ⇒ 一个字都不写，不画"0"），
--- floor 成整数。吃"已经拿到的原始值"，不管它是 rec.ilvl 还是 GetItemInfo 返回值。
function Skin:SlotInfoText(raw)
    local n = Secrets.Number(raw)
    if n and n > 0 then return tostring(math.floor(n)) end -- TAINT-OK: Secrets.Number 守卫
    return ""
end

--- 物品冷却遮罩的统一绘制：三个返回值全过 `Secrets.Number`，拿不到明文就不画；
--- `duration > 0` 且 `enable ~= 0` 才 Show + SetCooldown，否则 Hide。itemID / getter 缺失
--- 同样 Hide（背包格子是**复用池**，上一件留下的遮罩不显式收就会画在空位上）。
--- 两边都只吃 `C_Container.GetItemCooldown`，所以 getter 固定，不再参数化。
function Skin:ApplySlotCooldown(cd, itemID)
    if not cd then return end
    local getter = C_Container and C_Container.GetItemCooldown
    local start, duration, enable
    if itemID and getter then
        local ok, s, d, e = pcall(getter, itemID)
        start, duration, enable = ok and Secrets.Number(s) or nil, Secrets.Number(d), Secrets.Number(e)
    end
    if start and duration and duration > 0 and enable ~= 0 then -- TAINT-OK: 三个数全过 Secrets.Number
        cd:Show()
        if not pcall(cd.SetCooldown, cd, start, duration) then cd:Hide() end -- TAINT-OK: Secrets.Number + pcall 兜底；物品冷却没有 duration-object API（那条只服务 GetActionCooldownDuration 的动作槽）
    else
        cd:Hide()
    end
end

--- 等级 + 冷却（人物面板装备格用；背包 / 我们自己的银行格也共用上面那三个 `Skin:Slot*` 原语，
--- 差别只在身份来源：这里从按钮字段反推，那边从 `bagRec` 权威 rec 直取）。
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
                    text = Skin:SlotInfoText(ok and lv or nil)
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
        Skin:ApplySlotCooldown(cd, ItemIDOf(entry.itemKey))
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

local function SnapQualityBorder(btn, border, entry)
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
    -- 算出来的四个偏移没变就别重设锚点（ClearAllPoints + 2×SetPoint = 3 次 pcall，
    -- 而格子不动的时候这个结果是不变的 —— 见 EnsureQualityDriver 的注释）。
    if entry then
        if entry.xl == xl and entry.xr == xr and entry.yb == yb and entry.yt == yt then return end
        entry.xl, entry.xr, entry.yb, entry.yt = xl, xr, yb, yt
    end
    pcall(border.ClearAllPoints, border)
    pcall(border.SetPoint, border, "BOTTOMLEFT", btn, "BOTTOMLEFT", xl, yb)
    pcall(border.SetPoint, border, "TOPRIGHT", btn, "BOTTOMLEFT", xr, yt)
end

--- 边框在不在屏幕上（品质驱动用来跳过藏着的格子）。读不出来 / 机密值一律按"显示着"
--- 处理 —— 保守方向：宁可多算一次，也不要因为读不到就漏掉一个真在屏幕上的格子。
local function BorderShown(border)
    local ok, vis = pcall(border.IsVisible, border)
    if not ok then return true end
    if Secrets and Secrets.IsSecret and Secrets.IsSecret(vis) then return true end
    return vis and true or false
end

local function EnsureQualityDriver()
    if qualityId then return end
    qualityId = Scheduler:Every(500, function()
        for btn, entry in pairs(qualityBorders) do
            local border = entry.frame
            if border and border.GetAlpha then
                -- 藏着的格子整条跳过。2026-11-07 实机 `/mui perf`：这一路每次 2.57ms
                -- （每 0.5 秒一记尖峰，占 16% 帧预算），而当时背包是关着的 —— 也就是
                -- 100 多个看不见的格子在白算像素对齐（AbsRectUnits 每层父链两次 pcall）
                -- 和品质解析。边框藏着自己会跟着藏，状态留着不动没有副作用；重新显示后
                -- 下一拍（≤0.5 秒）补算一次。
                local shown = BorderShown(border)
                if shown then
                    SnapQualityBorder(btn, border, entry)
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
                    -- 等级 + 冷却只在显式开过格（CharacterFrame 的装备格）上跑：
                    -- 商人 / 邮件那些同走这条扫描的窗口一个字节都不多写。
                    if entry.ilvl or entry.cd then UpdateSlotInfo(btn, entry) end
                end
            end
        end
    end, "皮肤:品质染色")
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
    -- 只认"真的造出了背板"的条目：以前 `NewBackdropFrame` 返回 nil 时照样往下走，
    -- `Widget:Theme(nil, …)` 抛错被上层 `M:Controls` 的 pcall 吞掉 ⇒
    -- 11-05 商人格"品质边框一个都没加上"在日志里完全看不见（第三次栽在"静默失败"上）。
    if entry and not entry.frame then entry = nil end
    if not entry then
        local border = NewBackdropFrame(btn, 1)
        if not border then
            local who = tostring((type(btn.GetName) == "function" and btn:GetName()) or "匿名格")
            Skin:WarnOnce("qualityBorder:" .. who,
                ("造不出品质边框的背板框：%s（IsScriptObject=%s）")
                    :format(who, tostring(self:IsScriptObject(btn))))
            return btn
        end
        Widget:Theme(border, { thickness = 1, bgAlpha = 0 })
        -- 留一个可认脸的标记：以前这颗边框只有 `qualityBorders` 私有表知道，
        -- 于是 `probeState` 与现场排查都把它读成"不是我们的"（11-05 商人窗误判就是这么来的）。
        Mark(border, "qualityBorder", true)
        self:Track(border)
        entry = { frame = border }
        qualityBorders[btn] = entry
        SnapQualityBorder(btn, border, entry)
        EnsureQualityDriver()
    end
    if withInfo and not entry.ilvl then
        entry.ilvl = Skin:SlotInfoFont(btn)
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

    local okAtlas, atlas = pcall(icon.GetAtlas, icon)
    if okAtlas and type(atlas) == "string" then return icon end
    -- **标记落在 atlas 门之后**：LoD 包的图标在登录那拍可能还挂着占位 atlas（或根本还没
    -- 贴图），先落标记就等于把它永久排除 —— 之后补扫进来只读到 icon=Y，裁切再也不会做。
    -- 门没过就不标记，下一趟贴图落地了再来（与 IconWidgetsIn 的 iconFlat 同一条口径）。
    Mark(icon, "icon", true)
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
-- 上限提到 1500：11-05 实测商人窗 600 件就截断，"看得见 184"其实是个**下限数**——
-- 报出下限却不标注，和报假数一样糟（`到上限截断` 那面旗仍然留着）。探针是按需跑的，成本可接受。
local MAX_PROBE_NODES, MAX_PROBE_DEPTH, MAX_PROBE_PRINT, MAX_PROBE_REGIONS = 1500, 6, 20, 24

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
    -- 裁成方形的肖像：图集**仍然是那张肖像图**（我们只改 texcoord 与位置），
    -- 所以不能落到下面"暴雪原样"那一档 —— 11-05 就因为这条口径，`layers` 把已经裁好、
    -- 已在框内的 `SocialUIFramePortrait` 报成"暴雪原样"，差点又被当成没做。
    if Marked(obj, "portraitSquared") then return "我们的肖像(已裁方)", false end
    -- 格子品质边框：也是"我们的东西"，以前探针认不出（11-05 商人窗误判的源头）
    if Marked(obj, "qualityBorder") then return "我们的格子边框", false end
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
