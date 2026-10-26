-- Utils/Media.lua
-- Font / texture registry.  Every asset ships inside the addon (Assets/).
-- NOTE: the paths are built from ADDON_NAME so the addon folder must stay named "MonetUI".

local ADDON_NAME, ns = ...

local Media = {}
ns.Media = Media

local ASSET = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Assets\\"

Media.asset        = ASSET
Media.fontsDir     = ASSET .. "Fonts\\"
Media.texturesDir  = ASSET .. "Textures\\"

-- 全项目只用两种字体，渲染标志统一走 Media.fontFlags（默认）/ Media.outlineFlags（小字号别名）。
--   pixel / pingfang  PingFangPixel（点阵苹方）：矢量轮廓 + 内嵌点阵位图，29 MB。
--       为什么换掉 fusion-pixel-12：它是真像素字（纯矩形轮廓、设计网格 em/12），但字库只映射
--       19317/20992 个 CJK 码位 —— 游戏数据里的生僻字（人名 / 物品 / 地名 / 成就）会掉成 □。
--       PingFangPixel 覆盖 20945/20992；本插件自己渲染的 794 个非 ASCII 字符两种字体都齐。
--       **授权**：文件内无 license 字段，苹方系苹果授权字体 —— 私有包里可以用，**公开发行前必须
--       换字**（见 Assets/Fonts/NOTICE.md；优先 OFL 的 方舟像素 Ark Pixel 12px 一类）。
--   cooldown          Super Effective，ASCII-only 小数字像素字体，只能给倒计时数字。
-- Unknown keys fall back to `pixel`, so legacy saved settings that still say "roadway", "number", "combat" or "default" resolve to the pixel font.
Media.font = {
    pixel    = ASSET .. "Fonts\\Pingfangpixel.ttf",
    cooldown = ASSET .. "Fonts\\super-effective.ttf",
    pingfang = ASSET .. "Fonts\\Pingfangpixel.ttf",
}

-- 默认渲染标志：OUTLINE = 1px 描边，MONOCHROME = 关掉抗锯齿。
-- 两者都用上才是"非抗锯齿描边"：描边和字身都是硬边，12px 下不会被 AA 糊出一圈灰。
Media.fontFlags = "OUTLINE, MONOCHROME"

-- 小字号（8–14px：光环时长 / 层数）用的同一套标志。保留别名，BuffFrame / Cooldown 的调用点
-- 不必改；将来要单独调小字号的描边粗细，只改这一行。
Media.outlineFlags = "OUTLINE, MONOCHROME"

--- Snap a font size onto the 12px step (and a sane floor).
-- 原本是为像素字的 em/12 网格；换成矢量字体（PingFangPixel）后网格不再是硬约束，但字号仍按同一步长
-- 取整 —— 全项目只有 10 / 12 / 24 这几档，位置和行高才不会因为某个下拉选项跳一档而错位。
-- Allows 10px as a valid size for compact unit frame text; otherwise snaps to the 12px step.
function Media:SnapSize(size)
    size = tonumber(size) or 12
    if size <= 10 then return 10 end
    return math.max(12, math.floor((size + 6) / 12) * 12)
end

