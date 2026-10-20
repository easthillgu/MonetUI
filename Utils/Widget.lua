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

-- Shading is geometry, not art: a StatusBar's texture is a flat tintable base colour and the volume
-- comes from a gradient set at runtime, along the bar's own axis.  Baking the ramp into the texture
-- (what monet_barfill used to do) ties the shading to one bar height -- stretch a 16px ramp over a
-- 40px slider thumb and it stops reading as a cross-section and becomes one long fade.
-- Two shared colour pairs serve every bar and every surface: SetGradient copies the values at call time,
-- so there is no per-widget state and no per-event allocation.  Built lazily and once -- a client without
-- CreateColor just keeps the flat base colour instead of raising on every bar.
local gradTail, gradHead   -- StatusBar fill: trailing end -> leading edge
local surfLit, surfSunk    -- flat surface: lit on top -> sunk below
local function EnsureGradients()
    if gradTail then return true end
    if type(CreateColor) ~= "function" then return false end
    gradTail = CreateColor(0.60, 0.60, 0.64, 1)
    gradHead = CreateColor(1, 1, 1, 1)
    surfLit  = CreateColor(1, 1, 1, 1)
    surfSunk = CreateColor(0.28, 0.28, 0.30, 1)
    return true
end

--- Re-derive a StatusBar's fill gradient from the bar's own orientation.
-- MUST be called again after SetStatusBarTexture: that call builds a brand new texture object, and the
-- old one carried the gradient (the same trap that catches their fill rotation after a texture swap).
function Widget:BarGradient(bar)
    if not bar then return end
    local tex = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    if not tex or not EnsureGradients() then return end
    local vertical = false
    if bar.GetOrientation then
        local ok, o = pcall(bar.GetOrientation, bar)
        vertical = ok and o == "VERTICAL"
    end
    tex:SetGradient(vertical and "VERTICAL" or "HORIZONTAL", gradTail, gradHead)
end

--- Cross-sectional shading for a flat surface (button sheen, scroll thumb): lit from the top, sinking
-- toward the bottom.  Unlike a bar this is about the surface's thickness, not its fill direction, so it
-- is always vertical -- a 12x40 thumb reads as a rounded grip instead of a smear.
function Widget:TopLight(tex)
    if not tex or not EnsureGradients() then return end
    tex:SetGradient("VERTICAL", surfLit, surfSunk)
end

--- The border colour for a widget: its own override if it set one, otherwise the user's global slot (see Color:GetBorderKey).
-- Only the hue comes from the key: the opacity stays the edge slot's, so switching to the (translucent) ambient tint can never make a border invisible.
local function BorderColor(opts)
    local key = (opts and opts.borderKey) or Color:GetBorderKey()
    local r, g, b = Color:Get(key)
    return r, g, b
end

-- Every size the addon hands to the engine goes through one of these three, so the whole UI lands on
-- the pixel grid without any call site having to remember.  They are the reason the rest of the file
-- is still allowed to call plain SetSize: a raw size is a size that missed the grid.
function Widget:Size(frame, width, height)
    if not frame then return frame end
    local w = Media:SnapUnit(width)
    frame:SetSize(w, height and Media:SnapUnit(height) or w)
    return frame
end

function Widget:Width(frame, width)   if frame then frame:SetWidth(Media:SnapUnit(width)) end return frame end
function Widget:Height(frame, height) if frame then frame:SetHeight(Media:SnapUnit(height)) end return frame end

function Widget:CreateFrame(name, parent, width, height, template)
    local frame = CreateFrame("Frame", name, parent, template or "BackdropTemplate")
    if width then Widget:Size(frame, width, height or width) end
    return frame
end

function Widget:Bar(parent, width, height, textureKey)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(Media:Texture(textureKey or "barfill"))
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    if width then Widget:Size(bar, width, height or 18) end
    Widget:BarGradient(bar)

    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    local r, g, b = Color:GetNeutral()
    bar.bg:SetColorTexture(r, g, b, 0.25)

    themed[bar] = { kind = "bar", bgAlpha = 0.25, texture = textureKey }
    return bar
end

