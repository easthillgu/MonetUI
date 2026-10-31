-- Modules/UnitFrames/Auras.lua
-- UnitFrames 的光环子系统（2026-10-25 从 UnitFrames.lua 拆出）。接口面：
--   * 输入：M.frames（单位框表）/ M.Shared（共享设置读取），由主文件挂到 M 上；
--   * 输出：M.auras.{EnsureTargetAuras, RebuildTargetAuras, StyleAuraButton}；
--   * 兼容：ns.AuraButtonStyle / ns.PrepareAuraStyle（BuffFrame 的战斗光环复用同一套样式）。

local ADDON_NAME, ns = ...

local Mark   = function(o, k, v) return ns:Mark(o, k, v) end
local Marked = function(o, k) return ns:Marked(o, k) end
local Secrets = ns.Secrets
local Widget  = ns.Widget
local Media   = ns.Media

local M = ns:GetModule("UnitFrames")
if not M then return end

local frames = M.frames
local Shared = M.Shared

-- ============================================================================
-- B 方案：Blizzard 原生 AuraContainer（当前启用）
-- ============================================================================
--
-- A 方案（借 TargetFrame 的光环子帧）整段注释在下面，保留以便回滚。切换理由：
--   A 改的是暴雪自己的子帧，暴雪每次重排都要抢回来（StackTargetAuras），而且它读不到
--   C_UnitAuras，只能指望 TargetFrame 继续替我们画。
--   B 让暴雪自己画：池化、排序、机密值处理、战斗中可变，全归引擎。
--
-- 本客户端的三个硬约束（EllesmereUI_AuraKit.lua 里都踩过）：
--   1. AuraContainer 属于 LoD 插件 Blizzard_AuraContainer，必须先 LoadAddOn 才能 CreateFrame。
--   2. 容器必须**先有可渲染的矩形**（SetSize(1,1)）：引擎的 parse/layout 是从一个
--      run-when-visible 的 OnUpdate 里排空的，没有矩形就永远不跑第一次布局。
--   3. initializeFrame 里必须**先把区域建好、上好样式，最后才注册给按钮**：每个 Set*
--      注册都会立刻触发引擎的 UpdateAuraDisplay -> SetText()，字体没设的 FontString 直接报错。
--
-- 回滚：删掉下面 A 方案的 --[==[ 和 ]==] 两行，把本段三个调用点换回
--       BorrowTargetAuras / RestoreTargetAuras / StackTargetAuras + HookAuraRelayout()。