--- The size of ONE physical screen pixel expressed in UI units ("mult").
-- Anything sized N * Media:Mult() stays exactly N physical pixels at any resolution and UI scale.
--
-- THE ARITHMETIC.  The UI's reference height is 768 units, so one physical pixel is
--   768 / physH                      screen units (physH = GetPhysicalScreenSize()'s height), and
--   (768 / physH) / uiScale          UI units, because the effective scale turns UI units into screen units.
-- Anything without the 768/physH factor is not a pixel: `1 / uiScale` happens to be right only on a
-- 768-pixel-tall screen, and equals screenHeight/768 physical pixels everywhere else (1.41 px at 1080p,
-- 2.81 px at 4K).  That was this function's bug until 2026-10-19.
--
-- Four independent implementations agree on the constant: Andromeda `C.MULT = (768/H)/scale`,
-- ElvUI `E.mult = E.perfect/UIScale`, NDui `C.mult = (pixel/scale)-((pixel-ratio)/scale)`, and
-- AishCore `PixelUnit = 768/ph/es`.  AishCore's PixelSnap is in daily use on THIS client, which is
-- what settled it.
--
-- WHY THE CVAR AND NOT UIParent.  Both of the obvious primitives are traps here:
--   * UIParent:GetEffectiveScale() -- marked SecretReturnsForAspect on this client; the number comes
--     back secret and cannot be used in arithmetic.  All four reference addons build on it and live
--     with the consequences.
--   * UIParent:GetHeight() -- the fragile half of the "GetHeight/physH" idiom: it stops equalling the
--     screen the moment another addon touches UIParent's size (ElvUI PixelPerfect.lua:79, Andromeda
--     uiscale.lua:19).  Note this is UIParent:GetHeight(), NOT GetPhysicalScreenSize().
-- We need neither.  GetPhysicalScreenSize() is a plain global (call: ok, no secret flags, unaffected by
-- any addon) and the CVar is a string, so this function owns nothing and cannot be outvoted.
--
-- REMAINING ASSUMPTION: effective scale == the uiScale CVar, i.e. nothing else rescaled UIParent.
-- That assumption is no stronger than before -- the old code made exactly the same one, it just also
-- dropped the 768/physH factor.
--
-- There is deliberately NO "if m == 1 then return n" shortcut in SnapUnit: at uiScale 1 the grid is
-- whole UI units, and a length of 19.37 still has to snap down to 19 or it never lands on the grid.
--- The physical screen height, or nil when the client cannot report it.
-- One source of truth for the screen size: Mult() and the pinned scale table both need it.
function Media:ScreenHeight()
    if not _G.GetPhysicalScreenSize then return nil end
    local ok, _, height = pcall(_G.GetPhysicalScreenSize)
    if not ok or type(height) ~= "number" or height <= 0 then return nil end
    return height
end

function Media:Mult()
    local raw
    local CVar = _G.C_CVar and _G.C_CVar.GetCVar
    if CVar then
        local ok, value = pcall(CVar, "uiScale")
        if ok then raw = value end
    end
    if raw == nil and _G.GetCVar then
        local ok, value = pcall(_G.GetCVar, "uiScale")
        if ok then raw = value end
    end
    -- tonumber inside pcall: a secret-string CVar would raise here, and this is the load-bearing path
    -- for every border in the addon.
    local okNum, scale = pcall(tonumber, raw)
    if not okNum or not scale or scale ~= scale or scale <= 0 then return 1 end
    -- Sanity band: a nonsense reading falls back to 1 (= uiScale 1.0), which is the common case.
    if scale < 0.1 or scale > 6 then return 1 end

    local physH = self:ScreenHeight()
    -- No resolution: keep at least the scale part rather than returning a wrong pixel size.
    if not physH then return 1 / scale end

    return (768 / physH) / scale
end

--- Snap a length onto the pixel grid: the nearest multiple of Media:Mult().
-- This is the missing half of the scale model.  A border whose width is right but whose two EDGES
-- land mid-pixel still reads as soft, and every size in the UI has to go through this for the whole
-- thing to line up.  Both reference addons do exactly this -- ElvUI truncates (`E:Scale`, PixelPerfect.lua:109),
-- Andromeda rounds (`F:Scale`, functions.lua:42).  We round.
function Media:SnapUnit(x)
    local n = tonumber(x)
    if not n or n == 0 then return x end
    local m = Media:Mult()
    return m * math.floor(n / m + 0.5)
end

