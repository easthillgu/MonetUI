-- Modules/Minimap/MicroMenuSecure.lua
-- 微型菜单的"全量安全载体"（#43，2026-11-05 作者选 A，**2026-11-06 实机逐行验过、已转正为默认**）。
-- 开着时右键小地图弹的是**并集**：我们自己的合法动作行（背包 / 地图 / 日历 / 设置，入口单源
-- = `MicroMenu.lua` 导出的 `ownEntries`）+ 能代点的原生微按钮行（角色 / 专业 / 法术书 / 天赋 /
-- 任务日志 / 公会 / 查找队伍 / 收藏 / 帮助 / 商店…）。关掉（`/mui` 小地图页取消勾选，
-- 或 `/mui minimap secure off`）就回 `MicroMenu.lua` 那 4 行纯 C_* 菜单。
-- **11-06 实机定案的两条属性写法**（都写在建行处注释里）：`type="click"` 的委托属性名是
-- **`clickbutton`**（不是 `click`），而且必须 `RegisterForClicks("AnyDown","AnyUp")` ——
-- 这台客户端 `ActionButtonUseKeyDown=1`，只注册 Up 会被算成"释放"，`type=click` 没有释放动作，
-- 于是**整行静默失效**。
--
-- 为什么单独一个文件：
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
-- 代价（作者实机确认过，接受并转正）：
--   * 战斗里开不了（Show 受保护框会被拦）—— 右键是脱战手势，真在战斗中按就当没这菜单。
--   * 菜单开着时进战斗，Close 的 Hide 也会被拦 ⇒ 那一拍关不掉，脱战后补关。
--   * 建行时按状态筛：**不可点的入口不建行**（18 级实测跳掉"传承" `IsEnabled=false`；
--     "游戏菜单"是暴雪自己拒绝脚本化点击，进 `FORWARD_BLOCKED` 黑名单）。
--     跳过原因记在 `skipped` 台账里，`/mui minimap securemenu` 逐条印出来——
--     静默少一行是最难查的缺陷形态，宁缺毋"死行"。

local ADDON_NAME, ns = ...

local Widget = ns.Widget
local M = {}

local ROW_H  = 18
local MENU_W = 120

-- 原生微按钮候选名单（11-05 实机 `MicroMenu` 子件实名，12 颗都在）。
-- **这一列只是候选**：建行时逐颗筛 —— 按钮不存在 / `IsEnabled()=false` / 在 `FORWARD_BLOCKED`
-- 黑名单里，都不建行并把原因记进 `skipped`（11-06 实机：18 级跳掉"传承"，游戏菜单进黑名单）。
-- 行做的事只有一件：代点那颗暴雪微按钮（`type="click"` + `clickbutton`），施法/开窗全由客户端
-- 在受限环境里代做，我们一个暴雪 Lua 全局都不碰。
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
local catcher
local built   -- 只在脱战建一次；建失败（受限窗口 / 模板缺失）保持 false，下次脱战再试

-- 建行时跳过的原生入口（"标签：原因"），`/mui minimap securemenu` 把它报出来。
-- 为什么要有这本账：AGENTS 的教训是"点了没反应"这种**静默失败**最难查 ——
-- 与其让玩家（和我）去猜哪行是死的，不如在建行那一刻就把"为什么没建行"写进台账。
local skipped = {}

-- 明知代点不通的原生按钮（11-06 实机逐颗验过，不是猜）：
-- 它的 `IsEnabled` / `IsVisible` / `Enum.ForbiddenAspect` 全都是放行值，点了仍然零反应、
-- 零报错、零拦截 ⇒ 卡点在暴雪那颗按钮自己的处理里（游戏菜单只吃玩家直接输入）。
-- 留着它只会造出一颗死行 ⇒ 直接不建。
local FORWARD_BLOCKED = {
    MainMenuMicroButton = "暴雪不允许脚本化打开游戏菜单（11-06 实机：代点零反应、零报错、零拦截）",
}

