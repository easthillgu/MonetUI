-- Utils/Color.lua
-- Colour access layer: LibMonetColor-1.0 integration with a graceful fallback.
-- "5 + 3" model (see MonetUI.md): functional 5 (primary / health / resource / danger / neutral) + signature 3 (edge glow / ambient tint / highlight wash).
-- Only the signature colours (plus the Monet neutral) come from the engine; health / resource / danger stay UI-managed on purpose (they must never be "Monetised").
-- On top of the 5+3 sits the **surface ladder** (GetSurface): five CIE L* levels -- panel / hover / lost / weave / fill -- recomputed once per theme refresh. The engine gives hue, the ladder gives separation; bar contrast is the consumer's job (see docs/HANDOFF.md 8.14.3).

local ADDON_NAME, ns = ...

local LibStub = _G.LibStub
local LMC = LibStub and LibStub("LibMonetColor-1.0", true)
local Secrets = ns.Secrets      -- Secrets.lua 在本文件之前加载（见 Utils.xml）

-- 2026-11-12 作者拍板：默认（fallback）环境色 = 河林（mapID 2548，MonetColorMapData 实测行）。
-- 引擎解析序 override -> data -> C_Map 父链 -> fallbackEnv（LibMonetColor:580-611），
-- 原默认是无彩中灰 { h=0, s=0, l=0.5 }；此后认不出的地图一律按河林环境派生，
-- 与作者常驻地观感一致。走引擎官方通道（SetFallbackEnv 内部 ClearCache+Refresh；
-- 本文件加载时还没有消费者订阅 OnThemeColorsChanged，那次刷新只重算缓存、不广播重涂
-- —— 与 MonetColorMapEnvOverride 的加载期论证同一条）。
if LMC and type(LMC.SetFallbackEnv) == "function" then
    pcall(LMC.SetFallbackEnv, LMC, 137.6, 0.305, 0.269)
end

local Color = {}
ns.Color = Color

-- Palette used when LibMonetColor is missing or the user turns the engine off.
-- 2026-11-12 作者拍板：默认配色 = 河林（mapID 2548，h=137.6 s=0.305 l=0.269）。
-- signature 3 + primary 的数值是**实机**把河林环境喂给引擎公共函数
-- （LMC.ComputeEdgeColor / ComputeAmbientTint / ComputeHighlightWash / ComputeNeutral
-- + GetRules）算出的逐位结果，不是手调 —— 引擎规则改版后应重跑一遍再同步这里。
-- highlight / neutral 的引擎函数不返回 alpha，沿用原有 alpha（engine-on 时 Theme()
-- 这两个 alpha 也永远取本表，两条路径观感一致）；health / resource / danger 是
-- 功能色，设计上不 Monet 化（见文件头注释），不跟着环境换。
local FALLBACK = {
    edge      = { r = 0.809, g = 0.653, b = 0.763, a = 0.800 },  -- 河林 edge（引擎实测）
    ambient   = { r = 0.261, g = 0.248, b = 0.290, a = 0.253 },  -- 河林 ambient（引擎实测）
    highlight = { r = 0.497, g = 0.541, b = 0.532, a = 0.50 },   -- 河林 highlight（RGB 引擎实测）
    neutral   = { r = 0.726, g = 0.736, b = 0.729, a = 0.85 },   -- 河林 neutral（RGB 引擎实测）

    health    = { r = 0.20, g = 0.80, b = 0.20, a = 1.00 },
    resource  = { r = 0.20, g = 0.50, b = 0.90, a = 1.00 },
    danger    = { r = 0.90, g = 0.20, b = 0.20, a = 1.00 },
    primary   = { r = 0.809, g = 0.653, b = 0.763, a = 1.00 },   -- 河林 edge RGB
}

