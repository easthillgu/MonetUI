-- Utils/Math.lua
-- Math utilities: lerp / clamp / round / colour helpers / number formatting.
-- Lua 5.1 compatible (no bit32, no goto, no table.unpack).

local ADDON_NAME, ns = ...

local Math = {}
ns.Math = Math

function Math:Lerp(a, b, t)
    return a + (b - a) * t
end

function Math:Clamp(val, lo, hi)
    return math.max(lo, math.min(hi, val))
end

function Math:Clamp01(val)
    return math.max(0, math.min(1, val or 0))
end

function Math:Round(val, decimals)
    local mult = 10 ^ (decimals or 0)
    return math.floor(val * mult + 0.5) / mult
end

function Math:IsInRange(val, lo, hi)
    return val >= lo and val <= hi
end

function Math:SafeDiv(a, b, fallback)
    if not b or b == 0 then return fallback or 0 end
    return a / b
end

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
    s = self:Clamp01(s)
    l = self:Clamp01(l)

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
    else               r, g, b = c, 0, x
    end

    return r + m, g + m, b + m
end

-- Convert RGB to HSL (r/g/b: 0-1)
function Math:RGBToHSL(r, g, b)
    r = self:Clamp01(r)
    g = self:Clamp01(g)
    b = self:Clamp01(b)

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

function Math:RGBToHex(r, g, b)
    r = math.floor(self:Clamp01(r) * 255 + 0.5)
    g = math.floor(self:Clamp01(g) * 255 + 0.5)
    b = math.floor(self:Clamp01(b) * 255 + 0.5)
    return string.format("%02x%02x%02x", r, g, b)
end

--- 1234 -> "1.2K", 1500000 -> "1.5M", 42 -> "42".
function Math:ShortNumber(value, decimals)
    value = tonumber(value)
    if not value then return "0" end
    decimals = decimals or 1

    local negative = value < 0
    if negative then value = -value end

    local out
    if value >= 1e12 then
        out = string.format("%." .. decimals .. "fT", value / 1e12)
    elseif value >= 1e9 then
        out = string.format("%." .. decimals .. "fB", value / 1e9)
    elseif value >= 1e6 then
        out = string.format("%." .. decimals .. "fM", value / 1e6)
    elseif value >= 1e5 then
        out = string.format("%." .. decimals .. "fK", value / 1e3)
    else
        out = tostring(math.floor(value + 0.5))
    end

    if negative then out = "-" .. out end
    return out
end

--- Add thousands separators: 1234567 -> "1,234,567".
function Math:Comma(value)
    value = tonumber(value)
    if not value then return "0" end

    local formatted = tostring(math.floor(math.abs(value) + 0.5))
    local negative = value < 0
    while true do
        local replaced
        formatted, replaced = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        if replaced == 0 then break end
    end
    if negative then formatted = "-" .. formatted end
    return formatted
end

--- 75 -> "1:15", 3671 -> "1:01:11", 90061 -> "1d 1h".
function Math:FormatTime(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds < 0 then return "" end
    seconds = math.floor(seconds + 0.5)

    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60

    if days > 0 then
        return string.format("%dd %dh", days, hours)
    elseif hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, secs)
    else
        return string.format("%d:%02d", minutes, secs)
    end
end

--- Compact duration for auras: 3599 -> "59m", 86399 -> "23h", 90000 -> "1d".
function Math:DurationText(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds < 0 then return "" end

    if seconds >= 86400 then
        return string.format("%dd", math.floor(seconds / 86400))
    elseif seconds >= 3600 then
        return string.format("%dh", math.floor(seconds / 3600))
    elseif seconds >= 60 then
        return string.format("%dm", math.floor(seconds / 60))
    else
        return string.format("%d", math.floor(seconds + 0.5))
    end
end

function Math:Percent(current, maximum, decimals)
    current = tonumber(current)
    maximum = tonumber(maximum)
    if not current or not maximum or maximum == 0 then return 0 end
    return tonumber(string.format("%." .. (decimals or 0) .. "f", current / maximum * 100))
end
