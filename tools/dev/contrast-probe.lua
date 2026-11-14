-- tools/dev/contrast-probe.lua
-- 离线复刻 Utils/Color.lua 的亮度阶梯：逐地图打印每档 CIE L*、目标偏差与两两对比度。
-- 只读、不进发行包（tools/ 被 .gitignore 排除）。
-- 跑法（仓库根）：lua tools/dev/contrast-probe.lua [mapID ...]
-- 不带参数 = 打印 Atlas 17 区 + 河林 fallback + 几个极端 envL 的合成场景。

-- 本机 Lua 5.4 缺 WoW 的全局别名（LibStub / LMC 用的是 strmatch / unpack 那套）。
_G.strmatch  = _G.strmatch or string.match
_G.strfind   = _G.strfind or string.find
_G.strsub    = _G.strsub or string.sub
_G.strupper  = _G.strupper or string.upper
_G.strlower  = _G.strlower or string.lower
_G.strformat = _G.strformat or string.format
_G.strlen    = _G.strlen or string.len
_G.strrep    = _G.strrep or string.rep
_G.format    = _G.format or string.format
_G.tinsert   = _G.tinsert or table.insert
_G.tremove   = _G.tremove or table.remove
_G.unpack    = _G.unpack or table.unpack
_G.wipe      = _G.wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
_G.GetTime   = _G.GetTime or function() return os.clock() end

local ROOT = "."
local function dofile_p(path)
    local fn, err = loadfile(ROOT .. "/" .. path)
    if not fn then error("loadfile " .. path .. ": " .. tostring(err)) end
    return fn()
end

dofile_p("Libs/LibStub/LibStub.lua")
dofile_p("Libs/LibMonetColor-1.0/LibMonetColor-1.0.lua")
dofile_p("Libs/MonetColorMapData-1.0/MonetColorMapData-1.0.lua")
dofile_p("Libs/MonetColorMapData-1.0/MonetColorMapEnvOverride.lua")
dofile_p("Libs/MonetColorMapData-1.0/MonetColorMapEnvAtlas.lua")

local LMC = LibStub("LibMonetColor-1.0", true)
assert(LMC, "LibMonetColor 没起来")
LMC:SetFallbackEnv(137.6, 0.305, 0.269)

-- 与 Utils/Color.lua 逐字对齐的两张表
local SURFACE_KEYS  = { "panel", "hover", "lost", "weave", "fill" }
local SURFACE_STEPS = { panel = 10, hover = 13, lost = 28, weave = 40, fill = 46 }
local SURFACE_HUE   = { panel = "ambient", hover = "ambient", lost = "neutral", weave = "neutral" }
local SURFACE_MUL_LEGACY = { panel = 0.35, hover = 0.40, lost = 0.32, weave = 1, fill = 1 }

local function clamp01(v)
    if type(v) ~= "number" then return nil end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function surfaceColor(t, key, step)
    local srcKey = SURFACE_HUE[key]
    local src = t[srcKey or "edge"] or t.neutral
    local r, g, b = src.r, src.g, src.b
    if not srcKey then
        r, g, b = 1 - (r or 0), 1 - (g or 0), 1 - (b or 0)
    end
    local pr, pg, pb = LMC.AtLightness(r, g, b, step)
    if not pr then
        local mul = SURFACE_MUL_LEGACY[key]
        return r * mul, g * mul, b * mul
    end
    return clamp01(pr) or 0, clamp01(pg) or 0, clamp01(pb) or 0
end

local function hex(c)
    return string.format("%02x%02x%02x",
        math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5))
end

