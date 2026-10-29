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

-- 字体双轨制（2026-10-28 定）：按**字号**换字体与渲染标志，Media:FontFor / Media:FlagsFor /
-- Media:EffectiveFlags 是唯一漏斗（Widget:Font / SetFont / FitText / Cooldown / Nameplates /
-- Skins 全走它）。字号与字体必须同源解析，否则楷体会被塞进小字号发虚。
--   ≥12px   LXGW WenKai（霞鹜文楷）+ OUTLINE（抗锯齿）：楷体笔画有粗细与笔锋，大字号
--           抗锯齿才舒展；OFL 1.1 可分发（全文见 Assets/Fonts/OFL-LXGWWenKai.txt）。
--   <12px   点阵苹方（PingFangPixel）+ OUTLINE, MONOCHROME（硬边）：楷体小字号 + AA 实机
--           发虚（2026-10-28 判例：12 以下整体糊），点阵苹方就是为小尺寸设计的。
--           **无授权声明**，只许私有包携带（NOTICE.md 记档），转公开前必须处理。
--   cooldown 键例外：Super Effective 只给倒计时数字，任何字号都用它自己。
-- 键名保留 `pixel` / `pingfang`（15+ 调用点引用的是键不是文件；未知键回落到 pixel）。
Media.font = {
    pixel    = ASSET .. "Fonts\\LXGWWenKai-Regular.ttf",
    cooldown = ASSET .. "Fonts\\super-effective.ttf",
    wenkai   = ASSET .. "Fonts\\LXGWWenKai-Regular.ttf",
    -- 历史别名：15+ 调用点还写着 "pingfang"（键是历史名，文件已换文楷），语义与 pixel 相同。
    pingfang = ASSET .. "Fonts\\LXGWWenKai-Regular.ttf",
}

-- 小字轨（<12px）专用文件与标志；大字轨不引用它。
Media.smallFont = ASSET .. "Fonts\\Pingfangpixel.ttf"

-- 大字轨（≥12px）渲染标志：OUTLINE = 1px 描边 + 灰度抗锯齿（不写 MONOCHROME）。
-- 楷体笔画有粗细与笔锋，MONOCHROME 会把曲线边缘打成锯齿。
Media.fontFlags = "OUTLINE"

-- 小字轨（<12px）渲染标志：点阵苹方 + 硬边，见文件头"字体双轨制"。
Media.smallFlags = "OUTLINE, MONOCHROME"

-- Media.outlineFlags 是历史别名（多个调用点还传它）。换挡逻辑在 Media:EffectiveFlags：
-- 调用点传 fontFlags / outlineFlags（"默认口径"的两种拼写）都会被按字号替换成对应轨的标志。
Media.outlineFlags = "OUTLINE"

