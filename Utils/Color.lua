-- Utils/Color.lua
-- Color access layer: MonetColor integration with fallback

local LMC = LibStub and LibStub("LibMonetColor-1.0", true)

local Color = {}

-- Private: cached theme colors
local theme = nil

-- Fallback palette (Andromeda-inspired)
local FALLBACK = {
    edge = {r = 0.8, g = 0.6, b = 0.2, a = 0.9},
    ambient = {r = 0.2, g = 0.2, b = 0.3, a = 0.2},
    highlight = {r = 0.9, g = 0.9, b = 0.9, a = 0.5},
    neutral = {r = 0.5, g = 0.5, b = 0.5, a = 0.8},
    health = {r = 0.2, g = 0.8, b = 0.2, a = 1.0},
    resource = {r = 0.2, g = 0.5, b = 0.9, a = 1.0},
    danger = {r = 0.9, g = 0.2, b = 0.2, a = 1.0},
}

-- ============================================================================
-- Public API
-- ============================================================================

function Color:Refresh()
    if not LMC then
        theme = FALLBACK
        return
    end

    local er, eg, eb, ea = LMC:GetCurrentEdgeColor()
    local ar, ag, ab, aa = LMC:GetCurrentAmbientTint()
    local hr, hg, hb = LMC:GetCurrentHighlightWash()
    local nr, ng, nb = LMC:GetCurrentNeutral()

    theme = {
        edge = {r = er or 0.8, g = eg or 0.6, b = eb or 0.2, a = ea or 0.9},
        ambient = {r = ar or 0.2, g = ag or 0.2, b = ab or 0.3, a = aa or 0.2},
        highlight = {r = hr or 0.9, g = hg or 0.9, b = hb or 0.9, a = 0.5},
        neutral = {r = nr or 0.5, g = ng or 0.5, b = nb or 0.5, a = 0.8},
        health = FALLBACK.health,
        resource = FALLBACK.resource,
        danger = FALLBACK.danger,
    }
end

function Color:GetTheme()
    if not theme then
        self:Refresh()
    end
    return theme
end

function Color:GetEdge()
    local t = self:GetTheme()
    return t.edge.r, t.edge.g, t.edge.b, t.edge.a
end

function Color:GetAmbient()
    local t = self:GetTheme()
    return t.ambient.r, t.ambient.g, t.ambient.b, t.ambient.a
end

function Color:GetHighlight()
    local t = self:GetTheme()
    return t.highlight.r, t.highlight.g, t.highlight.b, t.highlight.a
end

function Color:GetNeutral()
    local t = self:GetTheme()
    return t.neutral.r, t.neutral.g, t.neutral.b, t.neutral.a
end

function Color:GetHealth()
    local t = self:GetTheme()
    return t.health.r, t.health.g, t.health.b, t.health.a
end

function Color:GetResource()
    local t = self:GetTheme()
    return t.resource.r, t.resource.g, t.resource.b, t.resource.a
end

function Color:GetDanger()
    local t = self:GetTheme()
    return t.danger.r, t.danger.g, t.danger.b, t.danger.a
end

function Color:GetWithAlpha(color, alpha)
    return color.r, color.g, color.b, (color.a or 1) * alpha
end

function Color:HasMonetColor()
    return LMC ~= nil
end

return Color