-- 亮度阶梯（CIE L*）：把"窗口底衬 / 悬停底衬 / 掉血空槽 / 织纹 / 血条填充"五档在同一个色相家族里拉开。
-- 数字的来由见 docs/HANDOFF.md 8.14.3：这层之前是 ambient×0.35（面板）对 neutral×0.32（空槽），
-- 14 个区域实测两者对比度只有 1.00–1.19 —— 不是"颜色不对"，是亮度几乎重合，所以怎么换色相都分不开。
-- 阶梯只动亮度，色相仍由引擎给（下面 SURFACE_HUE / SURFACE_INVERT 那三行是 2026-10-25 配色案，不改）。
-- hover 那一档是"鼠标压在这块底衬上"：panel +3 L*（2026-11-02 真像素候选实测，正文 neutral 对比度
-- 5.72 → 5.38，仍在 4.5 线内；天花板实测在 +10）。它必须是一档**命名**的阶梯，
-- 不是调用点现算的乘数 —— 见 docs/DESIGN-LANGUAGE.md §3。
local SURFACE_KEYS = { "panel", "hover", "lost", "weave", "fill" }
local SURFACE_STEPS = {
    panel = 10,   -- 窗口底衬：近乎无光，只负责承托内容
    hover = 13,   -- 悬停底衬：只比面板亮 3 L*，读作"亮了一点"而不是"换了一块板"
    lost  = 28,   -- 掉血空槽：比面板亮一档，"少了的那截血"要看得出来
    weave = 40,   -- 织纹发丝线：压在空槽之上、比填充暗，读作布纹而不抢血量
    fill  = 46,   -- 血条填充：整条里最亮的一档
}

-- 每档吃哪个色相。fill 不在表里 = 走 edge 的 RGB 反相（保持"反色血条"的招牌识别）。
-- hover 和 panel 同色相（ambient）：悬停只许动亮度，动色相就成了"你的颜色"，那是 §7-a 的边界。
local SURFACE_HUE = { panel = "ambient", hover = "ambient", lost = "neutral", weave = "neutral" }

-- 引擎没带 1.2.0 工具函数（老 vendored 副本）时的回退乘数：就是这层之前各调用点自己写死的那几个数，
-- 逐位一致，所以缺工具函数只是"回到旧观感"，不会算出别的颜色。
local SURFACE_MUL_LEGACY = { panel = 0.35, hover = 0.40, lost = 0.32, weave = 1, fill = 1 }

local theme
local surface
local useMonetColor = true

local function clamp01(v)
    if type(v) ~= "number" then return nil end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

--- 引擎工具函数的唯一入口：老 vendored 副本没有 1.2.0 的 AtLightness / RGBToLab /
-- ContrastRatio，名字查不到、调用抛错、返回不是数都算「拿不到」，一律回 nil 让调用方
-- 退回旧观感（AtLightness 回三值，所以数到第一个非数为止全部转发）。
-- pcall 这层不许省：实机教训是缺守卫时引擎一抛就带崩整次主题刷新。
local function optionalLMC(name, ...)
    if not (LMC and type(LMC[name]) == "function") then return nil end
    local args = { ... }
    local ok, results = pcall(function()
        local out = {}
        for i, v in ipairs({ LMC[name](unpack(args)) }) do
            if type(v) ~= "number" then break end
            out[i] = v
        end
        return out
    end)
    if not ok or #results == 0 then return nil end
    return unpack(results)
end

--- 把一块颜色放到指定的 CIE L*（色相、饱和都不动）。
-- 拿不到结果就返回 nil 让调用方退回旧乘数。
local function place(r, g, b, targetL)
    local pr, pg, pb = optionalLMC("AtLightness", r, g, b, targetL)
    local cr, cg, cb = clamp01(pr), clamp01(pg), clamp01(pb)
    if not (cr and cg and cb) then return nil end
    return cr, cg, cb
end

local function lightnessOf(c)
    return optionalLMC("RGBToLab", c.r, c.g, c.b)
end

local function contrastOf(a, b)
    return optionalLMC("ContrastRatio", a.r, a.g, a.b, b.r, b.g, b.b)
end

