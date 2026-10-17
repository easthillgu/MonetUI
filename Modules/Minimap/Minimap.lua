-- Modules/Minimap/Minimap.lua
-- Minimap reshape: move the cluster to the bottom-right corner, turn the circular
-- map into a 256x190 rectangle, add a themed panel, drop the default circular art.

local ADDON_NAME, ns = ...

local Widget   = ns.Widget
local EventBus = ns.EventBus

local M = { name = "Minimap" }

local panel = nil

-- Andromeda's shape: parks the cluster bottom-right, stretches it into a 256x190 rectangle.
local MINIMAP_GAP    = 33
local MINIMAP_CANVAS = 256          -- the (square) minimap canvas
local MINIMAP_CROP   = 33           -- (256 - 190) / 2, hidden above and below
local MINIMAP_HEIGHT = MINIMAP_CANVAS - MINIMAP_CROP * 2
local minimapWarned  = false
local restoreWarned  = false
local shapeOverridden = false

-- State captured before the first skin, cleared by Restore(): "disabled" must mean the default is back.
local original = nil

-- Runtime switch state; a zone change must not re-skin a module the user turned off.
local active = false

-- XML-declared default mask: there is no MinimapFrame:GetMaskTexture getter (only Texture's),
-- so this path is the restore target.
local DEFAULT_MASK = "Interface\\Minimap\\MiniMap-CompassMask"

local ART_NAMES = { "MinimapBorder", "MinimapBorderTop", "MinimapCompassTexture",
                    "MinimapBackdrop", "MinimapNorthTag" }

--- Move the minimap cluster to the bottom-right corner.  Edit Mode also anchors this
--- frame, so the SetPoint is guarded; re-applied on every skin.
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

--- Turn the circular minimap into a 256x190 rectangle Andromeda-style: the canvas stays
--- 256x256, a mask blanks the top and bottom bands, the hit rect shrinks to match.
local function ReshapeMinimap(minimap)
    pcall(minimap.SetMaskTexture, minimap, ns.Media:Texture("minimapRect"))
    pcall(minimap.SetSize, minimap, MINIMAP_CANVAS, MINIMAP_CANVAS)
    pcall(minimap.SetHitRectInsets, minimap, 0, 0, MINIMAP_CROP, MINIMAP_CROP)
    pcall(minimap.SetClampRectInsets, minimap, 0, 0, 0, 0)
    pcall(minimap.SetClampedToScreen, minimap, true)

-- Third-party buttons ask GetMinimapShape to place themselves; the square answer keeps
-- them inside the rectangle.  Overriding the global is deliberate.
    if not shapeOverridden then
        shapeOverridden = true
        _G.GetMinimapShape = function() return "SQUARE" end
    end
end

--- Remove the default circular art; the themed panel is the frame now.  Remember()
--- snapshots every name below before this runs.
local function ClearDefaultArt()
    for _, name in ipairs(ART_NAMES) do
        local region = _G[name]
        if region and region.Hide then region:Hide() end
        if region and region.SetAlpha then region:SetAlpha(0) end
    end
end

--- Snapshot everything the skin changes, exactly once, so Restore() can undo it.
local function Remember(minimap)
    if original then return end

    local state = {
        mask = DEFAULT_MASK,
        art  = {},
    }
    if minimap.GetSize           then state.size    = { minimap:GetSize() } end
    if minimap.GetHitRectInsets  then state.hit     = { minimap:GetHitRectInsets() } end
    if minimap.GetClampRectInsets then state.clamp  = { minimap:GetClampRectInsets() } end
    if minimap.IsClampedToScreen then state.clamped = minimap:IsClampedToScreen() end

    local cluster = _G.MinimapCluster
    if cluster and cluster.GetNumPoints then
        state.points = {}
        for i = 1, cluster:GetNumPoints() do
            local point, relTo, relPoint, x, y = cluster:GetPoint(i)
            state.points[#state.points + 1] = { point, relTo, relPoint, x, y }
        end
    end

    for _, name in ipairs(ART_NAMES) do
        local region = _G[name]
        if region and region.IsShown then
            state.art[name] = { shown = region:IsShown(),
                                alpha = region.GetAlpha and region:GetAlpha() or 1 }
        end
    end

    state.shape = rawget(_G, "GetMinimapShape")
    original = state
end

--- Put the default minimap back: anchor, mask, size, insets, art, GetMinimapShape.
--- Protected methods are pcall'd; a failure (combat lockdown) is reported once.
local function Restore()
    local state = original
    original = nil
    if not state then return end

    local failed = false
    local function try(ok) if not ok then failed = true end end

    local cluster = _G.MinimapCluster
    if cluster and state.points and #state.points > 0 then
        pcall(cluster.ClearAllPoints, cluster)
        for _, pt in ipairs(state.points) do
            try(pcall(cluster.SetPoint, cluster, pt[1], pt[2], pt[3], pt[4], pt[5]))
        end
    end

    local minimap = _G.Minimap
    if minimap then
        try(pcall(minimap.SetMaskTexture, minimap, state.mask))
        if state.size then
            try(pcall(minimap.SetSize, minimap, state.size[1], state.size[2]))
        end
        if state.hit then
            try(pcall(minimap.SetHitRectInsets, minimap,
                      state.hit[1], state.hit[2], state.hit[3], state.hit[4]))
        end
        if state.clamp then
            try(pcall(minimap.SetClampRectInsets, minimap,
                      state.clamp[1], state.clamp[2], state.clamp[3], state.clamp[4]))
        end
        if state.clamped ~= nil then
            try(pcall(minimap.SetClampedToScreen, minimap, state.clamped))
        end
    end

    for name, saved in pairs(state.art) do
        local region = _G[name]
        if region and region.SetShown then
            region:SetShown(saved.shown)
            if region.SetAlpha and saved.alpha then region:SetAlpha(saved.alpha) end
        end
    end

    -- Restoring the deliberate global write: nil clears the override outright.
    _G.GetMinimapShape = state.shape
    shapeOverridden = false

    if failed and not restoreWarned then
        restoreWarned = true
        ns:Print("小地图还原未完全成功（可能处于战斗中），/reload 可恢复默认小地图。")
    end
end

local function Skin()
    if not active then return false end
    local minimap = _G.Minimap
    if not minimap then return false end

    Remember(minimap)
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

function M:Initialize()
    -- Blizzard re-anchors the cluster when the area changes; the skin is re-applied.
    EventBus:Register("PLAYER_ENTERING_WORLD", function() Skin() end)
    EventBus:Register("ZONE_CHANGED_NEW_AREA", function() Skin() end)
    EventBus:Register("MONETUI_THEME_CHANGED", function()
        if active then ClearDefaultArt() end
    end)

    active = true
    Skin()
end

--- Runtime switch (config panel / `/mui minimap on|off`).  Disabling restores
--- everything the skin changed, not just the panel.
function M:SetEnabled(enabled)
    active = enabled and true or false
    if active then
        Skin()
    else
        Restore()
    end
    if panel then panel:SetShown(active) end
end

ns:Register("Minimap", M)
