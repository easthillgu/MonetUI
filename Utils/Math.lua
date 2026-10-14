-- Utils/Math.lua
-- Math utilities: lerp/clamp/round/color helpers

local Math = {}

function Math:Lerp(a, b, t)
    return a + (b - a) * t
end

function Math:Clamp(val, lo, hi)
    return math.max(lo, math.min(hi, val))
end

function Math:Round(val, decimals)
    local mult = 10 ^ (decimals or 0)
    return math.floor(val * mult + 0.5) / mult
end

function Math:IsInRange(val, lo, hi)
    return val >= lo and val <= hi
end

-- Color lerp: blend two RGBA colors
function Math:LerpColor(c1, c2, t)
    return {
        r = self:Lerp(c1.r, c2.r, t),
        g = self:Lerp(c1.g, c2.g, t),
        b = self:Lerp(c1.b, c2.b, t),
        a = self:Lerp(c1.a or 1, c2.a or 1, t),
    }
end

-- Convert HSL to RGB (h: 0-360, s/l: 0-1)
function Math:HSLToRGB(h, s, l)
    h = ((h or 0) % 360 + 360) % 360
    s = self:Clamp(s or 0, 0, 1)
    l = self:Clamp(l or 0.5, 0, 1)

    if s == 0 then
        return l, l, l
    end

    local c = (1 - math.abs(2 * l - 1)) * s
    local hp = h / 60
    local x = c * (1 - math.abs(hp % 2 - 1))
    local m = l - c / 2
    local r, g, b

    if     hp < 1 then r, g, b = c, x, 0
    elseif hp < 2 then r, g, b = x, c, 0
    elseif hp < 3 then r, g, b = 0, c, x
    elseif hp < 4 then r, g, b = 0, x, c
    elseif hp < 5 then r, g, b = x, 0, c
    else                 r, g, b = c, 0, x
    end

    return r + m, g + m, b + m
end

-- Convert RGB to HSL (r/g/b: 0-1)
function Math:RGBToHSL(r, g, b)
    r = self:Clamp(r or 0, 0, 1)
    g = self:Clamp(g or 0, 0, 1)
    b = self:Clamp(b or 0, 0, 1)

    local max = math.max(r, g, b)
    local min = math.min(r, g, b)
    local l = (max + min) / 2
    local h, s

    if max == min then
        h, s = 0, 0
    else
        local d = max - min
        s = l > 0.5 and d / (2 - max - min) or d / (max + min)
        if max == r then
            h = (g - b) / d
            if g < b then h = h + 6 end
        elseif max == g then
            h = (b - r) / d + 2
        else
            h = (r - g) / d + 4
        end
        h = h * 60
    end

    return h, s, l
end

return Math