-- Icon size chosen so the justified row lands on an integer spacing:
--   158px content / 24px wide icons => 6 per row, gaps = (158 - 6*24) / 5 = 2.8px.
-- Height 18 keeps the icons compact (24:18 = 4:3); the square spell art is cropped to that aspect.
-- 时长 / 堆叠数字的字号按**图标高度**等比算（见 StyleAuraButton），所以这里改图标尺寸，
-- 字会自己跟着走 —— 没有任何写死的字号。
local TARGET_AURA_ICON_W   = 24
local TARGET_AURA_ICON_H   = 18
local TARGET_AURA_BORDER_PX = 0   -- no width inset: keeps the full 24px, so the art is not stretched
local TARGET_AURA_V_CROP_PX = 3   -- height crop top and bottom (24 - 3 - 3 = 18)
local TARGET_AURA_SPACING  = 2    -- base spacing (used when icons don't fill row)
local TARGET_AURA_ROWS     = 2

--- Compute justified aura layout for given frame width.
-- Returns: iconsPerRow, actualSpacing, rowWidth
-- Goal: align both left and right edges to frame outer edges.
local function ComputeAuraLayout(frameWidth)
    local border = (Shared("border") or 1)
    local contentWidth = frameWidth - border * 2  -- frame content width (inner)
    -- Maximum icons that fit with minimum spacing
    local maxIcons = math.floor((contentWidth + TARGET_AURA_SPACING) / (TARGET_AURA_ICON_W + TARGET_AURA_SPACING))
    if maxIcons < 1 then maxIcons = 1 end
    if maxIcons > 12 then maxIcons = 12 end  -- cap at reasonable max

    -- Calculate spacing to exactly fill the row (justified)
    -- rowWidth = icons * iconWidth + (icons - 1) * spacing = contentWidth
    local actualSpacing
    if maxIcons > 1 then
        actualSpacing = (contentWidth - maxIcons * TARGET_AURA_ICON_W) / (maxIcons - 1)
        if actualSpacing < 0 then actualSpacing = 0 end
        if actualSpacing > 8 then actualSpacing = 8 end
    else
        actualSpacing = TARGET_AURA_SPACING
    end

    local rowWidth = maxIcons * TARGET_AURA_ICON_W + (maxIcons - 1) * actualSpacing
    return maxIcons, actualSpacing, rowWidth
end

--- TexCoord for a square spell icon shown in an 18 x 14 slot.
--- Reference square is TARGET_AURA_ICON_W px (18):
---   width  : full 0..1  (no inset -- keeps the source aspect at 18:14, so no stretch)
---   height : crop 2px top and bottom  (18 - 2 - 2 = 14)
--- => SetTexCoord(0, 1, 2/18, 16/18) = (0, 1, 0.1111, 0.8889)
local function AuraIconTexCoord()
    local n = TARGET_AURA_ICON_W
    local x0 = TARGET_AURA_BORDER_PX / n
    local x1 = 1 - TARGET_AURA_BORDER_PX / n
    local y0 = TARGET_AURA_V_CROP_PX / n
    local y1 = 1 - TARGET_AURA_V_CROP_PX / n
    return x0, x1, y0, y1
end

local auraAddonReady = false

--- AuraContainer 是 LoD 插件，没加载时 CreateFrame 拿不到那个模板。
local function EnsureAuraContainerAddOn()
    if auraAddonReady then return true end
    local C = _G.C_AddOns
    if not C or type(C.LoadAddOn) ~= "function" then return false end
    local ok, loaded = pcall(C.IsAddOnLoaded, "Blizzard_AuraContainer")
    if not ok then return false end
    if not loaded and not pcall(C.LoadAddOn, "Blizzard_AuraContainer") then return false end
    auraAddonReady = true
    return true
end

-- 两代 API：Flow* 是新名字，AuraLayout* 是旧名字。这个 fork 上哪一代在，实机才知道，
-- 所以每个 setter 都「新名优先、旧名兜底、都没有就跳过」，绝不裸调。
local function FlowCall(container, newName, oldName, ...)
    local f = container[newName]
    if type(f) ~= "function" and oldName then f = container[oldName] end
    if type(f) ~= "function" then return false end
    return pcall(f, container, ...)
end

-- 引擎按钮只在我们手里一次：之后光环变机密（战斗中），Post-creation 访问会被拒。
local function TintAuraButton(button)
    local host = Marked(button, "borderHost")
    if not host then return end
    -- 只写我们自己的子帧。写在按钮的 region 上会被 Bad self 拒掉（pcall 吞掉后边框就永远是
    -- 创建那一刻的颜色，换主题也不变）—— 子帧没有这个限制，重涂是幂等的。
    Widget:TintIconBorder(host)   -- 与 NP 的 debuff 色带共用一点(review #4)
end

-- 时长文本的染色曲线：配色和动作条冷却（Modules/Cooldown）同一套 ——
--   <10s 红 · <60s 黄 · <1h 蓝 · <1d 绿 · 更长灰
-- 曲线由**引擎**按剩余时长求值（DurationTextBinding 的 RemainingDuration 属性），
-- 所以就算光环数值是机密的，颜色照样会变；只建一条，所有光环按钮共用。
local durationColorCurve

local function GetDurationColorCurve()
    if durationColorCurve ~= nil then return durationColorCurve or nil end

    local curveUtil = _G.C_CurveUtil
    if type(curveUtil) ~= "table" or type(curveUtil.CreateColorCurve) ~= "function"
        or type(_G.CreateColor) ~= "function" then
        durationColorCurve = false
        return nil
    end
    local ok, curve = pcall(curveUtil.CreateColorCurve)
    -- 注意：本客户端的曲线对象是 **userdata**（不是 table），只认 table 会把它当成失败。
    local curveType = type(curve)
    if not ok or (curveType ~= "table" and curveType ~= "userdata")
        or type(curve.AddPoint) ~= "function" then
        durationColorCurve = false
        return nil
    end

    local function point(x, r, g, b)
        local okColor, color = pcall(_G.CreateColor, r, g, b, 1)
        if okColor and color then pcall(curve.AddPoint, curve, x, color) end
    end
    -- 每个单位切换点两侧各放一个点，做出 1 秒的快速过渡（曲线本身是连续插值的）。
    point(0,        0.99, 0.21, 0.07)   -- 秒：红（<10s）
    point(10,       0.99, 0.21, 0.07)
    point(11,       1.00, 0.91, 0.00)   -- 秒：黄
    point(59,       1.00, 0.91, 0.00)
    point(61,       0.13, 0.78, 0.87)   -- 分钟：蓝
    point(3599,     0.13, 0.78, 0.87)
    point(3601,     0.31, 0.80, 0.21)   -- 小时：绿
    point(86399,    0.31, 0.80, 0.21)
    point(86401,    0.75, 0.75, 0.70)   -- 天：灰
    point(31536000, 0.75, 0.75, 0.70)

    durationColorCurve = curve
    return curve
end

--- debuff 的**解魔法类型色边框**。原来那条有色边框不是被裁图标裁掉的，是模板差异：
--- 我们用的是 CustomAuraButtonTemplate（光板，没有任何边框 region），暴雪目标框的 debuff
--- 按钮模板才自带 DispelBorder。
---
--- 做法：用引擎的 AddDispelTypeTexture 把边框交回**引擎**上色（暴雪代码按 auraData.dispelName
--- 调 AuraUtil.SetAuraBorderColor），全程不经过插件代码，所以"initializeFrame 之后按钮不可写"
--- 这条限制不影响它。样式用 PreserveAsset：引擎**只改顶点色**、不动贴图，于是形状还是我们的
--- —— 四条 1 物理像素的直边拼一个平直矩形环，和 buff 那圈主题边框同一套几何（暴雪那种圆角厚
--- 图集边框太"重"，不贴 Monet）。
--- 引擎要求一个边框 = 一个 Texture，所以四条边各自注册一次；它们同时被 Show/Hide、同时上色。
local function AddDispelBorder(button, pad, expand)
    local styles = _G.Enum and _G.Enum.CustomAuraButtonDispelTypeTextureStyle
    local style = styles and styles.PreserveAsset
    if style == nil or type(button.AddDispelTypeTexture) ~= "function" then return false end
    -- expand = 环相对按钮外扩多少（正数向外）；厚度永远是 pad。默认向外扩一个 pad，
    -- 目标框用这个；玩家 buff 行传 0，环就贴着按钮边、画在按钮**里面**，和自绘那套一致。
    if type(expand) ~= "number" then expand = pad end

    -- 和暴雪原版一致：没有解魔法类型的 debuff（物理/流血）也画一圈灰边，不然后者完全没边框。
    local opts = {
        style = style,
        showWhenHarmful = true,     -- 有害光环（debuff）
        showWhenHelpful = false,
        showWithoutDispelType = true,
    }

    local edges = {
        -- { 起点, 终点, 起点偏移, 终点偏移, 方向 }
        { "TOPLEFT",     "TOPRIGHT",    -expand,  expand, "h" },
        { "BOTTOMLEFT",  "BOTTOMRIGHT", -expand, -expand, "h" },
        { "TOPLEFT",     "BOTTOMLEFT",  -expand,  expand, "v" },
        { "TOPRIGHT",    "BOTTOMRIGHT",  expand,  expand, "v" },
    }

    local made = 0
    for i = 1, #edges do
        local from, to, off, offY, axis = edges[i][1], edges[i][2], edges[i][3], edges[i][4], edges[i][5]
        -- 引擎按钮在受限窗口里生产时，对它的 Create* 会连本带拒绝（ обслуживания实测：同一容器的
        -- 第一批按钮 style 完整、之后的批次全部失格）。Create* 不包 pcall 会把整个批次炸掉
        -- （错误面板的 Backdrop.lua:342 / MathUtil.lua:24 波），所以每一次创建都要及早退出。
        local okTex, texture = pcall(button.CreateTexture, button, nil, "OVERLAY")
        if okTex and texture then
            -- 先定白色（引擎随后把顶点色改成解魔法类型色），再定几何，最后才交给引擎。
            pcall(texture.SetColorTexture, texture, 1, 1, 1, 1)
            if axis == "h" then
                pcall(texture.SetPoint, texture, from, button, from, off, offY)
                pcall(texture.SetPoint, texture, to, button, to, -off, offY)
                pcall(texture.SetHeight, texture, pad)
            else
                pcall(texture.SetPoint, texture, from, button, from, off, offY)
                pcall(texture.SetPoint, texture, to, button, to, off, -offY)
                pcall(texture.SetWidth, texture, pad)
            end
            if pcall(button.AddDispelTypeTexture, button, texture, opts) then
                made = made + 1
                Mark(button, "dispelBorder", texture)
            else
                pcall(texture.Hide, texture)
            end
        end
    end
    return made > 0
end

-- 边框：debuff 优先用引擎的解魔法类型色边框（就是"原始那种带色边框"）；buff 用主题边框。
-- 引擎那条建不出来（枚举/方法缺失）时退回主题边框，不会出现完全没边框的图标。
local function EnsureAuraBorder(button, kind, spec, pad, buttonLevel)
    local borderInside = (type(spec) == "table" and spec.borderInside) and true or false
    if kind ~= "debuff" or not AddDispelBorder(button, pad, borderInside and 0 or nil) then
        -- 边框画在**我们自己的子帧**上，不画进按钮的贴图：引擎按钮在 initializeFrame 返回之后
        -- 就受 DenyTaintedAccessWhenAurasAreSecret 约束，之后再对它的 region 调 SetColorTexture
        -- 会被拒 —— 这就是"边框染色失败"、换主题也不跟随的根因。子帧是我们建的，任何时候都能重涂
        -- （Ellesmere 的 borderHost 同一个道理）。
        -- 几何：默认比图标外扩 1 个**物理像素**（Media:Mult 就是那个换算），层级压到按钮之下，所以环
        -- 只在图标外沿露出来；用 ApplyBorder（只有边、无底色）而不是整块色贴图 —— 万一层级没压住，
        -- 也只有那 1px 的环会盖到图标，不会把图标糊成一块色。
        -- Create* 的早退守卫：受限窗口里生产时引擎直接拒绝，样式就此作罢（剩下的交给引擎外观），
        -- 不允许从我们的 initializeFrame 里抛出 —— 抛了会把整个批次连同其它 9 个按钮一起带走。
        local okHost, borderHost = pcall(CreateFrame, "Frame", nil, button, "BackdropTemplate")
        if not okHost or not borderHost then
            return
        end
        if borderInside then
            borderHost:SetAllPoints(button)
        else
            borderHost:SetPoint("TOPLEFT", button, "TOPLEFT", -pad, pad)
            borderHost:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", pad, -pad)
        end
        borderHost:SetFrameLevel(math.max(0, buttonLevel - 1))
        borderHost:EnableMouse(false)
        Widget:ApplyBorder(borderHost, 1)
        Mark(button, "borderHost", borderHost)
    end
end

-- 图标：建纹理、按 spec.iconInset 内缩，并按 spec.crop 定裁切（nil = 3:4 槽裁切，
-- false = 不裁，{x0,x1,y0,y1} = 指定窗）。裁切原因见主函数 spec 注释（BuffFrame 的方形
-- 行也要砍掉法术图标自带 8% 描边）。
local function EnsureAuraIcon(button, spec)
    local okIcon, icon = pcall(button.CreateTexture, button, "ARTWORK")
    if not okIcon or not icon then return nil end
    local iconInset = (type(spec) == "table" and spec.iconInset) or 0
    if type(iconInset) == "number" and iconInset > 0 then
        icon:SetPoint("TOPLEFT", button, "TOPLEFT", iconInset, -iconInset)
        icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -iconInset, iconInset)
    else
        icon:SetAllPoints(button)
    end
    local crop = type(spec) == "table" and spec.crop or nil
    if crop == nil then
        -- Crop the square spell art to the 3:4 (H:W) slot aspect.
        local x0, x1, y0, y1 = AuraIconTexCoord()
        ns.Skin:CropIcon(icon, x0, x1, y0, y1)
    elseif type(crop) == "table" then
        ns.Skin:CropIcon(icon, crop[1], crop[2], crop[3], crop[4])
    end
    return icon
end

-- 冷却：覆盖图标本身（不是整颗按钮），这样扫过的底色不会染到边框那一圈。
local function EnsureAuraCooldown(button, icon)
    local okCd, cd = pcall(CreateFrame, "Cooldown", nil, button, "CooldownFrameTemplate")
    if not okCd or not cd then return nil end
    cd:SetAllPoints(icon)
    pcall(cd.SetDrawEdge, cd, false)
    pcall(cd.SetDrawSwipe, cd, true)
    return cd
end

-- 数字文本：时长（带颜色曲线的 FontString）+ 层数，全部建在冷却帧上（作为它的 region）——
-- 实测引擎自己那行数字就是这样画的、位于图标之上；挂在按钮的子帧里会被图标盖住。
-- 字号**跟着图标当前的实际尺寸走**（不写死字号）：现量按钮的宽高，高度不超过 45%
-- （上下各留约 2 单位内边距）、宽度保证最长 5 个字符（"1h37m"）不越界，两个上限取更小的
-- 那个，再夹一个可读下限。Andromeda 的口径是 fontSize = floor(size / 30 * 10 + 0.5)
-- （modules/blizzard/aura.lua），但那是给 30px 方形图标、外加 HalfHeight 字体算的；
-- 我们的图标是 4:3 的小格，直接照抄会顶满整格还往外溢。图标尺寸（TARGET_AURA_ICON_W/H
-- 或以后的配置项）变了，这里算出来的字号就跟着变，不需要改代码。
-- exact = true 让算出来的值真的生效（Widget:SetFont 默认会把 ≤10 的都夹到 10）。
local function EnsureAuraTexts(button, cd, spec)
    local okW, iconW = pcall(button.GetWidth, button)
    local okH, iconH = pcall(button.GetHeight, button)
    if not (okW and type(iconW) == "number" and iconW > 0) then iconW = TARGET_AURA_ICON_W end
    if not (okH and type(iconH) == "number" and iconH > 0) then iconH = TARGET_AURA_ICON_H end
    local textSize = math.max(4, math.min(
        math.floor(iconH * 0.45 + 0.5),
        math.floor(iconW / 3.4 + 0.5)))
    -- 调用方可以强制字号（BuffFrame 要跟它自绘那套的 12px 对齐）。
    if type(spec) == "table" and type(spec.textSize) == "number" then
        textSize = spec.textSize
    end

    -- 时长文本：先给冷却自带的那行数字留条后路（换成像素字体、压进图标下沿），
    -- 万一 RegisterDurationText 不被客户端接受，就继续用它们。
    local inset = math.max(2, math.floor(textSize * 0.55 + 0.5))
    local okRegions, regions = pcall(function() return { cd:GetRegions() } end)
    if okRegions then
        for i = 1, #regions do
            local region = regions[i]
            if type(region) == "table" and type(region.GetObjectType) == "function"
                and region:GetObjectType() == "FontString" then
                Widget:SetFont(region, textSize, "pingfang", Media.outlineFlags, true)
                pcall(region.ClearAllPoints, region)
                pcall(region.SetPoint, region, "BOTTOM", button, "BOTTOM", 0, inset)
                pcall(region.SetJustifyH, region, "CENTER")
            end
        end
    end

    local okDur, duration = pcall(cd.CreateFontString, cd, nil, "OVERLAY")
    if not okDur or not duration then return nil end
    -- 时长数字用 PingFangPixel + 硬描边：这套字号是跟着图标尺寸算的（目标框光环 14-20px，
    -- 算出来 4-8px），像素字体在这个尺寸下认不出来。
    Widget:SetFont(duration, textSize, "pingfang", Media.outlineFlags, true)
    duration:SetPoint("BOTTOM", button, "BOTTOM", 0, inset)
    duration:SetJustifyH("CENTER")

    -- 层数：锚在右上角，和左下角的时长错开。
    local okStack, stack = pcall(cd.CreateFontString, cd, nil, "OVERLAY")
    if not okStack or not stack then return nil end -- 与原函数同语义：任一文本串建不出就整批罢手
    Widget:SetFont(stack, textSize, "pixel", nil, true)
    stack:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
    stack:SetJustifyH("RIGHT")
    return duration, stack
end

-- 时长注册：带颜色曲线（textColor.curve + RemainingDuration，引擎按剩余时长求值，
-- 机密值也有效）；客户端不接受这套选项时退回最简形式，再不行才用冷却自带的数字。
-- 返回 registered —— 真生效了调用方就关掉冷却自带的那行数字，避免同一格里两份时长。
local function RegisterAuraDuration(button, cd, duration)
    local prop = _G.Enum and Enum.DurationTextBindingProperty
    prop = prop and prop.RemainingDuration
    local curve = GetDurationColorCurve()
    if curve and prop ~= nil then
        if pcall(button.SetDurationText, button, duration,
            { textColor = { curve = curve, property = prop } }) then
            return true
        end
    end
    if not pcall(button.SetDurationText, button, duration, {}) then
        return false
    end
    -- 退一步：文本已注册、只是这次没接受颜色选项，就单独给绑定设曲线
    -- （不同客户端对 options 的校验不一致，这条路等价）。
    if curve and prop ~= nil and type(button.GetDurationTextBinding) == "function" then
        local okBinding, binding = pcall(button.GetDurationTextBinding, button)
        local bindingType = type(binding)
        if okBinding and (bindingType == "table" or bindingType == "userdata")
            and type(binding.SetTextColorCurve) == "function" then
            pcall(binding.SetTextColorCurve, binding, curve, prop)
        end
    end
    return true
end

-- initializeFrame：一个引擎按钮只进来一次。碰按钮的事必须在这里做完。
-- spec（可选）：{ width, height, crop } —— BuffFrame 的战斗兜底复用这套样式，但玩家 buff 行是
-- 方形图标、且不裁边（目标框的 18x14 槽才需要 3:4 裁切）。不传 spec 就等于原来的目标框样子。
--
-- **必需件优先（2026-10-25 修复"战斗中 proc 只有提示没有图标"）**：
-- 引擎把机密光环数据写进 `SetIcon / SetDurationCooldown / SetApplicationCount` 交给它的那三个
-- 对象。以前任一文本串/边框建不出来就整段 return，等于**连 SetIcon 一起放弃**——屏幕上就是
-- "按钮在、能悬停、没有图标"。现在顺序改成：先建图标→冷却→层数并**立刻注册**，装饰件
-- （边框 / 时长文本 / 染色）全部排在注册之后、各自 pcall 隔离：装饰失败最多"不好看"，不会
-- 让图标消失。机密期不建颜色曲线（`C_CurveUtil` 会被拒），退回冷却自带数字。
-- （对齐 ArcAuras 的 `initializeFrame` 纪律：`AD_DriverAura.lua:796-883`。）
local function StyleAuraButton(button, kind, spec)
    if type(button) ~= "table" then return end

    local specW = (type(spec) == "table" and spec.width) or TARGET_AURA_ICON_W
    local specH = (type(spec) == "table" and spec.height) or TARGET_AURA_ICON_H
    pcall(button.SetSize, button, specW, specH)
    -- 引擎按钮默认**可点**：压在条上会吃掉换目标的点击。只有这个窗口能可靠关掉。
    pcall(button.SetMouseClickEnabled, button, false)

    -- 必需件 1/3：图标。
    local icon = EnsureAuraIcon(button, spec)
    if icon then pcall(button.SetIcon, button, icon) end

    -- 必需件 2/3：冷却（覆盖在图标上；时长数字也建在它上面）。
    local cd
    if icon then
        cd = EnsureAuraCooldown(button, icon)
        if cd then pcall(button.SetDurationCooldown, button, cd) end
    end

    -- 必需件 3/3：层数 + 我们自己的时长文本（建不出来不影响前两件）。
    local duration, stack
    if cd then
        local okTexts, d, s = pcall(EnsureAuraTexts, button, cd, spec)
        if okTexts then duration, stack = d, s end
    end
    if stack then pcall(button.SetApplicationCount, button, stack, {}) end

    -- 装饰 1/3：边框（我们自己的子件，写不进引擎数据，失败只丢边框）。
    local okLevel, buttonLevel = pcall(button.GetFrameLevel, button)
    if not (okLevel and type(buttonLevel) == "number") then buttonLevel = 1 end
    local pad = Media:Mult()
    if type(pad) ~= "number" or pad <= 0 then pad = 1 end
    pcall(EnsureAuraBorder, button, kind, spec, pad, buttonLevel)

    -- 装饰 2/3：时长文本绑定。机密期跳过颜色曲线（会被拒），退回冷却自带数字。
    if duration and cd then
        local registered = false
        if not Secrets.AurasSecret() then
            local okReg, res = pcall(RegisterAuraDuration, button, cd, duration)
            registered = okReg and res == true
        end
        if registered then
            pcall(cd.SetHideCountdownNumbers, cd, true)
        else
            pcall(duration.Hide, duration)
        end
    end

    -- 装饰 3/3：主题染色（同样只碰我们自己的子件）。
    pcall(TintAuraButton, button)
end

--- 导出给 BuffFrame：战斗里客户端不给插件读光环，玩家 buff 行改由引擎 AuraContainer 显示，
--- 按钮样式必须和目标框一致，所以共用这一个函数（尺寸/裁切由 spec 覆盖）。
ns.AuraButtonStyle = StyleAuraButton
--- 曲线必须由**非 securecall** 的调用方先建好：引擎的 initializeFrame 是 securecall 进去跑的，
--- 在里面首次调 C_CurveUtil.CreateColorCurve 会被拒。
ns.PrepareAuraStyle = GetDurationColorCurve

--- 流式布局：贴左下、向右上长、每行自动计算图标数并两端对齐（justified）。
-- Anchor at BOTTOMLEFT of frame (frame outer left edge), grow RIGHT then UP.
local function ApplyContainerLayout(container, frame)
    local iconsPerRow, actualSpacing, rowWidth = ComputeAuraLayout(frame:GetWidth())

    FlowCall(container, "SetFlowLayoutAnchorPoint", "SetAuraLayoutAnchorPoint", "BOTTOMLEFT")
    -- 生长方向必须传 AnchorUtil.FlowDirection 的**枚举值**（Right=1 / Up=1、Left/Down=-1）。
    -- 传字符串 "RIGHT"/"UP" 会被 wrapper 里的 assert 拒掉，pcall 吞掉之后方向还是默认的
    -- 向下 —— 这就是之前"满一行往下换行"的原因。先试数字版，老客户端再退字符串版。
    local flow = _G.AnchorUtil and _G.AnchorUtil.FlowDirection
    local growthSet = false
    if type(flow) == "table" and flow.Right ~= nil and flow.Up ~= nil then
        growthSet = FlowCall(container, "SetFlowLayoutGrowthDirection", "SetAuraLayoutGrowthDirection",
            flow.Right, flow.Up)
    end
    if not growthSet then
        FlowCall(container, "SetFlowLayoutGrowthDirection", "SetAuraLayoutGrowthDirection", "RIGHT", "UP")
    end

    local axes = _G.AnchorUtil and _G.AnchorUtil.FlowLayoutAxis
    if axes and type(container.SetFlowLayoutAxis) == "function" then
        pcall(container.SetFlowLayoutAxis, container, axes.Horizontal)
    end

    -- Set element spacing to the justified spacing (may be fractional, FlowLayout handles it)
    FlowCall(container, "SetFlowLayoutElementSpacing", "SetAuraLayoutElementSpacing", actualSpacing)
    FlowCall(container, "SetFlowLayoutLineSpacing", "SetAuraLayoutLineSpacing", actualSpacing)

    -- 最大行宽。**不能**正好给 rowWidth：引擎判断换行时会先把一个 elementSpacing 也算进
    -- 下一格的位置（即 6 格需要 6*24 + 6*2.8 = 160.8，而不是我们算的两端对齐 158），
    -- 于是恰好排满 6 个的一行在第 6 个之前就换行了（实测 5 个就换行）。多给一个间距的余量，
    -- 刚好放下 iconsPerRow 个、又放不下 iconsPerRow + 1 个。
    local lineSize = rowWidth + actualSpacing
    FlowCall(container, "SetFlowLayoutMaximumLineSize", "SetAuraLayoutRowWidth", lineSize)

    -- Store for potential refresh
    Mark(container, "auraLayout", {
        iconsPerRow = iconsPerRow,
        spacing = actualSpacing,
        rowWidth = rowWidth,
    })
    return iconsPerRow, actualSpacing, rowWidth
end

--- 建一个只装一组光环的容器。成功返回 container，失败返回 nil + 原因。
local function CreateAuraContainer(parent, key, filterString, kind)
    if not EnsureAuraContainerAddOn() then
        return nil, "Blizzard_AuraContainer 未加载"
    end

    local ok, container = pcall(CreateFrame, "AuraContainer", nil, parent, "CustomAuraContainerTemplate")
    if not ok or type(container) ~= "table" then
        return nil, "CreateFrame(AuraContainer) 失败（模板可能不存在）"
    end

    -- 约束 2：先给一个可渲染的矩形，否则引擎那轮 OnUpdate 永远不会跑第一次布局。
    container:SetSize(1, 1)

    -- Compute justified layout based on parent frame width
    local iconsPerRow, actualSpacing, rowWidth = ApplyContainerLayout(container, parent)

    local opts = {
        maxFrameCount = iconsPerRow * TARGET_AURA_ROWS,
        candidateFilters = {},              -- 空表 = 不设白名单，引擎自己决定显示什么
        layout = {
            elementSpacing = actualSpacing,
            lineSpacing    = actualSpacing,
            elementWidth   = TARGET_AURA_ICON_W,
            elementHeight  = TARGET_AURA_ICON_H,
            layoutIndex    = 1,
        },
        -- 闭包把"这是 debuff 组"带进 init：debuff 走引擎的解魔法类型色边框。
        -- 整个回调套 pcall：这里是 securecall 进来的引擎生产链，我们的任何异常会把
        -- 整个批次（连同其它 9 个按钮）一起带走（Backdrop.lua:342 / MathUtil.lua:24 波）。
        initializeFrame = function(button)
            pcall(StyleAuraButton, button, kind)
        end,
    }
    -- 这两个是枚举**表**（AuraContainerSortMethod.Default = 0、SortDirection.Normal = 0），
    -- 直接把表当参数传会被引擎拒绝（"sortMethod must be a valid AuraContainerSortMethod"，
    -- 零售 12.x 实测）。取出标量再传；取不到就干脆不传，让引擎用默认排序。
    local sortMethod = _G.AuraContainerSortMethod
    if type(sortMethod) == "table" then sortMethod = sortMethod.Default end
    if type(sortMethod) == "number" then opts.sortMethod = sortMethod end

    local sortDirection = _G.AuraContainerSortDirection
    if type(sortDirection) == "table" then sortDirection = sortDirection.Normal end
    if type(sortDirection) == "number" then opts.sortDirection = sortDirection end

    local okAdd, err = pcall(container.AddAuraGroup, container, key, filterString, opts)
    if not okAdd then
        return nil, "AddAuraGroup 失败: " .. tostring(err)
    end

    pcall(container.SetUnit, container, "target")
    pcall(container.UpdateAllAuras, container)
    return container
end

local targetAuraDebuffs, targetAuraBuffs
local RebuildTargetAuras   -- 前置声明：EnsureTargetAuras 战斗中要把它排进 ns:AfterCombat（实现在下面）

--- 建/显示目标光环容器。取代 A 方案的 BorrowTargetAuras。
--- buff 贴着血条、debuff 叠在 buff 之上，两组都是满一行往上换行。
local function EnsureTargetAuras(frame)
    if not frame then return end

    if not Shared("showTargetAuras") then
        if targetAuraDebuffs then targetAuraDebuffs:Hide() end
        if targetAuraBuffs then targetAuraBuffs:Hide() end
        return
    end

    -- 染色曲线必须在这里（不安全上下文）先建好：引擎按钮的 initializeFrame 是
    -- securecall 进去跑的，在里面第一次调 C_CurveUtil.CreateColorCurve 会被拒，
    -- 结果所有按钮都拿不到曲线、时长只剩白色。
    GetDurationColorCurve()

    if not targetAuraDebuffs then
        -- 战斗中建容器会被拦：拿到的一组容器**永远是空的**（实测 0 个按钮显示、换目标也不刷新），
        -- 而且之后没人再重建。所以战斗里干脆不建，排队到脱战补做（ns:AfterCombat）。
        if type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() then
            ns:AfterCombat("unitframes-auras", RebuildTargetAuras)
            return
        end
        local debuffs, why = CreateAuraContainer(frame, "monetTargetDebuffs", "HARMFUL", "debuff")
        if not debuffs then
            -- 一次性警告，不刷屏。
            if not M.__auraWarned then
                M.__auraWarned = true -- TAINT-OK: M 是本模块自建 table
                ns:Print("目标光环（原生 AuraContainer）不可用：" .. tostring(why))
            end
            return
        end
        targetAuraDebuffs = debuffs

        local buffs = CreateAuraContainer(frame, "monetTargetBuffs", "HELPFUL", "buff")
        targetAuraBuffs = buffs

        -- 排法（都是 BOTTOMLEFT 锚点 + 向上生长）：buff 贴着血条，第一行满了往上排第二行；
        -- debuff 再叠在 buff 上面，同样是满行往上换行。buff 变高时 debuff 跟着往上抬。
        local gap = Shared("targetAuraGap") or 22
        if buffs then
            buffs:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, gap)
            debuffs:SetPoint("BOTTOMLEFT", buffs, "TOPLEFT", 0, TARGET_AURA_SPACING)
        else
            debuffs:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, gap)
        end
    end

    if targetAuraDebuffs then targetAuraDebuffs:Show() end
    if targetAuraBuffs then targetAuraBuffs:Show() end

    -- 换目标以后上一个目标的光环还留在屏幕上：引擎只在光环**变化**时刷新按钮，
    -- 换目标本身不算变化。客户端自己留了口子 —— AuraContainerSharedMixin:UpdateAllAuras
    -- 的注释就写着 "Exposed to allow external events to trigger refreshes where needed
    -- (e.g. target changes)" —— 这里就是那个 external event。
    if targetAuraDebuffs then pcall(targetAuraDebuffs.UpdateAllAuras, targetAuraDebuffs) end
    if targetAuraBuffs then pcall(targetAuraBuffs.UpdateAllAuras, targetAuraBuffs) end
