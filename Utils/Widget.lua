-- Utils/Widget.lua
-- Widget factory: shared UI construction (the addon's private API).
-- Everything created here can be themed: Widget:Theme() registers the widget in a weak table and every registered widget is re-tinted when Core fires "MONETUI_THEME_CHANGED" -- the loose coupling the modules rely on.

local ADDON_NAME, ns = ...

local Color = ns.Color
local Media = ns.Media
local EventBus = ns.EventBus

local Widget = {}
ns.Widget = Widget

-- weak keys so hidden / discarded widgets do not leak
local themed = setmetatable({}, { __mode = "k" })

--- The border colour for a widget: its own override if it set one, otherwise the user's global slot (see Color:GetBorderKey).
-- Only the hue comes from the key: the opacity stays the edge slot's, so switching to the (translucent) ambient tint can never make a border invisible.
local function BorderColor(opts)
    local key = (opts and opts.borderKey) or Color:GetBorderKey()
    local r, g, b = Color:Get(key)
    return r, g, b
end

function Widget:CreateFrame(name, parent, width, height, template)
    local frame = CreateFrame("Frame", name, parent, template or "BackdropTemplate")
    if width then frame:SetSize(width, height or width) end
    return frame
end

function Widget:Bar(parent, width, height, textureKey)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(Media:Texture(textureKey or "barfill"))
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
-- @param key font key in Media.font ("pixel", "cooldown"); @param colorKey "edge" | "neutral" | "highlight" | "health" | "danger" | {r,g,b}
function Widget:Font(parent, size, key, colorKey, justify, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    local fontPath = Media:Font(key)
    fs:SetFont(fontPath, Media:SnapSize(size), Media.fontFlags)
    if fs.SetShadowOffset then fs:SetShadowOffset(0, 0) end
    fs:SetJustifyH(justify or "LEFT")
    Widget:ColorText(fs, colorKey)

    themed[fs] = { kind = "text", colorKey = colorKey }
    return fs
end

--- Re-apply an existing FontString's font (used when a widget already exists).
function Widget:SetFont(fs, size, key, flags)
    if not fs or not fs.SetFont then return fs end
    pcall(fs.SetFont, fs, Media:Font(key), Media:SnapSize(size), flags or Media.fontFlags)
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
            pcall(region.SetFont, region, Media:Font(key or "cooldown"), Media:SnapSize(size), Media.fontFlags)
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
        -- edgeSize / insets are physical pixels (thickness * Media:Mult()), so the line stays crisp at any UI scale instead of softening when scale ~= 1.
        local mult = Media:Mult()
        local edge = opts.thickness * mult
        local bd = frame.__monetBackdrop
        if not bd then
            bd = {}
            frame.__monetBackdrop = bd
        end
        bd.bgFile   = Media.texture.blank
        bd.edgeFile = Media.texture.blank
        bd.edgeSize = edge
        bd.insets = { left = edge, right = edge, top = edge, bottom = edge }
        frame:SetBackdrop(bd)
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
            -- A live state (threat glow ...) outranks the themed colour and lives in this opts table, so a theme-refresh broadcast re-applies *it* instead of stomping it.
            frame:SetBackdropBorderColor(state.r, state.g, state.b, state.a or 1)
        else
            local kr, kg, kb = BorderColor(opts)
            local _, _, _, ka = Color:GetEdge()
            frame:SetBackdropBorderColor(kr, kg, kb, opts.borderAlpha or ka or 1)
        end
    end
end

--- Give a themed frame a live border colour, or take it back with no colour.
-- Dynamic states (threat glow, hover) write here instead of SetBackdropBorderColor: the override is kept in the widget's theme entry, so a MONETUI_THEME_CHANGED repaint applies the same override rather than resetting to the global slot.  Returns false for a frame that was never themed.
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
    local edge = thickness * Media:Mult()   -- N physical pixels at any scale
    if not frame.backdrop then
        frame.backdrop = {}
    end
    frame.backdrop.bgFile = Media.texture.blank
    frame.backdrop.edgeFile = Media.texture.blank
    frame.backdrop.edgeSize = edge
    frame.backdrop.insets = { left = edge, right = edge, top = edge, bottom = edge }
    if frame.SetBackdrop then
        frame:SetBackdrop(frame.backdrop)
        frame:SetBackdropColor(0, 0, 0, 0)
        frame:SetBackdropBorderColor(r, g, b, a or 1)
    end
    return frame
end

--- Subtle hover highlight used by the modules: one shared driver breathes the border alpha every ~1.2 s between 40% and full while hovered -- the Andromeda "button hover animation" idea, run against our border slot so it reads as the Monet edge quietly pulsing.
local pulsing = setmetatable({}, { __mode = "k" })
local PULSE_PERIOD = 1.2

--- Put a border back to whatever it should show when not hovered: its live dynamic state (quality, threat) if it has one, otherwise the theme slot.
local function RestoreBorder(frame)
    if not frame or not frame.SetBackdropBorderColor then return end
    local opts = themed[frame]
    local st = opts and opts.borderState
    if st then
        frame:SetBackdropBorderColor(st.r, st.g, st.b, st.a or 1)
    else
        local r, g, b = BorderColor(opts)
        local _, _, _, a = Color:GetEdge()
        frame:SetBackdropBorderColor(r, g, b, a or 1)
    end
end

local pulseDriver = CreateFrame("Frame")
pulseDriver:Hide()
pulseDriver:SetScript("OnUpdate", function(self, elapsed)
    for frame, st in pairs(pulsing) do
        if not frame:IsShown() or not frame:IsMouseOver() then
            -- lost the leave event (hidden / teleported) -- close out by hand
            pulsing[frame] = nil
            if frame.icon then frame.icon:SetVertexColor(1, 1, 1) end
            RestoreBorder(frame)
        else
            st.t = st.t + elapsed
            local wave = 0.5 + 0.5 * math.sin(st.t * (2 * math.pi) / PULSE_PERIOD)
            frame:SetBackdropBorderColor(st.r, st.g, st.b,
                st.amax * (0.4 + 0.6 * wave))
        end
    end
    if next(pulsing) == nil then self:Hide() end
end)

--- Start the border breath on a frame.  Public so hand-written hover scripts (the bag slots also drive a tooltip) can breathe exactly like Widget:Highlight -- one driver, one look.
--   r,g,b  hue to breathe;  amax peak alpha (default 1)
function Widget:Pulse(frame, r, g, b, amax)
    if not frame or not frame.SetBackdropBorderColor then return end
    pulsing[frame] = { r = r, g = g, b = b, amax = amax or 1, t = 0 }
    frame:SetBackdropBorderColor(r, g, b, amax or 1)
    pulseDriver:Show()
end

--- Stop the breath and put the border back (dynamic state first).
function Widget:UnPulse(frame)
    if not frame then return end
    pulsing[frame] = nil
    RestoreBorder(frame)
end

function Widget:Highlight(frame, alpha)
    frame:SetScript("OnEnter", function(self)
        if self.icon then self.icon:SetVertexColor(1.2, 1.2, 1.2) end
        local r, g, b = Color:GetHighlight()
        local st = themed[self] and themed[self].borderState
        if st then r, g, b = st.r, st.g, st.b end   -- pulse the live hue
        Widget:Pulse(self, r, g, b, alpha or 1)
    end)
    frame:SetScript("OnLeave", function(self)
        if self.icon then self.icon:SetVertexColor(1, 1, 1) end
        Widget:UnPulse(self)
    end)
    return frame
end

--- The Monet button/slot "material": a seamless weave tile laid UNDER the content (this is the Andromeda/NDui "tiled backdrop texture" step, drawn from scratch) plus an ADD-blended top-lit gradient sheen (monet-barfill) OVER the content.
-- Both layers are near-white and tintable, so one theme colour drives the whole material; purely additive -- two texture regions, the frame itself untouched, which keeps it safe on Blizzard secure buttons.
--   opts.weaveAlpha / opts.alpha  strength of weave / sheen (defaults 0.6 / 0.2);  opts.r,g,b tint;  opts.weaveLayer,Sublevel / layer,Sublevel draw layers (BACKGROUND/2, OVERLAY/1)
function Widget:ButtonMaterial(frame, opts)
    if frame.__monetMaterial then return frame.__monetMaterial end
    opts = opts or {}

    local weave = frame:CreateTexture(nil, opts.weaveLayer or "BACKGROUND", nil, opts.weaveSublevel or 2)
    weave:SetTexture(Media.texture["monet-diagonal-weave"])
    weave:SetAllPoints(frame)
    weave:SetVertexColor(opts.r or 1, opts.g or 1, opts.b or 1, opts.weaveAlpha or 0.6)

    local sheen = frame:CreateTexture(nil, opts.layer or "OVERLAY", nil, opts.sublevel or 1)
    sheen:SetTexture(Media.texture["monet-barfill"])
    sheen:SetAllPoints(frame)
    sheen:SetBlendMode("ADD")
    sheen:SetVertexColor(opts.r or 1, opts.g or 1, opts.b or 1, opts.alpha or 0.2)

    frame.__monetMaterial = { weave = weave, sheen = sheen }
    return frame.__monetMaterial
end

--- Soft drop shadow around a frame: four gradient strips reaching outward from the frame edge (opaque where they touch the frame, fading to nothing at the far side), tinted from the Monet ambient tone so it reads as a cool painted grey-blue.
-- Pure SetGradient geometry -- no texture ships for it and the fade direction is explicit per side, which a single edgeFile texture cannot guarantee (the Andromeda equivalent is one self-drawn ui-shadow-outline used as an edgeFile).
--   opts.size   reach, in physical pixels (default 6);  opts.alpha  opacity at the frame edge (default 0.55)
function Widget:Shadow(frame, opts)
    if not frame then return nil end
    if frame.__monetShadow then return frame.__monetShadow end
    opts = opts or {}

    -- The shadow sits one level below the frame; a level-0 frame would tie with its own child, so lift the frame first.
    if frame.GetFrameLevel and frame:GetFrameLevel() < 1 then
        frame:SetFrameLevel(1)
    end

    local reach = (opts.size or 6) * Media:Mult()
    local a = opts.alpha or 0.55
    local ar, ag, ab = Color:GetAmbient()
    local r, g, b = ar * 0.3, ag * 0.3, ab * 0.3

    local sh = CreateFrame("Frame", nil, frame)
    sh:SetFrameLevel(frame:GetFrameLevel() - 1)
    sh:SetAllPoints(frame)
    pcall(sh.EnableMouse, sh, false)
    frame.__monetShadow = sh

    local function MakeColor(rr, gg, bb, aa)
        if type(CreateColor) == "function" then return CreateColor(rr, gg, bb, aa) end
        return { GetRGBA = function() return rr, gg, bb, aa end }
    end
    local far  = MakeColor(r, g, b, 0)
    local near = MakeColor(r, g, b, a)

    local okAll = false
    -- Two anchors fix the strip's span, SetHeight/SetWidth fix its reach; every strip is oriented so the opaque end lands against the frame.
    local function Strip(orient, minC, maxC, ...)
        local tex = sh:CreateTexture(nil, "ARTWORK")
        tex:ClearAllPoints()
        tex:SetPoint(...)
        local ok = false
        if type(CreateColor) == "function" then
            ok = pcall(tex.SetGradient, tex, orient, minC, maxC)
        end
        if not ok then
            local r1, g1, b1, a1 = minC:GetRGBA()
            local r2, g2, b2, a2 = maxC:GetRGBA()
            ok = pcall(tex.SetGradient, tex, orient, r1, g1, b1, a1, r2, g2, b2, a2)
        end
        if ok then okAll = true else tex:Hide() end
        return tex
    end

    local top = Strip("VERTICAL", far, near,
        "TOPLEFT", sh, "TOPLEFT", 0, reach,
        "TOPRIGHT", sh, "TOPRIGHT", 0, reach)
    top:SetHeight(reach)

    local bot = Strip("VERTICAL", near, far,
        "BOTTOMLEFT", sh, "BOTTOMLEFT", 0, -reach,
        "BOTTOMRIGHT", sh, "BOTTOMRIGHT", 0, -reach)
    bot:SetHeight(reach)

    local lef = Strip("HORIZONTAL", far, near,
        "TOPLEFT", sh, "TOPLEFT", -reach, 0,
        "BOTTOMLEFT", sh, "BOTTOMLEFT", -reach, 0)
    lef:SetWidth(reach)

    local rig = Strip("HORIZONTAL", near, far,
        "TOPRIGHT", sh, "TOPRIGHT", reach, 0,
        "BOTTOMRIGHT", sh, "BOTTOMRIGHT", reach, 0)
    rig:SetWidth(reach)

    if not okAll then
        sh:Hide()
        frame.__monetShadow = nil
        return nil
    end
    return sh
end

--- A hand-painted brush underline (monet-brush-stroke) beneath `anchor` -- our version of Andromeda's gradient hairline: the spindle tapers at both ends and keeps its baked cream-core / ochre-rim two-tone, so it is only faded, never re-tinted.
--   opts.gap  distance below the anchor, physical px (default 3);  opts.height  stroke height, physical px (default 9);  opts.alpha  (default 0.9)
function Widget:Rule(frame, anchor, opts)
    if not frame or not anchor then return nil end
    if frame.__monetRule then return frame.__monetRule end
    opts = opts or {}
    local gap = (opts.gap or 3) * Media:Mult()
    local tex = frame:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(Media.texture["monet-brush-stroke"])
    tex:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -gap)
    tex:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -gap)
    tex:SetHeight((opts.height or 9) * Media:Mult())
    tex:SetVertexColor(1, 1, 1, opts.alpha or 0.9)
    frame.__monetRule = tex
    return tex