--- 一档阶梯的最终颜色：先按 L* 重定位（色相家族不变），拿不到就退回旧的固定乘数。
-- fill 档不在 SURFACE_HUE 里 = edge 的 RGB 反相（先反相再定位），旧口径是反相后直接用。
local function surfaceColor(t, key, step)
    local srcKey = SURFACE_HUE[key]
    local src = t[srcKey or "edge"] or t.neutral
    local r, g, b = src.r, src.g, src.b
    if not srcKey then
        r, g, b = 1 - (r or 0), 1 - (g or 0), 1 - (b or 0)
    end
    local pr, pg, pb = place(r, g, b, step)
    if not pr then
        local mul = SURFACE_MUL_LEGACY[key]
        return r * mul, g * mul, b * mul
    end
    return pr, pg, pb
end

--- 算出这一套主题的阶梯（每刷新一次主题只算一遍，调用点 GetSurface 是 O(1) 读表）。
-- 返回 { 每档 = {r,g,b}, steps, levels = {L*}, cr = {两两对比度} }；
-- levels / cr 在没有工具函数时为 nil，正好给 /mui colors 当"这层有没有生效"的证据。
local function computeSurface(t)
    local s = { keys = { unpack(SURFACE_KEYS) },
                steps = SURFACE_STEPS, levels = {}, cr = {} }

    for i = 1, #SURFACE_KEYS do
        local key = SURFACE_KEYS[i]
        local r, g, b = surfaceColor(t, key, s.steps[key])
        s[key] = { r = clamp01(r) or 0, g = clamp01(g) or 0, b = clamp01(b) or 0 }
    end

    for i = 1, #SURFACE_KEYS do
        local key = SURFACE_KEYS[i]
        s.levels[key] = lightnessOf(s[key])
    end
    s.cr.panelLost = contrastOf(s.panel, s.lost)
    -- **只是记账，不进闸门**：hover 只比 panel 高 3 个 L*（悬停态靠"贴得近才看得出的那点差"），
    -- 折算对比度 ≈1.07，天然低于 Core.lua 的 COLOR_CR_MIN 1.4 那条"相邻两档要分得开"的门。
    -- 别把它加进 CR_PAIRS 去"修红" —— 那一改等于把 D +3 推回 +6 以上，正文对比度先撑不住。
    s.cr.panelHover = contrastOf(s.panel, s.hover)
    s.cr.lostWeave = contrastOf(s.lost, s.weave)
    s.cr.lostFill = contrastOf(s.lost, s.fill)
    s.cr.panelFill = contrastOf(s.panel, s.fill)

    return s
end

function Color:HasMonetColor()
    return LMC ~= nil
end

function Color:SetSource(useMonet)
    useMonetColor = useMonet ~= false
    self:Refresh()
end

function Color:GetSource()
    if LMC and useMonetColor then
        return "monet", LMC:GetActiveProfile()
    end
    return "fallback"
end

--- Current zone environment info, for /mui status diagnostics and the config panel's zone preview.
-- Resolves the player's map through C_Map (pcall-guarded) and asks the engine for its environment colour; nil when the engine is absent, so the caller never has to know whether LibMonetColor shipped.
-- `mapID` 过一道 `Secrets.Number`：本客户端有 Map 类受限窗口（`ns:IsRestricted()` 那六类之一），
-- 而这个 ID 之后一定要进 `%d` / 表索引（Core 的 /mui status、面板的预览行）。读不出就当"没有区域"，
-- 调用方的 `if mapID then` 会整段跳过 —— 比拿机密值去格式化后被客户端拦下来好（AGENTS：宁可少显示一行）。
-- 返回的 `name` 来自我们自己的数据表（MonetColorMapData / override），不是客户端给的字符串，所以不过守卫。
-- @return mapID|nil, zoneName|nil, source|nil, h, s, l
function Color:GetZoneInfo()
    if not LMC or type(LMC.GetMapEnv) ~= "function" then return nil end

    local mapID
    if type(_G.C_Map) == "table" and _G.C_Map.GetBestMapForUnit then
        local ok, id = pcall(_G.C_Map.GetBestMapForUnit, "player")
        if ok then mapID = Secrets.Number(id) end
    end

    local h, s, l, name, source = LMC:GetMapEnv(mapID)
    return mapID, name, source, h, s, l
