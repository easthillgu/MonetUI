-- Modules/Minimap/Minimap.lua
-- Minimap reshape.
--
-- The module does not replace the minimap, it reworks it: the cluster is moved
-- to the bottom-right corner and the circular map becomes a 256x190 rectangle
-- (Andromeda's shape), a themed panel is placed behind it and the default
-- circular art is removed.

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local EventBus = ns.EventBus

local M = { name = "Minimap" }

local panel = nil

-- -- Skinning -----------------------------------------------------------------

-- Andromeda parks the minimap in the bottom-right corner and stretches it into a
-- 256x190 rectangle; its UI_GAP is 33.
local MINIMAP_GAP    = 33
local MINIMAP_CANVAS = 256          -- the (square) minimap canvas
local MINIMAP_CROP   = 33           -- (256 - 190) / 2, hidden above and below
local MINIMAP_HEIGHT = MINIMAP_CANVAS - MINIMAP_CROP * 2
local minimapWarned = false
local shapeOverridden = false

--- Move Blizzard's minimap cluster to the bottom-right corner.
-- Guarded: Edit Mode also anchors this frame, and a failure here (which would
-- taint) must not stop the rest of the module.  Re-applied on every skin so a
-- zone change or an Edit Mode layout cannot undo it.
local function MoveCluster()
    local cluster = _G.MinimapCluster
    if not cluster then return end

    pcall(cluster.ClearAllPoints, cluster)
    local ok = pcall(cluster.SetPoint, cluster, "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT",
        -MINIMAP_GAP, MINIMAP_GAP)
    if not ok and not minimapWarned then
        minimapWarned = true
        ns:Print("小地图定位失败，已保留暴雪默认位置。")
    end
end

--- Turn the circular minimap into a 256x190 rectangle the way Andromeda does:
-- the canvas stays 256x256 and a mask texture blanks the top and bottom bands,
-- while the hit rectangle is shrunk to match what is actually visible.
local function ReshapeMinimap(minimap)
    pcall(minimap.SetMaskTexture, minimap, ns.Media:Texture("minimapRect"))
    pcall(minimap.SetSize, minimap, MINIMAP_CANVAS, MINIMAP_CANVAS)
    pcall(minimap.SetHitRectInsets, minimap, 0, 0, MINIMAP_CROP, MINIMAP_CROP)
    pcall(minimap.SetClampRectInsets, minimap, 0, 0, 0, 0)
    pcall(minimap.SetClampedToScreen, minimap, true)

    -- Third-party minimap buttons ask this to place themselves; telling them the
    -- map is square keeps them inside the rectangle (this is what Andromeda
    -- does).  Overriding a Blizzard global is deliberate here, hence the write.
    if not shapeOverridden then
        shapeOverridden = true
        _G.GetMinimapShape = function() return "SQUARE" end
    end
end

--- Remove the default circular art: it no longer fits the rectangular map (the
-- themed panel behind the cluster is the frame now).
local function ClearDefaultArt()
    for _, name in ipairs({ "MinimapBorder", "MinimapBorderTop", "MinimapCompassTexture",
                            "MinimapBackdrop", "MinimapNorthTag" }) do
        local region = _G[name]
        if region and region.Hide then region:Hide() end
        if region and region.SetAlpha then region:SetAlpha(0) end
    end
end

local function Skin()
    local minimap = _G.Minimap
    if not minimap then return false end

    MoveCluster()
    ReshapeMinimap(minimap)
    ClearDefaultArt()

    -- framed panel hugging the visible rectangle
    if not panel then
        panel = Widget:CreateFrame("MonetUIMinimapPanel", UIParent,
            MINIMAP_CANVAS + 8, MINIMAP_HEIGHT + 8)
        panel:SetFrameStrata("BACKGROUND")
        panel:SetFrameLevel(1)
        panel:EnableMouse(false)
        Widget:Theme(panel, { thickness = 2, bgAlpha = 0.35 })
    end
    panel:ClearAllPoints()
    panel:SetPoint("CENTER", minimap, "CENTER", 0, 0)

    return true
end

-- -- Lifecycle ----------------------------------------------------------------

function M:Initialize()
    -- Blizzard re-anchors the cluster when the area changes, so the skin is
    -- re-applied rather than done once.
    EventBus:Register("PLAYER_ENTERING_WORLD", function() Skin() end)
    EventBus:Register("ZONE_CHANGED_NEW_AREA", function() Skin() end)
    EventBus:Register("MONETUI_THEME_CHANGED", function() ClearDefaultArt() end)

    Skin()
end

function M:SetEnabled(enabled)
    if panel then panel:SetShown(enabled and true or false) end
end

ns:Register("Minimap", M)