--- 让 12 颗代点目标"可见但透明"：shown=true + alpha 0。
--- 引擎对 `type="click"` 的 `HandleAttributeClick` 会跳过 `IsVisible()=false` 的目标，
--- 而 `IsVisible` 只看自身与祖先的 shown 链、不看 alpha ⇒ 透明不影响代点落地。
--- 每次开菜单都重 assert 一次（暴雪/第三方可能把底栏重新藏回去）。
--- **11-06 实机补的一层**：只 assert 父链不够 —— 单颗按钮自己也可能被暴雪藏着
--- （`HelpMicroButton` 实测 `shown=false`，而它父链 `MicroMenu` 是 shown 的），
--- 那颗就会变成"行能点、什么都不发生"的死行。所以逐颗也 assert 一次。
function M.ensureVisible()
    for _, name in ipairs({ "MicroMenuContainer", "MicroMenu" }) do
        local f = _G[name]
        if f and type(f.IsShown) == "function" and not f:IsShown() then
            pcall(f.Show, f)
        end
        if f and type(f.SetAlpha) == "function" then
            pcall(f.SetAlpha, f, 0)
        end
    end
    for _, t in ipairs(TARGETS) do
        local b = _G[t.btn]
        if b and type(b.IsShown) == "function" then
            local ok, shown = pcall(b.IsShown, b)
            if ok and not shown then pcall(b.Show, b) end
        end
    end
end