end

--- Recompute the cached theme (called at login and on every zone change).
function Color:Refresh()
    local db = ns.DB and ns:DB()
    if db and db.theme and db.theme.useMonetColor ~= nil then
        useMonetColor = db.theme.useMonetColor
    end

    if not (LMC and useMonetColor) then
        theme = FALLBACK
        surface = computeSurface(theme)
        return theme
    end

    local er, eg, eb, ea = LMC:GetCurrentEdgeColor()
    local ar, ag, ab, aa = LMC:GetCurrentAmbientTint()
    local hr, hg, hb = LMC:GetCurrentHighlightWash()
    local nr, ng, nb = LMC:GetCurrentNeutral()

    theme = {
        edge      = { r = er or FALLBACK.edge.r, g = eg or FALLBACK.edge.g, b = eb or FALLBACK.edge.b, a = ea or FALLBACK.edge.a },
        ambient   = { r = ar or FALLBACK.ambient.r, g = ag or FALLBACK.ambient.g, b = ab or FALLBACK.ambient.b, a = aa or FALLBACK.ambient.a },
        highlight = { r = hr or FALLBACK.highlight.r, g = hg or FALLBACK.highlight.g, b = hb or FALLBACK.highlight.b, a = FALLBACK.highlight.a },
        neutral   = { r = nr or FALLBACK.neutral.r, g = ng or FALLBACK.neutral.g, b = nb or FALLBACK.neutral.b, a = FALLBACK.neutral.a },

        health    = FALLBACK.health,
        resource  = FALLBACK.resource,
        danger    = FALLBACK.danger,
        primary   = { r = er or FALLBACK.primary.r, g = eg or FALLBACK.primary.g, b = eb or FALLBACK.primary.b, a = 1 },
    }

    surface = computeSurface(theme)
    return theme
end

function Color:GetTheme()
    if not theme then
        self:Refresh()
    end
    return theme
end

local function unpackColor(c)
    return c.r, c.g, c.b, c.a
end

function Color:GetEdge()      return unpackColor(self:GetTheme().edge) end
function Color:GetAmbient()   return unpackColor(self:GetTheme().ambient) end
function Color:GetHighlight() return unpackColor(self:GetTheme().highlight) end
function Color:GetNeutral()   return unpackColor(self:GetTheme().neutral) end
function Color:GetHealth()    return unpackColor(self:GetTheme().health) end
function Color:GetResource()  return unpackColor(self:GetTheme().resource) end
function Color:GetDanger()    return unpackColor(self:GetTheme().danger) end
function Color:GetPrimary()   return unpackColor(self:GetTheme().primary) end

--- 亮度阶梯的一层：Color:GetSurface("lost") -> r, g, b
-- RGB  only：和 GetBorder 一样，不透明度归调用点决定（面板 0.85、条底 0.25、织纹 0.85 各不相同）。
-- 未知 / 缺省的 key 落到 panel，所以调用点写错名字只会"回到最暗那一档"，不会拿到 nil。
function Color:GetSurface(key)
    if not surface then
        self:Refresh()
    end
    local c = surface[key] or surface.panel
    return c.r, c.g, c.b
end

--- 整本阶梯，含每档实测 L*（levels）与四组两两对比度（cr）；/mui colors 的账本读这个。
function Color:Surface()
    if not surface then
        self:Refresh()
    end
    return surface
end

--- Generic getter: Color:Get("edge") -> r, g, b, a
function Color:Get(key)
    local entry = self:GetTheme()[key or "edge"] or self:GetTheme().edge
    return unpackColor(entry)
end

-- Only the three signature colours plus the Monet neutral may be spent on chrome: health / resource / danger keep their own UI meaning.
local BORDER_KEYS = { edge = true, ambient = true, highlight = true, neutral = true }

