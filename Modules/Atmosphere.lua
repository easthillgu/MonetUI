-- Modules/Atmosphere.lua
-- A4 氛围暗角：一整张"世界之上、所有 UI 之下"的压暗层。
--
-- 只有暗角，没有画布齿纹（2026-11-02 点名：a4 做暗角，周边向中心变亮）。
-- 摆法 = 候选页里最稳的那一档：层放在 `BACKGROUND` 档，于是游戏画面被压、**所有 UI 天然在它上面**
-- —— 面板和文字一位都不减，验收页上量出来的对比度数字全部照旧成立。
-- 同档里还有两个我们自己的框（信息条 / 小地图面板）：它们显式 `SetFrameLevel(1)`，
-- 保证压在暗角之上（这一档默认 0，靠创建先后决定谁盖谁不稳，所以写死）。
--
-- 材质是一张纯白模具（`monet_vignette_62` / `_55`：整张图只给径向 alpha），压暗的近黑由运行期
-- `SetVertexColor` 给，强度给顶点 alpha —— 三档共用两张图，不逐档出材质。
-- 全程只建我们自己的框、不碰任何暴雪框体；默认关（`DEFAULTS.modules.Atmosphere = false`）。

local ADDON_NAME, ns = ...

local Widget = ns.Widget
local Media  = ns.Media

local M = { name = "Atmosphere" }
ns.Atmosphere = M

-- 候选页（tools/gen-beauty-candidates.js）量出来的压暗色 `DARK`：近黑、极轻的冷偏。
-- **不走主题槽**：暗角要的是"世界变暗"，跟着区域色走会变成"世界被染色"。
local DARK_R, DARK_G, DARK_B = 0.05, 0.06, 0.08

--- 三档强度。`alpha` = 顶点 alpha（贴图自己归一化到峰值 1.0）；`tex` = 剖面半径：
--- .06 / .10 配 r0 = .62（平段宽，只在最外圈下探），.12 配 r0 = .55（深一档要更宽的下探）。
--- 这三组数是验收页上逐档算过有效底和正文对比度之后留下的，别改成"看着顺眼的中间值"。
local TIERS = {
    { alpha = 0.06, tex = "monet_vignette_62", label = "轻 .06" },
    { alpha = 0.10, tex = "monet_vignette_62", label = "中 .10" },
    { alpha = 0.12, tex = "monet_vignette_55", label = "重 .12" },
}

local frame, art

function M:Settings()
    local db = ns:DB()
    if type(db) ~= "table" then return {} end
    if type(db.atmosphere) ~= "table" then db.atmosphere = {} end
    return db.atmosphere
end

--- 当前那一档（按 alpha 认，认不到退回默认那档）。
function M:Tier()
    local want = tonumber(self:Settings().strength)
    if not want then return TIERS[2] end
    for i = 1, #TIERS do
        if TIERS[i].alpha == want then return TIERS[i] end
    end
    return TIERS[2]
end

function M:SetTier(alpha)
    for i = 1, #TIERS do
        if TIERS[i].alpha == alpha then
            self:Settings().strength = alpha
            self:Apply()
            return true
        end
    end
    return false
end

local function Ensure()
    if frame then return end

    frame = Widget:CreateFrame("MonetUIAtmosphere", _G.UIParent)
    -- 层本身不接鼠标：暗角不是控件，压在所有 UI 之下，一个事件都不该收。
    frame:SetFrameStrata("BACKGROUND")
    frame:SetFrameLevel(0)
    pcall(frame.EnableMouse, frame, false)
    pcall(frame.EnableMouseWheel, frame, false)
    frame:SetAllPoints(_G.UIParent)

    art = frame:CreateTexture(nil, "BACKGROUND")
    art:SetAllPoints(frame)
    -- 一张正方形图拉满屏幕 = 等 α 线贴合屏幕比例的椭圆，和候选页那三张同一形状。
    art:SetTexCoord(0, 1, 0, 1)
end

function M:Apply()
    if not ns:IsModuleEnabled(self.name) then
        if frame then frame:Hide() end
        return
    end

    Ensure()
    local tier = self:Tier()
    art:SetTexture(Media.texture[tier.tex])
    -- 顶点色 alpha 和 GetAlpha 是同一个存储（AGENTS「客户端行为细则」），
    -- 所以强度只从这里给，别再补一次 SetAlpha。
    art:SetVertexColor(DARK_R, DARK_G, DARK_B, tier.alpha)
    frame:Show()
end

function M:Initialize()
    self:Apply()
end

function M:SetEnabled(value)
    if value then
        self:Apply()
    elseif frame then
        frame:Hide()
    end
end

--- `/mui atmosphere status` —— 实机第一趟要看的就是"层在不在、HUD 有没有被压"。
--- `/mui atmosphere strength <0.06|0.10|0.12>` —— 不开面板逐档换，方便对着截图点名。
function M:HandleCommand(rest)
    local arg, value = string.match(rest or "", "^(%a+)%s*(.*)$")
    if not arg or arg == "status" then
        local tier = self:Tier()
        local on = ns:IsModuleEnabled(self.name) and "开" or "关"
        ns:Print(("暗角：%s｜强度 %.2f｜材质 %s｜框 %s｜层级 %s/%s"):format(
            on, tier.alpha, tier.tex,
            frame and (frame:IsShown() and "显示" or "隐藏") or "未创建",
            tostring(frame and frame:GetFrameStrata() or "?"),
            tostring(frame and frame:GetFrameLevel() or "?")))
        local parts = {}
        for i = 1, #TIERS do parts[i] = ("%.2f(%s)"):format(TIERS[i].alpha, TIERS[i].tex) end
        ns:Print("可选强度：" .. table.concat(parts, " / ") .. "｜换档：/mui atmosphere strength 0.10")
        return true
    end

    if arg == "strength" then
        local alpha = tonumber(value)
        if not alpha then
            ns:Print("用法：/mui atmosphere strength 0.06|0.10|0.12")
            return true
        end
        if self:SetTier(alpha) then
            ns:Print("暗角强度已设为 " .. tostring(alpha))
        else
            ns:Print("那一档不在表里（可选 0.06 / 0.10 / 0.12）：" .. tostring(value))
        end
        return true
    end

    return false
end

ns:Register("Atmosphere", M)