-- 双轨分界：低于此字号走小字轨（SnapSize 地板 10，exact 模式可到 8）。
Media.smallSizeCutoff = 12

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
    -- PowerShell scripts are archived under tools/deprecated/).  交付格式：**BLP2 优先**
    -- （2026-10-28 拍板，`node tools/tga-to-blp.js <file.tga>` 逐张生成 raw3 无压缩 + 完整 mip 链），
    -- TGA 源在 Assets-src/Textures（进 git、不发行），BLP 在 Assets/Textures（进游戏）——
    -- audit-pixels.js 审的是源，regen 出源后自动同步 BLP。Media 键不带扩展名，SetTexture 类消费端由引擎自行
    -- 解析（两格式同在时各消费端加载哪个由引擎决定，显示应一致——两者是同一像素）；SetBackdrop
    -- edgeFile 的唯一客户仍走 blank/直角（本引擎对 edgeFile 连 RAW3 BLP 也渲染破碎，见下方 _blp
    -- 键注释与 Widget:ApplyBackdrop）。只有 .toc 的 IconTexture 是显式 .blp 引用；浏览器预览页的
    -- PNG 副本照旧走 gitignored 的 docs/texture-preview/。两条规矩：
    -- regen 出 TGA 后必须同步转 BLP；两套格式的像素必须一致（同一生成源）。
    -- BLP 必须带**完整 mip 链**：triangle 滤波 + 逐级白衬底修正（`mipmaps:false` 是交付缺陷，
    -- 没有 mip 的贴图一旦被缩小显示，1px 线条会丢、会闪）。对照表：node tools/make-blp-compare.js。
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

    -- bar ground (Widget:BarWeave): 64x64, one-direction 45° hairlines on a 4px period.
    -- Fine enough to read as cloth at a 4px health bar; tiled 1 texel = 1 physical pixel
    -- so the angle never stretches with the bar width.
    ["monet_stripe_weave"] = ASSET .. "Textures\\monet_stripe_weave",

    ["monet_close_normal"]  = ASSET .. "Textures\\monet_close_normal",
    ["monet_close_hover"]   = ASSET .. "Textures\\monet_close_hover",
    ["monet_close_push"]    = ASSET .. "Textures\\monet_close_push",
    ["monet_win_minimize"]  = ASSET .. "Textures\\monet_win_minimize",
    ["monet_win_maximize"]  = ASSET .. "Textures\\monet_win_maximize",

    ["monet_check"]         = ASSET .. "Textures\\monet_check",
    ["monet_radio"]         = ASSET .. "Textures\\monet_radio",
    ["monet_chevron_down"]  = ASSET .. "Textures\\monet_chevron_down",
    ["monet_chevron_up"]    = ASSET .. "Textures\\monet_chevron_up",
    ["monet_arrow_left"]    = ASSET .. "Textures\\monet_arrow_left",
    ["monet_arrow_right"]   = ASSET .. "Textures\\monet_arrow_right",
    -- 三角火花（SVG 手绘，tools/svg/monet_spark_*.svg）：16×8 的纯白模具，整张图只提供 alpha，
    -- 颜色由运行期 SetVertexColor 给。**尖端在贴图边缘**（up = 顶边，down = 底边），
    -- 所以摆放时把那条边锚在能量条下沿 / 经验线上就是"尖端精确顶住"。
    ["monet_spark_up"]      = ASSET .. "Textures\\monet_spark_up",
    ["monet_spark_down"]    = ASSET .. "Textures\\monet_spark_down",

    -- 插件图标（睡莲，.toc IconTexture 同一张）：128×128 **整图烘焙彩色**，不是染色模具 ——
    -- 只调 alpha，绝不 SetVertexColor（引擎是 贴图 × 顶点色 相乘，会把池水的深绿洗掉）。
    ["monet_addon_icon"]    = ASSET .. "Textures\\monet_addon_icon",

    -- 进出战斗提示的剑 / 盾（SVG 手绘，tools/svg/monet_combat_{sword,shield}.svg）：
    -- 无色相灰阶模具，运行期 SetVertexColor 染主题高光 / 主题色（CombatText.lua 的提示编排）。
    ["monet_combat_sword"]  = ASSET .. "Textures\\monet_combat_sword",
    ["monet_combat_shield"] = ASSET .. "Textures\\monet_combat_shield",

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

    -- 滚动条（2026-10-29 细线风）：轨道 = 8x64 的 1px 竖线；把手 = 8x64 的 3px 竖条。
    -- 都按覆盖率光栅化（和 weave / round_edge 同一套），1px 线干净不虚。
    ["monet_scrollbar_track"] = ASSET .. "Textures\\monet_scrollbar_track",
    ["monet_scrollbar_thumb"] = ASSET .. "Textures\\monet_scrollbar_thumb",

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
    -- 32x32 圆角填充：形状与环的外沿完全重合，压在环下面补住 SetBackdrop 方底的四个角
    -- （方底的角点落在弧外，不补的话圆角处会戳出一小块底色）。
    ["monet_round_fill"]        = ASSET .. "Textures\\monet_round_fill",
    ["monet_round_edge"]        = ASSET .. "Textures\\monet_round_edge",          -- 环宽 2，外弧 8
    ["monet_round_edge_thin"]   = ASSET .. "Textures\\monet_round_edge_thin",     -- 环宽 1，外弧 8
    ["monet_round_edge_thick"]  = ASSET .. "Textures\\monet_round_edge_thick",    -- 环宽 3，外弧 8
    -- 注：曾有三个 `*_blp` 别名键专供 SetBackdrop 的 edgeFile 走 BLP 圆角 9-slice，
    -- 实测本引擎对 edgeFile 连 RAW3 BLP 都渲染成碎线（见 Widget:ApplyBackdrop 的注释），
    -- 该方案已废弃、别名无人读取，2026-10-28 删除。现在三个键的路径不带扩展名，
    -- 引擎按 Assets/Textures 里存在的 .blp 解析（同名 TGA 只在 Assets-src 里，不发行）。

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

--- 双轨漏斗①：按字号解析字体路径（≥12px 走 Media.font 的键，<12px 一律点阵苹方；
--- cooldown 键例外，任何字号都是 Super Effective）。所有 SetFont 调用点都该走这个，
--- 不要直接 Media:Font —— 字号与字体必须同源，否则楷体会被塞进小字号发虚。
function Media:FontFor(key, size)
    size = tonumber(size) or 12
    if key == "cooldown" then return self.font.cooldown end
    if size < self.smallSizeCutoff then return self.smallFont end
    return self:Font(key)
end

--- 双轨漏斗②：按字号解析渲染标志（<12px 硬边，≥12px 抗锯齿）。
function Media:FlagsFor(size)
    size = tonumber(size) or 12
    if size < self.smallSizeCutoff then return self.smallFlags end
    return self.fontFlags
end

--- 双轨漏斗③：调用方传"默认口径"（fontFlags / outlineFlags 两种拼写）或不传时，
--- 按字号换挡；显式自定义的 flags 尊重调用方。
function Media:EffectiveFlags(flags, size)
    if flags == nil or flags == self.fontFlags or flags == self.outlineFlags then
        return self:FlagsFor(size)
    end
    return flags
end

--- Resolve a texture key to a path (unknown keys fall back to the blank texture).
function Media:Texture(key)
    return self.texture[key] or self.texture.blank
end