local function report(label, h, s, l)
    local rules = LMC:GetRules()
    local er, eg, eb, ea = LMC.ComputeEdgeColor(h, s, l, rules)
    local ar, ag, ab, aa = LMC.ComputeAmbientTint(h, s, l, rules)
    local hr, hg, hb = LMC.ComputeHighlightWash(h, s, l, rules)
    local nr, ng, nb = LMC.ComputeNeutral(h, s, l, rules)

    local t = {
        edge      = { r = er, g = eg, b = eb, a = ea },
        ambient   = { r = ar, g = ag, b = ab, a = aa },
        highlight = { r = hr, g = hg, b = hb },
        neutral   = { r = nr, g = ng, b = nb },
        primary   = { r = er, g = eg, b = eb, a = 1 },
    }

    local su = {}
    for i = 1, #SURFACE_KEYS do
        local key = SURFACE_KEYS[i]
        local r, g, b = surfaceColor(t, key, SURFACE_STEPS[key])
        su[key] = { r = r, g = g, b = b }
    end

    local function cr(a, b)
        return LMC.ContrastRatio(su[a].r, su[a].g, su[a].b, su[b].r, su[b].g, su[b].b)
    end
    local function lab(c) return LMC.RGBToLab(c.r, c.g, c.b) end

    -- 目标 L* 与实际 L* 的偏差：AtLightness 在 out-of-gamut 时会退回"最接近可达色"
    local dev = {}
    for i = 1, #SURFACE_KEYS do
        local key = SURFACE_KEYS[i]
        dev[#dev + 1] = string.format("%s:%d/%d", key:sub(1, 1),
            math.floor(lab(su[key]) + 0.5), SURFACE_STEPS[key])
    end

    print(string.format("%-22s env(%5.1f,%4.2f,%4.2f)  %s", label, h, s, l, table.concat(dev, " ")))
    print(string.format("   panel %s  lost %s  weave %s  fill %s  neutral %s  edge %s",
        hex(su.panel), hex(su.lost), hex(su.weave), hex(su.fill), hex(t.neutral), hex(t.edge)))
    print(string.format("   CR panelLost %.2f  lostWeave %.2f  lostFill %.2f  panelFill %.2f  panelHover %.2f | neutral/panel %.2f  neutral/lost %.2f  edge/panel %.2f",
        cr("panel", "lost"), cr("lost", "weave"), cr("lost", "fill"), cr("panel", "fill"), cr("panel", "hover"),
        LMC.ContrastRatio(nr, ng, nb, su.panel.r, su.panel.g, su.panel.b),
        LMC.ContrastRatio(nr, ng, nb, su.lost.r, su.lost.g, su.lost.b),
        LMC.ContrastRatio(er, eg, eb, su.panel.r, su.panel.g, su.panel.b)))

    -- 与"游戏世界"的真实关系：血条压在半透明板上，板下是环境色；文字压在同一块板上。
    -- 账本只算不透明 RGB 两两比，这一步把 alpha 合成补回来，才是玩家看到的画面。
    local envR, envG, envB = LMC.HSLToRGB(h, s, l)
    local env = { r = envR, g = envG, b = envB }
    local function over(fg, alpha, bg)
        return { r = fg.r * alpha + bg.r * (1 - alpha),
                 g = fg.g * alpha + bg.g * (1 - alpha),
                 b = fg.b * alpha + bg.b * (1 - alpha) }
    end
    local function crC(a, b)
        return LMC.ContrastRatio(a.r, a.g, a.b, b.r, b.g, b.b)
    end
    local neu = { r = nr, g = ng, b = nb }
    local p35, p85 = over(su.panel, 0.35, env), over(su.panel, 0.85, env)
    local _, fh = LMC.RGBToHSL(su.fill.r, su.fill.g, su.fill.b)
    local dh = math.abs(fh - (h % 360)); if dh > 180 then dh = 360 - dh end
    print(string.format("   env %s | fill/env %.2f  lost/env %.2f  fillHueΔ%.0f° | text/panel@35%% %.2f  @85%% %.2f  panel@35%%/env %.2f",
        hex(env), crC(su.fill, env), crC(su.lost, env), dh,
        crC(neu, p35), crC(neu, p85), crC(p35, env)))
end

local args = { ... }
if #args > 0 then
    for i = 1, #args do
        local id = tonumber(args[i])
        local h, s, l, name, src = LMC:GetMapEnv(id)
        report(tostring(id) .. " " .. tostring(name or "?") .. " [" .. tostring(src) .. "]", h, s, l)
    end
else
    -- Atlas 17 区
    local ids = { 1411, 1412, 1413, 1438, 1439, 1440, 1441, 1442, 1443, 1444,
                  1445, 1446, 1447, 1448, 1449, 1450, 2521, 2548 }
    for i = 1, #ids do
        local h, s, l, name, src = LMC:GetMapEnv(ids[i])
        report(tostring(ids[i]) .. " " .. tostring(name or "?") .. " [" .. tostring(src) .. "]", h, s, l)
    end
    -- 极端亮度扫描（找哪些 envL 会破线）
    print("--- envL sweep (h=35.9 s=0.371) ---")
    for _, lv in ipairs({ 0.20, 0.30, 0.38, 0.44, 0.50, 0.60, 0.70, 0.80 }) do
        report(string.format("sweep L=%.2f", lv), 35.9, 0.371, lv)
    end
end

-- ------------------------------------------------------------------ 真实配色库复算（纠偏后）
-- 不复刻算法：直接把仓库里的 Utils/Color.lua 装进一个最小 ns，再对每张地图跑 Color:Refresh()。
-- 这样离线探针验的就是发行代码本身，改了契约层这里会立刻对不上。
local currentMapID = 1446
_G.C_Map = { GetBestMapForUnit = function() return currentMapID end }

