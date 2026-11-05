-- Modules/Minimap/MicroMenu.lua
-- 右键小地图弹出的微型游戏菜单：一列游戏面板的快捷入口，面板用统一的 Monet 材质。
--
-- 入口全部"存在才画"：每一行要么把点击**安全转发**给暴雪自己的那颗微按钮
-- （`SecureActionButtonTemplate` + `type="click"`），要么只有一个**纯 C_* API** 动作
-- （`Settings.OpenToCategory` / `C_Map.OpenWorldMap` / 我们自己的模块）。两者都拿不到就不建行。
-- **不再有**"探测 _G 里的暴雪开关函数然后调用它"这条路 —— 那是 11-05 开服 P0 的写法（§8.36）。

local ADDON_NAME, ns = ...

local Widget = ns.Widget

local M = {}

local ROW_H  = 16
local MENU_W = 56

local frame      -- 菜单面板
local catcher    -- 点别处关闭
local rows       -- 已建的行

--- 入口定义：`buttons` 是**可安全转发**的暴雪微型按钮实名（谁在就用谁），`luaAction` 只允许
--- 纯 C_* API 或我们自己的模块 —— 两个字段都取不到，这一行就不建（宁可少一行，不弹「界面行为失效」）。
---
--- ⚠ 以前这里每行还挂一个 `action`（`ToggleAllBags` / `ToggleQuestLog` / `ToggleFriendsFrame`
--- 这类**暴雪 Lua 全局**）当备用开关。11-05 开服 P0 之后这条路径已经整个删掉，`action` 字段
--- 也不再被读（`SafeActionFor` 只认 `luaAction`）：留着就是"看着还有兜底、其实一行不跑"，
--- 而且会把下一个改这里的人引回同一条污染路（AGENTS「绝不直调暴雪 Lua 全局」）。
---
--- **1.60 实名（开服日 `/mui compat find MicroButton`，全客户端 17 个命中）**：
--- Character / PlayerSpells / Spellbook / Talent / Achievement / QuestLog / Guild / LFD /
--- Collections / EJ / Profession / Store / Housing / Legacy / MainMenu / Help（+ 容器
--- `MicroButtonAndBagsBar`）。**`BagMicroButton` / `MapMicroButton` / `CalendarMicroButton` /
--- `GJMicroButton` / `SocialsMicroButton` / `PVPMicroButton` 都不存在** —— 背包那一排改名成
--- `BagsBar`（不是可点按钮），日历/社交/PVP 折进了别的窗口，所以那几行换成下面两种合法出口。
local ENTRIES = {
    { label = "角色", buttons = { "CharacterMicroButton" } },
    { label = "法术", buttons = { "PlayerSpellsMicroButton", "SpellbookMicroButton" } },
    { label = "背包", luaAction = function()
        -- 本客户端没有 `BagMicroButton` 可转发（那一排改成了 `BagsBar` 图标簇，不是按钮），
        -- 而 `ToggleAllBags` 是暴雪 Lua 全局 —— 走我们自己的背包窗口，动作完全在我们名下。
        local bags = ns:GetModule("Bags")
        if bags and type(bags.Toggle) == "function" then bags:Toggle(true) end
      end },
    { label = "任务", buttons = { "QuestLogMicroButton" } },
    { label = "成就", buttons = { "AchievementMicroButton" } },
    { label = "好友", buttons = { "GuildMicroButton" } },
    { label = "地图", luaAction = function()
        -- `C_Map.OpenWorldMap` 文档标 [受限]：受限窗口里一行都不做，别让它替我们撞墙。
        if ns:IsRestricted() then return end
        local C_Map = _G.C_Map
        if C_Map and type(C_Map.OpenWorldMap) == "function" then C_Map.OpenWorldMap() end
      end },
    { label = "收藏", buttons = { "CollectionsMicroButton" } },
    { label = "副本", buttons = { "EJMicroButton" } },
    { label = "职业", buttons = { "ProfessionMicroButton" } },
    { label = "寻找组", buttons = { "LFDMicroButton" } },
    { label = "住房", buttons = { "HousingMicroButton" } },
    { label = "商店", buttons = { "StoreMicroButton" } },
    { label = "帮助", buttons = { "HelpMicroButton" } },
    { label = "设置", buttons = { "MainMenuMicroButton" },
      -- 只有这条允许 Lua 直调：`Settings.OpenToCategory` 是客户端 C 侧 API，不会把暴雪的
      -- Lua 面板链拉进我们的执行环境（对比：`ToggleGameMenu` 是暴雪 Lua 函数，已撤掉）。
      luaAction = function()
        local settings = _G.Settings
        if settings and type(settings.OpenToCategory) == "function" and settings.INTERFACE_CATEGORY_ID then
            return settings.OpenToCategory(settings.INTERFACE_CATEGORY_ID)
        end
      end },
}

