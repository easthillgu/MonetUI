-- Utils/Widget.lua
-- Widget factory: shared UI construction (the addon's private API).
--
-- Everything created here can be themed: Widget:Theme() registers the widget in
-- a weak table and every registered widget is re-tinted when Core fires
-- "MONETUI_THEME_CHANGED".  That is the loose coupling the modules rely on.

local ADDON_NAME, ns = ...

local Color = ns.Color
local Media = ns.Media
local EventBus = ns.EventBus

local Widget = {}
ns.Widget = Widget

-- weak keys so hidden / discarded widgets do not leak
local themed = setmetatable({}, { __mode = "k" })

--- The border colour for a widget: its own override if it set one, otherwise the
-- user's global slot (see Color:GetBorderKey).  Only the hue comes from the key:
-- the opacity stays the edge slot's, so switching to the (translucent) ambient
-- tint can never make a border invisible.
local function BorderColor(opts)
    local key = (opts and opts.borderKey) or Color:GetBorderKey()
    local r, g, b = Color:Get(key)
    return r, g, b
end

-- -- Frame creation -----------------------------------------------------------

function Widget:CreateFrame(name, parent, width, height, template)
    local frame = CreateFrame("Frame", name, parent, template or "BackdropTemplate")
    if width then frame:SetSize(width, height or width) end
    return frame
end

function Widget:Bar(parent, width, height, textureKey)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(Media:Texture(textureKey or "statusbar"))
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    if width then bar:SetSize(width, height or 18) end

    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    local r, g, b = Color:GetNeutral()
    bar.bg:SetColorTexture(r, g, b, 0.25)

    themed[bar] = { kind = "bar", bgAlpha = 0.25, texture = textureKey }
    return bar
end

function Widget:Icon(parent, size, layer, sublevel)
    local icon = parent:CreateTexture(nil, layer or "ARTWORK", nil, sublevel)
    if size then icon:SetSize(size, size) end
    return icon
end

--- A FontString using the addon fonts.
-- @param key      font key in Media.font ("pixel", "combat", "cooldown", "roadway")
-- @param colorKey "edge" | "neutral" | "highlight" | "health" | "danger" | {r,g,b}
function Widget:Font(parent, size, key, colorKey, justify, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    local fontPath = Media:Font(key)
    fs:SetFont(fontPath, size or 12, "")
    if fs.SetShadowOffset then fs:SetShadowOffset(0, 0) end
    fs:SetJustifyH(justify or "LEFT")
    Widget:ColorText(fs, colorKey)

    themed[fs] = { kind = "text", colorKey = colorKey }
    return fs
end

--- Re-apply an existing FontString's font (used when a widget already exists).
function Widget:SetFont(fs, size, key, flags)
    if not fs or not fs.SetFont then return fs end
    pcall(fs.SetFont, fs, Media:Font(key), size or 12, flags or "")
    return fs
end

function Widget:ColorText(fs, colorKey)
    if not fs or not fs.SetTextColor then return fs end

    local r, g, b, a
    if type(colorKey) == "table" then
        r, g, b, a = colorKey.r, colorKey.g, colorKey.b, colorKey.a or 1
    elseif colorKey == "edge" then
        r, g, b, a = Color:GetEdge()
    elseif colorKey == "highlight" then
        r, g, b, a = Color:GetHighlight()
    elseif colorKey == "health" then
        r, g, b, a = Color:GetHealth()
    elseif colorKey == "danger" then
        r, g, b, a = Color:GetDanger()
    elseif colorKey == "resource" then
        r, g, b, a = Color:GetResource()
    else
        r, g, b, a = Color:GetNeutral()
    end

    fs:SetTextColor(r, g, b, a or 1)
    return fs
end

function Widget:Cooldown(parent, size)
    local cd = CreateFrame("Cooldown", nil, parent, "CooldownFrameTemplate")
    cd:SetAllPoints()
    if size then cd:SetSize(size, size) end
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetDrawSwipe(true)
    cd:SetHideCountdownNumbers(false)
    Widget:StyleCooldownText(cd)
    return cd
end

--- Style the built-in countdown numbers of a Cooldown widget.
function Widget:StyleCooldownText(cd, size, key, color)
    if not cd then return end
    for _, region in ipairs({ cd:GetRegions() }) do
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
            pcall(region.SetFont, region, Media:Font(key or "cooldown"), size or 14, "OUTLINE")
            local r, g, b = 1, 1, 1
            if type(color) == "table" then r, g, b = color.r, color.g, color.b end
            pcall(region.SetTextColor, region, r, g, b, 1)
        end
    end
end

function Widget:CloseButton(parent, size)
    local btn = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    btn:SetSize(size or 24, size or 24)
    return btn
end

-- -- Theming ------------------------------------------------------------------

--- Register a frame for themed background + border.
-- @param opts table { thickness=, bgAlpha=, borderAlpha=, bgTexture=, borderKey= }
function Widget:Theme(frame, opts)
    if not frame then return frame end
    opts = opts or {}
    opts.thickness = opts.thickness or 1
    opts.bgAlpha = opts.bgAlpha or 0.85
    opts.kind = "frame"

    themed[frame] = opts

    if frame.SetBackdrop then
        if not frame.__monetBackdrop then
            frame.__monetBackdrop = {
                bgFile   = Media.texture.blank,
                edgeFile = Media.texture.blank,
                edgeSize = opts.thickness,
                insets   = {
                    left = opts.thickness, right = opts.thickness,
                    top = opts.thickness, bottom = opts.thickness,
                },
            }
        end
        frame:SetBackdrop(frame.__monetBackdrop)
        Widget:Refresh(frame, opts)
    end
    return frame
end

function Widget:Refresh(frame, opts)
    opts = opts or themed[frame] or {}

    if opts.kind == "bar" then
        if frame.bg then
            local r, g, b = Color:GetNeutral()
            frame.bg:SetColorTexture(r, g, b, opts.bgAlpha or 0.25)
        end
    elseif opts.kind == "text" then
        Widget:ColorText(frame, opts.colorKey)
    elseif frame.SetBackdropColor then
        local ar, ag, ab = Color:GetAmbient()
        frame:SetBackdropColor(ar * 0.35, ag * 0.35, ab * 0.35, opts.bgAlpha or 0.85)

        local state = opts.borderState
        if state then
            -- A live state (threat glow ...) outranks the themed colour, and
            -- because it lives in this opts table the theme-refresh broadcast
            -- re-applies *it* instead of stomping it.
            frame:SetBackdropBorderColor(state.r, state.g, state.b, state.a or 1)
        else
            local kr, kg, kb = BorderColor(opts)
            local _, _, _, ka = Color:GetEdge()
            frame:SetBackdropBorderColor(kr, kg, kb, opts.borderAlpha or ka or 1)
        end
    end
end

--- Give a themed frame a live border colour, or take it back with no colour.
-- Dynamic states (threat glow, hover) write here instead of calling
-- SetBackdropBorderColor directly: the override is kept in the widget's theme
-- entry, so a MONETUI_THEME_CHANGED repaint applies the same override rather
-- than resetting to the global border slot, and clearing it returns the frame
-- to that slot.  Returns false for a frame that was never themed.
function Widget:SetBorderState(frame, r, g, b, a)
    local opts = frame and themed[frame]
    if not opts then return false end

    if r then
        opts.borderState = { r = r, g = g, b = b, a = a }
    else
        opts.borderState = nil
    end
    Widget:Refresh(frame, opts)
    return true
end

--- Re-tint every widget created through the factory.
function Widget:RefreshThemes()
    for frame, opts in pairs(themed) do
        if frame then
            Widget:Refresh(frame, opts)
        end
    end
end

--- Border only (no background) using the current border colour.
function Widget:ApplyBorder(frame, thickness, borderKey)
    local r, g, b
    if borderKey then
        r, g, b = Color:Get(borderKey)
    else
        r, g, b = Color:GetBorder()
    end
    local _, _, _, a = Color:GetEdge()
    thickness = thickness or 1
    if not frame.backdrop then
        frame.backdrop = {
            bgFile = Media.texture.blank,
            edgeFile = Media.texture.blank,
            edgeSize = thickness,
            insets = { left = thickness, right = thickness, top = thickness, bottom = thickness },
        }
    end
    if frame.SetBackdrop then
        frame:SetBackdrop(frame.backdrop)
        frame:SetBackdropColor(0, 0, 0, 0)
        frame:SetBackdropBorderColor(r, g, b, a or 1)
    end
    return frame
end

--- Subtle hover highlight used by the modules.
function Widget:Highlight(frame, alpha)
    frame:SetScript("OnEnter", function(self)
        if self.icon then self.icon:SetVertexColor(1.2, 1.2, 1.2) end
        if self.SetBackdropBorderColor then
            local r, g, b = Color:GetHighlight()
            self:SetBackdropBorderColor(r, g, b, alpha or 1)
        end
    end)
    frame:SetScript("OnLeave", function(self)
        if self.icon then self.icon:SetVertexColor(1, 1, 1) end
        if self.SetBackdropBorderColor then
            local r, g, b = BorderColor(themed[self])
            local _, _, _, a = Color:GetEdge()
            self:SetBackdropBorderColor(r, g, b, a or 1)
        end
    end)
    return frame
end

--- Themed, safe tooltip helper (GameTooltip methods are guarded).
function Widget:UnitTooltip(frame, unit)
    local GameTooltip = _G.GameTooltip
    if not GameTooltip then return frame end

    frame:SetScript("OnEnter", function(self)
        pcall(GameTooltip.SetOwner, GameTooltip, self, "ANCHOR_RIGHT")
        pcall(GameTooltip.SetUnit, GameTooltip, unit)
        pcall(GameTooltip.Show, GameTooltip)
    end)
    frame:SetScript("OnLeave", function()
        pcall(GameTooltip.Hide, GameTooltip)
    end)
    frame:EnableMouse(true)
    return frame
end

-- Re-tint automatically whenever the theme changes.
EventBus:Register("MONETUI_THEME_CHANGED", function()
    Widget:RefreshThemes()
end)
