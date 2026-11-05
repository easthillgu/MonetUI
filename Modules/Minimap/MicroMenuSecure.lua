-- Modules/Minimap/MicroMenuSecure.lua
-- 微型菜单的"全量安全载体"（#43，2026-11-05 作者选 A）。默认关（`Core.lua` 的 `microMenuSecure = false`），
-- 开着时右键小地图弹这 12 行（代点暴雪原生那排微按钮），关着时走 MicroMenu.lua 那 4 行纯 C_* 菜单。
--
-- 为什么单独一个文件、还默认关：
--   * MicroMenu.lua 的 A2 闸门**禁止那个文件出现 `SecureActionButtonTemplate`**（当年 13 行安全钮锚进
--     面板、每次 Toggle 又对面板 ClearAllPoints/SetPoint，面板被锚定家族标成受保护后，战斗中我们的
--     排版写入被静默丢弃 ⇒ "右键没反应"，§8.37 / §8.38）。
--   * 这一版换了结构绕开它：**建一次 + 活锚点跟随小地图 + 之后一个 SetPoint 都不再写**，
--     Toggle 只 Show/Hide 且过 `ns:IsRestricted()` 门。
--
-- 11-05 实机（`/mui` 一次性安全框探针）推翻了一条旧假设：
--   **脱战时**对受保护容器 SetPoint / Show / Hide / SetAlpha 全都落地（left/right 跟着动了），
--   静默丢弃只在**战斗中**发生。所以只要排版全在脱战建一次、之后靠活锚点跟随，就不碰那条雷。
--
-- 代价（默认关的原因，作者实机验前不当已交付）：
--   * 战斗里开不了（Show 受保护框会被拦）—— 右键是脱战手势，可接受；真在战斗中按，菜单不出。
--   * 菜单开着时进战斗，Close 的 Hide 也会被拦 ⇒ 那一拍关不掉，脱战后补关。
--   这两条都要作者实机确认观感，所以先关着。

local ADDON_NAME, ns = ...

local Widget = ns.Widget
local M = {}

local ROW_H  = 18
local MENU_W = 120

-- 12 颗原生微按钮（11-05 实机 `MicroMenu` 子件实名，逐个存在才建行）。
-- 行做的事只有一件：代点那颗暴雪微按钮（`type="click"`），施法/开窗全由客户端在受限环境里代做，
-- 我们一个暴雪 Lua 全局都不碰。
local TARGETS = {
    { label = "角色",     btn = "CharacterMicroButton" },
    { label = "专业",     btn = "ProfessionMicroButton" },
    { label = "法术书",   btn = "SpellbookMicroButton" },
    { label = "天赋",     btn = "TalentMicroButton" },
    { label = "传承",     btn = "LegacyMicroButton" },
    { label = "任务日志", btn = "QuestLogMicroButton" },
    { label = "公会",     btn = "GuildMicroButton" },
    { label = "查找队伍", btn = "LFDMicroButton" },
    { label = "收藏",     btn = "CollectionsMicroButton" },
    { label = "帮助",     btn = "HelpMicroButton" },
    { label = "商店",     btn = "StoreMicroButton" },
    { label = "游戏菜单", btn = "MainMenuMicroButton" },
}

local frame
local rows
local built   -- 只在脱战建一次；建失败（受限窗口 / 模板缺失）保持 false，下次脱战再试

--- 一行一个**自烘**的点击片段：把目标按钮名直接写进片段串，`ChildUpdate` 一次广播、
--- 每行跑自己那条 ⇒ `type`/`click` 都在**安全环境**里写（Lua 直写是脏值，客户端点下去
--- 会把那次点击连带记成 MonetUI，见 Secure.lua 的 KIND_CHILD 段）。
local function ClickSnippet(btnName)
    return ("self:SetAttribute('type', 'click'); self:SetAttribute('click', _G[%q])"):format(btnName)
end