--- 这一行的目标：拿暴雪那颗微型按钮**本身**（不是它的 OnClick 函数！）。
--- ⚠ 以前这里写成 `pcall(GetScript(button,"OnClick"))` 再在我们的 Lua 里调用那个函数 ——
--- 11-05 开服实测这是 P0：`TextStatusBar.lua:110 attempt to compare a secret number value
--- (execution tainted by 'MonetUI')`，栈根在 `MicroMenu.lua:74`。把暴雪的 Lua 代码拉进我们的
--- 执行环境跑，等于让它的机密值比较记到我们账上，每个点角色/背包的玩家都会看到一条红。
--- 正解是安全转发：我们的行做成 `SecureActionButtonTemplate`，属性 `type="click"` +
--- `click=<那颗按钮>`，由客户端在受限环境里替我们点它。
local function TargetButtonFor(entry)
    for _, name in ipairs(entry.buttons or {}) do
        local button = _G[name]
        if button and type(button.GetName) == "function" then return button end
    end
    return nil
end

--- 只剩"纯 C_* API"可以留在 Lua 里直接调（不牵动暴雪的 Lua 面板链，也不会把机密值比较
--- 带进我们的环境）。`Settings.OpenToCategory` 属于这类；`ToggleGameMenu` 属于暴雪 Lua 函数，
--- **不再当备用动作**（以前会走到它，正是那条红字的来源之一）。
local function SafeActionFor(entry)
    return (type(entry.luaAction) == "function") and entry.luaAction or nil
end

--- 菜单贴着地图左上角展开（向左下），比"跟着鼠标跑"稳：地图本来就在屏幕右下角，
--- 菜单往左展开一定完整可见，不用去猜鼠标的屏幕坐标换算。
local function Build()
    if frame then return frame end

    frame = Widget:CreateFrame("MonetUIMinimapMicroMenu", UIParent, MENU_W, 40)
    -- 直角版（square-blp）：不带 round，走 SetBackdrop 的直角边框。
    Widget:Theme(frame, { thickness = 1, bgAlpha = 0.96, borderAlpha = 1 })
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(20)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:Hide()

    rows = {}
    local y = -4
    for _, entry in ipairs(ENTRIES) do
        local target = TargetButtonFor(entry)
        local luaAction = target and nil or SafeActionFor(entry)
        if target or luaAction then
            -- 有可转发的暴雪按钮 ⇒ SecureActionButtonTemplate（由客户端安全地"代点"）；
            -- 只有纯 C_* 动作时才用普通按钮。属性只写在我们自己造的按钮上（AGENTS 允许的那条路）。
            local row = target
                and CreateFrame("Button", nil, frame, "SecureActionButtonTemplate")
                or  CreateFrame("Button", nil, frame)
            row:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, y)
            row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, y)
            row:SetHeight(ROW_H)
            row:EnableMouse(true)

            local label = Widget:Font(row, 12, "pixel", "neutral", "CENTER")
            label:SetPoint("LEFT", row, "LEFT", 4, 0)
            label:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            label:SetText(entry.label)

            if target then
                row:RegisterForClicks("LeftButtonUp")
                pcall(row.SetAttribute, row, "type", "click")
                pcall(row.SetAttribute, row, "click", target)
                -- PostClick 是我们自己的收尾钩，允许在安全按钮上挂：只关菜单，不碰暴雪的东西。
                row:SetScript("PostClick", function() M:Close() end)
            else
                row:RegisterForClicks("LeftButtonUp")
                row:SetScript("OnClick", function()
                    pcall(luaAction)
                    M:Close()
                end)
            end
            row:HookScript("OnEnter", function() Widget:ColorText(label, "highlight") end) -- TAINT-OK: row 是自建微型菜单行
            row:HookScript("OnLeave", function() Widget:ColorText(label, "neutral") end) -- TAINT-OK: 同上

            rows[#rows + 1] = row
            y = y - (ROW_H + 1)
        end
    end

    frame:SetHeight(math.abs(y) + 10)

    -- 点别处关闭：整屏 catcher，层级比菜单低，菜单自己的点击不会被它吃掉。
    catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:SetFrameLevel(10)
    catcher:EnableMouse(true)
    catcher:SetScript("OnMouseDown", function() M:Close() end)
    catcher:Hide()

    return frame
end

--- 现在有没有别的菜单开着？
--- 暴雪的追踪菜单、LibDBPanel 这类插件会在同一次右键里开菜单；我们再 Toggle 一次，
--- 人家刚开的菜单就被我们关掉了（同一个右键既开又关，看着像"点了没反应"）。
--- AishCore 的做法：查 DropDownList1 与菜单管理器（Comfort.lua 544-551）。
local function AnyMenuOpen()
    local list = _G.DropDownList1
    if list and list.IsShown then
        local ok, shown = pcall(list.IsShown, list)
        if ok and shown then return true end
    end
    local menu = _G.Menu
    if menu and menu.GetManager then
        -- 布尔换算也放在 pcall 里：万一返回值是保密值，条件判断会直接报错
        local ok, anyOpen = pcall(function()
            local open = menu.GetManager():GetOpenMenu()
            return open and true or false
        end)
        if ok and anyOpen then return true end
    end
    return false
end

--- 在小地图旁边弹出（anchor 一般是小地图面板）。
function M:Toggle(anchor)
    if frame and frame:IsShown() then
        self:Close()
        return
    end
    -- 已经有别的菜单开着就别抢（见 AnyMenuOpen 的说明）
    if AnyMenuOpen() then return end
    Build()
    if not frame then return end

    frame:ClearAllPoints()
    if anchor then
        frame:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -6, 0)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    frame:Show()
    if catcher then catcher:Show() end