end

--- 主题变化时**重建**容器。引擎光环按钮在 initializeFrame 返回之后就不可再写 —— 实测连我们
--- 自己建在按钮里的子帧都被 DenyTaintedAccessWhenAurasAreSecret 拒掉（SetBackdropBorderColor /
--- SetAlpha / Hide 全部报 "Attempt to access forbidden object from code tainted by an AddOn"）。
--- 所以边框颜色只能在创建窗口里定稿，换主题的唯一出路是把容器连同按钮一起扔掉重建。
--- 战斗中建容器会被拦（会得到一组永远空的容器）：把自己排进 ns:AfterCombat，脱战重试。
function RebuildTargetAuras()
    if type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() then
        ns:AfterCombat("unitframes-auras", RebuildTargetAuras)
        return
    end
    for _, container in ipairs({ targetAuraDebuffs, targetAuraBuffs }) do
        if container then
            pcall(container.ClearAllPoints, container)
            pcall(container.Hide, container)
            pcall(container.SetParent, container, nil)
        end
    end
    targetAuraDebuffs, targetAuraBuffs = nil, nil
    EnsureTargetAuras(frames.target)
end

-- ============================================================================
-- A 方案（已停用，保留以便回滚）
-- ============================================================================
--[==[
-- Borrow Blizzard's target aura list: aura reads are restricted, but TargetFrame keeps drawing
-- its own, so its aura children are reparented above our bar (the ForeverUI trick).  Position only.

-- Candidate aura children on Blizzard's TargetFrame; whichever are found stack above the frame.
local TARGET_AURA_CHILDREN = { "DebuffFrame", "AurasFrame", "BuffFrame" }

--- One aura child by candidate name: a raw field first, then a guarded lookup.
local function AuraChild(blizzard, name)
    if not blizzard then return nil end
    local child = rawget(blizzard, name)
    if not child then
        local ok, value = pcall(function() return blizzard[name] end)
        if ok then child = value end
    end
    if type(child) == "table" and type(child.SetParent) == "function" then
        return child
    end
    return nil
end

--- Anchor one borrowed list `gap` px above `below` (BOTTOMLEFT, growing up).
local function AnchorAuraList(list, below, gap)
    pcall(list.ClearAllPoints, list)
    pcall(list.SetPoint, list, "BOTTOMLEFT", below, "TOPLEFT", 0, gap)
end

-- Defined below; forward-declared for the option-off path.
local RestoreTargetAuras

--- (Re)stack the borrowed lists above the frame; also pulls them back after
--- Blizzard re-anchors them to its own hidden frame.
local function StackTargetAuras(frame)
    local lists = frame.blizzardAuras
    if not lists then return end

    local gap = Shared("targetAuraGap") or 22
    for i, list in ipairs(lists) do
        -- Blizzard may have reparented it back to itself; claim it again.
        if list:GetParent() ~= frame then
            pcall(list.SetParent, list, frame)
        end
        pcall(list.SetAlpha, list, 1)
        local below = (i == 1) and frame or lists[i - 1]
        AnchorAuraList(list, below, i == 1 and gap or 2)
    end
end

--- Lift Blizzard's aura children onto our target frame; runs on every target change.
local function BorrowTargetAuras(frame)
    if not Shared("showTargetAuras") then
        RestoreTargetAuras(frame)
        return
    end

    local blizzard = _G.TargetFrame
    if not blizzard then return end

    local lists = {}
    for _, name in ipairs(TARGET_AURA_CHILDREN) do
        local child = AuraChild(blizzard, name)
        if child then lists[#lists + 1] = child end
    end

    if #lists == 0 then
        if not Marked(frame, "auraWarned") then
            Mark(frame, "auraWarned", true)
            print("|cffce3e2fMonetUI|r: 未在 TargetFrame 上找到光环子帧，目标框光环已跳过（帧名待实机核对）")
        end
        return
    end

    Mark(frame, "auraWarned", nil)
    frame.blizzardAuras = lists
    StackTargetAuras(frame)
end

--- Hand the list back to Blizzard (module off, or the option turned off).
function RestoreTargetAuras(frame)
    local lists = frame.blizzardAuras
    if not lists then return end

    local blizzard = _G.TargetFrame
    for _, list in ipairs(lists) do
        if blizzard and type(list.SetParent) == "function" then
            pcall(list.SetParent, list, blizzard)
        end
    end
    -- Let the game re-anchor its own list now that it owns it again.
    if blizzard and type(_G.TargetFrame_Update) == "function" then
        pcall(_G.TargetFrame_Update, blizzard)
    end

    frame.blizzardAuras = nil
end

-- Blizzard re-anchors the list to its own hidden frame on every target / aura
-- update; the hook re-stacks it (the same guard pattern as Nameplates).
local function HookAuraRelayout()
    if M.__auraHooked then return end
    M.__auraHooked = true -- TAINT-OK: M 是本模块自建 table（幂等门控）

    local function restack()
        local frame = frames.target
        if frame and frame.blizzardAuras then StackTargetAuras(frame) end
    end

    for _, name in ipairs({ "TargetFrame_Update", "TargetFrame_UpdateAuras", "TargetFrame_SetUnit" }) do
        if type(_G[name]) == "function" and type(hooksecurefunc) == "function" then
            pcall(hooksecurefunc, name, restack)
        end
    end
end
]==]

-- P5：供主文件调用的接口面（其余函数保持文件内局部）。
M.auras = {
    EnsureTargetAuras = EnsureTargetAuras,
    RebuildTargetAuras = RebuildTargetAuras,
    StyleAuraButton = StyleAuraButton,
}
