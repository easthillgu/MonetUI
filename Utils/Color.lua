-- Utils/Color.lua
-- Colour access layer: LibMonetColor-1.0 integration with a graceful fallback.
--
-- "5 + 3" model (see MonetUI.md):
--   functional 5 : primary / health / resource / danger / neutral
--   signature  3 : edge glow / ambient tint / highlight wash
--
-- Only the signature colours (plus the Monet neutral) come from the engine.
-- Health / resource / danger stay UI-managed on purpose (they must never be
-- "Monetised").

local ADDON_NAME, ns = ...

local LibStub = _G.LibStub
local LMC = LibStub and LibStub("LibMonetColor-1.0", true)

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

local theme
local useMonetColor = true

-- -- Source control -----------------------------------------------------------

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

-- -- Refresh ------------------------------------------------------------------

--- Recompute the cached theme (called at login and on every zone change).
function Color:Refresh()
    local db = ns.DB and ns:DB()
    if db and db.theme and db.theme.useMonetColor ~= nil then
        useMonetColor = db.theme.useMonetColor
    end

    if not (LMC and useMonetColor) then
        theme = FALLBACK
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

    return theme
end

function Color:GetTheme()
    if not theme then
        self:Refresh()
    end
    return theme
end

-- -- Getters ------------------------------------------------------------------

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

--- Generic getter: Color:Get("edge") -> r, g, b, a
function Color:Get(key)
    local entry = self:GetTheme()[key or "edge"] or self:GetTheme().edge
    return unpackColor(entry)
end

-- -- Border source -------------------------------------------------------------

-- The slots a border may be drawn from.  Only the three signature colours (plus
-- the Monet neutral) are offered: health / resource / danger keep their own UI
-- meaning and must not be "spent" on chrome.
local BORDER_KEYS = { edge = true, ambient = true, highlight = true, neutral = true }

--- Which slot the borders come from.  This is a single user setting, so one
-- dropdown re-tints every frame at once; a module may still override it per
-- widget with Widget:Theme(..., { borderKey = ... }).  "edge" -- the signature
-- glowing edge -- is the default, and the fallback for an unknown value.
function Color:GetBorderKey()
    local db = ns.DB and ns:DB()
    local key = db and db.theme and db.theme.borderKey
    if type(key) == "string" and BORDER_KEYS[key] then return key end
    return "edge"
end

--- The border colour for the current key.  RGB only: every call site picks its
-- own opacity (panels are solid, hand-drawn rings use 0.9).
function Color:GetBorder()
    local r, g, b = self:Get(self:GetBorderKey())
    return r, g, b
end

function Color:WithAlpha(r, g, b, a, alpha)
    return r, g, b, (a or 1) * (alpha or 1)
end

--- Linear blend between two slots (t = 0 -> from, t = 1 -> to).  Lets a
-- dynamic state ramp through the Monet palette -- the threat glow goes
-- primary -> danger -> health -- instead of borrowing Blizzard's raw
-- red / orange / yellow.
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

-- -- Class colours ------------------------------------------------------------

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