-- The canvas weave (Assets/Textures/monet_canvas_weave.tga, drawn by tools/regen-textures.js):
-- 64x64, a grid of 2px threads with an 8px step, so the cloth repeats every 8 rows.  The
-- number is the texture's, not a taste call -- the texcoord window below is measured in it.
local WEAVE_SIZE = 64

--- The Monet "canvas" ground for a bar: the same woven cloth the buttons sit on
--- (monet_canvas_weave), laid over the bar's background so the empty part of a bar reads as
--- painted canvas instead of a flat hole.  The fill stays flat on purpose -- a bar's volume
--- is SetGradient geometry (see Widget:BarGradient), and a woven fill would fight it.
--- ORDER MATTERS: call this AFTER the bar's other background textures, so the cloth draws
--- over them (same draw layer, creation order) while the fill still covers it.
--- The weave is 64 rows tall and a unit frame bar is only a couple of UI units tall: a 64-row
--- texture squeezed into three rows is averaged into a flat tone by the mip/filter stage, so
--- the texture is sampled through a texcoord window of the bar's own height instead.  The
--- window is measured in PHYSICAL pixels (Media:Mult() is the size of one physical pixel in
--- UI units), so one texel lands on one physical pixel and the threads read as threads
--- instead of as a smear.  The window always starts on the same row of the cloth (the weave
--- repeats every 8 rows), so a 1px power bar and a 2px health bar show the same phase.
---   opts.height  bar height in UI units (default: the bar's own height)
---   opts.alpha   opacity of the weave (default 0.5)
--- @return the weave texture, cached on the bar as __monetWeave
function Widget:BarWeave(bar, opts)
    if not bar then return nil end
    opts = opts or {}

    local weave = bar.__monetWeave
    if not weave then
        -- Same layer as the bar's other background textures (BACKGROUND, sublevel 0) and
        -- created after them, so it draws over them -- the StatusBar's own fill texture sits
        -- in a higher layer, so the fill still covers the cloth wherever the bar is filled.
        -- (Andromeda's health element is the reference: its "lost" background is created the
        -- same way and the fill stays on top.)
        weave = bar:CreateTexture(nil, "BACKGROUND")
        weave:SetTexture(Media.texture["monet_canvas_weave"])
        weave:SetAllPoints(bar)
        bar.__monetWeave = weave
    end

    -- One texel per physical pixel.
    local height = opts.height or (bar:GetHeight() or 2)
    local rows = math.max(1, math.min(WEAVE_SIZE - 1, math.floor(height / Media:Mult() + 0.5)))
    weave:SetTexCoord(0, 1, 1 / WEAVE_SIZE, (1 + rows) / WEAVE_SIZE)

    local r, g, b = Color:GetNeutral()
    local alpha = opts.alpha or 0.5
    weave:SetVertexColor(r, g, b, alpha)

    -- The ground follows the theme like the flat background does.
    local entry = themed[bar]
    if entry then
        entry.weave = weave
        entry.weaveAlpha = alpha
    end
    return weave
end

function Widget:Icon(parent, size, layer, sublevel)
    local icon = parent:CreateTexture(nil, layer or "ARTWORK", nil, sublevel)
    if size then Widget:Size(icon, size, size) end
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
    if size then Widget:Size(cd, size) end
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
    Widget:Size(btn, size or 24)
    return btn
end

-- The rounded-border art, in three ring widths.  Each entry is fixed by the texture, not by taste:
--   ring   = the ring's width in texels, which 9-slice maps 1:1 into UI units  -> also the background inset
--   slice  = the outer arc radius in texels, which is also the smallest edgeSize that shows the whole arc
-- The generated files are Assets/Textures/monet_round_edge{,_thin,_thick}.tga; the three numbers have to
-- stay in step with tools/regen-textures.js (ROUND_EDGES) or the border drifts or gets clipped.
local ROUND_EDGES = {
    { key = "monet_round_edge_thin",  ring = 1, slice = 2 },
    { key = "monet_round_edge",       ring = 2, slice = 3 },
    { key = "monet_round_edge_thick", ring = 3, slice = 4 },
}

--- Pick the ring whose width is nearest the physical thickness asked for.
-- The ring lives in the texture, so its width can only be a whole number of UI units; the width we
-- actually want is thickness / uiScale, which is usually fractional (thickness=2 at uiScale 0.71 wants
-- 2.82).  Rounding to the nearest available ring keeps the error under half a physical pixel instead
-- of letting the two rounded panels drift by 2/uiScale against every flat border in the addon.
local function PickRoundEdge(thickness)
    local want = thickness * Media:Mult()        -- 想要的 UI 单位数
    local best, bestErr = ROUND_EDGES[2], nil
    for i = 1, #ROUND_EDGES do
        local e = ROUND_EDGES[i]
        local err = math.abs(e.ring - want)
        if not bestErr or err < bestErr then best, bestErr = e, err end
    end
    return best
end

--- (Re)build the backdrop table and push it to the frame.  Split out of Theme so it can be re-run on
--- its own: every value here is derived from Media:Mult(), i.e. from the uiScale CVar, so a UI scale
--- change invalidates all of them.  Without this the borders built before the player moved the slider
--- keep their old physical width while newly created widgets get the new one -- two border widths on
--- screen at once.
function Widget:ApplyBackdrop(frame, opts)
    if not frame or not frame.SetBackdrop then return end
    local bd = frame.__monetBackdrop
    if not bd then
        bd = {}
        frame.__monetBackdrop = bd
    end
    bd.bgFile = Media.texture.blank
    if opts.round then
        -- A rounded panel takes the 9-slice edge art instead of the flat BLANK: the backdrop draws a
        -- texture's outer EDGE_SIZE px as the four corners and stretches the edges, so an arc drawn
        -- in the art rounds the border at any frame size.  A mask could not do this -- it is applied
        -- pixel for pixel, so the radius would stretch with the frame's height.
        -- Three couplings come with the art, all of them fixed by ROUND_EDGES:
        --   * EDGE_SIZE is both the corner slice and the sampled strip, so it has to cover the whole
        --     arc (slice).
        --   * the ring painted inside the art is what makes the visible line that wide (ring).
        --   * the ring is baked in texture pixels, which are UI units here.  A flat border is held at
        --     a constant *physical* width through Media:Mult(); a curved one cannot be, because the
        --     art cannot hold half a texel -- hence three ring widths and PickRoundEdge.
        local e = PickRoundEdge(opts.thickness)
        bd.edgeFile = Media.texture[e.key]
        bd.edgeSize = math.max(e.slice, e.ring)
        bd.insets = { left = e.ring, right = e.ring, top = e.ring, bottom = e.ring }
    else
        -- edgeSize / insets are physical pixels (thickness * Media:Mult()), so the line stays crisp at any UI scale instead of softening when scale ~= 1.
        local edge = opts.thickness * Media:Mult()
        bd.edgeFile = Media.texture.blank
        bd.edgeSize = edge
        bd.insets = { left = edge, right = edge, top = edge, bottom = edge }
    end
    frame:SetBackdrop(bd)
end

--- Register a frame for themed background + border.
-- @param opts table { thickness=, bgAlpha=, borderAlpha=, bgTexture=, borderKey=, round= }
function Widget:Theme(frame, opts)
    if not frame then return frame end
    opts = opts or {}
    opts.thickness = opts.thickness or 1
    opts.bgAlpha = opts.bgAlpha or 0.85
    opts.kind = "frame"

    themed[frame] = opts

    Widget:ApplyBackdrop(frame, opts)
    Widget:Refresh(frame, opts)
    return frame
end

function Widget:Refresh(frame, opts)
    opts = opts or themed[frame] or {}

    if opts.kind == "bar" then
        if frame.bg then
            local r, g, b = Color:GetNeutral()
            frame.bg:SetColorTexture(r, g, b, opts.bgAlpha or 0.25)
        end
        -- The woven ground follows the theme like the flat background does, and its texcoord
        -- window follows the UI scale (one texel per physical pixel).
        if opts.weave then
            Widget:BarWeave(frame, { alpha = opts.weaveAlpha })
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
        -- The table is reused: the state layer repaints the border on every
        -- pulse frame, and a fresh table each time would be pure garbage.
        local state = opts.borderState
        if not state then
            state = { r = r, g = g, b = b, a = a }
            opts.borderState = state
        else
            state.r, state.g, state.b, state.a = r, g, b, a
        end
    else
        opts.borderState = nil
    end
    Widget:Refresh(frame, opts)
    return true
end

--- Re-tint every widget created through the factory.
-- Also re-derives the backdrop geometry, not just the colours: edgeSize / insets are built from
-- Media:Mult(), so a UI scale change leaves them stale.  `rescale` is set by the UI_SCALE_CHANGED
-- handler; on an ordinary theme change only the colours move and the backdrop is left alone.
function Widget:RefreshThemes(rescale)
    for frame, opts in pairs(themed) do
        if frame then
            if rescale and opts.kind == "frame" then
                Widget:ApplyBackdrop(frame, opts)
            end
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

--- IsMouseOver that can never raise.
-- This client declares IsMouseOver's return as SecretWhenAnchoringSecret: it is a SECRET boolean
-- whenever the frame's anchoring is secret (protected frames in combat, exactly when a threat pulse is
-- running).  pcall does not help -- the call succeeds and hands back a secret -- and `not secret` or
-- `secret and x` raises.  Every hover question in the addon goes through this one guarded answer.
-- The secret test has to come before ANY comparison: `value == nil` on a secret raises too.
function Widget:IsMouseOver(frame)
    if not frame or type(frame.IsMouseOver) ~= "function" then return false end
    local ok, value = pcall(frame.IsMouseOver, frame)
    if not ok then return false end
    if type(_G.issecretvalue) == "function" and _G.issecretvalue(value) then return false end
    if value == nil then return false end
    return value and true or false