end

function M:Close()
    if frame then frame:Hide() end
    if catcher then catcher:Hide() end
end

function M:IsOpen()
    return frame and frame:IsShown() and true or false
end

--- `/mui minimap menu` 用（11-05 开服实测：玩家报"右键小地图没出菜单"，而这台机器的 taint.log
--- 对 `ADDON_ACTION_BLOCKED` 零记录，拿不到栈 ⇒ 只能把判据做成一条命令）。
--- 报三件事，每件都指向一个不同的原因：
---   ① 行能不能建出来（入口名在本客户端不存在 ⇒ 那一行整个消失，不是"点了没反应"）；
---   ② 面板/行**是不是受保护**（安全模板锚到我们要重摆的框会把整条面板传染成受保护 ——
---      信息栏 §8.37 就是这么炸的，这里就是那条风险的现场复验）；
---   ③ 开关与展开状态（设置关着 ⇒ 右键那条 `if` 根本不走到这里）。
function M:Probe(enabledSetting)
    local withTarget, withAction, dead = 0, 0, {}
    for _, entry in ipairs(ENTRIES) do
        if TargetButtonFor(entry) then
            withTarget = withTarget + 1
        elseif SafeActionFor(entry) then
            withAction = withAction + 1
        else
            dead[#dead + 1] = entry.label
        end
    end
    ns:Print(("微菜单：%d 个入口定义 · 可安全转发 %d · 纯 C_* 动作 %d · 建不出行 %s"):format(
        #ENTRIES, withTarget, withAction, (#dead > 0) and table.concat(dead, "、") or "无"))

    if not frame then Build() end
    if not frame then
        ns:Print("|cffff6b6b面板造不出来|r（上面「建不出行」若列全了入口，就是这个客户端一颗可转发的按钮都没有）")
        return
    end

    local protFrame = (type(frame.IsProtected) == "function") and frame:IsProtected() or false
    local rowProt = 0
    for _, row in ipairs(rows or {}) do
        if type(row.IsProtected) == "function" and row:IsProtected() then rowProt = rowProt + 1 end
    end
    ns:Print(("面板：已建 · 受保护=%s · 行 %d 颗（其中受保护 %d）· 高度 %.1f · 当前 shown=%s"):format(
        tostring(protFrame), #(rows or {}), rowProt, frame:GetHeight() or 0, tostring(frame:IsShown())))
    ns:Print(("设置 microMenu=%s ⇒ %s"):format(tostring(enabledSetting),
        enabledSetting and "右键会走到这里" or "右键不会走到这里（模块里那道 if 直接跳过）"))

    if protFrame or rowProt > 0 then
        ns:Print("|cffff6b6b判读：面板被标成受保护|r ⇒ 之后每次 frame:SetPoint/SetHeight 都会被拒"
            .. "（和行上的 SecureActionButtonTemplate 锚进同一个家族 = 信息栏 §8.37 那个坑）。"
            .. "证据看 /mui logs 里有没有一批 ADDON_ACTION_BLOCKED MonetUI Frame:…。")
    else
        ns:Print("判读：面板与行都不受保护 ⇒ 每次展开重摆是安全的。")
    end
end

ns:GetModule("Minimap").microMenu = M
