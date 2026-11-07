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
-- style = "cn" switches to the Chinese 万 / 亿 scale: 12345 -> "1.2万", 1.5e8 -> "1.5亿".
function Math:ShortNumber(value, decimals, style)
    value = tonumber(value)
    if not value then return "0" end
    decimals = decimals or 1

    local negative = value < 0
    if negative then value = -value end

    local out
    if style == "cn" then
        if value >= 1e12 then
            out = string.format("%." .. decimals .. "f万亿", value / 1e12)
        elseif value >= 1e8 then
            out = string.format("%." .. decimals .. "f亿", value / 1e8)
        elseif value >= 1e4 then
            out = string.format("%." .. decimals .. "f万", value / 1e4)
        else
            out = tostring(math.floor(value + 0.5))
        end
    elseif value >= 1e12 then
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

--- Seconds until the displayed value next changes.
--- `half` = true : the display rounds to the nearest bucket (change at k*bucket + bucket/2)
--- `half` = false: the display floors to the bucket            (change at k*bucket)
local function TimeToNextChange(seconds, bucket, half)
    local boundary
    if half then
        boundary = (math.floor(seconds / bucket - 0.5) + 0.5) * bucket
    else
        boundary = math.floor(seconds / bucket) * bucket
    end
    local wait = seconds - boundary
    if wait < 0.02 then wait = 0.02 end
    return wait
end

--- Action-bar countdown text with two tunable clock switches (TenthTH / MmssTH):
---   seconds < tenthsTH  -> one decimal        ("4.3")
---   seconds >= mmssTH   -> mm:ss / h:mm / d   ("1:05", "2:05", "3d")
---   otherwise           -> the existing compact DurationText ("42", "59m")
--- tenthsTH / mmssTH <= 0 disables that switch.
--- Returns: valueText, suffix, secondsUntilTheTextChanges, bucket.
--- bucket is "seconds" | "minutes" | "hours" | "days" so the caller can tint it.
function Math:Countdown(seconds, tenthsTH, mmssTH)
    seconds = tonumber(seconds)
    if not seconds or seconds < 0 then return "", "", nil, nil end

    -- Keep one decimal of precision before the switch so 9.96 does not print "9".
    local tenths = math.floor(seconds * 10 + 0.5) / 10

    if tenthsTH and tenthsTH > 0 and tenths < tenthsTH then
        return string.format("%.1f", tenths), "", TimeToNextChange(seconds, 0.1, true), "seconds"
    end

    if mmssTH and mmssTH > 0 and seconds >= mmssTH then
        if seconds < 3600 then
            local m = math.floor(seconds / 60)
            local s = math.floor(seconds % 60 + 0.5)
            if s >= 60 then m, s = m + 1, 0 end
            return string.format("%d:%02d", m, s), "", TimeToNextChange(seconds, 1, true), "minutes"
        elseif seconds < 86400 then
            local h = math.floor(seconds / 3600)
            local m = math.floor((seconds % 3600) / 60 + 0.5)
            if m >= 60 then h, m = h + 1, 0 end
            return string.format("%d:%02d", h, m), "", TimeToNextChange(seconds, 60, true), "hours"
        else
            return tostring(math.floor(seconds / 86400)), "d",
                TimeToNextChange(seconds, 86400, false), "days"
        end
    end

    -- DurationText fallback, with the matching change boundary.
    if seconds >= 86400 then
        return tostring(math.floor(seconds / 86400)), "d",
            TimeToNextChange(seconds, 86400, false), "days"
    elseif seconds >= 3600 then
        return tostring(math.floor(seconds / 3600)), "h",
            TimeToNextChange(seconds, 3600, false), "hours"
    elseif seconds >= 60 then
        return tostring(math.floor(seconds / 60)), "m",
            TimeToNextChange(seconds, 60, false), "minutes"
    else
        return string.format("%d", math.floor(seconds + 0.5)), "",
            TimeToNextChange(seconds, 1, true), "seconds"
    end
end

function Math:Percent(current, maximum, decimals)
    current = tonumber(current)
    maximum = tonumber(maximum)
    if not current or not maximum or maximum == 0 then return 0 end
    return tonumber(string.format("%." .. (decimals or 0) .. "f", current / maximum * 100))
end

--- Cut a UTF-8 string down to `limit` CHARACTERS, appending "..." when anything was dropped.
-- Walks the character boundaries instead of using string.sub: a byte-wise cut can land inside a
-- Chinese character, and the font then draws a broken glyph.  A string that already fits is
-- returned as-is, so callers pay nothing for the common case.
function Math:Shorten(str, limit, dots)
    if type(str) ~= "string" then return str end
    limit = tonumber(limit)
    if not limit or limit <= 0 or #str <= limit then return str end

    local pos, count = 1, 0
    while count < limit and pos <= #str do
        local byte = str:byte(pos)
        if byte < 0xC0 then pos = pos + 1       -- ASCII (a continuation byte never starts a character)
        elseif byte < 0xE0 then pos = pos + 2   -- 2-byte
        elseif byte < 0xF0 then pos = pos + 3   -- 3-byte, i.e. every CJK character
        else pos = pos + 4 end                  -- 4-byte
        count = count + 1
    end
    if pos > #str then return str end
    return str:sub(1, pos - 1) .. (dots and "..." or "")
end

--- "Lady Sylvanas Windrunner" -> "L. S. Windrunner": every word but the last becomes an initial.
-- A Chinese name carries no spaces, so this leaves it alone -- Math:Shorten is what caps those.
function Math:AbbrName(name)
    if type(name) ~= "string" then return name end
    -- The capture keeps the whole first character (lead byte plus its continuation bytes) and drops
    -- its own trailing space, so each word collapses to "X. ".
    return (name:gsub("(%s?)(.[\128-\191]*)%S+%s", "%2. "))
end