--- Which slot the borders come from: one user setting re-tints every frame at once, a module may still override it per widget with Widget:Theme(..., { borderKey = ... }).
-- "edge" -- the signature glowing edge -- is the default and the fallback for an unknown value.
function Color:GetBorderKey()
    local db = ns.DB and ns:DB()
    local key = db and db.theme and db.theme.borderKey
    if type(key) == "string" and BORDER_KEYS[key] then return key end
    return "edge"
end

--- The border colour for the current key.  RGB only: every call site picks its own opacity.
function Color:GetBorder()
    local r, g, b = self:Get(self:GetBorderKey())
    return r, g, b
end

function Color:WithAlpha(r, g, b, a, alpha)
    return r, g, b, (a or 1) * (alpha or 1)
end

--- Linear blend between two slots (t = 0 -> from, t = 1 -> to), so a dynamic state can ramp through the Monet palette -- the threat glow goes primary -> danger -> health.
function Color:Blend(from, to, t)
    local a = self:GetTheme()[from] or self:GetTheme().edge
    local b = self:GetTheme()[to] or self:GetTheme().edge
    t = t or 0.5
    return a.r + (b.r - a.r) * t,
           a.g + (b.g - a.g) * t,
           a.b + (b.b - a.b) * t,
           a.a + (b.a - a.a) * t
end

function Color:Hex(r, g, b)
    return ns.Math:RGBToHex(r, g, b)
end

--- Class colour for a class file name ("MAGE", ...); nil when unknown.
function Color:ClassColor(classFile)
    if not classFile then return nil end
    if _G.C_ClassColor and _G.C_ClassColor.GetClassColor then
        local c = _G.C_ClassColor.GetClassColor(classFile)
        if c then return c.r, c.g, c.b end
    end
    local table_ = _G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS
    local c = table_ and table_[classFile]
    if c then return c.r, c.g, c.b end
    return nil
end

-- 名字必须带 Unit 前缀（1.60 快照实测：只有 UnitIsGroupLeader / UnitIsGroupAssistant /
-- UnitIsRaidOfficer，没有 IsRaidLeader，也没有 UnitIsRaidLeader）。这三个都是
-- SecretWhenUnitIdentityRestricted —— 所以下面走 Secrets.Bool，不直接真值测试。
-- 写成 `_G[...]` 动态查的名字 api-audit 抓不到：错名的症状不是报错，是"永不命中、静默返回默认色"。
local ROLE_MARKS = { "UnitIsGroupLeader", "UnitIsGroupAssistant", "UnitIsRaidOfficer" }

--- Vertex colour for role art (Assets/Textures/monet_role_*).  The three icons are deliberately
-- GREYSCALE (every pixel R==G==B, see the generator), so this is the only place their hue is decided:
-- a leader or assistant gets the highlight slot, everyone else stays a single colour.  The colour marks
-- the ROLE ASSIGNMENT, not the class -- a tank who is not leading reads exactly like any other tank.
-- Every query goes through pcall: on a Forever client the unit token can be secret, and a throw here would
-- take the whole styling pass down with it.
-- Call sites: Groups.UpdateRole (party/raid) and BossFrames.UpdateState.
function Color:RoleTint(unit)
    local marked = false
    if unit then
        for i = 1, #ROLE_MARKS do
            local api = _G[ROLE_MARKS[i]]
            if type(api) == "function" then
                local ok, v = pcall(api, unit)
                -- 真值测试前必须过 Secrets.Bool：受限环境下这几个 API 返回机密布尔，
                -- 直接 `if v then` 会被客户端拦成 ADDON_ACTION_BLOCKED（AGENTS 的"值级前置"）。
                if ok and Secrets.Bool(v, false) then marked = true break end
            end
        end
    end
    -- RGB only：GetHighlight 是四个返回值（带 a），直接透传会让调用点的
    -- SetVertexColor(r, g, b, a) 顺手把图标 alpha 改成主题高亮的 a —— 顶点色 alpha 和
    -- GetAlpha 是同一个存储（AGENTS「客户端行为细则」），所以这里截成三个。
    if marked then
        local r, g, b = self:GetHighlight()
        return r, g, b
    end
    return 1, 1, 1
end
