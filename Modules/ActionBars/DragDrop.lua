-- Modules/ActionBars/DragDrop.lua
-- 拖放接住器（P5' 拆分，2026-10-26）：每条条一只"只在手里拿着东西时才开鼠标"的透明接住器，
-- 按光标坐标算出目标格再 PlaceAction（普通 Frame 收不到 OnReceiveDrag，见下方长注释）。
-- 接口面：
--   * 输入：M.SlotOf（格子 → 动作槽位）；
--   * 输出：M.dragdrop.EnsureDropCatcher(bar)。

local ADDON_NAME, ns = ...
local Scheduler = ns.Scheduler

local M = ns:GetModule("ActionBars")
if not M then return end

local SlotOf = M.SlotOf

local Secrets = ns.Secrets

-- ---------------------------------------------------------------------------
-- 拖放接住器
--
-- 为什么需要它：把技能拖到格子上时，客户端是按"光标下最上层的可点框体"派发 OnReceiveDrag 的。
-- 我们的按钮虽然 level 61，但暴雪主条（MainActionBar，alpha 0、鼠标还开着、level 50）
-- 的矩形 786,45 562×45 正好压住 bar1 上半截和 bar2 整条 —— 实测 bar2 整排收不到
-- OnReceiveDrag（日志里只有 dstart，没有一次 receive），表现就是"bar2 放不进去、
-- 其它两排要对准一点"。
--
-- 解法：每条条上挂一只**只在手里拿着东西时才开鼠标**的透明接住器（level 70，压住整条），
-- 放下时按光标坐标**算**出目标格（不再依赖命中判定），再 PlaceAction。
-- 平时它关着鼠标，所以点击照旧落在我们自己的按钮上。
local dropCatchers = setmetatable({}, { __mode = "k" })

local function CursorUI()
    local x, y = GetCursorPosition()
    if not x then return nil end
    local scale = UIParent:GetEffectiveScale() or 1
    if scale == 0 then scale = 1 end
    return x / scale, y / scale
end

--- 光标落在这一条的第几格（1..n），不在条上返回 nil。
--- **按每个按钮自己的矩形判断**，不再用"条的左下角 + 格子间距"推算：
---   * GetLeft/GetBottom 已经是屏幕（UIParent 缩放后）坐标，再乘一次缩放会整体偏移；
---   * 间距/内边距一旦和 LayoutBar 不一致，推算出来的格子就会错位。
--- 逐格命中不存在这两个问题，而且天然支持将来每条不同的格子尺寸。
local function IndexAtCursor(bar)
    local cx, cy = CursorUI()
    if not cx or not cy then return nil end
    local upScale = UIParent:GetEffectiveScale() or 1
    for index, button in ipairs(bar.buttons) do
        local left, bottom = button:GetLeft(), button:GetBottom()
        if left and bottom then
            local s = (button:GetEffectiveScale() or upScale) / upScale
            local w = (button:GetWidth() or 0) * s
            local h = (button:GetHeight() or 0) * s
            if cx >= left and cx <= left + w and cy >= bottom and cy <= bottom + h then
                return index
            end
        end
    end
    return nil
end