--- 此刻有几颗代点目标真的可点（`IsVisible`）。给 Probe 用，也用来丢掉死行。
function M.clickableCount()
    local ok, dead = 0, {}
    for _, t in ipairs(TARGETS) do
        local b = _G[t.btn]
        local vis = false
        if b and type(b.IsVisible) == "function" then
            local okV, v = pcall(b.IsVisible, b)
            vis = okV and v and true or false
        end
        if vis then ok = ok + 1 else dead[#dead + 1] = t.label end
    end
    return ok, dead
end

--- 建载体。**必须在脱战**：建框 + 排版 + 写安全属性全在这一次做完，之后不再排版。
local function Build()
    if built then return frame end
    -- 受限窗口里建 = 排版写入会被静默吞（§8.38 那条），直接不建，等下次脱战再试。
    if ns:IsRestricted() then return nil end

    -- 模板名**必须串起来给**（逗号或空格都有效，11-06 实测）：只给 `SecureHandlerBaseTemplate` 的框
    -- `SetBackdrop` 不存在，`Widget:Theme` 里那句被 pcall 静默吞掉 ⇒ 载体没有底板、12 行文字浮在世界上
    -- （实机截图就是这个样子）。`Mix(frame, BackdropTemplateMixin)` 这条路在这台客户端不通（实测 afterMix=false）。
    -- 容器**不要用 `SecureHandlerBaseTemplate, BackdropTemplate` 这种模板串**（11-06 实测）：
    -- 串起来给确实能拿到 `SetBackdrop`，但 `SecureHandlerBaseTemplate` 的 `Execute` 会**一起消失**
    -- （base：Execute=true/SetBackdrop=false；comma/space：Execute=false/SetBackdrop=true）。
    -- 而这一版载体自始至终没有用过 `Execute`（行的属性是下面 Lua 直接 `SetAttribute`），
    -- 用它只换来"没有底板、12 行浮在世界上"。所以容器只要普通 `BackdropTemplate`；
    -- 安全的是**行**（`SecureActionButtonTemplate`），普通框当父级是暴雪自己的做法（动作条即如此）。
    -- 代价照 §8.38：有了安全子件后整框 `IsProtected()=true`（锚定家族），
    -- 所以排版全部在脱战这一次做完，之后一个 `SetPoint` 都不写。
    local container = CreateFrame("Frame", "MonetUIMicroMenuSecure", UIParent, "BackdropTemplate")
    if not container or type(container.SetBackdrop) ~= "function" then
        -- 连底衬能力都没有（异常客户端）⇒ 这版载体用不了，交回 4 行菜单。
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

    -- 代点的目标（那 12 颗原生微按钮）必须 IsVisible，否则引擎的 HandleAttributeClick
    -- 对 `type="click"` 有 `clickButton:IsVisible()` 守卫，会直接什么都不做（11-05 实机：
    -- 我们把整排微按钮藏了 ⇒ 行能弹、点了没反应）。做法：把微按钮链 shown + alpha 0
    -- （IsVisible 只看 shown 不看 alpha）⇒ 玩家看不见底栏，但代点能落地。
    M.ensureVisible()

    rows = {}
    skipped = {}
    local y = -4

    -- 行外壳：两组行的排版与悬停反馈**完全一样**，只有"点击做什么"不同
    -- （第一组跑我们自己的动作，第二组交给引擎代点暴雪按钮）。
    local function makeRow(text, template)
        local row = CreateFrame("Button", nil, container, template)
        row:SetPoint("TOPLEFT", container, "TOPLEFT", 3, y)
        row:SetPoint("TOPRIGHT", container, "TOPRIGHT", -3, y)
        row:SetHeight(ROW_H)
        row:EnableMouse(true)
        local label = Widget:Font(row, 12, "pixel", "neutral", "CENTER")
        label:SetPoint("LEFT", row, "LEFT", 6, 0)
        label:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        label:SetText(text)
        label:SetNonSpaceWrap(false)
        row:SetScript("OnEnter", function() Widget:ColorText(label, "highlight") end)
        row:SetScript("OnLeave", function() Widget:ColorText(label, "neutral") end)
        rows[#rows + 1] = row
        y = y - (ROW_H + 1)
        return row
    end

    -- **第一组：我们自己的合法动作**（纯 C_* API / 我们自己的模块）。
    -- 11-06 补的覆盖缺口：右键开着本载体时 `Minimap.lua` 不再走 `MicroMenu.lua` 那 4 行
    -- （见那边的分发点），于是不结这条并集就会丢掉"背包 / 地图 / 日历 / 设置"。
    -- 入口定义**只有一份**：`MicroMenu.lua` 导出 `ownEntries`，这里读，不抄第二份。
    local minimapModule = ns:GetModule("Minimap")
    local ownEntries = minimapModule and minimapModule.microMenu and minimapModule.microMenu.ownEntries
    for _, e in ipairs(ownEntries or {}) do
        if type(e.luaAction) == "function" then
            local row = makeRow(e.label)
            row:SetScript("OnClick", function(_, button)
                if button ~= "LeftButton" then return end
                pcall(e.luaAction)
                -- 自有动作行点完就收（与 4 行版一致）；代点行不能这么做，原因见下面 catcher 的注释。
                M:Close()
            end)
        else
            skipped[#skipped + 1] = e.label .. "：入口没有 luaAction（不该发生）"
        end
    end

    -- **第二组：代点原生微按钮**（安全行）。
    for _, t in ipairs(TARGETS) do
        local b = _G[t.btn]
        local whySkip
        if not b then
            whySkip = "本客户端没有这颗按钮"
        elseif FORWARD_BLOCKED[t.btn] then
            whySkip = FORWARD_BLOCKED[t.btn]
        else
            if type(b.IsEnabled) == "function" then
                local okE, en = pcall(b.IsEnabled, b)
                if okE and en == false then whySkip = "此刻不可用（IsEnabled=false）" end
            end
        end
        if whySkip then
            skipped[#skipped + 1] = t.label .. "：" .. whySkip
        else
            local row = makeRow(t.label, "SecureActionButtonTemplate")
            row:RegisterForClicks("AnyDown", "AnyUp")
            -- `type="click"` + **`clickbutton`**（不是 `click`！）：
            -- 暴雪 SecureTemplates 的实现是
            --   SECURE_ACTIONS.click = function(self, unit, button)
            --     local delegate = SecureButton_GetModifiedAttribute(self, "clickbutton", button)
            --     if delegate and not delegate:HasAccessConstraints()
            --        and not delegate:HasAnyForbiddenAspects(Enum.ForbiddenAspect.ScriptedInput) then
            --       delegate:Click(button) end end
            -- 11-06 双探针实机定案：属性名写 `click` 时 B 型完全不响应；改成 `clickbutton` 后
            -- **同一个目标立刻能开角色面板**（对照的 `type="macro"` + `/click` 反而不通，不用）。
            --
            -- **必须双注册 Down+Up**（同一次实机）：这台客户端 `ActionButtonUseKeyDown=1`，引擎判定是
            --   clickAction = (down and useOnKeyDown) or (not down and not useOnKeyDown)
            -- 只注册 `LeftButtonUp` 时，鼠标抬起那一拍被算成"释放"，而 `type=click` 没有释放动作 ⇒
            -- **静默什么都不做**（零报错、`taint.log` 零记录，玩家只看到"点了没反应"）。
            -- 施法/开窗全由客户端在受限环境里代做，我们一个暴雪 Lua 全局都不碰。
            row:SetAttribute("type", "click")
            row:SetAttribute("clickbutton", b)
            -- **安全模板缺席时 `CreateFrame` 不报错**，只会给一个普通按钮 —— 那种按钮属性写得再对也不会
            -- 代点（11-05 记过那一类："属性全对、0 拦截、点击无反应"）。整框 `IsProtected()` 会跟着
            -- 锚定家族变 true，所以判据只能看**这一行自己**是不是受保护。
            if type(row.IsProtected) ~= "function" or not row:IsProtected() then
                pcall(row.Hide, row)
                pcall(container.Hide, container)
                return nil
            end
        end
    end

    if #rows == 0 then
        -- 两组一行都没建成（异常客户端）⇒ 载体没意义，删掉交回 4 行菜单。
        container:Hide()
        return nil
    end

    container:SetHeight(math.abs(y) + 10)

    -- **点外面就关**：整屏 catcher，层级比菜单低（菜单容器 level 30，这里 10），
    -- 所以行上的点击不会被它吃掉（做法与 `MicroMenu.lua:130` 那版完全一致）。
    -- 它是我们的普通框、不在安全钮的锚定家族里 ⇒ 不受那条"面板被标成受保护"的雷。
    -- 说明一处不一致：**自有动作行点完会自己关**（那一行的 OnClick 是我们写的），
    -- 而代点行**做不到**——给 `SecureActionButtonTemplate` 挂 OnClick 会顶掉模板的引擎处理，
    -- 代点就废了。所以代点完留菜单开着，点别处再关。
    catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:SetFrameLevel(10)
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", function() M:Close() end)
    catcher:Hide()

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
    -- 已经有别的菜单开着就别抢（单源：`MicroMenu.lua` 导出的 `anyMenuOpen`）。
    -- 同一次右键里暴雪的追踪菜单 / LibDBPanel 这类也可能开菜单，我们再开一次就等于把人家关掉，
    -- 玩家看到的是"右键没反应"，而实际是"开了又立刻被关掉"。
    local minimapModule = ns:GetModule("Minimap")
    local anyMenuOpen = minimapModule and minimapModule.microMenu and minimapModule.microMenu.anyMenuOpen
    if type(anyMenuOpen) == "function" and anyMenuOpen() then return end
    if not Build() then return end
    M.ensureVisible()
    if catcher then pcall(catcher.Show, catcher) end
    frame:Show()
end

function M:Close()
    if not frame then return end
    -- 战斗中 Hide 受保护框会被拦：那一拍关不掉，留到脱战补（见文件头"代价"）。
    if ns:IsRestricted() then return end
    if catcher then pcall(catcher.Hide, catcher) end
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
            ns:Print("|cffff6b6b建不出来|r：容器没有底衬能力 / 客户端的 `SecureActionButtonTemplate` 不是安全模板（行不受保护）/ 12 颗微按钮一个都不在 ⇒ 交回 4 行菜单。")
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
    -- 判据印成结论：代点目标此刻有几颗真的可点（`IsVisible`）。
    -- **这条只读不写**（§8.38 的探针纪律：诊断命令不许产生它正在判定的状态）——
    -- 开菜单时 `ensureVisible()` 才会去补 Show，所以这里报出来的"不可点"不等于死行。
    local nOK, dead = M.clickableCount()
    ns:Print(("代点目标此刻可点 %d/%d%s（开菜单时 ensureVisible 会逐颗补 Show）"):format(
        nOK, #TARGETS, #dead > 0 and ("；不可点：" .. table.concat(dead, " ")) or ""))
    -- 建行时跳过的入口：这些行**故意不存在**，不是漏建（静默少一行是最难查的缺陷形态）
    if #skipped > 0 then
        ns:Print("没建行的入口（故意跳过，不是漏建）：")
        for _, why in ipairs(skipped) do ns:Print("   · " .. why) end
    end
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
