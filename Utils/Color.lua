-- Utils/Color.lua
-- Colour access layer: LibMonetColor-1.0 integration with a graceful fallback.
-- "5 + 3" model (see MonetUI.md): functional 5 (primary / health / resource / danger / neutral) + signature 3 (edge glow / ambient tint / highlight wash).
-- Only the signature colours (plus the Monet neutral) come from the engine; health / resource / danger stay UI-managed on purpose (they must never be "Monetised").
-- On top of the 5+3 sits the **surface ladder** (GetSurface): four CIE L* levels -- panel / lost / weave / fill -- recomputed once per theme refresh. The engine gives hue, the ladder gives separation; bar contrast is the consumer's job (see docs/HANDOFF.md 8.14.3).

local ADDON_NAME, ns = ...

local LibStub = _G.LibStub
local LMC = LibStub and LibStub("LibMonetColor-1.0", true)
local Secrets = ns.Secrets      -- Secrets.lua 在本文件之前加载（见 Utils.xml）

local Color = {}
ns.Color = Color

-- Palette used when LibMonetColor is missing or the user turns the engine off.
local FALLBACK = {
    edge      = { r = 0.85, g = 0.66, b = 0.36, a = 0.95 },  -- warm ochre
    ambient   = { r = 0.24, g = 0.26, b = 0.36, a = 0.22 },  -- cool blue-grey
    highlight = { r = 0.95, g = 0.93, b = 0.84, a = 0.50 },  -- soft cream
    neutral   = { r = 0.62, g = 0.60, b = 0.57, a = 0.85 },  -- Monet grey

    health    = { r = 0.20, g = 0.80, b = 0.20, a = 1.00 },
    resource  = { r = 0.20, g = 0.50, b = 0.90, a = 1.00 },
    danger    = { r = 0.90, g = 0.20, b = 0.20, a = 1.00 },
    primary   = { r = 0.85, g = 0.66, b = 0.36, a = 1.00 },
}

-- 亮度阶梯（CIE L*）：把"窗口底衬 / 掉血空槽 / 织纹 / 血条填充"四档在同一个色相家族里拉开。
-- 数字的来由见 docs/HANDOFF.md 8.14.3：这层之前是 ambient×0.35（面板）对 neutral×0.32（空槽），
-- 14 个区域实测两者对比度只有 1.00–1.19 —— 不是"颜色不对"，是亮度几乎重合，所以怎么换色相都分不开。
-- 阶梯只动亮度，色相仍由引擎给（下面 SURFACE_HUE / SURFACE_INVERT 那三行是 2026-10-25 配色案，不改）。
local SURFACE_KEYS = { "panel", "lost", "weave", "fill" }
local SURFACE_STEPS = {
    panel = 10,   -- 窗口底衬：近乎无光，只负责承托内容
    lost  = 28,   -- 掉血空槽：比面板亮一档，"少了的那截血"要看得出来
    weave = 40,   -- 织纹发丝线：压在空槽之上、比填充暗，读作布纹而不抢血量
    fill  = 46,   -- 血条填充：整条里最亮的一档
}

-- 每档吃哪个色相。fill 不在表里 = 走 edge 的 RGB 反相（保持"反色血条"的招牌识别）。
local SURFACE_HUE = { panel = "ambient", lost = "neutral", weave = "neutral" }

-- 引擎没带 1.2.0 工具函数（老 vendored 副本）时的回退乘数：就是这层之前各调用点自己写死的那几个数，
-- 逐位一致，所以缺工具函数只是"回到旧观感"，不会算出别的颜色。
local SURFACE_MUL_LEGACY = { panel = 0.35, lost = 0.32, weave = 1, fill = 1 }

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

--- 算出这一套主题的四级阶梯（每刷新一次主题只算一遍，调用点 GetSurface 是 O(1) 读表）。
-- 返回 { panel/lost/weave/fill = {r,g,b}, steps, levels = {L*}, cr = {两两对比度} }；
-- levels / cr 在没有工具函数时为 nil，正好给 /mui colors 当"这层有没有生效"的证据。
local function computeSurface(t)
    local s = { keys = SURFACE_KEYS, steps = SURFACE_STEPS, levels = {}, cr = {} }

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

--- Current zone environment info, for /mui status diagnostics.
-- Resolves the player's map through C_Map (pcall-guarded) and asks the engine for its environment colour; nil when the engine is absent, so the caller never has to know whether LibMonetColor shipped.  @return mapID|nil, zoneName|nil, source|nil, h, s, l
function Color:GetZoneInfo()
    if not LMC or type(LMC.GetMapEnv) ~= "function" then return nil end

    local mapID
    if type(_G.C_Map) == "table" and _G.C_Map.GetBestMapForUnit then
        local ok, id = pcall(_G.C_Map.GetBestMapForUnit, "player")
        if ok then mapID = id end
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

local ROLE_MARKS = { "IsGroupLeader", "IsRaidLeader", "IsGroupAssistant" }

--- Vertex colour for role art (Assets/Textures/monet_role_*).  The three icons are deliberately
-- GREYSCALE (every pixel R==G==B, see the generator), so this is the only place their hue is decided:
-- a leader or assistant gets the highlight slot, everyone else stays a single colour.  The colour marks
-- the ROLE ASSIGNMENT, not the class -- a tank who is not leading reads exactly like any other tank.
-- Every query goes through pcall: on a Forever client the unit token can be secret, and a throw here would
-- take the whole styling pass down with it.
-- TENTATIVE: no call site consumes this yet (the role icons are registered but not yet placed); the rule
-- is expected to be adjusted once there is something to look at.
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
    if marked then return self:GetHighlight() end
    return 1, 1, 1
end