local function EnsureDropCatcher(bar)
    if dropCatchers[bar] then return dropCatchers[bar] end
    local frame = bar.frame
    -- **必须用暴雪模板建**：实机证明普通 Frame 收不到 OnReceiveDrag（一次都没有），
    -- 而之前那版 ActionBarButtonTemplate 做的透明代理是能收到拖放的。所以接住器也用它。
    -- **必须带名字**：ActionButtonTemplate 的 OnLoad -> UpdateHotkeys 会拼 GetName()，
    -- 匿名框体会抛 "ActionButton.lua:489: attempt to concatenate a nil value"（日志里 16 次）。
    local catcherName = "MonetUIDropCatcher" .. tostring(bar.index or 0)
    local catcher
    for _, tmpl in ipairs({ "ActionBarButtonTemplate, SecureActionButtonTemplate",
                            "ActionButtonTemplate, SecureActionButtonTemplate",
                            "SecureActionButtonTemplate" }) do
        local ok, made = pcall(CreateFrame, "CheckButton", catcherName, UIParent, tmpl)
        if ok and made then catcher = made break end
    end
    if not catcher then return nil end
    -- **它只是接住拖放，绝不能施法、也不该有提示框。**
    -- ActionBarButtonTemplate 会带来暴雪 ActionButton 的 OnClick / OnEnter：
    --   * OnClick 在它没有 action 属性时会按 CalculateAction(id=0) 算成"动作条第 1 格"，
    --     于是点在它上面会放出 1 号格的法术（实机：宠物条 10 格全放"奥术射击"，
    --     提示框也写着"奥术射击"—— 因为鼠标其实落在它身上，它在 level 70，压着我们的按钮）；
    --   * OnEnter/OnLeave 会挂一个跟我们按钮无关的提示框。
    -- 我们只要它的 OnReceiveDrag / OnMouseUp（下面自己设），所以把模板带来的脚本全摘掉。
    pcall(catcher.SetScript, catcher, "OnClick", nil)
    pcall(catcher.SetScript, catcher, "OnEnter", nil)
    pcall(catcher.SetScript, catcher, "OnLeave", nil)
    pcall(catcher.SetAttribute, catcher, "type", nil)
    pcall(catcher.SetAttribute, catcher, "action", nil)
    if catcher.RegisterForClicks then pcall(catcher.RegisterForClicks, catcher) end
    catcher:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    catcher:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    catcher:SetFrameStrata("MEDIUM")
    catcher:SetFrameLevel(70)
    catcher:SetAlpha(0)
    -- **必须 Show**：OnUpdate 只在 Show 的框体上跑，隐藏的框体也不参与鼠标命中 ——
    -- 之前没 Show，结果它既不轮询也收不到放下事件（拖放依旧全废）。
    catcher:Show()
    catcher:EnableMouse(false)
    catcher:SetScript("OnReceiveDrag", function(self)
        if InCombatLockdown() then return end
        local index = IndexAtCursor(bar)
        local button = index and bar.buttons[index]
        local slot = button and SlotOf(button, bar, index)
        if slot and PlaceAction then pcall(PlaceAction, slot) end
        self.holding = false
        pcall(self.EnableMouse, self, false)
    end)
    -- **OnReceiveDrag 在这个客户端不派发给普通框体**（实机：接住器 mouse=true、光标确实拿着法术，
    -- 但一次 RECV 都没有）。所以真正的落点走 OnMouseUp：松手时只要手里还有东西，就按坐标算格子
    -- 再 PlaceAction —— 这也是"点一下把技能放进格子"的标准行为。
    catcher:SetScript("OnMouseUp", function(self)
        if InCombatLockdown() then return end
        if GetCursorInfo() == nil then return end
        local index = IndexAtCursor(bar)
        local button = index and bar.buttons[index]
        local slot = button and SlotOf(button, bar, index)
        if slot and PlaceAction then pcall(PlaceAction, slot) end
    end)
    -- 10Hz 轮询：只在"这条条显示着"**并且**手里拿着东西（法术/物品/宏）时才开鼠标。
    -- 早期写法是"条不显示就直接 return"——那会漏掉最重要的那一拍：接住器是挂在**条的矩形**上的
    -- （level 70，压过我们的按钮），而模板自带的事件会把它鼠标打开；条隐藏时不给它结算，
    -- 它就永远停在 mouse=true。实机后果（2026-10-26）：bar4..8 只有 3 组却开着接住器，
    -- bar4 的接住器正好压在姿态条上，姿态那几格点下去变成"动作条第 1 格"。
    -- 所以每一拍都算出一个**期望状态**，和当前状态不一致就写过去（包括"关掉"）。
    catcher.subId = Scheduler:Every(100, function()
        -- IsShown 在受限环境可能是机密值：走 Secrets.Bool，读不出来按"没显示"（= 关鼠标，更安全）。
        local active = Secrets.Bool(frame:IsShown(), false) and (GetCursorInfo() ~= nil)
        if active ~= catcher.holding then
            catcher.holding = active
            pcall(catcher.EnableMouse, catcher, active)
        end
    end, "动作条:拖放接收器")
    dropCatchers[bar] = catcher
    return catcher
end

M.dragdrop = {
    EnsureDropCatcher = EnsureDropCatcher,
}