-- engine-on 的四个 getter 在 standalone 下没有客户端地图上下文，按当前探针地图重算一遍。
local function envForProbe()
    local h, s, l = LMC:GetMapEnv(currentMapID)
    return h, s, l, LMC:GetRules()
end
function LMC:GetCurrentEdgeColor()
    local h, s, l, rules = envForProbe()
    return LMC.ComputeEdgeColor(h, s, l, rules)
end
function LMC:GetCurrentAmbientTint()
    local h, s, l, rules = envForProbe()
    return LMC.ComputeAmbientTint(h, s, l, rules)
end
function LMC:GetCurrentHighlightWash()
    local h, s, l, rules = envForProbe()
    return LMC.ComputeHighlightWash(h, s, l, rules)
end
function LMC:GetCurrentNeutral()
    local h, s, l, rules = envForProbe()
    return LMC.ComputeNeutral(h, s, l, rules)
end

local db = { theme = { useMonetColor = true, minContrast = 1.8 } }
local ns = {
    Secrets = { Number = function(v) return tonumber(v) end,
                Bool = function(v) return v and true or false end,
                CanRead = function() return true end },
    Math = { RGBToHex = function(_, r, g, b)
        return string.format("%02x%02x%02x", math.floor(r * 255 + 0.5),
            math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
    end },
}
function ns:DB() return db end

local chunk = assert(loadfile(ROOT .. "/Utils/Color.lua"))
chunk("MonetUI", ns)
local Color = assert(ns.Color, "Utils/Color.lua 没挂 ns.Color")

local function hex3(r, g, b)
    return string.format("%02x%02x%02x", math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local afterIDs = #args > 0 and args or
    { "1411", "1413", "1440", "1446", "1449", "1450", "2521", "2548" }
print("=== AFTER (真实 Utils/Color.lua, minContrast=1.8) ===")
for i = 1, #afterIDs do
    currentMapID = tonumber(afterIDs[i]) or 2548
    local _, _, _, name = LMC:GetMapEnv(currentMapID)
    Color:Refresh()
    local su = Color:Surface()
    local a = su.adjust
    local envLine = 0
    for j = 1, #su.rows do
        if su.rows[j].key == "fillEnv" then envLine = su.rows[j].min or 0 end
    end
    local fr, fg, fb = Color:GetSurface("fill")
    local nr, ng, nb = Color:GetNeutral()
    local bad = {}
    for j = 1, #su.rows do
        local row = su.rows[j]
        if row.min and not row.ok then
            bad[#bad + 1] = string.format("%s %.2f<%.1f", row.label, row.cr or 0, row.min)
        end
    end
    print(string.format("%-5s %-8s applied=%s fillHue=%s fillL* %s→%s textL* %s→%s fill #%s text #%s",
        tostring(currentMapID), tostring(name or "?"),
        a.applied and "Y" or "N", a.fillHue and "Y" or "N",
        a.fillFrom and string.format("%.0f", a.fillFrom) or "-",
        a.fillTo and string.format("%.0f", a.fillTo) or "-",
        a.textFrom and string.format("%.0f", a.textFrom) or "-",
        a.textTo and string.format("%.0f", a.textTo) or "-",
        hex3(fr, fg, fb), hex3(nr, ng, nb)))
    print(string.format("   CR " ..
        "lostFill %.2f  fillEnv %.2f/%.1f  text %.2f/4.5  textFill %.2f  edge %.2f  %s",
        su.cr.lostFill or 0, su.cr.fillEnv or 0, envLine,
        su.cr.textPlate or 0, su.cr.textFill or 0, su.cr.edgePanel or 0,
        #bad == 0 and "ALL PASS" or ("FAIL: " .. table.concat(bad, ", "))))
end

-- 控制值扫描：证明这一档数真的在管血条，而不是只写进账本的装饰。
print("=== minContrast sweep (塔纳利斯 1446) ===")
currentMapID = 1446
for _, v in ipairs({ 1.4, 1.8, 2.1, 2.4, 2.7, 3.0 }) do
    db.theme.minContrast = v
    Color:Refresh()
    local su = Color:Surface()
    local a = su.adjust
    print(string.format("  %.1f -> fillL* %s  lostFill %.2f  fillEnv %.2f  barFixed=%s",
        v, a.fillTo and string.format("%.0f", a.fillTo) or "-",
        su.cr.lostFill or 0, su.cr.fillEnv or 0, a.barFixed and "Y" or "N"))
end
db.theme.minContrast = 1.8