end

--- Four brush ornaments on the frame corners (monet-corner), a small flourish Andromeda has no equivalent for -- its only chrome decoration is a gradient hairline.
-- The ornament lives on a child frame raised above the content level, so a window's own buttons can never bury the corners; it keeps the asset's painted two-tone (tinted only for opacity).
--   opts.size  edge length, physical px (default 16);  opts.alpha  (default 0.9);  opts.omit  corner names left bare, e.g. { "TOPRIGHT" } when a close button owns it
function Widget:Corners(frame, opts)
    if not frame then return nil end
    if frame.__monetCorners then return frame.__monetCorners end
    opts = opts or {}

    local omit = {}
    for _, name in ipairs(opts.omit or {}) do omit[name] = true end

    local orn = CreateFrame("Frame", nil, frame)
    orn:SetFrameLevel(frame:GetFrameLevel() + 10)
    orn:SetAllPoints(frame)
    pcall(orn.EnableMouse, orn, false)
    frame.__monetOrnament = orn

    local size = (opts.size or 16) * Media:Mult()
    local r, g, b = Color:GetEdge()
    local a = opts.alpha or 0.9
    local path = Media.texture["monet-corner"]

    -- The asset is the top-left arc; the other three are mirror images.
    local defs = {
        { "TOPLEFT",     nil, nil },
        { "TOPRIGHT",    true, nil },
        { "BOTTOMLEFT",  nil, true },
        { "BOTTOMRIGHT", true, true },
    }
    local list = {}
    for _, d in ipairs(defs) do
        if not omit[d[1]] then
            local tex = orn:CreateTexture(nil, "ARTWORK")
            tex:SetTexture(path)
            tex:SetPoint(d[1], orn, d[1], 0, 0)
            tex:SetSize(size, size)
            if d[2] and d[3] then
                tex:SetTexCoord(1, 0, 1, 0)
            elseif d[2] then
                tex:SetTexCoord(1, 0, 0, 1)
            elseif d[3] then
                tex:SetTexCoord(0, 1, 1, 0)
            end
            tex:SetVertexColor(r, g, b, a)
            list[#list + 1] = tex
        end
    end
    frame.__monetCorners = list
    return list
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