end

local pulseDriver = CreateFrame("Frame")
pulseDriver:Hide()
pulseDriver:SetScript("OnUpdate", function(self, elapsed)
    for frame, st in pairs(pulsing) do
        if not frame:IsShown() or not Widget:IsMouseOver(frame) then
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

--- The Monet button/slot "material": a seamless weave tile laid UNDER the content (this is the Andromeda/NDui "tiled backdrop texture" step, drawn from scratch) plus an ADD-blended top-lit gradient sheen (monet_barfill) OVER the content.
-- Both layers are near-white and tintable, so one theme colour drives the whole material; purely additive -- two texture regions, the frame itself untouched, which keeps it safe on Blizzard secure buttons.
--   opts.weaveAlpha / opts.alpha  strength of weave / sheen (defaults 0.6 / 0.2);  opts.r,g,b tint;  opts.weaveLayer,Sublevel / layer,Sublevel draw layers (BACKGROUND/2, OVERLAY/1)
function Widget:ButtonMaterial(frame, opts)
    if frame.__monetMaterial then return frame.__monetMaterial end
    opts = opts or {}

    local weave = frame:CreateTexture(nil, opts.weaveLayer or "BACKGROUND", nil, opts.weaveSublevel or 2)
    weave:SetTexture(Media.texture["monet_diagonal_weave"])
    weave:SetAllPoints(frame)
    weave:SetVertexColor(opts.r or 1, opts.g or 1, opts.b or 1, opts.weaveAlpha or 0.6)

    local sheen = frame:CreateTexture(nil, opts.layer or "OVERLAY", nil, opts.sublevel or 1)
    sheen:SetTexture(Media.texture["monet_barfill"])
    sheen:SetAllPoints(frame)
    sheen:SetBlendMode("ADD")
    -- The sheen is a flat base colour too; the top-lit look comes from this gradient, not from the art.
    -- Under ADD a dark end simply stops adding, so the button reads lit from above and neutral below.
    Widget:TopLight(sheen)
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

    -- SetGradient puts minColor at the BOTTOM for VERTICAL and at the LEFT for HORIZONTAL.  So the
    -- argument order depends on which end of the strip touches the frame, and the four strips do NOT
    -- pair up the way it looks like they should:
    --   top / bot are VERTICAL, anchored at the frame's top / bottom edge.  For top that edge is the
    --   strip's BOTTOM (opaque end must be minC); for bot it is the strip's TOP (opaque end must be
    --   maxC).  lef / rig are HORIZONTAL: for lef the frame edge is the RIGHT end (maxC), for rig the
    --   LEFT end (minC).  Passing them the other way round fades the shadow from nothing at the window
    --   edge to 0.55 alpha out in open space -- a halo instead of a contact shadow.
    local top = Strip("VERTICAL", near, far,
        "TOPLEFT", sh, "TOPLEFT", 0, reach,
        "TOPRIGHT", sh, "TOPRIGHT", 0, reach)
    top:SetHeight(reach)

    local bot = Strip("VERTICAL", far, near,
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

--- An oil-painted brush underline (monet_brush_stroke) beneath `anchor` -- our version of Andromeda's gradient hairline.
-- The art carries its own colours (cream core / ochre rim / dark dry edge, five tones in all), so it is only faded, never re-tinted.
-- The texture is stretched between the two anchors and squeezed to `height`, and the art is drawn for exactly that:
-- there is no thickness taper (a taper would stretch into a long spike) and every variation along the length is an
-- integer number of periods, so the stroke stays a stroke at any width.
--   opts.gap  distance below the anchor, physical px (default 3);  opts.height  stroke height, physical px (default 9);  opts.alpha  (default 0.9)
function Widget:Rule(frame, anchor, opts)
    if not frame or not anchor then return nil end
    if frame.__monetRule then return frame.__monetRule end
    opts = opts or {}
    local gap = (opts.gap or 3) * Media:Mult()
    local tex = frame:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(Media.texture["monet_brush_stroke"])
    tex:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -gap)
    tex:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -gap)
    tex:SetHeight((opts.height or 9) * Media:Mult())
    tex:SetVertexColor(1, 1, 1, opts.alpha or 0.9)
    frame.__monetRule = tex
    return tex
