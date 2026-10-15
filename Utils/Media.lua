-- Utils/Media.lua
-- Font / texture registry.  Every asset ships inside the addon (Assets/).
--
-- NOTE: the paths are built from ADDON_NAME so the addon folder must stay named
--       "MonetUI".

local ADDON_NAME, ns = ...

local Media = {}
ns.Media = Media

local ASSET = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Assets\\"

Media.asset        = ASSET
Media.fontsDir     = ASSET .. "Fonts\\"
Media.texturesDir  = ASSET .. "Textures\\"

-- Fonts -----------------------------------------------------------------------
Media.font = {
    pixel    = ASSET .. "Fonts\\Pingfangpixel.ttf",    -- body text (Chinese-friendly pixel font)
    combat   = ASSET .. "Fonts\\combat.ttf",           -- large combat numbers
    cooldown = ASSET .. "Fonts\\super-effective.ttf",  -- cooldown countdown
    roadway  = ASSET .. "Fonts\\roadway.ttf",          -- headings / decorative
    default  = "Fonts\\FRIZQT__.TTF",
    number   = "Fonts\\ARIALN.TTF",
}

-- Textures --------------------------------------------------------------------
Media.texture = {
    blank     = "Interface\\Buttons\\WHITE8X8",
    statusbar = "Interface\\TargetingFrame\\UI-StatusBar",
    mask      = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
    ring      = "Interface\\Minimap\\MiniMap-TrackingBorder",
    glow      = "Interface\\SpellActivationOverlay\\IconAlertAnts",
    -- 256x256 alpha mask that keeps only the middle 190px band: it turns the
    -- circular minimap into Andromeda's 256x190 rectangle.
    minimapRect = ASSET .. "Textures\\rectangle-mask",
}

--- Resolve a font key to a path (unknown keys fall back to the pixel font).
function Media:Font(key)
    return self.font[key] or self.font.pixel
end

--- Resolve a texture key to a path (unknown keys fall back to the blank texture).
function Media:Texture(key)
    return self.texture[key] or self.texture.blank
end