-- The pinned UI scale per common resolution.  Every size in this addon is authored in UI
-- units, so 1 unit has to land on a whole number of physical pixels: a 4-unit bar or a
-- 12-unit font that straddles a pixel edge is soft on one side, and the grid everything
-- snaps to (SnapUnit) is only half right.
--   uiScale = 768 * pixelsPerUnit / screenHeight -- exact, not rounded:
--     1080p -> 1 unit = 1 px  (the classic look: the UI covers 71% of the screen height)
--     1440p -> 1 unit = 1 px  (the same pixel size as 1080p; on a taller panel the UI
--                              covers 53% of the height instead)
--     4K    -> 1 unit = 2 px  (the panel is far denser, so the UI doubles and still covers 71%)
-- Each entry lists what to try, best first: the client's UI-scale slider stops at 0.65, so a
-- value under it can be clamped away -- then the next one (2 px per unit) is used instead.
-- Andromeda reaches the same numbers by scaling UIParent itself (Andromeda/core/uiscale.lua);
-- MonetUI cannot (UIParent:GetEffectiveScale() comes back secret here), so the uiScale CVar
-- is the only lever -- see Core.lua's ApplyAutoScale.
Media.scalePresets = {
    [1080] = { { scale = 768 / 1080,     pixels = 1 },
               { scale = 768 * 2 / 1080, pixels = 2 } },
    [1440] = { { scale = 768 / 1440,     pixels = 1 },
               { scale = 768 * 2 / 1440, pixels = 2 } },
    [2160] = { { scale = 768 * 2 / 2160, pixels = 2 },
               { scale = 768 * 3 / 2160, pixels = 3 } },
}

--- The pinned scale for the current resolution: the uiScale that makes 1 UI unit a whole
--- number of physical pixels, or nil when the resolution is not one of the pinned ones.
-- @return scale, pixelsPerUnit
function Media:PinnedScale()
    local height = self:ScreenHeight()
    if not height then return nil end
    local presets = self.scalePresets[height]
    if not presets then return nil end
    return presets[1].scale, presets[1].pixels
end