end

--- A plain 1px rule (monet_hairline) stretched between two points -- the quiet sibling of Widget:Rule,
-- which draws the hand-painted brush underline.  Same "texture carries no direction" trick: the 256x1 art
-- is one opaque row, so it only reads as a hairline while the widget stays 1px tall; give it height and it
-- becomes a separator band, which is usually what you want anyway.
--   opts.alpha (default 0.55);  opts.anchor  anchor point pair, default TOPLEFT/TOPRIGHT
function Widget:Hairline(frame, anchor, opts)
    if not frame or not anchor then return nil end
    if frame.__monetHairline then return frame.__monetHairline end
    opts = opts or {}
    local tex = frame:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(Media.texture["monet_hairline"])
    tex:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(opts.gap or 1))
    tex:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -(opts.gap or 1))
    tex:SetHeight(Media:SnapUnit(1))
    -- A hairline is the one place where texel snapping is unambiguously right: the image is a single
    -- opaque row, so any sub-texel placement is pure blur.  Both setters are call:ok on this client.
    -- (Animated fills want the opposite -- snapping makes a growing bar jump a pixel at a time --
    -- which is why this is set per texture and not globally.)
    if tex.SetSnapToPixelGrid then pcall(tex.SetSnapToPixelGrid, tex, true) end
    if tex.SetTexelSnappingBias then pcall(tex.SetTexelSnappingBias, tex, 0) end
    local r, g, b = Color:GetEdge()
    tex:SetVertexColor(r, g, b, opts.alpha or 0.55)
    -- Deliberately NOT Skin:Track()ed.  A hairline is drawn on one of our own frames, so there is no
    -- Blizzard art to roll back; on Skin's undo list it would only make the Skins toggle hide our own
    -- separators.  This used to call self:Track() -- but Track lives on Skin, not Widget, so every
    -- call raised "attempt to call method 'Track' (a nil value)".
    frame.__monetHairline = tex
    return tex
end

--- Four brush ornaments on the frame corners (monet_corner), a small flourish Andromeda has no equivalent for -- its only chrome decoration is a gradient hairline.
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
    local path = Media.texture["monet_corner"]

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
            tex:SetSize(Media:SnapUnit(size), Media:SnapUnit(size))
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