--- 建载体。**必须在脱战**：建框 + 排版 + 写安全属性全在这一次做完，之后不再排版。
local function Build()
    if built then return frame end
    -- 受限窗口里建 = 排版写入会被静默吞（§8.38 那条），直接不建，等下次脱战再试。
    if ns:IsRestricted() then return nil end

    local container = CreateFrame("Frame", "MonetUIMicroMenuSecure", UIParent, "SecureHandlerBaseTemplate")
    if not container or type(container.Execute) ~= "function" then
        -- 这台客户端没有安全处理器基础模板（Execute 拿不到）⇒ 这版载体用不了，交回 4 行菜单。
        return nil
    end

    Widget:Theme(container, { thickness = 1, bgAlpha = 0.96, borderAlpha = 1 })
    container:SetFrameStrata("DIALOG")
    container:SetFrameLevel(30)
    container:EnableMouse(true)
    container:SetClampedToScreen(true)
    -- 宽度必须显式给：行是 TOPLEFT/TOPRIGHT 撑到容器两侧，容器没宽就全塌成 ~0（11-05 实机
    -- "没弹"真凶 = 只 SetHeight 没 SetWidth，探针读矩形 2x242）。
    container:SetWidth(MENU_W)

    -- 活锚点：锚到暴雪 Minimap 的右上角，**只 SetPoint 这一次**。
    -- 小地图被搬动（玩家 / 第三方收纳器）时，活锚点每拍自己重算 ⇒ 菜单跟着走，我们不再写排版。
    -- 锚到暴雪 Minimap（本就受保护）不牵动我们的排版框，和 §8.38 那个"锚到我们要重排的框"不同型。
    local mm = _G.Minimap
    if mm then
        container:SetPoint("BOTTOMRIGHT", mm, "TOPRIGHT", -6, 6)
    else
        container:SetPoint("CENTER", UIParent, "CENTER")
    end

    rows = {}
    local y = -4
    for _, t in ipairs(TARGETS) do
        if _G[t.btn] then
            local row = CreateFrame("Button", nil, container, "SecureActionButtonTemplate")
            row:SetPoint("TOPLEFT", container, "TOPLEFT", 3, y)
            row:SetPoint("TOPRIGHT", container, "TOPRIGHT", -3, y)
            row:SetHeight(ROW_H)
            row:EnableMouse(true)
            row:RegisterForClicks("LeftButtonUp")
            -- 目标名烘进片段；这里只装片段，真正写属性在下面一次 ChildUpdate（安全环境）。
            pcall(row.SetAttributeNoHandler, row, "_childupdate-mui-click", ClickSnippet(t.btn))

            local label = Widget:Font(row, 12, "pixel", "neutral", "CENTER")
            label:SetPoint("LEFT", row, "LEFT", 6, 0)
            label:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            label:SetText(t.label)
            label:SetNonSpaceWrap(false)

            row:SetScript("OnEnter", function() Widget:ColorText(label, "highlight") end)
            row:SetScript("OnLeave", function() Widget:ColorText(label, "neutral") end)

            rows[#rows + 1] = row
            y = y - (ROW_H + 1)
        end
    end

    if #rows == 0 then
        -- 一颗微按钮都不在（异常客户端）⇒ 载体没意义，删掉交回 4 行菜单。
        container:Hide()
        return nil
    end

    container:SetHeight(math.abs(y) + 10)

    -- 一次广播：每行跑自己的片段，把 type/click 写进安全属性。
    pcall(container.Execute, container, "self:ChildUpdate('mui-click', 0)")

    container:Hide()
    frame = container
    built = true
    return frame
end

function M:Toggle()
    if frame and frame:IsShown() then
        self:Close()
        return
    end
    -- 受限窗口里 Show 受保护框会被拦 ⇒ 这一拍不开（右键是脱战手势，真在战斗中按就当没这菜单）。
    if ns:IsRestricted() then return end
    if not Build() then return end
    frame:Show()
end

function M:Close()
    if not frame then return end
    -- 战斗中 Hide 受保护框会被拦：那一拍关不掉，留到脱战补（见文件头"代价"）。
    if ns:IsRestricted() then return end
    frame:Hide()
end

function M:IsOpen()
    return frame and frame:IsShown() and true or false
end

--- `/mui minimap securemenu`：把判据印成结论（AGENTS：别让玩家对着裸数字判断）。
--- 报三件事：① 模板/安全钮在不在（决定能不能建）；② 面板受不受保护、有没有排版落地；③ 此刻能不能开。
function M:Probe(enabledSetting)
    if not built then
        if ns:IsRestricted() then
            ns:Print("载体还没建：此刻处于受限窗口（战斗/地图/聊天…），脱战后第一次右键才会建。")
        elseif not Build() then
            ns:Print("|cffff6b6b建不出来|r：没有 SecureHandlerBaseTemplate / SecureActionButtonTemplate，或 12 颗微按钮一个都不在 ⇒ 交回 4 行菜单。")
            return
        end
    end
    if not frame then
        ns:Print("载体对象为空（内部状态异常），交回 4 行菜单。")
        return
    end
    local prot = (type(frame.IsProtected) == "function") and frame:IsProtected() or false
    local np = (type(frame.GetNumPoints) == "function") and frame:GetNumPoints() or "?"
    local rl, rb, rw, rh
    if type(frame.GetRect) == "function" then rl, rb, rw, rh = frame:GetRect() end
    local rowProt = 0
    for _, row in ipairs(rows or {}) do
        if type(row.IsProtected) == "function" and row:IsProtected() then rowProt = rowProt + 1 end
    end
    ns:Print(("安全载体：行 %d · 面板受保护=%s（应为 true，安全钮子树）· 行受保护=%d/%d · 锚点数=%s · 矩形=%s · shown=%s"):format(
        #(rows or {}), tostring(prot), rowProt, #(rows or {}), tostring(np),
        (rl and string.format("%.0f,%.0f %.0fx%.0f", rl, rb, rw or 0, rh or 0)) or "读不出",
        tostring(frame:IsShown())))
    local verdict
    if not enabledSetting then
        verdict = "开着 4 行菜单，这个载体不参与右键"
    elseif ns:IsRestricted() then
        verdict = "战斗/受限中：右键不会打开（脱战才开）"
    else
        verdict = "可开：右键小地图应弹出 12 行"
    end
    ns:Print(("设置 microMenuSecure=%s · 此刻受限=%s ⇒ %s"):format(
        tostring(enabledSetting), tostring(ns:IsRestricted()), verdict))
    if np == 0 then
        ns:Print("|cffff6b6b判读：面板一个锚点都没有|r ⇒ 建时那次 SetPoint 没落地（不该发生 —— 建是在脱战做的）。")
    end
end

ns:GetModule("Minimap").microMenuSecure = M