Media.texture = {
    blank     = "Interface\\Buttons\\WHITE8X8",
    statusbar = "Interface\\TargetingFrame\\UI-StatusBar",
    mask      = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
    ring      = "Interface\\Minimap\\MiniMap-TrackingBorder",
    glow      = "Interface\\SpellActivationOverlay\\IconAlertAnts",

    -- Self-drawn alpha mask (tools/regen-textures.js -- the generator writes the file and the
    -- validation script checks it pixel by pixel, so no third-party art is shipped for it).  A mask is
    -- authored at its frame's native size and applied 1:1, so 1 mask px = 1 UI unit.
    -- 256x256: keeps the middle 190px band (rows 33..222), turning the circular minimap into a
    -- 256x190 rectangle.  The band is centred, so the 33 rows cropped off above and below are
    -- exactly the "discarded corners" the round minimap used to have.
    -- Corner radius 6: the band has to keep a rounding of its own.  The old value 4 is invisible
    -- on a 256-wide map -- the four corners read as hard cuts and the round minimap's character is
    -- gone; 6 reads as a rounded rectangle without turning the map into a lozenge.
    -- The band sits 4 UI units inside the panel, so it never reaches the panel's border ring
    -- (2 wide) -- this radius shapes the map's own corners only, it never fights the panel's arc.
    minimapRect = ASSET .. "Textures\\minimap_rect_mask",

    -- Self-drawn UI textures, generated by tools/regen-textures.js (node-canvas/Cairo; the legacy
    -- PowerShell scripts are archived under tools/deprecated/).  Only the .tga ships (the game
    -- cannot read PNG); the browser preview page gets a PNG copy under the gitignored docs/texture-preview/.
    -- Two rules cover every file below, and audit-pixels.js enforces both.
    --
    -- 1) MATTE.  Every alpha=0 pixel is PURE WHITE (255,255,255), never black: the client drags edge
    --    colour into the visible area when it builds mips / filters, so a black fringe rings every icon.
    --    A white matte times any tint to exactly that tint.
    --
    -- 2) STENCILS ARE ACHROMATIC.  The engine multiplies texture by vertex colour, so any hue baked into
    --    a texture lands in the final colour: #fffcf6 came out as borderColor * (1, .988, .965), 3.5%
    --    less blue than the WHITE8X8 flat borders beside it, and the gold close-push turned a blue theme
    --    muddy.  So anything reached by SetVertexColor / SetBackdropBorderColor is neutral -- pure white
    --    (PALETTE.stencil in the generator) or pure grey.  The role icons are greyscale because their hue
    --    is a STATE signal (leader/assist) picked at runtime, not a material colour; see below.
    --
    -- Deliberately NOT neutral, each for a stated reason (do not flatten these by accident):
    --    monet_close_hover   Skin:CloseButton leaves the highlight untinted -- an additive tint would go
    --                          invisible on dark borders -- so its gold IS the hover signal.
    --    monet_win_maximize  the gold title bar says "this is a window".
    --    monet_brush_stroke  Widget:Rule fades it only; the cream core / ochre rim is the whole point.
    --                          五个色（暖白芯 / 暖白 / 浅金 / 赭金 / 干笔暗边）都是平涂的色块 ——
    --                          渐变会在两色之间插出第三、第四种颜色，"油画笔触"要的是一块块的。
    --    monet_corner        Widget:Corners likewise only sets opacity.

    -- status bar fill: a FLAT tintable base colour.  The volume is NOT baked in -- Widget:BarGradient
    -- shades it at runtime along the bar's axis, so one 16x16 square serves any bar height and either
    -- orientation (the reference skin does the same: texture = material, SetGradient = shading).
    ["monet_barfill"]      = ASSET .. "Textures\\monet_barfill",

    -- legacy 平纹布底（已被 monet_stripe_weave 取代，保留作回退素材）
    ["monet_canvas_weave"] = ASSET .. "Textures\\monet_canvas_weave",

    -- bar ground (Widget:BarWeave): 64x64, one-direction 45° hairlines on a 4px period.
    -- Fine enough to read as cloth at a 4px health bar; tiled 1 texel = 1 physical pixel
    -- so the angle never stretches with the bar width.
    ["monet_stripe_weave"] = ASSET .. "Textures\\monet_stripe_weave",

    -- 十字斜纹变体：备用材质（当前按钮 / 状态条都改用 monet_stripe_weave）
    ["monet_diagonal_weave"] = ASSET .. "Textures\\monet_diagonal_weave",

    ["monet_close_normal"]  = ASSET .. "Textures\\monet_close_normal",
    ["monet_close_hover"]   = ASSET .. "Textures\\monet_close_hover",
    ["monet_close_push"]    = ASSET .. "Textures\\monet_close_push",
    ["monet_win_minimize"]  = ASSET .. "Textures\\monet_win_minimize",
    ["monet_win_maximize"]  = ASSET .. "Textures\\monet_win_maximize",
    ["monet_win_restore"]   = ASSET .. "Textures\\monet_win_restore",

    ["monet_check"]         = ASSET .. "Textures\\monet_check",
    ["monet_radio"]         = ASSET .. "Textures\\monet_radio",
    ["monet_plus"]          = ASSET .. "Textures\\monet_plus",
    ["monet_minus"]         = ASSET .. "Textures\\monet_minus",
    ["monet_chevron_down"]  = ASSET .. "Textures\\monet_chevron_down",
    ["monet_chevron_up"]    = ASSET .. "Textures\\monet_chevron_up",
    ["monet_arrow_left"]    = ASSET .. "Textures\\monet_arrow_left",
    ["monet_arrow_right"]   = ASSET .. "Textures\\monet_arrow_right",
    -- 三角火花（SVG 手绘，tools/svg/monet_spark_*.svg）：16×8 的纯白模具，整张图只提供 alpha，
    -- 颜色由运行期 SetVertexColor 给。**尖端在贴图边缘**（up = 顶边，down = 底边），
    -- 所以摆放时把那条边锚在能量条下沿 / 经验线上就是"尖端精确顶住"。
    ["monet_spark_up"]      = ASSET .. "Textures\\monet_spark_up",
    ["monet_spark_down"]    = ASSET .. "Textures\\monet_spark_down",
    ["monet_search"]        = ASSET .. "Textures\\monet_search",

    -- role icons: the art is DELIBERATELY GREYSCALE (every pixel R==G==B), so all hue comes from
    -- SetVertexColor at the call site.  Color:RoleTint() is the only place that decides it: a leader /
    -- assistant is tinted with the highlight slot, everyone else stays a single colour.  Do not bake a
    -- semantic colour into these three -- that would force one file per state for no gain.
    ["monet_role_tank"]     = ASSET .. "Textures\\monet_role_tank",
    ["monet_role_heal"]     = ASSET .. "Textures\\monet_role_heal",
    ["monet_role_dps"]      = ASSET .. "Textures\\monet_role_dps",

    ["monet_brush_stroke"]  = ASSET .. "Textures\\monet_brush_stroke",
    ["monet_corner"]        = ASSET .. "Textures\\monet_corner",

    -- 256x1 hairline: the whole texture is one opaque row, so it reads as a hairline only at
    -- SetHeight(1); stretched taller it becomes a separator band.  See Widget:Hairline.
    ["monet_hairline"]      = ASSET .. "Textures\\monet_hairline",

    -- 16x16 rounded 9-slice border rings for Widget:Theme's round panels, in three ring widths.
    -- The ring is painted PURE WHITE, like WHITE8X8, and that is not an accident: Widget:Refresh tints it
    -- with SetBackdropBorderColor, the same call that tints every flat border, and the engine multiplies
    -- texture by vertex colour.  A warm stroke here would land on screen as borderColor * (1, .988, .965)
    -- -- 3.5% less blue than the flat borders sitting right next to it, and that gap is invisible in the
    -- art but obvious across a 200px run.  audit-pixels.js holds this with the TINTABLE set.
    -- The ring is baked in texture pixels, which ARE UI units here (9-slice maps the outer edgeSize
    -- texels 1:1), so a 2-texel ring is 2 UI units = 2 * uiScale physical px -- it would drift with the
    -- UI scale while every flat border stays exact.  Widget:Theme therefore picks the ring whose width
    -- is nearest to thickness * Media:Mult(), keeping the error under half a physical pixel.
    -- Each one's outer arc radius is also its required 9-slice slice, and the ring width is also the
    -- background inset -- see ROUND_EDGES in Utils/Widget.lua, which must stay in step with the generator.
    ["monet_round_edge"]        = ASSET .. "Textures\\monet_round_edge",          -- 环宽 2，外弧 3
    ["monet_round_edge_thin"]   = ASSET .. "Textures\\monet_round_edge_thin",     -- 环宽 1，外弧 2
    ["monet_round_edge_thick"]  = ASSET .. "Textures\\monet_round_edge_thick",    -- 环宽 3，外弧 4

    -- BLP2 versions of the above three (tga-to-blp.js, format=raw3, 16x16 identical pixels).
    -- TGA works fine with SetTexture/SetStatusBarTexture; SetBackdrop edgeFile is the sole customer
    -- that cannot handle TGA (retail 12.x/Forever: comes out as a row of dashes), so BLP2 exists only
    -- to unblock that single path.  Kept here rather than overwriting the .tga keys because 99% of
    -- consumers never go through SetBackdrop and those should keep reading TGA.
    ["monet_round_edge_blp"]        = ASSET .. "Textures\\monet_round_edge.blp",
    ["monet_round_edge_thin_blp"]   = ASSET .. "Textures\\monet_round_edge_thin.blp",
    ["monet_round_edge_thick_blp"]  = ASSET .. "Textures\\monet_round_edge_thick.blp",

    -- 小地图内的三个 3:4 按钮图标（追踪 / 插件收纳 / 难度）。纯白模具：颜色全在运行期
    -- 由 SetVertexColor 染（追踪=中性色、收纳=边缘色、难度=副本难度色），贴图里不带色相。
    -- 底板是 Widget:Theme 画的同一块 15×20 平边框，三个按钮的"框"因此是同一套材质。
    ["monet_map_tracking"]    = ASSET .. "Textures\\monet_map_tracking",
    ["monet_map_compartment"] = ASSET .. "Textures\\monet_map_compartment",
    ["monet_map_difficulty"]  = ASSET .. "Textures\\monet_map_difficulty",
}

--- Resolve a font key to a path (unknown keys fall back to the pixel font).
function Media:Font(key)
    return self.font[key] or self.font.pixel
end

--- Resolve a texture key to a path (unknown keys fall back to the blank texture).
function Media:Texture(key)
    return self.texture[key] or self.texture.blank
end
